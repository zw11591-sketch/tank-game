class_name TankRoster
## 玩家可选坦克名册：型号 → 模型 / 尺寸 / 数值 / 特性。
##
## 与 tools/blender/dims.py 的 TANKS 表一一对应：模型按那张表建模，名册按同一尺寸给
## 碰撞体。两者一旦不一致，就会出现"车看起来开进了墙里"——观感上与真的穿墙无异，
## 而且调物理参数永远修不掉。所以改观感随意，改尺寸必须同时改 dims.py 与这里的 DIMS。
##
## 之所以单独成一个文件而不是写在 player.gd 里：选车界面要在玩家坦克存在的**之前**
## 就把数值摊开显示，而 Player 是 CharacterBody3D，实例化它会连带建碰撞体、模型、
## 音源。数据与实体分开，界面就只读数据。

const DEFAULT_ID := "falcon"

## 模型尺寸真值表（键即 assets/models/<key>.glb）。
##   radius / length —— Tank.body_radius / Tank.body_length，决定碰撞轮廓
##   hull            —— Godot 约定下的车体尺寸 (宽, 高, 长)，供 HullGuide 摆灯与朝向箭头
##   wheel           —— 负重轮半径，只影响滚动速度的观感
##   aim_y           —— 炮管耳轴离地高度，瞄准解算与"打不到就变灰"的参考高度
const DIMS := {
	"tank_player":    {"radius": 1.50, "length": 4.4, "hull": Vector3(3.4, 1.00, 4.4), "wheel": 0.42, "aim_y": 1.95},
	"tank_scout":     {"radius": 1.35, "length": 3.9, "hull": Vector3(3.0, 0.90, 3.9), "wheel": 0.55, "aim_y": 1.70},
	"tank_medium":    {"radius": 1.50, "length": 4.4, "hull": Vector3(3.4, 1.00, 4.4), "wheel": 0.42, "aim_y": 1.95},
	"tank_heavy":     {"radius": 1.75, "length": 4.9, "hull": Vector3(3.8, 1.15, 4.9), "wheel": 0.42, "aim_y": 2.15},
	"tank_artillery": {"radius": 1.50, "length": 4.6, "hull": Vector3(3.3, 0.95, 4.6), "wheel": 0.42, "aim_y": 1.70},
	"tank_destroyer": {"radius": 1.50, "length": 5.0, "hull": Vector3(3.4, 0.85, 5.0), "wheel": 0.42, "aim_y": 1.54},
	"tank_boss":      {"radius": 2.30, "length": 6.0, "hull": Vector3(4.6, 1.40, 6.0), "wheel": 0.50, "aim_y": 2.55},
}

## 选车界面里的排列顺序（也是 ←→ 的循环顺序）。
## 按"轻 → 中 → 重 → 特化"排，玩家第一眼看到的就是最标准的基准车。
const ORDER: Array[String] = ["lynx", "falcon", "anvil", "thunder", "hunter"]

