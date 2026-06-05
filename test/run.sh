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
# redundant (no commits of their own), and keeping them both isolates the
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
assert "keep config leaves redundant branch alone" \
  git -C "$repo" show-ref --verify --quiet refs/heads/wt-clean
assert_not "keep config is quiet about kept branches" quiet grep "^    skip" <<<"$out"
assert "kept redundant branches summarized" \
  quiet grep "keeping 4 redundant local branch(es) (tidy.local.branches keep)" <<<"$out"
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

# --- sync gate: unmerged work blocks the switch; worktrees never block
sync="$sandbox/sync"
git clone -q "$sandbox/origin.git" "$sync" 2>/dev/null
git -C "$sync" config user.email tidy-test@example.invalid
git -C "$sync" config user.name tidy-test
git -C "$sync" worktree add -q "$sandbox/sync-wt" -b sync-wt
echo update > "$sandbox/sync-wt/update.txt"
git -C "$sandbox/sync-wt" add update.txt
git -C "$sandbox/sync-wt" commit -qm update
git -C "$sandbox/sync-wt" push -q origin "HEAD:refs/heads/$branch"
# Unmerged work on top keeps the branch and worktree alive through tidy.
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
# Unmerged work parks the branch; without it tidy would clean it up.
echo parked-work > "$sync/parked.txt"
git -C "$sync" add parked.txt
git -C "$sync" commit -qm parked-work
parked_status=0
out_parked="$( (cd "$sync" && run_tidy) 2>&1 )" || parked_status=$?
assert "tidy exits 0 on parked branch" test "$parked_status" -eq 0
assert "unmerged work blocks the switch; the worktree alone does not" \
  quiet grep "skip sync to $branch (on parked: HEAD has 1 commit(s) not on origin/$branch)" <<<"$out_parked"
assert "still on parked branch" \
  test "$(git -C "$sync" symbolic-ref --short HEAD)" = parked

# --- redundant branches: the full remote + local + worktree lifecycle --------
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

# live-wt: a worktree with unmerged committed work — must survive
git -C "$life" worktree add -q "$life/.worktrees/live-wt" -b live-wt "$branch"
echo lw > "$life/.worktrees/live-wt/lw.txt"
git -C "$life/.worktrees/live-wt" add lw.txt
git -C "$life/.worktrees/live-wt" commit -qm live-wt-work

# dirty-wt: redundant branch, but unsaved work in its worktree — must survive
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
assert "remote branch with unmerged work kept" quiet grep "refs/heads/live$" <<<"$remote_heads"
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
assert "worktree with unmerged work kept" test -d "$life/.worktrees/live-wt"
assert "dirty worktree kept" test -f "$life/.worktrees/dirty-wt/precious.txt"
assert "dirty worktree reported" quiet grep "skip (worktree .*dirty-wt not clean)" <<<"$out_life"
assert "branch narration grouped per branch" quiet grep "^  swt:$" <<<"$out_life"
swt_block="$(grep -A2 '^  swt:$' <<<"$out_life")"
assert "worktree removal nests under the branch header" quiet grep "removed worktree" <<<"$swt_block"
assert "branch deletion nests under the branch header" quiet grep "deleted branch" <<<"$swt_block"

assert "main checkout switched off redundant branch" \
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
assert "remote branch with unmerged work still kept" quiet grep "refs/heads/live$" <<<"$remote_heads"
assert "invalid decision value warns" \
  quiet grep "ignoring invalid tidy.local.detachedFolders" <<<"$out_life2"

# --- safety guards around checked-out redundant branches ---------------------
guard="$sandbox/guard"
git clone -q "$sandbox/origin.git" "$guard" 2>/dev/null
git -C "$guard" config user.email tidy-test@example.invalid
git -C "$guard" config user.name tidy-test

# Running from inside a worktree on a redundant branch: tidy must not remove
# the worktree it is standing in.
git -C "$guard" worktree add -q "$guard/.worktrees/inside" -b inside "$branch"
inside_status=0
out_inside="$( (cd "$guard/.worktrees/inside" && run_tidy) 2>&1 )" || inside_status=$?
assert "tidy exits 0 from inside a redundant-branch worktree" test "$inside_status" -eq 0
assert "current worktree not removed" test -d "$guard/.worktrees/inside"
assert "current worktree's branch kept" quiet git -C "$guard" show-ref --verify refs/heads/inside
assert "current worktree skip reported" \
  quiet grep "skip (checked out in current worktree" <<<"$out_inside"
