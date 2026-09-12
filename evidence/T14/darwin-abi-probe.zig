const std = @import("std");
const darwin = @import("darwin");
const core = @import("zcr_core");
fn push(_: *anyopaque, _: core.WatchEvent) void {}
export fn probe() void {
    var b = darwin.Backend{};
    var requested = std.atomic.Value(bool).init(false);
    const cancel = core.Cancel{.requested = &requested};
    const root = core.TrustedRoot{.dir = undefined, .canonical_path = "/tmp"};
    b.start(undefined, root, .{.context = &b, .push = push}, 1) catch {};
    _ = b.refresh(undefined, root, cancel) catch false;
    _ = b.poll(undefined, cancel) catch 0;
    b.stop(undefined);
    _ = b.watchedCount();
    _ = b.synchronized();
}
