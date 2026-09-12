//! T08 tests: the direct stdio MCP adapter (MC-001..MC-004) over the I01-I06
//! implementations and the T07 projection.
//!
//! Run: `zig build test -Dtest-group=mcp`.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const memory = @import("zcr_memory");
const admission = @import("zcr_admission");
const fs_read = @import("zcr_fs_read");
const traverse = @import("zcr_fs_traverse");
const search = @import("zcr_search");
const batch = @import("zcr_batch");
const projection = @import("zcr_projection");
const mcp = @import("zcr_mcp");

const codec = mcp.codec;
const framing = mcp.framing;
const testing = std.testing;
const io = testing.io;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const KiB = core.limits.KiB;
const MiB = core.limits.MiB;

extern "c" fn pipe(fds: *[2]c_int) c_int;

const workspace: core.WorkspaceId = .{ .registry_uuid = @splat(0x11), .incarnation = @splat(0x22) };
const task: core.TaskId = .{ .uuid = @splat(0x33) };
const digest: core.PolicyDigest = @splat(0x44);

fn session(id: u8) core.SessionContext {
    return .{
        .session_id = .{ .uuid = @splat(id) },
        .security_domain = .{ .id = 1 },
        .policy_digest = digest,
        .bound_workspace = workspace,
        .bound_task = task,
        .capability_handle = .none,
    };
}

const Harness = struct {
    arena: Allocator,
    tmp: testing.TmpDir,
    root: core.TrustedRoot,
    authorizer: policy.Authorizer,
    counters: memory.accounting.Counters = .{},
    budget: memory.Budget = undefined,
    admission: admission.Admission = undefined,
    reader: fs_read.Reader,
    traverser: traverse.Traverser,
    searcher: search.Searcher,
    batcher: batch.Batcher,
    registry: mcp.Registry = .{},
    server: mcp.Server = undefined,
    out_file: Io.File = undefined,
    writer: framing.Writer = undefined,
    cancel_flag: std.atomic.Value(bool) = .init(false),

    fn init(arena: Allocator) !*Harness {
        const h = try arena.create(Harness);
        h.* = .{
            .arena = arena,
            .tmp = testing.tmpDir(.{}),
            .root = undefined,
            .authorizer = undefined,
            .reader = undefined,
            .traverser = undefined,
            .searcher = undefined,
            .batcher = undefined,
        };
        const root_path = try h.tmp.dir.realPathFileAlloc(io, ".", arena);
        const dir = try Io.Dir.openDirAbsolute(io, root_path, .{});
        h.root = .{ .dir = dir, .canonical_path = root_path };
        h.authorizer = try policy.Authorizer.init(arena, io, h.root, workspace, task, .{
            .digest = digest,
            .state = .active,
            .read_paths = &.{.{ .bytes = "." }},
            .write_paths = &.{},
            .immutable_paths = &.{},
            .operations = &.{ .read, .enumerate, .search, .batch_read, .status, .health },
            .max_changed_files = 1,
        }, .{ .git_dir = null, .common_dir = null });
        h.budget = memory.Budget.init(1, .{ .bytes = 256 * MiB, .fds = 64, .cpu = 4, .output_bytes = 32 * MiB }, &h.counters);
        h.admission = admission.Admission.init(&h.budget, null);
        h.reader = fs_read.Reader.init(h.root, workspace, 7);
        h.traverser = try traverse.Traverser.init(testing.allocator, h.root, workspace, .{});
        h.searcher = try search.Searcher.init(testing.allocator, h.root, workspace, 7, .{});
        h.batcher = batch.Batcher.init(&h.authorizer, &h.reader, .{}, .{ .requested = &h.cancel_flag });
        h.server = try mcp.Server.init(testing.allocator, h.deps(), session(0x55), .{}, .{}, &h.registry);
        h.out_file = try h.tmp.dir.createFile(io, "stdout.jsonl", .{});
        h.writer = framing.Writer.init(h.out_file);
        return h;
    }

    fn deps(h: *Harness) mcp.Dependencies {
        return .{
            .authorizer = &h.authorizer,
            .reader = &h.reader,
            .traverser = &h.traverser,
            .searcher = &h.searcher,
            .batcher = &h.batcher,
            .budget = &h.budget,
            .admission = &h.admission,
            .counters = &h.counters,
        };
    }

    fn deinit(h: *Harness) void {
        h.server.deinit();
        h.out_file.close(io);
        h.searcher.deinit();
        h.traverser.deinit();
        h.root.dir.close(io);
        h.tmp.cleanup();
    }

    fn write(h: *Harness, sub: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub)) |parent| try h.tmp.dir.createDirPath(io, parent);
        try h.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = data });
    }

    /// Serves one record and returns the response bytes (empty for a notification).
    fn serve(h: *Harness, record: []const u8) !core.EncodedToolResult {
        var connection: core.Connection = .{ .context = h };
        return h.server.serveFrame(io, &connection, .{ .bytes = record, .limit = framing.max_frame_bytes });
    }

    /// Serves a record and parses the JSON-RPC response.
    fn call(h: *Harness, record: []const u8) !std.json.Value {
        const result = try h.serve(record);
        try testing.expect(result.bytes.len > 0);
        return std.json.parseFromSliceLeaky(std.json.Value, h.arena, result.bytes, .{});
    }

    fn initialize(h: *Harness) !void {
        const response = try h.call(
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1"},"capabilities":{}}}
        );
        try testing.expect(response.object.get("error") == null);
    }

    /// The logical response inside a tool result's single text block.
    fn toolText(h: *Harness, response: std.json.Value) !std.json.Value {
        const result = response.object.get("result") orelse {
            std.debug.print("expected a tool result, got {s}\n", .{@tagName(response.object.get("error").?)});
            return error.TestExpectedEqual;
        };
        const content = result.object.get("content").?.array.items;
        try testing.expectEqual(@as(usize, 1), content.len);
        try testing.expectEqualStrings("text", content[0].object.get("type").?.string);
        return std.json.parseFromSliceLeaky(std.json.Value, h.arena, content[0].object.get("text").?.string, .{});
    }

    fn isError(response: std.json.Value) bool {
        const result = response.object.get("result") orelse return false;
        return result.object.get("isError").?.bool;
    }

    fn errorCode(response: std.json.Value) i64 {
        return response.object.get("error").?.object.get("code").?.integer;
    }
};

