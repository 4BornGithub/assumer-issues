#!/usr/bin/env bash
# Board sync for project users/4BornGithub/projects/26. Runs in the public assumer-issues repo; everything it
# reads or writes lives in the private repo 4BornGithub/assumer-releases:
#   branch board-requests  requests/<id>.json  {"issue": 465, "status": "Done – not deployed"}  (written by Claude)
#   branch board-sync      board.json, board.md, fields.json, status.json, results/<id>.json   (written here)
# A request is applied once: its result file marks it done. Column names match ignoring case, spaces and dashes.
# GH_TOKEN: classic token with the `project` and `repo` scopes (secret PROJECT_TOKEN). Nothing is printed.
set -uo pipefail

OWNER=4BornGithub
NUMBER=26
PRIVATE=4BornGithub/assumer-releases
WORK=$(mktemp -d)
REMOTE="https://x-access-token:${GH_TOKEN}@github.com/${PRIVATE}.git"
NOW=$(date -u +%FT%TZ)
# The id Claude sends with a dispatch, echoed in status.json so it can tell its own run has finished.
REQUEST_ID=$(jq -r '.client_payload.request_id // empty' "${GITHUB_EVENT_PATH:-/dev/null}" 2>/dev/null)

git config --global user.name "board-sync"
git config --global user.email "board-sync@users.noreply.github.com"

# Snapshot branch (created on first run).
if git clone -q --depth 1 --branch board-sync "$REMOTE" "$WORK/sync" 2>/dev/null; then :; else
  git init -q "$WORK/sync" && git -C "$WORK/sync" checkout -q --orphan board-sync && git -C "$WORK/sync" remote add origin "$REMOTE"
fi
OUT=$WORK/sync
mkdir -p "$OUT/results"

finish() {
  jq -n --argjson ok "$1" --arg message "$2" --arg at "$NOW" --arg project "${PROJECT_TITLE:-}" \
    --arg request_id "${REQUEST_ID:-}" --arg trigger "${GITHUB_EVENT_NAME:-local}" \
    '{ok:$ok, message:$message, project:$project, checked_at:$at, request_id:$request_id, trigger:$trigger}' > "$OUT/status.json"
  git -C "$OUT" add -A
  git -C "$OUT" commit -qm "board snapshot $NOW" || exit 0
  for attempt in 1 2 3; do
    git -C "$OUT" push -q origin HEAD:board-sync && exit 0
    git -C "$OUT" pull -q --rebase origin board-sync
  done
  exit 1
}

[ -n "${GH_TOKEN:-}" ] || finish false "PROJECT_TOKEN secret is empty or missing"
gh api user > /dev/null || finish false "token rejected by GitHub"

