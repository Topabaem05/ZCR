//! Development evidence tool (T01; DEV-01, DEV-03).
//!
//! Keeps implementation tasks from contaminating each other:
//!   preflight        refuse to claim a worktree with user changes; never stash/reset/clean
//!   record, verify   bind a test result to worktree identity, commit, tree and binary digest
//!   ledger-*, resume persist step state and re-validate it in a new model session
//!   contract-digest  digest of tracked contract files (same method as T00)
//!   verify-contracts core declarations against contracts/ and config/
//!
//! Git is run with explicit argv and `-C <worktree>`; the process never changes
//! its working directory or GIT_DIR. See AGENTS.md for command usage.

const std = @import("std");
const core = @import("zcr_core");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const evidence_schema_version = "zcr-evidence/1";
pub const ledger_schema_version = "zcr-step-ledger/1";

const git_timeout_ms = 30_000;
const max_git_output = 16 * 1024 * 1024;
const max_state_file = 16 * 1024 * 1024;
const hash_chunk_bytes = 64 * 1024;

pub const Git = struct { exe: []const u8, environ: *const Environ.Map };

pub const DirtyKind = enum { modified, added, deleted, renamed, copied, type_changed, unmerged, untracked };
pub const DirtyEntry = struct { kind: DirtyKind, path: []const u8, orig_path: ?[]const u8 = null };

pub const WorktreeState = struct {
    toplevel: []const u8,
    /// Canonical per-worktree git dir; the identity that HEAD alone cannot provide.
    absolute_git_dir: []const u8,
    common_dir: []const u8,
    head_commit: []const u8,
    head_tree: []const u8,
    branch: ?[]const u8,
    entries: []const DirtyEntry,

    pub fn isClean(state: WorktreeState) bool {
        return state.entries.len == 0;
    }
};

pub const Preflight = struct { ok: bool, state: WorktreeState, reasons: []const []const u8 };

pub const Evidence = struct {
    schema_version: []const u8,
    task_id: []const u8,
    label: []const u8,
    command: []const u8,
    exit_code: u8,
    source_commit: []const u8,
    source_tree: []const u8,
    worktree_git_dir: []const u8,
    binary_path: []const u8,
    binary_sha256: []const u8,
    recorded_at_unix_ms: i64,
};

pub const RecordInput = struct {
    task_id: []const u8,
    label: []const u8,
    command: []const u8,
    exit_code: u8,
    binary_path: []const u8,
};

pub const StepId = enum { S01, S02, S03, S04, S05, S06 };
pub const StepResult = enum { pass, fail };

pub const StepRecord = struct {
    step_id: StepId,
    result: StepResult,
    head_commit: []const u8,
    recorded_at_unix_ms: i64,
    evidence: []const []const u8 = &.{},
};

pub const Ledger = struct {
    schema_version: []const u8,
    task_id: []const u8,
    worktree_git_dir: []const u8,
    base_commit: []const u8,
    contract_paths: []const []const u8,
    contract_digest: []const u8,
    steps: []const StepRecord,
};

pub const Resume = struct { next_step: ?StepId, head_commit: []const u8 };

pub const CheckStatus = enum { pass, fail };
pub const Check = struct { name: []const u8, status: CheckStatus, detail: []const u8 };
pub const ContractReport = struct { checks: []const Check, failed: usize };

pub const RejectError = error{
    DirtyWorktree,
    WorktreeMismatch,
    SourceCommitMismatch,
    SourceTreeMismatch,
    BinaryDigestMismatch,
    SchemaMismatch,
    BaseNotAncestor,
    HeadMismatch,
    ContractDigestMismatch,
    StepOrderInvalid,
};

// ------------------------------------------------------------------ git

pub fn findGit(arena: Allocator, io: Io, environ: *const Environ.Map) !Git {
    const path_var = environ.get("PATH") orelse return error.GitNotFound;
    var dirs = std.mem.tokenizeScalar(u8, path_var, ':');
    while (dirs.next()) |dir| {
        if (!std.fs.path.isAbsolute(dir)) continue;
        const candidate = try std.fs.path.join(arena, &.{ dir, "git" });
        const stat = Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
        if (stat.kind != .file or stat.permissions.toMode() & 0o111 == 0) continue;
        return .{ .exe = candidate, .environ = environ };
    }
    return error.GitNotFound;
}

const GitResult = struct { exit_code: ?u8, stdout: []u8, stderr: []u8 };

