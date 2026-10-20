# -*- coding: utf-8 -*-
"""坦克表面贴图：程序化生成 + 三平面（box）UV 投影。

为什么"纯色 + 顶点脏化"不够
--------------------------
顶点色只能在**有顶点的地方**发生变化，而坦克的大平板往往只有四个角顶点。
于是"迷彩""油污""焊缝"这类**片状**信息在几何上根本没有落脚点，除非把平板细分，
而细分会把三角面预算顶穿。贴图不受这个限制：它按面积采样，
同样的面数因此能承载远超顶点数的细节。

三条约束决定了这里的实现方式
----------------------------
1. **不引入外部素材**：贴图和几何一样由 numpy 程序化生成，可反复重跑、零版权风险。
   生成结果按文件名缓存到 tex_cache/，改动生成器时必须抬 VERSION 让缓存失效。
2. **UV 必须自洽**：程序化几何没有 UV。这里按面法线主轴做 box 投影，
   取另外两个世界坐标当 UV，并统一除以 TILE（米）——于是无论哪个部件、
   哪一面朝向，同一米上的纹理密度都相同，跨部件才看不出接缝。
3. **M_Paint 仍要能被阵营涂装覆写**：Godot 的 `albedo_color` 与 albedo 贴图是**相乘**的。
   所以 M_Paint 的贴图刻意画成近白的"明度细节图"——迷彩是 0.74 的**暗斑**而不是绿斑，
   阵营色乘上去之后才得到"带迷彩与焊缝的阵营绿"。若把颜色烘进贴图，
   阵营涂装就会退化成二次染色，山猫的黄和猎手的白都会糊掉。

材质与贴图的对应
----------------
    M_Paint      迷彩 / 拼缝 / 铆钉 / 焊缝 / 掉漆 / 流痕   （明度图，供阵营色相乘）
    M_TankMetal  钢色 / 轧制纹 / 划痕 / 油污                （颜色烘在贴图里）
其余材质一律不贴图：M_DarkMetal 及以下颜色太深，细节看不见，只会白白撑大包体。

**贴图只挂坦克材质，且为此新增了 M_TankMetal。** 因为世界资源的网格（墙 / 道具 / 碉堡）
没有 UV，若直接给共享的 M_Metal 挂贴图，那些模型会全部退化成一个固定像素的纯色块。
新增一个材质名，代价远小于"给整个世界补 UV 并各自背一套贴图"。

坐标约定：数组 row 0 = 图像顶部（写盘时统一翻转成 Blender 的自下而上）。
"""

import hashlib
import math
import os

import bpy
import numpy as np

import lib_build as L

# ---------------- 常量 ----------------

_HERE = os.path.dirname(os.path.abspath(__file__))
TEX_DIR = os.path.join(_HERE, "tex_cache")

# 生成器一改，缓存必须失效，否则会拿着旧图当新图用
VERSION = "v3"

## 一个 UV 单位对应多少米。全部件共用，贴图才可能跨部件对齐。
TILE = 2.0

## 主装甲面积最大、最常入镜，只有它给 1024；其余 512 就够。
SIZE_PAINT = 1024
SIZE_METAL = 512

## 贴图分组：一组三张（albedo / normal / orm）
_PAINT = "tex_paint"
_METAL = "tex_metal"


# ---------------- 可平铺噪声 ----------------
#
# 全部可平铺：格点索引取模、Sobel 用 np.roll 环绕，于是贴图在 UV 边界处天然无缝。
# 换成不可平铺的噪声，车体上会浮出一整片格子状的接缝。

