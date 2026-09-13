const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const memory = @import("zcr_memory");
const cache = @import("zcr_cache");
const workspace_mod = @import("zcr_workspace");
const mcp = @import("zcr_mcp");
const fs_read = @import("zcr_fs_read");
const options = @import("build_options");
const testing = std.testing;
const io = testing.io;
const Posix = struct {
    extern "c" fn pipe(*[2]std.c.fd_t) c_int;
};
const workspace: core.WorkspaceId = .{ .registry_uuid = @splat(1), .incarnation = @splat(2) };
const task: core.TaskId = .{ .uuid = @splat(3) };
const session: core.SessionContext = .{ .session_id = .{ .uuid = @splat(4) }, .security_domain = .{ .id = 1 }, .policy_digest = @splat(5), .bound_workspace = workspace, .bound_task = task, .capability_handle = .none };
const initialize = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"fixture\",\"version\":\"1\"}}}";
const initialized = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";

test "BR-001 host batch ceiling uses one funded worker and reports broker backend" {
    const h = try Harness.init();
    defer h.deinit();
    try h.start();
    var held = try h.budget.reserve(session, .{ .cpu_permits = 3 });
    defer h.budget.release(&held) catch unreachable;
    const request = "{\"items\":[{\"item_id\":\"a\",\"path\":\"hello.txt\"},{\"item_id\":\"b\",\"path\":\"hello.txt\"}]}";
    try expectToolError(h, "zcr_batch_read", request, "E_RESOURCE");
    h.server.config.max_batch_concurrency = 1;
    h.server.config.backend = .broker;
    const batch_body = try logical(h, try h.tool("zcr_batch_read", request));
    try testing.expect(batch_body.object.get("ok").?.bool);
    const health = try logical(h, try h.tool("zcr_health", "{}"));
    try testing.expectEqualStrings("broker", health.object.get("data").?.object.get("backend").?.string);
    var invalid = h.server.config;
    invalid.max_batch_concurrency = 0;
    try testing.expectError(error.InvalidArgument, mcp.Server.init(invalid));
    invalid.max_batch_concurrency = 3;
    try testing.expectError(error.InvalidArgument, mcp.Server.init(invalid));
}

test "IO-004 native MCP preserves deadline-only failure in its envelope" {
    const h = try Harness.init();
    defer h.deinit();
    try h.start();
    const flag_only: core.Cancel = .{ .requested = &h.flag };
    const raw = (try h.server.respond(h.arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_health\",\"arguments\":{}}}", flag_only.withTimeout(io, 0))).?;
    const reply = (try std.json.parseFromSlice(std.json.Value, h.arena.allocator(), raw, .{})).value;
    const body = try logical(h, reply);
    try testing.expectEqualStrings("E_DEADLINE", body.object.get("error").?.object.get("code").?.string);
    try testing.expect(!h.flag.load(.acquire));
}