fn toolCall(arena: Allocator, id: u32, name: []const u8, arguments: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":{d},"method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
    , .{ id, name, arguments });
}

// ------------------------------------------------------------------ MC-001

test "MC-001 initialize negotiates the supported version and refuses others explicitly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();

    // An unsupported version is refused by name, and the server stays uninitialized.
    const refused = try h.call(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"t","version":"1"},"capabilities":{}}}
    );
    try testing.expectEqual(@as(i64, codec.rpc_invalid_params), Harness.errorCode(refused));
    try testing.expect(std.mem.indexOf(u8, refused.object.get("error").?.object.get("message").?.string, mcp.protocol_version) != null);
    const before_init = try h.call(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    try testing.expectEqual(@as(i64, codec.rpc_invalid_request), Harness.errorCode(before_init));

    const accepted = try h.call(
        \\{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"t","version":"1"},"capabilities":{}}}
    );
    const result = accepted.object.get("result").?.object;
    try testing.expectEqualStrings(mcp.protocol_version, result.get("protocolVersion").?.string);
    try testing.expectEqualStrings(mcp.server_name, result.get("serverInfo").?.object.get("name").?.string);
    try testing.expect(result.get("capabilities").?.object.get("tools") != null);
    try testing.expectEqual(@as(i64, 3), accepted.object.get("id").?.integer);

    // A second initialize is a protocol error, not a silent re-handshake.
    const again = try h.call(
        \\{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"t","version":"1"},"capabilities":{}}}
    );
    try testing.expectEqual(@as(i64, codec.rpc_invalid_request), Harness.errorCode(again));
    try testing.expectEqual(@as(u64, 0), h.server.report().tool_calls);
}

