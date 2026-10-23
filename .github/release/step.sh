#!/usr/bin/env bash
# step.sh <name> <script> [args]: runs one release step with all output in the private log <name>.txt, prints ok/failed.
set -uo pipefail
name=$1; shift
mkdir -p "${RUNNER_TEMP:-/tmp}/rel/logs"
log="${RUNNER_TEMP:-/tmp}/rel/logs/$name.txt"
start=$SECONDS
if bash "$@" >> "$log" 2>&1; then echo ok; code=0; else code=$?; echo failed; fi
echo "$name exit=$code seconds=$((SECONDS - start))" >> "${RUNNER_TEMP:-/tmp}/rel/logs/steps.txt"
exit $code
