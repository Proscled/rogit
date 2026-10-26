#!/bin/sh
# Installs RoGit on macOS: downloads the newest release and runs `rogit self-install`, which puts RoGit in
# ~/.rogit/bin, adds that folder to your PATH, installs the RoGit Studio plugin, and starts RoGit in the background
# (and from then on whenever you log in).
#
#   curl -fsSL https://__SITE__/install.sh | sh
#
# ROGIT_VERSION=v0.3.3 installs that release instead of the newest. ROGIT_NO_AUTOSTART=1 leaves starting RoGit to you
# (rogit serve).

set -eu

repo="${ROGIT_REPO:-__REPO__}"
version="${ROGIT_VERSION:-latest}"

fail() {
    printf 'rogit: %s\n' "$*" >&2
    exit 1
}

[ "$(uname -s)" = Darwin ] || fail "this installer is for macOS. On Windows, use install.ps1 from the same site."
case "$(uname -m)" in
    arm64 | aarch64) arch=aarch64 ;;
    x86_64)
        # A terminal running under Rosetta reports x86_64 on Apple silicon; the native build is faster.
        if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then arch=aarch64; else arch=x86_64; fi
        ;;
    *) fail "unsupported processor: $(uname -m)" ;;
esac
command -v curl >/dev/null || fail "curl is needed to download RoGit."
command -v unzip >/dev/null || fail "unzip is needed to unpack RoGit."

asset="rogit-macos-$arch.zip"
if [ "$version" = latest ]; then
    url="https://github.com/$repo/releases/latest/download/$asset"
else
    url="https://github.com/$repo/releases/download/$version/$asset"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf 'Downloading %s...\n' "$asset"
curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/rogit.zip" "$url" ||
    fail "couldn't download $url. Check your connection, or that the release exists."
unzip -q -o "$tmp/rogit.zip" -d "$tmp" || fail "couldn't unpack $asset."
[ -f "$tmp/rogit" ] || fail "$asset doesn't contain rogit."
chmod +x "$tmp/rogit"
"$tmp/rogit" self-install