def _noise(rng, size, cells):
    """value noise。cells 个格点铺满整张图，双线性 + smoothstep 插值。"""
    cells = max(2, int(cells))
    g = rng.random((cells, cells))
    t = np.arange(size, dtype=np.float64) * (cells / size)
    i0 = np.floor(t).astype(np.int64) % cells
    i1 = (i0 + 1) % cells
    f = t - np.floor(t)
    f = f * f * (3.0 - 2.0 * f)              # smoothstep，否则会看到格点棱线
    fy, fx = f[:, None], f[None, :]
    r0, r1 = i0[:, None], i1[:, None]
    c0, c1 = i0[None, :], i1[None, :]
    v00, v01 = g[r0, c0], g[r0, c1]
    v10, v11 = g[r1, c0], g[r1, c1]
    a = v00 + (v01 - v00) * fx
    b = v10 + (v11 - v10) * fx
    return a + (b - a) * fy


def _fbm(rng, size, cells=2, octaves=4, gain=0.5):
    out = np.zeros((size, size), np.float64)
    amp, total, c = 1.0, 0.0, cells
    for _ in range(octaves):
        out += amp * _noise(rng, size, c)
        total += amp
        amp *= gain
        c *= 2
    return out / total


def _smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# ---------------- 结构线 ----------------

def _axis_phase(size, periods):
    return (np.arange(size, dtype=np.float64) / size * periods) % 1.0


def _axis_dist(size, periods, phase):
    """到最近一条结构线的距离，单位是 UV（也就是 TILE 米的几分之一）。"""
    coord = (_axis_phase(size, periods) + phase) % 1.0
    return np.minimum(coord, 1.0 - coord) / periods


def _line_of(dist, width_uv):
    """由距离场得到带软边的线掩码：1 = 缝心。"""
    return np.clip(1.0 - dist / (width_uv * 0.5), 0.0, 1.0)


def _height_to_normal(h, strength):
    """高度场 → 切线空间法线。np.roll 环绕，所以法线图同样无缝。

    符号不能想当然：高度场 h(u,v) 的表面是 (u, v, h)，两个切向是
    (1,0,∂h/∂u) 与 (0,1,∂h/∂v)，叉乘得到 N = (-∂h/∂u, -∂h/∂v, 1)。
    两个分量都要**取负**。漏了负号，凹槽会渲染成凸起、铆钉会渲染成凹坑——
    画面上表现为"缝是亮线而不是暗线"，而且不会有任何报错。

    行/列到 (u,v) 的映射：数组 row 0 = 图像顶部、col 0 = 图像左侧，
    而 UV 的 v=0 在图像底部，于是 ∂h/∂v = -∂h/∂row、∂h/∂u = +∂h/∂col。
    合起来：Nx ∝ -列梯度、Ny ∝ +行梯度。
    """
    gc = np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)     # 沿列（u）
    gr = np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)     # 沿行（v 的反向）
    nx = -gc * strength
    ny = gr * strength
    nz = np.ones_like(h)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    return np.stack([nx / ln * 0.5 + 0.5,
                     ny / ln * 0.5 + 0.5,
                     nz / ln * 0.5 + 0.5], axis=2)


def _lin_to_srgb(c):
    """线性反照率 → sRGB。调色板里存的是线性值，写进 sRGB 贴图前必须转，
    否则钢件会比原来暗一大截。"""
    c = np.asarray(c, np.float64)
    return np.where(c <= 0.0031308, c * 12.92,
                    1.055 * np.power(np.maximum(c, 0.0), 1.0 / 2.4) - 0.055)


