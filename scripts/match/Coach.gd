class_name Coach
extends Node3D
## A sideline coach character — pure reactive observer, totally separate from the
## kids' AI. He paces within the COACH ZONE (the strip between the field edge and
## the trees), never enters the field, reacts to game events with moods/animations,
## and pops old-timey speech-bubble quips above his head.

enum Mood { IDLE, HAPPY, ANGRY, HYPE }

const COACH_BASE: PackedScene = preload("res://assets/character/coach/coach_base.glb")
const MODEL_SCALE := 4.5                     # clearly adult — ~1.6x the kids' height

# clip key -> source glb + internal animation name
const CLIPS := {
	"alert": ["res://assets/character/coach/coach_alert.glb", "Armature|Alert|baselayer"],
	"walk": ["res://assets/character/coach/coach_walk.glb", "Armature|walking_man|baselayer"],
	"run": ["res://assets/character/coach/coach_run.glb", "Armature|running|baselayer"],
	"cheer": ["res://assets/character/coach/coach_cheer.glb", "Armature|Cheer_with_Both_Hands|baselayer"],
	"cheer2": ["res://assets/character/coach/coach_cheer2.glb", "Armature|Cheer_with_Both_Hands_1|baselayer"],
	"stomp": ["res://assets/character/coach/coach_stomp.glb", "Armature|Angry_Ground_Stomp|baselayer"],
	"agree": ["res://assets/character/coach/coach_agree.glb", "Armature|Agree_Gesture|baselayer"],
	"dance_boom": ["res://assets/character/coach/coach_dance_boom.glb", "Armature|Boom_Dance|baselayer"],
	"dance_cardio": ["res://assets/character/coach/coach_dance_cardio.glb", "Armature|Cardio_Dance|baselayer"],
	"dance_groove": ["res://assets/character/coach/coach_dance_groove.glb", "Armature|Gangnam_Groove|baselayer"],
	"dance_night": ["res://assets/character/coach/coach_dance_night.glb", "Armature|All_Night_Dance|baselayer"],
	"backflip": ["res://assets/character/coach/coach_backflip.glb", "Armature|Backflip_Jump|baselayer"],
	"sit": ["res://assets/character/coach/coach_sit.glb", "Armature|Stand_to_Sit_Transition_M|baselayer"],
	"stand": ["res://assets/character/coach/coach_stand.glb", "Armature|Sit_to_standTransition_Female_2|baselayer"],
	"sit_idle": ["res://assets/character/coach/coach_sitidle.glb", "Armature|Sitting_Clap|baselayer"],
}

# per-mood quip pools
const QUIPS := {
	Mood.IDLE: [
		"Back in MY day we played in the SNOW!",
		"Walk it off, ya hear?",
		"That's how the pros do it!",
		"You call that hustle?",
		"Drink some water, champ!",
	],
	Mood.HAPPY: [
		"Now THAT'S what I'm talkin' about!",
		"Atta kid! Atta KID!",
		"Beautiful! Just beautiful!",
		"That's the GOOD stuff!",
	],
	Mood.ANGRY: [
		"My GRANDMA runs faster than that!",
		"Give me twenty laps! TWENTY!",
		"What was THAT?!",
		"You're killin' me out there!",
	],
	Mood.HYPE: [
		"GO GO GO!",
		"Put some MUSTARD on it!",
		"This is the BIG one!",
		"Leave it all on the field!",
	],
}

var _user_team := "blue"
var _mood: int = Mood.IDLE
var _zone_center := Vector3.ZERO
var _player: Node3D = null
var _zone_half := Vector3(4.0, 0, 70.0)      # thin strip along X, paces the length in Z
var _target := Vector3.ZERO
var _speed := 18.0
var _mood_timer := 0.0
# bench break: every now and then the coach walks to the nearest bench, sits and
# claps for a bit, then gets back up and resumes patrol. Purely cosmetic charm.
const BENCH_XS := 63.2          # just in front of the bench row (benches at x=65)
const BENCH_ZS := [80.0, 45.0, -45.0, -80.0]
var _sit_state := 0             # 0 none, 1 walk-to-bench, 2 sitting-down, 3 seated, 4 standing-up
var _sit_timer := 0.0
var _bench_break_cd := 50.0     # first break ~50s in; then randomized
var _bench_target := Vector3.ZERO
var _pre_sit_y := 0.0
var _emote_cooldown := 0.0    # forced patrol time after an emote, so he keeps following the player
var _quip_timer := 0.0

