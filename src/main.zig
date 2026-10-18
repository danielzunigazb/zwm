const std = @import("std");
const cfg = @import("config.zig");
const tree_mod = @import("tree.zig");
const c = @import("c.zig").c;
const Bar = @import("bar.zig").Bar;

const Tree = tree_mod.Tree;
const Node = tree_mod.Node;
const Rect = tree_mod.Rect;

const Saved = struct { tree: Tree, focus: ?*Node = null };

const WM = struct {
    conn: *c.xcb_connection_t,
    root: c.xcb_window_t,
    area: Rect,
    tree: Tree,
    bar: Bar,
    focus: ?*Node = null,
    // `tree`/`focus` are the live workspace; the others sit here (saved[cur] is stale).
    saved: [cfg.workspaces]Saved,
    cur: usize = 0,
    keycodes: [cfg.binds.len]c.xcb_keycode_t = undefined,
    wm_protocols: c.xcb_atom_t,
    wm_delete: c.xcb_atom_t,
    running: bool = true,

    fn atom(conn: *c.xcb_connection_t, name: []const u8) c.xcb_atom_t {
        const cookie = c.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr);
        const reply = c.xcb_intern_atom_reply(conn, cookie, null) orelse return 0;
        defer std.c.free(reply);
        return reply.*.atom;
    }

    fn grabKeys(wm: *WM) void {
        const syms = c.xcb_key_symbols_alloc(wm.conn);
        defer c.xcb_key_symbols_free(syms);
        // Also grab with NumLock (mod2) / CapsLock (lock) so they don't break binds.
        const extra = [_]u16{ 0, 2, 16, 18 };
        for (cfg.binds, 0..) |b, i| {
            const kc = c.xcb_key_symbols_get_keycode(syms, b.keysym) orelse continue;
            defer std.c.free(kc);
            wm.keycodes[i] = kc[0];
            const m = cfg.mod_mask | b.extra;
            for (extra) |e| {
                _ = c.xcb_grab_key(wm.conn, 1, wm.root, m | e, kc[0], c.XCB_GRAB_MODE_ASYNC, c.XCB_GRAB_MODE_ASYNC);
            }
        }
    }

    fn setBorder(wm: *WM, win: u32, color: u32) void {
        _ = c.xcb_change_window_attributes(wm.conn, win, c.XCB_CW_BORDER_PIXEL, &color);
    }

    fn setFocus(wm: *WM, n: ?*Node) void {
        if (wm.focus) |old| if (old.isLeaf()) wm.setBorder(old.win, cfg.border_normal);
        wm.focus = n;
        if (n) |leaf| {
            wm.setBorder(leaf.win, cfg.border_focus);
            _ = c.xcb_set_input_focus(wm.conn, c.XCB_INPUT_FOCUS_POINTER_ROOT, leaf.win, c.XCB_CURRENT_TIME);
        } else {
            _ = c.xcb_set_input_focus(wm.conn, c.XCB_INPUT_FOCUS_POINTER_ROOT, wm.root, c.XCB_CURRENT_TIME);
        }
    }

    fn layout(wm: *WM, n: ?*Node, r: Rect) void {
        const node = n orelse return;
        if (node.isLeaf()) {
            const g: i32 = cfg.gap;
            const b2: u32 = 2 * cfg.border;
            const vals = [_]u32{
                @bitCast(r.x + g),
                @bitCast(r.y + g),
                r.w -| (2 * cfg.gap + b2),
                r.h -| (2 * cfg.gap + b2),
                cfg.border,
            };
            const mask = c.XCB_CONFIG_WINDOW_X | c.XCB_CONFIG_WINDOW_Y | c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT | c.XCB_CONFIG_WINDOW_BORDER_WIDTH;
            _ = c.xcb_configure_window(wm.conn, node.win, mask, &vals);
            return;
        }
        wm.layout(node.a, Tree.split(node, r, false));
        wm.layout(node.b, Tree.split(node, r, true));
    }

    fn relayout(wm: *WM) void {
        wm.layout(wm.tree.root, wm.area);
        _ = c.xcb_flush(wm.conn);
    }

    fn manage(wm: *WM, win: u32) void {
        if (wm.tree.find(win) != null) return;
        const mask: u32 = c.XCB_EVENT_MASK_ENTER_WINDOW;
        _ = c.xcb_change_window_attributes(wm.conn, win, c.XCB_CW_EVENT_MASK, &mask);
        const leaf = wm.tree.insert(wm.focus, win, wm.area) catch return;
        _ = c.xcb_map_window(wm.conn, win);
        wm.relayout();
        wm.setFocus(leaf);
    }

    fn unmanage(wm: *WM, win: u32) void {
        if (wm.tree.find(win)) |leaf| {
            if (wm.focus == leaf) wm.focus = null;
            const next = wm.tree.remove(leaf);
            wm.relayout();
            if (wm.focus == null) wm.setFocus(next);
        } else if (wm.findHidden(win)) |h| {
            const s = &wm.saved[h.ws];
            if (s.focus == h.node) s.focus = null;
            const next = s.tree.remove(h.node);
            if (s.focus == null) s.focus = next;
        }
    }

    fn findHidden(wm: *WM, win: u32) ?struct { ws: usize, node: *Node } {
        for (&wm.saved, 0..) |*s, i| {
            if (i == wm.cur) continue;
            if (s.tree.find(win)) |n| return .{ .ws = i, .node = n };
        }
        return null;
    }

    fn onUnmap(wm: *WM, win: u32) void {
        const node = wm.tree.find(win) orelse (if (wm.findHidden(win)) |h| h.node else return);
        if (node.skip_unmap > 0) {
            node.skip_unmap -= 1;
            return;
        }
        wm.unmanage(win);
    }

    fn setMapped(wm: *WM, n: ?*Node, map: bool) void {
        const node = n orelse return;
        if (node.isLeaf()) {
            if (map) {
                _ = c.xcb_map_window(wm.conn, node.win);
            } else {
                node.skip_unmap += 1;
                _ = c.xcb_unmap_window(wm.conn, node.win);
            }
            return;
        }
        wm.setMapped(node.a, map);
        wm.setMapped(node.b, map);
    }

    fn switchTo(wm: *WM, n: usize) void {
        if (n == wm.cur) return;
        wm.setMapped(wm.tree.root, false);
        wm.saved[wm.cur] = .{ .tree = wm.tree, .focus = wm.focus };
        wm.cur = n;
        wm.tree = wm.saved[n].tree;
        const f = wm.saved[n].focus;
        wm.focus = null;
        wm.setMapped(wm.tree.root, true);
        wm.relayout();
        wm.setFocus(f orelse if (wm.tree.root) |r| Tree.firstLeaf(r) else null);
    }

    fn sendTo(wm: *WM, n: usize) void {
        if (n == wm.cur) return;
        const leaf = wm.focus orelse return;
        const win = leaf.win;
        wm.focus = null;
        const next = wm.tree.remove(leaf);
        const dst = &wm.saved[n];
        const nl = dst.tree.insert(dst.focus, win, wm.area) catch return;
        nl.skip_unmap = 1;
        _ = c.xcb_unmap_window(wm.conn, win);
        if (dst.focus == null) dst.focus = nl;
        wm.relayout();
        wm.setFocus(next);
    }

    fn closeFocused(wm: *WM) void {
        const leaf = wm.focus orelse return;
        var ev = std.mem.zeroes(c.xcb_client_message_event_t);
        ev.response_type = c.XCB_CLIENT_MESSAGE;
        ev.format = 32;
        ev.window = leaf.win;
        ev.type = wm.wm_protocols;
        ev.data.data32[0] = wm.wm_delete;
        ev.data.data32[1] = c.XCB_CURRENT_TIME;
        _ = c.xcb_send_event(wm.conn, 0, leaf.win, c.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&ev));
        _ = c.xcb_flush(wm.conn);
    }

    fn spawn(cmd: [*:0]const u8) void {
        const pid = c.fork();
        if (pid == 0) {
            _ = c.setsid();
            if (c.fork() == 0) {
                const argv = [_:null]?[*:0]const u8{cmd};
                _ = c.execvp(cmd, @ptrCast(&argv));
            }
            c._exit(0);
        } else if (pid > 0) {
            _ = c.waitpid(pid, null, 0);
        }
    }

    /// Closest leaf in direction `dir` from the focused one (must overlap on the other axis).
    fn neighbor(wm: *WM, dir: cfg.Dir4) ?*Node {
        const cur = wm.focus orelse return null;
        var list: [Tree.max_leaves]Tree.Entry = undefined;
        var len: usize = 0;
        Tree.collect(wm.tree.root, wm.area, &list, &len);

        var cr: Rect = undefined;
        for (list[0..len]) |e| if (e.node == cur) {
            cr = e.rect;
        };

        const horiz = dir == .left or dir == .right;
        var best: ?*Node = null;
        var best_gap: i64 = std.math.maxInt(i64);
        var best_off: i64 = std.math.maxInt(i64);
        for (list[0..len]) |e| {
            if (e.node == cur) continue;
            const r = e.rect;
            const gap: i64 = switch (dir) {
                .left => @as(i64, cr.x) - (r.x + @as(i64, r.w)),
                .right => @as(i64, r.x) - (cr.x + @as(i64, cr.w)),
                .up => @as(i64, cr.y) - (r.y + @as(i64, r.h)),
                .down => @as(i64, r.y) - (cr.y + @as(i64, cr.h)),
            };
            if (gap < 0) continue;
            // Overlap on the perpendicular axis.
            const a0: i64 = if (horiz) cr.y else cr.x;
            const a1: i64 = a0 + (if (horiz) cr.h else cr.w);
            const b0: i64 = if (horiz) r.y else r.x;
            const b1: i64 = b0 + (if (horiz) r.h else r.w);
            if (@min(a1, b1) <= @max(a0, b0)) continue;
            const off: i64 = @intCast(@abs((a0 + a1) - (b0 + b1)));
            if (gap < best_gap or (gap == best_gap and off < best_off)) {
                best = e.node;
                best_gap = gap;
                best_off = off;
            }
        }
        return best;
    }

    fn swapWith(wm: *WM, dir: cfg.Dir4) void {
        const cur = wm.focus orelse return;
        const other = wm.neighbor(dir) orelse return;
        std.mem.swap(u32, &cur.win, &other.win);
        wm.relayout();
        wm.setFocus(other); // focused window now lives in `other`
    }

    fn resizeDir(wm: *WM, dir: cfg.Dir4) void {
        const cur = wm.focus orelse return;
        const horiz = dir == .left or dir == .right;
        const anc = Tree.ancestor(cur, if (horiz) .horizontal else .vertical) orelse return;
        const sign: f32 = if (dir == .right or dir == .down) 1 else -1;
        anc.split.ratio = std.math.clamp(anc.split.ratio + sign * cfg.resize_step, 0.1, 0.9);
        wm.relayout();
    }

    fn onKey(wm: *WM, ev: *c.xcb_key_press_event_t) void {
        const state = ev.state & ~@as(u16, 2 | 16); // drop lock bits
        for (cfg.binds, 0..) |b, i| {
            const m = cfg.mod_mask | b.extra;
            if (ev.detail != wm.keycodes[i] or state != m) continue;
            switch (b.action) {
                .spawn_terminal => spawn(cfg.terminal),
                .close => wm.closeFocused(),
                .quit => wm.running = false,
                .focus => if (wm.neighbor(b.dir)) |n| wm.setFocus(n),
                .swap => wm.swapWith(b.dir),
                .resize => wm.resizeDir(b.dir),
                .workspace => wm.switchTo(b.n),
                .send_to => wm.sendTo(b.n),
            }
            return;
        }
    }

    fn onConfigureRequest(wm: *WM, ev: *c.xcb_configure_request_event_t) void {
        if (wm.tree.find(ev.window) != null) {
            wm.relayout();
            return;
        }
        // Unmanaged window: let it have what it asks for.
        var vals: [7]u32 = undefined;
        var n: usize = 0;
        const fields = .{
            .{ c.XCB_CONFIG_WINDOW_X, @as(u32, @bitCast(@as(i32, ev.x))) },
            .{ c.XCB_CONFIG_WINDOW_Y, @as(u32, @bitCast(@as(i32, ev.y))) },
            .{ c.XCB_CONFIG_WINDOW_WIDTH, @as(u32, ev.width) },
            .{ c.XCB_CONFIG_WINDOW_HEIGHT, @as(u32, ev.height) },
            .{ c.XCB_CONFIG_WINDOW_BORDER_WIDTH, @as(u32, ev.border_width) },
            .{ c.XCB_CONFIG_WINDOW_SIBLING, ev.sibling },
            .{ c.XCB_CONFIG_WINDOW_STACK_MODE, @as(u32, ev.stack_mode) },
        };
        inline for (fields) |f| {
            if (ev.value_mask & f[0] != 0) {
                vals[n] = f[1];
                n += 1;
            }
        }
        _ = c.xcb_configure_window(wm.conn, ev.window, ev.value_mask, &vals);
        _ = c.xcb_flush(wm.conn);
    }

    fn handle(wm: *WM, ev: *c.xcb_generic_event_t) void {
        switch (ev.response_type & 0x7f) {
            c.XCB_MAP_REQUEST => wm.manage(@as(*c.xcb_map_request_event_t, @ptrCast(@alignCast(ev))).window),
            c.XCB_UNMAP_NOTIFY => wm.onUnmap(@as(*c.xcb_unmap_notify_event_t, @ptrCast(@alignCast(ev))).window),
            c.XCB_DESTROY_NOTIFY => wm.unmanage(@as(*c.xcb_destroy_notify_event_t, @ptrCast(@alignCast(ev))).window),
            c.XCB_CONFIGURE_REQUEST => wm.onConfigureRequest(@ptrCast(@alignCast(ev))),
            c.XCB_KEY_PRESS => wm.onKey(@ptrCast(@alignCast(ev))),
            c.XCB_EXPOSE => {
                const e: *c.xcb_expose_event_t = @ptrCast(@alignCast(ev));
                if (e.window == wm.bar.win and e.count == 0) wm.redrawBar(true);
            },
            c.XCB_ENTER_NOTIFY => {
                const e: *c.xcb_enter_notify_event_t = @ptrCast(@alignCast(ev));
                if (wm.tree.find(e.event)) |leaf| if (leaf != wm.focus) wm.setFocus(leaf);
            },
            else => {},
        }
    }

    fn redrawBar(wm: *WM, force: bool) void {
        var occupied: u8 = 0;
        for (0..cfg.workspaces) |i| {
            const root = if (i == wm.cur) wm.tree.root else wm.saved[i].tree.root;
            if (root != null) occupied |= @as(u8, 1) << @intCast(i);
        }
        wm.bar.draw(wm.cur, occupied, force);
    }

    /// Sleep budget for poll(): the clock only changes once a minute.
    fn msToNextMinute() c_int {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
        const ms: i64 = @mod(@as(i64, ts.tv_sec), 60) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
        return @intCast(60_000 - ms + 20);
    }

    fn run(wm: *WM) void {
        var pfd = c.struct_pollfd{ .fd = c.xcb_get_file_descriptor(wm.conn), .events = c.POLLIN, .revents = 0 };
        wm.redrawBar(true);
        while (wm.running) {
            while (c.xcb_poll_for_event(wm.conn)) |ev| {
                defer std.c.free(ev);
                wm.handle(ev);
            }
            if (c.xcb_connection_has_error(wm.conn) != 0) break;
            wm.redrawBar(false);
            _ = c.xcb_flush(wm.conn);
            if (!wm.running) break;
            _ = c.poll(&pfd, 1, msToNextMinute());
        }
    }
};

