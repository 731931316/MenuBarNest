#!/bin/bash
# 构建系统框架原生应用；输出目录可由调用方指定，不写入个人绝对路径。
set -euo pipefail

# 通过脚本位置定位项目，使源码拷贝后仍可独立构建。
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$project_dir/dist}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
cd "$project_dir"

# 分别交叉编译两种处理器，再合并成 macOS 通用可执行文件。
swift build -c release --arch x86_64 --scratch-path .build-release-intel
swift build -c release --arch arm64 --scratch-path .build-release-apple
intel_binary="$project_dir/.build-release-intel/x86_64-apple-macosx/release/MenuBarNest"
apple_binary="$project_dir/.build-release-apple/arm64-apple-macosx/release/MenuBarNest"

# 先在临时 bundle 中组装，构建失败不会破坏已有成品。
staging_dir="$(mktemp -d "$output_dir/.menubarnest-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/MenuBarNest.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
lipo -create "$intel_binary" "$apple_binary" -output "$app_dir/Contents/MacOS/MenuBarNest"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
chmod 755 "$app_dir/Contents/MacOS/MenuBarNest"

# 生成多分辨率原生应用图标并放入 bundle。
icon_set="$staging_dir/AppIcon.iconset"
mkdir -p "$icon_set"
swift scripts/generate-icon.swift "$staging_dir/icon.png"
for icon_size in 16 32 128 256 512; do
    sips -z "$icon_size" "$icon_size" "$staging_dir/icon.png" --out "$icon_set/icon_${icon_size}x${icon_size}.png" >/dev/null
    retina_size=$((icon_size * 2))
    sips -z "$retina_size" "$retina_size" "$staging_dir/icon.png" --out "$icon_set/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_set" -o "$app_dir/Contents/Resources/AppIcon.icns"

# 本地签名保证 bundle 完整；不宣称具有开发者公证签名。
codesign --force --sign - --identifier local.MenuBarNest "$app_dir"
codesign --verify --deep --strict "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist"
if [ -e "$output_dir/MenuBarNest.app" ]; then
    # 保存上一次构建，便于失败回滚和避免无提示删除成品。
    previous_bundle="$output_dir/MenuBarNest-previous-$(date +%Y%m%d%H%M%S).app"
    mv "$output_dir/MenuBarNest.app" "$previous_bundle"
fi
mv "$app_dir" "$output_dir/MenuBarNest.app"
printf 'Built %s\n' "$output_dir/MenuBarNest.app"
