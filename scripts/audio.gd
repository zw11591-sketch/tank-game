extends Node
## 程序化音效单例（Audio autoload）：所有音效均在运行时合成，无需外部音频文件。
##
## 真实感不来自"波形画得多准"，而来自下面这四件事，缺任何一件都会立刻听出假：
##
##   1. 每一发都不一样 —— 同一段波形重复播放是最刺耳的破绽，人耳对精确重复极其敏感。
##      所以每个声音在播放时都按 VARY 表随机一点音高，没有两发是相同的。
##   2. 声音有尾巴   —— 炮响之后应该有建筑/地形的反射声。混响挂在 World 总线上，
##      参数随地形切换（见 SPACES），于是 12 张战场在听觉上也彼此区分。
##   3. 远处的声音是闷的 —— 空气吸收高频，100 米外的炮击是"咚"而不是小音量的"砰"。
##      按距离压低每个 3D 声源的低通截止频率来实现。
##   4. 远处的声音会晚到 —— 声速 343 m/s，150 米外那一炮应该晚将近半秒。
##      这是战争场景里最有说服力的一条线索，而成本只是一个定时器。
##
## 总线布局（在 _build_buses() 里用 AudioServer 建，不依赖 .tres 资源）：
##
##   Master ── 限幅器，兜住多路声音叠加时的削波
##     └─ SFX ── 音效总音量
##         ├─ World ── 混响。所有 play_3d() 的战场声走这里
##         │    └─ Engine ── 发动机循环，单独可调（它是唯一长时间持续的声源）
##         └─ UI ── 干声。play() 的界面与反馈提示走这里，不进混响，
##                  因为空击"咔"、命中"叮"这类提示要的是紧贴耳朵的即时感

const SR := 44100
const MAX_VOICES := 28

## 声速（m/s）与延迟上限。超过 MAX_DELAY 的距离听感上已经分不出远近，
## 再延长只会让"看到爆炸很久以后才听到"显得像卡顿。
const SOUND_SPEED := 343.0
const MAX_DELAY := 0.65
## 低于这个延迟就直接播：几米之内的声音拖一帧反而像音频故障
const MIN_DELAY := 0.04

## 3D 声源的默认可听半径。超出直接不建节点——既省语音位，也省节点分配。
const CULL_DIST := 130.0

const BUS_MASTER := "Master"
const BUS_SFX := "SFX"
const BUS_WORLD := "World"
const BUS_UI := "UI"
const BUS_ENGINE := "Engine"

## 每种音效的音高随机幅度（±比例）。
##
## 机械与爆炸类给得大：真实世界里它们每次都不同，给足随机量才像"又响了一次"
## 而不是"又放了一遍同一个文件"。
## 带音调含义的提示音给 0：命中"叮"、胜负音效一旦跑调就会听成走音的电子琴。
const VARY := {
	"shoot": 0.09,
	"boom": 0.11,
	"steel": 0.13,
	"ricochet": 0.14,
	"brick": 0.12,
	"track": 0.18,
	"dryfire": 0.10,
	"smoke": 0.08,
	"spawn": 0.05,
	"boost": 0.04,
	"hitmark": 0.0,
	"switch": 0.0,
	"pickup": 0.0,
	"power": 0.0,
	"alert": 0.0,
	"gameover": 0.0,
	"victory": 0.0,
}
const VARY_DEFAULT := 0.06

## 地形 layout -> 混响参数。键与 Arena.TERRAINS 的 "layout" 一一对应。
##
## 判断依据只有一条：这张图的几何会把炮声反射回来多少。
## 砖石与金属（废墟、回廊、港区、铁路）反射强、衰减慢；
## 植被、沙地与积雪吸声（丛林、沙漠、雪原）几乎没有尾音，开阔地同理。
## 这组参数不影响任何判定，纯粹是让耳朵也能认出"我在哪张图上"。
const SPACES := {
	"ruins":    {"room": 0.62, "damp": 0.35, "wet": 0.34, "pre": 28.0},
	"fortress": {"room": 0.78, "damp": 0.25, "wet": 0.42, "pre": 18.0},
	"valley":   {"room": 0.50, "damp": 0.50, "wet": 0.20, "pre": 55.0},
	"maze":     {"room": 0.55, "damp": 0.40, "wet": 0.38, "pre": 14.0},
	"badlands": {"room": 0.30, "damp": 0.75, "wet": 0.08, "pre": 70.0},
	"snow":     {"room": 0.25, "damp": 0.90, "wet": 0.05, "pre": 40.0},
	"docks":    {"room": 0.85, "damp": 0.18, "wet": 0.46, "pre": 32.0},
	"crater":   {"room": 0.60, "damp": 0.45, "wet": 0.26, "pre": 48.0},
	"jungle":   {"room": 0.35, "damp": 0.85, "wet": 0.12, "pre": 20.0},
	"night":    {"room": 0.68, "damp": 0.30, "wet": 0.36, "pre": 26.0},
	"desert":   {"room": 0.30, "damp": 0.80, "wet": 0.07, "pre": 65.0},
	"rail":     {"room": 0.80, "damp": 0.22, "wet": 0.40, "pre": 36.0},
}
const SPACE_DEFAULT := {"room": 0.5, "damp": 0.5, "wet": 0.22, "pre": 30.0}

