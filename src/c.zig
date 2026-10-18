pub const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/xcb_keysyms.h");
    @cInclude("xcb/shape.h");
    @cInclude("systemd/sd-bus.h");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
    @cInclude("stdlib.h");
    @cInclude("dirent.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("time.h");
    @cInclude("stdio.h");
    @cInclude("sys/wait.h");
});
