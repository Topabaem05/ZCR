//! Error model (docs/02 §6, docs/08 §3).
//!
//! Internal error sets are grouped by category. Each member maps to exactly one
//! wire code from contracts/response.schema.json; `zig build verify-contracts`
//! checks that `WireCode` matches the schema enum in order.

const std = @import("std");

/// Wire error codes. Tag names are the exact strings in response.schema.json.
pub const WireCode = enum {
    E_INVALID_ARGUMENT,
    E_SCOPE,
    E_PATH_ESCAPE,
    E_UNSUPPORTED,
    E_NOT_FOUND,
    E_NOT_REGULAR,
    E_VERSION_CONFLICT,
    E_LEASE,
    E_FENCE,
    E_BUSY,
    E_RESOURCE,
    E_OUTPUT_BUDGET,
    E_CANCELLED,
    E_DEADLINE,
    E_IO,
    E_DURABILITY,
    E_RECOVERY_REQUIRED,
    E_INTERNAL,
};

/// Schema, range, UTF-8, overlap and unsupported-mode errors. Fix the input.
pub const ContractError = error{ InvalidArgument, Unsupported, ManifestUnbound };
/// Root, task or path authority refused.
pub const PermissionError = error{ OutOfScope, PathEscape };
/// Memory, FD, queue or output budget unavailable.
pub const ResourceError = error{ OutOfMemory, ResourceExhausted, Busy, OutputBudgetExceeded };
/// Stopped before a commit point.
pub const InterruptError = error{ Cancelled, DeadlineExceeded };
/// Content, lease or fence no longer matches what the caller holds.
pub const ConflictError = error{ VersionConflict, LeaseExpired, FenceMismatch };
/// Filesystem results and persistence failures.
pub const FileError = error{ NotFound, NotRegular, IoFailure, DurabilityFailed };
/// Commit state unknown or an internal invariant broke; the workspace is quarantined.
pub const IntegrityError = error{ RecoveryRequired, InvariantViolation };

pub const Error = ContractError || PermissionError || ResourceError || InterruptError ||
    ConflictError || FileError || IntegrityError;

pub const max_message_bytes = 4096;

/// Wire-level error object (`error` in the response envelope).
pub const ErrorInfo = struct {
    code: WireCode,
    message: []const u8,
    retryable: bool,
};

pub fn wireCode(err: Error) WireCode {
    return switch (err) {
        error.InvalidArgument => .E_INVALID_ARGUMENT,
        error.Unsupported => .E_UNSUPPORTED,
        // docs/06 names E_MANIFEST_UNBOUND, but response.schema.json has no such code.
        // Until the integrator changes the contract, an unbound manifest is a scope refusal.
        error.ManifestUnbound => .E_SCOPE,
        error.OutOfScope => .E_SCOPE,
        error.PathEscape => .E_PATH_ESCAPE,
        error.OutOfMemory, error.ResourceExhausted => .E_RESOURCE,
        error.Busy => .E_BUSY,
        error.OutputBudgetExceeded => .E_OUTPUT_BUDGET,
        error.Cancelled => .E_CANCELLED,
        error.DeadlineExceeded => .E_DEADLINE,
        error.VersionConflict => .E_VERSION_CONFLICT,
        error.LeaseExpired => .E_LEASE,
        error.FenceMismatch => .E_FENCE,
        error.NotFound => .E_NOT_FOUND,
        error.NotRegular => .E_NOT_REGULAR,
        error.IoFailure => .E_IO,
        error.DurabilityFailed => .E_DURABILITY,
        error.RecoveryRequired => .E_RECOVERY_REQUIRED,
        error.InvariantViolation => .E_INTERNAL,
    };
}

/// Default `retryable` flag for a code. Only queue and resource exhaustion is
/// retryable with bounded backoff; everything else needs a changed request, a
/// re-read, a host rebind or a receipt check first (docs/08 §3).
pub fn defaultRetryable(code: WireCode) bool {
    return switch (code) {
        .E_BUSY, .E_RESOURCE => true,
        else => false,
    };
}
