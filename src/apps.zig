// Application database for the launcher: .desktop files, fuzzy search, usage counts.

const std = @import("std");
const c = @import("c.zig").c;
const store = @import("store.zig");
const bar = @import("bar.zig");

pub const App = struct {
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    exec: [240]u8 = undefined,
    exec_len: u8 = 0,
    terminal: bool = false,
    hash: u64 = 0,

    pub fn nameS(a: *const App) []const u8 {
        return a.name[0..a.name_len];
    }
    pub fn execS(a: *const App) []const u8 {
        return a.exec[0..a.exec_len];
    }
};

const Usage = struct { hash: u64, n: u32 };
const max_usage = 256;

pub const Db = struct {
    list: std.ArrayList(App) = .empty,
    usage: [max_usage]Usage = undefined,
    n_usage: usize = 0,

    pub fn load(db: *Db) void {
        const gpa = std.heap.c_allocator;
        // User dir first so its entries win over system duplicates.
        if (c.getenv("HOME")) |home| {
            var path: [512]u8 = undefined;
            if (std.fmt.bufPrintZ(&path, "{s}/.local/share/applications", .{std.mem.span(home)})) |p| {
                db.scanDir(gpa, p);
            } else |_| {}
        }
        inline for (.{ "/usr/local/share/applications", "/usr/share/applications", "/var/lib/flatpak/exports/share/applications" }) |dir| {
            db.scanDir(gpa, dir);
        }
        db.loadUsage();
    }

    pub fn deinit(db: *Db) void {
        db.list.deinit(std.heap.c_allocator);
        db.list = .empty;
    }

    fn scanDir(db: *Db, gpa: std.mem.Allocator, dir_path: [*:0]const u8) void {
        const dir = c.opendir(dir_path) orelse return;
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
            if (!std.mem.endsWith(u8, name, ".desktop")) continue;
            var pbuf: [768]u8 = undefined;
            const full = std.fmt.bufPrintZ(&pbuf, "{s}/{s}", .{ std.mem.span(dir_path), name }) catch continue;
            var fbuf: [12288]u8 = undefined;
            const data = bar.readFile(full, &fbuf);
            const app = parseDesktop(data) orelse continue;
            var dup = false;
            for (db.list.items) |x| if (x.hash == app.hash) {
                dup = true;
            };
            if (!dup) db.list.append(gpa, app) catch return;
        }
    }

    // ---- usage counts, persisted as "<hash hex> <count>" lines ----

    fn usagePath(buf: []u8) ?[:0]const u8 {
        const home = c.getenv("HOME") orelse return null;
        return std.fmt.bufPrintZ(buf, "{s}/.cache/wm-launcher", .{std.mem.span(home)}) catch null;
    }

    fn loadUsage(db: *Db) void {
        db.n_usage = 0;
        var pb: [256]u8 = undefined;
        const path = usagePath(&pb) orelse return;
        var buf: [6144]u8 = undefined;
        const data = bar.readFile(path, &buf);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            const h = it.next() orelse continue;
            const n = it.next() orelse continue;
            if (db.n_usage >= max_usage) break;
            db.usage[db.n_usage] = .{
                .hash = std.fmt.parseInt(u64, h, 16) catch continue,
                .n = std.fmt.parseInt(u32, n, 10) catch continue,
            };
            db.n_usage += 1;
        }
    }

    pub fn uses(db: *const Db, hash: u64) u32 {
        for (db.usage[0..db.n_usage]) |u| if (u.hash == hash) return u.n;
        return 0;
    }

    pub fn bump(db: *Db, hash: u64) void {
        var found = false;
        for (db.usage[0..db.n_usage]) |*u| if (u.hash == hash) {
            u.n += 1;
            found = true;
        };
        if (!found) {
            if (db.n_usage == max_usage) { // drop the least used
                var lo: usize = 0;
                for (db.usage[0..db.n_usage], 0..) |u, i| if (u.n < db.usage[lo].n) {
                    lo = i;
                };
                db.usage[lo] = .{ .hash = hash, .n = 1 };
            } else {
                db.usage[db.n_usage] = .{ .hash = hash, .n = 1 };
                db.n_usage += 1;
            }
        }
        db.saveUsage();
    }

    fn saveUsage(db: *Db) void {
        var pb: [256]u8 = undefined;
        const path = usagePath(&pb) orelse return;
        const fd = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
        if (fd < 0) return;
        defer _ = c.close(fd);
        var line: [48]u8 = undefined;
        for (db.usage[0..db.n_usage]) |u| {
            const s = std.fmt.bufPrint(&line, "{x} {d}\n", .{ u.hash, u.n }) catch continue;
            _ = c.write(fd, s.ptr, s.len);
        }
    }

    // ---- search ----

    pub const Match = struct { idx: u16, score: i32 };

    /// Best `out.len` apps for `query` (fuzzy), ordered by score; returns how many.
    pub fn search(db: *const Db, query: []const u8, out: []Match) usize {
        var n: usize = 0;
        for (db.list.items, 0..) |*app, i| {
            const base = if (query.len == 0) 0 else fuzzy(app.nameS(), query);
            if (base < 0) continue;
            const m = Match{ .idx = @intCast(i), .score = base + @as(i32, @intCast(@min(db.uses(app.hash), 20))) * 4 };
            // Insert into the sorted top list.
            var pos = n;
            while (pos > 0 and better(db, m, out[pos - 1])) pos -= 1;
            if (pos >= out.len) continue;
            if (n < out.len) n += 1;
            var k = n - 1;
            while (k > pos) : (k -= 1) out[k] = out[k - 1];
            out[pos] = m;
        }
        return n;
    }

    fn better(db: *const Db, a: Match, b: Match) bool {
        if (a.score != b.score) return a.score > b.score;
        return std.ascii.lessThanIgnoreCase(db.list.items[a.idx].nameS(), db.list.items[b.idx].nameS());
    }
};

