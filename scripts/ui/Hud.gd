extends Control
## HUD: a scoreboard (top-left) showing each side's score — points scored by
## banking the enemy's stolen targets — plus the human's stamina bar and a
## win/lose screen with a restart button. Reads state only.

var player_actor: Node = null
var match_ref: Node = null          # set by Main so the restart button can reset
var camera: Camera3D = null         # for projecting 3D lock/landing points to screen
var _crosshair: Control = null
var _prompt: Label = null
var _lock_reticle: Control = null   # ring over the locked pass target
var _arc: Line2D = null             # throw arc preview / in-flight tracking line
var _throw_flash: Label = null      # "Caught!" / "Intercepted!" / "Dropped!"
var _flash_timer := 0.0
var _hidden_for_debug := false      # HUD hidden by the debug fly-cam (only restore what we hid)
var _qte_panel: Control = null      # player catch quick-time bar
var _qte_active := false
var _qte_time := 0.0
var _qte_ball: Node = null
# Catch QTE has two modes, chosen at random each time:
#   "timing" — the classic sweeping-cursor bar; press catch_qte (E) in the window.
#   "key"    — press a specific shown keyboard key within the time limit. The key
#              is picked from QTE_KEY_POOL (keys bound to nothing else), and never
#              repeats twice in a row (_qte_last_key).
var _qte_mode := "timing"
var _qte_key: int = KEY_F            # the key to press in "key" mode (int keycode)
var _qte_last_key: int = KEY_NONE    # so the key never repeats back-to-back
# Candidate keys for the key-press QTE: every letter and digit. The picker
# filters this against the LIVE InputMap each pick, so whatever the player has
# bound (defaults OR rebinds) is excluded automatically — rebinding updates the
# effective pool instantly, and the candidate space is big enough that it never
# runs dry.
var QTE_KEY_POOL: Array = _build_qte_candidates()

static func _build_qte_candidates() -> Array:
	var out: Array = []
	for k in range(KEY_A, KEY_Z + 1):
		out.append(k)
	for k in range(KEY_0, KEY_9 + 1):
		out.append(k)
	return out
var _countdown: Label = null
# Throw QTE: mirror of the catch timing bar, but for RELEASING a throw. Reuses the
# same _qte_panel in timing mode. _throw_qte_actor is who to call back on resolve.
var _throw_qte := false
var _throw_qte_actor: Node = null
var _respawn_label: Label = null    # "tagged out — respawn in Ns" timer
var _safe_label: Label = null       # live safe-zone countdown while resting
var _controls_panel: Panel = null   # "how to play" hint shown at match start
var _clock: Label = null
var _lb: PanelContainer = null      # Tab leaderboard popup
var _lb_body: HBoxContainer = null
var _lb_refresh := 0.0            # match clock under the scoreboard (MM:SS / OVERTIME)

func _ready() -> void:
	add_to_group("hud")
	Events.match_won.connect(_on_match_won)
	# match clock, tucked under the score rows
	_clock = Label.new()
	_clock.add_theme_font_size_override("font_size", 18)
	_clock.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0))
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	$Scoreboard/Rows.add_child(_clock)
	Events.ball_banked.connect(func(_t): _refresh_scoreboard())
	Events.ball_state_changed.connect(func(_b): _refresh_scoreboard())
	Events.match_restart.connect(_on_restarted)
	$Scoreboard.visible = false
	$StaminaWrap.visible = false
	$Carry.visible = false
	$EndScreen.visible = false
	_build_crosshair_and_prompt()
	_build_throw_feedback()
	Events.pass_thrown.connect(_on_pass_thrown)
	Events.countdown_tick.connect(_on_countdown_tick)
	Events.match_started.connect(_on_match_started_controls)

## Show a brief controls reference at the start of a Raiders match so new players
## know how to play. Fades out a few seconds after the match begins.
func _on_match_started_controls(_team: String, _cam: String) -> void:
	if GameState.mode != "raiders":
		return
	# the live menu-background (orbit) match has no human player — no controls hint
	if GameState.cam_mode == "orbit" or player_actor == null:
		return
	if _controls_panel != null and is_instance_valid(_controls_panel):
		_controls_panel.queue_free()
	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	panel.position = Vector2(-320, -150)
	panel.custom_minimum_size = Vector2(300, 300)
	panel.size = Vector2(300, 300)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.10, 0.16, 0.82)
	sb.set_corner_radius_all(12)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.4, 0.6, 0.9, 0.7)
	sb.content_margin_left = 18
	sb.content_margin_top = 14
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)
	_controls_panel = panel

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "HOW TO PLAY"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	vb.add_child(title)
	var lines := [
		"WASD  —  Move",
		"Shift  —  Sprint",
		"Space  —  Jump",
		"Left Click  —  Throw",
		"Right Click  —  Pass (lock target)",
		"E  —  Tag enemy / grab",
		"R  —  Revive a teammate",
		"V  —  Camera   ·   Tab  —  Pause",
		"",
		"Steal their stuff, bank it at home!",
	]
	for t in lines:
		var l := Label.new()
		l.text = t
		l.add_theme_font_size_override("font_size", 15)
		l.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
		vb.add_child(l)

	# fade out a few seconds into play
	var tw := create_tween()
	tw.tween_interval(6.0)
	tw.tween_property(panel, "modulate:a", 0.0, 1.5)
	tw.tween_callback(panel.queue_free)