## 型号定义。每款车的差异必须落在两组量上，缺一组就会"数值不同但玩起来一样"：
##   * 交换律上的取舍（火力 / 装甲 / 机动三者此消彼长）——决定选谁；
##   * 一条**行为**上的特性（射界、弹种、技能冷却）——决定怎么玩。
##
## turn 是车体原地转向的角速度（rad/s），玩家的"转向跟手程度"就是这个数。
## 2026-10 整体上调 20%：原值（3.2 / 2.5 / 1.9 / 2.1 / 2.3）在开阔地原地转 90°
## 要 0.49~0.83 s，其中铁砧 0.83 s、雷锤 0.75 s，玩家的反馈是"左右转向不灵活"
## （tools/_hull_clip_probe.gd 的 pivot 一栏）。车与车之间的相对次序完全保留，
## 所以"山猫最快、铁砧最慢"这条对比条不变；同时镜头的跟随速度也提了一档
## （见 CameraRig.FOLLOW_RATE），因为转向时画面滞后同样会被读成"车不跟手"。
##
## af / as / ar 是入射伤害倍率（装甲/侧面/背面），越小越硬。玩家基准是 0.5/1.0/1.7，
## 比敌人的 0.7 更硬，因为玩家只有一辆车而敌人有半打。
##
## reload 是"点一下就打得出去"的手感量：它必须短到玩家感觉不到等待。
## 五款车统一压到 0.05~0.09 s（上一版 0.08~0.13 s，再早 0.12~0.26 s）。
## 慢装填的车按一下鼠标要等半秒以上才响第二发，读起来就是"点击没反应"；而车与车之间的
## 强弱差别本来就已经由单发伤害、装甲、机动这一组量拉开了，不需要再靠"等装填"补。
## 所有数值必须维持原来的相对次序（山猫最快、雷锤最慢），否则"装填"这一条对比条
## 就失去意义。困难难度系数 1.21 之后最慢的雷锤也只有 0.11 s，落在
## `Player.DRY_WAIT`（0.30 s）以内，于是"点一下 = 一定打出去一发"在任何车上都成立。
const SPECS := {
	"lynx": {
		"name": "山猫",
		"full": "山猫 · 轻型侦察车",
		"tag": "侦察",
		"model": "tank_scout",
		"desc": "轮式底盘，全场最快的机动与最快的装填。",
		"perk_name": "轻装疾行",
		"perk_desc": "冲刺可持续 3.0 秒、冷却仅 6 秒，\n烟雾冷却 15 秒。靠机动而不是装甲活命。",
		"hull_color": Color(0.40, 0.39, 0.26),
		"accent_color": Color(0.82, 0.70, 0.26),
		"hp": 330, "speed": 19.5, "turn": 3.8, "turret": 5.4, "snap": 1.5,
		"reload": 0.05, "damage": 62,
		"af": 0.90, "as": 1.15, "ar": 1.60,
		"he": true, "he_mult": 0.62, "he_splash": 0.85,
		"boost_time": 3.0, "boost_cd": 6.0, "smoke_cd": 15.0,
		"turret_limit": 0.0,
	},
	"falcon": {
		"name": "游隼",
		"full": "游隼 · 中型主战坦克",
		"tag": "主战",
		"model": "tank_player",
		"desc": "没有任何短板，也没有任何长板——所有战术它都能做。",
		"perk_name": "多面手",
		"perk_desc": "AP / HE 双弹种 + 冲刺 + 烟雾全部齐备，\n炮塔回转与俯仰最跟手。不知道选什么就选它。",
		"hull_color": Color(0.30, 0.44, 0.32),
		"accent_color": Color(0.80, 0.68, 0.24),
		"hp": 480, "speed": 15.0, "turn": 3.0, "turret": 4.6, "snap": 1.2,
		"reload": 0.06, "damage": 115,
		"af": 0.50, "as": 1.00, "ar": 1.70,
		"he": true, "he_mult": 0.72, "he_splash": 1.0,
		"boost_time": 2.2, "boost_cd": 9.0, "smoke_cd": 22.0,
		"turret_limit": 0.0,
	},
	"anvil": {
		"name": "铁砧",
		"full": "铁砧 · 重型突破坦克",
		"tag": "突破",
		"model": "tank_heavy",
		"desc": "正面装甲近乎免疫 AP，单发伤害全场最高。",
		"perk_name": "正面堡垒",
		"perk_desc": "正面只吃 32% 伤害（基准 50%），\n但车体最宽最重：单格宽通道里转向会明显迟滞。",
		"hull_color": Color(0.34, 0.38, 0.42),
		"accent_color": Color(0.78, 0.52, 0.20),
		"hp": 760, "speed": 11.2, "turn": 2.3, "turret": 3.3, "snap": 0.8,
		"reload": 0.08, "damage": 165,
		"af": 0.32, "as": 0.85, "ar": 1.55,
		"he": true, "he_mult": 0.72, "he_splash": 1.1,
		"boost_time": 1.8, "boost_cd": 11.0, "smoke_cd": 24.0,
		"turret_limit": 0.0,
	},
	"thunder": {
		"name": "雷锤",
		"full": "雷锤 · 自行火炮",
		"tag": "支援",
		"model": "tank_artillery",
		"desc": "5.2 米长身管，高爆弹伤害与溅射范围都远超其余车型。",
		"perk_name": "高爆专精",
		"perk_desc": "HE 伤害 ×1.45、溅射半径 ×1.35，\n一发能整片铲平砖墙与掩体后的敌人。装甲极脆、装填最慢。",
		"hull_color": Color(0.44, 0.40, 0.28),
		"accent_color": Color(0.72, 0.38, 0.16),
		"hp": 350, "speed": 12.5, "turn": 2.5, "turret": 2.9, "snap": 0.6,
		"reload": 0.09, "damage": 118,
		"af": 0.75, "as": 1.25, "ar": 1.85,
		"he": true, "he_mult": 1.05, "he_splash": 1.35,
		"boost_time": 2.0, "boost_cd": 9.0, "smoke_cd": 18.0,
		"turret_limit": 0.0,
	},
	"hunter": {
		"name": "猎手",
		"full": "猎手 · 坦克歼击车",
		"tag": "歼击",
		"model": "tank_destroyer",
		"desc": "低矮的无炮塔式车体，一门 190 伤害的 4.6 米长身管。",
		"perk_name": "限位炮塔",
		"perk_desc": "炮塔只能左右各转 40°，射界之外必须用车体指向目标。\n换来的是全场最高的单发伤害与近乎免疫的正面装甲。",
		"hull_color": Color(0.32, 0.38, 0.34),
		"accent_color": Color(0.70, 0.72, 0.74),
		"hp": 400, "speed": 13.5, "turn": 2.8, "turret": 3.6, "snap": 1.0,
		"reload": 0.07, "damage": 190,
		"af": 0.30, "as": 0.95, "ar": 1.70,
		"he": false, "he_mult": 0.72, "he_splash": 1.0,
		"boost_time": 2.2, "boost_cd": 9.0, "smoke_cd": 20.0,
		"turret_limit": 0.6981317,
	},
}


