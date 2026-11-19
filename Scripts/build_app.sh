#!/bin/bash
# 构建原生应用，产物放入隐藏目录，避免聚焦搜索收录开发副本。
set -euo pipefail
if [[ $# -gt 0 ]]; then
    if [[ $# -eq 1 && "$1" == "--help" ]]; then
        echo '用法：Scripts/build_app.sh；产物：.build/app/MacClean.app'
        exit 0
    fi
    echo '错误：不支持的参数。' >&2
    exit 1
fi
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
swift build -c release --product MacCleanApp
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/.build/app/MacClean.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
/usr/bin/install -m 0755 "$binary_dir/MacCleanApp" "$app_dir/Contents/MacOS/MacClean"
/usr/bin/install -m 0644 Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/bin/install -m 0644 Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
if [[ -f Resources/Assets.car ]]; then
    /usr/bin/install -m 0644 Resources/Assets.car "$app_dir/Contents/Resources/Assets.car"
fi
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign "${MAC_CLEAN_SIGN_IDENTITY:--}" --timestamp=none "$app_dir"
/usr/bin/codesign --verify --strict "$app_dir"
echo "应用已生成：$app_dir"
