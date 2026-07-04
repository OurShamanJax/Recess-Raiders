class_name CharacterRig
extends Node3D
## Presentation: the rigged, animated boy model (replaces the old box ActorModel).
## Loads the base GLB, harvests animation clips from the per-clip GLBs into one
## AnimationPlayer, and drives a small state machine:
##   locomotion (walk<->run blended by speed) / dead / arise.
## Reads state the Actor pushes in; never touches simulation.

## Per-team model + clip sets. Blue uses the original boy; red uses the red boy
## which ships extra walk/run variants for visual variety. Both rigs share the
## same bone structure and default +Z facing, so facing_offset_deg=0 fits both.
const BLUE_BASE: PackedScene = preload("res://assets/character/boy_base.glb")
const RED_BASE: PackedScene = preload("res://assets/character/red/red_base.glb")

const BLUE_CLIPS := {
	"alert": "res://assets/character/boy_alert.glb",
	"walk": "res://assets/character/boy_walk.glb",
	"run": "res://assets/character/boy_run.glb",
	"dead": "res://assets/character/boy_dead.glb",
	"arise": "res://assets/character/boy_arise.glb",
}
const BLUE_NAMES := {
	"alert": "Armature|Alert|baselayer",
	"walk": "Armature|walking_man|baselayer",
	"run": "Armature|running|baselayer",
	"dead": "Armature|Dead|baselayer",
	"arise": "Armature|Arise|baselayer",
}
# Red ships extra variants: casual/unsteady walks and three run styles.
const RED_CLIPS := {
	"alert": "res://assets/character/red/red_alert.glb",
	"walk": "res://assets/character/red/red_walk.glb",
	"walk_casual": "res://assets/character/red/red_walk_casual.glb",
	"run": "res://assets/character/red/red_run.glb",
	"run_fast": "res://assets/character/red/red_run_fast.glb",
	"run_03": "res://assets/character/red/red_run_03.glb",
	"dead": "res://assets/character/red/red_dead.glb",
	"arise": "res://assets/character/red/red_arise.glb",
}
const RED_NAMES := {
	"alert": "Armature|Alert|baselayer",
	"walk": "Armature|walking_man|baselayer",
	"walk_casual": "Armature|Casual_Walk|baselayer",
	"run": "Armature|running|baselayer",
	"run_fast": "Armature|RunFast|baselayer",
	"run_03": "Armature|Run_03|baselayer",
	"dead": "Armature|Dead|baselayer",
	"arise": "Armature|Arise|baselayer",
}

# Girl model — used for every other red kid. Same rig + internal anim names as red.
const GIRL_BASE: PackedScene = preload("res://assets/character/girl/girl_base.glb")
const GIRL_CLIPS := {
	"alert": "res://assets/character/girl/girl_alert.glb",
	"walk": "res://assets/character/girl/girl_walk.glb",
	"walk_casual": "res://assets/character/girl/girl_walk_casual.glb",
	"run": "res://assets/character/girl/girl_run.glb",
	"run_fast": "res://assets/character/girl/girl_run_fast.glb",
	"run_03": "res://assets/character/girl/girl_run_03.glb",
	"dead": "res://assets/character/girl/girl_dead.glb",
	"arise": "res://assets/character/girl/girl_arise.glb",
}
const GIRL_NAMES := RED_NAMES   # identical internal animation names

# active set (chosen by team in build())
var _clip_sources: Dictionary = BLUE_CLIPS
var _src_name: Dictionary = BLUE_NAMES
var _is_red := false
var _is_girl := false
var _run_variant := "run"   # red picks one for per-kid running style

