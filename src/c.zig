pub const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/xcb_keysyms.h");
    @cInclude("xcb/shape.h");
    @cInclude("systemd/sd-bus.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("time.h");
    @cInclude("stdio.h");
    @cInclude("sys/wait.h");
});