func _on_countdown_tick(n: int) -> void:
	if _countdown == null:
		_countdown = Label.new()
		_countdown.set_anchors_preset(Control.PRESET_CENTER)
		_countdown.position = Vector2(-150, -120)
		_countdown.custom_minimum_size = Vector2(300, 0)
		_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_countdown.add_theme_font_size_override("font_size", 72)
		_countdown.add_theme_color_override("font_color", Color(1, 1, 1))
		_countdown.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		_countdown.add_theme_constant_override("outline_size", 8)
		_countdown.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_countdown)
	_countdown.text = "RAID!" if n == 0 else str(n)
	_countdown.visible = true
	_countdown.modulate = Color(1, 1, 1, 1)
	var tw := create_tween()
	tw.tween_property(_countdown, "modulate:a", 0.0, 0.7)

func _input(event: InputEvent) -> void:
	if not _qte_active:
		return
	if _qte_mode == "key":
		# KEY MODE: only the exact demanded key counts as a hit. Any other key in
		# the pool (or a wrong press) is a miss, so you can't just mash.
		if event is InputEventKey and event.pressed and not event.echo:
			var kc: int = (event as InputEventKey).physical_keycode
			if kc == _qte_key:
				_resolve_qte(true, true)   # correct key = clean (perfect) catch
			elif kc in QTE_KEY_POOL:
				_resolve_qte(false)        # pressed a wrong pool key = fumble
	else:
		# TIMING MODE. For a THROW QTE, the release press is the throw/pass button
		# (mouse) — "time the mouse press" — or the catch key as a fallback. For a
		# CATCH QTE it's the catch action.
		if _throw_qte:
			if event.is_action_pressed("throw_ball") or event.is_action_pressed("pass_ball") \
					or event.is_action_pressed("catch_qte"):
				qte_press()
		elif event.is_action_pressed("catch_qte"):
			qte_press()

