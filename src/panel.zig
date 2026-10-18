// Side panel (calendar, music, notifications), desktop widget and notification toasts.
// Everything is a gfx.Surface drawn from the shared store.

const std = @import("std");
const cfg = @import("config.zig");
const c = @import("c.zig").c;
const gfx = @import("gfx.zig");
const icons = @import("icons.zig");
const store = @import("store.zig");

const Store = store.Store;
const glyph_w = gfx.glyph_w;

const full_days = [_][]const u8{ "domingo", "lunes", "martes", "miercoles", "jueves", "viernes", "sabado" };
const full_months = [_][]const u8{ "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre" };

// ---- calendar math ----

fn isLeap(y: i32) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn daysIn(y: i32, m0: i32) i32 {
    const t = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return if (m0 == 1 and isLeap(y)) 29 else t[@intCast(m0)];
}

fn weeksInYear(y: i32) i32 {
    const p = struct {
        fn f(yy: i32) i32 {
            return @mod(yy + @divFloor(yy, 4) - @divFloor(yy, 100) + @divFloor(yy, 400), 7);
        }
    }.f;
    return if (p(y) == 4 or p(y - 1) == 3) 53 else 52;
}

fn isoWeek(year: i32, yday0: i32, wday: i32) i32 {
    const wd = if (wday == 0) 7 else wday;
    const w = @divFloor(yday0 + 1 - wd + 10, 7);
    if (w < 1) return weeksInYear(year - 1);
    if (w > weeksInYear(year)) return 1;
    return w;
}

fn localNow() c.struct_tm {
    var now: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&now, &tm);
    return tm;
}

pub fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

// ---- side panel ----

pub const Click = union(enum) { prev, play, next, dismiss: u32 };

const Hit = struct { x: i32, y: i32, w: i32, h: i32, what: Click };

pub const panel_w: u16 = 320;
const pad = 14;
const card_gap = 12;

