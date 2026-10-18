// Software drawing: a BGRX framebuffer with an 8x16 PSF bitmap font, and a
// Surface = override-redirect X window painted from it (optionally rounded via SHAPE).

const std = @import("std");
const c = @import("c.zig").c;

const font = @embedFile("font.psf");
pub const glyph_w = 8;
pub const glyph_h = 16;
const psf_header = 32; // PSF2 header, then 256 glyphs of 16 bytes

pub fn blend(dst: u32, src: u32, cov: f32) u32 {
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

/// 1.0 inside a w*h rounded rect (radius r) at pixel (x, y), fading over corner edges.
pub fn roundCoverage(x: f32, y: f32, w: f32, h: f32, r: f32) f32 {
    const px = x + 0.5;
    const py = y + 0.5;
    const cx = if (px < r) r else if (px > w - r) w - r else px;
    const cy = if (py < r) r else if (py > h - r) h - r else py;
    const dx = px - cx;
    const dy = py - cy;
    const d = @sqrt(dx * dx + dy * dy);
    return std.math.clamp(r - d + 0.5, 0, 1);
}

pub const Canvas = struct {
    buf: []u32,
    w: u16,
    h: u16,

    pub fn init(w: u16, h: u16) !Canvas {
        return .{ .buf = try std.heap.c_allocator.alloc(u32, @as(usize, w) * h), .w = w, .h = h };
    }

    pub fn deinit(cv: *Canvas) void {
        std.heap.c_allocator.free(cv.buf);
    }

    pub fn fill(cv: *Canvas, color: u32) void {
        @memset(cv.buf, color);
    }

    pub fn rect(cv: *Canvas, x: i32, y: i32, w: i32, h: i32, color: u32) void {
        var yy = @max(y, 0);
        const y1 = @min(y + h, cv.h);
        const x0 = @max(x, 0);
        const x1 = @min(x + w, cv.w);
        if (x1 <= x0) return;
        while (yy < y1) : (yy += 1) {
            const row = @as(usize, @intCast(yy)) * cv.w;
            @memset(cv.buf[row + @as(usize, @intCast(x0)) ..][0..@intCast(x1 - x0)], color);
        }
    }

    /// Rounded rect with antialiased corners.
    pub fn roundRect(cv: *Canvas, x: i32, y: i32, w: i32, h: i32, r: f32, color: u32) void {
        var yy: i32 = @max(y, 0);
        const y1 = @min(y + h, cv.h);
        const x0 = @max(x, 0);
        const x1 = @min(x + w, cv.w);
        while (yy < y1) : (yy += 1) {
            var xx: i32 = x0;
            while (xx < x1) : (xx += 1) {
                const cov = roundCoverage(@floatFromInt(xx - x), @floatFromInt(yy - y), @floatFromInt(w), @floatFromInt(h), r);
                const i = @as(usize, @intCast(yy)) * cv.w + @as(usize, @intCast(xx));
                cv.buf[i] = blend(cv.buf[i], color, cov);
            }
        }
    }

    pub fn textScaled(cv: *Canvas, x0: i32, y0: i32, s: []const u8, color: u32, scale: u8) i32 {
        const sc: i32 = scale;
        var x = x0;
        for (s) |ch| {
            const g = font[psf_header + @as(usize, ch) * glyph_h ..][0..glyph_h];
            for (0..glyph_h) |row| {
                const bits = g[row];
                if (bits == 0) continue;
                for (0..glyph_w) |col| {
                    if (bits & (@as(u8, 0x80) >> @intCast(col)) == 0) continue;
                    cv.rect(x + @as(i32, @intCast(col)) * sc, y0 + @as(i32, @intCast(row)) * sc, sc, sc, color);
                }
            }
            x += glyph_w * sc;
        }
        return x;
    }

    pub fn text(cv: *Canvas, x: i32, y: i32, s: []const u8, color: u32) i32 {
        return cv.textScaled(x, y, s, color, 1);
    }

    /// Fake bold: draw twice, one pixel apart.
    pub fn textBold(cv: *Canvas, x: i32, y: i32, s: []const u8, color: u32) i32 {
        _ = cv.text(x + 1, y, s, color);
        return cv.text(x, y, s, color);
    }

    /// Draw `s` clipped to `max_chars`, ending in "..." when cut.
    pub fn textFit(cv: *Canvas, x: i32, y: i32, s: []const u8, max_chars: usize, color: u32) i32 {
        if (s.len <= max_chars) return cv.text(x, y, s, color);
        const keep = if (max_chars > 3) max_chars - 3 else 0;
        const nx = cv.text(x, y, s[0..keep], color);
        return cv.text(nx, y, "...", color);
    }
};

pub const Surface = struct {
    conn: *c.xcb_connection_t,
    win: c.xcb_window_t,
    gc: c.xcb_gcontext_t,
    depth: u8,
    cv: Canvas,

    /// Create an unmapped override-redirect window. `radius` > 0 clips corners with SHAPE.
    pub fn create(conn: *c.xcb_connection_t, screen: *const c.xcb_screen_t, x: i32, y: i32, w: u16, h: u16, radius: u16, event_mask: u32, bg: u32) !Surface {
        const win = c.xcb_generate_id(conn);
        const vals = [_]u32{ bg, 1, event_mask };
        _ = c.xcb_create_window(conn, screen.root_depth, win, screen.root, @intCast(x), @intCast(y), w, h, 0, c.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual, c.XCB_CW_BACK_PIXEL | c.XCB_CW_OVERRIDE_REDIRECT | c.XCB_CW_EVENT_MASK, &vals);
        const gc = c.xcb_generate_id(conn);
        _ = c.xcb_create_gc(conn, gc, win, 0, null);
        var s = Surface{ .conn = conn, .win = win, .gc = gc, .depth = screen.root_depth, .cv = try Canvas.init(w, h) };
        if (radius > 0) s.applyShape(screen, radius);
        return s;
    }

    pub fn destroy(s: *Surface) void {
        _ = c.xcb_destroy_window(s.conn, s.win);
        _ = c.xcb_free_gc(s.conn, s.gc);
        s.cv.deinit();
    }

    pub fn map(s: *Surface) void {
        _ = c.xcb_map_window(s.conn, s.win);
    }

    pub fn setStack(s: *Surface, above: bool) void {
        const mode: u32 = if (above) c.XCB_STACK_MODE_ABOVE else c.XCB_STACK_MODE_BELOW;
        _ = c.xcb_configure_window(s.conn, s.win, c.XCB_CONFIG_WINDOW_STACK_MODE, &mode);
    }

    pub fn move(s: *Surface, x: i32, y: i32) void {
        const v = [_]u32{ @bitCast(x), @bitCast(y) };
        _ = c.xcb_configure_window(s.conn, s.win, c.XCB_CONFIG_WINDOW_X | c.XCB_CONFIG_WINDOW_Y, &v);
    }

    fn applyShape(s: *Surface, screen: *const c.xcb_screen_t, radius: u16) void {
        const msb = c.xcb_get_setup(s.conn).*.bitmap_format_bit_order == c.XCB_IMAGE_ORDER_MSB_FIRST;
        const w = s.cv.w;
        const h = s.cv.h;
        const stride = (@as(usize, w) + 31) / 32 * 4;
        const mask = std.heap.c_allocator.alloc(u8, stride * h) catch return;
        defer std.heap.c_allocator.free(mask);
        @memset(mask, 0);
        const r: f32 = @floatFromInt(radius);
        for (0..h) |y| {
            for (0..w) |x| {
                if (roundCoverage(@floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h), r) < 0.5) continue;
                const bit: u3 = @intCast(x % 8);
                mask[y * stride + x / 8] |= if (msb) @as(u8, 0x80) >> bit else @as(u8, 1) << bit;
            }
        }
        const pix = c.xcb_generate_id(s.conn);
        _ = c.xcb_create_pixmap(s.conn, 1, pix, screen.root, w, h);
        const gc1 = c.xcb_generate_id(s.conn);
        // XY_BITMAP paints with the GC's fg for 1-bits and bg for 0-bits; the default is fg=0, bg=1.
        const gc_vals = [_]u32{ 1, 0 };
        _ = c.xcb_create_gc(s.conn, gc1, pix, c.XCB_GC_FOREGROUND | c.XCB_GC_BACKGROUND, &gc_vals);
        _ = c.xcb_put_image(s.conn, c.XCB_IMAGE_FORMAT_XY_BITMAP, pix, gc1, w, h, 0, 0, 0, 1, @intCast(mask.len), mask.ptr);
        _ = c.xcb_shape_mask(s.conn, c.XCB_SHAPE_SO_SET, c.XCB_SHAPE_SK_BOUNDING, s.win, 0, 0, pix);
        _ = c.xcb_free_gc(s.conn, gc1);
        _ = c.xcb_free_pixmap(s.conn, pix);
    }

    /// Push the canvas to the window (also used to answer Expose).
    pub fn flush(s: *Surface) void {
        const rows_per: usize = 16;
        var y: usize = 0;
        while (y < s.cv.h) : (y += rows_per) {
            const n = @min(rows_per, s.cv.h - y);
            const slice = std.mem.sliceAsBytes(s.cv.buf[y * s.cv.w ..][0 .. n * s.cv.w]);
            _ = c.xcb_put_image(s.conn, c.XCB_IMAGE_FORMAT_Z_PIXMAP, s.win, s.gc, s.cv.w, @intCast(n), 0, @intCast(y), 0, s.depth, @intCast(slice.len), slice.ptr);
        }
        _ = c.xcb_flush(s.conn);
    }
};
