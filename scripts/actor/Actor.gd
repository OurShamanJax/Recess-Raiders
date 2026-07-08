class_name Actor
extends CharacterBody3D
## Simulation entity (spec §6) + expanded mechanics:
##  - carries either a Ball or a GoalCone (shared "carryable" surface)
##  - look-at + interact pickup (must face the target within LOOK_DOT)
##  - throw/pass only valid when carrying a BALL (cones are carry-only)
##  - tagged-out: sit and wait for a teammate to revive; auto-return on timeout
##  - drives the animated CharacterRig (walk<->run blend, dead, arise)
## Reads one Intent/physics-frame from its injected controller; knows nothing
## about who controls it.

@export var team: String = "blue"
@export var role: String = "striker"
@export var is_user: bool = false

# --- attribute/stat system (Phase 1 scaffolding) ---
var display_name: String = "Kid"
var sex: String = "M"               # "M" / "F" — shown in nametag
var height_cm: float = 130.0        # taller = more stamina, faster baseline burn
var weight_kg: float = 32.0         # heavier = shorter throws, faster burn

var id: int = 0
var stamina: float = Config.STAMINA_MAX
var heading: float = 0.0
var carried: Node = null               # Ball or GoalCone (or null)
var _tagged := false
var _revive_timer := 0.0               # counts up while tagged; auto-return at timeout
var _downed_time := 0.0                # counts up while tagged; revive is BLOCKED until
									   # this passes REVIVE_MIN_DOWNED, so a surrounded
									   # player can't get stuck in a down->revive->down
									   # jitter loop when friends and enemies overlap
var spawn_pos: Vector3 = Vector3.ZERO
var _interact_cooldown := 0.0
# Bench sitting. When _sitting, the player is snapped to _sit_pos and locked in
# place until they press E again. No sit animation yet, so the model stands
# rigidly on the bench (looks janky by design until an anim is added).
var _sitting := false
var _sit_pos := Vector3.ZERO
var _sit_heading := 0.0         # facing while seated (from the bench's orientation)
# standing spot and the seated spot over the transition, matching the animation so
var _sit_cooldown := 0.0
# While > 0 the player stays pinned after pressing E to stand, so the stand-up
# animation can play before control returns. Only used for models with sit clips.
var _stand_lock := 0.0
var _tag_cooldown := 0.0          # short window after a successful tag so you can't spam
var _tag_grace := 0.0             # untaggable window right after a revive (anti tag-camping)

## A teammate has thrown a ball to this actor. Record it so the controller (AI or
## player) can react — break to the landing spot / show the catch prompt.
func on_incoming_pass(ball: Node) -> void:
	incoming_ball = ball
	incoming_pass_time = 2.5      # how long we expect the ball to be in the air-ish
	if controller != null and controller.has_method("on_incoming_pass"):
		controller.on_incoming_pass(ball)

## The animated hand node (RightHand bone attachment) carried items follow, so
## balls and cones ride the actual hand instead of floating at a guessed offset.
func get_hand_node() -> Node3D:
	if rig != null and rig.has_method("get_hand_attachment"):
		return rig.get_hand_attachment()
	return null

## Best enemy this actor could tag right now: nearest taggable enemy within reach,
## strongly preferring one the player is looking at. Returns null if none. Used by
## the HUD to show the "Press E to tag" prompt and by the player to act on it.
## SINGLE SOURCE OF TRUTH for "can I tag this enemy right now". Every tag path
## (player manual, universal auto-tag, AI chase target selection) routes through
## this so the rules can't drift apart again. An enemy is taggable if they're
## carrying our loot, OR they're intruding on our half and not safe in a pod.
func can_tag(e: Node) -> bool:
	if e == null or not is_instance_valid(e):
		return false
	# debug fly-cam (god mode): the player is "not really there" — NPCs can't tag
	# or interact with them while you're flying around inspecting the map.
	if GameState.debug_mode and "is_user" in e and e.is_user:
		return false
	if e == self or e.team == team or e.is_tagged():
		return false
	# post-revive grace: freshly revived kids can't be instantly re-tagged
	if "_tag_grace" in e and e._tag_grace > 0.0:
		return false
	# vertical gate: someone well above/below you (mid-jump, on a mound) is out of
	# arm's reach — jumping over a tagger is now a real dodge
	if absf(e.global_position.y - global_position.y) > Config.TAG_HEIGHT_TOL:
		return false
	if e.has_target():
		# A carrier holding stolen loot is ALWAYS fair game until they actually
		# bank it — no safe-zone immunity, no "deep in their own half" exemption.
		# The whole run home is meant to be risky; letting a thief become
		# untaggable by camping a pod or crossing a line removed the core tension.
		return true
	# An empty-handed enemy is only taggable while intruding on our half and not
	# resting in a safe zone (a breather, not a free pass to steal).
	return Config.intruding_into(team, e.global_position.z) and not e.in_own_pod()

var _last_tag_target_id: int = 0     # stabilizes tag selection in a crowd

