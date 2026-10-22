# -*- coding: utf-8 -*-
"""Blender 侧共享构建工具。

设计取向：全部程序化、可反复重跑、零版权风险，且不引用任何外部素材。
写实感靠四件事堆出来——
  1. 倒角 + 加权法线：让纯色金属也有硬朗的边缘高光；
  2. 脏化顶点色：把缝隙和凹陷烘进顶点色，当作免费的 AO 与边缘磨损；
  3. 程序化贴图：迷彩、拼缝、铆钉、划痕这类"片状"细节只能靠贴图承载，
     见 lib_tex.py（只挂坦克材质，世界资源保持纯色）；
  4. 统一 PBR 材质命名：Godot 侧按材质名决定哪些面刷阵营涂装。
"""

import math
import os

import bpy

# ---------------- 材质调色板 ----------------
# M_Paint / M_Accent 会被 Godot 按阵营覆写 albedo，其余材质原样使用。
PALETTE = {
    # 金属不再做成"镜面钢"：metallic 0.85 时车体的可见颜色几乎全来自天空反射，
    # 于是在车库的亮天空下，尾板、翼子板、舱盖全部读成一块块浅灰塑料。
    # 真车的轧制钢板是**粗糙的暗金属**，roughness 0.6 以上才压得住反射。
    "M_Paint":    ((0.33, 0.38, 0.30, 1.0), 0.58, 0.10),
    "M_Accent":   ((0.62, 0.52, 0.20, 1.0), 0.62, 0.05),
    "M_Metal":    ((0.105, 0.110, 0.120, 1.0), 0.62, 0.30),
    # 坦克专用的金属色。值同 M_Metal，但**只有坦克材质挂贴图**——
    # 世界资源的网格没有 UV，共享的 M_Metal 一旦被挂上贴图，
    # 墙 / 道具 / 碉堡都会退化成一个固定像素的纯色块。见 lib_tex.py。
    "M_TankMetal": ((0.24, 0.25, 0.27, 1.0), 0.58, 0.35),
    "M_DarkMetal": ((0.038, 0.038, 0.042, 1.0), 0.72, 0.30),
    "M_Rubber":   ((0.028, 0.028, 0.031, 1.0), 0.92, 0.00),
    "M_Glass":    ((0.028, 0.045, 0.062, 1.0), 0.14, 0.15),
    "M_Rust":     ((0.34, 0.17, 0.09, 1.0), 0.88, 0.25),
    # 砖墙三档色差。原来的单色砖墙在阳光下是一整片橙红，看不出砌筑层次；
    # 三档只差 10% 左右，混在一起才像"不同窑次烧出来的砖"，而不是花砖。
    # 再压一档：0.105 线性大约是 0.36 sRGB，在阳光 + 天光 + ACES 之后
    # 正好落在"旧砖"的区间；原来的 0.255（0.54 sRGB）会把整面墙读成粉砂岩。
    "M_Brick":    ((0.105, 0.070, 0.058, 1.0), 0.90, 0.00),
    "M_BrickB":   ((0.120, 0.078, 0.064, 1.0), 0.90, 0.00),
    "M_BrickC":   ((0.094, 0.064, 0.055, 1.0), 0.90, 0.00),
    # 压顶石：墙顶是第三人称视角里面积最大的受光面，颜色必须**明显暗于砖面**。
    # 0.085 线性在阳光直射 + ACES 之后仍会到 0.5 sRGB，读起来就是一条白边；
    # 压到 0.030 之后它才是"被雨淋黑的石条"，而不是盖在墙上的白纸。
    "M_Coping":   ((0.030, 0.028, 0.025, 1.0), 0.90, 0.00),
    "M_CopingB":  ((0.038, 0.035, 0.031, 1.0), 0.90, 0.00),
    "M_Mortar":   ((0.060, 0.057, 0.052, 1.0), 0.94, 0.00),
    # 混凝土 / 沙袋 / 木材同样压到真实反照率：0.22 线性是"白石膏"，
    # 在直射光下会过曝成一块白板，而真实的水泥路面只有 0.08~0.12。
    "M_Concrete": ((0.085, 0.083, 0.077, 1.0), 0.88, 0.00),
    "M_Sandbag":  ((0.115, 0.098, 0.068, 1.0), 0.92, 0.00),
    "M_Wood":     ((0.130, 0.088, 0.052, 1.0), 0.85, 0.00),
    # 帆布/热护套原来线性 0.38，转成 sRGB 约 0.65——在阳光下是一块米白，
    # 会把炮管与炮塔的剪影抢掉。压到 0.030 之后才是脏橄榄色。
    "M_Canvas":   ((0.030, 0.028, 0.022, 1.0), 0.95, 0.00),
    # 尾灯：给一个很弱的自发光，远处能读出车尾朝向，但不会像两颗霓虹灯。
    # 原来用 M_Glass（金属漆面）——它会镜面反射暖色地面，变成两块橙色方块。
    # 0.55 的自发光强度在 ACES + 泛光下仍会扩成一圈橙边；再压到 0.35、
    # 反照率收到深红，近看只是两颗暗红小灯。
    "M_TailLight": ((0.16, 0.018, 0.012, 1.0), 0.62, 0.00, 0.35),
    "M_Water":    ((0.07, 0.19, 0.27, 1.0), 0.06, 0.15),
    # 履带分上/下两支段，是为了在 Godot 侧按相反方向滚动 UV。
    # 两者颜色一致，只有名字不同——名字就是"这一支该往哪边滚"的唯一线索。
    "M_Track":    ((0.018, 0.018, 0.021, 1.0), 0.88, 0.25),
    "M_TrackLow": ((0.018, 0.018, 0.021, 1.0), 0.88, 0.25),
    # 履带板：贴在下支段上的一排凸起。它**不参与** UV 滚动——
    # 履带带面滚动时，板子本身是跟着车一起走的实体，纹理再滚一遍就成了
    # "履带在板子底下滑动"。颜色与 M_Track 完全一致，只用材质名区分。
    "M_TrackPlate": ((0.018, 0.018, 0.021, 1.0), 0.88, 0.25),
}


