pub fn main(init: std.process.Init.Minimal) !void {
    // the same choice std's start.zig makes for std.process.Init
    const use_safe_allocator = switch (builtin.mode) {
        .debug, .safe => true,
        .fast, .small => false,
    };
    var safe_allocator: std.heap.SafeAllocator = if (use_safe_allocator) .init(std.heap.page_allocator, .{}) else undefined;
    defer if (use_safe_allocator) {
        const leak_count = safe_allocator.deinit();
        if (leak_count != 0) errExit("leaked {d} allocations", .{leak_count});
    };
    const gpa = if (use_safe_allocator) safe_allocator.allocator() else std.heap.smp_allocator;
    // process-lifetime memory, kept out of gpa so it skips gpa's bookkeeping
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = init.environ, .argv0 = .init(init.args) });
    defer threaded.deinit();
    const io = threaded.io();
    const environ = init.environ;

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
        var arg_it = try init.args.iterateAllocator(arena);
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

    const app_data_path = try appDataDir(arena, environ);
    defer arena.free(app_data_path);
    // std.log.info("appdata '{s}'", .{app_data_path});
    std.debug.assert(std.fs.path.isAbsolute(app_data_path));
    try std.Io.Dir.cwd().createDirPath(io, app_data_path);

    if (opt.update) {
        const src = try std.fs.path.join(arena, &.{ app_data_path, "src" });
        defer arena.free(src);

        const src_lock_path = try std.mem.concat(arena, u8, &.{ src, ".lock" });
        defer arena.free(src_lock_path);

        const master = blk: {
            break :blk try fetchDofMaster(io, src, src_lock_path, arena);
        };
        if (!std.mem.eql(u8, &master, &build_options.sha)) {
            std.log.info("running: {s}", .{&build_options.sha});
            std.log.info("master : {s}", .{&master});
            try updateExecNoreturn(
                io,
                arena,
                try init.args.toSlice(arena),
                src,
                src_lock_path,
                &master,
            );
        }
        std.log.info("already running master ({s})", .{&build_options.sha});
    }

    return switch (opt.sub_command) {
        .none => try defaultCommand(io, arena, environ, opt.interactive, app_data_path),
        .path => |path| try pathCommand(io, arena, app_data_path, path),
        .branch => |branch| try branchCommand(io, arena, app_data_path, branch),
    };
}

