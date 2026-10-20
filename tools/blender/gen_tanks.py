# -*- coding: utf-8 -*-
"""生成 7 台坦克的 GLB。

节点层级严格为 Hull / Turret / Barrel / Muzzle，另有 Wheel_L0..n、Wheel_R0..n。
tank.gd 按这些名字取节点，所以改名等于改代码契约。

写实感的做法是"堆层次"，而不是堆多边形。真实坦克之所以好认，是因为它身上有大量
**解释得通的小零件**：舱盖有铰链、灯有灯罩、履带侧有托带轮、发动机盖上有一排百叶窗、
炮管上有热护套、钢板交界处有焊缝与铆钉排。每一样单看都只有几十个面，合起来才把
"一台被维护过的机器"和"一个灰色方块"区分开。

按 style 取用的细节清单（见各函数）：
    车体：倾斜首下装甲、首上折角、反应装甲块、格栅装甲、侧裙、翼子板与橡胶挡泥帘、
          焊缝、铆钉排、牵引钩、车灯与尾灯、工具箱、备用履带块、
          发动机百叶窗与舱盖、排气管与消声器、驻锄、拖曳环
    行走：履带板与履带销、负重轮（轮毂 + 轮缘螺栓）、托带轮、悬挂臂、
          主动轮（含齿）、诱导轮、挡泥板
    炮塔：炮塔环、倾斜前脸、顶盖识别色块、车长指挥塔与舱盖、装填手舱盖、
          观瞄镜箱、潜望镜、并列机枪、高射机枪、尾部储物篮与篷布、
          侧挂储物箱、探照灯、抽风机、烟幕弹发射器、天线
    炮管：炮盾与螺栓、身管、热护套、抽气装置、炮口制退器、炮口内膛
"""

import math
import sys
from os import path as _p

sys.path.append(_p.dirname(_p.abspath(__file__)))

import lib_build as L
import lib_tex as T
import dims as D

RAD = math.radians


# ---------------- 阵列件小工具 ----------------
#
# 铆钉、履带销、百叶窗都是"同一件东西沿某个轴排一排"。单件只有几十个面，
# 但件数一多手写循环就有几十行重复代码，所以统一成两个生成器。

def _row(prefix, n, maker, start, step, axis=0):
    out = []
    for i in range(n):
        loc = list(start)
        loc[axis] += step * i
        out.append(maker(i, tuple(loc)))
    return out


def _bolts(prefix, n, start, step, axis=0, radius=0.05, depth=0.08,
           rot=(0, 0, 0), material="M_Metal"):
    """一排螺栓。钢板上有没有这排点，是"贴图感"与"结构感"的分界。"""
    return _row(prefix, n,
                lambda i, loc: L.cyl("%s%d" % (prefix, i), radius, depth,
                                     loc=loc, rot=rot, verts=6, material=material),
                start, step, axis)


def _louvers(prefix, n, w, start, step, axis=1, material="M_DarkMetal"):
    """带倾角的百叶窗叶片。发动机盖上一排，车体顶部立刻不再是"平板"。"""
    return _row(prefix, n,
                lambda i, loc: L.box("%s%d" % (prefix, i), (w, 0.085, 0.075),
                                     loc=loc, rot=(RAD(-26), 0, 0), material=material),
                start, step, axis)


def _box_pair(prefix, x, y, z, size, material="M_Metal"):
    """左右对称的一对盒子。翼子板挂件、拖钩、储物箱全是成对的。"""
    return [L.box("%s%d" % (prefix, sx), size,
                  loc=(sx * x, y, z), material=material) for sx in (-1, 1)]


# ---------------- 车体 ----------------

