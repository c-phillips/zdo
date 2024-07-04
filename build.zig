const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{.preferred_optimize_mode = .ReleaseSafe});
    const exe = b.addExecutable(.{
        .name = "zdo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const install_step = b.addInstallArtifact(exe, .{});
    b.default_step.dependOn(&install_step.step,);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(&install_step.step);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
