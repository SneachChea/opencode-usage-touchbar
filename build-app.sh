#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:-$project_dir/dist}"
app_dir="$output_dir/OpenCode Usage TouchBar.app"
sign_identity="${CODE_SIGN_IDENTITY:--}"

IFS=' ' read -r -a build_archs <<< "${CODEX_USAGE_ARCHS:-arm64 x86_64}"

cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/module-cache"
export XDG_CACHE_HOME="$project_dir/.build/cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$XDG_CACHE_HOME"

binaries=()
for architecture in "${build_archs[@]}"; do
  scratch_path="$project_dir/.build/$architecture"
  swift build -c release --arch "$architecture" --scratch-path "$scratch_path"
  binary_dir="$(swift build -c release --arch "$architecture" --scratch-path "$scratch_path" --show-bin-path)"
  binaries+=("$binary_dir/opencode-usage-touchbar")
done

universal_dir="$project_dir/.build/universal"
mkdir -p "$universal_dir"
universal_binary="$universal_dir/opencode-usage-touchbar"
if [[ "${#binaries[@]}" -eq 1 ]]; then
  cp "${binaries[0]}" "$universal_binary"
else
  lipo -create "${binaries[@]}" -output "$universal_binary"
fi

asset_output="$project_dir/.build/compiled-assets"
iconset_output="$asset_output/AppIcon.iconset"
rm -rf "$asset_output"
mkdir -p "$iconset_output"
cp Resources/Assets.xcassets/AppIcon.appiconset/*.png "$iconset_output/"
cp Resources/Assets.xcassets/AppIcon.appiconset/Contents.json "$iconset_output/"
iconutil -c icns "$iconset_output" -o "$asset_output/AppIcon.icns"

if [[ -e "$app_dir" ]]; then
  rm -rf "$app_dir"
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$universal_binary" "$app_dir/Contents/MacOS/opencode-usage-touchbar"
cp "Info.plist" "$app_dir/Contents/Info.plist"
cp "$asset_output/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
chmod +x "$app_dir/Contents/MacOS/opencode-usage-touchbar"

codesign_args=(--force --deep --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
  codesign_args+=(--options runtime --timestamp)
fi
codesign "${codesign_args[@]}" "$app_dir"
echo "$app_dir"
