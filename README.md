# git-tidy

A `git` subcommand that cleans up a repository: prunes stale worktrees, removes detached worktree folders left under `.worktree/` or `.worktrees/`, deletes branches whose upstream is gone, fast-forwards the default branch, and runs `git gc`.

```
$ git tidy
==> git fetch --all --prune
==> git worktree prune
==> cleaning 1 detached worktree folder(s)
  removed /path/to/repo/.worktrees/abandoned-spike
==> cleaning 3 stale branch(es)
  removed worktree .worktrees/old-feature
  deleted branch old-feature
  ...
==> git pull --ff-only
==> git gc
==> done
```

Run with `-i` for an interactive prompt before each destructive action, or pass a directory to tidy every repo found beneath it.

## Install

Pick one. Homebrew and the one-liner both install the latest [release](https://github.com/dbaggott/git-tidy/releases); from source installs whatever you have checked out.

### Homebrew (recommended on macOS)

```sh
brew tap dbaggott/tap
brew install git-tidy
```

Upgrade with `brew upgrade git-tidy`.

### One-liner installer

```sh
curl -fsSL https://raw.githubusercontent.com/dbaggott/git-tidy/main/install.sh | bash
```

Installs the latest release to `~/.local/bin/git-tidy`. Override the install prefix with `PREFIX=/usr/local`, or pin a version with `REF=v0.2.0` (`REF=main` installs unreleased work). Upgrade with `git tidy --self-upgrade`.

### From source

```sh
git clone https://github.com/dbaggott/git-tidy.git
cd git-tidy
make install                        # installs to ~/.local/bin
# or: make install PREFIX=/usr/local
```

Upgrade with `git pull && make install`.

## Usage

```
git tidy [-i|--interactive] [DIR]
```

| Flag | Effect |
|------|--------|
| `-i`, `--interactive` | Prompt `y/N` before each destructive action |
| `-V`, `--version` | Print version |
| `--self-upgrade` | Re-run the installer to fetch the latest version |
| `-h`, `--help` | Show full help |

Run `git tidy --help` for details on what each cleanup step does and what it skips.

## Releasing

Bump `VERSION=` in the `git-tidy` script and merge to main. CI tags the
commit `v<VERSION>`, publishes a GitHub Release with generated notes, and
updates the Homebrew tap formula — merging the bump is the whole release.

## Requirements

Bash 3.2+ and `git`. macOS ships bash 3.2, which is supported — no separate `brew install bash` needed.

## License

MIT — see [LICENSE](LICENSE).
