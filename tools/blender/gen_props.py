# -*- coding: utf-8 -*-
"""生成场景道具 GLB，供 Godot 用 MultiMeshInstance3D 在空格里散布。

MultiMesh 只接受单一 Mesh，所以每个道具都合并成一个网格对象，
原点在底面中心、朝向任意（Godot 会随机绕 Y 转）。
面数压在几百以内，几百个实例也只是一次 draw call。
"""

import math
import random
import sys
from os import path as _p

sys.path.append(_p.dirname(_p.abspath(__file__)))

import lib_build as L

RAD = math.radians


def _finish(parts, name, out_dir, bevel_w=0.02):
    ob = L.join(parts, name)
    if bevel_w > 0:
        L.bevel(ob, width=bevel_w, segments=1, angle=40.0)
    L.dirt(ob, 1.0)
    key = "prop_" + name.lower()
    L.export_glb(_p.join(out_dir, key + ".glb"), [ob])
    return key, L.tri_count()


def sandbags(out_dir):
    L.reset_scene()
    rng = random.Random(11)
    parts = []
    for layer in range(3):
        n = 5 - layer
        for i in range(n):
            x = (i - (n - 1) * 0.5) * 0.62
            bag = L.sphere("bag%d_%d" % (layer, i), 0.33,
                           loc=(x, rng.uniform(-0.05, 0.05), 0.17 + layer * 0.3),
                           segments=10, rings=5, material="M_Sandbag")
            bag.scale = (1.3, 0.85, 0.5)
            bag.rotation_euler = (0, 0, rng.uniform(-0.15, 0.15))
            parts.append(bag)
    return _finish(parts, "Sandbags", out_dir, bevel_w=0.0)


def barrel(out_dir):
    L.reset_scene()
    parts = [L.cyl("drum", 0.34, 1.05, loc=(0, 0, 0.52), verts=14, material="M_Rust")]
    for i in range(2):
        parts.append(L.torus("hoop%d" % i, 0.355, 0.035, loc=(0, 0, 0.32 + i * 0.42),
                             major_seg=14, minor_seg=5, material="M_DarkMetal"))
    parts.append(L.cyl("cap", 0.12, 0.07, loc=(0.16, 0, 1.06), verts=8,
                       material="M_Accent"))
    return _finish(parts, "Barrel", out_dir)


def ammo_crate(out_dir):
    L.reset_scene()
    rng = random.Random(3)
    parts = []
    for i in range(3):
        parts.append(L.box("crate%d" % i, (1.05, 0.62, 0.42),
                           loc=(rng.uniform(-0.12, 0.12), rng.uniform(-0.1, 0.1),
                                0.21 + i * 0.43),
                           rot=(0, 0, RAD(rng.uniform(-12, 12))),
                           material="M_Wood"))
        parts.append(L.box("band%d" % i, (1.07, 0.1, 0.44),
                           loc=(parts[-1].location.x, parts[-1].location.y,
                                parts[-1].location.z),
                           rot=parts[-1].rotation_euler, material="M_DarkMetal"))
    return _finish(parts, "AmmoCrate", out_dir)


def hedgehog(out_dir):
    """拒马：三根工字钢交叉焊死。"""
    L.reset_scene()
    parts = []
    for i, rot in enumerate(((RAD(55), 0, 0), (RAD(-55), 0, RAD(60)), (0, RAD(55), RAD(-60)))):
        parts.append(L.box("beam%d" % i, (0.16, 2.3, 0.16), loc=(0, 0, 0.8),
                           rot=rot, material="M_Metal"))
    parts.append(L.sphere("weld", 0.2, loc=(0, 0, 0.8), segments=8, rings=4,
                          material="M_Rust"))
    return _finish(parts, "Hedgehog", out_dir)


def rubble(out_dir):
    L.reset_scene()
    rng = random.Random(5)
    parts = []
    for i in range(14):
        s = rng.uniform(0.16, 0.5)
        parts.append(L.box("rock%d" % i, (s, s * rng.uniform(0.6, 1.1), s * 0.7),
                           loc=(rng.uniform(-1.1, 1.1), rng.uniform(-1.1, 1.1), s * 0.35),
                           rot=(RAD(rng.uniform(0, 40)), RAD(rng.uniform(0, 40)),
                                RAD(rng.uniform(0, 360))),
                           material="M_Concrete" if i % 3 else "M_Brick"))
    return _finish(parts, "Rubble", out_dir, bevel_w=0.015)


