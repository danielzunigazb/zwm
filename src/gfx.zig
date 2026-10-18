// Software drawing: a BGRX framebuffer with an 8x16 PSF bitmap font, and a
// Surface = override-redirect X window painted from it (optionally rounded via SHAPE).

const std = @import("std");
const c = @import("c.zig").c;

const font = @embedFile("font.psf");
pub const glyph_w = 8;
pub const glyph_h = 16;
const psf_header = 32; // PSF2 header, then 256 glyphs of 16 bytes

/// True when JetBrains Mono loaded, i.e. text can be real UTF-8 instead of the bitmap font's ASCII.
pub fn hasTtf() bool {
    return ttf.get(false) != null;
}

/// Number of UTF-8 code points (invalid bytes count as one each).
pub fn cpCount(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) i += cpLen(s, i);
    return n;
}

fn cpLen(s: []const u8, i: usize) usize {
    const l = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    if (i + l > s.len) return 1;
    _ = std.unicode.utf8Decode(s[i..][0..l]) catch return 1;
    return l;
}

/// Byte offset of the `n`-th code point (or s.len).
pub fn cpOffset(s: []const u8, n: usize) usize {
    var i: usize = 0;
    var k: usize = 0;
    while (i < s.len and k < n) : (k += 1) i += cpLen(s, i);
    return i;
}

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

