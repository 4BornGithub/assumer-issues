#!/usr/bin/env bash
# cli.sh <clone|install|build|verify>: the CLI release build (docs/release/release-checklist.md sections 2 and 3).
source "$(dirname "$0")/lib.sh"
TARGETS="linux-arm64 linux-x64 linux-x64-baseline linux-arm64-musl linux-x64-musl linux-x64-baseline-musl darwin-arm64 darwin-x64 darwin-x64-baseline windows-arm64 windows-x64 windows-x64-baseline"
case "$1" in
  clone)
    clone Assumer "$REF" "$A" || exit 1
    git -C "$A" log -1 --format='%H %s'
    [ -z "$(git -C "$A" status --porcelain)" ] || exit 1
    ;;
  install)
    command -v node-gyp > /dev/null 2>&1 || npm i -g node-gyp
    cd "$A" && GITHUB_TOKEN="$GH_TOKEN" bun install --frozen-lockfile
    ;;
  build)
    want=$(jq -r .packageManager "$A/package.json" | cut -d@ -f2)
    echo "bun $(bun --version), packageManager bun@$want"
    [ "$(bun --version)" = "$want" ] || exit 1
    command -v zip > /dev/null || exit 1
    cd "$A/packages/assumer" &&
      ASSUMER_VERSION="$VERSION" ASSUMER_RELEASE=1 GH_REPO="$PRIVATE" ASSUMER_RELEASE_REPO="$PRIVATE" bun run script/build.ts
    ;;
  verify)
    cd "$A/packages/assumer" || exit 1
    jq . dist/build.json
    jq -e --arg v "$VERSION" '.version == $v and .complete == true and (.packages | length) == 12' dist/build.json || exit 1
    for t in $TARGETS; do jq -e --arg p "assumer-$t" '.packages | index($p)' dist/build.json > /dev/null || { echo "build.json lacks $t"; exit 1; }; done
    for t in linux-x64 linux-x64-baseline; do
      out=$(dist/assumer-$t/bin/assumer --version); echo "assumer-$t --version: $out"; [ "$out" = "$VERSION" ] || exit 1
    done
    out=$(HOME="$WORK/home" XDG_DATA_HOME="$WORK/home/d" XDG_CONFIG_HOME="$WORK/home/c" XDG_STATE_HOME="$WORK/home/s" \
      timeout 60 dist/assumer-linux-x64/bin/assumer --help 2>&1); echo "$out" | head -20
    [ -z "$(find dist -name '*.map')" ] || { echo "source maps in dist"; exit 1; }
    : > "$LOGS/SHA256SUMS"
    files=()
    for t in $TARGETS; do
      case $t in linux-*) f=dist/assumer-$t.tar.gz; list=$(tar -tzf "$f") ;; *) f=dist/assumer-$t.zip; list=$(unzip -Z1 "$f") ;; esac
      [ -f "$f" ] || { echo "missing $f"; exit 1; }
      echo "== $f $(wc -c < "$f" | tr -d ' ') bytes: $(echo $list)"
      case $t in
        windows-*) for x in assumer.exe conpty.dll OpenConsole.exe; do grep -qx "$x" <<<"$list" || { echo "$f lacks $x"; exit 1; }; done ;;
        *) grep -Eqx '(\./)?assumer' <<<"$list" || { echo "$f lacks assumer"; exit 1; } ;;
      esac
      ! grep -Eq '\.(map|ts|tsx)$' <<<"$list" || { echo "$f carries source"; exit 1; }
      bin=dist/assumer-$t/bin/assumer; [ -f "$bin" ] || bin=$bin.exe
      grep -q "$PRIVATE" "$bin" || { echo "$bin does not name $PRIVATE"; exit 1; }
      echo "$(sha256 "$f")  $(basename "$f")" >> "$LOGS/SHA256SUMS"
      files+=("$f")
    done
    cat "$LOGS/SHA256SUMS"
    cmp -s dist/assumer-darwin-x64/bin/assumer dist/assumer-darwin-x64-baseline/bin/assumer && echo "darwin x64 pair identical (expected)"
    ! cmp -s dist/assumer-linux-x64/bin/assumer dist/assumer-linux-x64-baseline/bin/assumer || { echo "linux baseline equals x64"; exit 1; }
    check_uploaded "${files[@]}"
    ;;
  *) exit 1 ;;
esac
