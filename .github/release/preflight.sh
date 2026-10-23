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
  draft)
    # Creates the draft v$VERSION, or replaces its notes, from release-notes/v$VERSION.md on branch os-results of the
    # private repo. A published release is never touched.
    rm -rf "$WORK/notes"
    auth git clone -q --depth 1 --branch os-results "https://github.com/$PRIVATE.git" "$WORK/notes" || exit 1
    notes="$WORK/notes/release-notes/v$VERSION.md"
    [ -s "$notes" ] || { echo "no release-notes/v$VERSION.md"; exit 1; }
    json=$(RELEASE_JSON_ONCE=1 release_json)
    if [ -z "$json" ] || [ "$json" = null ]; then
      jq -n --arg tag "v$VERSION" --arg name "Assumer $VERSION" --rawfile body "$notes" \
        '{tag_name:$tag, name:$name, body:$body, draft:true, prerelease:false}' |
        gh api -X POST "repos/$PRIVATE/releases" --input - --jq '{id, tag_name, draft, html_url}' || exit 1
    else
      [ "$(jq -r .draft <<<"$json")" = true ] || { echo "v$VERSION is already published"; exit 1; }
      # tag_name is sent every time: a PATCH of a draft without it leaves the draft untagged.
      jq -n --arg tag "v$VERSION" --arg name "Assumer $VERSION" --rawfile body "$notes" '{tag_name:$tag, name:$name, body:$body}' |
        gh api -X PATCH "repos/$PRIVATE/releases/$(jq -r .id <<<"$json")" --input - --jq '{id, tag_name, draft, html_url}' || exit 1
    fi
    [ "$(release_json | jq -r .tag_name)" = "v$VERSION" ] || { echo "draft is not tagged v$VERSION"; exit 1; }
    ;;
  *) exit 1 ;;
esac
