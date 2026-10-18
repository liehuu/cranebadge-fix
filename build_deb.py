#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CraneBadgeFix deb 打包器（零依赖，Python 标准库）。
在 macOS GitHub Actions runner 上无 dpkg-deb，故手写 ar + tar.gz 生成标准 .deb。

.deb 结构（dpkg/Cydia 均兼容）：
  !<arch>\n
  debian-binary           内容 "2.0\n"
  control.tar.gz          含 ./control ./postinst（维护脚本）
  data.tar.gz             含实际安装文件
"""
import io, os, sys, tarfile, plistlib

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT  = os.path.join(ROOT, "out", "com.82flex.cranebadgefix_0.2.0_iphoneos-arm64e.deb")
DYLIB = os.path.join(ROOT, "out", "CraneBadgeFix.dylib")
PLIST = os.path.join(ROOT, "CraneBadgeFix.plist")
CONTROL = os.path.join(ROOT, "control")
POSTINST = os.path.join(ROOT, "postinst")


def tar_gz(entries, mode=0o644):
    """entries: list of (arcname, local_path or (name, bytes, mode))"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for arc, payload in entries:
            if isinstance(payload, tuple):
                name, data, m = payload
                ti = tarfile.TarInfo(name=name)
                ti.size = len(data)
                ti.mode = m
                ti.mtime = 0
                tf.addfile(ti, io.BytesIO(data))
            else:
                ti = tarfile.TarInfo(name=arc)
                ti.size = os.path.getsize(payload)
                ti.mode = mode
                ti.mtime = 0
                with open(payload, "rb") as f:
                    tf.addfile(ti, f)
    return buf.getvalue()


def ar_entry(name, data):
    """标准 GNU ar 成员头（60 字节）。"""
    assert len(name) <= 15, name
    h = bytearray()
    h += name.ljust(16).encode()      # name (16)
    h += b"0".rjust(12, b"0")         # mtime (12)
    h += b"0".rjust(6, b"0")          # uid (6)
    h += b"0".rjust(6, b"0")          # gid (6)
    h += b"100644".rjust(8, b"0")     # mode (8, 八进制)
    h += str(len(data)).rjust(10).encode()  # size (10)
    h += b"\x60\n"                    # 结束标记 (2)
    assert len(h) == 60, len(h)
    body = data + (b"\n" if len(data) % 2 else b"")
    return bytes(h) + body


def main():
    for p in (DYLIB, PLIST, CONTROL, POSTINST):
        if not os.path.exists(p):
            sys.exit(f"missing: {p}")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)

    debian_binary = b"2.0\n"

    # control.tar.gz：./control + ./postinst（755）
    control_tar = tar_gz([
        ("control", CONTROL),
        ("postinst", ("./postinst", open(POSTINST, "rb").read(), 0o755)),
    ])

    # plist 转 binary plist（Substrate 只认合法 plist；参考补丁同样是二进制）
    with open(PLIST, "rb") as f:
        plist_obj = plistlib.load(f)
    plist_binary = plistlib.dumps(plist_obj, fmt=plistlib.FMT_BINARY)

    # data.tar.gz：dylib(755) + 过滤 plist(binary)
    data_tar = tar_gz([
        ("Library/MobileSubstrate/DynamicLibraries/CraneBadgeFix.dylib",
         ("./Library/MobileSubstrate/DynamicLibraries/CraneBadgeFix.dylib",
          open(DYLIB, "rb").read(), 0o755)),
        ("Library/MobileSubstrate/DynamicLibraries/CraneBadgeFix.plist",
         ("./Library/MobileSubstrate/DynamicLibraries/CraneBadgeFix.plist",
          plist_binary, 0o644)),
    ])

    # ar 归档
    out = bytearray()
    out += b"!<arch>\n"
    out += ar_entry("debian-binary", debian_binary)
    out += ar_entry("control.tar.gz", control_tar)
    out += ar_entry("data.tar.gz", data_tar)

    with open(OUT, "wb") as f:
        f.write(bytes(out))
    print(f"[build_deb] wrote {OUT}  ({len(out)} bytes)")


if __name__ == "__main__":
    main()