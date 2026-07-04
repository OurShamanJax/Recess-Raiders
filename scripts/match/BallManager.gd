class_name BallManager
extends Node3D
## Owns the balls, steps all carryables, and resolves the UNCERTAIN catch model
## (spec'd with the new throw mechanic). Keeps GameState steal-target counts in
## sync. Authoritative — ball motion + catch rolls happen only here.

const BallScene := preload("res://scenes/Ball.tscn")

func spawn_balls() -> void:
	var idx := 0
	for i in range(Config.BALLS_PER_TEAM):
		var spread := (float(i) - float(Config.BALLS_PER_TEAM - 1) * 0.5) * 22.0
		# alternate the two ball models so each team fields one of each look
		var variant := i % 2
		_spawn("blue", Vector3(spread, Ball.RADIUS, Config.GOAL_BLUE_Z - 8.0), idx, variant); idx += 1
		_spawn("red", Vector3(spread, Ball.RADIUS, Config.GOAL_RED_Z + 8.0), idx, variant); idx += 1
	_recount()

func _spawn(team: String, home: Vector3, id: int, variant: int) -> void:
	var b: Ball = BallScene.instantiate()
	add_child(b)
	b.setup(team, home, id, variant)

func _ready() -> void:
	Events.ball_banked.connect(_on_changed)
	Events.ball_state_changed.connect(_on_changed)

func _on_changed(_x = null) -> void:
	_recount()

func _physics_process(delta: float) -> void:
	if GameState.phase != GameState.Phase.PLAYING:
		return
	for c in get_tree().get_nodes_in_group("carryables"):
		c.sim_step(delta)
	_resolve_catches()

## Uncertain catch model: any actor near an in-flight ball may ATTEMPT a catch.
## The attempt succeeds on a probability roll built from facing, distance from the
## ball, contest, the thrower's accuracy, and the catcher's difficulty. Possible
## results per attempt: clean catch, fumble (deflect + stay live), or no contact.
func _resolve_catches() -> void:
	for b in get_tree().get_nodes_in_group("balls"):
		if not b.is_catchable():
			continue
		if b.global_position.y > 12.0:
			continue  # too high to reach yet

		# find the best-positioned actor attempting this ball
		var receiver: Node = b.intended_catcher
		var receiver_is_player: bool = receiver != null and is_instance_valid(receiver) and receiver.is_user
		var contenders: Array = []
		for a in GameState.actors():
			if a.is_tagged() or a.has_target() or a == b.thrower:
				continue
			# RECEIVER RULE: when this throw has an intended catcher, the proximity
			# roll must not let uninvolved bystanders vacuum the ball. Only the
			# intended NPC catcher and ENEMIES of the thrower (interceptors) may
			# contend. If the receiver is the player, the QTE owns the catch — so
			# no NPC teammate may grab it out from under the player either.
			if receiver != null and is_instance_valid(receiver):
				var is_enemy_of_thrower: bool = b.thrower != null and is_instance_valid(b.thrower) and a.team != b.thrower.team
				if receiver_is_player:
					if not is_enemy_of_thrower:
						continue            # only interceptors; player handles own catch via QTE
				else:
					if a != receiver and not is_enemy_of_thrower:
						continue            # only the intended catcher or an interceptor
			var to_ball: Vector3 = b.global_position - a.global_position
			to_ball.y = 0.0
			var d: float = to_ball.length()
			if d <= Config.CATCH_RADIUS * 1.6:
				contenders.append({"actor": a, "dist": d, "dir": to_ball})
		if contenders.is_empty():
			continue

		var contested := contenders.size() > 1
		# process nearest first
		contenders.sort_custom(func(ca, cb): return ca["dist"] < cb["dist"])

		for c in contenders:
			var a = c["actor"]
			var cdir: Vector3 = c["dir"]
			var cdist: float = c["dist"]
			var p := _catch_probability(b, a, cdist, cdir, contested)
			var roll := randf()
			if roll < p:
				# clean catch — this actor's team gains possession
				var was_intended: bool = (b.intended_catcher == a)
				b.carrier = a
				a.carried = b
				b.set_team(a.team)        # caught ball now counts for catcher's team
				b.on_picked_up(a)
				# feel/sound hook: was this the intended receiver, or a pick?
				if was_intended:
					Events.pass_caught.emit(a)
				else:
					Events.pass_intercepted.emit(a)
				break
			elif roll < p + Config.FUMBLE_BAND:
				# fumble: deflect the ball, keep it live, brief no-catch lock
				var push: Vector3 = cdir.normalized() * -6.0 + Vector3.UP * 4.0
				b.linear_velocity = b.linear_velocity * 0.4 + push
				b.fumble_lock()
				break
			# else: this contender misses entirely; next contender may try

## Build the catch chance for one actor on one ball. Returns 0..~0.95.
func _catch_probability(ball: Ball, actor: Node, dist: float, to_ball: Vector3, contested: bool) -> float:
	# base by how centered the ball is in the catch radius (closer = easier)
	var closeness := clampf(1.0 - dist / (Config.CATCH_RADIUS * 1.6), 0.0, 1.0)
	var p := Config.CATCH_BASE * closeness

	# facing: are they looking toward the incoming ball?
	var facing := Vector3(sin(actor.heading), 0, cos(actor.heading))
	var face_dot := facing.dot(to_ball.normalized()) if to_ball.length() > 0.01 else 1.0
	# map -1..1 -> a 0.45..1.15 multiplier (catch from behind is much worse)
	p *= lerpf(0.45, 1.15, clampf((face_dot + 1.0) * 0.5, 0.0, 1.0))

	# intended catcher gets a hands bonus; surprise interceptions are harder
	if ball.intended_catcher == actor:
		p *= 1.2
	else:
		p *= Config.INTERCEPT_FACTOR

	# AI skill: a bot's difficulty weight nudges its hands; the human is neutral
	if not actor.is_user:
		p *= lerpf(0.8, 1.1, Config.ai_val("aim"))

	# contested balls are harder for everyone (batted around)
	if contested:
		p *= 0.7

	return clampf(p, 0.0, 0.95)

func recount() -> void:
	_recount()

func _recount() -> void:
	var blue := 0
	var red := 0
	for grp in ["balls", "goal_cones"]:
		for c in get_tree().get_nodes_in_group(grp):
			if c.team == "blue":
				blue += 1
			else:
				red += 1
	GameState.set_counts(blue, red)