def _panel(size, seed, period_x, period_y, width_uv, rivet_pitch, rivet_r,
           wobble=0.30, band_uv=0.022):
    """一组结构线：拼缝 / 铆钉 / 焊缝。颜色与法线共用同一组掩码，两边才对得上。

    **线不平直、也不完整**，这一点是"像装甲"和"像贴图网格"的分界：
      * 相位被一层低频噪声横向推动，缝因此缓慢起伏——真实钢板下料与焊接都有变形，
        笔直的等距缝在车体上会立刻读成格子纸；
      * 再乘一层二维噪声掩码，让缝断断续续，只有局部真的焊接在一起。
    返回的 hz 也已经是二维的：既然线会摆动，它就不再是"按行等距"的一维量了。
    """
    rng = np.random.default_rng(seed)
    # 1D 摆动量：从可平铺的二维噪声里取一行/一列，于是它自己也是周期的
    wob_u = (_noise(rng, size, 3)[0, :] - 0.5) * wobble * period_x      # (size,)
    wob_v = (_noise(rng, size, 3)[:, 0] - 0.5)[:, None] * wobble * period_y

    # 横缝：位置随**列**摆动（(size,1) 的相位广播到 (1,size) 的摆动上）
    cu = (_axis_phase(size, period_x) + 0.17)[:, None] + wob_u[None, :]
    cu %= 1.0
    dh = np.minimum(cu, 1.0 - cu) / period_x
    # 竖缝：位置随**行**摆动
    cv = (_axis_phase(size, period_y) + 0.41)[None, :] + wob_v
    cv %= 1.0
    dv = np.minimum(cv, 1.0 - cv) / period_y

    brk = _smoothstep(0.34, 0.50, _fbm(rng, size, cells=4, octaves=2))
    hz = _line_of(dh, width_uv) * brk
    vt = _line_of(dv, width_uv) * brk
    seam = np.clip(hz + vt, 0.0, 1.0)

    # 铆钉排：点阵 × "离缝两个厘米以内"的宽带。这条带必须由距离场算，
    # 线掩码只有一点几厘米宽，铆钉会被裁成一条细线。
    band = np.clip(1.0 - np.minimum(dh, dv) / band_uv, 0.0, 1.0)
    ru = _axis_dist(size, 1.0 / rivet_pitch, 0.23)[:, None]
    rv = _axis_dist(size, 1.0 / rivet_pitch, 0.61)[None, :]
    # 用真实的径向距离，而不是把两个方向的掩码相乘——相乘出来的是**方头**铆钉
    rr = np.sqrt(ru * ru + rv * rv)
    rivet = band * np.clip(1.0 - rr / (rivet_r * 0.5), 0.0, 1.0) * brk
    # 焊缝：只在部分缝上出现。真实车体也不是每条缝都焊。
    weld = seam * _smoothstep(0.52, 0.62, _fbm(rng, size, cells=3, octaves=2))
    return seam, hz, rivet, weld


def _scratches(size, rng, count, thin, wide):
    """随机方向与长度的划痕。

    数量和长度都要克制：金属件上密布亮线不会读成"被用过"，只会读成"贴图坏了"。
    起点刻意缩在画面中部 70% 内、长度也留了余量，于是绝大多数划痕不会碰到贴图
    边界——碰到边界的那几条会被硬切一刀，而硬切的断口在同一高度反复出现，
    就会看出"平铺"这件事。这样比给每条划痕做四次环绕便宜得多。
    """
    layer = np.zeros((size, size), np.float32)
    px = np.arange(size, dtype=np.float32)[None, :]
    py = np.arange(size, dtype=np.float32)[:, None]
    for _ in range(count):
        ang = rng.random() * math.pi
        ca, sa = math.cos(ang), math.sin(ang)
        x0 = size * (0.15 + rng.random() * 0.70)
        y0 = size * (0.15 + rng.random() * 0.70)
        ln = size * (0.02 + rng.random() * 0.10)
        w = thin + rng.random() * wide
        ddx, ddy = px - x0, py - y0
        along = ddx * ca + ddy * sa
        across = np.abs(-ddx * sa + ddy * ca)
        m = np.clip(1.0 - across / w, 0.0, 1.0)
        m *= ((along >= 0.0) & (along <= ln)).astype(np.float32)
        layer = np.maximum(layer, m.astype(np.float32))
    return layer


# ---------------- 主装甲 ----------------

