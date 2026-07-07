extends Node
## Authoritative match state. Tracks the user's team, camera mode, the live
## steal-target counts per team, the derived SCORE (how many of the enemy's
## targets you've banked), and the win condition. Mutated only by the simulation.

enum Phase { TITLE, SIDE_SELECT, COUNTDOWN, PLAYING, FINISHED }

var phase: int = Phase.TITLE
# True while the main-menu overlay is up (even though a background demo match sets
# phase=PLAYING). The pause menu checks this so Esc in the menu doesn't open the
# in-game pause menu.
var menu_open: bool = true
var user_team: String = "blue"
var cam_mode: String = "third"
# True while the debug fly-cam (god mode) is active: the HUD hides and NPCs
# ignore the player (no tagging/targeting). Reset when debug mode is toggled off.
var debug_mode: bool = false
var mode: String = "raiders"        # only "raiders" now (tennis removed); kept for the mode seam
var player_model: String = ""       # chosen player model id (empty = team default)

# --- match stats (for the end-of-match summary) -----------------------------
var stats := {"steals": 0, "tags_made": 0, "times_tagged": 0, "passes": 0, "points": 0}

func reset_stats() -> void:
	stats = {"steals": 0, "tags_made": 0, "times_tagged": 0, "passes": 0, "points": 0}

func bump_stat(key: String, by: int = 1) -> void:
	if stats.has(key):
		stats[key] += by
var winner: String = ""

# Live counts of steal-targets currently belonging to each team (cones + balls).
var counts := {"blue": 0, "red": 0}
# MATCH CLOCK: 15-minute games. If tied at 0:00 we go to OVERTIME — next score
# wins (golden goal). Ticked here (autoload _process) only while PLAYING.
const MATCH_LENGTH := 15.0 * 60.0
var match_time_left: float = MATCH_LENGTH
var overtime := false
# Starting totals, captured at match start, used to derive score.
var start_totals := {"blue": 0, "red": 0}

# Shared AI "claim" registry: target_instance_id -> claiming actor id. Lets bots
# avoid piling on the same target. Lives here (autoload) rather than a static var.
var ai_claims := {}

# Shared "team belief" registry: per-team list of {pos: Vector3, time: float} for
# enemies a teammate has spotted recently. Nearby teammates "hear" about threats
# via this layer with a time decay, so the team feels like it's reacting together
# rather than 14 individuals.
var ai_threat_beliefs := {"blue": [], "red": []}
const BELIEF_TTL := 2.5     # how long a shouted threat sticks around (seconds)
const BELIEF_MAX := 24      # hard cap so a busy fight can't balloon the list

# --- actor cache (optimization) ---------------------------------------------
# get_nodes_in_group allocates a fresh array every call, and ~28 bots each query
# it several times per frame — that's the main O(n^2) cost. We refresh ONE shared
# array per physics frame and everyone reads it, turning N*M queries into 1.
var _actor_cache: Array = []
var _actor_cache_frame: int = -1

func actors() -> Array:
	# returns the cached actor list, refreshing at most once per physics frame
	var f: int = Engine.get_physics_frames()
	if f != _actor_cache_frame:
		_actor_cache_frame = f
		_actor_cache = Engine.get_main_loop().get_nodes_in_group("actors")
	return _actor_cache

func push_threat_belief(team: String, pos: Vector3) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	var list: Array = ai_threat_beliefs.get(team, [])
	# prune-on-write: drop expired, and skip if a fresh belief already sits very
	# close (many bots see the SAME carrier every frame — without this the list
	# grows by dozens of entries per frame and eventually freezes the game)
	var fresh: Array = []
	var is_dup := false
	for b in list:
		if now - b.time >= BELIEF_TTL:
			continue
		if b.pos.distance_to(pos) < 8.0:
			is_dup = true
		fresh.append(b)
	if not is_dup:
		fresh.append({"pos": pos, "time": now})
	if fresh.size() > BELIEF_MAX:
		fresh = fresh.slice(fresh.size() - BELIEF_MAX, fresh.size())
	ai_threat_beliefs[team] = fresh

func get_threat_beliefs(team: String) -> Array:
	var now: float = Time.get_ticks_msec() / 1000.0
	var list: Array = ai_threat_beliefs.get(team, [])
	var fresh: Array = []
	for b in list:
		if now - b.time < BELIEF_TTL:
			fresh.append(b)
	ai_threat_beliefs[team] = fresh
	return fresh

func reset() -> void:
	phase = Phase.TITLE
	match_time_left = MATCH_LENGTH
	overtime = false
	winner = ""
	debug_mode = false
	counts = {"blue": 0, "red": 0}
	# clear AI working state so a new match starts clean (no stale claims/beliefs)
	ai_claims = {}
	ai_threat_beliefs = {"blue": [], "red": []}
	reset_stats()

## Called once after spawning, to remember how many each side began with.
func capture_start_totals() -> void:
	start_totals.blue = counts.blue
	start_totals.red = counts.red

## Score = targets you've taken FROM the enemy = enemy's starting total minus
## what they still hold. (Blue's score grows as red's count drops.)
func score_for(team: String) -> int:
	var enemy := Config.enemy_of(team)
	return maxi(0, start_totals[enemy] - counts[enemy])

func set_counts(blue: int, red: int) -> void:
	counts.blue = blue
	counts.red = red
	if phase == Phase.PLAYING and (blue == 0 or red == 0):
		_finish("blue" if red == 0 else "red")
		return
	# golden goal: first score change that breaks the tie ends overtime
	if phase == Phase.PLAYING and overtime:
		var sb := score_for("blue")
		var sr := score_for("red")
		if sb != sr:
			_finish("blue" if sb > sr else "red")

func _process(delta: float) -> void:
	if phase != Phase.PLAYING or overtime:
		return
	match_time_left = maxf(0.0, match_time_left - delta)
	if match_time_left <= 0.0:
		var sb := score_for("blue")
		var sr := score_for("red")
		if sb == sr:
			overtime = true   # sudden death: next score wins
		else:
			_finish("blue" if sb > sr else "red")

func _finish(team: String) -> void:
	phase = Phase.FINISHED
	winner = team
	# progression: winning on the player's team unlocks the next locked character
	# (any team). Silent for now — the selector shows the new one next visit.
	if team == user_team:
		_award_unlock()
	Events.match_won.emit(team)

## Unlock the next still-locked character in the SAME order the selector shows
## them (starter first, then curated), so unlocks arrive in a predictable sequence.
func _award_unlock() -> void:
	var priority := {
		"blue_boy": 0, "blue_asiangirl": 1, "blue_indianboy": 2, "blue_girl": 3,
		"red_asianboy": 0, "red_boy": 1, "red_fatboy": 2, "red_girl": 3,
	}
	for tm in ["blue", "red"]:
		var defs: Array = CharacterDefs.defs_for_team(tm)
		defs.sort_custom(func(a, b):
			var pa: int = priority.get(String(a.id), 99)
			var pb: int = priority.get(String(b.id), 99)
			if pa != pb:
				return pa < pb
			return String(a.id) < String(b.id))
		for d in defs:
			if not Settings.is_character_unlocked(String(d.id)):
				Settings.unlock_character(String(d.id))
				return