func _build_throw_feedback() -> void:
	# ring that sits over the locked pass target
	_lock_reticle = Control.new()
	_lock_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lock_reticle.visible = false
	add_child(_lock_reticle)
	var ring := ColorRect.new()
	ring.color = Color(0.3, 1.0, 0.5, 0.0)
	ring.size = Vector2(54, 54)
	ring.position = Vector2(-27, -27)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# draw a ring via a thin border using a StyleBox on a Panel instead
	var ringp := Panel.new()
	var rs := StyleBoxFlat.new()
	rs.bg_color = Color(0, 0, 0, 0)
	rs.border_color = Color(0.3, 1.0, 0.5, 0.9)
	rs.set_border_width_all(3)
	rs.set_corner_radius_all(27)
	ringp.add_theme_stylebox_override("panel", rs)
	ringp.size = Vector2(54, 54)
	ringp.position = Vector2(-27, -27)
	ringp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lock_reticle.add_child(ringp)

	# throw arc line — a Line2D we feed projected 3D arc points into each frame
	_arc = Line2D.new()
	_arc.width = 4.0
	_arc.default_color = Color(0.35, 1.0, 0.55, 0.85)
	_arc.joint_mode = Line2D.LINE_JOINT_ROUND
	_arc.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_arc.end_cap_mode = Line2D.LINE_CAP_ROUND
	_arc.visible = false
	add_child(_arc)

	# result flash (center, large)
	_throw_flash = Label.new()
	_throw_flash.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_throw_flash.position = Vector2(-150, 70)
	_throw_flash.custom_minimum_size = Vector2(300, 0)
	_throw_flash.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_throw_flash.add_theme_font_size_override("font_size", 34)
	_throw_flash.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_throw_flash.add_theme_constant_override("outline_size", 6)
	_throw_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_throw_flash.visible = false
	add_child(_throw_flash)

	# QTE catch bar (appears when the player is the receiver) — a clean, larger
	# timing meter with a glowing target window and a sharp cursor.
	_qte_panel = Control.new()
	_qte_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_qte_panel.position = Vector2(-150, -170)
	_qte_panel.visible = false
	add_child(_qte_panel)

	var qbg := Panel.new()
	qbg.size = Vector2(300, 78)
	var qs := StyleBoxFlat.new()
	qs.bg_color = Color(0.06, 0.07, 0.10, 0.82)
	qs.set_corner_radius_all(14)
	qs.set_border_width_all(2)
	qs.border_color = Color(1, 1, 1, 0.12)
	qs.shadow_color = Color(0, 0, 0, 0.4)
	qs.shadow_size = 8
	qbg.add_theme_stylebox_override("panel", qs)
	_qte_panel.add_child(qbg)

	var qlabel := Label.new()
	qlabel.name = "QLabel"
	qlabel.position = Vector2(0, 10)
	qlabel.size = Vector2(300, 22)
	qlabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qlabel.text = "CATCH"
	qlabel.add_theme_font_size_override("font_size", 18)
	qlabel.add_theme_color_override("font_color", Color(1, 1, 1))
	qlabel.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	qlabel.add_theme_constant_override("outline_size", 4)
	_qte_panel.add_child(qlabel)

	# the track (rounded, inset)
	var qbar_bg := Panel.new()
	qbar_bg.name = "BarBg"
	qbar_bg.position = Vector2(40, 42)
	qbar_bg.size = Vector2(220, 18)
	var tbs := StyleBoxFlat.new()
	tbs.bg_color = Color(0.16, 0.17, 0.22, 1.0)
	tbs.set_corner_radius_all(9)
	qbar_bg.add_theme_stylebox_override("panel", tbs)
	_qte_panel.add_child(qbar_bg)

	# the target window (good zone) — keep name "Window" + geometry contract
	var qwin := ColorRect.new()
	qwin.name = "Window"
	qwin.color = Color(0.3, 0.9, 0.45, 0.85)
	qwin.position = Vector2(150, 42)
	qwin.size = Vector2(48, 18)
	_qte_panel.add_child(qwin)

	# the PERFECT sweet-spot in the center of the window (brighter sliver)
	var qperfect := ColorRect.new()
	qperfect.name = "Perfect"
	qperfect.color = Color(1.0, 0.95, 0.5, 0.95)
	qperfect.position = Vector2(168, 42)
	qperfect.size = Vector2(12, 18)
	_qte_panel.add_child(qperfect)

	# the cursor — a sharp bright bar that sweeps across
	var qcursor := ColorRect.new()
	qcursor.name = "Cursor"
	qcursor.color = Color(1, 1, 1, 1)
	qcursor.position = Vector2(40, 38)
	qcursor.size = Vector2(4, 26)
	_qte_panel.add_child(qcursor)

	# KEY-MODE prompt: a big boxed letter shown instead of the timing bar when the
	# QTE is in "key" mode. Hidden by default; _start_qte toggles bar vs. key.
	var qkey := Label.new()
	qkey.name = "KeyPrompt"
	qkey.position = Vector2(0, 34)
	qkey.size = Vector2(300, 34)
	qkey.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qkey.text = "[ F ]"
	qkey.add_theme_font_size_override("font_size", 28)
	qkey.add_theme_color_override("font_color", Color(1.0, 0.95, 0.5))
	qkey.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	qkey.add_theme_constant_override("outline_size", 5)
	qkey.visible = false
	_qte_panel.add_child(qkey)

## A center-screen crosshair dot plus an action prompt ("Press E to tag" /
## "Press R to revive") that appears when an enemy or downed teammate is in reach.
func _build_crosshair_and_prompt() -> void:
	_crosshair = Control.new()
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_crosshair)
	var dot := ColorRect.new()
	dot.color = Color(1, 1, 1, 0.7)
	dot.size = Vector2(6, 6)
	dot.position = Vector2(-3, -3)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crosshair.add_child(dot)

	_prompt = Label.new()
	_prompt.set_anchors_preset(Control.PRESET_CENTER)
	_prompt.position = Vector2(-80, 28)
	_prompt.custom_minimum_size = Vector2(160, 0)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_color_override("font_color", Color(1, 1, 1))
	_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_prompt.add_theme_constant_override("outline_size", 4)
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt.visible = false
	add_child(_prompt)

func bind(a: Node, m: Node, cam: Camera3D = null) -> void:
	player_actor = a
	match_ref = m
	camera = cam
	$Scoreboard.visible = true
	$StaminaWrap.visible = true
	_refresh_scoreboard()
	# wire end-screen buttons once: Main Menu (back to title, no welcome audio
	# replay) and Quit (exit the program)
	if not $EndScreen/Panel/VBox/Restart.pressed.is_connected(_on_main_menu_pressed):
		var btn := $EndScreen/Panel/VBox/Restart
		btn.text = "MAIN MENU"
		btn.pressed.connect(_on_main_menu_pressed)
		# add a Quit button beneath it if not already present
		if not $EndScreen/Panel/VBox.has_node("QuitBtn"):
			var quit_btn := Button.new()
			quit_btn.name = "QuitBtn"
			quit_btn.text = "QUIT"
			quit_btn.custom_minimum_size = Vector2(200, 56)
			quit_btn.add_theme_font_size_override("font_size", 22)
			$EndScreen/Panel/VBox.add_child(quit_btn)
			quit_btn.pressed.connect(_on_quit_pressed)

