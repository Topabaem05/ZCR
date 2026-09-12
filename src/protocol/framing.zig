//! stdio record framing (T08; docs/08 §1, §8).
//!
//! S02 stub: the API the tests use, with no behaviour yet.

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
        _ = f;
        _ = input;
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

    /// Writes one record and its newline as one locked write, so records never interleave.
    pub fn writeRecord(w: *Writer, io: Io, record: []const u8) error{ IoFailure, InvalidArgument }!void {
        _ = w;
        _ = io;
        _ = record;
        return error.IoFailure;
    }
};
