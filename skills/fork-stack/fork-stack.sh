#!/usr/bin/env bash
# fork-stack: keep a fork as a linear stack of your commits on top of upstream.
#
#   fork-stack.sh ledger                 list your patches (the stack)
#   fork-stack.sh check                  fail if the stack is not clean and linear
#   fork-stack.sh blast-radius [--max N] lines each patch changes in upstream's files
#   fork-stack.sh sync                   fetch, rebase the stack onto upstream, verify
#   fork-stack.sh sync --abort-on-conflict   same, but back out and report on conflicts
#                                        (for scheduled runs with nobody there to resolve)
#   fork-stack.sh verify                 range-diff + ledger + checks after a sync
#
# Per-repo settings live in git config (nothing to commit, nothing to conflict):
#   git config fork-stack.upstream upstream/master   # default: upstream/HEAD, main, master
#   git config fork-stack.check "just check"         # optional, run by sync/verify
#
# Never pushes. Exit codes: 0 ok, 1 a check failed, 2 the rebase stopped on conflicts.
set -euo pipefail

# State is kept per branch, so syncing one worktree never overwrites another's. Slashes
# in branch names are escaped so "topic" and "topic/sub" cannot collide as refs.
pre_ref() { echo "refs/fork-stack/pre/${1//\//%2F}"; }
base_ref() { echo "refs/fork-stack/base/${1//\//%2F}"; }
# The upstream commit the stack was last rebased onto: the boundary between theirs and yours.
onto_ref() { echo "refs/fork-stack/onto/${1//\//%2F}"; }

die() {
  echo "fork-stack: $*" >&2
  exit 1
}

