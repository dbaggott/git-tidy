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
# Pin branch/worktree cleanup to keep: this fixture's branches all count as
# finished (no commits of their own), and keeping them both isolates the
# detached-folder assertions and exercises the keep configuration.
git -C "$repo" config tidy.remote.branches keep
git -C "$repo" config tidy.local.branches keep
git -C "$repo" config tidy.local.worktrees keep
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
assert "keep config leaves finished branch alone" \
  git -C "$repo" show-ref --verify --quiet refs/heads/wt-clean
assert_not "keep config is quiet about kept branches" quiet grep "skip branch" <<<"$out"
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
# Unfinished work on top keeps the branch and worktree alive through tidy.
echo wip > "$sandbox/sync-wt/wip.txt"
git -C "$sandbox/sync-wt" add wip.txt
git -C "$sandbox/sync-wt" commit -qm wip

sync_status=0
out_sync="$( (cd "$sync" && run_tidy) 2>&1 )" || sync_status=$?
assert "tidy exits 0 in sync fixture" test "$sync_status" -eq 0
assert "default branch ff-pulled despite another worktree" \
  test "$(git -C "$sync" rev-parse HEAD)" = "$(git -C "$sync" rev-parse "origin/$branch")"
assert "pull reported" quiet grep -- "git pull --ff-only" <<<"$out_sync"
assert_not "no sync skip when only a pull is needed" quiet grep "skip sync" <<<"$out_sync"

git -C "$sync" switch -qc parked
# Unfinished work parks the branch; without it tidy would clean it up.
echo parked-work > "$sync/parked.txt"
git -C "$sync" add parked.txt
git -C "$sync" commit -qm parked-work
parked_status=0
out_parked="$( (cd "$sync" && run_tidy) 2>&1 )" || parked_status=$?
assert "tidy exits 0 on parked branch" test "$parked_status" -eq 0
assert "switch away still blocked by other worktree" \
  quiet grep "skip sync to $branch (1 other worktree(s) present)" <<<"$out_parked"
assert "still on parked branch" \
  test "$(git -C "$sync" symbolic-ref --short HEAD)" = parked

# --- finished branches: the full remote + local + worktree lifecycle --------
# One clone ("life") holds branches in every state of the PR lifecycle; a
# second clone ("dev") plays the server side — merging, squash-merging, and
# deleting branches on origin.
life="$sandbox/life"
git clone -q "$sandbox/origin.git" "$life" 2>/dev/null
git -C "$life" config user.email tidy-test@example.invalid
git -C "$life" config user.name tidy-test
base="origin/$branch"

# merged-plain: pushed, then merged into the default branch
git -C "$life" switch -qc merged-plain --no-track "$base"
echo mp > "$life/mp.txt"
git -C "$life" add mp.txt
git -C "$life" commit -qm merged-plain
git -C "$life" push -q -u origin merged-plain

# squashed: pushed, then squash-merged; left checked out in the main
# checkout so tidy has to switch away before it can delete the branch
git -C "$life" switch -qc squashed --no-track "$base"
echo sq > "$life/sq.txt"
git -C "$life" add sq.txt
git -C "$life" commit -qm squashed-1
echo sq2 >> "$life/sq.txt"
git -C "$life" commit -qam squashed-2
git -C "$life" push -q -u origin squashed

# swt: pushed and squash-merged, checked out in a worktree
git -C "$life" worktree add -q "$life/.worktrees/swt" -b swt "$branch"
echo swt > "$life/.worktrees/swt/swt.txt"
git -C "$life/.worktrees/swt" add swt.txt
git -C "$life/.worktrees/swt" commit -qm swt-work
git -C "$life/.worktrees/swt" push -q -u origin swt

# live: pushed work the default branch does not have — branch and remote stay
git -C "$life" switch -qc live --no-track "$base"
echo live > "$life/live.txt"
git -C "$life" add live.txt
git -C "$life" commit -qm live-work
git -C "$life" push -q -u origin live

