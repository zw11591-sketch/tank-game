extends Node
## 验收：击毁后留下残骸、燃烧期"挡车不挡弹"，燃烧期满后自动塌陷并解除阻挡。
##
## 判据：
##   1. 击毁一辆敌车后，Arena 的 Wrecks 根节点下出现一个残骸；
##   2. 残骸碰撞体在 LAYER_BLOCKER（坦克 mask 含这一层）；
##   3. 残骸不在炮弹射线的 mask（WORLD | TANK）里；
##   4. 击毁 2 秒后残骸仍然存在，且黑烟粒子还在发射；
##   5. 等到燃烧期结束（覆盖 6.5 s 与 18 s 两档之后）：
##      残骸标记 collapsed、碰撞层归零、它封过的格重新变回可通行。
##   6. 再击毁一辆车，在燃烧期内走玩家的卡死自救入口（`Player._check_stuck`；
##      玩家不可用时退回直接调 `collapse_wreck_near()`）：最近的残骸被提前
##      塌陷、碰撞层归零、封格同样撤销。
##
## 第 5 条是"残骸不该永久锁死走廊"的回归测试：少了它，把塌陷计时器接错、
## 或者塌陷时忘了撤销封格，都会让玩家重新被永久堵在残骸外面。
## 第 6 条覆盖玩家的卡死自救（`Player._check_stuck`）与重生点保护
## （`Main._spawn_player`）都依赖的提前塌陷入口。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会二次编码。

const WAIT_KILL := 900          ## 最多等多久才凑出一辆可击毁的敌车（120 Hz）
const WAIT_BURN := 240          ## 击毁后再等 2 秒：确认燃烧期仍然挡车
const WAIT_COLLAPSE := 2640     ## 再等 22 秒：长于两档燃烧期，确认自动塌陷
const WAIT_PRE_COLLAPSE := 90   ## 第二辆击毁后等 0.75 秒：仍在燃烧期内

var _f := 0
var _state := 0
var _w: Wreck = null
var _cell := Vector2i(-1, -1)
var _marked := false
var _burn_ok := false
var _killed := ""
var _kill_pos := Vector3.ZERO
var _rescue_pos := Vector3.ZERO
var _rescue_hit := false
var _rescue_route := ""


func _main() -> Node:
	return get_node_or_null("Main")


func _ready() -> void:
	await get_tree().process_frame
	var main := _main()
	if main == null:
		print("WRECK FAIL no Main")
		get_tree().quit(1)
		return
	main._sel_diff = 0
	main._sel_stage = 0
	main._sel_terrain = 0
	main._confirm_start()