test "MC-001 tools/list advertises only enabled contract tools and no output schema" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    try h.initialize();

    const listed = try h.call(
        \\{"jsonrpc":"2.0","id":5,"method":"tools/list"}
    );
    const tools = listed.object.get("result").?.object.get("tools").?.array.items;
    const contract = try std.json.parseFromSliceLeaky(std.json.Value, h.arena, mcp.tools_json, .{});
    const contract_tools = contract.object.get("tools").?.array.items;

    var names: std.ArrayList([]const u8) = .empty;
    for (tools) |tool| {
        const name = tool.object.get("name").?.string;
        try names.append(h.arena, name);
        try testing.expect(tool.object.get("inputSchema") != null);
        try testing.expect(tool.object.get("outputSchema") == null);
        const in_contract = for (contract_tools) |c| {
            if (std.mem.eql(u8, c.object.get("name").?.string, name)) break true;
        } else false;
        try testing.expect(in_contract);
    }
    const expected = [_][]const u8{ "zcr_read", "zcr_files", "zcr_search", "zcr_batch_read", "zcr_status", "zcr_health" };
    try testing.expectEqual(expected.len, names.items.len);
    for (expected, names.items) |want, got| try testing.expectEqualStrings(want, got);

    // Writes are not advertised and cannot be called before T12.
    const patch = try h.call(try toolCall(h.arena, 6, "zcr_patch",
        \\{"path":"a.txt","expected_sha256":"00","replacements":[],"idempotency_key":"k"}
    ));
    try testing.expect(Harness.isError(patch));
    const envelope = try h.toolText(patch);
    try testing.expectEqualStrings("E_UNSUPPORTED", envelope.object.get("error").?.object.get("code").?.string);
    try testing.expect(!envelope.object.get("ok").?.bool);
}

test "MC-001 every enabled tool answers with one text block holding a zcr/1 response" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    try h.write("a.txt", "alpha\nbeta\ngamma\n");
    try h.write("sub/b.txt", "needle here\nsecond\n");
    try h.initialize();

    const read = try h.toolText(try h.call(try toolCall(h.arena, 10, "zcr_read",
        \\{"path":"a.txt","start_line":1,"line_count":2}
    )));
    try testing.expectEqualStrings(core.schema_version, read.object.get("schema_version").?.string);
    try testing.expect(read.object.get("ok").?.bool);
    const lines = read.object.get("data").?.object.get("lines").?.array.items;
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("alpha\n", lines[0].object.get("text").?.string);
    try testing.expectEqualStrings("checked_live", read.object.get("consistency").?.string);
    try testing.expect(read.object.get("meta").?.object.get("returned_bytes").?.integer > 0);

    const files = try h.toolText(try h.call(try toolCall(h.arena, 11, "zcr_files",
        \\{"glob":"**/*.txt","limit":10}
    )));
    const paths = files.object.get("data").?.object.get("paths").?.array.items;
    try testing.expectEqual(@as(usize, 2), paths.len);

    const found = try h.toolText(try h.call(try toolCall(h.arena, 12, "zcr_search",
        \\{"literal":"needle","context_lines":1,"limit":5}
    )));
    const hits = found.object.get("data").?.object.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("sub/b.txt", hits[0].object.get("path").?.string);

    const many = try h.toolText(try h.call(try toolCall(h.arena, 13, "zcr_batch_read",
        \\{"items":[{"item_id":"one","path":"a.txt","start_line":1,"line_count":1},{"item_id":"two","path":"missing.txt"},{"item_id":"three","path":"sub/b.txt","start_line":2,"line_count":1}]}
    )));
    const items = many.object.get("data").?.object.get("items").?.array.items;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("one", items[0].object.get("item_id").?.string);
    try testing.expect(items[0].object.get("ok").?.bool);
    try testing.expectEqualStrings("E_NOT_FOUND", items[1].object.get("error").?.object.get("code").?.string);
    try testing.expectEqualStrings("second\n", items[2].object.get("data").?.object.get("lines").?.array.items[0].object.get("text").?.string);

    const status = try h.toolText(try h.call(try toolCall(h.arena, 14, "zcr_status", "{}")));
    try testing.expectEqualStrings("read_only", status.object.get("data").?.object.get("write_mode").?.string);
    const health = try h.toolText(try h.call(try toolCall(h.arena, 15, "zcr_health", "{}")));
    const capabilities = health.object.get("data").?.object.get("capabilities").?.object;
    try testing.expect(capabilities.get("read").?.bool);
    try testing.expect(!capabilities.get("patch").?.bool);
    try testing.expect(health.object.get("data").?.object.get("tracked_limit_bytes").?.integer > 0);

    const rep = h.server.report();
    try testing.expectEqual(@as(u64, 6), rep.tool_calls);
    try testing.expectEqual(@as(u64, 0), rep.tool_errors);
}

// ------------------------------------------------------------------ MC-002

