# -*- coding: utf-8 -*-
"""生成指挥部碉堡 base_bunker.glb。

原点在地面中心，射击口朝 +Y，也就是 Godot 里的 -Z。玩家基地在网格 y=21、
敌人从 y=2 一侧压过来，而网格 y 沿 +Z 增长，所以敌人来向正是基地的 -Z。
于是模型不需要在 Godot 侧额外旋转，射击口天然朝着敌人。

血量反馈沿用现在的做法：Godot 侧只改 M_Accent 材质的 albedo 与自发光强度，
于是"基地告急会变红"这条视觉语言不变。
"""

import math
import random
import sys
from os import path as _p

sys.path.append(_p.dirname(_p.abspath(__file__)))

import lib_build as L
import dims as D

RAD = math.radians
P = D.BASE_PLINTH      # 6.8，基座边长
H = D.BASE_H           # 3.2，主体高度


def build(out_dir):
    L.reset_scene()
    rng = random.Random(42)
    parts = []

    # ---- 混凝土基座与碉堡主体 ----
    parts.append(L.box("plinth", (P, P, 0.9), loc=(0, 0, 0.45), material="M_Concrete"))
    parts.append(L.wedge("bunker", (P * 0.62, P * 0.62, H), loc=(0, 0, 0.9 + H * 0.5),
                         taper=0.76, material="M_Concrete"))
    # 射击口（朝 +Y，即 Godot 的 -Z）
    parts.append(L.box("embrasure", (P * 0.34, 0.5, 0.42),
                       loc=(0, P * 0.3, 0.9 + H * 0.55), material="M_DarkMetal"))
    # 顶板与通风口
    parts.append(L.box("roof", (P * 0.56, P * 0.56, 0.22),
                       loc=(0, 0, 0.9 + H + 0.11), material="M_Concrete"))
    parts.append(L.cyl("vent", 0.26, 0.5, loc=(-P * 0.16, -P * 0.16, 0.9 + H + 0.35),
                       verts=10, material="M_Metal"))

    # ---- 旗杆与信号灯（M_Accent，Godot 侧按血量染色） ----
    parts.append(L.tube_y("flagpole", 0.07, 3.6, 0.0, verts=8, material="M_Metal"))
    parts[-1].rotation_euler = (RAD(-90), 0, 0)
    parts[-1].location = (P * 0.22, -P * 0.2, 0.9)
    parts.append(L.box("flag", (0.05, 1.3, 0.8),
                       loc=(P * 0.22 + 0.68, -P * 0.2, 3.9), material="M_Accent"))
    parts.append(L.sphere("beacon", 0.42, loc=(0, 0, 0.9 + H + 0.6),
                          segments=14, rings=8, material="M_Accent"))

    # ---- 天线阵 ----
    for i in range(3):
        parts.append(L.tube_y("antenna%d" % i, 0.03, 1.4 + i * 0.5, 0.0,
                              verts=6, material="M_DarkMetal"))
        parts[-1].rotation_euler = (RAD(-88), 0, RAD(-12 + i * 12))
        parts[-1].location = (-P * 0.2 + i * 0.22, P * 0.18, 0.9 + H)
    parts.append(L.torus("dish_ring", 0.45, 0.04, loc=(-P * 0.26, P * 0.1, 0.9 + H + 0.9),
                         rot=(RAD(60), 0, 0), major_seg=16, minor_seg=6,
                         material="M_Metal"))

    # ---- 探照灯 ----
    parts.append(L.cyl("light_housing", 0.34, 0.5,
                       loc=(P * 0.2, P * 0.2, 0.9 + H + 0.3),
                       rot=(RAD(68), 0, RAD(25)), verts=12, material="M_Metal"))
    parts.append(L.cyl("light_lens", 0.3, 0.06,
                       loc=(P * 0.2 + 0.18, P * 0.2 + 0.4, 0.9 + H + 0.48),
                       rot=(RAD(68), 0, RAD(25)), verts=12, material="M_Glass"))

    # ---- 沙袋围圈：背面（-Y，远离敌人来向）留一个缺口当出入口 ----
    # 袋子用 8x4 的低模球压扁而成：一圈几十个，分段多一点整座碉堡就要多几千面
    ring_r = P * 0.52
    seg = 18
    for i in range(seg):
        ang = math.tau * i / seg
        if math.sin(ang) < -0.6:
            continue   # 朝 -Y 一侧留口
        for layer in range(2):
            r = ring_r - layer * 0.18
            bag = L.sphere("bag%d_%d" % (i, layer), 0.34,
                           loc=(math.cos(ang) * r, math.sin(ang) * r,
                                0.9 + 0.22 + layer * 0.34),
                           segments=8, rings=4, material="M_Sandbag")
            bag.scale = (1.35, 0.85, 0.5)
            bag.rotation_euler = (0, 0, ang + rng.uniform(-0.12, 0.12))
            parts.append(bag)

    # ---- 弹药箱与杂物 ----
    for i in range(4):
        parts.append(L.box("crate%d" % i, (0.7, 0.45, 0.4),
                           loc=(-P * 0.34 + i * 0.5, -P * 0.36, 1.1),
                           rot=(0, 0, RAD(rng.uniform(-14, 14))),
                           material="M_Wood"))

    ob = L.join(parts, "BaseBunker")
    L.bevel(ob, width=0.03, segments=1)
    L.dirt(ob, 1.0)
    L.export_glb(_p.join(out_dir, "base_bunker.glb"), [ob])
    return "base_bunker", L.tri_count()


def build_all(out_dir):
    return [build(out_dir)]
