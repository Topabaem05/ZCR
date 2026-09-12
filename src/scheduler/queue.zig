//! Bounded queue of chunk jobs. The executor serializes access.
//! One job is one bounded chunk (normally <=256 KiB); unit deficit quantum
//! gives task round robin inside equally weighted workspace turns. Callers
//! split longer work and return to this queue at each cancellation boundary.
const std = @import("std");
const core = @import("zcr_core");

pub const Resources = struct {
    cpu: u32,
    non_short_cpu: u32,
    io: u32,
    /// The executor also excludes idle while foreground is executing.
    idle_allowed: bool = true,
};
pub const Entry = struct {
    job: *core.JobEnvelope,
    handle: core.JobHandle,
    workspace_turn: u64 = 0,
    task_turn: u64 = 0,
};

pub fn cpuCost(job: *const core.JobEnvelope) u32 {
    return @max(1, job.scratch_reservation.cpu);
}
pub fn ioCost(job: *const core.JobEnvelope) u32 {
    return if (job.scratch_reservation.fd > 0) 1 else 0;
}
fn lane(job: *const core.JobEnvelope) enum { foreground, maintenance, idle } {
    return switch (job.qos_intent) {
        .fg_short, .fg_bulk => .foreground,
        .maintenance => .maintenance,
        .idle => .idle,
    };
}
fn sameTask(a: *const core.JobEnvelope, b: *const core.JobEnvelope) bool {
    return a.context.bound_workspace.eql(b.context.bound_workspace) and std.mem.eql(u8, &a.context.bound_task.uuid, &b.context.bound_task.uuid);
}

pub const Queue = struct {
    entries: [core.limits.values.global_queue]Entry = undefined,
    len: usize = 0,
    foreground_credit: u32 = 4,
    turn: u64 = 0,
    /// A selected service turn retains its grant while existing callbacks
    /// drain. Otherwise small refills can keep a larger accepted job ineligible
    /// forever. A handle survives array compaction and dependency promotion.
    protected_handle: ?core.JobHandle = null,

    /// Failure retains caller ownership. Session bounds apply to waiting jobs,
    /// independently from the running permits held by the executor.
    pub fn push(self: *Queue, job: *core.JobEnvelope, handle: core.JobHandle) error{Busy}!void {
        if (self.len == self.entries.len) return error.Busy;
        var session_count: usize = 0;
        var entry: Entry = .{ .job = job, .handle = handle, .workspace_turn = self.turn, .task_turn = self.turn };
        for (self.entries[0..self.len]) |existing| {
            if (std.mem.eql(u8, &existing.job.context.session_id.uuid, &job.context.session_id.uuid)) session_count += 1;
            if (lane(existing.job) != lane(job)) continue;
            if (existing.job.context.bound_workspace.eql(job.context.bound_workspace)) entry.workspace_turn = existing.workspace_turn;
            if (sameTask(existing.job, job)) entry.task_turn = existing.task_turn;
        }
        if (session_count >= core.limits.values.session_queue) return error.Busy;
        self.entries[self.len] = entry;
        self.len += 1;
    }

    /// Promote only a waiting dependency. Running chunks retain their current
    /// class and the caller submits their continuation with foreground intent.
    pub fn promote(self: *Queue, handle: core.JobHandle) bool {
        for (self.entries[0..self.len]) |*entry| if (entry.handle.id == handle.id) {
            if (entry.job.qos_intent == .maintenance or entry.job.qos_intent == .idle) {
                entry.job.qos_intent = .fg_bulk;
                entry.workspace_turn = 0;
                entry.task_turn = 0;
            }
            return true;
        };
        return false;
    }

    fn eligible(job: *const core.JobEnvelope, resources: Resources) bool {
        return cpuCost(job) <= resources.cpu and ioCost(job) <= resources.io and
            (job.qos_intent == .fg_short or cpuCost(job) <= resources.non_short_cpu);
    }
    fn choose(self: *const Queue, wanted: @TypeOf(lane(undefined)), resources: ?Resources) ?usize {
        var chosen: ?usize = null;
        for (self.entries[0..self.len], 0..) |entry, i| {
            if (lane(entry.job) != wanted) continue;
            if (resources) |available_| if (!eligible(entry.job, available_)) continue;
            if (chosen) |index| {
                const previous = self.entries[index];
                if (entry.workspace_turn > previous.workspace_turn) continue;
                if (entry.workspace_turn == previous.workspace_turn and entry.task_turn >= previous.task_turn) continue;
            }
            chosen = i;
        }
        return chosen;
    }
    fn preferred(self: *const Queue, resources: ?Resources, idle_allowed: bool) ?usize {
        const foreground = self.choose(.foreground, resources);
        const maintenance = self.choose(.maintenance, resources);
        if (foreground != null and (self.foreground_credit > 0 or maintenance == null)) return foreground;
        if (maintenance != null) return maintenance;
        // Idle neither bypasses queued dependencies nor starts alongside an
        // active foreground callback. Pressure policy can further deny idle.
        if (!idle_allowed) return null;
        for (self.entries[0..self.len]) |entry| if (lane(entry.job) != .idle) return null;
        return self.choose(.idle, resources);
    }

    pub fn pop(self: *Queue, resources: Resources) ?Entry {
        var selected: usize = if (self.protected_handle) |handle| blk: {
            for (self.entries[0..self.len], 0..) |entry, i| {
                if (entry.handle.id == handle.id) break :blk i;
            }
            unreachable; // Only pop removes an entry, clearing its protection.
        } else self.preferred(null, resources.idle_allowed) orelse return null;

        const candidate = self.entries[selected];
        if (!eligible(candidate.job, resources)) {
            // Choose the fair turn BEFORE checking permit availability. Its
            // CPU/non-short/I/O grant is withheld from subsequent refills until
            // running jobs release enough capacity. Only noncompeting spare
            // capacity may run other jobs (including reserved short foreground).
            if (lane(candidate.job) == .idle) return null;
            self.protected_handle = candidate.handle;
            var spare = resources;
            spare.cpu -|= cpuCost(candidate.job);
            if (candidate.job.qos_intent != .fg_short) spare.non_short_cpu -|= cpuCost(candidate.job);
            spare.io -|= ioCost(candidate.job);
            selected = self.preferred(spare, resources.idle_allowed) orelse return null;
        }
        const result = self.entries[selected];
        if (self.protected_handle) |handle| {
            if (handle.id == result.handle.id) self.protected_handle = null;
        }
        switch (lane(result.job)) {
            .foreground => self.foreground_credit -|= 1,
            .maintenance => self.foreground_credit = 4,
            .idle => {},
        }
        std.mem.copyForwards(Entry, self.entries[selected .. self.len - 1], self.entries[selected + 1 .. self.len]);
        self.len -= 1;
        self.turn += 1;
        for (self.entries[0..self.len]) |*entry| {
            if (lane(entry.job) != lane(result.job)) continue;
            if (entry.job.context.bound_workspace.eql(result.job.context.bound_workspace)) entry.workspace_turn = self.turn;
            if (sameTask(entry.job, result.job)) entry.task_turn = self.turn;
        }
        return result;
    }
};