# When build() is handed a CharacterDef, the model/clips/scale come from it
# instead of the hardcoded constants above. Null = legacy hardcoded path (the
# known-good fallback for every not-yet-migrated character). See CharacterDef.gd.
var _def: CharacterDef = null
var _has_run_variants := false
var _variant_keys: PackedStringArray = PackedStringArray(["run"])
# True when the active model has a jump clip (def.has_jump). Drives whether the
# rig builds + uses a jump animation state. False bodies keep their locomotion
# pose mid-air (old behavior), so jump is purely additive per-model.
var _has_jump := false
# True when the def ships sit-down + stand-up clips ("sit"/"sit_exit"). Drives an
# optional pair of bench states, purely additive per-model like jump — bodies
# without the clips keep the old rigid-stand sit.
var _has_sit := false
var _seated := false
# Optional throw (baseball_pitching clip): one-shot pitch state, per-model.
var _has_throw := false
var _throwing := false
var _airborne := false

# The Meshy model stands ~2.2 units tall in glTF space after the 0.01 armature
# scale; our actors are ~6 units. Scale up to match, and rotate so the model's
# forward aligns with Godot -Z (the model faces +Z by default).
@export var model_scale := 2.7
@export var facing_offset_deg := 0.0

var _anim: AnimationPlayer
var _tree: AnimationTree
var _state_machine: AnimationNodeStateMachinePlayback
var _blend_speed := 0.0
var _is_dead := false
var _team_tint := Color.WHITE
var _hand_attach: BoneAttachment3D = null   # carried items parent here (RightHand bone)
var _base_mat: StandardMaterial3D = null    # the team-tinted material (stored so highlight toggle can't corrupt it)
var _mesh_inst: MeshInstance3D = null       # cached mesh instance for material swaps

func build(team_color: Color, _role: String, team: String = "blue", use_girl: bool = false, def: CharacterDef = null, height_mult: float = 1.0) -> void:
	_team_tint = team_color
	_is_red = (team == "red")
	_def = def

	var base_scene: PackedScene
	var scale_mult: float = 1.0

	if _def != null:
		# --- DATA-DRIVEN PATH (CharacterDef) -------------------------------------
		# Everything the rig needs comes from the def; no team branching here.
		base_scene = load(_def.base_model_path)
		if base_scene == null:
			push_warning("CharacterRig: def '%s' base model failed to load (%s)" % [String(_def.id), _def.base_model_path])
			return
		_clip_sources = _def.clip_paths
		_src_name = _def.clip_anim_names
		_is_girl = false
		model_scale = _def.model_scale
		facing_offset_deg = _def.facing_offset_deg
		scale_mult = _def.scale_mult
		_has_run_variants = _def.has_run_variants
		_variant_keys = _def.run_variant_keys
		_has_jump = _def.has_jump and _def.clip_paths.has("jump")
		_has_sit = _def.clip_paths.has("sit") and _def.clip_paths.has("sit_exit")
		_has_throw = _def.clip_paths.has("throw")
		if _has_run_variants and _variant_keys.size() > 0:
			_run_variant = _variant_keys[randi() % _variant_keys.size()]
		else:
			_run_variant = "run"
	else:
		# --- LEGACY HARDCODED PATH (known-good fallback) -------------------------
		# choose the team's model + clip set. Red has two body types: the red boy
		# and the girl (every other red kid), which share rig + animation names.
		if _is_red and use_girl:
			base_scene = GIRL_BASE
			_clip_sources = GIRL_CLIPS
			_src_name = GIRL_NAMES
			_is_girl = true
		elif _is_red:
			base_scene = RED_BASE
			_clip_sources = RED_CLIPS
			_src_name = RED_NAMES
		else:
			base_scene = BLUE_BASE
			_clip_sources = BLUE_CLIPS
			_src_name = BLUE_NAMES
		# red kids each pick a running style for variety
		if _is_red:
			var variants := ["run", "run_fast", "run_03"]
			_run_variant = variants[randi() % variants.size()]
			_has_run_variants = true
		# red boy exports smaller; match the others
		if _is_red and not _is_girl:
			scale_mult = 1.12

	var inst := base_scene.instantiate()
	# height_mult gives each kid a slightly different stature (from their height_cm)
	# so the crowd reads as individual elementary kids, not clones. Clamped so it
	# stays in a believable kid range. The coach is a separate system (Coach.gd,
	# fixed adult scale) and is unaffected.
	var h := clampf(height_mult, 0.9, 1.1)
	inst.scale = Vector3(model_scale, model_scale, model_scale) * scale_mult * h
	inst.rotation.y = deg_to_rad(facing_offset_deg)
	add_child(inst)

	_anim = _find_anim_player(inst)
	if _anim == null:
		push_warning("CharacterRig: no AnimationPlayer in base model")
		return

	_harvest_clips()
	_apply_team_tint(inst, team_color)
	_build_tree(inst)
	_setup_hand_attachment(inst)