func _refresh_scoreboard() -> void:
	var blue_score: int = GameState.score_for("blue")
	var red_score: int = GameState.score_for("red")
	$Scoreboard/Rows/BlueRow/BlueScore.text = str(blue_score)
	$Scoreboard/Rows/RedRow/RedScore.text = str(red_score)
	# mark which side the player is on
	$Scoreboard/Rows/BlueRow/BlueName.text = "BLUE" + ("  (you)" if GameState.user_team == "blue" else "")
	$Scoreboard/Rows/RedRow/RedName.text = "RED" + ("  (you)" if GameState.user_team == "red" else "")

func _process(delta: float) -> void:
	# debug fly-cam (god mode): hide all HUD elements; restore when it ends.
	# IMPORTANT: only restore what WE hid (_hidden_for_debug) — the old
	# `elif not visible: visible = true` re-showed the HUD every frame, fighting
	# every other system that hides it (menu backdrop, pause, post-match return)
	# and leaking "Pass!" flashes onto the menu skycam.
	if GameState.debug_mode:
		if visible:
			visible = false
			_hidden_for_debug = true
		return
	elif _hidden_for_debug:
		_hidden_for_debug = false
		visible = true
	# Tab leaderboard: toggle + periodic refresh while open
	if Input.is_action_just_pressed("show_scoreboard") and GameState.phase == GameState.Phase.PLAYING and not GameState.debug_mode:
		_toggle_leaderboard()
	if _lb != null and _lb.visible:
		_lb_refresh -= delta
		if _lb_refresh <= 0.0:
			_lb_refresh = 0.5
			_fill_leaderboard()
	if _clock != null:
		if GameState.overtime:
			_clock.text = "OVERTIME"
			_clock.add_theme_color_override("font_color", Color(1.0, 0.55, 0.25))
		else:
			var s: int = int(ceil(GameState.match_time_left))
			@warning_ignore("integer_division")
			_clock.text = "%d:%02d" % [s / 60, s % 60]
	if player_actor != null and is_instance_valid(player_actor):
		$StaminaWrap/Bar.value = player_actor.stamina
		$Carry.visible = player_actor.has_target()
		_update_action_prompt()
		_update_lock_reticle()
		_update_respawn_timer()
		_update_safe_timer()
		_update_arc()
	_update_throw_flash(delta)
	_update_qte(delta)



## Draw the throw arc line. Two cases:
##  1. aiming — player holds a ball and has a lock target → preview arc to them
##  2. in flight — a homing ball is airborne → track the line to its LIVE target
## In both cases the line bends as the target moves, since we sample the target's
## current position each frame.
func _update_arc() -> void:
	if _arc == null or camera == null or player_actor == null or not is_instance_valid(player_actor):
		return
	var from_w: Vector3 = Vector3.ZERO
	var to_w: Vector3 = Vector3.ZERO
	var _arc_visible := false

	# case 2 first: a homing ball in flight that the PLAYER is throwing or
	# catching. We only draw arcs for player-involved passes — not every NPC↔NPC
	# throw across the field.
	var homing_ball: Node = _find_player_homing_ball()
	if homing_ball != null:
		from_w = homing_ball.global_position
		to_w = homing_ball.homing_target()
		_arc_visible = true
	elif player_actor.has_ball() and player_actor.lock_target != null \
			and is_instance_valid(player_actor.lock_target) \
			and not player_actor.lock_target.is_tagged():
		# case 1: preview from the player to the locked teammate
		from_w = player_actor.global_position + Vector3(0, 5.0, 0)
		var lt: Vector3 = player_actor.lock_target.global_position
		to_w = Vector3(lt.x, 5.0, lt.z)
		_arc_visible = true

	if not _arc_visible:
		_arc.visible = false
		return

	# sample a parabola between from and to, project each point to screen. If a
	# point is behind the camera we SKIP it rather than abandoning the whole arc,
	# so the line still shows when part of it is off-screen.
	var pts := PackedVector2Array()
	var span: float = from_w.distance_to(to_w)
	var peak: float = clampf(span * 0.32, 2.0, 16.0)
	var samples := 14
	for i in range(samples + 1):
		var t: float = float(i) / float(samples)
		var flat: Vector3 = from_w.lerp(to_w, t)
		var lift: float = 4.0 * peak * t * (1.0 - t)
		var wp: Vector3 = Vector3(flat.x, flat.y + lift, flat.z)
		if not camera.is_position_behind(wp):
			pts.append(camera.unproject_position(wp))
	if pts.size() >= 2:
		_arc.points = pts
		_arc.visible = true
	else:
		_arc.visible = false

## Find a homing ball in flight that the PLAYER is throwing or catching.
func _find_player_homing_ball() -> Node:
	for b in get_tree().get_nodes_in_group("balls"):
		if not (b.has_method("is_homing") and b.is_homing()):
			continue
		# only player-involved: player is the thrower OR the intended catcher
		if b.thrower == player_actor or b.intended_catcher == player_actor:
			return b
	return null

