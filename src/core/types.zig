//! Frozen public types and interface signatures (docs/17, protocol zcr/1).
//!
//! This file is the root of the `zcr_core` module. Adding or changing a public
//! field, error set or signature is a contract change owned by the integrator;
//! tasks do not declare their own public variants of these concepts. Private
//! implementation structs stay inside their modules.
//!
//! Ownership notation from docs/17 maps to Zig as follows: `Borrow<T>` is a
//! plain slice or pointer valid only for the synchronous call, `Owned<T>` is
//! `Owned(T)` below, and `Result<T,E>` is an error union.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const errors = @import("errors.zig");
pub const limits = @import("limits.zig");

pub const schema_version = "zcr/1";

// ------------------------------------------------------------------ identifiers

pub const Uuid = [16]u8;
pub const Sha256 = [32]u8;
pub const ContentHash = Sha256;
pub const PolicyDigest = Sha256;
pub const FenceToken = u64;
pub const RequestId = u64;

/// Filesystem identity of a file or directory (device + inode or platform equivalent).
pub const FileId = struct { device: u64, inode: u64 };

/// Approved git-common-dir identity plus registry UUID. Never a repository name.
pub const RepoId = struct { common_dir: FileId, registry_uuid: Uuid };

/// Root handle identity, per-worktree git-dir identity and incarnation. Never HEAD alone.
pub const WorkspaceId = struct {
    registry_uuid: Uuid,
    incarnation: Uuid,

    pub fn eql(a: WorkspaceId, b: WorkspaceId) bool {
        return std.mem.eql(u8, &a.registry_uuid, &b.registry_uuid) and std.mem.eql(u8, &a.incarnation, &b.incarnation);
    }
};

/// Issued by the operator or host, never chosen by the model.
pub const TaskId = struct { uuid: Uuid };
/// Created at handshake and bound to a task and workspace.
pub const SessionId = struct { uuid: Uuid };
pub const ReceiptId = struct { uuid: Uuid };
pub const SecurityDomain = struct { id: u64 };
pub const CapabilityHandle = enum(u64) { none = 0, _ };

// ------------------------------------------------------------------ enums shared with contracts/

/// Task manifest `operations` (contracts/task-manifest.schema.json).
pub const Operation = enum { read, enumerate, search, batch_read, patch, create, status, health };

/// Manifest `state`.
pub const ManifestState = enum { planned, ready, active, completed, revoked };

/// The eight tools in contracts/tools.json, in order.
pub const ToolName = enum {
    zcr_read,
    zcr_files,
    zcr_search,
    zcr_batch_read,
    zcr_patch,
    zcr_create,
    zcr_status,
    zcr_health,

    pub fn operation(tool: ToolName) Operation {
        return switch (tool) {
            .zcr_read => .read,
            .zcr_files => .enumerate,
            .zcr_search => .search,
            .zcr_batch_read => .batch_read,
            .zcr_patch => .patch,
            .zcr_create => .create,
            .zcr_status => .status,
            .zcr_health => .health,
        };
    }
};

/// Response envelope `consistency`.
pub const Consistency = enum { checked_live, managed_generation, bounded_stale, immutable_snapshot, not_applicable };
/// Consistency a v1 request may ask for; `immutable_snapshot` is internal (E_UNSUPPORTED).
pub const RequestConsistency = enum { checked_live, managed_generation, bounded_stale };
/// `coverage.index_state`.
pub const IndexState = enum { live, managed, stale, uncertain, not_applicable };
/// `meta.cache`.
pub const CacheResult = enum { hit, partial, miss, not_applicable };
pub const Order = enum { discovery, path_then_offset };
pub const Durability = enum { process, durable, strongest_available };
/// `status.write_mode`.
pub const WriteMode = enum { read_only, dedicated_managed, proposal_only };
/// `health.pressure`.
pub const Pressure = enum { normal, soft, warning, critical, recovery, unknown };
pub const OutputProfile = enum { text_v1 };

/// Internal scheduling class (docs/04 §3). Mapping to OS QoS belongs to the scheduler.
pub const QosIntent = enum { fg_short, fg_bulk, maintenance, idle };
pub const ThermalState = enum { nominal, fair, serious, critical, unknown };

