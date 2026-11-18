const std = @import("std");
const cfg = @import("config.zig");
const tree_mod = @import("tree.zig");
const c = @import("c.zig").c;
const Bar = @import("bar.zig").Bar;
const panel_mod = @import("panel.zig");
const store_mod = @import("store.zig");
const dbus_mod = @import("dbus.zig");
const sys = @import("sys.zig");
const Launcher = @import("launcher.zig").Launcher;
const Lock = @import("lock.zig").Lock;
const Lyrics = @import("lyrics.zig").Lyrics;
const anim = @import("anim.zig");

const Tree = tree_mod.Tree;
const Node = tree_mod.Node;
const Rect = tree_mod.Rect;

const Saved = struct { tree: Tree, focus: ?*Node = null };

/// A window of the workspace we just left, sliding off screen before it is unmapped.
const Ghost = struct { win: u32, x: f32, y: i32, w: u32, h: u32, sx: i32, target: f32 };

const WM = struct {
    conn: *c.xcb_connection_t,
    root: c.xcb_window_t,
    area: Rect,
    tree: Tree,
    bar: Bar,
    widget: panel_mod.Widget,
    panel: panel_mod.Panel,
    toasts: panel_mod.Toasts,
    launcher: Launcher,
    lock: Lock,
    lyrics: Lyrics,
    syms: ?*c.xcb_key_symbols_t = null,
    store: store_mod.Store = .{},
    dbus: dbus_mod.Dbus = .{},
    last_minute: i64 = 0,
    last_pos_ms: i64 = 0,
    focus: ?*Node = null,
    // `tree`/`focus` are the live workspace; the others sit here (saved[cur] is stale).
    saved: [cfg.workspaces]Saved,
    cur: usize = 0,
    keycodes: [cfg.binds.len]c.xcb_keycode_t = [_]c.xcb_keycode_t{0} ** cfg.binds.len, // 0 = no such key on this keyboard
    wm_protocols: c.xcb_atom_t,
    wm_delete: c.xcb_atom_t,
    wm_type: c.xcb_atom_t, // _NET_WM_WINDOW_TYPE
    wm_desktop: c.xcb_atom_t, // _NET_WM_DESKTOP: which workspace a window belongs to
    float_types: [8]c.xcb_atom_t, // types that float instead of tiling
    net_supported: c.xcb_atom_t,
    net_check: c.xcb_atom_t, // _NET_SUPPORTING_WM_CHECK
    net_active: c.xcb_atom_t, // _NET_ACTIVE_WINDOW
    active: u32 = 0, // what _NET_ACTIVE_WINDOW on root says right now (0 = None)
    running: bool = true,
    ghosts: [Tree.max_leaves]Ghost = undefined,
    n_ghosts: usize = 0,
    animating: bool = false,
    vol: sys.Volume = .{},
    art: sys.Art = .{},
    brightness: sys.Brightness = .{},
    remote: sys.Remote = .{},
    apps_warm: bool = false,
    last_ns: i64 = 0,

    fn atom(conn: *c.xcb_connection_t, name: []const u8) c.xcb_atom_t {
        const cookie = c.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr);
        const reply = c.xcb_intern_atom_reply(conn, cookie, null) orelse return 0;
        defer std.c.free(reply);
        return reply.*.atom;
    }

    fn grabKeys(wm: *WM) void {
        // One keysym table for the life of the WM; it is refreshed on MappingNotify (onMapping).
        if (wm.syms == null) wm.syms = c.xcb_key_symbols_alloc(wm.conn);
        const syms = wm.syms orelse return;
        // Also grab with NumLock (mod2) / CapsLock (lock) so they don't break binds.
        const extra = [_]u16{ 0, 2, 16, 18 };
        for (cfg.binds, 0..) |b, i| {
            wm.keycodes[i] = 0; // a bind whose key left the keymap stops matching
            const kc = c.xcb_key_symbols_get_keycode(syms, b.keysym) orelse continue;
            defer std.c.free(kc);
            if (kc[0] == 0) continue; // NoSymbol
            wm.keycodes[i] = kc[0];
            const m = (if (b.mod) cfg.mod_mask else 0) | b.extra;
            for (extra) |e| {
                _ = c.xcb_grab_key(wm.conn, 1, wm.root, m | e, kc[0], c.XCB_GRAB_MODE_ASYNC, c.XCB_GRAB_MODE_ASYNC);
            }
        }
    }

    /// Keyboard layout changed (MappingNotify): refresh the keysyms and move every grab to the new keycodes.
    fn onMapping(wm: *WM, e: *c.xcb_mapping_notify_event_t) void {
        if (e.request != c.XCB_MAPPING_KEYBOARD) return;
        if (wm.syms) |syms| _ = c.xcb_refresh_keyboard_mapping(syms, e);
        _ = c.xcb_ungrab_key(wm.conn, c.XCB_GRAB_ANY, wm.root, c.XCB_MOD_MASK_ANY);
        wm.grabKeys();
        _ = c.xcb_flush(wm.conn);
    }

    /// Window's workspace, stored in its _NET_WM_DESKTOP so it survives a WM restart.
    fn stamp(wm: *WM, win: u32, ws: usize) void {
        const v = [_]u32{@intCast(ws)};
        _ = c.xcb_change_property(wm.conn, c.XCB_PROP_MODE_REPLACE, win, wm.wm_desktop, c.XCB_ATOM_CARDINAL, 32, 1, &v);
    }

    fn desktopOf(wm: *WM, win: u32) ?usize {
        const ck = c.xcb_get_property(wm.conn, 0, win, wm.wm_desktop, c.XCB_ATOM_CARDINAL, 0, 1);
        const r = c.xcb_get_property_reply(wm.conn, ck, null) orelse return null;
        defer std.c.free(r);
        if (c.xcb_get_property_value_length(r) < 4) return null;
        const v: *const u32 = @ptrCast(@alignCast(c.xcb_get_property_value(r)));
        return if (v.* < cfg.workspaces) v.* else null;
    }

    /// Basic EWMH: a check window that names the WM, the hints it honours (_NET_SUPPORTED), and
    /// _NET_ACTIVE_WINDOW, which `setActive` keeps in step with the focus. Bars and window
    /// switchers read these. Overwrites whatever a previous WM instance left on root.
    fn setupEwmh(wm: *WM) void {
        const P = c.XCB_PROP_MODE_REPLACE;
        // Never mapped; override-redirect so adopt() and MapRequest never treat it as a client.
        const check = c.xcb_generate_id(wm.conn);
        const ovr = [_]u32{1};
        _ = c.xcb_create_window(wm.conn, 0, check, wm.root, -1, -1, 1, 1, 0, c.XCB_WINDOW_CLASS_INPUT_ONLY, c.XCB_COPY_FROM_PARENT, c.XCB_CW_OVERRIDE_REDIRECT, &ovr);
        const cw = [_]u32{check};
        _ = c.xcb_change_property(wm.conn, P, check, wm.net_check, c.XCB_ATOM_WINDOW, 32, 1, &cw);
        const name = "zwm";
        _ = c.xcb_change_property(wm.conn, P, check, atom(wm.conn, "_NET_WM_NAME"), atom(wm.conn, "UTF8_STRING"), 8, name.len, name.ptr);
        _ = c.xcb_change_property(wm.conn, P, wm.root, wm.net_check, c.XCB_ATOM_WINDOW, 32, 1, &cw);

        // Only what the WM really does: the check window, the active window, and the window types
        // that make a window float (shouldFloat).
        var list: [4 + wm.float_types.len]u32 = undefined;
        var n: usize = 0;
        for ([_]u32{ wm.net_supported, wm.net_check, wm.net_active, wm.wm_type } ++ wm.float_types) |a| {
            if (a == 0) continue; // atom could not be interned
            list[n] = a;
            n += 1;
        }
        _ = c.xcb_change_property(wm.conn, P, wm.root, wm.net_supported, c.XCB_ATOM_ATOM, 32, @intCast(n), &list);

        const none = [_]u32{0};
        _ = c.xcb_change_property(wm.conn, P, wm.root, wm.net_active, c.XCB_ATOM_WINDOW, 32, 1, &none);
        wm.active = 0;
    }

    /// On exit: claim nothing for whatever runs next (the check window goes with the connection).
    fn dropEwmh(wm: *WM) void {
        _ = c.xcb_delete_property(wm.conn, wm.root, wm.net_active);
        _ = c.xcb_delete_property(wm.conn, wm.root, wm.net_supported);
        _ = c.xcb_delete_property(wm.conn, wm.root, wm.net_check);
        // Wait for a reply so the server has run the deletes before we disconnect: closing with
        // unread events queued (e.g. right after a workspace switch) resets the connection, and
        // the server then drops whatever requests it had not processed yet.
        if (c.xcb_get_input_focus_reply(wm.conn, c.xcb_get_input_focus(wm.conn), null)) |r| std.c.free(r);
    }

    /// _NET_ACTIVE_WINDOW follows every input-focus change the WM makes (0 = None).
    fn setActive(wm: *WM, win: u32) void {
        if (win == wm.active) return;
        // Log every time _NET_ACTIVE_WINDOW enters or leaves None: ActivityWatch files that time
        // under "unknown", and this says when and on which workspace it happened.
        if (win == 0 or wm.active == 0) {
            var ts: c.struct_timespec = undefined;
            _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
            const t: c.time_t = ts.tv_sec;
            var tm: c.struct_tm = undefined;
            _ = c.localtime_r(&t, &tm);
            std.debug.print("{d:0>2}:{d:0>2}:{d:0>2} active 0x{x} -> 0x{x} (workspace {d})\n", .{
                @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)), @as(u32, @intCast(tm.tm_sec)),
                wm.active, win, wm.cur + 1,
            });
        }
        wm.active = win;
        const v = [_]u32{win};
        _ = c.xcb_change_property(wm.conn, c.XCB_PROP_MODE_REPLACE, wm.root, wm.net_active, c.XCB_ATOM_WINDOW, 32, 1, &v);
    }

    /// The window _NET_ACTIVE_WINDOW names was unmapped or destroyed (a floating dialog closing):
    /// the focus goes back to the tiled window that had it, or to nothing, so the property never
    /// names a window that is gone.
    fn dropActive(wm: *WM, win: u32) void {
        if (win == 0 or win != wm.active) return;
        if (wm.focus) |f| if (f.isLeaf()) return wm.setFocus(f);
        wm.setFocus(null);
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
            wm.setActive(leaf.win);
        } else {
            _ = c.xcb_set_input_focus(wm.conn, c.XCB_INPUT_FOCUS_POINTER_ROOT, wm.root, c.XCB_CURRENT_TIME);
            wm.setActive(0);
        }
    }

    /// Compute every leaf's target rect. Nothing is sent to the server here: `stepWindows`
    /// walks the current rects toward these.
    fn layout(wm: *WM, n: ?*Node, r: Rect) void {
        const node = n orelse return;
        if (node.isLeaf()) {
            const g: i32 = cfg.gap;
            const b2: u32 = 2 * cfg.border;
            node.tx = r.x + g;
            node.ty = r.y + g;
            node.tw = @max(1, r.w -| (2 * cfg.gap + b2));
            node.th = @max(1, r.h -| (2 * cfg.gap + b2));
            return;
        }
        wm.layout(node.a, Tree.split(node, r, false));
        wm.layout(node.b, Tree.split(node, r, true));
    }

    fn configure(wm: *WM, node: *Node, with_border: bool) void {
        node.sx = anim.round(node.cx);
        node.sy = anim.round(node.cy);
        node.sw = @intCast(@max(1, anim.round(node.cw)));
        node.sh = @intCast(@max(1, anim.round(node.ch)));
        const vals = [_]u32{ @bitCast(node.sx), @bitCast(node.sy), node.sw, node.sh, cfg.border };
        const geom: u32 = c.XCB_CONFIG_WINDOW_X | c.XCB_CONFIG_WINDOW_Y | c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT;
        const border: u32 = c.XCB_CONFIG_WINDOW_BORDER_WIDTH;
        const mask: u16 = @intCast(if (with_border) geom | border else geom);
        _ = c.xcb_configure_window(wm.conn, node.win, mask, &vals);
    }

    /// Give every not-yet-placed leaf a starting rect (its target shifted by `off_x`, or where a
    /// sliding-out ghost of the same window currently is) and configure it there.
    fn place(wm: *WM, n: ?*Node, off_x: f32) void {
        const node = n orelse return;
        if (!node.isLeaf()) {
            wm.place(node.a, off_x);
            wm.place(node.b, off_x);
            return;
        }
        if (node.placed) return;
        node.cx = @floatFromInt(node.tx);
        node.cy = @floatFromInt(node.ty);
        node.cw = @floatFromInt(node.tw);
        node.ch = @floatFromInt(node.th);
        node.cx += off_x;
        for (wm.ghosts[0..wm.n_ghosts], 0..) |gh, i| {
            if (gh.win != node.win) continue;
            // Switched back before the slide finished: resume from where it is.
            node.cx = gh.x;
            node.cy = @floatFromInt(gh.y);
            node.cw = @floatFromInt(gh.w);
            node.ch = @floatFromInt(gh.h);
            node.skip_unmap -|= 1; // the pending unmap will never happen
            wm.ghosts[i] = wm.ghosts[wm.n_ghosts - 1];
            wm.n_ghosts -= 1;
            break;
        }
        node.placed = true;
        wm.configure(node, true);
    }

    fn relayout(wm: *WM) void {
        wm.layout(wm.tree.root, wm.area);
        wm.place(wm.tree.root, 0);
        _ = c.xcb_flush(wm.conn);
    }

    /// One animation step for the current workspace's windows. True while any is still moving.
    fn stepWindows(wm: *WM, n: ?*Node, dt: f32) bool {
        const node = n orelse return false;
        if (!node.isLeaf()) {
            const a = wm.stepWindows(node.a, dt);
            const b = wm.stepWindows(node.b, dt);
            return a or b;
        }
        if (!node.placed) return false;
        const k = cfg.k_window;
        const m1 = anim.settle(&node.cx, @floatFromInt(node.tx), dt, k);
        const m2 = anim.settle(&node.cy, @floatFromInt(node.ty), dt, k);
        // Size is applied at once, only position glides: every size change is a SIGWINCH, and a
        // shell redraws its prompt on each one (animating size filled terminals with prompts).
        node.cw = @floatFromInt(node.tw);
        node.ch = @floatFromInt(node.th);
        const nx = anim.round(node.cx);
        const ny = anim.round(node.cy);
        const nw: u32 = @intCast(@max(1, anim.round(node.cw)));
        const nh: u32 = @intCast(@max(1, anim.round(node.ch)));
        if (nx != node.sx or ny != node.sy or nw != node.sw or nh != node.sh) wm.configure(node, false);
        return m1 or m2;
    }

    fn stepGhosts(wm: *WM, dt: f32) bool {
        var i: usize = 0;
        while (i < wm.n_ghosts) {
            const g = &wm.ghosts[i];
            const moving = anim.settle(&g.x, g.target, dt, cfg.k_workspace);
            const nx = anim.round(g.x);
            if (nx != g.sx) {
                g.sx = nx;
                const v = [_]u32{@bitCast(nx)};
                _ = c.xcb_configure_window(wm.conn, g.win, c.XCB_CONFIG_WINDOW_X, &v);
            }
            if (moving) {
                i += 1;
            } else {
                _ = c.xcb_unmap_window(wm.conn, g.win);
                wm.ghosts[i] = wm.ghosts[wm.n_ghosts - 1];
                wm.n_ghosts -= 1;
            }
        }
        return wm.n_ghosts > 0;
    }

    /// Every window of the workspace we are leaving slides off in direction `-dir` and is unmapped
    /// once it is out of sight.
    fn ghostOut(wm: *WM, n: ?*Node, dir: f32) void {
        const node = n orelse return;
        if (!node.isLeaf()) {
            wm.ghostOut(node.a, dir);
            wm.ghostOut(node.b, dir);
            return;
        }
        node.placed = false;
        if (wm.n_ghosts >= wm.ghosts.len) {
            node.skip_unmap += 1;
            _ = c.xcb_unmap_window(wm.conn, node.win);
            return;
        }
        node.skip_unmap += 1;
        const w: f32 = @floatFromInt(wm.area.w);
        wm.ghosts[wm.n_ghosts] = .{
            .win = node.win,
            .x = node.cx,
            .y = anim.round(node.cy),
            .w = @intCast(@max(1, anim.round(node.cw))),
            .h = @intCast(@max(1, anim.round(node.ch))),
            .sx = anim.round(node.cx),
            .target = @as(f32, @floatFromInt(node.tx)) - dir * w,
        };
        wm.n_ghosts += 1;
    }

    fn animate(wm: *WM, dt: f32) bool {
        var moving = wm.stepWindows(wm.tree.root, dt);
        moving = wm.stepGhosts(dt) or moving;
        moving = wm.bar.step(wm.cur, dt) or moving;
        moving = wm.panel.step(dt) or moving;
        moving = wm.toasts.step(dt) or moving;
        moving = wm.launcher.step(dt) or moving;
        moving = wm.lock.step(dt) or moving;
        moving = wm.lyrics.step(dt) or moving;
        return moving;
    }

    /// Dialogs, splash screens, menus, docks...: shown where they ask to be, never tiled.
    fn shouldFloat(wm: *WM, win: u32) bool {
        const tf = c.xcb_get_property(wm.conn, 0, win, c.XCB_ATOM_WM_TRANSIENT_FOR, c.XCB_ATOM_WINDOW, 0, 1);
        if (c.xcb_get_property_reply(wm.conn, tf, null)) |r| {
            defer std.c.free(r);
            if (r.*.value_len > 0) return true;
        }
        const ck = c.xcb_get_property(wm.conn, 0, win, wm.wm_type, c.XCB_ATOM_ATOM, 0, 8);
        const r = c.xcb_get_property_reply(wm.conn, ck, null) orelse return false;
        defer std.c.free(r);
        const n: usize = @intCast(@max(0, @divTrunc(c.xcb_get_property_value_length(r), 4)));
        const atoms: [*]const u32 = @ptrCast(@alignCast(c.xcb_get_property_value(r)));
        for (atoms[0..n]) |a| for (wm.float_types) |ft| if (ft != 0 and a == ft) return true;
        return false;
    }

    fn mapFloating(wm: *WM, win: u32) void {
        const mask: u32 = c.XCB_EVENT_MASK_ENTER_WINDOW;
        _ = c.xcb_change_window_attributes(wm.conn, win, c.XCB_CW_EVENT_MASK, &mask);
        if (c.xcb_get_geometry_reply(wm.conn, c.xcb_get_geometry(wm.conn, win), null)) |g| {
            defer std.c.free(g);
            // Windows that did not pick a position get centered in the usable area.
            if (g.*.x <= 0 and g.*.y <= 0) {
                const x: i32 = wm.area.x + @divTrunc(@as(i32, @intCast(wm.area.w)) - g.*.width, 2);
                const y: i32 = wm.area.y + @divTrunc(@as(i32, @intCast(wm.area.h)) - g.*.height, 2);
                const v = [_]u32{ @bitCast(@max(x, wm.area.x)), @bitCast(@max(y, wm.area.y)) };
                _ = c.xcb_configure_window(wm.conn, win, c.XCB_CONFIG_WINDOW_X | c.XCB_CONFIG_WINDOW_Y, &v);
            }
        }
        _ = c.xcb_map_window(wm.conn, win);
        const top = [_]u32{c.XCB_STACK_MODE_ABOVE};
        _ = c.xcb_configure_window(wm.conn, win, c.XCB_CONFIG_WINDOW_STACK_MODE, &top);
        _ = c.xcb_set_input_focus(wm.conn, c.XCB_INPUT_FOCUS_POINTER_ROOT, win, c.XCB_CURRENT_TIME);
        wm.setActive(win);
        _ = c.xcb_flush(wm.conn);
    }

    fn manage(wm: *WM, win: u32) void {
        if (wm.tree.find(win) != null) return;
        // A window of another workspace asking to map: leave it hidden, never duplicate it here.
        if (wm.findHidden(win) != null) return;
        if (wm.shouldFloat(win)) {
            wm.mapFloating(win);
            return;
        }
        const mask: u32 = c.XCB_EVENT_MASK_ENTER_WINDOW;
        _ = c.xcb_change_window_attributes(wm.conn, win, c.XCB_CW_EVENT_MASK, &mask);
        const leaf = wm.tree.insert(wm.focus, win, wm.area) catch {
            // Out of memory for the tree: show it floating rather than leave it unmapped forever.
            wm.mapFloating(win);
            return;
        };
        wm.stamp(win, wm.cur);
        // Start the new window on top of the one it splits, then let both settle into their halves.
        if (leaf.parent) |p| if (p.a) |sib| if (sib.placed and sib.isLeaf()) {
            leaf.cx = sib.cx;
            leaf.cy = sib.cy;
            leaf.cw = sib.cw;
            leaf.ch = sib.ch;
            leaf.placed = true;
            wm.configure(leaf, true);
        };
        _ = c.xcb_map_window(wm.conn, win);
        wm.relayout();
        wm.setFocus(leaf);
    }

    fn dropGhost(wm: *WM, win: u32) void {
        for (wm.ghosts[0..wm.n_ghosts], 0..) |g, i| if (g.win == win) {
            wm.ghosts[i] = wm.ghosts[wm.n_ghosts - 1];
            wm.n_ghosts -= 1;
            return;
        };
    }

    fn unmanage(wm: *WM, win: u32) void {
        wm.dropGhost(win);
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
        const dir: f32 = if (n > wm.cur) 1 else -1;
        wm.ghostOut(wm.tree.root, dir);
        wm.saved[wm.cur] = .{ .tree = wm.tree, .focus = wm.focus };
        wm.cur = n;
        wm.tree = wm.saved[n].tree;
        const f = wm.saved[n].focus;
        // The window leaving the screen loses focus; its border must say so for when it comes back.
        if (wm.focus) |old| if (old.isLeaf()) wm.setBorder(old.win, cfg.border_normal);
        wm.focus = null;
        // Incoming windows are configured one screen away, then mapped, then slide in.
        wm.layout(wm.tree.root, wm.area);
        wm.place(wm.tree.root, dir * @as(f32, @floatFromInt(wm.area.w)));
        wm.setMapped(wm.tree.root, true);
        _ = c.xcb_flush(wm.conn);
        wm.setFocus(f orelse if (wm.tree.root) |r| Tree.firstLeaf(r) else null);
    }

    fn sendTo(wm: *WM, n: usize) void {
        if (n == wm.cur) return;
        const leaf = wm.focus orelse return;
        const win = leaf.win;
        wm.setBorder(win, cfg.border_normal);
        wm.focus = null;
        const next = wm.tree.remove(leaf);
        const dst = &wm.saved[n];
        const nl = dst.tree.insert(dst.focus, win, wm.area) catch return;
        nl.skip_unmap = 1;
        wm.stamp(win, n);
        _ = c.xcb_unmap_window(wm.conn, win);
        if (dst.focus == null) dst.focus = nl;
        wm.relayout();
        wm.setFocus(next);
    }

    fn supportsDelete(wm: *WM, win: u32) bool {
        const ck = c.xcb_get_property(wm.conn, 0, win, wm.wm_protocols, c.XCB_ATOM_ATOM, 0, 32);
        const r = c.xcb_get_property_reply(wm.conn, ck, null) orelse return false;
        defer std.c.free(r);
        const n: usize = @intCast(@max(0, @divTrunc(c.xcb_get_property_value_length(r), 4)));
        const atoms: [*]const u32 = @ptrCast(@alignCast(c.xcb_get_property_value(r)));
        for (atoms[0..n]) |a| if (a == wm.wm_delete) return true;
        return false;
    }

    /// Ask nicely (WM_DELETE_WINDOW); clients that do not speak it are killed instead.
    fn closeFocused(wm: *WM) void {
        const leaf = wm.focus orelse return;
        if (!wm.supportsDelete(leaf.win)) {
            _ = c.xcb_kill_client(wm.conn, leaf.win);
            _ = c.xcb_flush(wm.conn);
            return;
        }
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

    /// Closest leaf in direction `dir` from the focused one (must overlap on the other axis).
    fn neighbor(wm: *WM, dir: cfg.Dir4) ?*Node {
        const cur = wm.focus orelse return null;
        var list: [Tree.max_leaves]Tree.Entry = undefined;
        var len: usize = 0;
        Tree.collect(wm.tree.root, wm.area, &list, &len);

        // The focused leaf is missing from `list` when the tree has more leaves than max_leaves.
        var cr: Rect = undefined;
        var found = false;
        for (list[0..len]) |e| if (e.node == cur) {
            cr = e.rect;
            found = true;
        };
        if (!found) return null;

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
        // The windows trade places: carry their current rects along so they glide across.
        std.mem.swap(f32, &cur.cx, &other.cx);
        std.mem.swap(f32, &cur.cy, &other.cy);
        std.mem.swap(f32, &cur.cw, &other.cw);
        std.mem.swap(f32, &cur.ch, &other.ch);
        std.mem.swap(i32, &cur.sx, &other.sx);
        std.mem.swap(i32, &cur.sy, &other.sy);
        std.mem.swap(u32, &cur.sw, &other.sw);
        std.mem.swap(u32, &cur.sh, &other.sh);
        wm.relayout();
        wm.setFocus(other); // focused window now lives in `other`
    }

    fn resizeDir(wm: *WM, dir: cfg.Dir4) void {
        const cur = wm.focus orelse return;
        const horiz = dir == .left or dir == .right;
        // Growing toward right/down means the focused leaf is in the first child (its far edge is
        // the divider); toward left/up it is in the second child.
        const forward = dir == .right or dir == .down;
        const split = Tree.ancestorOn(cur, if (horiz) .horizontal else .vertical, forward) orelse return;
        const sign: f32 = if (forward) 1 else -1;
        split.ratio = std.math.clamp(split.ratio + sign * cfg.resize_step, 0.1, 0.9);
        wm.relayout();
    }

    /// Take over windows that are already on screen (after a WM restart) instead of orphaning them.
    /// Take over the windows a previous WM instance left behind. Each one goes back to its workspace
    /// (_NET_WM_DESKTOP). Hidden windows of other workspaces stay unmapped in that workspace's tree.
    fn adopt(wm: *WM) void {
        const r = c.xcb_query_tree_reply(wm.conn, c.xcb_query_tree(wm.conn, wm.root), null) orelse return;
        defer std.c.free(r);
        const n: usize = @intCast(@max(0, c.xcb_query_tree_children_length(r)));
        const kids = c.xcb_query_tree_children(r)[0..n];
        for (kids) |w| {
            const a = c.xcb_get_window_attributes_reply(wm.conn, c.xcb_get_window_attributes(wm.conn, w), null) orelse continue;
            defer std.c.free(a);
            if (a.*.override_redirect != 0) continue;
            const viewable = a.*.map_state == c.XCB_MAP_STATE_VIEWABLE;
            const ws = wm.desktopOf(w);
            // Hidden and never stamped: not one of ours (a helper or a closed dialog). Leave it alone.
            if (!viewable and ws == null) continue;
            const target = ws orelse 0;
            if (target == wm.cur) wm.manage(w) else wm.adoptHidden(w, target, viewable);
        }
    }

    /// A window of a workspace we are not on: keep it unmapped in that workspace's tree. Switching
    /// there maps it, as for any window that was hidden by a switch.
    fn adoptHidden(wm: *WM, win: u32, ws: usize, viewable: bool) void {
        const dst = &wm.saved[ws];
        const leaf = dst.tree.insert(dst.focus, win, wm.area) catch return;
        const mask: u32 = c.XCB_EVENT_MASK_ENTER_WINDOW;
        _ = c.xcb_change_window_attributes(wm.conn, win, c.XCB_CW_EVENT_MASK, &mask);
        if (viewable) {
            leaf.skip_unmap = 1; // this unmap is ours: the UnmapNotify must not drop the window
            _ = c.xcb_unmap_window(wm.conn, win);
        }
        if (dst.focus == null) dst.focus = leaf;
    }

    fn onKey(wm: *WM, ev: *c.xcb_key_press_event_t) void {
        if (wm.lock.visible()) { // locked: no binds, nothing but the password reaches the WM
            if (wm.syms) |syms| if (wm.lock.onKey(ev, syms)) wm.unlocked();
            return;
        }
        // Keyboard is grabbed by the launcher: typing goes to it, but Super combinations are binds
        // (Super+L must lock even with the launcher open).
        if (wm.launcher.visible() and ev.state & cfg.mod_mask == 0) {
            wm.launcherResult(wm.launcher.onKey(ev));
            return;
        }
        const state = ev.state & ~@as(u16, 2 | 16); // drop lock bits
        for (cfg.binds, 0..) |b, i| {
            const m = (if (b.mod) cfg.mod_mask else 0) | b.extra;
            if (wm.keycodes[i] == 0 or ev.detail != wm.keycodes[i] or state != m) continue;
            switch (b.action) {
                .spawn_terminal => sys.spawn(cfg.terminal),
                .close => wm.closeFocused(),
                .quit => wm.running = false,
                .focus => if (wm.neighbor(b.dir)) |n| wm.setFocus(n),
                .swap => wm.swapWith(b.dir),
                .resize => wm.resizeDir(b.dir),
                .workspace => wm.switchTo(b.n),
                .send_to => wm.sendTo(b.n),
                .toggle_panel => wm.panel.toggle(&wm.store, &wm.art),
                .spawn => sys.spawn(b.cmd),
                .launcher => if (wm.syms) |syms| {
                    if (!wm.launcher.open(syms)) wm.notify("No se pudo abrir el lanzador", "Otra aplicación tiene el teclado.");
                },
                .lock => wm.lockScreen(),
                .music_toggle => wm.musicControl(.toggle),
                .music_next => wm.musicControl(.next),
                .music_prev => wm.musicControl(.prev),
                .volume => wm.vol.request(b.cmd),
                .brightness => sys.spawn(b.cmd),
            }
            return;
        }
    }

    fn onConfigureRequest(wm: *WM, ev: *c.xcb_configure_request_event_t) void {
        if (wm.tree.find(ev.window) != null) {
            wm.relayout();
            return;
        }
        // Unmanaged window: let it have what it asks for, except where it stacks: while the lock is up,
        // nothing may be raised above it.
        var mask = ev.value_mask;
        if (wm.lock.visible()) mask &= ~@as(u16, c.XCB_CONFIG_WINDOW_SIBLING | c.XCB_CONFIG_WINDOW_STACK_MODE);
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
            if (mask & f[0] != 0) {
                vals[n] = f[1];
                n += 1;
            }
        }
        _ = c.xcb_configure_window(wm.conn, ev.window, mask, &vals);
        _ = c.xcb_flush(wm.conn);
    }

    fn handle(wm: *WM, ev: *c.xcb_generic_event_t) void {
        switch (ev.response_type & 0x7f) {
            c.XCB_MAP_REQUEST => {
                wm.manage(@as(*c.xcb_map_request_event_t, @ptrCast(@alignCast(ev))).window);
                wm.panel.raise();
                wm.toasts.raise();
                wm.launcher.raise();
                wm.lock.raise(); // a new window must never end up above the lock
            },
            c.XCB_UNMAP_NOTIFY => {
                const win = @as(*c.xcb_unmap_notify_event_t, @ptrCast(@alignCast(ev))).window;
                wm.onUnmap(win);
                wm.dropActive(win);
            },
            c.XCB_DESTROY_NOTIFY => {
                const win = @as(*c.xcb_destroy_notify_event_t, @ptrCast(@alignCast(ev))).window;
                wm.unmanage(win);
                // A floating window may have held the input focus.
                if (wm.focus) |f| if (f.isLeaf()) wm.setFocus(f);
                wm.dropActive(win);
            },
            c.XCB_CONFIGURE_REQUEST => wm.onConfigureRequest(@ptrCast(@alignCast(ev))),
            // Override-redirect windows (menus, popups) map without a MapRequest: put the lock back on
            // top when one shows up. The lock's own MapNotify is skipped, so this cannot loop.
            c.XCB_MAP_NOTIFY => {
                const e: *c.xcb_map_notify_event_t = @ptrCast(@alignCast(ev));
                if (wm.lock.visible() and e.window != wm.lock.winId()) wm.lock.raise();
            },
            c.XCB_MAPPING_NOTIFY => wm.onMapping(@ptrCast(@alignCast(ev))),
            c.XCB_KEY_PRESS => wm.onKey(@ptrCast(@alignCast(ev))),
            c.XCB_EXPOSE => {
                const e: *c.xcb_expose_event_t = @ptrCast(@alignCast(ev));
                if (e.count != 0) return;
                if (e.window == wm.bar.surf.win) wm.bar.surf.flush();
                wm.widget.expose(e.window);
                wm.lyrics.expose(e.window);
                wm.panel.expose(e.window);
                wm.toasts.expose(e.window);
                wm.launcher.expose(e.window);
                wm.lock.expose(e.window);
            },
            c.XCB_BUTTON_PRESS => wm.onButtonPress(@ptrCast(@alignCast(ev))),
            c.XCB_ENTER_NOTIFY => {
                const e: *c.xcb_enter_notify_event_t = @ptrCast(@alignCast(ev));
                // Windows gliding under a still pointer must not steal focus, nor must grab crossings.
                if (wm.animating or e.mode != c.XCB_NOTIFY_MODE_NORMAL or e.detail == c.XCB_NOTIFY_DETAIL_INFERIOR) return;
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
        wm.bar.draw(wm.cur, occupied, &wm.store.status, force);
    }

    fn launcherResult(wm: *WM, r: @import("launcher.zig").Result) void {
        switch (r) {
            .none => {},
            .close => wm.launcher.close(),
            .launch => {
                sys.spawn(wm.launcher.cmdZ());
                wm.launcher.close();
            },
            .calc => {
                _ = wm.store.add("calc", "zwm", wm.launcher.calcText(), "", 0, store_mod.toast_default_ms, panel_mod.nowMs());
                wm.launcher.close();
            },
        }
    }

    /// Super+L. The launcher gives way: it would hold the keyboard grab otherwise.
    fn lockScreen(wm: *WM) void {
        wm.launcher.close();
        if (!wm.lock.open()) wm.notify("No se pudo bloquear", "Otra aplicación tiene el teclado o el puntero.");
    }

    /// Local notification (a toast from the WM itself, not from a client).
    fn notify(wm: *WM, summary: []const u8, body: []const u8) void {
        _ = wm.store.add("zwm", "zwm", summary, body, 0, store_mod.toast_default_ms, panel_mod.nowMs());
    }

    /// PAM accepted the password: put the keyboard back where it was.
    fn unlocked(wm: *WM) void {
        wm.setFocus(wm.focus);
    }

    fn onButtonPress(wm: *WM, e: *c.xcb_button_press_event_t) void {
        if (wm.lock.visible()) return; // clicks land on the lock window; nothing underneath may act
        
        if (wm.launcher.visible()) {
            wm.launcherResult(wm.launcher.click(e.event, e.event_y));
        } else if (wm.toasts.idAt(e.event)) |id| {
            wm.store.dropToast(id);
        } else if (wm.panel.hit(e.event, e.event_x, e.event_y)) |click| switch (click) {
            .prev => wm.musicControl(.prev),
            .play => wm.musicControl(.toggle),
            .next => wm.musicControl(.next),
            .lyrics => {
                wm.store.lyrics_on = !wm.store.lyrics_on;
                wm.store.version +%= 1; // the panel repaints the switch; refreshData starts or drops the lyrics
            },
            .dismiss => |id| wm.store.dismiss(id),
        };
    }

    /// Transport buttons and media keys: MPRIS for a player on this PC, zwm-music (Spotify Connect)
    /// when what the panel shows is playing on another device.
    fn musicControl(wm: *WM, what: enum { toggle, next, prev }) void {
        if (!wm.store.music.remote) {
            wm.dbus.control(switch (what) {
                .toggle => "PlayPause",
                .next => "Next",
                .prev => "Previous",
            });
            return;
        }
        sys.spawn(switch (what) {
            .toggle => if (wm.store.music.playing) "zwm-music pause" else "zwm-music resume",
            .next => "zwm-music next",
            .prev => "zwm-music prev",
        });
        if (what == .toggle) wm.remote.toggled(&wm.store, panel_mod.nowMs());
    }

    fn minuteNow() i64 {
        return @divFloor(@as(i64, c.time(null)), 60);
    }

    /// Pull fresh data from D-Bus / the system when something flagged it (or a minute passed).
    fn refreshData(wm: *WM, now: i64) void {
        const minute = minuteNow();
        if (minute != wm.last_minute) {
            wm.last_minute = minute;
            wm.vol.request(null);
            wm.store.net_dirty = true; // e.g. ethernet plugged in while connected: no StateChanged
            wm.remote.ensure(); // also restarts the Spotify watcher if it died or Spotify was authorised since
        }
        if (wm.store.music_dirty) wm.dbus.refreshMusic();
        // The cover is only fetched while the panel is open, and dropped when nothing plays.
        wm.art.want(&wm.store, if (wm.panel.visible() and wm.store.music.have) wm.store.music.artUrlSlice() else "");
        if (wm.store.net_dirty) wm.dbus.refreshNet();
        wm.lyrics.sync(&wm.store, now);
        if ((wm.panel.visible() or wm.lyrics.active()) and wm.store.music.playing and now - wm.last_pos_ms >= 1000) {
            wm.last_pos_ms = now;
            if (wm.store.music.remote) wm.remote.tick(&wm.store, now) else wm.dbus.refreshPosition();
        }
    }

    fn redrawAll(wm: *WM, force: bool) void {
        if (wm.lock.visible()) { // only the lock is on screen; the bar and panel stay untouched under it
            wm.lock.render(anim.nowNs());
            return;
        }
        const now = panel_mod.nowMs();
        wm.redrawBar(force);
        wm.widget.draw(&wm.store, force);
        wm.lyrics.draw();
        wm.toasts.sync(&wm.store, now, wm.panel.visible());
        wm.panel.draw(&wm.store, &wm.art, force);
    }

    /// poll() budget while idle: the clock only changes once a minute, unless a toast, the
    /// progress bar or a D-Bus timeout needs us sooner.
    fn sleepMs(wm: *WM, now: i64) c_int {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
        var ms: i64 = 60_000 - (@mod(@as(i64, ts.tv_sec), 60) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000)) + 20;
        if (panel_mod.Toasts.nextExpiry(&wm.store, now)) |e| ms = @min(ms, e + 5);
        if (wm.panel.visible() and wm.store.music.playing) ms = @min(ms, 1000);
        if (wm.lyrics.wakeInMs(now)) |t| ms = @min(ms, t);
        if (wm.dbus.timeoutMs()) |t| ms = @min(ms, t);
        return @intCast(@max(ms, 0));
    }

    /// ~/.config/zwm/autostart, once per session (the session script sets ZWM_AUTOSTART only for the
    /// first WM launch), and only now that the WM owns the screen so its windows get tiled.
    fn runAutostart(wm: *WM) void {
        _ = wm;
        const v = c.getenv("ZWM_AUTOSTART") orelse return;
        const on = v[0] == '1';
        _ = c.unsetenv("ZWM_AUTOSTART"); // not for the apps we start
        if (on) sys.spawn("f=\"${XDG_CONFIG_HOME:-$HOME/.config}/zwm/autostart\"; [ -x \"$f\" ] && exec \"$f\"");
    }

    fn run(wm: *WM) void {
        var pfd: [8]c.struct_pollfd = undefined;
        wm.last_minute = minuteNow();
        wm.redrawAll(true);
        _ = c.xcb_flush(wm.conn); // first paint before anything slow (volume probe, app scan)
        wm.vol.request(null);
        wm.brightness.request();
        wm.remote.ensure();
        wm.runAutostart();
        while (wm.running) {
            while (c.xcb_poll_for_event(wm.conn)) |ev| {
                defer std.c.free(ev);
                wm.handle(ev);
            }
            if (c.xcb_connection_has_error(wm.conn) != 0) break;
            wm.dbus.process();
            wm.vol.service(&wm.store.status);
            wm.art.service(&wm.store);
            const now = panel_mod.nowMs();
            wm.remote.service(&wm.store, now);
            wm.lyrics.service(now);
            wm.refreshData(now);
            wm.brightness.service(&wm.store.status);

            // Animations: dt is measured, so uneven wakeups still look even. After idling, the
            // first frame advances by exactly one frame interval instead of the whole idle time.
            const t0 = anim.nowNs();
            const dt: f32 = if (wm.animating) @as(f32, @floatFromInt(t0 - wm.last_ns)) / 1e9 else 1.0 / @as(f32, @floatFromInt(cfg.anim_hz));
            wm.last_ns = t0;
            wm.animating = wm.animate(std.math.clamp(dt, 0.001, 0.05));

            wm.redrawAll(false);
            _ = c.xcb_flush(wm.conn);
            if (!wm.running) break;
            // Not while the launcher shows results: a rescan would reorder the list its matches index into.
            if (!wm.apps_warm and !wm.animating and !wm.launcher.visible()) {
                // First idle moment: scan the .desktop files now so the first Alt+Space is instant.
                wm.apps_warm = true;
                wm.launcher.db.load();
            }
            pfd[0] = .{ .fd = c.xcb_get_file_descriptor(wm.conn), .events = c.POLLIN, .revents = 0 };
            const n0 = 1 + wm.dbus.pollFill(pfd[1..3]);
            pfd[n0] = .{ .fd = wm.vol.pollFd(), .events = c.POLLIN, .revents = 0 }; // -1 = ignored by poll
            pfd[n0 + 1] = .{ .fd = wm.brightness.pollFd(), .events = c.POLLIN, .revents = 0 };
            pfd[n0 + 2] = .{ .fd = wm.art.pollFd(), .events = c.POLLIN, .revents = 0 };
            pfd[n0 + 3] = .{ .fd = wm.remote.pollFd(), .events = c.POLLIN, .revents = 0 };
            pfd[n0 + 4] = .{ .fd = wm.lyrics.pollFd(), .events = c.POLLIN, .revents = 0 };
            const n = n0 + 5;
            if (wm.animating) {
                _ = anim.waitUntil(pfd[0..@intCast(n)], t0 + anim.frame_ns);
            } else {
                _ = c.poll(&pfd, @intCast(n), wm.sleepMs(now));
            }
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

    // Desktop colour; the desktop widget window uses the same one.
    const bg = [_]u32{cfg.desktop_bg};
    _ = c.xcb_change_window_attributes(conn, screen.root, c.XCB_CW_BACK_PIXEL, &bg);
    _ = c.xcb_clear_area(conn, 0, screen.root, 0, 0, 0, 0);

    var wm = WM{
        .conn = conn,
        .root = screen.root,
        // Top of the screen is taken by the bar (plus its gap).
        .area = .{ .x = 0, .y = cfg.gap + cfg.bar_h, .w = screen.width_in_pixels, .h = screen.height_in_pixels - (cfg.gap + cfg.bar_h) },
        .bar = try Bar.init(conn, &screen),
        .widget = try panel_mod.Widget.init(conn, &screen),
        .panel = .{ .conn = conn, .screen = screen },
        .toasts = .{ .conn = conn, .screen = screen },
        .launcher = .{ .conn = conn, .screen = screen },
        .lock = .{ .conn = conn, .screen = screen },
        .lyrics = .{ .conn = conn, .screen = screen },
        .tree = .{ .gpa = std.heap.c_allocator },
        .saved = [_]Saved{.{ .tree = .{ .gpa = std.heap.c_allocator } }} ** cfg.workspaces,
        .wm_protocols = WM.atom(conn, "WM_PROTOCOLS"),
        .wm_delete = WM.atom(conn, "WM_DELETE_WINDOW"),
        .wm_type = WM.atom(conn, "_NET_WM_WINDOW_TYPE"),
        .wm_desktop = WM.atom(conn, "_NET_WM_DESKTOP"),
        .float_types = .{
            WM.atom(conn, "_NET_WM_WINDOW_TYPE_DIALOG"),
            WM.atom(conn, "_NET_WM_WINDOW_TYPE_SPLASH"),
            WM.atom(conn, "_NET_WM_WINDOW_TYPE_UTILITY"),
            WM.atom(conn, "_NET_WM_WINDOW_TYPE_DOCK"),
            WM.atom(conn, "_NET_WM_WINDOW_TYPE_MENU"),
            WM.atom(conn, "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU"),
            WM.atom(conn, "_NET_WM_WINDOW_TYPE_POPUP_MENU"),
            WM.atom(conn, "_NET_WM_WINDOW_TYPE_TOOLTIP"),
        },
        .net_supported = WM.atom(conn, "_NET_SUPPORTED"),
        .net_check = WM.atom(conn, "_NET_SUPPORTING_WM_CHECK"),
        .net_active = WM.atom(conn, "_NET_ACTIVE_WINDOW"),
    };
    wm.setupEwmh(); // before adopt(): its focus changes must land on a fresh _NET_ACTIVE_WINDOW
    wm.grabKeys();
    wm.dbus.connect(&wm.store);
    wm.adopt();
    _ = c.xcb_flush(conn);
    wm.run();
    wm.dropEwmh();
}

test {
    _ = @import("calc.zig");
    _ = @import("intent.zig");
    _ = @import("store.zig");
    _ = @import("apps.zig");
    _ = @import("panel.zig");
    _ = @import("tree.zig");
    _ = @import("lock.zig");
    _ = @import("lyrics.zig");
}
