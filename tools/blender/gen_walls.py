# -*- coding: utf-8 -*-
"""生成墙体与水面的 GLB。

全部模型的原点都在**底面中心**（z=0 为地面）。Godot 的 StaticBody3D 仍然
放在 cell_center + h/2 处，所以挂模型时要补一个 (0, -h/2, 0) 的偏移。
碰撞体尺寸一行不改，只换视觉。

砖墙有完好 3 变体 + 受损 3 变体；钢墙 2 变体（混凝土隔离墩 / 钢板掩体）。
变体的意义是打破 24x24 网格的重复感——同一张地图里相邻两格不再长得一样。
"""

import math
import random
import sys
from os import path as _p

sys.path.append(_p.dirname(_p.abspath(__file__)))

import bpy

import lib_build as L
import dims as D

RAD = math.radians
W = D.BLOCK_XY
BH = D.BRICK_H
SH = D.STEEL_H


def _brick_courses(rng, rows=9, missing=0.0, name="brick"):
    """逐层错缝砌砖。每块砖带微小的位置与尺寸抖动，所以墙面不是平板一块。

    6 列 x 9 行：4 m 的格子里砖长约 0.66 m、层高 0.33 m。原来的 4x6 是
    1.0 m x 0.6 m 的"巨型积木"，贴着墙看时一眼就出戏；再密一档（8x12）
    单格要多 600 个三角面，而墙是同屏实例数最多的资源，不值。

    砖色分三档轮换（M_Brick / M_BrickB / M_BrickC）：单色砖墙在阳光下是
    一整片橙红，看不出砌筑层次；三档只差 10% 左右，混在一起才像不同窑次的砖。
    """
    parts = []
    bh = BH / rows
    brick_mats = ("M_Brick", "M_BrickB", "M_BrickC")
    for r in range(rows):
        z = bh * (r + 0.5)
        cols = 6
        bw = W / cols
        offset = (bw * 0.5) if r % 2 else 0.0
        # 错缝行从墙左缘外半块砖开始，到右缘为止，**两端的砖按剩余宽度裁短**。
        # 原先是"砖心越界就整块跳过"，于是奇数行两端各少一块砖，
        # 露出 1 m 宽的砂浆芯——远看像墙块两边被切掉一个缺口。
        x = -W * 0.5 - offset
        c = 0
        while x < W * 0.5 - 1e-4:
            x0 = max(x, -W * 0.5)
            x1 = min(x + bw, W * 0.5)
            w = x1 - x0
            if w > bw * 0.28:
                if not (rng.random() < missing):
                    jitter = (rng.uniform(-0.02, 0.02), rng.uniform(-0.03, 0.03),
                              rng.uniform(-0.015, 0.015))
                    parts.append(L.box(
                        "%s_r%dc%d" % (name, r, c),
                        (w * 0.975 + jitter[2], W * 0.985, bh * 0.94),
                        loc=((x0 + x1) * 0.5 + jitter[0], jitter[1], z),
                        material=brick_mats[(r * 3 + c) % 3]))
            x += bw
            c += 1
    # 砂浆芯：砖块之间露出的灰缝。
    #
    # 必须**缩进**到砖面以内（0.90W 对 0.985W，每侧缩 17 cm）。原来的芯只缩 5 cm、
    # 又比砖缝亮，于是墙块两端露出几条与砖面几乎齐平的浅色横带——远看就是
    # "砖色夹心蛋糕"，而不是一堵砌起来的墙。缩进之后，砖缝后面没有可见面，
    # 缝隙读成阴影与深度；端面只剩砖的端头。
    parts.append(L.box("%s_core" % name, (W * 0.90, W * 0.90, BH * 0.94),
                       loc=(0, 0, BH * 0.47), material="M_Mortar"))
    # 压顶石。原来是一整块 4 m 见方的亮色板——第三人称镜头一压低，
    # 玩家看到的就是"一排盖着白纸的砖箱"。改成 3x3 块**留真缝**的压顶石：
    # 缝宽 4 cm（不是 1.8 cm 的细线），高度逐块 ±1.2 cm，两档石材色交替；
    # 这样墙顶在俯视时读得出"一块块石头"，而不是一张平板。
    parts.append(L.box("%s_bed" % name, (W * 0.94, W * 0.94, 0.05),
                       loc=(0, 0, BH - 0.115), material="M_Mortar"))
    cw = W * 0.315
    gap = W * 0.0125
    for ix in range(3):
        for iy in range(3):
            jz = rng.uniform(-0.012, 0.012)
            parts.append(L.box(
                "%s_cap%d_%d" % (name, ix, iy),
                (cw, cw, 0.10 + jz),
                loc=((ix - 1) * (cw + gap), (iy - 1) * (cw + gap),
                     BH - 0.04 + jz * 0.5),
                material="M_Coping" if (ix + iy) % 2 == 0 else "M_CopingB"))
    return parts


