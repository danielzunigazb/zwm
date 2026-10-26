//! zwm-watch: what plays on any of the user's Spotify devices (phone, other PC...), one line per poll
//! of the Web API on stdout. The zwm panel reads it; it ends when the panel goes away (broken pipe).
//!
//! A separate static binary, not part of the WM: the WM must never block on TLS. Line format (tabs):
//!   state (P playing, p paused, - nothing), title, artist, cover URL, position ms, length ms, device
//! Tokens live in the same file zwm-music writes (~/.config/zwm/spotify.json).

const std = @import("std");
const Io = std.Io;
const http = std.http;

const player_url = "https://api.spotify.com/v1/me/player?additional_types=episode";
const token_url = "https://accounts.spotify.com/api/token";

const Image = struct { url: []const u8 = "" };
const Artist = struct { name: []const u8 = "" };
const Album = struct { images: []const Image = &.{} };
const Show = struct { name: []const u8 = "", images: []const Image = &.{} };
const Item = struct {
    type: []const u8 = "",
    name: []const u8 = "",
    duration_ms: ?i64 = null,
    artists: []const Artist = &.{},
    album: ?Album = null,
    show: ?Show = null,
    images: []const Image = &.{},
};
const Device = struct { name: []const u8 = "" };
const Player = struct { is_playing: bool = false, progress_ms: ?i64 = null, item: ?Item = null, device: ?Device = null };

/// Replies and the config file go through fixed buffers, and the HTTP/TLS client allocates from
/// `page_allocator`: what it frees (the root certificates, ~200 KB once parsed) goes back to the
/// kernel instead of sitting in a malloc heap that never shrinks. Resident size is the point of this
/// binary: ~0.6 MB, against ~29 MB for the Python interpreter it replaces.
var body_buf: [64 * 1024]u8 = undefined;
var conf_buf: [8 * 1024]u8 = undefined;

