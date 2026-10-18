// sd-bus glue. Session bus: org.freedesktop.Notifications server + MPRIS client.
// System bus: NetworkManager state. Both are polled from the main loop.

const std = @import("std");
const c = @import("c.zig").c;
const store_mod = @import("store.zig");
const panel = @import("panel.zig");
const sys = @import("sys.zig");

const Store = store_mod.Store;

const mpris_path = "/org/mpris/MediaPlayer2";
const player_iface = "org.mpris.MediaPlayer2.Player";

pub const Dbus = struct {
    store: *Store = undefined,
    session: ?*c.sd_bus = null,
    system: ?*c.sd_bus = null,
    player: [128:0]u8 = [_:0]u8{0} ** 128,
    player_len: usize = 0,

    /// `d` must not move afterwards (callbacks keep a pointer to it).
    pub fn connect(d: *Dbus, st: *Store) void {
        d.store = st;
        st.music_dirty = true;
        st.net_dirty = true;

        var bus: ?*c.sd_bus = null;
        if (c.sd_bus_open_user(&bus) >= 0 and bus != null) {
            d.session = bus;
            _ = c.sd_bus_set_method_call_timeout(bus, 150_000); // µs: never stall the WM
            // Fails harmlessly if another notification daemon already owns the name.
            _ = c.sd_bus_request_name(bus, "org.freedesktop.Notifications", 0);
            _ = c.sd_bus_add_filter(bus, null, onMethod, d);
            _ = c.sd_bus_add_match(bus, null, "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='" ++ mpris_path ++ "'", onMusicSignal, d);
            _ = c.sd_bus_add_match(bus, null, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0namespace='org.mpris.MediaPlayer2'", onMusicSignal, d);
        }

        var sbus: ?*c.sd_bus = null;
        if (c.sd_bus_open_system(&sbus) >= 0 and sbus != null) {
            d.system = sbus;
            _ = c.sd_bus_set_method_call_timeout(sbus, 150_000);
            _ = c.sd_bus_add_match(sbus, null, "type='signal',sender='org.freedesktop.NetworkManager',interface='org.freedesktop.NetworkManager',member='StateChanged'", onNetSignal, d);
        }
    }

    /// Fill poll entries for the buses we have; returns how many were added.
    pub fn pollFill(d: *Dbus, pfd: []c.struct_pollfd) usize {
        var n: usize = 0;
        for ([_]?*c.sd_bus{ d.session, d.system }) |maybe| {
            const bus = maybe orelse continue;
            if (n >= pfd.len) break;
            pfd[n] = .{ .fd = c.sd_bus_get_fd(bus), .events = @intCast(c.sd_bus_get_events(bus)), .revents = 0 };
            n += 1;
        }
        return n;
    }

    /// Soonest bus-internal timeout in ms (relative), if any.
    pub fn timeoutMs(d: *Dbus) ?i64 {
        var best: ?i64 = null;
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        const now_us: u64 = @as(u64, @intCast(ts.tv_sec)) * 1_000_000 + @as(u64, @intCast(ts.tv_nsec)) / 1000;
        for ([_]?*c.sd_bus{ d.session, d.system }) |maybe| {
            const bus = maybe orelse continue;
            var us: u64 = 0;
            if (c.sd_bus_get_timeout(bus, &us) < 0 or us == std.math.maxInt(u64)) continue;
            const ms: i64 = if (us <= now_us) 0 else @intCast((us - now_us + 999) / 1000);
            if (best == null or ms < best.?) best = ms;
        }
        return best;
    }

    pub fn process(d: *Dbus) void {
        for ([_]*?*c.sd_bus{ &d.session, &d.system }) |slot| {
            const bus = slot.* orelse continue;
            var r: c_int = 1;
            while (r > 0) r = c.sd_bus_process(bus, null);
            if (r < 0 or c.sd_bus_is_open(bus) <= 0) {
                // The daemon went away: drop the bus, otherwise its dead fd makes poll() spin.
                _ = c.sd_bus_flush_close_unref(bus);
                slot.* = null;
                if (slot == &d.session) d.player_len = 0;
                continue;
            }
            _ = c.sd_bus_flush(bus);
        }
    }

    // ---- MPRIS ----

    fn playerZ(d: *Dbus) [*:0]const u8 {
        return &d.player;
    }

    fn playbackIs(d: *Dbus, dest: [*:0]const u8, want: []const u8) bool {
        const bus = d.session orelse return false;
        var err = std.mem.zeroes(c.sd_bus_error);
        defer c.sd_bus_error_free(&err);
        var ret: [*c]u8 = null;
        if (c.sd_bus_get_property_string(bus, dest, mpris_path, player_iface, "PlaybackStatus", &err, &ret) < 0) return false;
        defer std.c.free(ret);
        return std.mem.eql(u8, std.mem.span(ret), want);
    }

    /// Choose a player: prefer one that is playing, else the first one found.
    fn pickPlayer(d: *Dbus) bool {
        const bus = d.session orelse return false;
        var err = std.mem.zeroes(c.sd_bus_error);
        defer c.sd_bus_error_free(&err);
        var reply: ?*c.sd_bus_message = null;
        if (c.sd_bus_call_method(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", &err, &reply, "") < 0) return false;
        defer _ = c.sd_bus_message_unref(reply);
        if (c.sd_bus_message_enter_container(reply, 'a', "s") < 0) return false;

        var found = false;
        var found_playing = false;
        var name: [*c]const u8 = null;
        while (c.sd_bus_message_read(reply, "s", &name) > 0) {
            const nm = std.mem.span(name);
            if (!std.mem.startsWith(u8, nm, "org.mpris.MediaPlayer2.") or nm.len >= d.player.len) continue;
            var tmp: [128:0]u8 = [_:0]u8{0} ** 128;
            @memcpy(tmp[0..nm.len], nm);
            const playing = d.playbackIs(&tmp, "Playing");
            if (!found or (playing and !found_playing)) {
                d.player = tmp;
                d.player_len = nm.len;
                found = true;
                found_playing = playing;
            }
        }
        if (!found) d.player_len = 0;
        return found;
    }

    pub fn refreshMusic(d: *Dbus) void {
        const st = d.store;
        st.music_dirty = false;
        defer st.version +%= 1;
        const m = &st.music;
        m.* = .{};
        if (d.session == null or !d.pickPlayer()) return;
        m.have = true;
        m.playing = d.playbackIs(d.playerZ(), "Playing");
        d.readMetadata(m);
        d.refreshPosition();
    }

    pub fn refreshPosition(d: *Dbus) void {
        const bus = d.session orelse return;
        if (d.player_len == 0) return;
        var err = std.mem.zeroes(c.sd_bus_error);
        defer c.sd_bus_error_free(&err);
        var pos: i64 = 0;
        if (c.sd_bus_get_property_trivial(bus, d.playerZ(), mpris_path, player_iface, "Position", &err, 'x', &pos) >= 0) {
            d.store.music.pos_us = pos;
        }
    }

    fn readMetadata(d: *Dbus, m: *store_mod.Music) void {
        const bus = d.session orelse return;
        var err = std.mem.zeroes(c.sd_bus_error);
        defer c.sd_bus_error_free(&err);
        var r: ?*c.sd_bus_message = null;
        if (c.sd_bus_call_method(bus, d.playerZ(), mpris_path, "org.freedesktop.DBus.Properties", "Get", &err, &r, "ss", player_iface, "Metadata") < 0) return;
        defer _ = c.sd_bus_message_unref(r);
        if (c.sd_bus_message_enter_container(r, 'v', "a{sv}") < 0) return;
        if (c.sd_bus_message_enter_container(r, 'a', "{sv}") < 0) return;

        while (c.sd_bus_message_enter_container(r, 'e', "sv") > 0) {
            var key: [*c]const u8 = null;
            if (c.sd_bus_message_read(r, "s", &key) < 0) break;
            const k = std.mem.span(key);

            var ty: u8 = 0;
            var cont: [*c]const u8 = null;
            _ = c.sd_bus_message_peek_type(r, &ty, &cont);
            const sig: []const u8 = if (cont != null) std.mem.span(cont) else "";

            if (std.mem.eql(u8, k, "xesam:title") and std.mem.eql(u8, sig, "s")) {
                _ = c.sd_bus_message_enter_container(r, 'v', "s");
                var s: [*c]const u8 = null;
                if (c.sd_bus_message_read(r, "s", &s) > 0) m.title_len = store_mod.sanitize(&m.title, std.mem.span(s));
                _ = c.sd_bus_message_exit_container(r);
            } else if (std.mem.eql(u8, k, "xesam:artist") and std.mem.eql(u8, sig, "as")) {
                _ = c.sd_bus_message_enter_container(r, 'v', "as");
                _ = c.sd_bus_message_enter_container(r, 'a', "s");
                var s: [*c]const u8 = null;
                var first = true;
                while (c.sd_bus_message_read(r, "s", &s) > 0) {
                    if (first) m.artist_len = store_mod.sanitize(&m.artist, std.mem.span(s));
                    first = false;
                }
                _ = c.sd_bus_message_exit_container(r);
                _ = c.sd_bus_message_exit_container(r);
            } else if (std.mem.eql(u8, k, "mpris:length") and (std.mem.eql(u8, sig, "x") or std.mem.eql(u8, sig, "t"))) {
                if (std.mem.eql(u8, sig, "x")) {
                    _ = c.sd_bus_message_enter_container(r, 'v', "x");
                    var v: i64 = 0;
                    if (c.sd_bus_message_read(r, "x", &v) > 0) m.len_us = v;
                } else {
                    _ = c.sd_bus_message_enter_container(r, 'v', "t");
                    var v: u64 = 0;
                    if (c.sd_bus_message_read(r, "t", &v) > 0) m.len_us = @intCast(@min(v, std.math.maxInt(i64)));
                }
                _ = c.sd_bus_message_exit_container(r);
            } else {
                _ = c.sd_bus_message_skip(r, "v");
            }
            _ = c.sd_bus_message_exit_container(r); // dict entry
        }
    }

    pub fn control(d: *Dbus, method: [*:0]const u8) void {
        const bus = d.session orelse return;
        if (d.player_len == 0 and !d.pickPlayer()) return;
        var err = std.mem.zeroes(c.sd_bus_error);
        defer c.sd_bus_error_free(&err);
        _ = c.sd_bus_call_method(bus, d.playerZ(), mpris_path, player_iface, method, &err, null, "");
    }

    // ---- NetworkManager ----

    pub fn refreshNet(d: *Dbus) void {
        const st = d.store;
        st.net_dirty = false;
        const s = &st.status;
        s.net = .none;
        s.net_len = 0;
        s.net_pct = -1;
        defer s.version +%= 1;
        const bus = d.system orelse return;

        var err = std.mem.zeroes(c.sd_bus_error);
        defer c.sd_bus_error_free(&err);

        // PrimaryConnection is an object path ('o'), which get_property_string rejects: use Get + variant.
        var reply: ?*c.sd_bus_message = null;
        if (c.sd_bus_call_method(bus, "org.freedesktop.NetworkManager", "/org/freedesktop/NetworkManager", "org.freedesktop.DBus.Properties", "Get", &err, &reply, "ss", "org.freedesktop.NetworkManager", "PrimaryConnection") < 0) return;
        defer _ = c.sd_bus_message_unref(reply);
        if (c.sd_bus_message_enter_container(reply, 'v', "o") < 0) return;
        var path: [*c]const u8 = null;
        if (c.sd_bus_message_read(reply, "o", &path) < 0) return;
        if (std.mem.len(path) <= 1) return; // "/" = no connection

        const active_iface = "org.freedesktop.NetworkManager.Connection.Active";
        var ty: [*c]u8 = null;
        if (c.sd_bus_get_property_string(bus, "org.freedesktop.NetworkManager", path, active_iface, "Type", &err, &ty) < 0) return;
        defer std.c.free(ty);
        if (std.mem.indexOf(u8, std.mem.span(ty), "wireless") != null) {
            var id: [*c]u8 = null;
            if (c.sd_bus_get_property_string(bus, "org.freedesktop.NetworkManager", path, active_iface, "Id", &err, &id) >= 0) {
                defer std.c.free(id);
                s.net_len = store_mod.sanitize(&s.net_name, std.mem.span(id));
            }
            s.net = .wifi;
            s.net_pct = sys.wifiQuality();
        } else {
            s.net = .eth;
        }
    }
};

fn self(ud: ?*anyopaque) *Dbus {
    return @ptrCast(@alignCast(ud.?));
}

fn onMusicSignal(_: ?*c.sd_bus_message, ud: ?*anyopaque, _: [*c]c.sd_bus_error) callconv(.c) c_int {
    self(ud).store.music_dirty = true;
    return 0;
}

fn onNetSignal(_: ?*c.sd_bus_message, ud: ?*anyopaque, _: [*c]c.sd_bus_error) callconv(.c) c_int {
    self(ud).store.net_dirty = true;
    return 0;
}

const cap_body: [*:0]const u8 = "body";
const info_name: [*:0]const u8 = "wm";
const info_vendor: [*:0]const u8 = "dan";
const info_version: [*:0]const u8 = "0.1";
const info_spec: [*:0]const u8 = "1.2";

/// Implements the org.freedesktop.Notifications methods by hand (no vtable).
fn onMethod(m: ?*c.sd_bus_message, ud: ?*anyopaque, _: [*c]c.sd_bus_error) callconv(.c) c_int {
    if (c.sd_bus_message_is_method_call(m, "org.freedesktop.Notifications", null) <= 0) return 0;
    const d = self(ud);
    const member = std.mem.span(c.sd_bus_message_get_member(m));

    if (std.mem.eql(u8, member, "Notify")) {
        var app: [*c]const u8 = null;
        var rid: c_uint = 0;
        var icon: [*c]const u8 = null;
        var summary: [*c]const u8 = null;
        var body: [*c]const u8 = null;
        if (c.sd_bus_message_read(m, "susss", &app, &rid, &icon, &summary, &body) < 0) return 0;
        _ = c.sd_bus_message_skip(m, "asa{sv}");
        var timeout: c_int = -1;
        _ = c.sd_bus_message_read(m, "i", &timeout);
        const id = d.store.add(std.mem.span(app), std.mem.span(summary), std.mem.span(body), rid, timeout, panel.nowMs());
        _ = c.sd_bus_reply_method_return(m, "u", @as(c_uint, id));
    } else if (std.mem.eql(u8, member, "GetCapabilities")) {
        _ = c.sd_bus_reply_method_return(m, "as", @as(c_uint, 1), cap_body);
    } else if (std.mem.eql(u8, member, "GetServerInformation")) {
        _ = c.sd_bus_reply_method_return(m, "ssss", info_name, info_vendor, info_version, info_spec);
    } else if (std.mem.eql(u8, member, "CloseNotification")) {
        var id: c_uint = 0;
        _ = c.sd_bus_message_read(m, "u", &id);
        d.store.dismiss(id);
        _ = c.sd_bus_reply_method_return(m, null);
    } else return 0;
    return 1;
}
