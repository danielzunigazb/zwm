// Synced lyrics on the desktop: the previous line and the next one dimmed around the current one,
// which is highlighted. Lines are fetched from lrclib.net (as LRC text, "[mm:ss.xx] words") by a
// curl child so the event loop never waits on the network, cached on disk by song, and followed
// with the playback position the music card already keeps. A line change glides the whole block up
// on a critically damped spring while colours cross-fade, so nothing jumps.

const std = @import("std");
const cfg = @import("config.zig");
const c = @import("c.zig").c;
const gfx = @import("gfx.zig");
const anim = @import("anim.zig");
const store = @import("store.zig");

const gpa = std.heap.c_allocator;

const api_base = "https://lrclib.net/api/";
const user_agent = "zwm (https://github.com/danielzunigazb/zwm)";
const reply_cap: usize = 1 << 20; // a /search reply carries the lyrics of every candidate
const cache_cap: usize = 128 * 1024;
const max_lines = 1024;
const max_duration_diff_s: f64 = 3; // lrclib's own matching tolerance is 2 s

// ---- LRC ----

pub const Line = struct { t_ms: u32, off: u32, len: u8 };

pub const Parsed = struct {
    lines: []Line,
    text: []u8, // every line's (sanitized) words back to back

    pub fn deinit(p: Parsed) void {
        gpa.free(p.lines);
        gpa.free(p.text);
    }

    pub fn textOf(p: *const Parsed, i: usize) []const u8 {
        const l = p.lines[i];
        return p.text[l.off..][0..l.len];
    }
};

fn digits(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 6) return null;
    var v: u32 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        v = v * 10 + (ch - '0');
    }
    return v;
}

/// "mm:ss", "mm:ss.x", "mm:ss.xx" or "mm:ss.xxx" (what sits between the brackets) in milliseconds.
/// Null for anything else, which is how tags like "ar:Someone" are told apart.
fn parseStamp(s: []const u8) ?u32 {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    const min = digits(s[0..colon]) orelse return null;
    var secs = s[colon + 1 ..];
    var frac_ms: u32 = 0;
    if (std.mem.indexOfScalar(u8, secs, '.')) |dot| {
        const frac = secs[dot + 1 ..];
        secs = secs[0..dot];
        if (frac.len == 0 or frac.len > 3) return null;
        frac_ms = (digits(frac) orelse return null) * std.math.pow(u32, 10, @intCast(3 - frac.len));
    }
    const sec = digits(secs) orelse return null;
    if (min > 9999 or sec > 99) return null;
    return min * 60_000 + sec * 1000 + frac_ms;
}

fn byTime(_: void, a: Line, b: Line) bool {
    return a.t_ms < b.t_ms;
}

/// Parse LRC text into lines sorted by time. A line may carry several stamps ("[00:10.00][01:30.00]
/// words": a repeated chorus); tag lines ("[ar:...]") are skipped; lines with no words are kept,
/// they mark the silences.
pub fn parse(lrc: []const u8) !Parsed {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(gpa);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);

    var rows = std.mem.splitScalar(u8, lrc, '\n');
    while (rows.next()) |raw| {
        var rest = std.mem.trim(u8, raw, " \t\r");
        var stamps: [8]u32 = undefined;
        var n: usize = 0;
        while (rest.len > 0 and rest[0] == '[') {
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse break;
            const t = parseStamp(rest[1..close]) orelse break;
            if (n < stamps.len) {
                stamps[n] = t;
                n += 1;
            }
            rest = rest[close + 1 ..];
        }
        if (n == 0) continue;

        var clean: [256]u8 = undefined;
        const len = store.sanitize(&clean, std.mem.trim(u8, rest, " \t"));
        const off: u32 = @intCast(text.items.len);
        try text.appendSlice(gpa, clean[0..len]);
        for (stamps[0..n]) |t| {
            if (lines.items.len >= max_lines) break;
            try lines.append(gpa, .{ .t_ms = t, .off = off, .len = len });
        }
    }
    std.sort.block(Line, lines.items, {}, byTime);
    return .{ .lines = try lines.toOwnedSlice(gpa), .text = try text.toOwnedSlice(gpa) };
}

