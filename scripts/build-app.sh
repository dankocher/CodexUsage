#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/dist/CodexUsage.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/CodexUsage" "$app_dir/Contents/MacOS/CodexUsage"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
swift "$project_dir/scripts/generate-icon.swift" "$project_dir/dist/AppIcon.iconset"
iconutil -c icns "$project_dir/dist/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
printf 'App creada: %s\n' "$app_dir"
if [[ "${1:-}" == "--open" ]]; then open "$app_dir"; fi