fn defaultCommand(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    interactive: bool,
    app_data_path: []const u8,
) !void {
    const repo_path = blk_repo_path: {
        const app_data_repo = try std.fs.path.join(arena, &.{ app_data_path, "repo" });
        defer arena.free(app_data_repo);
        const repo_config_lock_path = try std.mem.concat(arena, u8, &.{ app_data_repo, ".lock" });
        defer arena.free(repo_config_lock_path);
        var repo_config_lock = try LockFile.lock(io, repo_config_lock_path);
        defer repo_config_lock.unlock(io);
        const path = readFileMax(io, arena, app_data_repo, 2000) catch |err| switch (err) {
            error.FileNotFound => errExit("NO PATH! set a path with: dof path PATH", .{}),
            else => |e| return e,
        };
        if (try dofPathProblem(io, path)) |problem| errExit(
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
        var branch_lock = try LockFile.lock(io, branch_lock_path);
        defer branch_lock.unlock(io);
        break :blk readFileMax(io, arena, app_data_branch, 2000) catch |err| switch (err) {
            error.FileNotFound => errExit("NO BRANCH! set a branch with: dof branch BRANCH", .{}),
            else => |e| return e,
        };
    };
    defer arena.free(branch);

    const repo_lock_path = try std.mem.concat(arena, u8, &.{ repo_path, ".lock" });
    defer arena.free(repo_lock_path);
    const config_dof_path = try std.fs.path.join(arena, &.{ repo_path, "config.dof" });
    defer arena.free(config_dof_path);

    switch (try gitStatus(io, repo_path)) {
        .dirty => {
            if (!interactive) errExit("repo is dirty and --non-interactive is preset", .{});
            std.log.info("repo is dirty", .{});
            {
                var repo_lock = try LockFile.lock(io, repo_lock_path);
                defer repo_lock.unlock(io);
                try runDof(io, arena, environ, repo_path, config_dof_path);
            }
            switch (try prompt(io, "dof changes applied, push?")) {
                .yes => {},
                .no => {
                    std.log.info("user answered no", .{});
                    std.process.exit(0xff);
                },
            }

            {
                var repo_lock = try LockFile.lock(io, repo_lock_path);
                defer repo_lock.unlock(io);
                try run(io, &.{ "git", "-C", repo_path, "add", "-A" }, null);
                try run(io, &.{ "git", "-C", repo_path, "diff", "--cached", "--stat" }, null);

                switch (try prompt(io, "commit and push these changes?")) {
                    .yes => {},
                    .no => {
                        try run(io, &.{ "git", "-C", repo_path, "reset" }, null);
                        std.log.info("changes left uncommitted", .{});
                        std.process.exit(0xff);
                    },
                }

                const commit_msg = try promptLine(io, arena, "commit message: ");
                defer arena.free(commit_msg);
                try run(io, &.{ "git", "-C", repo_path, "commit", "-m", commit_msg }, null);
                try run(io, &.{ "git", "-C", repo_path, "fetch", "origin", branch }, null);
                if (try runExitCode(io, &.{ "git", "-C", repo_path, "rebase", "FETCH_HEAD" }, null) != 0) {
                    try run(io, &.{ "git", "-C", repo_path, "rebase", "--abort" }, null);
                    errExit("rebase failed, resolve conflicts manually in '{s}'", .{repo_path});
                }
                // run dof again after rebase
                try runDof(io, arena, environ, repo_path, config_dof_path);
                try run(io, &.{ "git", "-C", repo_path, "push", "origin", branch }, null);
            }
        },
        .clean => {
            std.log.info("repo is clean", .{});
            var repo_lock = try LockFile.lock(io, repo_lock_path);
            defer repo_lock.unlock(io);
            try run(io, &.{ "git", "-C", repo_path, "fetch", "origin", branch }, null);
            try run(io, &.{ "git", "-C", repo_path, "reset", "--hard", "FETCH_HEAD" }, null);
            try runDof(io, arena, environ, repo_path, config_dof_path);
        },
    }
}

fn pathCommand(io: std.Io, arena: std.mem.Allocator, app_data_path: []const u8, path_raw: []const u8) !void {
    const path = std.mem.trimEnd(u8, path_raw, switch (builtin.os.tag) {
        .windows => "/" ++ "\\",
        else => "/",
    });

    if (!std.fs.path.isAbsolute(path)) errExit("path '{s}' must be absolute", .{path});
    if (try dofPathProblem(io, path)) |problem| errExit("dof path '{s}' {s}", .{ path, problem });

    const app_data_repo = try std.fs.path.join(arena, &.{ app_data_path, "repo" });
    defer arena.free(app_data_repo);

    const repo_lock_path = try std.mem.concat(arena, u8, &.{ app_data_repo, ".lock" });
    defer arena.free(repo_lock_path);

    var repo_lock = try LockFile.lock(io, repo_lock_path);
    defer repo_lock.unlock(io);

    const current_path: ?[]const u8 = blk: {
        break :blk readFileMax(io, arena, app_data_repo, 2000) catch |err| switch (err) {
            error.FileNotFound => break :blk null,
            else => |e| return e,
        };
    };
    defer if (current_path) |p| arena.free(p);
    if (current_path) |p| {
        if (std.mem.eql(u8, p, path)) {
            std.log.info("dof path already set to '{s}'", .{path});
            std.process.exit(0);
        }
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = app_data_repo, .data = path });

    if (current_path) |p|
        std.log.info("dof path updated from '{s}' to '{s}'", .{ p, path })
    else
        std.log.info("dof path newly set to '{s}'", .{path});
}

