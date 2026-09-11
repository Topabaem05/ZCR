//! Common compact output projection (T07; docs/08 §3, §5, contracts/response.schema.json).
//!
//! S02 stub: the API the tests use, with no behaviour yet.

const std = @import("std");
const core = @import("zcr_core");

pub const max_request_id_bytes = 256;
pub const reason_output_budget = "serialized data reached output_bytes";
pub const message_item_output_budget = "item does not fit the remaining batch output_bytes";

pub const Envelope = struct {
    request_id: []const u8,
    workspace_id: ?core.WorkspaceId = null,
    generation: ?u64 = null,
    elapsed_us: ?u64 = null,
    cache: ?core.CacheResult = null,
};

pub const FilesData = struct { paths: []const core.RelativePath, order: core.Order };
pub const SearchData = struct { files: []const core.SearchFileResult, order: core.Order };

pub const Data = union(enum) {
    read: core.ReadResult,
    batch_read: core.BatchResult,
    files: FilesData,
    search: SearchData,
};

pub const Response = struct {
    bytes: []const u8,
    returned_bytes: u64,
    ok: bool,
    complete: bool,
    truncated: bool,
    /// Lines, items, paths or files left out or replaced to fit `output_bytes`.
    omitted: u32,
};

pub const Error = error{ InvalidArgument, OutputBudgetExceeded };

/// Buffer capacity that always holds `success` for this envelope, status and budget.
pub fn bufferBytes(envelope: Envelope, status: core.ResultStatus, output_bytes: u64) u64 {
    _ = envelope;
    _ = status;
    _ = output_bytes;
    return 0;
}

/// Buffer capacity that always holds `failure` for this envelope and error.
pub fn failureBufferBytes(envelope: Envelope, info: core.errors.ErrorInfo) u64 {
    _ = envelope;
    _ = info;
    return 0;
}

pub fn success(buffer: []u8, envelope: Envelope, data: Data, status: core.ResultStatus, output_bytes: u64) Error!Response {
    _ = buffer;
    _ = envelope;
    _ = data;
    _ = status;
    _ = output_bytes;
    return error.InvalidArgument;
}

pub fn failure(buffer: []u8, envelope: Envelope, info: core.errors.ErrorInfo) error{InvalidArgument}!Response {
    _ = buffer;
    _ = envelope;
    _ = info;
    return error.InvalidArgument;
}
