# -*- coding: utf-8 -*-
"""GLB 材质契约报告（开发期工具，不需要 Blender）。

    python tools/blender/glb_report.py [文件或目录...]

默认检查 assets/models 下的全部 GLB。打印每个模型每个材质的
baseColorFactor、是否带 albedo / normal / metallicRoughness 贴图，
并断言两条**不能坏**的契约：

  1. M_Paint 的 baseColorFactor 必须是白的。
     Godot 的 Assets.paint() 是**赋值**而不是相乘：它把 albedo_color 直接设成阵营色，
     再与 albedo 贴图相乘。若因子不是白的，阵营色就会被二次压暗，
     山猫的黄和猎手的白会一起糊掉。
  2. M_TankMetal 必须带贴图——它的钢色是烘在贴图里的，Base Color 因子是白的；
     贴图一旦丢失，炮管就会变成一块纯白。
"""

import json
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_DIR = os.path.join(ROOT, "assets", "models")

_JSON_CHUNK = 0x4E4F534A


def _read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, _ver, _total = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF":
        raise ValueError("不是 GLB：%s" % path)
    off = 12
    while off < len(data):
        clen, ctype = struct.unpack_from("<II", data, off)
        off += 8
        if ctype == _JSON_CHUNK:
            return json.loads(data[off:off + clen].decode("utf-8"))
        off += clen
    raise ValueError("没有 JSON chunk：%s" % path)


def _factor(mat):
    pbr = mat.get("pbrMetallicRoughness", {})
    return pbr.get("baseColorFactor", [1.0, 1.0, 1.0, 1.0])


def report(path, problems):
    gltf = _read_glb(path)
    mats = gltf.get("materials", [])
    images = gltf.get("images", [])
    name = os.path.basename(path)
    print("%s  materials=%d images=%d size=%.2fMB" % (
        name, len(mats), len(images), os.path.getsize(path) / 1048576.0))
    for m in mats:
        pbr = m.get("pbrMetallicRoughness", {})
        f = _factor(m)
        tags = []
        if "baseColorTexture" in pbr:
            tags.append("albedo")
        if "normalTexture" in m:
            tags.append("normal")
        if "metallicRoughnessTexture" in pbr:
            tags.append("orm")
        print("    %-14s factor=(%.2f,%.2f,%.2f) tex=[%s]" % (
            m.get("name", "?"), f[0], f[1], f[2], ",".join(tags) or "-"))
        if m.get("name") == "M_Paint" and abs(f[0] - 1.0) > 1e-3:
            problems.append("%s: M_Paint 的 baseColorFactor 不是白的（阵营涂装会被二次相乘）" % name)
        if m.get("name") == "M_TankMetal" and "baseColorTexture" not in pbr:
            problems.append("%s: M_TankMetal 丢了 albedo 贴图（钢色烘在贴图里，会变成纯白）" % name)
    for i, img in enumerate(images):
        print("    image[%d] %s" % (i, img.get("mimeType", "?")))


def main(argv):
    targets = argv or [DEFAULT_DIR]
    paths = []
    for t in targets:
        if os.path.isdir(t):
            paths.extend(os.path.join(t, n) for n in sorted(os.listdir(t))
                         if n.endswith(".glb"))
        else:
            paths.append(t)
    problems = []
    for p in paths:
        report(p, problems)
    print("-" * 60)
    if problems:
        print("发现 %d 处契约问题：" % len(problems))
        for p in problems:
            print("  - " + p)
        return 1
    print("检查 %d 个模型，契约全部通过。" % len(paths))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