def _hull(w, l, h, style):
    """车体：主箱体 + 首下斜板 + 首上折角 + 尾板 + 附件 + 发动机舱细节。

    返回 (零件列表, 车体中心高度 z)。
    """
    parts = []
    z = 0.35 + h * 0.5
    hw = w * 0.5
    low = style == "td"          # 歼击车：更平的首上，把正面投影压到最低

    parts.append(L.box("hull_main", (w, l, h), loc=(0, 0, z)))

    # 倾斜首下装甲：视觉上强调"正面更硬"，与 armor_front 的数值设定呼应
    glacis_angle = RAD(38 if low else 32)
    glacis = L.box("hull_glacis", (w * 0.96, 1.5, 0.85),
                   loc=(0, l * 0.5 - 0.55, z + 0.18), rot=(glacis_angle, 0, 0))
    parts.append(glacis)
    # 首上折角，压出一条亮边
    parts.append(L.box("hull_nose", (w * 0.9, 0.9, 0.5),
                       loc=(0, l * 0.5 - 0.1, z - h * 0.35),
                       rot=(RAD(-14 if low else -20), 0, 0)))
    # 首下装甲上的铆钉排：斜板与箱体的连接处
    parts.extend(_bolts("hull_bolt_front", 7, (-w * 0.30, l * 0.5 - 0.80, z + 0.34),
                        0.10, axis=0, radius=0.045, depth=0.10,
                        rot=(RAD(90), 0, 0)))
    # 车体侧面的焊缝：一条细长条，比整面平墙多一层转折
    for sx in (-1, 1):
        parts.append(L.box("hull_seam%d" % sx, (0.07, l * 0.86, 0.07),
                           loc=(sx * (hw - 0.02), 0, z + h * 0.42), material="M_Metal"))
        parts.extend(_bolts("hull_bolt_side%d" % sx, 4,
                            (sx * (hw - 0.01), l * 0.5 - 1.0, z + h * 0.22),
                            -0.42, axis=1, radius=0.042, depth=0.07,
                            rot=(0, RAD(90), 0)))

    # 尾板 + 拖曳环
    parts.append(L.box("hull_tail", (w * 0.92, 0.45, h * 0.9),
                       loc=(0, -l * 0.5 + 0.1, z), material="M_DarkMetal"))
    parts.extend(_box_pair("hull_tow", hw * 0.62, -l * 0.5 - 0.14, z - h * 0.18,
                           (0.24, 0.34, 0.20)))
    # 排气管 + 消声器：真车的尾部永远挂着这两根，而且是最容易被认出来的部件之一
    for sx in (-1, 1):
        parts.append(L.cyl("hull_muffler%d" % sx, 0.17, 0.95,
                           loc=(sx * hw * 0.62, -l * 0.5 + 0.95, z + h * 0.42),
                           rot=(0, RAD(90), 0), verts=14, material="M_DarkMetal"))
        pipe = L.tube_y("hull_exhaust%d" % sx, 0.10, 0.55, -l * 0.5 - 0.15,
                        verts=10, material="M_DarkMetal")
        pipe.location.x = sx * hw * 0.72
        pipe.location.z = z + h * 0.42
        parts.append(pipe)

    # 发动机舱：一排百叶窗 + 一块带铰链的检修盖
    parts.extend(_louvers("hull_louver", 5, w * 0.50,
                          (0, -l * 0.5 + 1.45, z + h * 0.5 + 0.035), 0.30))
    parts.append(L.box("hull_hatch", (w * 0.44, 0.95, 0.07),
                       loc=(0, -l * 0.5 + 0.80, z + h * 0.5 + 0.02)))
    parts.extend(_row("hull_hinge", 2,
                      lambda i, loc: L.cyl("hull_hinge%d" % i, 0.05, 0.22,
                                           loc=loc, rot=(0, RAD(90), 0), verts=8,
                                           material="M_DarkMetal"),
                      (-w * 0.18, -l * 0.5 + 0.36, z + h * 0.5 + 0.05), w * 0.36, axis=0))

    # 挡泥板 + 橡胶挡泥帘：车体最外侧的两片，宽度必须收在车体宽度之内
    #
    # 这两片原来比车体宽 0.95 / 0.40 米，整车因此有 4.86 米宽——而碰撞圆柱只有
    # 3.0 米、格子只有 4.0 米。单格走廊里车身两侧各压进墙里 0.4 米以上，
    # 屏幕上就是"坦克在穿墙"（tools/mesh_dims.gd、tools/shots/clipview）。
    # 视觉轮廓必须跟着碰撞轮廓走：多出来的那 0.9 米不是细节，是穿墙。
    for sy in (1, -1):
        parts.append(L.box("hull_fender%d" % sy, (w - 0.06, 0.5, 0.10),
                           loc=(0, sy * (l * 0.5 - 0.35), 0.92), material="M_Metal"))
        for sx in (-1, 1):
            parts.append(L.box("hull_flap%d_%d" % (sy, sx), (0.44, 0.06, 0.32),
                               loc=(sx * (hw - 0.24), sy * (l * 0.5 - 0.02), 0.80),
                               material="M_Rubber"))

    # 翼子板上的随车工具：一个钢制工具箱 + 一个帆布铺盖卷
    parts.append(L.box("hull_toolbox", (0.42, 0.92, 0.32),
                       loc=(hw - 0.30, l * 0.5 - 1.20, 1.00), material="M_Metal"))
    parts.append(L.cyl("hull_bedroll", 0.16, 1.0, loc=(-hw + 0.24, 0.2, 1.02),
                       rot=(RAD(90), 0, 0), verts=10, material="M_Canvas"))
    # 车灯：玻璃灯罩 + 钢制灯体，夜间地形上这两点亮光是唯一主动的朝向线索
    for sx in (-1, 1):
        parts.append(L.cyl("hull_lampbase%d" % sx, 0.13, 0.16,
                           loc=(sx * hw * 0.74, l * 0.5 - 0.05, z + 0.10),
                           rot=(RAD(90), 0, 0), verts=12, material="M_Metal"))
        parts.append(L.cyl("hull_lampglass%d" % sx, 0.10, 0.06,
                           loc=(sx * hw * 0.74, l * 0.5 + 0.06, z + 0.10),
                           rot=(RAD(90), 0, 0), verts=12, material="M_Glass"))
    # 尾灯：两颗小红灯，"哪头是车尾"在最远的视距上也读得出来
    for sx in (-1, 1):
        parts.append(L.box("hull_taillight%d" % sx, (0.13, 0.07, 0.11),
                           loc=(sx * hw * 0.66, -l * 0.5 - 0.02, z + h * 0.30),
                           material="M_Glass"))

    # ---- 按风格追加的外挂件 ----
    if style in ("heavy", "boss"):
        # 格栅装甲：重型与 Boss 的标志性外挂件
        for i in range(5):
            parts.extend(_box_pair("hull_cage%d_" % i, hw - 0.12,
                                   l * 0.25 - i * 0.42, z + 0.5, (0.07, 0.9, 0.7)))
    if style in ("mbt", "heavy", "boss"):
        # 附加反应装甲块 + 首上的备用履带块
        for i in range(4):
            parts.append(L.box("hull_era%d" % i, (0.55, 0.42, 0.16),
                               loc=(-w * 0.28 + i * (w * 0.19), l * 0.5 - 0.95,
                                    z + h * 0.52),
                               rot=(RAD(28), 0, 0), material="M_Paint"))
        parts.extend(_row("hull_sparetrack", 6,
                          lambda i, loc: L.box("hull_sparetrack%d" % i,
                                               (w * 0.62, 0.13, 0.09),
                                               loc=loc, rot=(RAD(30), 0, 0),
                                               material="M_DarkMetal"),
                          (0, l * 0.5 - 1.55, z + h * 0.62), 0.20, axis=1))
    if style == "spg":
        # 驻锄：火炮车尾部的两条支撑
        for sx in (-1, 1):
            parts.append(L.box("hull_spade%d" % sx, (0.35, 1.3, 0.12),
                               loc=(sx * w * 0.3, -l * 0.5 - 0.4, 0.3),
                               rot=(RAD(-18), 0, 0), material="M_Metal"))
    if style == "td":
        # 歼击车：首上加一层倾斜附加装甲，把"正面最硬"这件事画出来
        parts.append(L.box("hull_plow", (w * 0.88, 1.15, 0.22),
                           loc=(0, l * 0.5 - 1.45, z + h * 0.56),
                           rot=(RAD(24), 0, 0), material="M_Paint"))
    return parts, z


