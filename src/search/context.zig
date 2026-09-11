//! Context intervals and projection (T06; docs/07 §3).
//!
//! Each match asks for lines `[line - c, line + c]`. Windows that overlap or
//! touch are merged, so a line is returned once even when several matches need
//! it. Projection re-reads each merged interval from the file into one text
//! buffer, splits it into lines, and checks that every match still lies inside
//! its line with the literal bytes in place; anything else means the file changed
//! between scan and projection. When the output budget or the line capacity runs
//! out, only complete lines are kept and matches beyond them are dropped.

const std = @import("std");
const core = @import("zcr_core");
const Io = std.Io;

pub const max_context_lines = 20;

/// A match found by the scan, with the first line and byte offset of its context window.
pub const FileMatch = struct {
    start: u64,
    end: u64,
    line: u32,
    window_first: u32,
    window_start: u64,
};

pub const Interval = struct {
    first_line: u32,
    last_line: u32,
    start_offset: u64,
    match_begin: u32,
    match_end: u32,
};

/// Builds merged intervals from matches in offset order; returns how many were written.
pub fn buildIntervals(matches: []const FileMatch, context_lines: u32, out: []Interval) usize {
    var len: usize = 0;
    for (matches, 0..) |m, i| {
        const last = m.line +| context_lines;
        if (len > 0 and m.window_first <= out[len - 1].last_line +| 1) {
            out[len - 1].last_line = @max(out[len - 1].last_line, last);
            out[len - 1].match_end = @intCast(i + 1);
            continue;
        }
        out[len] = .{ .first_line = m.window_first, .last_line = last, .start_offset = m.window_start, .match_begin = @intCast(i), .match_end = @intCast(i + 1) };
        len += 1;
    }
    return len;
}

pub const Projection = struct {
    lines: usize = 0,
    text: usize = 0,
    matches: usize = 0,
    truncated: bool = false,
    changed: bool = false,
};

const read_step = 64 * 1024;

/// `reader` provides `fn readAt(reader, io, file, buffer, offset) error{IoFailure}!usize`.
pub fn project(
    io: Io,
    file: Io.File,
    reader: anytype,
    literal: []const u8,
    matches: []const FileMatch,
    intervals: []const Interval,
    budget: u64,
    lines_out: []core.Line,
    text_out: []u8,
    results_out: []core.SearchMatch,
) error{IoFailure}!Projection {
    var p: Projection = .{};
    const text_cap: usize = @intCast(@min(budget, text_out.len));

    for (intervals) |iv| {
        const seg_start = p.text;
        const need: u32 = iv.last_line - iv.first_line + 1;
        var filled = seg_start;
        var scan_from = seg_start;
        var complete_lines: u32 = 0;
        var eof = false;
        var out_of_room = false;

        while (complete_lines < need) {
            if (filled >= text_cap) {
                out_of_room = true;
                break;
            }
            const want = @min(text_cap - filled, read_step);
            const n = try reader.readAt(io, file, text_out[filled..][0..want], iv.start_offset + (filled - seg_start));
            if (n == 0) {
                eof = true;
                break;
            }
            filled += n;
            while (complete_lines < need) {
                const newline = std.mem.indexOfScalarPos(u8, text_out[0..filled], scan_from, '\n') orelse {
                    scan_from = filled;
                    break;
                };
                complete_lines += 1;
                scan_from = newline + 1;
            }
        }

        // Lines kept for this interval: complete lines, plus an unterminated last line at EOF.
        var end = seg_start + lineBytes(text_out[seg_start..filled], complete_lines);
        var kept_lines = complete_lines;
        if (eof and complete_lines < need and filled > end) {
            end = filled;
            kept_lines += 1;
        }
        if (out_of_room and complete_lines < need) p.truncated = true;

        // Split into line records.
        var offset = iv.start_offset;
        var cursor = seg_start;
        var recorded: u32 = 0;
        while (recorded < kept_lines) : (recorded += 1) {
            if (p.lines == lines_out.len) {
                p.truncated = true;
                break;
            }
            const line_end = if (std.mem.indexOfScalarPos(u8, text_out[0..end], cursor, '\n')) |nl| nl + 1 else end;
            const len = line_end - cursor;
            lines_out[p.lines] = .{
                .number = iv.first_line + recorded,
                .span = .{ .start = offset, .end = offset + len },
                .text = text_out[cursor..line_end],
            };
            p.lines += 1;
            offset += len;
            cursor = line_end;
        }
        const first_record = p.lines - recorded;

        for (matches[iv.match_begin..iv.match_end]) |m| {
            if (recorded == 0 or m.line >= iv.first_line + recorded) {
                // Budget or capacity ran out before this match's line; a shorter file means a change.
                if (!p.truncated) p.changed = true;
                p.text = cursor;
                return p;
            }
            const line = lines_out[first_record + (m.line - iv.first_line)];
            if (m.start < line.span.start or m.end > line.span.end) {
                p.changed = true;
                return p;
            }
            const at: usize = @intCast(m.start - line.span.start);
            if (!std.mem.eql(u8, line.text[at..][0..literal.len], literal)) {
                p.changed = true;
                return p;
            }
            results_out[p.matches] = .{ .span = .{ .start = m.start, .end = m.end }, .line = m.line };
            p.matches += 1;
        }
        p.text = cursor;
        if (p.truncated) return p;
    }
    return p;
}

/// Bytes of the first `count` complete lines in `bytes`.
fn lineBytes(bytes: []const u8, count: u32) usize {
    var seen: u32 = 0;
    var index: usize = 0;
    while (seen < count) : (seen += 1) {
        index = (std.mem.indexOfScalarPos(u8, bytes, index, '\n') orelse return index) + 1;
    }
    return index;
}
