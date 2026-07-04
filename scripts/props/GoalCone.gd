class_name GoalCone
extends Area3D
## A stealable goal cone. Shares the carryable surface with Ball so Actors and AI
## treat it the same — but it is carry-only (you can't throw or pass a cone; you
## run it back to your goalie by hand, per the brief). States reuse Ball's enum
## values via get_state(): HOME(0) / CARRIED(1) / LOOSE(3). No IN_FLIGHT.

const IS_BALL := false
const RADIUS := 1.6
const HOLD_HEIGHT := 3.6
const HOLD_FORWARD := 2.6
const HOLD_RIGHT := 1.4

var state: int = 0          # 0 HOME, 1 CARRIED, 3 LOOSE (matches Ball.State)
var team: String = "blue"
var origin_team: String = "blue"   # for restart: where this target started
var _origin_home: Vector3 = Vector3.ZERO
var carrier: Node = null
var home_pos: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO   # always zero; present for shared surface
var id: int = 0

func setup(p_team: String, p_home: Vector3, p_id: int) -> void:
	team = p_team
	origin_team = p_team
	home_pos = p_home
	_origin_home = p_home
	id = p_id
	add_to_group("goal_cones")
	add_to_group("carryables")
	_tint()
	to_home()

func restore_origin() -> void:
	team = origin_team
	home_pos = _origin_home
	carrier = null
	set_team(team)
	to_home()

func get_state() -> int:
	return state

func is_ball() -> bool:
	return false

func _tint() -> void:
	var mi := _find_mesh(self)
	if mi == null:
		return
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.3, 0.55, 1.0) if team == "blue" else Color(1.0, 0.4, 0.32)
	m.emission_enabled = true
	m.emission = Color(0.1, 0.2, 0.4) if team == "blue" else Color(0.4, 0.1, 0.08)
	mi.set_surface_override_material(0, m)

func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r != null:
			return r
	return null

func set_team(t: String) -> void:
	team = t
	_tint()

func to_home() -> void:
	state = 0
	carrier = null
	global_position = home_pos
	rotation = Vector3.ZERO
	Events.ball_state_changed.emit(self)

func to_loose(at: Vector3) -> void:
	state = 3
	carrier = null
	global_position = Vector3(at.x, RADIUS, at.z)
	Events.ball_state_changed.emit(self)

func on_picked_up(by: Node) -> void:
	state = 1
	carrier = by
	Events.ball_state_changed.emit(self)

func sim_step(_delta: float) -> void:
	if state == 1 and carrier != null:
		var hand: Node3D = null
		if carrier.has_method("get_hand_node"):
			hand = carrier.get_hand_node()
		if hand != null:
			global_position = hand.global_position
		else:
			var p: Vector3 = carrier.global_position
			var h: float = carrier.heading
			var fwd := Vector3(sin(h), 0, cos(h))
			var rgt := Vector3(-fwd.z, 0, fwd.x)
			global_position = p + fwd * HOLD_FORWARD + rgt * HOLD_RIGHT + Vector3(0, HOLD_HEIGHT, 0)
	elif state == 3:
		global_position.y = RADIUS

func is_grabbable_by(actor_team: String) -> bool:
	if carrier != null:
		return false
	if state == 3:
		return true
	if state == 0 and team == Config.enemy_of(actor_team):
		return true
	return false
