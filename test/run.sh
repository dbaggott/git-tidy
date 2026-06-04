#!/usr/bin/env bash
# Sandbox tests for git-tidy: build throwaway repos, fabricate detached
# worktree folders, and assert on what tidy removes, skips, and reports.
#
# Run via `make test`. Set TIDY_BASH to test git-tidy under a specific bash
# (e.g. TIDY_BASH=/bin/bash exercises macOS's stock 3.2).
set -euo pipefail

tidy_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TIDY_BASH="${TIDY_BASH:-bash}"
run_tidy() { "$TIDY_BASH" "$tidy_dir/git-tidy"; }

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/git-tidy-test.XXXXXX")"
cleanup() {
  chmod -R u+rwX "$sandbox" 2>/dev/null || true
  rm -rf "$sandbox"
}
trap cleanup EXIT

failures=0
quiet() { "$@" >/dev/null 2>&1; }
assert() {
  local desc="$1"
  shift
  if "$@"; then
    echo "ok: $desc"
  else
    echo "FAIL: $desc"
    failures=$((failures + 1))
  fi
}
assert_not() {
  local desc="$1"
  shift
  if "$@"; then
    echo "FAIL: $desc"
    failures=$((failures + 1))
  else
    echo "ok: $desc"
  fi
}

# --- fixture: bare origin plus a clone with one commit (file, subdir, symlink)
git init -q --bare "$sandbox/origin.git"
repo="$sandbox/repo"
git clone -q "$sandbox/origin.git" "$repo" 2>/dev/null
git -C "$repo" config user.email tidy-test@example.invalid
git -C "$repo" config user.name tidy-test
echo hello > "$repo/file.txt"
mkdir "$repo/sub"
echo nested > "$repo/sub/inner.txt"
ln -s file.txt "$repo/link.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm initial
branch="$(git -C "$repo" symbolic-ref --short HEAD)"
git -C "$repo" push -q origin "HEAD:refs/heads/$branch"
git -C "$repo" fetch -q origin
git -C "$repo" branch -q --set-upstream-to="origin/$branch"

# Worktrees under .worktrees/: two get detached (admin record dropped, folder
# kept — the leftover this feature targets), one stays live.
git -C "$repo" worktree add -q .worktrees/wt-clean -b wt-clean
git -C "$repo" worktree add -q .worktrees/wt-dirty -b wt-dirty
git -C "$repo" worktree add -q .worktrees/wt-live -b wt-live
echo "precious unsaved thing" > "$repo/.worktrees/wt-dirty/notes.txt"
rm -rf "$repo/.git/worktrees/wt-clean" "$repo/.git/worktrees/wt-dirty"
git -C "$repo" worktree prune

# An empty leftover, a registered worktree nested one level deeper than the
# scan, and a folder find cannot fully traverse.
mkdir "$repo/.worktrees/empty-dir"
git -C "$repo" worktree add -q .worktrees/nested/inner -b nested-inner
mkdir -p "$repo/.worktrees/locked/secret"
echo sealed > "$repo/.worktrees/locked/secret/data.txt"
chmod 000 "$repo/.worktrees/locked/secret"

tidy_status=0
out="$( (cd "$repo" && run_tidy) 2>&1 )" || tidy_status=$?

assert "tidy exits 0" test "$tidy_status" -eq 0
assert "clean detached folder removed" test ! -e "$repo/.worktrees/wt-clean"
assert "empty detached folder removed" test ! -e "$repo/.worktrees/empty-dir"
assert "dirty detached folder kept" test -f "$repo/.worktrees/wt-dirty/notes.txt"
assert "dirty detached folder reported" quiet grep "skip .*wt-dirty (unsaved work, e.g. notes.txt)" <<<"$out"
assert "registered worktree untouched" quiet git -C "$repo/.worktrees/wt-live" rev-parse --verify HEAD
assert "folder containing a nested registered worktree untouched" \
  quiet git -C "$repo/.worktrees/nested/inner" rev-parse --verify HEAD
if [[ "$(id -u)" != 0 ]]; then  # root can read through chmod 000
  assert "unreadable folder kept" test -d "$repo/.worktrees/locked"
  assert "unreadable folder reported" quiet grep "skip .*locked (not fully readable)" <<<"$out"
fi

# --- invoked from inside a registered worktree (main repo found via common dir)
mkdir "$repo/.worktrees/leftover"
echo hello > "$repo/.worktrees/leftover/copy.txt"  # content already committed
inner_status=0
quiet sh -c "cd '$repo/.worktrees/wt-live' && '$TIDY_BASH' '$tidy_dir/git-tidy'" || inner_status=$?
assert "tidy from inside a worktree exits 0" test "$inner_status" -eq 0
assert "detached folder cleaned from inside a worktree" test ! -e "$repo/.worktrees/leftover"

# --- a repo without .worktree[s] produces no detached-folder output
plain="$sandbox/plain"
git clone -q "$sandbox/origin.git" "$plain" 2>/dev/null
plain_status=0
out_plain="$( (cd "$plain" && run_tidy) 2>&1 )" || plain_status=$?
assert "tidy exits 0 in plain repo" test "$plain_status" -eq 0
assert_not "no detached-folder output for plain repo" quiet grep detached <<<"$out_plain"

# --- sync gate: other worktrees block switching, not the ff-only pull
sync="$sandbox/sync"
git clone -q "$sandbox/origin.git" "$sync" 2>/dev/null
git -C "$sync" config user.email tidy-test@example.invalid
git -C "$sync" config user.name tidy-test
git -C "$sync" worktree add -q "$sandbox/sync-wt" -b sync-wt
echo update > "$sandbox/sync-wt/update.txt"
git -C "$sandbox/sync-wt" add update.txt
git -C "$sandbox/sync-wt" commit -qm update
git -C "$sandbox/sync-wt" push -q origin "HEAD:refs/heads/$branch"

sync_status=0
out_sync="$( (cd "$sync" && run_tidy) 2>&1 )" || sync_status=$?
assert "tidy exits 0 in sync fixture" test "$sync_status" -eq 0
assert "default branch ff-pulled despite another worktree" \
  test "$(git -C "$sync" rev-parse HEAD)" = "$(git -C "$sync" rev-parse "origin/$branch")"
assert "pull reported" quiet grep -- "git pull --ff-only" <<<"$out_sync"
assert_not "no sync skip when only a pull is needed" quiet grep "skip sync" <<<"$out_sync"

git -C "$sync" switch -qc parked
parked_status=0
out_parked="$( (cd "$sync" && run_tidy) 2>&1 )" || parked_status=$?
assert "tidy exits 0 on parked branch" test "$parked_status" -eq 0
assert "switch away still blocked by other worktree" \
  quiet grep "skip sync to $branch (1 other worktree(s) present)" <<<"$out_parked"
assert "still on parked branch" \
  test "$(git -C "$sync" symbolic-ref --short HEAD)" = parked

if (( failures > 0 )); then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
