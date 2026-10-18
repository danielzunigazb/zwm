// Frame-rate independent smoothing. Everything animated in the WM chases a target with
// critically-damped exponential decay: retargeting mid-flight never jumps, and the
// result is the same whatever the frame pacing is.

const std = @import("std");
const cfg = @import("config.zig");
const c = @import("c.zig").c;

pub const frame_ns: i64 = @divTrunc(1_000_000_000, cfg.anim_hz);

pub fn nowNs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1_000_000_000 + @as(i64, ts.tv_nsec);
}

/// Move `cur` toward `target`; true while still moving. Snaps when within half a pixel.
pub fn settle(cur: *f32, target: f32, dt: f32, k: f32) bool {
    if (cur.* == target) return false;
    cur.* += (target - cur.*) * (1 - @exp(-k * dt));
    if (@abs(target - cur.*) < 0.5) {
        cur.* = target;
        return false;
    }
    return true;
}

pub fn round(v: f32) i32 {
    return @intFromFloat(@round(v));
}

/// Sleep until `deadline` (CLOCK_MONOTONIC ns), waking early for X/D-Bus traffic.
/// `pfd` are the descriptors to watch. Returns poll()'s result.
pub fn waitUntil(pfd: []c.struct_pollfd, deadline: i64) c_int {
    const left = deadline - nowNs();
    const ms: c_int = if (left <= 0) 0 else @intCast(@divTrunc(left, 1_000_000));
    const r = c.poll(pfd.ptr, @intCast(pfd.len), ms);
    if (r == 0) {
        const rest = deadline - nowNs();
        if (rest > 0) {
            var ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = @intCast(rest) };
            _ = c.nanosleep(&ts, null);
        }
    }
    return r;
}
