#!/usr/bin/env bash
# Generic runner for the OS check workflow. Everything it reads or writes is private (4BornGithub/assumer-releases):
#   branch os-checks   checks/<CHECK>/run.sh (+ optional checks/<CHECK>/needs listing extra repos, e.g. Assumer-Server)
#   branch os-results  results/<REQUEST_ID>/<OS_LABEL>/{status.json, log.txt, setup.txt, ...}   (written here)
# The code under test is cloned at REF into runner temp space. Nothing is printed; the token never reaches the check.
set -uo pipefail

PRIVATE=4BornGithub/assumer-releases
TMP=${RUNNER_TEMP:-$(mktemp -d)}
WORK="$TMP/osc"
OUT="$WORK/out"
RES="$WORK/res"
mkdir -p "$WORK" "$RES"
START=$(date -u +%FT%TZ)
SETUP_LOG="$RES/setup.txt"

git config --global core.autocrlf false
git config --global core.longpaths true
# Auth through an environment-only header, so the token is never written to disk or into a remote URL.
AUTH="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${GH_TOKEN:-}" | base64 | tr -d '\n\r')"
auth() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader GIT_CONFIG_VALUE_0="$AUTH" "$@"; }

publish() {
  local ok=$1 code=$2 msg=$3
  jq -n --argjson ok "$ok" --argjson exit_code "$code" --arg message "$msg" --arg check "${CHECK:-}" --arg ref "${REF:-}" \
    --arg sha "${SHA:-}" --arg os "${OS_LABEL:-}" --arg runner_os "${RUNNER_OS:-}" --arg started "$START" \
    --arg finished "$(date -u +%FT%TZ)" --arg request_id "${REQUEST_ID:-}" --arg run "${GITHUB_RUN_ID:-}" \
    '{ok:$ok, exit_code:$exit_code, message:$message, check:$check, ref:$ref, sha:$sha, os:$os, runner_os:$runner_os,
      started:$started, finished:$finished, request_id:$request_id, run_id:$run}' > "$RES/status.json"
  # Keep every file under GitHub's 100 MB limit.
  find "$RES" -type f -size +45M -exec sh -c 'tail -c 45000000 "$1" > "$1.tmp" && mv "$1.tmp" "$1"' _ {} \;
  local i
  for i in 1 2 3 4 5 6; do
    rm -rf "$OUT"
    if auth git clone -q --depth 1 --branch os-results "https://github.com/$PRIVATE.git" "$OUT" 2>>"$SETUP_LOG"; then :; else
      git init -q "$OUT" && git -C "$OUT" checkout -q --orphan os-results
    fi
    local dest="$OUT/results/$REQUEST_ID/$OS_LABEL"
    rm -rf "$dest" && mkdir -p "$dest" && cp -R "$RES/." "$dest/"
    git -C "$OUT" add -A
    git -C "$OUT" -c user.name=os-check -c user.email=os-check@users.noreply.github.com \
      commit -qm "os-check $CHECK $OS_LABEL $REQUEST_ID" || exit 1
    auth git -C "$OUT" push -q "https://github.com/$PRIVATE.git" HEAD:os-results 2>>"$SETUP_LOG" && { [ "$ok" = true ]; exit $?; }
    sleep $((i * 4 + RANDOM % 5))
  done
  exit 1
}

[[ "${CHECK:-}" =~ ^[a-z0-9-]+$ && "${REQUEST_ID:-}" =~ ^[A-Za-z0-9._-]+$ && -n "${OS_LABEL:-}" ]] || exit 1
[ -n "${GH_TOKEN:-}" ] || publish false 1 "PROJECT_TOKEN secret is empty or missing"

{
  auth git clone -q --depth 1 --branch os-checks "https://github.com/$PRIVATE.git" "$WORK/checks"
} >>"$SETUP_LOG" 2>&1 || publish false 1 "cannot read branch os-checks"
[ -f "$WORK/checks/checks/$CHECK/run.sh" ] || publish false 1 "no check named $CHECK"

clone_repo() { # <repo> <dir>
  auth git clone -q --filter=blob:none --no-checkout "https://github.com/4BornGithub/$1.git" "$2" &&
    git -C "$2" checkout -q "$REF" 2>/dev/null || git -C "$2" checkout -q "origin/$REF"
}
{ clone_repo Assumer "$WORK/assumer"; } >>"$SETUP_LOG" 2>&1 || publish false 1 "cannot check out Assumer at $REF"
SHA=$(git -C "$WORK/assumer" rev-parse HEAD)
SERVER_DIR=""
if grep -qx 'Assumer-Server' "$WORK/checks/checks/$CHECK/needs" 2>/dev/null; then
  { clone_repo Assumer-Server "$WORK/server" || { git -C "$WORK/server" checkout -q origin/HEAD; }; } >>"$SETUP_LOG" 2>&1 \
    || publish false 1 "cannot check out Assumer-Server"
  SERVER_DIR="$WORK/server"
fi

# The check runs without the token: AUTH is not exported and GH_TOKEN is removed from its environment.
code=0
(
  cd "$WORK/checks/checks/$CHECK" &&
  env -u GH_TOKEN -u GITHUB_TOKEN CHECKS_DIR="$WORK/checks" ASSUMER_DIR="$WORK/assumer" SERVER_DIR="$SERVER_DIR" \
    RESULTS_DIR="$RES" WORK_DIR="$WORK" bash ./run.sh
) > "$RES/log.txt" 2>&1 || code=$?
if [ "$code" -eq 0 ]; then publish true 0 "passed"; else publish false "$code" "check exited with $code"; fi
