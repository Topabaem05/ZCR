const std = @import("std");
const edit = @import("zcr_fs_edit");
const core = @import("zcr_core");
comptime {
    if (edit.production_writes_enabled) @compileError("T12 gate unexpectedly enabled");
    if (@TypeOf(@as(edit.Editor, undefined).fault) != void) @compileError("runtime exposes test fault hook");
    if (@TypeOf(@as(edit.publish.Temp, undefined).probe) != void) @compileError("runtime exposes temp probe");
    if (@TypeOf(@as(edit.publish.Parent, undefined).after_publish_error) != void) @compileError("runtime exposes synthetic syscall error");
}
pub fn main() !void {
    // All authority/IO objects are intentionally absent: the compile-time gate
    // must refuse both entry points before any object is inspected or IO starts.
    var editor = edit.Editor.init(undefined);
    const lease: core.WriterLease = undefined;
    const create = editor.createFile(undefined, undefined, &lease, .{ .path = .{ .bytes = "blocked.txt" }, .content = "blocked", .idempotency_key = "gate" });
    if (create) |_| return error.RuntimeWriteEnabled else |err| if (err != error.Unsupported) return err;
    const patch = editor.applyPatch(undefined, undefined, &lease, .{ .path = .{ .bytes = "blocked.txt" }, .expected_sha256 = @splat(0), .replacements = &.{}, .idempotency_key = "gate" });
    if (patch) |_| return error.RuntimeWriteEnabled else |err| if (err != error.Unsupported) return err;
}
