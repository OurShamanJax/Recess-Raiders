class_name Ball
extends RigidBody3D
## Football with REAL physics (bounce + roll) and an uncertain catch model.
## States: HOME / CARRIED / IN_FLIGHT / LOOSE.
##  - HOME: parked in a goal zone, frozen, counts for its team.
##  - CARRIED: kinematic, follows the carrier at hand height.
##  - IN_FLIGHT: dynamic rigidbody just thrown; catchable, can be intercepted.
##  - LOOSE: dynamic rigidbody at rest/rolling; grabbable by touch.
## A throw is NOT a guaranteed catch — see BallManager.try_catch() for the roll.

enum State { HOME, CARRIED, IN_FLIGHT, LOOSE }

const IS_BALL := true
const RADIUS := 1.25   # slightly smaller ball (was 1.5); scene collision matches

# Two ball models; each team fields one of each.
const MODEL_DEFAULT: PackedScene = preload("res://assets/props/ball.glb")
const MODEL_GREEN: PackedScene = preload("res://assets/props/ball_green.glb")
const HAND_HEIGHT := 3.6
const HAND_FORWARD := 2.6
const HAND_RIGHT := 1.4

var state: int = State.HOME
var team: String = "blue"
var origin_team: String = "blue"   # for restart: where this target started
var _origin_home: Vector3 = Vector3.ZERO
var carrier: Node = null
var home_pos: Vector3 = Vector3.ZERO
var intended_catcher: Node = null
var predicted_landing: Vector3 = Vector3.ZERO   # where the ball will come down (for receiver reaction)
# --- homing arc (locked throws) ---------------------------------------------
# A locked throw flies a kinematic arc that RE-AIMS at the catcher's live
# position every frame, so a moving target can't outrun the pass. Unlocked
# (free) throws leave _homing false and use plain physics.
var _homing := false
var _homing_start := Vector3.ZERO
var _homing_elapsed := 0.0
var _homing_total := 0.8
var _homing_arc := 0.35
var thrower: Node = null
var id: int = 0
var _flight_time := 0.0          # how long it's been airborne (catch grace)
var _catch_lock := 0.0           # brief no-catch window after a fumble

func setup(p_team: String, p_home: Vector3, p_id: int, model_variant: int = 0) -> void:
	team = p_team
	origin_team = p_team
	home_pos = p_home
	_origin_home = p_home
	id = p_id
	# attach the visual model (variant 0 = default, 1 = green)
	var model_scene: PackedScene = MODEL_GREEN if model_variant == 1 else MODEL_DEFAULT
	var model := model_scene.instantiate()
	model.name = "Model"
	model.scale = Vector3(RADIUS, RADIUS, RADIUS)
	add_child(model)
	add_to_group("balls")
	add_to_group("carryables")
	# physics setup
	gravity_scale = 1.0
	mass = 0.6
	contact_monitor = true
	max_contacts_reported = 4
	physics_material_override = PhysicsMaterial.new()
	physics_material_override.bounce = 0.55
	physics_material_override.friction = 0.6
	collision_layer = 4          # balls on layer 3 (value 4)
	collision_mask = 2 + 8       # bounce off border cones(2) + ground(8); pass through actors
	to_home()

func restore_origin() -> void:
	team = origin_team
	home_pos = _origin_home
	carrier = null
	to_home()

func get_state() -> int:
	return state

func is_ball() -> bool:
	return true

func set_team(t: String) -> void:
	team = t

func _freeze(v: bool) -> void:
	freeze = v
	if v:
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		sleeping = true

func to_home() -> void:
	state = State.HOME
	carrier = null
	intended_catcher = null
	_homing = false
	thrower = null
	# HOME balls are fully immovable — STATIC freeze + no gravity — so they never
	# drift or roll on the field until an actor steals and drops one.
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	gravity_scale = 0.0
	_freeze(true)
	global_position = Vector3(home_pos.x, RADIUS, home_pos.z)
	rotation = Vector3.ZERO
	Events.ball_state_changed.emit(self)

func to_loose(at: Vector3) -> void:
	state = State.LOOSE
	carrier = null
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	gravity_scale = 1.0          # gains the ability to fall/roll once stolen & dropped
	freeze = false
	sleeping = false
	global_position = Vector3(at.x, RADIUS + 0.2, at.z)
	Events.ball_state_changed.emit(self)

func on_picked_up(by: Node) -> void:
	state = State.CARRIED
	carrier = by
	intended_catcher = null
	_homing = false
	thrower = null
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	_freeze(true)
	Events.ball_state_changed.emit(self)