test "MC-005 authority is revalidated after execution before response publication" {
    const Check = struct {
        calls: u8 = 0,
        fn validate(context: ?*anyopaque) core.AuthorizeError!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (self.calls == 2) return error.OutOfScope;
        }
    };
    const h = try Harness.init();
    defer h.deinit();
    try h.start();
    var check: Check = .{};
    h.server.config.authority_context = &check;
    h.server.config.validate_authority = Check.validate;
    try expectToolError(h, "zcr_health", "{}", "E_SCOPE");
    try testing.expectEqual(@as(u8, 2), check.calls);
}
const Harness = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: core.TrustedRoot,
    authorizer: policy.Authorizer,
    counters: memory.accounting.Counters = .{},
    budget: memory.Budget = undefined,
    server: mcp.Server = undefined,
    flag: std.atomic.Value(bool) = .init(false),
    fn init() !*Harness {
        const h = try testing.allocator.create(Harness);
        errdefer testing.allocator.destroy(h);
        h.* = .{ .arena = .init(testing.allocator), .tmp = testing.tmpDir(.{}), .root = undefined, .authorizer = undefined };
        const a = h.arena.allocator();
        const path = try h.tmp.dir.realPathFileAlloc(io, ".", a);
        h.root = .{ .dir = try std.Io.Dir.openDirAbsolute(io, path, .{}), .canonical_path = path };
        h.authorizer = try policy.Authorizer.init(a, io, h.root, workspace, task, .{ .digest = session.policy_digest, .state = .active, .read_paths = &.{.{ .bytes = "." }}, .write_paths = &.{}, .immutable_paths = &.{}, .operations = &.{ .read, .enumerate, .search, .batch_read, .status, .health, .patch, .create }, .max_changed_files = 0 }, .{ .git_dir = null, .common_dir = null });
        h.budget = memory.Budget.init(8, .{ .bytes = 32 * 1024 * 1024, .fds = 128, .cpu = 4, .output_bytes = 4 * 1024 * 1024 }, &h.counters);
        h.server = try mcp.Server.init(.{ .allocator = testing.allocator, .io = io, .authorizer = &h.authorizer, .session = session, .budget = &h.budget, .generation = 7, .tools_json = options.tools_json });
        try h.tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "alpha\r\nbeta \\\"\n" });
        return h;
    }
    fn deinit(h: *Harness) void {
        std.debug.assert(h.budget.usage().bytes == 0);
        h.root.dir.close(io);
        h.tmp.cleanup();
        h.arena.deinit();
        testing.allocator.destroy(h);
    }
    fn reply(h: *Harness, raw: []const u8) !std.json.Value {
        const a = h.arena.allocator();
        const response = (try h.server.respond(a, raw, .{ .requested = &h.flag })) orelse return .null;
        return (try std.json.parseFromSlice(std.json.Value, a, response, .{})).value;
    }
    fn start(h: *Harness) !void {
        _ = try h.reply(initialize);
        try testing.expect((try h.reply(initialized)) == .null);
    }
    fn tool(h: *Harness, name: []const u8, args: []const u8) !std.json.Value {
        const raw = try std.fmt.allocPrint(h.arena.allocator(), "{{\"jsonrpc\":\"2.0\",\"id\":\"rpc-text-id\",\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ name, args });
        return try h.reply(raw);
    }
};
fn logical(h: *Harness, reply: std.json.Value) !std.json.Value {
    const result = reply.object.get("result") orelse return error.MissingResult;
    try testing.expect(!result.object.contains("structuredContent"));
    try testing.expectEqual(@as(usize, 1), result.object.get("content").?.array.items.len);
    return (try std.json.parseFromSlice(std.json.Value, h.arena.allocator(), result.object.get("content").?.array.items[0].object.get("text").?.string, .{})).value;
}
fn expectToolError(h: *Harness, name: []const u8, args: []const u8, code: []const u8) !void {
    const reply = try h.tool(name, args);
    try testing.expect(reply.object.get("result").?.object.get("isError").?.bool);
    const body = try logical(h, reply);
    try testing.expectEqualStrings(code, body.object.get("error").?.object.get("code").?.string);
}
test "MC-001 supported version negotiates exact capabilities and schema discovery" {
    const h = try Harness.init();
    defer h.deinit();
    try testing.expect(mcp.supportedVersion("2025-11-25"));
    try testing.expect(!mcp.supportedVersion("2024-11-05"));
    const unsupported = try h.reply("{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"old\"}}");
    try testing.expectEqual(@as(i64, -32602), unsupported.object.get("error").?.object.get("code").?.integer);
    try h.start();
    const reply = try h.reply("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    const tools = reply.object.get("result").?.object.get("tools").?.array.items;
    try testing.expectEqual(@as(usize, 6), tools.len);
    var catalog = try std.json.parseFromSlice(std.json.Value, h.arena.allocator(), options.tools_json, .{});
    defer catalog.deinit();
    for (tools) |tool| {
        try testing.expect(!tool.object.contains("outputSchema"));
        const name = tool.object.get("name").?.string;
        try testing.expect(!std.mem.eql(u8, name, "zcr_patch") and !std.mem.eql(u8, name, "zcr_create"));
        for (catalog.value.object.get("tools").?.array.items) |expected| if (std.mem.eql(u8, expected.object.get("name").?.string, name)) {
            try testing.expectEqualStrings(try std.json.Stringify.valueAlloc(h.arena.allocator(), expected, .{}), try std.json.Stringify.valueAlloc(h.arena.allocator(), tool, .{}));
        };
    }
}
test "MC-002 exact text_v1 real read files search batch status health and ids" {
    const h = try Harness.init();
    defer h.deinit();
    try h.start();
    const reply = try h.tool("zcr_read", "{\"path\":\"hello.txt\",\"write_intent\":true}");
    try testing.expectEqualStrings("rpc-text-id", reply.object.get("id").?.string);
    const body = try logical(h, reply);
    try testing.expect(body.object.get("ok").?.bool);
    const data = body.object.get("data").?;
    try testing.expectEqualStrings("alpha\r\n", data.object.get("lines").?.array.items[0].object.get("text").?.string);
    try testing.expectEqual(@as(usize, 64), data.object.get("version").?.object.get("sha256").?.string.len);
    const encoded_data = try std.json.Stringify.valueAlloc(h.arena.allocator(), data, .{});
    try testing.expectEqual(@as(i64, @intCast(encoded_data.len)), body.object.get("meta").?.object.get("returned_bytes").?.integer);
    const files = try logical(h, try h.tool("zcr_files", "{}"));
    try testing.expect(files.object.get("ok").?.bool);
    try testing.expectEqual(@as(usize, 1), files.object.get("data").?.object.get("paths").?.array.items.len);
    const hits = try logical(h, try h.tool("zcr_search", "{\"literal\":\"alpha\"}"));
    try testing.expect(hits.object.get("ok").?.bool);
    try testing.expectEqual(@as(usize, 1), hits.object.get("data").?.object.get("files").?.array.items.len);
    const items = try logical(h, try h.tool("zcr_batch_read", "{\"items\":[{\"item_id\":\"a\",\"path\":\"hello.txt\"},{\"item_id\":\"b\",\"path\":\"missing\"}]}"));
    try testing.expect(items.object.get("ok").?.bool);
    try testing.expectEqual(@as(usize, 2), items.object.get("data").?.object.get("items").?.array.items.len);
    try testing.expect(!(items.object.get("data").?.object.get("items").?.array.items[1].object.get("ok").?.bool));
    for ([_][]const u8{ "zcr_status", "zcr_health" }) |name| {
        const value = try logical(h, try h.tool(name, "{}"));
        try testing.expect(value.object.get("ok").?.bool);
    }
}
test "MC-003 malformed JSON fields numeric bounds unsupported capabilities are classified" {
    const h = try Harness.init();
    defer h.deinit();
    try h.start();
    const malformed = [_][]const u8{ "{", "{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}", "NaN" };
    for (malformed) |raw| {
        const reply = try h.reply(raw);
        try testing.expectEqual(@as(i64, -32700), reply.object.get("error").?.object.get("code").?.integer);
    }
    const batch_request = try h.reply("[]");
    try testing.expectEqual(@as(i64, -32600), batch_request.object.get("error").?.object.get("code").?.integer);
    const invalid_args = [_][]const u8{ "{\"path\":\"hello.txt\",\"root\":\"/\"}", "{\"path\":\"hello.txt\",\"start_line\":4294967296}", "{\"path\":\"hello.txt\",\"start_line\":4294967295,\"line_count\":2}", "{\"path\":\"hello.txt\",\"output_bytes\":1023}", "{\"path\":\"hello.txt\",\"deadline_ms\":60001}", "{\"path\":\"hello.txt\",\"line_count\":1.5}", "{\"path\":\"hello.txt\",\"line_count\":18446744073709551616}" };
    for (invalid_args) |args| try expectToolError(h, "zcr_read", args, "E_INVALID_ARGUMENT");
    try expectToolError(h, "zcr_read", "{\"path\":\"missing\"}", "E_NOT_FOUND");
    try expectToolError(h, "zcr_patch", "{}", "E_UNSUPPORTED");
    try expectToolError(h, "zcr_create", "{}", "E_UNSUPPORTED");
    try expectToolError(h, "zcr_read", "{\"path\":\"hello.txt\",\"consistency\":\"managed_generation\"}", "E_UNSUPPORTED");
    const unknown = try h.reply("{\"jsonrpc\":\"2.0\",\"id\":-9223372036854775808,\"method\":\"missing\"}");
    try testing.expectEqual(std.math.minInt(i64), unknown.object.get("id").?.integer);
    try testing.expectEqual(@as(i64, -32601), unknown.object.get("error").?.object.get("code").?.integer);
}
test "MC-002 partial frames preserve escaped newline and drain oversized records" {
    const buffer = try testing.allocator.alloc(u8, mcp.framing.max_frame_bytes);
    defer testing.allocator.free(buffer);
    var decoder = mcp.framing.Decoder.init(buffer);
    const input = "{\"text\":\"a\\nb\"}\n{}\n";
    var count: usize = 0;
    for (input) |byte| switch (decoder.push(byte)) {
        .frame => |raw| {
            try mcp.codec.preflight(raw);
            count += 1;
        },
        .none => {},
        else => return error.UnexpectedFrame,
    };
    try testing.expectEqual(@as(usize, 2), count);
    try decoder.finish();
    for (0..mcp.framing.max_frame_bytes + 1) |_| _ = decoder.push(' ');
    try testing.expect(decoder.push('\n') == .oversized);
    _ = decoder.push('{');
    _ = decoder.push('}');
    try testing.expectEqualStrings("{}", decoder.push('\n').frame);
    _ = decoder.push('{');
    try testing.expectError(error.TruncatedFrame, decoder.finish());
}
test "MC-004 request cancellation remains local and authority revalidation rejects stale root" {
    const h = try Harness.init();
    defer h.deinit();
    try h.start();
    h.flag.store(true, .release);
    try expectToolError(h, "zcr_read", "{\"path\":\"hello.txt\"}", "E_CANCELLED");
    h.flag.store(false, .release);
    const result = try logical(h, try h.tool("zcr_read", "{\"path\":\"hello.txt\"}"));
    try testing.expect(result.object.get("ok").?.bool);
    const Validate = struct {
        fn call(_: ?*anyopaque) core.AuthorizeError!void {
            return error.OutOfScope;
        }
    };
    h.server.config.validate_authority = Validate.call;
    try expectToolError(h, "zcr_read", "{\"path\":\"hello.txt\"}", "E_SCOPE");
}
test "MC-002 direct stdio worker emits complete records within 32 MiB native budget" {
    const h = try Harness.init();
    defer h.deinit();
    const input = initialize ++ "\n" ++ initialized ++ "\n" ++ "{\"jsonrpc\":\"2.0\",\"id\":\"one\",\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{\"path\":\"hello.txt\"}}}\n";
    try h.tmp.dir.writeFile(io, .{ .sub_path = "input", .data = input });
    const file = try h.tmp.dir.openFile(io, "input", .{});
    defer file.close(io);
    const output = try h.tmp.dir.createFile(io, "output", .{ .read = true });
    defer output.close(io);
    try h.server.serve(file, output);
    var bytes: [8192]u8 = undefined;
    const count = try output.readPositionalAll(io, &bytes, 0);
    var records = std.mem.splitScalar(u8, bytes[0..count], '\n');
    var n: usize = 0;
    while (records.next()) |raw| {
        if (raw.len == 0) continue;
        try mcp.codec.preflight(raw);
        const parsed = try std.json.parseFromSlice(std.json.Value, h.arena.allocator(), raw, .{});
        if (parsed.value.object.get("id").? == .string) {
            const value = try logical(h, parsed.value);
            try testing.expect(value.object.get("ok").?.bool);
        }
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(h.budget.peakBytes() <= 32 * 1024 * 1024);
}

test "MC-004 real partial pipe input cancellation and slow output drain without interleaving" {
    const h = try Harness.init();
    defer h.deinit();
    // Separate input/output pipes exercise an actual blocked kernel write.
    var in_fds: [2]std.c.fd_t = undefined;
    var out_fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), Posix.pipe(&in_fds));
    try testing.expectEqual(@as(c_int, 0), Posix.pipe(&out_fds));
    const input: std.Io.File = .{ .handle = in_fds[0], .flags = .{ .nonblocking = false } };
    const feed: std.Io.File = .{ .handle = in_fds[1], .flags = .{ .nonblocking = false } };
    const drain: std.Io.File = .{ .handle = out_fds[0], .flags = .{ .nonblocking = false } };
    const output: std.Io.File = .{ .handle = out_fds[1], .flags = .{ .nonblocking = false } };
    defer input.close(io);
    defer drain.close(io);
    const text = try h.arena.allocator().alloc(u8, 128 * 1024);
    @memset(text, 'x');
    text[text.len - 1] = '\n';
    try h.tmp.dir.writeFile(io, .{ .sub_path = "large", .data = text });
    const Runner = struct {
        h: *Harness,
        input: std.Io.File,
        output: std.Io.File,
        failed: std.atomic.Value(bool) = .init(false),
        fn run(r: *@This()) void {
            r.h.server.serve(r.input, r.output) catch {
                r.failed.store(true, .release);
            };
            r.output.close(io);
        }
    };
    var runner: Runner = .{ .h = h, .input = input, .output = output };
    const SlowValidate = struct {
        fn call(_: ?*anyopaque) core.AuthorizeError!void {
            std.Io.sleep(io, .fromMilliseconds(5), .awake) catch return error.IoFailure;
        }
    };
    h.server.config.validate_authority = SlowValidate.call;
    // Capacity allows multiple requests while the writer is stalled, independently
    // of the 32 MiB single-request test above.
    h.budget.caps.bytes = 96 * 1024 * 1024;
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    try feed.writeStreamingAll(io, initialize[0..47]);
    try feed.writeStreamingAll(io, initialize[47..] ++ "\n" ++ initialized ++ "\n");
    try feed.writeStreamingAll(io, "{\"jsonrpc\":\"2.0\",\"id\":\"large\",\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{\"path\":\"large\",\"line_count\":1}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":\"cancel-me\",\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_search\",\"arguments\":{\"literal\":\"not-present\",\"glob\":\"large\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"cancel-me\"}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":\"healthy\",\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_health\",\"arguments\":{}}}\n");
    feed.close(io);
    try std.Io.sleep(io, .fromMilliseconds(30), .awake);
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(testing.allocator);
    var block: [4096]u8 = undefined;
    while (true) {
        const n = drain.readStreaming(io, &.{&block}) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;
        try all.appendSlice(testing.allocator, block[0..n]);
    }
    thread.join();
    try testing.expect(!runner.failed.load(.acquire));
    var records = std.mem.splitScalar(u8, all.items, '\n');
    var n: usize = 0;
    var cancelled = false;
    var healthy = false;
    while (records.next()) |raw| {
        if (raw.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, h.arena.allocator(), raw, .{});
        n += 1;
        const id = parsed.value.object.get("id").?;
        if (id != .string) continue;
        const body = try logical(h, parsed.value);
        if (std.mem.eql(u8, id.string, "cancel-me")) {
            try testing.expectEqualStrings("E_CANCELLED", body.object.get("error").?.object.get("code").?.string);
            cancelled = true;
        }
        if (std.mem.eql(u8, id.string, "healthy")) {
            try testing.expect(body.object.get("ok").?.bool);
            healthy = true;
        }
    }
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expect(cancelled and healthy);
}

