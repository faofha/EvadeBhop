#!/usr/bin/env bash
# Runs EvadeClone.lua inside the headless Roblox mock and prints the mechanics checks.
# Requires the `luau` CLI on PATH (https://github.com/luau-lang/luau/releases).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d)"
cat "$here/mock.lua" "$root/EvadeClone.lua" "$here/driver2.lua" > "$tmp/run.lua"
luau -O0 "$tmp/run.lua" | sed -n '/^A)/,$p'
rm -rf "$tmp"
