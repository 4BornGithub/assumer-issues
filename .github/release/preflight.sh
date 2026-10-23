#!/usr/bin/env bash
# preflight.sh <token|release-draft|release-any>
source "$(dirname "$0")/lib.sh"
case "$1" in
  token)
    # PROJECT_TOKEN must be able to write releases of the private repo: a classic token with the repo scope, or a
    # fine-grained token with push access to it.
    [ -n "${GH_TOKEN:-}" ] || { echo "PROJECT_TOKEN is empty"; exit 1; }
    scopes=$(curl -sS -D - -o /dev/null -H "Authorization: token $GH_TOKEN" https://api.github.com/rate_limit |
      tr -d '\r' | awk -F': ' 'tolower($1) == "x-oauth-scopes" {print $2}')
    push=$(gh api "repos/$PRIVATE" --jq .permissions.push)
    echo "scopes: ${scopes:-<none: fine-grained token>}"; echo "push to $PRIVATE: $push"
    [ "$push" = true ] || exit 1
    if [ -n "$scopes" ]; then tr ', ' '\n\n' <<<"$scopes" | grep -qx repo || { echo "no repo scope"; exit 1; }; fi
    ;;
  release-draft)
    json=$(release_json); [ -n "$json" ] && [ "$json" != null ] || { echo "no release v$VERSION"; exit 1; }
    jq '{tag_name, draft, prerelease, assets: [.assets[].name]}' <<<"$json"
    [ "$(jq -r .draft <<<"$json")" = true ] || { echo "v$VERSION is not a draft"; exit 1; }
    ;;
  release-any)
    json=$(release_json); [ -n "$json" ] && [ "$json" != null ] || { echo "no release v$VERSION"; exit 1; }
    jq '{tag_name, draft, prerelease, assets: [.assets[].name]}' <<<"$json"
    ;;
  *) exit 1 ;;
esac