pub const Panel = struct {
    conn: *c.xcb_connection_t,
    screen: c.xcb_screen_t,
    surf: ?gfx.Surface = null,
    last_sig: u64 = 0,
    hits: [24]Hit = undefined,
    n_hits: usize = 0,

    pub fn visible(p: *const Panel) bool {
        return p.surf != null;
    }

    pub fn toggle(p: *Panel, st: *const Store) void {
        if (p.surf) |*s| {
            s.destroy();
            p.surf = null;
            return;
        }
        const gap: i32 = cfg.gap;
        const y: i32 = 2 * gap + cfg.bar_h;
        const h: u16 = @intCast(@as(i32, p.screen.height_in_pixels) - y - gap);
        const x: i32 = @as(i32, p.screen.width_in_pixels) - gap - panel_w;
        var s = gfx.Surface.create(p.conn, &p.screen, x, y, panel_w, h, 14, c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_BUTTON_PRESS, cfg.bar_bg) catch return;
        s.map();
        p.surf = s;
        p.draw(st, true);
    }

    pub fn raise(p: *Panel) void {
        if (p.surf) |*s| s.setStack(true);
    }

    pub fn expose(p: *Panel, win: c.xcb_window_t) void {
        if (p.surf) |*s| if (s.win == win) s.flush();
    }

    pub fn hit(p: *const Panel, win: c.xcb_window_t, x: i32, y: i32) ?Click {
        const s = p.surf orelse return null;
        if (s.win != win) return null;
        for (p.hits[0..p.n_hits]) |h| {
            if (x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h) return h.what;
        }
        return null;
    }

    fn addHit(p: *Panel, x: i32, y: i32, w: i32, h: i32, what: Click) void {
        if (p.n_hits < p.hits.len) {
            p.hits[p.n_hits] = .{ .x = x, .y = y, .w = w, .h = h, .what = what };
            p.n_hits += 1;
        }
    }

    pub fn draw(p: *Panel, st: *const Store, force: bool) void {
        const s = &(p.surf orelse return);
        const tm = localNow();
        const m = &st.music;
        const sig = std.hash.Wyhash.hash(0, std.mem.asBytes(&[_]i64{ st.version, tm.tm_min, tm.tm_hour, tm.tm_mday, @intFromBool(m.playing), @divFloor(m.pos_us, 1_000_000), @intFromBool(m.have) }));
        if (!force and sig == p.last_sig) return;
        p.last_sig = sig;
        p.n_hits = 0;

        const cv = &s.cv;
        cv.fill(cfg.bar_bg);
        const inner_w: i32 = panel_w - 2 * pad;
        var y: i32 = pad;

        // Calendar card.
        {
            const year = tm.tm_year + 1900;
            const first_wd = @mod(tm.tm_wday - (tm.tm_mday - 1), 7);
            const offset = @mod(first_wd + 6, 7); // Monday-first
            const dim = daysIn(year, tm.tm_mon);
            const rows = @divTrunc(offset + dim + 6, 7);
            const cell_w = 36; // 7 columns + 2px gaps fill the 236px card interior
            const cell_h = 30;
            const pitch_x = cell_w + 2;
            const pitch_y = cell_h + 2;
            const card_h = pad + 17 + 10 + pitch_y * (rows + 1) - 2 + pad;
            cv.roundRect(pad, y, inner_w, card_h, 10, cfg.desktop_bg);

            var hbuf: [32]u8 = undefined;
            const head = std.fmt.bufPrint(&hbuf, "{s} {d}", .{ full_months[@intCast(tm.tm_mon)], @as(u32, @intCast(year)) }) catch "";
            _ = cv.textAt(pad + pad, y + pad + 13, head, cfg.fg_bright, 13, true);
            var wbuf: [12]u8 = undefined;
            const wk = std.fmt.bufPrint(&wbuf, "sem {d}", .{@as(u32, @intCast(isoWeek(year, tm.tm_yday, tm.tm_wday)))}) catch "";
            _ = cv.textAt(pad + inner_w - pad - @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(wk.len)) * 6.6))), y + pad + 13, wk, cfg.fg_dim, 11, false);

            const gx = pad + pad;
            const gy = y + pad + 17 + 10;
            for ([_]u8{ 'L', 'M', 'M', 'J', 'V', 'S', 'D' }, 0..) |ch, i| {
                _ = cv.textAt(gx + @as(i32, @intCast(i)) * pitch_x + 14, gy + 19, &[1]u8{ch}, cfg.fg_dim, 12, false);
            }
            var day: i32 = 1;
            while (day <= dim) : (day += 1) {
                const idx = offset + day - 1;
                const col = @mod(idx, 7);
                const row = @divTrunc(idx, 7) + 1;
                const cx = gx + col * pitch_x;
                const cy = gy + row * pitch_y;
                var nb: [4]u8 = undefined;
                const num = std.fmt.bufPrint(&nb, "{d}", .{@as(u32, @intCast(day))}) catch "";
                const nw: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(num.len)) * 7.2));
                const tx = cx + @divTrunc(cell_w - nw, 2);
                if (day == tm.tm_mday) {
                    cv.roundRect(cx, cy, cell_w, cell_h, 8, cfg.accent);
                    _ = cv.textAt(tx, cy + 19, num, cfg.bar_bg, 12, true);
                } else {
                    _ = cv.textAt(tx, cy + 19, num, cfg.fg, 12, false);
                }
            }
            y += card_h + card_gap;
        }

        // Music card.
        if (m.have) {
            const card_h = pad + 17 + 3 + 16 + 12 + 4 + 12 + 22 + pad;
            cv.roundRect(pad, y, inner_w, card_h, 10, cfg.desktop_bg);
            const maxc: usize = @intCast(@divTrunc(inner_w - 2 * pad, 7));
            _ = cv.textFit13(pad + pad, y + pad + 13, m.titleSlice(), maxc, cfg.fg_bright, true);
            _ = cv.textFit13(pad + pad, y + pad + 17 + 3 + 12, m.artistSlice(), maxc + 1, cfg.fg_dim, false);

            const by = y + pad + 17 + 3 + 16 + 12;
            const bw = inner_w - 2 * pad;
            cv.roundRect(pad + pad, by, bw, 4, 2, 0x4c566a);
            if (m.len_us > 0) {
                const frac = std.math.clamp(@as(f32, @floatFromInt(m.pos_us)) / @as(f32, @floatFromInt(m.len_us)), 0, 1);
                const fw: i32 = @intFromFloat(@as(f32, @floatFromInt(bw)) * frac);
                if (fw > 0) cv.roundRect(pad + pad, by, fw, 4, 2, cfg.accent);
            }

            const cy = by + 4 + 12;
            const mid = @divTrunc(panel_w, 2);
            icons.draw(cv, .prev, @floatFromInt(mid - 42 - 9), @floatFromInt(cy + 2), 18, cfg.fg);
            icons.draw(cv, if (m.playing) .pause else .play, @floatFromInt(mid - 11), @floatFromInt(cy), 22, cfg.accent);
            icons.draw(cv, .next, @floatFromInt(mid + 42 - 9), @floatFromInt(cy + 2), 18, cfg.fg);
            p.addHit(mid - 42 - 20, cy - 4, 40, 30, .prev);
            p.addHit(mid - 20, cy - 4, 40, 30, .play);
            p.addHit(mid + 42 - 20, cy - 4, 40, 30, .next);
            y += card_h + card_gap;
        }

        // Notifications card, fills the rest.
        {
            const card_h = @as(i32, cv.h) - y - pad;
            if (card_h > 40) {
                cv.roundRect(pad, y, inner_w, card_h, 10, cfg.desktop_bg);
                _ = cv.textAt(pad + pad, y + pad + 13, "Notificaciones", cfg.fg_bright, 13, true);
                if (st.count > 0) {
                    var cb: [8]u8 = undefined;
                    const cnt = std.fmt.bufPrint(&cb, "{d}", .{st.count}) catch "";
                    _ = cv.textAt(pad + inner_w - pad - @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(cnt.len)) * 7.2))), y + pad + 13, cnt, cfg.fg_dim, 12, false);
                } else {
                    _ = cv.textAt(pad + pad, y + pad + 13 + 27, "sin notificaciones", cfg.fg_dim, 12, false);
                }
                const maxc: usize = @intCast(@divTrunc(inner_w - 2 * pad, 7));
                var iy = y + pad + 17 + 10;
                for (st.notifs[0..st.count]) |*n| {
                    if (iy + 36 > y + card_h - 6) break;
                    _ = cv.textFit13(pad + pad, iy + 12, n.appSlice(), maxc, cfg.fg_dim, false);
                    _ = cv.textFit13(pad + pad, iy + 12 + 16, n.summarySlice(), maxc, cfg.fg, false);
                    p.addHit(pad, iy - 4, inner_w, 40, .{ .dismiss = n.id });
                    iy += 42;
                }
            }
        }

        s.flush();
    }
};

