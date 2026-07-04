extends Node3D
## Camera + movement basis. Two self-contained modes cycled with V:
##   "fp"    first person  — eye-level, mouse-look; move relative to look dir
##   "third" third person  — locked over the RIGHT shoulder; move relative to look dir
##
## The rig OWNS the movement basis. Each frame it publishes `move_forward` and
## `move_right` (flat, normalized, on the ground plane). PlayerController just
## reads those — so what you press always matches what you see, in every mode,
## with no per-mode sign hacks living in two files.

@export var fp_eye_height: float = Config.FP_EYE_HEIGHT
@export var fp_forward_offset: float = Config.FP_FORWARD_OFFSET
@export var fp_mouse_sens: float = Config.FP_MOUSE_SENS
@export var fp_pitch_clamp: float = Config.FP_PITCH_CLAMP

@export var third_back: float = Config.THIRD_BACK
@export var third_height: float = Config.THIRD_HEIGHT
@export var third_shoulder: float = Config.THIRD_SHOULDER

const MODES := ["fp", "third"]

var yaw: float = 0.0
var pitch: float = 0.0
var target: Node = null
var base_fov: float = 62.0

# zoom state
var third_zoomed := false            # right-mouse toggle: tight over-shoulder aim

# --- debug fly-cam (god mode) ---
# N detaches the camera to free-fly the map (player model hidden); N again snaps
# back to the saved fp/third view. WASD = move along look, Space/Ctrl = up/down,
# scroll = adjust fly speed.
var _debug_active := false
var _debug_saved_mode := "third"
var _debug_pos := Vector3.ZERO
var _debug_speed := 40.0
const _DEBUG_SPEED_MIN := 6.0
const _DEBUG_SPEED_MAX := 300.0
var _debug_fov := 62.0               # scroll-controlled zoom while flying
var _sprint_fx_amount := 0.0         # smoothed sprint FOV punch (0..1)
const _DEBUG_FOV_MIN := 18.0         # zoomed in (telephoto)
const _DEBUG_FOV_MAX := 95.0         # zoomed out (wide)

# Published movement basis (read by PlayerController). Flat, on ground plane.
var move_forward: Vector3 = Vector3(0, 0, -1)
var move_right: Vector3 = Vector3(1, 0, 0)
# Aim direction for throwing (includes pitch in FP).
var aim_dir: Vector3 = Vector3(0, 0, -1)

@onready var camera: Camera3D = $Camera3D

func _ready() -> void:
	# This camera is moved every RENDER frame (_process smoothing), not in physics
	# ticks, so exempt it from physics interpolation — otherwise Godot warns
	# "Interpolated Camera3D triggered from outside physics process" on every
	# teleport (mode switches, resets). It's already per-frame smooth.
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

func set_target(t: Node) -> void:
	target = t
	base_fov = camera.fov
	if target != null:
		yaw = target.heading
	_capture_mouse(_is_mouse_look())

func _is_mouse_look() -> bool:
	# orbit is the menu/skycam background — never capture the mouse there, or the
	# menu cursor vanishes and you can't click anything.
	if GameState.cam_mode == "orbit":
		return false
	return GameState.cam_mode == "fp" or GameState.cam_mode == "third"

func _input(event: InputEvent) -> void:
	# debug fly-cam toggle (N) — only while actually playing, never in the menu
	# skycam (orbit), where it would hijack the background feed
	if event.is_action_pressed("toggle_debug_cam") and GameState.phase == GameState.Phase.PLAYING and GameState.cam_mode != "orbit":
		_toggle_debug_cam()
		return

	# mouse-look: active in fp/third AND in debug fly mode
	var look_active := _is_mouse_look() or _debug_active
	if look_active and event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sens := fp_mouse_sens * Settings.mouse_sensitivity
		yaw -= event.relative.x * sens
		pitch = clampf(pitch - event.relative.y * sens, -fp_pitch_clamp, fp_pitch_clamp)

	# debug fly speed: scroll now controls FOV/zoom (below); speed is fixed but
	# boosted by sprint. Scroll DOWN zooms in (narrower FOV), UP zooms out.
	if _debug_active and event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_debug_fov = clampf(_debug_fov + 4.0, _DEBUG_FOV_MIN, _DEBUG_FOV_MAX)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_debug_fov = clampf(_debug_fov - 4.0, _DEBUG_FOV_MIN, _DEBUG_FOV_MAX)
		return

	if event.is_action_pressed("toggle_cam") and GameState.phase == GameState.Phase.PLAYING and not _debug_active:
		cycle_mode()
	# third-person: right mouse button toggles a tight over-shoulder zoom
	if GameState.cam_mode == "third" and not _debug_active and event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			third_zoomed = not third_zoomed