var _anim: AnimationPlayer
var _state_machine: AnimationNodeStateMachinePlayback
var _cur_anim := ""                  # which clip is playing now (avoid re-travel spam)
var _anim_tree: AnimationTree = null # kept so we can set playback speed
var _bubble: Sprite3D = null
var _bubble_label: Label = null
var _bubble_vp: SubViewport = null
var _bubble_timer := 0.0

func setup(user_team: String, zone_center: Vector3, player: Node3D = null) -> void:
	_user_team = user_team
	_zone_center = zone_center
	_player = player
	global_position = zone_center
	_target = zone_center
	_build_model()
	_build_bubble()
	# react to game events — no coupling to the AI, just listens
	Events.ball_banked.connect(_on_ball_banked)
	Events.match_won.connect(_on_match_won)
	Events.actor_tagged.connect(_on_actor_tagged)
	_pick_new_target()
	_quip_timer = randf_range(4.0, 9.0)

func _build_model() -> void:
	var inst := COACH_BASE.instantiate()
	inst.scale = Vector3(MODEL_SCALE, MODEL_SCALE, MODEL_SCALE)
	add_child(inst)
	_anim = _find_anim_player(inst)
	if _anim == null:
		return
	_harvest_clips()
	_build_tree(inst)

func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null

func _harvest_clips() -> void:
	var lib := AnimationLibrary.new()
	for key in CLIPS.keys():
		var entry: Array = CLIPS[key]
		var src_scene: PackedScene = load(entry[0])
		if src_scene == null:
			continue
		var src_inst := src_scene.instantiate()
		var src_player := _find_anim_player(src_inst)
		if src_player != null:
			for lib_name in src_player.get_animation_library_list():
				var l := src_player.get_animation_library(lib_name)
				for anim_name in l.get_animation_list():
					if anim_name == entry[1]:
						var clip: Animation = l.get_animation(anim_name).duplicate()
						clip.loop_mode = Animation.LOOP_LINEAR
						if lib.has_animation(key):
							lib.remove_animation(key)
						lib.add_animation(key, clip)
		src_inst.queue_free()
	if _anim.has_animation_library("coach"):
		_anim.remove_animation_library("coach")
	_anim.add_animation_library("coach", lib)

func _build_tree(_inst: Node) -> void:
	var tree := AnimationTree.new()
	add_child(tree)
	# now that the tree is in the scene it shares a common parent with _anim,
	# so these relative paths resolve (fixes the "common_parent is null" T-pose)
	tree.anim_player = tree.get_path_to(_anim)
	var sm := AnimationNodeStateMachine.new()
	var keys: Array = CLIPS.keys()
	for key in keys:
		var node := AnimationNodeAnimation.new()
		node.animation = "coach/" + key
		sm.add_node(key, node, Vector2(160, 80))
	# fully-connected immediate transitions so travel() can reach any state from
	# any state WITHOUT snapping to a bind/T-pose (the missing piece before)
	for a in keys:
		for b in keys:
			if a == b:
				continue
			var trans := AnimationNodeStateMachineTransition.new()
			trans.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
			sm.add_transition(a, b, trans)
	tree.tree_root = sm
	# point the tree at the model so clip tracks resolve against the same skeleton
	tree.root_node = tree.get_path_to(_anim.get_parent())
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	tree.active = true
	_anim_tree = tree
	# slow his animations down — they play too fast/twitchy at native speed
	_anim.speed_scale = 0.55
	_state_machine = tree["parameters/playback"]
	_state_machine.travel("alert")

func _build_bubble() -> void:
	# a speech bubble = a Label rendered into a SubViewport shown on a Sprite3D
	# billboard above the coach's head
	_bubble_vp = SubViewport.new()
	_bubble_vp.size = Vector2i(320, 96)
	_bubble_vp.transparent_bg = true
	_bubble_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_bubble_vp)

	var panel := PanelContainer.new()
	panel.size = Vector2(320, 96)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.92)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(12)
	style.border_color = Color(0.15, 0.35, 0.7)
	style.set_border_width_all(3)
	panel.add_theme_stylebox_override("panel", style)
	_bubble_vp.add_child(panel)

	_bubble_label = Label.new()
	_bubble_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bubble_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_bubble_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bubble_label.add_theme_color_override("font_color", Color(0.1, 0.12, 0.2))
	_bubble_label.add_theme_font_size_override("font_size", 26)
	panel.add_child(_bubble_label)

	_bubble = Sprite3D.new()
	_bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_bubble.texture = _bubble_vp.get_texture()
	_bubble.pixel_size = 0.03
	_bubble.position = Vector3(0, 13.0, 0)     # above his head
	_bubble.modulate = Color(1, 1, 1, 0)        # start hidden
	_bubble.no_depth_test = true
	add_child(_bubble)

