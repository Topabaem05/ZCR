//! Git ignore rules (T05; gitignore(5)).
//!
//! Supported: blank and `#` comment lines, `\#` and `\!` escapes, trailing
//! spaces unless escaped with `\`, `!` negation, trailing `/` for directories,
//! patterns anchored to their .gitignore when they contain `/`, and wildmatch
//! with `*`, `?`, bracket expressions (ranges, `!`/`^` negation, POSIX classes)
//! and `\` escapes, none of which match `/`. A whole `**` segment matches any
//! number of path segments; `**` as the last segment matches at least one.
//! Matching is byte-wise and case-sensitive (core.ignorecase is not applied).
//! Later rules win; deeper .gitignore files are pushed after their parents.
//!
//! Matching needs no allocation and is bounded: segments are matched with a
//! single-star backtracking scan, and `**` segments with the same scan over
//! segments, so time is O(pattern × text) per rule.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pattern = struct {
    /// Pattern body without `!`, leading `/` or trailing `/`; escapes kept.
    text: []const u8,
    negative: bool,
    must_be_dir: bool,
    /// Contains `/`: matched against the path relative to the .gitignore directory.
    /// Otherwise matched against the basename at any depth below it.
    anchored: bool,
};

/// Parses one .gitignore line; null for blank and comment lines.
pub fn parseLine(raw: []const u8) ?Pattern {
    var line = raw;
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    while (line.len > 0 and line[line.len - 1] == ' ') {
        if (line.len >= 2 and line[line.len - 2] == '\\') break;
        line = line[0 .. line.len - 1];
    }
    if (line.len == 0 or line[0] == '#') return null;

    var negative = false;
    if (line[0] == '!') {
        negative = true;
        line = line[1..];
    } else if (line.len >= 2 and line[0] == '\\' and (line[1] == '#' or line[1] == '!')) {
        line = line[1..];
    }
    var must_be_dir = false;
    if (line.len > 0 and line[line.len - 1] == '/') {
        must_be_dir = true;
        line = line[0 .. line.len - 1];
    }
    if (line.len == 0) return null;
    const anchored = std.mem.indexOfScalar(u8, line, '/') != null;
    if (line[0] == '/') line = line[1..];
    if (line.len == 0) return null;
    return .{ .text = line, .negative = negative, .must_be_dir = must_be_dir, .anchored = anchored };
}

/// Pathname wildmatch of `pattern` against `text` (both `/`-separated).
pub fn wildmatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0; // start of the current pattern segment; pattern.len + 1 means consumed
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (true) {
        const pattern_done = pi > pattern.len;
        const text_done = ti > text.len;
        if (!pattern_done) {
            const ps = segment(pattern, pi);
            if (std.mem.eql(u8, ps.bytes, "**")) {
                // A trailing `**` matches everything below, but at least one segment.
                if (ps.next > pattern.len) return !text_done;
                star_pi = ps.next;
                star_ti = ti;
                pi = ps.next;
                continue;
            }
            if (!text_done) {
                const ts = segment(text, ti);
                if (segmentMatch(ps.bytes, ts.bytes)) {
                    pi = ps.next;
                    ti = ts.next;
                    continue;
                }
            }
        } else if (text_done) {
            return true;
        }
        const restart = star_pi orelse return false;
        if (star_ti > text.len) return false;
        star_ti = segment(text, star_ti).next;
        ti = star_ti;
        pi = restart;
    }
}

const Segment = struct { bytes: []const u8, next: usize };

fn segment(s: []const u8, start: usize) Segment {
    const end = std.mem.indexOfScalarPos(u8, s, start, '/') orelse s.len;
    return .{ .bytes = s[start..end], .next = end + 1 };
}

/// One path segment: `*`, `?`, brackets and escapes; `**` inside a segment acts as `*`.
fn segmentMatch(p: []const u8, t: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star: ?usize = null;
    var star_t: usize = 0;
    while (ti < t.len) {
        if (pi < p.len) {
            switch (p[pi]) {
                '*' => {
                    while (pi < p.len and p[pi] == '*') pi += 1;
                    star = pi;
                    star_t = ti;
                    continue;
                },
                '?' => {
                    pi += 1;
                    ti += 1;
                    continue;
                },
                '[' => if (bracket(p, pi, t[ti])) |result| {
                    if (result.matched) {
                        pi = result.end;
                        ti += 1;
                        continue;
                    }
                },
                '\\' => if (pi + 1 < p.len and p[pi + 1] == t[ti]) {
                    pi += 2;
                    ti += 1;
                    continue;
                },
                else => if (p[pi] == t[ti]) {
                    pi += 1;
                    ti += 1;
                    continue;
                },
            }
        }
        const restart = star orelse return false;
        star_t += 1;
        ti = star_t;
        pi = restart;
    }
    while (pi < p.len and p[pi] == '*') pi += 1;
    return pi == p.len;
}

const BracketResult = struct { matched: bool, end: usize };