test "MC-004 deadline watcher interrupts before filesystem work and output failure drains" {
    const h = try Harness.init();
    defer h.deinit();
    const SlowValidate = struct {
        fn call(_: ?*anyopaque) core.AuthorizeError!void {
            std.Io.sleep(io, .fromMilliseconds(15), .awake) catch return error.IoFailure;
        }
    };
    h.server.config.validate_authority = SlowValidate.call;
    try h.tmp.dir.writeFile(io, .{ .sub_path = "input", .data = initialize ++ "\n" ++ initialized ++ "\n" ++ "{\"jsonrpc\":\"2.0\",\"id\":\"deadline\",\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{\"path\":\"missing\",\"deadline_ms\":1}}}\n" });
    const input = try h.tmp.dir.openFile(io, "input", .{});
    defer input.close(io);
    const output = try h.tmp.dir.createFile(io, "output", .{ .read = true });
    defer output.close(io);
    try h.server.serve(input, output);
    var bytes: [8192]u8 = undefined;
    const n = try output.readPositionalAll(io, &bytes, 0);
    try testing.expect(std.mem.indexOf(u8, bytes[0..n], "E_DEADLINE") != null);
    try testing.expect(std.mem.indexOf(u8, bytes[0..n], "E_NOT_FOUND") == null);
    const bad_input = try h.tmp.dir.openFile(io, "input", .{});
    defer bad_input.close(io);
    const readonly_output = try h.tmp.dir.openFile(io, "hello.txt", .{});
    defer readonly_output.close(io);
    try testing.expectError(error.IoFailure, h.server.serve(bad_input, readonly_output));
}

