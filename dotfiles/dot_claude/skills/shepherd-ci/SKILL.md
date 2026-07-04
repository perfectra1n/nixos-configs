---
name: shepherd-ci
description: Use to drive a branch's CI/CD to fully green on ANY git forge — GitHub, Gitea, GitLab, or a self-hosted/remote forge. Watches the pipeline, pulls failed job logs, fixes the root cause (even outside the change's original scope), validates locally by mirroring what CI runs, commits and pushes, then re-checks — looping until every check passes. Trigger whenever the user says "get CI green", "fix the failing pipeline/build/checks", "shepherd CI", "make the actions pass", "why is CI red", or points at a red pipeline on Gitea/GitLab/GitHub. Forge-agnostic: detects the forge from the git remote and uses gh / tea / glab or the commit-status API automatically. Never force-pushes, never merges.
---

# Shepherd CI

Babysit a branch's CI to green on whatever forge it lives on. Each cycle:
**assess → triage failures → fix → validate locally → push → wait → repeat**, up
to **50 iterations**.

Unlike a GitHub-only helper, this skill starts by *detecting the forge* from the
git remote and speaks to it through the right adapter (`gh`, `tea`, `glab`, or the
universal commit-status API). Everything downstream — the loop, the local
validation, the safety rules — is the same regardless of forge. Your job is the
debugging, not the plumbing; the bundled `scripts/ci-status.sh` normalizes every
forge into one `VERDICT:` line.

This is the CI sibling of `shepherd-pr`. Where `shepherd-pr` also satisfies a
review bot and is wired to one specific repo, `shepherd-ci` is portable and
concerned only with **making the pipeline pass** on any repo you're standing in.

## When to use

- "Get CI green" / "fix the failing build" / "the actions are red" / "shepherd CI".
- A pushed branch has a failing or stuck pipeline and you want it driven to green
  autonomously — on a Gitea repo, a GitLab project, a GitHub repo, or a homelab
  forge you self-host.
- After pushing work and wanting CI babysat without you watching it.

## Exit condition (done)

The loop is **done** when the assess verdict is `GREEN` — every CI run for the
current branch head has a terminal success state and nothing is pending. Then
**stop and report**. Do **not** merge, tag, deploy, or mark anything ready unless
the user explicitly asks — same as `shepherd-pr`, shepherding ≠ landing.

## Prerequisites

- Inside a git repo with a remote whose forge is reachable. The forge CLI for
  that host should be authenticated:
  - **GitHub** → `gh auth status` green (also covers GitHub Enterprise hosts `gh`
    is logged into).
  - **Gitea** → the host appears in `tea logins list`.
  - **GitLab** → `glab auth status` green.
  - **Any other forge** → a token in the environment (`GITEA_TOKEN`, `GH_TOKEN`,
    `FORGE_TOKEN`, …) so the commit-status API fallback can read state.
- The branch is already pushed (CI runs on the remote). If it isn't, push first.
- To reproduce failures locally you need the repo's own toolchain (its
  `cargo`/`pnpm`/`make`/`mise`/`go`/`pytest`/…). If you can't run it locally,
  you can still fix-and-push and rely on CI to confirm — just note it.

## The loop

Track the iteration with `TaskCreate`. The skill scripts live next to this file;
call them by absolute path or `"$(dirname)"`-relative from the skill dir.

### Step 1 — Assess

```bash
<skill-dir>/scripts/ci-status.sh [REF]
```

`REF` is optional (defaults to the current branch; a bare number is a PR on
GitHub). It prints the resolved repo/host/forge/branch/head and a final
`VERDICT:` line — **this is the only thing you key off**:

