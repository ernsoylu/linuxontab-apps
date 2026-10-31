# linuxontab-apps

Apps cross-compiled for [LinuxOnTab 2.0](https://linuxontab.com/2.0/), where the
Linux kernel and every program run as native WebAssembly (`wasm32-linux-musl`).
LinuxOnTab's own repository has about 80 packages; this repo builds others from
upstream source and publishes them as GitHub releases.

| App | Version | Binary |
| --- | --- | --- |
| [Neovim](https://neovim.io) | see [releases](https://github.com/ernsoylu/linuxontab-apps/releases) | `nvim` |

## Install

Inside a LinuxOnTab 2.0 shell:

```sh
curl -fsSL https://raw.githubusercontent.com/ernsoylu/linuxontab-apps/main/install.sh | sh
```

This downloads the latest Neovim release, checks its SHA-256, and copies it into
`/usr/local` (`/usr/local/bin/nvim` plus its runtime in `/usr/local/share/nvim`).

```sh
# a specific app and version
curl -fsSL https://raw.githubusercontent.com/ernsoylu/linuxontab-apps/main/install.sh | sh -s -- neovim v0.12.6

# somewhere else
curl -fsSL https://raw.githubusercontent.com/ernsoylu/linuxontab-apps/main/install.sh | PREFIX=$HOME/.local sh
```

To uninstall: `rm -rf /usr/local/bin/nvim /usr/local/share/nvim /usr/local/lib/nvim`.

## Neovim on wasm32: what differs

| Feature | Status |
| --- | --- |
| Editing, TUI, Lua plugins, `:!cmd`, `jobstart()` | Expected to work. The platform has no `fork()`, so libuv is patched to start processes with `posix_spawn()`. |
| `:terminal`, pty jobs | Not available: they need `forkpty()`. Calls fail with ENOSYS. |
| Tree-sitter highlighting | Not available: parsers are shared libraries and there is no `dlopen()`. Built-in ftplugins fall back to regex `syntax`. |
| Lua engine | PUC Lua 5.1, since LuaJIT has no WebAssembly backend. Plugins that need LuaJIT's `ffi` won't load. |

## Release format

Each release `neovim-v<version>` has three assets:

- `neovim-v<version>-wasm32.tar.gz`: a LinuxOnTab package, `pkg-neovim/{bin,share,lib,info}`,
  the same layout as `linuxontab.com/packages/*.tar.gz`.
- `neovim-v<version>-wasm32.tar.gz.sha256`: its checksum, which `install.sh` verifies.
- `neovim.json`: an entry in LinuxOnTab's
  [`packages/index.json`](https://github.com/kilian-ai/linuxontab/blob/main/packages/index.json) format.

## How it is built

[`.github/workflows/neovim.yml`](.github/workflows/neovim.yml) runs
[`scripts/build-neovim.sh`](scripts/build-neovim.sh):

1. `host`: a native Neovim build. Neovim runs Lua code generators and its own
   binary (for helptags) during the build, which a wasm32 binary can't do on the
   build machine. This build provides `NLUA0_HOST_PRG`, `LUA_GEN_PRG` and `NVIM_HOST_PRG`.
2. `wasm`: runs inside the [tombl/distro](https://github.com/tombl/distro) devShell,
   which provides the wasm32-capable clang and musl sysroot that LinuxOnTab 2.0's
   userland comes from. Neovim and its bundled dependencies are built with
   [`toolchain/wasm32-linux-musl.cmake`](toolchain/wasm32-linux-musl.cmake). Then
   [`patches/`](patches) is applied: [`libuv.patch`](patches/libuv.patch) switches
   spawning from `fork()` to `posix_spawn()`, and
   [`neovim.patch`](patches/neovim.patch) disables `forkpty()` and guards
   `vim.treesitter.start()`.
3. Post-processing follows LinuxOnTab's `packages/build-package.sh`: strip debug
   info, apply the mallocng safety patch, run the binaryen asyncify pass
   (`LOT_ASYNCIFY=0` skips it), and check that the module imports its memory
   from the kernel.

A push to `main` that changes any of these files builds and releases
`neovim-v<version>`, unless that release already exists. A manual run
(**Actions → neovim → Run workflow**) rebuilds and replaces the assets.

### Updating Neovim

```sh
git -C neovim fetch --depth 1 origin tag v0.12.7
git -C neovim checkout v0.12.7
git commit -am "neovim: v0.12.7" && git push
```

If the patches no longer apply, refresh them against the new source.

### Building locally

You need Nix with flakes, CMake, Ninja, and a C compiler.

```sh
git clone --recurse-submodules https://github.com/ernsoylu/linuxontab-apps
cd linuxontab-apps
scripts/build-neovim.sh host
distro=github:tombl/distro/189b9c3ed921015572e88e02c16275fb182b72cb
nix shell --inputs-from $distro nixpkgs#binaryen nixpkgs#wabt --command \
  nix develop $distro --accept-flake-config --command scripts/build-neovim.sh wasm
ls dist/
```
