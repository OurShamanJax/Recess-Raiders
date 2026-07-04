class_name PlayerController
extends BaseController
## Human input -> Intent. Movement is ALWAYS camera-relative: the CameraRig
## publishes move_forward / move_right (flat ground vectors) for whatever mode
## is active, and we just combine them with WASD. This means W is always "the way
## the camera faces / up the field", and A/D always strafe correctly — no per-mode
## sign flips. Left-click throws when carrying a ball, else interacts; E interacts.

var camera_rig: Node = null
var _throw_queued := false
var _pass_queued := false
var _interact_queued := false
var _tag_queued := false
var _revive_queued := false

func _unhandled_input(event: InputEvent) -> void:
	if GameState.phase != GameState.Phase.PLAYING:
		return
	if event.is_action_pressed("throw_ball"):
		# left-click: throw if carrying; else tag an enemy in front; else grab
		if actor != null and actor.has_ball():
			_throw_queued = true
		elif actor != null and actor.best_tag_target() != null:
			_tag_queued = true
		elif actor != null and actor.best_revive_target() != null:
			_revive_queued = true
		else:
			_interact_queued = true
	if event.is_action_pressed("pass_ball"):
		_pass_queued = true
	if event.is_action_pressed("interact"):
		# E: tag an enemy if one's in reach, otherwise grab a looked-at item
		if actor != null and actor.best_tag_target() != null:
			_tag_queued = true
		else:
			_interact_queued = true
	if event.is_action_pressed("revive"):
		_revive_queued = true
	if event.is_action_pressed("cycle_lock"):
		if actor != null:
			actor.cycle_lock_target()

func build_intent(_delta: float) -> Intent:
	intent.clear()
	# while carrying a ball, keep a valid locked pass target for the reticle
	if actor != null and actor.has_ball():
		actor.ensure_lock_target()
	elif actor != null:
		actor.lock_target = null

	# Movement basis comes straight from the camera for the current mode.
	var fwd := Vector3(0, 0, -1)
	var right := Vector3(1, 0, 0)
	if camera_rig != null:
		fwd = camera_rig.move_forward
		right = camera_rig.move_right
		intent.aim = camera_rig.aim_dir

	var m := Vector3.ZERO
	if Input.is_action_pressed("move_forward"): m += fwd
	if Input.is_action_pressed("move_back"):    m -= fwd
	if Input.is_action_pressed("move_right"):   m += right
	if Input.is_action_pressed("move_left"):    m -= right
	if m.length_squared() > 0.0:
		m = m.normalized()
		intent.move = m

	intent.sprint = Input.is_action_pressed("sprint")
	intent.crouch = Input.is_action_pressed("crouch")
	intent.want_jump = Input.is_action_just_pressed("jump")
	intent.want_throw = _throw_queued
	intent.want_pass = _pass_queued
	intent.want_interact = _interact_queued
	intent.want_tag = _tag_queued
	intent.want_revive = _revive_queued
	_throw_queued = false
	_pass_queued = false
	_interact_queued = false
	_tag_queued = false
	_revive_queued = false
	return intent