- `VERDICT: GREEN` → go to **Step 6 (finish)**.
- `VERDICT: FAILING count=N <names>` → runs failed; go to **Step 2**. (There may
  also be pending runs; a real failure means start fixing now, don't wait.)
- `VERDICT: PENDING count=N` → still running; go to **Step 5 (wait)**, then back here.
- `VERDICT: NO_CI` → no runs for this head. Either CI isn't configured for this
  repo, or the push hasn't triggered it yet. Wait ~30s and re-assess once; if
  still `NO_CI`, tell the user CI may not be wired up and stop.
- `VERDICT: UNKNOWN <reason>` → the script couldn't reach the forge (no
  adapter/auth, detached HEAD). Fix the prerequisite (authenticate the CLI /
  export a token / checkout a branch) and re-run; if you can't, stop and report.

Record `head:`, `branch:`, and the failing set so you can detect no-progress later.

### Step 2 — Pull the failed logs (never guess from the job name)

The assess output prints the exact log command for your forge. Use it:

- **GitHub**: `gh run view <id> --log-failed`
- **Gitea**: `tea actions runs view <id> --jobs --remote origin` to find the
  failed job, then `tea actions runs logs <id> --job <job-id> --remote origin`
- **GitLab**: `glab ci view` then `glab ci trace <job>` (or `glab ci trace` for
  the running/last job)
- **Fallback**: open the `target_url` the commit-status API printed for the
  failing context.

Read the actual failing step. Treat it as a real debugging task — apply
`superpowers:systematic-debugging`. Identify the root cause from the log, not from
the check's name.

### Step 3 — Fix the root cause

Make the edits that address the underlying failure, not just the symptom the log
names. A failure at one call site often has siblings — fix the whole class, and
prefer a shared constant/helper so the drift can't recur.

**Fix breakage even if it's outside the original change's scope.** A red pipeline
you inherited is still a red pipeline; carrying it forward hides real regressions.
If a fix is genuinely huge or needs a product/human decision, stop and surface it
rather than pushing a band-aid.

If the failure is a flaky/infra issue (a runner died, a network blip, a transient
timeout with no code cause), don't invent a code change — re-run the job
(`gh run rerun <id> --failed`, `tea actions runs list` + re-trigger, `glab ci
retry`) and treat it as a `PENDING` wait. Only conclude "flake" from evidence in
the log, not convenience.

### Step 4 — Validate locally BEFORE pushing (mirror what CI runs)

The point of shepherding is to not burn a full CI cycle per guess. Reproduce the
specific failure locally first. Because this skill is repo-agnostic, **discover
the command instead of assuming one**:

1. **Read the CI definition** to see the exact command that failed. Look in:
   `.github/workflows/*.yml`, `.gitea/workflows/*.yml` / `.forgejo/workflows/*.yml`,
   `.gitlab-ci.yml`, `.woodpecker*.yml`, `.drone.yml`, `Jenkinsfile`. Find the job
   whose name matches the failing check and copy its script step.
2. **Prefer the repo's task runner** if it has one (the workflow usually calls it):
   `mise run <task>`, `just <task>`, `make <target>`, `npm/pnpm/yarn run <script>`,
   `cargo …`, `go test …`, `pytest …`, `tox`, `nox`. Run the narrowest command that
   covers the failure, then a broader build/test to be safe.
3. If the repo documents a "run CI locally" path (a `ci` task, `act`, a `mise`/
   `just` recipe), use it.

Run the reproduced command, confirm it now passes locally, and also build/typecheck
the parts you touched. If the failure is environment-only (a secret, a service, a
runner arch you don't have), you can't reproduce it — say so and rely on CI.

If your change regenerates artifacts (codegen, generated bindings, lockfiles,
snapshots), regenerate them and stage the results — a stale generated file is a
classic re-fail.

### Step 5 — Commit, push, and wait

Commit in the **repo's own style** (match the recent `git log` — conventional
commits, ticket prefixes, whatever it uses), staging only files you changed:

```bash
git add <specific files> && git commit -m "<style>: <what + why>"
git push
```

**Safety (hard rules, same as shepherd-pr):** never `--force` /
`--force-with-lease`, never `--no-verify` / `--no-gpg-sign`, never amend or rebase
already-pushed commits, never `git add -A`/`git add .`. If `git push` is rejected
as non-fast-forward, someone else pushed — `git pull --rebase`, re-validate, then
push. If CI says the branch is behind its base, merge the base in
(`git merge origin/<base>`) and resolve conflicts without discarding either side.

