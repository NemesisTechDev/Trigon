#!/usr/bin/env bash
# Same as fetch_torrserver.ps1 for Linux/macOS shells. Run from the project root.
#   tools/fetch_torrserver.sh [tag]
set -euo pipefail
[ -f pubspec.yaml ] || { echo "Run this from the project root (pubspec.yaml)."; exit 1; }
if [ "${1:-}" ]; then base="https://github.com/YouROK/TorrServer/releases/download/$1"
else base="https://github.com/YouROK/TorrServer/releases/latest/download"; fi

get() { # asset dest
  mkdir -p "$(dirname "$2")"
  echo "Downloading $1 ..."
  curl -fL --retry 3 -o "$2" "$base/$1"
  size=$(wc -c < "$2")
  if [ "$size" -lt 1048576 ]; then rm -f "$2"; echo "$1 is too small ($size bytes); asset name may have changed."; exit 1; fi
}
get TorrServer-android-arm64     android/app/src/main/jniLibs/arm64-v8a/libtorrserver.so
get TorrServer-android-arm7      android/app/src/main/jniLibs/armeabi-v7a/libtorrserver.so
get TorrServer-android-amd64     android/app/src/main/jniLibs/x86_64/libtorrserver.so
get TorrServer-windows-amd64.exe windows/torrserver/torrserver.exe
echo "Done. Now apply the steps in PHASE8.md."
