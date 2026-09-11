//! File metadata snapshots (T04). S02 RED stub.

const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");

pub const Snapshot = struct { identity: policy.paths.Identity, size: u64, mtime_ns: i128 };