/// Index of the line being sung at `t_ms`: the last one that started, -1 before the first.
pub fn lineAt(lines: []const Line, t_ms: i64) i32 {
    var lo: usize = 0;
    var hi: usize = lines.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (@as(i64, lines[mid].t_ms) <= t_ms) lo = mid + 1 else hi = mid;
    }
    return @as(i32, @intCast(lo)) - 1;
}

// ---- lrclib ----

/// "Song - Remastered 2011", "Song (feat. X)", "Song [Live]" -> "Song". The same text when there is
/// nothing to cut. Streaming services decorate titles; lrclib mostly stores the plain one.
fn cleanTitle(title: []const u8) []const u8 {
    var end = title.len;
    if (std.mem.indexOf(u8, title, " - ")) |i| end = i;
    if (std.mem.indexOfAny(u8, title[0..end], "([")) |i| {
        if (i > 0) end = i;
    }
    const t = std.mem.trim(u8, title[0..end], " ");
    return if (t.len == 0) title else t;
}

const Entry = struct {
    duration: ?f64 = null,
    syncedLyrics: ?[]const u8 = null,
};

/// The synced lyrics inside an lrclib reply, as a copy owned by the caller: the object of
/// /api/get, or the candidate of /api/search whose length is closest to the song's (within
/// `max_duration_diff_s`). `secs` of 0 = unknown length: the first candidate with lyrics.
fn pickSynced(json: []const u8, secs: u32) ?[]u8 {
    const body = std.mem.trim(u8, json, " \t\r\n");
    if (body.len == 0) return null;
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    if (body[0] == '{') {
        const p = std.json.parseFromSlice(Entry, gpa, body, opts) catch return null;
        defer p.deinit();
        const s = p.value.syncedLyrics orelse return null;
        return if (s.len == 0) null else gpa.dupe(u8, s) catch null;
    }
    if (body[0] != '[') return null;
    const p = std.json.parseFromSlice([]Entry, gpa, body, opts) catch return null;
    defer p.deinit();
    var best: ?[]const u8 = null;
    var best_diff: f64 = max_duration_diff_s + 1;
    for (p.value) |e| {
        const s = e.syncedLyrics orelse continue;
        if (s.len == 0) continue;
        const diff: f64 = if (secs == 0) 0 else @abs((e.duration orelse continue) - @as(f64, @floatFromInt(secs)));
        if (diff <= max_duration_diff_s and diff < best_diff) {
            best = s;
            best_diff = diff;
        }
    }
    return if (best) |s| gpa.dupe(u8, s) catch null else null;
}

/// The song being followed, copied out of the store.
const Track = struct {
    title: [128]u8 = undefined,
    title_len: u8 = 0,
    artist: [64]u8 = undefined,
    artist_len: u8 = 0,
    secs: u32 = 0, // 0 = unknown

    fn from(m: *const store.Music) ?Track {
        if (!m.have or m.title_len == 0) return null;
        var t = Track{ .title_len = m.title_len, .artist_len = m.artist_main_len };
        @memcpy(t.title[0..m.title_len], m.titleSlice());
        @memcpy(t.artist[0..m.artist_main_len], m.mainArtistSlice());
        t.secs = @intCast(@max(@divFloor(m.len_us + 500_000, 1_000_000), 0));
        return t;
    }

    fn titleS(t: *const Track) []const u8 {
        return t.title[0..t.title_len];
    }
    fn artistS(t: *const Track) []const u8 {
        return t.artist[0..t.artist_len];
    }

    /// Identity of the song, also the name of its cache file. Never 0 (that is "no song").
    fn key(t: *const Track) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(t.titleS());
        h.update("\x00");
        h.update(t.artistS());
        h.update("\x00");
        h.update(std.mem.asBytes(&t.secs));
        return h.final() | 1;
    }
};

// ---- disk cache ----

fn cacheDir(buf: []u8) ?[:0]const u8 {
    if (c.getenv("XDG_CACHE_HOME")) |x| {
        if (x[0] != 0) return std.fmt.bufPrintZ(buf, "{s}/zwm/lyrics", .{std.mem.span(x)}) catch null;
    }
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.cache/zwm/lyrics", .{std.mem.span(home)}) catch null;
}

