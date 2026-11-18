#!/usr/bin/env python3
"""
给 64 位 Mach-O 可执行文件插入一条 LC_LOAD_DYLIB。

为什么自己写这个：
    常见做法是 `insert_dylib` / `optool` 这类工具，但它们要么需要编译
    一堆源码，要么在 runner 上装不上。这个脚本只做一件事、只用标准库，
    行为可预期，出错时能说清楚「为什么插不进去」。

原理（简单到可以背下来）：
    Mach-O 的 header 后面是 load commands，再后面才是第一个 section 的
    真实内容。编译器会在这两者之间留一段对齐/安装名预留的空隙
    （headerpad）。只要空隙够放下一个 dylib_command，就可以原地写入，
    然后把 header 里的 ncmds +1、sizeofcmds +新命令长度。
    —— 不移动任何一字节原有内容，文件大小不变。

    空隙不够时会明确报错，不会硬塞。这种情况下要重新出包并加链接参数
    `-Wl,-headerpad_max_install_names`，不要试图挪 section。

注意：改完之后原代码签名就失效了，必须重新签名（见 workflow）。

用法：
    python3 inject_dylib.py <macho> @executable_path/Frameworks/X.dylib
    python3 inject_dylib.py <macho> --check @executable_path/...
"""

import argparse
import os
import struct
import sys
import tempfile

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_ENCRYPTION_INFO_64 = 0x2C

HEADER_64 = struct.Struct("<8I")
SEGMENT_64 = struct.Struct("<II16sQQQQiiII")
SECTION_64 = struct.Struct("<16s16sQQIIIIIIII")
DYLIB_CMD = struct.Struct("<IIIIII")

HEADER_SIZE = HEADER_64.size  # 32


class InjectError(Exception):
    pass


def _align(value, alignment=8):
    return (value + alignment - 1) // alignment * alignment


def _read_commands(data):
    """返回 (ncmds, sizeofcmds, cmds_end, existing_names, first_section_offset, cryptid)"""
    magic, _cputype, _cpusub, _filetype, ncmds, sizeofcmds, _flags, _res = HEADER_64.unpack_from(data, 0)

    if magic == MH_CIGAM_64:
        raise InjectError("这是大端序 Mach-O，本脚本只处理小端（arm64），不支持。")
    if magic != MH_MAGIC_64:
        raise InjectError("不是 64 位 Mach-O（magic=0x%08X）。fat 包请先 lipo 拆出 arm64。" % magic)

    cmds_end = HEADER_SIZE + sizeofcmds
    if cmds_end > len(data):
        raise InjectError("sizeofcmds 越界，文件可能已损坏。")

    offset = HEADER_SIZE
    names = []
    first_section = None
    cryptid = 0

    for index in range(ncmds):
        if offset + 8 > cmds_end:
            raise InjectError("load command #%d 越界。" % index)
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmdsize < 8 or offset + cmdsize > cmds_end:
            raise InjectError("load command #%d 的 cmdsize 非法：%d" % (index, cmdsize))

        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            name_off = struct.unpack_from("<I", data, offset + 8)[0]
            if 0 < name_off < cmdsize:
                raw = data[offset + name_off: offset + cmdsize]
                names.append(raw.split(b"\0", 1)[0].decode("utf-8", "replace"))

        elif cmd == LC_SEGMENT_64:
            segname, _vmaddr, _vmsize, _fileoff, _filesize, _mx, _ip, nsects, _fl = SEGMENT_64.unpack_from(data, offset)[2:]
            sect_off = offset + SEGMENT_64.size
            for s in range(nsects):
                if sect_off + SECTION_64.size > offset + cmdsize:
                    break
                fields = SECTION_64.unpack_from(data, sect_off)
                section_offset = fields[4]
                # offset == 0 是 zerofill 段（只占内存不占文件），跳过
                if section_offset > 0 and (first_section is None or section_offset < first_section):
                    first_section = section_offset
                sect_off += SECTION_64.size

        elif cmd == LC_ENCRYPTION_INFO_64:
            # cryptid != 0 = App Store 下载的加密包
            if cmdsize >= 20:
                cryptid = struct.unpack_from("<I", data, offset + 16)[0]

        offset += cmdsize

    if first_section is None:
        raise InjectError("找不到任何带文件偏移的 section，无法判断可用空隙。")

    return ncmds, sizeofcmds, cmds_end, names, first_section, cryptid


