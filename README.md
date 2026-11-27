<h1 align="center">ship-safely</h1>

<p align="center">
  <strong>An Agent Skill that ships a code change behind a Flagsmith flag, rolls it out in stages with a health gate at every step, and kills it the moment a gate fails.</strong>
</p>

<p align="center">
  A rollout ends in one of two places: <em>on for everyone, flag removed</em>, or <em>off for everyone, with a written trail</em>. Never somewhere in between.
</p>

<p align="center">
  <a href="https://youtu.be/yktG5Ck0wxo"><img alt="Demo video, 2 minutes 36 seconds" src="https://img.shields.io/badge/demo_video-2:36-7b51fb"></a>
  <img alt="Agent Skill" src="https://img.shields.io/badge/Agent_Skill-agentskills.io-2f2f2f">
  <img alt="Built on Flagsmith CLI v2" src="https://img.shields.io/badge/Flagsmith_CLI-v2-2f2f2f">
  <img alt="Toggle Wars, Track 04" src="https://img.shields.io/badge/Toggle_Wars-Track_04-2f2f2f">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-2f2f2f">
</p>

<p align="center">
  <a href="https://youtu.be/yktG5Ck0wxo">
    <img src="https://img.youtube.com/vi/yktG5Ck0wxo/hqdefault.jpg" width="720" alt="ship-safely demo video thumbnail. Opens the 2 minute 36 second walkthrough on YouTube.">
  </a>
</p>

---

## Contents