test "MC-003 policy enabled discovery filters and complete serialized output budget" {
    const h = try Harness.init();
    defer h.deinit();
    try h.start();
    h.authorizer.policy.operations = &.{.read};
    const list = try h.reply("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/list\"}");
    try testing.expectEqual(@as(usize, 1), list.object.get("result").?.object.get("tools").?.array.items.len);
    try expectToolError(h, "zcr_health", "{}", "E_UNSUPPORTED");
    const text = try h.arena.allocator().alloc(u8, 900);
    @memset(text, '\\');
    try h.tmp.dir.writeFile(io, .{ .sub_path = "escaped", .data = text });
    try expectToolError(h, "zcr_read", "{\"path\":\"escaped\",\"output_bytes\":1024}", "E_OUTPUT_BUDGET");
    h.server.config.output_bytes = 1024;
    try expectToolError(h, "zcr_read", "{\"path\":\"escaped\"}", "E_OUTPUT_BUDGET");
    var frame_context: mcp.Server.FrameContext = .{ .allocator = h.arena.allocator(), .cancel = .{ .requested = &h.flag } };
    var connection: core.Connection = .{ .context = &frame_context };
    try testing.expectError(error.InvalidArgument, h.server.serveFrame(io, &connection, .{ .bytes = "{}", .limit = 1 }));
}

test "MC-003 depth64 keys and flat-value parser caps are enforced before DOM allocation" {
    var nested: [131]u8 = undefined;
    @memset(nested[0..64], '[');
    nested[64] = '0';
    @memset(nested[65..129], ']');
    try mcp.codec.preflight(nested[0..129]);
    @memset(nested[0..65], '[');
    nested[65] = '0';
    @memset(nested[66..131], ']');
    try testing.expectError(error.DepthExceeded, mcp.codec.preflight(&nested));
    try testing.expectError(error.DuplicateKey, mcp.codec.preflight("{\"é\":0,\"\\u00e9\":1}"));
    try testing.expectError(error.InvalidJson, mcp.codec.preflight("{\"x\":\"\\ud800\"}"));
    const too_large = try testing.allocator.alloc(u8, mcp.codec.max_frame_bytes + 1);
    defer testing.allocator.free(too_large);
    @memset(too_large, ' ');
    try testing.expectError(error.FrameTooLarge, mcp.codec.preflight(too_large));
    var values: std.ArrayList(u8) = .empty;
    defer values.deinit(testing.allocator);
    try values.append(testing.allocator, '[');
    for (0..mcp.codec.max_values) |i| {
        if (i > 0) try values.append(testing.allocator, ',');
        try values.append(testing.allocator, '0');
    }
    try values.append(testing.allocator, ']');
    try testing.expectError(error.ResourceExhausted, mcp.codec.preflight(values.items));
}

test "MC-002 enumerate and search are admitted on native32MiB profile" {
    for ([_][]const u8{ "zcr_files", "zcr_search" }) |name| {
        const h = try Harness.init();
        defer h.deinit();
        try h.start();
        const arguments = if (std.mem.eql(u8, name, "zcr_files")) "{\"glob\":\"*.txt\"}" else "{\"literal\":\"alpha\",\"glob\":\"*.txt\"}";
        const request = try std.fmt.allocPrint(h.arena.allocator(), "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}\n", .{ name, arguments });
        try h.tmp.dir.writeFile(io, .{ .sub_path = "input", .data = request });
        const input = try h.tmp.dir.openFile(io, "input", .{});
        defer input.close(io);
        const output = try h.tmp.dir.createFile(io, "output", .{ .read = true });
        defer output.close(io);
        try h.server.serve(input, output);
        var bytes: [8192]u8 = undefined;
        const n = try output.readPositionalAll(io, &bytes, 0);
        const parsed = try std.json.parseFromSlice(std.json.Value, h.arena.allocator(), bytes[0..n], .{});
        const body = try logical(h, parsed.value);
        if (!body.object.get("ok").?.bool) std.debug.print("native32 {s}: {s} peak={d}\n", .{ name, bytes[0..n], h.budget.peakBytes() });
        try testing.expect(body.object.get("ok").?.bool);
        try testing.expect(h.budget.peakBytes() <= 32 * 1024 * 1024);
    }
}

test "MC-003 oversized unknown fields reject before DOM allocation and preserve RPC id" {
    const h = try Harness.init();
    defer h.deinit();
    try h.start();
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(testing.allocator);
    try raw.appendSlice(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"early\\u002did\",\"method\":\"tools/call\",\"params\":{\"arguments\":{\"path\":\"hello.txt\",\"unknown\":\"");
    try raw.appendNTimes(testing.allocator, 'x', 2 * 1024 * 1024);
    try raw.appendSlice(testing.allocator, "\"},\"name\":\"zcr_read\"}}");
    var bounded: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&bounded);
    const response = (try h.server.respond(fba.allocator(), raw.items, .{ .requested = &h.flag })).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, h.arena.allocator(), response, .{});
    try testing.expectEqualStrings("early-id", parsed.value.object.get("id").?.string);
    const body = try logical(h, parsed.value);
    try testing.expectEqualStrings("E_INVALID_ARGUMENT", body.object.get("error").?.object.get("code").?.string);
}

test "MC-004 stdout failure stops even when peer keeps stdin open" {
    const h = try Harness.init();
    defer h.deinit();
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), Posix.pipe(&fds));
    const input: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const feed: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer input.close(io);
    const output = try h.tmp.dir.openFile(io, "hello.txt", .{});
    defer output.close(io);
    const Runner = struct {
        h: *Harness,
        input: std.Io.File,
        output: std.Io.File,
        done: std.atomic.Value(bool) = .init(false),
        failed: std.atomic.Value(bool) = .init(false),
        fn run(r: *@This()) void {
            r.h.server.serve(r.input, r.output) catch {
                r.failed.store(true, .release);
            };
            r.done.store(true, .release);
        }
    };
    var runner: Runner = .{ .h = h, .input = input, .output = output };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    try feed.writeStreamingAll(io, initialize ++ "\n");
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (!runner.done.load(.acquire) and started.untilNow(io).raw.toMilliseconds() < 250) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    const stopped_before_eof = runner.done.load(.acquire);
    feed.close(io);
    thread.join();
    try testing.expect(stopped_before_eof);
    try testing.expect(runner.failed.load(.acquire));
}