## Find the RightHand bone and attach a BoneAttachment3D so carried items can be
## parented to the actual animated hand instead of floating at a guessed offset.
func _setup_hand_attachment(root: Node) -> void:
	var skel := _find_skeleton(root)
	if skel == null:
		return
	var bone_idx := skel.find_bone("RightHand")
	if bone_idx < 0:
		return
	_hand_attach = BoneAttachment3D.new()
	_hand_attach.name = "HandAttachment"
	skel.add_child(_hand_attach)
	_hand_attach.bone_idx = bone_idx

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for c in node.get_children():
		var s := _find_skeleton(c)
		if s != null:
			return s
	return null

## The node carried items should parent to. Null until the rig is built.
func get_hand_attachment() -> Node3D:
	return _hand_attach


# --- find the AnimationPlayer the GLB import created --------------------------
func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null

# --- pull each clip from its source GLB into our one AnimationPlayer ----------
# Clips go into a dedicated library "rig" and are referenced as "rig/<key>".
func _harvest_clips() -> void:
	var lib := AnimationLibrary.new()
	for key in _clip_sources.keys():
		var src_scene: PackedScene = load(_clip_sources[key])
		if src_scene == null:
			continue
		var src_inst := src_scene.instantiate()
		var src_player := _find_anim_player(src_inst)
		if src_player != null:
			for lib_name in src_player.get_animation_library_list():
				var l := src_player.get_animation_library(lib_name)
				for anim_name in l.get_animation_list():
					if anim_name == _src_name[key]:
						var clip: Animation = l.get_animation(anim_name).duplicate()
						# all walk/run/idle variants loop; one-shot states play once
						var looping: bool = not (key == "dead" or key == "arise" or key == "jump" or key == "sit" or key == "sit_exit" or key == "throw")
						clip.loop_mode = Animation.LOOP_LINEAR if looping else Animation.LOOP_NONE
						# per-def leading trim: cut baked-in dead time (windups, long
						# static holds) so the visible motion syncs with the physics
						if _def != null and _def.clip_trims.has(key):
							_trim_leading(clip, float(_def.clip_trims[key]))
						# per-def end cut: drop dead tail (long follow-through holds)
						if _def != null and _def.clip_cuts.has(key):
							clip.length = minf(clip.length, float(_def.clip_cuts[key]))
						if lib.has_animation(key):
							lib.remove_animation(key)
						lib.add_animation(key, clip)
		src_inst.queue_free()
	if _anim.has_animation_library("rig"):
		_anim.remove_animation_library("rig")
	_anim.add_animation_library("rig", lib)

## Remove the first `trim` seconds of a clip: drop keys before the trim point and
## shift the rest back so the clip starts mid-motion. Order is preserved (constant
## shift), and with no key at t=0 Godot holds the first remaining key's value.
func _trim_leading(clip: Animation, trim: float) -> void:
	if trim <= 0.0:
		return
	for ti in range(clip.get_track_count()):
		while clip.track_get_key_count(ti) > 0 and clip.track_get_key_time(ti, 0) < trim:
			clip.track_remove_key(ti, 0)
		for ki in range(clip.track_get_key_count(ti)):
			clip.track_set_key_time(ti, ki, clip.track_get_key_time(ti, ki) - trim)
	clip.length = maxf(0.1, clip.length - trim)

