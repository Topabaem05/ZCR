//! Explicit client transport. It never starts a broker or retries a write.
const std = @import("std");
const core = @import("zcr_core");
const auth = @import("auth.zig");
pub const buffer_bytes = 64 * 1024;
/// Fixed bridge buffers/control are charged per approved grant at server creation.
pub const charged_bytes = 2 * buffer_bytes + @sizeOf(Client) + @sizeOf(Reconnect) + 8192;
pub const Client = struct {
    fd: std.c.fd_t,
    received: [4096]u8 = undefined,
    received_start: usize = 0,
    received_end: usize = 0,
    pub fn connect(a: std.mem.Allocator, io: std.Io, path: []const u8, token: auth.Token, domain: core.SecurityDomain) !Client {
        const parent = try auth.privateParent(a, io, path);
        defer parent.close(io);
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.IoFailure;
        errdefer _ = std.c.close(fd);
        try auth.configureSocket(fd);
        var addr = try auth.address(path);
        if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.IoFailure;
        if (try auth.peerUid(fd) != std.c.geteuid()) return error.OutOfScope;
        var c: Client = .{ .fd = fd };
        var hello: [192]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&hello, "{{\"zcr_broker\":1,\"token\":\"{s}\",\"domain\":{d}}}\n", .{ std.fmt.bytesToHex(token, .lower), domain.id });
        try c.sendAll(bytes);
        var ack: [256]u8 = undefined;
        const response = try c.readLine(&ack);
        if (!std.mem.eql(u8, response, "{\"zcr_broker\":1,\"authenticated\":true,\"writes\":false}")) return error.OutOfScope;
        return c;
    }
    pub fn close(c: *Client) void {
        _ = std.c.close(c.fd);
        c.fd = -1;
    }
    pub fn sendAll(c: *Client, bytes: []const u8) !void {
        var at: usize = 0;
        while (at < bytes.len) {
            try wait(c.fd, std.c.POLL.OUT);
            const n = auth.send(c.fd, bytes[at..]);
            if (n < 0) {
                if (auth.wouldBlock(n)) continue;
                return error.IoFailure;
            }
            if (n == 0) return error.Disconnected;
            at += @intCast(n);
        }
    }
    pub fn readLine(c: *Client, buffer: []u8) ![]const u8 {
        var at: usize = 0;
        while (at < buffer.len) {
            if (c.received_start == c.received_end) {
                try wait(c.fd, std.c.POLL.IN);
                const n = std.c.recv(c.fd, &c.received, c.received.len, 0);
                if (n < 0) {
                    if (auth.wouldBlock(n)) continue;
                    return error.IoFailure;
                }
                if (n == 0) return error.Disconnected;
                c.received_start = 0;
                c.received_end = @intCast(n);
            }
            const byte = c.received[c.received_start];
            c.received_start += 1;
            if (byte == '\n') return buffer[0..at];
            buffer[at] = byte;
            at += 1;
        }
        return error.ResourceExhausted;
    }
    /// Exclusive owner of these stdio handles. Fixed buffers are covered by
    /// charged_bytes in the broker's grant reservation before connecting. Disconnect
    /// returns immediately; there is no automatic reconnect or request replay.
    pub fn forward(c: *Client, input: std.Io.File, output: std.Io.File, cancel: core.Cancel) !void {
        try cancel.check();
        var inbound: [buffer_bytes]u8 = undefined;
        var outbound: [buffer_bytes]u8 = undefined;
        var incoming: usize = c.received_end - c.received_start;
        @memcpy(inbound[0..incoming], c.received[c.received_start..c.received_end]);
        c.received_start = c.received_end;
        var incoming_at: usize = 0;
        var outgoing: usize = 0;
        var outgoing_at: usize = 0;
        var input_eof = false;
        var socket_eof = false;
        var write_shutdown = false;
        var disconnected = false;
        const in_flags = std.c.fcntl(input.handle, std.c.F.GETFL);
        const out_flags = std.c.fcntl(output.handle, std.c.F.GETFL);
        if (in_flags < 0 or out_flags < 0) return error.IoFailure;
        const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
        if (std.c.fcntl(input.handle, std.c.F.SETFL, in_flags | nonblock) < 0) return error.IoFailure;
        defer _ = std.c.fcntl(input.handle, std.c.F.SETFL, in_flags);
        if (std.c.fcntl(output.handle, std.c.F.SETFL, out_flags | nonblock) < 0) return error.IoFailure;
        defer _ = std.c.fcntl(output.handle, std.c.F.SETFL, out_flags);
        while (true) {
            try cancel.check();
            if (input_eof and outgoing == 0 and !write_shutdown) {
                const rc = std.c.shutdown(c.fd, std.c.SHUT.WR);
                if (rc != 0 and std.posix.errno(rc) != .NOTCONN) disconnected = true;
                write_shutdown = true;
            }
            if (disconnected and incoming == 0 and !socket_eof) {
                const n = std.c.recv(c.fd, &inbound, inbound.len, 0);
                if (n > 0) {
                    incoming = @intCast(n);
                    incoming_at = 0;
                } else if (n < 0 and std.posix.errno(n) == .INTR) continue else socket_eof = true;
            }
            if (socket_eof and incoming == 0) {
                if (disconnected or !input_eof or outgoing != 0) return error.Disconnected;
                return;
            }
            const read_socket = incoming == 0 and !socket_eof;
            var fds = [_]std.c.pollfd{
                .{ .fd = if (!input_eof and outgoing == 0) input.handle else -1, .events = std.c.POLL.IN, .revents = 0 },
                .{ .fd = if (incoming != 0) output.handle else -1, .events = std.c.POLL.OUT, .revents = 0 },
                .{ .fd = if (read_socket or outgoing != 0) c.fd else -1, .events = (if (read_socket) @as(i16, std.c.POLL.IN) else 0) | (if (outgoing != 0) @as(i16, std.c.POLL.OUT) else 0), .revents = 0 },
            };
            const rc = std.c.poll(&fds, fds.len, 20);
            if (rc < 0) {
                if (std.posix.errno(rc) == .INTR) continue;
                return error.IoFailure;
            }
            if (fds[1].revents & (std.c.POLL.ERR | std.c.POLL.HUP | std.c.POLL.NVAL) != 0) return error.Disconnected;
            if (fds[0].revents & (std.c.POLL.IN | std.c.POLL.HUP) != 0) {
                const n = readReady(input.handle, &outbound, fds[0].revents) catch |err| {
                    if (err == error.WouldBlock) continue;
                    return err;
                };
                if (n == 0) input_eof = true else {
                    outgoing = n;
                    outgoing_at = 0;
                }
            }
            if (fds[2].revents & std.c.POLL.OUT != 0 and outgoing != 0) {
                const n = auth.send(c.fd, outbound[outgoing_at..outgoing]);
                if (n <= 0) {
                    if (n == 0 or !auth.wouldBlock(n)) {
                        // A failed next write must not discard an earlier
                        // response staged behind stdout backpressure.
                        disconnected = true;
                        input_eof = true;
                        outgoing = 0;
                        write_shutdown = true;
                    }
                } else {
                    outgoing_at += @intCast(n);
                    if (outgoing_at == outgoing) outgoing = 0;
                }
            }
            if (read_socket and fds[2].revents & (std.c.POLL.IN | std.c.POLL.HUP | std.c.POLL.ERR | std.c.POLL.NVAL) != 0) {
                const n = std.c.recv(c.fd, &inbound, inbound.len, 0);
                if (n == 0) socket_eof = true else if (n < 0) {
                    if (!auth.wouldBlock(n)) {
                        disconnected = true;
                        socket_eof = true;
                    }
                } else {
                    incoming = @intCast(n);
                    incoming_at = 0;
                }
            }
            if (fds[1].revents & std.c.POLL.OUT != 0 and incoming != 0) {
                const n = std.c.write(output.handle, inbound[incoming_at..incoming].ptr, incoming - incoming_at);
                if (n <= 0) {
                    if (n == 0 or !auth.wouldBlock(n)) return error.Disconnected;
                } else {
                    incoming_at += @intCast(n);
                    if (incoming_at == incoming) incoming = 0;
                }
            }
        }
    }
};
fn wait(fd: std.c.fd_t, events: i16) !void {
    var pollfds = [_]std.c.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    const rc = std.c.poll(&pollfds, 1, 5000);
    if (rc == 0) return error.DeadlineExceeded;
    if (rc < 0) return error.IoFailure;
    if (pollfds[0].revents & events == 0) return error.Disconnected;
}
/// Only the host can provide the approved recovered journal. Missing receipts
/// remain uncertain: this state machine has no resend action, even for absence.
pub const Reconnect = struct {
    state: enum { idle, write_in_flight, uncertain, resolved } = .idle,
    key: core.JournalKey = undefined,
    digest: core.Sha256 = undefined,
    key_bytes: [128]u8 = undefined,
    key_len: usize = 0,
    pub fn beginWrite(r: *Reconnect, key: core.JournalKey, digest: core.Sha256) !void {
        if (r.state != .idle and r.state != .resolved) return error.Busy;
        if (key.idempotency_key.len == 0 or key.idempotency_key.len > r.key_bytes.len) return error.InvalidArgument;
        r.key = key;
        r.key.idempotency_key = "";
        r.key_len = key.idempotency_key.len;
        @memcpy(r.key_bytes[0..r.key_len], key.idempotency_key);
        r.digest = digest;
        r.state = .write_in_flight;
    }
    pub fn disconnected(r: *Reconnect) void {
        if (r.state == .write_in_flight) r.state = .uncertain;
    }
    pub fn lookup(r: *Reconnect, store: core.JournalStore) !?core.Receipt {
        if (r.state != .uncertain) return error.InvalidArgument;
        var key = r.key;
        key.idempotency_key = r.key_bytes[0..r.key_len];
        return switch (try store.lookup(key)) {
            .found => |receipt| blk: {
                if (!std.mem.eql(u8, &receipt.op_digest, &r.digest)) return error.OutOfScope;
                r.state = .resolved;
                break :blk receipt;
            },
            .absent, .stored => null,
            .conflict => error.OutOfScope,
        };
    }
};

/// One ready input read, including the final POLLIN|POLLHUP bytes.
pub fn readReady(fd: std.c.fd_t, buffer: []u8, events: i16) !usize {
    if (events & (std.c.POLL.ERR | std.c.POLL.NVAL) != 0) return error.Disconnected;
    const n = std.c.read(fd, buffer.ptr, buffer.len);
    if (n < 0) {
        if (auth.wouldBlock(n)) return error.WouldBlock;
        return error.IoFailure;
    }
    return @intCast(n);
}
