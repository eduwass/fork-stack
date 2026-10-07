# fork-stack

An agent skill for maintaining a fork without falling behind upstream.

https://github.com/user-attachments/assets/dfe6c964-73f1-4f91-a752-82d012b27bbb

The idea: your fork is upstream plus a short, linear stack of your own commits,
one per feature, replayed on top every time upstream moves. Rebasing is cheap
when an agent does it. What keeps it cheap is the shape of the stack: small
patches that barely touch upstream's files, and a check that the rebase did not
quietly change what a patch does.

The skill is a guide for the agent ([SKILL.md](skills/fork-stack/SKILL.md)) plus
one bash script for the parts that should not be improvised.

## What the script does

Run it inside your fork, on the branch that holds your commits.

```sh
$ fork-stack.sh ledger
4f1c2aa keybinds: tmux-style prefix
9b03e71 confirm before closing a running pane
c2d88f0 pane titles from the agent
3 patch(es) on upstream/main, 12 behind

$ fork-stack.sh blast-radius
  theirs  files    yours  patch
       4      1        0  4f1c2aa keybinds: tmux-style prefix
       2      1       41  9b03e71 confirm before closing a running pane
     118      6        0  c2d88f0 pane titles from the agent
124 line(s) changed in upstream's files across the stack

$ fork-stack.sh sync
```

| command | what it does |
| --- | --- |
| `ledger` | lists your patches and how far behind upstream you are |
| `check` | fails on merge commits, unfolded `fixup!` commits, a dirty tree or a rebase in progress |
| `blast-radius [--max N]` | per patch: lines and files changed in upstream's paths versus paths only the fork has |
| `sync` | fetches, records an undo point, rebases the stack onto upstream, then runs `verify` |
| `sync --abort-on-conflict` | the same, but on conflicts it reports the patch and files, aborts the rebase and leaves the branch untouched |
| `verify` | `range-diff` of the stack before and after, the ledger, `check`, and your repo's own check command |

`theirs` is the number to shrink: lines inside upstream's files can conflict on
every sync, lines in files only your fork has almost never do. The second patch
above is the shape to aim for: a two-line hook in their file, the logic in yours.

`sync` never pushes. It stops with exit code 2 on conflicts and hands back to
you or your agent; after `git rebase --continue`, `verify` shows each patch
before and after so a bad conflict resolution is visible.

## Install

Copy the skill folder to wherever your agent reads skills from, for example:

```sh
git clone https://github.com/eduwass/fork-stack
cp -r fork-stack/skills/fork-stack ~/.claude/skills/
```

Per fork, once:

```sh
git remote add upstream <url>
git config fork-stack.upstream upstream/master   # only if it is not upstream/main or upstream/master
git config fork-stack.check "just check"         # your repo's test or lint entrypoint
```

Settings live in git config, so nothing is added to the fork's tree.

## Run it on a schedule

Syncing weekly keeps every rebase small. `sync` is the command to schedule; pick
the mode by whether anything is there to resolve conflicts.

**Plain cron, no agent.** Use `--abort-on-conflict`. A clean rebase lands and is
verified. A conflict is reported and backed out, so the fork is never left
mid-rebase:

```sh
# Mondays at 09:00, one line per fork
0 9 * * 1  cd ~/code/my-fork && ~/.claude/skills/fork-stack/fork-stack.sh sync --abort-on-conflict >> ~/fork-stack.log 2>&1
```

Exit code `0` means the fork is on top of upstream and its checks passed. `2`
means that sync needs a person or an agent. Anything else is a failed check.

**A scheduled agent.** Use whatever scheduler your agent has (a cron job that
starts it headless, a routine, a CI workflow) with a prompt like:

```
Use the fork-stack skill. For each of these forks: ~/code/fork-a, ~/code/fork-b
run fork-stack.sh sync, resolve any conflicts, and read the range-diff.
Do not push, build or deploy. Report per fork: patches replayed, patches that
disappeared and why, conflicts you resolved, and the check result.
```

Either way the run stops at your local branch. Nothing is pushed.

## The rules it teaches

- One stack. Cut a separate branch only to send a patch upstream.
- One hook line in their file, your logic in your own file.
- Rebase, never merge. Fold fixes back into the commit they belong to.
- Do not add a feature flag just to make rebasing easier.
- Sync often. Small deltas are trivial.
- No ledger file. `git log upstream..HEAD` is the ledger.

## Development

`skills/fork-stack/test.sh` builds a throwaway upstream and fork in a temp
directory and exercises every command, including a conflict, a merge commit and
an upstream force-push. Needs bash and git.

## License

MIT
