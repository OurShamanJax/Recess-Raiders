class_name Perception
extends RefCounted
## Per-NPC senses. Builds a "belief" each tick about what this bot can actually
## perceive — a vision cone (facing + FOV) with a raycast line-of-sight check,
## plus a wider proximity radius (you feel things close behind you even if you
## can't see them). The conductor and state behaviors read this instead of having
## every bot omnisciently know every position.

# Tunables (degrees/units). Exposed via Config so they're tweakable in one place.
var fov_cos: float          # cosine of half the field-of-view angle
var view_range: float
var proximity_range: float

var actor: Node

# Results, refreshed by sense():
var visible_enemies: Array = []        # enemies inside the cone with line of sight
var visible_carriers: Array = []       # subset of the above who carry something
var nearby_enemies: Array = []         # enemies inside proximity (felt, not necessarily seen)
var visible_targets: Array = []        # grabbable balls/cones in view
var nearest_visible_carrier: Node = null
var nearest_visible_carrier_dist: float = INF

func _init(p_actor: Node) -> void:
	actor = p_actor
	fov_cos = cos(deg_to_rad(Config.VISION_FOV_DEG * 0.5))
	view_range = Config.VISION_RANGE
	proximity_range = Config.PROXIMITY_RANGE

## Refresh perception. `facing` is the bot's current heading as a unit Vector3.
func sense(facing: Vector3) -> void:
	visible_enemies.clear()
	visible_carriers.clear()
	nearby_enemies.clear()
	visible_targets.clear()
	nearest_visible_carrier = null
	nearest_visible_carrier_dist = INF

	var my_pos: Vector3 = actor.global_position
	var my_team: String = actor.team
	var space: PhysicsDirectSpaceState3D = null
	if actor.is_inside_tree():
		space = actor.get_world_3d().direct_space_state

	for o in GameState.actors():
		if o == actor or o.team == my_team or o.is_tagged():
			continue
		var to: Vector3 = o.global_position - my_pos
		to.y = 0.0
		var dist: float = to.length()
		if dist < 0.001:
			continue
		var dir: Vector3 = to / dist

		# proximity: felt regardless of facing
		if dist <= proximity_range:
			nearby_enemies.append(o)

		# vision cone: within range, inside FOV, and (optionally) line of sight
		if dist <= view_range and facing.dot(dir) >= fov_cos:
			if _has_line_of_sight(space, my_pos, o):
				visible_enemies.append(o)
				if o.has_target():
					visible_carriers.append(o)
					if dist < nearest_visible_carrier_dist:
						nearest_visible_carrier_dist = dist
						nearest_visible_carrier = o
						# share with the team: a sighted carrier is the highest-value
						# threat news and propagates as a "shouted" team belief
						GameState.push_threat_belief(my_team, o.global_position)
					elif Config.intruding_into(my_team, o.global_position.z):
						GameState.push_threat_belief(my_team, o.global_position)

	# visible grabbable targets (balls + goal cones)
	for grp in ["balls", "goal_cones"]:
		for b in actor.get_tree().get_nodes_in_group(grp):
			if not b.is_grabbable_by(my_team):
				continue
			var tto: Vector3 = b.global_position - my_pos
			tto.y = 0.0
			var td: float = tto.length()
			if td <= view_range and (td < 0.001 or facing.dot(tto / td) >= fov_cos):
				visible_targets.append(b)

## Raycast from eye height to the target; blocked only by border cones (layer 2).
## Other actors don't block sight. If we can't query space, assume visible.
func _has_line_of_sight(space: PhysicsDirectSpaceState3D, from_pos: Vector3, target: Node) -> bool:
	if space == null:
		return true
	if not Config.VISION_USE_RAYCAST:
		return true
	var a := from_pos + Vector3.UP * 6.0
	var b: Vector3 = target.global_position + Vector3.UP * 6.0
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.collision_mask = 2          # border cones only
	q.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(q)
	return hit.is_empty()
