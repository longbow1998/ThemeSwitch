#!/bin/bash
# 非 bash 调用（如 sh build.sh）时切换到 bash 再跑
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

#
# ThemeSwitch 安装器（不需要 root）
#
#   ./install.sh [--launch-at-login] [--no-build] [-h]
#
# 选项：
#   --launch-at-login   安装 LaunchAgent，登录后自动启动 App
#   --no-build          跳过构建，直接安装已存在的 build/ThemeSwitch.app
#   -h, --help          显示帮助
#
# 环境变量：
#   APPS_DIR            安装目录（默认 /Applications；不可写时退回 ~/Applications）
#   LAUNCH_AGENTS_DIR   LaunchAgent 目录（默认 ~/Library/LaunchAgents）
#
# 安装内容：
#   <APPS_DIR>/ThemeSwitch.app           App bundle（含 Info.plist、可执行文件）
#   <LAUNCH_AGENTS_DIR>/<bundle id>.plist（仅 --launch-at-login）
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

APP_NAME="ThemeSwitch"
APP_DIR="build/$APP_NAME.app"
BUNDLE_ID_DEFAULT="com.themeswitch.app"

DO_BUILD=1
LAUNCH_AT_LOGIN=0

usage() {
    cat <<EOF
用法: $0 [--launch-at-login] [--no-build] [-h]

  --launch-at-login   安装 LaunchAgent，登录后自动启动 App
  --no-build          跳过构建，直接安装已有 build/ThemeSwitch.app
  -h, --help          显示本帮助

环境变量:
  APPS_DIR            安装目录（默认 /Applications，不可写时用 ~/Applications）
  LAUNCH_AGENTS_DIR   LaunchAgent 目录（默认 ~/Library/LaunchAgents）
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --launch-at-login) LAUNCH_AT_LOGIN=1 ;;
        --no-build)        DO_BUILD=0 ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# 1) 构建（除非 --no-build）
if [ "$DO_BUILD" -eq 1 ]; then
    ./build.sh
fi
if [ ! -d "$APP_DIR" ]; then
    echo "错误：找不到 ${APP_DIR}，请先运行 ./build.sh 或去掉 --no-build" >&2
    exit 1
fi

# 2) 从包内 Info.plist 读 bundle id / 版本号，保证与产物一致
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_DIR/Contents/Info.plist")"
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo "?")"

# 3) 选择安装目录
if [ -n "${APPS_DIR:-}" ]; then
    DEST_DIR="$APPS_DIR"
elif [ -w /Applications ]; then
    DEST_DIR="/Applications"
else
    DEST_DIR="$HOME/Applications"
fi
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/$APP_NAME.app"

# 4) 覆盖安装前先退出运行中的旧实例，避免占用正在被替换的文件
pkill -x "$APP_NAME" 2>/dev/null || true

rm -rf "$DEST"
cp -R "$APP_DIR" "$DEST"
echo "✅ 已安装 $DEST (v$APP_VERSION)"

# 5) 登录自启（可选）：写 LaunchAgent plist 到用户目录
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
if [ "$LAUNCH_AT_LOGIN" -eq 1 ]; then
    mkdir -p "$LAUNCH_AGENTS_DIR"
    AGENT_PLIST="$LAUNCH_AGENTS_DIR/$BUNDLE_ID.plist"
    cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
    # 只有落在真实 LaunchAgents 目录时才动 launchd；自定义目录（测试/迁移场景）只写文件
    if [ "$LAUNCH_AGENTS_DIR" = "$HOME/Library/LaunchAgents" ]; then
        launchctl bootout "gui/$UID/$BUNDLE_ID" >/dev/null 2>&1 || true
        if launchctl bootstrap "gui/$UID" "$AGENT_PLIST" 2>/dev/null; then
            echo "✅ 已注册登录自启并后台启动"
        else
            echo "⚠️  launchctl bootstrap 失败，重启后会自动启动"
        fi
    else
        echo "✅ 已写入 $AGENT_PLIST (自定义 LAUNCH_AGENTS_DIR，跳过 launchctl)"
    fi
fi

echo
echo "启动 App:  open \"$DEST\""
echo "卸载:      ./uninstall.sh"
