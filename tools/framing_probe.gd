extends Node
## 验收：镜头尺度与墙体可读性。这一轮把相机从"10 m 高空俯视"压到
## "2.35 m 眼高、7.6 m 臂长、18° 俯角"，判据必须能量出来，否则下次调镜头
## 又会慢慢滑回"桌面沙盘"。
##
## 两个指标都不依赖截图，可以在 --headless 下跑：
##   1. tankCover —— 玩家坦克在画面里的垂直占比。取车体包围盒 8 个角投影到屏幕，
##      量最高点与最低点的像素差。判据 >= 0.35（4.4 m 的车至少占画面 35% 高）。
##   2. capShare  —— 墙体压顶石在画面中的占比。从相机按 28x16 网格发射射线，
##      统计命中"朝上的墙面"（法线朝上、高度接近 3.0 m）的比例。
##      相机压低后判据是 <= 0.10：你看到的是墙立面，不是一排墙顶。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会二次编码。

const FRAMES_PER_TERRAIN := 60
const COVER_MIN := 0.35
const CAP_MAX := 0.10
const RAY_COLS := 28
const RAY_ROWS := 16

var _terrain := 0
var _f := 0
var _rows: Array = []
var _min_cover := 1.0
var _max_cap := 0.0
var _worst_cover := ""
var _worst_cap := ""


func _main() -> Node:
	return get_node_or_null("Main")


func _ready() -> void:
	await get_tree().process_frame
	_begin(0)


func _begin(i: int) -> void:
	_terrain = i
	_f = 0
	var main := _main()
	main._sel_diff = 1
	main._sel_stage = 1
	main._sel_terrain = i
	main._confirm_start()


func _physics_process(_delta: float) -> void:
	var main := _main()
	if main == null or main.arena == null or main.player == null:
		return
	_f += 1
	if _f < FRAMES_PER_TERRAIN:
		return

	var cover := _tank_cover(main)
	var caps := _cap_share(main)
	var name: String = str(Arena.TERRAINS[_terrain]["layout"])
	print("FRAMING %-9s tankCover=%5.3f wallTop=%5.3f fov=%.1f arm=%.2f pivotY=%.2f" % [
		name, cover, caps, main.rig.cam.fov, main.rig.arm.spring_length,
		main.rig.arm.position.y,
	])
	_rows.append(name)
	if cover < _min_cover:
		_min_cover = cover
		_worst_cover = name
	if caps > _max_cap:
		_max_cap = caps
		_worst_cap = name

	if _terrain + 1 < Arena.TERRAINS.size():
		_begin(_terrain + 1)
	else:
		_summary(main)


## 车体包围盒投影后的垂直像素占比
func _tank_cover(main) -> float:
	var p = main.player
	var cam: Camera3D = main.rig.cam
	var vp := cam.get_viewport().get_visible_rect().size
	if vp.y <= 0.0:
		return 0.0
	var half_x: float = maxf(p.body_radius, 0.4)
	var half_z: float = maxf(p.body_length * 0.5, 0.4)
	var min_y := INF
	var max_y := -INF
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			for hy in [0.05, 2.45]:
				var w: Vector3 = p.global_transform * Vector3(half_x * sx, hy, half_z * sz)
				if cam.is_position_behind(w):
					continue
				var s := cam.unproject_position(w)
				min_y = minf(min_y, s.y)
				max_y = maxf(max_y, s.y)
	if min_y == INF:
		return 0.0
	return clampf((max_y - min_y) / vp.y, 0.0, 1.0)


## 屏幕网格射线里，命中"朝上的墙顶"的比例
func _cap_share(main) -> float:
	var cam: Camera3D = main.rig.cam
	var vp := cam.get_viewport().get_visible_rect().size
	var space := cam.get_world_3d().direct_space_state
	var cap := 0
	var total := 0
	for row in RAY_ROWS:
		for col in RAY_COLS:
			var sp := Vector2(
				(float(col) + 0.5) / float(RAY_COLS) * vp.x,
				(float(row) + 0.5) / float(RAY_ROWS) * vp.y)
			total += 1
			var from := cam.project_ray_origin(sp)
			var dir := cam.project_ray_normal(sp)
			var q := PhysicsRayQueryParameters3D.create(
				from, from + dir * 160.0, Tank.LAYER_WORLD)
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				continue
			var h: Vector3 = hit.position
			var n: Vector3 = hit.normal
			# 砖墙顶：法线朝上、高度在 2.5~3.4 m，且落在场地范围内
			if n.y > 0.72 and h.y > 2.5 and h.y < 3.4 \
					and absf(h.x) <= 50.0 and absf(h.z) <= 50.0:
				cap += 1
	return float(cap) / float(maxi(total, 1))


func _summary(main) -> void:
	print("FRAMING ---- summary ----")
	print("FRAMING terrains=%d coverMin=%.3f at=%s (need >= %.2f)" % [
		_rows.size(), _min_cover, _worst_cover, COVER_MIN])
	print("FRAMING wallTopMax=%.3f at=%s (need <= %.2f)" % [
		_max_cap, _worst_cap, CAP_MAX])
	var ok: bool = _min_cover >= COVER_MIN and _max_cap <= CAP_MAX
	print("FRAMING VERDICT framingOK=%s" % str(ok))
	get_tree().quit(0 if ok else 1)
