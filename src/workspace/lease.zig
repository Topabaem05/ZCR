//! Bounded writer lease state, serialized by the owning registry lock.
//!
//! No method allocates, waits, reads the clock or performs I/O. The registry
//! supplies trusted monotonic time and validates workspace/session authority.
//! A State keeps its address and counters throughout the registry lifetime,
//! including workspace slot reuse; every callback must drain before destruction.
const std = @import("std");
const core = @import("zcr_core");

pub const ttl_ns: u64 = 30 * std.time.ns_per_s;
pub const renewal_interval_ns: u64 = 10 * std.time.ns_per_s;
pub const max_callbacks: usize = 64;

/// Internal completion token. The registry retains it for the callback lifetime;
/// it is not a transport capability and cannot authorize a writer by itself.
pub const CallbackTicket = enum(u128) { _ };

const Active = struct {
    lease: core.WriterLease,
    renewed_at_ns: u64,
};

const Callback = struct {
    id: u64,
    fence: core.FenceToken,
};

pub const State = struct {
    fence: core.FenceToken = 0,
    active: ?Active = null,
    last_callback_id: u64 = 0,
    callbacks: [max_callbacks]?Callback = .{null} ** max_callbacks,
    callback_count: usize = 0,

    pub fn acquire(self: *State, workspace: core.WorkspaceId, task: core.TaskId, now_ns: u64) core.LeaseError!core.WriterLease {
        self.expire(now_ns);
        if (self.active != null or !self.isDrained()) return error.Busy;
        const expires = std.math.add(u64, now_ns, ttl_ns) catch return error.ResourceExhausted;
        const next_fence = std.math.add(core.FenceToken, self.fence, 1) catch return error.ResourceExhausted;
        const lease: core.WriterLease = .{
            .workspace_id = workspace,
            .task_id = task,
            .fence = next_fence,
            .expires_at_monotonic_ns = expires,
        };
        self.fence = next_fence;
        self.active = .{ .lease = lease, .renewed_at_ns = now_ns };
        return lease;
    }

    /// Renewal issues a fresh snapshot at most once per ten seconds. Existing
    /// callback tickets remain valid across renewal of the same writer fence.
    pub fn renew(self: *State, lease: core.WriterLease, now_ns: u64) core.LeaseError!core.WriterLease {
        try self.validate(lease, now_ns);
        const writer = &self.active.?;
        if (now_ns < writer.renewed_at_ns or now_ns - writer.renewed_at_ns < renewal_interval_ns) return error.Busy;
        const expires = std.math.add(u64, now_ns, ttl_ns) catch return error.ResourceExhausted;
        writer.lease.expires_at_monotonic_ns = expires;
        writer.renewed_at_ns = now_ns;
        return writer.lease;
    }

    /// Invalidation is immediate; completion tickets remain live until returned.
    /// Saturation never wraps a fence or allows another writer to acquire it.
    pub fn revoke(self: *State) void {
        if (self.active == null) return;
        self.active = null;
        self.fence = std.math.add(core.FenceToken, self.fence, 1) catch std.math.maxInt(core.FenceToken);
    }

    pub fn validate(self: *State, lease: core.WriterLease, now_ns: u64) core.LeaseError!void {
        self.expire(now_ns);
        const writer = self.active orelse {
            if (now_ns >= lease.expires_at_monotonic_ns) return error.LeaseExpired;
            return error.FenceMismatch;
        };
        if (!lease.workspace_id.eql(writer.lease.workspace_id) or
            !std.mem.eql(u8, &lease.task_id.uuid, &writer.lease.task_id.uuid) or
            lease.fence != writer.lease.fence or
            lease.expires_at_monotonic_ns != writer.lease.expires_at_monotonic_ns)
        {
            return error.FenceMismatch;
        }
    }

    pub fn beginCallback(self: *State, lease: core.WriterLease, now_ns: u64) core.LeaseError!CallbackTicket {
        try self.validate(lease, now_ns);
        if (self.callback_count == max_callbacks) return error.Busy;
        const next_id = std.math.add(u64, self.last_callback_id, 1) catch return error.ResourceExhausted;
        for (&self.callbacks) |*slot| {
            if (slot.* != null) continue;
            slot.* = .{ .id = next_id, .fence = lease.fence };
            self.last_callback_id = next_id;
            self.callback_count += 1;
            return @enumFromInt((@as(u128, @intFromPtr(self)) << 64) | next_id);
        }
        unreachable; // callback_count exactly counts the occupied fixed slots.
    }

    /// Called immediately before a callback's commit phase. The caller must
    /// serialize the commit transition with lease invalidation in its actor.
    pub fn validateCallback(self: *State, ticket: CallbackTicket, now_ns: u64) core.LeaseError!void {
        self.expire(now_ns);
        const index = self.callbackIndex(ticket) orelse return error.FenceMismatch;
        const writer = self.active orelse return error.FenceMismatch;
        if (self.callbacks[index].?.fence != writer.lease.fence) return error.FenceMismatch;
    }

    /// Completion is accepted after invalidation, but only once per ticket.
    pub fn endCallback(self: *State, ticket: CallbackTicket) core.LeaseError!void {
        const index = self.callbackIndex(ticket) orelse return error.FenceMismatch;
        self.callbacks[index] = null;
        self.callback_count -= 1;
    }

    pub fn isDrained(self: *const State) bool {
        return self.callback_count == 0;
    }

    /// Snapshot only; the caller still validates expiry and callback authority.
    pub fn currentLease(self: *const State) ?core.WriterLease {
        const writer = self.active orelse return null;
        return writer.lease;
    }

    fn expire(self: *State, now_ns: u64) void {
        if (self.active) |writer| {
            if (now_ns >= writer.lease.expires_at_monotonic_ns) self.revoke();
        }
    }

    fn callbackIndex(self: *const State, ticket: CallbackTicket) ?usize {
        const raw = @intFromEnum(ticket);
        if (raw >> 64 != @as(u128, @intFromPtr(self))) return null;
        const id: u64 = @truncate(raw);
        for (self.callbacks, 0..) |slot, index| {
            if (slot) |callback| {
                if (callback.id == id) return index;
            }
        }
        return null;
    }
};

