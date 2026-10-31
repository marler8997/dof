//! End-to-end tests: run the dof exe against a throwaway dotfiles repo with a local bare
//! remote, a second clone standing in for another machine, and a temporary home directory.

test "no local changes fast-forwards and applies" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.commitAndPush("other", "a.txt", "2\n", "other change");

    _ = try f.expectDof(0, "", &.{});
    try f.expectFile("home/a.txt", "2\n");
    try f.expectSameCommit("repo", "HEAD", "remote.git", "main");
}

test "local changes are applied before asking, quit leaves them" {
    var f: Fixture = try .init();
    defer f.deinit();
    const initial = try f.revParse("remote.git", "main");
    try f.writeFile("repo/a.txt", "local\n");

    const result = try f.expectDof(0, "q\n", &.{});
    try expectContains(result.stderr, "[p]ush, [s]ave for later, [d]iscard, [q]uit?");
    try f.expectFile("home/a.txt", "local\n");
    try f.expectFile("repo/a.txt", "local\n");
    try std.testing.expectEqual(initial, try f.revParse("remote.git", "main"));
}

test "push commits, rebases onto the remote and pushes" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.commitAndPush("other", "b.txt", "other\n", "other change");
    try f.writeFile("repo/a.txt", "mine\n");

    _ = try f.expectDof(0, "p\nmy change\n", &.{});
    const log = try f.gitOutput("remote.git", &.{ "log", "--format=%s", "main" });
    defer gpa.free(log);
    try std.testing.expectEqualStrings("my change\nother change\ninit\n", log);
    try f.expectNoMerges("remote.git", "main");
    try f.expectFile("home/a.txt", "mine\n");
    try f.expectFile("home/b.txt", "other\n");
    try f.expectClean("repo");
}

test "unpushed commits with no uncommitted changes are pushed without a commit message" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.writeFile("repo/a.txt", "committed\n");
    try f.git("repo", &.{ "commit", "-am", "local commit" });

    const result = try f.expectDof(0, "p\n", &.{});
    try expectNotContains(result.stderr, "commit message:");
    try f.expectSameCommit("repo", "HEAD", "remote.git", "main");
    try f.expectFile("home/a.txt", "committed\n");
}

test "a conflicting rebase is aborted" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.commitAndPush("other", "a.txt", "other\n", "other change");
    const remote = try f.revParse("remote.git", "main");
    try f.writeFile("repo/a.txt", "mine\n");

    const result = try f.expectDof(null, "p\nmy change\n", &.{});
    try expectContains(result.stderr, "conflicted");
    try std.testing.expectEqual(remote, try f.revParse("remote.git", "main"));
    try f.expectGitOutput("repo", &.{ "log", "-1", "--format=%s" }, "my change\n");
    try f.expectNoRebaseInProgress("repo");
    try f.expectClean("repo");
}

test "save moves local commits and changes, including untracked files, to a branch" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.writeFile("repo/c.txt", "c\n");
    try f.git("repo", &.{ "add", "c.txt" });
    try f.git("repo", &.{ "commit", "-m", "local commit" });
    try f.writeFile("repo/a.txt", "saved\n");
    try f.writeFile("repo/u.txt", "untracked\n");
    try f.commitAndPush("other", "b.txt", "other\n", "other change");

    _ = try f.expectDof(0, "s\n", &.{});
    try f.expectSameCommit("repo", "HEAD", "remote.git", "main");
    try f.expectClean("repo");
    const saved = try f.gitOutput("repo", &.{ "branch", "--list", "--format=%(refname:short)", "dof-saved-*" });
    defer gpa.free(saved);
    const branch = std.mem.trimEnd(u8, saved, "\n");
    try std.testing.expect(std.mem.indexOfScalar(u8, branch, '\n') == null);
    var spec_buf: [200]u8 = undefined;
    try f.expectGitOutput("repo", &.{ "show", try std.fmt.bufPrint(&spec_buf, "{s}:a.txt", .{branch}) }, "saved\n");
    try f.expectGitOutput("repo", &.{ "show", try std.fmt.bufPrint(&spec_buf, "{s}:u.txt", .{branch}) }, "untracked\n");
    try f.expectGitOutput("repo", &.{ "show", try std.fmt.bufPrint(&spec_buf, "{s}:c.txt", .{branch}) }, "c\n");
    try f.expectFile("home/a.txt", "1\n");
    try f.expectFile("home/b.txt", "other\n");
}