test "MC-004 retiring tool id is detached before gated arena teardown" {
    const h = try Harness.init();
    defer h.deinit();
    // A successful tools/call validates authority twice (before and after
    // execution). Only validations made while the first slot's teardown is
    // held by the hook count, so the check does not depend on scheduling.
    const Gate = struct {
        entered: std.atomic.Value(bool) = .init(false),
        allow: std.atomic.Value(bool) = .init(false),
        validated_while_gated: std.atomic.Value(u32) = .init(0),
        fn validate(ctx: ?*anyopaque) core.AuthorizeError!void {
            const g: *@This() = @ptrCast(@alignCast(ctx.?));
            if (g.entered.load(.acquire) and !g.allow.load(.acquire)) _ = g.validated_while_gated.fetchAdd(1, .acq_rel);
        }
        fn retire(ctx: ?*anyopaque) void {
            const g: *@This() = @ptrCast(@alignCast(ctx.?));
            if (g.entered.swap(true, .acq_rel)) return;
            while (!g.allow.load(.acquire)) std.Io.sleep(io, .fromMilliseconds(1), .awake) catch return;
        }
    };
    var gate: Gate = .{};
    h.server.config.validate_authority = Gate.validate;
    h.server.config.authority_context = &gate;
    h.server.config.before_tool_release = Gate.retire;
    h.server.config.retirement_context = &gate;
    var input_fds: [2]std.c.fd_t = undefined;
    var output_fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), Posix.pipe(&input_fds));
    try testing.expectEqual(@as(c_int, 0), Posix.pipe(&output_fds));
    const input: std.Io.File = .{ .handle = input_fds[0], .flags = .{ .nonblocking = false } };
    const feed: std.Io.File = .{ .handle = input_fds[1], .flags = .{ .nonblocking = false } };
    const drain: std.Io.File = .{ .handle = output_fds[0], .flags = .{ .nonblocking = false } };
    const output: std.Io.File = .{ .handle = output_fds[1], .flags = .{ .nonblocking = false } };
    defer input.close(io);
    defer drain.close(io);
    const Runner = struct {
        h: *Harness,
        input: std.Io.File,
        output: std.Io.File,
        failed: std.atomic.Value(bool) = .init(false),
        fn run(r: *@This()) void {
            r.h.server.serve(r.input, r.output) catch {
                r.failed.store(true, .release);
            };
            r.output.close(io);
        }
    };
    var runner: Runner = .{ .h = h, .input = input, .output = output };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    const call = "{\"jsonrpc\":\"2.0\",\"id\":\"reused-string-id\",\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{\"path\":\"hello.txt\"}}}\n";
    try feed.writeStreamingAll(io, initialize ++ "\n" ++ initialized ++ "\n" ++ call);
    // Both waits end on an event; the bound only turns a hang into a failure.
    const hang_guard_ms = 10_000;
    var started = std.Io.Clock.Timestamp.now(io, .awake);
    while (!gate.entered.load(.acquire) and started.untilNow(io).raw.toMilliseconds() < hang_guard_ms) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    const entered = gate.entered.load(.acquire);
    if (entered) try feed.writeStreamingAll(io, call);
    started = std.Io.Clock.Timestamp.now(io, .awake);
    while (entered and gate.validated_while_gated.load(.acquire) < 2 and started.untilNow(io).raw.toMilliseconds() < hang_guard_ms) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    const validated_while_gated = gate.validated_while_gated.load(.acquire);
    gate.allow.store(true, .release);
    feed.close(io);
    thread.join();
    var buffer: [16384]u8 = undefined;
    var reader = drain.readerStreaming(io, &buffer);
    const records = try reader.interface.allocRemaining(testing.allocator, .limited(16384));
    defer testing.allocator.free(records);
    var accepted: usize = 0;
    var lines = std.mem.splitScalar(u8, records, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const record = (try std.json.parseFromSlice(std.json.Value, h.arena.allocator(), raw, .{})).value;
        try testing.expect(record.object.get("error") == null);
        const id = record.object.get("id").?;
        if (id != .string) continue;
        try testing.expectEqualStrings("reused-string-id", id.string);
        try testing.expect((try logical(h, record)).object.get("ok").?.bool);
        accepted += 1;
    }
    try testing.expect(entered);
    // The reused id was admitted and fully executed while the first slot was retiring.
    try testing.expectEqual(@as(u32, 2), validated_while_gated);
    try testing.expectEqual(@as(usize, 2), accepted);
    try testing.expect(!runner.failed.load(.acquire));
}

test "MC-004 pre-reserved health control credit survives ordinary budget exhaustion" {
    const h = try Harness.init();
    defer h.deinit();
    var input_fds: [2]std.c.fd_t = undefined;
    var output_fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), Posix.pipe(&input_fds));
    try testing.expectEqual(@as(c_int, 0), Posix.pipe(&output_fds));
    const input: std.Io.File = .{ .handle = input_fds[0], .flags = .{ .nonblocking = false } };
    const feed: std.Io.File = .{ .handle = input_fds[1], .flags = .{ .nonblocking = false } };
    const drain: std.Io.File = .{ .handle = output_fds[0], .flags = .{ .nonblocking = false } };
    const output: std.Io.File = .{ .handle = output_fds[1], .flags = .{ .nonblocking = false } };
    defer input.close(io);
    defer drain.close(io);
    const Runner = struct {
        h: *Harness,
        input: std.Io.File,
        output: std.Io.File,
        failed: std.atomic.Value(bool) = .init(false),
        fn run(r: *@This()) void {
            r.h.server.serve(r.input, r.output) catch {
                r.failed.store(true, .release);
            };
            r.output.close(io);
        }
    };
    var runner: Runner = .{ .h = h, .input = input, .output = output };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    var cleanup_done = false;
    defer if (!cleanup_done) {
        feed.close(io);
        thread.join();
    };
    try feed.writeStreamingAll(io, initialize ++ "\n" ++ initialized ++ "\n");
    var buf: [16384]u8 = undefined;
    var reader = drain.readerStreaming(io, &buf);
    _ = try reader.interface.takeDelimiterInclusive('\n');
    try feed.writeStreamingAll(io, "{\"jsonrpc\":\"2.0\",\"id\":\"discovery\",\"method\":\"tools/list\"}\n");
    const discovery = try reader.interface.takeDelimiterInclusive('\n');
    const listed = try std.json.parseFromSlice(std.json.Value, h.arena.allocator(), discovery, .{});
    try testing.expectEqual(@as(usize, 6), listed.value.object.get("result").?.object.get("tools").?.array.items.len);
    var pressure = try h.budget.reserve(session, .{ .scratch_bytes = h.budget.caps.bytes - h.budget.usage().bytes });
    defer if (!pressure.released) h.budget.release(&pressure) catch unreachable;
    try feed.writeStreamingAll(io, "{\"jsonrpc\":\"2.0\",\"id\":\"pressure-health\",\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_health\",\"arguments\":{}}}\n");
    const response = try reader.interface.takeDelimiterInclusive('\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, h.arena.allocator(), response, .{});
    const body = try logical(h, parsed.value);
    const health_ok = body.object.get("ok").?.bool;
    const live = body.object.get("data").?.object.get("tracked_live_bytes").?.integer;
    try h.budget.release(&pressure);
    try feed.writeStreamingAll(io, "{\"jsonrpc\":\"2.0\",\"id\":\"still-alive\",\"method\":\"ping\"}\n");
    _ = try reader.interface.takeDelimiterInclusive('\n');
    feed.close(io);
    thread.join();
    cleanup_done = true;
    try testing.expect(health_ok);
    try testing.expectEqual(@as(i64, @intCast(h.budget.caps.bytes)), live);
    try testing.expect(!runner.failed.load(.acquire));
}