## 取型号定义，并注入 id 字段（界面与实体都要用 id 反查 DIMS）。
## 未知 id 一律退回基准车，于是坏存档 / 手改 settings.cfg 不会让游戏开不了局。
static func spec(id: String) -> Dictionary:
	var key := id if SPECS.has(id) else DEFAULT_ID
	var s: Dictionary = SPECS[key].duplicate()
	s["id"] = key
	return s


static func has(id: String) -> bool:
	return SPECS.has(id)


## 模型尺寸。未知模型退回玩家基准尺寸，宁可碰撞体稍大也不要 null。
static func dims(model_key: String) -> Dictionary:
	if DIMS.has(model_key):
		return DIMS[model_key]
	return DIMS["tank_player"]


## 界面用：把数值摊成 6 条对比条。每条给 0..1 的归一值与一句读数。
##
## 归一化的分母是"名册内的量程"而不是理论最大值：这样五款车并排比较时，
## 满格与空格本身就说明了彼此的相对位置，不必去记绝对数字。
static func bars(id: String) -> Array:
	var s := spec(id)
	var limit: float = float(s["turret_limit"])
	var arc := "全向 360°" if limit <= 0.0 else "射界 ±%.0f°" % rad_to_deg(limit)
	return [
		{"label": "火力", "v": float(s["damage"]) / 200.0,
			"text": "%d / 发" % int(s["damage"])},
		{"label": "防护", "v": (1.0 - float(s["af"])) / 0.70,
			"text": "正 %.0f%% · 侧 %.0f%% · 后 %.0f%%" % [
				float(s["af"]) * 100.0, float(s["as"]) * 100.0, float(s["ar"]) * 100.0]},
		{"label": "机动", "v": float(s["speed"]) / 20.0,
			"text": "%.1f m/s" % float(s["speed"])},
		{"label": "炮塔", "v": float(s["turret"]) / 5.6,
			"text": "%.1f rad/s · %s" % [float(s["turret"]), arc]},
		{"label": "装填", "v": 1.0 - (float(s["reload"]) - 0.05) / 0.06,
			"text": "%.2f s" % float(s["reload"])},
		{"label": "结构", "v": float(s["hp"]) / 780.0,
			"text": "%d" % int(s["hp"])},
	]
