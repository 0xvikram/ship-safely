#!/usr/bin/env bash
# ship-safely: staged Flagsmith rollouts with health gates and a kill switch.
# Every command prints ONE line of JSON so an agent spends as few tokens as possible.
# Commands that change Flagsmith refuse to run without --approved: the agent passes it only after a human says yes.
#
#   rollout.sh preflight <feature>
#   rollout.sh start     <feature> <pct> --approved [--description TEXT]
#   rollout.sh widen     <feature> <pct> --approved
#   rollout.sh gate      <feature> [--samples N] -- <health command...>
#   rollout.sh kill      <feature> --reason TEXT --approved
#   rollout.sh finish    <feature> --approved
#   rollout.sh archive   <feature> --approved
#   rollout.sh status    <feature>
set -euo pipefail
exec 3>&1 # errors go to the real stdout even from inside $(...)

STATE_DIR="${SHIP_SAFELY_STATE:-.ship-safely}"
FS=(flagsmith --no-input)
# fs: a read; fsm: a change (only reached after --approved). Both return the CLI's stdout, or fail with its first error line as JSON.
fs() { local out; if ! out="$("${FS[@]}" "$@" 2>&1)"; then die "flagsmith $(printf '%s ' "$@" | sed 's/--yes //' | cut -c1-40)failed: $(printf '%s' "$out" | grep -m1 -i 'error' | cut -c1-200)"; fi; printf '%s' "$out"; }
fsm() { fs --yes "$@"; }

die() { jq -cn --arg e "$1" --arg hint "${2:-}" '{ok:false,error:$e} + (if $hint=="" then {} else {hint:$hint} end)' >&3; exit 1; }
need() { command -v "$1" >/dev/null || die "missing dependency: $1" "${2:-}"; }
need flagsmith "install: brew install Flagsmith/tap/flagsmith"
need jq

cmd="${1:-}"; shift || true
feature="${1:-}"; [ -n "$feature" ] && shift || true
[[ "$cmd" =~ ^(preflight|start|widen|gate|kill|finish|archive|status)$ ]] || die "usage: rollout.sh <preflight|start|widen|gate|kill|finish|archive|status> <feature> ..."
[ -n "$feature" ] || die "feature name required"
[[ "$feature" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || die "feature names: lowercase letters, digits, - and _"

approved=0; reason=""; description=""; samples=20; pct=""; health=()
while [ $# -gt 0 ]; do
  case "$1" in
    --approved) approved=1 ;;
    --reason) reason="${2:-}"; shift ;;
    --description) description="${2:-}"; shift ;;
    --samples) samples="${2:-20}"; shift ;;
    --) shift; health=("$@"); break ;;
    *) [ -z "$pct" ] && pct="$1" || die "unexpected argument: $1" ;;
  esac
  shift
done

mutating() { [ "$approved" = 1 ] || die "refused: '$cmd' changes Flagsmith; ask the human, then re-run with --approved"; }
seg_name="${feature}-rollout"
state_file="$STATE_DIR/$feature.json"
mkdir -p "$STATE_DIR"
[ -f "$state_file" ] || echo '{"feature":"'"$feature"'","stage":0,"history":[]}' > "$state_file"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
record() { # record <event> <json-object>
  local tmp; tmp="$(mktemp)"
  jq -c --arg ev "$1" --arg at "$(now)" --argjson d "$2" '.history += [{at:$at, event:$ev} + $d] | . + $d' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}
rules() { jq -cn --arg p "$1" '{type:"ALL",rules:[{type:"ANY",conditions:[{operator:"PERCENTAGE_SPLIT",property:null,value:$p}]}]}'; }
# `flagsmith segment create/update --rules` drops an empty "property", and the API answers a percentage split
# without that key with a 500. So the rollout segment goes through `flagsmith api` with "property": null.
project_id() { fs config --json | jq -r '.project.value'; }
seg_create() { # seg_create <pct> -> segment id
  local fid body; fid="$(fs feature get "$feature" --jq .id)"
  body="$(jq -cn --arg n "$seg_name" --argjson pr "$(project_id)" --argjson f "$fid" --argjson r "$(rules "$1")" --arg d "ship-safely staged rollout of $feature" \
    '{name:$n, project:$pr, feature:$f, description:$d, rules:[$r]}')"
  printf '%s' "$body" | fs api "api/v1/projects/$(project_id)/segments/" -X POST --input - | jq -r .id
}
seg_set_pct() { # seg_set_pct <segment id> <pct>
  local body; body="$(jq -cn --arg n "$seg_name" --argjson r "$(rules "$2")" '{name:$n, rules:[$r]}')"
  printf '%s' "$body" | fs api "api/v1/projects/$(project_id)/segments/$1/" -X PATCH --input - >/dev/null
}
valid_pct() { [[ "$pct" =~ ^[0-9]+$ ]] && [ "$pct" -ge 1 ] && [ "$pct" -le 100 ] || die "percentage must be 1-100"; }
seg_id() { "${FS[@]}" segment list --include-feature-specific --jq "[.[] | select(.name==\"$seg_name\") | .id][0] // empty" 2>/dev/null || true; }
env_name() { "${FS[@]}" config --json 2>/dev/null | jq -r '.environment.value // .environment // empty' 2>/dev/null || true; }

