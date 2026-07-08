class_name AIController
extends BaseController
## Utility-based AI brain. Instead of being told a state, each bot SCORES its own
## options every ~1.5s and picks the best, then steers toward it with awareness of
## crowds, threats, and the field. Teammates avoid duplicating jobs via a shared
## "claim" registry, which produces natural spacing without a central commander.
##
## The PlayCaller no longer commands; it only publishes team INFLUENCE (raid vs
## defend bias) that nudges every bot's scores. Personality traits make kids differ.

enum Job { IDLE, GRAB, CARRY_HOME, CHASE, DEFEND_GOAL, HOLD_LINE, SUPPORT, RESCUE, REST, RAID }

# kept for spawn/scene compatibility; no longer drives behavior directly
var role: String = "striker"
var state: int = 0
var chase_target: Node = null
var rescue_target: Node = null

var perception: Perception

# --- current commitment ---
var _job: int = Job.IDLE
var _job_target: Node = null
var _job_point: Vector3 = Vector3.ZERO
var _commit := 0.0                 # time left committed to current job
var _opening_t := 25.0             # opening phase: roles are split (see setup)
var _opening_raider := true        # my opening role
var _current_score := 0.0          # score of the currently committed job (for hysteresis)
var _t := 0.0
const _SENSE_INTERVAL := 0.1        # sense ~10x/sec instead of 60x/sec
var _sense_accum := 0.0
var _juke_phase := 0.0              # evasion weave timer
var _juke_seed := 0.0              # per-bot phase offset so they juke differently
var _facing := Vector3.FORWARD
var _stuck_time := 0.0             # how long we've wanted to move but haven't
var _last_pos := Vector3.ZERO
# Separation push smoothed over time. The raw per-frame push flips direction as a
# bot passes teammates, which caused a visible side-to-side STUTTER while moving
# forward; smoothing it removes the flicker. Also lets us weight the bot's own
# goal above spacing so a squad DRIFTS apart instead of moving as a rigid blob.
var _smoothed_push := Vector3.ZERO

# --- personality (rolled once at setup) ---
var _brave := 1.0                  # >1 raids deeper, chases harder
var _lane_wander := 0.0            # occasional sideways lane offset (horizontal variety)
var _team_play := 1.0              # >1 passes & supports more
var _hustle := 1.0                 # >1 sprints/commits more

## Fraction of my team currently tagged out (0..1) — drives crisis rescue.
func _team_down_ratio() -> float:
	var total := 0
	var down := 0
	for k in GameState.actors():
		if not is_instance_valid(k) or k.team != actor.team:
			continue
		total += 1
		if k.is_tagged():
			down += 1
	return (float(down) / float(total)) if total > 0 else 0.0

func setup(p_actor: Node) -> void:
	super.setup(p_actor)
	perception = Perception.new(p_actor)
	_t = randf() * 10.0
	_sense_accum = randf() * _SENSE_INTERVAL   # spread senses across frames
	_juke_seed = randf() * TAU                 # unique evasion rhythm per bot
	_facing = Vector3(sin(p_actor.heading), 0, cos(p_actor.heading))
	# personality spread
	_brave = randf_range(0.7, 1.4)
	_team_play = randf_range(0.7, 1.4)
	# OPENING ROLES: not everyone charges at kickoff. ~40% start as holders
	# (defend/hold the line ~25s) so a lost opening clash can't steamroll us —
	# there's always a home guard to tag intruders and pick people up.
	_opening_raider = randf() > 0.4
	_opening_t = 25.0
	_hustle = randf_range(0.8, 1.3)

func build_intent(delta: float) -> Intent:
	intent.clear()
	_t += delta
	var a := actor
	if a.is_tagged():
		_release_claim()
		return intent
	_opening_t = maxf(0.0, _opening_t - delta)

	_facing = Vector3(sin(a.heading), 0, cos(a.heading))
	# PERFORMANCE: perception (scanning all actors + raycasts) is the biggest
	# per-frame cost. Instead of every bot sensing every frame, each senses every
	# few frames, staggered by id so the work spreads across frames. The cached
	# results (visible_enemies etc.) carry over between senses — enemies don't
	# teleport, so slightly stale perception is imperceptible but ~4x cheaper.
	_sense_accum += delta
	if _sense_accum >= _SENSE_INTERVAL:
		_sense_accum = 0.0
		perception.sense(_facing)

	# HIGHEST priority for a non-carrier: a ball is being thrown to me — break to
	# where it'll land and catch it. Now-or-never, so this beats everything else.
	if a.incoming_ball != null and is_instance_valid(a.incoming_ball) and not a.has_target():
		var land: Vector3 = a.incoming_ball.predicted_landing
		_seek(land, true)         # sprint to the landing spot
		intent.want_interact = true
		return intent

	# JUMP-INTERCEPT (AI_DESIGN.md §4): an enemy throw arcing past nearby is a
	# now-or-never chance to knock it down. Skill-gated so casual kids often
	# miss the window while ruthless ones time it well. Beats normal jobs but
	# not catching a pass meant for us / carrying.
	var icept := _intercept_chance()
	if icept != Vector3.INF:
		_seek(icept, true)
		# jump when the ball is nearly on us and at jumpable height
		var d_ic: float = Vector3(icept.x - a.global_position.x, 0, icept.z - a.global_position.z).length()
		if d_ic < 3.5 and randf() < Config.ai_val("react"):
			intent.want_jump = true
		return intent

	# carriers always run home (highest priority, never re-scored away)
	if a.has_target():
		_job = Job.CARRY_HOME
		_behave_carry_home(delta)
		intent.want_interact = true
		return intent

	# re-score options on a commit timer (kills twitching). Hysteresis: when the
	# timer fires, we only ABANDON the current job if it's invalid (target gone)
	# or if a new candidate scores meaningfully (40%) higher. This makes bots
	# follow through on a chase or a raid instead of flickering between options.
	_commit -= delta
	if _commit <= 0.0:
		if not _job_valid():
			_choose_job()
		else:
			var current_now := _score_current_job()
			var prev := _job
			var prev_target := _job_target
			var prev_point := _job_point
			# tentatively re-score everything
			_choose_job()
			# if the new best isn't 40% better than sticking with current, revert
			if (_job != prev or _job_target != prev_target) and _current_score < current_now * 1.4:
				_release_claim()
				_job = prev
				_job_target = prev_target
				_job_point = prev_point
				_current_score = current_now
				if _job_target != null:
					_claim(_job_target)
		_commit = Config.AI_COMMIT_TIME * randf_range(0.85, 1.2)

	_execute_job()
	_avoid_and_steer(delta)
	intent.want_interact = true

	# stuck-detection safety net: if we WANT to move but haven't actually moved
	# for a while (mutual steering deadlock in a cluster), force a fresh decision
	# and inject a random sidestep to break the logjam.
	if intent.move.length_squared() > 0.01:
		var moved: float = a.global_position.distance_to(_last_pos)
		if moved < 0.15:
			_stuck_time += delta
			if _stuck_time > 1.2:
				_stuck_time = 0.0
				_commit = 0.0                       # re-decide next frame
				_release_claim()                    # stale claim freed too
				var ang := randf() * TAU
				intent.move = (intent.move + Vector3(cos(ang), 0, sin(ang)) * 1.5).normalized()
		else:
			_stuck_time = 0.0
	_last_pos = a.global_position
	return intent

