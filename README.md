# ship-safely

**An Agent Skill that takes a code change from "merged behind a Flagsmith flag" to "on for everyone, flag removed", or to "off for everyone, with a written trail". Never somewhere in between.**

Built on the [Flagsmith CLI](https://github.com/Flagsmith/flagsmith-cli) for Toggle Wars (WeMakeDevs × Flagsmith), Track 04: Flagsmith Agent Skills.

```
preflight → start 5% → gate → widen 25% → gate → 50% → gate → 100% → gate → finish → remove flag → archive
                         │                 │              │               │
                         └── a failed gate at any stage → kill: flag off for everyone + incident note
```

## What it does

You tell your coding agent "ship this safely". The skill makes it:

1. **Preflight** – confirm the project and environment by name before touching anything.
2. **Put the change behind a flag**, evaluated per user, with the old path as the default.
3. **Start at 5%** – creates the feature (off for everyone), a feature-specific percentage-split segment, and turns the flag on for that segment only.
4. **Gate every stage** – first waits until Flagsmith is *actually serving* the new share (edge servers lag a few seconds; a health check that runs before the change is live passes for the wrong reason), then runs your health command and keeps only its exit code and last line.
5. **Widen** 25% → 50% → 100%, asking a human before each step.
6. **Kill** on any failed gate: flag off for the segment and the environment default, plus `.ship-safely/<feature>-incident.md` with the reason, stage, last gate and the command to resume.
7. **Finish** at 100%: on for everyone via the environment default, rollout segment deleted (no leftover segment holding the feature up).
8. **Archive** after the flag checks are removed from the code – it refuses while `git grep` still finds the flag.

## Safety by construction

- Every command that changes Flagsmith **refuses without `--approved`**. The skill tells the agent to pass it only after a human says yes for that exact step (kill after a failed gate is pre-approved at start).
- **One stage at a time**: widening below the current stage, or after a kill, is refused.
- `finish` only runs after a **passing gate at 100%**; `archive` only after `finish` and only when the code is clean.
- State and history live in `.ship-safely/<feature>.json`, so any agent (or person) can see exactly where a rollout stands.

## Token efficiency (measured)

Every command prints **one line of JSON**, and CLI errors come back as one line instead of a help page.

Same job, same model (Claude Code, headless): roll `new-checkout` out 5% → 25% → 50% → 100% with a health gate after each stage, then finish. Run on Flagsmith Cloud, 26 Nov 2026.

|  | **with ship-safely** | raw Flagsmith CLI, no skill |
|---|---|---|
| Agent turns | **9** | 19 |
| Output tokens | **1,638** | 5,127 (3.1×) |
| Input tokens (incl. cache reads) | **379k** | 1.03M (2.7×) |
| Cost | **$0.41** | $0.68 |
| Time | **82 s** | 125 s |
| Ended | flag on for everyone, segment removed | flag default still **off**, rollout segment left at 100% |

The skill's own footprint for the whole job: **SKILL.md ≈ 1,285 tokens + all 8 script outputs ≈ 630 tokens**.

## Install

```sh
brew install Flagsmith/tap/flagsmith      # Flagsmith CLI v2+
flagsmith login && flagsmith init          # in your repo
```

Copy `skills/ship-safely/` into your agent's skills folder, for Claude Code `.claude/skills/ship-safely/` (or symlink it, as `demo/` does). Needs `bash` and `jq`. Changing flags needs Flagsmith 2.263.0+ (Flagsmith Cloud is fine).

Then ask your agent: *"Ship the new checkout safely. Health command: `npm run smoke`."*

## Run the demo yourself

`demo/` is a tiny checkout service whose new pricing path sits behind `new-checkout`. `BUG=1` plants a real defect in that path (carts over $50 throw), so you can watch a gate fail and the kill fire.

```sh
cd demo && npm install
flagsmith init --project <your-project> --create-environment Production
echo "FLAGSMITH_SERVER_KEY=$(flagsmith --yes environment key create Production --json | jq -r .key)" > .env
set -a && . ./.env && set +a && node server.mjs &        # add BUG=1 to plant the defect

S=../skills/ship-safely/scripts/rollout.sh
$S preflight new-checkout
$S start new-checkout 5 --approved
$S gate  new-checkout -- node health.mjs
$S widen new-checkout 25 --approved && $S gate new-checkout -- node health.mjs
```

What we saw on Flagsmith Cloud: at 5% 3/60 users got the new path, at 25% 12/60, at 50% 29/60, at 100% 58–60/60, all with 0 errors. With `BUG=1` at 50%, the gate saw 15/60 errors; `kill` turned the flag off and the next health check showed 0/60 errors.

## Commands

| Command | Changes Flagsmith | What it prints |
|---|---|---|
| `preflight <feature>` | no | project, environment, whether the feature exists, current stage |
| `start <feature> <pct> --approved` | yes | segment id, stage |
| `gate <feature> [--samples N] -- <health cmd>` | no | live?, served share, health exit code and last line, next step (exit 2 = failed → kill, 3 = not live yet) |
| `widen <feature> <pct> --approved` | yes | from → to |
| `kill <feature> --reason TEXT --approved` | yes | stage killed at, path to the incident note |
| `finish <feature> --approved` | yes | flag on for everyone |
| `archive <feature> --approved` | yes | archived |
| `status <feature>` | no | stage, flags, last event |

## Found while building

`flagsmith segment create --rules` can't create a **percentage-split** segment, the standard building block of a gradual rollout: the CLI omits an empty `property`, and the API answers a `PERCENTAGE_SPLIT` condition without that key with a 500 (`"property": null` works, `""` is a 400). The skill creates and widens the rollout segment through `flagsmith api` with `"property": null` until that is fixed upstream.

## License

MIT
