pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_state.allocator();

    const SubCommand = union(enum) {
        none,
        path: []const u8,
        branch: []const u8,
    };
    const opt: struct {
        update: bool,
        interactive: bool,
        sub_command: SubCommand,
    } = blk: {
        var update: bool = true;
        var interactive: bool = true;
        var sub_command: SubCommand = .none;
        var arg_it = switch (builtin.os.tag) {
            .windows => try std.process.argsWithAllocator(arena),
            else => std.process.args(),
        };
        _ = arg_it.next();
        while (arg_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--no-update")) {
                update = false;
            } else if (std.mem.eql(u8, arg, "--non-interactive")) {
                interactive = false;
            } else if (std.mem.eql(u8, arg, "path")) {
                if (sub_command != .none) errExit("cannot specify both '{t}' and 'path'", .{sub_command});
                const path_arg = arg_it.next() orelse errExit("the 'path' subcommand requires an argument", .{});
                if (std.mem.startsWith(u8, path_arg, "-")) errExit("expected a path but got '{s}'", .{path_arg});
                sub_command = .{ .path = path_arg };
            } else if (std.mem.eql(u8, arg, "branch")) {
                if (sub_command != .none) errExit("cannot specify both '{t}' and 'branch'", .{sub_command});
                const branch_arg = arg_it.next() orelse errExit("the 'branch' subcommand requires an argument", .{});
                if (std.mem.startsWith(u8, branch_arg, "-")) errExit("expected a branch but got '{s}'", .{branch_arg});
                sub_command = .{ .branch = branch_arg };
            } else errExit("unknown cmdline option '{s}'", .{arg});
        }
        break :blk .{
            .update = update,
            .interactive = interactive,
            .sub_command = sub_command,
        };
    };

    const app_data_path = try std.fs.getAppDataDir(arena, "dof");
    defer arena.free(app_data_path);
    // std.log.info("appdata '{s}'", .{app_data_path});
    std.debug.assert(std.fs.path.isAbsolute(app_data_path));
    try std.fs.cwd().makePath(app_data_path);

    if (opt.update) {
        const src = try std.fs.path.join(arena, &.{ app_data_path, "src" });
        defer arena.free(src);

        const src_lock_path = try std.mem.concat(arena, u8, &.{ src, ".lock" });
        defer arena.free(src_lock_path);

        const master = blk: {
            break :blk try fetchDofMaster(src, src_lock_path, arena);
        };
        if (!std.mem.eql(u8, &master, &build_options.sha)) {
            std.log.info("running: {s}", .{&build_options.sha});
            std.log.info("master : {s}", .{&master});
            try updateExecNoreturn(
                arena,
                src,
                src_lock_path,
                &master,
            );
        }
        std.log.info("already running master ({s})", .{&build_options.sha});
    }

    return switch (opt.sub_command) {
        .none => try defaultCommand(arena, opt.interactive, app_data_path),
        .path => |path| try pathCommand(arena, app_data_path, path),
        .branch => |branch| try branchCommand(arena, app_data_path, branch),
    };
}