fn branchCommand(io: std.Io, arena: std.mem.Allocator, app_data_path: []const u8, branch: []const u8) !void {
    const app_data_branch = try std.fs.path.join(arena, &.{ app_data_path, "branch" });
    defer arena.free(app_data_branch);

    const branch_lock_path = try std.mem.concat(arena, u8, &.{ app_data_branch, ".lock" });
    defer arena.free(branch_lock_path);

    var branch_lock = try LockFile.lock(io, branch_lock_path);
    defer branch_lock.unlock(io);

    const current_branch: ?[]const u8 = blk: {
        break :blk readFileMax(io, arena, app_data_branch, 2000) catch |err| switch (err) {
            error.FileNotFound => break :blk null,
            else => |e| return e,
        };
    };
    defer if (current_branch) |p| arena.free(p);
    if (current_branch) |p| {
        if (std.mem.eql(u8, p, branch)) {
            std.log.info("dof branch already set to '{s}'", .{branch});
            std.process.exit(0);
        }
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = app_data_branch, .data = branch });

    if (current_branch) |p|
        std.log.info("dof branch updated from '{s}' to '{s}'", .{ p, branch })
    else
        std.log.info("dof branch newly set to '{s}'", .{branch});
}

fn dofPathProblem(io: std.Io, path: []const u8) !?[:0]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return "does not exist",
        else => |e| return e,
    };
    defer dir.close(io);
    var git = dir.openDir(io, ".git", .{}) catch |err| switch (err) {
        error.FileNotFound => return "is not a git repo (no .git directory)",
        else => |e| return e,
    };
    defer git.close(io);
    return null;
}

fn runDof(
    io: std.Io,
    scratch: std.mem.Allocator,
    environ: std.process.Environ,
    repo: []const u8,
    config_dof_path: []const u8,
) !void {
    const content = readFileMax(io, scratch, config_dof_path, 100 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => errExit("repo '{s}' is missing 'config.dof'", .{std.fs.path.dirname(config_dof_path).?}),
        else => |e| return e,
    };
    defer scratch.free(content);

    var runner: DofRunner = .{
        .io = io,
        .environ = environ,
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
    io: std.Io,
    environ: std.process.Environ,
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
        var f = std.Io.File.stderr().writerStreaming(runner.io, &buf);
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

        std.Io.Dir.accessAbsolute(runner.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => try runner.throw(token.start, "install-home source '{s}' not found", .{path}),
            else => |e| return e,
        };

        const home = try getHome(runner.allocator, runner.environ);
        const dest_path = try std.fs.path.join(runner.allocator, &.{ home, sub_path });
        defer runner.allocator.free(dest_path);

        try installToHome(runner.io, runner.allocator, path, dest_path);
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

        std.Io.Dir.accessAbsolute(runner.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => try runner.throw(token.start, "emacs-load-file '{s}' not found", .{path}),
            else => |e| return e,
        };

        const load_string = try std.fmt.allocPrint(runner.allocator, "(load-file \"{s}\")\n", .{path});
        defer runner.allocator.free(load_string);

        const emacs_home_path = try getEmacsHome(runner.allocator, runner.environ);
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        std.log.info("emacs HOME at '{s}'", .{emacs_home_path});

        var emacs_home = try std.Io.Dir.cwd().createDirPathOpen(runner.io, emacs_home_path, .{});
        defer emacs_home.close(runner.io);

        if (emacs_home.openFile(runner.io, ".emacs", .{})) |dot_emacs| {
            defer dot_emacs.close(runner.io);
            if (try scanFile(runner.io, dot_emacs, load_string)) {
                std.log.info("emacs-load-file '{s}': already installed", .{sub_path});
                return token.end;
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }

        {
            var dot_emacs = try emacs_home.createFile(runner.io, ".emacs", .{ .truncate = false });
            defer dot_emacs.close(runner.io);
            try dot_emacs.writePositionalAll(runner.io, load_string, try dot_emacs.length(runner.io));
            std.log.info("emacs-load-file '{s}': appended to .emacs", .{sub_path});
        }

        {
            var dot_emacs = try emacs_home.openFile(runner.io, ".emacs", .{});
            defer dot_emacs.close(runner.io);
            std.debug.assert(try scanFile(runner.io, dot_emacs, load_string));
        }
        return token.end;
    }
};

fn installToHome(io: std.Io, allocator: std.mem.Allocator, src_path: []const u8, dest_path: []const u8) !void {
    var src_dir = std.Io.Dir.openDirAbsolute(io, src_path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return installFile(io, src_path, dest_path),
        else => |e| return e,
    };
    defer src_dir.close(io);

    try std.Io.Dir.cwd().createDirPath(io, dest_path);

    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        const child_src = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(child_src);
        const child_dest = try std.fs.path.join(allocator, &.{ dest_path, entry.name });
        defer allocator.free(child_dest);
        switch (entry.kind) {
            .file => try installFile(io, child_src, child_dest),
            .directory => try installToHome(io, allocator, child_src, child_dest),
            else => errExit("{s}: unsupported file type '{s}'", .{ child_src, @tagName(entry.kind) }),
        }
    }
}