fn cachePath(buf: []u8, key: u64) ?[:0]const u8 {
    var db: [200]u8 = undefined;
    const dir = cacheDir(&db) orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/{x:0>16}.lrc", .{ dir, key }) catch null;
}

/// mkdir -p, owner only.
fn makeDirs(dir: []const u8) void {
    var buf: [200:0]u8 = undefined;
    if (dir.len >= buf.len) return;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    for (1..dir.len + 1) |i| {
        if (buf[i] != '/' and buf[i] != 0) continue;
        const keep = buf[i];
        buf[i] = 0;
        _ = c.mkdir(&buf, 0o700);
        buf[i] = keep;
    }
}

fn saveCache(key: u64, lrc: []const u8) void {
    var db: [200]u8 = undefined;
    const dir = cacheDir(&db) orelse return;
    makeDirs(dir);
    var pb: [256]u8 = undefined;
    var tb: [264]u8 = undefined;
    const path = cachePath(&pb, key) orelse return;
    const tmp = std.fmt.bufPrintZ(&tb, "{s}.tmp", .{path}) catch return;
    const fd = c.open(tmp, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return;
    var done: usize = 0;
    while (done < lrc.len) {
        const n = c.write(fd, lrc.ptr + done, lrc.len - done);
        if (n <= 0) break;
        done += @intCast(n);
    }
    _ = c.close(fd);
    // Renamed only when whole, so a half-written file never reads back as the song's lyrics.
    if (done == lrc.len) _ = c.rename(tmp, path) else _ = c.unlink(tmp);
}

// ---- layout ----

const pitch: f32 = 56; // distance between the baselines of consecutive lines
const band_h: u16 = 208;
const band_max_w: u16 = 1400;
const px_base: f32 = 30;
const px_min: f32 = 18;
const side_pad: f32 = 48;

/// How a line at `d` line-heights from the centre looks: `vis` (0..1) fades the lines leaving the
/// three shown, `hot` (0..1) is how much it is the current one. At rest the line at 0 is hot, the
/// ones at +-1 are dim, everything else is invisible.
fn weights(d: f32) struct { vis: f32, hot: f32 } {
    const a = @abs(d);
    const vis = if (a <= 1) 1 else if (a < 2) 2 - a else 0;
    const h = std.math.clamp(1 - a, 0, 1);
    return .{ .vis = vis, .hot = h * h * (3 - 2 * h) };
}

fn advance(px: f32) f32 {
    return if (gfx.hasTtf()) px * 0.6 else @as(f32, @floatFromInt(@max(1, @as(i32, @intFromFloat(px / 13.3 + 0.5))))) * gfx.glyph_w;
}

/// Draw `text` centred on x = `cx` with its baseline at `base`, shrunk (then cut with "...") to fit `max_w`.
fn drawCentered(cv: *gfx.Canvas, cx: f32, base: i32, text: []const u8, color: u32, max_w: f32) void {
    if (text.len == 0) return;
    var px = px_base;
    var shown = text;
    var cut = false;
    const n: f32 = @floatFromInt(gfx.cpCount(text));
    if (n * advance(px) > max_w) {
        px = @max(px_min, @floor(px * max_w / (n * advance(px))));
        if (n * advance(px) > max_w) {
            const keep: usize = @intFromFloat(@max(max_w / advance(px) - 3, 1));
            shown = text[0..gfx.cpOffset(text, keep)];
            cut = true;
        }
    }
    const w = (@as(f32, @floatFromInt(gfx.cpCount(shown))) + if (cut) @as(f32, 3) else 0) * advance(px);
    const x: i32 = @intFromFloat(@round(cx - w / 2));
    const end = cv.textAt(x, base, shown, color, px, true);
    if (cut) _ = cv.textAt(end, base, "...", color, px, true);
}

// ---- the widget ----

pub const Lyrics = struct {
    conn: *c.xcb_connection_t,
    screen: c.xcb_screen_t,
    surf: ?gfx.Surface = null,

    // The song the lines below belong to (key 0 = none) and the lines themselves.
    track: ?Track = null,
    key: u64 = 0,
    parsed: ?Parsed = null,

    // lrclib lookup, one curl child at a time.
    fd: c_int = -1,
    pid: c.pid_t = 0,
    reply: ?[]u8 = null,
    got: usize = 0,
    overflow: bool = false,
    attempt: u8 = 0, // 0: exact title, 1: title without decorations, 2: search
    stale: bool = false, // the song changed while the child was running

    // Playback clock: the position seen at `anchor_ms`, run forward while playing.
    anchor_us: i64 = 0,
    anchor_ms: i64 = 0,
    seen_pos_us: i64 = -1,
    playing: bool = false,

    // Animation. `scroll` is in px: line i sits at i * pitch.
    idx: i32 = -1,
    scroll: f32 = 0,
    vel: f32 = 0,
    alpha: f32 = 0,
    alpha_vel: f32 = 0,
    dirty: bool = false,

    pub fn pollFd(l: *const Lyrics) c_int {
        return l.fd;
    }

    /// True while there are lines on screen or being fetched, i.e. the playback position is worth keeping fresh.
    pub fn active(l: *const Lyrics) bool {
        return l.parsed != null;
    }

    fn posMs(l: *const Lyrics, now: i64) i64 {
        var us = l.anchor_us;
        if (l.playing) us += (now - l.anchor_ms) * 1000;
        return @divFloor(us, 1000) + cfg.lyrics_lead_ms;
    }

    /// Milliseconds until the next line starts, for poll()'s timeout: the only wakeups lyrics need.
    pub fn wakeInMs(l: *const Lyrics, now: i64) ?i64 {
        const p = l.parsed orelse return null;
        if (!l.playing) return null;
        const next: usize = @intCast(l.idx + 1);
        if (next >= p.lines.len) return null;
        return @max(@as(i64, p.lines[next].t_ms) - l.posMs(now), 0) + 5;
    }

    /// Follow the store: a new song starts a lookup, the playback position moves the current line.
    pub fn sync(l: *Lyrics, st: *const store.Store, now: i64) void {
        if (!cfg.lyrics) return;
        const m = &st.music;
        if (m.pos_us != l.seen_pos_us or m.playing != l.playing) {
            l.seen_pos_us = m.pos_us;
            l.anchor_us = m.pos_us;
            l.anchor_ms = now;
            l.playing = m.playing;
        }
        const track = if (st.lyrics_on) Track.from(m) else null; // switched off: no song, so no lookups
        const key: u64 = if (track) |t| t.key() else 0;
        if (key != l.key) {
            l.key = key;
            l.track = track;
            l.clear();
            // A child still running is for the song we just left (or for none): its reply is dropped.
            if (l.fd >= 0) l.stale = true else if (key != 0) l.begin(now);
        }
        if (l.parsed) |p| {
            const i = lineAt(p.lines, l.posMs(now));
            if (i != l.idx) l.idx = i;
        }
    }

    /// Drop the lines (and the window) of the song that was playing, or of all songs when switched off.
    fn clear(l: *Lyrics) void {
        if (l.parsed) |p| p.deinit();
        l.parsed = null;
        l.idx = -1;
        if (l.surf) |*s| s.destroy();
        l.surf = null;
    }

    /// Look the song up: the disk cache first, otherwise ask lrclib.
    fn begin(l: *Lyrics, now: i64) void {
        var pb: [256]u8 = undefined;
        if (cachePath(&pb, l.key)) |path| {
            const buf = gpa.alloc(u8, cache_cap) catch return;
            defer gpa.free(buf);
            const data = @import("bar.zig").readFile(path, buf);
            if (data.len > 0 and l.adopt(data, now)) return;
        }
        l.attempt = 0;
        l.fetch();
    }

    /// Take LRC text as the lyrics of the current song and fade them in. False if it has no lines.
    fn adopt(l: *Lyrics, lrc: []const u8, now: i64) bool {
        const p = parse(lrc) catch return false;
        if (p.lines.len == 0) {
            p.deinit();
            return false;
        }
        l.clear();
        l.parsed = p;
        l.idx = lineAt(p.lines, l.posMs(now));
        l.scroll = @as(f32, @floatFromInt(l.idx)) * pitch; // already there: no glide over the lines before it
        l.vel = 0;
        l.alpha = 0;
        l.alpha_vel = 0;
        l.dirty = true;
        const sw = l.screen.width_in_pixels;
        const w = @min(sw, band_max_w);
        var s = gfx.Surface.create(l.conn, &l.screen, @divTrunc(@as(i32, sw) - w, 2), @divTrunc(@as(i32, l.screen.height_in_pixels) - band_h, 2), w, band_h, 0, c.XCB_EVENT_MASK_EXPOSURE, cfg.desktop_bg) catch return true;
        s.map();
        s.setStack(false); // beneath tiled windows, like the clock
        l.surf = s;
        return true;
    }

    /// Start the curl child for the current attempt; with nothing left to try, the song has no lyrics.
    fn fetch(l: *Lyrics) void {
        const t = &(l.track orelse return);
        const clean = cleanTitle(t.titleS());
        if (l.attempt == 1 and clean.len == t.title_len) l.attempt = 2; // nothing was decorated: same query again
        if (l.attempt > 2) return;
        const search = l.attempt == 2;

        var tn: [160:0]u8 = undefined;
        var an: [96:0]u8 = undefined;
        var dn: [32:0]u8 = undefined;
        const title_arg = std.fmt.bufPrintZ(&tn, "track_name={s}", .{if (l.attempt == 0) t.titleS() else clean}) catch return;
        const artist_arg = std.fmt.bufPrintZ(&an, "artist_name={s}", .{t.artistS()}) catch return;
        const dur_arg = std.fmt.bufPrintZ(&dn, "duration={d}", .{t.secs}) catch return;

        // Arguments go straight to curl (no shell): the title is data from a stranger's tags.
        var argv = [_]?[*:0]const u8{null} ** 20;
        var n: usize = 0;
        for ([_][*:0]const u8{ "curl", "-fsS", "--max-time", "8", "-A", user_agent, "-G", "--data-urlencode" }) |a| {
            argv[n] = a;
            n += 1;
        }
        argv[n] = title_arg.ptr;
        n += 1;
        if (t.artist_len > 0) {
            argv[n] = "--data-urlencode";
            argv[n + 1] = artist_arg.ptr;
            n += 2;
        }
        if (!search and t.secs > 0) { // /search has no duration filter; the candidates are matched by it afterwards
            argv[n] = "--data-urlencode";
            argv[n + 1] = dur_arg.ptr;
            n += 2;
        }
        argv[n] = if (search) api_base ++ "search" else api_base ++ "get";

        const buf = gpa.alloc(u8, reply_cap) catch return;
        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) {
            gpa.free(buf);
            return;
        }
        _ = c.fcntl(fds[0], c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(fds[1], c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(fds[0], c.F_SETFL, c.O_NONBLOCK);
        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            gpa.free(buf);
            return;
        }
        if (pid == 0) {
            const null_fd = c.open("/dev/null", c.O_RDWR);
            if (null_fd >= 0) {
                _ = c.dup2(null_fd, 0);
                _ = c.dup2(null_fd, 2);
            }
            _ = c.dup2(fds[1], 1);
            _ = c.execvp("curl", @ptrCast(&argv));
            c._exit(127);
        }
        _ = c.close(fds[1]);
        l.fd = fds[0];
        l.pid = pid;
        l.reply = buf;
        l.got = 0;
        l.overflow = false;
    }

    /// Drain the child; when it ends, use its reply or move on to the next kind of query.
    pub fn service(l: *Lyrics, now: i64) void {
        if (l.fd < 0) return;
        const buf = l.reply orelse return;
        while (true) {
            var scratch: [4096]u8 = undefined;
            const n = c.read(l.fd, &scratch, scratch.len);
            if (n > 0) {
                const len: usize = @intCast(n);
                const k = @min(len, buf.len - l.got);
                @memcpy(buf[l.got..][0..k], scratch[0..k]);
                l.got += k;
                if (k < len) l.overflow = true;
                continue;
            }
            if (n < 0) {
                const e = c.__errno_location().*;
                if (e == c.EAGAIN or e == c.EINTR) return; // curl still running
            }
            break;
        }
        _ = c.close(l.fd);
        l.fd = -1;
        _ = c.waitpid(l.pid, null, 0);
        // Let go of the reply before anything below starts the next child, which brings its own.
        l.reply = null;
        defer gpa.free(buf);

        if (l.stale) { // the song changed meanwhile: that reply is for the previous one
            l.stale = false;
            if (l.key != 0) l.begin(now);
            return;
        }
        if (!l.overflow and l.got > 0) {
            const secs = if (l.track) |t| t.secs else 0;
            if (pickSynced(buf[0..l.got], secs)) |lrc| {
                defer gpa.free(lrc);
                if (l.adopt(lrc, now)) {
                    saveCache(l.key, lrc);
                    return;
                }
            }
        }
        l.attempt += 1;
        l.fetch();
    }

    pub fn step(l: *Lyrics, dt: f32) bool {
        if (l.parsed == null) return false;
        const target = @as(f32, @floatFromInt(l.idx)) * pitch;
        // A seek across many lines: nobody can follow a glide over lines that are not on screen.
        if (@abs(target - l.scroll) > 3 * pitch) {
            l.scroll = target;
            l.vel = 0;
            l.dirty = true;
        }
        const before = [2]f32{ l.scroll, l.alpha };
        const a = anim.smooth(&l.scroll, &l.vel, target, dt, cfg.k_lyrics, 0.3);
        const b = anim.smooth(&l.alpha, &l.alpha_vel, 1, dt, 7, 0.01);
        if (l.scroll != before[0] or l.alpha != before[1]) l.dirty = true;
        return a or b;
    }

    pub fn expose(l: *Lyrics, win: c.xcb_window_t) void {
        if (l.surf) |*s| if (s.win == win) s.flush();
    }

    pub fn draw(l: *Lyrics) void {
        const s = &(l.surf orelse return);
        const p = l.parsed orelse return;
        if (!l.dirty) return;
        l.dirty = false;

        const cv = &s.cv;
        cv.fill(cfg.desktop_bg);
        const cx: f32 = @as(f32, @floatFromInt(cv.w)) / 2;
        const cy: f32 = @as(f32, @floatFromInt(cv.h)) / 2;
        const first = @floor(l.scroll / pitch) - 1;
        var k: i32 = 0;
        while (k < 4) : (k += 1) {
            const i: i32 = @as(i32, @intFromFloat(first)) + k;
            if (i < 0 or i >= p.lines.len) continue;
            const d = (@as(f32, @floatFromInt(i)) * pitch - l.scroll) / pitch;
            const w = weights(d);
            if (w.vis <= 0) continue;
            const color = gfx.blend(cfg.desktop_bg, gfx.blend(cfg.fg_dim, cfg.fg_bright, w.hot), w.vis * l.alpha);
            const base: i32 = @intFromFloat(@round(cy + d * pitch + px_base * 0.35));
            drawCentered(cv, cx, base, p.textOf(@intCast(i)), color, @as(f32, @floatFromInt(cv.w)) - 2 * side_pad);
        }
        s.flush();
    }
};

// ---- tests (the words are made up) ----

test "parse: stamps, tags, repeats and silences" {
    const p = try parse(
        \\[ar:Nobody]
        \\[00:12.50] alpha beta
        \\[00:03.00]gamma
        \\[00:20.5][00:40.25] delta
        \\[00:30.00]
        \\[bad] zeta
        \\no stamp at all
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 5), p.lines.len);
    try std.testing.expectEqual(@as(u32, 3000), p.lines[0].t_ms);
    try std.testing.expectEqualStrings("gamma", p.textOf(0));
    try std.testing.expectEqualStrings("alpha beta", p.textOf(1));
    try std.testing.expectEqual(@as(u32, 20500), p.lines[2].t_ms); // ".5" is half a second, not 5 ms
    try std.testing.expectEqualStrings("", p.textOf(3)); // the silence is kept
    try std.testing.expectEqualStrings("delta", p.textOf(4)); // second stamp of the repeated line
    try std.testing.expectEqual(@as(u32, 40250), p.lines[4].t_ms);
}