test "MC-002 records survive any chunk boundary and keep escaped newlines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const records = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"zcr_read","arguments":{"path":"a\nb.txt"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"ping"}
        ,
    };
    var stream: std.ArrayList(u8) = .empty;
    for (records) |r| {
        try stream.appendSlice(arena, r);
        try stream.append(arena, '\n');
    }

    var chunk: usize = 1;
    while (chunk <= stream.items.len) : (chunk += 7) {
        var buffer: [4 * KiB]u8 = undefined;
        var framer = framing.Framer.init(&buffer);
        var seen: usize = 0;
        var offset: usize = 0;
        while (offset < stream.items.len) {
            const end = @min(offset + chunk, stream.items.len);
            var input: []const u8 = stream.items[offset..end];
            while (framer.next(&input)) |item| {
                try testing.expectEqualStrings(records[seen], item.record);
                seen += 1;
            }
            try testing.expectEqual(@as(usize, 0), input.len);
            offset = end;
        }
        try testing.expectEqual(records.len, seen);
        try testing.expectEqual(@as(usize, 0), framer.pending());
        try testing.expectEqual(@as(u64, records.len), framer.records);
    }
}

test "MC-002 a record larger than the buffer is dropped and framing resyncs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const big = try arena.alloc(u8, 600);
    @memset(big, 'x');
    const stream = try std.fmt.allocPrint(arena, "{{\"a\":\"{s}\"}}\n{{\"b\":1}}\n", .{big});

    var buffer: [256]u8 = undefined;
    var framer = framing.Framer.init(&buffer);
    var input: []const u8 = stream;
    const first = framer.next(&input).?;
    try testing.expectEqual(@as(u64, 1), first.too_large);
    const second = framer.next(&input).?;
    try testing.expectEqualStrings("{\"b\":1}", second.record);
    try testing.expectEqual(@as(u64, 1), framer.oversize);
    try testing.expectEqual(@as(u64, 1), framer.records);
}

const Chorus = struct {
    writer: *framing.Writer,
    failures: std.atomic.Value(u32) = .init(0),

    fn shout(self: *Chorus, who: u8) void {
        var buffer: [4 * KiB]u8 = undefined;
        for (0..25) |i| {
            const size = 16 + (i * 37) % 900;
            const text = buffer[0..size];
            @memset(text, 'a' + who);
            const record = std.fmt.bufPrint(buffer[size..], "{{\"who\":{d},\"n\":{d},\"text\":\"{s}\"}}", .{ who, i, text }) catch unreachable;
            self.writer.writeRecord(io, record) catch {
                _ = self.failures.fetchAdd(1, .monotonic);
                return;
            };
        }
    }
};

test "MC-002 concurrent writers keep one record per line and never interleave" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();

    var chorus: Chorus = .{ .writer = &h.writer };
    var group: Io.Group = .init;
    for (1..4) |who| group.async(io, Chorus.shout, .{ &chorus, @as(u8, @intCast(who)) });
    chorus.shout(0);
    group.await(io) catch {};
    try testing.expectEqual(@as(u32, 0), chorus.failures.load(.monotonic));
    try testing.expectEqual(@as(u64, 100), h.writer.records);

    const written = try h.tmp.dir.readFileAlloc(io, "stdout.jsonl", h.arena, .limited(4 * MiB));
    var lines = std.mem.splitScalar(u8, written[0 .. written.len - 1], '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, h.arena, line, .{});
        const who: u8 = @intCast(value.object.get("who").?.integer);
        const text = value.object.get("text").?.string;
        for (text) |c| try testing.expectEqual('a' + who, c);
    }
    try testing.expectEqual(@as(usize, 100), count);
    try testing.expectEqual(written[written.len - 1], '\n');
}

test "MC-002 source content only reaches stdout inside a record, and never stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    try h.write("secret.txt", "TOPSECRET line\n");
    try h.initialize();

    const stderr_file = try h.tmp.dir.createFile(io, "stderr.log", .{});
    defer stderr_file.close(io);
    const response = try h.serve(try toolCall(h.arena, 20, "zcr_read",
        \\{"path":"secret.txt"}
    ));
    try h.writer.writeRecord(io, response.bytes);

    const written = try h.tmp.dir.readFileAlloc(io, "stdout.jsonl", h.arena, .limited(4 * MiB));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\n"));
    try testing.expect(std.mem.indexOf(u8, written, "TOPSECRET") != null);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, h.arena, written[0 .. written.len - 1], .{});
    const text = value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
    try testing.expect(std.mem.indexOf(u8, text, "TOPSECRET") != null);
    const log = try h.tmp.dir.readFileAlloc(io, "stderr.log", h.arena, .limited(1 * MiB));
    try testing.expectEqual(@as(usize, 0), log.len);
}