fn installFile(io: std.Io, src_path: []const u8, dest_path: []const u8) !void {
    const src_file = try std.Io.Dir.openFileAbsolute(io, src_path, .{});
    defer src_file.close(io);

    const status: enum { new, updated } = if (std.Io.Dir.openFileAbsolute(io, dest_path, .{})) |dest_file| blk: {
        defer dest_file.close(io);
        if (try filesEqual(io, src_file, dest_file)) {
            std.log.info("{s}: already up-to-date", .{dest_path});
            return;
        }
        break :blk .updated;
    } else |err| switch (err) {
        error.FileNotFound => blk: {
            if (std.fs.path.dirname(dest_path)) |parent| {
                try std.Io.Dir.cwd().createDirPath(io, parent);
            }
            break :blk .new;
        },
        else => |e| return e,
    };
    try std.Io.Dir.copyFileAbsolute(src_path, dest_path, io, .{});
    std.log.info("{s}: {s}", .{ dest_path, switch (status) {
        .new => "newly installed",
        .updated => "updated",
    } });
}

fn filesEqual(io: std.Io, a: std.Io.File, b: std.Io.File) !bool {
    const a_stat = try a.stat(io);
    const b_stat = try b.stat(io);
    if (a_stat.size != b_stat.size) return false;

    var reader_a = a.readerStreaming(io, &.{});
    var reader_b = b.readerStreaming(io, &.{});
    var buf_a: [4096]u8 = undefined;
    var buf_b: [4096]u8 = undefined;
    while (true) {
        const n_a = reader_a.interface.readSliceShort(&buf_a) catch return reader_a.err.?;
        const n_b = reader_b.interface.readSliceShort(&buf_b) catch return reader_b.err.?;
        if (n_a != n_b) return false;
        if (n_a == 0) return true;
        if (!std.mem.eql(u8, buf_a[0..n_a], buf_b[0..n_b])) return false;
    }
}

fn getHome(allocator: std.mem.Allocator, environ: std.process.Environ) ![]const u8 {
    if (try getEnv(allocator, environ, "HOME")) |home| return home;
    if (builtin.os.tag == .windows) {
        if (try getEnv(allocator, environ, "USERPROFILE")) |profile| return profile;
    }
    return error.HomeNotFound;
}

fn getEmacsHome(allocator: std.mem.Allocator, environ: std.process.Environ) ![]const u8 {
    if (try getEnv(allocator, environ, "HOME")) |home| return home;
    if (builtin.os.tag == .windows) {
        if (try getEnv(allocator, environ, "APPDATA")) |appdata| return appdata;
    }
    return error.EmacsHomeNotFound;
}

/// Returns null if the variable is unset or empty. On windows the value is
/// converted to WTF-8 in `allocator`, elsewhere it points into the environment.
fn getEnv(allocator: std.mem.Allocator, environ: std.process.Environ, comptime name: []const u8) !?[]const u8 {
    if (builtin.os.tag == .windows) {
        const value_w = environ.getWindows(comptime std.unicode.wtf8ToWtf16LeStringLiteral(name)) orelse return null;
        if (value_w.len == 0) return null;
        return try std.unicode.wtf16LeToWtf8Alloc(allocator, value_w);
    }
    const value = environ.getPosix(name) orelse return null;
    if (value.len == 0) return null;
    return value;
}

