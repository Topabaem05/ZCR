const std = @import("std");
const workspace = @import("zcr_workspace");
comptime {
    if (@TypeOf(@as(workspace.Registry, undefined).test_before_lock) != void) @compileError("test lock hook leaked into runtime");
    if (@TypeOf(workspace.identity.marker_test_hook) != void) @compileError("test marker hook leaked into runtime");
}
pub export fn registryStorageBytes() usize { return @sizeOf(workspace.Registry); }
