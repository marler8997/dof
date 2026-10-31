pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // not standardOptimizeOption, it defaults to debug and the install scripts
    // and self-update run a plain `zig build install`
    const optimize: std.builtin.Optimize = b.option(
        std.builtin.Optimize,
        "optimize",
        "Prioritize performance, safety, or binary size (default: safe)",
    ) orelse switch (b.graph.release_mode) {
        .off, .any, .safe => .safe,
        .fast => .fast,
        .small => .small,
    };

    const patched_std = b.dependency("patch", .{
        .std_patches = &[_]std.Build.LazyPath{
            b.path("src/windows-unexpected-error-message.patch"),
        },
    }).module("std");

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
            .imports = &.{.{ .name = "std", .module = patched_std }},
        }),
    });
    dof_exe.root_module.addOptions("build_options", build_options);
    if (maybe_sha == null) dof_exe.step.dependOn(
        &b.addFail("the dof exe requires the -Dsha=<sha> build option").step,
    );

    // const run = b.addRunArtifact(dof_exe);
    // if (b.args) |a| run.addArgs(a);
    // b.step("run", "").dependOn(&run.step);

    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dof.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "std", .module = patched_std }},
        }),
    });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(test_exe).step);

    {
        // the e2e tests always pass --no-update so the sha is never used
        const e2e_dof_options = b.addOptions();
        const zero_sha: [40]u8 = @splat('0');
        e2e_dof_options.addOption([40]u8, "sha", zero_sha);
        const e2e_dof = b.addExecutable(.{
            .name = "dof",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/dof.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "std", .module = patched_std }},
            }),
        });
        e2e_dof.root_module.addOptions("build_options", e2e_dof_options);
        const e2e_options = b.addOptions();
        e2e_options.addOptionPath("dof_exe", e2e_dof.getEmittedBin());
        const e2e_exe = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/e2e.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        e2e_exe.root_module.addOptions("e2e_options", e2e_options);
        b.step("e2e", "Run the end-to-end tests (needs git)").dependOn(&b.addRunArtifact(e2e_exe).step);
    }

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
        install_dof.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix } }, .{ .make_absolute = true });
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
