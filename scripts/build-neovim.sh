#!/usr/bin/env bash
# Build Neovim (the ./neovim submodule) for LinuxOnTab 2.0 and package it.
#
#   scripts/build-neovim.sh version  print the submodule's Neovim version
#   scripts/build-neovim.sh host     native build: code generators + helptags
#   scripts/build-neovim.sh wasm     cross build, inside the tombl/distro devShell;
#                                    writes dist/neovim-v<version>-wasm32.tar.gz
#
# Neovim runs Lua code generators and its own binary while building, which a
# wasm32 binary can't do on the build machine, so the native build supplies
# them (NLUA0_HOST_PRG, LUA_GEN_PRG, NVIM_HOST_PRG). The wasm32 binary embeds
# PUC Lua 5.1, since LuaJIT has no WebAssembly backend.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NVIM_SRC=$ROOT/neovim
BUILD=${BUILD:-$ROOT/_build}
HOST=$BUILD/host
WASM=$BUILD/wasm
DIST=$ROOT/dist
REPO=${GITHUB_REPOSITORY:-ernsoylu/linuxontab-apps}

version() {
  local v=() k
  for k in MAJOR MINOR PATCH; do
    v+=("$(sed -n "s/^set(NVIM_VERSION_$k \([0-9]*\))/\1/p" "$NVIM_SRC/CMakeLists.txt")")
  done
  (IFS=.; echo "${v[*]}")
}

host() {
  if [ -x "$HOST/nvim/bin/nvim" ] && [ -f "$HOST/nvim/lib/libnlua0.so" ]; then
    echo "host build up to date: $HOST"
    return
  fi
  cmake -S "$NVIM_SRC/cmake.deps" -B "$HOST/deps" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DUSE_BUNDLED_TS_PARSERS=OFF
  cmake --build "$HOST/deps"
  cmake -S "$NVIM_SRC" -B "$HOST/nvim" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DDEPS_PREFIX="$HOST/deps/usr" -DENABLE_LIBINTL=OFF
  cmake --build "$HOST/nvim" --target nvim_bin nlua0
}

wasm() {
  : "${sysroot:?run inside the devShell: nix develop github:tombl/distro --command $0 wasm}"
  local ver host_lua src=$WASM/src deps=$WASM/deps out=$WASM/nvim stage=$WASM/stage
  ver=$(version)
  host_lua=$(sed -n 's/^LUA_PRG:FILEPATH=//p' "$HOST/nvim/CMakeCache.txt" 2>/dev/null || true)
  [ -x "$host_lua" ] || { echo "error: no host build, run '$0 host' first" >&2; exit 1; }

  rm -rf "$WASM"
  mkdir -p "$src" "$stage" "$WASM/libuv" "$WASM/shims"
  git -C "$NVIM_SRC" archive HEAD | tar -x -C "$src"
  patch -d "$src" -p1 <"$ROOT/patches/neovim.patch"

  # libuv spawns children with fork(), which the platform lacks; the patch
  # moves it to posix_spawn(). Hand the patched tarball to Neovim's deps build.
  local uv_url uv_sha
  uv_url=$(sed -n 's/^LIBUV_URL //p' "$src/cmake.deps/deps.txt")
  uv_sha=$(sed -n 's/^LIBUV_SHA256 //p' "$src/cmake.deps/deps.txt")
  curl -fsSL -o "$WASM/libuv-orig.tar.gz" "$uv_url"
  echo "$uv_sha  $WASM/libuv-orig.tar.gz" | sha256sum -c -
  tar -xzf "$WASM/libuv-orig.tar.gz" -C "$WASM/libuv" --strip-components=1
  patch -d "$WASM/libuv" -p1 <"$ROOT/patches/libuv.patch"
  tar -czf "$WASM/libuv.tar.gz" -C "$WASM" libuv
  uv_sha=$(sha256sum "$WASM/libuv.tar.gz" | cut -d' ' -f1)

  # Lua's plain Makefile calls bare ar/ranlib, which can't index wasm objects.
  ln -sf "$(command -v llvm-ar)" "$WASM/shims/ar"
  ln -sf "$(command -v llvm-ranlib)" "$WASM/shims/ranlib"
  export PATH="$WASM/shims:$PATH"
  export LOT_DEPS_PREFIX=$deps/usr PKG_CONFIG_LIBDIR=$deps/usr/lib/pkgconfig
  local tc=$ROOT/toolchain/wasm32-linux-musl.cmake

  cmake -S "$src/cmake.deps" -B "$deps" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$tc" \
    -DUSE_BUNDLED_LUAJIT=OFF -DUSE_BUNDLED_LUA=ON -DUSE_BUNDLED_TS_PARSERS=OFF \
    -DLIBUV_URL="$WASM/libuv.tar.gz" -DLIBUV_SHA256="$uv_sha"
  cmake --build "$deps"

  cmake -S "$src" -B "$out" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$tc" -DDEPS_PREFIX="$deps/usr" -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DPREFER_LUA=ON -DCOMPILE_LUA=OFF -DENABLE_LTO=OFF -DENABLE_LIBINTL=OFF \
    -DLUA_PRG="$host_lua" -DLUA_GEN_PRG="$host_lua" \
    -DNLUA0_HOST_PRG="$HOST/nvim/lib/libnlua0.so" -DNVIM_HOST_PRG="$HOST/nvim/bin/nvim"
  cmake --build "$out" --target nvim
  DESTDIR="$stage" cmake --install "$out"

  postprocess "$stage/usr/local/bin/nvim"
  package "$ver" "$stage/usr/local"
}

