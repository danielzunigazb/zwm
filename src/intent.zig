// Music commands typed into the launcher ("pon cerati", "pausa", "siguiente"). Pure text parsing:
// the actual work is done by the zwm-music helper, which talks to Spotify Connect and so reaches
// whatever device is playing (the phone, not necessarily this machine).

const std = @import("std");

pub const Kind = enum { play, album, pause, resume_, next, prev };

pub const Intent = struct {
    kind: Kind,
    arg: []const u8 = "", // what to search for; borrowed from the input

    pub fn verb(i: Intent) []const u8 {
        return switch (i.kind) {
            .play => "play",
            .album => "album",
            .pause => "pause",
            .resume_ => "resume",
            .next => "next",
            .prev => "prev",
        };
    }

    pub fn takesArg(i: Intent) bool {
        return i.kind == .play or i.kind == .album;
    }
};

const play_words = [_][]const u8{ "pon", "pone", "ponme", "poneme", "play", "reproduce", "reproduci", "toca", "toc" };
const articles = [_][]const u8{ "la", "el", "una", "un", "mi", "algo" };
const song_words = [_][]const u8{ "cancion", "tema", "musica", "rola" };
const album_words = [_][]const u8{ "disco", "album" };

const singles = [_]struct { word: []const u8, kind: Kind }{
    .{ .word = "pausa", .kind = .pause },
    .{ .word = "pausar", .kind = .pause },
    .{ .word = "pause", .kind = .pause },
    .{ .word = "stop", .kind = .pause },
    .{ .word = "para", .kind = .pause },
    .{ .word = "sigue", .kind = .resume_ },
    .{ .word = "continua", .kind = .resume_ },
    .{ .word = "reanuda", .kind = .resume_ },
    .{ .word = "resume", .kind = .resume_ },
    .{ .word = "play", .kind = .resume_ },
    .{ .word = "siguiente", .kind = .next },
    .{ .word = "proxima", .kind = .next },
    .{ .word = "next", .kind = .next },
    .{ .word = "skip", .kind = .next },
    .{ .word = "salta", .kind = .next },
    .{ .word = "anterior", .kind = .prev },
    .{ .word = "previa", .kind = .prev },
    .{ .word = "prev", .kind = .prev },
    .{ .word = "atras", .kind = .prev },
};

fn oneOf(list: []const []const u8, w: []const u8) bool {
    for (list) |x| if (std.ascii.eqlIgnoreCase(x, w)) return true;
    return false;
}

const Split = struct { word: []const u8, rest: []const u8 };

/// Split off the first space-separated word; `rest` has its leading spaces trimmed.
fn nextWord(s: []const u8) Split {
    const t = std.mem.trimStart(u8, s, " ");
    const end = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
    return .{ .word = t[0..end], .rest = std.mem.trimStart(u8, t[end..], " ") };
}

/// Interpret `query` as a music command, or null when it is an ordinary launcher search.
/// Matching is ASCII and case-insensitive; the launcher cannot type accents, so "pone" is "poné".
pub fn parse(query: []const u8) ?Intent {
    const q = std.mem.trim(u8, query, " ");
    if (q.len == 0) return null;

    const head = nextWord(q);
    if (head.rest.len == 0) {
        for (singles) |s| if (std.ascii.eqlIgnoreCase(s.word, head.word)) return .{ .kind = s.kind };
        return null;
    }
    if (!oneOf(&play_words, head.word)) return null;

    // Filler between the verb and the thing: "la cancion X", "el disco X", "algo de X", "tema X".
    // An article alone is not filler: "pon la camisa negra" is a title.
    var kind: Kind = .play;
    var rest = head.rest;
    const w1 = nextWord(rest);
    if (oneOf(&articles, w1.word)) {
        const w2 = nextWord(w1.rest);
        if (oneOf(&song_words, w2.word)) {
            rest = w2.rest;
        } else if (oneOf(&album_words, w2.word)) {
            rest = w2.rest;
            kind = .album;
        } else if (std.ascii.eqlIgnoreCase(w1.word, "algo") and std.ascii.eqlIgnoreCase(w2.word, "de")) {
            rest = w2.rest;
        }
    } else if (oneOf(&song_words, w1.word)) {
        rest = w1.rest;
    } else if (oneOf(&album_words, w1.word)) {
        rest = w1.rest;
        kind = .album;
    }

    // "pon el disco de X": the "de" belongs to the phrasing, not the name.
    if (kind == .album) {
        const w = nextWord(rest);
        if (std.ascii.eqlIgnoreCase(w.word, "de") and w.rest.len > 0) rest = w.rest;
    }

    if (rest.len == 0) return null;
    return .{ .kind = kind, .arg = rest };
}