assert "default branch held elsewhere reported as the sync blocker" \
  quiet grep "skip sync to $branch (on inside: $branch checked out at" <<<"$out_inside"

# Main checkout on a redundant branch with uncommitted tracked changes: the
# switch-away is blocked, so the branch survives.
git -C "$guard" switch -qc parked-dirty --no-track "origin/$branch"
echo dirt >> "$guard/file.txt"
dirty_status=0
out_dirty="$( (cd "$guard" && run_tidy) 2>&1 )" || dirty_status=$?
assert "tidy exits 0 with dirty main checkout" test "$dirty_status" -eq 0
assert "dirty checkout's redundant branch kept" quiet git -C "$guard" show-ref --verify refs/heads/parked-dirty
assert "still on the dirty redundant branch" \
  test "$(git -C "$guard" symbolic-ref --short HEAD)" = parked-dirty
assert "dirty checkout skip reported" \
  quiet grep "skip (checked out at .*tracked files have uncommitted changes)" <<<"$out_dirty"

# Default branch checked out in another worktree: the switch fails, so the
# redundant branch survives with the failure reported.
git -C "$guard" checkout -q -- file.txt
git -C "$guard" worktree add -q "$guard/.worktrees/wt-main" "$branch"
swfail_status=0
out_swfail="$( (cd "$guard" && run_tidy) 2>&1 )" || swfail_status=$?
assert "tidy exits 0 when switch is blocked" test "$swfail_status" -eq 0
assert "switch-blocked redundant branch kept" quiet git -C "$guard" show-ref --verify refs/heads/parked-dirty
assert "still on the switch-blocked branch" \
  test "$(git -C "$guard" symbolic-ref --short HEAD)" = parked-dirty
assert "switch failure reported" \
  quiet grep "skip (cannot switch to $branch" <<<"$out_swfail"

# A branch that conflicts with the default branch is not redundant: the
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
assert_not "redundant branch deleted once no longer checked out" \
  quiet git -C "$guard" show-ref --verify refs/heads/parked-dirty

# The gone-but-unmerged report is information, not an action: it must
# survive an all-keep configuration.
git -C "$guard" switch -qc gu-keep --no-track "origin/$branch"
echo gk > "$guard/gk.txt"
git -C "$guard" add gk.txt
git -C "$guard" commit -qm gu-keep-work
git -C "$guard" push -q -u origin gu-keep
git -C "$guard" push -q origin --delete gu-keep
git -C "$guard" config tidy.local.branches keep
git -C "$guard" config tidy.local.worktrees keep
gk_status=0
out_gk="$( (cd "$guard" && run_tidy) 2>&1 )" || gk_status=$?
assert "tidy exits 0 under all-keep config" test "$gk_status" -eq 0
assert "gone-unmerged still reported under all-keep config" \
  quiet grep "keep gu-keep (upstream gone)" <<<"$out_gk"

# keep stays observable for detached folders too: a summary line, and
# unsaved work is reported whatever the configuration.
git -C "$guard" config tidy.local.detachedFolders keep
mkdir -p "$guard/.worktrees/stale-keep"
echo unsaved-thing > "$guard/.worktrees/stale-keep/wip.txt"
mkdir "$guard/.worktrees/stale-clean"
dk_status=0
out_dk="$( (cd "$guard" && run_tidy) 2>&1 )" || dk_status=$?
assert "tidy exits 0 with detachedFolders keep" test "$dk_status" -eq 0
assert "kept detached folders summarized" \
  quiet grep "keeping 2 detached worktree folder(s) (tidy.local.detachedFolders keep)" <<<"$out_dk"
assert "unsaved work reported under detachedFolders keep" \
  quiet grep "keep .*stale-keep (unsaved work, e.g. wip.txt)" <<<"$out_dk"
assert_not "saved detached folder not flagged under keep" quiet grep "stale-clean" <<<"$out_dk"
assert "kept detached folder untouched" test -f "$guard/.worktrees/stale-keep/wip.txt"

# --- tidy.remote.branches keep leaves a genuinely redundant remote alone -----
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
out_rk="$( (cd "$rk" && run_tidy) 2>&1 )" || rk_status=$?
assert "tidy exits 0 with remote keep" test "$rk_status" -eq 0
assert "remote keep leaves merged remote branch" \
  quiet grep "refs/heads/rk-merged$" <<<"$(git ls-remote --heads "$sandbox/origin.git")"