## Throw/pass: launch as a real rigidbody with an arc. catcher is the intended
## teammate (gets a small catch bonus); thrower is excluded from catching its own.
func launch(dir: Vector3, speed: float, up: float, from: Vector3, catcher: Node, p_thrower: Node) -> void:
	state = State.IN_FLIGHT
	carrier = null
	intended_catcher = catcher
	thrower = p_thrower
	_flight_time = 0.0
	_catch_lock = 0.0
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	freeze = false
	sleeping = false
	gravity_scale = Config.THROW_GRAVITY_SCALE   # heavier in flight -> tighter arc
	global_position = Vector3(from.x, HAND_HEIGHT, from.z)
	var v := dir.normalized() * speed
	v.y = up
	linear_velocity = v
	angular_velocity = Vector3(randf_range(-4, 4), randf_range(-2, 2), randf_range(-4, 4))
	Events.ball_state_changed.emit(self)

## Football-style throw: compute the launch velocity that lands the ball AT a
## target point with a pleasing arc, instead of firing at a fixed huge speed
## (which sailed the ball off the map). dir/range are derived from the target.
func launch_to(target: Vector3, arc: float, from: Vector3, catcher: Node, p_thrower: Node) -> void:
	state = State.IN_FLIGHT
	carrier = null
	intended_catcher = catcher
	thrower = p_thrower
	_flight_time = 0.0
	_catch_lock = 0.0
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	freeze = false
	sleeping = false
	var start := Vector3(from.x, HAND_HEIGHT, from.z)
	global_position = start

	if catcher != null and is_instance_valid(catcher):
		# LOCKED throw → kinematic homing arc that re-aims at the catcher each
		# frame. No physics velocity; sim_step drives the position.
		_homing = true
		_homing_start = start
		_homing_elapsed = 0.0
		_homing_arc = arc
		gravity_scale = 0.0
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3(randf_range(-4, 4), randf_range(-2, 2), randf_range(-4, 4))
		# flight time scales with distance so near/far passes both feel right
		var d: float = start.distance_to(target)
		_homing_total = clampf(d / 28.0, 0.45, 1.6)
		predicted_landing = target
	else:
		# FREE throw → plain physics launch (rolls/bounces, anyone can chase)
		_homing = false
		gravity_scale = Config.THROW_GRAVITY_SCALE
		var g: float = 9.8 * Config.THROW_GRAVITY_SCALE
		var to: Vector3 = target - start
		var flat := Vector3(to.x, 0, to.z)
		var horiz_dist: float = flat.length()
		if horiz_dist < 0.5:
			horiz_dist = 0.5
		var peak: float = clampf(horiz_dist * arc, 4.0, 30.0)
		var vy: float = sqrt(2.0 * g * peak)
		var dy: float = to.y
		var t_up: float = vy / g
		var t_down: float = sqrt(maxf(0.01, 2.0 * (peak - dy) / g))
		var t_total: float = t_up + t_down
		var horiz_speed: float = horiz_dist / t_total
		var dir := flat.normalized()
		linear_velocity = dir * horiz_speed + Vector3(0, vy, 0)
		angular_velocity = Vector3(randf_range(-3, 3), randf_range(-2, 2), randf_range(-3, 3))
		predicted_landing = target
	_notify_receiver()
	Events.ball_state_changed.emit(self)

## The live landing point of a homing throw — the catcher's current position.
## The HUD reads this to draw the arc line that bends as the target moves.
func homing_target() -> Vector3:
	if _homing and intended_catcher != null and is_instance_valid(intended_catcher):
		var p: Vector3 = intended_catcher.global_position
		return Vector3(p.x, HAND_HEIGHT, p.z)
	return predicted_landing

func is_homing() -> bool:
	return _homing and state == State.IN_FLIGHT

## End the homing arc and return the ball to physics. Called on arrival (the
## catch resolver then converts it for whoever's there) or if the target is lost.
func _end_homing() -> void:
	_homing = false
	gravity_scale = Config.THROW_GRAVITY_SCALE
	# give it a gentle continuing motion so if uncaught it falls/rolls naturally
	var fwd: Vector3 = (homing_target() - global_position)
	fwd.y = 0
	if fwd.length() > 0.1:
		linear_velocity = fwd.normalized() * 4.0
	else:
		linear_velocity = Vector3.ZERO
	_flight_time = maxf(_flight_time, 0.3)   # eligible to settle to LOOSE soon

## Tell the intended catcher a ball is incoming so they can react (NPC breaks to
## the landing spot; player gets the catch prompt). This is the link that turns a
## blind launch into a real pass.
func _notify_receiver() -> void:
	if intended_catcher != null and is_instance_valid(intended_catcher):
		if intended_catcher.has_method("on_incoming_pass"):
			intended_catcher.on_incoming_pass(self)
	Events.pass_thrown.emit(self, intended_catcher)

## Force this ball into a clean catch by an actor (used by the player QTE).
func force_catch(by: Node) -> void:
	carrier = by
	by.carried = self
	intended_catcher = null
	_homing = false
	predicted_landing = Vector3.ZERO
	set_team(by.team)
	on_picked_up(by)
	Events.ball_state_changed.emit(self)