// ------------------------------------------------------------------ value types

/// Root-relative UTF-8 path. `init` performs syntactic checks only; authorization,
/// symlink resolution and escape checks belong to I01 (T02).
pub const RelativePath = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) error{InvalidArgument}!RelativePath {
        if (bytes.len == 0 or bytes.len > limits.values.path_max_utf8_bytes) return error.InvalidArgument;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidArgument;
        if (bytes[0] == '/' or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidArgument;
        var components = std.mem.splitScalar(u8, bytes, '/');
        while (components.next()) |component| {
            if (std.mem.eql(u8, component, "..")) return error.InvalidArgument;
        }
        return .{ .bytes = bytes };
    }
};

/// Half-open byte range `[start, end)`.
pub const ByteSpan = struct {
    start: u64,
    end: u64,

    pub fn init(start: u64, end: u64) error{InvalidArgument}!ByteSpan {
        if (start > end) return error.InvalidArgument;
        return .{ .start = start, .end = end };
    }

    pub fn len(span: ByteSpan) u64 {
        return span.end - span.start;
    }
};

/// 1-based line range.
pub const LineRange = struct {
    first: u32,
    count: u32,

    pub fn init(first: u32, count: u32) error{InvalidArgument}!LineRange {
        if (first == 0 or count == 0 or count > limits.values.max_read_lines) return error.InvalidArgument;
        _ = std.math.add(u32, first, count - 1) catch return error.InvalidArgument;
        return .{ .first = first, .count = count };
    }
};

pub const SessionContext = struct {
    session_id: SessionId,
    security_domain: SecurityDomain,
    policy_digest: PolicyDigest,
    bound_workspace: WorkspaceId,
    bound_task: TaskId,
    capability_handle: CapabilityHandle,
};

pub const TaskContext = struct {
    task_id: TaskId,
    /// Lowercase hex Git object id (40 or 64 characters).
    base_commit: ?[]const u8,
    scope_digest: Sha256,
    fence: FenceToken,
    expires_at_unix_ms: i64,
};

pub const FileVersion = struct {
    workspace_id: WorkspaceId,
    file_id: FileId,
    generation: u64,
    size: u64,
    mtime_ns: i128,
    /// Whole-file digest; null unless computed for the whole file.
    sha256: ?ContentHash,
};

/// Immutable authority for one operation on one path. Cannot widen the root.
pub const Capability = struct {
    handle: CapabilityHandle,
    operation: Operation,
    workspace_id: WorkspaceId,
    task_id: TaskId,
    policy_digest: PolicyDigest,
    path: RelativePath,
};

/// Worst-case bytes and handles an operation needs before it allocates (INV-03).
pub const ResourceCost = struct {
    input_bytes: u64 = 0,
    scratch_bytes: u64 = 0,
    output_bytes: u64 = 0,
    write_temp_bytes: u64 = 0,
    parser_bytes: u64 = 0,
    journal_bytes: u64 = 0,
    fds: u16 = 0,
    cpu_permits: u8 = 0,

    /// Sum of all byte fields; overflow is an invalid request, not a wrap.
    pub fn totalBytes(cost: ResourceCost) error{InvalidArgument}!u64 {
        var total: u64 = 0;
        for ([_]u64{ cost.input_bytes, cost.scratch_bytes, cost.output_bytes, cost.write_temp_bytes, cost.parser_bytes, cost.journal_bytes }) |bytes| {
            total = std.math.add(u64, total, bytes) catch return error.InvalidArgument;
        }
        return total;
    }
};

/// Move-only budget grant. Copy it only through `take`, which leaves the source released.
pub const Reservation = struct {
    budget_id: u32,
    bytes: u64,
    fd: u16,
    cpu: u8,
    output: u64,
    released: bool = false,

    pub fn take(r: *Reservation) Reservation {
        const moved = r.*;
        r.* = .{ .budget_id = r.budget_id, .bytes = 0, .fd = 0, .cpu = 0, .output = 0, .released = true };
        return moved;
    }
};

/// Cooperative cancellation. `requested` outlives every job that holds it.
pub const Cancel = struct {
    requested: *const std.atomic.Value(bool),

    pub fn isRequested(c: Cancel) bool {
        return c.requested.load(.acquire);
    }
};

