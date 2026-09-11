//! Scalar literal kernel (T06; docs/10, T19).
//!
//! The byte-span reference that accelerated kernels (T19) must reproduce
//! exactly: the leftmost occurrence of `needle` at or after `start`.

const std = @import("std");

pub fn find(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    return std.mem.indexOfPos(u8, haystack, start, needle);
}