def brick(variant, out_dir):
    rng = random.Random(1000 + variant)
    L.reset_scene()
    parts = _brick_courses(rng, rows=8 + variant, missing=0.02 * variant)
    ob = L.join(parts, "WallBrick")
    # 砖块本身就小，倒角收益低于面数代价，这里只靠脏化顶点色出缝隙阴影
    L.dirt(ob, 1.0)
    name = "wall_brick_%s" % "abc"[variant]
    L.export_glb(_p.join(out_dir, name + ".glb"), [ob])
    return name, L.tri_count()


def brick_damaged(variant, out_dir):
    """受损态：缺口 / 裸露钢筋 / 碎块堆。砖墙血量 <50% 时换上这个。"""
    rng = random.Random(2000 + variant)
    L.reset_scene()
    parts = _brick_courses(rng, rows=9, missing=0.18 + 0.12 * variant, name="dmg")
    # 咬掉一块：从墙顶挖一个三角缺口
    hole_x = rng.uniform(-0.8, 0.8)
    keep = []
    for ob in parts:
        c = ob.location
        if c.z > BH * (0.55 - 0.1 * variant) and abs(c.x - hole_x) < 1.0 + 0.3 * variant:
            L._activate(ob)
            bpy.ops.object.delete()
            continue
        keep.append(ob)

    # 裸露钢筋
    for i in range(3 + variant):
        keep.append(L.tube_y("rebar%d" % i, 0.035, rng.uniform(0.5, 1.1), 0.0,
                             verts=5, material="M_Rust"))
        keep[-1].rotation_euler = (RAD(rng.uniform(-115, -65)), 0, RAD(rng.uniform(-25, 25)))
        keep[-1].location = (hole_x + rng.uniform(-0.7, 0.7),
                             rng.uniform(-0.3, 0.3),
                             BH * rng.uniform(0.45, 0.62))
    # 脚下的碎块
    for i in range(5 + variant * 2):
        s = rng.uniform(0.1, 0.3)
        keep.append(L.box("chunk%d" % i, (s, s * 0.8, s * 0.7),
                          loc=(rng.uniform(-W * 0.45, W * 0.45),
                               rng.uniform(-W * 0.45, W * 0.45),
                               s * 0.4),
                          rot=(RAD(rng.uniform(0, 60)), 0, RAD(rng.uniform(0, 360))),
                          material="M_Brick"))
    ob = L.join(keep, "WallBrickDamaged")
    L.dirt(ob, 1.0)
    name = "wall_brick_dmg_%s" % "abc"[variant]
    L.export_glb(_p.join(out_dir, name + ".glb"), [ob])
    return name, L.tri_count()


def steel_barrier(out_dir):
    """混凝土隔离墙：4.4 m 高的直墙，不是一座金字塔。

    原来的上半段是一整块 2.7 m 高的楔形（taper 0.55），从第三人称的俯角看，
    整块墙读成"一顶米色的帐篷"——这正是远处那排"帐篷"的来源。真实的
    新泽西护栏是 0.8 m 高的矮墩，而这里要占满 4.4 m 的格子，所以它必须是
    一堵墙：竖直墙身 + 0.2 m 倒角压顶 + 分缝 / 吊装孔 / 端部警示。
    """
    L.reset_scene()
    parts = [
        # 基座略宽，墙身收进 4 cm：墙根有一条阴影线，墙才"站在地上"
        L.box("barrier_foot", (W * 0.99, W * 0.99, 0.34),
              loc=(0, 0, 0.17), material="M_Concrete"),
        L.box("barrier_core", (W * 0.95, W * 0.56, SH * 0.90),
              loc=(0, 0, SH * 0.45), material="M_Concrete"),
        # 压顶：比墙身略宽、颜色更深，从上方看是一条明确的墙脊
        L.box("barrier_cap", (W * 0.97, W * 0.64, 0.18),
              loc=(0, 0, SH - 0.09), material="M_Coping"),
    ]
    # 竖向分缝 + 横向模板线：混凝土墙的"砌筑"信息，两面都做
    for sx in (-1, 1):
        for i in range(3):
            parts.append(L.box("barrier_joint%d_%d" % (sx, i),
                               (0.05, 0.03, SH * 0.82),
                               loc=((i - 1) * W * 0.28, sx * W * 0.285,
                                    SH * 0.45), material="M_Mortar"))
        parts.append(L.box("barrier_form%d" % sx, (W * 0.95, 0.03, 0.06),
                           loc=(0, sx * W * 0.285, SH * 0.52),
                           material="M_Mortar"))
        # 吊装孔
        for sx2 in (-1, 1):
            parts.append(L.box("barrier_lift%d_%d" % (sx, sx2), (0.34, 0.05, 0.26),
                               loc=(sx2 * W * 0.18, sx * W * 0.285, SH * 0.78),
                               material="M_DarkMetal"))
        # 端部警示：两块短块，靠近地面，远看不会变成"墙上的黄条"
        for sx2 in (-1, 1):
            for i in range(2):
                parts.append(L.box("barrier_stripe%d_%d_%d" % (sx, sx2, i),
                                   (W * 0.14, 0.04, 0.24),
                                   loc=(sx2 * W * 0.34, sx * W * 0.29,
                                        0.95 + i * 0.52), material="M_Accent"))
        # 水痕/锈迹：从压顶垂下来的细长条
        for i in range(2):
            parts.append(L.box("barrier_stain%d_%d" % (sx, i),
                               (W * 0.06, 0.02, SH * 0.55),
                               loc=((i * 2 - 1) * W * 0.22, sx * W * 0.292,
                                    SH * 0.30), material="M_Rust"))
    ob = L.join(parts, "WallSteelA")
    L.bevel(ob, width=0.02, segments=1)
    L.dirt(ob, 1.0)
    L.export_glb(_p.join(out_dir, "wall_steel_a.glb"), [ob])
    return "wall_steel_a", L.tri_count()