var _streams: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _voices := 0
var _root3d: Node3D = null
var _reverb: AudioEffectReverb = null
## 合成这一批波形花了多少毫秒。启动开销可见，才不会悄悄退化。
var _build_ms := 0


func _ready() -> void:
	_rng.randomize()
	_build_buses()
	var t0 := Time.get_ticks_msec()
	_build_streams()
	_build_ms = Time.get_ticks_msec() - t0
	set_space("ruins")
	apply_volumes()
	Settings.audio_changed.connect(apply_volumes)


# ---------------- 总线 ----------------

## 用代码建总线而不是 default_bus_layout.tres：参数与它们的理由能写在一起，
## 也免得一个二进制资源文件变成没人敢改的黑盒。
##
## Godot 的约束是"总线只能送往索引更小的总线"，所以建立顺序即依赖顺序。
func _build_buses() -> void:
	# 已经建过（场景重载时 autoload 不会重跑，但保险起见）
	if AudioServer.get_bus_index(BUS_SFX) >= 0:
		_reverb = _find_reverb()
		return

	_add_bus(BUS_SFX, BUS_MASTER)
	_add_bus(BUS_WORLD, BUS_SFX)
	_add_bus(BUS_UI, BUS_SFX)
	_add_bus(BUS_ENGINE, BUS_WORLD)

	# 混响只挂在 World 上：战场声要尾巴，界面提示音不要
	_reverb = AudioEffectReverb.new()
	_reverb.spread = 0.9
	_reverb.hipass = 0.08
	AudioServer.add_bus_effect(AudioServer.get_bus_index(BUS_WORLD), _reverb)

	# 限幅器兜在最后：28 路未压缩的声音叠在一起必然削波，
	# 而削波的听感是"爆音"，比任何合成瑕疵都更破坏真实感
	var lim := AudioEffectLimiter.new()
	lim.threshold_db = -3.0
	lim.ceiling_db = -0.5
	lim.soft_clip_db = 2.0
	AudioServer.add_bus_effect(AudioServer.get_bus_index(BUS_MASTER), lim)


func _add_bus(name_: String, send_to: String) -> void:
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, name_)
	AudioServer.set_bus_send(idx, send_to)


func _find_reverb() -> AudioEffectReverb:
	var idx := AudioServer.get_bus_index(BUS_WORLD)
	if idx < 0:
		return null
	for i in AudioServer.get_bus_effect_count(idx):
		var e := AudioServer.get_bus_effect(idx, i)
		if e is AudioEffectReverb:
			return e
	return null


## 切换战场空间感。Arena 换地形时调用，参数见 SPACES。
func set_space(layout: String) -> void:
	if _reverb == null:
		return
	var s: Dictionary = SPACES.get(layout, SPACE_DEFAULT)
	_reverb.room_size = s["room"]
	_reverb.damping = s["damp"]
	_reverb.wet = s["wet"]
	_reverb.dry = 1.0
	_reverb.predelay_msec = s["pre"]


## 把设置里的三个音量写进总线。静音用 set_bus_mute 而不是 -80dB，省掉无谓的混音。
func apply_volumes() -> void:
	_set_bus_volume(BUS_MASTER, Settings.master_vol)
	_set_bus_volume(BUS_SFX, Settings.sfx_vol)
	_set_bus_volume(BUS_ENGINE, Settings.engine_vol)


