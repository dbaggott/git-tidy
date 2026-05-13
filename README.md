# git-tidy

A `git` subcommand that cleans up a repository: prunes stale worktrees, deletes branches whose upstream is gone, fast-forwards the default branch, and runs `git gc`.

```
$ git tidy
==> git fetch --all --prune
==> git worktree prune
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

Pick one. All three are equivalent — they install the same script.

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

Installs to `~/.local/bin/git-tidy`. Override the install prefix with `PREFIX=/usr/local`. Upgrade with `git tidy --self-upgrade`.

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

## Requirements

Bash 3.2+ and `git`. macOS ships bash 3.2, which is supported — no separate `brew install bash` needed.

## License

MIT — see [LICENSE](LICENSE).
