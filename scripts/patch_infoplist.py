#!/usr/bin/env python3
"""
给注入后的 App 补 Info.plist 里 dylib 运行所必需的三项配置。

为什么必须补（不是可选项）：
    这三项都是**进程级**配置，dylib 在运行时改不了 —— 不像代码可以 swizzle，
    ATS 的判定发生在 CFNetwork 里，读的就是 App bundle 的 Info.plist。

    1. NSAppTransportSecurity.NSAllowsArbitraryLoads
       中转站 / 路由器后台都是 http://192.168.x.x 的明文地址。
       不给这一项，请求直接被 ATS 拦死（NSURLErrorDomain -1022）。

    2. NSLocalNetworkUsageDescription
       iOS 14 起访问局域网要授权，缺这一项压根不弹框，请求表现为连不上。

    3. NSBonjourServices 里带上 _minis-relay._tcp
       RelayRoute 冷启动会起一个 NWBrowser 探这个服务，作用是**主动触发**
       本地网络授权弹窗（不探的话要等第一次真正请求才弹，首帧就是空的）。
       没有这一项，NWBrowser 直接失败，弹窗不出现。

    只补缺失项，已有值不覆盖 —— 官方如果自己配了更严的 ATS 例外，别去动它。

用法：
    python3 patch_infoplist.py Payload/Minis.app/Info.plist
"""

import plistlib
import sys

ATS_KEY = "NSAppTransportSecurity"
ATS_ARBITRARY = "NSAllowsArbitraryLoads"
LOCAL_NET_KEY = "NSLocalNetworkUsageDescription"
LOCAL_NET_TEXT = (
    "全能AI 需要访问局域网，用于连接你家里的中转站和路由器后台。"
)
BONJOUR_KEY = "NSBonjourServices"
BONJOUR_SERVICE = "_minis-relay._tcp"


def patch(path):
    with open(path, "rb") as f:
        raw = f.read()

    # 保留原有的存储格式：App 里的 Info.plist 通常是二进制
    is_binary = raw.startswith(b"bplist00")
    data = plistlib.loads(raw)

    changes = []

    ats = data.get(ATS_KEY)
    if not isinstance(ats, dict):
        ats = {}
        data[ATS_KEY] = ats
    if ats.get(ATS_ARBITRARY) is not True:
        ats[ATS_ARBITRARY] = True
        changes.append("%s.%s = true" % (ATS_KEY, ATS_ARBITRARY))

    if not (data.get(LOCAL_NET_KEY) or "").strip():
        data[LOCAL_NET_KEY] = LOCAL_NET_TEXT
        changes.append("%s = %s" % (LOCAL_NET_KEY, LOCAL_NET_TEXT))

    services = data.get(BONJOUR_KEY)
    if not isinstance(services, list):
        services = []
    if BONJOUR_SERVICE not in services:
        services.append(BONJOUR_SERVICE)
        data[BONJOUR_KEY] = services
        changes.append("%s += %s" % (BONJOUR_KEY, BONJOUR_SERVICE))

    if not changes:
        print("Info.plist 已有这三项，未改动")
        return 0

    fmt = plistlib.FMT_BINARY if is_binary else plistlib.FMT_XML
    with open(path, "wb") as f:
        plistlib.dump(data, f, fmt=fmt, sort_keys=False)

    for line in changes:
        print("已写入：%s" % line)
    return 0


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    return patch(sys.argv[1])


if __name__ == "__main__":
    sys.exit(main())
