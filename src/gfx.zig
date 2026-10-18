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

/// Lazily loaded JetBrains Mono (regular + semibold) from the system fonts directory.
const ttf = struct {
    var lib: c.FT_Library = null;
    var regular: c.FT_Face = null;
    var semibold: c.FT_Face = null;
    var tried = false;

    const dirs = [_][]const u8{ "/usr/share/fonts/TTF/", "/usr/share/fonts/truetype/jetbrains-mono/", "/usr/share/fonts/jetbrains-mono/", "/usr/share/fonts/OTF/" };
    const regular_names = [_][]const u8{ "JetBrainsMonoNerdFontMono-Regular.ttf", "JetBrainsMono-Regular.ttf", "JetBrainsMonoNerdFont-Regular.ttf" };
    const semibold_names = [_][]const u8{ "JetBrainsMonoNerdFontMono-SemiBold.ttf", "JetBrainsMono-SemiBold.ttf", "JetBrainsMonoNerdFont-SemiBold.ttf" };

    fn open(names: []const []const u8) c.FT_Face {
        var buf: [256]u8 = undefined;
        for (dirs) |d| for (names) |n| {
            const path = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ d, n }) catch continue;
            var face: c.FT_Face = null;
            if (c.FT_New_Face(lib, path.ptr, 0, &face) == 0) return face;
        };
        return null;
    }

    fn get(bold: bool) c.FT_Face {
        if (!tried) {
            tried = true;
            if (c.FT_Init_FreeType(&lib) == 0) {
                regular = open(&regular_names);
                semibold = open(&semibold_names);
            }
        }
        return if (bold and semibold != null) semibold else regular;
    }
};

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

    /// Text with its baseline at `base`; `px` is the em size. Advance is 0.6em (JetBrains Mono).
    /// Falls back to the 8x16 bitmap font when no TTF could be loaded. Returns the end x.
    pub fn textAt(cv: *Canvas, x0: i32, base: i32, s: []const u8, color: u32, px: f32, bold: bool) i32 {
        const face = ttf.get(bold) orelse return cv.bitmapText(x0, base - 12, s, color, @max(1, @as(i32, @intFromFloat(px / 13.3 + 0.5))), bold);
        _ = c.FT_Set_Char_Size(face, 0, @intFromFloat(px * 64), 72, 72);
        const adv = px * 0.6;
        var fx: f32 = @floatFromInt(x0);
        var i: usize = 0;
        while (i < s.len) {
            var cp: u21 = s[i];
            var n: usize = 1;
            if (s[i] >= 0x80) {
                n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                if (i + n > s.len) n = 1;
                cp = if (n > 1) (std.unicode.utf8Decode(s[i..][0..n]) catch s[i]) else s[i];
            }
            i += n;
            const gx: i32 = @intFromFloat(@round(fx));
            fx += adv;
            if (cp == ' ') continue;
            if (c.FT_Load_Char(face, cp, c.FT_LOAD_RENDER | c.FT_LOAD_NO_HINTING) != 0) continue;
            const g = face.*.glyph;
            const bm = g.*.bitmap;
            const ox = gx + g.*.bitmap_left;
            const oy = base - g.*.bitmap_top;
            const pitch: usize = @intCast(bm.pitch);
            for (0..bm.rows) |r| {
                const yy = oy + @as(i32, @intCast(r));
                if (yy < 0 or yy >= cv.h) continue;
                for (0..bm.width) |q| {
                    const xx = ox + @as(i32, @intCast(q));
                    if (xx < 0 or xx >= cv.w) continue;
                    const a = bm.buffer[r * pitch + q];
                    if (a == 0) continue;
                    const idx = @as(usize, @intCast(yy)) * cv.w + @as(usize, @intCast(xx));
                    cv.buf[idx] = blend(cv.buf[idx], color, @as(f32, @floatFromInt(a)) / 255.0);
                }
            }
        }
        return @intFromFloat(@round(fx));
    }

    fn bitmapText(cv: *Canvas, x0: i32, y0: i32, s: []const u8, color: u32, sc: i32, bold: bool) i32 {
        if (bold) _ = cv.bitmapText(x0 + 1, y0, s, color, sc, false);
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

    /// Legacy API: `y0` is the top of a 16px line; 8px advance per scale step.
    pub fn textScaled(cv: *Canvas, x0: i32, y0: i32, s: []const u8, color: u32, scale: u8) i32 {
        const k: f32 = @floatFromInt(scale);
        return cv.textAt(x0, y0 + @as(i32, scale) * 12, s, color, 13.333 * k, false);
    }

    pub fn text(cv: *Canvas, x: i32, y: i32, s: []const u8, color: u32) i32 {
        return cv.textAt(x, y + 12, s, color, 13.333, false);
    }

    pub fn textBold(cv: *Canvas, x: i32, y: i32, s: []const u8, color: u32) i32 {
        return cv.textAt(x, y + 12, s, color, 13.333, true);
    }

    // ---- antialiased strokes (for icons) ----

    /// Round-capped line of width `w`.
    pub fn line(cv: *Canvas, x0: f32, y0: f32, x1: f32, y1: f32, w: f32, color: u32) void {
        const r = w / 2;
        const bx0: i32 = @intFromFloat(@floor(@min(x0, x1) - r - 1));
        const bx1: i32 = @intFromFloat(@ceil(@max(x0, x1) + r + 1));
        const by0: i32 = @intFromFloat(@floor(@min(y0, y1) - r - 1));
        const by1: i32 = @intFromFloat(@ceil(@max(y0, y1) + r + 1));
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len2 = dx * dx + dy * dy;
        var yy = @max(by0, 0);
        while (yy <= @min(by1, cv.h - 1)) : (yy += 1) {
            var xx = @max(bx0, 0);
            while (xx <= @min(bx1, cv.w - 1)) : (xx += 1) {
                const px = @as(f32, @floatFromInt(xx)) + 0.5 - x0;
                const py = @as(f32, @floatFromInt(yy)) + 0.5 - y0;
                const t = if (len2 == 0) 0 else std.math.clamp((px * dx + py * dy) / len2, 0, 1);
                const ex = px - t * dx;
                const ey = py - t * dy;
                const cov = std.math.clamp(r - @sqrt(ex * ex + ey * ey) + 0.5, 0, 1);
                if (cov <= 0) continue;
                const idx = @as(usize, @intCast(yy)) * cv.w + @as(usize, @intCast(xx));
                cv.buf[idx] = blend(cv.buf[idx], color, cov);
            }
        }
    }

    /// Arc around (cx, cy), angles in degrees (0 = right, 90 = down).
    pub fn arc(cv: *Canvas, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, w: f32, color: u32) void {
        const steps: usize = 16;
        var px: f32 = 0;
        var py: f32 = 0;
        for (0..steps + 1) |i| {
            const a = (a0 + (a1 - a0) * @as(f32, @floatFromInt(i)) / steps) * std.math.pi / 180.0;
            const x = cx + r * @cos(a);
            const y = cy + r * @sin(a);
            if (i > 0) cv.line(px, py, x, y, w, color);
            px = x;
            py = y;
        }
    }
    /// Like textFit but at an explicit baseline and 13px (bold optional); cuts UTF-8 on a boundary.
    pub fn textFit13(cv: *Canvas, x: i32, base: i32, s: []const u8, max_chars: usize, color: u32, bold: bool) i32 {
        if (s.len <= max_chars) return cv.textAt(x, base, s, color, 13, bold);
        var keep = if (max_chars > 3) max_chars - 3 else 0;
        while (keep > 0 and keep < s.len and (s[keep] & 0xc0) == 0x80) keep -= 1;
        const nx = cv.textAt(x, base, s[0..keep], color, 13, bold);
        return cv.textAt(nx, base, "...", color, 13, bold);
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

    /// Change the window height in place (no unmap, so no flicker); keeps position and rounding.
    pub fn resize(s: *Surface, screen: *const c.xcb_screen_t, h: u16, radius: u16) void {
        const w = s.cv.w;
        const cv = Canvas.init(w, h) catch return;
        s.cv.deinit();
        s.cv = cv;
        const v = [_]u32{ w, h };
        _ = c.xcb_configure_window(s.conn, s.win, c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT, &v);
        if (radius > 0) s.applyShape(screen, radius);
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
