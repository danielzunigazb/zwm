// State shared between D-Bus producers (notifications, MPRIS, NetworkManager, wpctl)
// and the widgets that draw it.

const std = @import("std");
const gfx = @import("gfx.zig");

pub const Net = enum { none, wifi, eth };

pub const Status = struct {
    version: u32 = 0,
    vol_pct: i32 = -1,
    muted: bool = false,
    net: Net = .none,
    net_name: [32]u8 = undefined,
    net_len: u8 = 0,
    net_pct: i32 = -1,

    pub fn name(s: *const Status) []const u8 {
        return s.net_name[0..s.net_len];
    }
};

pub const Music = struct {
    have: bool = false,
    playing: bool = false,
    title: [128]u8 = undefined,
    title_len: u8 = 0,
    artist: [96]u8 = undefined,
    artist_len: u8 = 0,
    pos_us: i64 = 0,
    len_us: i64 = 0,

    pub fn titleSlice(m: *const Music) []const u8 {
        return m.title[0..m.title_len];
    }
    pub fn artistSlice(m: *const Music) []const u8 {
        return m.artist[0..m.artist_len];
    }
};

pub const max_notifs = 16;

pub const Notif = struct {
    id: u32 = 0,
    app: [32]u8 = undefined,
    app_len: u8 = 0,
    summary: [96]u8 = undefined,
    summary_len: u8 = 0,
    body: [160]u8 = undefined,
    body_len: u8 = 0,
    toast_until: i64 = 0, // monotonic ms; 0 = no toast

    pub fn appSlice(n: *const Notif) []const u8 {
        return n.app[0..n.app_len];
    }
    pub fn summarySlice(n: *const Notif) []const u8 {
        return n.summary[0..n.summary_len];
    }
    pub fn bodySlice(n: *const Notif) []const u8 {
        return n.body[0..n.body_len];
    }
};

const latin1_map = "AAAAAAACEEEEIIIIDNOOOOO*OUUUUYTsaaaaaaaceeeeiiiidnooooo/ouuuuyty";

/// Copy text into `dst`, replacing control characters. With the TTF font loaded the UTF-8 is kept
/// (cut on a code point boundary); with only the bitmap font it is folded to printable ASCII.
pub fn sanitize(dst: []u8, src: []const u8) u8 {
    const cap = @min(dst.len, 255);
    var n: usize = 0;
    var i: usize = 0;
    const utf8 = gfx.hasTtf();
    while (i < src.len and n < cap) {
        const b = src[i];
        if (b < 0x80) {
            dst[n] = if (b < 0x20 or b == 0x7f) ' ' else b;
            n += 1;
            i += 1;
        } else if (utf8) {
            const l = std.unicode.utf8ByteSequenceLength(b) catch 0;
            const ok = l > 1 and i + l <= src.len and (std.unicode.utf8Decode(src[i..][0..l]) catch null) != null;
            if (!ok) {
                dst[n] = '?';
                n += 1;
                i += 1;
            } else if (n + l <= cap) {
                @memcpy(dst[n..][0..l], src[i..][0..l]);
                n += l;
                i += l;
            } else break;
        } else if (b == 0xC3 and i + 1 < src.len and src[i + 1] >= 0x80 and src[i + 1] <= 0xBF) {
            dst[n] = latin1_map[src[i + 1] - 0x80];
            n += 1;
            i += 2;
        } else {
            dst[n] = if (b == 0xC2 and i + 1 < src.len and src[i + 1] == 0xA1) '!' else '?';
            n += 1;
            i += 1;
            while (i < src.len and src[i] & 0xC0 == 0x80) i += 1; // skip continuation bytes
        }
    }
    return @intCast(n);
}

pub const Store = struct {
    /// Bumped on any notification/music change so widgets know to repaint.
    version: u32 = 0,
    /// Bumped only when the notification list changes (toasts rebuild on this).
    notif_version: u32 = 0,
    music: Music = .{},
    notifs: [max_notifs]Notif = undefined, // newest first
    count: usize = 0,
    next_id: u32 = 1,
    status: Status = .{},

    music_dirty: bool = true,
    net_dirty: bool = true,

    pub fn add(s: *Store, app: []const u8, summary: []const u8, body: []const u8, replaces: u32, timeout_ms: i32, now_ms: i64) u32 {
        var n = Notif{};
        n.app_len = sanitize(&n.app, app);
        n.summary_len = sanitize(&n.summary, summary);
        n.body_len = sanitize(&n.body, body);
        const t: i64 = if (timeout_ms < 0) 5000 else if (timeout_ms == 0) 8000 else @min(timeout_ms, 10_000);
        n.toast_until = now_ms + t;

        var idx: ?usize = null;
        if (replaces != 0) for (s.notifs[0..s.count], 0..) |x, i| {
            if (x.id == replaces) idx = i;
        };
        if (idx) |i| {
            n.id = replaces;
            // Move to front.
            @memmove(s.notifs[1 .. i + 1], s.notifs[0..i]);
        } else {
            n.id = s.next_id;
            s.next_id +%= 1;
            if (s.next_id == 0) s.next_id = 1;
            const keep: usize = @min(s.count, max_notifs - 1);
            @memmove(s.notifs[1 .. keep + 1], s.notifs[0..keep]);
            s.count = keep + 1;
        }
        s.notifs[0] = n;
        s.version +%= 1;
        s.notif_version +%= 1;
        return n.id;
    }

    pub fn dismiss(s: *Store, id: u32) void {
        for (s.notifs[0..s.count], 0..) |x, i| {
            if (x.id != id) continue;
            @memmove(s.notifs[i .. s.count - 1], s.notifs[i + 1 .. s.count]);
            s.count -= 1;
            s.version +%= 1;
            s.notif_version +%= 1;
            return;
        }
    }

    pub fn dropToast(s: *Store, id: u32) void {
        for (s.notifs[0..s.count]) |*x| if (x.id == id and x.toast_until != 0) {
            x.toast_until = 0;
            s.version +%= 1;
            s.notif_version +%= 1;
        };
    }

    pub fn clearAll(s: *Store) void {
        s.count = 0;
        s.version +%= 1;
        s.notif_version +%= 1;
    }
};

test "sanitize never overruns and keeps valid text" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u8, 3), sanitize(&buf, "abc"));
    try std.testing.expectEqual(@as(u8, 8), sanitize(&buf, "0123456789")); // cut at capacity
    try std.testing.expectEqualStrings("a b", buf[0..sanitize(&buf, "a\nb")]); // control -> space
    _ = sanitize(&buf, "\xff\xfe\xc3"); // invalid / truncated sequences must not crash
    _ = sanitize(&buf, "\xe2\x82"); // truncated 3-byte sequence
}

test "notification store: replace, dismiss, overflow" {
    var s = Store{};
    const a = s.add("app", "one", "", 0, 0, 0);
    const b = s.add("app", "two", "", 0, 0, 0);
    try std.testing.expect(a != b and s.count == 2);
    const a2 = s.add("app", "one again", "", a, 0, 0);
    try std.testing.expectEqual(a, a2); // replaced keeps its id...
    try std.testing.expectEqual(@as(usize, 2), s.count);
    try std.testing.expectEqual(a, s.notifs[0].id); // ...and moves to the front
    s.dismiss(b);
    try std.testing.expectEqual(@as(usize, 1), s.count);
    s.dismiss(9999); // unknown id: no-op
    for (0..40) |_| _ = s.add("app", "x", "", 0, 0, 0);
    try std.testing.expectEqual(@as(usize, max_notifs), s.count);
}