const Watcher = struct {
    io: Io,
    gpa: std.mem.Allocator,
    client: http.Client,
    conf_path: []const u8,
    token: [512]u8 = undefined,
    token_len: usize = 0,
    expires_at: i64 = 0,

    const Error = error{ Offline, Rejected, NotLoggedIn };

    /// One request on the kept-alive connection; the body (if any) lands in `out`.
    /// Not `client.fetch`: std waits for the connection to close to find the end of a 204's (absent)
    /// body, which here would mean hanging for as long as Spotify keeps the connection open.
    fn exchange(w: *Watcher, method: http.Method, url: []const u8, headers: http.Client.Request.Headers, payload: ?[]const u8, out: *Io.Writer) !http.Status {
        var req = try w.client.request(method, try std.Uri.parse(url), .{
            .redirect_behavior = .unhandled,
            .headers = headers,
        });
        defer req.deinit();
        if (payload) |p| {
            req.transfer_encoding = .{ .content_length = p.len };
            var body = try req.sendBodyUnflushed(&.{});
            try body.writer.writeAll(p);
            try body.end();
            try req.connection.?.flush();
        } else try req.sendBodiless();

        var response = try req.receiveHead(&.{});
        const status = response.head.status;
        if (status == .no_content) {
            req.reader.state = .ready; // no body: the connection is ready for the next poll
            return status;
        }
        var transfer: [64]u8 = undefined;
        _ = response.reader(&transfer).streamRemaining(out) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        return status;
    }

    /// The system root certificates are only needed to open a connection, and the connection then lives
    /// for hours: free them after each good request. `client.now` stays set so std does not rescan on
    /// every request...
    fn dropCerts(w: *Watcher) void {
        w.client.ca_bundle.deinit(w.client.allocator);
        w.client.ca_bundle = .empty;
    }

    /// ...and clearing it makes the next request reload them: before talking to a host the live
    /// connection is not to, or after a request failed (the connection is gone).
    fn needCerts(w: *Watcher) void {
        w.client.now = null;
    }

    fn now(w: *Watcher) i64 {
        return Io.Timestamp.now(w.io, .real).toSeconds();
    }

    fn readConf(w: *Watcher) !std.json.Parsed(std.json.Value) {
        var file = Io.Dir.cwd().openFile(w.io, w.conf_path, .{}) catch return error.NotLoggedIn;
        defer file.close(w.io);
        var r = file.reader(w.io, &.{});
        const n = r.interface.readSliceShort(&conf_buf) catch return error.NotLoggedIn;
        return std.json.parseFromSlice(std.json.Value, w.gpa, conf_buf[0..n], .{}) catch error.NotLoggedIn;
    }

    fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const v = obj.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    fn expiry(obj: std.json.ObjectMap) i64 {
        const v = obj.get("expires_at") orelse return 0;
        return switch (v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => 0,
        };
    }

    /// A valid access token in `w.token`. zwm-music may have refreshed it since: look at the file first.
    fn ensureToken(w: *Watcher, force: bool) !void {
        if (!force and w.token_len > 0 and w.expires_at > w.now() + 30) return;
        const parsed = try w.readConf();
        defer parsed.deinit();
        if (parsed.value != .object) return error.NotLoggedIn;
        const obj = parsed.value.object;
        const refresh_token = str(obj, "refresh_token") orelse return error.NotLoggedIn;
        const client_id = str(obj, "client_id") orelse return error.NotLoggedIn;

        if (str(obj, "access_token")) |t| {
            if (!force and expiry(obj) > w.now() + 30 and t.len <= w.token.len) {
                @memcpy(w.token[0..t.len], t);
                w.token_len = t.len;
                w.expires_at = expiry(obj);
                return;
            }
        }
        try w.refresh(obj, refresh_token, client_id);
    }

    fn refresh(w: *Watcher, obj: std.json.ObjectMap, refresh_token: []const u8, client_id: []const u8) !void {
        var form: [1024]u8 = undefined;
        var fw = Io.Writer.fixed(&form);
        fw.writeAll("grant_type=refresh_token&refresh_token=") catch return error.Rejected;
        formEncode(&fw, refresh_token) catch return error.Rejected;
        fw.writeAll("&client_id=") catch return error.Rejected;
        formEncode(&fw, client_id) catch return error.Rejected;

        var out = Io.Writer.fixed(&body_buf);
        w.needCerts(); // accounts.spotify.com is not the host of the live connection
        defer w.dropCerts();
        const status = w.exchange(.POST, token_url, .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .accept_encoding = .omit,
        }, fw.buffered(), &out) catch return error.Offline;
        if (status != .ok) return error.Rejected;

        const tok = std.json.parseFromSlice(struct {
            access_token: []const u8,
            expires_in: ?i64 = null,
            refresh_token: ?[]const u8 = null,
        }, w.gpa, out.buffered(), .{ .ignore_unknown_fields = true }) catch return error.Rejected;
        defer tok.deinit();
        if (tok.value.access_token.len > w.token.len) return error.Rejected;
        @memcpy(w.token[0..tok.value.access_token.len], tok.value.access_token);
        w.token_len = tok.value.access_token.len;
        w.expires_at = w.now() + (tok.value.expires_in orelse 3600);
        w.save(obj, tok.value.refresh_token orelse refresh_token);
    }

    /// Same file and shape zwm-music writes, replaced atomically and readable by the owner only.
    fn save(w: *Watcher, old: std.json.ObjectMap, refresh_token: []const u8) void {
        var map = old;
        var arena = std.heap.ArenaAllocator.init(w.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var copy = std.json.ObjectMap.empty;
        var it = map.iterator();
        while (it.next()) |e| copy.put(a, e.key_ptr.*, e.value_ptr.*) catch return;
        copy.put(a, "access_token", .{ .string = w.token[0..w.token_len] }) catch return;
        copy.put(a, "refresh_token", .{ .string = refresh_token }) catch return;
        copy.put(a, "expires_at", .{ .integer = w.expires_at }) catch return;

        var out = Io.Writer.fixed(&conf_buf);
        std.json.Stringify.value(std.json.Value{ .object = copy }, .{ .whitespace = .indent_1 }, &out) catch return;

        var atomic = Io.Dir.cwd().createFileAtomic(w.io, w.conf_path, .{
            .permissions = .fromMode(0o600),
            .replace = true,
        }) catch return;
        defer atomic.deinit(w.io);
        atomic.file.writeStreamingAll(w.io, out.buffered()) catch return;
        atomic.replace(w.io) catch return;
    }

    /// One poll: status and body (in `body_buf`). A 401 refreshes the token once, and a failed request
    /// is retried once on a new connection (the kept-alive one may have been closed by the server).
    fn poll(w: *Watcher) Error!struct { status: http.Status, body: []const u8 } {
        var refreshed = false;
        var reconnected = false;
        while (true) {
            w.ensureToken(refreshed) catch |e| return switch (e) {
                error.NotLoggedIn => error.NotLoggedIn,
                error.Rejected => error.Rejected,
                else => error.Offline,
            };
            var auth: [520]u8 = undefined;
            const header = std.fmt.bufPrint(&auth, "Bearer {s}", .{w.token[0..w.token_len]}) catch return error.Rejected;
            var out = Io.Writer.fixed(&body_buf);
            const status = w.exchange(.GET, player_url, .{
                .authorization = .{ .override = header },
                .accept_encoding = .omit,
            }, null, &out) catch {
                w.needCerts(); // a new connection needs them
                if (reconnected) return error.Offline;
                reconnected = true;
                continue;
            };
            w.dropCerts();
            if (status == .unauthorized) {
                if (refreshed) return error.Rejected;
                refreshed = true;
                continue;
            }
            return .{ .status = status, .body = out.buffered() };
        }
    }
};