// Real MCP calls share the same cache and CPU-one request budget; no test inserts content manually.
const CacheHarness = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    registry: workspace_mod.Registry,
    counters: memory.accounting.Counters = .{},
    budget: memory.Budget = undefined,
    store: ?*cache.Store = null,
    const Client = struct {
        root: core.TrustedRoot,
        auth: policy.Authorizer,
        facade: cache.Session,
        server: mcp.Server,
        flag: std.atomic.Value(bool) = .init(false),
    };
    fn init() !*CacheHarness {
        const f = try testing.allocator.create(CacheHarness);
        f.* = .{ .arena = .init(testing.allocator), .tmp = testing.tmpDir(.{}), .registry = try workspace_mod.Registry.init(testing.allocator, io, .{ .git_executable = "/usr/bin/git" }) };
        f.budget = memory.Budget.init(88, .{ .bytes = 32 * 1024 * 1024, .fds = 64, .cpu = 1, .output_bytes = 4 * 1024 * 1024 }, &f.counters);
        return f;
    }
    fn deinit(f: *CacheHarness) void {
        if (f.store) |store| store.deinit() catch unreachable;
        testing.expectEqual(@as(u64, 0), f.budget.usage().bytes) catch unreachable;
        testing.expectEqual(@as(u64, 0), f.counters.live_bytes.load(.monotonic)) catch unreachable;
        f.registry.deinit() catch unreachable;
        f.tmp.cleanup();
        f.arena.deinit();
        testing.allocator.destroy(f);
    }
    fn client(f: *CacheHarness, n: u8, domain: u64, bytes: []const u8) !*Client {
        const a = f.arena.allocator();
        const name = try std.fmt.allocPrint(a, "repo-{d}", .{n});
        try f.tmp.dir.createDir(io, name, .default_dir);
        const path = try f.tmp.dir.realPathFileAlloc(io, name, a);
        var env: std.process.Environ.Map = .init(a);
        try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        const init_git = try std.process.run(a, io, .{ .argv = &.{ "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "init.templateDir=", "-C", path, "init", "-q", "-b", "main" }, .environ_map = &env });
        if (init_git.term != .exited or init_git.term.exited != 0) return error.FixtureGit;
        const c = try a.create(Client);
        const root: core.TrustedRoot = .{ .dir = try f.tmp.dir.openDir(io, name, .{}), .canonical_path = path };
        defer root.dir.close(io);
        try root.dir.writeFile(io, .{ .sub_path = "file.txt", .data = bytes });
        const commit = try std.process.run(a, io, .{ .argv = &.{ "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "-c", "user.name=cache-test", "-c", "user.email=cache@example.invalid", "-C", path, "commit", "--allow-empty", "-q", "-m", "fixture" }, .environ_map = &env });
        if (commit.term != .exited or commit.term.exited != 0) return error.FixtureGit;
        const pol: core.Policy = .{ .digest = @splat(19), .state = .active, .read_paths = &.{.{ .bytes = "." }}, .write_paths = &.{}, .immutable_paths = &.{}, .operations = &.{ .read, .batch_read, .search, .health }, .max_changed_files = 0 };
        const id = try f.registry.registerWorkspace(io, root, pol);
        const snap = try f.registry.snapshot(id);
        const context: core.SessionContext = .{ .session_id = .{ .uuid = @splat(n) }, .security_domain = .{ .id = domain }, .policy_digest = pol.digest, .bound_workspace = id, .bound_task = .{ .uuid = @splat(n + 32) }, .capability_handle = @enumFromInt(@as(u64, n) + 1) };
        try f.registry.bindSession(context, .{ .task_id = context.bound_task, .base_commit = snap.head[0..snap.head_len], .scope_digest = pol.digest, .fence = 1, .expires_at_unix_ms = std.math.maxInt(i64) }, f.registry.bootNonce());
        c.* = .{ .root = snap.root, .auth = try policy.Authorizer.init(a, io, snap.root, id, context.bound_task, pol, snap.git), .facade = undefined, .server = undefined };
        if (f.store == null) f.store = try cache.Store.create(testing.allocator, io, &f.budget, context, .{ .verification_budget = &f.budget });
        c.facade = try cache.Session.init(f.store.?, &f.registry, &c.auth, context, .{ .requested = &c.flag });
        c.server = try mcp.Server.init(.{ .allocator = testing.allocator, .io = io, .authorizer = &c.auth, .session = context, .generation = snap.generation, .budget = &f.budget, .cache_session = &c.facade, .tools_json = options.tools_json });
        _ = try c.server.respond(a, initialize, .{ .requested = &c.flag });
        _ = try c.server.respond(a, initialized, .{ .requested = &c.flag });
        return c;
    }
    fn read(f: *CacheHarness, c: *Client, args: []const u8) !std.json.Value {
        return f.readWithCancel(c, args, .{ .requested = &c.flag });
    }
    fn readWithCancel(f: *CacheHarness, c: *Client, args: []const u8, cancel: core.Cancel) !std.json.Value {
        const a = f.arena.allocator();
        const raw = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"zcr_read\",\"arguments\":{s}}}}}", .{args});
        const response = (try c.server.respond(a, raw, cancel)).?;
        const rpc = (try std.json.parseFromSlice(std.json.Value, a, response, .{})).value;
        return (try std.json.parseFromSlice(std.json.Value, a, rpc.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string, .{})).value;
    }
};

test "BR-001 runtime cache pressure preserves a previously admissible real MCP read" {
    const f = try CacheHarness.init();
    defer f.deinit();
    const c = try f.client(1, 7, "tiny\n");
    const cold = try f.read(c, "{\"path\":\"file.txt\",\"output_bytes\":2097152}");
    try testing.expect(cold.object.get("ok").?.bool);
    // Mirror the long-lived stdio transport credit while real tool calls run.
    var transport_credit = try f.budget.reserve(c.facade.context, .{ .scratch_bytes = 22 * 1024 * 1024 });
    defer f.budget.release(&transport_credit) catch unreachable;

    const bytes = try f.arena.allocator().alloc(u8, 200_000);
    @memset(bytes, 'x');
    bytes[bytes.len - 1] = '\n';
    for (0..16) |i| {
        const name = try std.fmt.allocPrint(f.arena.allocator(), "warm-{d}.txt", .{i});
        bytes[0] = @intCast('A' + i);
        try c.root.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
        const args = try std.fmt.allocPrint(f.arena.allocator(), "{{\"path\":\"{s}\"}}", .{name});
        for (0..2) |_| {
            const warmed = try f.read(c, args);
            try testing.expect(warmed.object.get("ok").?.bool);
        }
    }
    try testing.expect(f.store.?.stats().content_bytes >= 16 * 200_000);
    var slot_credit = try f.budget.reserve(c.facade.context, .{ .scratch_bytes = 4 * 1024 * 1024 });
    defer f.budget.release(&slot_credit) catch unreachable;
    const recovered = try f.read(c, "{\"path\":\"file.txt\",\"output_bytes\":2097152}");
    try testing.expect(recovered.object.get("ok").?.bool);
}

test "BR-001 runtime cache pressure never evicts pinned entries or for CPU-only refusal" {
    const f = try CacheHarness.init();
    defer f.deinit();
    const c = try f.client(1, 7, "pinned\n");
    for (0..2) |_| _ = try f.read(c, "{\"path\":\"file.txt\"}");
    try testing.expectEqual(@as(usize, 1), f.store.?.stats().entries);

    var cpu = try f.budget.reserve(c.facade.context, .{ .cpu_permits = 1 });
    const cpu_refused = try f.read(c, "{\"path\":\"file.txt\"}");
    try testing.expectEqualStrings("E_RESOURCE", cpu_refused.object.get("error").?.object.get("code").?.string);
    try testing.expectEqual(@as(usize, 1), f.store.?.stats().entries);
    try f.budget.release(&cpu);

    const capability = try c.auth.authorize(io, c.facade.context, .read, .{ .bytes = "file.txt" });
    const pin = (try c.facade.cacheGetCurrent(capability, .{ .max_pinned_bytes = 1024 })).pin.?;
    try testing.expectEqual(@as(usize, 1), f.store.?.stats().pins);
    const available = f.budget.caps.bytes - f.budget.usage().bytes;
    var pressure = try f.budget.reserve(c.facade.context, .{ .scratch_bytes = available - 1024 });
    const pinned_refusal = try f.read(c, "{\"path\":\"file.txt\",\"output_bytes\":2097152}");
    try testing.expectEqualStrings("E_RESOURCE", pinned_refusal.object.get("error").?.object.get("code").?.string);
    try testing.expectEqual(@as(usize, 1), f.store.?.stats().entries);
    try testing.expectEqual(@as(usize, 1), f.store.?.stats().pins);
    try f.budget.release(&pressure);
    try c.facade.unpin(pin);
}

test "BR-001 runtime cache repeated real reads hit with one existing CPU credit" {
    const f = try CacheHarness.init();
    defer f.deinit();
    const c = try f.client(1, 7, "alpha\r\nbeta\n");
    const first = try f.read(c, "{\"path\":\"file.txt\"}");
    try testing.expect(first.object.get("ok").?.bool);
    const second = try f.read(c, "{\"path\":\"file.txt\"}");
    try testing.expect(second.object.get("ok").?.bool);
    try testing.expectEqual(@as(usize, 1), f.store.?.stats().entries);
    const third = try f.read(c, "{\"path\":\"file.txt\"}");
    try testing.expect(third.object.get("ok").?.bool);
    try testing.expectEqualStrings("hit", third.object.get("meta").?.object.get("cache").?.string);
    try testing.expectEqualStrings(try std.json.Stringify.valueAlloc(f.arena.allocator(), first.object.get("data").?, .{}), try std.json.Stringify.valueAlloc(f.arena.allocator(), third.object.get("data").?, .{}));
    try testing.expectEqual(@as(usize, 0), f.store.?.stats().pins);
    try testing.expectEqual(@as(u8, 0), f.budget.usage().cpu);
    try testing.expectEqual(@as(u16, 0), f.budget.usage().fds);
}

test "BR-001 runtime cache four workspace queries share one allocation and drain pins" {
    const f = try CacheHarness.init();
    defer f.deinit();
    const first = try f.client(1, 7, "shared\n");
    _ = try f.read(first, "{\"path\":\"file.txt\"}");
    _ = try f.read(first, "{\"path\":\"file.txt\"}");
    const charge = f.store.?.stats().content_bytes;
    try testing.expect(charge > 0);
    for (2..5) |n| {
        const c = try f.client(@intCast(n), 7, "shared\n");
        const result = try f.read(c, "{\"path\":\"file.txt\"}");
        try testing.expect(result.object.get("ok").?.bool);
        try testing.expectEqualStrings("hit", result.object.get("meta").?.object.get("cache").?.string);
        try testing.expectEqual(charge, f.store.?.stats().content_bytes);
    }
    try testing.expectEqual(@as(usize, 1), f.store.?.stats().entries);
    try testing.expectEqual(@as(usize, 4), f.store.?.stats().associations);
    try testing.expectEqual(@as(usize, 0), f.store.?.stats().pins);
}

test "BR-001 runtime cache hit preserves read version line output and truncation semantics" {
    const f = try CacheHarness.init();
    defer f.deinit();
    const bytes = "\xef\xbb\xbfalpha\r\n" ++ "line with enough text to exercise output limits\r\n" ** 70 ++ "last without terminator";
    const c = try f.client(1, 1, bytes);
    for (0..2) |_| _ = try f.read(c, "{\"path\":\"file.txt\"}");
    for ([_][]const u8{
        "{\"path\":\"file.txt\"}",
        "{\"path\":\"file.txt\",\"start_line\":2,\"line_count\":3}",
        "{\"path\":\"file.txt\",\"start_line\":72,\"line_count\":2,\"write_intent\":true}",
        "{\"path\":\"file.txt\",\"start_line\":4000,\"line_count\":1}",
        "{\"path\":\"file.txt\",\"output_bytes\":1024}",
    }) |args| {
        c.server.config.cache_session = null;
        const baseline = try f.read(c, args);
        c.server.config.cache_session = &c.facade;
        const cached = try f.read(c, args);
        for ([_][]const u8{ "ok", "data", "complete", "truncated", "consistency", "coverage" }) |key| {
            try testing.expectEqualStrings(try std.json.Stringify.valueAlloc(f.arena.allocator(), baseline.object.get(key).?, .{}), try std.json.Stringify.valueAlloc(f.arena.allocator(), cached.object.get(key).?, .{}));
        }
        if (cached.object.get("ok").?.bool) try testing.expectEqualStrings("hit", cached.object.get("meta").?.object.get("cache").?.string);
        try testing.expectEqual(@as(usize, 0), f.store.?.stats().pins);
    }
    // Zero bytes and final-newline boundaries pass through the same real query path.
    for ([_][]const u8{ "", "\n", "one\n" }, 2..) |text_, n| {
        const other = try f.client(@intCast(n), 1, text_);
        const first = try f.read(other, "{\"path\":\"file.txt\",\"write_intent\":true}");
        _ = try f.read(other, "{\"path\":\"file.txt\",\"write_intent\":true}");
        const hit = try f.read(other, "{\"path\":\"file.txt\",\"write_intent\":true}");
        try testing.expectEqualStrings("hit", hit.object.get("meta").?.object.get("cache").?.string);
        try testing.expectEqualStrings(try std.json.Stringify.valueAlloc(f.arena.allocator(), first.object.get("data").?, .{}), try std.json.Stringify.valueAlloc(f.arena.allocator(), hit.object.get("data").?, .{}));
    }
}

test "IS-006 runtime cache respects domains revocation generation and same-metadata changes" {
    const f = try CacheHarness.init();
    defer f.deinit();
    const a = try f.client(1, 1, "alpha\n");
    for (0..2) |_| _ = try f.read(a, "{\"path\":\"file.txt\"}");
    const b = try f.client(2, 2, "alpha\n");
    const separate = try f.read(b, "{\"path\":\"file.txt\"}");
    try testing.expectEqualStrings("miss", separate.object.get("meta").?.object.get("cache").?.string);
    try testing.expectEqual(@as(usize, 1), f.store.?.stats().entries);
    const generation = try f.registry.markChanged(a.facade.context.bound_workspace);
    const changed_generation = try f.read(a, "{\"path\":\"file.txt\"}");
    try testing.expectEqualStrings("hit", changed_generation.object.get("meta").?.object.get("cache").?.string);
    try testing.expectEqual(@as(i64, @intCast(generation)), changed_generation.object.get("generation").?.integer);
    const old = try a.root.dir.statFile(io, "file.txt", .{});
    try a.root.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "other\n" });
    const file = try a.root.dir.openFile(io, "file.txt", .{ .mode = .read_write });
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = old.mtime } });
    file.close(io);
    const changed = try f.read(a, "{\"path\":\"file.txt\"}");
    try testing.expect(changed.object.get("ok").?.bool);
    try testing.expectEqualStrings("miss", changed.object.get("meta").?.object.get("cache").?.string);
    try testing.expectEqualStrings("other\n", changed.object.get("data").?.object.get("lines").?.array.items[0].object.get("text").?.string);
    try f.registry.unbindSession(a.facade.context.session_id, f.registry.bootNonce());
    const refused = try f.read(a, "{\"path\":\"file.txt\"}");
    try testing.expectEqualStrings("E_SCOPE", refused.object.get("error").?.object.get("code").?.string);
    try testing.expectEqual(@as(usize, 0), f.store.?.stats().pins);
}