def reset_scene():
    """清空场景与数据块，保证每个模型都从干净状态开始生成。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for coll in (bpy.data.materials, bpy.data.meshes, bpy.data.objects):
        for item in list(coll):
            coll.remove(item)


def mat(name):
    """按调色板取（或建）材质。glTF 会把 base color/metallic/roughness 原样带给 Godot。

    PALETTE 的第四项是可选的发光强度：尾灯这类小面积主动光源需要一个底，
    否则镜面材质只会反射地面颜色，远看就是两块橙色方块。
    """
    if name in bpy.data.materials:
        return bpy.data.materials[name]
    entry = PALETTE.get(name, PALETTE["M_Metal"])
    color, rough, metal = entry[0], entry[1], entry[2]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    if bsdf is not None:
        bsdf.inputs["Base Color"].default_value = color
        bsdf.inputs["Roughness"].default_value = rough
        bsdf.inputs["Metallic"].default_value = metal
        if len(entry) > 3:
            bsdf.inputs["Emission Color"].default_value = color
            bsdf.inputs["Emission Strength"].default_value = entry[3]
    m.diffuse_color = color
    return m


def _finish(obj, material, parent):
    if material:
        obj.data.materials.append(mat(material))
    if parent is not None:
        obj.parent = parent
        obj.matrix_parent_inverse = parent.matrix_world.inverted()
    return obj


def box(name, size, loc=(0, 0, 0), rot=(0, 0, 0), material="M_Paint", parent=None):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc, rotation=rot)
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = (size[0], size[1], size[2])
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return _finish(ob, material, parent)


def wedge(name, size, loc=(0, 0, 0), rot=(0, 0, 0), taper=0.5,
          material="M_Paint", parent=None):
    """上窄下宽的梯形块。倾斜装甲、炮塔侧壁、混凝土墩都靠它。"""
    ob = box(name, size, loc=loc, rot=rot, material=material, parent=parent)
    for v in ob.data.vertices:
        if v.co.z > 0:
            v.co.x *= taper
            v.co.y *= taper
    ob.data.update()
    return ob


def cyl(name, radius, depth, loc=(0, 0, 0), rot=(0, 0, 0), verts=16,
        material="M_Metal", parent=None):
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=verts, radius=radius, depth=depth, location=loc, rotation=rot)
    ob = bpy.context.active_object
    ob.name = name
    return _finish(ob, material, parent)


def tube_y(name, radius, length, y0, verts=14, material="M_Metal", parent=None, taper=1.0):
    """沿 +Y 的圆柱（炮管、天线、管道）。taper<1 则 +Y 一端收细。

    rot 取 -90° 而非 +90°，这样局部 +Z 正好映射到世界 +Y，
    收细的那一端就是炮口而不是炮尾。
    """
    ob = cyl(name, radius, length, loc=(0, y0 + length * 0.5, 0),
             rot=(math.radians(-90), 0, 0), verts=verts,
             material=material, parent=parent)
    if taper != 1.0:
        for v in ob.data.vertices:
            if v.co.z > 0:  # 局部 +Z 即世界 +Y
                v.co.x *= taper
                v.co.y *= taper
        ob.data.update()
    return ob


def sphere(name, radius, loc=(0, 0, 0), segments=16, rings=8,
           material="M_Paint", parent=None):
    bpy.ops.mesh.primitive_uv_sphere_add(
        segments=segments, ring_count=rings, radius=radius, location=loc)
    ob = bpy.context.active_object
    ob.name = name
    return _finish(ob, material, parent)


def torus(name, major, minor, loc=(0, 0, 0), rot=(0, 0, 0), major_seg=20, minor_seg=8,
          material="M_Rubber", parent=None):
    bpy.ops.mesh.primitive_torus_add(
        major_radius=major, minor_radius=minor, major_segments=major_seg,
        minor_segments=minor_seg, location=loc, rotation=rot)
    ob = bpy.context.active_object
    ob.name = name
    return _finish(ob, material, parent)


def empty(name, loc=(0, 0, 0), parent=None):
    """控制节点。Godot 侧按名字取 Turret / Barrel / Muzzle。

    这里刻意不设 matrix_parent_inverse：loc 就是相对父节点的局部坐标，
    于是 Barrel 的 0.55 读作"炮塔原点往上 0.55"，与 tank.gd 的写法一致。
    """
    ob = bpy.data.objects.new(name, None)
    ob.empty_display_size = 0.3
    ob.location = loc
    bpy.context.collection.objects.link(ob)
    if parent is not None:
        ob.parent = parent
    return ob


# ---------------- 修形 ----------------

def bevel(obj, width=0.025, segments=2, angle=30.0):
    """倒角 + 加权法线 + 按角度平滑。

    这三步是"无贴图也像金属"的关键：倒角给边缘一条窄高光带，
    加权法线让大面保持平直、不被倒角带歪，按角度平滑保留硬转折。
    """
    m = obj.modifiers.new("Bevel", "BEVEL")
    m.width = width
    m.segments = segments
    m.limit_method = 'ANGLE'
    m.angle_limit = math.radians(angle)
    m.harden_normals = True
    m.miter_outer = 'MITER_ARC'
    wn = obj.modifiers.new("WeightedNormal", "WEIGHTED_NORMAL")
    wn.keep_sharp = True
    _activate(obj)
    bpy.ops.object.shade_smooth()
    bpy.ops.object.shade_auto_smooth(angle=math.radians(angle))
    bpy.ops.object.modifier_apply(modifier="Bevel")
    bpy.ops.object.modifier_apply(modifier="WeightedNormal")


def _activate(obj):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def bake(obj, loc=False, rot=True, scale=True):
    """把旋转/缩放烘进顶点，让物体的局部坐标轴回到世界轴向。

    负重轮必须这么做：Godot 侧是直接改 `wheel.rotation.x` 来滚动的，
    物体自身若还带着 90° 的摆放旋转，赋值会把摆放姿态一起冲掉。
    """
    _activate(obj)
    bpy.ops.object.transform_apply(location=loc, rotation=rot, scale=scale)
    return obj


def dirt(obj, strength=0.9, blur=1):
    """脏化顶点色：凹处压暗、凸边提亮，等于把 AO 与磨损烘进顶点色。

    Godot 的 glTF 导入器见到 COLOR_0 会自动打开 vertex_color_use_as_albedo，
    于是这层信息零成本地叠在 PBR 材质上。
    """
    me = obj.data
    if not me.color_attributes:
        me.color_attributes.new(name="Col", type='BYTE_COLOR', domain='CORNER')
    _activate(obj)
    try:
        bpy.ops.paint.vertex_color_dirt(
            blur_strength=1.0, blur_iterations=blur, clean_angle=math.pi,
            dirt_angle=0.0, dirt_only=False)
        if strength < 1.0:
            _fade_colors(me, strength)
    except RuntimeError:
        pass


def _fade_colors(me, strength):
    layer = me.color_attributes.active_color
    if layer is None:
        return
    for d in layer.data:
        c = d.color
        d.color = (
            1.0 + (c[0] - 1.0) * strength,
            1.0 + (c[1] - 1.0) * strength,
            1.0 + (c[2] - 1.0) * strength,
            c[3],
        )


def join(objs, name):
    """合并为单一网格，保留各自材质槽（Godot 侧仍是多 surface）。"""
    objs = [o for o in objs if o is not None and o.type == 'MESH']
    if not objs:
        return None
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    ob = bpy.context.active_object
    ob.name = name
    return ob


# ---------------- 统计与导出 ----------------

def tri_count(objs=None):
    total = 0
    for o in (objs if objs is not None else bpy.data.objects):
        if o.type != 'MESH':
            continue
        total += sum(len(p.vertices) - 2 for p in o.data.polygons)
    return total


def export_glb(path, roots=None):
    """导出整场景为 GLB。roots 非空时只导出这些对象及其子树。"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.object.select_all(action='DESELECT')
    if roots:
        for r in roots:
            _select_tree(r)
        bpy.context.view_layer.objects.active = roots[0]
    else:
        bpy.ops.object.select_all(action='SELECT')
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format='GLB',
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_materials='EXPORT',
        export_vertex_color='ACTIVE',
        export_cameras=False,
        export_lights=False,
        export_animations=False,
    )
    return path


def _select_tree(obj):
    obj.select_set(True)
    for c in obj.children:
        _select_tree(c)