upstream_ref() {
  local ref candidate
  ref=$(git config --get fork-stack.upstream || true)
  if [ -z "$ref" ]; then
    ref=$(git symbolic-ref -q --short refs/remotes/upstream/HEAD || true)
  fi
  if [ -z "$ref" ]; then
    for candidate in upstream/main upstream/master; do
      if git rev-parse -q --verify "$candidate^{commit}" >/dev/null; then
        ref=$candidate
        break
      fi
    done
  fi
  [ -n "$ref" ] || die "no upstream ref found. Run: git config fork-stack.upstream <remote>/<branch>"
  ref=${ref#refs/remotes/}
  git rev-parse -q --verify "$ref^{commit}" >/dev/null || die "upstream ref '$ref' does not exist (fetch it first)"
  echo "$ref"
}

rebase_in_progress() {
  [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]
}

# Untracked files are ignored on purpose: forks often carry local build output.
dirty() {
  [ -n "$(git status --porcelain --untracked-files=no)" ]
}

current_branch() {
  git symbolic-ref -q --short HEAD || die "HEAD is detached; check out the branch that holds the stack"
}

cmd_ledger() {
  git log --reverse --format='%h %s' "$UP..HEAD"
  echo "$(git rev-list --count "$UP..HEAD") patch(es) on $UP, $(git rev-list --count "HEAD..$UP") behind"
}

cmd_check() {
  local failed=0 count me
  fail() {
    echo "FAIL $*"
    failed=1
  }

  if rebase_in_progress; then fail "a rebase is in progress; finish or abort it"; fi
  if dirty; then fail "working tree has uncommitted changes"; fi

  count=$(git rev-list --merges --count "$UP..HEAD")
  [ "$count" -eq 0 ] || fail "$count merge commit(s) in the stack; rebase onto $UP instead of merging it"

  count=$(git log --format=%s "$UP..HEAD" | grep -cE '^(fixup|squash|amend)! ' || true)
  [ "$count" -eq 0 ] || fail "$count unfolded fixup commit(s); run: git rebase -i --autosquash $UP"

  [ "$(git rev-list --count "$UP..HEAD")" -gt 0 ] || echo "WARN the stack is empty"

  me=$(git config user.email || true)
  if [ -n "$me" ]; then
    count=$(git log --format=%ae "$UP..HEAD" | grep -vcFx "$me" || true)
    [ "$count" -eq 0 ] || echo "WARN $count commit(s) in the stack are not authored by $me; if this fork is based on a release tag or branch, point fork-stack.upstream at it"
  fi

  count=$(git rev-list --count "HEAD..$UP")
  [ "$count" -eq 0 ] || echo "WARN $count commit(s) behind $UP; run: fork-stack.sh sync"

  if [ "$failed" -eq 0 ]; then echo "ok: stack is clean"; fi
  return "$failed"
}

# For every patch: churn (added + deleted lines) in paths that already exist at the base
# of the stack, versus churn in paths only the fork has. It is a size proxy for how much
# of a patch can collide with upstream; it does not follow renames.
cmd_blast_radius() {
  local max="" base commit record added deleted path theirs files mine worst=0 total=0 hot=""
  if [ "${1:-}" = "--max" ]; then
    max=${2:-}
    case $max in '' | *[!0-9]*) die "--max needs a number" ;; esac
  fi
  base=$(git merge-base "$UP" HEAD)

  printf '%8s %6s %8s  %s\n' "theirs" "files" "yours" "patch"
  for commit in $(git rev-list --reverse --no-merges "$UP..HEAD"); do
    theirs=0
    files=0
    mine=0
    while IFS= read -r -d '' record; do
      added=${record%%$'\t'*}
      record=${record#*$'\t'}
      deleted=${record%%$'\t'*}
      path=${record#*$'\t'}
      case $added in '' | *[!0-9-]*) continue ;; esac
      # Binary files show "-"; count them as one line so they still register.
      [ "$added" != "-" ] || added=1
      [ "$deleted" != "-" ] || deleted=0
      if git cat-file -e "$base:$path" 2>/dev/null; then
        theirs=$((theirs + added + deleted))
        files=$((files + 1))
        hot+="$((added + deleted))"$'\t'"${path//[$'\t\n']/?}"$'\n'
      else
        mine=$((mine + added + deleted))
      fi
    done < <(git show --no-renames --numstat -z --format= "$commit")
    printf '%8d %6d %8d  %s\n' "$theirs" "$files" "$mine" "$(git log -1 --format='%h %s' "$commit")"
    total=$((total + theirs))
    [ "$theirs" -le "$worst" ] || worst=$theirs
  done
  echo "$total line(s) changed in upstream's files across the stack"

  if [ -n "$hot" ]; then
    echo "upstream files you touch most:"
    printf '%s' "$hot" | awk -F'\t' '{ sum[$2] += $1 } END { for (file in sum) printf "%8d  %s\n", sum[file], file }' | sort -rn | sed -n '1,5p'
  fi

  if [ -n "$max" ] && [ "$worst" -gt "$max" ]; then
    echo "FAIL a patch changes $worst line(s) in upstream's files (max $max); see if the logic can live in your own file behind a hook"
    return 1
  fi
}

cmd_verify() {
  local check branch pre base
  if rebase_in_progress; then die "the rebase is still in progress; resolve, then: git rebase --continue"; fi
  branch=$(current_branch)
  pre=$(pre_ref "$branch")
  base=$(base_ref "$branch")
  git rev-parse -q --verify "$pre" >/dev/null || die "no sync recorded for branch '$branch'; run: fork-stack.sh sync"

  echo "== range-diff: every patch before the sync against the same patch after it"
  git range-diff "$base..$pre" "$UP..HEAD"
  echo "== ledger"
  cmd_ledger
  echo "== check"
  cmd_check
  # The stack now sits on upstream: record that boundary for the next sync.
  if git merge-base --is-ancestor "$UP" HEAD; then git update-ref "$(onto_ref "$branch")" "$UP"; fi

  check=$(git config --get fork-stack.check || true)
  if [ -n "$check" ]; then
    echo "== $check"
    # Exit 1, not the command's own status, so a check can never look like exit code 2.
    (cd "$(git rev-parse --show-toplevel)" && sh -c "$check") || {
      echo "FAIL '$check' exited $?"
      return 1
    }
  else
    echo "WARN no fork-stack.check command set; run this repo's tests yourself"
  fi
  echo "before the sync '$branch' was at $(git rev-parse --short "$pre") (kept in $pre)"
}

cmd_sync() {
  local remote=${UP%%/*} branch old_upstream base onto unattended=0
  [ "${1:-}" != "--abort-on-conflict" ] || unattended=1
  branch=$(current_branch)
  if rebase_in_progress; then die "a rebase is already in progress"; fi
  if dirty; then die "working tree has uncommitted changes; commit them first"; fi
  # A rebase drops merge commits together with whatever was fixed in their resolution.
  [ "$(git rev-list --merges --count "$UP..HEAD")" -eq 0 ] ||
    die "the stack contains merge commits; linearize it by hand first, sync would silently drop their conflict resolutions"

  # The stack is whatever sits on top of upstream as we know it now, before fetching.
  # Prefer the boundary recorded by the last finished sync: an aborted attempt may already
  # have fetched a rewritten upstream, which would make merge-base point too far back.
  old_upstream=$(git rev-parse "$UP")
  base=$(git merge-base "$UP" HEAD)
  onto=$(git rev-parse -q --verify "$(onto_ref "$branch")" || true)
  if [ -n "$onto" ] && git merge-base --is-ancestor "$onto" HEAD && git merge-base --is-ancestor "$base" "$onto"; then
    base=$onto
  fi
  if git remote | grep -qFx "$remote"; then git fetch --quiet "$remote"; fi
  git merge-base --is-ancestor "$old_upstream" "$UP" ||
    echo "WARN $UP was rewritten upstream; replaying only the patches that sat on the old base"

  git update-ref "$(pre_ref "$branch")" HEAD
  git update-ref "$(base_ref "$branch")" "$base"
  # Remember conflict resolutions so the same conflict is only ever resolved once.
  git config rerere.enabled true

  # --no-update-refs: only this branch has an undo point, so only this branch may move.
  if ! git rebase --no-update-refs --onto "$UP" "$base"; then
    rebase_in_progress || die "git rebase could not start (see its message above); nothing was changed"
    if [ "$unattended" -eq 1 ]; then
      echo
      echo "fork-stack: conflicts in '$(git log -1 --format='%h %s' REBASE_HEAD)':"
      git diff --name-only --diff-filter=U | sed 's/^/  /'
      git rebase --abort
      echo "fork-stack: rebase aborted, '$branch' is unchanged and $(git rev-list --count "HEAD..$UP") behind $UP"
      exit 2
    fi
    echo
    echo "fork-stack: the rebase stopped on conflicts."
    echo "  resolve each file, git add it, then: git rebase --continue"
    echo "  when the rebase is finished run:     fork-stack.sh verify"
    echo "  to give up and go back:              git rebase --abort"
    exit 2
  fi
  cmd_verify
}

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
UP=$(upstream_ref)

case ${1:-} in
ledger) cmd_ledger ;;
check) cmd_check ;;
blast-radius) shift && cmd_blast_radius "$@" ;;
sync) shift && cmd_sync "$@" ;;
verify) cmd_verify ;;
*) die "usage: fork-stack.sh ledger | check | blast-radius [--max N] | sync [--abort-on-conflict] | verify" ;;
esac
