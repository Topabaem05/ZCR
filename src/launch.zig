//! Trusted launch configuration and startup identity binding (integrator-owned).
//! The stable manifest fingerprint authorizes existing filesystem objects. Each
//! process still obtains a fresh Registry WorkspaceId/session incarnation.
const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const workspace = @import("zcr_workspace");
const memory = @import("zcr_memory");
const mcp = @import("zcr_mcp");
const options = @import("build_options");
const ignores = @import("launch_ignore.zig");
const Io = std.Io;
const A = std.mem.Allocator;
const max_config_bytes = 1024 * 1024;

pub fn parseExpiry(value: []const u8) error{InvalidArgument}!i64 {
    if (value.len != 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':' or value[19] != 'Z') return error.InvalidArgument;
    const year = try decimal(u16, value[0..4]);
    const month = try decimal(u8, value[5..7]);
    const day = try decimal(u8, value[8..10]);
    const hour = try decimal(u8, value[11..13]);
    const minute = try decimal(u8, value[14..16]);
    const second = try decimal(u8, value[17..19]);
    if (year < 1970 or month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return error.InvalidArgument;
    if (day > std.time.epoch.getDaysInMonth(year, @enumFromInt(month))) return error.InvalidArgument;
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
    var mon: u8 = 1;
    while (mon < month) : (mon += 1) days += std.time.epoch.getDaysInMonth(year, @enumFromInt(mon));
    days += day - 1;
    return (((days * 24 + hour) * 60 + minute) * 60 + second) * 1000;
}
fn decimal(comptime T: type, text: []const u8) error{InvalidArgument}!T {
    for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidArgument;
    return std.fmt.parseInt(T, text, 10) catch error.InvalidArgument;
}
pub fn workspaceFingerprint(buffer: []u8, root: core.FileId, git: core.FileId, common: core.FileId) error{InvalidArgument}![]const u8 {
    return std.fmt.bufPrint(buffer, "fs:{d}:{d}:{d}:{d}:{d}:{d}", .{ root.device, root.inode, git.device, git.inode, common.device, common.inode }) catch error.InvalidArgument;
}

const LaunchPolicy = struct {
    status: []const u8,
    root: []const u8,
    task_manifest: []const u8,
    write_mode: core.WriteMode = .read_only,
    memory_profile: []const u8 = "auto",
    profile: []const u8 = "balanced",
    broker_allowed: bool = false,
    additional_roots: []const []const u8 = &.{},
    network_allowed: bool = false,
    arbitrary_exec_allowed: bool = false,
    git_executable: []const u8 = "/usr/bin/git",
    /// Explicit trusted absolute path. Git configuration and HOME are not loaded.
    global_exclude: ?[]const u8 = null,
};
const Manifest = struct {
    schema_version: []const u8,
    state: core.ManifestState,
    task_id: []const u8,
    workspace_id: ?[]const u8,
    base_commit: ?[]const u8,
    contract_digest: ?[]const u8,
    fence: ?u64,
    expires_at: ?[]const u8,
    read_paths: []const []const u8,
    write_paths: []const []const u8,
    immutable_paths: []const []const u8,
    operations: []const core.Operation,
    max_changed_files: u32,
};

fn readJson(comptime T: type, a: A, io: Io, path: []const u8) !std.json.Parsed(T) {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArgument;
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_config_bytes));
    defer a.free(bytes);
    // Depth/duplicate validation precedes the typed decoder, including ignored-looking fields.
    var checked = try mcp.codec.parse(a, bytes);
    defer checked.deinit();
    return std.json.parseFromSlice(T, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .ignore_unknown_fields = false });
}
fn paths(a: A, raw: []const []const u8) ![]const core.RelativePath {
    if (raw.len > 256) return error.InvalidArgument;
    const result = try a.alloc(core.RelativePath, raw.len);
    for (raw, result) |p, *out| {
        try policy.paths.validate(p);
        out.* = .{ .bytes = p };
    }
    return result;
}
fn hash(bytes: []const u8) core.Sha256 {
    var result: core.Sha256 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub fn describe(a: A, io: Io, root_path: []const u8, git_executable: []const u8) !void {
    if (!std.fs.path.isAbsolute(root_path)) return error.InvalidArgument;
    var root = try Io.Dir.openDirAbsolute(io, root_path, .{ .follow_symlinks = false });
    defer root.close(io);
    var identity = try workspace.identity.discover(a, io, git_executable, .{ .dir = root, .canonical_path = root_path });
    defer identity.deinit(io);
    var buf: [256]u8 = undefined;
    const label = try workspaceFingerprint(&buf, identity.root_id, identity.git_dir_id, identity.common_dir_id);
    const text = try std.json.Stringify.valueAlloc(a, .{ .workspace_id = label, .base_commit = identity.head[0..identity.head_len], .contract_digest = options.contract_digest }, .{});
    defer a.free(text);
    try Io.File.stdout().writeStreamingAll(io, text);
    try Io.File.stdout().writeStreamingAll(io, "\n");
}

const Authority = struct {
    registry: *workspace.Registry,
    session: core.SessionContext,
    boot: core.Uuid,
    io: Io,
    info_exclude: *const ignores.BoundFile,
    global_exclude: ?*const ignores.AbsoluteFile,
    fn validate(context: ?*anyopaque) core.AuthorizeError!void {
        const self: *Authority = @ptrCast(@alignCast(context orelse return error.OutOfScope));
        self.registry.validateSession(self.session, self.boot) catch return error.OutOfScope;
        try self.info_exclude.validate(self.io);
        if (self.global_exclude) |global| try global.validate(self.io);
    }
};

pub fn serve(a: A, io: Io, policy_path: []const u8) !void {
    var launch = try readJson(LaunchPolicy, a, io, policy_path);
    defer launch.deinit();
    const cfg = launch.value;
    if (!std.mem.eql(u8, cfg.status, "approved")) return error.ManifestUnbound;
    if (!std.fs.path.isAbsolute(cfg.root) or !std.fs.path.isAbsolute(cfg.git_executable)) return error.InvalidArgument;
    if (cfg.write_mode != .read_only or cfg.broker_allowed or cfg.additional_roots.len != 0 or cfg.network_allowed or cfg.arbitrary_exec_allowed) return error.Unsupported;
    if (!std.mem.eql(u8, cfg.profile, "balanced") or !std.mem.eql(u8, cfg.memory_profile, "auto")) return error.Unsupported;
    var manifest = try readJson(Manifest, a, io, cfg.task_manifest);
    defer manifest.deinit();
    const mf = manifest.value;
    if (!std.mem.eql(u8, mf.schema_version, "zcr-task/1") or mf.state != .active) return error.ManifestUnbound;
    if (mf.task_id.len != 3 or mf.task_id[0] != 'T' or !std.ascii.isDigit(mf.task_id[1]) or !std.ascii.isDigit(mf.task_id[2])) return error.InvalidArgument;
    const approved_workspace = mf.workspace_id orelse return error.ManifestUnbound;
    const base = mf.base_commit orelse return error.ManifestUnbound;
    const digest = mf.contract_digest orelse return error.ManifestUnbound;
    const fence = mf.fence orelse return error.ManifestUnbound;
    const expiry = try parseExpiry(mf.expires_at orelse return error.ManifestUnbound);
    const now_ms = @divFloor(Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_ms);
    if (fence == 0 or expiry <= now_ms or mf.max_changed_files > 256) return error.OutOfScope;
    if (!std.mem.eql(u8, digest, options.contract_digest)) return error.OutOfScope;
    if (mf.operations.len == 0 or mf.operations.len > 8) return error.InvalidArgument;
    for (mf.operations, 0..) |op, i| {
        if (op == .patch or op == .create) return error.Unsupported;
        for (mf.operations[0..i]) |earlier| if (earlier == op) return error.InvalidArgument;
    }
    var root = try Io.Dir.openDirAbsolute(io, cfg.root, .{ .follow_symlinks = false });
    defer root.close(io);
    const trusted: core.TrustedRoot = .{ .dir = root, .canonical_path = cfg.root };
    var discovered = try workspace.identity.discover(a, io, cfg.git_executable, trusted);
    defer discovered.deinit(io);
    var label_buffer: [256]u8 = undefined;
    const actual_label = try workspaceFingerprint(&label_buffer, discovered.root_id, discovered.git_dir_id, discovered.common_dir_id);
    if (!std.mem.eql(u8, approved_workspace, actual_label) or !std.mem.eql(u8, base, discovered.head[0..discovered.head_len])) return error.OutOfScope;

    var local = std.heap.ArenaAllocator.init(a);
    defer local.deinit();
    const allocator = local.allocator();
    const canonical = try std.json.Stringify.valueAlloc(allocator, .{ .launch = cfg, .manifest = mf }, .{});
    const bound_policy: core.Policy = .{
        .digest = hash(canonical),
        .state = .active,
        .read_paths = try paths(allocator, mf.read_paths),
        .write_paths = try paths(allocator, mf.write_paths),
        .immutable_paths = try paths(allocator, mf.immutable_paths),
        .operations = mf.operations,
        .max_changed_files = mf.max_changed_files,
    };
    var registry = try workspace.Registry.init(a, io, .{ .git_executable = cfg.git_executable });
    defer registry.deinit() catch @panic("registry teardown failed");
    const id = try registry.registerWorkspace(io, trusted, bound_policy);
    const snapshot = try registry.snapshot(id);
    // Re-check the exact handles the registry retained, not only the earlier discovery.
    const retained = try workspaceFingerprint(&label_buffer, snapshot.root_id, snapshot.git_dir_id, snapshot.repo_id.common_dir);
    if (!std.mem.eql(u8, retained, approved_workspace) or !std.mem.eql(u8, base, snapshot.head[0..snapshot.head_len])) return error.OutOfScope;
    var info_exclude = try ignores.BoundFile.init(io, discovered.common_dir, "info/exclude");
    defer info_exclude.deinit(io);
    var global_exclude: ?ignores.AbsoluteFile = if (cfg.global_exclude) |path| try ignores.AbsoluteFile.init(io, path) else null;
    defer if (global_exclude) |*global| global.deinit(io);
    var session_id: core.Uuid = undefined;
    try io.randomSecure(&session_id);
    const task_hash = hash(canonical);
    const task: core.TaskId = .{ .uuid = task_hash[0..16].* };
    const session: core.SessionContext = .{ .session_id = .{ .uuid = session_id }, .security_domain = .{ .id = std.mem.readInt(u64, task_hash[0..8], .little) }, .policy_digest = bound_policy.digest, .bound_workspace = id, .bound_task = task, .capability_handle = @enumFromInt(1) };
    try registry.bindSession(session, .{ .task_id = task, .base_commit = base, .scope_digest = bound_policy.digest, .fence = fence, .expires_at_unix_ms = expiry }, registry.bootNonce());
    var authorizer = try policy.Authorizer.init(allocator, io, snapshot.root, id, task, bound_policy, snapshot.git);
    var counters: memory.accounting.Counters = .{};
    // Until T16/T17 signals are integrated, use the most conservative documented profile.
    var launch_caps = memory.capsFor(&core.limits.memory_profiles[0], .inflight);
    launch_caps.cpu = 1;
    var budget = memory.Budget.init(1, launch_caps, &counters);
    var authority: Authority = .{ .registry = &registry, .session = session, .boot = registry.bootNonce(), .io = io, .info_exclude = &info_exclude, .global_exclude = if (global_exclude) |*global| global else null };
    var server = try mcp.Server.init(.{ .allocator = a, .io = io, .authorizer = &authorizer, .session = session, .generation = snapshot.generation, .budget = &budget, .tools_json = options.tools_json, .version = options.version, .authority_context = &authority, .validate_authority = Authority.validate, .trusted_excludes = .{ .git_info_exclude = info_exclude.file, .global_exclude = if (global_exclude) |global| global.binding.file else null } });
    try server.serve(Io.File.stdin(), Io.File.stdout());
}