test "parseStamp: only real time stamps" {
    try std.testing.expectEqual(@as(?u32, 61_005), parseStamp("01:01.005"));
    try std.testing.expectEqual(@as(?u32, 5000), parseStamp("00:05"));
    try std.testing.expectEqual(@as(?u32, null), parseStamp("ti:Song"));
    try std.testing.expectEqual(@as(?u32, null), parseStamp("00:05."));
    try std.testing.expectEqual(@as(?u32, null), parseStamp("-1:05"));
    try std.testing.expectEqual(@as(?u32, null), parseStamp(""));
}

test "lineAt: before the first, on a boundary, after the last" {
    const lines = [_]Line{ .{ .t_ms = 1000, .off = 0, .len = 0 }, .{ .t_ms = 2000, .off = 0, .len = 0 }, .{ .t_ms = 2000, .off = 0, .len = 0 } };
    try std.testing.expectEqual(@as(i32, -1), lineAt(&lines, 999));
    try std.testing.expectEqual(@as(i32, 0), lineAt(&lines, 1000));
    try std.testing.expectEqual(@as(i32, 2), lineAt(&lines, 2000)); // equal stamps: the later one wins
    try std.testing.expectEqual(@as(i32, 2), lineAt(&lines, 999_999));
    try std.testing.expectEqual(@as(i32, -1), lineAt(&.{}, 5));
}