func _process(delta: float) -> void:
	if _anim == null:
		return
	_emote_cooldown = maxf(0.0, _emote_cooldown - delta)
	_wander(delta)
	_tick_mood(delta)
	_tick_quip(delta)
	_tick_bubble(delta)

func _wander(delta: float) -> void:
	# bench break has its own little state machine (walk over, sit, clap, stand)
	if _sit_state != 0:
		_tick_bench(delta)
		return
	# emote moods stand still and perform FACING THE FIELD (face_field is set once
	# by _set_mood; re-asserting the player every frame made him snap oddly).
	if _mood != Mood.IDLE:
		return
	# occasionally take a bench break when nothing exciting is happening
	_bench_break_cd -= delta
	if _bench_break_cd <= 0.0:
		_start_bench_break()
		return
	# track the player: run up and down the sideline to stay level with them on
	# Z, so the coach mirrors where the action is. Player is the orbit centre.
	var target_z := _zone_center.z
	if _player != null and is_instance_valid(_player):
		target_z = _player.global_position.z
	_target = Vector3(_zone_center.x, 0, target_z)
	var to: Vector3 = _target - global_position
	to.y = 0
	var d := to.length()
	if d > 1.0:
		var dir := to / d
		global_position += dir * _speed * delta
		# run animation kicks in sooner so he reads as actively sprinting the
		# sideline to keep up with the action, walking only for small adjustments
		_set_anim("run" if d > 6.0 else "walk")
		# FACE WHERE HE'S GOING while moving (was: always facing the field, which
		# made him sprint sideways like a crab). He turns to the field when he
		# stops or emotes.
		rotation.y = atan2(dir.x, dir.z)
	else:
		_set_anim("alert")
		_face_player()
	_clamp_to_zone()

## Always turn to face the player (so the coach watches the action).
func _face_player() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var to: Vector3 = _player.global_position - global_position
	to.y = 0
	if to.length_squared() > 0.01:
		rotation.y = atan2(to.x, to.z)

func _clamp_to_zone() -> void:
	global_position.x = clampf(global_position.x, _zone_center.x - _zone_half.x, _zone_center.x + _zone_half.x)
	global_position.z = clampf(global_position.z, _zone_center.z - _zone_half.z, _zone_center.z + _zone_half.z)
	global_position.y = _zone_center.y

func _pick_new_target() -> void:
	_target = _zone_center + Vector3(
		randf_range(-_zone_half.x, _zone_half.x),
		0,
		randf_range(-_zone_half.z, _zone_half.z))

func _tick_mood(delta: float) -> void:
	if _mood == Mood.IDLE:
		return
	_mood_timer -= delta
	if _mood_timer <= 0.0:
		_emote_cooldown = 6.0     # patrol for at least 6s before the next emote
		_set_mood(Mood.IDLE)

func _tick_quip(delta: float) -> void:
	_quip_timer -= delta
	if _quip_timer <= 0.0:
		_quip_timer = randf_range(6.0, 12.0)
		_say_quip(_mood)

func _tick_bubble(delta: float) -> void:
	if _bubble == null:
		return
	if _bubble_timer > 0.0:
		_bubble_timer -= delta
		# fade in fast, hold, fade out
		var a: float = clampf(_bubble_timer, 0.0, 1.0)
		if _bubble_timer > 3.0:
			a = clampf(4.0 - _bubble_timer, 0.0, 1.0)
		_bubble.modulate = Color(1, 1, 1, a)
	else:
		_bubble.modulate = Color(1, 1, 1, 0)

