extends Node
## 临时诊断：在本局地图上，每台车"在原地最多能转多少度"的分布。
## 对每个空格中心、8 个起始朝向，按 5° 步进转到底（用与 _limit_turn 相同的判据）。
## 打印全用 ASCII。

const STEP_DEG := 5.0
const YAW_N := 8

var _main: Node
var _a: Arena
var _p: Player


func _ready() -> void:
	await get_tree().process_frame
	_main = get_node("Main")
	_main._sel_tank = 2
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()
	await get_tree().process_frame
	_main.state = "play"
	_main.state_timer = 1.0e9
	_main.spawn_queue.clear()
	_main.max_active = 0
	for e in _main.enemies.duplicate():
		e.queue_free()
		_main.enemies.erase(e)
	_p = _main.player
	_p.shield_t = 0.0
	_p.set_physics_process(false)
	_a = _main.arena
	await _frames(4)

	for tank in [["anvil", 2], ["lynx", 0]]:
		await _measure(String(tank[0]), int(tank[1]))
	get_tree().quit(0)


func _measure(tag: String, sel: int) -> void:
	# 换车要重建 Player，直接改尺寸字段：判据只用到 _hull_* 与 arena
	var dims := {
		"anvil": Vector3(1.94, 2.87, 2.88),
		"lynx": Vector3(1.65, 2.37, 2.28),
	}
	var d: Vector3 = dims[tag]
	_p._hull_half_w = d.x
	_p._hull_half_f = d.y
	_p._hull_half_b = d.z
	_p._hull_half_l = (d.y + d.z) * 0.5

	var hist := [0, 0, 0, 0, 0, 0]   # <10,10-25,25-45,45-90,90-180,>=180
	var cells := 0
	var sum := 0.0
	for y in range(2, Arena.GRID_H - 2):
		for x in range(2, Arena.GRID_W - 2):
			if _a.blocks_tank(x, y):
				continue
			var pos := Arena.cell_center(x, y)
			cells += 1
			var total := 0.0
			for k in YAW_N:
				var yaw := TAU * float(k) / float(YAW_N)
				var got := _max_turn(pos, yaw)
				total += got
			var avg := rad_to_deg(total / float(YAW_N))
			sum += avg
			if avg < 10.0:
				hist[0] += 1
			elif avg < 25.0:
				hist[1] += 1
			elif avg < 45.0:
				hist[2] += 1
			elif avg < 90.0:
				hist[3] += 1
			elif avg < 180.0:
				hist[4] += 1
			else:
				hist[5] += 1
	print("PROBE pivot %-6s cells=%d mean=%.1fdeg  <10:%d 10-25:%d 25-45:%d 45-90:%d 90-180:%d >=180:%d" % [
		tag, cells, sum / maxf(float(cells), 1.0),
		hist[0], hist[1], hist[2], hist[3], hist[4], hist[5]])


## 从 yaw 开始，按 5° 步进能连续转过多大角度（任一步不可行就停）
func _max_turn(pos: Vector3, yaw0: float) -> float:
	var yaw := yaw0
	var total := 0.0
	for i in 36:
		var nxt := yaw + deg_to_rad(STEP_DEG)
		if _p._resolved_depth(pos, nxt) > 0.03:
			break
		yaw = nxt
		total += deg_to_rad(STEP_DEG)
	return total


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
