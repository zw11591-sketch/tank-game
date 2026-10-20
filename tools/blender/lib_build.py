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
    "M_Paint":    ((0.33, 0.38, 0.30, 1.0), 0.58, 0.10),
    "M_Accent":   ((0.85, 0.70, 0.22, 1.0), 0.45, 0.25),
    "M_Metal":    ((0.26, 0.27, 0.29, 1.0), 0.38, 0.90),
    # 坦克专用的金属色。值同 M_Metal，但**只有坦克材质挂贴图**——
    # 世界资源的网格没有 UV，共享的 M_Metal 一旦被挂上贴图，
    # 墙 / 道具 / 碉堡都会退化成一个固定像素的纯色块。见 lib_tex.py。
    "M_TankMetal": ((0.26, 0.27, 0.29, 1.0), 0.38, 0.90),
    "M_DarkMetal": ((0.13, 0.13, 0.14, 1.0), 0.50, 0.80),
    "M_Rubber":   ((0.055, 0.055, 0.06, 1.0), 0.92, 0.00),
    "M_Glass":    ((0.07, 0.11, 0.14, 1.0), 0.08, 0.40),
    "M_Rust":     ((0.34, 0.17, 0.09, 1.0), 0.88, 0.25),
    "M_Brick":    ((0.47, 0.22, 0.14, 1.0), 0.90, 0.00),
    "M_Mortar":   ((0.55, 0.52, 0.47, 1.0), 0.88, 0.00),
    "M_Concrete": ((0.47, 0.46, 0.43, 1.0), 0.82, 0.00),
    "M_Sandbag":  ((0.52, 0.45, 0.30, 1.0), 0.90, 0.00),
    "M_Wood":     ((0.35, 0.24, 0.14, 1.0), 0.85, 0.00),
    "M_Canvas":   ((0.38, 0.36, 0.28, 1.0), 0.93, 0.00),
    "M_Water":    ((0.07, 0.19, 0.27, 1.0), 0.06, 0.15),
}


def reset_scene():
    """清空场景与数据块，保证每个模型都从干净状态开始生成。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for coll in (bpy.data.materials, bpy.data.meshes, bpy.data.objects):
        for item in list(coll):
            coll.remove(item)


def mat(name):
    """按调色板取（或建）材质。glTF 会把 base color/metallic/roughness 原样带给 Godot。"""
    if name in bpy.data.materials:
        return bpy.data.materials[name]
    color, rough, metal = PALETTE.get(name, PALETTE["M_Metal"])
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    if bsdf is not None:
        bsdf.inputs["Base Color"].default_value = color
        bsdf.inputs["Roughness"].default_value = rough
        bsdf.inputs["Metallic"].default_value = metal
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