fn testWorkspace() core.WorkspaceId {
    return .{ .registry_uuid = .{1} ** 16, .incarnation = .{2} ** 16 };
}

fn testTask() core.TaskId {
    return .{ .uuid = .{3} ** 16 };
}

test "IS-005 writer lease has a thirty second TTL and excludes a second writer" {
    var state: State = .{};
    const now: u64 = 100;
    const lease = try state.acquire(testWorkspace(), testTask(), now);
    try std.testing.expect(lease.fence > 0);
    try std.testing.expectEqual(now + ttl_ns, lease.expires_at_monotonic_ns);
    try std.testing.expectError(error.Busy, state.acquire(testWorkspace(), testTask(), now));
}

test "IS-005 renewal every ten seconds refreshes snapshots and keeps callback authority" {
    var state: State = .{};
    const original = try state.acquire(testWorkspace(), testTask(), 0);
    const ticket = try state.beginCallback(original, 0);
    try std.testing.expectError(error.Busy, state.renew(original, renewal_interval_ns - 1));
    const renewed = try state.renew(original, renewal_interval_ns);
    try std.testing.expectEqual(original.fence, renewed.fence);
    try std.testing.expectEqual(ttl_ns + renewal_interval_ns, renewed.expires_at_monotonic_ns);
    try std.testing.expectError(error.FenceMismatch, state.validate(original, renewal_interval_ns));
    try state.validate(renewed, ttl_ns);
    try state.validateCallback(ticket, ttl_ns);
    try std.testing.expectError(error.LeaseExpired, state.renew(renewed, renewed.expires_at_monotonic_ns));
    try std.testing.expectError(error.FenceMismatch, state.validateCallback(ticket, renewed.expires_at_monotonic_ns));
    try state.endCallback(ticket);
}

test "IS-005 cancellation invalidates callbacks and a new writer waits for every drain" {
    var state: State = .{};
    const original = try state.acquire(testWorkspace(), testTask(), 0);
    const first = try state.beginCallback(original, 1);
    const second = try state.beginCallback(original, 2);
    state.revoke();
    try std.testing.expect(state.fence > original.fence);
    try std.testing.expectError(error.FenceMismatch, state.validate(original, 3));
    try std.testing.expectError(error.FenceMismatch, state.validateCallback(first, 3));
    try std.testing.expectError(error.Busy, state.acquire(testWorkspace(), testTask(), 3));
    try state.endCallback(first);
    try std.testing.expectError(error.FenceMismatch, state.endCallback(first));
    try std.testing.expectError(error.Busy, state.acquire(testWorkspace(), testTask(), 3));
    try state.endCallback(second);
    try std.testing.expect(state.isDrained());
    const replacement = try state.acquire(testWorkspace(), testTask(), 4);
    try std.testing.expect(replacement.fence > original.fence);
    try std.testing.expectError(error.FenceMismatch, state.validateCallback(first, 4));
}