case "$cmd" in
preflight)
  cfg="$("${FS[@]}" config --json 2>/dev/null)" || die "flagsmith is not set up here" "run: flagsmith login && flagsmith init"
  exists="$("${FS[@]}" feature list --jq "[.[] | select(.name==\"$feature\")] | length" 2>/dev/null || echo 0)"
  default="null"; [ "$exists" != 0 ] && default="$("${FS[@]}" flag get "$feature" --jq '.enabled' 2>/dev/null || echo null)"
  sid="$(seg_id)"
  jq -cn --argjson cfg "$cfg" --arg f "$feature" --argjson exists "$exists" --argjson def "$default" --arg sid "$sid" --slurpfile st "$state_file" \
    '{ok:true, feature:$f, exists:($exists>0), default_enabled:$def, rollout_segment:(if $sid=="" then null else ($sid|tonumber) end), stage:$st[0].stage,
      context:{project:($cfg.project.name // $cfg.project.value), environment:($cfg.environment.name // $cfg.environment.value)}}'
  ;;

start)
  mutating; valid_pct
  exists="$(fs feature list --jq "[.[] | select(.name==\"$feature\")] | length")"
  if [ "$exists" = 0 ]; then
    fsm feature create "$feature" --description "${description:-Rolled out by ship-safely}" --json >/dev/null
  fi
  fsm flag update "$feature" --disable --json >/dev/null              # everyone else stays on the old path
  sid="$(seg_id)"
  if [ -z "$sid" ]; then
    sid="$(seg_create "$pct")"
  else
    seg_set_pct "$sid" "$pct"
  fi
  fsm flag update "$feature" --enable --segment "$sid" --json >/dev/null
  record start "$(jq -cn --argjson s "$sid" --argjson p "$pct" '{segment:$s, stage:$p, killed:false}')"
  jq -cn --arg f "$feature" --argjson s "$sid" --argjson p "$pct" '{ok:true, feature:$f, segment:$s, rollout_pct:$p, next:"gate"}'
  ;;

widen)
  mutating; valid_pct
  sid="$(seg_id)"; [ -n "$sid" ] || die "no rollout segment for $feature" "run start first"
  cur="$(jq '.stage' "$state_file")"
  [ "$(jq -r '.killed // false' "$state_file")" = "true" ] && die "rollout was killed; fix the cause, then start again" "rollout.sh start $feature <pct> --approved"
  [ "$pct" -gt "$cur" ] || die "new percentage ($pct) must be above the current stage ($cur)"
  seg_set_pct "$sid" "$pct"
  record widen "$(jq -cn --argjson p "$pct" '{stage:$p}')"
  jq -cn --arg f "$feature" --argjson from "$cur" --argjson to "$pct" '{ok:true, feature:$f, from_pct:$from, rollout_pct:$to, next:"gate"}'
  ;;

gate)
  [ "${#health[@]}" -gt 0 ] || die "gate needs a health command after --" "e.g. rollout.sh gate $feature -- npm test"
  stage="$(jq '.stage' "$state_file")"
  # 1. wait until Flagsmith actually serves the new share (edge servers take a few seconds after a change);
  #    a health check that runs before the change is live would pass for the wrong reason.
  #    "plausible" = within 2.5 standard deviations of the stage for this sample size.
  low="$(awk -v p="$stage" -v n="$samples" 'BEGIN{sd=sqrt(p*(100-p)/n); l=p-2.5*sd; print (l<0?0:l)}')"
  high="$(awk -v p="$stage" -v n="$samples" 'BEGIN{sd=sqrt(p*(100-p)/n); h=p+2.5*sd; print (h>100?100:h)}')"
  served=0; tries=0; live=false
  while [ "$tries" -lt "${SHIP_SAFELY_PROBE_TRIES:-6}" ]; do
    tries=$((tries+1)); on=0
    for i in $(seq 1 "$samples"); do
      v="$("${FS[@]}" evaluate "$feature" --identity "ship-safely-probe-$i" --jq '.enabled' 2>/dev/null || echo false)"
      [ "$v" = "true" ] && on=$((on+1))
    done
    served=$(( on * 100 / samples ))
    if awk -v s="$served" -v l="$low" -v h="$high" 'BEGIN{exit !(s>=l && s<=h)}'; then live=true; break; fi
    sleep "${SHIP_SAFELY_PROBE_WAIT:-5}"
  done
  if [ "$live" != true ]; then
    jq -cn --arg f "$feature" --argjson p "$stage" --argjson served "$served" --argjson t "$tries" \
      '{ok:false, feature:$f, rollout_pct:$p, served_pct_sample:$served, probe_tries:$t, live:false,
        next:"not live yet: Flagsmith is not serving \($p)% after \($t) probes; wait and re-run gate (do not kill, do not widen)"}'
    exit 3
  fi
  # 2. the human-chosen health check, run while the flag is live; only its exit code and last line are kept
  set +e; out="$("${health[@]}" 2>&1)"; code=$?; set -e
  last="$(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
  pass=$([ "$code" = 0 ] && echo true || echo false)
  record gate "$(jq -cn --argjson p "$stage" --argjson served "$served" --argjson pass "$pass" --arg last "$last" '{gate:{stage:$p, served_pct:$served, health_ok:$pass, health_tail:$last}}')"
  jq -cn --arg f "$feature" --argjson p "$stage" --argjson served "$served" --argjson n "$samples" --argjson t "$tries" --argjson pass "$pass" --argjson code "$code" --arg last "$last" \
    '{ok:$pass, feature:$f, rollout_pct:$p, live:true, served_pct_sample:$served, samples:$n, probe_tries:$t, health_exit:$code, health_tail:$last,
      next:(if $pass then (if $p>=100 then "finish" else "ask human: widen?" end) else "KILL NOW: rollout.sh kill \($f) --reason ... --approved" end)}'
  [ "$pass" = true ] || exit 2
  ;;

