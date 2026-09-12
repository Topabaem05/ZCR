//! Newline-delimited UTF-8 JSON; a frame owns no memory beyond caller credit.
const std = @import("std");
pub const max_frame_bytes = 16 * 1024 * 1024;
pub const Decoder = struct {
    buffer: []u8,
    len: usize = 0,
    dropping: bool = false,
    pub const Event = union(enum) { none, frame: []const u8, oversized };
    pub fn init(credited_buffer: []u8) Decoder {
        std.debug.assert(credited_buffer.len >= max_frame_bytes);
        return .{ .buffer = credited_buffer[0..max_frame_bytes] };
    }
    /// The frame slice stays valid until the next call. Oversize records are
    /// drained through their delimiter so one malformed record cannot desync.
    pub fn push(self: *Decoder, byte: u8) Event {
        if (byte == '\n') {
            if (self.dropping) {
                self.dropping = false;
                self.len = 0;
                return .oversized;
            }
            const frame = self.buffer[0..self.len];
            self.len = 0;
            return .{ .frame = frame };
        }
        if (self.dropping) return .none;
        if (self.len == self.buffer.len) {
            self.dropping = true;
            self.len = 0;
            return .none;
        }
        self.buffer[self.len] = byte;
        self.len += 1;
        return .none;
    }
    pub fn finish(self: *Decoder) error{TruncatedFrame}!void {
        if (self.dropping or self.len != 0) return error.TruncatedFrame;
    }
};

/// The only stdout record writer. A dedicated owner calls this method; it
/// writes the delimiter in the same critical section as all message bytes.
pub const RecordWriter = struct {
    io: std.Io,
    output: std.Io.File,
    lock: std.Io.Mutex = .init,
    pub fn write(self: *RecordWriter, record: []const u8) !void {
        if (std.mem.indexOfScalar(u8, record, '\n') != null) return error.InvalidRecord;
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        try self.output.writeStreamingAll(self.io, record);
        try self.output.writeStreamingAll(self.io, "\n");
    }
};