def steel_plate(out_dir):
    """钢板掩体：型钢框架 + 铆接钢板 + 射击孔。"""
    L.reset_scene()
    parts = [L.box("plate_core", (W * 0.9, W * 0.7, SH), loc=(0, 0, SH * 0.5),
                   material="M_Metal")]
    # 竖向工字骨架
    for sx in (-1, 0, 1):
        parts.append(L.box("plate_rib%d" % sx, (0.22, W * 0.8, SH),
                           loc=(sx * W * 0.36, 0, SH * 0.5), material="M_DarkMetal"))
    # 横向加强梁
    for i in range(3):
        parts.append(L.box("plate_beam%d" % i, (W * 0.95, W * 0.75, 0.16),
                           loc=(0, 0, 0.6 + i * 1.5), material="M_DarkMetal"))
    # 铆钉：只在正面点几颗，剩下的交给脏化顶点色暗示
    rng = random.Random(7)
    for i in range(8):
        parts.append(L.cyl("rivet%d" % i, 0.05, 0.06,
                           loc=(rng.uniform(-W * 0.42, W * 0.42),
                                -W * 0.36,
                                rng.uniform(0.2, SH - 0.2)),
                           rot=(RAD(90), 0, 0), verts=5, material="M_Metal"))
    # 射击孔
    parts.append(L.box("plate_slot", (0.9, 0.25, 0.22), loc=(0, -W * 0.3, SH * 0.62),
                       material="M_DarkMetal"))
    # 压顶梁：钢板墙顶上一条深色横梁，收住"没封口"的剪影，
    # 从第三人称俯角看不会直接露出现场背后的天空。
    parts.append(L.box("plate_cap", (W * 0.97, W * 0.78, 0.20),
                       loc=(0, 0, SH - 0.10), material="M_DarkMetal"))
    # 底部沙袋压重
    for i in range(3):
        parts.append(L.sphere("plate_bag%d" % i, 0.3,
                              loc=(-W * 0.26 + i * (W * 0.26), -W * 0.42, 0.22),
                              segments=7, rings=3, material="M_Sandbag"))
        parts[-1].scale = (1.3, 0.9, 0.55)
    ob = L.join(parts, "WallSteelB")
    L.bevel(ob, width=0.025, segments=1)
    L.dirt(ob, 1.0)
    L.export_glb(_p.join(out_dir, "wall_steel_b.glb"), [ob])
    return "wall_steel_b", L.tri_count()


def water(out_dir):
    """水面网格：细分到 8x8，配合 Godot 的水 shader 做顶点扰动。"""
    L.reset_scene()
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=8, y_subdivisions=8,
                                    size=1.0, location=(0, 0, D.WATER_H))
    ob = bpy.context.active_object
    ob.name = "WaterSurface"
    ob.scale = (W, W, 1.0)
    L.bake(ob, scale=True, rot=False)
    ob.data.materials.append(L.mat("M_Water"))
    # 四周的淤泥岸沿，避免水面边缘硬切
    bank = []
    for sx, sy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        bank.append(L.box("bank_%d_%d" % (sx, sy),
                          (W if sx == 0 else 0.3, W if sy == 0 else 0.3, 0.26),
                          loc=(sx * W * 0.48, sy * W * 0.48, 0.13),
                          material="M_Mortar"))
    ob = L.join([ob] + bank, "WaterSurface")
    L.export_glb(_p.join(out_dir, "water_surface.glb"), [ob])
    return "water_surface", L.tri_count()


def build_all(out_dir):
    out = []
    for v in range(3):
        out.append(brick(v, out_dir))
    for v in range(3):
        out.append(brick_damaged(v, out_dir))
    out.append(steel_barrier(out_dir))
    out.append(steel_plate(out_dir))
    out.append(water(out_dir))
    return out