/// Same locations std.fs.getAppDataDir used (it was removed from std) so
/// existing installs keep their config.
fn appDataDir(allocator: std.mem.Allocator, environ: std.process.Environ) ![]const u8 {
    switch (builtin.os.tag) {
        .windows => {
            const local_app_data = try getEnv(allocator, environ, "LOCALAPPDATA") orelse errExit("can't find dof's data directory, LOCALAPPDATA is unset or empty", .{});
            return std.fs.path.join(allocator, &.{ local_app_data, "dof" });
        },
        .macos => {
            const home = try getEnv(allocator, environ, "HOME") orelse errExit("can't find dof's data directory, HOME is unset or empty", .{});
            return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "dof" });
        },
        else => {
            if (try getEnv(allocator, environ, "XDG_DATA_HOME")) |xdg| return std.fs.path.join(allocator, &.{ xdg, "dof" });
            const home = try getEnv(allocator, environ, "HOME") orelse errExit("can't find dof's data directory, XDG_DATA_HOME and HOME are unset or empty", .{});
            return std.fs.path.join(allocator, &.{ home, ".local", "share", "dof" });
        },
    }
}

/// Like readFileAlloc but a file of exactly `max_bytes` is allowed (readFileAlloc's
/// limit is exclusive) and a bigger one exits with an error naming the file.
fn readFileMax(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => errExit("'{s}' is over {d} bytes", .{ path, max_bytes }),
        else => |e| return e,
    };
}

/// Scans file contents for `needle` as a substring.
fn scanFile(io: std.Io, file: std.Io.File, needle: []const u8) !bool {
    var reader = file.readerStreaming(io, &.{});
    var buf: [8192]u8 = undefined;
    // TODO: need to allocate a bigger buffer if we ever exceed this
    std.debug.assert(needle.len <= buf.len);
    if (needle.len == 0) return true;
    var len: usize = 0;
    while (true) {
        const n = reader.interface.readSliceShort(buf[len..]) catch return reader.err.?;
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

fn prompt(io: std.Io, str: []const u8) !enum { yes, no } {
    var write_buf: [300]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &write_buf);

    var read_buf: [100]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &read_buf);
    while (true) {
        stderr.interface.print("{s} [yes/no] ", .{str}) catch return stderr.err.?;
        stderr.interface.flush() catch return stderr.err.?;

        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.StreamTooLong => errExit("input too long", .{}),
        } orelse errExit("unexpected end of stdin", .{});
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.eql(u8, trimmed, "yes")) return .yes;
        if (std.mem.eql(u8, trimmed, "no")) return .no;
        stderr.interface.print("\nerror: unknown response '{f}'\n", .{std.zig.fmtString(trimmed)}) catch return stderr.err.?;
    }
}

fn promptLine(io: std.Io, allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
    var write_buf: [300]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &write_buf);

    stderr.interface.print("{s}", .{str}) catch return stderr.err.?;
    stderr.interface.flush() catch return stderr.err.?;

    var read_buf: [1000]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &read_buf);
    const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.StreamTooLong => errExit("input too long", .{}),
    } orelse errExit("unexpected end of stdin", .{});
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    if (trimmed.len == 0) errExit("commit message cannot be empty", .{});
    return try allocator.dupe(u8, trimmed);
}

fn runExitCode(
    io: std.Io,
    argv: []const []const u8,
    maybe_cwd: ?[]const u8,
) !u8 {
    try logRun(io, argv, maybe_cwd);
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = childCwd(maybe_cwd) });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => errExit("{s} {f}", .{ argv[0], term }),
    };
}

fn childCwd(maybe_cwd: ?[]const u8) std.process.Child.Cwd {
    return if (maybe_cwd) |cwd| .{ .path = cwd } else .inherit;
}