assert "kept redundant remote branch summarized" \
  quiet grep "keeping 1 redundant remote branch(es) (tidy.remote.branches keep)" <<<"$out_rk"
assert_not "merged local branch still deleted under remote keep" \
  quiet git -C "$rk" show-ref --verify refs/heads/rk-merged

# --- a merged remote branch still being built on locally is left alone ------
au="$sandbox/ahead"
git clone -q "$sandbox/origin.git" "$au" 2>/dev/null
git -C "$au" config user.email tidy-test@example.invalid
git -C "$au" config user.name tidy-test
git -C "$au" switch -qc ahead-work --no-track "origin/$branch"
echo aw > "$au/aw.txt"
git -C "$au" add aw.txt
git -C "$au" commit -qm ahead-work
git -C "$au" push -q -u origin ahead-work
git -C "$dev" fetch -q origin
quiet git -C "$dev" merge --no-ff -m merge-aw origin/ahead-work
git -C "$dev" push -q origin "HEAD:refs/heads/$branch"
# more local work on top, unpushed: the lifecycle isn't over
echo aw2 > "$au/aw2.txt"
git -C "$au" add aw2.txt
git -C "$au" commit -qm ahead-more
git -C "$au" switch -q "$branch"
au_status=0
quiet sh -c "cd '$au' && '$TIDY_BASH' '$tidy_dir/git-tidy'" || au_status=$?
assert "tidy exits 0 with in-use merged remote" test "$au_status" -eq 0
assert "merged remote branch kept while local builds on it" \
  quiet grep "refs/heads/ahead-work$" <<<"$(git ls-remote --heads "$sandbox/origin.git")"
assert "local branch building on merged remote kept" \
  quiet git -C "$au" show-ref --verify refs/heads/ahead-work

# --- a pull collision is reported but does not abort the run ----------------
coll="$sandbox/coll"
git clone -q "$sandbox/origin.git" "$coll" 2>/dev/null
git -C "$coll" config user.email tidy-test@example.invalid
git -C "$coll" config user.name tidy-test
echo local-scratch > "$coll/scratch.txt"
echo upstream > "$dev/scratch.txt"
git -C "$dev" add scratch.txt
git -C "$dev" commit -qm scratch
git -C "$dev" push -q origin "HEAD:refs/heads/$branch"
coll_status=0
out_coll="$( (cd "$coll" && run_tidy) 2>&1 )" || coll_status=$?
assert "tidy exits 0 when the ff-pull collides with an untracked file" test "$coll_status" -eq 0
assert "pull failure reported" quiet grep "pull failed; leaving the checkout as-is" <<<"$out_coll"
assert "run completes after pull failure" quiet grep "==> done" <<<"$out_coll"
assert "untracked file preserved" test "$(cat "$coll/scratch.txt")" = local-scratch

# --- the sync-stage switch proceeds while another worktree exists -----------
# tidy.local.branches keep matters: without it the fully-merged parked branch
# counts as redundant and the *cleanup* stage does the switch, so the
# sync-gate path would never execute.
swx="$sandbox/syncwx"
git clone -q "$sandbox/origin.git" "$swx" 2>/dev/null
git -C "$swx" config user.email tidy-test@example.invalid
git -C "$swx" config user.name tidy-test
git -C "$swx" config tidy.local.branches keep
git -C "$swx" worktree add -q "$swx/.worktrees/swx-live" -b swx-live "$branch"
echo sl > "$swx/.worktrees/swx-live/sl.txt"
git -C "$swx/.worktrees/swx-live" add sl.txt
git -C "$swx/.worktrees/swx-live" commit -qm swx-live-work
git -C "$swx" switch -qc swx-parked --no-track "origin/$branch"
swx_status=0
out_swx="$( (cd "$swx" && run_tidy) 2>&1 )" || swx_status=$?
assert "tidy exits 0 in sync-switch fixture" test "$swx_status" -eq 0
assert "sync switch runs despite another worktree" quiet grep -- "==> git switch $branch" <<<"$out_swx"
assert "checkout lands on the default branch" \
  test "$(git -C "$swx" symbolic-ref --short HEAD)" = "$branch"
assert "live worktree untouched by the sync" test -f "$swx/.worktrees/swx-live/sl.txt"
assert "parked branch kept per config" quiet git -C "$swx" show-ref --verify refs/heads/swx-parked