test "IS-005 exact TTL expiry revokes old fence and waits for callback drain" {
    var state: State = .{};
    const original = try state.acquire(testWorkspace(), testTask(), 0);
    const ticket = try state.beginCallback(original, 1);
    try state.validate(original, ttl_ns - 1);
    try std.testing.expectError(error.Busy, state.acquire(testWorkspace(), testTask(), ttl_ns));
    try std.testing.expectError(error.LeaseExpired, state.validate(original, ttl_ns));
    try std.testing.expectError(error.FenceMismatch, state.validateCallback(ticket, ttl_ns));
    try state.endCallback(ticket);
    const replacement = try state.acquire(testWorkspace(), testTask(), ttl_ns);
    try std.testing.expect(replacement.fence > original.fence);
    try std.testing.expectError(error.FenceMismatch, state.validate(original, ttl_ns));
}

test "IS-005 callback slots are bounded and duplicate or foreign completion cannot drain work" {
    var state: State = .{};
    var other: State = .{};
    const lease = try state.acquire(testWorkspace(), testTask(), 0);
    var tickets: [max_callbacks]CallbackTicket = undefined;
    for (&tickets) |*ticket| ticket.* = try state.beginCallback(lease, 1);
    try std.testing.expectError(error.Busy, state.beginCallback(lease, 1));
    try std.testing.expectError(error.FenceMismatch, other.endCallback(tickets[0]));
    try state.endCallback(tickets[0]);
    const replacement_ticket = try state.beginCallback(lease, 1);
    try std.testing.expect(replacement_ticket != tickets[0]);
    try std.testing.expectError(error.FenceMismatch, state.endCallback(tickets[0]));
    try std.testing.expectError(error.FenceMismatch, state.validateCallback(tickets[0], 1));
    for (tickets[1..]) |ticket| try state.endCallback(ticket);
    try std.testing.expect(!state.isDrained());
    try state.endCallback(replacement_ticket);
    try std.testing.expect(state.isDrained());
}

test "IS-005 forged workspace task fence or expiry cannot acquire callback authority" {
    var state: State = .{};
    const lease = try state.acquire(testWorkspace(), testTask(), 0);
    var forged = lease;
    forged.workspace_id.incarnation[0] ^= 1;
    try std.testing.expectError(error.FenceMismatch, state.beginCallback(forged, 1));
    forged = lease;
    forged.task_id.uuid[0] ^= 1;
    try std.testing.expectError(error.FenceMismatch, state.beginCallback(forged, 1));
    forged = lease;
    forged.fence += 1;
    try std.testing.expectError(error.FenceMismatch, state.beginCallback(forged, 1));
    forged = lease;
    forged.expires_at_monotonic_ns += 1;
    try std.testing.expectError(error.FenceMismatch, state.beginCallback(forged, 1));
    try std.testing.expect(state.isDrained());
    try state.validate(lease, 1);
}

test "IS-005 fence and timestamp overflow fail closed without wrapping authority" {
    var state: State = .{ .fence = std.math.maxInt(u64) - 1 };
    const lease = try state.acquire(testWorkspace(), testTask(), 0);
    const ticket = try state.beginCallback(lease, 1);
    try std.testing.expectEqual(std.math.maxInt(u64), lease.fence);
    state.revoke();
    try std.testing.expectError(error.FenceMismatch, state.validateCallback(ticket, 2));
    try state.endCallback(ticket);
    try std.testing.expectError(error.ResourceExhausted, state.acquire(testWorkspace(), testTask(), 2));
    try std.testing.expectEqual(std.math.maxInt(u64), state.fence);

    var time_state: State = .{};
    const latest_start = std.math.maxInt(u64) - ttl_ns;
    try std.testing.expectError(error.ResourceExhausted, time_state.acquire(testWorkspace(), testTask(), latest_start + 1));
    const late = try time_state.acquire(testWorkspace(), testTask(), latest_start);
    try std.testing.expectError(error.ResourceExhausted, time_state.renew(late, latest_start + renewal_interval_ns));
    try time_state.validate(late, latest_start + renewal_interval_ns);
}

test "IS-005 callback id exhaustion preserves existing work and never reuses a ticket" {
    var state: State = .{ .last_callback_id = std.math.maxInt(u64) - 1 };
    const lease = try state.acquire(testWorkspace(), testTask(), 0);
    const ticket = try state.beginCallback(lease, 0);
    try std.testing.expectError(error.ResourceExhausted, state.beginCallback(lease, 0));
    try state.validateCallback(ticket, 0);
    try state.endCallback(ticket);
    try std.testing.expect(state.isDrained());
    try std.testing.expectError(error.ResourceExhausted, state.beginCallback(lease, 0));
}