def inject(path, dylib_name, check_only=False, allow_encrypted=False):
    with open(path, "rb") as f:
        data = f.read()

    ncmds, sizeofcmds, cmds_end, names, first_section, cryptid = _read_commands(data)

    if cryptid and not allow_encrypted:
        raise InjectError(
            "这是加密包（LC_ENCRYPTION_INFO_64 cryptid=%d），来自 App Store 下载。\n"
            "  注入会连带重签，重签后 FairPlay 解密失效 —— 装上就是闪退。\n"
            "  要么用自己编的包（cryptid=0），要么先砸壳；确实知道自己在做什么时加 --allow-encrypted。"
            % cryptid
        )

    already = dylib_name in names
    if check_only:
        return already, first_section - cmds_end

    if already:
        print("已存在，跳过：%s" % dylib_name)
        return True, first_section - cmds_end

    raw_name = dylib_name.encode("utf-8") + b"\0"
    cmdsize = _align(DYLIB_CMD.size + len(raw_name), 8)
    # 24 字节是 dylib_command 头的长度（name_offset 指向头后面紧跟的字符串）
    cmd = DYLIB_CMD.pack(
        LC_LOAD_DYLIB,
        cmdsize,
        DYLIB_CMD.size,   # name_offset
        2,                # timestamp
        0x00010000,       # current_version 1.0.0
        0x00010000,       # compatibility_version 1.0.0
    ) + raw_name
    cmd = cmd.ljust(cmdsize, b"\0")

    padding = first_section - cmds_end
    if padding < cmdsize:
        raise InjectError(
            "headerpad 不够：需要 %d 字节，只剩 %d 字节。\n"
            "  补救：重新出包时给链接器加 -Wl,-headerpad_max_install_names，"
            "或者用 insert_dylib --inplace（会移动数据，本脚本不做）。"
            % (cmdsize, padding)
        )

    buffer = bytearray(data)
    buffer[cmds_end:cmds_end + cmdsize] = cmd
    magic, cputype, cpusub, filetype, _n, _s, flags, reserved = HEADER_64.unpack_from(data, 0)
    HEADER_64.pack_into(buffer, 0, magic, cputype, cpusub, filetype,
                        ncmds + 1, sizeofcmds + cmdsize, flags, reserved)

    # 原地写回：保留权限位，先写临时文件再替换，避免中途失败留下半个文件
    mode = os.stat(path).st_mode
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".inject-")
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(buffer)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

    print("已插入 LC_LOAD_DYLIB：%s（用了 %d / %d 字节空隙）" % (dylib_name, cmdsize, padding))
    return False, padding


def main():
    parser = argparse.ArgumentParser(description="给 Mach-O 插入 LC_LOAD_DYLIB")
    parser.add_argument("macho", help="目标可执行文件")
    parser.add_argument("dylib", help="install name，例如 @executable_path/Frameworks/RelayDylib.dylib")
    parser.add_argument("--check", action="store_true", help="只检查，不修改")
    parser.add_argument("--allow-encrypted", action="store_true",
                        help="允许对 cryptid!=0 的加密包动手（会破掉 FairPlay，通常不该用）")
    args = parser.parse_args()

    if not os.path.isfile(args.macho):
        print("error: 找不到文件 %s" % args.macho, file=sys.stderr)
        return 1

    try:
        already, padding = inject(args.macho, args.dylib,
                                  check_only=args.check,
                                  allow_encrypted=args.allow_encrypted)
    except InjectError as error:
        print("error: %s" % error, file=sys.stderr)
        return 1

    if args.check:
        print("已存在: %s | 可用空隙: %d 字节" % ("是" if already else "否", padding))
    return 0


if __name__ == "__main__":
    sys.exit(main())
