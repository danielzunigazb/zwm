// State shared between D-Bus producers (notifications, MPRIS, NetworkManager, wpctl)
// and the widgets that draw it.

const std = @import("std");
const gfx = @import("gfx.zig");
const cfg = @import("config.zig");

pub const Net = enum { none, wifi, eth };

pub const Status = struct {
    version: u32 = 0,
    vol_pct: i32 = -1,
    muted: bool = false,
    brightness_pct: i32 = -1,
    net: Net = .none,
    net_name: [32]u8 = undefined,
    net_len: u8 = 0,

    pub fn name(s: *const Status) []const u8 {
        return s.net_name[0..s.net_len];
    }
};

pub const Music = struct {
    have: bool = false,
    playing: bool = false,
    /// Comes from Spotify on another device (phone, other PC), not from a player on this machine:
    /// the transport buttons then go through zwm-music instead of MPRIS.
    remote: bool = false,
    title: [128]u8 = undefined,
    title_len: u8 = 0,
    artist: [96]u8 = undefined,
    artist_len: u8 = 0,
    /// The first artist alone (`artist` may carry a second one and the device): what lyrics are looked up by.
    artist_main: [64]u8 = undefined,
    artist_main_len: u8 = 0,
    art_url: [256]u8 = undefined,
    art_url_len: u8 = 0,
    pos_us: i64 = 0,
    len_us: i64 = 0,

    pub fn titleSlice(m: *const Music) []const u8 {
        return m.title[0..m.title_len];
    }
    pub fn artistSlice(m: *const Music) []const u8 {
        return m.artist[0..m.artist_len];
    }
    pub fn mainArtistSlice(m: *const Music) []const u8 {
        return m.artist_main[0..m.artist_main_len];
    }

    /// Set `artist_main` from a display string like "A, B": everything before the first comma.
    pub fn setMainArtist(m: *Music, artists: []const u8) void {
        const first = if (std.mem.indexOf(u8, artists, ", ")) |i| artists[0..i] else artists;
        m.artist_main_len = sanitize(&m.artist_main, first);
    }
    pub fn artUrlSlice(m: *const Music) []const u8 {
        return m.art_url[0..m.art_url_len];
    }

    /// Same thing on screen, ignoring the position (which has its own once-a-second repaint).
    fn sameShown(a: *const Music, b: *const Music) bool {
        return a.have == b.have and a.playing == b.playing and a.remote == b.remote and a.len_us == b.len_us and
            std.mem.eql(u8, a.titleSlice(), b.titleSlice()) and
            std.mem.eql(u8, a.artistSlice(), b.artistSlice()) and
            std.mem.eql(u8, a.artUrlSlice(), b.artUrlSlice());
    }
};

pub const max_notifs = 16;

/// Toast time for a notification with no timeout of its own (`expire_timeout` 0 in the spec means
/// "never expire"; the WM shows it for this long instead). Also used for the WM's own notices.
pub const toast_default_ms: i32 = 8000;
const toast_server_ms: i32 = 5000; // expire_timeout < 0: the sender left it to the server
const toast_max_ms: i32 = 10_000; // a sender may not keep a toast on screen longer than this