// ------------------------------------------------------------------ MC-003

test "MC-003 duplicate keys, deep JSON, unknown fields and bad numbers are refused early" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    try h.write("a.txt", "alpha\n");
    try h.initialize();

    const duplicate = try h.call(
        \\{"jsonrpc":"2.0","id":1,"method":"ping","method":"tools/list"}
    );
    try testing.expectEqual(@as(i64, codec.rpc_invalid_request), Harness.errorCode(duplicate));

    const deep = try h.arena.alloc(u8, 0);
    _ = deep;
    var nested: std.ArrayList(u8) = .empty;
    try nested.appendSlice(h.arena,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":
    );
    for (0..codec.max_depth + 2) |_| try nested.append(h.arena, '[');
    for (0..codec.max_depth + 2) |_| try nested.append(h.arena, ']');
    try nested.append(h.arena, '}');
    const too_deep = try h.call(nested.items);
    try testing.expect(Harness.errorCode(too_deep) == codec.rpc_invalid_request or Harness.errorCode(too_deep) == codec.rpc_invalid_params);

    const broken = try h.call("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":");
    try testing.expectEqual(@as(i64, codec.rpc_parse_error), Harness.errorCode(broken));
    const not_json = try h.call("hello");
    try testing.expectEqual(@as(i64, codec.rpc_parse_error), Harness.errorCode(not_json));
    const no_version = try h.call(
        \\{"id":4,"method":"ping"}
    );
    try testing.expectEqual(@as(i64, codec.rpc_invalid_request), Harness.errorCode(no_version));
    const unknown_method = try h.call(
        \\{"jsonrpc":"2.0","id":5,"method":"resources/list"}
    );
    try testing.expectEqual(@as(i64, codec.rpc_method_not_found), Harness.errorCode(unknown_method));

    // Tool argument problems are tool errors with a wire code, not JSON-RPC errors.
    const cases = [_]struct { args: []const u8, code: []const u8 }{
        .{ .args =
        \\{"path":"a.txt","unknown_field":1}
        , .code = "E_INVALID_ARGUMENT" },
        .{ .args =
        \\{"path":"a.txt","start_line":0}
        , .code = "E_INVALID_ARGUMENT" },
        .{ .args =
        \\{"path":"a.txt","line_count":100000}
        , .code = "E_INVALID_ARGUMENT" },
        .{ .args =
        \\{"path":"a.txt","output_bytes":10}
        , .code = "E_INVALID_ARGUMENT" },
        .{ .args =
        \\{"path":"a.txt","start_line":"1"}
        , .code = "E_INVALID_ARGUMENT" },
        .{ .args =
        \\{"path":"a.txt","start_line":99999999999999999999}
        , .code = "E_INVALID_ARGUMENT" },
        .{ .args =
        \\{}
        , .code = "E_INVALID_ARGUMENT" },
        .{ .args =
        \\{"path":"../outside.txt"}
        , .code = "E_PATH_ESCAPE" },
        .{ .args =
        \\{"path":"a.txt","consistency":"bounded_stale"}
        , .code = "E_UNSUPPORTED" },
    };
    for (cases, 0..) |c, i| {
        const response = try h.call(try toolCall(h.arena, @intCast(100 + i), "zcr_read", c.args));
        try testing.expect(Harness.isError(response));
        const envelope = try h.toolText(response);
        try testing.expectEqualStrings(c.code, envelope.object.get("error").?.object.get("code").?.string);
        try testing.expect(!envelope.object.get("ok").?.bool);
    }
    const unknown_tool = try h.call(try toolCall(h.arena, 200, "zcr_teleport", "{}"));
    try testing.expect(Harness.isError(unknown_tool));

    try testing.expect(h.server.report().tool_errors >= cases.len);
}