/// Evaluates the bracket expression starting at `p[start] == '['` for byte `c`.
/// Null when the expression is not terminated (it then matches nothing).
fn bracket(p: []const u8, start: usize, c: u8) ?BracketResult {
    var i = start + 1;
    var negate = false;
    if (i < p.len and (p[i] == '!' or p[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < p.len) {
        if (p[i] == ']' and !first) return .{ .matched = matched != negate, .end = i + 1 };
        first = false;
        if (p[i] == '[' and i + 1 < p.len and p[i + 1] == ':') {
            const close = std.mem.indexOfPos(u8, p, i + 2, ":]") orelse return null;
            if (classMatch(p[i + 2 .. close], c)) matched = true;
            i = close + 2;
            continue;
        }
        var low = p[i];
        if (low == '\\' and i + 1 < p.len) {
            i += 1;
            low = p[i];
        }
        i += 1;
        if (i + 1 < p.len and p[i] == '-' and p[i + 1] != ']') {
            var high = p[i + 1];
            i += 2;
            if (high == '\\' and i < p.len) {
                high = p[i];
                i += 1;
            }
            if (c >= low and c <= high) matched = true;
        } else if (c == low) {
            matched = true;
        }
    }
    return null;
}

fn classMatch(name: []const u8, c: u8) bool {
    const classes = [_]struct { name: []const u8, test_fn: *const fn (u8) bool }{
        .{ .name = "alnum", .test_fn = std.ascii.isAlphanumeric },
        .{ .name = "alpha", .test_fn = std.ascii.isAlphabetic },
        .{ .name = "blank", .test_fn = isBlank },
        .{ .name = "cntrl", .test_fn = std.ascii.isControl },
        .{ .name = "digit", .test_fn = std.ascii.isDigit },
        .{ .name = "graph", .test_fn = isGraph },
        .{ .name = "lower", .test_fn = std.ascii.isLower },
        .{ .name = "print", .test_fn = std.ascii.isPrint },
        .{ .name = "punct", .test_fn = isPunct },
        .{ .name = "space", .test_fn = std.ascii.isWhitespace },
        .{ .name = "upper", .test_fn = std.ascii.isUpper },
        .{ .name = "xdigit", .test_fn = std.ascii.isHex },
    };
    for (classes) |class| {
        if (std.mem.eql(u8, class.name, name)) return class.test_fn(c);
    }
    return false;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isGraph(c: u8) bool {
    return c > ' ' and c < 0x7f;
}

fn isPunct(c: u8) bool {
    return isGraph(c) and !std.ascii.isAlphanumeric(c);
}

pub const Rule = struct {
    pattern: Pattern,
    base_offset: u32,
    base_len: u32,
};

/// Rules of the .gitignore files on the current path, as a stack with fixed capacity.
pub const RuleStack = struct {
    allocator: Allocator,
    rules: []Rule,
    len: u32 = 0,
    pool: []u8,
    pool_len: usize = 0,

    pub const Mark = struct { rules: u32, pool: usize };
    pub const PushError = error{ TooManyRules, PoolFull };

    pub fn init(allocator: Allocator, max_rules: u32, pool_bytes: usize) Allocator.Error!RuleStack {
        const rules = try allocator.alloc(Rule, max_rules);
        errdefer allocator.free(rules);
        return .{ .allocator = allocator, .rules = rules, .pool = try allocator.alloc(u8, pool_bytes) };
    }

    pub fn deinit(self: *RuleStack) void {
        self.allocator.free(self.pool);
        self.allocator.free(self.rules);
    }

    pub fn mark(self: *const RuleStack) Mark {
        return .{ .rules = self.len, .pool = self.pool_len };
    }

    pub fn restore(self: *RuleStack, m: Mark) void {
        self.len = m.rules;
        self.pool_len = m.pool;
    }

    /// Adds the rules of one ignore file whose directory is `base` ("" for the root).
    /// All or nothing: on error the stack is unchanged.
    pub fn pushFile(self: *RuleStack, base: []const u8, contents: []const u8) PushError!void {
        const start = self.mark();
        errdefer self.restore(start);
        const base_offset = try self.copy(base);
        const text = self.pool[try self.copy(contents)..][0..contents.len];

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const pattern = parseLine(line) orelse continue;
            if (self.len == self.rules.len) return error.TooManyRules;
            self.rules[self.len] = .{ .pattern = pattern, .base_offset = @intCast(base_offset), .base_len = @intCast(base.len) };
            self.len += 1;
        }
    }

    fn copy(self: *RuleStack, bytes: []const u8) PushError!usize {
        if (self.pool.len - self.pool_len < bytes.len) return error.PoolFull;
        const offset = self.pool_len;
        @memcpy(self.pool[offset..][0..bytes.len], bytes);
        self.pool_len += bytes.len;
        return offset;
    }

    /// Whether `path` (root-relative) is excluded by the rules on the stack. Parent
    /// directories are not checked here: a traversal never enters an excluded directory.
    pub fn isIgnored(self: *const RuleStack, path: []const u8, is_dir: bool) bool {
        var i = self.len;
        while (i > 0) {
            i -= 1;
            const rule = self.rules[i];
            if (rule.pattern.must_be_dir and !is_dir) continue;
            const base = self.pool[rule.base_offset..][0..rule.base_len];
            const relative = if (base.len == 0) path else blk: {
                if (path.len <= base.len or !std.mem.startsWith(u8, path, base) or path[base.len] != '/') continue;
                break :blk path[base.len + 1 ..];
            };
            const subject = if (rule.pattern.anchored) relative else std.fs.path.basenamePosix(relative);
            if (wildmatch(rule.pattern.text, subject)) return !rule.pattern.negative;
        }
        return false;
    }
};
