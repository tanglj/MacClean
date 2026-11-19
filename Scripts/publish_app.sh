#!/bin/bash
# 安装到当前用户的 Applications，已打开时自动退出并重启。
set -euo pipefail
if [[ $# -gt 0 ]]; then
    if [[ $# -eq 1 && "$1" == "--help" ]]; then
        echo '用法：Scripts/publish_app.sh；安装到 ~/Applications/MacClean.app'
        exit 0
    fi
    echo '错误：不支持的参数。' >&2
    exit 1
fi
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$project_dir/Scripts/build_app.sh"
destination="$HOME/Applications/MacClean.app"
mkdir -p "$HOME/Applications"
staging="$(mktemp -d "$HOME/Applications/.mac-clean-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$project_dir/.build/app/MacClean.app" "$staging/MacClean.app"
/usr/bin/codesign --verify --strict "$staging/MacClean.app"
restart=false
if /usr/bin/pgrep -x MacClean >/dev/null; then
    restart=true
    /usr/bin/osascript -e 'tell application id "com.macclean.app" to quit'
    for ((attempt = 0; attempt < 30; attempt++)); do
        if ! /usr/bin/pgrep -x MacClean >/dev/null; then break; fi
        /bin/sleep 1
    done
    if /usr/bin/pgrep -x MacClean >/dev/null; then
        echo '应用尚未退出，取消安装以保留正在运行的版本。' >&2
        exit 1
    fi
fi
if [[ -e "$destination" ]]; then mv "$destination" "$staging/previous.app"; fi
if ! mv "$staging/MacClean.app" "$destination"; then
    if [[ -e "$staging/previous.app" ]]; then mv "$staging/previous.app" "$destination"; fi
    exit 1
fi
/usr/bin/codesign --verify --strict "$destination"
lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
"$lsregister" -u "$project_dir/.build/app/MacClean.app" || true
"$lsregister" -f "$destination"
if [[ "$restart" == true ]]; then /usr/bin/open "$destination"; fi
echo "已安装：$destination"
