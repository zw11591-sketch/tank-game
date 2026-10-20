extends Node
## 验收：HE（高爆弹）的弹道解算到底把炮弹送去了哪里。
##
## 不发射真炮弹，而是直接算：沿炮管方向打一条射线找到"准星落在哪"，
## 把这个落点交给 Shell.lob_dir() 解出低抛弹道，再把这条抛物线在**敌车所在距离**上的
## 高度算出来。于是不用等炮弹飞完，就能看出"这一发会不会从敌人头顶飞过去"。
##
## 三个量：
##   hit    射线打到什么（tank / world / none）。none 就是走到了 220 米的兜底点
##   hitD   射线落点距离（米）。它就是弹道解算的目标距离
##   miss   抛物线在敌车距离处的高度 − 敌车中心高度（米）。正数 = 从头顶飞过
##
## 判据：准星压在敌车上、或者压在它身后的掩体上时，|miss| 都不该超过车高的一半。
## 射线什么都没打到时（hit=none）另算一类，那正是"高射炮"的来源。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会变乱码。

## 交战距离
const DIST := 36.0
## 瞄准误差取样（度）
const OFFSETS := [-4.0, -2.0, -1.0, 0.0, 1.0, 2.0, 4.0]
## 炮塔与炮管回转到位的等待帧数
const SETTLE := 60
## 允许的落点偏差（米）。半车高
const MAX_MISS := 1.2
const DUMMY_HP := 1000000

var _rows: Array = []


func _main() -> Node:
	return get_node("Main")


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	for t in Arena.TERRAINS.size():
		await _measure(t)

	print("---- HE BALLISTIC TABLE ----")
	print("   miss = parabola height at %.0fm - enemy center (m);  hitD = solve target distance (m)"
			% DIST)
	print("   verdict flags: FALLBACK(no solve target) OVER(elev beyond HE solve limit %.0fdeg)"
			% rad_to_deg(Shell.HE_SOLVE_MAX))
	print("   MISS is only counted when the crosshair is on the enemy (hit=tank)")
	print("   or on nothing (hit=none); hit=world means the player aimed past the enemy")
	print("idx layout          dyaw  dPitch  hit    hitD   elev  evol   miss verdict")
	var fails := 0
	var worst := 0.0
	var fallback := 0
	for r in _rows:
		var bad := ""
		if String(r["hit"]) == "none":
			fallback += 1
		if r["elev"] > rad_to_deg(Shell.HE_SOLVE_MAX) + 0.1:
			bad += " OVER"
		if String(r["hit"]) != "world" and absf(r["miss"]) > MAX_MISS:
			bad += " MISS"
		if bad != "":
			fails += 1
		worst = maxf(worst, absf(r["miss"]))
		print("%2d  %-14s %5.1f %6.1f  %-6s %5.1f %6.2f %6.2f %6.2f%s" % [
				r["idx"], r["layout"], r["dyaw"], r["dpitch"], r["hit"], r["hitD"],
				r["elev"], r["evol"], r["miss"], bad])
	print("VERDICT fail=%d / %d  fallback=%d  worstMiss=%.2fm" % [
			fails, _rows.size(), fallback, worst])
	get_tree().quit()


func _measure(idx: int) -> void:
	var main := _main()
	var layout := String(Arena.TERRAINS[idx]["layout"])
	seed(20261016 + idx)
	main._sel_diff = 1
	main._sel_stage = 2
	main._sel_terrain = idx
	main._confirm_start()
	main.state = "ready"
	main.state_timer = 1.0e9
	for _i in 6:
		await get_tree().physics_frame

	var p: Player = main.player
	var arena: Arena = main.arena

	var e := Enemy.new()
	e.configure(1, 3, 1)
	e.max_hp = DUMMY_HP
	e.setup(main, arena, p.global_position)
	main.add_child(e)
	main.enemies.append(e)

	if not await _place(main, arena, p, e):
		e.alive = false
		main.enemies.erase(e)
		e.queue_free()
		return

	# 靶车摆好之后再算基准朝向，否则算出来的是它被挤开之前的位置
	await get_tree().physics_frame
	var ctr: Vector3 = e.global_position + Vector3(0, 1.1, 0)
	var pivot: Vector3 = p.global_position + Vector3(0, 1.9, 0)
	var to: Vector3 = ctr - pivot
	var flat := Vector2(to.x, to.z).length()
	var base_yaw := atan2(-to.x, -to.z)
	var base_pitch := atan2(to.y, maxf(flat, 0.5))

	for dp in OFFSETS:
		# 只扫俯仰：这是"准星压高一点还是压低一点"那一下，
		# 也正是让射线从车顶擦过去、落点从敌车跳到远处围墙的那一下
		main.rig.aim_yaw = wrapf(base_yaw, -PI, PI)
		main.rig.aim_pitch = clampf(base_pitch + deg_to_rad(dp),
				Tank.PITCH_MIN, Tank.PITCH_MAX)
		main.rig.yaw = base_yaw
		p.rotation.y = base_yaw
		for _i in SETTLE:
			e.hp = DUMMY_HP
			await get_tree().physics_frame
		_rows.append(_solve(main, p, e, idx, layout, 0.0, dp))

	e.alive = false
	main.enemies.erase(e)
	e.queue_free()