fn runGit(arena: Allocator, io: Io, git: Git, worktree: []const u8, args: []const []const u8) !GitResult {
    const argv = try arena.alloc([]const u8, args.len + 3);
    argv[0] = git.exe;
    argv[1] = "-C";
    argv[2] = worktree;
    @memcpy(argv[3..], args);
    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .environ_map = git.environ,
        .stdout_limit = .limited(max_git_output),
        .stderr_limit = .limited(max_git_output),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(git_timeout_ms), .clock = .awake } },
    });
    return .{
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => null,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// Runs git and returns stdout, or error.GitCommandFailed on any non-zero exit.
fn gitOutput(arena: Allocator, io: Io, git: Git, worktree: []const u8, args: []const []const u8) ![]const u8 {
    const result = try runGit(arena, io, git, worktree, args);
    if (result.exit_code != null and result.exit_code.? == 0) return result.stdout;
    std.log.debug("git {s} failed: {s}", .{ args[0], result.stderr });
    return error.GitCommandFailed;
}

fn gitLine(arena: Allocator, io: Io, git: Git, worktree: []const u8, args: []const []const u8) ![]const u8 {
    return std.mem.trim(u8, try gitOutput(arena, io, git, worktree, args), " \r\n");
}

fn isAncestor(arena: Allocator, io: Io, git: Git, worktree: []const u8, ancestor: []const u8, descendant: []const u8) !bool {
    const result = try runGit(arena, io, git, worktree, &.{ "merge-base", "--is-ancestor", ancestor, descendant });
    // 0 ancestor, 1 not an ancestor, anything else (unknown object) cannot be trusted as one.
    return result.exit_code != null and result.exit_code.? == 0;
}

// ------------------------------------------------------------------ worktree state and preflight

pub fn inspect(arena: Allocator, io: Io, git: Git, worktree: []const u8) !WorktreeState {
    const git_dir = try gitLine(arena, io, git, worktree, &.{ "rev-parse", "--absolute-git-dir" });
    const common_dir = try gitLine(arena, io, git, worktree, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    const branch = try runGit(arena, io, git, worktree, &.{ "symbolic-ref", "-q", "--short", "HEAD" });
    const status = try gitOutput(arena, io, git, worktree, &.{ "status", "--porcelain=v2", "-z", "--untracked-files=all" });
    return .{
        .toplevel = try gitLine(arena, io, git, worktree, &.{ "rev-parse", "--show-toplevel" }),
        .absolute_git_dir = try Io.Dir.realPathFileAbsoluteAlloc(io, git_dir, arena),
        .common_dir = try Io.Dir.realPathFileAbsoluteAlloc(io, common_dir, arena),
        .head_commit = try gitLine(arena, io, git, worktree, &.{ "rev-parse", "HEAD" }),
        .head_tree = try gitLine(arena, io, git, worktree, &.{ "rev-parse", "HEAD^{tree}" }),
        .branch = if (branch.exit_code != null and branch.exit_code.? == 0) std.mem.trim(u8, branch.stdout, " \r\n") else null,
        .entries = try parsePorcelainV2(arena, status),
    };
}

/// Parses `git status --porcelain=v2 -z`. Paths may contain spaces; renames
/// carry the original path in the following NUL-terminated field.
pub fn parsePorcelainV2(arena: Allocator, bytes: []const u8) ![]const DirtyEntry {
    var entries: std.ArrayList(DirtyEntry) = .empty;
    var fields = std.mem.splitScalar(u8, bytes, 0);
    while (fields.next()) |record_| {
        if (record_.len < 2) continue;
        switch (record_[0]) {
            '1' => {
                const xy = try statusXy(record_);
                try entries.append(arena, .{ .kind = ordinaryKind(xy), .path = try afterFields(record_, 8) });
            },
            '2' => {
                const xy = try statusXy(record_);
                const orig = fields.next() orelse return error.MalformedGitStatus;
                const kind: DirtyKind = if (std.mem.indexOfScalar(u8, xy, 'C') != null) .copied else .renamed;
                try entries.append(arena, .{ .kind = kind, .path = try afterFields(record_, 9), .orig_path = orig });
            },
            'u' => try entries.append(arena, .{ .kind = .unmerged, .path = try afterFields(record_, 10) }),
            '?' => try entries.append(arena, .{ .kind = .untracked, .path = record_[2..] }),
            '!', '#' => {},
            else => return error.MalformedGitStatus,
        }
    }
    return entries.items;
}

fn statusXy(record_: []const u8) ![]const u8 {
    if (record_.len < 4 or record_[1] != ' ') return error.MalformedGitStatus;
    return record_[2..4];
}

fn ordinaryKind(xy: []const u8) DirtyKind {
    if (std.mem.indexOfScalar(u8, xy, 'D') != null) return .deleted;
    if (std.mem.indexOfScalar(u8, xy, 'A') != null) return .added;
    if (std.mem.indexOfScalar(u8, xy, 'T') != null) return .type_changed;
    return .modified;
}

/// Returns the remainder after `count` space-separated fields.
fn afterFields(record_: []const u8, count: usize) ![]const u8 {
    var index: usize = 0;
    var seen: usize = 0;
    while (seen < count) : (seen += 1) {
        index = (std.mem.indexOfScalarPos(u8, record_, index, ' ') orelse return error.MalformedGitStatus) + 1;
    }
    return record_[index..];
}

const in_progress_markers = [_][]const u8{ "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "rebase-merge", "rebase-apply" };

/// Read-only claim check. A dirty or mid-operation worktree is reported, never repaired.
pub fn preflight(arena: Allocator, io: Io, git: Git, worktree: []const u8) !Preflight {
    const state = try inspect(arena, io, git, worktree);
    var reasons: std.ArrayList([]const u8) = .empty;
    if (!state.isClean()) {
        try reasons.append(arena, try std.fmt.allocPrint(
            arena,
            "worktree has {d} uncommitted entries (tracked, untracked, renamed or deleted); preserve them and claim a clean task worktree instead",
            .{state.entries.len},
        ));
    }
    for (in_progress_markers) |marker| {
        const marker_path = try std.fs.path.join(arena, &.{ state.absolute_git_dir, marker });
        if (Io.Dir.cwd().statFile(io, marker_path, .{})) |_| {
            try reasons.append(arena, try std.fmt.allocPrint(arena, "git operation in progress ({s})", .{marker}));
        } else |_| {}
    }
    return .{ .ok = reasons.items.len == 0, .state = state, .reasons = reasons.items };
}

// ------------------------------------------------------------------ evidence

pub fn record(arena: Allocator, io: Io, git: Git, worktree: []const u8, input: RecordInput) !Evidence {
    const state = try inspect(arena, io, git, worktree);
    if (!state.isClean()) return error.DirtyWorktree;
    return .{
        .schema_version = evidence_schema_version,
        .task_id = try arena.dupe(u8, input.task_id),
        .label = try arena.dupe(u8, input.label),
        .command = try arena.dupe(u8, input.command),
        .exit_code = input.exit_code,
        .source_commit = state.head_commit,
        .source_tree = state.head_tree,
        .worktree_git_dir = state.absolute_git_dir,
        .binary_path = try arena.dupe(u8, input.binary_path),
        .binary_sha256 = try hashFileHex(arena, io, input.binary_path),
        .recorded_at_unix_ms = nowUnixMs(io),
    };
}

/// Accepts evidence only for this worktree, its clean current commit and the
/// exact binary that produced the result.
pub fn verify(arena: Allocator, io: Io, git: Git, worktree: []const u8, ev: *const Evidence) !void {
    if (!std.mem.eql(u8, ev.schema_version, evidence_schema_version)) return error.SchemaMismatch;
    const state = try inspect(arena, io, git, worktree);
    if (!std.mem.eql(u8, ev.worktree_git_dir, state.absolute_git_dir)) return error.WorktreeMismatch;
    if (!state.isClean()) return error.DirtyWorktree;
    if (!std.mem.eql(u8, ev.source_commit, state.head_commit)) return error.SourceCommitMismatch;
    if (!std.mem.eql(u8, ev.source_tree, state.head_tree)) return error.SourceTreeMismatch;
    const actual = hashFileHex(arena, io, ev.binary_path) catch |err| switch (err) {
        error.FileNotFound => return error.BinaryDigestMismatch,
        else => |e| return e,
    };
    if (!std.mem.eql(u8, ev.binary_sha256, actual)) return error.BinaryDigestMismatch;
}

pub fn evidenceToJson(arena: Allocator, ev: *const Evidence) ![]u8 {
    return std.json.Stringify.valueAlloc(arena, ev.*, .{ .whitespace = .indent_2 });
}

pub fn parseEvidence(arena: Allocator, json: []const u8) !Evidence {
    const ev = try std.json.parseFromSliceLeaky(Evidence, arena, json, .{ .allocate = .alloc_always });
    if (!std.mem.eql(u8, ev.schema_version, evidence_schema_version)) return error.SchemaMismatch;
    return ev;
}

// ------------------------------------------------------------------ contract digest

/// sha256 over `<sha256hex>  <path>\n` for tracked files under `paths`, in byte
/// order: the same value as
/// `git ls-files -z <paths> | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256`.
pub fn contractDigest(arena: Allocator, io: Io, git: Git, worktree: []const u8, paths: []const []const u8) ![]const u8 {
    const args = try arena.alloc([]const u8, paths.len + 3);
    args[0] = "ls-files";
    args[1] = "-z";
    args[2] = "--";
    @memcpy(args[3..], paths);
    const listing = try gitOutput(arena, io, git, worktree, args);

    var files: std.ArrayList([]const u8) = .empty;
    var names = std.mem.tokenizeScalar(u8, listing, 0);
    while (names.next()) |name| try files.append(arena, name);
    std.mem.sort([]const u8, files.items, {}, lessThanBytes);

    var outer = Sha256.init(.{});
    for (files.items) |name| {
        const hex = try hashFileHex(arena, io, try std.fs.path.join(arena, &.{ worktree, name }));
        outer.update(hex);
        outer.update("  ");
        outer.update(name);
        outer.update("\n");
    }
    return arena.dupe(u8, &std.fmt.bytesToHex(outer.finalResult(), .lower));
}

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ------------------------------------------------------------------ step ledger

pub fn beginLedger(arena: Allocator, io: Io, git: Git, worktree: []const u8, task_id: []const u8, contract_paths: []const []const u8) !Ledger {
    const state = try inspect(arena, io, git, worktree);
    if (!state.isClean()) return error.DirtyWorktree;
    const paths = try arena.alloc([]const u8, contract_paths.len);
    for (paths, contract_paths) |*dst, src| dst.* = try arena.dupe(u8, src);
    return .{
        .schema_version = ledger_schema_version,
        .task_id = try arena.dupe(u8, task_id),
        .worktree_git_dir = state.absolute_git_dir,
        .base_commit = state.head_commit,
        .contract_paths = paths,
        .contract_digest = try contractDigest(arena, io, git, worktree, paths),
        .steps = &.{},
    };
}

/// The step a ledger allows next: S01 first, the same step again after a
/// failure, otherwise the following step. Null once S06 has passed.
pub fn expectedNextStep(ledger: *const Ledger) ?StepId {
    if (ledger.steps.len == 0) return .S01;
    const last = ledger.steps[ledger.steps.len - 1];
    if (last.result == .fail) return last.step_id;
    const next = @intFromEnum(last.step_id) + 1;
    if (next >= @typeInfo(StepId).@"enum".fields.len) return null;
    return @enumFromInt(next);
}

/// Records a step bound to the current clean commit. Refuses to skip steps,
/// rewrite recorded history or record under a changed contract.
pub fn appendStep(
    arena: Allocator,
    io: Io,
    git: Git,
    worktree: []const u8,
    ledger: *Ledger,
    step: StepId,
    result: StepResult,
    evidence_paths: []const []const u8,
) !void {
    const state = try checkLedgerTree(arena, io, git, worktree, ledger);
    if (expectedNextStep(ledger) != step) return error.StepOrderInvalid;
    if (ledger.steps.len > 0) {
        const previous = ledger.steps[ledger.steps.len - 1].head_commit;
        if (!try isAncestor(arena, io, git, worktree, previous, state.head_commit)) return error.HeadMismatch;
    }
    const digest = try contractDigest(arena, io, git, worktree, ledger.contract_paths);
    if (!std.mem.eql(u8, digest, ledger.contract_digest)) return error.ContractDigestMismatch;

    const paths = try arena.alloc([]const u8, evidence_paths.len);
    for (paths, evidence_paths) |*dst, src| dst.* = try arena.dupe(u8, src);
    const steps = try arena.alloc(StepRecord, ledger.steps.len + 1);
    @memcpy(steps[0..ledger.steps.len], ledger.steps);
    steps[ledger.steps.len] = .{
        .step_id = step,
        .result = result,
        .head_commit = state.head_commit,
        .recorded_at_unix_ms = nowUnixMs(io),
        .evidence = paths,
    };
    ledger.steps = steps;
}

/// Re-validates a ledger against the real tree before a new session continues.
pub fn resumeTask(arena: Allocator, io: Io, git: Git, worktree: []const u8, ledger: *const Ledger) !Resume {
    const state = try checkLedgerTree(arena, io, git, worktree, ledger);
    const expected_head = if (ledger.steps.len == 0) ledger.base_commit else ledger.steps[ledger.steps.len - 1].head_commit;
    if (!std.mem.eql(u8, expected_head, state.head_commit)) return error.HeadMismatch;
    const digest = try contractDigest(arena, io, git, worktree, ledger.contract_paths);
    if (!std.mem.eql(u8, digest, ledger.contract_digest)) return error.ContractDigestMismatch;
    return .{ .next_step = expectedNextStep(ledger), .head_commit = state.head_commit };
}

/// Checks shared by resume and append: schema, worktree identity, clean tree, base ancestry.
fn checkLedgerTree(arena: Allocator, io: Io, git: Git, worktree: []const u8, ledger: *const Ledger) !WorktreeState {
    if (!std.mem.eql(u8, ledger.schema_version, ledger_schema_version)) return error.SchemaMismatch;
    const state = try inspect(arena, io, git, worktree);
    if (!std.mem.eql(u8, ledger.worktree_git_dir, state.absolute_git_dir)) return error.WorktreeMismatch;
    if (!state.isClean()) return error.DirtyWorktree;
    if (!try isAncestor(arena, io, git, worktree, ledger.base_commit, state.head_commit)) return error.BaseNotAncestor;
    return state;
}

pub fn saveLedger(arena: Allocator, io: Io, ledger: *const Ledger, path: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(arena, ledger.*, .{ .whitespace = .indent_2 });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

pub fn loadLedger(arena: Allocator, io: Io, path: []const u8) !Ledger {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_state_file));
    const ledger = try std.json.parseFromSliceLeaky(Ledger, arena, bytes, .{ .allocate = .alloc_always });
    if (!std.mem.eql(u8, ledger.schema_version, ledger_schema_version)) return error.SchemaMismatch;
    return ledger;
}

// ------------------------------------------------------------------ contract verification

const Checker = struct {
    arena: Allocator,
    checks: std.ArrayList(Check) = .empty,
    failed: usize = 0,

    fn add(c: *Checker, name: []const u8, ok: bool, detail: []const u8) !void {
        if (!ok) c.failed += 1;
        try c.checks.append(c.arena, .{ .name = name, .status = if (ok) .pass else .fail, .detail = detail });
    }

    fn expectInt(c: *Checker, name: []const u8, value: ?std.json.Value, expected: i64) !void {
        const found: ?i64 = if (value) |v| switch (v) {
            .integer => |i| i,
            else => null,
        } else null;
        const ok = found != null and found.? == expected;
        try c.add(name, ok, try std.fmt.allocPrint(c.arena, "expected {d}, found {?d}", .{ expected, found }));
    }

    fn expectString(c: *Checker, name: []const u8, value: ?std.json.Value, expected: []const u8) !void {
        const found: ?[]const u8 = if (value) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null;
        const ok = found != null and std.mem.eql(u8, found.?, expected);
        try c.add(name, ok, try std.fmt.allocPrint(c.arena, "expected \"{s}\", found \"{s}\"", .{ expected, found orelse "<missing>" }));
    }

    /// The JSON enum array must list the Zig enum's tags in declaration order.
    fn expectEnum(c: *Checker, name: []const u8, comptime E: type, value: ?std.json.Value) !void {
        const names = comptime enumNames(E);
        var ok = false;
        if (value) |v| if (v == .array and v.array.items.len == names.len) {
            ok = true;
            for (v.array.items, names) |item, expected| {
                if (item != .string or !std.mem.eql(u8, item.string, expected)) ok = false;
            }
        };
        try c.add(name, ok, try std.fmt.allocPrint(c.arena, "{s} tags {s}", .{ @typeName(E), try std.mem.join(c.arena, ",", &names) }));
    }
};

fn enumNames(comptime E: type) [@typeInfo(E).@"enum".fields.len][]const u8 {
    const fields = @typeInfo(E).@"enum".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, i| names[i] = field.name;
    return names;
}

/// Walks object keys; a key of the form "#N" indexes an array.
fn at(value: std.json.Value, keys: []const []const u8) ?std.json.Value {
    var current = value;
    for (keys) |key| {
        if (key.len > 1 and key[0] == '#') {
            const index = std.fmt.parseInt(usize, key[1..], 10) catch return null;
            if (current != .array or index >= current.array.items.len) return null;
            current = current.array.items[index];
        } else {
            if (current != .object) return null;
            current = current.object.get(key) orelse return null;
        }
    }
    return current;
}

const ContractFiles = struct {
    limits: std.json.Value,
    memory_profiles: std.json.Value,
    scheduler_profiles: std.json.Value,
    response: std.json.Value,
    data: std.json.Value,
    tools: std.json.Value,
    manifest: std.json.Value,
    inputs: [core_input_names.len]std.json.Value,
};

const core_input_names = [_][]const u8{ "zcr_read", "zcr_files", "zcr_search", "zcr_batch_read", "zcr_patch", "zcr_create", "zcr_status", "zcr_health" };

fn loadJson(arena: Allocator, io: Io, root: []const u8, relative: []const u8) !std.json.Value {
    const path = try std.fs.path.join(arena, &.{ root, relative });
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_state_file));
    return std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
}