func best_tag_target() -> Node:
	# TWO-TIER tagging so a crowd can't steal your tag:
	#   TIER 1 (AIM): if any taggable enemy is under your reticle (aim_dot >=
	#     LOOK_DOT, i.e. genuinely in your crosshair cone) and within the aimed
	#     reach (PLAYER_ACTION_RANGE), tag the MOST dead-on one. This wins outright
	#     — proximity never overrides who you're actually looking at.
	#   TIER 2 (PROXIMITY): only if nobody is under the reticle, fall back to the
	#     closest enemy within contact range (TAG_RADIUS), regardless of facing.
	# In fp/third modes `heading` tracks the camera/reticle, so `look` is your aim.
	var look := Vector3(sin(heading), 0, cos(heading))
	var aim_reach: float = Config.PLAYER_ACTION_RANGE
	var prox_reach: float = Config.TAG_RADIUS
	var cone_dot: float = Config.LOOK_DOT   # how centered an enemy must be to count as "aimed at"

	var best_aim: Node = null
	var best_aim_dot: float = -INF
	var best_prox: Node = null
	var best_prox_dist: float = INF

	for e in GameState.actors():
		if not can_tag(e):
			continue
		var to: Vector3 = e.global_position - global_position
		to.y = 0
		var dist: float = to.length()
		if dist < 0.001:
			continue
		var aim_dot: float = look.dot(to / dist)

		# TIER 1 candidate: under the reticle and within aimed reach.
		if aim_dot >= cone_dot and dist <= aim_reach:
			# prefer the most-centered; hysteresis keeps a held target sticky in a
			# crowd so the pick doesn't flicker frame to frame.
			var effective_dot: float = aim_dot
			if e.get_instance_id() == _last_tag_target_id:
				effective_dot += 0.15
			if effective_dot > best_aim_dot:
				best_aim_dot = effective_dot
				best_aim = e

		# TIER 2 candidate: within contact range (used only if no aim winner).
		if dist <= prox_reach:
			var effective_dist: float = dist
			if e.get_instance_id() == _last_tag_target_id:
				effective_dist -= 0.5   # sticky bonus (treated as slightly closer)
			if effective_dist < best_prox_dist:
				best_prox_dist = effective_dist
				best_prox = e

	var best: Node = best_aim if best_aim != null else best_prox
	_last_tag_target_id = best.get_instance_id() if best != null else 0
	return best

## The enemy an NPC will tag: nearest eligible enemy within tag reach. Same
## can_tag() rule as the player, but no aim term (NPCs have no camera) and uses
## TAG_RADIUS (the close-contact range), with a small bonus reach for carriers.
func _npc_tag_target() -> Node:
	var best: Node = null
	var best_d: float = INF
	for e in GameState.actors():
		if not can_tag(e):
			continue
		var d: float = global_position.distance_to(e.global_position)
		var reach: float = Config.TAG_RADIUS + (2.0 if e.has_target() else 0.0)
		if d < reach and d < best_d:
			best_d = d
			best = e
	return best

## Best downed teammate this actor could revive right now (same selection logic).
func best_revive_target() -> Node:
	var reach: float = Config.PLAYER_ACTION_RANGE
	var look := Vector3(sin(heading), 0, cos(heading))
	var best: Node = null
	var best_score: float = -INF
	for d in GameState.actors():
		if d == self or d.team != team or not d.is_tagged():
			continue
		var to: Vector3 = d.global_position - global_position
		to.y = 0
		var dist: float = to.length()
		if dist > reach or dist < 0.001:
			continue
		var aim_dot: float = look.dot(to / dist)
		var score: float = (1.0 - dist / reach) + aim_dot * 0.8
		if score > best_score:
			best_score = score; best = d
	return best

## Whether the player is currently sitting on a bench.
func is_sitting() -> bool:
	return _sitting

## Nearest bench within sit range (and roughly in front of the player), or null.
## Used by the HUD to show the "Press E To Sit" prompt. The sit action itself is
## not wired yet — this just powers the prompt for now.
func nearest_bench() -> Node3D:
	var reach := 6.0
	var best: Node3D = null
	var best_dist := reach
	for b in get_tree().get_nodes_in_group("benches"):
		if not (b is Node3D):
			continue
		var to: Vector3 = (b as Node3D).global_position - global_position
		to.y = 0
		var dist: float = to.length()
		if dist < best_dist:
			best_dist = dist
			best = b
	return best