test "cleanTitle: cuts decorations, keeps plain titles" {
    try std.testing.expectEqualStrings("Alpha", cleanTitle("Alpha - Remastered 2011"));
    try std.testing.expectEqualStrings("Alpha", cleanTitle("Alpha (feat. Someone)"));
    try std.testing.expectEqualStrings("Alpha", cleanTitle("Alpha [Live] - Radio Edit"));
    try std.testing.expectEqualStrings("Alpha Beta", cleanTitle("Alpha Beta"));
    try std.testing.expectEqualStrings("(Alpha) Beta", cleanTitle("(Alpha) Beta")); // starts with the bracket: nothing to cut before it
}

test "pickSynced: a /get object, and the closest length among /search candidates" {
    const one = pickSynced("{\"duration\":200.0,\"syncedLyrics\":\"[00:01.00] one\",\"plainLyrics\":\"one\"}", 200).?;
    defer gpa.free(one);
    try std.testing.expectEqualStrings("[00:01.00] one", one);

    const list =
        \\[{"duration":180,"syncedLyrics":"[00:01.00] short"},
        \\ {"duration":null,"syncedLyrics":"[00:01.00] unknown"},
        \\ {"duration":201.4,"syncedLyrics":"[00:01.00] right"},
        \\ {"duration":199,"syncedLyrics":null}]
    ;
    const best = pickSynced(list, 200).?;
    defer gpa.free(best);
    try std.testing.expectEqualStrings("[00:01.00] right", best);
    try std.testing.expect(pickSynced(list, 300) == null); // nothing near that length
    const any = pickSynced(list, 0).?; // unknown length: first with lyrics
    defer gpa.free(any);
    try std.testing.expectEqualStrings("[00:01.00] short", any);

    try std.testing.expect(pickSynced("{\"syncedLyrics\":null,\"instrumental\":true}", 200) == null);
    try std.testing.expect(pickSynced("not json", 200) == null);
    try std.testing.expect(pickSynced("", 200) == null);
}