# unpushed: local-only work — must never be touched
git -C "$life" switch -qc unpushed --no-track "$base"
echo up > "$life/up.txt"
git -C "$life" add up.txt
git -C "$life" commit -qm unpushed-work

# gone-unmerged: pushed, then the remote branch deleted without merging
# (a PR closed unmerged) — must be kept and reported
git -C "$life" switch -qc gone-unmerged --no-track "$base"
echo gu > "$life/gu.txt"
git -C "$life" add gu.txt
git -C "$life" commit -qm gone-unmerged-work
git -C "$life" push -q -u origin gone-unmerged

# never-started: no commits of its own
git -C "$life" branch -q never-started "$base"

# live-wt: a worktree with unfinished committed work — must survive
git -C "$life" worktree add -q "$life/.worktrees/live-wt" -b live-wt "$branch"
echo lw > "$life/.worktrees/live-wt/lw.txt"
git -C "$life/.worktrees/live-wt" add lw.txt
git -C "$life/.worktrees/live-wt" commit -qm live-wt-work

# dirty-wt: finished branch, but unsaved work in its worktree — must survive
git -C "$life" worktree add -q "$life/.worktrees/dirty-wt" -b dirty-wt "$branch"
echo precious > "$life/.worktrees/dirty-wt/precious.txt"

# The server side: merge merged-plain, squash-merge squashed and swt, delete
# gone-unmerged's remote branch, and add a merged branch nothing here tracks.
dev="$sandbox/dev"
git clone -q "$sandbox/origin.git" "$dev" 2>/dev/null
git -C "$dev" config user.email tidy-test@example.invalid
git -C "$dev" config user.name tidy-test
quiet git -C "$dev" merge --no-ff -m merge-mp origin/merged-plain
quiet git -C "$dev" merge --squash origin/squashed
git -C "$dev" commit -qm "squashed (#1)"
quiet git -C "$dev" merge --squash origin/swt
git -C "$dev" commit -qm "swt (#2)"
git -C "$dev" push -q origin "HEAD:refs/heads/$branch"
git -C "$dev" push -q origin --delete gone-unmerged
git -C "$dev" push -q origin "refs/heads/$branch:refs/heads/theirs-merged"

git -C "$life" switch -q squashed
life_status=0
out_life="$( (cd "$life" && run_tidy) 2>&1 )" || life_status=$?

assert "tidy exits 0 in lifecycle repo" test "$life_status" -eq 0

remote_heads="$(git ls-remote --heads "$sandbox/origin.git")"
assert_not "merged remote branch deleted" quiet grep "refs/heads/merged-plain$" <<<"$remote_heads"
assert_not "squash-merged remote branch deleted" quiet grep "refs/heads/squashed$" <<<"$remote_heads"
assert_not "squash-merged worktree remote branch deleted" quiet grep "refs/heads/swt$" <<<"$remote_heads"
assert "remote branch with unfinished work kept" quiet grep "refs/heads/live$" <<<"$remote_heads"
assert "untracked merged remote branch kept under tracked scope" \
  quiet grep "refs/heads/theirs-merged$" <<<"$remote_heads"

assert_not "merged local branch deleted" quiet git -C "$life" show-ref --verify refs/heads/merged-plain
assert_not "squash-merged local branch deleted" quiet git -C "$life" show-ref --verify refs/heads/squashed
assert_not "squash-merged worktree branch deleted" quiet git -C "$life" show-ref --verify refs/heads/swt
assert_not "never-started branch deleted" quiet git -C "$life" show-ref --verify refs/heads/never-started
assert "live branch kept" quiet git -C "$life" show-ref --verify refs/heads/live
assert "unpushed branch kept" quiet git -C "$life" show-ref --verify refs/heads/unpushed
assert "gone-unmerged branch kept" quiet git -C "$life" show-ref --verify refs/heads/gone-unmerged
assert "gone-unmerged branch reported" quiet grep "keep gone-unmerged (upstream gone)" <<<"$out_life"