func cycle_mode() -> void:
	var i := MODES.find(GameState.cam_mode)
	GameState.cam_mode = MODES[(i + 1) % MODES.size()]
	if _is_mouse_look() and target != null:
		# keep facing continuous when switching into a mouse-look mode
		yaw = target.heading
		pitch = 0.0
	_capture_mouse(_is_mouse_look())

## Toggle the debug fly-cam (god mode). Detaches the camera to free-fly, hides
## the player model, and captures the mouse for looking. Pressing again restores
## the previous fp/third view and re-shows the model.
func _toggle_debug_cam() -> void:
	_debug_active = not _debug_active
	GameState.debug_mode = _debug_active
	if _debug_active:
		_debug_saved_mode = GameState.cam_mode
		_debug_pos = camera.global_position
		_debug_fov = camera.fov
		_set_player_model_visible(false)
		_freeze_player(true)        # lock the player in place while we fly
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		# snap back to where the real camera belongs (fp/third updates next frame)
		GameState.cam_mode = _debug_saved_mode
		camera.fov = base_fov
		_set_player_model_visible(true)
		_freeze_player(false)       # hand control back; player is right where it was
		if target != null:
			yaw = target.heading
			pitch = 0.0
		_capture_mouse(_is_mouse_look())

## Freeze (or unfreeze) the player so it stays exactly where it was while the
## debug fly-cam is active — no gravity, no drift, no input. On unfreeze the
## player resumes from the identical position it held when debug was entered.
func _freeze_player(frozen: bool) -> void:
	if target == null or not is_instance_valid(target):
		return
	target.set_physics_process(not frozen)
	if "velocity" in target:
		target.velocity = Vector3.ZERO

func _set_player_model_visible(v: bool) -> void:
	if target != null and is_instance_valid(target) and "rig" in target and target.rig != null:
		target.rig.visible = v

## Free-fly update: move along the look direction with WASD, Space/Ctrl for
## vertical, at a scroll-adjustable speed. Independent of the player entirely.
func _update_debug(delta: float) -> void:
	var look := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)).normalized()
	var flat_fwd := Vector3(sin(yaw), 0.0, cos(yaw)).normalized()
	var right := Vector3(-flat_fwd.z, 0.0, flat_fwd.x)
	var move := Vector3.ZERO
	if Input.is_action_pressed("move_forward"): move += flat_fwd
	if Input.is_action_pressed("move_back"):    move -= flat_fwd
	if Input.is_action_pressed("move_right"):   move += right
	if Input.is_action_pressed("move_left"):    move -= right
	if Input.is_key_pressed(KEY_SPACE):         move += Vector3.UP
	if Input.is_key_pressed(KEY_CTRL):          move += Vector3.DOWN
	# sprint key gives a temporary boost
	var spd := _debug_speed * (2.5 if Input.is_action_pressed("sprint") else 1.0)
	if move.length() > 0.0:
		_debug_pos += move.normalized() * spd * delta
	camera.fov = _debug_fov
	camera.global_position = _debug_pos
	camera.look_at(_debug_pos + look, Vector3.UP)