def _paint_maps():
    n = SIZE_PAINT
    rng = np.random.default_rng(20261019)

    seam, hz, rivet, weld = _panel(n, 4711, 2.0, 2.5, 0.014, 0.045, 0.017)
    grain = _fbm(rng, n, cells=64, octaves=3)

    # --- 迷彩：两级阈值的斑块。只压暗、不染色，阵营色乘上来才是本阵营的迷彩 ---
    big = _fbm(rng, n, cells=2, octaves=4)
    mid = _fbm(rng, n, cells=4, octaves=4)
    alb = np.ones((n, n, 3), np.float64)
    c_cool = np.array([0.74, 0.73, 0.70])       # 冷灰斑
    c_warm = np.array([0.89, 0.85, 0.77])       # 暖褐斑
    alb = np.where((big > 0.55)[:, :, None], c_cool, alb)
    alb = np.where(((big <= 0.55) & (mid > 0.57))[:, :, None], c_warm, alb)

    # --- 拼缝与铆钉 ---
    alb *= (1.0 - 0.52 * seam)[:, :, None]
    alb = np.where(rivet[:, :, None] > 0.4, alb * 0.66, alb)
    alb = np.where(weld[:, :, None] > 0.2, alb * 0.82, alb)

    # --- 掉漆划痕：擦到接近底漆的亮度 ---
    scratch = _scratches(n, rng, 55, 1.0, 1.6)
    alb = np.where(scratch[:, :, None] > 0.5, (0.96, 0.95, 0.93), alb)

    # --- 流痕与积灰：从横缝向下拖出的暗纹，再靠噪声打断成断续的条 ---
    grime = _streaks(n, hz, 1.0)
    grime = grime * _smoothstep(0.45, 0.62, _fbm(rng, n, cells=6, octaves=3))
    alb *= (1.0 - 0.22 * grime)[:, :, None]

    # --- 细颗粒：让大平面在近距离下不是一片死平 ---
    alb *= (0.965 + 0.07 * grain)[:, :, None]
    alb = np.clip(alb, 0.0, 1.0)

    # --- 法线：同一组结构线当高度场。缝是凹槽，铆钉与焊缝是凸起 ---
    h = np.full((n, n), 0.5, np.float64)
    h -= 0.60 * seam
    h += 0.22 * rivet
    h += 0.14 * weld
    h += 0.05 * grain
    nrm = _height_to_normal(h, 1.6)

    # --- ORM：R=遮蔽（本项目不用，给 1）、G=粗糙度、B=金属度 ---
    orm = np.ones((n, n, 3), np.float64)
    rough = 0.62 + 0.20 * (_fbm(rng, n, cells=8, octaves=3) - 0.5)
    rough -= 0.16 * scratch              # 擦痕露出的底漆更光滑
    orm[:, :, 1] = np.clip(rough, 0.15, 0.95)
    orm[:, :, 2] = 0.05
    return alb, nrm, orm


def _streaks(size, source, gain=1.0, span=40):
    """把横缝向下拖成流痕。坦克上的竖向污迹几乎都来自上方的积水与排气。"""
    acc = np.zeros_like(source)
    for k in range(1, span):
        acc = np.maximum(acc, np.roll(source, k, axis=0) * (1.0 - k / float(span)))
    return acc * gain


# ---------------- 金属件 ----------------