assert "squash-merged worktree removed" test ! -e "$life/.worktrees/swt"
assert "worktree with unfinished work kept" test -d "$life/.worktrees/live-wt"
assert "dirty worktree kept" test -f "$life/.worktrees/dirty-wt/precious.txt"
assert "dirty worktree reported" quiet grep "skip worktree .*dirty-wt (working tree not clean)" <<<"$out_life"

assert "main checkout switched off finished branch" \
  test "$(git -C "$life" symbolic-ref --short HEAD)" = "$branch"
assert "switch reported" quiet grep "switched .* to $branch" <<<"$out_life"
assert "default branch ff-pulled after cleanup" \
  test "$(git -C "$life" rev-parse HEAD)" = "$(git -C "$life" rev-parse "origin/$branch")"

# Second pass: widened remote scope picks up the untracked merged branch,
# and an invalid decision value warns and falls back to delete.
git -C "$life" config tidy.remote.branchScope all
git -C "$life" config tidy.local.detachedFolders bogus
life2_status=0
out_life2="$( (cd "$life" && run_tidy) 2>&1 )" || life2_status=$?
assert "tidy exits 0 on second lifecycle pass" test "$life2_status" -eq 0
remote_heads="$(git ls-remote --heads "$sandbox/origin.git")"
assert_not "untracked merged remote branch deleted with scope=all" \
  quiet grep "refs/heads/theirs-merged$" <<<"$remote_heads"
assert "remote branch with unfinished work still kept" quiet grep "refs/heads/live$" <<<"$remote_heads"
assert "invalid decision value warns" \
  quiet grep "ignoring invalid tidy.local.detachedFolders" <<<"$out_life2"

# --- safety guards around checked-out finished branches ---------------------
guard="$sandbox/guard"
git clone -q "$sandbox/origin.git" "$guard" 2>/dev/null
git -C "$guard" config user.email tidy-test@example.invalid
git -C "$guard" config user.name tidy-test

# Running from inside a worktree on a finished branch: tidy must not remove
# the worktree it is standing in.
git -C "$guard" worktree add -q "$guard/.worktrees/inside" -b inside "$branch"
inside_status=0
out_inside="$( (cd "$guard/.worktrees/inside" && run_tidy) 2>&1 )" || inside_status=$?
assert "tidy exits 0 from inside a finished-branch worktree" test "$inside_status" -eq 0
assert "current worktree not removed" test -d "$guard/.worktrees/inside"
assert "current worktree's branch kept" quiet git -C "$guard" show-ref --verify refs/heads/inside
assert "current worktree skip reported" \
  quiet grep "skip branch inside (checked out in current worktree" <<<"$out_inside"

# Main checkout on a finished branch with uncommitted tracked changes: the
# switch-away is blocked, so the branch survives.
git -C "$guard" switch -qc parked-dirty --no-track "origin/$branch"
echo dirt >> "$guard/file.txt"
dirty_status=0
out_dirty="$( (cd "$guard" && run_tidy) 2>&1 )" || dirty_status=$?
assert "tidy exits 0 with dirty main checkout" test "$dirty_status" -eq 0
assert "dirty checkout's finished branch kept" quiet git -C "$guard" show-ref --verify refs/heads/parked-dirty
assert "still on the dirty finished branch" \
  test "$(git -C "$guard" symbolic-ref --short HEAD)" = parked-dirty
assert "dirty checkout skip reported" \
  quiet grep "skip branch parked-dirty (checked out at .*tracked files have uncommitted changes)" <<<"$out_dirty"

# Default branch checked out in another worktree: the switch fails, so the
# finished branch survives with the failure reported.
git -C "$guard" checkout -q -- file.txt
git -C "$guard" worktree add -q "$guard/.worktrees/wt-main" "$branch"
swfail_status=0
out_swfail="$( (cd "$guard" && run_tidy) 2>&1 )" || swfail_status=$?
assert "tidy exits 0 when switch is blocked" test "$swfail_status" -eq 0
assert "switch-blocked finished branch kept" quiet git -C "$guard" show-ref --verify refs/heads/parked-dirty
assert "still on the switch-blocked branch" \
  test "$(git -C "$guard" symbolic-ref --short HEAD)" = parked-dirty