fn defaultCommand(arena: std.mem.Allocator, interactive: bool, app_data_path: []const u8) !void {
    const repo_path = blk_repo_path: {
        const app_data_repo = try std.fs.path.join(arena, &.{ app_data_path, "repo" });
        defer arena.free(app_data_repo);
        const repo_config_lock_path = try std.mem.concat(arena, u8, &.{ app_data_repo, ".lock" });
        defer arena.free(repo_config_lock_path);
        var repo_config_lock = try LockFile.lock(repo_config_lock_path);
        defer repo_config_lock.unlock();
        const path = blk: {
            const file = std.fs.openFileAbsolute(app_data_repo, .{}) catch |err| switch (err) {
                error.FileNotFound => errExit("NO PATH! set a path with: dof path PATH", .{}),
                else => |e| return e,
            };
            defer file.close();
            break :blk try file.readToEndAlloc(arena, 2000);
        };
        if (try dofPathProblem(path)) |problem| errExit(
            "dof path '{s}' {s} (read from '{s}')",
            .{ path, problem, app_data_repo },
        );
        break :blk_repo_path path;
    };
    defer arena.free(repo_path);

    const branch: []const u8 = blk: {
        const app_data_branch = try std.fs.path.join(arena, &.{ app_data_path, "branch" });
        defer arena.free(app_data_branch);
        const branch_lock_path = try std.mem.concat(arena, u8, &.{ app_data_branch, ".lock" });
        defer arena.free(branch_lock_path);
        var branch_lock = try LockFile.lock(branch_lock_path);
        defer branch_lock.unlock();
        const file = std.fs.openFileAbsolute(app_data_branch, .{}) catch |err| switch (err) {
            error.FileNotFound => errExit("NO BRANCH! set a branch with: dof branch BRANCH", .{}),
            else => |e| return e,
        };
        defer file.close();
        break :blk try file.readToEndAlloc(arena, 2000);
    };
    defer arena.free(branch);

    const repo_lock_path = try std.mem.concat(arena, u8, &.{ repo_path, ".lock" });
    defer arena.free(repo_lock_path);
    const config_dof_path = try std.fs.path.join(arena, &.{ repo_path, "config.dof" });
    defer arena.free(config_dof_path);

    switch (try gitStatus(arena, repo_path)) {
        .dirty => {
            if (!interactive) errExit("repo is dirty and --non-interactive is preset", .{});
            std.log.info("repo is dirty", .{});
            {
                var repo_lock = try LockFile.lock(repo_lock_path);
                defer repo_lock.unlock();
                try runDof(arena, repo_path, config_dof_path);
            }
            switch (try prompt("dof changes applied, push?")) {
                .yes => {},
                .no => {
                    std.log.info("user answered no", .{});
                    std.process.exit(0xff);
                },
            }

            {
                var repo_lock = try LockFile.lock(repo_lock_path);
                defer repo_lock.unlock();
                try run(arena, &.{ "git", "-C", repo_path, "add", "-A" }, null);
                try run(arena, &.{ "git", "-C", repo_path, "diff", "--cached", "--stat" }, null);

                switch (try prompt("commit and push these changes?")) {
                    .yes => {},
                    .no => {
                        try run(arena, &.{ "git", "-C", repo_path, "reset" }, null);
                        std.log.info("changes left uncommitted", .{});
                        std.process.exit(0xff);
                    },
                }

                const commit_msg = try promptLine(arena, "commit message: ");
                defer arena.free(commit_msg);
                try run(arena, &.{ "git", "-C", repo_path, "commit", "-m", commit_msg }, null);
                try run(arena, &.{ "git", "-C", repo_path, "fetch", "origin", branch }, null);
                if (try runExitCode(arena, &.{ "git", "-C", repo_path, "rebase", "FETCH_HEAD" }, null) != 0) {
                    try run(arena, &.{ "git", "-C", repo_path, "rebase", "--abort" }, null);
                    errExit("rebase failed, resolve conflicts manually in '{s}'", .{repo_path});
                }
                // run dof again after rebase
                try runDof(arena, repo_path, config_dof_path);
                try run(arena, &.{ "git", "-C", repo_path, "push", "origin", branch }, null);
            }
        },
        .clean => {
            std.log.info("repo is clean", .{});
            var repo_lock = try LockFile.lock(repo_lock_path);
            defer repo_lock.unlock();
            try run(arena, &.{ "git", "-C", repo_path, "fetch", "origin", branch }, null);
            try run(arena, &.{ "git", "-C", repo_path, "reset", "--hard", "FETCH_HEAD" }, null);
            try runDof(arena, repo_path, config_dof_path);
        },
    }
}

