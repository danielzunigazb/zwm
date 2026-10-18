// Floating status bar: an override-redirect window painted from a software
// framebuffer (8x16 PSF bitmap font), clipped to a rounded shape with SHAPE.

const std = @import("std");
const cfg = @import("config.zig");
const c = @import("c.zig").c;

const font = @embedFile("font.psf");
const glyph_w = 8;
const glyph_h = 16;
const psf_header = 32; // PSF2 header size, 256 glyphs of 16 bytes

const days = [_][]const u8{ "dom", "lun", "mar", "mie", "jue", "vie", "sab" };
const months = [_][]const u8{ "ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic" };

pub const Bar = struct {
    conn: *c.xcb_connection_t,
    win: c.xcb_window_t,
    gc: c.xcb_gcontext_t,
    depth: u8,
    w: u16,
    h: u16,
    buf: []u32,
    last_sig: u64 = 0,
    bat_path: ?[*:0]const u8 = null,

    pub fn init(conn: *c.xcb_connection_t, screen: *const c.xcb_screen_t) !Bar {
        const gap: u16 = cfg.gap;
        const w: u16 = screen.width_in_pixels - 2 * gap;
        const h: u16 = cfg.bar_h;
        const win = c.xcb_generate_id(conn);
        const vals = [_]u32{ cfg.bar_bg, 1, c.XCB_EVENT_MASK_EXPOSURE };
        _ = c.xcb_create_window(conn, screen.root_depth, win, screen.root, @intCast(gap), @intCast(gap), w, h, 0, c.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual, c.XCB_CW_BACK_PIXEL | c.XCB_CW_OVERRIDE_REDIRECT | c.XCB_CW_EVENT_MASK, &vals);

        const gc = c.xcb_generate_id(conn);
        _ = c.xcb_create_gc(conn, gc, win, 0, null);

        var bar = Bar{
            .conn = conn,
            .win = win,
            .gc = gc,
            .depth = screen.root_depth,
            .w = w,
            .h = h,
            .buf = try std.heap.c_allocator.alloc(u32, @as(usize, w) * h),
        };
        bar.applyShape(screen);
        bar.bat_path = findBattery();
        _ = c.xcb_map_window(conn, win);
        return bar;
    }

    fn applyShape(bar: *Bar, screen: *const c.xcb_screen_t) void {
        const setup = c.xcb_get_setup(bar.conn);
        const msb = setup.*.bitmap_format_bit_order == c.XCB_IMAGE_ORDER_MSB_FIRST;
        const stride = (@as(usize, bar.w) + 31) / 32 * 4;
        const mask = std.heap.c_allocator.alloc(u8, stride * bar.h) catch return;
        defer std.heap.c_allocator.free(mask);
        @memset(mask, 0);
        const r: f32 = cfg.bar_radius;
        for (0..bar.h) |y| {
            for (0..bar.w) |x| {
                if (!insideRound(@floatFromInt(x), @floatFromInt(y), bar.w, bar.h, r)) continue;
                const bit: u3 = @intCast(x % 8);
                mask[y * stride + x / 8] |= if (msb) @as(u8, 0x80) >> bit else @as(u8, 1) << bit;
            }
        }
        const pix = c.xcb_generate_id(bar.conn);
        _ = c.xcb_create_pixmap(bar.conn, 1, pix, screen.root, bar.w, bar.h);
        const gc1 = c.xcb_generate_id(bar.conn);
        // XY_BITMAP paints with the GC's fg for 1-bits and bg for 0-bits; the default is fg=0, bg=1.
        const gc_vals = [_]u32{ 1, 0 };
        _ = c.xcb_create_gc(bar.conn, gc1, pix, c.XCB_GC_FOREGROUND | c.XCB_GC_BACKGROUND, &gc_vals);
        _ = c.xcb_put_image(bar.conn, c.XCB_IMAGE_FORMAT_XY_BITMAP, pix, gc1, bar.w, bar.h, 0, 0, 0, 1, @intCast(mask.len), mask.ptr);
        _ = c.xcb_shape_mask(bar.conn, c.XCB_SHAPE_SO_SET, c.XCB_SHAPE_SK_BOUNDING, bar.win, 0, 0, pix);
        _ = c.xcb_free_gc(bar.conn, gc1);
        _ = c.xcb_free_pixmap(bar.conn, pix);
    }

    // ---- drawing primitives (BGRX pixels) ----

    fn blend(dst: u32, src: u32, cov: f32) u32 {
        if (cov >= 1) return src;
        if (cov <= 0) return dst;
        var out: u32 = 0;
        inline for (.{ 0, 8, 16 }) |sh| {
            const d: f32 = @floatFromInt((dst >> sh) & 0xff);
            const s: f32 = @floatFromInt((src >> sh) & 0xff);
            const v: u32 = @intFromFloat(s * cov + d * (1 - cov) + 0.5);
            out |= v << sh;
        }
        return out;
    }

    fn fill(bar: *Bar, color: u32) void {
        @memset(bar.buf, color);
    }

    /// Rounded rect with antialiased corners.
    fn roundRect(bar: *Bar, x: i32, y: i32, w: i32, h: i32, r: f32, color: u32) void {
        var yy: i32 = y;
        while (yy < y + h) : (yy += 1) {
            var xx: i32 = x;
            while (xx < x + w) : (xx += 1) {
                if (xx < 0 or yy < 0 or xx >= bar.w or yy >= bar.h) continue;
                const cov = roundCoverage(@floatFromInt(xx - x), @floatFromInt(yy - y), @floatFromInt(w), @floatFromInt(h), r);
                const i = @as(usize, @intCast(yy)) * bar.w + @as(usize, @intCast(xx));
                bar.buf[i] = blend(bar.buf[i], color, cov);
            }
        }
    }

    fn text(bar: *Bar, x0: i32, y0: i32, s: []const u8, color: u32) i32 {
        var x = x0;
        for (s) |ch| {
            const g = font[psf_header + @as(usize, ch) * glyph_h ..][0..glyph_h];
            for (0..glyph_h) |row| {
                const bits = g[row];
                for (0..glyph_w) |col| {
                    if (bits & (@as(u8, 0x80) >> @intCast(col)) == 0) continue;
                    const px = x + @as(i32, @intCast(col));
                    const py = y0 + @as(i32, @intCast(row));
                    if (px < 0 or py < 0 or px >= bar.w or py >= bar.h) continue;
                    bar.buf[@as(usize, @intCast(py)) * bar.w + @as(usize, @intCast(px))] = color;
                }
            }
            x += glyph_w;
        }
        return x;
    }

    fn textBold(bar: *Bar, x: i32, y: i32, s: []const u8, color: u32) i32 {
        _ = bar.text(x + 1, y, s, color);
        return bar.text(x, y, s, color);
    }

    // ---- content ----

    /// Repaint if anything visible changed (or `force`). `occupied` has one bit per workspace.
    pub fn draw(bar: *Bar, cur: usize, occupied: u8, force: bool) void {
        var now: c.time_t = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&now, &tm);
        const bat = bar.battery();

        const sig: u64 = @as(u64, @intCast(cur)) | @as(u64, occupied) << 8 | @as(u64, @intCast(@divFloor(now, 60))) << 16 | @as(u64, @intCast(bat.pct + 1)) << 52 | @as(u64, @intFromBool(bat.charging)) << 63;
        if (!force and sig == bar.last_sig) return;
        bar.last_sig = sig;

        bar.fill(cfg.bar_bg);

        // Workspaces, left.
        for (0..cfg.workspaces) |i| {
            const x: i32 = 6 + @as(i32, @intCast(i)) * 30;
            var digit = [1]u8{'1' + @as(u8, @intCast(i))};
            if (i == cur) {
                bar.roundRect(x, 5, 26, 22, 7, cfg.accent);
                _ = bar.textBold(x + 9, 8, &digit, cfg.bar_bg);
            } else {
                const col: u32 = if (occupied & (@as(u8, 1) << @intCast(i)) != 0) cfg.fg else cfg.fg_dim;
                _ = bar.text(x + 9, 8, &digit, col);
            }
        }

        // Clock + date, centered.
        var tbuf: [8]u8 = undefined;
        var dbuf: [16]u8 = undefined;
        const t = std.fmt.bufPrint(&tbuf, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)) }) catch "";
        const d = std.fmt.bufPrint(&dbuf, "{s} {d} {s}", .{ days[@intCast(tm.tm_wday)], @as(u32, @intCast(tm.tm_mday)), months[@intCast(tm.tm_mon)] }) catch "";
        const total: i32 = @intCast((t.len + 2 + d.len) * glyph_w);
        var cx: i32 = @divTrunc(@as(i32, bar.w) - total, 2);
        cx = bar.textBold(cx, 8, t, cfg.fg_bright);
        _ = bar.text(cx + 2 * glyph_w, 8, d, cfg.fg_dim);

        // Right side: battery.
        if (bat.pct >= 0) {
            var bbuf: [12]u8 = undefined;
            const b = std.fmt.bufPrint(&bbuf, "{d}%{s}", .{ @as(u32, @intCast(bat.pct)), if (bat.charging) "+" else "" }) catch "";
            const label = "bat ";
            const rw: i32 = @intCast((label.len + b.len) * glyph_w);
            const rx = @as(i32, bar.w) - 12 - rw;
            const nx = bar.text(rx, 8, label, cfg.accent);
            _ = bar.text(nx, 8, b, cfg.fg);
        }

        bar.flush();
    }

    fn flush(bar: *Bar) void {
        const rows_per: usize = 16;
        var y: usize = 0;
        while (y < bar.h) : (y += rows_per) {
            const n = @min(rows_per, bar.h - y);
            const slice = std.mem.sliceAsBytes(bar.buf[y * bar.w ..][0 .. n * bar.w]);
            _ = c.xcb_put_image(bar.conn, c.XCB_IMAGE_FORMAT_Z_PIXMAP, bar.win, bar.gc, bar.w, @intCast(n), 0, @intCast(y), 0, bar.depth, @intCast(slice.len), slice.ptr);
        }
        _ = c.xcb_flush(bar.conn);
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

fn readFile(path: [*:0]const u8, buf: []u8) []const u8 {
    const fd = c.open(path, c.O_RDONLY);
    if (fd < 0) return buf[0..0];
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    return if (n > 0) buf[0..@intCast(n)] else buf[0..0];
}

/// 1.0 inside a w*h rounded rect (radius r) at pixel (x, y), fading over corner edges.
fn roundCoverage(x: f32, y: f32, w: f32, h: f32, r: f32) f32 {
    const px = x + 0.5;
    const py = y + 0.5;
    const cx = if (px < r) r else if (px > w - r) w - r else px;
    const cy = if (py < r) r else if (py > h - r) h - r else py;
    const dx = px - cx;
    const dy = py - cy;
    const d = @sqrt(dx * dx + dy * dy);
    return std.math.clamp(r - d + 0.5, 0, 1);
}

fn insideRound(x: f32, y: f32, w: u16, h: u16, r: f32) bool {
    return roundCoverage(x, y, @floatFromInt(w), @floatFromInt(h), r) >= 0.5;
}