/// Rasterised glyph coverage, kept so redrawing text (the bar repaints every frame while the
/// workspace pill glides) never goes back to FreeType. Open-addressed, fixed size; once it is
/// nearly full new glyphs are simply rendered uncached.
const glyphs = struct {
    const Glyph = struct { w: u16, h: u16, left: i32, top: i32, data: []u8 };
    const slots = 1024;
    const max_load = 768;
    var used: [slots]bool = [_]bool{false} ** slots;
    var keys: [slots]u64 = undefined;
    var table: [slots]Glyph = undefined;
    var count: usize = 0;
    var scratch: [64 * 1024]u8 = undefined; // for glyphs that do not get cached

    fn keyOf(cp: u21, px16: u32, bold: bool) u64 {
        return @as(u64, cp) | @as(u64, px16) << 24 | @as(u64, @intFromBool(bold)) << 63;
    }

    fn get(face: c.FT_Face, cp: u21, px: f32, px16: u32, bold: bool, size_set: *bool) ?Glyph {
        const key = keyOf(cp, px16, bold);
        var h: usize = @intCast((key *% 0x9E3779B97F4A7C15) >> 54); // top 10 bits
        var probes: usize = 0;
        while (used[h] and probes < slots) : (probes += 1) {
            if (keys[h] == key) return table[h];
            h = (h + 1) & (slots - 1);
        }

        if (!size_set.*) {
            _ = c.FT_Set_Char_Size(face, 0, @intFromFloat(px * 64), 72, 72);
            size_set.* = true;
        }
        if (c.FT_Load_Char(face, cp, c.FT_LOAD_RENDER | c.FT_LOAD_NO_HINTING) != 0) return null;
        const slot = face.*.glyph;
        const bm = slot.*.bitmap;
        if (bm.pixel_mode != c.FT_PIXEL_MODE_GRAY and bm.width * bm.rows != 0) return null;
        const w: usize = bm.width;
        const rows: usize = bm.rows;
        const pitch: usize = @intCast(@abs(bm.pitch));
        const size = w * rows;
        const cacheable = count < max_load and !used[h] and probes < slots;
        var out: []u8 = undefined;
        if (cacheable) {
            out = std.heap.c_allocator.alloc(u8, size) catch return null;
        } else if (size <= scratch.len) {
            out = scratch[0..size];
        } else return null;
        for (0..rows) |r| @memcpy(out[r * w ..][0..w], bm.buffer[r * pitch ..][0..w]);
        const g = Glyph{ .w = @intCast(w), .h = @intCast(rows), .left = slot.*.bitmap_left, .top = slot.*.bitmap_top, .data = out };
        if (cacheable) {
            used[h] = true;
            keys[h] = key;
            table[h] = g;
            count += 1;
        }
        return g;
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

    /// Rounded rect with antialiased corners. Only the corner squares pay for coverage math;
    /// the rest is plain row fills.
    pub fn roundRect(cv: *Canvas, x: i32, y: i32, w: i32, h: i32, r: f32, color: u32) void {
        if (w <= 0 or h <= 0) return;
        const ri: i32 = @min(@as(i32, @intFromFloat(@ceil(r))), @divTrunc(@min(w, h), 2));
        const y0 = @max(y, 0);
        const y1 = @min(y + h, @as(i32, cv.h));
        const x0 = @max(x, 0);
        const x1 = @min(x + w, @as(i32, cv.w));
        var yy: i32 = y0;
        while (yy < y1) : (yy += 1) {
            const ry = yy - y;
            const in_corner_rows = ry < ri or ry >= h - ri;
            // Columns [cx0, cx1) are fully inside whenever this row is outside the corner bands.
            const cx0 = if (in_corner_rows) x + ri else x0;
            const cx1 = if (in_corner_rows) x + w - ri else x1;
            const fx0 = std.math.clamp(cx0, x0, x1);
            const fx1 = std.math.clamp(cx1, x0, x1);
            const row = @as(usize, @intCast(yy)) * cv.w;
            if (fx1 > fx0) @memset(cv.buf[row + @as(usize, @intCast(fx0)) ..][0..@intCast(fx1 - fx0)], color);
            if (!in_corner_rows) continue;
            var xx: i32 = x0;
            while (xx < x1) : (xx += 1) {
                if (xx >= fx0 and xx < fx1) {
                    xx = fx1 - 1;
                    continue;
                }
                const cov = roundCoverage(@floatFromInt(xx - x), @floatFromInt(ry), @floatFromInt(w), @floatFromInt(h), r);
                if (cov <= 0) continue;
                const i = row + @as(usize, @intCast(xx));
                cv.buf[i] = blend(cv.buf[i], color, cov);
            }
        }
    }

    /// Text with its baseline at `base`; `px` is the em size. Advance is 0.6em (JetBrains Mono).
    /// Falls back to the 8x16 bitmap font when no TTF could be loaded. Returns the end x.
    pub fn textAt(cv: *Canvas, x0: i32, base: i32, s: []const u8, color: u32, px: f32, bold: bool) i32 {
        const face = ttf.get(bold) orelse return cv.bitmapText(x0, base - 12, s, color, @max(1, @as(i32, @intFromFloat(px / 13.3 + 0.5))), bold);
        const px16: u32 = @intFromFloat(@round(px * 16));
        var size_set = false; // FreeType's size is only touched on a cache miss
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
            const g = glyphs.get(face, cp, px, px16, bold, &size_set) orelse continue;
            const ox = gx + g.left;
            const oy = base - g.top;
            for (0..g.h) |r| {
                const yy = oy + @as(i32, @intCast(r));
                if (yy < 0 or yy >= cv.h) continue;
                const row = @as(usize, @intCast(yy)) * cv.w;
                for (0..g.w) |q| {
                    const xx = ox + @as(i32, @intCast(q));
                    if (xx < 0 or xx >= cv.w) continue;
                    const a = g.data[r * g.w + q];
                    if (a == 0) continue;
                    const idx = row + @as(usize, @intCast(xx));
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
    /// Like textFit but at an explicit baseline and 13px (bold optional).
    pub fn textFit13(cv: *Canvas, x: i32, base: i32, s: []const u8, max_chars: usize, color: u32, bold: bool) i32 {
        if (cpCount(s) <= max_chars) return cv.textAt(x, base, s, color, 13, bold);
        const keep = cpOffset(s, if (max_chars > 3) max_chars - 3 else 0);
        const nx = cv.textAt(x, base, s[0..keep], color, 13, bold);
        return cv.textAt(nx, base, "...", color, 13, bold);
    }

    /// Draw `s` clipped to `max_chars` code points, ending in "..." when cut.
    pub fn textFit(cv: *Canvas, x: i32, y: i32, s: []const u8, max_chars: usize, color: u32) i32 {
        return cv.textFit13(x, y + 12, s, max_chars, color, false);
    }
};

var rect_scratch: [16384]u32 = undefined; // flushRect staging (64 KB)

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
    /// Push only a sub-rectangle (e.g. the area where the workspace pill moves).
    pub fn flushRect(s: *Surface, x: u16, y: u16, w: u16, h: u16) void {
        if (x >= s.cv.w or y >= s.cv.h) return;
        const rw: usize = @min(w, s.cv.w - x);
        const rh: usize = @min(h, s.cv.h - y);
        if (rw * rh > rect_scratch.len) return s.flush();
        for (0..rh) |r| @memcpy(rect_scratch[r * rw ..][0..rw], s.cv.buf[(y + r) * s.cv.w + x ..][0..rw]);
        const bytes = std.mem.sliceAsBytes(rect_scratch[0 .. rw * rh]);
        _ = c.xcb_put_image(s.conn, c.XCB_IMAGE_FORMAT_Z_PIXMAP, s.win, s.gc, @intCast(rw), @intCast(rh), @intCast(x), @intCast(y), 0, s.depth, @intCast(bytes.len), bytes.ptr);
        _ = c.xcb_flush(s.conn);
    }

    pub fn flush(s: *Surface) void {
        // Keep every PutImage well under the 256K request limit even on wide surfaces.
        const rows_per: usize = @max(1, 200_000 / (@as(usize, s.cv.w) * 4));
        var y: usize = 0;
        while (y < s.cv.h) : (y += rows_per) {
            const n = @min(rows_per, s.cv.h - y);
            const slice = std.mem.sliceAsBytes(s.cv.buf[y * s.cv.w ..][0 .. n * s.cv.w]);
            _ = c.xcb_put_image(s.conn, c.XCB_IMAGE_FORMAT_Z_PIXMAP, s.win, s.gc, s.cv.w, @intCast(n), 0, @intCast(y), 0, s.depth, @intCast(slice.len), slice.ptr);
        }
        _ = c.xcb_flush(s.conn);
    }
};