## Show a respawn countdown when the player is tagged out. Appears on tag,
## counts down, and vanishes the instant they're revived (by a teammate) or
## auto-respawn returns them — driven purely by the live tagged state.
func _update_respawn_timer() -> void:
	var tagged: bool = player_actor.is_tagged()
	if tagged:
		if _respawn_label == null:
			_respawn_label = Label.new()
			_respawn_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
			_respawn_label.position = Vector2(-200, 120)
			_respawn_label.custom_minimum_size = Vector2(400, 0)
			_respawn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_respawn_label.add_theme_font_size_override("font_size", 30)
			_respawn_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.4))
			_respawn_label.add_theme_color_override("font_outline_color", Color(0.1, 0.05, 0.05))
			_respawn_label.add_theme_constant_override("outline_size", 6)
			add_child(_respawn_label)
		var secs: int = int(ceil(player_actor.respawn_seconds_left()))
		_respawn_label.text = "TAGGED OUT\nRespawn in %d  (or wait for a teammate)" % secs
		_respawn_label.visible = true
	elif _respawn_label != null:
		_respawn_label.visible = false

## Live safe-zone countdown — appears only while the player rests inside a safe
## zone, showing the seconds left before they're pushed back out onto the field.
func _update_safe_timer() -> void:
	if player_actor == null or not is_instance_valid(player_actor):
		return
	var in_zone: bool = player_actor.in_own_pod() and player_actor.safe_seconds_left() > 0.0
	if in_zone:
		if _safe_label == null:
			_safe_label = Label.new()
			_safe_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
			_safe_label.position = Vector2(-200, 110)
			_safe_label.custom_minimum_size = Vector2(400, 0)
			_safe_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_safe_label.add_theme_font_size_override("font_size", 22)
			_safe_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.7))
			_safe_label.add_theme_color_override("font_outline_color", Color(0.05, 0.12, 0.08))
			_safe_label.add_theme_constant_override("outline_size", 5)
			add_child(_safe_label)
		var secs: int = int(ceil(player_actor.safe_seconds_left()))
		_safe_label.text = "SAFE ZONE — %ds left" % secs
		_safe_label.visible = true
	elif _safe_label != null:
		_safe_label.visible = false

func _update_lock_reticle() -> void:
	if _lock_reticle == null or camera == null:
		return
	# show a ring over the locked pass target while the player carries a ball
	if player_actor == null or not player_actor.has_ball() or player_actor.lock_target == null \
			or not is_instance_valid(player_actor.lock_target):
		_lock_reticle.visible = false
		return
	var wp: Vector3 = player_actor.lock_target.global_position + Vector3(0, 6, 0)
	if camera.is_position_behind(wp):
		_lock_reticle.visible = false
		return
	_lock_reticle.position = camera.unproject_position(wp)
	_lock_reticle.visible = true

func _update_throw_flash(delta: float) -> void:
	if _throw_flash == null:
		return
	if _flash_timer > 0.0:
		_flash_timer -= delta
		_throw_flash.visible = true
		var a: float = clampf(_flash_timer, 0.0, 1.0)
		_throw_flash.modulate = Color(1, 1, 1, a)
	else:
		_throw_flash.visible = false

func flash_result(text: String, color: Color) -> void:
	if _throw_flash == null:
		return
	_throw_flash.text = text
	_throw_flash.add_theme_color_override("font_color", color)
	_flash_timer = 1.4

func _on_pass_thrown(ball: Node, receiver: Node) -> void:
	# if the pass is to the player, open the catch QTE with a heads-up beat
	if receiver != null and receiver == player_actor:
		flash_result("INCOMING!", Color(1.0, 0.85, 0.3))
		_start_qte(ball)
	elif receiver != null:
		flash_result("Pass!", Color(0.8, 0.9, 1.0))

## Open the THROW QTE: a timing bar you must hit to release the throw. Called by
## the player Actor when it wants to throw/pass. On a hit we tell the actor to
## execute the throw; on a miss/timeout the actor fumbles the ball.
func start_throw_qte(actor: Node) -> void:
	if _qte_active or _throw_qte:
		return   # don't stack with a catch QTE
	_throw_qte = true
	_throw_qte_actor = actor
	_qte_active = true
	_qte_time = 0.0
	_qte_mode = "timing"   # throw is always the timing bar
	_qte_ball = null
	_configure_qte_panel()
	# relabel for throwing
	if _qte_panel != null:
		var ql := _qte_panel.get_node_or_null("QLabel") as Label
		if ql != null:
			ql.text = "THROW!"
		_qte_panel.visible = true

