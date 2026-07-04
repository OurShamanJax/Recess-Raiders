class_name Juice
extends Node
## Game-feel layer (point 3 of the remaster). Pure presentation: listens to game
## events and adds screen shake + brief hit-pause so impacts read physically.
## Touches nothing in the simulation — if this node is removed the match is
## identical, just less punchy.

var _camera: Camera3D = null
var _shake_amount := 0.0
const SHAKE_DECAY_RATE := 6.0     # units of shake bled off per second (linear → hits 0 fast)
var _pause_until_msec := 0    # wall-clock deadline so time_scale can't stretch it

func setup(camera: Camera3D) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_camera = camera
	Events.ball_banked.connect(_on_bank)
	Events.actor_tagged.connect(_on_tag)
	Events.pass_caught.connect(_on_caught)
	Events.pass_intercepted.connect(_on_intercept)
	Events.match_won.connect(_on_won)

func _process(delta: float) -> void:
	# hit-pause: briefly slow time for impact weight, then restore. Uses the
	# wall clock (not delta) because delta is itself scaled by time_scale.
	if _pause_until_msec > 0 and Time.get_ticks_msec() >= _pause_until_msec:
		_pause_until_msec = 0
		Engine.time_scale = 1.0
	if _camera == null:
		return
	# screen shake: random jitter that decays LINEARLY to exactly zero. (The old
	# lerp toward zero was asymptotic — it never quite reached it, so the camera
	# jittered forever and cost a write every frame even while standing still.)
	if _shake_amount > 0.0:
		_shake_amount = maxf(0.0, _shake_amount - SHAKE_DECAY_RATE * delta)
		if _shake_amount <= 0.0:
			# fully settled — zero the offsets once and stop touching the camera
			_camera.h_offset = 0.0
			_camera.v_offset = 0.0
		else:
			_camera.h_offset = randf_range(-1.0, 1.0) * _shake_amount
			_camera.v_offset = randf_range(-1.0, 1.0) * _shake_amount

func shake(amount: float) -> void:
	_shake_amount = maxf(_shake_amount, amount)

func hit_pause(duration: float, time_scale: float = 0.05) -> void:
	Engine.time_scale = time_scale
	_pause_until_msec = Time.get_ticks_msec() + int(duration * 1000.0)

# --- event reactions --------------------------------------------------------
# Only react to events near the player/camera. Without this, 28 bots tagging each
# other across the field fire shake+hit_pause many times a second — which reads
# as constant jitter and stacks time_scale drops into real lag.
func _near_player(n: Node, radius: float) -> bool:
	if n == null or not is_instance_valid(n) or _camera == null:
		return false
	if not (n is Node3D):
		return false
	return (n as Node3D).global_position.distance_to(_camera.global_position) < radius

func _on_bank(_team: String) -> void:
	shake(0.3)
	hit_pause(0.07, 0.2)

func _on_tag(actor: Node) -> void:
	if _near_player(actor, 45.0):
		shake(0.18)

func _on_caught(actor: Node) -> void:
	if _near_player(actor, 45.0):
		shake(0.12)

func _on_intercept(actor: Node) -> void:
	if _near_player(actor, 45.0):
		shake(0.2)

func _on_won(_team: String) -> void:
	shake(0.45)