test "BR-001 runtime cache partial reads do not admit and cancelled or failed hits drain" {
    const f = try CacheHarness.init();
    defer f.deinit();
    const c = try f.client(1, 1, "one\ntwo\n");
    for (0..3) |_| _ = try f.read(c, "{\"path\":\"file.txt\",\"line_count\":1,\"write_intent\":true}");
    try testing.expectEqual(@as(usize, 0), f.store.?.stats().entries);
    try testing.expectEqual(@as(usize, 0), f.store.?.stats().probation);
    for (0..2) |_| _ = try f.read(c, "{\"path\":\"file.txt\"}");
    const baseline = f.budget.usage().bytes;
    const Hook = struct {
        fn cancel(context: *anyopaque) void {
            const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(context));
            flag.store(true, .release);
        }
    };
    var request_flag = std.atomic.Value(bool).init(false);
    cache.association.test_hooks = .{ .context = &request_flag, .after_chunk = Hook.cancel };
    defer cache.association.test_hooks = null;
    const cancelled = try f.readWithCancel(c, "{\"path\":\"file.txt\"}", .{ .requested = &request_flag });
    try testing.expectEqualStrings("E_CANCELLED", cancelled.object.get("error").?.object.get("code").?.string);
    cache.association.test_hooks = null;
    try testing.expect(!c.flag.load(.acquire));
    try testing.expect(c.facade.cancel.requested == &c.flag);
    try testing.expect(c.facade.cancel.deadline == null);
    var deadline_flag = std.atomic.Value(bool).init(false);
    const deadline = try f.readWithCancel(c, "{\"path\":\"file.txt\"}", (core.Cancel{ .requested = &deadline_flag }).withTimeout(io, 0));
    try testing.expectEqualStrings("E_DEADLINE", deadline.object.get("error").?.object.get("code").?.string);
    try testing.expect(c.facade.request_credit == null);
    try testing.expectEqual(@as(usize, 0), f.store.?.stats().pins);
    try testing.expectEqual(baseline, f.budget.usage().bytes);
    // Scratch allocation succeeds, then the owned result allocation fails after pin acquisition.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    c.server.config.allocator = failing.allocator();
    const failed = try f.read(c, "{\"path\":\"file.txt\"}");
    c.server.config.allocator = testing.allocator;
    try testing.expectEqualStrings("E_RESOURCE", failed.object.get("error").?.object.get("code").?.string);
    try testing.expectEqual(@as(usize, 0), f.store.?.stats().pins);
    try testing.expectEqual(baseline, f.budget.usage().bytes);
    const recovered = try f.read(c, "{\"path\":\"file.txt\"}");
    try testing.expectEqualStrings("hit", recovered.object.get("meta").?.object.get("cache").?.string);
}