# --- mixed keep configs stay observable: kept items are counted -------------
mixed="$sandbox/mixed"
git clone -q "$sandbox/origin.git" "$mixed" 2>/dev/null
git -C "$mixed" config user.email tidy-test@example.invalid
git -C "$mixed" config user.name tidy-test
git -C "$mixed" config tidy.local.branches keep
git -C "$mixed" worktree add -q "$mixed/.worktrees/mw" -b mw "$branch"
git -C "$mixed" branch -q mb "$branch"
mixed_status=0
out_mixed="$( (cd "$mixed" && run_tidy) 2>&1 )" || mixed_status=$?
assert "tidy exits 0 with branches keep + worktrees delete" test "$mixed_status" -eq 0
assert "worktree removed in mixed config" test ! -e "$mixed/.worktrees/mw"
assert "branches kept in mixed config" quiet git -C "$mixed" show-ref --verify refs/heads/mb
assert "kept branches counted in mixed config" \
  quiet grep "kept 2 branch(es) (tidy.local.branches keep)" <<<"$out_mixed"

git -C "$mixed" config tidy.local.branches delete
git -C "$mixed" config tidy.local.worktrees keep
git -C "$mixed" worktree add -q "$mixed/.worktrees/mw2" -b mw2 "$branch"
mixed2_status=0
out_mixed2="$( (cd "$mixed" && run_tidy) 2>&1 )" || mixed2_status=$?
assert "tidy exits 0 with branches delete + worktrees keep" test "$mixed2_status" -eq 0
assert "worktree kept in reverse mixed config" test -d "$mixed/.worktrees/mw2"
assert_not "unencumbered branch deleted in reverse mixed config" \
  quiet git -C "$mixed" show-ref --verify refs/heads/mb
assert "kept worktrees counted in reverse mixed config" \
  quiet grep "kept 1 worktree(s) (tidy.local.worktrees keep)" <<<"$out_mixed2"

# --- recursive mode: hidden directories (vendored checkouts) not searched ---
tree="$sandbox/tree"
mkdir -p "$tree"
git clone -q "$sandbox/origin.git" "$tree/app" 2>/dev/null
mkdir -p "$tree/app/.terraform/modules"
git init -q "$tree/app/.terraform/modules/vendored"
rec_status=0
out_rec="$("$TIDY_BASH" "$tidy_dir/git-tidy" "$tree" 2>&1)" || rec_status=$?
assert "recursive tidy exits 0" test "$rec_status" -eq 0
assert "recursive tidy visits the plain repo" quiet grep -xF "### $tree/app" <<<"$out_rec"
assert_not "repo under a hidden directory not visited" quiet grep -F vendored <<<"$out_rec"

# --- a detached HEAD is someone's arrangement: sync leaves it alone ----------
det="$sandbox/det"
git clone -q "$sandbox/origin.git" "$det" 2>/dev/null
git -C "$det" switch -q --detach
det_status=0
out_det="$( (cd "$det" && run_tidy) 2>&1 )" || det_status=$?
assert "tidy exits 0 on detached HEAD" test "$det_status" -eq 0
assert "detached HEAD sync skip reported" \
  quiet grep "skip sync to $branch (detached HEAD)" <<<"$out_det"
assert_not "still detached after tidy" quiet git -C "$det" symbolic-ref -q HEAD

# --- remote-less repo: redundant means contained in the local default branch -
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

# --- GitHub PR lookup vouches for conflict-stranded squash-merged branches ---
ghx="$sandbox/ghx"
git clone -q "$sandbox/origin.git" "$ghx" 2>/dev/null
git -C "$ghx" config user.email tidy-test@example.invalid
git -C "$ghx" config user.name tidy-test
# The availability gate requires a github.com origin: point the remote URL
# at github.com and rewrite the actual transport back to the sandbox.
git -C "$ghx" remote set-url origin https://github.com/tidy-test/sandbox.git
git -C "$ghx" config url."$sandbox/origin.git".insteadOf https://github.com/tidy-test/sandbox.git

# ghx-squashed: pushed, squash-merged, then its territory rewritten on the
# default branch — the content probe conflicts, only the PR lookup can vouch
git -C "$ghx" switch -qc ghx-squashed --no-track "origin/$branch"
echo first > "$ghx/ghx.txt"
git -C "$ghx" add ghx.txt
git -C "$ghx" commit -qm ghx-squashed-work
git -C "$ghx" push -q -u origin ghx-squashed
git -C "$dev" fetch -q origin
quiet git -C "$dev" merge --squash origin/ghx-squashed
git -C "$dev" commit -qm "ghx-squashed (#77)"
echo second > "$dev/ghx.txt"
git -C "$dev" commit -qam ghx-rewrite
git -C "$dev" push -q origin "HEAD:refs/heads/$branch"

