#!/bin/bash
#
# 编译 RelayDylib.dylib
#
# 为什么不用 theos / xcodeproj：
#   这里只有一个 dylib，没有 bundle、没有资源、没有 Info.plist。
#   一个 xcodeproj 或一套 theos Makefile 带来的维护成本，比它省下的
#   几行 xcrun 高得多 —— 而且 pbxproj 还容易在合并上游时冲突。
#   直接用 swiftc / clang 调 iPhoneOS SDK，谁都能一眼读完。
#
# 用法：
#   ./build.sh                # 产物落到 ./build/RelayDylib.dylib
#   ./build.sh /tmp/out       # 指定输出目录
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/build}"
NAME="RelayDylib"

# 部署目标跟着主 App 走（Minis 主 target 是 16.0）
TARGET="arm64-apple-ios16.0"
# 装进 app 内 Frameworks/ 后靠这个路径被 dyld 找到
INSTALL_NAME="@executable_path/Frameworks/${NAME}.dylib"

if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: 找不到 xcrun —— 这一步必须在 macOS + Xcode 上跑" >&2
    exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK:    $SDK"
echo "TARGET: $TARGET"

mkdir -p "$OUT"
OBJDIR="$OUT/obj"
rm -rf "$OBJDIR"
mkdir -p "$OBJDIR"

# ── 1. ObjC 入口 + 运行时桥 ──
# constructor 只能写在 C/ObjC 里，见 RelayEntry.m 顶部注释。
# RelayBridge.m 是 v3 的：App 的配置写入通道只有 @objc 类，编译期不可见，
# 只能在运行时按类名后缀找（见该文件顶部注释）。
for objc_src in RelayEntry RelayBridge; do
    xcrun --sdk iphoneos clang \
        -c "$HERE/Sources/${objc_src}.m" \
        -o "$OBJDIR/${objc_src}.o" \
        -target "$TARGET" \
        -isysroot "$SDK" \
        -fobjc-arc \
        -O2
done

# ── 2. Swift + 链接 ──
# 一次调用里既编又链：swiftc 会把 .o 一起交给链接器，并且自动带上
# Swift 运行时（libswiftCore 等在系统 /usr/lib/swift 里，不需要内嵌）。
#
# -undefined dynamic_lookup：允许引用主 App 的符号留到运行时解析。
#   v2 搬进来的 Relay 页面不需要，但留着不会有副作用。
#
# 源文件分两处：入口/首页在 Sources/ 根下，从中转站 fork 搬来的页面在
# Sources/Relay/。这里用 globstar 之外的写法（显式两组 glob），因为
# runner 上的 bash 3.2 没开 globstar。
SWIFT_FILES=("$HERE/Sources/"*.swift)
if [ -d "$HERE/Sources/Relay" ]; then
    SWIFT_FILES+=("$HERE/Sources/Relay/"*.swift)
fi
echo "源文件 ${#SWIFT_FILES[@]} 个"

xcrun --sdk iphoneos swiftc \
    -emit-library \
    -o "$OUT/$NAME.dylib" \
    -target "$TARGET" \
    -sdk "$SDK" \
    -module-name "$NAME" \
    -parse-as-library \
    -O \
    -Xlinker -install_name -Xlinker "$INSTALL_NAME" \
    -Xlinker -undefined -Xlinker dynamic_lookup \
    -framework UIKit \
    -framework SwiftUI \
    -framework WebKit \
    -framework Foundation \
    -framework Network \
    "${SWIFT_FILES[@]}" \
    "$OBJDIR/RelayEntry.o" \
    "$OBJDIR/RelayBridge.o"

# ── 3. 自检：产物必须存在、架构对、install_name 对 ──
echo "--- 产物 ---"
ls -l "$OUT/$NAME.dylib"
ARCHS="$(xcrun lipo -archs "$OUT/$NAME.dylib")"
echo "架构: $ARCHS"
if [ "$ARCHS" != "arm64" ]; then
    echo "error: 期望 arm64，实际 $ARCHS" >&2
    exit 1
fi
xcrun otool -D "$OUT/$NAME.dylib" | tail -n +2

# 导出符号里必须有 RelayDylibMain，否则 constructor 会链接不上（运行时空转）
if ! xcrun nm -gU "$OUT/$NAME.dylib" | grep -q "RelayDylibMain"; then
    echo "error: dylib 里没有导出 RelayDylibMain，constructor 会调不到" >&2
    exit 1
fi

# v3 的配置写入桥。它由 -undefined dynamic_lookup 放行，缺了也照样链接通过，
# 只会在用户点了「保存」那一刻才炸 —— 所以在这里先验一遍定义在不在。
if ! xcrun nm -gU "$OUT/$NAME.dylib" | grep -q "RelayConfigAddProvider"; then
    echo "error: dylib 里没有 RelayConfigAddProvider（RelayBridge.m 没编进去）" >&2
    exit 1
fi

echo "OK: $OUT/$NAME.dylib"