# ---------------- 行走部分 ----------------

def _running_gear(hull_parent, w, l, h, count, style):
    """行走部分。轮式车给大轮胎，履带车给履带 + 负重轮 + 主动轮 + 托带轮。

    返回 (可滚动的轮子对象, 要合并进车体的静态件)。
    轮子保持独立对象并烘掉摆放旋转，Godot 侧才能直接改 rotation.x 滚动；
    轮毂与轮缘螺栓**并进轮子本体**（而不是各挂一个子节点），
    否则光这一项就要往场景里多塞上百个节点。
    """
    wheels = []
    static = []
    hw = w * 0.5

    if style == "wheeled":
        r = 0.55
        # 轮胎外沿齐平车体侧面：车宽 w 是**整车**宽度（含行走部分），
        # 而不是"车体再加一圈履带/轮胎"。见文件头与 _hull 的挡泥板注释。
        x = hw - 0.27
        for i in range(count):
            y = l * 0.5 - 0.75 - i * ((l - 1.5) / max(count - 1, 1))
            for side, sx in (("L", -1), ("R", 1)):
                tire = L.cyl("Wheel_%s%d" % (side, i), r, 0.42,
                             loc=(sx * x, y, r), rot=(0, RAD(90), 0),
                             verts=20, material="M_Rubber")
                parts = [tire,
                         L.cyl("hub", r * 0.52, 0.46, loc=(sx * x, y, r),
                               rot=(0, RAD(90), 0), verts=14, material="M_Metal")]
                # 轮缘螺栓：轮式车最显眼的一圈细节
                for k in range(6):
                    a = math.pi * 2.0 * k / 6.0
                    parts.append(L.cyl("bolt%d" % k, 0.045, 0.50,
                                       loc=(sx * x, y + math.cos(a) * r * 0.34,
                                            r + math.sin(a) * r * 0.34),
                                       rot=(0, RAD(90), 0), verts=6,
                                       material="M_DarkMetal"))
                wheel = L.join(parts, "Wheel_%s%d" % (side, i))
                L.bake(wheel)
                wheel.parent = hull_parent
                wheels.append(wheel)
        # 轮式底盘没有履带，但要有一对前轮挡泥板才像车
        for side, sx in (("L", -1), ("R", 1)):
            static.append(L.box("mudguard_%s" % side, (0.12, 1.0, 0.08),
                                loc=(sx * (x + 0.21), l * 0.5 - 1.05, 1.16),
                                material="M_Metal"))
        return wheels, static

    # ---- 履带 ----
    #
    # 履带**不是**一整块厚板：而是上支段 + 下支段 + 前后绕过诱导轮/主动轮的包边。
    # 原实现用一块 0.85 米高的实心箱体当履带，负重轮整个埋在里面——也就是说
    # 那 6 个轮子一个都看不见，"行走部分"实际只是两块黑方块。这正是模型显得廉价
    # 最直接的来源，所以这里改成真正的环状结构：轮子露在外面，履带只负责包住它。
    r = 0.50 if style == "boss" else 0.42
    wheel_z = r + 0.04
    track_w = 0.70
    # 履带外沿（含履带板的 0.03）正好齐平车体侧面。原来是 hw + 0.28，
    # 整车因此比碰撞圆柱宽出近 1 米——这一条就是"坦克穿墙"的主因。
    x = hw - track_w * 0.5 - 0.04
    run_t = 0.13
    roll_r = r + 0.16            # 诱导轮 / 主动轮半径，决定履带环的整体高度
    roll_z = 0.58
    top_z = roll_z + roll_r - run_t * 0.5
    run_len = l - 0.6 + 0.26
    for side, sx in (("L", -1), ("R", 1)):
        static.append(L.box("track_low_%s" % side, (track_w, run_len, run_t),
                            loc=(sx * x, 0, 0.055), material="M_Rubber"))
        static.append(L.box("track_top_%s" % side, (track_w, run_len, run_t),
                            loc=(sx * x, 0, top_z), material="M_Rubber"))
        # 履带板纹路：从 10 片加密到 14 片，贴地那一段才不再是"一块黑条"
        for i in range(14):
            static.append(L.box("tracklink_%s%d" % (side, i),
                                (track_w + 0.06, 0.12, 0.08),
                                loc=(sx * x,
                                     run_len * 0.5 - 0.22 - i * (run_len - 0.44) / 13.0,
                                     0.055 + run_t * 0.5),
                                material="M_DarkMetal"))
        # 侧裙：挂在履带外沿、只盖住上支段。位置特意抬高到负重轮上缘之上，
        # 于是"轮子看得见、上支段看不见"——真车从侧面看就是这样。
        static.append(L.box("skirt_%s" % side, (0.10, l * 0.86, 0.42),
                            loc=(sx * (x + track_w * 0.5 - 0.02), -0.05, top_z + 0.02)))
        # 托带轮：托着上支段的两个小轮，缺了履带上部就像悬在空中
        for i in range(2):
            static.append(L.cyl("returnroller_%s%d" % (side, i), 0.13, 0.30,
                                loc=(sx * x, 0.45 - i * 1.5, top_z - run_t * 0.5 - 0.13),
                                rot=(0, RAD(90), 0), verts=12, material="M_Metal"))

    span = (l - 1.6) / max(count - 1, 1)
    for i in range(count):
        y = l * 0.5 - 0.95 - i * span
        for side, sx in (("L", -1), ("R", 1)):
            wheel = L.cyl("Wheel_%s%d" % (side, i), r, 0.50,
                          loc=(sx * x, y, wheel_z), rot=(0, RAD(90), 0),
                          verts=18, material="M_DarkMetal")
            # 轮毂与轮缘螺栓并进轮子本体：它们要跟着轮子一起滚，
            # 但各挂一个子节点的话光这一项就要多出上百个节点。
            parts = [wheel,
                     L.cyl("hub", r * 0.42, 0.56, loc=(sx * x, y, wheel_z),
                           rot=(0, RAD(90), 0), verts=12, material="M_Metal")]
            for k in range(6):
                a = math.pi * 2.0 * k / 6.0
                parts.append(L.cyl("bolt%d" % k, 0.042, 0.60,
                                   loc=(sx * x, y + math.cos(a) * r * 0.28,
                                        wheel_z + math.sin(a) * r * 0.28),
                                   rot=(0, RAD(90), 0), verts=6, material="M_Metal"))
            one = L.join(parts, "Wheel_%s%d" % (side, i))
            L.bake(one)
            one.parent = hull_parent
            wheels.append(one)

    # 诱导轮（前）与主动轮（后）：比负重轮大一圈，履带环由它们撑起来
    for side, sx in (("L", -1), ("R", 1)):
        static.append(L.cyl("idler_%s" % side, roll_r, 0.60,
                            loc=(sx * x, l * 0.5 - 0.30, roll_z),
                            rot=(0, RAD(90), 0), verts=18, material="M_DarkMetal"))
        static.append(L.cyl("sprocket_%s" % side, roll_r, 0.64,
                            loc=(sx * x, -l * 0.5 + 0.30, roll_z),
                            rot=(0, RAD(90), 0), verts=18, material="M_Metal"))
        for k in range(8):
            a = math.pi * 2.0 * k / 8.0
            static.append(L.box("sprocket_tooth_%s%d" % (side, k),
                                (0.50, 0.13, 0.13),
                                loc=(sx * x,
                                     -l * 0.5 + 0.30 + math.cos(a) * (roll_r + 0.06),
                                     roll_z + math.sin(a) * (roll_r + 0.06)),
                                rot=(0, RAD(90), -a), material="M_Metal"))
    return wheels, static