pub fn verifyContracts(arena: Allocator, io: Io, root: []const u8) !ContractReport {
    var files: ContractFiles = .{
        .limits = try loadJson(arena, io, root, "config/limits.json"),
        .memory_profiles = try loadJson(arena, io, root, "config/memory-profiles.json"),
        .scheduler_profiles = try loadJson(arena, io, root, "config/scheduler-profiles.json"),
        .response = try loadJson(arena, io, root, "contracts/response.schema.json"),
        .data = try loadJson(arena, io, root, "contracts/data.schema.json"),
        .tools = try loadJson(arena, io, root, "contracts/tools.json"),
        .manifest = try loadJson(arena, io, root, "contracts/task-manifest.schema.json"),
        .inputs = undefined,
    };
    for (&files.inputs, core_input_names) |*input, name| {
        input.* = try loadJson(arena, io, root, try std.fmt.allocPrint(arena, "contracts/inputs/{s}.schema.json", .{name}));
    }

    var c: Checker = .{ .arena = arena };
    try checkLimits(&c, files.limits);
    try checkMemoryProfiles(&c, files.memory_profiles);
    try checkScheduler(&c, files.scheduler_profiles);
    try checkEnvelope(&c, files.response, files.tools, files.manifest, files.data);
    try checkInputs(&c, &files);
    return .{ .checks = c.checks.items, .failed = c.failed };
}