## Toggle sitting on a bench. On sit: snap the player to the bench's center and
## lock them there. On stand: unlock. There's no sit animation yet, so the model
## just stands rigidly at the seat — intentionally janky until an anim exists.
func _toggle_sit(bench: Node3D) -> void:
	_sitting = not _sitting
	if _sitting:
		# face the SAME way the bench visually faces (outward toward the field).
		# The bench model's front is along its local +Z after rotation, so take that
		# as the seated forward and turn it into a heading. Derived from the bench's
		# own yaw so it stays correct wherever a bench is placed.
		var fwd: Vector3 = bench.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		_sit_heading = atan2(fwd.x, fwd.z)
		heading = _sit_heading
		# Snap to the seat. Models WITH a sit animation get raised to seat height
		# and nudged toward the seat's front edge so the seated pose rests ON the
		# seat with the legs hanging in front (pinning at ground level at the bench
		# center sank the body into the bench). Models without sit clips keep the
		# old center pin. Both offsets are first-draft tunables.
		var bp := bench.global_position
		var has_anim: bool = rig != null and rig.has_sit()
		# per-def sit offsets (different sit clips drop the hips differently), with
		# sensible defaults for models without a sit animation
		var seat_raise: float = 0.0
		var fwd_off: float = 0.0
		if has_anim:
			var def: CharacterDef = rig.get_def()
			seat_raise = def.sit_raise if def != null else 0.9
			fwd_off = def.sit_forward if def != null else 1.0
		_sit_pos = Vector3(bp.x, global_position.y + seat_raise, bp.z) + fwd * fwd_off
		global_position = _sit_pos
		_y_vel = 0.0
		# play the sit-down animation (now trimmed to start at the descent, so the
		# legs drop straight onto the seat instead of hanging through the bench
		# during a long standing phase)
		if has_anim:
			rig.play_sit()
	else:
		# standing up: play the stand animation, hold briefly so the rise reads
		if rig != null and rig.has_sit():
			rig.play_stand()
			_stand_lock = 0.6
	_sit_cooldown = 0.35

## Set or clear what this actor is carrying, and update the carrier-highlight
## glow on the rig so the player can see who has loot at a glance.
func _set_carried(item) -> void:
	carried = item
	if rig != null and rig.has_method("set_carrier_highlight"):
		rig.set_carrier_highlight(item != null)
var _y_vel := 0.0
var _crouching := false
var _sprinting := false
# sprint-exhaustion latch: true once stamina hits 0, cleared only after stamina
# recovers past SPRINT_RECOVER_FRAC — stops walk<->sprint oscillation at empty
var _gassed := false
var _was_on_floor := true   # for landing detection (air -> floor transition)
# pending animated-throw release: play_throw winds up, then the ball leaves the
# hand at the anim's release frame (THROW_ANIM_RELEASE_DELAY after start)
var _pending_release_timer := 0.0
var _pending_release_pass := false
var _pending_release_aim := Vector3.ZERO
# our own smoothed horizontal velocity for the momentum system — kept separate from
# CharacterBody3D.velocity, which move_and_slide rewrites on collisions
var _move_vel := Vector2.ZERO
# last spot this actor stood safely on the floor — the fall-through safety net
# restores here (nearby) instead of yanking them across the map to spawn
var _last_safe_pos := Vector3.ZERO
var _has_safe_pos := false

func is_sprinting() -> bool:
	return _sprinting

## Stat-derived modifiers. Tuned subtle so they flavor play without breaking balance.
func _burn_mult() -> float:
	# heavier + taller burn faster; normalized around the average kid
	var w := (weight_kg - 32.0) / 32.0      # -0.19..+0.31
	var h := (height_cm - 130.0) / 130.0    # -0.08..+0.12
	return clampf(1.0 + w * 0.5 + h * 0.4, 0.7, 1.6)

func _stamina_max() -> float:
	# taller kids have a bigger pool
	return Config.STAMINA_MAX * clampf(1.0 + (height_cm - 130.0) / 130.0 * 0.6, 0.85, 1.3)

func _throw_mult() -> float:
	# heavier kids throw shorter
	return clampf(1.0 - (weight_kg - 32.0) / 32.0 * 0.35, 0.65, 1.2)

var controller: BaseController = null
var rig: CharacterRig = null           # presentation
var incoming_ball: Node = null         # a ball is being thrown to me (catch reaction)
var incoming_pass_time: float = 0.0    # countdown while expecting the catch
var lock_target: Node = null           # player's locked pass target (reticle), switchable

func _ready() -> void:
	add_to_group("kids")
	GameState.stat_row(self)   # register on the scoreboard from frame one
	add_to_group("actors")
	# Keep the character glued to the ground when walking over terrain whose
	# height changes (up or down). Without a snap length, descending a slope
	# briefly launches the body into the air and the next frame it catches lower
	# down — which reads as clipping/jitter through the ground. A generous snap
	# plus a high walkable angle fixes both up- and down-slope movement.
	floor_snap_length = 4.0
	floor_max_angle = deg_to_rad(70.0)
	floor_stop_on_slope = false
	floor_constant_speed = true
	_setup_nav_agent()

# A NavigationAgent3D used PURELY as a pathfinder (not as a mover). The AI reads
# the next path corner from it so it routes AROUND the border-cone field instead
# of walking into it; local separation/threat steering stays in AIController.
# This is fail-safe: if no NavigationRegion3D is baked, get_next_path_position()
# returns the target itself, so movement degrades to the old straight-line seek.
var nav_agent: NavigationAgent3D = null

func _setup_nav_agent() -> void:
	nav_agent = NavigationAgent3D.new()
	# radius a touch above the body so paths keep clear of obstacle edges; the
	# agent does NOT drive velocity (avoidance off), it only computes the path.
	nav_agent.radius = 2.0
	nav_agent.height = 4.0
	nav_agent.path_desired_distance = 3.0
	nav_agent.target_desired_distance = 3.0
	nav_agent.avoidance_enabled = false
	nav_agent.path_max_distance = 12.0
	add_child(nav_agent)