fn pathCommand(arena: std.mem.Allocator, app_data_path: []const u8, path_raw: []const u8) !void {
    const path = std.mem.trimRight(u8, path_raw, switch (builtin.os.tag) {
        .windows => "/" ++ "\\",
        else => "/",
    });

    if (!std.fs.path.isAbsolute(path)) errExit("path '{s}' must be absolute", .{path});
    if (try dofPathProblem(path)) |problem| errExit("dof path '{s}' {s}", .{ path, problem });

    const app_data_repo = try std.fs.path.join(arena, &.{ app_data_path, "repo" });
    defer arena.free(app_data_repo);

    const repo_lock_path = try std.mem.concat(arena, u8, &.{ app_data_repo, ".lock" });
    defer arena.free(repo_lock_path);

    var repo_lock = try LockFile.lock(repo_lock_path);
    defer repo_lock.unlock();

    const current_path: ?[]const u8 = blk: {
        const file = std.fs.openFileAbsolute(app_data_repo, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk null,
            else => |e| return e,
        };
        defer file.close();
        break :blk try file.readToEndAlloc(arena, 2000);
    };
    defer if (current_path) |p| arena.free(p);
    if (current_path) |p| {
        if (std.mem.eql(u8, p, path)) {
            std.log.info("dof path already set to '{s}'", .{path});
            std.process.exit(0);
        }
    }

    {
        var file = try std.fs.createFileAbsolute(app_data_repo, .{});
        defer file.close();
        var file_writer = file.writer(&.{});
        file_writer.interface.writeAll(path) catch return file_writer.err.?;
    }

    if (current_path) |p|
        std.log.info("dof path updated from '{s}' to '{s}'", .{ p, path })
    else
        std.log.info("dof path newly set to '{s}'", .{path});
}

fn branchCommand(arena: std.mem.Allocator, app_data_path: []const u8, branch: []const u8) !void {
    const app_data_branch = try std.fs.path.join(arena, &.{ app_data_path, "branch" });
    defer arena.free(app_data_branch);

    const branch_lock_path = try std.mem.concat(arena, u8, &.{ app_data_branch, ".lock" });
    defer arena.free(branch_lock_path);

    var branch_lock = try LockFile.lock(branch_lock_path);
    defer branch_lock.unlock();

    const current_branch: ?[]const u8 = blk: {
        const file = std.fs.openFileAbsolute(app_data_branch, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk null,
            else => |e| return e,
        };
        defer file.close();
        break :blk try file.readToEndAlloc(arena, 2000);
    };
    defer if (current_branch) |p| arena.free(p);
    if (current_branch) |p| {
        if (std.mem.eql(u8, p, branch)) {
            std.log.info("dof branch already set to '{s}'", .{branch});
            std.process.exit(0);
        }
    }

    {
        var file = try std.fs.createFileAbsolute(app_data_branch, .{});
        defer file.close();
        var file_writer = file.writer(&.{});
        file_writer.interface.writeAll(branch) catch return file_writer.err.?;
    }

    if (current_branch) |p|
        std.log.info("dof branch updated from '{s}' to '{s}'", .{ p, branch })
    else
        std.log.info("dof branch newly set to '{s}'", .{branch});
}

fn dofPathProblem(path: []const u8) !?[:0]const u8 {
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return "does not exist",
        else => |e| return e,
    };
    defer dir.close();
    var git = dir.openDir(".git", .{}) catch |err| switch (err) {
        error.FileNotFound => return "is not a git repo (no .git directory)",
        else => |e| return e,
    };
    defer git.close();
    return null;
}

fn runDof(scratch: std.mem.Allocator, repo: []const u8, config_dof_path: []const u8) !void {
    const content = blk: {
        var file = std.fs.openFileAbsolute(config_dof_path, .{}) catch |err| switch (err) {
            error.FileNotFound => errExit("repo '{s}' is missing 'config.dof'", .{std.fs.path.dirname(config_dof_path).?}),
            else => |e| return e,
        };
        defer file.close();
        break :blk try file.readToEndAlloc(scratch, 100 * 1024 * 1024);
    };
    defer scratch.free(content);

    var runner: DofRunner = .{
        .allocator = scratch,
        .repo = repo,
        .filename = config_dof_path,
        .content = content,
    };
    try runner.run(0);
}

const Command = enum {
    // @"home-link",
    @"install-home",
    @"emacs-load-file",
};