# ---------------- 炮塔 / 战斗室 ----------------

def _turret(w, style):
    """炮塔主体 + 指挥塔 + 观瞄 + 机枪 + 储物 + 烟幕发射器 + 天线。

    歼击车（style == "td"）走另一条分支：没有指挥塔，战斗室低矮、前脸大角度倾斜，
    因为那台车的设计目标就是"被看见之前先开火"。
    """
    parts = []
    tw = w * 0.72
    if style == "td":
        return _casemate(w, tw)

    parts.append(L.wedge("turret_main", (tw, tw * 1.25, 0.8), loc=(0, 0, 0.4), taper=0.78))
    # 炮塔环：炮塔与车体 roof 之间的那道缝，缺了炮塔像"浮在车顶上"
    parts.append(L.cyl("turret_ring", tw * 0.60, 0.10, loc=(0, 0.05, 0.02),
                       verts=20, material="M_DarkMetal"))
    # 炮塔前脸倾斜板
    parts.append(L.box("turret_face", (tw * 0.85, 0.7, 0.62),
                       loc=(0, tw * 0.6, 0.42), rot=(RAD(-24), 0, 0)))
    # 顶盖识别色块（Godot 侧按阵营刷色）
    parts.append(L.box("turret_cap", (tw * 0.5, tw * 0.5, 0.1),
                       loc=(0, -0.1, 0.84), material="M_Accent"))
    # 定角器 + 炮盾后方的螺栓
    parts.extend(_bolts("turret_bolt", 6,
                        (-tw * 0.44, tw * 0.62, 0.52), 0.17, axis=0,
                        radius=0.05, depth=0.14, rot=(RAD(-24), 0, 0)))
    # 车长指挥塔 + 舱盖铰链 + 观瞄窗
    parts.append(L.cyl("turret_cupola", 0.34, 0.30, loc=(-tw * 0.26, -0.3, 0.95),
                       verts=16, material="M_Paint"))
    parts.append(L.cyl("turret_hatch", 0.30, 0.09, loc=(-tw * 0.26, -0.3, 1.13),
                       verts=16, material="M_Paint"))
    parts.append(L.box("turret_hatch_hinge", (0.26, 0.08, 0.06),
                       loc=(-tw * 0.26, -0.62, 1.13), material="M_DarkMetal"))
    parts.append(L.cyl("turret_periscope", 0.12, 0.14, loc=(-tw * 0.26, -0.12, 1.14),
                       verts=10, material="M_Glass"))
    # 装填手舱盖
    parts.append(L.cyl("turret_hatch2", 0.26, 0.09, loc=(tw * 0.26, -0.34, 0.86),
                       verts=14, material="M_Paint"))
    # 观瞄镜箱：车长用来测距的那个方盒子，正面一块玻璃
    parts.append(L.box("turret_sight", (0.30, 0.42, 0.22),
                       loc=(-tw * 0.30, tw * 0.52, 0.90), material="M_Metal"))
    parts.append(L.box("turret_sight_glass", (0.24, 0.06, 0.16),
                       loc=(-tw * 0.30, tw * 0.74, 0.90), material="M_Glass"))
    # 抽风机：炮塔顶上的小圆顶
    parts.append(L.cyl("turret_vent", 0.14, 0.10, loc=(tw * 0.10, -0.44, 0.86),
                       verts=12, material="M_Metal"))
    # 并列机枪
    parts.append(L.box("turret_mgbase", (0.22, 0.3, 0.16), loc=(tw * 0.3, 0.1, 0.9),
                       material="M_DarkMetal"))
    mg = L.tube_y("turret_mg", 0.055, 0.8, 0.25, verts=8, material="M_DarkMetal")
    mg.location.x = tw * 0.3
    mg.location.z = 0.98
    parts.append(mg)
    # 尾部储物篮 + 篷布卷
    parts.append(L.box("turret_basket", (tw * 0.8, 0.5, 0.3),
                       loc=(0, -tw * 0.66, 0.5), material="M_Metal"))
    parts.append(L.box("turret_tarp", (tw * 0.7, 0.42, 0.22),
                       loc=(0, -tw * 0.66, 0.6), material="M_Canvas"))
    # 侧挂储物箱：炮塔两侧各一个，把侧影从"梯形"变成"梯形挂了两块"
    for sx in (-1, 1):
        parts.append(L.box("turret_stow%d" % sx, (0.14, tw * 0.55, 0.28),
                           loc=(sx * tw * 0.56, -tw * 0.20, 0.42), material="M_Metal"))
    # 抽烟榴弹发射器（对应 smoke 技能）
    for sx in (-1, 1):
        for i in range(3):
            parts.append(L.cyl("turret_smoke%d_%d" % (sx, i), 0.075, 0.26,
                               loc=(sx * tw * 0.42, tw * 0.3 - i * 0.18, 0.62),
                               rot=(RAD(-70), 0, 0), verts=8, material="M_DarkMetal"))
    # 探照灯：夜战图里唯一主动发光的部件
    parts.append(L.box("turret_light_base", (0.14, 0.14, 0.20),
                       loc=(tw * 0.40, tw * 0.30, 0.98), material="M_Metal"))
    parts.append(L.cyl("turret_light", 0.17, 0.26, loc=(tw * 0.40, tw * 0.34, 1.14),
                       rot=(RAD(90), 0, 0), verts=14, material="M_Metal"))
    parts.append(L.cyl("turret_light_lens", 0.14, 0.05, loc=(tw * 0.40, tw * 0.48, 1.14),
                       rot=(RAD(90), 0, 0), verts=14, material="M_Glass"))
    # 天线
    parts.append(L.tube_y("turret_antenna", 0.025, 1.5, 0.0, verts=6,
                          material="M_DarkMetal"))
    parts[-1].rotation_euler = (RAD(-82), 0, 0)
    parts[-1].location = (-tw * 0.44, -tw * 0.5, 0.9)

    if style in ("mbt", "heavy"):
        # 高射机枪：架在指挥塔上，是"这台车有人在里面"最直接的一件证据
        parts.append(L.cyl("turret_aa_base", 0.10, 0.30,
                           loc=(-tw * 0.26, -0.5, 1.30), verts=10, material="M_Metal"))
        aa = L.tube_y("turret_aa_mg", 0.045, 0.95, 0.10, verts=8, material="M_DarkMetal")
        aa.location.x = -tw * 0.26
        aa.location.z = 1.42
        parts.append(aa)
    if style == "boss":
        # Boss 裙甲 + 第二观瞄塔
        for sx in (-1, 1):
            parts.append(L.box("turret_bossfin%d" % sx, (0.1, tw * 0.9, 0.45),
                               loc=(sx * tw * 0.52, 0, 0.3)))
        parts.append(L.cyl("turret_boss_sensor", 0.2, 0.34, loc=(tw * 0.24, -0.45, 0.98),
                           verts=12, material="M_Glass"))
    return parts


