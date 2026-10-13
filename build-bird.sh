#!/usr/bin/env bash
# Builds one or more BIRD versions with BMP, the same way nxthdr does
# (playbooks/install-bird.yml: --with-protocols='bmp,bgp,rpki,static').
# Each version is installed in ./build/inst-<version>/ (nothing is installed system-wide).
#
# Sources:
#   <x.y.z>    official tarball from bird.network.cz, falling back to the
#              official GitHub mirror CZ-NIC/bird (tag v<x.y.z>) if refused
#   gouel-fix  branch fix-bmp-adj-rib-in of github.com/matthieugouel/bird
#              (BMP fix on top of BIRD 3.2.0, January 2026, not merged upstream)
#
# Usage: ./build-bird.sh 2.16.1 3.3.3
#        ./build-bird.sh 3.2.0 3.3.2 gouel-fix
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
mkdir -p "$BUILD"

git_src() {  # $1 = repo URL, $2 = branch or tag, $3 = destination
  rm -rf "$3"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$2" "$1" "$3"
  ( cd "$3" && autoreconf -fi >/dev/null 2>&1 )
}

fetch() {  # $1 = version, $2 = source directory
  local v="$1" src="$2"
  if [ "$v" = gouel-fix ]; then
    echo "  source: github.com/matthieugouel/bird (branch fix-bmp-adj-rib-in)"
    git_src https://github.com/matthieugouel/bird.git fix-bmp-adj-rib-in "$src"
    return
  fi
  local url="${BIRD_BASE_URL:-https://bird.network.cz/download}/bird-$v.tar.gz"
  if curl -fsSL "$url" -o "$BUILD/bird-$v.tar.gz" 2>/dev/null; then
    echo "  source: $url"
    tar xzf "$BUILD/bird-$v.tar.gz" -C "$src" --strip-components=1
    rm -f "$BUILD/bird-$v.tar.gz"
  else
    echo "  bird.network.cz refused the download, using github.com/CZ-NIC/bird (tag v$v)"
    git_src https://github.com/CZ-NIC/bird.git "v$v" "$src"
  fi
}

for v in "$@"; do
  echo "=== BIRD $v ==="
  src="$BUILD/src-$v"
  rm -rf "$src"; mkdir -p "$src"
  fetch "$v" "$src"
  echo "  building..."
  ( cd "$src" \
    && ./configure --prefix="$BUILD/inst-$v" --with-protocols='bmp,bgp,rpki,static' >/dev/null \
    && make -j"$(nproc)" >/dev/null 2>&1 \
    && make install >/dev/null 2>&1 )
  "$BUILD/inst-$v/sbin/bird" --version
done