META=$(gh api graphql -f login="$OWNER" -F number="$NUMBER" -f query='
  query($login:String!, $number:Int!) {
    user(login:$login) { projectV2(number:$number) {
      id title url
      fields(first:50) { nodes { ... on ProjectV2SingleSelectField { id name options { id name } } } }
    } }
  }') || finish false "cannot read project $NUMBER (does the token have the project scope?)"
PROJECT_ID=$(jq -r '.data.user.projectV2.id // empty' <<<"$META")
[ -n "$PROJECT_ID" ] || finish false "project $NUMBER not found for $OWNER"
PROJECT_TITLE=$(jq -r '.data.user.projectV2.title' <<<"$META")
jq '.data.user.projectV2 | {title, url, fields: [.fields.nodes[] | select(.name)]}' <<<"$META" > "$OUT/fields.json"
STATUS_FIELD=$(jq -r '.fields[] | select(.name=="Status") | .id' "$OUT/fields.json")

# Reads every card. A page is retried when GitHub answers with an error, and the snapshot is only replaced when the
# number of cards read equals the board's own totalCount, so a partial read never looks like a complete board.
export_items() {
  local after=null page total="" attempt
  : > "$WORK/items.ndjson"
  while :; do
    for attempt in 1 2 3 4; do
      page=$(gh api graphql -f login="$OWNER" -F number="$NUMBER" -F after="$after" -f query='
        query($login:String!, $number:Int!, $after:String) {
          user(login:$login) { projectV2(number:$number) { items(first:100, after:$after) {
            totalCount
            pageInfo { hasNextPage endCursor }
            nodes {
              id updatedAt
              status: fieldValueByName(name:"Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
              content {
                __typename
                ... on Issue { number title state url repository { nameWithOwner } assignees(first:5) { nodes { login } } labels(first:20) { nodes { name } } }
                ... on PullRequest { number title state url repository { nameWithOwner } }
                ... on DraftIssue { title }
              }
            }
          } } }
        }') && jq -e '.data.user.projectV2.items.nodes | type == "array"' <<<"$page" > /dev/null && break
      page=""
      sleep $((attempt * 5))
    done
    [ -n "$page" ] || { echo "a page failed 4 times" > "$WORK/why"; return 1; }
    # A card whose content the token cannot read comes back with a partial error; the count check below still
    # guarantees nothing was skipped. The error's type is kept for the status line (no private text).
    jq -r '.errors[]? | "\(.type // "error") at \((.path // []) | map(tostring) | join("."))"' <<<"$page" >> "$WORK/partial-errors"
    total=$(jq -r '.data.user.projectV2.items.totalCount' <<<"$page")
    jq -c '.data.user.projectV2.items.nodes[] | {
        item_id: .id, status: (.status.name // "No status"), type: .content.__typename, number: .content.number,
        repo: .content.repository.nameWithOwner, title: .content.title, state: .content.state, url: .content.url,
        assignees: [.content.assignees.nodes[]?.login], labels: [.content.labels.nodes[]?.name], updated_at: .updatedAt }' \
      <<<"$page" >> "$WORK/items.ndjson" || return 1
    [ "$(jq -r '.data.user.projectV2.items.pageInfo.hasNextPage' <<<"$page")" = true ] || break
    after=$(jq -r '.data.user.projectV2.items.pageInfo.endCursor' <<<"$page")
  done
  [ "$(wc -l < "$WORK/items.ndjson")" -eq "$total" ] || { echo "read $(wc -l < "$WORK/items.ndjson") of $total; errors: $(sort "$WORK/partial-errors" 2>/dev/null | uniq -c | tr -s ' ' | tr '\n' ',' | cut -c1-300)" > "$WORK/why"; return 1; }
  jq -s 'sort_by(.status, -(.number // 0))' "$WORK/items.ndjson" > "$OUT/board.json"
}

read_board() { local n; for n in 1 2 3; do export_items && return 0; sleep $((n * 10)); done; return 1; }
read_board || {
  # Say why, without printing anything private: the GraphQL rate limit is the usual cause on busy days.
  RATE=$(gh api graphql -f query='query { rateLimit { remaining resetAt } }' --jq '"\(.data.rateLimit.remaining) points left, resets \(.data.rateLimit.resetAt)"' 2>/dev/null || echo "rate limit unknown")
  finish false "could not read the whole board ($(cat "$WORK/why" 2>/dev/null || echo unknown); $RATE); the previous snapshot is kept"
}

# Apply new move requests.
if git clone -q --depth 1 --branch board-requests "$REMOTE" "$WORK/req" 2>/dev/null; then
  moved=0
  for f in "$WORK"/req/requests/*.json; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .json)
    [ -e "$OUT/results/$id.json" ] && continue
    issue=$(jq -r '.issue' "$f")
    target=$(jq -r '.status' "$f")
    norm() { tr '[:upper:]' '[:lower:]' <<<"$1" | tr -cd 'a-z0-9'; }
    option=$(jq -r '.fields[] | select(.name=="Status") | .options[] | "\(.id)\t\(.name)"' "$OUT/fields.json" |
      while IFS=$'\t' read -r oid oname; do [ "$(norm "$oname")" = "$(norm "$target")" ] && echo "$oid" && break; done)
    result() { jq -n --arg id "$id" --argjson issue "$issue" --arg status "$target" --argjson ok "$1" --arg message "$2" --arg at "$NOW" \
      '{id:$id, issue:$issue, status:$status, ok:$ok, message:$message, at:$at}' > "$OUT/results/$id.json"; }
    if [ -z "$option" ]; then result false "the board has no column named '$target'"; continue; fi
    item=$(jq -r --argjson n "$issue" --arg r "$PRIVATE" '.[] | select(.number==$n and ((.repo // "")|ascii_downcase)==($r|ascii_downcase)) | .item_id' "$OUT/board.json" | head -1)
    if [ -z "$item" ]; then
      node=$(gh api "repos/$PRIVATE/issues/$issue" --jq .node_id) || { result false "issue #$issue not found"; continue; }
      item=$(gh api graphql -f p="$PROJECT_ID" -f c="$node" -f query='
        mutation($p:ID!, $c:ID!) { addProjectV2ItemById(input:{projectId:$p, contentId:$c}) { item { id } } }' \
        --jq '.data.addProjectV2ItemById.item.id') || { result false "could not add #$issue to the board"; continue; }
    fi
    if gh api graphql -f p="$PROJECT_ID" -f i="$item" -f f="$STATUS_FIELD" -f o="$option" -f query='
        mutation($p:ID!, $i:ID!, $f:ID!, $o:String!) {
          updateProjectV2ItemFieldValue(input:{projectId:$p, itemId:$i, fieldId:$f, value:{singleSelectOptionId:$o}}) { projectV2Item { id } }
        }' > /dev/null; then
      result true "moved"; moved=$((moved + 1))
    else
      result false "GitHub refused the move"
    fi
  done
  [ "$moved" -gt 0 ] && { read_board || finish false "moved cards but could not re-read the board"; }
fi

{
  echo "# $PROJECT_TITLE"
  echo
  echo "Snapshot $NOW. $(jq length "$OUT/board.json") cards."
  echo
  echo "| Status | Cards |"
  echo "|---|---|"
  jq -r 'group_by(.status)[] | "| \(.[0].status) | \(length) |"' "$OUT/board.json"
  jq -r 'group_by(.status)[] | "\n## \(.[0].status) (\(length))\n", (.[] | "- #\(.number // "-") \(.title)\(if (.assignees|length)>0 then " (" + (.assignees|join(", ")) + ")" else "" end)")' "$OUT/board.json"
} > "$OUT/board.md"

finish true "read $(jq length "$OUT/board.json") cards$( [ -s "$WORK/partial-errors" ] && echo "; partial errors: $(sort "$WORK/partial-errors" | uniq -c | tr -s ' ' | tr '\n' ',')" )"
