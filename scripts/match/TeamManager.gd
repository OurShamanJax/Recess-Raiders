class_name TeamManager
extends Node3D
## Spawns both teams, injects controllers, and runs each AI team's PlayCaller.
## The human replaces one slot on their chosen team. AI bots get an AIController;
## the human gets a PlayerController. Each AI team has one PlayCaller that assigns
## states to its bots every tick.

const ActorScene := preload("res://scenes/Actor.tscn")
const PlayerControllerScript := preload("res://scripts/actor/controllers/PlayerController.gd")
const AIControllerScript := preload("res://scripts/actor/controllers/AIController.gd")
const CharacterRigScript := preload("res://scripts/actor/CharacterRig.gd")

var camera_rig: Node = null
var player_actor: Actor = null

# AI bookkeeping for the conductors
var _ai_bots := {"blue": [], "red": []}     # team -> Array[AIController]
var _play_callers := {}                       # team -> PlayCaller

## Build a role list for a team of `n`: ~15% goalies, ~35% sentries, rest strikers.
## The conductor reassigns dynamically anyway; these are just starting biases.
func _roles_for(n: int) -> Array:
	var roles: Array = []
	var goalies: int = maxi(1, int(round(n * 0.15)))
	var sentries: int = maxi(1, int(round(n * 0.35)))
	for i in range(n):
		if i < goalies:
			roles.append("goalie")
		elif i < goalies + sentries:
			roles.append("sentry")
		else:
			roles.append("striker")
	return roles

func spawn_teams(user_team: String) -> void:
	var enemy := Config.enemy_of(user_team)
	var id := 0
	var user_roles := _roles_for(Config.TEAM_SIZE)
	var enemy_roles := _roles_for(Config.TEAM_SIZE)

	player_actor = _spawn(user_team, "player", true, id); id += 1
	# human takes a striker slot; give the remaining roles to the AI allies
	for i in range(Config.TEAM_SIZE - 1):
		_spawn(user_team, user_roles[i], false, id); id += 1
	for i in range(Config.TEAM_SIZE):
		_spawn(enemy, enemy_roles[i], false, id); id += 1

	# One conductor per team that has AI bots.
	for team in ["blue", "red"]:
		if not _ai_bots[team].is_empty():
			_play_callers[team] = PlayCaller.new(team)

