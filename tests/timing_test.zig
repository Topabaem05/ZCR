const std = @import("std");
const core = @import("zcr_core");
const t = std.testing;

test "IO-004 deadline stops a native operation without a cancellation producer" {
    var flag = std.atomic.Value(bool).init(false);
    const cancel: core.Cancel = .{ .requested = &flag };
    try cancel.check();
    const expired = cancel.withTimeout(t.io, 0);
    try t.expectError(error.DeadlineExceeded, expired.check());
    try t.expect(expired.isRequested());
    try t.expect(!flag.load(.acquire));
    flag.store(true, .release);
    try t.expectError(error.Cancelled, expired.check());
}

test "IO-004 nested native deadlines cannot extend an expired parent" {
    var flag = std.atomic.Value(bool).init(false);
    const cancel: core.Cancel = .{ .requested = &flag };
    const expired = cancel.withTimeout(t.io, 0);
    const nested = expired.withTimeout(t.io, 60_000);
    try t.expectError(error.DeadlineExceeded, nested.check());
    const future = cancel.withTimeout(t.io, 60_000);
    try future.check();
    try t.expectError(error.DeadlineExceeded, future.withTimeout(t.io, 0).check());
}