fn formEncode(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try w.writeByte(ch);
        } else try w.print("%{X:0>2}", .{ch});
    }
}

/// One line in the zwm-music watch format, or "-" when the player has nothing.
fn formatLine(w: *Io.Writer, data: Player) Io.Writer.Error!void {
    const item = data.item orelse return w.writeAll("-\n");
    var artist: []const u8 = "";
    var artist2: []const u8 = "";
    var images: []const Image = &.{};
    if (std.mem.eql(u8, item.type, "episode")) {
        if (item.show) |s| {
            artist = s.name;
            images = if (item.images.len > 0) item.images else s.images;
        } else images = item.images;
    } else {
        if (item.artists.len > 0) artist = item.artists[0].name;
        if (item.artists.len > 1) artist2 = item.artists[1].name;
        if (item.album) |al| images = al.images;
    }
    // The medium cover (300 px) when there is one: that is the size the panel draws.
    const cover = if (images.len > 1) images[1].url else if (images.len == 1) images[0].url else "";

    try w.writeByte(if (data.is_playing) 'P' else 'p');
    try w.writeByte('\t');
    try tidy(w, item.name);
    try w.writeByte('\t');
    try tidy(w, artist);
    if (artist2.len > 0) {
        try w.writeAll(", ");
        try tidy(w, artist2);
    }
    try w.writeByte('\t');
    try w.writeAll(cover);
    try w.print("\t{d}\t{d}\t", .{ data.progress_ms orelse 0, item.duration_ms orelse 0 });
    try tidy(w, if (data.device) |d| d.name else "");
    try w.writeByte('\n');
}

/// Collapse whitespace runs to one space: one line, no tabs (the WM splits on them).
fn tidy(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    var pending_space = false;
    var wrote = false;
    for (text) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0b or ch == 0x0c) {
            pending_space = wrote;
            continue;
        }
        if (pending_space) try w.writeByte(' ');
        pending_space = false;
        wrote = true;
        try w.writeByte(ch);
    }
}

fn confPath(buf: []u8, environ: std.process.Environ) ?[]const u8 {
    if (environ.getPosix("XDG_CONFIG_HOME")) |x| if (x.len > 0)
        return std.fmt.bufPrint(buf, "{s}/zwm/spotify.json", .{x}) catch null;
    const home = environ.getPosix("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/zwm/spotify.json", .{home}) catch null;
}

