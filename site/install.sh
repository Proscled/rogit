#!/bin/sh
# Installs rogit on macOS: downloads the latest release into ~/.rogit/bin, puts that folder on your PATH and installs
# the RoGit Studio plugin. Run it again to update.
#
#   curl -fsSL https://__SITE__/install.sh | sh
#
# ROGIT_VERSION=v0.2.0 installs that release instead of the latest.

set -eu

repo="${ROGIT_REPO:-__REPO__}"
version="${ROGIT_VERSION:-latest}"
home="$HOME/.rogit"
bin="$home/bin"

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
command -v curl >/dev/null || fail "curl is needed to download rogit."
command -v unzip >/dev/null || fail "unzip is needed to unpack rogit."

asset="rogit-macos-$arch.zip"
if [ "$version" = latest ]; then
    url="https://github.com/$repo/releases/latest/download/$asset"
else
    url="https://github.com/$repo/releases/download/$version/$asset"
fi

mkdir -p "$bin"
# Unpacked next to the old copy, so the move below is a rename: a running `rogit serve` keeps its copy.
tmp="$(mktemp -d "$home/download.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

printf 'Downloading %s...\n' "$asset"
curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/rogit.zip" "$url" ||
    fail "couldn't download $url. Check your connection, or that the release exists."
unzip -q -o "$tmp/rogit.zip" -d "$tmp" || fail "couldn't unpack $asset."
[ -f "$tmp/rogit" ] || fail "$asset doesn't contain rogit."
chmod +x "$tmp/rogit"
mv -f "$tmp/rogit" "$bin/rogit"

# PATH: one small file that shells load, so a reinstall never adds the line twice.
cat >"$home/env" <<'EOF'
# Added by the rogit installer: puts rogit on your PATH.
case ":$PATH:" in
    *":$HOME/.rogit/bin:"*) ;;
    *) export PATH="$HOME/.rogit/bin:$PATH" ;;
esac
EOF
line='. "$HOME/.rogit/env"'
changed=""
add_line() {
    if [ -f "$1" ] && grep -qF "$line" "$1"; then return; fi
    printf '\n%s\n' "$line" >>"$1"
    changed="$changed ~${1#"$HOME"}"
}
# zsh, the default on macOS, reads .zshenv in every shell, VS Code's terminal included.
add_line "${ZDOTDIR:-$HOME}/.zshenv"
# bash login shells read only the first of these that exists.
if [ -f "$HOME/.bash_profile" ]; then
    add_line "$HOME/.bash_profile"
elif [ -f "$HOME/.bash_login" ]; then
    add_line "$HOME/.bash_login"
elif [ -f "$HOME/.profile" ]; then
    add_line "$HOME/.profile"
elif [ "${SHELL##*/}" = bash ]; then
    add_line "$HOME/.bash_profile"
fi
[ -f "$HOME/.bashrc" ] && add_line "$HOME/.bashrc"
if [ -d "$HOME/.config/fish" ] || [ "${SHELL##*/}" = fish ]; then
    mkdir -p "$HOME/.config/fish/conf.d"
    cat >"$HOME/.config/fish/conf.d/rogit.fish" <<'EOF'
# Added by the rogit installer: puts rogit on your PATH.
contains -- $HOME/.rogit/bin $PATH; or set -gx PATH $HOME/.rogit/bin $PATH
EOF
fi

"$bin/rogit" plugin install

printf '\n%s is installed in ~/.rogit/bin.\n' "$("$bin/rogit" --version)"
[ -n "$changed" ] && printf 'Added it to your PATH in%s.\n' "$changed"
found="$(command -v rogit 2>/dev/null || true)"
if [ -n "$found" ] && [ "$found" != "$bin/rogit" ]; then
    printf '\nNote: there is also a rogit at %s. If `rogit --version` in a new terminal shows another version, remove that one.\n' "$found"
fi
printf '\nNext: open a new terminal (VS Code: Terminal > New Terminal) in your game'"'"'s project folder and run\n\n    rogit serve\n\n'