assert "switch failure reported" \
  quiet grep "skip branch parked-dirty (cannot switch to $branch" <<<"$out_swfail"

# A branch that conflicts with the default branch is not finished: the
# merge-tree probe must answer "keep", locally and on origin.
git -C "$guard" switch -qc conflicted --no-track "origin/$branch"
echo mine > "$guard/sub/inner.txt"
git -C "$guard" commit -qam conflicted-work
git -C "$guard" push -q -u origin conflicted
echo theirs > "$dev/sub/inner.txt"
git -C "$dev" commit -qam conflicting-change
git -C "$dev" push -q origin "HEAD:refs/heads/$branch"
conflict_status=0
quiet sh -c "cd '$guard' && '$TIDY_BASH' '$tidy_dir/git-tidy'" || conflict_status=$?
assert "tidy exits 0 with a conflicting branch" test "$conflict_status" -eq 0
assert "conflicting local branch kept" quiet git -C "$guard" show-ref --verify refs/heads/conflicted
assert "conflicting remote branch kept" \
  quiet grep "refs/heads/conflicted$" <<<"$(git ls-remote --heads "$sandbox/origin.git")"
assert_not "finished branch deleted once no longer checked out" \
  quiet git -C "$guard" show-ref --verify refs/heads/parked-dirty

# --- tidy.remote.branches keep leaves a genuinely finished remote alone -----
rk="$sandbox/rk"
git clone -q "$sandbox/origin.git" "$rk" 2>/dev/null
git -C "$rk" config user.email tidy-test@example.invalid
git -C "$rk" config user.name tidy-test
git -C "$rk" config tidy.remote.branches keep
git -C "$rk" switch -qc rk-merged --no-track "origin/$branch"
echo rk > "$rk/rk.txt"
git -C "$rk" add rk.txt
git -C "$rk" commit -qm rk-work
git -C "$rk" push -q -u origin rk-merged
git -C "$dev" fetch -q origin
quiet git -C "$dev" merge --no-ff -m merge-rk origin/rk-merged
git -C "$dev" push -q origin "HEAD:refs/heads/$branch"
git -C "$rk" switch -q "$branch"
rk_status=0
quiet sh -c "cd '$rk' && '$TIDY_BASH' '$tidy_dir/git-tidy'" || rk_status=$?
assert "tidy exits 0 with remote keep" test "$rk_status" -eq 0
assert "remote keep leaves merged remote branch" \
  quiet grep "refs/heads/rk-merged$" <<<"$(git ls-remote --heads "$sandbox/origin.git")"
assert_not "merged local branch still deleted under remote keep" \
  quiet git -C "$rk" show-ref --verify refs/heads/rk-merged

# --- remote-less repo: finished means contained in the local default branch -
solo="$sandbox/solo"
git init -q -b main "$solo"
git -C "$solo" config user.email tidy-test@example.invalid
git -C "$solo" config user.name tidy-test
echo a > "$solo/a.txt"
git -C "$solo" add a.txt
git -C "$solo" commit -qm initial
git -C "$solo" branch -q done-work
git -C "$solo" switch -qc active
echo b > "$solo/b.txt"
git -C "$solo" add b.txt
git -C "$solo" commit -qm active-work
git -C "$solo" switch -q main
solo_status=0
out_solo="$( (cd "$solo" && run_tidy) 2>&1 )" || solo_status=$?
assert "tidy exits 0 in remote-less repo" test "$solo_status" -eq 0
assert_not "contained branch deleted in remote-less repo" \
  quiet git -C "$solo" show-ref --verify refs/heads/done-work
assert "branch with unique work kept in remote-less repo" \
  quiet git -C "$solo" show-ref --verify refs/heads/active
assert "sync skip reported without origin" \
  quiet grep "skip sync to main (cannot compare HEAD to origin/main)" <<<"$out_solo"

if (( failures > 0 )); then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