# --- recolor the shirt so teams read apart (multiply tint over the texture) ---
func _apply_team_tint(root: Node, color: Color) -> void:
	# Teams read apart by model (red team uses the red boy) plus a light albedo
	# nudge toward the team color. No floating indicator meshes.
	var mesh_inst := _find_mesh(root)
	if mesh_inst == null:
		return
	_mesh_inst = mesh_inst
	var mat := mesh_inst.get_active_material(0)
	if mat is StandardMaterial3D:
		var m := (mat as StandardMaterial3D).duplicate()
		# tint biases the shirt/model toward the team color (stronger now that the
		# jersey band is gone), while keeping skin and texture detail readable
		m.albedo_color = Color(1, 1, 1).lerp(color, 0.35)
		_base_mat = m                        # remember the team-tinted material
		mesh_inst.set_surface_override_material(0, m)

## Highlight a kid who is carrying enemy loot — they are the highest-value tag
## target in the game, and the player needs to see them at a glance. A bright
## emission bump on the model material reads instantly without adding extra geo.
func set_carrier_highlight(on: bool) -> void:
	# Always start from the stored team-tinted material so toggling the glow can
	# never lose or corrupt the team color (the source of the random-tint bug).
	if _mesh_inst == null or _base_mat == null:
		return
	var m := _base_mat.duplicate()
	if on:
		m.emission_enabled = true
		m.emission = Color(1.0, 0.85, 0.2)   # warm gold "you have loot" glow
		m.emission_energy_multiplier = 0.7
	_mesh_inst.set_surface_override_material(0, m)

func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r != null:
			return r
	return null

