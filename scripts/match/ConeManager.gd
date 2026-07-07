class_name ConeManager
extends Node3D
## Spawns the two cone types:
##  - Border cones along the midline (knockable BorderCone physics bodies)
##  - Goal cones in each team's goal zone (stealable GoalCone pickup targets)
## Mirrors BallManager for the goal-cone simulation step + counting.

const ConeModel: PackedScene = preload("res://assets/props/cone.glb")
const BorderConeScript := preload("res://scripts/props/Cone.gd")
const GoalConeScript := preload("res://scripts/props/GoalCone.gd")

const CONE_HEIGHT := 2.6   # visual scale for the imported cone (≈2 units tall raw); sized to sit around a kid's knee, not tower over them

# World positions of the border (midline) cones, captured at spawn so NavManager
# can carve them out of the field navmesh. Read by Match after spawn_all().
var border_cone_positions: Array = []

func spawn_all() -> void:
	_spawn_border_line()
	_spawn_goal_cones()

# --- midline divider, knockable ---------------------------------------------
func _spawn_border_line() -> void:
	var n := Config.BORDER_CONE_COUNT
	for i in range(n):
		var t := float(i) / float(n - 1)
		var x := lerpf(-Config.FIELD_X + 4.0, Config.FIELD_X - 4.0, t)
		var body := RigidBody3D.new()
		body.set_script(BorderConeScript)
		# visual-only marker: no collision layers/mask, no collision shape at all
		body.collision_layer = 0
		body.collision_mask = 0
		add_child(body)
		_attach_model(body)
		var home := Transform3D(Basis(), Vector3(x, 0, 0))
		body.setup(home, i)
		border_cone_positions.append(Vector3(x, 0, 0))

# --- stealable goal cones ----------------------------------------------------
func _spawn_goal_cones() -> void:
	var idx := 0
	for team in ["blue", "red"]:
		var gz: float = Config.goal_pos(team).z
		var cnt := Config.GOAL_CONES_PER_TEAM
		for i in range(cnt):
			var area := Area3D.new()
			area.set_script(GoalConeScript)
			add_child(area)
			_attach_model(area)
			var col := CollisionShape3D.new()
			var shape := CylinderShape3D.new()
			shape.radius = 1.4
			shape.height = CONE_HEIGHT
			col.shape = shape
			# The Area3D node now rests at the cone's vertical CENTRE (GoalCone.REST_Y),
			# and the model is centre-origin, so the collision centres on the node
			# (offset 0) — spanning the visual cone rather than floating above it.
			col.position.y = 0.0
			area.add_child(col)
			var x := lerpf(-30.0, 30.0, float(i) / float(maxi(cnt - 1, 1)))
			var home := Vector3(x, 0, gz)
			area.setup(team, home, idx)
			idx += 1

func _attach_model(parent: Node) -> void:
	var m := ConeModel.instantiate()
	m.name = "Model"
	m.scale = Vector3(CONE_HEIGHT * 0.5, CONE_HEIGHT * 0.5, CONE_HEIGHT * 0.5)
	parent.add_child(m)