const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub const Tag = enum {
        invalid,
        eof,
        identifier,
        string,
    };
};
fn lex(text: []const u8, lex_start: usize) Token {
    const State = union(enum) {
        start,
        identifier: usize,
        string: usize,
        line_comment,
    };

    var index = lex_start;
    var state: State = .start;

    while (true) {
        if (index >= text.len) return switch (state) {
            .start, .line_comment => .{ .tag = .eof, .start = index, .end = index },
            .identifier => |start| .{
                .tag = .identifier,
                .start = start,
                .end = index,
            },
            .string => |start| .{ .tag = .invalid, .start = start, .end = index },
        };
        switch (state) {
            .start => {
                switch (text[index]) {
                    ' ', '\n', '\t', '\r' => index += 1,
                    '"' => {
                        state = .{ .string = index };
                        index += 1;
                    },
                    'a'...'z', 'A'...'Z', '_', '-', '.', '/' => {
                        state = .{ .identifier = index };
                        index += 1;
                    },
                    else => return .{ .tag = .invalid, .start = index, .end = index + 1 },
                }
            },
            .identifier => |start| {
                switch (text[index]) {
                    'a'...'z', 'A'...'Z', '_', '-', '.', '/', '0'...'9' => index += 1,
                    else => return .{ .tag = .identifier, .start = start, .end = index },
                }
            },
            .string => |start| switch (text[index]) {
                '"' => return .{ .tag = .string, .start = start, .end = index + 1 },
                '\n' => return .{ .tag = .invalid, .start = start, .end = index },
                else => index += 1,
            },
            .line_comment => switch (text[index]) {
                '\n' => {
                    state = .start;
                    index += 1;
                },
                else => index += 1,
            },
        }
    }
}

