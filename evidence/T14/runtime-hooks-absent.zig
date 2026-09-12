const watch = @import("zcr_watch");
comptime {
 if (@TypeOf(@as(watch.Runtime, undefined).test_hook) != void) @compileError("Runtime test hook leaked");
 if (@TypeOf(@as(watch.linux.Backend, undefined).test_force_unknown) != void) @compileError("Linux test hook leaked");
}
pub export fn runtimeBytes() usize { return @sizeOf(watch.Runtime); }
pub export fn indexBytes() usize { return @sizeOf(watch.Index); }
pub export fn backendBytes() usize { return @sizeOf(watch.linux.Backend); }
