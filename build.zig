pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dof_exe = b.addExecutable(.{
        .name = "dof",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dof.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const install = b.addInstallArtifact(dof_exe, .{});
    b.getInstallStep().dependOn(&install.step);

    const run = b.addRunArtifact(dof_exe);
    run.step.dependOn(&install.step);
    if (b.args) |a| run.addArgs(a);
    b.step("run", "").dependOn(&run.step);
}

fn validSha(sha: *const [40]u8) bool {
    for (sha) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

const builtin = @import("builtin");
const std = @import("std");