const DofRunner = struct {
    allocator: std.mem.Allocator,
    repo: []const u8,
    filename: []const u8,
    content: []const u8,
    pub fn run(runner: *DofRunner, start: usize) !void {
        var offset = start;
        while (true) {
            const token = lex(runner.content, offset);
            switch (token.tag) {
                .invalid => try runner.throw(token.start, "invalid token '{s}'", .{runner.content[token.start..token.end]}),
                .eof => return,
                .identifier => {
                    const id_string = runner.content[token.start..token.end];
                    const command = std.meta.stringToEnum(Command, id_string) orelse try runner.throw(
                        token.start,
                        "unknown directive '{s}'",
                        .{id_string},
                    );
                    switch (command) {
                        // .@"home-link" => offset = try runner.@"home-link"(token.end),
                        .@"install-home" => offset = try runner.@"install-home"(token.end),
                        .@"emacs-load-file" => offset = try runner.@"emacs-load-file"(token.end),
                    }
                },
                .string => try runner.throw(token.start, "TODO: handle string", .{}),
            }
        }
    }
    fn throw(runner: *DofRunner, at: usize, comptime fmt: []const u8, args: anytype) !noreturn {
        const line, const col = getLineCol(runner.content, at);
        var buf: [1024]u8 = undefined;
        var f = std.fs.File.stderr().writer(&buf);
        const w = &f.interface;
        w.print("{s}:{}:{}: ", .{ runner.filename, line, col }) catch return f.err.?;
        w.print(fmt, args) catch return f.err.?;
        w.writeAll("\n") catch return f.err.?;
        w.flush() catch return f.err.?;
        std.process.exit(0xff);
    }

    // fn @"home-link"(runner: *DofRunner, start: usize) !usize {
    //     const token = lex(runner.content, start);
    //     switch (token.tag) {
    //         .identifier => {},
    //         else => try runner.throw(token.start, "expected a path but got {t}", .{token.tag}),
    //     }

    //     std.debug.assert(std.fs.path.isAbsolute(runner.repo));
    //     const sub_path = runner.content[token.start..token.end];
    //     std.debug.assert(!std.fs.path.isAbsolute(sub_path));
    //     const path = try std.fs.path.join(runner.allocator, &.{ runner.repo, sub_path });
    //     defer runner.allocator.free(path);

    //     std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
    //         error.FileNotFound => try runner.throw(token.start, "home-link source '{s}' not found", .{path}),
    //         else => |e| return e,
    //     };

    //     const home = try getHome(runner.allocator);
    //     defer runner.allocator.free(home);
    //     const link_path = try std.fs.path.join(runner.allocator, &.{ home, sub_path });
    //     defer runner.allocator.free(link_path);

    //     // Check if the link already exists and points to the right place.
    //     var readlink_buf: [std.fs.max_path_bytes]u8 = undefined;
    //     if (try stdfix.readLinkAbsolute(link_path, &readlink_buf)) |existing_target| {
    //         if (std.mem.eql(u8, existing_target, path)) {
    //             std.log.info("home-link '{s}': already linked", .{sub_path});
    //             return token.end;
    //         }
    //     }

    //     // Ensure parent directory exists.
    //     if (std.fs.path.dirname(link_path)) |parent| {
    //         try std.fs.cwd().makePath(parent);
    //     }

    //     // Try symlink first; on Windows this may fail without elevated privileges,
    //     // so fall back to copying the file.
    //     std.fs.symLinkAbsolute(path, link_path, .{}) catch |symlink_err| {
    //         if (builtin.os.tag != .windows) return symlink_err;
    //         std.log.info("home-link '{s}': symlink failed, copying instead", .{sub_path});
    //         std.fs.copyFileAbsolute(path, link_path, .{}) catch |copy_err| {
    //             std.log.err("home-link '{s}': copy failed: {}", .{ sub_path, copy_err });
    //             return copy_err;
    //         };
    //         std.log.info("home-link '{s}': copied", .{sub_path});
    //         return token.end;
    //     };
    //     std.log.info("home-link '{s}': linked", .{sub_path});
    //     return token.end;
    // }

    fn @"install-home"(runner: *DofRunner, start: usize) !usize {
        const token = lex(runner.content, start);
        switch (token.tag) {
            .identifier => {},
            else => try runner.throw(token.start, "expected a path but got {t}", .{token.tag}),
        }

        std.debug.assert(std.fs.path.isAbsolute(runner.repo));
        const sub_path = runner.content[token.start..token.end];
        std.debug.assert(!std.fs.path.isAbsolute(sub_path));
        const path = try std.fs.path.join(runner.allocator, &.{ runner.repo, sub_path });
        defer runner.allocator.free(path);

        std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => try runner.throw(token.start, "install-home source '{s}' not found", .{path}),
            else => |e| return e,
        };

        const home = try getHome(runner.allocator);
        defer runner.allocator.free(home);
        const dest_path = try std.fs.path.join(runner.allocator, &.{ home, sub_path });
        defer runner.allocator.free(dest_path);

        try installToHome(runner.allocator, path, dest_path);
        return token.end;
    }

    fn @"emacs-load-file"(runner: *DofRunner, start: usize) !usize {
        const token = lex(runner.content, start);
        switch (token.tag) {
            .identifier => {},
            else => try runner.throw(token.start, "expected a path but got {t}", .{token.tag}),
        }

        std.debug.assert(std.fs.path.isAbsolute(runner.repo));
        const sub_path = runner.content[token.start..token.end];
        std.debug.assert(!std.fs.path.isAbsolute(sub_path));
        const path = try std.fs.path.join(runner.allocator, &.{ runner.repo, sub_path });
        defer runner.allocator.free(path);

        // normalize path for emacs
        for (path) |*ch| ch.* = switch (ch.*) {
            '\\' => '/',
            else => ch.*,
        };

        std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => try runner.throw(token.start, "emacs-load-file '{s}' not found", .{path}),
            else => |e| return e,
        };

        const load_string = try std.fmt.allocPrint(runner.allocator, "(load-file \"{s}\")\n", .{path});
        defer runner.allocator.free(load_string);

        const emacs_home_path = try getEmacsHome(runner.allocator);
        defer runner.allocator.free(emacs_home_path);
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        std.log.info("emacs HOME at '{s}'", .{emacs_home_path});

        var emacs_home = try std.fs.cwd().makeOpenPath(emacs_home_path, .{});
        defer emacs_home.close();

        if (emacs_home.openFile(".emacs", .{})) |dot_emacs| {
            defer dot_emacs.close();
            if (try scanFile(dot_emacs, load_string)) {
                std.log.info("emacs-load-file '{s}': already installed", .{sub_path});
                return token.end;
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }

        {
            var dot_emacs = try emacs_home.createFile(".emacs", .{ .truncate = false });
            defer dot_emacs.close();
            try dot_emacs.seekFromEnd(0);
            try dot_emacs.writeAll(load_string);
            std.log.info("emacs-load-file '{s}': appended to .emacs", .{sub_path});
        }

        {
            var dot_emacs = try emacs_home.openFile(".emacs", .{});
            defer dot_emacs.close();
            std.debug.assert(try scanFile(dot_emacs, load_string));
        }
        return token.end;
    }
};

