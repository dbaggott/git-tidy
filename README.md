# git-tidy

A `git` subcommand that cleans up a repository: deletes remote and local branches whose work is finished, removes their worktrees, cleans up detached worktree folders left under `.worktree/` or `.worktrees/`, fast-forwards the default branch, and runs `git gc`.

```
$ git tidy
==> git fetch --all --prune
==> git worktree prune
==> cleaning 1 detached worktree folder(s)
  removed /path/to/repo/.worktrees/abandoned-spike
==> cleaning 2 finished remote branch(es)
  deleted origin/old-feature
  deleted origin/squashed-feature
==> cleaning 2 finished local branch(es)
  old-feature:
    removed worktree .worktrees/old-feature
    deleted branch
  squashed-feature:
    switched /path/to/repo to main
    deleted branch
==> git pull --ff-only
==> git gc
==> done
```

A branch counts as **finished** when the default branch already contains its work — merged, squash- or rebase-merged (detected by content, no forge API needed; requires git ≥ 2.38), or never started (no commits of its own). Work that isn't safely somewhere else is never destroyed: branches with unmerged commits are left alone (even when their upstream is gone — e.g. a PR closed unmerged — those are reported), worktrees are only removed when clean, and detached folders only when every file's content is already in git's object database.

Run with `-i` for an interactive prompt before each destructive action, or pass a directory to tidy every repo found beneath it.

## Configuration

Each cleanup decision is configurable via `git config` (per repo, or `--global` for your default workflow). Every decision accepts `delete`, `keep` (leave as-is — no per-item narration, just a one-line summary when candidates are being held back), or `prompt`; the default is `delete`. Work at risk is always reported regardless of configuration: branches whose upstream vanished with unmerged work, and detached folders holding unsaved files.

| Key | Decides what happens to |
|-----|------------------------|
| `tidy.remote.branches` | finished branches on origin |
| `tidy.local.branches` | finished local branches |
| `tidy.local.worktrees` | worktrees checked out on a finished branch |
| `tidy.local.detachedFolders` | detached folders under `.worktree[s]/` |

`tidy.remote.branchScope` controls which origin branches are candidates: `tracked` (default) considers only branches some local branch tracks — i.e. yours — while `all` considers every branch on origin (for repos where you want one tidy run to sweep everything). Either way, a remote branch is left alone while a local branch is still building on it with unfinished work of its own, and deletion is lease-protected: if origin moved after git-tidy's fetch, the delete is refused rather than destroying the newer push.

```sh
# Example: never touch origin, ask before removing worktrees
git config --global tidy.remote.branches keep
git config --global tidy.local.worktrees prompt

# See every tidy setting in effect (all scopes)
git config --get-regexp '^tidy\.'
```

`-i` upgrades every configured `delete` to `prompt` for that run; `keep` stays `keep`.

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
