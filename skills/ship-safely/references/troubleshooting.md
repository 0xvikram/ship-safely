# Troubleshooting

| What you see | Cause | Do |
|---|---|---|
| `flagsmith is not set up here` | No login or no `flagsmith.json` | Ask the human to run `flagsmith login` then `flagsmith init` in the repo |
| `not logged in` in CI | No browser login there | Set `FLAGSMITH_API_KEY` (Admin API key) and `FLAGSMITH_ENVIRONMENT` |
| Mutations fail with a version error | Self-hosted Flagsmith older than 2.263.0 | Upgrade, or use Flagsmith Cloud |
| `no rollout segment for <feature>` | `widen` before `start`, or the segment was deleted in the dashboard | Run `start <feature> 5 --approved` again |
| `served_pct_sample` far from the stage | Small sample, or the app evaluates per request instead of per identity | Re-run the gate with `--samples 100`; check the code uses identity flags |
| `refused: ... --approved` | Working as intended | Ask the human, then re-run with `--approved` |
| Gate passes but users report errors | The health command does not cover the change | Kill, then improve the health command before restarting |

Diagnostics (only when needed, they print more): `flagsmith config`, `flagsmith segment get <feature>-rollout`, `flagsmith flag get <feature> --segment <feature>-rollout`.