fn checkLimits(c: *Checker, json: std.json.Value) !void {
    const Limits = core.limits.Limits;
    const fields = @typeInfo(Limits).@"struct".fields;
    const declared = comptime blk: {
        var names: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| names[i] = field.name;
        break :blk names;
    };
    inline for (fields) |field| {
        try c.expectInt("config/limits.json " ++ field.name, at(json, &.{ "limits", field.name }), @intCast(@field(core.limits.values, field.name)));
    }
    var undeclared: std.ArrayList([]const u8) = .empty;
    if (at(json, &.{"limits"})) |limits| if (limits == .object) {
        var keys = limits.object.iterator();
        while (keys.next()) |entry| {
            for (declared) |name| {
                if (std.mem.eql(u8, name, entry.key_ptr.*)) break;
            } else try undeclared.append(c.arena, entry.key_ptr.*);
        }
    };
    try c.add("config/limits.json keys declared in core", undeclared.items.len == 0, try std.mem.join(c.arena, ",", undeclared.items));
}

fn checkMemoryProfiles(c: *Checker, json: std.json.Value) !void {
    const rows = at(json, &.{"profiles"});
    const count_ok = rows != null and rows.? == .array and rows.?.array.items.len == core.limits.memory_profiles.len;
    try c.add("config/memory-profiles.json row count", count_ok, try std.fmt.allocPrint(c.arena, "core declares {d} rows", .{core.limits.memory_profiles.len}));
    if (!count_ok) return;

    for (core.limits.memory_profiles, rows.?.array.items, 0..) |row, json_row, i| {
        var mismatches: std.ArrayList([]const u8) = .empty;
        inline for (@typeInfo(core.limits.MemoryProfile).@"struct".fields) |field| {
            const expected = @field(row, field.name);
            const found = json_row.object.get(field.name);
            const ok = if (@typeInfo(field.type) == .optional)
                (if (expected) |e| found != null and found.? == .integer and found.?.integer == e else found != null and found.? == .null)
            else
                found != null and found.? == .integer and found.?.integer == expected;
            if (!ok) try mismatches.append(c.arena, field.name);
        }
        try c.add(
            try std.fmt.allocPrint(c.arena, "config/memory-profiles.json row {d}", .{i}),
            mismatches.items.len == 0,
            try std.mem.join(c.arena, ",", mismatches.items),
        );

        const parts = row.base_mib + row.emergency_mib + row.paths_mib + row.content_mib + row.ast_mib + row.inflight_mib;
        try c.add(
            try std.fmt.allocPrint(c.arena, "memory profile {d} parts sum to tracked (75% of group)", .{i}),
            parts == row.tracked_mib and row.tracked_mib * 4 == row.group_mib * 3,
            try std.fmt.allocPrint(c.arena, "parts={d} tracked={d} group={d}", .{ parts, row.tracked_mib, row.group_mib }),
        );
    }
}