## Drop the ball loose where it is (used when the player muffs the QTE).
func drop_loose() -> void:
	# The catch failed — DON'T freeze the ball in the air. Let it carry on past
	# the catcher along its arc and fall naturally to the ground, where it
	# becomes a LOOSE ball anyone can snag as it rolls. Restore physics and give
	# it a continuing forward+downward velocity so it arcs down believably.
	var fwd := Vector3.ZERO
	if intended_catcher != null and is_instance_valid(intended_catcher):
		fwd = (intended_catcher.global_position - global_position)
	fwd.y = 0.0
	if fwd.length() < 0.1:
		fwd = Vector3(sin(randf() * TAU), 0, cos(randf() * TAU))
	fwd = fwd.normalized()
	state = State.LOOSE
	carrier = null
	intended_catcher = null
	_homing = false
	_catch_lock = 0.4
	freeze = false
	gravity_scale = Config.THROW_GRAVITY_SCALE     # restore gravity so it falls
	# carry past the would-be catcher and drop — a gentle forward toss + slight
	# upward so it finishes the arc instead of dead-dropping
	linear_velocity = fwd * 11.0 + Vector3(0, 2.5, 0)
	angular_velocity = Vector3(randf_range(-4, 4), randf_range(-2, 2), randf_range(-4, 4))
	Events.ball_state_changed.emit(self)

## Called by BallManager each physics frame.
func sim_step(delta: float) -> void:
	match state:
		State.CARRIED:
			if carrier != null:
				# follow the actual animated hand bone if available, else fall back
				# to the heading-based offset (keeps working if no rig/skeleton)
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
					global_position = p + fwd * HAND_FORWARD + rgt * HAND_RIGHT + Vector3(0, HAND_HEIGHT, 0)
		State.IN_FLIGHT:
			_flight_time += delta
			_catch_lock = maxf(0.0, _catch_lock - delta)
			if _homing:
				# kinematic homing arc: interpolate start → catcher's LIVE position,
				# with a parabolic lift for the arc. Re-aiming every frame is what
				# lets the ball track a moving target instead of landing where the
				# target used to be.
				if intended_catcher == null or not is_instance_valid(intended_catcher) \
						or intended_catcher.is_tagged():
					_end_homing()       # target gone → drop to physics
				else:
					_homing_elapsed += delta
					var t: float = clampf(_homing_elapsed / _homing_total, 0.0, 1.0)
					var tgt: Vector3 = homing_target()
					var flat: Vector3 = _homing_start.lerp(tgt, t)
					var span: float = _homing_start.distance_to(tgt)
					var peak: float = clampf(span * _homing_arc, 2.0, 16.0)
					var lift: float = 4.0 * peak * t * (1.0 - t)   # parabola, 0 at ends
					global_position = Vector3(flat.x, flat.y + lift, flat.z)
					if t >= 1.0:
						# arrived at the catcher — hand off to the catch resolver by
						# dropping into a catchable low-velocity state right on them
						_end_homing()
			elif global_position.y <= RADIUS + 0.4 and linear_velocity.length() < 6.0 and _flight_time > 0.25:
				# physics (free) throw settled near the ground → loose
				state = State.LOOSE
				Events.ball_state_changed.emit(self)
		State.LOOSE:
			pass  # physics handles rolling/resting
	# Keep the ball on the field: bounce off the boundary when free-moving. The
	# player can leave the field, but the ball always stays in play.
	# Only keep LOOSE (rolling/settling) balls on the field. A thrown ball
	# (IN_FLIGHT) arcs to a target and must fly unobstructed — bouncing it
	# mid-flight made throws ricochet off the field edge near safe zones.
	if state == State.LOOSE:
		_bounce_off_bounds()

func _bounce_off_bounds() -> void:
	var bx: float = Config.FIELD_X
	var bz: float = Config.FIELD_Z
	var v := linear_velocity
	var bounced := false
	if global_position.x > bx and v.x > 0.0:
		v.x = -v.x * 0.6; global_position.x = bx; bounced = true
	elif global_position.x < -bx and v.x < 0.0:
		v.x = -v.x * 0.6; global_position.x = -bx; bounced = true
	if global_position.z > bz and v.z > 0.0:
		v.z = -v.z * 0.6; global_position.z = bz; bounced = true
	elif global_position.z < -bz and v.z < 0.0:
		v.z = -v.z * 0.6; global_position.z = -bz; bounced = true
	if bounced:
		linear_velocity = v

func is_grabbable_by(actor_team: String) -> bool:
	if carrier != null:
		return false
	if state == State.LOOSE:
		return true
	if state == State.HOME and team == Config.enemy_of(actor_team):
		return true
	return false

## Can this actor attempt a catch right now? (in flight, not the thrower mid-throw)
func is_catchable() -> bool:
	return state == State.IN_FLIGHT and _catch_lock <= 0.0

func fumble_lock() -> void:
	_catch_lock = 0.25
