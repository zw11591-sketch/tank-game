class_name Wreck
extends Node3D
## 击毁后留在战场上的车体残骸。
##
## 残骸在玩法上真正起作用的只有一件事：**挡车**。炮弹主射线的 mask 不含
## `Tank.LAYER_BLOCKER`，敌人选掩体时也明确把残骸排除，所以它既不挡弹、
## 也不挡视线。原来的实现让这个"挡车"变成**永久**的：一具残骸死在走廊或
## 基地门口，玩家就再也过不去——自己的车推不动它，炮弹打不烂它，局内也没有
## 重开关卡的手段。
##
## 现在拆成两段：
##   * 燃烧期（BURN_HOLD / CHOKE_HOLD）：完整阻挡，保留"刚被击毁"的压场感；
##   * 塌陷后：碰撞体直接关掉，车体压扁沉进地面，只剩一堆低矮的焦黑残壳。
##
## 塌陷时同步调用 `Arena.release_wreck()` 撤销寻路封格。物理体与 A* 认知必须
## 在同一时刻对齐：晚一步的话，敌人会绕着一堆已经能开过去的残骸走远路。

## 普通残骸的完整阻挡时长（秒）。18 秒足够让玩家看清"这里死了辆车"，
## 又不至于让一次交火把半张图永久锁死。
const BURN_HOLD := 18.0
## 关键通道上的完整阻挡时长。判据见 Arena.note_wreck() 的 `critical`：
## 脚印压到基地门口 / 渡口，或者封格会切断地图。不压到 0，是因为
## "刚炸毁的车能直接开过去"比"等几秒"更穿帮。
const CHOKE_HOLD := 6.5
## 塌陷动画时长（秒）
const COLLAPSE_TIME := 1.6
## 塌陷后的视觉：沿 Y 压扁到 34%，同时沉进地面 0.55 m。
## 车体连同炮塔约 2.4 m 高，压扁后剩 0.8 m，下沉后露出地面约 0.25 m。
## 坦克从上面轧过去时只会擦到履带下沿，读起来是"压过一堆烧塌的废铁"，
## 而不是从一堵完整的车身里穿过去。
const COLLAPSED_SCALE_Y := 0.34
const COLLAPSED_SINK := 0.55

## 是否已经塌陷。用于卡死自救时跳过已经能开过去的残骸。
var collapsed := false

var _arena: Arena
var _visual: Node3D
var _body: StaticBody3D
var _smoke: GPUParticles3D
var _fire: GPUParticles3D
var _sparks: GPUParticles3D
var _ember: OmniLight3D
## 这具残骸在 Arena 里封住的格。塌陷时按这份清单原样撤销，不多不少。
var _cells: Array[Vector2i] = []


## 车体与特效都挂进来之后再调用：所有引用都在这里一次性交给残骸自己管。
## `info` 是 `Arena.note_wreck()` 的返回值：`cells` 是它实际封住的格，
## `critical` 决定这具残骸用普通时长还是关键通道时长。
func setup(a: Arena, body: StaticBody3D, smoke: GPUParticles3D, fire: GPUParticles3D,
		sparks: GPUParticles3D, ember: OmniLight3D, info: Dictionary) -> void:
	_arena = a
	_body = body
	_smoke = smoke
	_fire = fire
	_sparks = sparks
	_ember = ember

	var cells = info.get("cells", [])
	if cells is Array:
		for c in cells:
			_cells.append(c)

	var hold := CHOKE_HOLD if bool(info.get("critical", false)) else BURN_HOLD
	var t := Timer.new()
	t.name = "CollapseTimer"
	t.wait_time = hold
	t.one_shot = true
	t.autostart = true
	t.timeout.connect(collapse)
	add_child(t)


## 压扁用的视觉根节点。特效、碰撞体、计时器都不挂在这里：
## 它们不该跟着车体一起被压扁。
func visual() -> Node3D:
	if _visual == null:
		_visual = Node3D.new()
		_visual.name = "Visual"
		add_child(_visual)
	return _visual


## 提前塌陷。计时器到点会调用它，玩家的卡死自救与重生点保护也会。
func collapse() -> void:
	if collapsed:
		return
	collapsed = true

	# 火、烟、火星与余烬光都随燃烧期结束。塌陷后的残骸不该还在烧。
	if is_instance_valid(_smoke):
		_smoke.emitting = false
	if is_instance_valid(_fire):
		_fire.emitting = false
	if is_instance_valid(_sparks):
		_sparks.emitting = false
	if is_instance_valid(_ember):
		_ember.light_energy = 0.0

	# 碰撞体必须**整个关掉**，不能只把碰撞盒压低：坦克的碰撞轮廓是一条贴地的
	# 圆柱（见 Tank._build_body），0.3 m 高的盒子仍然与它相交，车照样过不去。
	if is_instance_valid(_body):
		_body.set_deferred("collision_layer", 0)
		_body.set_deferred("collision_mask", 0)

	if _arena != null:
		_arena.release_wreck(_cells)

	if _visual != null:
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(_visual, "scale:y", COLLAPSED_SCALE_Y, COLLAPSE_TIME) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_property(_visual, "position:y", -COLLAPSED_SINK, COLLAPSE_TIME) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
