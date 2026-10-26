// Password check through PAM, using the same stack a console login uses (system-local-login).
// The password is handed to PAM and nothing here keeps a copy; PAM frees its own copy.

const std = @import("std");
const c = @import("c.zig").c;

const service = "system-local-login";

/// Name of the user running the WM (the account being unlocked).
pub fn user() ?[*:0]const u8 {
    const pw = c.getpwuid(c.getuid()) orelse return null;
    return pw.*.pw_name;
}

/// Answers every prompt PAM asks with the password. PAM takes ownership of what it gets back and
/// frees it, so the response is a fresh strdup, never a pointer into our buffer.
fn conv(num: c_int, msgs: [*c][*c]const c.struct_pam_message, out: [*c][*c]c.struct_pam_response, appdata: ?*anyopaque) callconv(.c) c_int {
    const pass: [*:0]const u8 = @ptrCast(appdata orelse return c.PAM_CONV_ERR);
    const n: usize = @intCast(num);
    const rs: [*]c.struct_pam_response = @ptrCast(@alignCast(c.calloc(n, @sizeOf(c.struct_pam_response)) orelse return c.PAM_BUF_ERR));
    for (0..n) |i| {
        const style = msgs[i].*.msg_style;
        if (style == c.PAM_PROMPT_ECHO_OFF or style == c.PAM_PROMPT_ECHO_ON) {
            rs[i].resp = c.strdup(pass);
            if (rs[i].resp == null) {
                freeResponses(rs, i); // PAM never saw these: they are ours to free
                return c.PAM_BUF_ERR;
            }
        }
    }
    out.* = rs;
    return c.PAM_SUCCESS;
}

/// Free the first `n` responses and the array, wiping each copy of the password first.
fn freeResponses(rs: [*]c.struct_pam_response, n: usize) void {
    for (rs[0..n]) |r| {
        if (r.resp) |p| {
            const len = c.strlen(p);
            @memset(p[0..len], 0);
            c.free(p);
        }
    }
    c.free(rs);
}

/// True when PAM accepts `who` with `pass`, both the authentication and the account checks.
/// Blocks for as long as PAM takes (a few ms for pam_unix).
pub fn check(who: [*:0]const u8, pass: [*:0]const u8) bool {
    var handle: ?*c.pam_handle_t = null;
    var cv = c.struct_pam_conv{ .conv = conv, .appdata_ptr = @constCast(pass) };
    if (c.pam_start(service, who, &cv, &handle) != c.PAM_SUCCESS) return false;
    var status: c_int = c.pam_authenticate(handle, 0);
    if (status == c.PAM_SUCCESS) status = c.pam_acct_mgmt(handle, 0);
    _ = c.pam_end(handle, status);
    return status == c.PAM_SUCCESS;
}