# The same treatment LinuxOnTab's packages/build-package.sh gives its packages.
postprocess() {
  local f=$1 imports
  llvm-strip --strip-debug "$f"

  # Some wasm32 musl sysroots ship a mallocng that ignores sbrk()'s return and
  # uses a hard-coded 0x8000 meta-area base, clobbering guest memory. Byte-patch
  # it to use sbrk()'s result; a no-op against a fixed libc.
  python3 -I - "$f" <<'PY'
import sys
path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
old = bytes.fromhex('417f460d03418080022102')
new = bytes.fromhex('2202417f460d0301010101')
n = data.count(old)
if n > 1:
    sys.exit(f"{path}: alloc_meta pattern found {n} times, refusing to patch")
if n == 1:
    i = data.find(old)
    data[i:i + len(old)] = new
    open(path, 'wb').write(data)
    print(f"{path}: patched mallocng alloc_meta at 0x{i:x}")
PY

  if [ "${LOT_ASYNCIFY:-1}" = 1 ]; then
    "${WASM_OPT:-wasm-opt}" --enable-exception-handling --asyncify -O1 "$f" -o "$f.tmp"
    mv "$f.tmp" "$f"
  fi

  # The kernel supplies process memory; a module defining its own won't load.
  imports=$(wasm-objdump -x -j Import "$f")
  [[ $imports == *'<- env.memory'* ]] || { echo "error: $f does not import env.memory" >&2; exit 1; }
}

# LinuxOnTab package layout: pkg-<name>/{bin,share,...,info}.
package() {
  local ver=$1 prefix=$2 name=neovim
  local tag=$name-v$ver pkg=$WASM/pkg-$name
  local asset=$tag-wasm32.tar.gz
  cp -a "$prefix" "$pkg"
  cat >"$pkg/info" <<EOF
name=$name
version=$ver
built_with=tombl/distro${DISTRO_REV:+@$DISTRO_REV}
target=wasm32-linux-musl
EOF
  mkdir -p "$DIST"
  tar -czf "$DIST/$asset" -C "$WASM" "pkg-$name"
  (cd "$DIST" && sha256sum "$asset" >"$asset.sha256")

  # An entry in LinuxOnTab's packages/index.json format.
  cat >"$DIST/$name.json" <<EOF
{
  "$name": {
    "version": "$ver",
    "description": "Vim-fork focused on extensibility and usability",
    "url": "https://github.com/$REPO/releases/download/$tag/$asset",
    "size": $(stat -c %s "$DIST/$asset"),
    "sha256": "$(cut -d' ' -f1 "$DIST/$asset.sha256")",
    "bins": ["nvim"],
    "depends": [],
    "status": "available"
  }
}
EOF
  ls -l "$DIST"
}

case ${1:-} in
  version | host | wasm) "$1" ;;
  *) sed -n '2,7s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
esac
