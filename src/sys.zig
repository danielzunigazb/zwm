// Process helpers: the non-blocking wpctl volume probe, and fire-and-forget spawn for shell commands.

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
        _ = std.fmt.bufPrintZ(&secs, "{d}", .{3 + n / 16}) catch unreachable; // "{d}" of a small integer always fits
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

/// Side length of the cover the panel shows. ImageMagick scales to exactly this, so the WM needs no
/// image decoder (or scaler) of its own.
pub const art_px: usize = 84;
const art_bytes = art_px * art_px * 4;

/// `file:///a%20b.png` -> `/a b.png` in `out`. http(s) URLs pass through; anything else is refused.
fn artSource(url: []const u8, out: []u8) ?[]const u8 {
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
        if (url.len > out.len) return null;
        @memcpy(out[0..url.len], url);
        return out[0..url.len];
    }
    const path = if (std.mem.startsWith(u8, url, "file://")) url["file://".len..] else return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (n += 1) {
        if (n >= out.len) return null;
        if (path[i] == '%' and i + 2 < path.len) {
            if (std.fmt.parseInt(u8, path[i + 1 ..][0..2], 16)) |b| {
                out[n] = b;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = path[i];
        i += 1;
    }
    if (n == 0 or out[0] != '/') return null; // also keeps ImageMagick from reading "coder:" prefixes
    return out[0..n];
}

/// Cover art for the panel's music card, rendered by a child process (curl for remote covers,
/// ImageMagick to decode and scale) so the event loop never waits on the network or a decoder.
pub const Art = struct {
    pixels: [art_px * art_px]u32 = undefined, // 0x00RRGGBB, valid while `have`
    have: bool = false,
    incoming: [art_px * art_px]u32 = undefined,
    got: usize = 0, // bytes of `incoming` filled so far
    fd: c_int = -1,
    pid: c.pid_t = 0,
    wanted: [256]u8 = undefined,
    wanted_len: usize = 0,
    loading: [256]u8 = undefined,
    loading_len: usize = 0,

    const script =
        \\im() { if command -v magick >/dev/null 2>&1; then magick "$@"; else convert "$@"; fi; }
        \\args="-resize 84x84^ -gravity center -extent 84x84 -background black -alpha remove -alpha off -depth 8 bgra:-"
        \\case "$1" in
        \\  http*) curl -fsSL --max-time 6 --max-filesize 10000000 -- "$1" | im "-[0]" $args ;;
        \\  *) im "$1[0]" $args ;;
        \\esac 2>/dev/null
    ;

    pub fn pollFd(a: *const Art) c_int {
        return a.fd;
    }

    /// Point the card at the current track's cover; the previous cover goes away at once.
    pub fn want(a: *Art, st: *store.Store, url: []const u8) void {
        if (std.mem.eql(u8, url, a.wanted[0..a.wanted_len]) or url.len > a.wanted.len) return;
        @memcpy(a.wanted[0..url.len], url);
        a.wanted_len = url.len;
        if (a.have) {
            a.have = false;
            st.version +%= 1;
        }
        if (a.fd < 0) a.start();
    }

    fn start(a: *Art) void {
        if (a.wanted_len == 0) return;
        var src: [257]u8 = undefined; // room for the NUL
        const s = artSource(a.wanted[0..a.wanted_len], src[0..256]) orelse {
            a.loading_len = a.wanted_len; // nothing to fetch; remember so we do not retry
            @memcpy(a.loading[0..a.wanted_len], a.wanted[0..a.wanted_len]);
            return;
        };
        src[s.len] = 0;
        @memcpy(a.loading[0..a.wanted_len], a.wanted[0..a.wanted_len]);
        a.loading_len = a.wanted_len;

        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return;
        _ = c.fcntl(fds[0], c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(fds[1], c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(fds[0], c.F_SETFL, c.O_NONBLOCK);
        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            return;
        }
        if (pid == 0) {
            _ = c.dup2(fds[1], 1);
            const argv = [_:null]?[*:0]const u8{ "timeout", "10", "sh", "-c", script, "sh", @ptrCast(&src) };
            _ = c.execvp("timeout", @ptrCast(&argv));
            const plain = [_:null]?[*:0]const u8{ "sh", "-c", script, "sh", @ptrCast(&src) };
            _ = c.execvp("sh", @ptrCast(&plain)); // no coreutils timeout: run unguarded
            c._exit(127);
        }
        _ = c.close(fds[1]);
        a.fd = fds[0];
        a.pid = pid;
        a.got = 0;
    }

    /// Drain the child; when it finishes keep the cover if it is still the one wanted, then start
    /// on a newer one if the track changed meanwhile.
    pub fn service(a: *Art, st: *store.Store) void {
        if (a.fd < 0) return;
        const bytes = std.mem.sliceAsBytes(&a.incoming);
        while (true) {
            var scratch: [4096]u8 = undefined;
            const n = c.read(a.fd, &scratch, scratch.len);
            if (n > 0) {
                const k: usize = @min(@as(usize, @intCast(n)), bytes.len - a.got); // extra bytes: drained, dropped
                @memcpy(bytes[a.got..][0..k], scratch[0..k]);
                a.got += k;
                continue;
            }
            if (n < 0) {
                const e = c.__errno_location().*;
                if (e == c.EAGAIN or e == c.EINTR) return; // child still running
            }
            break;
        }
        _ = c.close(a.fd);
        a.fd = -1;
        _ = c.waitpid(a.pid, null, 0); // EOF means the writer exited
        const current = std.mem.eql(u8, a.loading[0..a.loading_len], a.wanted[0..a.wanted_len]);
        if (current and a.got == art_bytes) {
            a.pixels = a.incoming;
            a.have = true;
            st.version +%= 1;
        }
        if (!current) a.start();
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

/// Brightness via brightnessctl
pub const Brightness = struct {
    fd: c_int = -1,
    pid: c.pid_t = 0,
    want_read: bool = false,

    pub fn request(b: *Brightness) void {
        if (b.fd >= 0) {
            b.want_read = true;
            return;
        }
        b.start();
    }

    pub fn pollFd(b: *const Brightness) c_int {
        return b.fd;
    }

    fn start(b: *Brightness) void {
        const argv = [_:null]?[*:0]const u8{ "sh", "-c", "brightnessctl info 2>/dev/null | grep -oP '\\d+%' | head -1 | tr -d '%'" };
        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return;
        _ = c.fcntl(fds[0], c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(fds[1], c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(fds[0], c.F_SETFL, c.O_NONBLOCK);
        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            return;
        }
        if (pid == 0) {
            _ = c.dup2(fds[1], 1);
            _ = c.execvp("sh", @ptrCast(&argv));
            c._exit(127);
        }
        _ = c.close(fds[1]);
        b.fd = fds[0];
        b.pid = pid;
    }

    pub fn service(b: *Brightness, st: *store.Status) void {
        if (b.fd < 0) return;
        while (true) {
            var scratch: [64]u8 = undefined;
            const n = c.read(b.fd, &scratch, scratch.len);
            if (n > 0) {
                const line = std.mem.sliceTo(scratch[0..@intCast(n)], '\n');
                const pct = std.fmt.parseInt(i32, std.mem.trim(u8, line, " \n"), 10) catch -1;
                if (pct != st.brightness_pct) {
                    st.brightness_pct = pct;
                    st.version +%= 1;
                }
                continue;
            }
            if (n < 0) {
                const e = c.__errno_location().*;
                if (e == c.EAGAIN or e == c.EINTR) return;
            }
            break;
        }
        _ = c.close(b.fd);
        b.fd = -1;
        _ = c.waitpid(b.pid, null, 0);
        if (b.want_read) {
            b.want_read = false;
            b.start();
        }
    }
};

test "artSource: file URLs are decoded, anything else is refused" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp/a b/c.png", artSource("file:///tmp/a%20b/c.png", &buf).?);
    try std.testing.expectEqualStrings("/x%zz", artSource("file:///x%zz", &buf).?);
    try std.testing.expectEqualStrings("https://i.scdn.co/image/ab67", artSource("https://i.scdn.co/image/ab67", &buf).?);
    try std.testing.expect(artSource("data:image/png;base64,AAAA", &buf) == null);
    try std.testing.expect(artSource("file://relative.png", &buf) == null);
    try std.testing.expect(artSource("", &buf) == null);
}
