#!/bin/bash
# 非 bash 调用（如 sh uninstall.sh）时切换到 bash 再跑
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

#
# ThemeSwitch 卸载器（不需要 root）
#
#   ./uninstall.sh [--purge] [-h]
#
# 选项：
#   --purge      同时删除 App 的偏好设置（UserDefaults 域）
#   -h, --help   显示帮助
#
# 环境变量（与安装时保持一致）：
#   APPS_DIR           安装目录（默认 /Applications；不可写时是 ~/Applications）
#   LAUNCH_AGENTS_DIR  LaunchAgent 目录（默认 ~/Library/LaunchAgents）
#
# 删除内容：
#   <APPS_DIR>/ThemeSwitch.app                已安装的 App
#   <LAUNCH_AGENTS_DIR>/<bundle id>.plist     登录自启项（存在才删）
#   ~/Library/LaunchAgents/<bundle id>.plist  同上：App 内「登录时自动启动」开关写的也是这份
#   UserDefaults 域（仅 --purge）
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

APP_NAME="ThemeSwitch"
BUNDLE_ID_DEFAULT="com.themeswitch.app"
PURGE=0

usage() {
    cat <<EOF
用法: $0 [--purge] [-h]

  --purge      同时删除 App 的偏好设置（UserDefaults 域）
  -h, --help   显示本帮助

环境变量:
  APPS_DIR           安装目录（默认 /Applications，不可写时是 ~/Applications）
  LAUNCH_AGENTS_DIR  LaunchAgent 目录（默认 ~/Library/LaunchAgents）
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --purge)     PURGE=1 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# bundle id 优先从仓库里的 Info.plist 读，保证和安装时一致
if [ -r "Info.plist" ]; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist 2>/dev/null || echo "$BUNDLE_ID_DEFAULT")"
else
    BUNDLE_ID="$BUNDLE_ID_DEFAULT"
fi

# 1) 退出运行中的实例
pkill -x "$APP_NAME" 2>/dev/null || true

# 2) 卸载登录自启：安装时 --launch-at-login 与 App 内「登录时自动启动」开关用的是
#    同一个 label、同一份 <LaunchAgents>/<bundle id>.plist，这里一并注销并删除。
#    label 属于本 App，未注册时 bootout 只是无害的空操作。
REAL_LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$REAL_LAUNCH_AGENTS_DIR}"
launchctl bootout "gui/$UID/$BUNDLE_ID" >/dev/null 2>&1 || true
# 自定义 LAUNCH_AGENTS_DIR 时也检查真实目录，避免漏掉 App 内开关写下的那份
for DIR in "$LAUNCH_AGENTS_DIR" "$REAL_LAUNCH_AGENTS_DIR"; do
    AGENT_PLIST="$DIR/$BUNDLE_ID.plist"
    if [ -f "$AGENT_PLIST" ]; then
        rm -f "$AGENT_PLIST"
        echo "✅ 已移除 $AGENT_PLIST"
    fi
done

# 3) 删除 App：默认同时检查 /Applications 与 ~/Applications，重复执行安全
if [ -n "${APPS_DIR:-}" ]; then
    TARGET_DIRS=("$APPS_DIR")
else
    TARGET_DIRS=("/Applications" "$HOME/Applications")
fi
REMOVED_ANY=0
for DIR in "${TARGET_DIRS[@]}"; do
    CANDIDATE="$DIR/$APP_NAME.app"
    if [ -e "$CANDIDATE" ]; then
        rm -rf "$CANDIDATE"
        echo "✅ 已移除 $CANDIDATE"
        REMOVED_ANY=1
    fi
done
if [ "$REMOVED_ANY" -eq 0 ]; then
    echo "○ 未找到已安装的 $APP_NAME.app（${TARGET_DIRS[*]}）"
fi

# 4) 可选：清理偏好设置
if [ "$PURGE" -eq 1 ]; then
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    echo "✅ 已清理偏好设置（${BUNDLE_ID}）"
fi

echo "卸载完成。"
