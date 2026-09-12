const cache = @import("zcr_cache");
comptime {
    if (@TypeOf(cache.association.test_hooks) != void) @compileError("cache test hooks leaked into runtime");
}
pub export fn cacheStorageBytes() usize { return @sizeOf(cache.Store); }
