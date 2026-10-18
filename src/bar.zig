// Floating status bar: workspaces, clock/date, volume, network, battery.

const std = @import("std");
const cfg = @import("config.zig");
const c = @import("c.zig").c;
const gfx = @import("gfx.zig");
const store = @import("store.zig");

const glyph_w = gfx.glyph_w;

pub const days = [_][]const u8{ "dom", "lun", "mar", "mie", "jue", "vie", "sab" };
pub const months = [_][]const u8{ "ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic" };

pub const Bar = struct {
    surf: gfx.Surface,
    last_sig: u64 = 0,
    bat_path: ?[*:0]const u8 = null,

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

    /// Repaint if anything visible changed (or `force`). `occupied` has one bit per workspace.
    pub fn draw(bar: *Bar, cur: usize, occupied: u8, st: *const store.Status, force: bool) void {
        var now: c.time_t = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&now, &tm);
        const bat = bar.battery();

        var sig: u64 = @as(u64, @intCast(cur)) | @as(u64, occupied) << 8 | @as(u64, @intCast(@divFloor(now, 60))) << 16;
        sig = std.hash.Wyhash.hash(sig, std.mem.asBytes(&[_]i64{ bat.pct, @intFromBool(bat.charging), st.version }));
        if (!force and sig == bar.last_sig) return;
        bar.last_sig = sig;

        const cv = &bar.surf.cv;
        const w: i32 = cv.w;
        cv.fill(cfg.bar_bg);

        // Workspaces, left.
        for (0..cfg.workspaces) |i| {
            const x: i32 = 6 + @as(i32, @intCast(i)) * 30;
            var digit = [1]u8{'1' + @as(u8, @intCast(i))};
            if (i == cur) {
                cv.roundRect(x, 5, 26, 22, 7, cfg.accent);
                _ = cv.textBold(x + 9, 8, &digit, cfg.bar_bg);
            } else {
                const col: u32 = if (occupied & (@as(u8, 1) << @intCast(i)) != 0) cfg.fg else cfg.fg_dim;
                _ = cv.text(x + 9, 8, &digit, col);
            }
        }

        // Clock + date, centered.
        var tbuf: [8]u8 = undefined;
        var dbuf: [16]u8 = undefined;
        const t = std.fmt.bufPrint(&tbuf, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)) }) catch "";
        const d = std.fmt.bufPrint(&dbuf, "{s} {d} {s}", .{ days[@intCast(tm.tm_wday)], @as(u32, @intCast(tm.tm_mday)), months[@intCast(tm.tm_mon)] }) catch "";
        const total: i32 = @intCast((t.len + 2 + d.len) * glyph_w);
        var cx: i32 = @divTrunc(w - total, 2);
        cx = cv.textBold(cx, 8, t, cfg.fg_bright);
        _ = cv.text(cx + 2 * glyph_w, 8, d, cfg.fg_dim);

        // Right side, laid out right to left: battery, network, volume.
        var rx: i32 = w - 12;
        if (bat.pct >= 0) {
            var bbuf: [12]u8 = undefined;
            const b = std.fmt.bufPrint(&bbuf, "{d}%{s}", .{ @as(u32, @intCast(bat.pct)), if (bat.charging) "+" else "" }) catch "";
            rx = item(cv, rx, "bat", b, cfg.fg);
        }
        {
            var nbuf: [48]u8 = undefined;
            const v: []const u8 = switch (st.net) {
                .none => "sin red",
                .eth => "eth",
                .wifi => if (st.net_pct >= 0)
                    std.fmt.bufPrint(&nbuf, "{s} {d}%", .{ st.name(), @as(u32, @intCast(st.net_pct)) }) catch st.name()
                else
                    st.name(),
            };
            rx = item(cv, rx, "net", v, if (st.net == .none) cfg.fg_dim else cfg.fg);
        }
        if (st.vol_pct >= 0) {
            var vbuf: [12]u8 = undefined;
            const v = if (st.muted) "mute" else std.fmt.bufPrint(&vbuf, "{d}%", .{@as(u32, @intCast(st.vol_pct))}) catch "";
            _ = item(cv, rx, "vol", v, if (st.muted) cfg.fg_dim else cfg.fg);
        }

        bar.surf.flush();
    }

    /// Draw "label value" ending at `right`; returns the x where the next item should end.
    fn item(cv: *gfx.Canvas, right: i32, label: []const u8, value: []const u8, vcol: u32) i32 {
        const width: i32 = @intCast((label.len + 1 + value.len) * glyph_w);
        const x = right - width;
        const nx = cv.text(x, 8, label, cfg.accent);
        _ = cv.text(nx + glyph_w, 8, value, vcol);
        return x - 18;
    }

    // ---- battery ----

    const Battery = struct { pct: i32 = -1, charging: bool = false };

    fn battery(bar: *Bar) Battery {
        const base = bar.bat_path orelse return .{};
        var path: [64]u8 = undefined;
        var buf: [16]u8 = undefined;
        const cap = readFile(std.fmt.bufPrintZ(&path, "{s}/capacity", .{std.mem.span(base)}) catch return .{}, &buf);
        const pct = std.fmt.parseInt(i32, std.mem.trim(u8, cap, " \n"), 10) catch return .{};
        const st = readFile(std.fmt.bufPrintZ(&path, "{s}/status", .{std.mem.span(base)}) catch return .{ .pct = pct }, &buf);
        return .{ .pct = pct, .charging = std.mem.startsWith(u8, st, "Charging") };
    }
};

fn findBattery() ?[*:0]const u8 {
    const candidates = [_][*:0]const u8{ "/sys/class/power_supply/BAT0", "/sys/class/power_supply/BAT1" };
    var buf: [16]u8 = undefined;
    for (candidates) |p| {
        var path: [64]u8 = undefined;
        const f = std.fmt.bufPrintZ(&path, "{s}/capacity", .{std.mem.span(p)}) catch continue;
        if (readFile(f, &buf).len > 0) return p;
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