# ghx-live: conflicts the same way but no merged PR — must be kept
git -C "$ghx" switch -qc ghx-live --no-track "origin/$branch"
echo mine > "$ghx/ghx.txt"
git -C "$ghx" add ghx.txt
git -C "$ghx" commit -qm ghx-live-work
git -C "$ghx" push -q -u origin ghx-live
git -C "$ghx" switch -q "$branch"

# Fake gh: auth always succeeds; pr list emulates the post---jq output,
# answering only for the merged fixture branch when the query embeds its
# exact tip OID (the real call's --jq expression contains the OID).
sq_oid="$(git -C "$ghx" rev-parse refs/heads/ghx-squashed)"
mkdir -p "$sandbox/ghstub"
cat > "$sandbox/ghstub/gh" <<STUB
#!/bin/sh
[ "\$1" = "auth" ] && exit 0
head=""; oid_seen=0; prev=""
for a in "\$@"; do
  [ "\$prev" = "--head" ] && head="\$a"
  case "\$a" in *$sq_oid*) oid_seen=1 ;; esac
  prev="\$a"
done
if [ "\$head" = "ghx-squashed" ] && [ "\$oid_seen" = 1 ]; then
  echo "https://github.com/tidy-test/sandbox/pull/77"
fi
STUB
chmod +x "$sandbox/ghstub/gh"

# Lookup off: the conflicted branch stays unjudged and kept.
git -C "$ghx" config tidy.prLookup off
ghx_off_status=0
quiet sh -c "cd '$ghx' && PATH='$sandbox/ghstub':\$PATH '$TIDY_BASH' '$tidy_dir/git-tidy'" || ghx_off_status=$?
assert "tidy exits 0 with prLookup off" test "$ghx_off_status" -eq 0
assert "conflicted branch kept with prLookup off" \
  quiet git -C "$ghx" show-ref --verify refs/heads/ghx-squashed
git -C "$ghx" config --unset tidy.prLookup

# The key's pre-1.3.0 name is still honored.
git -C "$ghx" config tidy.github.prLookup off
ghx_legacy_status=0
quiet sh -c "cd '$ghx' && PATH='$sandbox/ghstub':\$PATH '$TIDY_BASH' '$tidy_dir/git-tidy'" || ghx_legacy_status=$?
assert "tidy exits 0 with the legacy prLookup key" test "$ghx_legacy_status" -eq 0
assert "legacy key still disables the lookup" \
  quiet git -C "$ghx" show-ref --verify refs/heads/ghx-squashed

# Unauthenticated gh: the gate closes silently and the branch is kept.
git -C "$ghx" config --unset tidy.github.prLookup
mkdir -p "$sandbox/ghstub-noauth"
printf '#!/bin/sh\nexit 1\n' > "$sandbox/ghstub-noauth/gh"
chmod +x "$sandbox/ghstub-noauth/gh"
ghx_noauth_status=0
quiet sh -c "cd '$ghx' && PATH='$sandbox/ghstub-noauth':\$PATH '$TIDY_BASH' '$tidy_dir/git-tidy'" || ghx_noauth_status=$?
assert "tidy exits 0 with unauthenticated gh" test "$ghx_noauth_status" -eq 0
assert "conflicted branch kept when gh auth fails" \
  quiet git -C "$ghx" show-ref --verify refs/heads/ghx-squashed

# Lookup on (default auto): the merged PR vouches; the impostor stays.
ghx_status=0
out_ghx="$( (cd "$ghx" && PATH="$sandbox/ghstub:$PATH" run_tidy) 2>&1 )" || ghx_status=$?
assert "tidy exits 0 with PR lookup" test "$ghx_status" -eq 0
assert "conflicted merged remote branch deleted with citation" \
  quiet grep "deleted origin/ghx-squashed (merged as https://github.com/tidy-test/sandbox/pull/77)" <<<"$out_ghx"
assert "conflicted merged local branch deleted with citation" \
  quiet grep "deleted branch (merged as https://github.com/tidy-test/sandbox/pull/77)" <<<"$out_ghx"
assert_not "merged remote branch gone from origin" \
  quiet grep "refs/heads/ghx-squashed$" <<<"$(git ls-remote --heads "$sandbox/origin.git")"