def _metal_maps():
    n = SIZE_METAL
    rng = np.random.default_rng(20261020)

    seam, hz, rivet, weld = _panel(n, 90210, 1.5, 2.0, 0.016, 0.05, 0.018)
    grain = _fbm(rng, n, cells=48, octaves=3)

    # 颜色烘进贴图：M_TankMetal 的 Base Color 因此留白，不会和因子二次相乘
    base = _lin_to_srgb(L.PALETTE["M_Metal"][0][:3])
    alb = np.ones((n, n, 3), np.float64) * base

    # 轧制纹：把竖向相邻几行平均掉，得到横向拉长的各向异性，像钢板的轧制方向
    roll = _fbm(rng, n, cells=24, octaves=3)
    roll = (roll + np.roll(roll, 1, axis=0) + np.roll(roll, 2, axis=0)) / 3.0
    alb *= (0.94 + 0.12 * roll)[:, :, None]

    alb *= (1.0 - 0.45 * seam)[:, :, None]
    alb = np.where(rivet[:, :, None] > 0.4, alb * 0.72, alb)

    # 划痕露出的裸钢比氧化层亮
    scratch = _scratches(n, rng, 18, 0.7, 1.0)
    alb = np.where(scratch[:, :, None] > 0.5, np.minimum(base * 1.45, 1.0), alb)

    # 油污与锈斑：向暗褐**插值**，而不是只把红通道抬上去——
    # 抬高红通道会把中性灰直接染成粉色，看起来像印花布而不是油泥。
    smudge = _smoothstep(0.55, 0.78, _fbm(rng, n, cells=7, octaves=4))
    alb = alb * (1.0 - 0.45 * smudge)[:, :, None] + \
        np.array([0.34, 0.30, 0.26]) * (0.45 * smudge)[:, :, None]
    alb *= (0.96 + 0.08 * grain)[:, :, None]
    alb = np.clip(alb, 0.0, 1.0)

    h = np.full((n, n), 0.5, np.float64)
    h -= 0.55 * seam
    h += 0.20 * rivet
    h += 0.10 * weld
    h += 0.045 * grain
    nrm = _height_to_normal(h, 1.4)

    orm = np.ones((n, n, 3), np.float64)
    rough = 0.38 + 0.32 * (_fbm(rng, n, cells=9, octaves=3) - 0.5)
    rough -= 0.14 * scratch
    rough += 0.30 * smudge
    orm[:, :, 1] = np.clip(rough, 0.12, 0.98)
    orm[:, :, 2] = 0.90
    return alb, nrm, orm


# ---------------- 落盘与装配 ----------------

def _write_png(path, arr):
    h, w = arr.shape[:2]
    rgba = np.ones((h, w, 4), np.float32)
    rgba[:, :, :3] = np.clip(arr, 0.0, 1.0)
    img = bpy.data.images.new("_tex_tmp", width=w, height=h, alpha=False)
    # Blender 的 pixels 是**自下而上**的行序，所以写盘前翻转一次，
    # 让生成器里 row 0 = 图像顶部。
    img.pixels.foreach_set(np.flipud(rgba).reshape(-1))
    img.filepath_raw = path
    img.file_format = 'PNG'
    img.save()
    bpy.data.images.remove(img)


def _image(group, kind, arr, colorspace):
    name = "%s_%s_%s" % (group, kind, VERSION)
    path = os.path.join(TEX_DIR, name + ".png")
    if not os.path.exists(path):
        os.makedirs(TEX_DIR, exist_ok=True)
        _write_png(path, arr)
    # 缓存命中时从磁盘读回：reset_scene() 会把 bpy.data 清空，于是每台车都要重新装载，
    # 而不是重新生成。生成一遍 1024 的迷彩要一两秒，七台车就是十几秒。
    img = bpy.data.images.load(path, check_existing=True)
    img.colorspace_settings.name = colorspace
    return img


def _maps(group):
    alb_arr, nrm_arr, orm_arr = _paint_maps() if group == _PAINT else _metal_maps()
    return (
        _image(group, "albedo", alb_arr, 'sRGB'),
        _image(group, "normal", nrm_arr, 'Non-Color'),
        _image(group, "orm", orm_arr, 'Non-Color'),
    )