func setup(p_team: String, p_role: String, p_user: bool, p_id: int) -> void:
	team = p_team
	role = p_role
	is_user = p_user
	id = p_id
	# The player can collide with the school's solid walls (layer 5 = bit 16) so
	# they can explore the building. Game-mode bots do NOT — they stay on the
	# field and never path into the school, so they keep the narrow world mask.
	if is_user:
		collision_mask = 9 | 16

# --- shared queries the AI/Actor use ----------------------------------------
func has_target() -> bool:        # "is carrying something"
	return carried != null
func has_ball() -> bool:
	return carried != null and carried.has_method("is_ball") and carried.is_ball()
func carrying_is_ball() -> bool:
	return has_ball()
func is_tagged() -> bool:
	return _tagged

## Seconds remaining until this actor auto-returns to spawn while tagged out.
## Used by the HUD to show the player's respawn countdown. 0 if not tagged.
func respawn_seconds_left() -> float:
	if not _tagged:
		return 0.0
	return maxf(0.0, Config.REVIVE_AUTO_TIMEOUT - _revive_timer)

var _is_safe := false
var _safe_seconds_left := 0.0   # remaining dwell time in the current safe zone

func in_own_pod() -> bool:
	# now driven by SafeZoneManager (occupancy + dwell + lockout aware)
	return _is_safe

func set_safe(v: bool) -> void:
	_is_safe = v
	if not v:
		_safe_seconds_left = 0.0

## SafeZoneManager pushes the remaining dwell time here each frame so the HUD
## can show a live countdown while the player rests in a zone.
func set_safe_seconds_left(s: float) -> void:
	_safe_seconds_left = s

func safe_seconds_left() -> float:
	return _safe_seconds_left

## Knocked out of an overstayed safe zone: shove the actor outward off the circle.
func eject_from_safe(zone_center: Vector3) -> void:
	var dir: Vector3 = global_position - zone_center
	dir.y = 0.0
	if dir.length() < 0.1:
		dir = Vector3(randf() - 0.5, 0, randf() - 0.5)
	dir = dir.normalized()
	# push just outside the circle radius
	global_position = zone_center + dir * (Config.SAFE_POD_RADIUS + 4.0)
	global_position.y = 0.0

# --- tagging / revive --------------------------------------------------------
func _post_revive_credit() -> void:
	pass   # marker: revive succeeded (ins recorded above); hook for future FX

func on_tagged() -> void:
	GameState.record(self, "outs")
	if _tagged:
		return
	_tagged = true
	_sitting = false   # can't stay seated once tagged out
	_stand_lock = 0.0  # (play_dead clears the rig's seated guard)
	_pending_release_timer = 0.0   # a tagged thrower fumbles; no delayed release
	_revive_timer = 0.0
	_downed_time = 0.0
	if carried != null:
		# A stolen enemy item snaps back to ITS OWN base (you lose your steal when
		# caught carrying it home). Use restore_origin so it returns to the side it
		# belongs to, not where the carrier fell.
		if carried.has_method("restore_origin"):
			carried.restore_origin()
		else:
			carried.to_loose(global_position)
		_set_carried(null)
	Events.actor_tagged.emit(self)
	# downed players are "out of play" for OTHER ACTORS — drop the actor layer so
	# teammates/enemies pass through the body, but KEEP ground collision (8|16) so
	# a body tagged mid-jump still falls and lands instead of dropping through.
	collision_layer = 0
	collision_mask = (8 | 16) if is_user else 8
	if rig != null:
		rig.play_dead()

## How long this actor has been tagged out (for AI rescue timing).
func downed_time() -> float:
	return _downed_time

func revive() -> bool:
	if not _tagged:
		return false
	# minimum-downed delay: block revives (teammate OR tag-back) until the player
	# has been down long enough, so overlapping friends/enemies can't loop them
	# through down->revive->down while the arise animation is still playing.
	if _downed_time < Config.REVIVE_MIN_DOWNED:
		return false
	_tagged = false
	GameState.record(self, "ins")
	_revive_timer = 0.0
	# back in play — restore collision (layer 1 = actors, mask 9 = world+ground).
	# The player keeps the extra school/terrain layer (16) so they don't start
	# clipping through buildings and hills after a revive.
	collision_layer = 1
	collision_mask = (9 | 16) if is_user else 9
	# brief untaggable grace so the enemy who downed you can't camp the body and
	# re-tag the instant a teammate picks you up
	_tag_grace = Config.REVIVE_TAG_GRACE
	_post_revive_credit()
	if rig != null:
		rig.play_arise()
	return true

func _return_to_spawn() -> void:
	_tagged = false
	_revive_timer = 0.0
	global_position = spawn_pos + Vector3(randf_range(-2, 2), 0, randf_range(-2, 2))
	stamina = maxf(stamina, 50.0)
	collision_layer = 1
	collision_mask = (9 | 16) if is_user else 9
	# brief untaggable grace so the enemy who downed you can't camp the body and
	# re-tag the instant a teammate picks you up
	_tag_grace = Config.REVIVE_TAG_GRACE
	if rig != null:
		rig.play_arise()


