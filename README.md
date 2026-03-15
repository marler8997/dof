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
- sync your dotfiles repo (pull or commit/push/pull)
- execute `config.dof`

If you have uncommitted changes, `dof` will execute your `config.dof` first, then ask if you want to commit and push your changes before pulling any updates.