func _start_qte(ball: Node) -> void:
	_qte_active = true
	_qte_time = 0.0
	_qte_ball = ball
	# Randomly choose the QTE flavor each time: ~half timing-bar, half key-press.
	_qte_mode = "key" if randf() < 0.5 else "timing"
	if _qte_mode == "key":
		_qte_key = _pick_qte_key()
		_qte_last_key = _qte_key
	_configure_qte_panel()
	if _qte_panel != null:
		_qte_panel.visible = true

## Pick a key from the unused-key pool that isn't the same as last time (so the
## demanded key never repeats twice in a row).
func _pick_qte_key() -> int:
	# Exclude any key CURRENTLY bound to a game action. Keys are rebindable, so
	# this must check the live InputMap every pick — a static safe-list breaks
	# the moment the player rebinds (e.g. sprint onto F). Polling-based actions
	# (sprint/crouch) can't be blocked by consuming the event, so exclusion at
	# pick time is the only safe approach.
	var bound := {}
	for action in InputMap.get_actions():
		if String(action).begins_with("ui_"):
			continue
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey:
				var ke := ev as InputEventKey
				if ke.physical_keycode != 0:
					bound[ke.physical_keycode] = true
				if ke.keycode != 0:
					bound[ke.keycode] = true
	var choices: Array = []
	for k in QTE_KEY_POOL:
		if k != _qte_last_key and not bound.has(k):
			choices.append(k)
	# fallback ladder: allow a repeat before ever allowing a bound key
	if choices.is_empty():
		for k in QTE_KEY_POOL:
			if not bound.has(k):
				choices.append(k)
	if choices.is_empty():
		choices = QTE_KEY_POOL.duplicate()
	return choices[randi() % choices.size()]

## Show/hide the timing-bar pieces vs. the key prompt depending on _qte_mode, and
## set the label text for the active mode.
func _configure_qte_panel() -> void:
	if _qte_panel == null:
		return
	var bar_names := ["BarBg", "Window", "Perfect", "Cursor"]
	var timing := _qte_mode == "timing"
	for n in bar_names:
		var node := _qte_panel.get_node_or_null(n)
		if node != null:
			(node as CanvasItem).visible = timing
	var keyprompt := _qte_panel.get_node_or_null("KeyPrompt") as Label
	if keyprompt != null:
		keyprompt.visible = not timing
		if not timing:
			keyprompt.text = "[ %s ]" % OS.get_keycode_string(_qte_key)
	var qlabel := _qte_panel.get_node_or_null("QLabel") as Label
	if qlabel != null:
		qlabel.text = "CATCH" if timing else "QUICK!  PRESS:"

func _update_qte(delta: float) -> void:
	if not _qte_active or _qte_panel == null:
		return
	_qte_time += delta
	# KEY MODE: no sweeping cursor — you just have until the timeout to press the
	# shown key. A slightly longer window than the timing bar since there's no
	# "aim", just reaction. The KeyPrompt pulses to convey urgency.
	if _qte_mode == "key":
		var keyprompt := _qte_panel.get_node_or_null("KeyPrompt") as Label
		if keyprompt != null:
			var pulse: float = 0.7 + 0.3 * sin(_qte_time * 16.0)
			keyprompt.modulate = Color(1, 1, 1, pulse)
		if _qte_time > 1.4:
			_resolve_qte(false)
		return
	var cursor := _qte_panel.get_node("Cursor") as ColorRect
	var win := _qte_panel.get_node("Window") as ColorRect
	var travel: float = clampf(_qte_time / 1.2, 0.0, 1.0)   # ~1.2s sweep
	if cursor != null:
		cursor.position.x = 40.0 + travel * 216.0   # sweeps across the 220px track
	# RISING TENSION: the window pulses and brightens as the cursor approaches it,
	# so the moment crescendos instead of staying flat.
	if win != null and cursor != null:
		var to_win: float = absf(cursor.position.x - (win.position.x + win.size.x * 0.5))
		var nearness: float = clampf(1.0 - to_win / 90.0, 0.0, 1.0)
		var pulse: float = 0.7 + 0.3 * sin(_qte_time * 18.0)
		# brighter + pulsing green as you near the window
		win.color = Color(0.3, 0.7 + 0.3 * nearness, 0.4, 0.55 + 0.45 * nearness * pulse)
	# timed out without a press -> per-spec random fallback
	if _qte_time > 1.3:
		_resolve_qte(false)

## Player pressed the catch button during the QTE — hit if the cursor is in the
## green window, miss otherwise. Called from PlayerController via the HUD.
func qte_press() -> void:
	if not _qte_active:
		return
	var cursor := _qte_panel.get_node("Cursor") as ColorRect
	var win := _qte_panel.get_node("Window") as ColorRect
	var hit := false
	var perfect := false
	if cursor != null and win != null:
		var cx: float = cursor.position.x
		hit = cx >= win.position.x - 4 and cx <= win.position.x + win.size.x
		# PERFECT: within the bright sweet-spot sliver at the window's center
		var center: float = win.position.x + win.size.x * 0.5
		perfect = absf(cx - center) <= 7.0
	_resolve_qte(hit, perfect)

