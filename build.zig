pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const maybe_sha = b.option([]const u8, "sha", "The SHA to embed inside the exe");

    const build_options = b.addOptions();
    if (maybe_sha) |sha| {
        if (sha.len != 40) {
            std.log.err("invalid SHA '{s}' (must be exactly 40 chars)", .{sha});
            std.process.exit(0xff);
        }
        if (!validSha(sha[0..40])) {
            std.log.err("invalid SHA '{s}' (must only contain only '0'..'9' and 'a'..'f')", .{sha});
            std.process.exit(0xff);
        }
        build_options.addOption([40]u8, "sha", sha[0..40].*);
    }
    const dof_exe = b.addExecutable(.{
        .name = "dof",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dof.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dof_exe.root_module.addOptions("build_options", build_options);
    if (maybe_sha == null) dof_exe.step.dependOn(
        &b.addFail("the dof exe requires the -Dsha=<sha> build option").step,
    );

    // const run = b.addRunArtifact(dof_exe);
    // if (b.args) |a| run.addArgs(a);
    // b.step("run", "").dependOn(&run.step);

    // on windows, we use our own installer so we can overwrite the dof.exe while
    // it's running
    if (builtin.os.tag == .windows) {
        const install_exe = b.addExecutable(.{
            .name = "install",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/installwindows.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const install_dof = b.addRunArtifact(install_exe);
        install_dof.addArg("--prefix");
        install_dof.addArg(b.install_prefix);
        install_dof.addArg("--exe");
        install_dof.addArtifactArg(dof_exe);
        if (target.result.os.tag == .windows) {
            install_dof.addArg("--pdb");
            install_dof.addFileArg(dof_exe.getEmittedPdb());
        }
        b.getInstallStep().dependOn(&install_dof.step);
    } else {
        const install = b.addInstallArtifact(dof_exe, .{
            .dest_dir = .{ .override = .prefix },
        });
        // run.step.dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
    }
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