test "MC-003 frames beyond the raw frame limit are refused before decoding" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    try h.initialize();

    const oversize = try testing.allocator.alloc(u8, framing.max_frame_bytes + 1);
    defer testing.allocator.free(oversize);
    @memset(oversize, ' ');
    @memcpy(oversize[0..9], "{\"a\":\"bb\"");
    const live_before = h.counters.live_bytes.load(.monotonic);
    var connection: core.Connection = .{ .context = h };
    const refused = try h.server.serveFrame(io, &connection, .{ .bytes = oversize, .limit = framing.max_frame_bytes });
    try testing.expect(refused.is_error);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, h.arena, refused.bytes, .{});
    try testing.expectEqual(@as(i64, codec.rpc_invalid_request), Harness.errorCode(value));
    try testing.expectEqual(@as(u64, 1), h.server.report().oversize_frames);
    try testing.expectEqual(live_before, h.counters.live_bytes.load(.monotonic));

    // A frame past the caller's own smaller limit is refused the same way.
    const small = try h.serve("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}");
    try testing.expect(!small.is_error);
    var connection2: core.Connection = .{ .context = h };
    const past_limit = try h.server.serveFrame(io, &connection2, .{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}", .limit = 8 });
    try testing.expect(past_limit.is_error);
}

test "MC-003 decoding stays inside the request budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    try h.write("a.txt", "alpha\n");
    try h.initialize();

    // 32 batch items with long ids and paths, repeated: nothing accumulates between frames.
    var items: std.ArrayList(u8) = .empty;
    for (0..32) |i| {
        if (i > 0) try items.append(h.arena, ',');
        try items.print(h.arena, "{{\"item_id\":\"id-{d}-{s}\",\"path\":\"a.txt\",\"start_line\":1,\"line_count\":1}}", .{ i, "x" ** 40 });
    }
    const record = try toolCall(h.arena, 30, "zcr_batch_read", try std.fmt.allocPrint(h.arena, "{{\"items\":[{s}]}}", .{items.items}));
    var peak_after_first: u64 = 0;
    for (0..3) |round| {
        const response = try h.call(record);
        try testing.expect(!Harness.isError(response));
        if (round == 0) peak_after_first = h.counters.peak_live_bytes.load(.monotonic);
    }
    try testing.expectEqual(peak_after_first, h.counters.peak_live_bytes.load(.monotonic));
    try testing.expect(h.server.report().peak_request_bytes <= h.server.caps.request_bytes);
    try testing.expectEqual(@as(u64, 0), h.counters.live_bytes.load(.monotonic));
}

// ------------------------------------------------------------------ MC-004

const Interrupter = struct {
    h: *Harness,
    /// Set by the search once it is inside the file.
    inside: std.atomic.Value(bool) = .init(false),
    /// Set by the canceller once the notification was served.
    cancelled: std.atomic.Value(bool) = .init(false),

    fn afterChunk(context: ?*anyopaque, chunk: u32) void {
        _ = chunk;
        const self: *Interrupter = @ptrCast(@alignCast(context.?));
        self.inside.store(true, .release);
        while (!self.cancelled.load(.acquire)) std.atomic.spinLoopHint();
    }

    /// Serves the cancellation from a second connection of the same session.
    fn cancel(self: *Interrupter, other: *mcp.Server, record: []const u8) void {
        while (!self.inside.load(.acquire)) std.atomic.spinLoopHint();
        var connection: core.Connection = .{ .context = self };
        const result = other.serveFrame(io, &connection, .{ .bytes = record, .limit = framing.max_frame_bytes }) catch unreachable;
        std.debug.assert(result.bytes.len == 0);
        self.cancelled.store(true, .release);
    }
};