## Re-score JUST the current job using the same formulas as _choose_job, so the
## hysteresis check has an apples-to-apples comparison.
func _score_current_job() -> float:
	var a := actor
	var raid_bias: float = Config.team_raid_bias(a.team)
	var def_bias := 1.0 - raid_bias
	var FIELD_DIAG := 220.0
	var danger := _danger_at(a.global_position)
	match _job:
		Job.GRAB:
			if _job_target == null or not is_instance_valid(_job_target):
				return -INF
			var tp: Vector3 = _job_target.global_position
			var dist: float = a.global_position.distance_to(tp)
			var prox: float = 1.0 - 0.6 * clampf(dist / FIELD_DIAG, 0.0, 1.0)
			var target_danger := _danger_at(tp)
			var score: float = 95.0 * prox * (0.6 + raid_bias) * _brave
			score *= (1.0 - target_danger * (0.5 / _brave))
			return score
		Job.CHASE:
			if _job_target == null or not is_instance_valid(_job_target) or _job_target.is_tagged():
				return -INF
			var ep: Vector3 = _job_target.global_position
			var dist2: float = a.global_position.distance_to(ep)
			var prox2: float = 1.0 - 0.6 * clampf(dist2 / FIELD_DIAG, 0.0, 1.0)
			var urgency := 2.0 if _job_target.has_target() else 1.1
			return 90.0 * prox2 * (0.5 + def_bias) * urgency
		Job.RESCUE:
			if _job_target == null or not is_instance_valid(_job_target) or not _job_target.is_tagged():
				return -INF
			var dp: Vector3 = _job_target.global_position
			var dist3: float = a.global_position.distance_to(dp)
			var prox3: float = 1.0 - 0.5 * clampf(dist3 / Config.RESCUE_MAX_DIST, 0.0, 1.0)
			return 75.0 * prox3 * Config.ai_val("revive") * _team_play
		Job.SUPPORT:
			if _job_target == null or not is_instance_valid(_job_target) or not _job_target.has_target():
				return -INF
			var dist4: float = a.global_position.distance_to(_job_target.global_position)
			var prox4: float = 1.0 - 0.6 * clampf(dist4 / FIELD_DIAG, 0.0, 1.0)
			return 65.0 * prox4 * _team_play * (0.5 + raid_bias)
		Job.REST:
			if a.stamina >= Config.GASSED_STAMINA:
				return -INF
			var gas: float = (Config.GASSED_STAMINA - a.stamina) / maxf(1.0, Config.GASSED_STAMINA)
			return 85.0 * gas * (0.5 + danger)
		Job.RAID:
			if a.stamina <= Config.GASSED_STAMINA:
				return -INF
			return 55.0 * (0.3 + raid_bias) * _brave
		Job.DEFEND_GOAL:
			return 45.0 * def_bias
		Job.HOLD_LINE:
			return 35.0 * (0.4 + raid_bias)
	return 0.0