func _resolve_qte(hit: bool, perfect: bool = false) -> void:
	_qte_active = false
	if _qte_panel != null:
		_qte_panel.visible = false

	# THROW QTE: resolve by calling back into the player actor. Hit = execute the
	# throw, miss = fumble the ball (drops loose, must be re-grabbed).
	if _throw_qte:
		_throw_qte = false
		var actor := _throw_qte_actor
		_throw_qte_actor = null
		if actor == null or not is_instance_valid(actor):
			return
		if hit:
			if actor.has_method("execute_pending_throw"):
				actor.execute_pending_throw()
			if perfect:
				flash_result("PERFECT THROW!", Color(1.0, 0.95, 0.4))
				_juice_pop(0.8)
			else:
				flash_result("THROW!", Color(0.5, 0.9, 1.0))
				_juice_pop(0.4)
		else:
			if actor.has_method("fumble_throw"):
				actor.fumble_throw()
			flash_result("FUMBLED!", Color(1.0, 0.45, 0.35))
			_juice_pop(0.3)
		return

	if _qte_ball == null or not is_instance_valid(_qte_ball):
		return
	if hit:
		# clean catch: hand the ball to the player, with a punchy payoff
		if player_actor != null and _qte_ball.has_method("force_catch"):
			_qte_ball.force_catch(player_actor)
		if perfect:
			flash_result("PERFECT CATCH!", Color(1.0, 0.95, 0.4))
			_juice_pop(0.9)
		else:
			flash_result("NICE CATCH!", Color(0.4, 1.0, 0.5))
			_juice_pop(0.5)
	else:
		# miss / ignored: per spec, random chance it's caught anyway, else drops
		if randf() < 0.35 and player_actor != null and _qte_ball.has_method("force_catch"):
			_qte_ball.force_catch(player_actor)
			flash_result("Lucky grab!", Color(0.7, 1.0, 0.6))
			_juice_pop(0.4)
		else:
			if _qte_ball.has_method("drop_loose"):
				_qte_ball.drop_loose()
			flash_result("FUMBLE!", Color(1.0, 0.45, 0.35))
			_juice_pop(0.3)
	_qte_ball = null

## Fire a little screen-shake payoff for catch outcomes, if the juice system is up.
func _juice_pop(amount: float) -> void:
	if match_ref != null and match_ref.has_method("get") and "juice" in match_ref:
		var j = match_ref.juice
		if j != null and j.has_method("shake"):
			j.shake(amount)

func _update_action_prompt() -> void:
	if _prompt == null:
		return
	# only show the crosshair/prompt in first/third person (not the overhead view),
	# and never while the win/lose end screen is up
	var show_cross: bool = (GameState.cam_mode == "fp" or GameState.cam_mode == "third") and not $EndScreen.visible
	if _crosshair != null:
		_crosshair.visible = show_cross
	# sitting on a bench overrides everything — you can only stand up
	if player_actor.has_method("is_sitting") and player_actor.is_sitting():
		_prompt.text = "Press E To Stand"
		_prompt.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
		_prompt.visible = true
		return
	if not show_cross or player_actor.has_target():
		_prompt.visible = false
		return
	# tag takes priority over revive, then bench-sit, when several are available
	if player_actor.best_tag_target() != null:
		_prompt.text = "Press E to tag"
		_prompt.add_theme_color_override("font_color", Color(1.0, 0.5, 0.4))
		_prompt.visible = true
	elif player_actor.best_revive_target() != null:
		_prompt.text = "Press R to revive"
		_prompt.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
		_prompt.visible = true
	elif player_actor.has_method("nearest_bench") and player_actor.nearest_bench() != null:
		_prompt.text = "Press E To Sit"
		_prompt.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
		_prompt.visible = true
	else:
		_prompt.visible = false

