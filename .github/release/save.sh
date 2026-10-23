#!/usr/bin/env bash
# save.sh <job>: copies this job's logs to results/$RUN_KEY/<job>/ on branch os-results of the private repo.
source "$(dirname "$0")/lib.sh"
job=$1
[[ "$job" =~ ^[A-Za-z0-9._-]+$ && "${RUN_KEY:-}" =~ ^[A-Za-z0-9._-]+$ ]] || exit 1
jq -n --arg job "$job" --arg status "${JOB_STATUS:-}" --arg run "${GITHUB_RUN_ID:-}" --arg os "${RUNNER_OS:-}" \
  --arg arch "${RUNNER_ARCH:-}" --arg version "${VERSION:-}" --arg ref "${REF:-}" --arg finished "$(date -u +%FT%TZ)" \
  '{job:$job, status:$status, run_id:$run, runner_os:$os, runner_arch:$arch, version:$version, ref:$ref, finished:$finished}' \
  > "$LOGS/status.json"
find "$LOGS" -type f -size +45M -exec sh -c 'tail -c 45000000 "$1" > "$1.tmp" && mv "$1.tmp" "$1"' _ {} \;
OUT="$WORK/out"
for i in 1 2 3 4 5 6; do
  rm -rf "$OUT"
  auth git clone -q --depth 1 --branch os-results "https://github.com/$PRIVATE.git" "$OUT" || exit 1
  dest="$OUT/results/$RUN_KEY/$job"
  rm -rf "$dest" && mkdir -p "$dest" && cp -R "$LOGS/." "$dest/"
  git -C "$OUT" add -A
  git -C "$OUT" -c user.name=release -c user.email=release@users.noreply.github.com commit -qm "release $RUN_KEY $job" || exit 1
  auth git -C "$OUT" push -q "https://github.com/$PRIVATE.git" HEAD:os-results && exit 0
  sleep $((i * 4 + RANDOM % 5))
done
exit 1