# ============================================================================
# UTILITY SCORING — pick the best job for right now
# ============================================================================
func _choose_job() -> void:
	# occasional sideways drift so travel isn't always the same column — kids
	# wander laterally, using the field's width (small chance per re-think)
	if randf() < 0.25:
		_lane_wander = randf_range(-16.0, 16.0)
	var a := actor
	_release_claim()
	var best_score: float = -INF
	var best_job: int = Job.HOLD_LINE
	var best_target: Node = null
	var best_point := Vector3.ZERO

	# team influence from the conductor (raid_bias high = attack, low = defend)
	var raid_bias: float = Config.team_raid_bias(a.team)
	var def_bias := 1.0 - raid_bias

	# live team threat: how hard are we being raided right now. This pulls the
	# WHOLE team toward defense as it rises, instead of each bot deciding alone —
	# the core of making the AI reactive rather than mindlessly raiding.
	var threat_n: int = Config.team_threat(a.team)
	var carrier_n: int = Config.team_carrier_threat(a.team)
	# 0 = calm, ramps up as raiders (esp. carriers) enter our half. Capped lower
	# and scaled gentler than before: threat should TILT the team toward defense,
	# not collapse all 14 bots onto the goal at once (which left the field empty
	# and deadlocked both teams at their endzones).
	var threat_level: float = clampf(float(threat_n) * 0.12 + float(carrier_n) * 0.3, 0.0, 0.7)
	# offense is damped and defense amplified as threat climbs — but gently, so
	# plenty of bots keep raiding even under pressure
	var off_mult: float = 1.0 - 0.35 * threat_level
	var def_mult: float = 1.0 + 0.6 * threat_level

	# danger to me right now (0 = safe, 1 = surrounded)
	var danger := _danger_at(a.global_position)

	# Scoring is normalized to ~0..100. Each option = base_value * proximity * modifiers,
	# where proximity falls off gently with distance (never collapses to ~0), so a
	# far-but-valuable raid still competes with holding the line.
	var FIELD_DIAG := 220.0

	# --- option: GRAB a stealable target (ball/cone) ---
	for t in _grabbable_targets():
		var tp: Vector3 = t.global_position
		var dist: float = a.global_position.distance_to(tp)
		var prox: float = 1.0 - 0.6 * clampf(dist / FIELD_DIAG, 0.0, 1.0)   # 1.0 near .. 0.4 far
		var claim_penalty := 0.5 if _is_claimed_by_other(t) else 1.0
		var target_danger := _danger_at(tp)
		# raiding is the heart of the game -> high base value
		var crowd := _teammate_crowding(tp, 28.0)   # spread out, don't swarm
		var score: float = 95.0 * prox * (0.6 + raid_bias) * claim_penalty * _brave * off_mult * crowd
		score *= (1.0 - target_danger * (0.5 / _brave))
		if score > best_score:
			best_score = score; best_job = Job.GRAB; best_target = t; best_point = tp

	# --- option: CHASE an enemy raider on our half ---
	for e in _threats_on_our_half():
		var ep: Vector3 = e.global_position
		var dist2: float = a.global_position.distance_to(ep)
		var prox2: float = 1.0 - 0.6 * clampf(dist2 / FIELD_DIAG, 0.0, 1.0)
		var claim_pen2 := 0.45 if _is_claimed_by_other(e) else 1.0
		# carriers (stealing our stuff) are far more valuable to stop
		var urgency := 2.0 if e.has_target() else 1.1
		# the bot physically closest to an intruder should be the one to react
		var local := _local_enemy_boost()
		var score2: float = 90.0 * prox2 * (0.5 + def_bias) * urgency * claim_pen2 * def_mult * local
		if score2 > best_score:
			best_score = score2; best_job = Job.CHASE; best_target = e; best_point = ep

	# --- option: ENGAGE a nearby enemy anywhere (incl. the contested middle) so
	# the teams actually clash instead of mutually avoiding at the border. Lower
	# weight than defending our own half, but enough to break the stalemate.
	var skip_engage := false
	for d2 in _downed_teammates():
		if d2.downed_time() < Config.REVIVE_MIN_DOWNED - 1.5:
			continue   # still deep in tag-out cooldown — fighting is fine meanwhile
		if actor.global_position.distance_to(d2.global_position) < 26.0:
			skip_engage = true   # a friend needs picking up — that comes first
			break
	for e2 in ([] if skip_engage else _nearby_enemies(22.0)):
		if e2.is_tagged():
			continue
		var epx: Vector3 = e2.global_position
		var distx: float = a.global_position.distance_to(epx)
		var proxx: float = 1.0 - clampf(distx / 22.0, 0.0, 1.0)
		var urg2 := 1.8 if e2.has_target() else 1.0   # chase carriers hard
		var claim_penx := 0.5 if _is_claimed_by_other(e2) else 1.0
		var scorex: float = 52.0 * proxx * urg2 * claim_penx * _brave * Config.ai_val("aggro")
		if scorex > best_score:
			best_score = scorex; best_job = Job.CHASE; best_target = e2; best_point = epx

	# --- option: RESCUE a downed teammate ---
	for d in _downed_teammates():
		var dp: Vector3 = d.global_position
		var dist3: float = a.global_position.distance_to(dp)
		if dist3 > Config.RESCUE_MAX_DIST:
			continue
		# TAG-OUT COOLDOWN TIMING: a fresh body can't be revived for
		# REVIVE_MIN_DOWNED seconds. Only commit if they'll be revivable by
		# roughly the time we arrive — otherwise bots cluster around the body
		# waiting (and the stuck-nudge yanks them away right before it unlocks).
		var travel_eta: float = dist3 / 22.0   # ~sprint speed with pathing slack
		if d.downed_time() + travel_eta < Config.REVIVE_MIN_DOWNED - 0.4:
			continue
		var prox3: float = 1.0 - 0.5 * clampf(dist3 / Config.RESCUE_MAX_DIST, 0.0, 1.0)
		var claim_pen3 := 0.4 if _is_claimed_by_other(d) else 1.0
		# revive trait floored at 0.7 so even casual bots help a downed teammate
		# (walking past a teammate begging for a revive felt terrible). Base bumped
		# and a proximity kicker: a bot standing right next to a body almost always
		# stops to help.
		var revive_w: float = maxf(0.7, Config.ai_val("revive"))
		# standing next to a body => overwhelming urge to help (2x within 16u).
		var close_kick: float = 2.0 if dist3 < 16.0 else 1.0
		# TEAM CRISIS: when lots of us are down, survivors drop everything and
		# pick people up — this is what stops the opening-clash steamroll.
		var crisis: float = 1.0 + 1.4 * _team_down_ratio()
		var score3: float = 115.0 * prox3 * revive_w * claim_pen3 * _team_play * close_kick * crisis
		if score3 > best_score:
			best_score = score3; best_job = Job.RESCUE; best_target = d; best_point = dp

	# --- option: SUPPORT our carrier (escort / be a pass outlet) ---
	var carrier := _our_carrier()
	if carrier != null:
		var cp: Vector3 = carrier.global_position
		var dist4: float = a.global_position.distance_to(cp)
		var prox4: float = 1.0 - 0.6 * clampf(dist4 / FIELD_DIAG, 0.0, 1.0)
		var score4: float = 65.0 * prox4 * _team_play * (0.5 + raid_bias)
		if score4 > best_score:
			best_score = score4; best_job = Job.SUPPORT; best_target = carrier; best_point = cp

	# --- option: REST when gassed ---
	if a.stamina < Config.GASSED_STAMINA:
		var pod := _nearest_own_pod()
		var gas: float = (Config.GASSED_STAMINA - a.stamina) / maxf(1.0, Config.GASSED_STAMINA)
		var rest_score: float = 85.0 * gas * (0.5 + danger)
		if rest_score > best_score:
			best_score = rest_score; best_job = Job.REST; best_target = null; best_point = pod

	# --- option: RAID — push toward the enemy stash even when we can't yet SEE a
	# specific target. The stash location is "common knowledge" (a fixed place),
	# so raiders advance into enemy territory to go LOOK for loot; once they get
	# close enough to perceive a ball/cone, GRAB takes over. Without this, bots
	# with no visible target just sat at the border.
	if a.stamina > Config.GASSED_STAMINA:
		# opening holders sit back for the first ~25s instead of joining the
		# kickoff stampede — the anti-steamroll home guard.
		var opening_mult: float = 1.0 if (_opening_raider or _opening_t <= 0.0) else 0.15
		var raid_score: float = 55.0 * (0.3 + raid_bias) * _brave * off_mult * opening_mult
		if raid_score > best_score:
			best_score = raid_score; best_job = Job.RAID; best_target = null
			best_point = _enemy_stash_point()

	# --- baseline options: defend goal or hold the line ---
	# These are FALLBACKS: deliberately lower than an available raid/chase so bots
	# don't just sit at the border when there's something better to do.
	var goal_score: float = 45.0 * def_bias * def_mult
	if goal_score > best_score:
		best_score = goal_score; best_job = Job.DEFEND_GOAL; best_target = null
		best_point = _goal_lane_point()
	var line_score: float = 30.0 * (0.4 + raid_bias)
	if line_score > best_score:
		best_score = line_score; best_job = Job.HOLD_LINE; best_target = null
		best_point = _border_lane_point()

	_job = best_job
	_job_target = best_target
	_job_point = best_point
	_current_score = best_score
	if best_target != null:
		_claim(best_target)