test "discard replaces the previous discard" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.writeFile("repo/a.txt", "first\n");
    _ = try f.expectDof(0, "d\n", &.{});
    try f.writeFile("repo/a.txt", "second\n");
    try f.writeFile("repo/u.txt", "untracked\n");
    _ = try f.expectDof(0, "d\n", &.{});

    try f.expectGitOutput("repo", &.{ "show", "dof-discarded:a.txt" }, "second\n");
    try f.expectGitOutput("repo", &.{ "show", "dof-discarded:u.txt" }, "untracked\n");
    try f.expectGitOutput("repo", &.{ "rev-list", "--count", "main..dof-discarded" }, "1\n");
    try f.expectClean("repo");
    try f.expectFile("repo/a.txt", "1\n");
    try f.expectFile("home/a.txt", "1\n");
}

test "non-interactive refuses local changes before applying them" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.writeFile("repo/a.txt", "local\n");

    const result = try f.expectDof(null, "", &.{"--non-interactive"});
    try expectContains(result.stderr, "--non-interactive");
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "home/a.txt", .{}));
}

test "merge commits are flattened by the rebase" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.git("repo", &.{ "switch", "-c", "side" });
    try f.writeFile("repo/c.txt", "c\n");
    try f.git("repo", &.{ "add", "c.txt" });
    try f.git("repo", &.{ "commit", "-m", "side" });
    try f.git("repo", &.{ "switch", "main" });
    try f.writeFile("repo/d.txt", "d\n");
    try f.git("repo", &.{ "add", "d.txt" });
    try f.git("repo", &.{ "commit", "-m", "main" });
    try f.git("repo", &.{ "merge", "--no-ff", "side", "-m", "merge" });

    _ = try f.expectDof(0, "p\n", &.{});
    try f.expectNoMerges("remote.git", "main");
    try f.expectGitOutput("remote.git", &.{ "show", "main:c.txt" }, "c\n");
    try f.expectGitOutput("remote.git", &.{ "show", "main:d.txt" }, "d\n");
    try f.expectSameCommit("repo", "HEAD", "remote.git", "main");
}

test "a branch other than dof's is refused" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.git("repo", &.{ "switch", "-c", "side" });

    const result = try f.expectDof(null, "", &.{});
    try expectContains(result.stderr, "has 'side' checked out but dof's branch is 'main'");
}

test "small diffs are shown in full" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.writeFile("repo/a.txt", "small change\n");
    try f.writeFile("repo/u.txt", "new file\n");

    const result = try f.expectDof(0, "q\n", &.{});
    try expectContains(result.stdout, "+small change");
    try expectContains(result.stdout, "+new file");
    try expectNotContains(result.stderr, "[v]iew diff");
}

test "large diffs are shortened and view diff shows them in full" {
    var f: Fixture = try .init();
    defer f.deinit();
    var content: std.Io.Writer.Allocating = .init(gpa);
    defer content.deinit();
    for (0..100) |i| try content.writer.print("line {d}\n", .{i});
    try f.writeFile("repo/a.txt", content.written());
    try f.writeFile("repo/big.txt", content.written());

    const result = try f.expectDof(0, "v\nq\n", &.{});
    try expectContains(result.stderr, "[v]iew diff");
    try expectContains(result.stdout, "a.txt: +100 -1\n");
    try expectContains(result.stdout, "big.txt: new file, 100 lines\n");
    try expectContains(result.stdout, "+line 99");
}

test "path and branch replace their settings" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.commitAndPush("other", "a.txt", "2\n", "other change");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const other = try f.absPath(&path_buf, "other");
    const result = try f.expectDof(0, "", &.{ "path", other });
    try expectContains(result.stderr, "dof path updated from");
    try expectContains((try f.expectDof(0, "", &.{ "path", other })).stderr, "dof path already set");
    try expectContains((try f.expectDof(0, "", &.{ "branch", "main" })).stderr, "dof branch already set");
    try expectContains((try f.expectDof(0, "", &.{ "branch", "dev" })).stderr, "dof branch updated from 'main' to 'dev'");
    try expectContains((try f.expectDof(null, "", &.{})).stderr, "but dof's branch is 'dev'");
    _ = try f.expectDof(0, "", &.{ "branch", "main" });

    // applies from the new path, which has the change committed
    _ = try f.expectDof(0, "", &.{});
    try f.expectFile("home/a.txt", "2\n");

    var tmp_dir = try f.tmp.dir.openDir(io, app_data_sub_path ++ std.fs.path.sep_str ++ "tmp", .{ .iterate = true });
    defer tmp_dir.close(io);
    var it = tmp_dir.iterate();
    try std.testing.expectEqual(null, try it.next(io));
}