- [Why](#why)
- [How it works](#how-it-works)
- [Safety by construction](#safety-by-construction)
- [Measured: token efficiency](#measured-token-efficiency)
- [Quick start](#quick-start)
- [Try the demo](#try-the-demo)
- [Command reference](#command-reference)
- [Found while building](#found-while-building)
- [Repository layout](#repository-layout)
- [License](#license)

## Why

Risky changes still go to 100% of users at once. Feature flags fix that, but when a coding agent drives the rollout it tends to stop halfway, skip the checks, or leave the flag and its segment behind as debt.

**ship-safely gives the agent one job with a clear end.** You say *"Ship the new checkout safely. Health command: `npm run smoke`."*, and the agent runs the whole release, stopping to ask you before every change to production.

## How it works

```text
preflight → start 5% → gate → 25% → gate → 50% → gate → 100% → gate → finish → remove flag → archive
                         │           │            │             │
                         └───────────┴────────────┴─────────────┴──► gate fails → kill (flag off for everyone)
                                                                                + incident note
```

| Step | What happens |
|---|---|
| **1. Preflight** | Confirms the project and environment **by name** before anything changes. |
| **2. Flag the change** | The new code path goes behind a per-user flag, with the old path as the default. |
| **3. Start at 5%** | Creates the feature (off for everyone), a feature-specific percentage-split segment, and turns the flag on for that segment only. |
| **4. Gate** | Waits until Flagsmith is *actually serving* the new share (edge servers lag a few seconds), then runs your health command and keeps only its exit code and last line. |
| **5. Widen** | 25% → 50% → 100%, with a human yes and a gate at every stage. |
| **6. Kill** | On any failed gate: flag off for the segment and the environment default, plus `.ship-safely/<feature>-incident.md` with the cause, stage, last gate and the command to resume. |
| **7. Finish** | After a passing gate at 100%: on for everyone, rollout segment deleted, so nothing is left holding the feature up. |
| **8. Archive** | Once the flag checks are out of the code. Refuses while `git grep` still finds the flag. |

## Safety by construction

> [!IMPORTANT]
> Every command that changes Flagsmith **refuses to run without `--approved`**. The skill tells the agent to pass it only after a human says yes to that exact step. The one pre-approved action is a kill after a failed gate.

- **One stage at a time.** Going backwards, or widening after a kill, is refused.
- **Finish needs proof.** `finish` runs only after a passing gate at 100%.
- **Archive needs clean code.** `archive` runs only after `finish`, and only when no code still references the flag.
- **Nothing is hidden.** State and history live in `.ship-safely/<feature>.json`, so any agent or person can see exactly where a rollout stands.

## Measured: token efficiency

Every command prints **one line of JSON**, and CLI errors come back as one line instead of a help page.

Same job, same model (Claude Code with Claude Opus 5.5, headless): roll `new-checkout` from 5% to 100% with a health gate after each stage, then finish. Run on Flagsmith Cloud, 26 Nov 2026.

| | With ship-safely | Raw Flagsmith CLI, no skill |
|---|---|---|
| Agent turns | **9** | 19 |
| Output tokens | **1,638** | 5,127 (3.1×) |
| Input tokens, incl. cache reads | **379k** | 1.03M (2.7×) |
| Cost | **$0.41** | $0.68 |
| Time | **82 s** | 125 s |
| How it ended | Flag on for everyone, segment removed | Flag default still **off**, rollout segment left at 100% |

The skill's own footprint for the whole job is about **1.9k tokens**: `SKILL.md` ≈ 1,285 plus all eight script outputs ≈ 630.

## Quick start

**Requirements:** the Flagsmith CLI v2+, `bash` and `jq`. Changing flags needs Flagsmith 2.263.0 or newer (Flagsmith Cloud works).

```sh
# 1. Install the Flagsmith CLI and bind your repo to a project
brew install Flagsmith/tap/flagsmith
flagsmith login && flagsmith init

# 2. Give your agent the skill (Claude Code shown; any Agent Skills-compatible agent works)
mkdir -p .claude/skills && cp -R path/to/ship-safely/skills/ship-safely .claude/skills/
```

Then ask your agent:

> Ship the new checkout safely. Health command: `npm run smoke`.

## Try the demo

`demo/` is a tiny checkout service whose new pricing path sits behind the `new-checkout` flag. Setting `BUG=1` plants a real defect in that path (carts over $50 throw an error), so you can watch a gate fail and the kill fire.

```sh
cd demo && npm install
flagsmith init --project <your-project> --create-environment Production
echo "FLAGSMITH_SERVER_KEY=$(flagsmith --yes environment key create Production --json | jq -r .key)" > .env
set -a && . ./.env && set +a && node server.mjs &     # BUG=1 node server.mjs to plant the defect

S=../skills/ship-safely/scripts/rollout.sh
$S preflight new-checkout
$S start new-checkout 5 --approved
$S gate  new-checkout -- node health.mjs
$S widen new-checkout 25 --approved && $S gate new-checkout -- node health.mjs
```

**What we saw on Flagsmith Cloud:**

| Stage | Users on the new path | Errors |
|---|---|---|
| 5% | 3 of 60 | 0 |
| 25% | 12 of 60 | 0 |
| 50% | 29 of 60 | 0 |
| 100% | 58–60 of 60 | 0 |
| 50% with `BUG=1` | 14 of 60 | **15 of 60** → gate failed → `kill` → next check: 0 of 60 |

## Command reference

All commands live in `skills/ship-safely/scripts/rollout.sh` and print one line of JSON.

| Command | Changes Flagsmith? | Prints |
|---|---|---|
| `preflight <feature>` | No | Project, environment, whether the feature exists, current stage |
| `start <feature> <pct> --approved` | Yes | Segment id, stage |
| `gate <feature> [--samples N] -- <health cmd>` | No | Live?, served share, health exit code and last line, next step. Exit 2 = failed (kill), 3 = not live yet |
| `widen <feature> <pct> --approved` | Yes | From → to |
| `kill <feature> --reason TEXT --approved` | Yes | Stage killed at, path to the incident note |
| `finish <feature> --approved` | Yes | Flag on for everyone |
| `archive <feature> --approved` | Yes | Archived |
| `status <feature>` | No | Stage, state flags, last event |

## Found while building

> [!NOTE]
> `flagsmith segment create --rules` can't create a **percentage-split** segment, the standard building block of a gradual rollout. The CLI omits an empty `property`, and the API answers a `PERCENTAGE_SPLIT` condition without that key with a 500. (`"property": null` works; `""` is a 400.)

The skill creates and widens the rollout segment through `flagsmith api` with `"property": null` until this is fixed in the CLI.

## Repository layout

```text
skills/ship-safely/
├── SKILL.md                    the job, step by step, with stop-and-ask points
├── scripts/rollout.sh          preflight · start · gate · widen · kill · finish · archive · status
└── references/
    ├── sdk-snippets.md         per-user flag checks for Node, Python and React
    └── troubleshooting.md      common CLI errors and what to do
demo/
├── server.mjs                  checkout service with a flagged pricing path (BUG=1 plants a defect)
└── health.mjs                  60 checkouts, fails above 1% errors
```

## License

[MIT](LICENSE)