test "weights: three lines at rest, the current one hot" {
    const cur = weights(0);
    try std.testing.expectEqual(@as(f32, 1), cur.vis);
    try std.testing.expectEqual(@as(f32, 1), cur.hot);
    for ([_]f32{ -1, 1 }) |d| {
        const w = weights(d);
        try std.testing.expectEqual(@as(f32, 1), w.vis);
        try std.testing.expectEqual(@as(f32, 0), w.hot);
    }
    try std.testing.expectEqual(@as(f32, 0), weights(2).vis);
    try std.testing.expectEqual(@as(f32, 0), weights(-3).vis);
    const mid = weights(0.5); // halfway through a change: the line is half way to hot
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid.hot, 0.001);
}

test "Track: key depends on title, artist and length" {
    var m = store.Music{ .have = true, .len_us = 200_000_000 };
    m.title_len = store.sanitize(&m.title, "Alpha");
    m.setMainArtist("Nobody, Somebody");
    try std.testing.expectEqualStrings("Nobody", m.mainArtistSlice());
    const a = Track.from(&m).?;
    try std.testing.expectEqual(@as(u32, 200), a.secs);
    try std.testing.expect(a.key() != 0);
    m.len_us = 201_000_000;
    try std.testing.expect(Track.from(&m).?.key() != a.key());
    m.have = false;
    try std.testing.expect(Track.from(&m) == null);
}