func _physics_process(_delta: float) -> void:
	var main := _main()
	if main == null or main.arena == null:
		return
	_f += 1

	if _state == 0:
		if _f < WAIT_KILL:
			for e in main.enemies:
				if is_instance_valid(e) and e.alive:
					_killed = str(e.name)
					# 把它挪到玩家活动区的开阔地再击毁。出生格本身是封格判据里的
					# "必须可达"目标，在那儿击毁会走"封了会切断地图"的拒绝分支，
					# 就测不到封格与塌陷后的撤销了。
					var spot := _open_spot(main.arena)
					e.global_position = Arena.cell_center(spot.x, spot.y)
					_kill_pos = e.global_position
					e.destroy(true)
					_state = 1
					_f = 0
					print("WRECK killed=%s spot=%s" % [_killed, str(spot)])
					return
		else:
			print("WRECK FAIL noEnemy frames=%d" % _f)
			get_tree().quit(1)
		return

	# 燃烧期：残骸应该还在挡车
	if _state == 1 and _f > WAIT_BURN:
		var root: Node3D = main.arena._wrecks_root
		var n: int = root.get_child_count() if root != null else 0
		if n > 0:
			_w = root.get_child(n - 1) as Wreck
		var body := _w.get_node_or_null("WreckBody") if _w != null else null
		var layer: int = (body as CollisionObject3D).collision_layer if body is CollisionObject3D else -1
		var blocks_tank: bool = (layer & Tank.LAYER_BLOCKER) != 0
		var shell_hits: bool = (layer & (Tank.LAYER_WORLD | Tank.LAYER_TANK)) != 0
		var smoke := _find_smoke(_w)
		var turret := Assets.find_node(_w, "Turret") if _w != null else null
		var barrel := Assets.find_node(_w, "Barrel") if _w != null else null
		var persists: bool = _w != null and is_instance_valid(_w) and _w.is_inside_tree()
		var placed: bool = persists and _w.global_position.distance_to(_kill_pos) < 4.0
		var in_tank_list := false
		for t in main.all_tanks():
			if t == _w:
				in_tank_list = true
		if persists:
			_cell = Arena.to_cell(_w.global_position)
			_marked = main.arena.is_wreck_cell(_cell.x, _cell.y)
		_burn_ok = n >= 1 and blocks_tank and not shell_hits and persists \
				and placed and turret != null and barrel != null and not in_tank_list
		print("WRECK burn wrecks=%d layer=%d blocksTank=%s shellHits=%s present=%s atKillSpot=%s turret=%s barrel=%s smoke=%s stillTargetable=%s markedCell=%s" % [
			n, layer, str(blocks_tank), str(shell_hits), str(persists),
			str(placed), str(turret != null), str(barrel != null), str(smoke),
			str(in_tank_list), str(_marked),
		])
		_state = 2
		_f = 0
		return

	# 燃烧期之后：残骸应该已经塌陷、碰撞层归零、封格撤销
	if _state == 2 and _f > WAIT_COLLAPSE:
		var body := _w.get_node_or_null("WreckBody") if is_instance_valid(_w) else null
		var layer: int = (body as CollisionObject3D).collision_layer if body is CollisionObject3D else -1
		var collapsed: bool = is_instance_valid(_w) and _w.collapsed
		var still_blocks: bool = _marked and main.arena.is_wreck_cell(_cell.x, _cell.y)
		var persists: bool = is_instance_valid(_w) and _w.is_inside_tree()
		var ok: bool = _burn_ok and collapsed and layer == 0 and not still_blocks and persists
		print("WRECK collapse collapsed=%s layer=%d navCellFree=%s present=%s" % [
			str(collapsed), layer, str(not still_blocks), str(persists),
		])
		if not ok:
			print("WRECK VERDICT lifecycle=false rescue=false")
			get_tree().quit(1)
			return
		print("WRECK VERDICT lifecycle=true")
		# 第 6 条：再击毁一辆，在燃烧期内把提前塌陷也走一遍
		var second := _first_alive(main)
		if second == null:
			print("WRECK rescue FAIL noSecondEnemy")
			get_tree().quit(1)
			return
		var spot2 := _open_spot(main.arena, _cell)
		second.global_position = Arena.cell_center(spot2.x, spot2.y)
		_rescue_pos = second.global_position
		second.destroy(true)
		print("WRECK rescueKill spot=%s" % str(spot2))
		_state = 3
		_f = 0
		return

	# 提前塌陷：玩家卡死自救（Player._check_stuck）与重生点保护都走这条入口
	if _state == 3 and _f > WAIT_PRE_COLLAPSE:
		var p = main.player
		if p != null and main.state == "play" \
				and p.global_position.distance_to(_rescue_pos) <= Player.STUCK_WRECK_RADIUS - 1.0:
			# 走玩家自己的入口，而不是直接调 Arena：多覆盖"油门 + 计时 + 就近
			# 选择"这段接线。把计时推到触发前一帧，下一次调用正好越过阈值。
			p._stuck_anchor = p.global_position
			p._stuck_t = Player.STUCK_RESCUE_TIME - 0.01
			p._check_stuck(0.02, 1.0)
			_rescue_route = "player"
		else:
			_rescue_hit = main.arena.collapse_wreck_near(_rescue_pos, 3.0)
			_rescue_route = "arena"
		_state = 4
		_f = 0
		return

	# `collapse()` 里关碰撞体走的是 set_deferred，等两帧再读才看得到结果
	if _state == 4 and _f > 2:
		var root: Node3D = main.arena._wrecks_root
		var n2: int = root.get_child_count() if root != null else 0
		var w2: Wreck = null
		if n2 > 0:
			w2 = root.get_child(n2 - 1) as Wreck
		var c2 := Arena.to_cell(_rescue_pos)
		var still: bool = main.arena.is_wreck_cell(c2.x, c2.y)
		var body2 := w2.get_node_or_null("WreckBody") if w2 != null else null
		var layer2: int = (body2 as CollisionObject3D).collision_layer if body2 is CollisionObject3D else -1
		var ok: bool = _rescue_route != "" and w2 != null and w2.collapsed \
				and layer2 == 0 and not still
		if _rescue_route != "player":
			ok = ok and _rescue_hit
		print("WRECK rescue route=%s collapsed=%s layer=%d navCellFree=%s" % [
			_rescue_route, str(w2 != null and w2.collapsed), layer2, str(not still),
		])
		print("WRECK VERDICT lifecycle=true rescue=%s" % str(ok))
		get_tree().quit(0 if ok else 1)


func _find_smoke(n: Node) -> bool:
	if n == null:
		return false
	if n is GPUParticles3D and (n as GPUParticles3D).emitting:
		return true
	for c in n.get_children():
		if _find_smoke(c):
			return true
	return false


func _first_alive(main: Node) -> Node:
	for e in main.enemies:
		if is_instance_valid(e) and e.alive:
			return e
	return null


## 玩家活动区是 `_carve_zones()` 凿出来的 6 × 3 格开阔地：在这里封一格
## 不可能切断地图，所以一定能走到"封格成功"那条分支。
func _open_spot(arena: Arena, avoid := Vector2i(-1, -1)) -> Vector2i:
	for y in [18, 17, 19]:
		for x in [13, 14, 12, 10, 9, 11]:
			var c := Vector2i(x, y)
			if c == avoid:
				continue
			if arena.cell(x, y) == Arena.EMPTY and not arena.blocks_nav(x, y):
				return c
	return Vector2i(11, 18)
