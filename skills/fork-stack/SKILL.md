---
name: fork-stack
description: >-
  Maintain a fork of someone else's project as a linear stack of your own commits
  on top of upstream, so syncing stays a cheap rebase. Use when adding or changing
  a customization in a fork, syncing a fork with upstream, resolving rebase
  conflicts in a fork, asking "what are my changes in this fork", or when the user
  says "sync the fork", "rebase onto upstream", "keep my patches small", or
  talks about the blast radius or patch stack of a fork's changes.
targets:
  - '*'
---

# fork-stack

A fork is upstream plus a short, linear stack of your commits: one commit per
feature, replayed on top of upstream every time upstream moves. The stack is the
only record of what is yours (`git log upstream..HEAD`), so there is no ledger
file to maintain.

The mechanical parts are in `fork-stack.sh`, next to this file. Run it from
inside the fork, on the branch that holds the stack. Use it instead of
hand-typing the git sequence: it records an undo point and runs the checks you
would otherwise skip.

| command | what it does |
| --- | --- |
| `ledger` | lists your patches and how far behind upstream you are |
| `check` | fails on merge commits, unfolded `fixup!` commits, a dirty tree or a rebase in progress |
| `blast-radius [--max N]` | per patch: lines and files changed in upstream's paths versus paths only the fork has; fails above `N` lines |
| `sync` | fetches, records an undo point, rebases the stack onto upstream, then runs `verify`; refuses a detached HEAD, a dirty tree or a stack with merge commits |
| `sync --abort-on-conflict` | the same, but on conflicts it names the patch and files, aborts the rebase and leaves the branch untouched |
| `verify` | `range-diff` of the stack before and after, the ledger, `check`, and the repo's own check command |

Exit codes: `0` fine, `1` a check failed (including the repo's own check
command), `2` the rebase stopped on conflicts. The script never pushes.
Untracked files do not count as a dirty tree.

## Set up a fork once

```sh
git remote add upstream <url>                      # if missing
git config fork-stack.upstream upstream/master     # only if it is not upstream/main or upstream/master
git config fork-stack.check "just check"           # the repo's own test/lint entrypoint
```

If the fork is built on a release tag or a release branch, point
`fork-stack.upstream` at that ref. `check` warns when the stack contains commits
you did not author, which is the sign that the upstream ref is wrong.

## Adding or changing a customization

1. Run `fork-stack.sh ledger` and read the stack first. Extend the existing commit
   for a feature rather than starting a second one.
2. Keep the change additive. Put the logic in a new file that only the fork has,
   and leave the smallest possible hook in upstream's file: an import and a call.
   Lines inside upstream's functions conflict whenever upstream edits nearby;
   a file upstream does not have conflicts only if upstream later adds the same
   path.
3. Give the customization a test of its own where the repo has tests. A clean
   rebase and an unchanged `range-diff` show the text survived, not that the
   behaviour did; only a test shows that.
4. Commit it as one commit per feature, with the reason in the commit body. A
   follow-up fix to an existing patch is `git commit --fixup <sha>` followed by
   `git -c sequence.editor=: rebase -i --autosquash <upstream ref>`, so the stack
   keeps one commit per feature.
5. Run `fork-stack.sh blast-radius`. `theirs` is the churn in paths that exist
   upstream and `files` is how many of them. Treat them as a prompt, not a
   target: a two-line hook can still depend heavily on upstream internals, and
   indirection added only to lower the number makes the patch worse. If
   one patch changes many lines in upstream's files, check whether the logic can
   move into your own file behind a hook. The metric goes by path and does not
   follow renames: renaming an upstream file makes later edits look like yours,
   so do not rename upstream's files.
6. Run `fork-stack.sh check` and the repo's own checks.

Do not add a feature flag just to make rebasing easier: a flag adds lines to
config parsing, defaults and docs, which is more conflict surface. Add one when
the behaviour needs a switch, and make it opt-in and default off if the patch
may be proposed upstream.

## Syncing with upstream

1. `fork-stack.sh sync`.
2. Exit code `2` means conflicts. For each conflicted file: keep upstream's new
   code, then re-apply what your patch was meant to do on top of it. Never
   resolve by taking your old version of the whole hunk; that silently reverts
   upstream's change. `git add` the file, `git rebase --continue`, and repeat
   until the rebase finishes. Then run `fork-stack.sh verify`.
3. Read the `range-diff` in the output. Each of your patches is compared with
   itself after the rebase. For every patch whose diff changed, confirm the new
   version still does what its commit message says. For every patch that
   disappeared, confirm upstream now contains that behaviour; a patch also
   disappears when a bad resolution emptied it, and that is lost work, not a
   merged patch.
4. If the repo's check command fails, fix the patch that broke with a fixup
   commit and autosquash; do not add a "fix after sync" commit on top.
5. Backing out. While the rebase is still stopped on conflicts:
   `git rebase --abort`. After a finished sync, `verify` prints where the branch
   was before; `git reset --hard <that commit>` returns to it, but only run it
   on the same branch with a clean tree, because it discards every commit made
   since the sync.

Sync is its own task. Do not fold it into feature work, and do not sync from a
dirty tree.

## Scheduled (weekly) runs

Syncing weekly keeps each rebase small. Two ways to schedule it:

- **A plain cron job, no agent.** Run `fork-stack.sh sync --abort-on-conflict` in
  each fork. A clean rebase lands and is verified; a conflict is reported and
  backed out, so the fork is never left mid-rebase. Exit code `2` means a human
  or an agent has to do that sync.
- **A scheduled agent.** Give it this skill and the list of fork paths. For each
  fork it runs `fork-stack.sh sync`, resolves any conflicts as described above,
  reads the `range-diff`, and reports per fork: patches replayed, patches that
  disappeared and why, conflicts resolved, and the result of the repo's check.

Either way a scheduled run stops at the local branch: no push, no build, no
deploy. Those stay with the user, who reads the report first.

## Rules

- Rebase, never merge upstream into the fork. A merge interleaves upstream's
  commits with yours and the stack can no longer be listed.
- Rewriting the stack means the next push is a force push. Ask the user before
  pushing, and use `git push --force-with-lease`, never `--force`.
- Follow the fork's own branch conventions for which branch holds the stack; a
  repo-local `CLAUDE.md` or `AGENTS.md` wins over this skill.
- To propose a patch upstream, cherry-pick that one commit onto a new branch cut
  from upstream. Do not open a PR from the stack branch.
- Do not keep a markdown list of the fork's changes. If the stack is hard to
  read, fix the commit messages.

`test.sh` next to the script builds a throwaway upstream and fork and exercises
every command; run it after editing the script.