func _capture_mouse(on: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE

func _process(delta: float) -> void:
	# debug fly-cam takes over completely when active (god mode free-fly)
	if _debug_active:
		_update_debug(delta)
		return
	# the orbit/skycam menu view doesn't need a target — it circles the field
	# center regardless of any player. Handle it before the target null-guard.
	if GameState.cam_mode == "orbit":
		_update_orbit(delta)
		return
	if target == null:
		return
	var p: Vector3 = target.global_position
	_update_fov(delta)
	match GameState.cam_mode:
		"fp":     _update_fp(p)
		_:        _update_third(p, delta)

# --- ORBIT / SKYCAM (menu background) ----------------------------------------
# Slowly circles the field center at a high football-skycam angle, always
# looking at the middle. Used as the live menu background — never cycled to by V.
var _orbit_angle: float = 0.0
func _update_orbit(delta: float) -> void:
	_orbit_angle += delta * 0.12   # slow, cinematic sweep
	var radius: float = 150.0
	var height: float = 95.0
	var center := Vector3(0, 0, 0)
	var want := center + Vector3(cos(_orbit_angle) * radius, height, sin(_orbit_angle) * radius)
	camera.global_position = want
	camera.look_at(center, Vector3.UP)

# --- FIRST PERSON ------------------------------------------------------------
# Eye just in front of the face. Move basis = camera yaw (flattened). Aim = look.
func _update_fp(p: Vector3) -> void:
	var look := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	var flat_fwd := Vector3(sin(yaw), 0.0, cos(yaw)).normalized()
	# eye height is relative to the player's CURRENT Y so the camera rises/falls
	# with jumps and crouches instead of staying locked at ground level
	var eye := Vector3(p.x, p.y + fp_eye_height, p.z) + flat_fwd * fp_forward_offset
	camera.global_position = eye
	camera.look_at(eye + look, Vector3.UP)
	move_forward = flat_fwd
	move_right = Vector3(-flat_fwd.z, 0.0, flat_fwd.x)   # forward × up (true right)
	aim_dir = look

# --- THIRD PERSON ------------------------------------------------------------
# Locked over the RIGHT shoulder, behind the player along yaw. Move basis = yaw.
func _update_third(p: Vector3, delta: float) -> void:
	var flat_fwd := Vector3(sin(yaw), 0.0, cos(yaw)).normalized()
	var right := Vector3(-flat_fwd.z, 0.0, flat_fwd.x)   # forward × up (true right)
	# head is relative to the player's CURRENT Y so the camera rises and falls
	# with them on terrain (was using an absolute height, so walking uphill made
	# the camera sink and eventually clip through the ground)
	var head := Vector3(p.x, p.y + fp_eye_height, p.z)
	# zoomed = tighter over-shoulder aim view; normal = a bit further back
	var back: float = third_back * (0.55 if third_zoomed else 1.0)
	var hgt: float = third_height * (0.7 if third_zoomed else 1.0)
	var shoulder: float = third_shoulder * (1.2 if third_zoomed else 1.0)
	var want := head - flat_fwd * back + Vector3(0, hgt, 0) + right * shoulder
	var t := 1.0 - pow(0.0001, delta)        # snappy but smooth, frame-rate independent
	camera.global_position = camera.global_position.lerp(want, t)
	# look at a point ahead of the player at chest height, biased by pitch
	var focus := head + flat_fwd * 14.0 + Vector3(0, pitch * 10.0, 0) + right * (shoulder * 0.5)
	camera.look_at(focus, Vector3.UP)
	move_forward = flat_fwd
	move_right = right
	aim_dir = flat_fwd

func _update_fov(delta: float) -> void:
	# pick the FOV for the current camera mode (separate FP / third-person)
	var mode_fov := base_fov
	if GameState.cam_mode == "fp" and "fov_first_person" in Settings:
		mode_fov = Settings.fov_first_person
	elif GameState.cam_mode == "third" and "fov_third_person" in Settings:
		mode_fov = Settings.fov_third_person
	# smooth the sprint state so momentary drops (stamina dips, a frame of not
	# moving) don't make the FOV punch flicker in and out jarringly
	var sprinting := false
	if Settings.sprint_fx and target != null and is_instance_valid(target):
		if target.has_method("is_sprinting"):
			sprinting = target.is_sprinting()
	_sprint_fx_amount = move_toward(_sprint_fx_amount, 1.0 if sprinting else 0.0, delta * 4.0)
	var want_fov: float = mode_fov + Config.SPRINT_FOV_BONUS * _sprint_fx_amount
	camera.fov = lerpf(camera.fov, want_fov, clampf(delta * 6.0, 0, 1))