# ============================================================================
# JOB EXECUTION — turn the chosen job into a steering target
# ============================================================================
func _execute_job() -> void:
	match _job:
		Job.GRAB:
			if _job_target != null and is_instance_valid(_job_target):
				var tp: Vector3 = _job_target.global_position
				if _job_target.has_method("get_state") and _job_target.get_state() == 2:
					# ball in flight: lead the target. Ball is a RigidBody3D, so its
					# speed is linear_velocity (not velocity, which is CharacterBody3D).
					if "linear_velocity" in _job_target:
						tp += _job_target.linear_velocity * (0.2 * Config.ai_val("anticip"))
				_seek(tp, true)
			else:
				_commit = 0.0
		Job.CHASE:
			if _job_target != null and is_instance_valid(_job_target) and actor.can_tag(_job_target):
				var tpos: Vector3 = _job_target.global_position
				if _job_target.has_target():
					# the target is carrying loot toward THEIR goal — don't trail
					# their tail, cut them off. Aim at a point ahead of them along
					# their route home so we actually intercept.
					var their_goal: Vector3 = Config.goal_pos(_job_target.team)
					var lead: Vector3 = tpos.lerp(their_goal, 0.3)
					# if we're roughly between them and their goal already, go
					# straight at them for the tag; else take the cutoff angle
					var to_me: float = actor.global_position.distance_to(their_goal)
					var to_them: float = tpos.distance_to(their_goal)
					_seek(lead if to_me > to_them else tpos, true)
				else:
					_seek(tpos, true)
			else:
				_commit = 0.0
		Job.RESCUE:
			if _job_target != null and is_instance_valid(_job_target) and _job_target.is_tagged():
				_seek(_job_target.global_position, true)
			else:
				_commit = 0.0
		Job.SUPPORT:
			if _job_target != null and is_instance_valid(_job_target) and _job_target.has_target():
				# flank slightly ahead of the carrier toward goal
				var goal := Config.goal_pos(actor.team)
				var ahead: Vector3 = _job_target.global_position.lerp(goal, 0.35)
				_seek(ahead, actor.stamina > 20.0)
			else:
				_commit = 0.0
		Job.REST:
			_seek(_job_point, false)
		Job.RAID:
			# push toward the enemy stash; sprint once on the enemy half. When we
			# get close, drop commit so the scorer can switch to GRAB on a target
			# we can now perceive.
			var sprint: bool = Config.on_enemy_half(actor.team, actor.global_position.z) \
				or actor.global_position.distance_to(_job_point) < 50.0
			_seek(_lane_travel(_job_point), sprint)
			if actor.global_position.distance_to(_job_point) < 30.0:
				_commit = 0.0   # re-evaluate: we should be able to see loot now
		Job.DEFEND_GOAL:
			# react: if a threat enters my area, intercept; else hold lane
			var threat := _nearest_threat_near(_job_point, 42.0)
			if threat != null:
				_seek(threat.global_position, true)
			else:
				_seek(_lane_travel(_job_point), false)
		Job.HOLD_LINE:
			var threat2 := _nearest_threat_near(actor.global_position, 36.0)
			if threat2 != null and Config.intruding_into(actor.team, threat2.global_position.z):
				_seek(threat2.global_position, true)
			else:
				_seek(_job_point, false)
		_:
			_seek(_border_lane_point(), false)

