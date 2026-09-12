//! Fixed public GCD queue classes. OS placement remains an OS decision.
const builtin = @import("builtin");
const core = @import("zcr_core");

pub fn qosClass(intent: core.QosIntent) core.limits.QosClass {
    return switch (intent) {
        .fg_short, .fg_bulk => .user_initiated,
        .maintenance => .utility,
        .idle => .background,
    };
}
const Raw = opaque {};
extern "c" fn zcr_gcd_create() ?*Raw;
extern "c" fn zcr_gcd_submit(*Raw, u32, *anyopaque, *const fn (*anyopaque) callconv(.c) void) void;
extern "c" fn zcr_gcd_destroy(*Raw) void;
extern "c" fn zcr_gcd_current_qos() u32;

/// Called only by the outer executor after obtaining CPU and I/O permits.
/// The adapter does not create worker pools or wait on job semaphores.
pub const Adapter = struct {
    raw: *Raw,
    pub fn init() error{ Unsupported, OutOfMemory }!Adapter {
        if (builtin.os.tag != .macos) return error.Unsupported;
        return .{ .raw = zcr_gcd_create() orelse return error.OutOfMemory };
    }
    pub fn submit(self: Adapter, intent: core.QosIntent, context: *anyopaque, callback: *const fn (*anyopaque) callconv(.c) void) void {
        if (builtin.os.tag != .macos) unreachable;
        const index: u32 = switch (qosClass(intent)) {
            .user_initiated => 0,
            .utility => 1,
            .background => 2,
        };
        zcr_gcd_submit(self.raw, index, context, callback);
    }
    pub fn deinit(self: Adapter) void {
        if (builtin.os.tag != .macos) unreachable;
        zcr_gcd_destroy(self.raw);
    }
};
/// A measurement hook for real Mac tests, not a placement guarantee.
pub fn currentQos() error{Unsupported}!u32 {
    if (builtin.os.tag != .macos) return error.Unsupported;
    return zcr_gcd_current_qos();
}