def _casemate(w, tw):
    """歼击车的低矮战斗室。

    它不是"小一号的炮塔"：没有指挥塔、没有储物篮，正面是一整块大角度倾斜板，
    顶盖离地只有 1.8 米左右（主战坦克的炮塔顶在 2.2 米以上）。
    射界只有 ±40°，所以它靠低矮与正面装甲换命，而不是靠转塔。
    """
    parts = []
    parts.append(L.wedge("turret_main", (tw * 1.05, tw * 1.45, 0.56),
                         loc=(0, 0.05, 0.28), taper=0.88))
    parts.append(L.cyl("turret_ring", tw * 0.55, 0.09, loc=(0, 0.05, 0.01),
                       verts=18, material="M_DarkMetal"))
    # 前脸大角度倾斜板：正面投影最小的那块
    parts.append(L.box("turret_face", (tw * 0.98, 1.05, 0.60),
                       loc=(0, tw * 0.66, 0.26), rot=(RAD(-36), 0, 0)))
    parts.append(L.box("turret_cap", (tw * 0.52, tw * 0.52, 0.09),
                       loc=(0, -0.12, 0.58), material="M_Accent"))
    # 车长舱盖 + 三具潜望镜（无指挥塔，低矮是这台车唯一的设计目标）
    parts.append(L.cyl("turret_hatch", 0.30, 0.10, loc=(-tw * 0.24, -0.32, 0.62),
                       verts=16, material="M_Paint"))
    parts.append(L.box("turret_hatch_hinge", (0.24, 0.08, 0.06),
                       loc=(-tw * 0.24, -0.62, 0.62), material="M_DarkMetal"))
    for i in range(3):
        parts.append(L.cyl("turret_periscope%d" % i, 0.075, 0.13,
                           loc=(-tw * 0.30 + i * 0.26, -0.62, 0.64),
                           verts=8, material="M_Glass"))
    parts.append(L.box("turret_sight", (0.28, 0.40, 0.20),
                       loc=(-tw * 0.28, tw * 0.50, 0.62), material="M_Metal"))
    parts.append(L.box("turret_sight_glass", (0.22, 0.06, 0.14),
                       loc=(-tw * 0.28, tw * 0.72, 0.62), material="M_Glass"))
    # 顶部的备用履带与工具箱：战斗室顶上不堆东西就不像真车
    parts.extend(_row("turret_sparetrack", 5,
                      lambda i, loc: L.box("turret_sparetrack%d" % i, (0.13, 0.60, 0.09),
                                           loc=loc, material="M_DarkMetal"),
                      (tw * 0.36, -0.10, 0.60), -0.19, axis=0))
    parts.append(L.box("turret_stow", (0.40, 0.70, 0.24),
                       loc=(-tw * 0.40, -0.28, 0.60), material="M_Metal"))
    for sx in (-1, 1):
        for i in range(3):
            parts.append(L.cyl("turret_smoke%d_%d" % (sx, i), 0.07, 0.24,
                               loc=(sx * tw * 0.50, tw * 0.40 - i * 0.17, 0.44),
                               rot=(RAD(-70), 0, 0), verts=8, material="M_DarkMetal"))
    parts.append(L.tube_y("turret_antenna", 0.025, 1.4, 0.0, verts=6,
                          material="M_DarkMetal"))
    parts[-1].rotation_euler = (RAD(-80), 0, 0)
    parts[-1].location = (-tw * 0.52, -tw * 0.52, 0.58)
    return parts


