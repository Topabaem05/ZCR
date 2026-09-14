//! Broker CLI wiring (integrator-owned). Runs the built `zcr` binary as real
//! subprocesses: `zcr broker serve` and `zcr mcp --broker`. The host token only
//! travels through an inherited pipe descriptor, never argv.
const std = @import("std");
const cli = @import("cli_options");
const t = std.testing;
const io = t.io;
const A = t.allocator;

const initialize = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"broker-cli-test\",\"version\":\"1\"}}}\n";
const initialized = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n";
const read_request = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{\"path\":\"file.txt\"}}}\n";
const patch_request = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_patch\",\"arguments\":{}}}\n";

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: t.TmpDir,
    socket_path: []const u8 = "",
    policy_path: []const u8 = "",

    fn init() !*Fixture {
        const f = try A.create(Fixture);
        errdefer A.destroy(f);
        f.* = .{ .arena = .init(A), .tmp = t.tmpDir(.{}) };
        const a = f.arena.allocator();
        const private_path = try f.tmp.dir.realPathFileAlloc(io, ".", a);
        try t.expect(std.c.chmod(try a.dupeZ(u8, private_path), 0o700) == 0);
        try f.tmp.dir.createDir(io, "r", .default_dir);
        const root = try f.tmp.dir.realPathFileAlloc(io, "r", a);
        try f.git(root, &.{ "init", "-q", "-b", "main" });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "r/file.txt", .data = "broker cli alpha\n" });
        try f.git(root, &.{ "add", "." });
        try f.git(root, &.{ "-c", "user.name=T01", "-c", "user.email=t01@example.invalid", "commit", "-q", "-m", "base" });

        const described = try std.process.run(a, io, .{ .argv = &.{ cli.zcr_exe, "workspace-id", "--root", root }, .stdout_limit = .limited(65536), .stderr_limit = .limited(65536) });
        try t.expect(described.term == .exited and described.term.exited == 0);
        const Id = struct { workspace_id: []const u8, base_commit: []const u8, contract_digest: []const u8 };
        const id = try std.json.parseFromSliceLeaky(Id, a, std.mem.trim(u8, described.stdout, "\n"), .{});
        const manifest = try std.json.Stringify.valueAlloc(a, .{
            .schema_version = "zcr-task/1",
            .state = "active",
            .task_id = "T15",
            .workspace_id = id.workspace_id,
            .base_commit = id.base_commit,
            .contract_digest = id.contract_digest,
            .fence = 1,
            .expires_at = "2099-01-01T00:00:00Z",
            .read_paths = &[_][]const u8{"."},
            .write_paths = &[_][]const u8{},
            .immutable_paths = &[_][]const u8{},
            .operations = &[_][]const u8{ "read", "enumerate", "search", "status", "health" },
            .max_changed_files = 1,
        }, .{});
        try f.tmp.dir.writeFile(io, .{ .sub_path = "manifest.json", .data = manifest });
        const manifest_path = try std.fs.path.join(a, &.{ private_path, "manifest.json" });
        const launch_policy = try std.json.Stringify.valueAlloc(a, .{ .status = "approved", .root = root, .task_manifest = manifest_path, .broker_allowed = true }, .{});
        try f.tmp.dir.writeFile(io, .{ .sub_path = "policy.json", .data = launch_policy });
        f.policy_path = try std.fs.path.join(a, &.{ private_path, "policy.json" });
        f.socket_path = try std.fs.path.join(a, &.{ private_path, "s" });
        return f;
    }
    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena.deinit();
        A.destroy(f);
    }
    fn git(f: *Fixture, path: []const u8, args: []const []const u8) !void {
        const a = f.arena.allocator();
        const argv = try a.alloc([]const u8, args.len + 3);
        argv[0] = "/usr/bin/git";
        argv[1] = "-C";
        argv[2] = path;
        @memcpy(argv[3..], args);
        var env: std.process.Environ.Map = .init(a);
        try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        const result = try std.process.run(a, io, .{ .argv = argv, .environ_map = &env, .stdout_limit = .limited(65536), .stderr_limit = .limited(65536) });
        try t.expect(result.term == .exited and result.term.exited == 0);
    }
};

