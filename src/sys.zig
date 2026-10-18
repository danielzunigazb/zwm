// Small system probes: volume (wpctl), wifi quality (/proc), and synchronous commands.

const std = @import("std");
const c = @import("c.zig").c;
const store = @import("store.zig");

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

/// Volume via wpctl, without ever blocking the event loop: wpctl is a separate process that takes
/// tens of ms (or hangs while PipeWire is down), so it runs as a child whose stdout is polled.
/// Key-bound volume commands are queued and run in one child, in order, followed by a read-back.
pub const Volume = struct {
    const max_queue = 1024; // sanity bound only; a held key is ~30 commands per second
    fd: c_int = -1, // read end of the running child's stdout; -1 = idle
    pid: c.pid_t = 0,
    queued: std.ArrayList([*:0]const u8) = .empty,
    want_read: bool = false, // a read-back was requested while a child was running
    buf: [96]u8 = undefined,
    len: usize = 0,

    /// Run `cmd` (if any) and then refresh the volume state. Never blocks.
    pub fn request(v: *Volume, cmd: ?[*:0]const u8) void {
        if (cmd) |cm| {
            // Dropped only on allocation failure or an absurd backlog; the read-back still happens.
            if (v.queued.items.len < max_queue) v.queued.append(std.heap.c_allocator, cm) catch {};
        }
        if (v.fd >= 0) {
            v.want_read = true; // child busy: its successor will pick everything up
            return;
        }
        v.start();
    }

    /// File descriptor to add to poll(), or -1.
    pub fn pollFd(v: *const Volume) c_int {
        return v.fd;
    }

    fn start(v: *Volume) void {
        const gpa = std.heap.c_allocator;
        const n = v.queued.items.len;
        // sh -c SCRIPT sh CMD... : each queued command, then print the volume.
        const script: [*:0]const u8 = "for c do eval \"$c\" >/dev/null 2>&1; done; exec wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null";
        // The whole batch gets a time limit that grows with its size (a wedged audio server must not
        // leave children around, but a long backlog of real commands must not be cut short either).
        var secs: [16:0]u8 = undefined;
        _ = std.fmt.bufPrintZ(&secs, "{d}", .{3 + n / 16}) catch {};
        const argv = gpa.alloc(?[*:0]const u8, 6 + n + 1) catch return;
        defer gpa.free(argv);
        const plain = gpa.alloc(?[*:0]const u8, 4 + n + 1) catch return;
        defer gpa.free(plain);
        argv[0] = "timeout";
        argv[1] = &secs;
        argv[2] = "sh";
        argv[3] = "-c";
        argv[4] = script;
        argv[5] = "sh";
        plain[0] = "sh";
        plain[1] = "-c";
        plain[2] = script;
        plain[3] = "sh";
        for (v.queued.items, 0..) |cm, i| {
            argv[6 + i] = cm;
            plain[4 + i] = cm;
        }
        argv[6 + n] = null;
        plain[4 + n] = null;

        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return;
        _ = c.fcntl(fds[0], c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(fds[1], c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(fds[0], c.F_SETFL, c.O_NONBLOCK);

        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            return; // commands stay queued for the next request
        }
        if (pid == 0) {
            _ = c.dup2(fds[1], 1);
            _ = c.execvp("timeout", @ptrCast(argv.ptr));
            _ = c.execvp("sh", @ptrCast(plain.ptr)); // no coreutils timeout: run unguarded
            c._exit(127);
        }
        _ = c.close(fds[1]);
        v.queued.clearRetainingCapacity();
        v.want_read = false;
        v.fd = fds[0];
        v.pid = pid;
        v.len = 0;
    }

    /// Drain the child's output; when it finishes, parse it into `st` and start the next batch.
    pub fn service(v: *Volume, st: *store.Status) void {
        if (v.fd < 0) return;
        while (true) {
            var scratch: [64]u8 = undefined;
            const n = c.read(v.fd, &scratch, scratch.len);
            if (n > 0) {
                // Only the first line matters; anything past the buffer is dropped, still drained.
                const k: usize = @min(@as(usize, @intCast(n)), v.buf.len - v.len);
                @memcpy(v.buf[v.len..][0..k], scratch[0..k]);
                v.len += k;
                continue;
            }
            if (n < 0) {
                const e = c.__errno_location().*;
                if (e == c.EAGAIN or e == c.EINTR) return; // child still running
            }
            break; // EOF (or a real error): the child is done
        }
        _ = c.close(v.fd);
        v.fd = -1;
        _ = c.waitpid(v.pid, null, 0); // EOF means every writer exited, so this returns at once
        parseVolume(st, v.buf[0..v.len]);
        if (v.queued.items.len > 0 or v.want_read) v.start();
    }
};

fn parseVolume(st: *store.Status, data: []const u8) void {
    var pct: i32 = -1;
    var muted = false;
    const line = std.mem.sliceTo(data, '\n');
    if (std.mem.startsWith(u8, line, "Volume: ")) {
        var it = std.mem.tokenizeScalar(u8, line["Volume: ".len..], ' ');
        if (it.next()) |num| {
            const v = std.fmt.parseFloat(f32, num) catch -1;
            if (v >= 0 and v < 100) pct = @intFromFloat(@round(v * 100));
        }
        muted = std.mem.indexOf(u8, line, "MUTED") != null;
    }
    if (pct != st.vol_pct or muted != st.muted) {
        st.vol_pct = pct;
        st.muted = muted;
        st.version +%= 1;
    }
}
