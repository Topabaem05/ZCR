//! Development evidence tool (T01). S02 RED stub: public API only.

const std = @import("std");
const core = @import("zcr_core");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const evidence_schema_version = "zcr-evidence/1";
pub const ledger_schema_version = "zcr-step-ledger/1";

pub const Git = struct { exe: []const u8, environ: *const Environ.Map };

pub const DirtyKind = enum { modified, added, deleted, renamed, copied, type_changed, unmerged, untracked };
pub const DirtyEntry = struct { kind: DirtyKind, path: []const u8, orig_path: ?[]const u8 = null };

pub const WorktreeState = struct {
    toplevel: []const u8,
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
    schema_version: []const u8 = evidence_schema_version,
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
    schema_version: []const u8 = ledger_schema_version,
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

pub fn findGit(arena: Allocator, io: Io, environ: *const Environ.Map) !Git {
    _ = .{ arena, io, environ };
    return error.NotImplemented;
}

pub fn inspect(arena: Allocator, io: Io, git: Git, worktree: []const u8) !WorktreeState {
    _ = .{ arena, io, git, worktree };
    return error.NotImplemented;
}

pub fn preflight(arena: Allocator, io: Io, git: Git, worktree: []const u8) !Preflight {
    _ = .{ arena, io, git, worktree };
    return error.NotImplemented;
}

pub fn record(arena: Allocator, io: Io, git: Git, worktree: []const u8, input: RecordInput) !Evidence {
    _ = .{ arena, io, git, worktree, input };
    return error.NotImplemented;
}

pub fn verify(arena: Allocator, io: Io, git: Git, worktree: []const u8, ev: *const Evidence) !void {
    _ = .{ arena, io, git, worktree, ev };
    return error.NotImplemented;
}

pub fn evidenceToJson(arena: Allocator, ev: *const Evidence) ![]u8 {
    _ = .{ arena, ev };
    return error.NotImplemented;
}

pub fn parseEvidence(arena: Allocator, json: []const u8) !Evidence {
    _ = .{ arena, json };
    return error.NotImplemented;
}

pub fn contractDigest(arena: Allocator, io: Io, git: Git, worktree: []const u8, paths: []const []const u8) ![]const u8 {
    _ = .{ arena, io, git, worktree, paths };
    return error.NotImplemented;
}

pub fn beginLedger(arena: Allocator, io: Io, git: Git, worktree: []const u8, task_id: []const u8, contract_paths: []const []const u8) !Ledger {
    _ = .{ arena, io, git, worktree, task_id, contract_paths };
    return error.NotImplemented;
}

pub fn appendStep(arena: Allocator, io: Io, git: Git, worktree: []const u8, ledger: *Ledger, step: StepId, result: StepResult, evidence_paths: []const []const u8) !void {
    _ = .{ arena, io, git, worktree, ledger, step, result, evidence_paths };
    return error.NotImplemented;
}

pub fn saveLedger(arena: Allocator, io: Io, ledger: *const Ledger, path: []const u8) !void {
    _ = .{ arena, io, ledger, path };
    return error.NotImplemented;
}

pub fn loadLedger(arena: Allocator, io: Io, path: []const u8) !Ledger {
    _ = .{ arena, io, path };
    return error.NotImplemented;
}

pub fn resumeTask(arena: Allocator, io: Io, git: Git, worktree: []const u8, ledger: *const Ledger) !Resume {
    _ = .{ arena, io, git, worktree, ledger };
    return error.NotImplemented;
}

pub fn verifyContracts(arena: Allocator, io: Io, root: []const u8) !ContractReport {
    _ = .{ arena, io, root };
    return error.NotImplemented;
}

pub fn main() u8 {
    return 1;
}