/// Read end of a pipe holding one token line. It is not close-on-exec, so a
/// spawned child inherits it under the same number; the parent closes it after spawning.
fn tokenPipe(token: []const u8) !std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    try t.expect(std.c.pipe(&fds) == 0);
    defer _ = std.c.close(fds[1]);
    var line: [65]u8 = undefined;
    @memcpy(line[0..token.len], token);
    line[token.len] = '\n';
    try t.expect(std.c.write(fds[1], &line, token.len + 1) == @as(isize, @intCast(token.len + 1)));
    return fds[0];
}

fn randomToken() ![64]u8 {
    var bytes: [32]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn readLine(file: std.Io.File, buffer: []u8) ![]const u8 {
    var at: usize = 0;
    while (at < buffer.len) {
        const n = std.c.read(file.handle, buffer[at..].ptr, 1);
        if (n <= 0) return buffer[0..at];
        if (buffer[at] == '\n') return buffer[0..at];
        at += 1;
    }
    return error.ResourceExhausted;
}

fn readAll(a: std.mem.Allocator, file: std.Io.File) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(file.handle, &chunk, chunk.len);
        if (n <= 0) break;
        try out.appendSlice(a, chunk[0..@intCast(n)]);
    }
    return out.items;
}

/// Reads until end of file, failing instead of blocking when the writer keeps the pipe open.
fn readAllWithin(a: std.mem.Allocator, file: std.Io.File, milliseconds: u32) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (started.untilNow(io).raw.toMilliseconds() < milliseconds) {
        var fds = [_]std.c.pollfd{.{ .fd = file.handle, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 100) <= 0) continue;
        const n = std.c.read(file.handle, &chunk, chunk.len);
        if (n <= 0) return out.items;
        try out.appendSlice(a, chunk[0..@intCast(n)]);
    }
    return error.Timeout;
}

fn expectExit(child: *std.process.Child, code: u8) !void {
    const term = try child.wait(io);
    try t.expect(term == .exited);
    try t.expectEqual(code, term.exited);
}