/// Heap-owned job. After a successful submit the executor owns it until the callback returns.
pub const JobEnvelope = struct {
    request_id: RequestId,
    context: SessionContext,
    cancel: Cancel,
    scratch_reservation: Reservation,
    callback: *const fn (job: *JobEnvelope) void,
    qos_intent: QosIntent,
    userdata: ?*anyopaque = null,
};

pub const JobHandle = struct { id: u64 };

pub const Receipt = struct {
    id: ReceiptId,
    idempotency_key: []const u8,
    op_digest: Sha256,
    applied: bool,
    durable: bool,
    cancellation_observed: bool,
    old_hash: ?ContentHash,
    new_hash: ?ContentHash,
    generation: u64,
    error_code: ?errors.WireCode,
};

// ------------------------------------------------------------------ request / result types

pub const Coverage = struct {
    scope: []const u8,
    skipped: u64,
    index_state: IndexState,
    reasons: []const []const u8 = &.{},
};

/// Envelope flags that must never be adjusted to look faster (INV-07).
pub const ResultStatus = struct {
    complete: bool,
    truncated: bool,
    consistency: Consistency,
    coverage: Coverage,
};

pub const ReadSpec = struct {
    path: RelativePath,
    lines: LineRange,
    write_intent: bool = false,
    consistency: RequestConsistency = .checked_live,
    output_bytes: u64 = limits.values.default_output_bytes,
    deadline_ms: u32 = limits.values.default_deadline_ms,
};

pub const Line = struct { number: u32, span: ByteSpan, text: []const u8 };

pub const ReadResult = struct {
    path: RelativePath,
    lines: []const Line,
    version: FileVersion,
    status: ResultStatus,
};

pub const FileSpec = struct {
    glob: []const u8 = "**/*",
    limit: u32 = 1000,
    include_hidden: bool = false,
    order: Order = .discovery,
    consistency: RequestConsistency = .checked_live,
    max_stale_ms: u32 = 0,
};

pub const SearchSpec = struct {
    literal: []const u8,
    glob: []const u8 = "**/*",
    context_lines: u8 = 2,
    limit: u32 = limits.values.default_search_matches,
    max_file_bytes: u64 = limits.values.default_search_file_bytes,
    include_hidden: bool = false,
    order: Order = .discovery,
    consistency: RequestConsistency = .checked_live,
    max_stale_ms: u32 = 0,
};

pub const SearchMatch = struct { span: ByteSpan, line: u32 };

pub const SearchFileResult = struct {
    path: RelativePath,
    matches: []const SearchMatch,
    context: []const Line,
    version: FileVersion,
};

pub const SinkError = error{ Busy, OutputBudgetExceeded, Cancelled };

/// Streaming consumer with backpressure. `push` may fail to stop the producer.
pub fn Sink(comptime Item: type) type {
    return struct {
        context: *anyopaque,
        push_fn: *const fn (context: *anyopaque, item: Item) SinkError!void,

        pub fn push(sink: @This(), item: Item) SinkError!void {
            return sink.push_fn(sink.context, item);
        }
    };
}

pub const BatchReadItem = struct { item_id: []const u8, spec: ReadSpec };
pub const BatchItemResult = union(enum) { ok: ReadResult, err: errors.ErrorInfo };
pub const BatchItem = struct { item_id: []const u8, result: BatchItemResult };
pub const BatchResult = struct { items: []const BatchItem, status: ResultStatus };

pub const TrustedRoot = struct { dir: Io.Dir, canonical_path: []const u8 };

/// Git locations from trusted discovery (T10), as canonical absolute paths.
/// Both are protected from writes even when they sit outside the root.
pub const GitMetadata = struct {
    /// Per-worktree git dir (`git rev-parse --absolute-git-dir`); null outside Git.
    git_dir: ?[]const u8,
    /// Shared git dir (`git rev-parse --path-format=absolute --git-common-dir`).
    common_dir: ?[]const u8,
};

