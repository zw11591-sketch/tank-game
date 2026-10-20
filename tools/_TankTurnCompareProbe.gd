extends Node
## 临时诊断：五款车在"单格走廊原地转 / 贴墙磨 / 撞墙"三种工况下的实际转角与压入深度。
## 不经过 Main 的状态机，直接造 Arena + Player。打印标签全用 ASCII。

const STEP := 1.0 / 120.0

var _a: Arena
var _g: Node
var _p: Player


func _ready() -> void:
	_g = Node.new()
	_g.set("state", "play")
	add_child(_g)
	_a = Arena.new()
	_a.game = _g
	add_child(_a)
	_a.generate(1, 0)
	await _frames(2)

	for id in TankRoster.ORDER:
		_clear()
		_a._rebuild_all()
		await _frames(1)
		_p = Player.new()
		_p.tank_id = id
		_p.setup(_g, _a, Arena.cell_center(12, 12))
		add_child(_p)
		await _frames(2)
		_p.shield_t = 0.0
		_p.set_physics_process(false)
		print("PROBE === %s turn=%.1f hull=(%.2f x %.2f..%.2f)" % [
			id, _p.turn_speed, _p._hull_half_w, _p._hull_half_f, _p._hull_half_b])
		await _corridor_pivot()
		await _wall_grind()
		await _ram()
		_p.queue_free()
		await _frames(2)
	get_tree().quit(0)


## 单格宽（4 m）走廊里原地打舵
func _corridor_pivot() -> void:
	_clear()
	for y in range(2, 24):
		_a.grid[y][11] = Arena.BRICK
		_a.grid[y][13] = Arena.BRICK
	_a._rebuild_all()
	_reset(Arena.cell_center(12, 12), 0.0)
	var worst := 0.0
	for i in 240:
		_p.drive(0.0, 1.0, STEP)
		worst = maxf(worst, _rect_depth())
	print("PROBE  pivot yaw=%.1f deep=%.3f" % [rad_to_deg(_p.rotation.y), worst])


## 贴着单侧墙、油门+舵到底
func _wall_grind() -> void:
	_clear()
	for y in range(2, 24):
		_a.grid[y][12] = Arena.BRICK
	_a._rebuild_all()
	var face: float = Arena.cell_center(12, 12).x - Arena.CELL * 0.5
	_reset(Vector3(face - _p._hull_half_w - 0.02, 0.0, Arena.cell_center(6, 4).z), 0.0)
	var worst := 0.0
	for i in 480:
		_p.drive(1.0, 1.0, STEP)
		worst = maxf(worst, _rect_depth())
	print("PROBE  grind yaw=%.1f deep=%.3f z=%.1f" % [
		rad_to_deg(_p.rotation.y), worst, _p.global_position.z])


## 正对墙全速撞
func _ram() -> void:
	_clear()
	for x in range(2, 24):
		_a.grid[6][x] = Arena.BRICK
	_a._rebuild_all()
	_reset(Arena.cell_center(12, 12), 0.0)
	var worst := 0.0
	for i in 360:
		_p.drive(1.0, 0.0, STEP)
		worst = maxf(worst, _rect_depth())
	print("PROBE  ram deep=%.3f z=%.1f" % [worst, _p.global_position.z])


func _reset(pos: Vector3, yaw: float) -> void:
	_p.global_position = pos
	_p.rotation.y = yaw
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = pos


func _clear() -> void:
	if _a == null:
		return
	for n in _a._blocks.values():
		n.queue_free()
	_a._blocks.clear()
	_a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			_a.grid[y][x] = Arena.EMPTY


func _rect_depth() -> float:
	var yaw: float = _p.rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var off := (_p._hull_half_f - _p._hull_half_b) * 0.5
	var center: Vector3 = _p.global_position + fwd * off
	var hl := (_p._hull_half_f + _p._hull_half_b) * 0.5
	var deep := 0.0
	for iz in 7:
		for ix in 7:
			var u := (float(ix) / 6.0 - 0.5) * 2.0
			var w := (float(iz) / 6.0 - 0.5) * 2.0
			var pt: Vector3 = center + right * (u * _p._hull_half_w) + fwd * (w * hl)
			var c := Arena.to_cell(pt)
			if not _a.blocks_tank(c.x, c.y):
				continue
			var cc := Arena.cell_center(c.x, c.y)
			var half := Arena.CELL * 0.5
			deep = maxf(deep, minf(half - absf(pt.x - cc.x), half - absf(pt.z - cc.z)))
	return deep


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