func _behave_carry_home(delta: float) -> void:
	var a := actor
	var goal := Config.goal_pos(a.team)
	var dist_goal: float = a.global_position.distance_to(goal)

	# FUMBLE: under pressure, a carrier has a small chance to lose the ball. This
	# adds tension to a steal (a closely-chased thief might cough it up) and
	# reuses the loose-ball system. Reversible via Config.ai_can_fumble.
	if Config.ai_can_fumble and a.carrying_is_ball() and _enemy_closing():
		# ~ small chance per second of pressured carrying; scaled by delta so it's
		# frame-rate independent. Tuned low so it's a spice, not a constant loss.
		var fumble_per_sec := 0.18
		if randf() < fumble_per_sec * delta:
			var ball: Node = a.carried
			if ball != null and is_instance_valid(ball) and ball.has_method("drop_loose"):
				a.drop_carried()
				ball.drop_loose()
				return

	_commit -= delta
	if _commit <= 0.0:
		_commit = 0.4
		if a.carrying_is_ball():
			# Pass readily when it genuinely helps: a teammate is meaningfully more
			# open / further upfield, OR my lane home is blocked. No rare dice roll.
			var mate := _open_teammate_forward()
			var pressured := _lane_blocked() or _enemy_closing()
			if mate != null and dist_goal > 18.0 and (pressured or _mate_much_better(mate)):
				intent.want_pass = true
			elif pressured and dist_goal > 30.0:
				# no good outlet but boxed in: lob it forward toward goal to advance it
				intent.aim = (goal - a.global_position).normalized()
				intent.want_throw = true
	# EVASION: a chased carrier shouldn't run a dead-straight predictable line to
	# the goal — weave to make the chaser miss. Add a perpendicular juke that
	# flips direction periodically, scaled by how close the threat is.
	if _enemy_closing():
		var chaser := _nearest_chaser()
		if chaser != null:
			var to_goal: Vector3 = goal - a.global_position
			to_goal.y = 0.0
			to_goal = to_goal.normalized()
			# perpendicular direction (left/right of the run)
			var perp := Vector3(-to_goal.z, 0.0, to_goal.x)
			# oscillate the juke direction over time, with a per-bot phase
			_juke_phase += delta * 3.2
			var side: float = 1.0 if sin(_juke_phase + _juke_seed) > 0.0 else -1.0
			var chaser_d: float = a.global_position.distance_to(chaser.global_position)
			var urgency: float = clampf(1.0 - chaser_d / 14.0, 0.0, 1.0)
			var juke := perp * side * urgency * 0.8
			_seek(a.global_position + (to_goal + juke) * 20.0, a.stamina > 10.0)
			return
	_seek(goal, a.stamina > 12.0)

## The nearest enemy who could tag this carrier (the active chaser), or null.
func _nearest_chaser() -> Node:
	var a := actor
	var best: Node = null
	var best_d := INF
	for o in GameState.actors():
		if o == a or o.team == a.team or o.is_tagged():
			continue
		if not o.has_method("can_tag") or not o.can_tag(a):
			continue
		var d: float = a.global_position.distance_to(o.global_position)
		if d < best_d:
			best_d = d
			best = o
	return best

## True if an enemy is closing in on the carrier (pressure to release the ball).
func _enemy_closing() -> bool:
	var a := actor
	for e in GameState.actors():
		if e.team == a.team or e.is_tagged():
			continue
		if a.global_position.distance_to(e.global_position) < 10.0:
			return true
	return false

## True if the candidate teammate is substantially further upfield than I am, so
## passing clearly advances the ball toward the enemy goal.
func _mate_much_better(mate: Node) -> bool:
	var a := actor
	var goal := Config.goal_pos(a.team)
	var my_d: float = a.global_position.distance_to(goal)
	var mate_d: float = mate.global_position.distance_to(goal)
	return (my_d - mate_d) > 12.0


