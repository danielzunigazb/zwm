const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.linkSystemLibrary("xcb", .{});
    mod.linkSystemLibrary("xcb-keysyms", .{});
    mod.linkSystemLibrary("xcb-shape", .{});
    mod.linkSystemLibrary("libsystemd", .{}); // sd-bus

    const exe = b.addExecutable(.{ .name = "wm", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the WM (inside DISPLAY)").dependOn(&run.step);
}