func _physics_process(delta: float) -> void:
	if GameState.phase != GameState.Phase.PLAYING:
		return
	# AI actors with no controller are positioned by their controller logic.
	# Skip the raiders sim for them (calling build_intent on null would crash).
	if controller == null:
		return
	_interact_cooldown = maxf(0.0, _interact_cooldown - delta)
	_tag_cooldown = maxf(0.0, _tag_cooldown - delta)
	_tag_grace = maxf(0.0, _tag_grace - delta)

	# incoming-pass reaction window: clear it once it lapses or the ball is gone
	if incoming_pass_time > 0.0:
		incoming_pass_time -= delta
		if incoming_pass_time <= 0.0 or incoming_ball == null or not is_instance_valid(incoming_ball) \
				or incoming_ball.state != 2:   # 2 = IN_FLIGHT; anything else means resolved
			incoming_ball = null
			incoming_pass_time = 0.0

	# Tagged-out: sit and wait. A nearby teammate (or auto-timeout) revives.
	if _tagged:
		# keep applying gravity so an actor tagged WHILE JUMPING falls to the
		# ground and lands (and is revivable) instead of freezing in mid-air.
		if not is_on_floor():
			_y_vel -= Config.GRAVITY * delta
		else:
			_y_vel = 0.0
		velocity = Vector3(0.0, _y_vel, 0.0)
		move_and_slide()
		_revive_timer += delta
		_downed_time += delta
		if _revive_timer >= Config.REVIVE_AUTO_TIMEOUT:
			_return_to_spawn()
		# presentation: stay in dead pose; rig handles it
		return

	var it := controller.build_intent(delta)

	# --- pending animated-throw release ---------------------------------------
	if _pending_release_timer > 0.0:
		_pending_release_timer -= delta
		if _pending_release_timer <= 0.0:
			if carried != null:   # may have been tagged and dropped it mid-windup
				var rit := Intent.new()
				rit.want_pass = _pending_release_pass
				rit.aim = _pending_release_aim
				_release_ball(rit)

	# --- bench sitting: locked in place until E is pressed again --------------
	# Also covers the brief stand-up phase (_stand_lock) so the stand animation
	# plays out before control returns.
	_sit_cooldown = maxf(0.0, _sit_cooldown - delta)
	if _sitting or _stand_lock > 0.0:
		# press E again (interact) to stand up
		if _sitting and is_user and it.want_interact and _sit_cooldown <= 0.0:
			_toggle_sit(self)
		if not _sitting and _stand_lock > 0.0:
			_stand_lock = maxf(0.0, _stand_lock - delta)
			if _stand_lock <= 0.0 and rig != null:
				rig.end_sit()   # release the rig guard; locomotion resumes
		if _sitting or _stand_lock > 0.0:
			# hold the player pinned to the seat; the animation (trimmed to its
			# descent/rise) provides the visible sit/stand motion.
			global_position = _sit_pos
			velocity = Vector3.ZERO
			_move_vel = Vector2.ZERO
			_y_vel = 0.0
			# keep the body turned to the seated facing (toward the field). The
			# normal facing code below is skipped by the early return, so drive the
			# rig here or the model would freeze at its pre-sit rotation.
			if rig != null:
				rig.face_heading(_sit_heading, delta)
			return

	# --- explicit player tag / revive (E, R, or left-click) ------------------
	if it.want_tag and _tag_cooldown <= 0.0:
		var tt := best_tag_target()
		if tt != null:
			tt.on_tagged()
			GameState.record(self, "tags")
			_tag_cooldown = 0.25
	if it.want_revive:
		var rt := best_revive_target()
		if rt != null:
			if rt.revive():
				GameState.record(self, "saves")

	# --- revive a downed teammate you're standing on (legacy auto) -----------
	if it.want_interact:
		_try_revive_nearby()

	# --- stamina + speed -----------------------------------------------------
	var moving := it.move.length_squared() > 0.0
	var crouching := it.crouch and is_on_floor()
	# Sprint hysteresis: once stamina hits 0 the actor is "gassed" and cannot sprint
	# until stamina recovers past the threshold AND the sprint key has been released.
	# The release requirement matters: without it, holding shift auto-resumed sprint
	# the instant stamina hit 25%, drained it back to 0 in under a second, and looped
	# — a slow sprint-burst/walk/sprint-burst surge that read as rubberbanding on any
	# long shift-held run. Now: gassed + still holding shift = steady walk; sprinting
	# again after recovery is a deliberate re-press.
	if stamina <= 0.0:
		_gassed = true
	elif _gassed and not it.sprint and stamina >= _stamina_max() * Config.SPRINT_RECOVER_FRAC:
		_gassed = false
	var can_sprint := it.sprint and not _gassed and stamina > 0.0 and moving and not crouching
	_sprinting = can_sprint
	if can_sprint:
		# heavier + taller burn faster (sprint speed stays identical for balance)
		var burn := Config.SPRINT_DRAIN * _burn_mult()
		stamina = maxf(0.0, stamina - burn * delta)
	else:
		var regen := Config.POD_REGEN if in_own_pod() else Config.WALK_REGEN
		stamina = minf(_stamina_max(), stamina + regen * delta)
	var speed := Config.SPRINT_SPEED if can_sprint else Config.WALK_SPEED
	if crouching:
		speed *= Config.CROUCH_SPEED_MULT
	_crouching = crouching

	# --- movement (horizontal from intent, vertical from gravity + jump) -----
	var horiz := Vector3.ZERO
	if moving:
		horiz = it.move * speed
	# Body facing: in mouse-look modes face where you aim (camera), so strafing
	# keeps you oriented forward. For AI bots and overhead-mode movers, face the
	# actual movement direction so the legs cycle "forward" instead of sliding
	# sideways/backward (the floaty look). The turn is delta-scaled (frame-rate
	# independent) and snappy so a sharp path change — common now that bots follow
	# navmesh corners — doesn't leave the body lagging behind its velocity.
	var face_target_set := false
	var desired_heading := heading
	if is_user and (GameState.cam_mode == "fp" or GameState.cam_mode == "third"):
		if it.aim.length_squared() > 0.0:
			desired_heading = atan2(it.aim.x, it.aim.z)
			face_target_set = true
	if not face_target_set and moving:
		desired_heading = atan2(it.move.x, it.move.z)
		face_target_set = true
	if face_target_set:
		# frame-rate-independent smoothing: t = 1 - exp(-rate*dt). Rate ~12 turns
		# the body to its heading in a few frames without snapping instantly.
		var turn_t := 1.0 - exp(-12.0 * delta)
		heading = _lerp_angle(heading, desired_heading, turn_t)
	# gravity
	if not is_on_floor():
		_y_vel -= Config.GRAVITY * delta
	else:
		_y_vel = 0.0
		# jump (only grounded, not crouching)
		if it.want_jump and not crouching:
			_y_vel = Config.JUMP_VELOCITY
	# momentum: ease horizontal velocity toward the target instead of snapping to
	# it, giving the player weight (ramp up to speed, glide to a stop). We track our
	# OWN smoothed horizontal velocity (_move_vel) rather than reading back
	# `velocity` — move_and_slide rewrites `velocity` on every collision (benches,
	# other kids, the varied-height bodies), and lerping toward target from that
	# collision-reflected value fed a feedback loop that rubberbanded sprinting.
	var target_h := Vector2(horiz.x, horiz.z)
	var accel_rate: float = (10.0 if moving else 13.0) if is_on_floor() else 2.5
	var t_h := 1.0 - exp(-accel_rate * delta)
	_move_vel = _move_vel.lerp(target_h, t_h)
	velocity = Vector3(_move_vel.x, _y_vel, _move_vel.y)
	var fall_speed := maxf(-velocity.y, 0.0)   # capture BEFORE landing zeroes it
	move_and_slide()
	# landing detection: fire once on the air->floor transition with real impact
	# (jump landings, drops) — Juice puffs dust, and it's a hook for landing SFX
	if is_on_floor() and not _was_on_floor and fall_speed > 10.0:
		Events.actor_landed.emit(self, fall_speed)
	_was_on_floor = is_on_floor()
	# Track the last spot this actor stood safely on the floor. If they ever fall
	# through the world, we restore HERE — not to spawn. Teleporting to spawn was
	# the sprint "slingshot across the map": sprint over a terrain seam → fall
	# through → silent snap to spawn → run back → fall again, back and forth.
	if is_on_floor() and global_position.y > -2.0:
		_last_safe_pos = global_position
		_has_safe_pos = true
	# fall-through-the-world safety net: restore to the last safe ground (or spawn
	# if we never had one), and log it so terrain holes are visible in the console.
	if global_position.y < -20.0:
		var back: Vector3 = (_last_safe_pos + Vector3(0, 2, 0)) if _has_safe_pos else (spawn_pos + Vector3(0, 2, 0))
		push_warning("Actor '%s' fell through the world at %s — restored to last safe ground %s" % [name, str(global_position.round()), str(back.round())])
		global_position = back
		_y_vel = 0.0
		_move_vel = Vector2.ZERO   # don't carry sprint momentum into the restore
	# keep NPCs inside the playable field; the player is free to explore past it
	# (for future map expansion). The ball still bounces off the field edge.
	if not is_user:
		global_position.x = clampf(global_position.x, -Config.FIELD_X, Config.FIELD_X)
		global_position.z = clampf(global_position.z, -Config.FIELD_Z, Config.FIELD_Z)

	# --- look-at pickup of a carryable (ball or goal cone) -------------------
	if carried == null and it.want_interact and _interact_cooldown <= 0.0:
		_try_pickup(it)

	# --- sit down on a bench (human only) ------------------------------------
	# Pressing E near a bench when there's nothing else to interact with sits you
	# down (snaps to the seat + locks movement; press E again to stand — handled
	# in the sit-lock block above). Guarded to never steal a pickup/tag/revive,
	# and gated by _sit_cooldown so the same press can't sit-then-stand.
	if is_user and it.want_interact and _sit_cooldown <= 0.0 and not _sitting \
			and _interact_cooldown <= 0.0 and carried == null \
			and best_tag_target() == null and best_revive_target() == null:
		var bench := nearest_bench()
		if bench != null:
			_toggle_sit(bench)
			_interact_cooldown = 0.4

	# --- throw / pass (balls only) -------------------------------------------
	if carried != null and has_ball() and (it.want_throw or it.want_pass):
		_request_throw(it)

	# --- bank ----------------------------------------------------------------
	if carried != null and global_position.distance_to(Config.goal_pos(team)) < Config.GOAL_BANK_RADIUS:
		_bank()

	# --- tagging --------------------------------------------------------------
	# The HUMAN tags manually with E / click (handled above via want_tag), so the
	# action is always deliberate. NPCs have no button, so they tag the single
	# best eligible enemy in reach — but only ONE per cooldown, chosen by the same
	# can_tag() rule and the same closeness logic the player uses. This is a
	# deliberate "tag the enemy I'm engaging", not a blanket proximity sweep.
	if not is_user and _tag_cooldown <= 0.0:
		var npc_target := _npc_tag_target()
		if npc_target != null:
			npc_target.on_tagged()
			GameState.record(self, "tags")
			_tag_cooldown = 0.25

	# --- drive the rig (presentation) ----------------------------------------
	if rig != null:
		rig.face_heading(heading, delta)
		# jump pose while off the ground (no-op for models without a jump clip)
		rig.set_airborne(not is_on_floor())
		var ratio := 0.0
		if moving:
			ratio = 1.0 if can_sprint else 0.5
		# held crouch pose (cosmetic; models without the clip ignore it)
		if rig.has_method("set_crouching"):
			rig.set_crouching(crouching)
		# pass the ACTUAL horizontal speed so walk/run playback tracks the ground
		# (momentum ramps, collisions) instead of skating at a fixed clip rate
		rig.set_locomotion(ratio, delta, Vector2(velocity.x, velocity.z).length())


