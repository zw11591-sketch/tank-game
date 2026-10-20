# -*- coding: utf-8 -*-
"""尺寸真值表。

这里的每一个数字都与 Godot 侧的玩法常量一一对应。模型按此表建模之后，
碰撞体、装甲分区角度、炮口位置、格子尺寸都不需要改一行代码。
改模型观感可以随意，但凡是本表里的量，改之前必须同步改 Godot 常量，
否则就会出现"模型变好看了，但判定错位了"。

坐标约定（Blender）：
    +X 右、+Y 车头前方、+Z 上。
glTF 导出会把 Blender 的 Z-up 转成 Y-up，于是在 Godot 里：
    +X 右、+Y 上、-Z 前方。
这正是 tank.gd 里 `-global_transform.basis.z` 当车头方向的约定。
"""

# ---------------- 战场网格（arena.gd） ----------------
CELL = 4.0            # Arena.CELL
BLOCK_XY = 3.92       # CELL * 0.98，墙体水平尺寸
BRICK_H = 3.0         # Arena.BRICK_H
STEEL_H = 4.4         # Arena.STEEL_H
WATER_H = 0.5         # Arena.WATER_H
BASE_H = 3.2          # Arena.BASE_H
BASE_PLINTH = CELL * 1.7

# ---------------- 坦克 ----------------
# hull:    (宽 X, 长 Y, 高 Z)，对应 tank.gd 的 _hull_size = (x, z, y)
# radius:  tank.gd 的 body_radius，碰撞圆柱半径
# turret:  炮塔回转中心 (Y 前后偏移, Z 高度)
# barrel:  炮管耳轴相对炮塔原点的高度 Z
# gun_len: 耳轴到炮口的长度，即 Muzzle 的局部 +Y
TANKS = {
    "tank_player": {
        "hull": (3.4, 4.4, 1.0),
        "radius": 1.50,
        "turret": (-0.15, 1.40),
        "barrel": 0.55,
        "gun_len": 3.80,
        "wheels": 6,
        "style": "mbt",
    },
    "tank_scout": {
        "hull": (3.0, 3.9, 0.90),
        "radius": 1.35,
        "turret": (-0.10, 1.25),
        "barrel": 0.45,
        "gun_len": 2.60,
        "wheels": 4,
        "style": "wheeled",
    },
    "tank_medium": {
        "hull": (3.4, 4.4, 1.00),
        "radius": 1.50,
        "turret": (-0.15, 1.40),
        "barrel": 0.55,
        "gun_len": 3.40,
        "wheels": 6,
        "style": "mbt",
    },
    "tank_heavy": {
        "hull": (3.8, 4.9, 1.15),
        "radius": 1.75,
        "turret": (-0.20, 1.55),
        "barrel": 0.60,
        "gun_len": 3.90,
        "wheels": 7,
        "style": "heavy",
    },
    "tank_artillery": {
        "hull": (3.3, 4.6, 0.95),
        "radius": 1.50,
        "turret": (-0.45, 1.20),
        "barrel": 0.50,
        "gun_len": 5.20,
        "wheels": 6,
        "style": "spg",
    },
    "tank_destroyer": {
        # 低矮的无炮塔式车体：长 5.0、高 0.85，战斗室顶盖比主战坦克的炮塔顶低 0.4 m。
        # 射界只有 ±40°（见 tank_roster.gd 的 turret_limit），所以车体必须自己指向目标。
        "hull": (3.4, 5.0, 0.85),
        "radius": 1.50,
        "turret": (0.30, 1.20),
        "barrel": 0.34,
        "gun_len": 4.60,
        "wheels": 6,
        "style": "td",
    },
    "tank_boss": {
        "hull": (4.6, 6.0, 1.40),
        "radius": 2.30,
        "turret": (-0.20, 1.85),
        "barrel": 0.70,
        "gun_len": 4.60,
        "wheels": 8,
        "style": "boss",
    },
}

# ---------------- 三角面预算 ----------------
# 预算按"同屏实例数"反推：墙体一张图能摆上百个，所以压得最狠；
# 坦克同屏最多 7 台、碉堡只有一座，可以多给一些。
# 超出预算 build_all.py 会在报告里标记，提醒回头简化。
#
# 坦克这一档从 12000 提到 26000、再提到 30000，是因为写实细节（铆钉排、托带轮、
# 百叶窗、热护套、舱盖铰链）单件只有几十个面，但件数多；而 7 台车同屏 20 万面在
# 桌面 GPU 上仍然只是一帧的零头，真正贵的是阴影与材质切换，不是这些顶点。
#
# 30000 是按实测值定的，不是拍的：细节加的最后一档让 7 台车里的 5 台跨过了 26000
# （主战/中型 27140、重型 28684、火炮 26328、Boss 29308，侦察 17820、
# 歼击 24524），最重的 Boss 距上限只剩 2%。再往上加细节就该重新评估同屏预算，
# 而不是顺手把上限再抬一格。
BUDGET = {
    "tank_": 30000,
    "wall_": 1200,
    "water_": 400,
    "base_": 9000,
    "prop_": 700,
}


def budget_for(name):
    for prefix, limit in BUDGET.items():
        if name.startswith(prefix):
            return limit
    return 2000