# ============================================================================
# STEERING with awareness (avoid crowds + threats, then move)
# ============================================================================
func _seek(point: Vector3, sprint: bool) -> void:
	# clamp target to playable field so bots never path into the tree-wall
	point.x = clampf(point.x, -Config.FIELD_X + 3.0, Config.FIELD_X - 3.0)
	point.z = clampf(point.z, -Config.FIELD_Z - 4.0, Config.FIELD_Z + 4.0)
	_job_point = point

	# Route the destination through the actor's NavigationAgent3D so the bot paths
	# AROUND the border-cone field instead of straight through it. The agent is a
	# PATHFINDER only; existing local steering (_avoid_and_steer) layers on after.
	#
	# CORRECT FALLBACK: a NavigationAgent3D whose map has no usable navmesh (not
	# baked yet, empty bake, or unsynced) returns its OWN position from
	# get_next_path_position() — NOT the target. If we steered toward that the bot
	# would freeze. So we only trust the agent when it reports the target reachable
	# AND the returned corner is meaningfully away from us; otherwise we steer
	# straight at the real point (the old behavior).
	var steer_to: Vector3 = point
	var agent: NavigationAgent3D = actor.nav_agent
	if agent != null:
		if agent.target_position.distance_to(point) > 1.0:
			agent.target_position = point
		if agent.is_target_reachable():
			var next_corner: Vector3 = agent.get_next_path_position()
			# guard: ignore a corner that's basically where we already stand (the
			# "no usable navmesh" degenerate case) — fall back to straight seek.
			if next_corner.distance_to(actor.global_position) > 1.5:
				steer_to = next_corner

	var d: Vector3 = steer_to - actor.global_position
	d.y = 0
	if d.length_squared() > 9.0:
		intent.move = d.normalized()
		intent.aim = intent.move
		intent.sprint = sprint and actor.stamina > 8.0 and _hustle > 0.85
	else:
		intent.sprint = false

func _avoid_and_steer(delta: float) -> void:
	# blend separation (teammates) + threat-avoidance into the move vector.
	# Separation ALWAYS runs — even if the bot isn't actively seeking — so a
	# stopped cluster still pushes itself apart instead of fusing into a blob.
	var a := actor
	var push := Vector3.ZERO
	for o in GameState.actors():
		if o == a or o.is_tagged():
			continue                              # ignore downed bodies entirely
		# debug fly-cam: the player is "not there" — bots don't space around them
		if GameState.debug_mode and "is_user" in o and o.is_user:
			continue
		var to: Vector3 = a.global_position - o.global_position
		to.y = 0
		var dist: float = to.length()
		if dist < 0.001:
			# exactly overlapping — shove out in a random direction to unstick
			var ang := randf() * TAU
			push += Vector3(cos(ang), 0, sin(ang)) * 1.5
			continue
		if o.team == a.team and dist < 7.0:
			# spacing ramps up sharply at very close range (quadratic) so tight
			# clusters blow apart instead of sitting fused together
			var t: float = 1.0 - dist / 7.0
			push += to.normalized() * t * t * 1.6
		elif o.team != a.team and dist < 7.0 and _job != Job.CHASE and _job != Job.GRAB:
			# THREAT-AWARE avoidance. Only flee an enemy who could actually tag
			# US (i.e. we're on their turf / carrying). If WE could tag THEM (they
			# are the intruder on our turf), we don't flee — we'd rather close in.
			# This fixes enemies pursuing players they can't tag, and players'
			# teammates fleeing enemies who pose no threat to them.
			var they_can_tag_me: bool = o.has_method("can_tag") and o.can_tag(a)
			var i_can_tag_them: bool = a.can_tag(o)
			if they_can_tag_me and not i_can_tag_them:
				push += to.normalized() * (1.0 - dist / 7.0) * 1.4   # flee real threat
			elif not i_can_tag_them:
				push += to.normalized() * (1.0 - dist / 7.0) * 0.5   # mild personal space
		# hard anti-overlap vs ANYONE very close (both teams) — stops the big
		# fused mass where players physically stack on the same spot
		if dist < 3.0:
			push += to.normalized() * (1.0 - dist / 3.0) * 2.0
	# clamp the raw push, then SMOOTH it over time. The raw push flips direction as
	# a bot passes teammates; feeding it straight in made the move vector jitter
	# side-to-side (the forward-motion stutter). Exponential smoothing gives the
	# push momentum so it can't reverse in a single frame.
	var max_push := 2.2
	if push.length() > max_push:
		push = push.normalized() * max_push
	var smooth_t: float = 1.0 - exp(-8.0 * delta)   # frame-rate-independent
	_smoothed_push = _smoothed_push.lerp(push, smooth_t)

	if _smoothed_push.length_squared() > 0.0001:
		# if actively moving, blend with the bot's OWN goal weighted well above
		# spacing (2.2 : 1) so a squad chasing the same objective DRIFTS apart
		# instead of moving as one rigidly-spaced blob. If idle, the push itself
		# becomes the move so a stuck bot steps out of the pile.
		if intent.move.length_squared() < 0.01:
			intent.move = _smoothed_push.normalized()
		else:
			intent.move = (intent.move * 2.2 + _smoothed_push).normalized()


# ============================================================================
# PERCEPTION-DRIVEN HELPERS (bots only act on what they SEE, SENSE, or HEAR
# about from teammates via the shared belief layer in GameState)
# ============================================================================
func _danger_at(pos: Vector3) -> float:
	# 0..~1: enemies the bot can perceive (visible or proximity-felt) near this point
	var d := 0.0
	var seen: Array = []
	seen.append_array(perception.visible_enemies)
	for e in perception.nearby_enemies:
		if not seen.has(e):
			seen.append(e)
	for e in seen:
		var dist: float = pos.distance_to(e.global_position)
		if dist < 30.0:
			d += (1.0 - dist / 30.0)
	# also count belief-points (teammate-shouted threats) at half weight
	for b in GameState.get_threat_beliefs(actor.team):
		var bd: float = pos.distance_to(b.pos)
		if bd < 30.0:
			d += 0.5 * (1.0 - bd / 30.0)
	return clampf(d * 0.5, 0.0, 1.0)