fn checkScheduler(c: *Checker, json: std.json.Value) !void {
    const s = core.limits.scheduler;
    inline for (@typeInfo(core.limits.SchedulerProfiles).@"struct".fields) |field| {
        const range = @field(s.profiles, field.name);
        var ok = true;
        inline for (@typeInfo(core.limits.PermitRange).@"struct".fields) |permit| {
            const found = at(json, &.{ "profiles", field.name, permit.name });
            if (found == null or found.? != .integer or found.?.integer != @field(range, permit.name)) ok = false;
        }
        try c.add("config/scheduler-profiles.json profile " ++ field.name, ok, "cpu/io initial and max permits");
    }

    var ok = true;
    const qos = [_]struct { key: []const u8, class: core.limits.QosClass }{
        .{ .key = "foreground", .class = s.qos_foreground },
        .{ .key = "maintenance", .class = s.qos_maintenance },
        .{ .key = "prefetch", .class = s.qos_prefetch },
    };
    for (qos) |entry| {
        const found = at(json, &.{ "qos", entry.key });
        if (found == null or found.? != .string or !std.mem.eql(u8, found.?.string, @tagName(entry.class))) ok = false;
    }
    try c.add("config/scheduler-profiles.json qos classes", ok, "foreground/maintenance/prefetch");

    try c.expectString("config/scheduler-profiles.json hardware_ceiling", at(json, &.{"hardware_ceiling"}), s.hardware_ceiling_formula);
    const clamp = at(json, &.{"all_cpu_counts_clamped_to_hardware_ceiling"});
    try c.add("config/scheduler-profiles.json clamp flag", clamp != null and clamp.? == .bool and clamp.?.bool == s.all_cpu_counts_clamped_to_hardware_ceiling, "");
    try c.expectInt("config/scheduler-profiles.json foreground_short_reserved_permits", at(json, &.{"foreground_short_reserved_permits"}), s.foreground_short_reserved_permits);
    try c.expectInt("config/scheduler-profiles.json weight foreground", at(json, &.{ "foreground_to_maintenance_weight", "#0" }), s.foreground_to_maintenance_weight[0]);
    try c.expectInt("config/scheduler-profiles.json weight maintenance", at(json, &.{ "foreground_to_maintenance_weight", "#1" }), s.foreground_to_maintenance_weight[1]);
    try c.expectInt("config/scheduler-profiles.json normal_stable_recovery_ms", at(json, &.{"normal_stable_recovery_ms"}), s.normal_stable_recovery_ms);
    try c.expectInt("config/scheduler-profiles.json recovery_step_ms", at(json, &.{"recovery_step_ms"}), s.recovery_step_ms);
    try c.expectInt("config/scheduler-profiles.json recovery_step_percentage_points", at(json, &.{"recovery_step_percentage_points"}), s.recovery_step_percentage_points);
}

