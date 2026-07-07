class_name MatchScene
extends Node3D
## Assembles a match: field, environment, ball + team managers, and the camera
## rig. Started by the menu via begin().

@onready var field := $Field
@onready var environment := $Environment
@onready var ball_manager := $BallManager
@onready var cone_manager := $ConeManager
@onready var nav_manager := $NavManager
@onready var team_manager := $TeamManager
@onready var camera_rig := $CameraRig
@onready var sun: DirectionalLight3D = $Sun

var safe_zones: SafeZoneManager = null
var coach: Coach = null
var juice: Juice = null
var sky_sun: SkySun = null
var _demo_active := false   # a live menu-background match is running

func begin(user_team: String, cam_mode: String) -> void:
	# if a live menu-background (demo) match is running, tear it down first so we
	# don't stack a second set of teams/balls/cones on top of it.
	if _demo_active:
		_teardown_demo()
	GameState.reset()
	GameState.user_team = user_team
	GameState.cam_mode = cam_mode

	# MODE SEAM: the shared core (actors, cameras, juice, sun, HUD) is identical
	# for every mode. Recess Raiders is the only mode.
	_begin_raiders(user_team, cam_mode)

## Start a LIVE BACKGROUND match for the menu: full Raiders sim filmed by the
## orbiting skycam, with the human's actor hidden so it reads as a bot match.
## No HUD, no countdown. The player "joining" later tears this down via begin().
## Tear down a live menu-background match: free everything it spawned so a real
## match can start clean. Entities live in groups, so clear those.
func _teardown_demo() -> void:
	_demo_active = false
	# Free everything the demo spawned. Crucially, remove each node from its
	# groups IMMEDIATELY (queue_free is deferred to end-of-frame, but the new
	# match spawns this same frame — without eager group removal the new bots
	# would briefly share the field with the dying demo bots, doubling every
	# team and corrupting AI/claims. That was breaking both teams.)
	for grp in ["actors", "balls", "goal_cones", "border_cones", "carryables"]:
		for n in get_tree().get_nodes_in_group(grp):
			if is_instance_valid(n):
				for g in n.get_groups():
					n.remove_from_group(g)
				n.queue_free()
	team_manager.player_actor = null
	# clear the cached actor list so the new match doesn't read stale entries
	GameState._actor_cache = []
	GameState._actor_cache_frame = -1

func begin_demo() -> void:
	GameState.reset()
	GameState.user_team = "blue"
	GameState.mode = "raiders"
	_begin_raiders("blue", "orbit")
	# hide the "player" actor — the 27 bots provide all the on-field action, and
	# the orbiting skycam never needs to focus on the hidden slot.
	var pa: Node = team_manager.player_actor
	if pa != null and is_instance_valid(pa):
		pa.visible = false
		if pa.has_method("set_physics_process"):
			pa.set_physics_process(false)   # park it; it's off-camera and hidden
	GameState.cam_mode = "orbit"
	# the menu needs a visible cursor — make sure nothing left it captured
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# make sure the orbit camera is the active one so the demo actually renders
	# behind the menu (cold start has no other camera making it current)
	if camera_rig != null and camera_rig.camera != null:
		camera_rig.camera.make_current()
	_demo_active = true