/// Where dof keeps its data given the fixture's environment.
const app_data_sub_path = switch (builtin.os.tag) {
    .windows => "localappdata\\dof",
    .macos => "home/Library/Application Support/dof",
    else => "home/.local/share/dof",
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    env: std.process.Environ.Map,
    dof_result: ?DofResult = null,

    const DofResult = struct { stdout: []u8, stderr: []u8 };

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try gpa.dupe(u8, path_buf[0..try tmp.dir.realPath(io, &path_buf)]);
        errdefer gpa.free(root);

        var env = try std.testing.environ.createMap(gpa);
        errdefer env.deinit();
        const home = try std.fs.path.join(gpa, &.{ root, "home" });
        defer gpa.free(home);
        try env.put("HOME", home);
        try env.put("USERPROFILE", home);
        try env.put("XDG_DATA_HOME", ""); // dof treats empty as unset
        const local_app_data = try std.fs.path.join(gpa, &.{ root, "localappdata" });
        defer gpa.free(local_app_data);
        try env.put("LOCALAPPDATA", local_app_data);
        const git_config = try std.fs.path.join(gpa, &.{ root, "gitconfig" });
        defer gpa.free(git_config);
        try env.put("GIT_CONFIG_GLOBAL", git_config);
        try env.put("GIT_CONFIG_NOSYSTEM", "1");

        var f: Fixture = .{ .tmp = tmp, .root = root, .env = env };
        try f.tmp.dir.createDirPath(io, "home");
        try f.tmp.dir.createDirPath(io, "localappdata");
        try f.writeFile("gitconfig",
            \\[init]
            \\    defaultBranch = main
            \\[user]
            \\    name = dof test
            \\    email = test@dof.invalid
            \\[advice]
            \\    detachedHead = false
            \\
        );

        try f.git(".", &.{ "init", "--bare", "remote.git" });
        try f.git(".", &.{ "clone", "remote.git", "seed" });
        try f.writeFile("seed/config.dof", "install-home a.txt\ninstall-home b.txt\n");
        try f.writeFile("seed/a.txt", "1\n");
        try f.writeFile("seed/b.txt", "1\n");
        try f.git("seed", &.{ "add", "." });
        try f.git("seed", &.{ "commit", "-m", "init" });
        try f.git("seed", &.{ "push", "origin", "main" });
        try f.git(".", &.{ "clone", "remote.git", "repo" });
        try f.git(".", &.{ "clone", "remote.git", "other" });

        const repo = try std.fs.path.join(gpa, &.{ root, "repo" });
        defer gpa.free(repo);
        _ = try f.expectDof(0, "", &.{ "path", repo });
        _ = try f.expectDof(0, "", &.{ "branch", "main" });
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.freeDofResult();
        f.env.deinit();
        gpa.free(f.root);
        f.tmp.cleanup();
    }

    fn freeDofResult(f: *Fixture) void {
        if (f.dof_result) |r| {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
            f.dof_result = null;
        }
    }

    fn absPath(f: *Fixture, buf: []u8, sub_path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ f.root, sub_path });
    }

    fn writeFile(f: *Fixture, sub_path: []const u8, data: []const u8) !void {
        try f.tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    }

    fn expectFile(f: *Fixture, sub_path: []const u8, expected: []const u8) !void {
        const actual = try f.tmp.dir.readFileAlloc(io, sub_path, gpa, .limited(1024 * 1024));
        defer gpa.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }

    /// Runs dof with --no-update, `stdin` as its input, and returns its output, which
    /// stays valid until the next call. A null `expected_code` expects any failure.
    fn expectDof(f: *Fixture, expected_code: ?u8, stdin: []const u8, args: []const []const u8) !DofResult {
        f.freeDofResult();
        var argv_buf: [10][]const u8 = undefined;
        argv_buf[0] = e2e_options.dof_exe;
        argv_buf[1] = "--no-update";
        @memcpy(argv_buf[2..][0..args.len], args);
        const argv = argv_buf[0 .. 2 + args.len];

        const stdout_file = try f.tmp.dir.createFile(io, "dof-stdout", .{ .read = true });
        defer stdout_file.close(io);
        const stderr_file = try f.tmp.dir.createFile(io, "dof-stderr", .{ .read = true });
        defer stderr_file.close(io);
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .environ_map = &f.env,
            .stdin = .pipe,
            .stdout = .{ .file = stdout_file },
            .stderr = .{ .file = stderr_file },
        });
        try child.stdin.?.writeStreamingAll(io, stdin);
        child.stdin.?.close(io);
        child.stdin = null;
        const term = try child.wait(io);

        const result: DofResult = .{
            .stdout = try f.tmp.dir.readFileAlloc(io, "dof-stdout", gpa, .limited(10 * 1024 * 1024)),
            .stderr = try f.tmp.dir.readFileAlloc(io, "dof-stderr", gpa, .limited(10 * 1024 * 1024)),
        };
        f.dof_result = result;
        const ok = switch (term) {
            .exited => |code| if (expected_code) |expected| code == expected else code != 0,
            else => false,
        };
        if (!ok) {
            std.debug.print("dof {f} expected exit code {?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ term, expected_code, result.stdout, result.stderr });
            return error.TestUnexpectedResult;
        }
        return result;
    }

    fn git(f: *Fixture, cwd: []const u8, args: []const []const u8) !void {
        gpa.free(try f.gitOutput(cwd, args));
    }

    fn gitOutput(f: *Fixture, cwd: []const u8, args: []const []const u8) ![]u8 {
        var argv_buf: [12][]const u8 = undefined;
        argv_buf[0] = "git";
        @memcpy(argv_buf[1..][0..args.len], args);
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const result = try std.process.run(gpa, io, .{
            .argv = argv_buf[0 .. 1 + args.len],
            .cwd = .{ .path = try f.absPath(&cwd_buf, cwd) },
            .environ_map = &f.env,
        });
        defer gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return result.stdout,
            else => {},
        }
        defer gpa.free(result.stdout);
        std.debug.print("git {f} in '{s}' failed with {f}\nstdout:\n{s}\nstderr:\n{s}\n", .{ fmtArgs(args), cwd, result.term, result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }

    /// A null `expected` only checks that git succeeds.
    fn expectGitOutput(f: *Fixture, cwd: []const u8, args: []const []const u8, expected: ?[]const u8) !void {
        const output = try f.gitOutput(cwd, args);
        defer gpa.free(output);
        if (expected) |e| try std.testing.expectEqualStrings(e, output);
    }

    fn revParse(f: *Fixture, cwd: []const u8, rev: []const u8) ![40]u8 {
        const output = try f.gitOutput(cwd, &.{ "rev-parse", "--verify", rev });
        defer gpa.free(output);
        const sha = std.mem.trimEnd(u8, output, "\n");
        try std.testing.expectEqual(40, sha.len);
        return sha[0..40].*;
    }

    fn expectSameCommit(f: *Fixture, a_cwd: []const u8, a_rev: []const u8, b_cwd: []const u8, b_rev: []const u8) !void {
        try std.testing.expectEqual(try f.revParse(a_cwd, a_rev), try f.revParse(b_cwd, b_rev));
    }

    fn expectClean(f: *Fixture, cwd: []const u8) !void {
        try f.expectGitOutput(cwd, &.{ "status", "--porcelain" }, "");
    }

    fn expectNoMerges(f: *Fixture, cwd: []const u8, rev: []const u8) !void {
        try f.expectGitOutput(cwd, &.{ "rev-list", "--merges", rev }, "");
    }

    fn expectNoRebaseInProgress(f: *Fixture, cwd: []const u8) !void {
        for ([_][]const u8{ "rebase-merge", "rebase-apply" }) |name| {
            const output = try f.gitOutput(cwd, &.{ "rev-parse", "--git-path", name });
            defer gpa.free(output);
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ try f.absPath(&dir_buf, cwd), std.mem.trimEnd(u8, output, "\n") });
            try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
        }
    }

    fn commitAndPush(f: *Fixture, clone: []const u8, file: []const u8, content: []const u8, msg: []const u8) !void {
        var path_buf: [200]u8 = undefined;
        try f.writeFile(try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ clone, file }), content);
        try f.git(clone, &.{ "add", file });
        try f.git(clone, &.{ "commit", "-m", msg });
        try f.git(clone, &.{ "push", "origin", "main" });
    }
};

fn fmtArgs(args: []const []const u8) FmtArgs {
    return .{ .args = args };
}
const FmtArgs = struct {
    args: []const []const u8,
    pub fn format(f: FmtArgs, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (f.args, 0..) |arg, i| try w.print("{s}{s}", .{ if (i == 0) "" else " ", arg });
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("expected not to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

const gpa = std.testing.allocator;
const io = std.testing.io;

const builtin = @import("builtin");
const e2e_options = @import("e2e_options");
const std = @import("std");
