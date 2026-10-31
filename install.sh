#!/bin/sh
# Install an app from github.com/ernsoylu/linuxontab-apps into LinuxOnTab 2.0.
#
#   curl -fsSL https://raw.githubusercontent.com/ernsoylu/linuxontab-apps/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- neovim v0.12.6   # app, version
#
# Environment: PREFIX (default /usr/local), LOT_APPS_REPO (default ernsoylu/linuxontab-apps).
# POSIX sh: runs under the guest's BusyBox.
set -eu

REPO=${LOT_APPS_REPO:-ernsoylu/linuxontab-apps}
APP=${1:-neovim}
VERSION=${2:-latest}
PREFIX=${PREFIX:-/usr/local}

die() { echo "install.sh: $*" >&2; exit 1; }

if [ "$VERSION" = latest ]; then
  # Releases are tagged <app>-v<version>, newest first.
  TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100" |
    grep -o "\"tag_name\": *\"$APP-v[^\"]*\"" | head -n 1 | cut -d '"' -f 4)
  [ -n "$TAG" ] || die "no release of '$APP' found in $REPO (or GitHub API unreachable)"
else
  TAG=$APP-v${VERSION#v}
fi

ASSET=$TAG-wasm32.tar.gz
URL=https://github.com/$REPO/releases/download/$TAG/$ASSET
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "Downloading $URL"
cd "$TMP"
curl -fL --progress-bar -o "$ASSET" "$URL" || die "download failed: $URL"
curl -fsSL -o "$ASSET.sha256" "$URL.sha256" || die "download failed: $URL.sha256"
sha256sum -c "$ASSET.sha256" >/dev/null || die "checksum mismatch for $ASSET"

tar -xzf "$ASSET"
[ -d "pkg-$APP" ] || die "$ASSET has no pkg-$APP/ directory"
rm -f "pkg-$APP/info"
mkdir -p "$PREFIX"
cp -R "pkg-$APP/." "$PREFIX/"

echo "Installed $TAG into $PREFIX"
case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo "Add it to PATH: export PATH=\"$PREFIX/bin:\$PATH\"" ;;
esac
