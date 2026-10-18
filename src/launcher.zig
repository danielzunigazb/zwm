// App launcher: keyboard-grabbing list on the left side. Fuzzy-searches .desktop
// apps; arithmetic typed in shows up as a calculator row.

const std = @import("std");
const cfg = @import("config.zig");
const c = @import("c.zig").c;
const gfx = @import("gfx.zig");
const anim = @import("anim.zig");
const apps = @import("apps.zig");
const calc = @import("calc.zig");

const glyph_w = gfx.glyph_w;
const width: u16 = 360;
const max_results = 10;
const row_h = 34;
const pad = 14;
const input_h = 38;

pub const Result = enum { none, close, launch, calc };

pub const Launcher = struct {
    conn: *c.xcb_connection_t,
    screen: c.xcb_screen_t,
    syms: ?*c.xcb_key_symbols_t = null,
    surf: ?gfx.Surface = null,
    db: apps.Db = .{},

    query: [64]u8 = undefined,
    qlen: usize = 0,
    matches: [max_results]apps.Db.Match = undefined,
    n_match: usize = 0,
    calc_val: ?f64 = null,
    sel: usize = 0,
    x: f32 = 0, // animated left edge: slides in from off screen on open

    /// Last action's payload, valid until the next key.
    cmd_buf: [320:0]u8 = [_:0]u8{0} ** 320,
    calc_buf: [96]u8 = undefined,
    calc_len: usize = 0,

    pub fn visible(l: *const Launcher) bool {
        return l.surf != null;
    }

    pub fn open(l: *Launcher, syms: *c.xcb_key_symbols_t) bool {
        if (l.surf != null) return true;
        const ck = c.xcb_grab_keyboard(l.conn, 0, l.screen.root, c.XCB_CURRENT_TIME, c.XCB_GRAB_MODE_ASYNC, c.XCB_GRAB_MODE_ASYNC);
        const reply = c.xcb_grab_keyboard_reply(l.conn, ck, null) orelse return false;
        defer std.c.free(reply);
        if (reply.*.status != c.XCB_GRAB_STATUS_SUCCESS) return false;

        l.syms = syms;
        l.db.load();
        l.qlen = 0;
        l.sel = 0;
        l.update();
        l.rebuild();
        return true;
    }

    pub fn close(l: *Launcher) void {
        if (l.surf) |*s| {
            s.destroy();
            l.surf = null;
            _ = c.xcb_ungrab_keyboard(l.conn, c.XCB_CURRENT_TIME);
            _ = c.xcb_flush(l.conn);
        }
    }

    pub fn step(l: *Launcher, dt: f32) bool {
        const s = &(l.surf orelse return false);
        const before = anim.round(l.x);
        const moving = anim.settle(&l.x, @floatFromInt(cfg.gap), dt, cfg.k_launcher);
        const nx = anim.round(l.x);
        if (nx != before) s.move(nx, 2 * cfg.gap + cfg.bar_h);
        return moving;
    }

    fn rows(l: *const Launcher) usize {
        const n = l.n_match + @intFromBool(l.calc_val != null);
        return @max(n, 1);
    }

    /// Recompute matches for the current query.
    fn update(l: *Launcher) void {
        const q = l.query[0..l.qlen];
        l.calc_val = calc.eval(q);
        l.n_match = l.db.search(q, &l.matches);
        l.sel = 0;
    }

    /// (Re)create the window at the height the current rows need, and paint it.
    fn rebuild(l: *Launcher) void {
        const h: u16 = @intCast(pad + input_h + 10 + l.rows() * row_h + pad - 2);
        if (l.surf) |*s| {
            if (s.cv.h != h) s.resize(&l.screen, h, 14); // grow/shrink in place: no flicker while typing
            l.draw();
            return;
        }
        const gap: i32 = cfg.gap;
        l.x = -@as(f32, width);
        var s = gfx.Surface.create(l.conn, &l.screen, anim.round(l.x), 2 * gap + cfg.bar_h, width, h, 14, c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_BUTTON_PRESS, cfg.bar_bg) catch return;
        s.map();
        s.setStack(true);
        l.surf = s;
        l.draw();
    }

    fn draw(l: *Launcher) void {
        const s = &(l.surf orelse return);
        const cv = &s.cv;
        cv.fill(cfg.bar_bg);

        // Input box.
        const iw: i32 = width - 2 * pad;
        cv.roundRect(pad, pad, iw, input_h, 10, cfg.desktop_bg);
        _ = cv.text(pad + 14, pad + 11, ">", cfg.accent);
        const tx = cv.text(pad + 14 + 2 * glyph_w, pad + 11, l.query[0..l.qlen], cfg.fg_bright);
        cv.rect(tx + 1, pad + 11, glyph_w, 16, cfg.accent);

        // Rows: calculator first, then apps.
        var y: i32 = pad + input_h + 10;
        var idx: usize = 0;
        const maxc: usize = @intCast(@divTrunc(iw - 28, glyph_w));
        if (l.calc_val) |v| {
            var nb: [48]u8 = undefined;
            var rb: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&rb, "= {s}", .{calc.format(&nb, v)}) catch "= ?";
            l.row(cv, y, idx, text, maxc);
            y += row_h;
            idx += 1;
        }
        for (l.matches[0..l.n_match]) |m| {
            l.row(cv, y, idx, l.db.list.items[m.idx].nameS(), maxc);
            y += row_h;
            idx += 1;
        }
        if (idx == 0) _ = cv.text(pad + 14, y + 8, "sin resultados", cfg.fg_dim);
        s.flush();
    }

    fn row(l: *const Launcher, cv: *gfx.Canvas, y: i32, idx: usize, text: []const u8, maxc: usize) void {
        const iw: i32 = width - 2 * pad;
        if (idx == l.sel) {
            cv.roundRect(pad, y, iw, row_h - 4, 8, cfg.accent);
            _ = cv.textFit(pad + 14, y + 9, text, maxc, cfg.bar_bg);
        } else {
            _ = cv.textFit(pad + 14, y + 9, text, maxc, cfg.fg);
        }
    }

    pub fn expose(l: *Launcher, win: c.xcb_window_t) void {
        if (l.surf) |*s| if (s.win == win) s.flush();
    }

    pub fn raise(l: *Launcher) void {
        if (l.surf) |*s| s.setStack(true);
    }

    /// Row under a click, selected and activated like Enter.
    pub fn click(l: *Launcher, win: c.xcb_window_t, y: i32) Result {
        const s = l.surf orelse return .none;
        if (s.win != win) return .none;
        const top = pad + input_h + 10;
        if (y < top) return .none;
        const idx: usize = @intCast(@divTrunc(y - top, row_h));
        if (idx >= l.n_match + @intFromBool(l.calc_val != null)) return .none;
        l.sel = idx;
        return l.activate();
    }

    fn activate(l: *Launcher) Result {
        var idx = l.sel;
        if (l.calc_val) |v| {
            if (idx == 0) {
                var nb: [48]u8 = undefined;
                const out = std.fmt.bufPrint(&l.calc_buf, "{s} = {s}", .{ std.mem.trim(u8, l.query[0..l.qlen], " "), calc.format(&nb, v) }) catch return .close;
                l.calc_len = out.len;
                return .calc;
            }
            idx -= 1;
        }
        if (idx >= l.n_match) return .none;
        const app = &l.db.list.items[l.matches[idx].idx];
        const cmd = if (app.terminal)
            std.fmt.bufPrintZ(&l.cmd_buf, "{s} -e {s}", .{ cfg.terminal, app.execS() })
        else
            std.fmt.bufPrintZ(&l.cmd_buf, "{s}", .{app.execS()});
        _ = cmd catch return .close;
        l.db.bump(app.hash);
        return .launch;
    }

    pub fn cmdZ(l: *Launcher) [*:0]const u8 {
        return &l.cmd_buf;
    }

    pub fn calcText(l: *const Launcher) []const u8 {
        return l.calc_buf[0..l.calc_len];
    }

    pub fn onKey(l: *Launcher, ev: *c.xcb_key_press_event_t) Result {
        const syms = l.syms orelse return .close;
        const shift = ev.state & 1 != 0;
        const ctrl = ev.state & 4 != 0;
        const ks = c.xcb_key_symbols_get_keysym(syms, ev.detail, if (shift) 1 else 0);
        const total = l.n_match + @intFromBool(l.calc_val != null);

        switch (ks) {
            0xff1b => return .close, // Escape
            0xff0d, 0xff8d => return l.activate(), // Return, KP_Enter
            0xff08 => { // BackSpace
                if (l.qlen > 0) l.qlen -= 1;
                l.update();
            },
            0xff52, 0xfe20 => if (total > 0) { // Up, ISO_Left_Tab
                l.sel = if (l.sel == 0) total - 1 else l.sel - 1;
            },
            0xff54, 0xff09 => if (total > 0) { // Down, Tab
                l.sel = (l.sel + 1) % total;
            },
            else => {
                if (ctrl) {
                    switch (ks) {
                        'u' => {
                            l.qlen = 0;
                            l.update();
                        },
                        'n' => if (total > 0) {
                            l.sel = (l.sel + 1) % total;
                        },
                        'p' => if (total > 0) {
                            l.sel = if (l.sel == 0) total - 1 else l.sel - 1;
                        },
                        'c' => return .close,
                        else => {},
                    }
                } else if (ks >= 0x20 and ks < 0x7f and l.qlen < l.query.len) {
                    l.query[l.qlen] = @intCast(ks);
                    l.qlen += 1;
                    l.update();
                } else return .none;
            },
        }
        l.rebuild();
        return .none;
    }
};
