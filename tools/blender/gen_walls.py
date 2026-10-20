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


def _brick_courses(rng, rows=6, missing=0.0, name="brick"):
    """逐层错缝砌砖。每块砖带微小的位置与尺寸抖动，所以墙面不是平板一块。

    层数与列数刻意压到 6x4：墙体是同屏实例数最多的资源，
    一格多 100 个三角形，一张图就多出一万多。错缝 + 抖动已经足够打破平板感。
    """
    parts = []
    bh = BH / rows
    for r in range(rows):
        z = bh * (r + 0.5)
        cols = 4
        bw = W / cols
        offset = (bw * 0.5) if r % 2 else 0.0
        for c in range(cols + 1):
            x = -W * 0.5 + bw * c + offset
            # 半块砖也不许越出格子。原来只判砖心，于是 x=-W/2 那块整块探出去半块，
            # 砖墙视觉宽 4.85 m 而格子只有 4.0 m——单格走廊里两侧墙面各自压进通道
            # 0.43 m，屏幕上就是"坦克开进墙里"（tools/mesh_dims.gd 的溢出列）。
            if abs(x) + bw * 0.5 > W * 0.5 + 1e-4:
                continue
            if rng.random() < missing:
                continue
            jitter = (rng.uniform(-0.02, 0.02), rng.uniform(-0.03, 0.03), rng.uniform(-0.015, 0.015))
            parts.append(L.box(
                "%s_r%dc%d" % (name, r, c),
                (bw * 0.94 + jitter[2], W * 0.98, bh * 0.88),
                loc=(x + jitter[0], jitter[1], z),
                material="M_Brick"))
    # 砂浆芯：砖块之间露出的灰缝
    parts.append(L.box("%s_core" % name, (W * 0.93, W * 0.93, BH * 0.99),
                       loc=(0, 0, BH * 0.5), material="M_Mortar"))
    # 压顶石
    parts.append(L.box("%s_cap" % name, (W, W * 0.99, 0.12),
                       loc=(0, 0, BH - 0.06), material="M_Mortar"))
    return parts


def brick(variant, out_dir):
    rng = random.Random(1000 + variant)
    L.reset_scene()
    parts = _brick_courses(rng, rows=5 + variant, missing=0.02 * variant)
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
    parts = _brick_courses(rng, rows=6, missing=0.18 + 0.12 * variant, name="dmg")
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
    """混凝土隔离墩：上窄下宽的梯形体 + 吊装孔 + 警示条。"""
    L.reset_scene()
    parts = [L.wedge("barrier", (W * 0.98, W * 0.98, SH), loc=(0, 0, SH * 0.5),
                     taper=0.72, material="M_Concrete")]
    # 底部加宽的基座
    parts.append(L.box("barrier_foot", (W, W, 0.35), loc=(0, 0, 0.17),
                       material="M_Concrete"))
    # 顶部钢制吊环
    for sx in (-1, 1):
        parts.append(L.torus("barrier_ring%d" % sx, 0.16, 0.035,
                             loc=(sx * W * 0.2, 0, SH + 0.05), rot=(RAD(90), 0, 0),
                             major_seg=12, minor_seg=6, material="M_Metal"))
    # 警示色条
    for i in range(3):
        parts.append(L.box("barrier_stripe%d" % i, (W * 0.72, W * 0.99, 0.18),
                           loc=(0, 0, 0.75 + i * 0.95), material="M_Accent"))
    ob = L.join(parts, "WallSteelA")
    L.bevel(ob, width=0.035, segments=1)
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
    # 底部沙袋压重
    for i in range(3):
        parts.append(L.sphere("plate_bag%d" % i, 0.3,
                              loc=(-W * 0.26 + i * (W * 0.26), -W * 0.42, 0.22),
                              segments=8, rings=4, material="M_Sandbag"))
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