kill)
  mutating; [ -n "$reason" ] || die "kill needs --reason (it becomes the trail for the follow-up)"
  sid="$(seg_id)"
  [ -n "$sid" ] && fsm flag update "$feature" --disable --segment "$sid" --json >/dev/null
  fsm flag update "$feature" --disable --json >/dev/null
  stage="$(jq '.stage' "$state_file")"
  record kill "$(jq -cn --arg r "$reason" --argjson p "$stage" '{killed:true, kill:{reason:$r, at_pct:$p}}')"
  trail="$STATE_DIR/$feature-incident.md"
  {
    echo "# $feature killed at ${stage}%"; echo; echo "- When: $(now)"; echo "- Why: $reason"
    echo "- State now: flag OFF for everyone (segment override and environment default)"
    echo "- Last gate: $(jq -c '.history | map(select(.event=="gate")) | last // {} | .gate // {}' "$state_file")"
    echo; echo "## Resume after the fix"; echo; echo '```sh'; echo "rollout.sh start $feature 5 --approved"; echo '```'
  } > "$trail"
  jq -cn --arg f "$feature" --argjson p "$stage" --arg t "$trail" '{ok:true, feature:$f, killed_at_pct:$p, flag:"off for everyone", trail:$t}'
  ;;

finish)
  mutating
  [ "$(jq '.stage' "$state_file")" -ge 100 ] || die "finish only after a passing gate at 100%" "rollout.sh widen $feature 100 --approved, then gate"
  last_ok="$(jq -r '.history | map(select(.event=="gate")) | last | .gate.health_ok // false' "$state_file")"
  [ "$last_ok" = "true" ] || die "the last gate did not pass"
  fsm flag update "$feature" --enable --json >/dev/null              # on for everyone without the segment
  sid="$(seg_id)"
  if [ -n "$sid" ]; then
    fsm flag delete "$feature" --segment "$sid" --json >/dev/null 2>&1 || true
    fsm segment delete "$sid" --json >/dev/null
  fi
  record finish '{"finished":true}'
  jq -cn --arg f "$feature" '{ok:true, feature:$f, flag:"on for everyone", next:"remove the flag checks from code, merge, then rollout.sh archive"}'
  ;;

archive)
  mutating
  [ "$(jq -r '.finished // false' "$state_file")" = "true" ] || die "archive only after finish"
  if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
    left="$(git grep -n -I -- "$feature" -- ':!.ship-safely' 2>/dev/null | head -5 || true)"
    [ -z "$left" ] || die "the flag is still referenced in code" "$(printf '%s' "$left" | tr '\n' ';' | cut -c1-300)"
  fi
  fsm feature update "$feature" --archive --json >/dev/null
  record archive '{"archived":true}'
  jq -cn --arg f "$feature" '{ok:true, feature:$f, archived:true}'
  ;;

status)
  jq -c '{feature, stage, killed:(.killed//false), finished:(.finished//false), archived:(.archived//false), events:(.history|length), last:(.history|last // null)}' "$state_file"
  ;;
esac