pub const Notif = struct {
    id: u32 = 0,
    /// Bus name of the client that sent it ("zwm" for our own). Only that client may replace or close it.
    owner: [48]u8 = undefined,
    owner_len: u8 = 0,
    app: [32]u8 = undefined,
    app_len: u8 = 0,
    summary: [96]u8 = undefined,
    summary_len: u8 = 0,
    body: [160]u8 = undefined,
    body_len: u8 = 0,
    toast_until: i64 = 0, // monotonic ms; 0 = no toast

    pub fn ownerSlice(n: *const Notif) []const u8 {
        return n.owner[0..n.owner_len];
    }
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

/// Bidi overrides/isolates and zero-width or format characters: a notification could use them to
/// make its text read differently from what it says.
fn isInvisible(cp: u21) bool {
    return (cp >= 0x200B and cp <= 0x200F) or (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069) or cp == 0xFEFF;
}

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
            const cp = if (l > 1 and i + l <= src.len) (std.unicode.utf8Decode(src[i..][0..l]) catch null) else null;
            if (cp == null) {
                dst[n] = '?';
                n += 1;
                i += 1;
            } else if (isInvisible(cp.?)) {
                i += l; // dropped: it would reorder or hide the text around it
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
    /// What the panel and widget show: see `mergeMusic`.
    music: Music = .{},
    music_local: Music = .{}, // MPRIS player on this machine
    music_remote: Music = .{}, // Spotify on another device, from `zwm-music watch`
    notifs: [max_notifs]Notif = undefined, // newest first
    count: usize = 0,
    next_id: u32 = 1,
    status: Status = .{},

    music_dirty: bool = true,
    net_dirty: bool = true,
    /// The panel's lyrics switch. Starts as configured; not remembered across restarts.
    lyrics_on: bool = cfg.lyrics,

    /// Pick what to show: a local player that is playing wins (no point mirroring what this PC
    /// plays), then Spotify playing elsewhere, then whichever is merely paused (local first).
    pub fn mergeMusic(s: *Store) void {
        const l = &s.music_local;
        const r = &s.music_remote;
        const next = if (r.have and (!l.have or (r.playing and !l.playing))) r else l;
        if (!s.music.sameShown(next)) s.version +%= 1;
        s.music = next.*;
    }

    /// True when notification `id` is still shown and was sent by `owner` (a bus name).
    pub fn ownedBy(s: *const Store, id: u32, owner: []const u8) bool {
        for (s.notifs[0..s.count]) |x| if (x.id == id) return std.mem.eql(u8, x.ownerSlice(), owner);
        return false;
    }

    /// `owner` is the sender's bus name. A notification can only be replaced by the client that sent it.
    pub fn add(s: *Store, app: []const u8, owner: []const u8, summary: []const u8, body: []const u8, replaces: u32, timeout_ms: i32, now_ms: i64) u32 {
        var n = Notif{};
        n.owner_len = sanitize(&n.owner, owner);
        n.app_len = sanitize(&n.app, app);
        n.summary_len = sanitize(&n.summary, summary);
        n.body_len = sanitize(&n.body, body);
        const t: i64 = if (timeout_ms < 0) toast_server_ms else if (timeout_ms == 0) toast_default_ms else @min(timeout_ms, toast_max_ms);
        n.toast_until = now_ms + t;

        var idx: ?usize = null;
        if (replaces != 0) for (s.notifs[0..s.count], 0..) |x, i| {
            if (x.id == replaces and std.mem.eql(u8, x.ownerSlice(), owner)) idx = i;
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
    const a = s.add("app", ":1.7", "one", "", 0, 0, 0);
    const b = s.add("app", ":1.7", "two", "", 0, 0, 0);
    try std.testing.expect(a != b and s.count == 2);
    const a2 = s.add("app", ":1.7", "one again", "", a, 0, 0);
    try std.testing.expectEqual(a, a2); // replaced keeps its id...
    try std.testing.expectEqual(@as(usize, 2), s.count);
    try std.testing.expectEqual(a, s.notifs[0].id); // ...and moves to the front
    s.dismiss(b);
    try std.testing.expectEqual(@as(usize, 1), s.count);
    s.dismiss(9999); // unknown id: no-op
    // Overflow drops the oldest: the first id must be gone once the list is full of newer ones.
    const oldest = s.add("app", ":1.7", "keep me", "", 0, 0, 0);
    for (0..40) |_| _ = s.add("app", ":1.7", "x", "", 0, 0, 0);
    try std.testing.expectEqual(@as(usize, max_notifs), s.count);
    for (s.notifs[0..s.count]) |x| try std.testing.expect(x.id != oldest);
}

test "notification store: only the sender may replace or close" {
    var s = Store{};
    const theirs = s.add("bank", ":1.5", "Your code is 123456", "", 0, 0, 0);
    // Another client names the same id: it must get a new notification, not overwrite this one.
    const forged = s.add("bank", ":1.9", "Send money to", "", theirs, 0, 0);
    try std.testing.expect(forged != theirs);
    try std.testing.expect(s.ownedBy(theirs, ":1.5"));
    try std.testing.expect(!s.ownedBy(theirs, ":1.9"));
    try std.testing.expectEqualStrings("Your code is 123456", s.notifs[1].summarySlice());
}

test "sanitize drops bidi overrides and zero-width characters" {
    // Without the TTF font, sanitize folds to ASCII instead of keeping UTF-8: nothing to check there.
    if (!gfx.hasTtf()) return error.SkipZigTest;
    var buf: [64]u8 = undefined;
    // U+202E (right-to-left override) and U+200B (zero-width space) around plain text.
    const n = sanitize(&buf, "a\u{202E}b\u{200B}c");
    try std.testing.expectEqualStrings("abc", buf[0..n]);
}

test "mergeMusic: local playing wins, then Spotify elsewhere, then paused local" {
    var s = Store{};
    const local = Music{ .have = true, .playing = true };
    const remote = Music{ .have = true, .playing = true, .remote = true };

    s.music_remote = remote;
    s.mergeMusic();
    try std.testing.expect(s.music.remote);

    s.music_local = local;
    s.mergeMusic();
    try std.testing.expect(!s.music.remote); // this PC plays: do not mirror the phone

    s.music_local.playing = false;
    s.mergeMusic();
    try std.testing.expect(s.music.remote); // PC paused, phone playing

    s.music_remote.playing = false;
    s.mergeMusic();
    try std.testing.expect(!s.music.remote); // both paused: the local player

    s.music_local = .{};
    s.music_remote = .{};
    s.mergeMusic();
    try std.testing.expect(!s.music.have);
}