assert "conflicted unmerged remote branch kept" \
  quiet grep "refs/heads/ghx-live$" <<<"$(git ls-remote --heads "$sandbox/origin.git")"
assert "conflicted unmerged local branch kept" \
  quiet git -C "$ghx" show-ref --verify refs/heads/ghx-live

# --- --self-upgrade routes a Homebrew-managed install through brew ----------
cellar_bin="$sandbox/homebrew/Cellar/git-tidy/9.9.9/bin"
mkdir -p "$cellar_bin" "$sandbox/homebrew/bin" "$sandbox/stubbin"
cp "$tidy_dir/git-tidy" "$cellar_bin/git-tidy"
chmod +x "$cellar_bin/git-tidy"
ln -s "../Cellar/git-tidy/9.9.9/bin/git-tidy" "$sandbox/homebrew/bin/git-tidy"
# A tap clone one commit behind its origin: --self-upgrade must pull it
# before upgrading, or a release published after brew's last auto-update
# is invisible.
git init -q --bare "$sandbox/tap-origin.git"
tap_seed="$sandbox/tap-seed"
git clone -q "$sandbox/tap-origin.git" "$tap_seed" 2>/dev/null
git -C "$tap_seed" config user.email tidy-test@example.invalid
git -C "$tap_seed" config user.name tidy-test
echo v1 > "$tap_seed/formula.rb"
git -C "$tap_seed" add formula.rb
git -C "$tap_seed" commit -qm v1
git -C "$tap_seed" push -q origin HEAD:main
git clone -q "$sandbox/tap-origin.git" "$sandbox/tap-repo" 2>/dev/null
echo v2 > "$tap_seed/formula.rb"
git -C "$tap_seed" commit -qam v2
git -C "$tap_seed" push -q origin HEAD:main

# The info JSON mirrors real brew's pretty-printed, multi-line shape —
# a compact stub would mask line-oriented parsing bugs (it did once).
cat > "$sandbox/stubbin/brew" <<STUB
#!/bin/sh
case "\$1" in
  info) cat <<'JSON'
{
  "formulae": [
    {
      "name": "git-tidy",
      "full_name": "tidy-test/tap/git-tidy",
      "tap": "tidy-test/tap",
      "desc": "Tidy up git repositories"
    }
  ],
  "casks": []
}
JSON
    ;;
  --repository) echo "$sandbox/tap-repo" ;;
  *) echo "brew-stub: \$*" ;;
esac
STUB
chmod +x "$sandbox/stubbin/brew"
bu_status=0
out_bu="$(PATH="$sandbox/stubbin:$PATH" "$TIDY_BASH" "$sandbox/homebrew/bin/git-tidy" --self-upgrade 2>&1)" || bu_status=$?
assert "--self-upgrade exits 0 for a brew install" test "$bu_status" -eq 0
assert "brew install detected" quiet grep "Homebrew install detected" <<<"$out_bu"
assert "upgrade routed through brew" quiet grep "brew-stub: upgrade git-tidy" <<<"$out_bu"
assert_not "curl installer not run for a brew install" quiet grep "fetching latest installer" <<<"$out_bu"
assert "tap refreshed before upgrade" \
  test "$(git -C "$sandbox/tap-repo" rev-parse HEAD)" = "$(git -C "$sandbox/tap-origin.git" rev-parse HEAD)"

# brew's opt/ path symlinks the directory, not the file — must still detect
mkdir -p "$sandbox/homebrew/opt"
ln -s "../Cellar/git-tidy/9.9.9" "$sandbox/homebrew/opt/git-tidy"
opt_status=0
out_opt="$(PATH="$sandbox/stubbin:$PATH" "$TIDY_BASH" "$sandbox/homebrew/opt/git-tidy/bin/git-tidy" --self-upgrade 2>&1)" || opt_status=$?
assert "--self-upgrade exits 0 via the opt/ path" test "$opt_status" -eq 0
assert "brew detected through a directory symlink" quiet grep "brew-stub: upgrade git-tidy" <<<"$out_opt"
assert_not "curl installer not run via the opt/ path" quiet grep "fetching latest installer" <<<"$out_opt"