// ---- desktop widget ----

pub const Widget = struct {
    surf: gfx.Surface,
    last_sig: u64 = 0,

    pub fn init(conn: *c.xcb_connection_t, screen: *const c.xcb_screen_t) !Widget {
        const h: u16 = 156;
        const y: i32 = @as(i32, screen.height_in_pixels) - 56 - h;
        var w = Widget{ .surf = try gfx.Surface.create(conn, screen, 48, y, 440, h, 0, c.XCB_EVENT_MASK_EXPOSURE, cfg.desktop_bg) };
        w.surf.map();
        w.surf.setStack(false); // always beneath tiled windows
        return w;
    }

    pub fn expose(w: *Widget, win: c.xcb_window_t) void {
        if (w.surf.win == win) w.surf.flush();
    }

    pub fn draw(w: *Widget, st: *const Store, force: bool) void {
        const tm = localNow();
        const m = &st.music;
        const sig = std.hash.Wyhash.hash(0, std.mem.asBytes(&[_]i64{ st.version, tm.tm_min, tm.tm_hour, tm.tm_mday, @intFromBool(m.playing), @intFromBool(m.have) }));
        if (!force and sig == w.last_sig) return;
        w.last_sig = sig;

        const cv = &w.surf.cv;
        cv.fill(cfg.desktop_bg);
        var tb: [8]u8 = undefined;
        const t = std.fmt.bufPrint(&tb, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)) }) catch "";
        _ = cv.textAt(0, 76, t, cfg.fg_bright, 88, true);
        var db: [48]u8 = undefined;
        const d = std.fmt.bufPrint(&db, "{s} {d} de {s}", .{ full_days[@intCast(tm.tm_wday)], @as(u32, @intCast(tm.tm_mday)), full_months[@intCast(tm.tm_mon)] }) catch "";
        _ = cv.textAt(0, 110, d, cfg.fg_dim, 16, false);
        if (m.have and m.playing) {
            var mb: [96]u8 = undefined;
            const line = std.fmt.bufPrint(&mb, "{s} \xc2\xb7 {s}", .{ m.titleSlice(), m.artistSlice() }) catch m.titleSlice();
            icons.draw(cv, .note, 0, 137, 14, cfg.accent);
            _ = cv.textFit13(22, 150, line, 52, cfg.fg_dim, false);
        }
        w.surf.flush();
    }
};

// ---- notification toasts ----

const max_toasts = 3;
const toast_w: u16 = 300;

const Toast = struct { surf: gfx.Surface, id: u32 };