fn checkEnvelope(c: *Checker, response: std.json.Value, tools: std.json.Value, manifest: std.json.Value, data: std.json.Value) !void {
    const values = core.limits.values;
    try c.expectString("response schema_version", at(response, &.{ "properties", "schema_version", "const" }), core.schema_version);
    try c.expectEnum("response error codes", core.errors.WireCode, at(response, &.{ "properties", "error", "oneOf", "#1", "properties", "code", "enum" }));
    try c.expectEnum("response error codes (failure branch)", core.errors.WireCode, at(response, &.{ "allOf", "#0", "else", "properties", "error", "properties", "code", "enum" }));
    try c.expectEnum("response consistency", core.Consistency, at(response, &.{ "properties", "consistency", "enum" }));
    try c.expectEnum("response coverage.index_state", core.IndexState, at(response, &.{ "properties", "coverage", "properties", "index_state", "enum" }));
    try c.expectEnum("response meta.cache", core.CacheResult, at(response, &.{ "properties", "meta", "properties", "cache", "enum" }));
    try c.expectInt("response meta.returned_bytes maximum", at(response, &.{ "properties", "meta", "properties", "returned_bytes", "maximum" }), @intCast(values.max_output_bytes));

    try c.expectString("tools.json schema_version", at(tools, &.{"schema_version"}), core.schema_version);
    try c.expectString("tools.json default_output_profile", at(tools, &.{"default_output_profile"}), @tagName(core.OutputProfile.text_v1));
    const tool_names = comptime enumNames(core.ToolName);
    var tools_ok = false;
    if (at(tools, &.{"tools"})) |list| if (list == .array and list.array.items.len == tool_names.len) {
        tools_ok = true;
        for (list.array.items, tool_names) |tool, expected| {
            const name = at(tool, &.{"name"});
            if (name == null or name.? != .string or !std.mem.eql(u8, name.?.string, expected)) tools_ok = false;
        }
    };
    try c.add("tools.json tool names", tools_ok, try std.mem.join(c.arena, ",", &tool_names));

    try c.expectEnum("task-manifest state", core.ManifestState, at(manifest, &.{ "properties", "state", "enum" }));
    try c.expectEnum("task-manifest operations", core.Operation, at(manifest, &.{ "properties", "operations", "items", "enum" }));

    try c.expectEnum("data health.pressure", core.Pressure, at(data, &.{ "$defs", "health", "properties", "pressure", "enum" }));
    try c.expectEnum("data status.write_mode", core.WriteMode, at(data, &.{ "$defs", "status", "properties", "write_mode", "enum" }));
    try c.expectInt("data read.lines maxItems", at(data, &.{ "$defs", "read", "properties", "lines", "maxItems" }), values.max_read_lines);
    try c.expectInt("data files.paths maxItems", at(data, &.{ "$defs", "files", "properties", "paths", "maxItems" }), values.max_file_results);
    try c.expectInt("data batch_read.items maxItems", at(data, &.{ "$defs", "batch_read", "properties", "items", "maxItems" }), values.max_batch_items);
}