fn installToHome(allocator: std.mem.Allocator, src_path: []const u8, dest_path: []const u8) !void {
    var src_dir = std.fs.openDirAbsolute(src_path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return installFile(src_path, dest_path),
        else => |e| return e,
    };
    defer src_dir.close();

    try std.fs.cwd().makePath(dest_path);

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        const child_src = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(child_src);
        const child_dest = try std.fs.path.join(allocator, &.{ dest_path, entry.name });
        defer allocator.free(child_dest);
        switch (entry.kind) {
            .file => try installFile(child_src, child_dest),
            .directory => try installToHome(allocator, child_src, child_dest),
            else => errExit("{s}: unsupported file type '{s}'", .{ child_src, @tagName(entry.kind) }),
        }
    }
}

fn installFile(src_path: []const u8, dest_path: []const u8) !void {
    const src_file = try std.fs.openFileAbsolute(src_path, .{});
    defer src_file.close();

    const status: enum { new, updated } = if (std.fs.openFileAbsolute(dest_path, .{})) |dest_file| blk: {
        defer dest_file.close();
        if (try filesEqual(src_file, dest_file)) {
            std.log.info("{s}: already up-to-date", .{dest_path});
            return;
        }
        break :blk .updated;
    } else |err| switch (err) {
        error.FileNotFound => blk: {
            if (std.fs.path.dirname(dest_path)) |parent| {
                try std.fs.cwd().makePath(parent);
            }
            break :blk .new;
        },
        else => |e| return e,
    };
    try std.fs.copyFileAbsolute(src_path, dest_path, .{});
    std.log.info("{s}: {s}", .{ dest_path, switch (status) {
        .new => "newly installed",
        .updated => "updated",
    } });
}

fn filesEqual(a: std.fs.File, b: std.fs.File) !bool {
    const a_stat = try a.stat();
    const b_stat = try b.stat();
    if (a_stat.size != b_stat.size) return false;

    var buf_a: [4096]u8 = undefined;
    var buf_b: [4096]u8 = undefined;
    while (true) {
        const n_a = try a.read(&buf_a);
        const n_b = try b.read(&buf_b);
        if (n_a != n_b) return false;
        if (n_a == 0) return true;
        if (!std.mem.eql(u8, buf_a[0..n_a], buf_b[0..n_b])) return false;
    }
}

fn getHome(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        return home;
    } else |_| {}
    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |profile| {
            return profile;
        } else |_| {}
    }
    return error.HomeNotFound;
}

fn getEmacsHome(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        return home;
    } else |_| {}
    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "APPDATA")) |appdata| {
            return appdata;
        } else |_| {}
    }
    return error.EmacsHomeNotFound;
}

/// Scans file contents for `needle` as a substring.
fn scanFile(file: std.fs.File, needle: []const u8) !bool {
    var buf: [8192]u8 = undefined;
    // TODO: need to allocate a bigger buffer if we ever exceed this
    std.debug.assert(needle.len <= buf.len);
    if (needle.len == 0) return true;
    var len: usize = 0;
    while (true) {
        const n = file.read(buf[len..]) catch return error.ReadFailed;
        if (n == 0) return false;
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], needle) != null) return true;
        // Keep the last needle.len-1 bytes for boundary matches.
        const keep = @min(needle.len - 1, len);
        std.mem.copyForwards(u8, buf[0..keep], buf[len - keep .. len]);
        len = keep;
    }
}

fn getLineCol(text: []const u8, offset: usize) struct { u32, u32 } {
    var line: u32 = 1;
    var col: u32 = 1;
    for (text[0..@min(text.len, offset)]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ line, col };
}

fn prompt(str: []const u8) !enum { yes, no } {
    const stdin = std.fs.File.stdin();

    var write_buf: [300]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&write_buf);

    var read_buf: [100]u8 = undefined;
    var reader = stdin.reader(&read_buf);
    while (true) {
        stderr.interface.print("{s} [yes/no] ", .{str}) catch return stderr.err.?;
        stderr.interface.flush() catch return stderr.err.?;

        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.StreamTooLong => errExit("input too long", .{}),
        } orelse errExit("unexpected end of stdin", .{});
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (std.mem.eql(u8, trimmed, "yes")) return .yes;
        if (std.mem.eql(u8, trimmed, "no")) return .no;
        stderr.interface.print("\nerror: unknown response '{f}'\n", .{std.zig.fmtString(trimmed)}) catch return stderr.err.?;
    }
}