# --- pickup: must be close AND facing the target -----------------------------
func _try_pickup(it: Intent) -> void:
	var face := it.aim
	face.y = 0
	if face.length_squared() < 0.01:
		face = Vector3(sin(heading), 0, cos(heading))
	face = face.normalized()
	var best: Node = null
	var best_score := -INF
	for grp in ["balls", "goal_cones"]:
		for c in get_tree().get_nodes_in_group(grp):
			if not c.is_grabbable_by(team):
				continue
			var to: Vector3 = c.global_position - global_position
			to.y = 0
			var d: float = to.length()
			if d > Config.PICKUP_RADIUS:
				continue
			var aim_dot := 1.0
			if d > 0.1:
				aim_dot = face.dot(to.normalized())
			# player must be looking roughly at it; AI is lenient.
			var need_dot: float = Config.LOOK_DOT if is_user else -0.3
			if d > 0.1 and aim_dot < need_dot:
				continue
			# Score so the reticle wins over raw proximity: alignment dominates,
			# closeness breaks ties. This fixes the "grabs whatever's nearest even
			# though I'm aiming at something else" indecision when items cluster.
			var prox := 1.0 - d / Config.PICKUP_RADIUS
			var score: float = aim_dot * 2.0 + prox
			if score > best_score:
				best_score = score
				best = c
	if best != null:
		_set_carried(best)
		best.on_picked_up(self)
		Events.item_grabbed.emit(self, best)
		_interact_cooldown = 0.3