func _on_match_won(team: String) -> void:
	var won: bool = (team == GameState.user_team)
	$EndScreen.visible = true
	# hide the aiming reticle + lock ring so they don't overlay the end menu text
	if _crosshair != null:
		_crosshair.visible = false
	if _lock_reticle != null:
		_lock_reticle.visible = false
	$EndScreen/Panel/VBox/Title.text = "VICTORY!" if won else "DEFEAT"
	$EndScreen/Panel/VBox/Title.modulate = Color(0.4, 0.85, 0.5) if won else Color(0.9, 0.4, 0.36)
	var ws: int = GameState.score_for(GameState.user_team)
	var ls: int = GameState.score_for(Config.enemy_of(GameState.user_team))
	# your row from the live per-kid registry (same data as the Tab scoreboard)
	var s: Dictionary = {}
	for row in GameState.stats.values():
		if row.user:
			s = row
			break
	var detail := ""
	detail = "Final score  —  you %d, them %d\n\n" % [ws, ls]
	detail += "Your match:\n"
	detail += "  Points banked:   %d\n" % int(s.get("pts", 0))
	detail += "  Tags made:        %d\n" % int(s.get("tags", 0))
	detail += "  Teammates saved: %d\n" % int(s.get("saves", 0))
	detail += "  Times tagged:    %d" % int(s.get("outs", 0))
	$EndScreen/Panel/VBox/Detail.text = detail
	# FULL RESULTS TABLE: both teams ranked with headshots — the same data and
	# builder as the Tab scoreboard, so the end screen tells the whole story.
	var vb := $EndScreen/Panel/VBox
	if vb.has_node("Results"):
		vb.get_node("Results").queue_free()
	var results := HBoxContainer.new()
	results.name = "Results"
	results.add_theme_constant_override("separation", 24)
	vb.add_child(results)
	results.add_child(_team_column("blue", 22, 13))
	results.add_child(_team_column("red", 22, 13))
	# keep the buttons at the bottom, under the table
	vb.move_child(results, $EndScreen/Panel/VBox/Restart.get_index())
	$EndScreen/Panel.custom_minimum_size = Vector2(880, 0)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _on_main_menu_pressed() -> void:
	$EndScreen.visible = false
	# back to the start of the main menu. Restart the demo/menu directly so the
	# Welcome audio does NOT replay — only the music loop continues.
	if match_ref != null and match_ref.has_method("return_to_menu"):
		match_ref.return_to_menu()

func _on_quit_pressed() -> void:
	get_tree().quit()

func _on_restarted() -> void:
	$EndScreen.visible = false
	_refresh_scoreboard()
	if GameState.cam_mode == "fp":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ---------------------------------------------------------------- leaderboard --
## Tab popup: every kid ranked per team by match impact. The same GameState.stats
## feed the future win/lose screen. (Headshot thumbnails: follow-up — the selector
## renders those via live viewports, too heavy to spawn 20 of mid-match.)
func _toggle_leaderboard() -> void:
	if _lb == null:
		# full-rect CenterContainer = genuinely centred panel at any resolution
		var lb_wrap := CenterContainer.new()
		lb_wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
		lb_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(lb_wrap)
		_lb = PanelContainer.new()
		_lb.custom_minimum_size = Vector2(820, 430)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.07, 0.09, 0.13, 0.94)
		sb.set_corner_radius_all(10)
		sb.set_content_margin_all(16)
		_lb.add_theme_stylebox_override("panel", sb)
		lb_wrap.add_child(_lb)
		var v := VBoxContainer.new()
		_lb.add_child(v)
		var title := Label.new()
		title.text = "SCOREBOARD"
		title.add_theme_font_size_override("font_size", 26)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(title)
		_lb_body = HBoxContainer.new()
		_lb_body.add_theme_constant_override("separation", 26)
		v.add_child(_lb_body)
	_lb.visible = not _lb.visible
	if _lb.visible:
		_fill_leaderboard()

func _fill_leaderboard() -> void:
	for c in _lb_body.get_children():
		c.queue_free()
	for tm in ["blue", "red"]:
		_lb_body.add_child(_team_column(tm, 26, 15))

## One ranked team column (shared by the Tab scoreboard AND the win/lose
## results table): headshot icon + name + pts/tags/saves/ins/outs, ranked by
## impact = pts*5 + tags*2 + saves*2 - outs, top 10, player row highlighted.
func _team_column(tm: String, icon_px: int, fnt: int) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var hdr := Label.new()
	hdr.text = tm.to_upper() + "   pts / tags / saves / ins / outs"
	hdr.add_theme_font_size_override("font_size", fnt)
	hdr.add_theme_color_override("font_color", Color(0.45, 0.7, 1.0) if tm == "blue" else Color(1.0, 0.5, 0.45))
	col.add_child(hdr)
	var rows: Array = []
	for key in GameState.stats.keys():
		var s: Dictionary = GameState.stats[key]
		if s.team != tm:
			continue
		var impact: int = s.pts * 5 + s.tags * 2 + s.saves * 2 - s.outs
		rows.append([impact, key, s])
	rows.sort_custom(func(x, y): return x[0] > y[0])
	var rank := 1
	for r in rows:
		if rank > 10:
			break
		var s2: Dictionary = r[2]
		var hrow := HBoxContainer.new()
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(icon_px, icon_px)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var tex = GameState.headshots.get(String(s2.get("char", "")), null)
		if tex != null:
			icon.texture = tex
		hrow.add_child(icon)
		var who: String = String(s2.get("label", r[1])) + (" (you)" if s2.user else "")
		var l := Label.new()
		l.text = "%2d. %-14s %d / %d / %d / %d / %d" % [rank, who, s2.pts, s2.tags, s2.saves, s2.ins, s2.outs]
		l.add_theme_font_size_override("font_size", fnt)
		if s2.user:
			l.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
		hrow.add_child(l)
		col.add_child(hrow)
		rank += 1
	return col
