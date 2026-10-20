extends SceneTree
## 临时：确认 angle_difference(from, to) 的符号约定。
## 这决定 player._relative_drive 里 err 的正负号解读，必须实测而不是猜。

func _initialize() -> void:
	print("AD(0, 0.5) = ", angle_difference(0.0, 0.5))
	print("AD(0.5, 0) = ", angle_difference(0.5, 0.0))
	print("AD(PI, PI+0.1) = ", angle_difference(PI, PI + 0.1))
	var v := Vector3(1, 0, 0)
	var b := Basis(Vector3.UP, PI + 0.1)
	print("basis.yaw=PI+0.1  z=(", b.z.x, ", ", b.z.z, ")  -z=(", -b.z.x, ", ", -b.z.z, ")")
	quit()
