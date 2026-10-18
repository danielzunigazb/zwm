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

    const exe = b.addExecutable(.{ .name = "wm", .root_module = mod });
    b.installArtifact(exe);

    // `zig build test` runs the pure-logic unit tests (calculator, sanitizer, fuzzy search, ...).
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the WM (inside DISPLAY)").dependOn(&run.step);
}