fn checkInputs(c: *Checker, files: *const ContractFiles) !void {
    const values = core.limits.values;
    for (core_input_names, files.inputs) |name, input| {
        const prefix = try std.fmt.allocPrint(c.arena, "inputs/{s} ", .{name});
        try c.expectInt(try std.mem.concat(c.arena, u8, &.{ prefix, "output_bytes maximum" }), at(input, &.{ "properties", "output_bytes", "maximum" }), @intCast(values.max_output_bytes));
        try c.expectInt(try std.mem.concat(c.arena, u8, &.{ prefix, "output_bytes default" }), at(input, &.{ "properties", "output_bytes", "default" }), @intCast(values.default_output_bytes));
        try c.expectInt(try std.mem.concat(c.arena, u8, &.{ prefix, "deadline_ms maximum" }), at(input, &.{ "properties", "deadline_ms", "maximum" }), values.max_deadline_ms);
        try c.expectInt(try std.mem.concat(c.arena, u8, &.{ prefix, "deadline_ms default" }), at(input, &.{ "properties", "deadline_ms", "default" }), values.default_deadline_ms);
    }

    const read = files.inputs[0];
    const list = files.inputs[1];
    const search = files.inputs[2];
    const batch = files.inputs[3];
    const patch = files.inputs[4];
    const create = files.inputs[5];

    try c.expectInt("inputs/zcr_read path maxLength", at(read, &.{ "properties", "path", "maxLength" }), values.path_max_utf8_bytes);
    try c.expectInt("inputs/zcr_read line_count maximum", at(read, &.{ "properties", "line_count", "maximum" }), values.max_read_lines);
    try c.expectInt("inputs/zcr_read line_count default", at(read, &.{ "properties", "line_count", "default" }), values.default_read_lines);
    try c.expectEnum("inputs/zcr_read consistency", core.RequestConsistency, at(read, &.{ "properties", "consistency", "enum" }));

    try c.expectInt("inputs/zcr_files limit maximum", at(list, &.{ "properties", "limit", "maximum" }), values.max_file_results);
    try c.expectEnum("inputs/zcr_files order", core.Order, at(list, &.{ "properties", "order", "enum" }));
    try c.expectEnum("inputs/zcr_files consistency", core.RequestConsistency, at(list, &.{ "properties", "consistency", "enum" }));

    try c.expectInt("inputs/zcr_search limit maximum", at(search, &.{ "properties", "limit", "maximum" }), values.max_search_matches);
    try c.expectInt("inputs/zcr_search limit default", at(search, &.{ "properties", "limit", "default" }), values.default_search_matches);
    try c.expectInt("inputs/zcr_search max_file_bytes maximum", at(search, &.{ "properties", "max_file_bytes", "maximum" }), @intCast(values.max_search_file_bytes));
    try c.expectInt("inputs/zcr_search max_file_bytes default", at(search, &.{ "properties", "max_file_bytes", "default" }), @intCast(values.default_search_file_bytes));
    try c.expectEnum("inputs/zcr_search order", core.Order, at(search, &.{ "properties", "order", "enum" }));

    try c.expectInt("inputs/zcr_batch_read items maxItems", at(batch, &.{ "properties", "items", "maxItems" }), values.max_batch_items);
    try c.expectInt("inputs/zcr_batch_read line_count maximum", at(batch, &.{ "properties", "items", "items", "properties", "line_count", "maximum" }), values.max_read_lines);

    try c.expectInt("inputs/zcr_patch replacements maxItems", at(patch, &.{ "properties", "replacements", "maxItems" }), values.max_patch_spans);
    try c.expectInt("inputs/zcr_patch span start maximum", at(patch, &.{ "properties", "replacements", "items", "properties", "start", "maximum" }), @intCast(values.max_write_file_bytes));
    try c.expectInt("inputs/zcr_patch span end maximum", at(patch, &.{ "properties", "replacements", "items", "properties", "end", "maximum" }), @intCast(values.max_write_file_bytes));
    try c.expectEnum("inputs/zcr_patch durability", core.Durability, at(patch, &.{ "properties", "durability", "enum" }));

    try c.expectInt("inputs/zcr_create content maxLength", at(create, &.{ "properties", "content", "maxLength" }), @intCast(values.max_write_file_bytes));
    try c.expectEnum("inputs/zcr_create durability", core.Durability, at(create, &.{ "properties", "durability", "enum" }));
}

// ------------------------------------------------------------------ helpers

fn nowUnixMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, 1_000_000));
}

fn hashFileHex(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var hasher = Sha256.init(.{});
    var reader_buf: [hash_chunk_bytes]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buf);
    var chunk: [hash_chunk_bytes]u8 = undefined;
    while (true) {
        const n = reader.interface.readSliceShort(&chunk) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
        };
        hasher.update(chunk[0..n]);
        if (n < chunk.len) break;
    }
    return arena.dupe(u8, &std.fmt.bytesToHex(hasher.finalResult(), .lower));
}

// ------------------------------------------------------------------ CLI

const usage =
    \\usage: zcr-dev-evidence <command> [options]
    \\
    \\  preflight        --worktree DIR
    \\  record           --worktree DIR --task ID --label L --command CMD --exit N --binary FILE [--out FILE]
    \\  verify           --worktree DIR --evidence FILE
    \\  ledger-begin     --worktree DIR --task ID --ledger FILE [--contracts PATH]...
    \\  ledger-step      --worktree DIR --ledger FILE --step S0N --result pass|fail [--evidence PATH]...
    \\  resume           --worktree DIR --ledger FILE
    \\  contract-digest  --worktree DIR [--contracts PATH]...
    \\  verify-contracts --root DIR
    \\
    \\exit: 0 accepted, 1 rejected, 64 usage error
    \\