func _spawn(team: String, role: String, is_user: bool, id: int) -> Actor:
	var a: Actor = ActorScene.instantiate()
	add_child(a)
	a.setup(team, role, is_user, id)
	var back_z := 96.0 if team == "blue" else -96.0
	a.spawn_pos = Vector3(0, 0, back_z)
	# spread across the back line in two staggered rows so the team doesn't overlap.
	# Columns scale with team size (ceil(size/2) per row) so the formation stays
	# tidy whether it is 10 or 14 a side.
	var per_team := Config.TEAM_SIZE
	var slot := id % per_team
	@warning_ignore("integer_division")
	var cols := (per_team + 1) / 2
	var grid_col := slot % cols
	@warning_ignore("integer_division")
	var row := slot / cols
	var x := lerpf(-48.0, 48.0, float(grid_col) / float(maxi(cols - 1, 1)))
	var z := back_z - (2.0 if team == "blue" else -2.0) * float(row)
	a.spawn_pos = Vector3(x, 0, z)
	a.global_position = a.spawn_pos
	# face the enemy end: blue (at +Z) looks toward -Z, red (at -Z) toward +Z
	a.heading = PI if team == "blue" else 0.0

	# --- assign stats + name (Phase 1 scaffolding) ---
	var is_f := randf() < 0.5
	a.sex = "F" if is_f else "M"
	var pool: Array = Config.NAMES_F if is_f else Config.NAMES_M
	a.display_name = "You" if is_user else pool[randi() % pool.size()]
	a.height_cm = randf_range(120.0, 145.0)
	a.weight_kg = randf_range(26.0, 42.0)
	# heavier/taller stamina pool + burn (kept subtle; sprint speed identical)
	a.stamina = Config.STAMINA_MAX

	# model (presentation): rigged, animated kid. Each team is split EVENLY across
	# all CharacterDefs registered for that team (defs_for_team), picked by roster
	# slot. Adding a new def for a team automatically rebalances the split — e.g.
	# blue with [blue_boy, blue_girl, blue_indianboy] divides the 14 kids ~3 ways.
	# The goal is eventually one unique model per NPC; until then this spreads the
	# available models across the roster. Order is sorted by id for determinism so
	# the same slot always gets the same body across a match.
	var team_defs: Array = CharacterDefs.defs_for_team(team)
	team_defs.sort_custom(func(da, db): return String(da.id) < String(db.id))

	var def: CharacterDef = null
	if team_defs.size() > 0:
		def = team_defs[slot % team_defs.size()]

	# the human player overrides their body with the menu choice (a def id).
	if is_user and GameState.player_model != "":
		var chosen: CharacterDef = CharacterDefs.get_def(GameState.player_model)
		# legacy menu ids ("boy"/"girl") map to the team's first/girl def
		if chosen == null:
			if GameState.player_model == "girl":
				chosen = CharacterDefs.get_def("blue_girl" if team == "blue" else "red_girl")
			elif GameState.player_model == "boy":
				chosen = CharacterDefs.get_def("blue_boy" if team == "blue" else "red_boy")
		if chosen != null and chosen.team == team:
			def = chosen

	# Female bodies (the girl defs) read as female: female sex + name. Detected by
	# id since CharacterDef has no sex field yet. use_girl is passed to rig.build
	# for the legacy fallback path (only meaningful if def is null).
	var is_female := def != null and String(def.id).contains("girl")
	var use_girl := is_female
	if is_female:
		a.sex = "F"
		if not is_user:
			var pool_f: Array = Config.NAMES_F
			a.display_name = pool_f[randi() % pool_f.size()]

	var rig := CharacterRigScript.new()
	a.add_child(rig)
	var col := Color(0.25, 0.45, 1.0) if team == "blue" else Color(1.0, 0.4, 0.32)
	# 1.1 ADDITIVE MIGRATION: all team bodies load via CharacterDef. Coach is a
	# separate system (Coach.gd) and is not affected. If def is null (no defs for
	# the team, or a bad load), rig.build falls back to its hardcoded path so the
	# game can't break.
	# visual stature from height_cm: 120..145cm -> ~0.93..1.08x, centered at 130cm.
	# Gives each kid an individual height within an elementary range.
	var height_mult: float = 1.0 + (a.height_cm - 130.0) / 130.0 * 0.9
	rig.build(col, role, team, use_girl, def, height_mult)
	rig.add_nametag("%s (%s)" % [a.display_name, a.sex], col)
	a.rig = rig
	rig.snap_heading(a.heading)   # face midfield at spawn, not the trees

	# controller (input). Set subclass-only members on a concrete-typed local so
	# the static analyzer is happy, then widen to BaseController for storage.
	var ctrl: BaseController
	if is_user:
		var pc: PlayerController = PlayerControllerScript.new()
		pc.camera_rig = camera_rig
		ctrl = pc
	else:
		var ai: AIController = AIControllerScript.new()
		ai.role = role
		_ai_bots[team].append(ai)
		ctrl = ai
	a.add_child(ctrl)
	ctrl.setup(a)
	a.controller = ctrl
	return a

func _physics_process(delta: float) -> void:
	if GameState.phase != GameState.Phase.PLAYING:
		return
	# PlayCallers assign states BEFORE the actors build their intents this frame.
	# TeamManager is the parent of all actors, so its _physics_process runs first
	# in tree order — states are fresh when each actor's controller reads them.
	for team in _play_callers.keys():
		var bots: Array = _ai_bots[team]
		if not bots.is_empty():
			_play_callers[team].conduct(bots, delta)

## Clear AI state on restart so bots don't keep stale chase/rescue targets.
func reset_team_state() -> void:
	for team in _ai_bots.keys():
		for ctrl: AIController in _ai_bots[team]:
			ctrl.state = 0          # RAID
			ctrl.chase_target = null
			ctrl.rescue_target = null
