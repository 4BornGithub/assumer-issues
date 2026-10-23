#!/usr/bin/env bash
# npm.sh <clone|install|fetch|dry-run|login|publish|verify>: publishes to npm exactly the binaries release v$VERSION
# carries (release-checklist.md section 4), with packages/assumer/script/unpack-release.ts and publish.ts.
source "$(dirname "$0")/lib.sh"
P="$A/packages/assumer"
NAMES="linux-arm64 linux-x64 linux-x64-baseline linux-arm64-musl linux-x64-musl linux-x64-baseline-musl darwin-arm64 darwin-x64 darwin-x64-baseline windows-arm64 windows-x64 windows-x64-baseline"
# Homebrew is never updated from here (it needs public archives); ASSUMER_RELEASE stays unset so publish.ts skips it.
unset ASSUMER_RELEASE
case "$1" in
  clone)
    clone Assumer "$REF" "$A" || exit 1
    git -C "$A" log -1 --format='%H %s'
    [ -f "$P/script/unpack-release.ts" ] && grep -q -- '--dry-run' "$P/script/publish.ts" || { echo "ref lacks the dry-run publish"; exit 1; }
    ;;
  install)
    cd "$A" && GITHUB_TOKEN="$GH_TOKEN" bun install --frozen-lockfile --ignore-scripts
    ;;
  fetch)
    mkdir -p "$WORK/archives"
    files=()
    for t in $NAMES; do
      case $t in linux-*) f="assumer-$t.tar.gz" ;; *) f="assumer-$t.zip" ;; esac
      asset "$f" "$WORK/archives/$f" || exit 1
      files+=("$WORK/archives/$f")
    done
    check_uploaded "${files[@]}" || exit 1
    cd "$P" && ASSUMER_VERSION="$VERSION" bun run script/unpack-release.ts "$WORK/archives" || exit 1
    out=$(dist/assumer-linux-x64/bin/assumer --version); echo "linux-x64 --version: $out"; [ "$out" = "$VERSION" ]
    ;;
  dry-run)
    cd "$P" && env -u NPM_TOKEN -u NODE_AUTH_TOKEN ASSUMER_VERSION="$VERSION" bun run script/publish.ts --dry-run || exit 1
    for w in assumer-ai @4born-solutions-assumer; do
      jq '{name, version, optionalDependencies}' "dist/wrapper-$w/package.json"
      jq -e --arg v "$VERSION" '.version == $v and (.optionalDependencies | length == 12 and all(.[]; . == $v))' "dist/wrapper-$w/package.json" > /dev/null || exit 1
    done
    ;;
  login)
    [ -n "${NPM_TOKEN:-}" ] || { echo "NPM_TOKEN not set"; exit 1; }
    printf '//registry.npmjs.org/:_authToken=${NPM_TOKEN}\n' > "$WORK/npmrc"
    NPM_CONFIG_USERCONFIG="$WORK/npmrc" npm whoami
    ;;
  token-facts)
    # Read-only facts about NPM_TOKEN; the token itself is never printed.
    [ -n "${NPM_TOKEN:-}" ] || { echo "NPM_TOKEN not set"; exit 1; }
    export NPM_CONFIG_USERCONFIG="$WORK/npmrc"
    user=$(npm whoami) || { echo "whoami failed"; exit 1; }
    echo "npm user: $user"
    echo "== profile (2FA)"; npm profile get --json 2>&1 | jq -c '{name, tfa, email_verified}' || true
    echo "== access"
    npm access list packages "$user" --json > "$WORK/access.json" 2>&1 || true
    cat "$WORK/access.json"
    bad=0
    for p in assumer-ai @4born-solutions/assumer $(for t in $NAMES; do echo "assumer-$t"; done); do
      acc=$(jq -r --arg p "$p" '.[$p] // "none"' "$WORK/access.json" 2>/dev/null)
      maint=$(npm view "$p" maintainers --json 2>/dev/null | jq -r --arg u "$user" 'if type=="array" then (map(if type=="string" then . else .name end) | map(split(" ")[0]) | index($u) != null) else false end')
      echo "$p access=$acc maintainer=$maint"
      [ "$acc" = read-write ] || [ "$maint" = true ] || bad=1
    done
    [ $bad = 0 ]
    ;;
  dry-run-token)
    cd "$P" && NPM_CONFIG_USERCONFIG="$WORK/npmrc" ASSUMER_VERSION="$VERSION" bun run script/publish.ts --dry-run
    ;;
  publish)
    cd "$P" && NPM_CONFIG_USERCONFIG="$WORK/npmrc" ASSUMER_VERSION="$VERSION" bun run script/publish.ts
    ;;
  verify)
    # The registry's own dist-tags endpoint, not a cached npm view; replicas can lag for minutes after a publish.
    ok=0
    for i in $(seq 1 20); do
      ok=1
      for p in assumer-ai $(for t in $NAMES; do echo "assumer-$t"; done); do
        tag=$(curl -fsS "https://registry.npmjs.org/-/package/$p/dist-tags" | jq -r .latest)
        [ "$tag" = "$VERSION" ] || { ok=0; echo "try $i: $p latest=$tag"; }
      done
      dev=$(curl -fsS "https://registry.npmjs.org/-/package/@4born-solutions%2fassumer/dist-tags" | jq -r .dev)
      [ "$dev" = "$VERSION" ] || { ok=0; echo "try $i: @4born-solutions/assumer dev=$dev"; }
      [ $ok = 1 ] && break
      sleep 30
    done
    curl -fsS "https://registry.npmjs.org/-/package/assumer-ai/dist-tags"; echo
    curl -fsS "https://registry.npmjs.org/-/package/@4born-solutions%2fassumer/dist-tags"; echo
    curl -fsS "https://registry.npmjs.org/assumer-ai/$VERSION" | jq -c .optionalDependencies
    curl -fsS "https://registry.npmjs.org/assumer-ai/$VERSION" | jq -e --arg v "$VERSION" '.optionalDependencies | length == 12 and all(.[]; . == $v)' || ok=0
    [ $ok = 1 ]
    ;;
  *) exit 1 ;;
esac