def _wire(name, group, normal_strength):
    """把一组贴图接到材质的 Principled BSDF 上。

    Base Color 的默认值刻意留白：贴图里已经带了该有的颜色（M_Paint 是近白细节图，
    M_TankMetal 是烘好的钢色），留白才能保证"因子 × 贴图"不会二次压暗。
    这样无论导出器是否把因子写进 glTF，结果都一样——不依赖它的实现细节。
    """
    m = L.mat(name)
    nt = m.node_tree
    nt.nodes.clear()

    out = nt.nodes.new("ShaderNodeOutputMaterial")
    out.location = (620, 0)
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (280, 0)
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    bsdf.inputs["Base Color"].default_value = (1.0, 1.0, 1.0, 1.0)

    alb, nrm, orm = _maps(group)

    ta = nt.nodes.new("ShaderNodeTexImage")
    ta.image = alb
    ta.location = (-280, 220)
    nt.links.new(ta.outputs["Color"], bsdf.inputs["Base Color"])

    tn = nt.nodes.new("ShaderNodeTexImage")
    tn.image = nrm
    tn.location = (-280, -40)
    nm = nt.nodes.new("ShaderNodeNormalMap")
    nm.location = (20, -40)
    nm.inputs["Strength"].default_value = normal_strength
    nt.links.new(tn.outputs["Color"], nm.inputs["Color"])
    nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])

    # glTF 的 ORM 约定：G=粗糙度、B=金属度、R=遮蔽。用 Separate Color 拆出来，
    # 导出器认得这个形状，会把它压成一张 metallicRoughnessTexture。
    to = nt.nodes.new("ShaderNodeTexImage")
    to.image = orm
    to.location = (-280, -320)
    sep = nt.nodes.new("ShaderNodeSeparateColor")
    sep.location = (20, -320)
    nt.links.new(to.outputs["Color"], sep.inputs["Color"])
    nt.links.new(sep.outputs["Green"], bsdf.inputs["Roughness"])
    nt.links.new(sep.outputs["Blue"], bsdf.inputs["Metallic"])

    # 兜底：万一导出器没认出上面的形状，这两个因子就是最终值
    bsdf.inputs["Roughness"].default_value = float(L.PALETTE[name][1])
    bsdf.inputs["Metallic"].default_value = float(L.PALETTE[name][2])
    return m


def _retarget_metal(obj):
    """把车上的 M_Metal 换成坦克专用的 M_TankMetal。"""
    for slot in obj.material_slots:
        m = slot.material
        if m is None:
            continue
        if m.name == "M_Metal" or m.name.startswith("M_Metal."):
            slot.material = L.mat("M_TankMetal")


def _uv_offset(key):
    """每台车给一个不同的平铺相位：斑块与污迹的位置因此各不相同。
    不必为五台车烘五套贴图，也不会出现"两台车迷彩一模一样"。"""
    h = int(hashlib.md5(key.encode("utf-8")).hexdigest()[:8], 16)
    return (h % 977) / 977.0, ((h // 977) % 991) / 991.0


def _box_uv(obj, offset):
    """按面法线主轴做 box 投影，取另外两个**世界**坐标当 UV。

    用世界坐标而不是局部坐标：炮塔与炮管的零件是按"相对各自装配原点"的坐标建的，
    直接拿来做 UV 会让它们的纹理密度与车体对不上。
    """
    me = obj.data
    if not me.uv_layers:
        me.uv_layers.new(name="UVMap")
    uv = me.uv_layers.active.data
    mw = obj.matrix_world
    co = [mw @ v.co for v in me.vertices]
    nmat = mw.to_3x3().inverted().transposed()
    ox, oy = offset
    for poly in me.polygons:
        nrm = nmat @ poly.normal
        ax, ay, az = abs(nrm.x), abs(nrm.y), abs(nrm.z)
        if az >= ax and az >= ay:
            iu, iv = 0, 1
        elif ax >= ay:
            iu, iv = 1, 2
        else:
            iu, iv = 0, 2
        for li in poly.loop_indices:
            p = co[me.loops[li].vertex_index]
            uv[li].uv = (p[iu] / TILE + ox, p[iv] / TILE + oy)


def _ensure_materials():
    _wire("M_Paint", _PAINT, 0.90)
    _wire("M_TankMetal", _METAL, 0.80)


def apply(obj, key):
    """给一辆车的某个网格补 UV，并把坦克材质接上贴图。

    必须在**装配完成之后**调用：box 投影取世界坐标，而炮塔/炮管的零件是按
    "相对回转中心"建的，挂到父节点之前它们的世界坐标并不是战场上的真实位置。
    """
    if obj is None or obj.type != 'MESH':
        return
    _retarget_metal(obj)
    _box_uv(obj, _uv_offset(key))
    _ensure_materials()
