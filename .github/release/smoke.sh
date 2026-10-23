#!/usr/bin/env bash
# smoke.sh <target>...: downloads each target's archive from release v$VERSION and runs `assumer --version` and
# `assumer --help` on this runner (musl targets inside an Alpine container).
source "$(dirname "$0")/lib.sh"
export HOME="$WORK/home" XDG_DATA_HOME="$WORK/home/d" XDG_CONFIG_HOME="$WORK/home/c" XDG_STATE_HOME="$WORK/home/s"
mkdir -p "$HOME"
fail=0
for t in "$@"; do
  d="$WORK/smoke/$t"; rm -rf "$d"; mkdir -p "$d"
  case $t in linux-*) f="assumer-$t.tar.gz" ;; *) f="assumer-$t.zip" ;; esac
  asset "$f" "$WORK/smoke/$f" || { fail=1; continue; }
  echo "$f sha256 $(sha256 "$WORK/smoke/$f")"
  case $t in
    linux-*) tar -xzf "$WORK/smoke/$f" -C "$d" ;;
    windows-*) pwsh -NoProfile -Command "Expand-Archive -Path '$(cygpath -w "$WORK/smoke/$f")' -DestinationPath '$(cygpath -w "$d")'" ;;
    *) unzip -q "$WORK/smoke/$f" -d "$d" ;;
  esac
  bin="$d/assumer"; [[ $t == windows-* ]] && bin="$d/assumer.exe"
  if [[ $t == *musl ]]; then
    run() { docker run --rm -v "$d:/x" alpine:3.20 sh -c "apk add -q --no-cache libstdc++ libgcc > /dev/null && HOME=/tmp /x/assumer $*"; }
  else
    run() { "$bin" "$@"; }
  fi
  [[ $(uname -s) == Darwin ]] && { codesign -dv "$bin" 2>&1 | head -3; file "$bin"; }
  out=$(run --version 2>&1 | tr -d '\r'); code=$?
  echo "assumer-$t --version: exit $code: $out"
  if [ $code -ne 0 ] || [ "$(tail -1 <<<"$out")" != "$VERSION" ]; then fail=1; continue; fi
  out=$(run --help 2>&1 | tr -d '\r'); code=$?
  echo "assumer-$t --help: exit $code"; head -8 <<<"$out"
  [ $code -eq 0 ] || fail=1
done
exit $fail