# brew-managed copy but brew not on PATH: explain and stop
sys_bash="$(command -v "$TIDY_BASH")"
nobrew_status=0
out_nobrew="$(PATH=/usr/bin:/bin "$sys_bash" "$cellar_bin/git-tidy" --self-upgrade 2>&1)" || nobrew_status=$?
assert "--self-upgrade exits 1 without brew on PATH" test "$nobrew_status" -eq 1
assert "missing brew explained" quiet grep "upgrade with: brew upgrade git-tidy" <<<"$out_nobrew"
assert_not "curl installer not run without brew" quiet grep "fetching latest installer" <<<"$out_nobrew"

# --- a dead remote must not abort the run --------------------------------
dr="$sandbox/deadremote"
git clone -q "$sandbox/origin.git" "$dr" 2>/dev/null
git -C "$dr" config user.email tidy-test@example.invalid
git -C "$dr" config user.name tidy-test
git -C "$dr" remote add dead /nonexistent-remote-path
git -C "$dr" remote set-head origin -d
git -C "$dr" branch -q dr-stale
dr_status=0
out_dr="$( (cd "$dr" && run_tidy) 2>&1 )" || dr_status=$?
assert "tidy exits 0 despite a dead remote" test "$dr_status" -eq 0
assert "fetch failure reported and survived" \
  quiet grep "fetch failed (continuing with the already-fetched state)" <<<"$out_dr"
assert_not "cleanup still ran after the failed fetch" \
  quiet git -C "$dr" show-ref --verify refs/heads/dr-stale
assert "run completed after the failed fetch" quiet grep "==> done" <<<"$out_dr"
# (Outcome only: on git >= 2.45 the retry fetch itself repairs the ref,
# so the explicit-repair narration is version-dependent.)
assert "origin/HEAD repaired via the origin-only retry" \
  quiet git -C "$dr" symbolic-ref refs/remotes/origin/HEAD

# --- missing origin/HEAD is repaired so non-main defaults still resolve -----
trunk_seed="$sandbox/trunk-seed"
git init -q -b trunk "$trunk_seed"
git -C "$trunk_seed" config user.email tidy-test@example.invalid
git -C "$trunk_seed" config user.name tidy-test
echo t > "$trunk_seed/t.txt"
git -C "$trunk_seed" add t.txt
git -C "$trunk_seed" commit -qm trunk-initial
git init -q --bare "$sandbox/trunk-origin.git"
git -C "$sandbox/trunk-origin.git" symbolic-ref HEAD refs/heads/trunk
git -C "$trunk_seed" remote add origin "$sandbox/trunk-origin.git"
git -C "$trunk_seed" push -q origin trunk
trunkc="$sandbox/trunkc"
git clone -q "$sandbox/trunk-origin.git" "$trunkc" 2>/dev/null
git -C "$trunkc" remote set-head origin -d
git -C "$trunkc" branch -q tnb
trunk_status=0
quiet sh -c "cd '$trunkc' && '$TIDY_BASH' '$tidy_dir/git-tidy'" || trunk_status=$?
assert "tidy exits 0 with missing origin/HEAD" test "$trunk_status" -eq 0
assert "origin/HEAD repaired" \
  test "$(git -C "$trunkc" symbolic-ref refs/remotes/origin/HEAD)" = refs/remotes/origin/trunk
assert_not "redundant branch cleaned once the default resolved" \
  quiet git -C "$trunkc" show-ref --verify refs/heads/tnb

# --- tidy.local.worktreeDirs: custom containers replace the default ---------
wd="$sandbox/wdirs"
git clone -q "$sandbox/origin.git" "$wd" 2>/dev/null
git -C "$wd" config user.email tidy-test@example.invalid
git -C "$wd" config user.name tidy-test
git -C "$wd" config tidy.local.worktreeDirs ".wt:$sandbox/abswt:~/wt-home"
mkdir -p "$wd/.wt/stale" "$wd/.wt/precious" "$wd/.worktrees/not-scanned" \
  "$sandbox/abswt/old" "$sandbox/home/wt-home/tilde-stale"
echo hello > "$wd/.wt/stale/copy.txt"            # content already in the odb
echo "one of a kind" > "$wd/.wt/precious/wip.txt"
echo hello > "$wd/.worktrees/not-scanned/copy.txt"
echo hello > "$sandbox/home/wt-home/tilde-stale/copy.txt"
wd_status=0
out_wd="$( (cd "$wd" && HOME="$sandbox/home" run_tidy) 2>&1 )" || wd_status=$?
assert "tidy exits 0 with custom worktree dirs" test "$wd_status" -eq 0
assert "saved folder removed from a relative custom dir" test ! -e "$wd/.wt/stale"
assert "unsaved folder kept in a custom dir" test -f "$wd/.wt/precious/wip.txt"
assert "unsaved folder reported in a custom dir" \
  quiet grep "skip .*precious (unsaved work, e.g. wip.txt)" <<<"$out_wd"