# --- build an AnimationTree with a blend(walk,run) + dead/arise states --------
func _build_tree(_inst: Node) -> void:
	_tree = AnimationTree.new()
	add_child(_tree)
	# now that _tree is in the scene, it shares a common parent with _anim
	_tree.anim_player = _tree.get_path_to(_anim)
	# Root state machine
	var sm := AnimationNodeStateMachine.new()

	# locomotion = blendspace1d between walk and run
	var loco := AnimationNodeBlendSpace1D.new()
	loco.min_space = 0.0
	loco.max_space = 1.0
	var alert_node := AnimationNodeAnimation.new(); alert_node.animation = "rig/alert"
	var walk_node := AnimationNodeAnimation.new(); walk_node.animation = "rig/walk"
	var run_node := AnimationNodeAnimation.new()
	# characters with run variants (red/girl, or any def that sets has_run_variants)
	# use their per-kid picked style; everyone else uses the single "run" clip
	run_node.animation = "rig/" + _run_variant if _has_run_variants else "rig/run"
	loco.add_blend_point(alert_node, 0.0)
	loco.add_blend_point(walk_node, 0.5)
	loco.add_blend_point(run_node, 1.0)

	var dead_node := AnimationNodeAnimation.new(); dead_node.animation = "rig/dead"
	var arise_node := AnimationNodeAnimation.new(); arise_node.animation = "rig/arise"

	sm.add_node("locomotion", loco, Vector2(200, 100))
	sm.add_node("dead", dead_node, Vector2(400, 100))
	sm.add_node("arise", arise_node, Vector2(400, 250))

	# transitions
	var t_to_dead := AnimationNodeStateMachineTransition.new()
	t_to_dead.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
	sm.add_transition("locomotion", "dead", t_to_dead)

	var t_dead_arise := AnimationNodeStateMachineTransition.new()
	t_dead_arise.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
	sm.add_transition("dead", "arise", t_dead_arise)

	var t_arise_loco := AnimationNodeStateMachineTransition.new()
	t_arise_loco.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
	sm.add_transition("arise", "locomotion", t_arise_loco)

	# Optional JUMP state — only for models whose def has a jump clip (_has_jump).
	# Travel into it on takeoff and back to locomotion on landing, both driven by
	# set_airborne() from the Actor. Switch mode IMMEDIATE so the pose responds the
	# instant the actor leaves/returns to the ground.
	if _has_jump:
		var jump_node := AnimationNodeAnimation.new(); jump_node.animation = "rig/jump"
		sm.add_node("jump", jump_node, Vector2(200, 250))
		var t_loco_jump := AnimationNodeStateMachineTransition.new()
		t_loco_jump.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
		sm.add_transition("locomotion", "jump", t_loco_jump)
		var t_jump_loco := AnimationNodeStateMachineTransition.new()
		t_jump_loco.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
		sm.add_transition("jump", "locomotion", t_jump_loco)

	# Optional SIT states — sit-down (holds the final seated pose, like dead holds
	# the flop) and sit_exit (stand-up), only for defs shipping both clips.
	if _has_sit:
		var sit_node := AnimationNodeAnimation.new(); sit_node.animation = "rig/sit"
		sm.add_node("sit", sit_node, Vector2(360, 250))
		var stand_node := AnimationNodeAnimation.new(); stand_node.animation = "rig/sit_exit"
		sm.add_node("sit_exit", stand_node, Vector2(360, 330))
		var t_loco_sit := AnimationNodeStateMachineTransition.new()
		t_loco_sit.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
		sm.add_transition("locomotion", "sit", t_loco_sit)
		var t_sit_stand := AnimationNodeStateMachineTransition.new()
		t_sit_stand.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
		sm.add_transition("sit", "sit_exit", t_sit_stand)
		var t_stand_loco := AnimationNodeStateMachineTransition.new()
		t_stand_loco.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
		sm.add_transition("sit_exit", "locomotion", t_stand_loco)

	# Optional THROW state — a one-shot pitch that auto-returns to locomotion when
	# the (trimmed + cut) clip ends.
	if _has_throw:
		var throw_node := AnimationNodeAnimation.new(); throw_node.animation = "rig/throw"
		sm.add_node("throw", throw_node, Vector2(520, 250))
		var t_loco_throw := AnimationNodeStateMachineTransition.new()
		t_loco_throw.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
		sm.add_transition("locomotion", "throw", t_loco_throw)
		var t_throw_loco := AnimationNodeStateMachineTransition.new()
		t_throw_loco.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
		t_throw_loco.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
		sm.add_transition("throw", "locomotion", t_throw_loco)

	_tree.tree_root = sm
	# advance with the physics step and point the tree at the model root so its
	# clip tracks resolve against the same skeleton the base model uses
	_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	_tree.root_node = _tree.get_path_to(_anim.get_parent())
	_tree.active = true
	_state_machine = _tree.get("parameters/playback")
	if _state_machine != null:
		_state_machine.start("locomotion")

# ============================================================================
# PUBLIC API — called by Actor (presentation only)
# ============================================================================

## ratio 0..1: 0 = idle (alert), 0.5 = walk, 1 = sprint. Self-heals the state
## machine back into locomotion if it ever got stuck (the respawn-glide bug).
func set_locomotion(ratio: float, delta: float) -> void:
	if _tree == null or _is_dead or _state_machine == null:
		return
	# Don't yank the rig out of the jump state while airborne — set_airborne owns
	# that transition. (Without this guard, the per-frame self-heal below would
	# instantly cancel the jump pose.)
	if _has_jump and _airborne:
		return
	# Same for the sit states — play_sit/play_stand/end_sit own those transitions;
	# without this guard the self-heal would instantly cancel the seated pose.
	if _has_sit and _seated:
		return
	# play_throw owns the throw window; don't let the self-heal cancel the pitch
	if _has_throw and _throwing:
		return
	# if we're not in the locomotion state (e.g. arise didn't auto-advance), force it
	if _state_machine.get_current_node() != "locomotion":
		_state_machine.travel("locomotion")
	_blend_speed = lerpf(_blend_speed, clampf(ratio, 0.0, 1.0), clampf(delta * 8.0, 0.0, 1.0))
	_tree.set("parameters/locomotion/blend_position", _blend_speed)