;

const Args = struct {
    arena: Allocator,
    keys: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList([]const u8) = .empty,

    fn one(a: *const Args, key: []const u8) ?[]const u8 {
        for (a.keys.items, a.values.items) |k, v| if (std.mem.eql(u8, k, key)) return v;
        return null;
    }

    fn many(a: *const Args, key: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (a.keys.items, a.values.items) |k, v| if (std.mem.eql(u8, k, key)) try out.append(a.arena, v);
        return out.items;
    }

    fn required(a: *const Args, key: []const u8) ![]const u8 {
        return a.one(key) orelse {
            std.log.err("missing --{s}", .{key});
            return error.Usage;
        };
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var argv = init.minimal.args.iterate();
    _ = argv.skip();
    const command = argv.next() orelse return usageError(io);

    var args: Args = .{ .arena = arena };
    while (argv.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) return usageError(io);
        try args.keys.append(arena, arg[2..]);
        try args.values.append(arena, argv.next() orelse return usageError(io));
    }

    return runCommand(arena, io, init.environ_map, command, &args) catch |err| switch (err) {
        error.Usage => usageError(io),
        error.DirtyWorktree,
        error.WorktreeMismatch,
        error.SourceCommitMismatch,
        error.SourceTreeMismatch,
        error.BinaryDigestMismatch,
        error.SchemaMismatch,
        error.BaseNotAncestor,
        error.HeadMismatch,
        error.ContractDigestMismatch,
        error.StepOrderInvalid,
        => {
            std.log.err("rejected: {t}", .{err});
            return 1;
        },
        else => |e| return e,
    };
}

fn runCommand(arena: Allocator, io: Io, environ: *const Environ.Map, command: []const u8, args: *const Args) !u8 {
    const stdout = Io.File.stdout();

    if (std.mem.eql(u8, command, "verify-contracts")) {
        const report = try verifyContracts(arena, io, try args.required("root"));
        for (report.checks) |check| {
            if (check.status == .fail) std.log.err("FAIL {s}: {s}", .{ check.name, check.detail });
        }
        try stdout.writeStreamingAll(io, try std.fmt.allocPrint(arena, "verify-contracts: {d} checks, {d} failed\n", .{ report.checks.len, report.failed }));
        return if (report.failed == 0) 0 else 1;
    }

    const git = try findGit(arena, io, environ);
    const worktree = try args.required("worktree");

    if (std.mem.eql(u8, command, "preflight")) {
        const result = try preflight(arena, io, git, worktree);
        try stdout.writeStreamingAll(io, try std.json.Stringify.valueAlloc(arena, result, .{ .whitespace = .indent_2 }));
        try stdout.writeStreamingAll(io, "\n");
        return if (result.ok) 0 else 1;
    }
    if (std.mem.eql(u8, command, "record")) {
        const exit_code = std.fmt.parseInt(u8, try args.required("exit"), 10) catch return error.Usage;
        const ev = try record(arena, io, git, worktree, .{
            .task_id = try args.required("task"),
            .label = try args.required("label"),
            .command = try args.required("command"),
            .exit_code = exit_code,
            .binary_path = try args.required("binary"),
        });
        const json = try evidenceToJson(arena, &ev);
        if (args.one("out")) |out| try Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = json }) else try stdout.writeStreamingAll(io, json);
        return 0;
    }
    if (std.mem.eql(u8, command, "verify")) {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, try args.required("evidence"), arena, .limited(max_state_file));
        const ev = try parseEvidence(arena, bytes);
        try verify(arena, io, git, worktree, &ev);
        try stdout.writeStreamingAll(io, "verify: accepted\n");
        return 0;
    }
    if (std.mem.eql(u8, command, "ledger-begin")) {
        const contracts = try args.many("contracts");
        const ledger = try beginLedger(arena, io, git, worktree, try args.required("task"), if (contracts.len == 0) &.{"contracts"} else contracts);
        try saveLedger(arena, io, &ledger, try args.required("ledger"));
        return 0;
    }
    if (std.mem.eql(u8, command, "ledger-step")) {
        const path = try args.required("ledger");
        var ledger = try loadLedger(arena, io, path);
        const step = std.meta.stringToEnum(StepId, try args.required("step")) orelse return error.Usage;
        const result = std.meta.stringToEnum(StepResult, try args.required("result")) orelse return error.Usage;
        try appendStep(arena, io, git, worktree, &ledger, step, result, try args.many("evidence"));
        try saveLedger(arena, io, &ledger, path);
        return 0;
    }
    if (std.mem.eql(u8, command, "resume")) {
        const ledger = try loadLedger(arena, io, try args.required("ledger"));
        const resumed = try resumeTask(arena, io, git, worktree, &ledger);
        try stdout.writeStreamingAll(io, try std.fmt.allocPrint(arena, "resume: task={s} head={s} next_step={s}\n", .{
            ledger.task_id,
            resumed.head_commit,
            if (resumed.next_step) |s| @tagName(s) else "complete",
        }));
        return 0;
    }
    if (std.mem.eql(u8, command, "contract-digest")) {
        const contracts = try args.many("contracts");
        const digest = try contractDigest(arena, io, git, worktree, if (contracts.len == 0) &.{"contracts"} else contracts);
        try stdout.writeStreamingAll(io, try std.fmt.allocPrint(arena, "{s}\n", .{digest}));
        return 0;
    }
    return error.Usage;
}

fn usageError(io: Io) u8 {
    Io.File.stderr().writeStreamingAll(io, usage) catch {};
    return 64;
}
