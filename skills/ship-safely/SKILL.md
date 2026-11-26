---
name: ship-safely
description: Ship a code change to production behind a Flagsmith feature flag, then roll it out in stages (5% → 25% → 50% → 100%) with a health gate at every stage, kill it instantly if a gate fails, and clean the flag up when it is fully out. Use when the user says "ship this safely", "roll this out gradually", "put this behind a flag", "canary this change", or asks to release a risky change with Flagsmith. Uses the Flagsmith CLI.
license: MIT
compatibility: Needs the Flagsmith CLI v2+ (brew install Flagsmith/tap/flagsmith), jq, bash, and a directory bound with `flagsmith init`. Changing flags needs Flagsmith 2.263.0+ (Flagsmith Cloud is fine).
metadata:
  author: 0xvikram
  version: "1.0"
---

# ship-safely

One job, start to finish: a change goes from "merged behind a flag" to "on for everyone, flag removed", or to "off for everyone, with a written trail", never to somewhere in between.

All Flagsmith work goes through `scripts/rollout.sh` (relative to this skill). Each command prints **one line of JSON**. Read that line; do not run raw `flagsmith` commands or print their full output unless debugging. Commands that change Flagsmith refuse to run without `--approved`.

## The rules

1. **Never pass `--approved` without a human "yes" for that exact step**, except `kill` after a failed gate (pre-approved in step 3).
2. **One stage at a time.** Gate, report, ask. Never widen twice in a row.
3. **A failed gate is a kill, not a retry.** Turn it off first, investigate after.
4. **Stop and ask** if anything is unexpected: the feature already exists with a different purpose, the environment is not the one the human named, a gate result looks wrong.

## Steps

### 1. Preflight

```sh
scripts/rollout.sh preflight <feature>
```

Check `context` (project and environment) with the human: "This will roll out in **<environment>** of **<project>**, correct?" If `exists` is true and you did not create it, ask before reusing it. Pick a feature name in kebab-case (e.g. `new-checkout`).

### 2. Put the change behind the flag

Wrap the new code path in a flag check, keeping the old path as the default. Use the project's existing Flagsmith SDK if there is one; otherwise see `references/sdk-snippets.md`. Evaluate per user (identity) so a percentage rollout means "this share of users", not "this share of requests". Commit this on a branch and get it merged and deployed: with the flag off, nothing changes for anyone.

Agree a **health command** with the human: something that exits non-zero when the change hurts users (a smoke test, an error-rate query, `npm test` against staging). It runs while the flag is live at each stage.

### 3. Start at 5%

Ask: "Start `<feature>` for 5% of users in <environment>? If a health gate fails I will turn it off for everyone immediately." On yes:

```sh
scripts/rollout.sh start <feature> 5 --approved --description "<one line>"
```

This creates the feature (off for everyone), a feature-specific segment `<feature>-rollout` with a percentage split, and turns the flag on for that segment only.

### 4. Gate

```sh
scripts/rollout.sh gate <feature> -- <health command>
```

It probes 20 identities to confirm Flagsmith serves the flag to about the intended share (`served_pct_sample`), then runs the health command and keeps only its exit code and last line.

- `ok:true` → report the one-line result and ask: "Widen to <next>%?"
- `ok:false` (exit 2) → **kill now** (step 6), then tell the human what failed.

A sample of 20 is coarse at 5% (expect 0 to 3 on). Treat `served_pct_sample` as a sanity check, not a measurement; the health command is the gate.

### 5. Widen, then gate again

```sh
scripts/rollout.sh widen <feature> 25 --approved
scripts/rollout.sh gate  <feature> -- <health command>
```

Repeat for 50 and 100, asking before each widen.

### 6. Kill (on any failed gate, or when the human says stop)

```sh
scripts/rollout.sh kill <feature> --reason "<what failed, in one sentence>" --approved
```

Turns the flag off for the segment and the environment default, and writes `.ship-safely/<feature>-incident.md` with the reason, the stage, the last gate result and the command to resume. Show the human the trail path. Do not restart until the cause is fixed; restarting begins again at 5%.

### 7. Finish at 100%

After a passing gate at 100%, ask, then:

```sh
scripts/rollout.sh finish <feature> --approved
```

Turns the flag on for everyone via the environment default and removes the rollout segment.

### 8. Remove the flag

Delete the flag checks and the old code path, keep the new path. Open a PR. After it merges:

```sh
scripts/rollout.sh archive <feature> --approved
```

`archive` refuses while `git grep` still finds the feature name in the code.

## Status and resuming

```sh
scripts/rollout.sh status <feature>
```

State lives in `.ship-safely/<feature>.json` (add `.ship-safely/` to `.gitignore`, or commit it as an audit log if the team wants one).

## When things go wrong

See `references/troubleshooting.md` for errors from the CLI (not logged in, wrong environment, old Flagsmith version, segment not found).