/// Subsequence match, case-insensitive. -1 = no match. Rewards prefixes,
/// word starts and consecutive runs.
fn fuzzy(name: []const u8, q: []const u8) i32 {
    var score: i32 = 0;
    var pos: usize = 0;
    var run: i32 = 0;
    for (q) |qc| {
        const ql = std.ascii.toLower(qc);
        var found = false;
        while (pos < name.len) : (pos += 1) {
            if (std.ascii.toLower(name[pos]) != ql) {
                run = 0;
                continue;
            }
            run += 1;
            score += 10 + run * 5;
            if (pos == 0 or std.mem.indexOfScalar(u8, " -_.", name[pos - 1]) != null) score += 15;
            pos += 1;
            found = true;
            break;
        }
        if (!found) return -1;
    }
    if (name.len >= q.len and std.ascii.startsWithIgnoreCase(name, q)) score += 100;
    if (std.ascii.indexOfIgnoreCase(name, q) != null) score += 40;
    return score - @as(i32, @intCast(@min(name.len, 40)));
}

fn parseDesktop(data: []const u8) ?App {
    var app = App{};
    var in_entry = false;
    var seen_entry = false;
    var skip = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len > 0 and line[0] == '[') {
            in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            if (!in_entry and seen_entry) break;
            seen_entry = seen_entry or in_entry;
            continue;
        }
        if (!in_entry) continue;
        if (std.mem.startsWith(u8, line, "Name=") and app.name_len == 0) {
            app.name_len = store.sanitize(&app.name, line[5..]);
        } else if (std.mem.startsWith(u8, line, "Exec=")) {
            app.exec_len = cleanExec(&app.exec, line[5..]);
        } else if (std.mem.eql(u8, line, "NoDisplay=true") or std.mem.eql(u8, line, "Hidden=true")) {
            skip = true;
        } else if (std.mem.eql(u8, line, "Terminal=true")) {
            app.terminal = true;
        } else if (std.mem.startsWith(u8, line, "Type=") and !std.mem.eql(u8, line, "Type=Application")) {
            skip = true;
        }
    }
    if (skip or app.name_len == 0 or app.exec_len == 0) return null;
    app.hash = std.hash.Wyhash.hash(0, app.nameS());
    return app;
}

/// Drop field codes (%u, %F, ...) from an Exec= line; "%%" becomes "%".
fn cleanExec(dst: []u8, src: []const u8) u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len and n < dst.len) : (i += 1) {
        if (src[i] == '%' and i + 1 < src.len) {
            if (src[i + 1] == '%') {
                dst[n] = '%';
                n += 1;
            }
            i += 1;
            continue;
        }
        dst[n] = src[i];
        n += 1;
    }
    return @intCast(std.mem.trimEnd(u8, dst[0..n], " ").len);
}