func _set_mood(m: int) -> void:
	if _sit_state != 0:
		return   # no emoting mid bench-break; he is off the clock
	_mood = m
	match m:
		Mood.IDLE:
			_set_anim("walk")
		Mood.HAPPY:
			_mood_timer = 5.5
			# a random dance from the coach's repertoire
			_set_anim(["dance_boom", "dance_cardio", "dance_groove", "dance_night"].pick_random())
			face_field()
		Mood.ANGRY:
			_mood_timer = 4.5
			# stomp the ground in frustration
			_set_anim("stomp")
			face_field()
		Mood.HYPE:
			_mood_timer = 4.0
			# cheer the team on (occasionally a celebratory backflip)
			_set_anim(["cheer", "cheer2", "cheer", "backflip"].pick_random())
			face_field()
	_say_quip(m)

func _start_bench_break() -> void:
	# nearest bench along the sideline row
	var bz: float = BENCH_ZS[0]
	for z in BENCH_ZS:
		if absf(z - global_position.z) < absf(bz - global_position.z):
			bz = z
	_bench_target = Vector3(BENCH_XS, 0.0, bz)
	_sit_state = 1

func _tick_bench(delta: float) -> void:
	match _sit_state:
		1:   # walk over to the bench spot
			var to: Vector3 = _bench_target - global_position
			to.y = 0
			var d := to.length()
			if d > 1.2:
				var dir := to / d
				global_position += dir * (_speed * 0.55) * delta
				rotation.y = atan2(dir.x, dir.z)
				_set_anim("walk")
			else:
				# arrived: face the field and sit down (lift onto the seat)
				face_field()
				_pre_sit_y = global_position.y
				global_position.y = 2.3      # bench seat height (scale-4 bench)
				global_position.x = 64.2     # scoot back onto the seat
				_set_anim("sit")
				_sit_state = 2
				_sit_timer = 1.6             # sit-down transition length to show
		2:   # sitting down -> seated clap
			_sit_timer -= delta
			if _sit_timer <= 0.0:
				_set_anim("sit_idle")
				_sit_state = 3
				_sit_timer = randf_range(8.0, 13.0)
		3:   # seated, clapping along with the game
			_sit_timer -= delta
			if _sit_timer <= 0.0:
				_set_anim("stand")
				_sit_state = 4
				_sit_timer = 1.5
		4:   # standing back up -> resume patrol
			_sit_timer -= delta
			if _sit_timer <= 0.0:
				global_position.y = _pre_sit_y
				global_position.x = _zone_center.x
				_sit_state = 0
				_bench_break_cd = randf_range(60.0, 110.0)
				_set_anim("alert")

func face_field() -> void:
	# turn to face the playing field — toward field center on X (he stands at X=±61)
	var to_field: Vector3 = Vector3(0, 0, global_position.z) - global_position
	if to_field.length_squared() > 0.01:
		rotation.y = atan2(to_field.x, to_field.z)

func _set_anim(key: String) -> void:
	# only switch when the state actually changes — calling travel() every frame
	# restarts/re-evaluates the state machine and makes the coach look twitchy
	if key == _cur_anim:
		return
	_cur_anim = key
	if _state_machine != null:
		_state_machine.travel(key)

func _say_quip(mood: int) -> void:
	if _bubble_label == null:
		return
	var pool: Array = QUIPS.get(mood, QUIPS[Mood.IDLE])
	if pool.is_empty():
		return
	_bubble_label.text = pool[randi() % pool.size()]
	_bubble_timer = 4.0       # ~1s fade in, ~2s hold, ~1s fade out

# --- event reactions --------------------------------------------------------
func _on_ball_banked(team: String) -> void:
	if team == _user_team:
		_set_mood(Mood.HAPPY)
	else:
		_set_mood(Mood.ANGRY)

func _on_match_won(team: String) -> void:
	if team == _user_team:
		_set_mood(Mood.HAPPY)
	else:
		_set_mood(Mood.ANGRY)

func _on_actor_tagged(actor: Node) -> void:
	# tags happen constantly across 28 bots — if every one triggered an emote the
	# coach would never stop performing and never patrol. So: only occasionally,
	# and only when he hasn't emoted recently (cooldown), so patrolling is the
	# default and emotes are rare punctuation.
	if _mood != Mood.IDLE or _emote_cooldown > 0.0:
		return
	if actor == null or not is_instance_valid(actor):
		return
	if actor.team == _user_team:
		if randf() < 0.12:
			_set_mood(Mood.ANGRY)
	else:
		if randf() < 0.14:
			_set_mood(Mood.HYPE)