/// `zwm-music VERB 'ARG'` for sh -c, with the argument single-quoted so nothing typed is ever
/// interpreted by the shell. Null when it does not fit in `buf`.
pub fn command(buf: [:0]u8, i: Intent) ?[*:0]const u8 {
    var w = std.Io.Writer.fixed(buf[0 .. buf.len - 1]);
    w.print("zwm-music {s}", .{i.verb()}) catch return null;
    if (i.takesArg()) {
        w.writeAll(" '") catch return null;
        for (i.arg) |ch| {
            if (ch == '\'') w.writeAll("'\\''") catch return null else w.writeByte(ch) catch return null;
        }
        w.writeAll("'") catch return null;
    }
    buf[w.end] = 0;
    return @ptrCast(buf.ptr);
}

test "play with filler words" {
    const t = std.testing;
    const a = parse("pon cerati cuando pase el temblor").?;
    try t.expectEqual(Kind.play, a.kind);
    try t.expectEqualStrings("cerati cuando pase el temblor", a.arg);

    try t.expectEqualStrings("la camisa negra", parse("pon la camisa negra").?.arg); // "la" is part of the title
    try t.expectEqualStrings("Bohemian Rhapsody", parse("Pon la cancion Bohemian Rhapsody").?.arg);
    try t.expectEqualStrings("soda stereo", parse("pon algo de soda stereo").?.arg);
    try t.expectEqualStrings("de musica ligera", parse("pon de musica ligera").?.arg); // title starting with "de"
    try t.expectEqualStrings("x", parse("  poneme   el tema   x ").?.arg);
}

test "albums" {
    const a = parse("pon el disco de Gustavo Cerati").?;
    try std.testing.expectEqual(Kind.album, a.kind);
    try std.testing.expectEqualStrings("Gustavo Cerati", a.arg);
    try std.testing.expectEqual(Kind.album, parse("pon disco abbey road").?.kind);
}

test "single-word controls" {
    const t = std.testing;
    try t.expectEqual(Kind.pause, parse("pausa").?.kind);
    try t.expectEqual(Kind.resume_, parse("PLAY").?.kind);
    try t.expectEqual(Kind.next, parse(" siguiente ").?.kind);
    try t.expectEqual(Kind.prev, parse("anterior").?.kind);
}

test "ordinary searches stay searches" {
    const t = std.testing;
    try t.expect(parse("") == null);
    try t.expect(parse("firefox") == null);
    try t.expect(parse("pon") == null); // nothing to play yet
    try t.expect(parse("pon el disco") == null);
    try t.expect(parse("pausa algo") == null); // controls take no argument
    try t.expect(parse("2+2") == null);
}

test "command quoting" {
    var buf: [128:0]u8 = undefined;
    const cmd = command(&buf, .{ .kind = .play, .arg = "it's $(rm -rf ~) `x`" }).?;
    try std.testing.expectEqualStrings("zwm-music play 'it'\\''s $(rm -rf ~) `x`'", std.mem.span(cmd));
    const p = command(&buf, .{ .kind = .pause }).?;
    try std.testing.expectEqualStrings("zwm-music pause", std.mem.span(p));
    var tiny: [20:0]u8 = undefined;
    try std.testing.expect(command(&tiny, .{ .kind = .play, .arg = "this will not fit" }) == null);
}