# ---------------- 炮管 ----------------

def _gun(gun_len, caliber, style):
    """炮管：炮盾 + 身管 + 热护套 + 抽气装置 + 炮口制退器 + 内膛。"""
    parts = []
    parts.append(L.box("gun_mantlet", (caliber * 5.0, 0.55, caliber * 4.4),
                       loc=(0, 0.3, 0), material="M_Paint"))
    parts.extend(_bolts("gun_mantlet_bolt", 4,
                        (-caliber * 1.8, 0.3, caliber * 2.3), caliber * 1.2,
                        axis=0, radius=caliber * 0.22, depth=caliber * 0.5,
                        rot=(RAD(90), 0, 0)))
    parts.append(L.tube_y("gun_barrel", caliber, gun_len - 0.5, 0.35,
                          verts=20, material="M_DarkMetal", taper=0.88))

    # 热护套：现代主战坦克最容易被认出来的特征，一圈分段套在身管后段。
    # 分段而不是一根整管——接缝本身就是细节。
    sleeve_from = 0.75
    sleeve_to = max(0.9, gun_len * 0.52)
    n_seg = 5
    seg_len = (sleeve_to - sleeve_from) / n_seg
    for i in range(n_seg):
        parts.append(L.cyl("gun_thermal%d" % i, caliber * 1.32, seg_len * 0.86,
                           loc=(0, sleeve_from + seg_len * (i + 0.5), 0),
                           rot=(RAD(90), 0, 0), verts=16, material="M_Canvas"))
    # 抽气装置
    parts.append(L.cyl("gun_evac", caliber * 1.7, 0.42,
                       loc=(0, gun_len * 0.62, 0), rot=(RAD(90), 0, 0),
                       verts=16, material="M_DarkMetal"))
    # 炮口制退器 + 内膛
    parts.append(L.cyl("gun_brake", caliber * 1.55, 0.5,
                       loc=(0, gun_len - 0.28, 0), rot=(RAD(90), 0, 0),
                       verts=16, material="M_Accent"))
    parts.append(L.cyl("gun_bore", caliber * 0.62, 0.22,
                       loc=(0, gun_len - 0.10, 0), rot=(RAD(90), 0, 0),
                       verts=14, material="M_DarkMetal"))
    for i in range(2):
        parts.append(L.box("gun_port%d" % i, (caliber * 3.4, 0.1, caliber * 0.7),
                           loc=(0, gun_len - 0.42 + i * 0.26, 0),
                           material="M_DarkMetal"))
    if style == "boss":
        # 双联装：Boss 的第二根身管
        second = L.tube_y("gun_barrel2", caliber * 0.62, gun_len - 1.2, 0.4,
                          verts=12, material="M_DarkMetal")
        second.location.x = caliber * 2.6
        parts.append(second)
    if style in ("spg", "td"):
        # 长身管加一圈加强箍：越长的管子越需要，也顺便把"这门炮很贵"讲出来
        for i in range(3):
            parts.append(L.cyl("gun_band%d" % i, caliber * 1.25, 0.16,
                               loc=(0, 1.2 + i * 1.2, 0), rot=(RAD(90), 0, 0),
                               verts=12, material="M_Metal"))
    return parts


