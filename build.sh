#!/bin/bash
# 非 bash 调用（如 sh build.sh）时切换到 bash 再跑
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

#
# ThemeSwitch 构建脚本：把 Sources/*.swift 编译成菜单栏 App
#
#   ./build.sh
#
# 产物：build/ThemeSwitch.app
#   Contents/MacOS/ThemeSwitch   可执行文件（swiftc -O，AppKit/Foundation 经 import 自动链接）
#   Contents/Info.plist          来自本目录的 Info.plist
#
# 无第三方依赖；ad-hoc 签名失败不阻塞本地运行。
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

APP_NAME="ThemeSwitch"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
INFO_PLIST="Info.plist"

if [ ! -r "$INFO_PLIST" ]; then
    echo "错误：找不到 ${INFO_PLIST}（放到脚本同目录）" >&2
    exit 1
fi

# 收集源文件；没有 .swift 时给出明确报错而不是把空 glob 传给 swiftc
shopt -s nullglob
SOURCES=(Sources/*.swift)
shopt -u nullglob
if [ "${#SOURCES[@]}" -eq 0 ]; then
    echo "错误：Sources/*.swift 不存在，先提供源文件再构建" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

echo "── swiftc $(swiftc --version 2>&1 | head -1)"
echo "── 编译 ${#SOURCES[@]} 个文件: ${SOURCES[*]##*/}"
swiftc -O -o "$APP_DIR/Contents/MacOS/$APP_NAME" "${SOURCES[@]}"

cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

# ad-hoc 签名：补全 bundle 结构、重复构建时签名状态干净；失败仅是警告
if command -v codesign >/dev/null 2>&1; then
    if codesign --force --sign - "$APP_DIR" 2>/dev/null; then
        echo "✅ ad-hoc 签名完成"
    else
        echo "⚠️  ad-hoc 签名失败（本地运行通常不受影响）"
    fi
fi

echo "✅ 构建完成：$APP_DIR"
