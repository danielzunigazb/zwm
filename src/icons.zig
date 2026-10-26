// Stroke icons on a 24-unit grid (Lucide-style), drawn antialiased at any size.

const gfx = @import("gfx.zig");

pub const Kind = enum { volume, wifi, battery, brightness, note, prev, next, pause, play };

pub fn draw(cv: *gfx.Canvas, kind: Kind, x: f32, y: f32, size: f32, color: u32) void {
    const k = size / 24.0;
    const w = 2.0 * k;
    const o = struct {
        k: f32,
        x: f32,
        y: f32,
        cv: *gfx.Canvas,
        w: f32,
        color: u32,
        fn ln(s: @This(), x0: f32, y0: f32, x1: f32, y1: f32) void {
            s.cv.line(s.x + x0 * s.k, s.y + y0 * s.k, s.x + x1 * s.k, s.y + y1 * s.k, s.w, s.color);
        }
        fn poly(s: @This(), pts: []const [2]f32) void {
            for (pts, 0..) |p, i| {
                const n = pts[(i + 1) % pts.len];
                s.ln(p[0], p[1], n[0], n[1]);
            }
        }
        fn arc(s: @This(), cx: f32, cy: f32, r: f32, a0: f32, a1: f32) void {
            s.cv.arc(s.x + cx * s.k, s.y + cy * s.k, r * s.k, a0, a1, s.w, s.color);
        }
        fn ring(s: @This(), cx: f32, cy: f32, r: f32) void {
            s.arc(cx, cy, r, 0, 360);
        }
    }{ .k = k, .x = x, .y = y, .cv = cv, .w = w, .color = color };

    switch (kind) {
        .volume => {
            o.poly(&.{ .{ 11, 5 }, .{ 6, 9 }, .{ 2, 9 }, .{ 2, 15 }, .{ 6, 15 }, .{ 11, 19 } });
            o.arc(11.93, 12, 5, -45, 45);
            o.arc(11.86, 12, 10, -44.4, 44.4);
        },
        .wifi => {
            o.arc(12, 19.64, 10, -135.6, -44.4);
            o.arc(12, 19.57, 5, -134.4, -45.6);
            o.ln(12, 19.5, 12, 19.5);
        },
        .battery => {
            o.poly(&.{ .{ 4, 7 }, .{ 17, 7 }, .{ 19, 9 }, .{ 19, 15 }, .{ 17, 17 }, .{ 4, 17 }, .{ 2, 15 }, .{ 2, 9 } });
            o.ln(22, 11, 22, 13);
            o.ln(6, 11, 6, 13);
            o.ln(10, 11, 10, 13);
        },
        .note => {
            o.ln(9, 18, 9, 5);
            o.ln(9, 5, 21, 3);
            o.ln(21, 3, 21, 16);
            o.ring(6, 18, 3);
            o.ring(18, 16, 3);
        },
        .prev => {
            o.poly(&.{ .{ 19, 20 }, .{ 9, 12 }, .{ 19, 4 } });
            o.ln(5, 19, 5, 5);
        },
        .next => {
            o.poly(&.{ .{ 5, 4 }, .{ 15, 12 }, .{ 5, 20 } });
            o.ln(19, 5, 19, 19);
        },
        .pause => {
            o.poly(&.{ .{ 6, 4 }, .{ 10, 4 }, .{ 10, 20 }, .{ 6, 20 } });
            o.poly(&.{ .{ 14, 4 }, .{ 18, 4 }, .{ 18, 20 }, .{ 14, 20 } });
        },
        .play => o.poly(&.{ .{ 6, 3 }, .{ 20, 12 }, .{ 6, 21 } }),
        .brightness => {
            // Sun icon with rays
            o.arc(12, 12, 4, 0, 360); // center circle
            o.ln(12, 3, 12, 6);
            o.ln(12, 18, 12, 21);
            o.ln(3, 12, 6, 12);
            o.ln(18, 12, 21, 12);
            o.ln(6, 6, 8, 8);
            o.ln(16, 16, 18, 18);
            o.ln(6, 18, 8, 16);
            o.ln(16, 6, 18, 8);
        },
    }
}
