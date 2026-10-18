// Small system probes: volume (wpctl), wifi quality (/proc), and synchronous commands.

const std = @import("std");
const c = @import("c.zig").c;
const store = @import("store.zig");
const bar = @import("bar.zig");

/// Run `sh -c cmd` and wait for it (for short commands whose effect we read back).
pub fn runWait(cmd: [*:0]const u8) void {
    const pid = c.fork();
    if (pid == 0) {
        // `timeout` so a wedged audio server can never freeze the WM's event loop.
        const argv = [_:null]?[*:0]const u8{ "timeout", "2", "sh", "-c", cmd };
        _ = c.execvp("timeout", @ptrCast(&argv));
        const plain = [_:null]?[*:0]const u8{ "sh", "-c", cmd };
        _ = c.execvp("sh", @ptrCast(&plain));
        c._exit(127);
    } else if (pid > 0) {
        _ = c.waitpid(pid, null, 0);
    }
}

/// Fire and forget: double fork so nothing is left to reap.
pub fn spawn(cmd: [*:0]const u8) void {
    const pid = c.fork();
    if (pid == 0) {
        _ = c.setsid();
        if (c.fork() == 0) {
            const argv = [_:null]?[*:0]const u8{ "sh", "-c", cmd };
            _ = c.execvp("sh", @ptrCast(&argv));
        }
        c._exit(0);
    } else if (pid > 0) {
        _ = c.waitpid(pid, null, 0);
    }
}

/// Query the default sink with wpctl. Leaves `st` untouched if wpctl is unavailable.
pub fn readVolume(st: *store.Status) void {
    const f = c.popen("timeout 1 wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null", "r") orelse return;
    var buf: [64]u8 = undefined;
    const got = c.fgets(&buf, buf.len, f);
    _ = c.pclose(f);
    var pct: i32 = -1;
    var muted = false;
    if (got != null) {
        const line = std.mem.sliceTo(&buf, 0);
        if (std.mem.startsWith(u8, line, "Volume: ")) {
            var it = std.mem.tokenizeScalar(u8, line["Volume: ".len..], ' ');
            if (it.next()) |num| {
                const v = std.fmt.parseFloat(f32, std.mem.trim(u8, num, "\n")) catch -1;
                if (v >= 0) pct = @intFromFloat(@round(v * 100));
            }
            muted = std.mem.indexOf(u8, line, "MUTED") != null;
        }
    }
    if (pct != st.vol_pct or muted != st.muted) {
        st.vol_pct = pct;
        st.muted = muted;
        st.version +%= 1;
    }
}

/// Link quality of the first wireless interface as 0..100, or -1.
pub fn wifiQuality() i32 {
    var buf: [512]u8 = undefined;
    const data = bar.readFile("/proc/net/wireless", &buf);
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next();
    _ = lines.next(); // two header lines
    const line = lines.next() orelse return -1;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return -1;
    var it = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
    _ = it.next(); // status
    const link = it.next() orelse return -1;
    const q = std.fmt.parseFloat(f32, std.mem.trimEnd(u8, link, ".")) catch return -1;
    return @intFromFloat(std.math.clamp(q * 100 / 70, 0, 100));
}
