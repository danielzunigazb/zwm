// Floating status bar: workspaces, clock/date, volume, network, battery.

const std = @import("std");
const cfg = @import("config.zig");
const c = @import("c.zig").c;
const gfx = @import("gfx.zig");
const store = @import("store.zig");
const icons = @import("icons.zig");
const anim = @import("anim.zig");


pub const days = [_][]const u8{ "dom", "lun", "mar", "mie", "jue", "vie", "sab" };
pub const months = [_][]const u8{ "ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic" };

pub const Bar = struct {
    surf: gfx.Surface,
    last_sig: u64 = 0,
    pill: f32 = -1, // x of the active-workspace pill; slides between slots
    pill_moving: bool = false,
    last_static: u64 = 0, // signature of everything except the pill
    last_pill: i32 = -1000,
    bat_path: ?[*:0]const u8 = null,
    bat: Battery = .{},
    bat_read: i64 = 0, // when `bat` was read (unix s): sysfs is only touched every few seconds

    pub fn init(conn: *c.xcb_connection_t, screen: *const c.xcb_screen_t) !Bar {
        const gap: u16 = cfg.gap;
        const w: u16 = screen.width_in_pixels - 2 * gap;
        var bar = Bar{
            .surf = try gfx.Surface.create(conn, screen, gap, gap, w, cfg.bar_h, cfg.bar_radius, c.XCB_EVENT_MASK_EXPOSURE, cfg.bar_bg),
        };
        bar.bat_path = findBattery();
        bar.surf.map();
        return bar;
    }

    /// Slide the workspace pill toward `cur`. True while it is moving.
    pub fn step(bar: *Bar, cur: usize, dt: f32) bool {
        const target: f32 = @floatFromInt(6 + @as(i32, @intCast(cur)) * 30);
        if (bar.pill < 0) bar.pill = target;
        bar.pill_moving = anim.settle(&bar.pill, target, dt, cfg.k_pill);
        return bar.pill_moving;
    }

    /// Repaint if anything visible changed (or `force`). `occupied` has one bit per workspace.
    pub fn draw(bar: *Bar, cur: usize, occupied: u8, st: *const store.Status, force: bool) void {
        var now: c.time_t = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&now, &tm);
        const bat = bar.battery(now);

        var sig: u64 = @as(u64, @intCast(cur)) | @as(u64, occupied) << 8 | @as(u64, @intCast(@divFloor(now, 60))) << 16;
        sig = std.hash.Wyhash.hash(sig, std.mem.asBytes(&[_]i64{ bat.pct, @intFromBool(bat.charging), st.version }));
        const pill_key = anim.round(bar.pill * 4);
        if (!force and sig == bar.last_static and pill_key == bar.last_pill) return;
        // Only the pill moved (a gliding workspace switch): repaint, but push just its strip.
        const full = force or sig != bar.last_static;
        bar.last_static = sig;
        bar.last_pill = pill_key;

        const cv = &bar.surf.cv;
        const w: i32 = cv.w;
        cv.fill(cfg.bar_bg);

        // Workspaces, left. The pill glides to the active slot; each digit fades between its
        // normal colour and the pill's dark colour by how much of the pill covers it.
        if (bar.pill < 0) bar.pill = @floatFromInt(6 + @as(i32, @intCast(cur)) * 30);
        cv.roundRect(anim.round(bar.pill), 5, 26, 22, 7, cfg.accent);
        for (0..cfg.workspaces) |i| {
            const x: i32 = 6 + @as(i32, @intCast(i)) * 30;
            var digit = [1]u8{'1' + @as(u8, @intCast(i))};
            const dx = x + 13 - 3; // 12px mono glyph is 7.2px wide, centered in the 26px pill
            const cover = std.math.clamp(1 - @abs(bar.pill - @as(f32, @floatFromInt(x))) / 26, 0, 1);
            const base: u32 = if (i == cur or occupied & (@as(u8, 1) << @intCast(i)) != 0) cfg.fg else cfg.fg_dim;
            _ = cv.textAt(dx, 20, &digit, gfx.blend(base, cfg.bar_bg, cover), 12, cover > 0.5);
        }

        // Clock + date, centered (13px, 10px apart).
        var tbuf: [8]u8 = undefined;
        var dbuf: [16]u8 = undefined;
        const t = std.fmt.bufPrint(&tbuf, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)) }) catch "";
        const d = std.fmt.bufPrint(&dbuf, "{s} {d} {s}", .{ days[@intCast(tm.tm_wday)], @as(u32, @intCast(tm.tm_mday)), months[@intCast(tm.tm_mon)] }) catch "";
        const total: i32 = @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(t.len + d.len)) * 7.8))) + 10;
        var cx: i32 = @divTrunc(w - total, 2);
        cx = cv.textAt(cx, 20, t, cfg.fg_bright, 13, true) + 10;
        _ = cv.textAt(cx, 20, d, cfg.fg_dim, 13, false);

        // Right side, laid out right to left: battery, network, volume. Icon, 6px, value; 14px between.
        var rx: i32 = w - 12;
        if (bat.pct >= 0) {
            var bbuf: [12]u8 = undefined;
            const b = std.fmt.bufPrint(&bbuf, "{d}%{s}", .{ @as(u32, @intCast(bat.pct)), if (bat.charging) "+" else "" }) catch "";
            rx = item(cv, rx, .battery, 16, b, cfg.fg);
        }
        {
            const v: []const u8 = switch (st.net) {
                .none => "sin red",
                .eth => "eth",
                .wifi => st.name(),
            };
            rx = item(cv, rx, .wifi, 14, v, if (st.net == .none) cfg.fg_dim else cfg.fg);
        }
        if (st.vol_pct >= 0) {
            var vbuf: [12]u8 = undefined;
            const v = if (st.muted) "mute" else std.fmt.bufPrint(&vbuf, "{d}%", .{@as(u32, @intCast(st.vol_pct))}) catch "";
            _ = item(cv, rx, .volume, 14, v, if (st.muted) cfg.fg_dim else cfg.fg);
        }

        if (full) bar.surf.flush() else bar.surf.flushRect(0, 0, 6 + cfg.workspaces * 30, cfg.bar_h);
    }

    /// Draw "icon value" ending at `right`; returns the x where the next item should end.
    fn item(cv: *gfx.Canvas, right: i32, kind: icons.Kind, isz: i32, value: []const u8, vcol: u32) i32 {
        const vw: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(gfx.cpCount(value))) * 7.2));
        const x = right - vw - 6 - isz;
        icons.draw(cv, kind, @floatFromInt(x), 9, @floatFromInt(isz), cfg.accent);
        _ = cv.textAt(x + isz + 6, 20, value, vcol, 12, false);
        return x - 14;
    }

    // ---- battery ----

    const Battery = struct { pct: i32 = -1, charging: bool = false };

    fn battery(bar: *Bar, now: i64) Battery {
        if (bar.bat_read != 0 and now - bar.bat_read < 20 and now >= bar.bat_read) return bar.bat;
        bar.bat_read = now;
        bar.bat = bar.readBattery();
        return bar.bat;
    }

    fn readBattery(bar: *Bar) Battery {
        const base = bar.bat_path orelse return .{};
        var path: [160]u8 = undefined;
        var buf: [16]u8 = undefined;
        const cap = readFile(std.fmt.bufPrintZ(&path, "{s}/capacity", .{std.mem.span(base)}) catch return .{}, &buf);
        const pct = std.fmt.parseInt(i32, std.mem.trim(u8, cap, " \n"), 10) catch return .{};
        const st = readFile(std.fmt.bufPrintZ(&path, "{s}/status", .{std.mem.span(base)}) catch return .{ .pct = pct }, &buf);
        return .{ .pct = pct, .charging = std.mem.startsWith(u8, st, "Charging") };
    }
};

var bat_dir: [96:0]u8 = undefined;

/// First power supply of type Battery (BAT0, BAT1, BATT, CMB0, ...).
fn findBattery() ?[*:0]const u8 {
    const root = "/sys/class/power_supply";
    const dir = c.opendir(root) orelse return null;
    defer _ = c.closedir(dir);
    var buf: [32]u8 = undefined;
    while (c.readdir(dir)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
        if (name.len == 0 or name[0] == '.') continue;
        var tp: [160]u8 = undefined;
        const tpath = std.fmt.bufPrintZ(&tp, "{s}/{s}/type", .{ root, name }) catch continue;
        if (!std.mem.startsWith(u8, readFile(tpath, &buf), "Battery")) continue;
        const dst = std.fmt.bufPrintZ(&bat_dir, "{s}/{s}", .{ root, name }) catch continue;
        return dst.ptr;
    }
    return null;
}

pub fn readFile(path: [*:0]const u8, buf: []u8) []const u8 {
    const fd = c.open(path, c.O_RDONLY);
    if (fd < 0) return buf[0..0];
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    return if (n > 0) buf[0..@intCast(n)] else buf[0..0];
}
