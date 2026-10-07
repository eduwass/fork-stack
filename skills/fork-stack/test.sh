#!/usr/bin/env bash
# Self-check for fork-stack.sh: builds a throwaway upstream + fork and runs every command.
set -euo pipefail

FS="$(cd "$(dirname "$0")" && pwd)/fork-stack.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok() { echo "ok   $*"; }
bad() {
  echo "FAIL $*"
  exit 1
}
# expect <exit code> <text in output> <command...>
expect() {
  local want=$1 text=$2 out code=0
  shift 2
  out=$("$@" 2>&1) || code=$?
  [ "$code" -eq "$want" ] || bad "$* exited $code, wanted $want: $out"
  case $out in *"$text"*) ok "$* -> $text" ;; *) bad "$* output lacks '$text': $out" ;; esac
}
commit() { git -c user.name=t -c user.email="$1" commit -qam "$2"; }

# upstream: one file with ten lines
git init -q -b main "$TMP/up"
cd "$TMP/up"
seq 1 10 >app.txt
git add app.txt
commit up@x u1

# fork: patch A edits one upstream line and adds its own file, patch B is all new
git clone -q "$TMP/up" "$TMP/fork"
cd "$TMP/fork"
git remote rename origin upstream
git config user.email me@x
git config user.name me
sed -i.bak '2s/$/ hook/' app.txt && rm app.txt.bak
printf 'a\nb\nc\n' >mine.txt
git add mine.txt
commit me@x "A: hook"
echo x >other.txt
git add other.txt
commit me@x "B: other"

expect 0 "2 patch(es) on upstream/main, 0 behind" "$FS" ledger
expect 0 "ok: stack is clean" "$FS" check
expect 0 "       2      1        3  " "$FS" blast-radius
expect 1 "max 0" "$FS" blast-radius --max 0

# upstream moves without touching our line: sync replays both patches
(cd "$TMP/up" && echo 11 >>app.txt && commit up@x u2)
expect 0 "2 patch(es) on upstream/main, 0 behind" "$FS" sync
[ "$(git merge-base upstream/main HEAD)" = "$(git rev-parse upstream/main)" ] || bad "stack is not on the upstream tip"
ok "stack sits on the upstream tip"
expect 0 "before the sync 'main' was at" "$FS" verify

# a failing repo check fails verify, and sync refuses a detached HEAD
git config fork-stack.check "exit 7"
expect 7 "== exit 7" "$FS" verify
git config fork-stack.check "true"
git checkout -q --detach
expect 1 "HEAD is detached" "$FS" sync
git checkout -q main

# an unfolded fixup and a merge commit both fail the check
echo y >>other.txt
commit me@x "fixup! B: other"
expect 1 "unfolded fixup" "$FS" check
git reset -q --hard HEAD~1
(cd "$TMP/up" && echo 12 >>app.txt && commit up@x u3)
git fetch -q upstream
git -c user.name=me -c user.email=me@x merge -q --no-edit upstream/main
expect 1 "merge commit" "$FS" check
merged=$(git rev-parse HEAD)
expect 1 "linearize it by hand" "$FS" sync
[ "$(git rev-parse HEAD)" = "$merged" ] || bad "sync moved HEAD despite refusing"
ok "sync refused the merge without moving HEAD"
git reset -q --hard HEAD~1

# upstream edits the line we hooked: sync stops with exit code 2
(cd "$TMP/up" && sed -i.bak '2s/.*/two/' app.txt && rm app.txt.bak && commit up@x u4)
before=$(git rev-parse HEAD)
expect 2 "stopped on conflicts" "$FS" sync
[ "$(git rev-parse refs/fork-stack/pre/main)" = "$before" ] || bad "undo point is not the pre-sync HEAD"
ok "undo point is the pre-sync HEAD"

# resolve it the right way (upstream's line plus our hook), finish, and verify
sed -i.bak -e '/^<<<<<<</d' -e '/^=======/d' -e '/^>>>>>>>/d' -e '/^2 hook$/d' -e 's/^two$/two hook/' app.txt && rm app.txt.bak
git add app.txt
GIT_EDITOR=true git rebase --continue >/dev/null
expect 0 "2 patch(es) on upstream/main, 0 behind" "$FS" verify
grep -qx "two hook" app.txt || bad "resolution lost upstream's change or our hook"
ok "conflict resolved, both changes kept"

# upstream force-pushes away a commit: only our patches are replayed, not the removed one
(cd "$TMP/up" && echo 13 >>app.txt && commit up@x u5)
expect 0 "2 patch(es) on upstream/main, 0 behind" "$FS" sync
(cd "$TMP/up" && git reset -q --hard HEAD~1 && echo replaced >>app.txt && commit up@x u5b)
expect 0 "was rewritten upstream" "$FS" sync
[ "$(git rev-list --count upstream/main..HEAD)" -eq 2 ] || bad "a commit upstream removed came back"
ok "rewritten upstream: stack is still 2 patches"

echo "all fork-stack checks passed"