pub fn main() !void {
    const conn = c.xcb_connect(null, null) orelse return error.NoDisplay;
    if (c.xcb_connection_has_error(conn) != 0) return error.NoDisplay;
    defer c.xcb_disconnect(conn);

    const screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn)).data.*;

    // Becoming the WM = selecting SubstructureRedirect on root. Fails if another WM runs.
    const mask: u32 = c.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY;
    const err = c.xcb_request_check(conn, c.xcb_change_window_attributes_checked(conn, screen.root, c.XCB_CW_EVENT_MASK, &mask));
    if (err != null) {
        std.c.free(err);
        return error.AnotherWmRunning;
    }

    var wm = WM{
        .conn = conn,
        .root = screen.root,
        // Top of the screen is taken by the bar (plus its gap).
        .area = .{ .x = 0, .y = cfg.gap + cfg.bar_h, .w = screen.width_in_pixels, .h = screen.height_in_pixels - (cfg.gap + cfg.bar_h) },
        .bar = try Bar.init(conn, &screen),
        .tree = .{ .gpa = std.heap.c_allocator },
        .saved = [_]Saved{.{ .tree = .{ .gpa = std.heap.c_allocator } }} ** cfg.workspaces,
        .wm_protocols = WM.atom(conn, "WM_PROTOCOLS"),
        .wm_delete = WM.atom(conn, "WM_DELETE_WINDOW"),
    };
    wm.grabKeys();
    _ = c.xcb_flush(conn);
    wm.run();
}
