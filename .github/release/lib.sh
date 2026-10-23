#!/usr/bin/env bash
# Shared by the release jobs (workflow release.yml). This repo is public, so it holds only these generic steps: the
# Assumer source and every build output stay in runner temp space, release files go to the GitHub release of the
# PRIVATE repo 4BornGithub/assumer-releases, and the full logs go to its branch os-results (results/<RUN_KEY>/<job>/).
# Nothing here prints; the workflow shows only each step's name and ok/failed.
set -uo pipefail

PRIVATE=4BornGithub/assumer-releases
WORK="${RUNNER_TEMP:-/tmp}/rel"
LOGS="$WORK/logs"
A="$WORK/assumer"
mkdir -p "$WORK" "$LOGS"

# Auth through an environment-only header, so the token is never written to disk or into a remote URL.
AUTH="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${GH_TOKEN:-}" | base64 | tr -d '\n\r')"
auth() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader GIT_CONFIG_VALUE_0="$AUTH" "$@"; }

# clone <repo> <ref> <dir>: a branch or tag is cloned shallow; a sha needs the history.
clone() {
  auth git clone -q --depth 1 --branch "$2" "https://github.com/4BornGithub/$1.git" "$3" && return 0
  rm -rf "$3"
  auth git clone -q --filter=blob:none --no-checkout "https://github.com/4BornGithub/$1.git" "$3" && git -C "$3" checkout -q "$2"
}

# The release v$VERSION (drafts included) as JSON.
release_json() {
  gh api "repos/$PRIVATE/releases?per_page=100" --jq "[.[] | select(.tag_name == \"v$VERSION\")] | first"
}

# asset <name> <file>: download one asset of v$VERSION through the API, which also serves drafts.
asset() {
  local id
  id=$(release_json | jq -r --arg n "$1" '.assets[] | select(.name == $n) | .id')
  [ -n "$id" ] && [ "$id" != null ] || { echo "no asset $1 on v$VERSION"; return 1; }
  gh api -H "Accept: application/octet-stream" "repos/$PRIVATE/releases/assets/$id" > "$2"
}

sha256() { if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# check_uploaded <file>...: each file is on v$VERSION under its own name with the same sha256.
check_uploaded() {
  local json f name local_sha remote_sha
  json=$(release_json)
  for f in "$@"; do
    name=$(basename "$f")
    local_sha=$(sha256 "$f")
    remote_sha=$(jq -r --arg n "$name" '.assets[] | select(.name == $n) | .digest // empty' <<<"$json" | sed 's/^sha256://')
    if [ -z "$remote_sha" ]; then
      asset "$name" "$WORK/check.bin" || return 1
      remote_sha=$(sha256 "$WORK/check.bin"); rm -f "$WORK/check.bin"
    fi
    [ "$local_sha" = "$remote_sha" ] || { echo "MISMATCH $name local $local_sha release $remote_sha"; return 1; }
    echo "uploaded ok $name $(wc -c < "$f" | tr -d ' ') $local_sha"
  done
}