func _grabbable_targets() -> Array:
	# perception already filters by vision cone + LOS; this is what the bot KNOWS
	# about. A bot won't beeline a ball it has no way of seeing.
	return perception.visible_targets

## Any perceived enemies within `radius`, anywhere on the field (used to break the
## border stalemate — bots engage foes in the contested middle, not just our half).
func _nearby_enemies(radius: float) -> Array:
	var out: Array = []
	var here: Vector3 = actor.global_position
	for e in perception.visible_enemies:
		if is_instance_valid(e) and not e.is_tagged() and here.distance_to(e.global_position) <= radius:
			out.append(e)
	for e in perception.nearby_enemies:
		if not out.has(e) and is_instance_valid(e) and not e.is_tagged() and here.distance_to(e.global_position) <= radius:
			out.append(e)
	return out

func _threats_on_our_half() -> Array:
	# directly perceived intruders on our half + teammate-shared beliefs.
	# This is what gives the team reactive defense: one bot sees the player raid,
	# nearby teammates "hear" about it and respond too.
	#
	# An enemy is a THREAT worth chasing if they're intruding on our half and not
	# safe in their own pod — whether or not they're carrying yet. This matches
	# best_tag_target(): an empty-handed intruder CAN be tagged (sent down), so
	# the AI should go punish them instead of ignoring them. Carriers are still
	# prioritized via the chase scoring (urgency), but an unarmed raider walking
	# onto our turf no longer gets a free pass.
	var out: Array = []
	for e in perception.visible_enemies:
		if _is_chase_threat(e):
			out.append(e)
	# proximity-felt enemies (someone right behind you on your half)
	for e in perception.nearby_enemies:
		if not out.has(e) and _is_chase_threat(e):
			out.append(e)
	return out

## An enemy is chase-worthy if our actor could tag them — the same rule the tag
## itself uses, so the AI never chases someone it can't tag, nor ignores someone
## it could. Carriers are made more urgent in the chase scoring, not here.
func _is_chase_threat(e: Node) -> bool:
	return actor.can_tag(e)

# Downed teammates are always known (you feel your team going down)
func _downed_teammates() -> Array:
	var out: Array = []
	for d in GameState.actors():
		if d.team == actor.team and d.is_tagged():
			out.append(d)
	return out

# Our own carrier is always known (it's your teammate)
func _our_carrier() -> Node:
	for o in GameState.actors():
		if o.team == actor.team and o != actor and o.has_target():
			return o
	return null

# Nearest belief or visible threat point near a position — used to react to
# threats the team has heard about even if I can't see them yet.
func _nearest_threat_near(point: Vector3, radius: float) -> Node:
	# only CARRYING enemies count as threats worth moving toward — an unarmed
	# enemy isn't stealing anything, so defenders hold position instead of chasing
	var best: Node = null
	var bd: float = radius
	for e in perception.visible_enemies:
		if not e.has_target():
			continue
		var dist: float = point.distance_to(e.global_position)
		if dist < bd:
			bd = dist; best = e
	return best

func _nearest_own_pod() -> Vector3:
	var pods := Config.pod_positions(actor.team)
	var p0: Vector3 = pods[0]
	var p1: Vector3 = pods[1]
	return p0 if actor.global_position.distance_squared_to(p0) < actor.global_position.distance_squared_to(p1) else p1

func _goal_lane_point() -> Vector3:
	var gz := 84.0 if actor.team == "blue" else -84.0
	return Vector3(_lane_x(70.0), 0, gz)

## A point in the ENEMY stash area, spread by lane, to raid toward. Blue raids
## the -Z end, red raids the +Z end.
func _enemy_stash_point() -> Vector3:
	var ez := -82.0 if actor.team == "blue" else 82.0
	return Vector3(_flanked_lane_x(60.0), 0, ez)

func _border_lane_point() -> Vector3:
	var bz := 14.0 if actor.team == "blue" else -14.0
	return Vector3(_flanked_lane_x(90.0), 0, bz)

## Lane X biased toward the play-caller's called flank. A RAID_LEFT/RIGHT play
## shifts the whole team's raid lanes to one side, overloading that flank — which
## is what makes a called play visibly change the shape of the attack.
func _flanked_lane_x(span: float) -> float:
	var base := _lane_x(span)
	var flank: int = Config.team_flank(actor.team)
	if flank == 0:
		return base
	# push toward the flank side, clamped inside the field
	var shifted := base + float(flank) * 22.0
	return clampf(shifted, -Config.FIELD_X + 5.0, Config.FIELD_X - 5.0)

## LANE-COLUMN TRAVEL (AI_DESIGN.md §2): while far from a travel objective (in Z),
## head up the bot's own lane column instead of diagonally straight at the point —
## raids arrive as a broad front, crossings spread over multiple border gaps, and
## the field's width actually gets used. Releases to the true point when close.
func _lane_travel(dest: Vector3) -> Vector3:
	var dz: float = dest.z - actor.global_position.z
	if absf(dz) < 30.0:
		return dest
	var lx := clampf(_flanked_lane_x(60.0) + _lane_wander, -Config.FIELD_X + 5.0, Config.FIELD_X - 5.0)
	return Vector3(lx, 0, actor.global_position.z + signf(dz) * 26.0)

