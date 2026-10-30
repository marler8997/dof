# dof

Keep your dotfiles in sync on any platform with a single command.

## Install

```
curl https://getdof.github.io/dof.sh | sh
```

Or windows:

```batch
powershell -c "irm https://getdof.github.io/dof.ps1 | iex"
```

> NOTE: dof currently depends on both `git` and `zig` ([anyzig](https://github.com/marler8997/anyzig) recommended) being in `PATH`. The install scripts use git to clone the source for dof and zig to build it on the host's machine.

## Configure

In your dotfiles repo, create a `config.dof`. This is a small text file that contains actions for dof to perform like creating symlinks or copying files.

```
# Link Emacs config
emacs-load-file emacs/init.el

# Copy Claude config to home directory
install-home .claude
```

After that, run `dof path PATH_TO_REPO` to configure where your dotfiles repo lives, e.g.

```
dof path ~/dotfiles
```

## Maintain

Whenever you want to pull or push changes to your dotfiles, just run `dof` and it will:

- update itself
- sync your dotfiles repo
- execute `config.dof`

### How dof syncs your repo

To keep things simple and avoid edge cases, dof limits commits to having only 1 parent. With no merges, catching up with the remote, publishing your changes, and both at once are the same operation: put your local commits on top of the remote branch and push.

Every time you run `dof` it fetches the remote branch. If you have no local changes, it fast-forwards to the remote and executes `config.dof`.

If you have local changes (uncommitted changes or commits the remote doesn't have), dof first executes `config.dof` from your repo as it is, so running `dof` is how you test your changes. Then it shows them: your unpushed commits, and the diff of each changed file (including untracked files), except that large diffs are shortened to the file's name and how many lines changed. Then it asks what to do:

```
[v]iew diff, [p]ush, [s]ave for later, [d]iscard, [q]uit?
```

- **view diff**: only offered when a diff was shortened. Print every diff in full, then ask again.
- **push**: commit any uncommitted changes (asking for a message), rebase your commits onto the remote branch and push them, then execute `config.dof`. If the rebase has a conflict, dof aborts it, which leaves your repo exactly as it was, and tells you which files conflicted so you can resolve them yourself. The rebase replays your commits one at a time, so a merge commit is flattened into the commits it merged.
- **save for later**: commit them, including untracked files, to a new local branch named `dof-saved-<date>-<time>`, then sync with the remote as if you had no local changes.
- **discard**: delete the local branch `dof-discarded` left by your previous discard, commit your changes, including untracked files, to a new `dof-discarded` branch, then sync with the remote as if you had no local changes. If you didn't mean to, your changes are still on that branch.
- **quit**: stop, leaving your changes as they are (already applied). This is the usual answer while you're still editing your dotfiles.

dof never deletes your work.