/// Approved, immutable policy snapshot. Scope changes issue a new policy.
pub const Policy = struct {
    digest: PolicyDigest,
    state: ManifestState,
    read_paths: []const RelativePath,
    write_paths: []const RelativePath,
    immutable_paths: []const RelativePath,
    operations: []const Operation,
    max_changed_files: u32,
};

pub const WriterLease = struct {
    workspace_id: WorkspaceId,
    task_id: TaskId,
    fence: FenceToken,
    expires_at_monotonic_ns: u64,
};

pub const Replacement = struct { span: ByteSpan, text: []const u8 };

pub const PatchSpec = struct {
    path: RelativePath,
    expected_sha256: ContentHash,
    replacements: []const Replacement,
    idempotency_key: []const u8,
    durability: Durability = .process,
};

pub const CreateSpec = struct {
    path: RelativePath,
    content: []const u8,
    idempotency_key: []const u8,
    durability: Durability = .process,
};

pub const JournalState = enum { prepared, applied, committed, aborted, uncertain };

/// docs/08 §4: (security_domain, workspace_incarnation, task_id, idempotency_key).
pub const JournalKey = struct {
    security_domain: SecurityDomain,
    workspace_incarnation: Uuid,
    task_id: TaskId,
    idempotency_key: []const u8,
};

pub const PreparedRecord = struct {
    key: JournalKey,
    op_digest: Sha256,
    path: RelativePath,
    old_hash: ?ContentHash,
    new_hash: ContentHash,
    generation: u64,
};

pub const JournalResult = union(enum) {
    absent,
    stored,
    found: Receipt,
    /// Same key, different operation digest: reject, never re-run.
    conflict: Sha256,
};

pub const JournalError = errors.ContractError || errors.FileError || errors.IntegrityError || errors.ResourceError;

/// I19. Versioned, checksummed persistence behind a vtable so T11 can test with a fake store.
pub const JournalStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        prepare: *const fn (context: *anyopaque, record: PreparedRecord) JournalError!JournalResult,
        record: *const fn (context: *anyopaque, receipt: Receipt) JournalError!JournalResult,
        lookup: *const fn (context: *anyopaque, key: JournalKey) JournalError!JournalResult,
    };

    pub fn prepare(store: JournalStore, record_: PreparedRecord) JournalError!JournalResult {
        return store.vtable.prepare(store.context, record_);
    }

    pub fn record(store: JournalStore, receipt: Receipt) JournalError!JournalResult {
        return store.vtable.record(store.context, receipt);
    }

    pub fn lookup(store: JournalStore, key: JournalKey) JournalError!JournalResult {
        return store.vtable.lookup(store.context, key);
    }
};

pub const RecoveryReport = struct {
    workspace_id: WorkspaceId,
    committed: u32,
    aborted: u32,
    uncertain: u32,
    quarantined_paths: []const RelativePath,
};

pub const PinBudget = struct { max_pinned_bytes: u64 };

/// Must be unpinned by the holder.
pub const PinnedEntry = struct { hash: ContentHash, bytes: []const u8, pin_id: u64 };

pub const WatchEventKind = enum { created, modified, removed, renamed, overflow, dropped, root_changed, cursor_wrapped };
pub const WatchEvent = struct { kind: WatchEventKind, path: ?RelativePath, cursor: u64 };

pub const ResourceSignals = struct {
    memory_pressure: Pressure,
    thermal_state: ThermalState,
    low_power_mode: ?bool,
    tracked_live_bytes: u64,
    model_active: bool = false,
    model_reserve_mib: ?u32 = null,
    decode_baseline_tok_s: ?f64 = null,
    decode_current_tok_s: ?f64 = null,
};

/// Never above the hard caps in `limits`.
pub const AdmissionLimits = struct {
    cpu_permits: u32,
    io_permits: u32,
    tracked_limit_bytes: u64,
    cache_target_bytes: u64,
    bulk_admission: bool,
    speculative_work: bool,
};

pub const ParserSpec = struct { language: []const u8, grammar_digest: Sha256, options_digest: Sha256 };
pub const OutlineKind = enum { function, method, type, module, other };
pub const OutlineCandidate = struct { kind: OutlineKind, name: []const u8, span: ByteSpan };

/// Syntax candidates only; never reported as exact references (INV-08).
pub const OutlineCandidates = struct { items: []const OutlineCandidate };