func _try_revive_nearby() -> void:
	for o in GameState.actors():
		if o == self or o.team != team or not o.is_tagged():
			continue
		if global_position.distance_to(o.global_position) < Config.REVIVE_RADIUS:
			if o.revive():
				GameState.record(self, "saves")
			return

## Release whatever we're carrying WITHOUT banking or snapping it home — used
## for fumbles, where the ball just pops loose where we are for a scramble.
func drop_carried() -> void:
	carried = null

## The human's throw is gated behind a timing QTE (like catching): pressing throw
## opens a bar in the HUD; hit the window and the throw fires, miss it and the
## ball is FUMBLED (dropped loose, must be re-grabbed). NPCs throw directly — no
## reticle/HUD, and they shouldn't be handicapped by a UI minigame.
var _throw_qte_active := false
var _pending_is_pass := false       # was the stashed throw a pass (vs. free throw)?

func _request_throw(it: Intent) -> void:
	# a throw is already committed (anim winding up, ball leaves at the release
	# frame) — ignore new requests until the ball is actually gone. Without this,
	# the very mouse-click that RESOLVED the QTE is re-read as a fresh throw press
	# during the 0.38s release window, opening a second QTE on an already-thrown
	# ball that then "fumbles" — the phantom double-QTE bug.
	if _pending_release_timer > 0.0:
		return
	if not is_user:
		_begin_throw(it)   # NPCs: no QTE; anim windup still applies if they have one
		return
	if _throw_qte_active:
		return   # already awaiting a throw QTE — ignore repeat presses
	var hud := get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("start_throw_qte"):
		_throw_qte_active = true
		_pending_is_pass = it.want_pass
		hud.start_throw_qte(self)
	else:
		_begin_throw(it)   # no HUD (shouldn't happen in-match) — throw directly

## Called by the HUD when the throw QTE is HIT — fire the stashed throw.
func execute_pending_throw() -> void:
	_throw_qte_active = false
	if not has_ball():
		return
	# rebuild a minimal intent from the stashed flag + current aim/heading
	var it := Intent.new()
	it.want_pass = _pending_is_pass
	it.want_throw = not _pending_is_pass
	it.aim = Vector3(sin(heading), 0, cos(heading))
	_begin_throw(it)