fn updateExecNoreturn(
    io: std.Io,
    arena: std.mem.Allocator,
    args: []const [:0]const u8,
    src: []const u8,
    src_lock_path: []const u8,
    master: *const [40]u8,
) !noreturn {
    const exe = try std.process.executablePathAlloc(io, arena);
    defer arena.free(exe);
    // exe must be absolute path since we run zig from the src directory
    std.debug.assert(std.fs.path.isAbsolute(exe));
    const exe_lock_path = try std.mem.concat(arena, u8, &.{ exe, ".lock" });
    defer arena.free(exe_lock_path);

    {
        var lock = try LockFile.lock(io, src_lock_path);
        defer lock.unlock(io);
        try run(io, &.{ "git", "-C", src, "reset", "--hard", master }, null);
        // should be safe from deadlock since lock order is always the same (src then exe)
        var exe_lock = try LockFile.lock(io, exe_lock_path);
        defer exe_lock.unlock(io);
        const prefix = "-Dsha=";
        var sha_arg_buf: [prefix.len + 40]u8 = undefined;
        const sha_arg = std.fmt.bufPrint(&sha_arg_buf, prefix ++ "{s}", .{master}) catch unreachable;
        try run(io, &.{
            "zig",
            "build",
            "install",
            sha_arg,
            "--prefix",
            std.fs.path.dirname(exe).?,
        }, src);
    }

    // Re-exec the newly built dof with --no-update plus all original args.
    const argv = try arena.alloc([]const u8, args.len + 1);
    argv[0] = exe;
    argv[1] = "--no-update";
    for (args[1..], argv[2..]) |a, *dst| dst.* = a;
    if (builtin.os.tag == .windows) {
        var child = try std.process.spawn(io, .{ .argv = argv });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| std.process.exit(code),
            else => errExit("{s} {f}", .{ exe, term }),
        }
    } else {
        const err = std.process.replace(io, .{ .argv = argv });
        errExit("exec '{s}' failed: {t}", .{ exe, err });
    }
}

fn fetchDofMaster(io: std.Io, src: []const u8, src_lock_path: []const u8, arena: std.mem.Allocator) ![40]u8 {
    var lock = try LockFile.lock(io, src_lock_path);
    defer lock.unlock(io);

    const src_exists = blk: {
        var dir = std.Io.Dir.cwd().openDir(io, src, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => |e| errExit("openDir '{s}' failed with {t}", .{ src, e }),
        };
        dir.close(io);
        break :blk true;
    };

    if (!src_exists) {
        try run(io, &.{ "git", "clone", "https://github.com/marler8997/dof", src, "-b", "master" }, null);
    }
    try run(io, &.{ "git", "-C", src, "fetch", "origin", "master" }, null);

    const fetch_head_path = try std.fs.path.join(arena, &.{ src, ".git", "FETCH_HEAD" });
    defer arena.free(fetch_head_path);
    return readSha(io, fetch_head_path);
}

fn readSha(io: std.Io, path: []const u8) ![40]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [100]u8 = undefined;
    var reader = file.reader(io, &buf);
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
    io: std.Io,
    argv: []const []const u8,
    maybe_cwd: ?[]const u8,
) !void {
    try logRun(io, argv, maybe_cwd);
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = childCwd(maybe_cwd) });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) errExit("{s} exited with non-zero exit code {}", .{ argv[0], code }),
        else => errExit("{s} {f}", .{ argv[0], term }),
    }
}

const GitStatus = enum { clean, dirty };
fn gitStatus(io: std.Io, repo_path: []const u8) !GitStatus {
    const argv: []const []const u8 = &.{ "git", "-C", repo_path, "status", "--porcelain" };
    try logRun(io, argv, null);
    var child = try std.process.spawn(io, .{ .argv = argv, .stdout = .pipe });
    var reader = child.stdout.?.readerStreaming(io, &.{});
    var write_buf: [1000]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &write_buf);
    const len = reader.interface.streamRemaining(&stderr_writer.interface) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.WriteFailed => return stderr_writer.err.?,
    };
    stderr_writer.interface.flush() catch return stderr_writer.err.?;
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) errExit("{s} exited with non-zero exit code {}", .{ argv[0], code }),
        else => errExit("{s} {f}", .{ argv[0], term }),
    }
    return if (len == 0) .clean else .dirty;
}

