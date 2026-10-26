// Binary space partition tree. Leaves hold windows, inner nodes hold a split.

const std = @import("std");

pub const Dir = enum { horizontal, vertical }; // horizontal = children side by side

pub const Rect = struct { x: i32, y: i32, w: u32, h: u32 };

pub const Node = struct {
    parent: ?*Node = null,
    win: u32 = 0, // valid when a == null
    skip_unmap: u8 = 0, // UnmapNotify events caused by the WM hiding this window
    dir: Dir = .horizontal,
    ratio: f32 = 0.5,
    a: ?*Node = null,
    b: ?*Node = null,

    // Leaf geometry for animation (driven from main.zig): target, current and last-sent rect.
    placed: bool = false, // `cx..` are valid (window has been configured at least once here)
    tx: i32 = 0,
    ty: i32 = 0,
    tw: u32 = 1,
    th: u32 = 1,
    cx: f32 = 0,
    cy: f32 = 0,
    cw: f32 = 1,
    ch: f32 = 1,
    sx: i32 = 0,
    sy: i32 = 0,
    sw: u32 = 0,
    sh: u32 = 0,

    pub fn isLeaf(n: *const Node) bool {
        return n.a == null;
    }
};

pub const Tree = struct {
    gpa: std.mem.Allocator,
    root: ?*Node = null,

    pub fn find(t: *const Tree, win: u32) ?*Node {
        return findIn(t.root, win);
    }

    fn findIn(n: ?*Node, win: u32) ?*Node {
        const node = n orelse return null;
        if (node.isLeaf()) return if (node.win == win) node else null;
        return findIn(node.a, win) orelse findIn(node.b, win);
    }

    /// Insert `win` by splitting `target` (or become root). Splits along the longer side.
    pub fn insert(t: *Tree, target: ?*Node, win: u32, area: Rect) !*Node {
        const leaf = try t.gpa.create(Node);
        leaf.* = .{ .win = win };
        const old = target orelse {
            t.root = leaf;
            return leaf;
        };
        const inner = try t.gpa.create(Node);
        const r = rectOf(t, old, area);
        inner.* = .{
            .parent = old.parent,
            .dir = if (r.w >= r.h) .horizontal else .vertical,
            .a = old,
            .b = leaf,
        };
        if (old.parent) |p| {
            if (p.a == old) p.a = inner else p.b = inner;
        } else t.root = inner;
        old.parent = inner;
        leaf.parent = inner;
        return leaf;
    }

    /// Remove leaf; returns the sibling subtree's first leaf (for focus), if any.
    pub fn remove(t: *Tree, leaf: *Node) ?*Node {
        const p = leaf.parent orelse {
            t.root = null;
            t.gpa.destroy(leaf);
            return null;
        };
        const sib = if (p.a == leaf) p.b.? else p.a.?;
        sib.parent = p.parent;
        if (p.parent) |gp| {
            if (gp.a == p) gp.a = sib else gp.b = sib;
        } else t.root = sib;
        t.gpa.destroy(leaf);
        t.gpa.destroy(p);
        return firstLeaf(sib);
    }

    pub fn firstLeaf(n: *Node) *Node {
        var cur = n;
        while (cur.a) |a| cur = a;
        return cur;
    }

    pub const Entry = struct { node: *Node, rect: Rect };
    /// Windows per workspace that the geometry and focus code can see. Beyond this, collect() skips
    /// leaves, so focus movement would ignore them; 256 is far past what fits on a screen anyway.
    pub const max_leaves = 256;

    /// Flatten leaves with their (gapless) rects.
    pub fn collect(n: ?*Node, r: Rect, out: *[max_leaves]Entry, len: *usize) void {
        const node = n orelse return;
        if (node.isLeaf()) {
            if (len.* < max_leaves) {
                out[len.*] = .{ .node = node, .rect = r };
                len.* += 1;
            }
            return;
        }
        collect(node.a, split(node, r, false), out, len);
        collect(node.b, split(node, r, true), out, len);
    }

    /// Nearest split along `dir` that has `n` on the side `want_a` (true = first child). Resizing
    /// toward the right needs the leaf in the left child: its right edge is the divider.
    pub fn ancestorOn(n: *Node, dir: Dir, want_a: bool) ?*Node {
        var child = n;
        while (child.parent) |p| : (child = p) {
            if (p.dir == dir and (p.a == child) == want_a) return p;
        }
        return null;
    }

    fn rectOf(t: *const Tree, n: *Node, area: Rect) Rect {
        var path: [64]*Node = undefined;
        var len: usize = 0;
        var cur: ?*Node = n;
        while (cur) |c| : (cur = c.parent) {
            if (len == path.len) break; // absurdly deep tree: stop rather than overflow
            path[len] = c;
            len += 1;
        }
        _ = t;
        var r = area;
        var i = len;
        while (i > 1) {
            i -= 1;
            const p = path[i];
            r = split(p, r, path[i - 1] == p.b.?);
        }
        return r;
    }

    pub fn split(p: *const Node, r: Rect, second: bool) Rect {
        switch (p.dir) {
            .horizontal => {
                const w1: u32 = @intFromFloat(@as(f32, @floatFromInt(r.w)) * p.ratio);
                return if (!second) .{ .x = r.x, .y = r.y, .w = w1, .h = r.h } else .{ .x = r.x + @as(i32, @intCast(w1)), .y = r.y, .w = r.w - w1, .h = r.h };
            },
            .vertical => {
                const h1: u32 = @intFromFloat(@as(f32, @floatFromInt(r.h)) * p.ratio);
                return if (!second) .{ .x = r.x, .y = r.y, .w = r.w, .h = h1 } else .{ .x = r.x, .y = r.y + @as(i32, @intCast(h1)), .w = r.w, .h = r.h - h1 };
            },
        }
    }
};

test "bsp insert, remove, geometry" {
    var t = Tree{ .gpa = std.testing.allocator };
    const area = Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    const a = try t.insert(null, 1, area);
    const b = try t.insert(a, 2, area);
    const c = try t.insert(b, 3, area);
    var list: [Tree.max_leaves]Tree.Entry = undefined;
    var len: usize = 0;
    Tree.collect(t.root, area, &list, &len);
    try std.testing.expectEqual(@as(usize, 3), len);
    var covered: u64 = 0; // leaves tile the area exactly
    for (list[0..len]) |e| covered += @as(u64, e.rect.w) * e.rect.h;
    try std.testing.expectEqual(@as(u64, 1000 * 600), covered);

    try std.testing.expect(t.find(2) == b);
    const next = t.remove(c).?;
    try std.testing.expect(next.isLeaf());
    _ = t.remove(b);
    _ = t.remove(a);
    try std.testing.expect(t.root == null);
}