pub const HealthSnapshot = struct {
    build_version: []const u8,
    backend: []const u8,
    capabilities: []const Operation,
    tracked_limit_bytes: u64,
    tracked_live_bytes: u64,
    pressure: Pressure,
    usable_cpu_permits: u32,
};

/// Opaque transport connection owned by the protocol module.
pub const Connection = struct { context: *anyopaque };
pub const BoundedBytes = struct { bytes: []const u8, limit: u64 };
pub const EncodedToolResult = struct { bytes: []const u8, is_error: bool };

/// `Owned<T>`: `value` lives in `arena`; call `deinit` only after the output lifetime ends.
pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(owned: *@This()) void {
            owned.arena.deinit();
        }
    };
}

// ------------------------------------------------------------------ interface signatures I01–I19

pub const AuthorizeError = errors.ContractError || errors.PermissionError || errors.FileError;
pub const ReserveError = errors.ResourceError || errors.InterruptError;
pub const ReadError = errors.ContractError || errors.PermissionError || errors.ResourceError ||
    errors.InterruptError || errors.ConflictError || errors.FileError;
pub const SubmitError = errors.ResourceError || errors.InterruptError;
pub const RegisterError = errors.ContractError || errors.PermissionError || errors.FileError || errors.ResourceError;
pub const LeaseError = errors.ConflictError || errors.ResourceError || errors.InterruptError;
pub const WriteError = errors.Error;
pub const RecoverError = errors.FileError || errors.IntegrityError || errors.ResourceError;
pub const CacheError = errors.PermissionError || errors.ResourceError;
pub const InvalidateError = errors.ResourceError || errors.IntegrityError;
pub const HealthError = errors.ResourceError;
pub const ServeError = errors.ContractError || errors.ResourceError || errors.InterruptError || errors.FileError;

// Each signature takes the implementing object as its first parameter so that
// trusted state (policy snapshot, root handle, budgets, executor) is explicit
// instead of global. Check an implementation with
// `comptime core.conforms(core.AuthorizeFn(Authorizer), Authorizer.authorize);`.

/// I01 capability is immutable and cannot widen the root.
pub fn AuthorizeFn(comptime Self: type) type {
    return fn (*Self, Io, SessionContext, Operation, RelativePath) AuthorizeError!Capability;
}
/// I02 no allocation before the reservation succeeds.
pub fn ReserveFn(comptime Self: type) type {
    return fn (*Self, SessionContext, ResourceCost) ReserveError!Reservation;
}
/// I03 FD and scratch are returned on success and cancellation.
pub fn ReadRangeFn(comptime Self: type) type {
    return fn (*Self, Io, Allocator, Capability, ReadSpec, *Reservation, Cancel) ReadError!Owned(ReadResult);
}
/// I04 respects sink backpressure.
pub fn EnumerateFn(comptime Self: type) type {
    return fn (*Self, Io, Capability, FileSpec, Sink(RelativePath), Cancel) ReadError!Coverage;
}
/// I05 byte spans identical to the scalar oracle.
pub fn SearchLiteralFn(comptime Self: type) type {
    return fn (*Self, Io, Capability, SearchSpec, Sink(SearchFileResult), Cancel) ReadError!Coverage;
}
/// I06 input order kept, errors per item.
pub fn BatchReadFn(comptime Self: type) type {
    return fn (*Self, Io, Allocator, SessionContext, []const BatchReadItem, *Reservation) ReadError!Owned(BatchResult);
}
/// I07 on success the executor owns the envelope.
pub fn SubmitFn(comptime Self: type) type {
    return fn (*Self, *JobEnvelope) SubmitError!JobHandle;
}
/// I08 creates or verifies the incarnation.
pub fn RegisterWorkspaceFn(comptime Self: type) type {
    return fn (*Self, Io, TrustedRoot, Policy) RegisterError!WorkspaceId;
}
/// I09 monotonic fence, one active writer.
pub fn AcquireWriterFn(comptime Self: type) type {
    return fn (*Self, TaskContext, WorkspaceId) LeaseError!WriterLease;
}
/// I10 exact expected digest, single-file commit.
pub fn ApplyPatchFn(comptime Self: type) type {
    return fn (*Self, Io, Capability, *const WriterLease, PatchSpec) WriteError!Receipt;
}
/// I11 no-overwrite publish.
pub fn CreateFileFn(comptime Self: type) type {
    return fn (*Self, Io, Capability, *const WriterLease, CreateSpec) WriteError!Receipt;
}
/// I12 ambiguous state quarantines writes.
pub fn RecoverFn(comptime Self: type) type {
    return fn (*Self, Io, Allocator, WorkspaceId, JournalStore) RecoverError!Owned(RecoveryReport);
}
/// I13 authorization first, immutable key, unpin mandatory.
pub fn CacheGetFn(comptime Self: type) type {
    return fn (*Self, ContentHash, Capability, PinBudget) CacheError!?PinnedEntry;
}
/// I14 never hides uncertain or dropped events.
pub fn InvalidateFn(comptime Self: type) type {
    return fn (*Self, WorkspaceId, WatchEvent) InvalidateError!IndexState;
}
/// I15 cannot raise limits above hard caps.
pub fn UpdatePolicyFn(comptime Self: type) type {
    return fn (*Self, ResourceSignals) AdmissionLimits;
}
/// I16 syntax candidates, not references.
pub fn OutlineFn(comptime Self: type) type {
    return fn (*Self, Io, Allocator, Capability, ParserSpec) ReadError!Owned(OutlineCandidates);
}
/// I17 never exposes other sessions' sources or tokens.
pub fn HealthFn(comptime Self: type) type {
    return fn (*Self, SessionContext) HealthError!HealthSnapshot;
}
/// I18 request and output lifetimes are separate.
pub fn ServeFrameFn(comptime Self: type) type {
    return fn (*Self, Io, *Connection, BoundedBytes) ServeError!EncodedToolResult;
}
/// I19 is a vtable (prepare/record/lookup); the receiver is `JournalStore.context`.
pub fn JournalStoreVTable(comptime Self: type) type {
    _ = Self;
    return JournalStore.VTable;
}