fn logRun(io: std.Io, argv: []const []const u8, maybe_cwd: ?[]const u8) !void {
    var buf: [1024]u8 = undefined;
    var f = std.Io.File.stderr().writerStreaming(io, &buf);
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

test "lex directive and path" {
    const text = "emacs-load-file emacs/init.el\n";
    const directive = lex(text, 0);
    try std.testing.expectEqual(Token.Tag.identifier, directive.tag);
    try std.testing.expectEqualStrings("emacs-load-file", text[directive.start..directive.end]);
    const path = lex(text, directive.end);
    try std.testing.expectEqual(Token.Tag.identifier, path.tag);
    try std.testing.expectEqualStrings("emacs/init.el", text[path.start..path.end]);
    try std.testing.expectEqual(Token.Tag.eof, lex(text, path.end).tag);
}

test "getLineCol" {
    const text = "ab\ncd";
    try std.testing.expectEqual(.{ 1, 1 }, getLineCol(text, 0));
    try std.testing.expectEqual(.{ 2, 2 }, getLineCol(text, 4));
}

fn testEnviron(comptime entries: []const [*:0]const u8) std.process.Environ {
    return .{ .block = .{ .slice = entries ++ &[_:null]?[*:0]const u8{} } };
}

test "getEnv treats empty as unset" {
    // windows reads the process environment, it can't take a test block
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const environ = testEnviron(&.{ "HOME=/home/u", "EMPTY=" });
    try std.testing.expectEqualStrings("/home/u", (try getEnv(std.testing.allocator, environ, "HOME")).?);
    try std.testing.expectEqual(null, try getEnv(std.testing.allocator, environ, "EMPTY"));
    try std.testing.expectEqual(null, try getEnv(std.testing.allocator, environ, "MISSING"));
}

test "appDataDir matches std.fs.getAppDataDir from zig 0.15" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Case = struct { environ: std.process.Environ, expected: []const u8 };
    const cases: []const Case = switch (builtin.os.tag) {
        .macos => &.{
            .{ .environ = testEnviron(&.{"HOME=/home/u"}), .expected = "/home/u/Library/Application Support/dof" },
            .{ .environ = testEnviron(&.{ "HOME=/home/u", "XDG_DATA_HOME=/xdg" }), .expected = "/home/u/Library/Application Support/dof" },
        },
        else => &.{
            .{ .environ = testEnviron(&.{"HOME=/home/u"}), .expected = "/home/u/.local/share/dof" },
            .{ .environ = testEnviron(&.{ "HOME=/home/u", "XDG_DATA_HOME=/xdg" }), .expected = "/xdg/dof" },
            .{ .environ = testEnviron(&.{ "HOME=/home/u", "XDG_DATA_HOME=" }), .expected = "/home/u/.local/share/dof" },
        },
    };
    for (cases) |case| {
        const path = try appDataDir(std.testing.allocator, case.environ);
        defer std.testing.allocator.free(path);
        try std.testing.expectEqualStrings(case.expected, path);
    }
}

test "scanFile finds a needle across its buffer boundary" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // scanFile reads 8192 bytes at a time, put the needle across that boundary
    var data: [8192 + 100]u8 = @splat('a');
    @memcpy(data[8190..][0..6], "needle");
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = &data });

    const file = try tmp.dir.openFile(io, "f", .{});
    defer file.close(io);
    try std.testing.expect(try scanFile(io, file, "needle"));
    const file2 = try tmp.dir.openFile(io, "f", .{});
    defer file2.close(io);
    try std.testing.expect(!try scanFile(io, file2, "missing"));
}

test filesEqual {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // bigger than filesEqual's 4096 byte buffers
    var data: [10000]u8 = @splat('x');
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = &data });
    try tmp.dir.writeFile(io, .{ .sub_path = "same", .data = &data });
    data[9999] = 'y';
    try tmp.dir.writeFile(io, .{ .sub_path = "differs_at_end", .data = &data });
    try tmp.dir.writeFile(io, .{ .sub_path = "shorter", .data = data[0..9999] });

    for ([_]struct { []const u8, bool }{
        .{ "same", true },
        .{ "differs_at_end", false },
        .{ "shorter", false },
    }) |case| {
        const name, const expected = case;
        const b = try tmp.dir.openFile(io, name, .{});
        defer b.close(io);
        // filesEqual reads from the current position, so open `a` fresh each time
        const a = try tmp.dir.openFile(io, "a", .{});
        defer a.close(io);
        try std.testing.expectEqual(expected, try filesEqual(io, a, b));
    }
}