Then **wait for the new pipeline to settle** before re-assessing. Run the bundled
waiter in the **background** (so you don't block) — it polls the forge and returns
the moment CI is no longer pending, with a hard 30-minute cap so a stuck pipeline
can't wedge the loop:

```bash
# run_in_background: true — you'll be notified on completion
<skill-dir>/scripts/wait-ci.sh --interval 60 --timeout 1800
```

On GitHub you *may* instead use the native `gh run watch <id>` / `gh pr checks
--watch` for instant notification — but `wait-ci.sh` works on every forge and is
the default. Do **not** sleep-poll by hand. When the waiter returns, go to **Step 1**.

**Watchdog.** If `wait-ci.sh` exits 124 (timed out still pending) or you simply
haven't been notified after ~30 min, run `ci-status.sh` directly as an independent
poll and act on *its* verdict — another `PENDING` means CI is genuinely slow
(restart the waiter for another window); any other verdict means proceed. This
guarantees forward progress regardless of a hung watch.

Increment the counter. **Cap: 50 iterations.**

### Step 6 — Finish & report

When `VERDICT: GREEN`, post a concise report:
- Iterations used; final state (all checks green on `<forge>`).
- What you fixed each round, grouped by root cause.
- Anything you re-ran as a flake (with the log evidence).
- Anything still needing a human, if you stopped early.

Do not merge, deploy, or mark ready. Leave that to the user.

## Stop early (escalate) when

- **No progress**: the same check fails for **2 consecutive iterations** despite
  your fixes. Looping won't help — report what's stuck and what you tried.
- **50 iterations** reached.
- A failure needs a **product/human decision**, or a **secret/service/runner** you
  don't control (the check *cannot* pass from code).
- A **merge conflict** with base you can't resolve without losing work.
- Forge auth/permission errors, or pushes rejected for reasons other than
  non-fast-forward.
- `VERDICT: UNKNOWN` you can't clear (no authenticated adapter, no token).

Leave the branch clean (validated work committed/pushed) and tell the user exactly
what's blocking and what you'd try next.

## Anti-patterns

- Guessing the fix from a check's *name* instead of reading the failed log.
- Pushing before the failure reproduces-then-passes locally (when it's
  reproducible) — that just burns CI cycles.
- Fixing only the one line the log names when siblings have the same bug.
- `--force` / `--no-verify` / amending pushed commits to "make CI happy" — never.
- Assuming GitHub. Always let `ci-status.sh` detect the forge; the same loop runs
  on Gitea and GitLab.
- Assuming a fixed test command. Read the repo's CI file and task runner — the
  command varies per repo.
- Calling a real failure a "flake" without log evidence, or re-running a genuine
  code failure hoping it passes.
- Sleep-polling CI by hand instead of backgrounding `wait-ci.sh`.
- Merging / deploying / tagging — out of scope; stop and report.

## Bundled scripts

- `scripts/ci-status.sh [REF]` — detect forge, resolve repo/branch/head (strips
  any credential in the remote URL), and print a normalized `VERDICT:` line
  (`GREEN` / `FAILING` / `PENDING` / `NO_CI` / `UNKNOWN`) plus the per-forge log
  command. The single source of truth for "what is CI doing?".
- `scripts/wait-ci.sh [REF] [--interval S] [--timeout S]` — poll `ci-status.sh`
  until the verdict leaves `PENDING`, capped so a stuck pipeline can't hang the
  loop. Run it backgrounded.

## Related

- `shepherd-pr` — the richer GitHub-wired sibling that *also* satisfies the review
  bot. Use it when the repo is this GitHub repo and you need reviewer + CI both.
- `superpowers:systematic-debugging` — for the actual failure diagnosis.
- `superpowers:receiving-code-review` — if CI failures are paired with review
  feedback, evaluate before implementing.