func _begin_raiders(user_team: String, cam_mode: String) -> void:
	# set the camera mode FIRST so that when set_target() later decides whether to
	# capture the mouse, it already knows we're in orbit (menu) mode and leaves
	# the cursor visible. (Previously cam_mode was set after, so the demo briefly
	# looked like "third" and captured the mouse on the menu — hiding the cursor.)
	GameState.cam_mode = cam_mode
	field.build()
	environment.build()

	team_manager.camera_rig = camera_rig
	ball_manager.spawn_balls()
	cone_manager.spawn_all()
	# Build the field navmesh now that the cones exist: register each border cone
	# as an obstruction so the baked navmesh routes bots around the midline, then
	# bake. Done before team spawn so agents have a navmesh from their first tick.
	# Fail-safe: if anything here errors the bots fall back to straight-line seek.
	# Border cones no longer collide (visual-only), so we DON'T carve them out of
	# the navmesh anymore — bots path straight through the midline like players do.
	nav_manager.build()
	team_manager.spawn_teams(user_team)

	# safe-zone rules (occupancy cap, dwell timer, lockout)
	if safe_zones == null:
		safe_zones = SafeZoneManager.new()
		add_child(safe_zones)

	# sideline coach: lives in the COACH ZONE on the player's side of the field,
	# paces there, reacts to game events. Pure observer — no gameplay coupling.
	if coach == null:
		coach = Coach.new()
		add_child(coach)
		var side: float = 1.0 if user_team == "blue" else -1.0
		var coach_x: float = (Config.FIELD_X + Config.COACH_ZONE_WIDTH * 0.5) * side
		coach.setup(user_team, Vector3(coach_x, 0.0, 0.0), team_manager.player_actor)

	camera_rig.set_target(team_manager.player_actor)

	# game-feel layer (screen shake + hit-pause). Pure presentation.
	if juice == null:
		juice = Juice.new()
		add_child(juice)
		juice.setup(camera_rig.camera)

	# the sun: a big bright sphere that slowly orbits the player so the sky is
	# never empty and it can't clip (unshaded, no depth test, tracks the player)
	if sky_sun == null:
		var sun_scene: PackedScene = load("res://assets/props/world/sun.glb")
		sky_sun = SkySun.new()
		add_child(sky_sun)
		sky_sun.setup(team_manager.player_actor, sun_scene, sun)

	# configure the sun's shadows from the quality setting, and re-apply whenever
	# settings change
	_apply_shadow_quality()
	if not Events.settings_applied.is_connected(_apply_shadow_quality):
		Events.settings_applied.connect(_apply_shadow_quality)

	GameState.capture_start_totals()
	Events.match_started.emit(user_team, cam_mode)
	if cam_mode == "orbit":
		# demo/menu-background match: no countdown, just play under the skycam
		GameState.match_time_left = GameState.MATCH_LENGTH
		GameState.overtime = false
		GameState.phase = GameState.Phase.PLAYING
	else:
		_run_countdown()

## Configure the sun's shadows from Settings.shadow_quality (0 off/low, 1 med,
## 2 high). This makes the previously-dead shadow-quality dropdown actually work,
## and gives the low-poly scene properly grounded, soft shadows at higher tiers.
func _apply_shadow_quality() -> void:
	if sun == null or not is_instance_valid(sun):
		return
	var q: int = Settings.shadow_quality if "shadow_quality" in Settings else 2
	match q:
		0:
			sun.shadow_enabled = false
		1:
			sun.shadow_enabled = true
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
			sun.shadow_blur = 1.0
			sun.directional_shadow_max_distance = 250.0
			sun.shadow_bias = 0.06
		_:
			sun.shadow_enabled = true
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
			sun.shadow_blur = 1.5
			sun.directional_shadow_max_distance = 400.0
			sun.shadow_bias = 0.04
			sun.directional_shadow_split_1 = 0.07
			sun.directional_shadow_split_2 = 0.2
			sun.directional_shadow_split_3 = 0.5

## Match-start arc: a short "3,2,1, RAID!" countdown that holds the sim until go.
## Emits countdown_tick each beat so the HUD shows it and audio plays a tick.
func _run_countdown() -> void:
	GameState.phase = GameState.Phase.COUNTDOWN
	for n in [3, 2, 1]:
		Events.countdown_tick.emit(n)
		await get_tree().create_timer(0.8).timeout
		if GameState.phase != GameState.Phase.COUNTDOWN:
			return                       # bailed (e.g. quit) — don't force PLAYING
	Events.countdown_tick.emit(0)        # 0 == "RAID!"
	GameState.match_time_left = GameState.MATCH_LENGTH
	GameState.overtime = false
	GameState.phase = GameState.Phase.PLAYING

## Reset the match in place: re-home every carryable, reset every actor, zero the
## scores — without rebuilding the field/environment. Returns to live PLAYING.
func restart() -> void:
	GameState.winner = ""
	# re-home all balls and goal cones to their ORIGINAL team's zone
	for c in get_tree().get_nodes_in_group("carryables"):
		c.restore_origin()
	# reset every actor to spawn, clear tags/carry/stamina
	for a in GameState.actors():
		if a.carried != null:
			a.carried = null
		a._return_to_spawn()
		a.stamina = Config.STAMINA_MAX
	team_manager.reset_team_state()
	# recount and re-capture totals
	ball_manager.recount()
	GameState.capture_start_totals()
	Events.match_restart.emit()
	_run_countdown()

## Return to the main menu from a finished match: tear down the live match and
## spin the demo/skycam background back up. The music keeps looping (the Welcome
## audio is NOT replayed — that only fires once at program launch). The menu
## overlay re-shows itself by listening for returned_to_menu.
func return_to_menu() -> void:
	GameState.reset()
	GameState.mode = "raiders"
	GameState.menu_open = true
	# tear down the finished match cleanly (eager group removal so the new demo
	# backdrop doesn't briefly double up), then spin the demo background back up.
	_teardown_demo()
	begin_demo()
	Events.returned_to_menu.emit()
