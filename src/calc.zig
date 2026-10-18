// Tiny expression evaluator for the launcher: + - * / % ^, unary minus, parentheses.

const std = @import("std");

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    bad: bool = false,

    fn peek(p: *Parser) u8 {
        while (p.i < p.s.len and p.s[p.i] == ' ') p.i += 1;
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    fn expr(p: *Parser) f64 {
        var v = p.term();
        while (true) {
            switch (p.peek()) {
                '+' => {
                    p.i += 1;
                    v += p.term();
                },
                '-' => {
                    p.i += 1;
                    v -= p.term();
                },
                else => return v,
            }
        }
    }

    fn term(p: *Parser) f64 {
        var v = p.power();
        while (true) {
            switch (p.peek()) {
                '*', 'x' => {
                    p.i += 1;
                    v *= p.power();
                },
                '/' => {
                    p.i += 1;
                    v /= p.power();
                },
                '%' => {
                    p.i += 1;
                    v = @mod(v, p.power());
                },
                else => return v,
            }
        }
    }

    fn power(p: *Parser) f64 {
        const base = p.unary();
        if (p.peek() == '^') {
            p.i += 1;
            return std.math.pow(f64, base, p.power()); // right associative
        }
        return base;
    }

    fn unary(p: *Parser) f64 {
        switch (p.peek()) {
            '-' => {
                p.i += 1;
                return -p.unary();
            },
            '+' => {
                p.i += 1;
                return p.unary();
            },
            else => return p.primary(),
        }
    }

    fn primary(p: *Parser) f64 {
        const ch = p.peek();
        if (ch == '(') {
            p.i += 1;
            const v = p.expr();
            if (p.peek() != ')') p.bad = true else p.i += 1;
            return v;
        }
        const start = p.i;
        while (p.i < p.s.len and (std.ascii.isDigit(p.s[p.i]) or p.s[p.i] == '.')) p.i += 1;
        if (p.i == start) {
            p.bad = true;
            return 0;
        }
        return std.fmt.parseFloat(f64, p.s[start..p.i]) catch blk: {
            p.bad = true;
            break :blk 0;
        };
    }
};

/// Returns the value if `s` is a complete arithmetic expression that actually
/// computes something (a bare number is not, so plain app searches stay apps).
pub fn eval(s: []const u8) ?f64 {
    const q = std.mem.trim(u8, s, " ");
    if (q.len < 3) return null;
    var has_digit = false;
    var has_op = false;
    for (q, 0..) |ch, i| {
        if (std.ascii.isDigit(ch)) has_digit = true;
        if (std.mem.indexOfScalar(u8, "+*/^%x(", ch) != null or (ch == '-' and i > 0)) has_op = true;
        if (std.mem.indexOfScalar(u8, "0123456789+-*/^%x(). ", ch) == null) return null;
    }
    if (!has_digit or !has_op) return null;
    var p = Parser{ .s = q };
    const v = p.expr();
    if (p.bad or p.peek() != 0 or !std.math.isFinite(v)) return null;
    return v;
}

/// Format without float noise (0.1+0.2 -> 0.3).
pub fn format(buf: []u8, v: f64) []const u8 {
    const r = @round(v * 1e9) / 1e9;
    return std.fmt.bufPrint(buf, "{d}", .{r}) catch "?";
}

test "arithmetic" {
    try std.testing.expectEqual(@as(?f64, 7), eval("1+2*3"));
    try std.testing.expectEqual(@as(?f64, 9), eval("(1+2)*3"));
    try std.testing.expectEqual(@as(?f64, 512), eval("2^3^2"));
    try std.testing.expectEqual(@as(?f64, 42), eval("6x7"));
    try std.testing.expectEqual(@as(?f64, -1), eval("2-3"));
    try std.testing.expectEqual(@as(?f64, 1), eval("10%3"));
}

test "rejects what is not a calculation" {
    try std.testing.expectEqual(@as(?f64, null), eval("firefox"));
    try std.testing.expectEqual(@as(?f64, null), eval("42")); // bare number stays an app search
    try std.testing.expectEqual(@as(?f64, null), eval("1/0"));
    try std.testing.expectEqual(@as(?f64, null), eval("(1+2"));
    try std.testing.expectEqual(@as(?f64, null), eval("1++"));
    try std.testing.expectEqual(@as(?f64, null), eval("x2"));
    try std.testing.expectEqual(@as(?f64, null), eval("9^9^9^9"));
}

test "format hides float noise" {
    var b: [48]u8 = undefined;
    try std.testing.expectEqualStrings("0.3", format(&b, 0.1 + 0.2));
    try std.testing.expectEqualStrings("42", format(&b, 42));
}
