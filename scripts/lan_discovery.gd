class_name LanDiscovery
extends Node
## 同网段房间发现：房主每 1 秒向 UDP 广播一个信标，客户端监听并汇总房间列表。
##
## 这里刻意不依赖 ENet / 大厅服务器：广播只在二层同网段有效，所以它解决的是
## "同一间办公室、同一个 WiFi" 这种最常见的场景。跨网段、AP 隔离、公司防火墙
## 挡掉广播时，客户端仍可在大厅里手动输入 IP —— 发现失败不等于联机失败。

signal rooms_changed(rooms: Array)

const MAGIC := "TANK3D_DISCOVER"
const PROTOCOL := 1
## 超过这个时间没有收到信标就把房间从列表里摘掉。3 秒足够容忍丢一两个包，
## 又不会让一台已经退出的机器在列表里停留太久。
const ROOM_TTL := 3.0

var _host_udp: PacketPeerUDP = null
var _client_udp: PacketPeerUDP = null
var _port := 45887
var _beacon := Callable()
var _beacon_t := 0.0
var _rooms: Dictionary = {}
var _dirty := false
var _emit_cd := 0.0


func start_host(beacon: Callable, port: int) -> bool:
	stop()
	_port = port
	_beacon = beacon
	_host_udp = PacketPeerUDP.new()
	var err := _host_udp.bind(_port)
	if err != OK:
		push_warning("[LAN] 无法监听发现端口 %d（%s），其他玩家将无法自动发现本房间" % [
			_port, error_string(err)])
		_host_udp = null
		return false
	_host_udp.set_broadcast_enabled(true)
	_beacon_t = 0.0
	set_process(true)
	return true


func start_listen(port: int) -> bool:
	stop()
	_port = port
	_client_udp = PacketPeerUDP.new()
	var err := _client_udp.bind(_port)
	if err != OK:
		push_warning("[LAN] 无法监听发现端口 %d（%s）。可能是同一台机器上的第二个实例，"\
				% [_port, error_string(err)] + "请用不同的 --discovery-port 或手动输入 IP")
		_client_udp = null
		return false
	_client_udp.set_broadcast_enabled(true)
	_rooms.clear()
	_dirty = true
	probe()
	set_process(true)
	return true


func stop() -> void:
	if _host_udp != null:
		_host_udp.close()
		_host_udp = null
	if _client_udp != null:
		_client_udp.close()
		_client_udp = null
	_rooms.clear()
	set_process(false)


## 客户端主动发一次探测。房主收到后立刻回一个信标，于是刚打开大厅
## 不必干等最多 1 秒的广播周期。
func probe() -> void:
	if _client_udp == null:
		return
	# 探测包用裸 MAGIC 字符串，而不是 JSON：房主只回应"有人在找房间"这一件事，
	# 周期信标也走 JSON，两者用首字符区分，解析路径互不干扰。
	var pkt := MAGIC.to_utf8_buffer()
	_client_udp.set_dest_address("255.255.255.255", _port)
	_client_udp.put_packet(pkt)


func get_rooms() -> Array:
	var out: Array = []
	for key in _rooms.keys():
		out.append((_rooms[key] as Dictionary).duplicate())
	out.sort_custom(func(a, b): return String(a.get("name", "")) < String(b.get("name", "")))
	return out


func _process(delta: float) -> void:
	if _host_udp != null:
		_poll_host()
		_beacon_t -= delta
		if _beacon_t <= 0.0:
			_beacon_t = 1.0
			_send_beacon()
	if _client_udp != null:
		_poll_client()
		_emit_cd -= delta
		if _expire() or (_dirty and _emit_cd <= 0.0):
			_dirty = false
			_emit_cd = 0.25
			rooms_changed.emit(get_rooms())


func _send_beacon() -> void:
	if _host_udp == null:
		return
	var data: Dictionary = {}
	if _beacon.is_valid():
		var got = _beacon.call()
		if got is Dictionary:
			data = got
	if data.is_empty():
		return
	data["magic"] = MAGIC
	data["v"] = PROTOCOL
	_send_to("255.255.255.255", _port, JSON.stringify(data).to_utf8_buffer())


func _send_to(ip: String, port: int, pkt: PackedByteArray) -> void:
	if _host_udp == null:
		return
	_host_udp.set_dest_address(ip, port)
	_host_udp.put_packet(pkt)


func _poll_host() -> void:
	var n := _host_udp.get_available_packet_count()
	for i in n:
		var pkt := _host_udp.get_packet()
		var ip := _host_udp.get_packet_ip()
		var port := _host_udp.get_packet_port()
		if pkt.is_empty():
			continue
		var txt := pkt.get_string_from_utf8()
		if txt != MAGIC and not txt.begins_with("{"):
			continue
		# 只回应探测包，不回应其他房主的周期信标（否则两个房主会互相刷屏）
		if txt == MAGIC:
			_send_to(ip, port, _beacon_packet())


func _beacon_packet() -> PackedByteArray:
	var data: Dictionary = {}
	if _beacon.is_valid():
		var got = _beacon.call()
		if got is Dictionary:
			data = got
	data["magic"] = MAGIC
	data["v"] = PROTOCOL
	return JSON.stringify(data).to_utf8_buffer()


func _poll_client() -> void:
	var n := _client_udp.get_available_packet_count()
	for i in n:
		var pkt := _client_udp.get_packet()
		var ip := _client_udp.get_packet_ip()
		if pkt.is_empty():
			continue
		var txt := pkt.get_string_from_utf8()
		if not txt.begins_with("{"):
			continue
		var parsed = JSON.parse_string(txt)
		if not (parsed is Dictionary):
			continue
		var d: Dictionary = parsed
		if String(d.get("magic", "")) != MAGIC:
			continue
		if int(d.get("v", 0)) != PROTOCOL:
			continue
		var room := {
			"ip": ip,
			"port": int(d.get("port", 45888)),
			"name": String(d.get("name", "坦克房间")),
			"stage": int(d.get("stage", 1)),
			"diff": int(d.get("diff", 1)),
			"players": int(d.get("players", 1)),
			"max": int(d.get("max", 4)),
			"build": String(d.get("build", "")),
			# 旧版本信标没有 active 字段，缺省当成"没在打"，不影响兼容。
			"active": bool(d.get("active", false)),
			"seen": Time.get_ticks_msec() / 1000.0,
		}
		_rooms[ip] = room
		_dirty = true


func _expire() -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	var dead: Array = []
	for ip in _rooms.keys():
		if now - float((_rooms[ip] as Dictionary).get("seen", 0.0)) > ROOM_TTL:
			dead.append(ip)
	for ip in dead:
		_rooms.erase(ip)
	return not dead.is_empty()
