// Lock screen (Super+L). A full-screen override-redirect window that owns the keyboard until PAM
// accepts the password. The background is the strata field from the screensaver, painted once.
// Each keystroke ripples the strata and adds a dot; a wrong password turns them red and shakes
// the dots. Only the HUD rectangle is repainted, so the frame cost stays small.

const std = @import("std");
const cfg = @import("config.zig");
const c = @import("c.zig").c;
const gfx = @import("gfx.zig");
const auth = @import("auth.zig");

const strata = 14;
const max_len = 255; // bytes; PAM copes with UTF-8 passwords
const max_dots = 32;
const hud_w: u16 = 720;
const hud_h: u16 = 340;
const frame_ns: i64 = 33_000_000; // HUD repaint cap, ~30 fps
const wrong_s: f32 = 0.9; // how long the failure look lasts

// Strata palette: teal -> violet -> ember, same as the screensaver.
const teal: u32 = 0x42c6b4;
const violet: u32 = 0x8d7cff;
const ember: u32 = 0xff8a4c;
const alarm: u32 = 0xff5d5d;

pub const Lock = struct {
    conn: *c.xcb_connection_t,
    screen: c.xcb_screen_t,
    surf: ?gfx.Surface = null,
    bg: []u32 = &.{}, // the untouched background, so the HUD can repaint its own rectangle
    name: [64:0]u8 = [_:0]u8{0} ** 64, // account being unlocked (copied: getpwuid's storage is static)

    pass: [max_len:0]u8 = [_:0]u8{0} ** max_len,
    len: usize = 0,

    dead: u32 = 0, // pending dead-key accent keysym (´ ¨ ^ ~ `), waiting for its letter

    amp: [strata]f32 = [_]f32{0} ** strata, // ripple per stratum, decays to rest
    wrong: f32 = 0, // seconds left of the failure look
    t: f32 = 0, // seconds since open, drives the waves
    seed: u64 = 0x9E3779B97F4A7C15,
    last_draw: i64 = 0,

    pub fn visible(l: *const Lock) bool {
        return l.surf != null;
    }

    /// Grab the keyboard and show the lock. False if the grab or the window fails (nothing changes).
    pub fn open(l: *Lock) bool {
        if (l.surf != null) return true;
        if (l.screen.width_in_pixels < hud_w or l.screen.height_in_pixels < hud_h) return false;
        // Keyboard AND pointer: an unlocked pointer could still click through to the apps below.
        if (!l.takeGrabs()) return false;

        var s = gfx.Surface.create(l.conn, &l.screen, 0, 0, l.screen.width_in_pixels, l.screen.height_in_pixels, 0, c.XCB_EVENT_MASK_EXPOSURE, cfg.desktop_bg) catch {
            l.releaseGrabs();
            return false;
        };
        l.bg = std.heap.c_allocator.alloc(u32, s.cv.buf.len) catch {
            s.destroy();
            l.releaseGrabs();
            return false;
        };
        paintBackground(&s.cv);
        @memcpy(l.bg, s.cv.buf);
        s.map();
        s.setStack(true);
        s.flush();
        l.surf = s;
        l.name = [_:0]u8{0} ** 64;
        if (auth.user()) |u| {
            const n = @min(std.mem.len(u), 63);
            @memcpy(l.name[0..n], u[0..n]);
        }
        l.clearPass();
        l.amp = [_]f32{0} ** strata;
        l.wrong = 0;
        l.t = 0;
        l.last_draw = 0;
        return true;
    }

    /// Hide the lock and give the keyboard back. The password buffer is wiped first.
    pub fn close(l: *Lock) void {
        l.clearPass();
        if (l.surf) |*s| {
            s.destroy();
            l.surf = null;
            l.releaseGrabs();
            _ = c.xcb_flush(l.conn);
        }
        if (l.bg.len > 0) {
            std.heap.c_allocator.free(l.bg);
            l.bg = &.{};
        }
    }

    /// The lock's window id (0 when not shown), so the WM can tell its own events apart.
    pub fn winId(l: *const Lock) u32 {
        return if (l.surf) |s| s.win else 0;
    }

    /// Keyboard and pointer, both or neither. A partial grab is given back at once.
    fn takeGrabs(l: *Lock) bool {
        const kb_reply = c.xcb_grab_keyboard_reply(l.conn, c.xcb_grab_keyboard(l.conn, 0, l.screen.root, c.XCB_CURRENT_TIME, c.XCB_GRAB_MODE_ASYNC, c.XCB_GRAB_MODE_ASYNC), null) orelse return false;
        defer std.c.free(kb_reply);
        if (kb_reply.*.status != c.XCB_GRAB_STATUS_SUCCESS) return false;
        // No event mask: the pointer is held, and its events go nowhere (not to the apps below).
        const ptr_reply = c.xcb_grab_pointer_reply(l.conn, c.xcb_grab_pointer(l.conn, 0, l.screen.root, 0, c.XCB_GRAB_MODE_ASYNC, c.XCB_GRAB_MODE_ASYNC, c.XCB_NONE, c.XCB_NONE, c.XCB_CURRENT_TIME), null) orelse {
            l.releaseGrabs();
            return false;
        };
        defer std.c.free(ptr_reply);
        if (ptr_reply.*.status != c.XCB_GRAB_STATUS_SUCCESS) {
            l.releaseGrabs();
            return false;
        }
        return true;
    }

    fn releaseGrabs(l: *Lock) void {
        _ = c.xcb_ungrab_keyboard(l.conn, c.XCB_CURRENT_TIME);
        _ = c.xcb_ungrab_pointer(l.conn, c.XCB_CURRENT_TIME);
    }

    pub fn raise(l: *Lock) void {
        if (l.surf) |*s| s.setStack(true);
    }

    pub fn expose(l: *Lock, win: c.xcb_window_t) void {
        if (l.surf) |*s| if (s.win == win) s.flush();
    }

    /// Advance the animation. Always true while locked (the clock and waves keep moving).
    pub fn step(l: *Lock, dt: f32) bool {
        if (l.surf == null) return false;
        l.t += dt;
        const k = @exp(-dt * 3.0);
        for (&l.amp) |*a| a.* *= k;
        l.wrong = @max(0, l.wrong - dt);
        return true;
    }

    /// Repaint the HUD if the frame cap allows it.
    pub fn render(l: *Lock, now: i64) void {
        const s = &(l.surf orelse return);
        if (now - l.last_draw < frame_ns) return;
        l.last_draw = now;
        const x: u16 = (s.cv.w - hud_w) / 2;
        const y: u16 = (s.cv.h - hud_h) / 2;
        l.paintHud(&s.cv, x, y);
        s.flushRect(x, y, hud_w, hud_h);
    }

    /// Feed one key press. True when the password was accepted and the lock closed.
    pub fn onKey(l: *Lock, ev: *c.xcb_key_press_event_t, syms: *c.xcb_key_symbols_t) bool {
        const shift = ev.state & 1 != 0;
        const caps = ev.state & 2 != 0;
        const ctrl = ev.state & 4 != 0;
        const altgr = ev.state & 0x80 != 0; // Mod5 = ISO_Level3_Shift (AltGr) on the usual layouts

        // Level: AltGr picks the third column, Shift the second. Caps Lock only flips letters,
        // like the keyboard itself does, so a capitalised password types the same as at login.
        const plain = c.xcb_key_symbols_get_keysym(syms, ev.detail, if (altgr) 2 else 0);
        const letter = (plain >= 'a' and plain <= 'z') or (plain >= 'A' and plain <= 'Z');
        const upper = shift != (caps and letter);
        const level: c_int = (if (upper) @as(c_int, 1) else 0) + (if (altgr) @as(c_int, 2) else 0);
        const ks = c.xcb_key_symbols_get_keysym(syms, ev.detail, level);

        var typed = false;
        switch (ks) {
            0xff0d, 0xff8d => return l.submit(), // Return, KP_Enter
            0xff08 => { // BackSpace
                l.dead = 0;
                l.backspace();
                typed = true;
            },
            0xff1b => l.clearPass(), // Escape
            0xffb0...0xffb9 => { // keypad digits
                l.dead = 0;
                l.append(@intCast(ks - 0xffb0 + '0'));
                typed = true;
            },
            else => {
                if (ctrl) {
                    if (ks == 'u') l.clearPass();
                } else if (isDead(ks)) {
                    l.dead = ks; // the accent waits for the letter it goes on
                } else if ((ks >= 0x20 and ks < 0x7f) or (ks >= 0xa0 and ks <= 0xff)) {
                    l.typeChar(@intCast(ks));
                    typed = true;
                }
            },
        }
        if (typed) l.ripple();
        return false;
    }

    /// A printable code point, with any pending dead accent applied to it.
    fn typeChar(l: *Lock, cp: u21) void {
        defer l.dead = 0;
        if (l.dead == 0) return l.appendCp(cp);
        if (cp == ' ') return l.appendCp(bareAccent(l.dead)); // accent + space = the bare accent
        if (compose(l.dead, cp)) |out| return l.appendCp(out);
        l.appendCp(bareAccent(l.dead));
        l.appendCp(cp);
    }

    fn submit(l: *Lock) bool {
        if (l.len == 0) {
            l.fail();
            return false;
        }
        if (l.name[0] == 0) { // no account name: nothing to check against
            l.fail();
            return false;
        }
        if (auth.check(&l.name, &l.pass)) {
            l.close();
            return true;
        }
        l.fail();
        return false;
    }

    fn fail(l: *Lock) void {
        l.clearPass();
        l.wrong = wrong_s;
        for (&l.amp) |*a| a.* = 1;
    }

    fn clearPass(l: *Lock) void {
        @memset(&l.pass, 0);
        l.len = 0;
        l.dead = 0;
    }

    fn isDead(ks: u32) bool {
        return switch (ks) {
            0xfe50, 0xfe51, 0xfe52, 0xfe53, 0xfe57 => true, // grave, acute, circumflex, tilde, diaeresis
            else => false,
        };
    }

    /// The accent on its own, for an accent that is not followed by a letter it combines with.
    fn bareAccent(dead: u32) u21 {
        return switch (dead) {
            0xfe50 => '`',
            0xfe51 => 0xb4,
            0xfe52 => '^',
            0xfe53 => '~',
            0xfe57 => 0xa8,
            else => ' ',
        };
    }

    const Compose = struct { dead: u32, base: []const u8, out: []const u21 };
    const composes = [_]Compose{
        .{ .dead = 0xfe51, .base = "aeiouAEIOU", .out = &.{ 0xe1, 0xe9, 0xed, 0xf3, 0xfa, 0xc1, 0xc9, 0xcd, 0xd3, 0xda } }, // ´
        .{ .dead = 0xfe50, .base = "aeiouAEIOU", .out = &.{ 0xe0, 0xe8, 0xec, 0xf2, 0xf9, 0xc0, 0xc8, 0xcc, 0xd2, 0xd9 } }, // `
        .{ .dead = 0xfe57, .base = "aeiouAEIOU", .out = &.{ 0xe4, 0xeb, 0xef, 0xf6, 0xfc, 0xc4, 0xcb, 0xcf, 0xd6, 0xdc } }, // ¨
        .{ .dead = 0xfe52, .base = "aeiouAEIOU", .out = &.{ 0xe2, 0xea, 0xee, 0xf4, 0xfb, 0xc2, 0xca, 0xce, 0xd4, 0xdb } }, // ^
        .{ .dead = 0xfe53, .base = "nNaAoO", .out = &.{ 0xf1, 0xd1, 0xe3, 0xc3, 0xf5, 0xd5 } }, // ~ (ñ, ã, õ)
    };

    /// The precomposed letter for accent + base, if there is one.
    fn compose(dead: u32, cp: u21) ?u21 {
        for (composes) |e| {
            if (e.dead != dead) continue;
            for (e.base, 0..) |b, i| if (cp == b) return e.out[i];
        }
        return null;
    }

    fn append(l: *Lock, ch: u8) void {
        if (l.len >= max_len) return;
        l.pass[l.len] = ch;
        l.len += 1;
    }

    fn appendCp(l: *Lock, cp: u21) void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        if (l.len + n > max_len) return;
        @memcpy(l.pass[l.len..][0..n], buf[0..n]);
        l.len += n;
    }

    /// Drop the last code point (not just the last byte).
    fn backspace(l: *Lock) void {
        while (l.len > 0) {
            l.len -= 1;
            const b = l.pass[l.len];
            l.pass[l.len] = 0;
            if (b & 0xC0 != 0x80) break; // a lead byte (or ASCII) ends the code point
        }
    }

    /// Every key moves one stratum a little. Position comes from an LCG, not the key, so the
    /// ripple shows typing without hinting at which character was typed.
    fn ripple(l: *Lock) void {
        l.seed = l.seed *% 6364136223846793005 +% 1442695040888963407;
        const i: usize = @intCast((l.seed >> 33) % strata);
        l.amp[i] = @min(1.0, l.amp[i] + 1.0);
        if (i > 0) l.amp[i - 1] = @min(1.0, l.amp[i - 1] + 0.5);
        if (i + 1 < strata) l.amp[i + 1] = @min(1.0, l.amp[i + 1] + 0.5);
    }

    // ---- painting ----

    fn ramp(u: f32) u32 {
        return if (u < 0.5) mix(teal, violet, u * 2) else mix(violet, ember, (u - 0.5) * 2);
    }

    fn mix(a: u32, b: u32, k: f32) u32 {
        var out: u32 = 0;
        inline for (.{ 0, 8, 16 }) |sh| {
            const x: f32 = @floatFromInt((a >> sh) & 0xff);
            const y: f32 = @floatFromInt((b >> sh) & 0xff);
            out |= @as(u32, @intFromFloat(x + (y - x) * k + 0.5)) << sh;
        }
        return out;
    }

    /// The strata field as a static image: each loop projected in perspective, drawn faint so the
    /// HUD on top is what you read.
    fn paintBackground(cv: *gfx.Canvas) void {
        cv.fill(cfg.desktop_bg);
        const cx: f32 = @as(f32, @floatFromInt(cv.w)) / 2;
        const cy: f32 = @as(f32, @floatFromInt(cv.h)) / 2;
        const focal: f32 = @as(f32, @floatFromInt(cv.h)) * 0.9;
        const segs = 180;
        for (0..strata) |i| {
            const fi: f32 = @floatFromInt(i);
            const u: f32 = fi / (strata - 1);
            const z = (u - 0.5) * 10;
            const col = ramp(u);
            for (0..segs + 1) |j| {
                const a = @as(f32, @floatFromInt(j)) / segs * std.math.tau;
                const w = @sin(3 * a + fi * 0.35) * 0.55 + @sin(5 * a + fi * 0.2) * 0.28;
                const r = 3.6 + w * (0.6 + 0.4 * u);
                const x = @cos(a) * r * 1.1;
                const y = @sin(a) * r * 0.72 + @sin(2 * a + fi * 0.4) * 0.35;
                const depth = z + @sin(2 * a) * 0.3 + 14;
                const sc = focal / depth;
                const px: i32 = @intFromFloat(@round(cx + x * sc));
                const py: i32 = @intFromFloat(@round(cy + y * sc));
                const cov = std.math.clamp(0.9 - depth * 0.02, 0.12, 0.45);
                plot(cv, px, py, col, cov);
                plot(cv, px + 1, py, col, cov);
            }
        }
    }

    fn plot(cv: *gfx.Canvas, x: i32, y: i32, col: u32, cov: f32) void {
        if (x < 0 or y < 0 or x >= cv.w or y >= cv.h) return;
        const idx = @as(usize, @intCast(y)) * cv.w + @as(usize, @intCast(x));
        cv.buf[idx] = gfx.blend(cv.buf[idx], col, cov);
    }

    /// Restore the HUD rectangle from the background, then draw clock, waves, dots and hint.
    fn paintHud(l: *Lock, cv: *gfx.Canvas, x0: u16, y0_: u16) void {
        for (0..hud_h) |row| {
            const off = (@as(usize, y0_) + row) * cv.w + x0;
            @memcpy(cv.buf[off..][0..hud_w], l.bg[off..][0..hud_w]);
        }

        const x: i32 = x0;
        const y: i32 = y0_;
        const cx: i32 = x + hud_w / 2;
        const failing = l.wrong > 0;
        const shake: f32 = if (failing) @sin(l.wrong * 60) * 10 * (l.wrong / wrong_s) else 0;

        // Clock, large, with the account name under it.
        var tbuf: [8]u8 = undefined;
        var now: c.time_t = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&now, &tm);
        const clock = std.fmt.bufPrint(&tbuf, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)) }) catch "--:--";
        centered(cv, cx, y + 100, clock, 96, cfg.fg_bright);
        if (l.name[0] != 0) centered(cv, cx, y + 138, std.mem.sliceTo(&l.name, 0), 13, cfg.fg_dim);

        // Strata: one wavy line per layer. A keystroke sets its amplitude; a failure paints them red.
        const bc: f32 = @floatFromInt(y + 200);
        const xa: f32 = @floatFromInt(x + 70);
        const xb: f32 = @floatFromInt(x + hud_w - 70);
        for (0..strata) |i| {
            const base = bc + (@as(f32, @floatFromInt(i)) - @as(f32, strata - 1) / 2) * 8;
            const col = if (failing) alarm else ramp(@as(f32, @floatFromInt(i)) / (strata - 1));
            const ph = @as(f32, @floatFromInt(i)) * 0.45;
            const amp = 2.5 + l.amp[i] * 16;
            var px = xa;
            var py = waveY(base, amp, px, ph, l.t, xa);
            var wx = xa + 6;
            while (wx <= xb) : (wx += 6) {
                const wy = waveY(base, amp, wx, ph, l.t, xa);
                cv.line(px, py, wx, wy, 1.6, col);
                px = wx;
                py = wy;
            }
        }

        // One dot per character typed (capped). The newest one is ember and a little larger.
        const count = @min(gfx.cpCount(l.pass[0..l.len]), max_dots);
        const spacing: f32 = 16;
        const row_w: f32 = max_dots * spacing;
        const dx0 = @as(f32, @floatFromInt(cx)) - row_w / 2 + shake;
        const dy: i32 = y + 282;
        for (0..count) |k| {
            const dx: i32 = @intFromFloat(@round(dx0 + @as(f32, @floatFromInt(k)) * spacing));
            const newest = k + 1 == count;
            const col = if (failing) alarm else if (newest) ember else cfg.fg;
            if (newest) {
                cv.roundRect(dx - 1, dy - 1, 10, 10, 5, col);
            } else {
                cv.roundRect(dx, dy, 8, 8, 4, col);
            }
        }

        const hint = if (failing) "contrase\u{f1}a incorrecta" else "escribe la contrase\u{f1}a y pulsa Enter";
        centered(cv, cx, y + 318, hint, 13, if (failing) alarm else cfg.fg_dim);
    }

    fn waveY(base: f32, amp: f32, x: f32, ph: f32, t: f32, x0: f32) f32 {
        return base + amp * @sin(0.028 * (x - x0) + ph + t * 1.3);
    }

    fn centered(cv: *gfx.Canvas, cx: i32, base: i32, s: []const u8, px: f32, col: u32) void {
        const w: i32 = @intFromFloat(@as(f32, @floatFromInt(gfx.cpCount(s))) * px * 0.6);
        _ = cv.textAt(cx - @divTrunc(w, 2), base, s, col, px, false);
    }
};

test "dead accents compose into the precomposed letter" {
    try std.testing.expectEqual(@as(?u21, 0xe1), Lock.compose(0xfe51, 'a')); // ´ + a = á
    try std.testing.expectEqual(@as(?u21, 0xf1), Lock.compose(0xfe53, 'n')); // ~ + n = ñ
    try std.testing.expectEqual(@as(?u21, null), Lock.compose(0xfe51, 'x')); // no such letter
}

test "backspace removes a whole UTF-8 character" {
    var l = Lock{ .conn = undefined, .screen = undefined };
    l.appendCp(0xf1); // ñ is two bytes
    l.append('a');
    l.backspace();
    try std.testing.expectEqual(@as(usize, 2), l.len);
    l.backspace();
    try std.testing.expectEqual(@as(usize, 0), l.len);
}