test "BR-004 zcr broker serve and mcp --broker take the token from an inherited fd and serve reads only" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const token = try randomToken();

    const broker_fd = try tokenPipe(&token);
    var broker = try std.process.spawn(io, .{
        .argv = &.{ cli.zcr_exe, "broker", "serve", "--socket", f.socket_path, "--policy", f.policy_path, "--token-fd", try std.fmt.allocPrint(a, "{d}", .{broker_fd}) },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    _ = std.c.close(broker_fd);
    defer broker.kill(io);
    var line_buffer: [512]u8 = undefined;
    const ready = try readLine(broker.stderr.?, &line_buffer);
    const marker = "zcr broker: listening domain=";
    try t.expect(std.mem.startsWith(u8, ready, marker));
    const domain = ready[marker.len..];
    _ = try std.fmt.parseInt(u64, domain, 10);
    try t.expect(std.mem.indexOf(u8, ready, &token) == null);

    // A bridge with the wrong token is refused and never serves tools.
    const wrong = try randomToken();
    const wrong_fd = try tokenPipe(&wrong);
    var refused = try std.process.spawn(io, .{
        .argv = &.{ cli.zcr_exe, "mcp", "--broker", "--socket", f.socket_path, "--domain", domain, "--token-fd", try std.fmt.allocPrint(a, "{d}", .{wrong_fd}) },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    _ = std.c.close(wrong_fd);
    try t.expectEqualStrings("", try readAll(a, refused.stdout.?));
    try t.expect(std.mem.indexOf(u8, try readAll(a, refused.stderr.?), "refused") != null);
    try expectExit(&refused, 69);

    const bridge_fd = try tokenPipe(&token);
    var bridge = try std.process.spawn(io, .{
        .argv = &.{ cli.zcr_exe, "mcp", "--broker", "--socket", f.socket_path, "--domain", domain, "--token-fd", try std.fmt.allocPrint(a, "{d}", .{bridge_fd}) },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    _ = std.c.close(bridge_fd);
    defer bridge.kill(io);
    try bridge.stdin.?.writeStreamingAll(io, initialize ++ initialized ++ read_request ++ patch_request);
    bridge.stdin.?.close(io);
    bridge.stdin = null;
    const responses = try readAll(a, bridge.stdout.?);
    try t.expect(std.mem.indexOf(u8, responses, "2025-11-25") != null);
    try t.expect(std.mem.indexOf(u8, responses, "broker cli alpha") != null);
    try t.expect(std.mem.indexOf(u8, responses, "E_UNSUPPORTED") != null);
    try expectExit(&bridge, 0);

    // The disconnect ended the only grant's host binding. The broker stops instead of listening
    // for bridges it could only refuse, and removes its socket.
    try t.expect(std.mem.indexOf(u8, try readAllWithin(a, broker.stderr.?, 10_000), "grant ended") != null);
    try expectExit(&broker, 0);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "s", .{}));

    // A second bridge finds no broker, is refused clearly, and starts nothing.
    const again_fd = try tokenPipe(&token);
    var again = try std.process.spawn(io, .{
        .argv = &.{ cli.zcr_exe, "mcp", "--broker", "--socket", f.socket_path, "--domain", domain, "--token-fd", try std.fmt.allocPrint(a, "{d}", .{again_fd}) },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    _ = std.c.close(again_fd);
    try t.expectEqualStrings("", try readAll(a, again.stdout.?));
    try t.expect(std.mem.indexOf(u8, try readAll(a, again.stderr.?), "standalone") != null);
    try expectExit(&again, 69);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "s", .{}));
}

test "BR-004 zcr broker serve stops when the operator closes its stdin before any bridge" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const token = try randomToken();
    const fd = try tokenPipe(&token);
    var broker = try std.process.spawn(io, .{
        .argv = &.{ cli.zcr_exe, "broker", "serve", "--socket", f.socket_path, "--policy", f.policy_path, "--token-fd", try std.fmt.allocPrint(a, "{d}", .{fd}) },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    _ = std.c.close(fd);
    defer broker.kill(io);
    var line_buffer: [512]u8 = undefined;
    try t.expect(std.mem.startsWith(u8, try readLine(broker.stderr.?, &line_buffer), "zcr broker: listening domain="));
    broker.stdin.?.close(io);
    broker.stdin = null;
    _ = try readAllWithin(a, broker.stderr.?, 10_000);
    try expectExit(&broker, 0);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "s", .{}));
}

test "BR-004 zcr mcp --broker without a running broker refuses clearly and starts nothing" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const token = try randomToken();
    const fd = try tokenPipe(&token);
    var bridge = try std.process.spawn(io, .{
        .argv = &.{ cli.zcr_exe, "mcp", "--broker", "--socket", f.socket_path, "--domain", "7", "--token-fd", try std.fmt.allocPrint(a, "{d}", .{fd}) },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    _ = std.c.close(fd);
    try t.expectEqualStrings("", try readAll(a, bridge.stdout.?));
    try t.expect(std.mem.indexOf(u8, try readAll(a, bridge.stderr.?), "standalone") != null);
    try expectExit(&bridge, 69);
    // No broker was started on the caller's behalf: the socket path does not exist.
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "s", .{}));
}

test "BR-004 zcr broker serve refuses a token on argv and a policy without broker_allowed" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const token = try randomToken();
    const on_argv = try std.process.run(a, io, .{ .argv = &.{ cli.zcr_exe, "broker", "serve", "--socket", f.socket_path, "--policy", f.policy_path, "--token", &token }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) });
    try t.expect(on_argv.term == .exited and on_argv.term.exited == 64);
    try t.expect(std.mem.indexOf(u8, on_argv.stderr, &token) == null);

    const policy = try f.tmp.dir.readFileAlloc(io, "policy.json", a, .limited(65536));
    const denied = try std.mem.replaceOwned(u8, a, policy, "\"broker_allowed\":true", "\"broker_allowed\":false");
    try t.expect(!std.mem.eql(u8, denied, policy));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "policy.json", .data = denied });
    const fd = try tokenPipe(&token);
    var broker = try std.process.spawn(io, .{
        .argv = &.{ cli.zcr_exe, "broker", "serve", "--socket", f.socket_path, "--policy", f.policy_path, "--token-fd", try std.fmt.allocPrint(a, "{d}", .{fd}) },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    _ = std.c.close(fd);
    try t.expect(std.mem.indexOf(u8, try readAll(a, broker.stderr.?), "refused") != null);
    try expectExit(&broker, 69);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "s", .{}));
}
