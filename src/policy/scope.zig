//! Task scope checks (T02, I01; docs/06 §6).
//!
//! Pure functions over the trusted policy snapshot. Matching is by whole path
//! component: `src` covers `src` and `src/x`, never `src2` or `srcx`. Deny wins:
//! immutable paths and anything named `.git` are never writable, whatever the
//! write list says. Filesystem aliases are handled by identity in capability.zig.

const std = @import("std");
const core = @import("zcr_core");

pub const Access = enum { read, write, none };

pub const ScopeError = error{ OutOfScope, ManifestUnbound };

pub fn accessFor(operation: core.Operation) Access {
    return switch (operation) {
        .read, .enumerate, .search, .batch_read => .read,
        .patch, .create => .write,
        .status, .health => .none,
    };
}

/// `prefix` covers `path` when they are equal or `path` continues with `/`.
/// An empty prefix or `.` covers every path.
pub fn covers(prefix: []const u8, path: []const u8) bool {
    const p = std.mem.trimEnd(u8, prefix, "/");
    if (p.len == 0 or std.mem.eql(u8, p, ".")) return true;
    if (!std.mem.startsWith(u8, path, p)) return false;
    return path.len == p.len or path[p.len] == '/';
}

pub fn coveredByAny(list: []const core.RelativePath, path: []const u8) bool {
    for (list) |prefix| {
        if (covers(prefix.bytes, path)) return true;
    }
    return false;
}

/// True when any component is `.git` in any ASCII case (case-insensitive volumes alias it).
pub fn namesGitMetadata(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.ascii.eqlIgnoreCase(component, ".git")) return true;
    }
    return false;
}

/// Only an active manifest authorizes. Planned or ready manifests are unbound;
/// completed or revoked ones no longer carry authority.
pub fn checkState(state: core.ManifestState) ScopeError!void {
    return switch (state) {
        .active => {},
        .planned, .ready => error.ManifestUnbound,
        .completed, .revoked => error.OutOfScope,
    };
}

pub fn allowsOperation(policy: *const core.Policy, operation: core.Operation) bool {
    return std.mem.indexOfScalar(core.Operation, policy.operations, operation) != null;
}

pub fn check(policy: *const core.Policy, operation: core.Operation, path: []const u8) ScopeError!void {
    try checkState(policy.state);
    if (!allowsOperation(policy, operation)) return error.OutOfScope;
    switch (accessFor(operation)) {
        .none => {},
        .read => {
            if (namesGitMetadata(path) or !coveredByAny(policy.read_paths, path)) return error.OutOfScope;
        },
        .write => {
            if (namesGitMetadata(path) or
                !coveredByAny(policy.write_paths, path) or
                coveredByAny(policy.immutable_paths, path)) return error.OutOfScope;
        },
    }
}
