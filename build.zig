const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Headers come from the host; the ABI comes from sysroot/, which holds the
    // device's own .so files. Anything newer than the device's libraries then
    // fails at link time here rather than at runtime on the handheld.
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/dbus-1.0" });
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/lib/dbus-1.0/include" });
    mod.addLibraryPath(b.path("sysroot"));
    mod.linkSystemLibrary("SDL2", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("SDL2_ttf", .{ .use_pkg_config = .no });
    // Fix round 2, finding M9: SDL2_image was linked (and `make sysroot`
    // pulled it from the device) with nothing in `src/` ever calling an
    // `IMG_*` function - a runtime dependency for nothing.
    mod.linkSystemLibrary("dbus-1", .{ .use_pkg_config = .no });

    const exe = b.addExecutable(.{ .name = "btui", .root_module = mod });
    b.installArtifact(exe);

    // Host tests: pure parsing only, no device libraries.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_all.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run host unit tests").dependOn(&b.addRunArtifact(tests).step);
}