pub const InterfaceEntry = struct { id: []const u8, name: []const u8, Signature: fn (comptime type) type };

/// docs/17 §3.
pub const interfaces = [_]InterfaceEntry{
    .{ .id = "I01", .name = "authorize", .Signature = AuthorizeFn },
    .{ .id = "I02", .name = "reserve", .Signature = ReserveFn },
    .{ .id = "I03", .name = "readRange", .Signature = ReadRangeFn },
    .{ .id = "I04", .name = "enumerate", .Signature = EnumerateFn },
    .{ .id = "I05", .name = "searchLiteral", .Signature = SearchLiteralFn },
    .{ .id = "I06", .name = "batchRead", .Signature = BatchReadFn },
    .{ .id = "I07", .name = "submit", .Signature = SubmitFn },
    .{ .id = "I08", .name = "registerWorkspace", .Signature = RegisterWorkspaceFn },
    .{ .id = "I09", .name = "acquireWriter", .Signature = AcquireWriterFn },
    .{ .id = "I10", .name = "applyPatch", .Signature = ApplyPatchFn },
    .{ .id = "I11", .name = "createFile", .Signature = CreateFileFn },
    .{ .id = "I12", .name = "recover", .Signature = RecoverFn },
    .{ .id = "I13", .name = "cacheGet", .Signature = CacheGetFn },
    .{ .id = "I14", .name = "invalidate", .Signature = InvalidateFn },
    .{ .id = "I15", .name = "updatePolicy", .Signature = UpdatePolicyFn },
    .{ .id = "I16", .name = "outline", .Signature = OutlineFn },
    .{ .id = "I17", .name = "health", .Signature = HealthFn },
    .{ .id = "I18", .name = "serveFrame", .Signature = ServeFrameFn },
    .{ .id = "I19", .name = "JournalStore", .Signature = JournalStoreVTable },
};

/// Compile-time check that an implementation matches its frozen signature.
pub fn conforms(comptime Signature: type, comptime function: anytype) void {
    if (@TypeOf(function) != Signature) {
        @compileError("signature mismatch: expected " ++ @typeName(Signature) ++ ", found " ++ @typeName(@TypeOf(function)));
    }
}
