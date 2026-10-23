#!/usr/bin/env bash
# desktop.sh <clone|install|build|package|check|upload>: the Windows desktop release (release-checklist.md section 6).
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib.sh"
D="$A/packages/desktop"
export ASSUMER_CHANNEL=prod ASSUMER_VERSION="$VERSION" GH_REPO="$PRIVATE" ASSUMER_RELEASE_REPO="$PRIVATE"
FILES=(dist/assumer-desktop-win-x64.exe dist/assumer-desktop-win-x64.exe.blockmap dist/latest.yml)
case "$1" in
  clone)
    clone Assumer "$REF" "$A" || exit 1
    git -C "$A" log -1 --format='%H %s'
    ;;
  install)
    command -v node-gyp > /dev/null 2>&1 || npm i -g node-gyp
    cd "$A" && GITHUB_TOKEN="$GH_TOKEN" bun install --frozen-lockfile
    ;;
  build)
    # The build and packaging never see the token: they only read the source and write dist/.
    cd "$D" && env -u GH_TOKEN -u GITHUB_TOKEN bun run build || exit 1
    grep -rl "$PRIVATE" out/main > /dev/null || { echo "out/main does not name $PRIVATE"; exit 1; }
    ;;
  package)
    cd "$D" && env -u GH_TOKEN -u GITHUB_TOKEN bun run package:win
    ;;
  check)
    cd "$D" || exit 1
    env -u GH_TOKEN -u GITHUB_TOKEN bun ./scripts/check-fuses.ts dist/win-unpacked/Assumer.exe || exit 1
    echo "== app-update.yml"; cat dist/win-unpacked/resources/app-update.yml
    grep -qx 'owner: 4BornGithub' dist/win-unpacked/resources/app-update.yml || exit 1
    grep -qx 'repo: assumer-releases' dist/win-unpacked/resources/app-update.yml || exit 1
    echo "== latest.yml"; cat dist/latest.yml
    grep -qx "version: $VERSION" dist/latest.yml || exit 1
    grep -Eq '^ *- url: assumer-desktop-win-x64\.exe$' dist/latest.yml || exit 1
    grep -qx 'path: assumer-desktop-win-x64.exe' dist/latest.yml || exit 1
    want=$(awk '/^sha512: /{print $2}' dist/latest.yml)
    have=$(openssl dgst -sha512 -binary dist/assumer-desktop-win-x64.exe | openssl base64 -A)
    echo "sha512 latest.yml $want, exe $have"; [ "$want" = "$have" ] || exit 1
    size=$(awk '/^ *size: /{print $2; exit}' dist/latest.yml); echo "size latest.yml $size, exe $(wc -c < dist/assumer-desktop-win-x64.exe)"
    [ "$size" = "$(wc -c < dist/assumer-desktop-win-x64.exe | tr -d ' ')" ] || exit 1
    for f in "${FILES[@]}"; do [ -f "$f" ] || exit 1; echo "$(sha256 "$f")  $(wc -c < "$f" | tr -d ' ')  $(basename "$f")"; done
    pwsh -NoProfile -Command "(Get-Item 'dist/win-unpacked/Assumer.exe').VersionInfo | Format-List ProductVersion,FileVersion,ProductName; Get-AuthenticodeSignature 'dist/assumer-desktop-win-x64.exe' | Format-List Status,StatusMessage"
    ;;
  upload)
    cd "$D" && gh release upload "v$VERSION" "${FILES[@]}" --repo "$PRIVATE" --clobber && check_uploaded "${FILES[@]}"
    ;;
  start)
    cd "$D" && pwsh -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$HERE/desktop-start.ps1")" \
      -Installer "$(cygpath -w "$D/dist/assumer-desktop-win-x64.exe")" -Logs "$(cygpath -w "$LOGS")" -Version "$VERSION"
    ;;
  *) exit 1 ;;
esac
