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
    _ = @errorName(err);
    return .E_INTERNAL; // S02 RED placeholder
}

/// Default `retryable` flag for a code. Only queue and resource exhaustion is
/// retryable with bounded backoff; everything else needs a changed request, a
/// re-read, a host rebind or a receipt check first (docs/08 §3).
pub fn defaultRetryable(code: WireCode) bool {
    _ = code;
    return true; // S02 RED placeholder
}