## Called by the HUD when the throw QTE is MISSED — fumble the ball: drop it loose
## at the player's feet so it must be chased down and re-grabbed.
func fumble_throw() -> void:
	_throw_qte_active = false
	if not has_ball():
		return
	var b := carried
	_set_carried(null)
	if b != null and is_instance_valid(b):
		if b.has_method("drop_loose"):
			b.drop_loose()
		elif b.has_method("force_drop"):
			b.force_drop()

## Start a throw. Models WITH a pitching clip wind up first and release the ball
## at the animation's measured release frame; models without release instantly.
func _begin_throw(it: Intent) -> void:
	if carried == null:
		return
	if rig != null and rig.has_method("has_throw") and rig.has_throw() and _pending_release_timer <= 0.0:
		rig.play_throw()
		_pending_release_timer = Config.THROW_ANIM_RELEASE_DELAY
		_pending_release_pass = it.want_pass
		_pending_release_aim = it.aim
	else:
		_release_ball(it)

func _release_ball(it: Intent) -> void:
	var b := carried
	_set_carried(null)
	# PASS: arc the ball to a teammate's position (lead them slightly).
	if it.want_pass:
		var mate := _best_pass_target()
		if mate != null:
			var lead: Vector3 = mate.global_position
			# lead a moving teammate a touch
			if "velocity" in mate:
				lead += mate.velocity * 0.25
			b.launch_to(lead, Config.PASS_ARC, global_position, mate, self)
			return
	# THROW: aim where the player/AI is facing, landing at a sensible distance
	# (never "into space" — distance is clamped to MAX_THROW_DIST).
	# THROW: if the player has a locked-on teammate, home the throw onto them
	# like a missile (tracks their live position so they can't be missed). With
	# no lock, it's a free directional throw that lands at a sensible distance.
	if is_user and lock_target != null and is_instance_valid(lock_target) \
			and not lock_target.is_tagged() and not lock_target.has_target():
		var lead: Vector3 = lock_target.global_position
		if "velocity" in lock_target:
			lead += lock_target.velocity * 0.25
		b.launch_to(lead, Config.PASS_ARC, global_position, lock_target, self)
		return
	var dir := it.aim
	dir.y = 0
	if dir.length_squared() < 0.01:
		dir = Vector3(sin(heading), 0, cos(heading))
	dir = dir.normalized()
	if not is_user:
		var err := (1.0 - Config.ai_val("aim")) * 0.4
		dir.x += randf_range(-err, err)
		dir.z += randf_range(-err, err)
		dir = dir.normalized()
	var reach: float = Config.MAX_THROW_DIST * _throw_mult()
	var target: Vector3 = global_position + dir * reach
	b.launch_to(target, Config.THROW_ARC, global_position, null, self)

func _best_pass_target() -> Node:
	# the player can lock a specific teammate; honor it if still valid
	if is_user and lock_target != null and is_instance_valid(lock_target) \
			and not lock_target.is_tagged() and not lock_target.has_target():
		return lock_target
	var goal := Config.goal_pos(team)
	var best: Node = null
	var bs: float = -INF
	for a in GameState.actors():
		if a == self or a.team != team or a.is_tagged() or a.has_target():
			continue
		var d: float = global_position.distance_to(a.global_position)
		if d > Config.PASS_RANGE:
			continue
		var advance: float = global_position.distance_to(goal) - a.global_position.distance_to(goal)
		var score := advance * 1.3 - d * 0.05
		if score > bs:
			bs = score
			best = a
	return best

## All teammates eligible to be a pass target right now (open, in range, upfield).
## Used by the player lock-on reticle + Tab cycling.
func open_pass_targets() -> Array:
	var goal := Config.goal_pos(team)
	var my_goal_d: float = global_position.distance_to(goal)
	var out: Array = []
	for a in GameState.actors():
		if a == self or a.team != team or a.is_tagged() or a.has_target():
			continue
		var d: float = global_position.distance_to(a.global_position)
		if d > Config.PASS_LOCK_RANGE:
			continue
		if my_goal_d - a.global_position.distance_to(goal) > -6.0:   # roughly level or ahead
			out.append(a)
	return out

## Cycle the player's locked pass target to the next open teammate (Tab).
func cycle_lock_target() -> void:
	var opts := open_pass_targets()
	if opts.is_empty():
		lock_target = null
		return
	var idx := opts.find(lock_target)
	lock_target = opts[(idx + 1) % opts.size()] if idx >= 0 else opts[0]

## Auto-pick a lock target if none is set (so the reticle always has something).
func ensure_lock_target() -> void:
	if lock_target == null or not is_instance_valid(lock_target) \
			or lock_target.is_tagged() or lock_target.has_target():
		var opts := open_pass_targets()
		lock_target = opts[0] if not opts.is_empty() else null

func _bank() -> void:
	var b := carried
	b.set_team(team)
	var gz: float = Config.goal_pos(team).z
	b.home_pos = Vector3(randf_range(-30, 30), 1.6, gz + randf_range(-8, 8))
	b.to_home()
	_set_carried(null)
	GameState.record(self, "pts")
	Events.ball_banked.emit(team)

func _lerp_angle(a: float, b: float, t: float) -> float:
	var d := fmod(b - a + PI, TAU) - PI
	return a + d * t
