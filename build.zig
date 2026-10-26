const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // One thread, no debug info in release: smaller binary, nothing to map at startup.
        .single_threaded = true,
        .strip = optimize != .Debug,
        .unwind_tables = if (optimize == .Debug) null else .none,
    });
    // ReleaseSafe turns on glibc's fortify wrappers, which translate-c cannot import.
    mod.addCMacro("_FORTIFY_SOURCE", "0");
    mod.linkSystemLibrary("xcb", .{});
    mod.linkSystemLibrary("xcb-keysyms", .{});
    mod.linkSystemLibrary("xcb-shape", .{});
    mod.linkSystemLibrary("libsystemd", .{}); // sd-bus
    mod.linkSystemLibrary("freetype2", .{});
    mod.linkSystemLibrary("pam", .{}); // lock screen password check

    const exe = b.addExecutable(.{ .name = "wm", .root_module = mod });
    b.installArtifact(exe);

    // The Spotify watcher the WM starts: a static musl binary (no glibc to map, no dynamic loader),
    // single-threaded, nothing but std. ReleaseSmall: ~1 MB resident vs ~1.9 MB in ReleaseSafe, and it
    // only parses replies from api.spotify.com over verified TLS.
    const watch = b.addExecutable(.{ .name = "zwm-watch", .root_module = b.createModule(.{
        .root_source_file = b.path("src/watch.zig"),
        .target = b.resolveTargetQuery(.{ .abi = .musl }),
        .optimize = .ReleaseSmall,
        .link_libc = true,
        .single_threaded = true,
        .strip = true,
        .unwind_tables = .none,
    }) });
    b.installArtifact(watch);

    // `zig build test` runs the pure-logic unit tests (calculator, sanitizer, fuzzy search, ...).
    const tests = b.addTest(.{ .root_module = mod });
    // The watcher's tests run with safety checks on, unlike the shipped ReleaseSmall binary.
    const watch_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/watch.zig"),
        .target = b.resolveTargetQuery(.{ .abi = .musl }),
        .optimize = optimize,
        .link_libc = true,
        .single_threaded = true,
    }) });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(watch_tests).step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the WM (inside DISPLAY)").dependOn(&run.step);
}