## Airborne state from the Actor (true while off the floor). Plays the jump clip
## for models that have one; no-op for models without a jump clip. Dead bodies
## ignore it (they're flopping, not jumping).
func set_airborne(airborne: bool) -> void:
	if not _has_jump or _tree == null or _is_dead or _state_machine == null:
		return
	if airborne == _airborne:
		return
	_airborne = airborne
	if airborne:
		_state_machine.travel("jump")
	else:
		_state_machine.travel("locomotion")

func play_dead() -> void:
	if _tree == null or _is_dead or _state_machine == null:
		return
	_is_dead = true
	_airborne = false
	_seated = false
	_throwing = false
	_state_machine.travel("dead")

func play_arise() -> void:
	if _tree == null or _state_machine == null:
		return
	_is_dead = false
	_airborne = false
	_seated = false
	_throwing = false
	# go straight back to locomotion; the arise clip is brief and the immediate
	# transition avoids getting stuck if the actor starts moving right away
	_state_machine.travel("locomotion")

# --- bench sitting (optional per-model, needs "sit" + "sit_exit" clips) --------

func has_sit() -> bool:
	return _has_sit

## The def this rig was built from (or null for the legacy hardcoded path).
func get_def() -> CharacterDef:
	return _def

## Play the sit-down clip; it holds the final seated pose until play_stand.
func play_sit() -> void:
	if not _has_sit or _tree == null or _is_dead or _state_machine == null:
		return
	_seated = true
	_state_machine.travel("sit")

## Play the stand-up clip. _seated stays true (guarding the state machine) until
## the Actor's stand lock expires and calls end_sit().
func play_stand() -> void:
	if not _has_sit or _tree == null or _is_dead or _state_machine == null:
		_seated = false
		return
	_state_machine.travel("sit_exit")

## Release the sit guard; the next set_locomotion self-heals back to locomotion.
func end_sit() -> void:
	_seated = false

# --- throwing (optional per-model, needs a "throw" clip) ------------------------

func has_throw() -> bool:
	return _has_throw

## Play the one-shot pitch. Guards the state machine for the clip's (trimmed+cut)
## duration, then releases; the AT_END auto-transition returns to locomotion.
func play_throw() -> void:
	if not _has_throw or _tree == null or _is_dead or _state_machine == null:
		return
	if _seated:
		return   # can't pitch from a bench
	_throwing = true
	_state_machine.travel("throw")
	var dur := 1.2
	if _anim != null and _anim.has_animation("rig/throw"):
		dur = _anim.get_animation("rig/throw").length + 0.1
	get_tree().create_timer(dur).timeout.connect(func(): _throwing = false)

func face_heading(heading: float, delta: float) -> void:
	# smooth yaw toward heading (model child already has facing offset baked)
	rotation.y = lerp_angle(rotation.y, heading, clampf(delta * 10.0, 0.0, 1.0))

## Snap instantly to a heading (used at spawn so bots face midfield immediately
## instead of lerping from rotation 0 — which left them facing the trees during
## the frozen countdown).
func snap_heading(heading: float) -> void:
	rotation.y = heading

var _nametag: Label3D = null

## Floating billboarded nametag above the head, team-colored. Honors the setting.
func add_nametag(text: String, color: Color) -> void:
	_nametag = Label3D.new()
	_nametag.text = text
	_nametag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_nametag.modulate = color
	_nametag.outline_modulate = Color(0, 0, 0, 0.8)
	_nametag.outline_size = 8
	_nametag.font_size = 48
	_nametag.pixel_size = 0.02
	_nametag.position = Vector3(0, 16.0, 0)
	_nametag.no_depth_test = false
	_nametag.visible = Settings.show_nametags
	add_child(_nametag)
	Events.settings_applied.connect(_refresh_nametag)

func _refresh_nametag() -> void:
	if _nametag != null:
		_nametag.visible = Settings.show_nametags