## JUMP-INTERCEPT detection: returns the point to contest an enemy ball in flight,
## or Vector3.INF when there's nothing interceptable. A ball qualifies if it was
## thrown by the other team, is IN_FLIGHT at jumpable height, and its horizontal
## path passes within reach soon (simple linear look-ahead on its velocity).
func _intercept_chance() -> Vector3:
	var a := actor
	for b in GameState.balls():
		if not is_instance_valid(b) or b.get_state() != 2:   # 2 = IN_FLIGHT
			continue
		var thrower: Node = b.thrower
		if thrower == null or not is_instance_valid(thrower) or thrower.team == a.team:
			continue
		var bp: Vector3 = b.global_position
		var bv: Vector3 = b.linear_velocity
		# closest horizontal approach within the next ~0.9s (sampled)
		var best_d := 999.0
		var best_p := Vector3.INF
		for i in range(1, 7):
			var tt := float(i) * 0.15
			var fp: Vector3 = bp + bv * tt + Vector3(0, -0.5 * Config.GRAVITY * tt * tt, 0)
			var hd := Vector2(fp.x - a.global_position.x, fp.z - a.global_position.z).length()
			if hd < best_d and fp.y > 2.0 and fp.y < 7.0:
				best_d = hd
				best_p = Vector3(fp.x, 0, fp.z)
		if best_d < 6.5:
			return best_p
	return Vector3.INF

func _lane_x(span: float) -> float:
	var n := maxi(1, Config.TEAM_SIZE)
	var slot: int = actor.id % n
	var f := float(slot) / float(maxi(1, n - 1))
	# clamp inside the field walls (X bounds ±55) so bots never path into them
	return clampf(lerpf(-span, span, f), -48.0, 48.0)

func _job_valid() -> bool:
	if _job_target == null:
		return _job in [Job.DEFEND_GOAL, Job.HOLD_LINE, Job.REST, Job.RAID]
	if not is_instance_valid(_job_target):
		return false
	# A CHASE stays valid ONLY while the target is still taggable. Without this,
	# the commit timer kept a bot chasing an enemy who fled back to their own
	# territory (and is no longer a threat) — the long-standing "chased into my
	# own turf empty-handed" bug. Re-check every frame, not just existence.
	if _job == Job.CHASE:
		return actor.can_tag(_job_target)
	return true


# --- claim registry (prevents clumping on one target) -----------------------
func _claim(t: Node) -> void:
	GameState.ai_claims[t.get_instance_id()] = actor.id

func _release_claim() -> void:
	var mine: Array = []
	for k in GameState.ai_claims.keys():
		if GameState.ai_claims[k] == actor.id:
			mine.append(k)
	for k in mine:
		GameState.ai_claims.erase(k)

func _is_claimed_by_other(t: Node) -> bool:
	var k: int = t.get_instance_id()
	return GameState.ai_claims.has(k) and GameState.ai_claims[k] != actor.id

## SPACING: how crowded a point already is with our own teammates. Returns a
## multiplier that drops as more teammates cluster near the point, so a bot is
## discouraged from piling onto a spot the squad already covers. This is what
## makes bots spread out instead of all chasing the same ball.
func _teammate_crowding(point: Vector3, radius: float) -> float:
	var count := 0
	for o in GameState.actors():
		if o == actor or o.team != actor.team or o.is_tagged():
			continue
		if o.global_position.distance_to(point) < radius:
			count += 1
	# 0 teammates near -> 1.0 (full value); each one nearby trims the value
	return clampf(1.0 - 0.28 * float(count), 0.25, 1.0)

## SPACING: how close the nearest enemy is to THIS bot right now. Returns a
## boost (>=1) that rises as an enemy gets near, so the bot physically closest to
## an intruder is the one that peels off to deal with them — no more ignoring an
## enemy three feet away.
func _local_enemy_boost() -> float:
	var nearest := 1e9
	for e in perception.nearby_enemies:
		if e.is_tagged():
			continue
		var d: float = actor.global_position.distance_to(e.global_position)
		if d < nearest:
			nearest = d
	if nearest > 35.0:
		return 1.0
	# within 35u, boost ramps up to ~1.8 at point-blank
	return 1.0 + 0.8 * (1.0 - clampf(nearest / 35.0, 0.0, 1.0))


# --- passing helpers (unchanged logic) --------------------------------------
func _open_teammate_forward() -> Node:
	var goal := Config.goal_pos(actor.team)
	var my_goal_dist: float = actor.global_position.distance_to(goal)
	var best: Node = null
	var best_score: float = -INF
	for o in GameState.actors():
		if o == actor or o.team != actor.team or o.is_tagged() or o.has_target():
			continue
		var dd: float = actor.global_position.distance_to(o.global_position)
		if dd > Config.PASS_RANGE:
			continue
		var advance: float = my_goal_dist - o.global_position.distance_to(goal)
		if advance > 4.0 and advance > best_score:
			best_score = advance; best = o
	return best

func _lane_blocked() -> bool:
	var goal := Config.goal_pos(actor.team)
	var dir: Vector3 = goal - actor.global_position
	var dist := dir.length()
	if dist < 1.0:
		return false
	dir /= dist
	for e in GameState.actors():
		if e.team == actor.team or e.is_tagged():
			continue
		var rel: Vector3 = e.global_position - actor.global_position
		var along := rel.dot(dir)
		if along < 2.0 or along > dist:
			continue
		var perp := (rel - dir * along).length()
		if perp < 7.0:
			return true
	return false