fn promptLine(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
    const stdin = std.fs.File.stdin();

    var write_buf: [300]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&write_buf);

    stderr.interface.print("{s}", .{str}) catch return stderr.err.?;
    stderr.interface.flush() catch return stderr.err.?;

    var read_buf: [1000]u8 = undefined;
    var reader = stdin.reader(&read_buf);
    const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.StreamTooLong => errExit("input too long", .{}),
    } orelse errExit("unexpected end of stdin", .{});
    const trimmed = std.mem.trimRight(u8, line, "\r");
    if (trimmed.len == 0) errExit("commit message cannot be empty", .{});
    return try allocator.dupe(u8, trimmed);
}

fn runExitCode(
    arena: std.mem.Allocator,
    argv: []const []const u8,
    maybe_cwd: ?[]const u8,
) !u8 {
    try logRun(argv, maybe_cwd);
    var child = std.process.Child.init(argv, arena);
    if (maybe_cwd) |cwd| child.cwd = cwd;
    try child.spawn();
    const term = try child.wait();
    return switch (term) {
        .Exited => |code| code,
        inline else => |why, sig| errExit("{s} terminated ({t}) with signal {}", .{ argv[0], sig, why }),
    };
}

pub fn selfExePathAlloc(allocator: std.mem.Allocator) ![:0]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return allocator.dupeZ(u8, try std.fs.selfExePath(&buf));
}

fn updateExecNoreturn(
    arena: std.mem.Allocator,
    src: []const u8,
    src_lock_path: []const u8,
    master: *const [40]u8,
) !noreturn {
    const exe = try selfExePathAlloc(arena);
    defer arena.free(exe);
    // exe must be absolute path since we run zig from the src directory
    std.debug.assert(std.fs.path.isAbsolute(exe));
    const exe_lock_path = try std.mem.concat(arena, u8, &.{ exe, ".lock" });
    defer arena.free(exe_lock_path);

    {
        var lock = try LockFile.lock(src_lock_path);
        defer lock.unlock();
        try run(arena, &.{ "git", "-C", src, "reset", "--hard", master }, null);
        // should be safe from deadlock since lock order is always the same (src then exe)
        var exe_lock = try LockFile.lock(exe_lock_path);
        defer exe_lock.unlock();
        const prefix = "-Dsha=";
        var sha_arg_buf: [prefix.len + 40]u8 = undefined;
        const sha_arg = std.fmt.bufPrint(&sha_arg_buf, prefix ++ "{s}", .{master}) catch unreachable;
        try run(arena, &.{
            "zig",
            "build",
            "install",
            sha_arg,
            "--prefix",
            std.fs.path.dirname(exe).?,
        }, src);
    }

    // Re-exec the newly built dof with --no-update plus all original args.
    if (builtin.os.tag == .windows) {
        var argv = std.ArrayListUnmanaged([]const u8){};
        try argv.append(arena, exe);
        try argv.append(arena, "--no-update");
        var arg_it = try std.process.argsWithAllocator(arena);
        _ = arg_it.next(); // skip argv[0]
        while (arg_it.next()) |arg| try argv.append(arena, arg);

        var child = std.process.Child.init(argv.items, arena);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        const term = try child.wait();
        switch (term) {
            .Exited => |code| std.process.exit(code),
            inline else => |why, sig| errExit("{s} terminated ({t}) with signal {}", .{ exe, sig, why }),
        }
    } else {
        const os_argv = std.os.argv;
        // +1 for --no-update, +1 for null sentinel, -1 because argv[0] is replaced = net +1
        const argv = try arena.allocSentinel(?[*:0]const u8, os_argv.len + 1, null);
        argv[0] = exe.ptr;
        argv[1] = "--no-update";
        for (os_argv[1..], argv[2..]) |a, *dst| dst.* = a;
        const err = std.posix.execveZ(exe.ptr, argv, @ptrCast(std.os.environ));
        errExit("execve failed: {}", .{err});
    }
}