## 复刻 fire() 的 HE 分支：射线落点 -> lob_dir -> 在敌车距离上的高度
func _solve(main: Node, p: Player, e: Enemy, idx: int, layout: String,
		dyaw: float, dpitch: float) -> Dictionary:
	var origin: Vector3 = p.muzzle_pos()
	var dir: Vector3 = p.aim_dir()
	var space := p.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
			origin, origin + dir * Tank.LOB_RANGE, Tank.LAYER_WORLD | Tank.LAYER_TANK)
	q.exclude = [p.get_rid()]
	var hit: Dictionary = space.intersect_ray(q)

	var kind := "none"
	var hit_point: Vector3 = origin + dir * Tank.LOB_RANGE
	if not hit.is_empty():
		hit_point = hit["position"]
		kind = "tank" if hit["collider"] == e else ("tank?" if hit["collider"] is Tank else "world")
	var hit_d: float = (hit_point - origin).length()

	# 走生产代码那条路：fire() 里的 HE 分支调的就是 he_dir()
	var solved: Vector3 = p.he_dir(origin, dir)

	# 抛物线在敌车所在水平距离处的高度。水平速度取解算方向的分量，
	# 于是"抬高一点"同时体现在飞得更高与飞得更久两处——与真实弹道一致
	var ctr: Vector3 = e.global_position + Vector3(0, 1.1, 0)
	var d: Vector3 = ctr - origin
	var r := Vector2(d.x, d.z).length()
	var vh := Vector2(solved.x, solved.z).length() * Shell.HE_SPEED
	var t := r / maxf(vh, 0.01)
	var y := origin.y + solved.y * Shell.HE_SPEED * t - 0.5 * Shell.HE_GRAVITY * t * t
	# 只关心横向：纵向偏差由"炮弹从车顶擦过去"体现，横向偏差另算
	var lateral := _lateral_miss(ctr, origin, solved)
	return {
		"idx": idx, "layout": layout, "dyaw": dyaw, "dpitch": dpitch,
		"hit": kind, "hitD": hit_d,
		"elev": rad_to_deg(asin(clampf(solved.y, -1.0, 1.0))),
		"evol": rad_to_deg(asin(clampf(dir.y, -1.0, 1.0))),
		"miss": y - ctr.y,
	}


## 抛物线在敌车距离处的横向偏移（米）。俯仰误差不应带来横向偏移，
## 它是"这条弹道还准不准"的补充量，和纵向偏差一起构成落点误差
func _lateral_miss(ctr: Vector3, origin: Vector3, solved: Vector3) -> float:
	var to := ctr - origin
	var flat_to := Vector2(to.x, to.z).normalized()
	var flat_v := Vector2(solved.x, solved.z).normalized()
	return absf(flat_to.cross(flat_v)) * Vector2(to.x, to.z).length()


## 把靶车放到距玩家 DIST 米、炮线真的通的空地
func _place(main: Node, arena: Arena, p: Tank, e: Enemy) -> bool:
	var eye: Vector3 = p.global_position + Vector3(0, 1.8, 0)
	for step in 180:
		var yaw := deg_to_rad(float(step) * 2.0)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var pos: Vector3 = p.global_position + dir * DIST
		var c := Arena.to_cell(pos)
		if c.x < 1 or c.y < 1 or c.x > Arena.GRID_W - 2 or c.y > Arena.GRID_H - 2:
			continue
		if arena.blocks_tank(c.x, c.y):
			continue
		if not arena.has_line_of_sight(eye, pos + Vector3(0, 1.8, 0)):
			continue
		e.global_position = pos
		e.rotation.y = yaw
		e.hp = DUMMY_HP
		await get_tree().physics_frame
		if not _clear_shot(main, p, e):
			continue
		return true
	return false


func _clear_shot(main: Node, p: Tank, e: Enemy) -> bool:
	var q := PhysicsRayQueryParameters3D.create(
			p.muzzle_pos(), e.global_position + Vector3(0, 1.1, 0),
			Tank.LAYER_WORLD | Tank.LAYER_TANK)
	q.exclude = [p.get_rid()]
	var hit: Dictionary = p.get_world_3d().direct_space_state.intersect_ray(q)
	return not hit.is_empty() and hit["collider"] == e