test "MC-004 a cancellation stops the running request of the same session only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    const big = try h.arena.alloc(u8, 2 * MiB);
    for (big, 0..) |*b, i| b.* = if (i % 80 == 79) '\n' else 'q';
    try h.write("big.txt", big);
    try h.initialize();

    // A second connection bound to the same session shares the request registry.
    var other = try mcp.Server.init(testing.allocator, h.deps(), session(0x55), .{}, .{}, &h.registry);
    defer other.deinit();
    var stranger = try mcp.Server.init(testing.allocator, h.deps(), session(0x77), .{}, .{}, &h.registry);
    defer stranger.deinit();

    var interrupter: Interrupter = .{ .h = h };
    var fault: search.SearchFault = .{ .after_chunk = Interrupter.afterChunk, .context = &interrupter };
    h.searcher.fault = &fault;
    defer h.searcher.fault = null;

    // Another session cannot cancel this request.
    var stranger_connection: core.Connection = .{ .context = h };
    const ignored = try stranger.serveFrame(io, &stranger_connection, .{ .bytes =
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":40,"reason":"stop"}}
    , .limit = framing.max_frame_bytes });
    try testing.expectEqual(@as(usize, 0), ignored.bytes.len);
    try testing.expectEqual(@as(u64, 1), stranger.report().cancel_ignored);

    var group: Io.Group = .init;
    group.async(io, Interrupter.cancel, .{ &interrupter, &other,
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":40,"reason":"stop"}}
    });
    const response = try h.call(try toolCall(h.arena, 40, "zcr_search",
        \\{"literal":"qqqq","limit":1000}
    ));
    group.await(io) catch {};

    try testing.expect(Harness.isError(response));
    const envelope = try h.toolText(response);
    try testing.expectEqualStrings("E_CANCELLED", envelope.object.get("error").?.object.get("code").?.string);
    try testing.expectEqual(@as(u64, 1), h.server.report().cancelled);

    // The registry is empty again and a later cancellation for the same id is ignored.
    var connection: core.Connection = .{ .context = h };
    const late = try h.server.serveFrame(io, &connection, .{ .bytes =
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":40,"reason":"stop"}}
    , .limit = framing.max_frame_bytes });
    try testing.expectEqual(@as(usize, 0), late.bytes.len);
    try testing.expectEqual(@as(u64, 1), h.server.report().cancel_ignored);

    // The next request still works.
    const after = try h.call(try toolCall(h.arena, 41, "zcr_read",
        \\{"path":"big.txt","start_line":1,"line_count":1}
    ));
    try testing.expect(!Harness.isError(after));
}

const SlowReader = struct {
    file: Io.File,
    bytes: std.atomic.Value(u64) = .init(0),
    lines: std.atomic.Value(u64) = .init(0),

    fn drain(self: *SlowReader) void {
        var buffer: [64]u8 = undefined;
        while (true) {
            const n = self.file.readStreaming(io, &.{&buffer}) catch return;
            if (n == 0) return;
            _ = self.bytes.fetchAdd(n, .monotonic);
            for (buffer[0..n]) |c| {
                if (c == '\n') _ = self.lines.fetchAdd(1, .monotonic);
            }
            for (0..2000) |_| std.atomic.spinLoopHint();
        }
    }
};

test "MC-004 a slow reader applies backpressure without deadlocking the writer" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), pipe(&fds));
    const read_end: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    var writer = framing.Writer.init(write_end);
    var slow: SlowReader = .{ .file = read_end };

    const record = try arena.alloc(u8, 64 * KiB);
    @memset(record, 'z');
    @memcpy(record[0..10], "{\"pad\":\"aa");
    @memcpy(record[record.len - 2 ..], "\"}");

    var group: Io.Group = .init;
    group.async(io, SlowReader.drain, .{&slow});
    for (0..16) |_| try writer.writeRecord(io, record);
    write_end.close(io);
    group.await(io) catch {};
    read_end.close(io);

    try testing.expectEqual(@as(u64, 16), writer.records);
    try testing.expectEqual(@as(u64, 16), slow.lines.load(.monotonic));
    try testing.expectEqual(@as(u64, 16 * (record.len + 1)), slow.bytes.load(.monotonic));
}

// ------------------------------------------------------------------ contracts

test "T08 protocol contracts" {
    comptime core.conforms(core.ServeFrameFn(mcp.Server), mcp.Server.serveFrame);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const contract = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), mcp.tools_json, .{});
    try testing.expectEqualStrings(mcp.protocol_version, contract.object.get("mcp_compatibility_baseline").?.string);
    try testing.expectEqualStrings(mcp.output_profile, contract.object.get("default_output_profile").?.string);
    try testing.expectEqual(@as(u64, 16 * MiB), framing.max_frame_bytes);
    try testing.expectEqual(@as(u32, 64), codec.max_depth);
    try testing.expectEqual(codec.Id{ .number = 7 }, codec.Id{ .number = 7 });
    try testing.expect(codec.Id.eql(.{ .string = "a" }, .{ .string = "a" }));
    try testing.expect(!codec.Id.eql(.{ .string = "a" }, .{ .number = 1 }));
}