def dead_tree(out_dir):
    L.reset_scene()
    rng = random.Random(9)
    parts = [L.cyl("trunk", 0.22, 3.4, loc=(0, 0, 1.7), verts=8, material="M_Wood")]
    for v in parts[0].data.vertices:
        if v.co.z > 0:
            v.co.x *= 0.45
            v.co.y *= 0.45
    parts[0].data.update()
    for i in range(5):
        br = L.tube_y("branch%d" % i, 0.07, rng.uniform(0.8, 1.6), 0.0,
                      verts=6, material="M_Wood", taper=0.4)
        br.rotation_euler = (RAD(rng.uniform(-60, -20)), 0, RAD(rng.uniform(0, 360)))
        br.location = (0, 0, rng.uniform(1.6, 3.1))
        parts.append(br)
    return _finish(parts, "DeadTree", out_dir, bevel_w=0.0)


def lamp(out_dir):
    L.reset_scene()
    parts = [L.cyl("pole", 0.11, 5.0, loc=(0, 0, 2.5), verts=10, material="M_Metal")]
    parts.append(L.box("arm", (0.1, 1.0, 0.1), loc=(0, 0.45, 4.95), material="M_Metal"))
    parts.append(L.box("head", (0.42, 0.62, 0.16), loc=(0, 0.9, 4.84),
                       material="M_DarkMetal"))
    parts.append(L.box("lens", (0.34, 0.5, 0.05), loc=(0, 0.9, 4.74),
                       material="M_Glass"))
    parts.append(L.cyl("foot", 0.3, 0.3, loc=(0, 0, 0.15), verts=10,
                       material="M_Concrete"))
    return _finish(parts, "Lamp", out_dir)


def wire(out_dir):
    """铁丝网：两根斜撑 + 三道横线 + 交叉拉索。"""
    L.reset_scene()
    parts = []
    for sx in (-1, 1):
        parts.append(L.box("post%d" % sx, (0.1, 0.1, 1.5), loc=(sx * 1.6, 0, 0.75),
                           rot=(RAD(sx * 8), 0, 0), material="M_Metal"))
    for i in range(3):
        parts.append(L.box("line%d" % i, (3.3, 0.03, 0.03),
                           loc=(0, 0, 0.4 + i * 0.45), material="M_DarkMetal"))
    for i in range(2):
        parts.append(L.box("cross%d" % i, (3.4, 0.025, 0.025), loc=(0, 0, 0.85),
                           rot=(0, RAD(-22 + i * 44), 0), material="M_DarkMetal"))
    return _finish(parts, "Wire", out_dir, bevel_w=0.0)


def wreck(out_dir):
    """报废坦克残骸：翻倒的车体 + 断掉的炮管 + 散落履带。"""
    L.reset_scene()
    rng = random.Random(13)
    parts = [L.box("hull", (3.0, 4.0, 0.9), loc=(0, 0, 0.5),
                   rot=(RAD(12), RAD(-7), RAD(18)), material="M_Rust")]
    parts.append(L.wedge("turret", (2.0, 2.2, 0.7), loc=(0.5, -0.6, 1.25),
                         rot=(0, 0, RAD(42)), taper=0.7, material="M_Rust"))
    gun = L.tube_y("gun", 0.15, 2.4, 0.0, verts=10, material="M_DarkMetal")
    gun.rotation_euler = (RAD(-72), 0, RAD(42))
    gun.location = (0.5, -0.6, 1.3)
    parts.append(gun)
    for i in range(4):
        parts.append(L.box("track%d" % i, (0.7, 1.2, 0.12),
                           loc=(rng.uniform(-2.2, 2.2), rng.uniform(-2.2, 2.2), 0.06),
                           rot=(0, 0, RAD(rng.uniform(0, 360))), material="M_DarkMetal"))
    return _finish(parts, "Wreck", out_dir)


def pipe(out_dir):
    """水泥管堆：下面两根、上面一根，中空（内壁用深色圆柱假装管腔）。"""
    L.reset_scene()
    parts = []
    layout = ((-1.32, 0.62), (1.32, 0.62), (0.0, 1.72))
    for i, (x, z) in enumerate(layout):
        loc = (x, 0.0, z)
        parts.append(L.cyl("pipe%d" % i, 0.62, 2.4, loc=loc,
                           rot=(0, RAD(90), 0), verts=14, material="M_Concrete"))
        parts.append(L.cyl("bore%d" % i, 0.44, 2.45, loc=loc,
                           rot=(0, RAD(90), 0), verts=14, material="M_DarkMetal"))
    return _finish(parts, "Pipe", out_dir)


def build_all(out_dir):
    return [
        sandbags(out_dir), barrel(out_dir), ammo_crate(out_dir), hedgehog(out_dir),
        rubble(out_dir), dead_tree(out_dir), lamp(out_dir), wire(out_dir),
        wreck(out_dir), pipe(out_dir),
    ]