func _set_bus_volume(name_: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(name_)
	if idx < 0:
		return
	AudioServer.set_bus_mute(idx, linear <= 0.001)
	AudioServer.set_bus_volume_db(idx, linear_to_db(clampf(linear, 0.0001, 1.0)))


# ---------------- 播放 ----------------

func set_listener_root(n: Node3D) -> void:
	_root3d = n


## 听者位置。第三人称下相机才是听者，所以空间感要以相机为准，而不是车的位置。
func _listener_pos() -> Vector3:
	if _root3d == null or not is_instance_valid(_root3d):
		return Vector3.INF
	var vp := _root3d.get_viewport()
	if vp == null:
		return Vector3.INF
	var cam := vp.get_camera_3d()
	return cam.global_position if cam != null else Vector3.INF


## 非定位播放：界面操作与贴耳反馈（空击、命中确认、装填就绪）走这里。
## 走 UI 总线，没有混响也没有延迟——这类声音的职责是"立刻告诉玩家发生了什么"。
func play(sfx: String, volume_db := 0.0) -> void:
	if not _streams.has(sfx) or _voices >= MAX_VOICES:
		return
	var p := AudioStreamPlayer.new()
	p.stream = _streams[sfx]
	p.volume_db = volume_db
	p.pitch_scale = _pitch(sfx)
	p.bus = BUS_UI
	add_child(p)
	_track(p)
	p.play()


## 按世界坐标播放战场声：距离衰减 + 声像定位 + 空气吸收 + 声速延迟。
##
## cull 是可听半径，超出则直接返回。履带声这类高频触发的声音把它调小，
## 于是七辆车同时跑也不会把 28 路语音位挤爆。
func play_3d(sfx: String, pos: Vector3, volume_db := 0.0, cull := CULL_DIST) -> void:
	if not _streams.has(sfx):
		return
	if _root3d == null or not is_instance_valid(_root3d):
		play(sfx, volume_db - 4.0)
		return

	var ear := _listener_pos()
	var dist := 0.0 if ear.x >= INF else ear.distance_to(pos)
	if dist > cull:
		return
	if _voices >= MAX_VOICES:
		return

	var delay := minf(dist / SOUND_SPEED, MAX_DELAY)
	if delay < MIN_DELAY:
		_emit_3d(sfx, pos, volume_db, dist)
		return
	# 占住语音位再等：否则远处一轮齐射会在延迟窗口里排起看不见的队
	_voices += 1
	await get_tree().create_timer(delay).timeout
	_voices -= 1
	_emit_3d(sfx, pos, volume_db, dist)


func _emit_3d(sfx: String, pos: Vector3, volume_db: float, dist: float) -> void:
	if _root3d == null or not is_instance_valid(_root3d) or _voices >= MAX_VOICES:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = _streams[sfx]
	p.volume_db = volume_db
	p.pitch_scale = _pitch(sfx)
	p.bus = BUS_WORLD
	p.unit_size = 22.0
	p.max_distance = CULL_DIST
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	# 空气吸收：越远越闷。这一条比音量衰减更能让人判断出距离。
	p.attenuation_filter_cutoff_hz = air_cutoff(dist)
	p.attenuation_filter_db = -14.0
	_root3d.add_child(p)
	p.global_position = pos
	_track(p)
	p.play()


## 距离 -> 低通截止频率。近处放到 20.5 kHz（等于不滤），110 米外压到 2.6 kHz。
static func air_cutoff(dist: float) -> float:
	return lerpf(20500.0, 2600.0, clampf(dist / 110.0, 0.0, 1.0))


## 本次播放的音高。同一个音效每次都不同，这是"听起来是真的"最便宜的一步。
func _pitch(sfx: String) -> float:
	var v: float = VARY.get(sfx, VARY_DEFAULT)
	if v <= 0.0:
		return 1.0
	return _rng.randf_range(1.0 - v, 1.0 + v)


func _track(p: Node) -> void:
	_voices += 1
	p.finished.connect(func() -> void:
		_voices -= 1
		p.queue_free())


## 发动机循环音轨。由调用方自己持有播放器并按车速改 pitch_scale，
## 所以不走 play()/play_3d() 那套一次性自动回收的通道。
func engine_stream() -> AudioStream:
	return _streams.get("engine")


## 诊断用：当前占用的语音位、波形合成耗时
func stats() -> Dictionary:
	return {"voices": _voices, "build_ms": _build_ms, "sr": SR, "streams": _streams.size()}


# ---------------- 波形表 ----------------

func _build_streams() -> void:
	_streams = {
		"shoot": _mix(_tone(180.0, 60.0, 0.22, 0.55, "square"), _noise(0.18, 0.5, 900.0)),
		"steel": _tone(1500.0, 820.0, 0.07, 0.28, "square"),
		"ricochet": _tone(2600.0, 420.0, 0.26, 0.3, "sine"),
		"brick": _noise(0.16, 0.45, 420.0),
		"boom": _mix(_noise(0.55, 0.6, 130.0), _tone(90.0, 32.0, 0.5, 0.45, "sine")),
		"pickup": _tone(660.0, 1180.0, 0.16, 0.4, "square"),
		"spawn": _tone(180.0, 520.0, 0.28, 0.3, "sine"),
		"power": _tone(440.0, 1320.0, 0.26, 0.34, "square"),
		"switch": _tone(900.0, 1250.0, 0.06, 0.25, "square"),
		# 空膛击发：一声干脆的机械"咔"，与 shoot 的厚重感完全分得开
		"dryfire": _mix(_tone(1400.0, 520.0, 0.045, 0.3, "square"), _noise(0.05, 0.35, 2600.0)),
		# 命中确认：一声短而亮的"叮"。开火到命中之间有飞行时间，
		# 没有这声提示就只能靠盯着目标猜打中没打中。
		"hitmark": _tone(1850.0, 2500.0, 0.055, 0.3, "sine"),
		# 履带链节撞击。坦克在现实里是靠履带声被人听见的，不是靠发动机——
		# 所以这一声比引擎更重要，也是"听声辨位"成立的前提。
		"track": _mix(_tone(430.0, 190.0, 0.05, 0.16, "square"), _noise(0.07, 0.2, 3200.0)),
		"boost": _tone(240.0, 780.0, 0.35, 0.32, "sine"),
		"smoke": _noise(0.5, 0.35, 700.0),
		"alert": _tone(880.0, 660.0, 0.35, 0.4, "square"),
		"gameover": _tone(392.0, 130.0, 0.9, 0.5, "square"),
		"victory": _tone(523.0, 1568.0, 0.8, 0.42, "square"),
		"engine": _engine_loop(45.0, 0.4),
	}


# ---------------- 波形合成 ----------------
#
# 采样率 44.1 kHz。原来的 22.05 kHz 奈奎斯特只有 11 kHz，炮声最关键的那一下
# 宽带瞬态（2–8 kHz）被整个砍掉，剩下的只有"闷"。
# 下面所有函数都以 SR 为参数，所以提采样率不需要重调任何一个音色。
# 唯一要注意的是 _noise() 的一极点系数 a = cutoff/SR：它的实际 -3dB 点约在
# cutoff/(2π) Hz，与 SR 无关，所以噪声的质感跨采样率是一致的。

func _tone(freq0: float, freq1: float, dur: float, vol: float, wave: String) -> AudioStreamWAV:
	var n := int(dur * SR)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in n:
		var t := float(i) / n
		var f := lerpf(freq0, freq1, t)
		phase = fmod(phase + f / SR, 1.0)
		var s := 0.0
		match wave:
			"square":
				s = 1.0 if phase < 0.5 else -1.0
			"sine":
				s = sin(phase * TAU)
		var env: float = minf(t * 12.0, 1.0) * (1.0 - t) * (1.0 - t)
		var v := int(clampf(s * vol * env, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	return _make_wav(data)


func _noise(dur: float, vol: float, cutoff: float) -> AudioStreamWAV:
	var n := int(dur * SR)
	var data := PackedByteArray()
	data.resize(n * 2)
	var last := 0.0
	var a := clampf(cutoff / SR, 0.0, 1.0)
	for i in n:
		var t := float(i) / n
		last = lerpf(last, _rng.randf_range(-1.0, 1.0), a)
		var env: float = minf(t * 8.0, 1.0) * (1.0 - t)
		var v := int(clampf(last * vol * env, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	return _make_wav(data)


## 叠加两段波形，得到更有厚度的炮击/爆炸声
func _mix(a: AudioStreamWAV, b: AudioStreamWAV) -> AudioStreamWAV:
	var da := a.data
	var db := b.data
	var n: int = maxi(da.size(), db.size()) / 2
	var out := PackedByteArray()
	out.resize(n * 2)
	for i in n:
		var va := da.decode_s16(i * 2) if i * 2 + 1 < da.size() else 0
		var vb := db.decode_s16(i * 2) if i * 2 + 1 < db.size() else 0
		out.encode_s16(i * 2, clampi(va + vb, -32768, 32767))
	return _make_wav(out)


## 发动机循环：基频 + 2/3/4 次谐波。所有分量的周期数都取整，
## 于是首尾相位连续，LOOP_FORWARD 衔接处听不到咔哒声。
## 噪声会破坏这个性质，所以质感靠一条 10Hz 的振幅调制来补。
func _engine_loop(base_hz: float, dur: float) -> AudioStreamWAV:
	var n := int(dur * SR)
	var data := PackedByteArray()
	data.resize(n * 2)
	# 每个分量在 dur 秒内走过的整数周期数
	var cycles := [
		maxi(1, int(round(base_hz * dur))),
		maxi(1, int(round(base_hz * dur))) * 2,
		maxi(1, int(round(base_hz * dur))) * 3,
		maxi(1, int(round(base_hz * dur))) * 4,
	]
	var gains := [1.0, 0.55, 0.3, 0.16]
	var am_cycles := maxi(1, int(round(10.0 * dur)))
	for i in n:
		var t := float(i) / n
		var s := 0.0
		for h in cycles.size():
			s += sin(t * TAU * float(cycles[h])) * float(gains[h])
		s /= 2.01
		# 轻微振幅起伏，避免听成纯电子音
		s *= 0.82 + 0.18 * sin(t * TAU * float(am_cycles))
		data.encode_s16(i * 2, int(clampf(s * 0.5, -1.0, 1.0) * 32767.0))
	var w := _make_wav(data)
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n - 1
	return w


func _make_wav(data: PackedByteArray) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SR
	w.stereo = false
	w.data = data
	return w