fn fetchDofMaster(src: []const u8, src_lock_path: []const u8, arena: std.mem.Allocator) ![40]u8 {
    var lock = try LockFile.lock(src_lock_path);
    defer lock.unlock();

    const src_exists = blk: {
        var dir = std.fs.cwd().openDir(src, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => |e| errExit("openDir '{s}' failed with {t}", .{ src, e }),
        };
        dir.close();
        break :blk true;
    };

    if (!src_exists) {
        try run(arena, &.{ "git", "clone", "https://github.com/marler8997/dof", src, "-b", "master" }, null);
    }
    try run(arena, &.{ "git", "-C", src, "fetch", "origin", "master" }, null);

    const fetch_head_path = try std.fs.path.join(arena, &.{ src, ".git", "FETCH_HEAD" });
    defer arena.free(fetch_head_path);
    return readSha(fetch_head_path);
}

fn readSha(path: []const u8) ![40]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var buf: [100]u8 = undefined;
    var reader = file.reader(&buf);
    var sha: [40]u8 = undefined;
    reader.interface.readSliceAll(&sha) catch |err| switch (err) {
        error.EndOfStream => |e| return e,
        error.ReadFailed => return reader.err.?,
    };
    if (!validSha(&sha)) errExit(
        "invalid git SHA \"{f}\" from '{s}'",
        .{ std.zig.fmtString(&sha), path },
    );
    return sha;
}

fn validSha(sha: *const [40]u8) bool {
    for (sha) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn run(
    arena: std.mem.Allocator,
    argv: []const []const u8,
    maybe_cwd: ?[]const u8,
) !void {
    try logRun(argv, maybe_cwd);
    var child = std.process.Child.init(argv, arena);
    if (maybe_cwd) |cwd| child.cwd = cwd;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) errExit("{s} exited with non-zero exit code {}", .{ argv[0], code }),
        inline else => |why, sig| errExit("{s} terminated ({t}) with signal {}", .{ argv[0], sig, why }),
    }
}

const GitStatus = enum { clean, dirty };
fn gitStatus(arena: std.mem.Allocator, repo_path: []const u8) !GitStatus {
    const argv: []const []const u8 = &.{ "git", "-C", repo_path, "status", "--porcelain" };
    try logRun(argv, null);
    var child = std.process.Child.init(argv, arena);
    child.stdout_behavior = .Pipe;
    try child.spawn();
    var reader = child.stdout.?.readerStreaming(&.{});
    var write_buf: [1000]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&write_buf);
    const len = reader.interface.streamRemaining(&stderr_writer.interface) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.WriteFailed => return stderr_writer.err.?,
    };
    stderr_writer.interface.flush() catch return stderr_writer.err.?;
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) errExit("{s} exited with non-zero exit code {}", .{ argv[0], code }),
        inline else => |why, sig| errExit("{s} terminated ({t}) with signal {}", .{ argv[0], sig, why }),
    }
    return if (len == 0) .clean else .dirty;
}

fn logRun(argv: []const []const u8, maybe_cwd: ?[]const u8) !void {
    var buf: [1024]u8 = undefined;
    var f = std.fs.File.stderr().writer(&buf);
    writeRun(argv, maybe_cwd, &f.interface) catch return f.err.?;
}
fn writeRun(argv: []const []const u8, maybe_cwd: ?[]const u8, w: *std.Io.Writer) error{WriteFailed}!void {
    try w.writeAll("run:");
    if (maybe_cwd) |cwd| {
        try w.print("cd {f} && ", .{fmtArg(cwd)});
    }
    for (argv) |arg| {
        try w.print(" {f}", .{fmtArg(arg)});
    }
    try w.writeAll("\n");
    try w.flush();
}
fn fmtArg(a: []const u8) FmtArg {
    return .{ .arg = a };
}
const FmtArg = struct {
    arg: []const u8,
    pub fn format(f: FmtArg, w: *std.Io.Writer) error{WriteFailed}!void {
        const needs_quote = std.mem.indexOfScalar(u8, f.arg, ' ') != null;
        const quote: []const u8 = if (needs_quote) "\"" else "";
        try w.print("{s}{s}{0s}", .{ quote, f.arg });
    }
};

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const build_options = @import("build_options");
const builtin = @import("builtin");
const std = @import("std");
const stdfix = @import("stdfix.zig");
const LockFile = @import("LockFile.zig");