/// The TLS handshake runs ~200 KB deep into the stack (crypto scratch space). Those pages are dead
/// once it returns but stay resident; hand them back.
fn releaseStack() void {
    var marker: u8 = 0;
    const live = std.mem.alignBackward(usize, @intFromPtr(&marker), 4096) - 4096;
    const window: usize = 1 << 20; // far more than the stack grows; unmapped parts are skipped
    _ = std.os.linux.madvise(@ptrFromInt(live - window), window, std.os.linux.MADV.DONTNEED);
}

/// One poll: print the line and return the seconds to wait before the next one.
fn step(w: *Watcher, out: *Io.Writer) error{ NotLoggedIn, Closed }!i64 {
    const res = w.poll() catch |e| switch (e) {
        error.NotLoggedIn => return error.NotLoggedIn,
        else => return 15, // offline or token rejected: keep the last line
    };
    switch (res.status) {
        .ok => {
            const parsed = std.json.parseFromSlice(Player, w.gpa, res.body, .{ .ignore_unknown_fields = true }) catch return 15;
            defer parsed.deinit();
            formatLine(out, parsed.value) catch return error.Closed;
            out.flush() catch return error.Closed; // the panel went away
            return if (parsed.value.is_playing) 3 else 6;
        },
        .no_content => { // no device has played recently
            out.writeAll("-\n") catch return error.Closed;
            out.flush() catch return error.Closed;
            return 10;
        },
        .too_many_requests => return 30,
        else => return 15,
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const io = Io.Threaded.global_single_threaded.io();
    var path_buf: [512]u8 = undefined;
    const path = confPath(&path_buf, init.environ) orelse return 1;

    var w = Watcher{ .io = io, .gpa = std.heap.c_allocator, .client = .{ .allocator = std.heap.page_allocator, .io = io }, .conf_path = path };
    var stdout_buf: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);

    while (true) {
        const wait = step(&w, &stdout.interface) catch |e| return switch (e) {
            error.NotLoggedIn => 1, // nothing to watch; the WM tries again in a minute
            error.Closed => 0,
        };
        releaseStack();
        io.sleep(.fromSeconds(wait), .awake) catch return 0;
    }
}

fn lineOf(json: []const u8, buf: []u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(Player, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var w = Io.Writer.fixed(buf);
    try formatLine(&w, parsed.value);
    return w.buffered();
}

test "formatLine: a playing track, two artists at most, the 300 px cover" {
    var buf: [512]u8 = undefined;
    const line = try lineOf(
        \\{"is_playing":true,"progress_ms":1500,"device":{"name":"OPPO  A60","id":"x"},
        \\ "item":{"type":"track","name":"Dt\tMF","duration_ms":200000,
        \\  "artists":[{"name":"Bad Bunny"},{"name":"Chencho"},{"name":"Third"}],
        \\  "album":{"images":[{"url":"big"},{"url":"mid"},{"url":"small"}],"name":"ignored"}}}
    , &buf);
    try std.testing.expectEqualStrings("P\tDt MF\tBad Bunny, Chencho\tmid\t1500\t200000\tOPPO A60\n", line);
}

test "formatLine: paused episode takes the show name and the cover of the episode" {
    var buf: [512]u8 = undefined;
    const line = try lineOf(
        \\{"is_playing":false,"progress_ms":null,"item":{"type":"episode","name":"Ep 1","duration_ms":null,
        \\ "images":[{"url":"only"}],"show":{"name":"El show","images":[{"url":"show"}]}}}
    , &buf);
    try std.testing.expectEqualStrings("p\tEp 1\tEl show\tonly\t0\t0\t\n", line);
}

test "formatLine: nothing to show is a dash" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("-\n", try lineOf("{\"is_playing\":false}", &buf));
    try std.testing.expectEqualStrings("-\n", try lineOf("{\"item\":null}", &buf));
}

test "formEncode: only unreserved characters pass through" {
    var buf: [64]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try formEncode(&w, "aZ09-_.~ +/=&");
    try std.testing.expectEqualStrings("aZ09-_.~%20%2B%2F%3D%26", w.buffered());
}