test "BR-001 runtime cache Reader truncation equals the filesystem oracle and unpins before result use" {
    const f = try CacheHarness.init();
    defer f.deinit();
    const c = try f.client(1, 1, "first line\r\nsecond line\nthird line is longer\nlast");
    for (0..2) |_| _ = try f.read(c, "{\"path\":\"file.txt\"}");
    var reservation = try f.budget.reserve(c.facade.context, .{ .scratch_bytes = 1024 * 1024, .output_bytes = 24, .fds = 3, .cpu_permits = 1 });
    defer f.budget.release(&reservation) catch unreachable;
    var allocation = memory.ReservedAllocator.init(testing.allocator, &reservation, &f.counters, null);
    const spec: core.ReadSpec = .{ .path = .{ .bytes = "file.txt" }, .lines = try core.LineRange.init(1, 200), .output_bytes = 24, .write_intent = true };
    const cap = try c.auth.authorize(io, c.facade.context, .read, spec.path);
    var plain = fs_read.Reader.init(c.root, c.facade.context.bound_workspace, c.server.config.generation);
    var expected = try plain.readRange(io, allocation.allocator(), cap, spec, &reservation, .{ .requested = &c.flag });
    defer expected.deinit();
    var request = try c.facade.forRequest(&f.budget, &reservation, &allocation, .{ .requested = &c.flag });
    var cached = plain;
    cached.cache_session = &request;
    var actual = try cached.readRange(io, allocation.allocator(), cap, spec, &reservation, .{ .requested = &c.flag });
    defer actual.deinit();
    try testing.expect(actual.value.status.truncated);
    try testing.expectEqualDeep(expected.value, actual.value);
    try testing.expectEqual(core.CacheResult.hit, cached.cache_result);
    try testing.expectEqual(@as(usize, 0), f.store.?.stats().pins);
    try testing.expect(f.store.?.evict(0) > 0);
    // Result bytes have independent reservation-backed ownership after pin release/eviction.
    try testing.expectEqualStrings("first line\r\n", actual.value.lines[0].text);
}

test "IS-006 runtime cache host configuration rejects foreign facades and independent budgets" {
    const f = try CacheHarness.init();
    defer f.deinit();
    const a = try f.client(1, 1, "one\n");
    const b = try f.client(2, 1, "one\n");
    var wrong = a.server.config;
    wrong.cache_session = &b.facade;
    try testing.expectError(error.OutOfScope, mcp.Server.init(wrong));
    var independent = memory.Budget.init(f.budget.id, f.budget.caps, &f.counters);
    wrong = a.server.config;
    wrong.budget = &independent;
    try testing.expectError(error.OutOfScope, mcp.Server.init(wrong));
}
