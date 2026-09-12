//! stdio record framing (T08; docs/08 §1, §8).
//!
//! One record is one UTF-8 JSON document followed by a newline. A record never
//! contains a raw newline, so `\n` ends it; newlines inside JSON strings are
//! escaped. `Framer` accepts input in any chunking, keeps a partial record in a
//! caller-owned buffer, and never grows: a record past the buffer or past the
//! raw frame limit is dropped as `too_large` and framing resyncs at the next
//! newline. `Writer` is the single stdout writer; it holds a lock for the whole
//! record so records from concurrent jobs never interleave, and a slow reader
//! blocks that writer instead of losing or mixing bytes.

const std = @import("std");
const core = @import("zcr_core");
const Io = std.Io;

pub const max_frame_bytes = core.limits.values.raw_frame_bytes;

pub const Framer = struct {
    buffer: []u8,
    len: usize = 0,
    /// The current record is past the buffer or the frame limit; drop it at its newline.
    skipping: bool = false,
    records: u64 = 0,
    oversize: u64 = 0,

    pub const Item = union(enum) { record: []const u8, too_large: u64 };

    pub fn init(buffer: []u8) Framer {
        return .{ .buffer = buffer };
    }

    /// Consumes bytes from `input` until one record ends; the record is valid until
    /// the next call. Returns null when `input` is exhausted.
    pub fn next(f: *Framer, input: *[]const u8) ?Item {
        while (input.len > 0) {
            const newline = std.mem.indexOfScalar(u8, input.*, '\n');
            const chunk = if (newline) |n| input.*[0..n] else input.*;
            const rest = if (newline) |n| input.*[n + 1 ..] else input.*[input.len..];
            input.* = rest;

            if (f.skipping) {
                if (newline == null) continue;
                f.skipping = false;
                f.oversize += 1;
                return .{ .too_large = f.oversize };
            }

            const too_big = f.len + chunk.len > f.buffer.len or f.len + chunk.len > max_frame_bytes;
            if (too_big) {
                f.len = 0;
                if (newline == null) {
                    f.skipping = true;
                    continue;
                }
                f.oversize += 1;
                return .{ .too_large = f.oversize };
            }

            @memcpy(f.buffer[f.len..][0..chunk.len], chunk);
            f.len += chunk.len;
            if (newline == null) continue;

            var record = f.buffer[0..f.len];
            f.len = 0;
            if (record.len > 0 and record[record.len - 1] == '\r') record = record[0 .. record.len - 1];
            if (record.len == 0) continue; // a blank line is not a record
            f.records += 1;
            return .{ .record = record };
        }
        return null;
    }

    pub fn pending(f: *const Framer) usize {
        return f.len;
    }
};

pub const Writer = struct {
    file: Io.File,
    mutex: Io.Mutex = .init,
    records: u64 = 0,
    bytes: u64 = 0,

    pub fn init(file: Io.File) Writer {
        return .{ .file = file };
    }

    /// Writes one record and its newline while holding the lock, so records never
    /// interleave. A record may not contain a newline of its own.
    pub fn writeRecord(w: *Writer, io: Io, record: []const u8) error{ IoFailure, InvalidArgument }!void {
        if (record.len == 0 or record.len > max_frame_bytes) return error.InvalidArgument;
        if (std.mem.indexOfScalar(u8, record, '\n') != null) return error.InvalidArgument;

        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        w.file.writeStreamingAll(io, record) catch return error.IoFailure;
        w.file.writeStreamingAll(io, "\n") catch return error.IoFailure;
        w.records += 1;
        w.bytes += record.len + 1;
    }
};