assert "saved folder removed from an absolute custom dir" test ! -e "$sandbox/abswt/old"
assert "default dir not scanned once overridden" test -d "$wd/.worktrees/not-scanned"
assert "tilde entry resolves against HOME" test ! -e "$sandbox/home/wt-home/tilde-stale"

# Non-hidden worktrees/ is in the default scan, but tracked content there
# is part of the project — committed (hence odb-"saved") files must not
# make a folder a removal candidate.
tw="$sandbox/trackedwt"
git clone -q "$sandbox/origin.git" "$tw" 2>/dev/null
git -C "$tw" config user.email tidy-test@example.invalid
git -C "$tw" config user.name tidy-test
mkdir -p "$tw/worktrees/docs" "$tw/worktrees/leftover"
echo "tracked content" > "$tw/worktrees/docs/notes.md"
git -C "$tw" add worktrees/docs/notes.md
git -C "$tw" commit -qm tracked-worktrees-content
echo hello > "$tw/worktrees/leftover/copy.txt"   # untracked, content in odb
tw_status=0
quiet sh -c "cd '$tw' && '$TIDY_BASH' '$tidy_dir/git-tidy'" || tw_status=$?
assert "tidy exits 0 with a tracked worktrees/ dir" test "$tw_status" -eq 0
assert "tracked folder under worktrees/ untouched" test -f "$tw/worktrees/docs/notes.md"
assert "untracked saved leftover under worktrees/ removed" test ! -e "$tw/worktrees/leftover"

# --- --offline: no network, local cleanup still runs ------------------------
off="$sandbox/offline"
git clone -q "$sandbox/origin.git" "$off" 2>/dev/null
git -C "$off" config user.email tidy-test@example.invalid
git -C "$off" config user.name tidy-test
git -C "$off" switch -qc off-merged --no-track "origin/$branch"
echo om > "$off/om.txt"
git -C "$off" add om.txt
git -C "$off" commit -qm off-merged-work
git -C "$off" push -q -u origin off-merged
git -C "$off" switch -q "$branch"
quiet git -C "$off" merge --no-ff -m merge-om off-merged
git -C "$off" push -q origin "HEAD:$branch"
git -C "$off" fetch -q origin
off_status=0
out_off="$( (cd "$off" && "$TIDY_BASH" "$tidy_dir/git-tidy" --offline) 2>&1 )" || off_status=$?
assert "tidy exits 0 offline" test "$off_status" -eq 0
assert "offline fetch skip narrated" quiet grep -- "skip fetch (--offline)" <<<"$out_off"
assert_not "redundant local branch cleaned offline" \
  quiet git -C "$off" show-ref --verify refs/heads/off-merged
assert "remote branch untouched offline" \
  quiet grep "refs/heads/off-merged$" <<<"$(git ls-remote --heads "$sandbox/origin.git")"
assert "remote cleanup skip narrated offline" \
  quiet grep "skip remote branch cleanup (origin not fetched this run)" <<<"$out_off"
assert "pull skip narrated offline" \
  quiet grep "skip pull (origin not fetched this run)" <<<"$out_off"

# --- unreachable origin: the same gates engage automatically ----------------
unr="$sandbox/unreach"
git clone -q "$sandbox/origin.git" "$unr" 2>/dev/null
git -C "$unr" config user.email tidy-test@example.invalid
git -C "$unr" config user.name tidy-test
git -C "$unr" branch -q unr-stale
git -C "$unr" remote set-url origin /nonexistent-origin-path
unr_status=0
out_unr="$( (cd "$unr" && run_tidy) 2>&1 )" || unr_status=$?
assert "tidy exits 0 with unreachable origin" test "$unr_status" -eq 0
assert "fetch failure survived with unreachable origin" \
  quiet grep "fetch failed (continuing with the already-fetched state)" <<<"$out_unr"
assert_not "local cleanup still ran with unreachable origin" \
  quiet git -C "$unr" show-ref --verify refs/heads/unr-stale
assert "remote cleanup skipped with unreachable origin" \
  quiet grep "skip remote branch cleanup (origin not fetched this run)" <<<"$out_unr"

if (( failures > 0 )); then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