# ---------------- 整车 ----------------

def build(key, spec, out_dir):
    L.reset_scene()
    w, l, h = spec["hull"]
    style = spec["style"]
    ty, tz = spec["turret"]
    gun_len = spec["gun_len"]
    caliber = 0.17 if style != "boss" else 0.21
    if style == "spg":
        caliber = 0.15
    if style == "td":
        caliber = 0.16
    if style == "wheeled":
        caliber = 0.13

    hull_root = L.empty("Hull")

    hull_parts, _z = _hull(w, l, h, style)
    wheels, running = _running_gear(hull_root, w, l, h, spec["wheels"], style)
    hull_mesh = L.join(hull_parts + running, "HullMesh")
    L.bevel(hull_mesh, width=0.03, segments=2)
    L.dirt(hull_mesh, 0.9)
    hull_mesh.parent = hull_root

    # 炮塔/炮管的零件都是按"相对回转中心"的坐标建的，所以直接赋 parent，
    # 让当前坐标成为局部坐标；不要动 matrix_parent_inverse，也不要清零 location。
    turret_node = L.empty("Turret", loc=(0, ty, tz), parent=hull_root)
    turret_mesh = L.join(_turret(w, style), "TurretMesh")
    L.bevel(turret_mesh, width=0.028, segments=2)
    L.dirt(turret_mesh, 0.85)
    turret_mesh.parent = turret_node

    barrel_node = L.empty("Barrel", loc=(0, 0, spec["barrel"]), parent=turret_node)
    barrel_mesh = L.join(_gun(gun_len, caliber, style), "BarrelMesh")
    L.bevel(barrel_mesh, width=0.02, segments=2)
    L.dirt(barrel_mesh, 0.75)
    barrel_mesh.parent = barrel_node

    L.empty("Muzzle", loc=(0, gun_len, 0), parent=barrel_node)

    for wheel in wheels:
        L.dirt(wheel, 0.6)

    # 贴图与 UV 放在**装配完成之后**：box 投影取世界坐标，
    # 而炮塔/炮管的零件是按"相对回转中心"建的，挂到父节点之前世界坐标还不是真实位置。
    for part in (hull_mesh, turret_mesh, barrel_mesh):
        T.apply(part, key)
    for wheel in wheels:
        T.apply(wheel, key)

    L.export_glb(_p.join(out_dir, key + ".glb"), [hull_root])
    return key, L.tri_count()


def build_all(out_dir):
    return [build(key, spec, out_dir) for key, spec in D.TANKS.items()]