pub const Toasts = struct {
    conn: *c.xcb_connection_t,
    screen: c.xcb_screen_t,
    list: [max_toasts]?Toast = [_]?Toast{null} ** max_toasts,
    shown_panel: bool = false,
    last_version: u32 = 0,

    /// Rebuild the visible toast windows when the set of live toasts (or panel state) changed.
    pub fn sync(t: *Toasts, st: *const Store, now: i64, panel_open: bool) void {
        var want: [max_toasts]u32 = undefined;
        var n: usize = 0;
        for (st.notifs[0..st.count]) |x| {
            if (x.toast_until > now and n < max_toasts) {
                want[n] = x.id;
                n += 1;
            }
        }
        var same = panel_open == t.shown_panel;
        for (t.list, 0..) |maybe, i| {
            const have: ?u32 = if (maybe) |m| m.id else null;
            const wnt: ?u32 = if (i < n) want[i] else null;
            if (have != wnt) same = false;
        }
        // A replaced notification keeps its id, so also compare the list version.
        if (same and t.last_version == st.notif_version) return;
        t.last_version = st.notif_version;
        t.shown_panel = panel_open;

        for (&t.list) |*maybe| {
            if (maybe.*) |*m| m.surf.destroy();
            maybe.* = null;
        }
        const gap: i32 = cfg.gap;
        const x: i32 = @as(i32, t.screen.width_in_pixels) - gap - toast_w - (if (panel_open) @as(i32, panel_w) + 2 * gap else 0);
        var y: i32 = 2 * gap + cfg.bar_h;
        for (0..n) |i| {
            const nt = for (st.notifs[0..st.count]) |*x2| {
                if (x2.id == want[i]) break x2;
            } else continue;
            var lines: [2][]const u8 = undefined;
            var cut = false;
            const nl = wrap(nt.bodySlice(), 34, &lines, &cut);
            const h: u16 = @intCast(12 + 15 + 4 + 17 + (if (nl > 0) 4 + nl * 16 else 0) + 12);
            var s = gfx.Surface.create(t.conn, &t.screen, x, y, toast_w, h, 12, c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_BUTTON_PRESS, cfg.bar_bg) catch continue;
            const cv = &s.cv;
            cv.fill(cfg.bar_bg);
            if (i == 0) {
                cv.roundRect(0, 0, toast_w, h, 12, cfg.accent);
                cv.roundRect(2, 2, toast_w - 4, h - 4, 10, cfg.bar_bg);
            }
            _ = cv.textFit13(14, 23, nt.appSlice(), 34, cfg.fg_dim, false);
            _ = cv.textFit13(14, 44, nt.summarySlice(), 34, cfg.fg_bright, false);
            var ly: i32 = 44 + 4 + 12;
            for (lines[0..nl], 0..) |ln, li| {
                const nx = cv.textAt(14, ly, ln, cfg.fg_dim, 12, false);
                if (cut and li == nl - 1) _ = cv.textAt(nx, ly, "...", cfg.fg_dim, 12, false);
                ly += 16;
            }
            s.map();
            s.setStack(true);
            t.list[i] = .{ .surf = s, .id = want[i] };
            y += h + gap;
        }
    }

    pub fn expose(t: *Toasts, win: c.xcb_window_t) void {
        for (&t.list) |*maybe| if (maybe.*) |*m| if (m.surf.win == win) m.surf.flush();
    }

    pub fn idAt(t: *const Toasts, win: c.xcb_window_t) ?u32 {
        for (t.list) |maybe| if (maybe) |m| if (m.surf.win == win) return m.id;
        return null;
    }

    pub fn raise(t: *Toasts) void {
        for (&t.list) |*maybe| if (maybe.*) |*m| m.surf.setStack(true);
    }

    /// Milliseconds until the next toast expires, if any.
    pub fn nextExpiry(st: *const Store, now: i64) ?i64 {
        var best: ?i64 = null;
        for (st.notifs[0..st.count]) |x| {
            if (x.toast_until > now) {
                const d = x.toast_until - now;
                if (best == null or d < best.?) best = d;
            }
        }
        return best;
    }
};

/// Greedy word wrap into at most 2 lines of `width` chars (slices of `s`). Returns line count.
fn wrap(s: []const u8, width: usize, out: *[2][]const u8, truncated: *bool) usize {
    var rest = std.mem.trim(u8, s, " ");
    var n: usize = 0;
    while (rest.len > 0 and n < 2) {
        if (rest.len <= width) {
            out[n] = rest;
            n += 1;
            rest = rest[0..0];
            break;
        }
        var cut: usize = width;
        if (std.mem.lastIndexOfScalar(u8, rest[0 .. width + 1], ' ')) |sp| {
            if (sp > 0) cut = sp;
        }
        out[n] = rest[0..cut];
        n += 1;
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }
    truncated.* = rest.len > 0;
    return n;
}
