extends Control
## Pause menu (Esc): Resume / Settings / Exit. The Settings panel edits a PENDING
## copy of Settings and only commits on Apply, so prefs "take effect and stick"
## on Apply rather than live. Pausing sets the SceneTree paused so the match
## freezes underneath.

var _paused := false
var _standalone_settings := false   # settings opened from the main menu
var _saved_cam_mode := "third"   # restore the player's camera on resume
var _pending := {}
# advanced graphics controls (built in code, populated on open)
var _was_mouse_captured := false

func _ready() -> void:
	visible = false
	# this menu must keep working while the tree is paused
	process_mode = Node.PROCESS_MODE_ALWAYS
	# allow the main menu to open settings standalone
	Events.open_settings_request.connect(open_settings_standalone)
	$Pause/Panel/VBox/Resume.pressed.connect(_resume)
	$Pause/Panel/VBox/SettingsBtn.pressed.connect(_open_settings)
	$Pause/Panel/VBox/Exit.pressed.connect(_exit)
	# "Main Menu" sits between Settings and Exit — built in code so the scene file
	# stays untouched. Hard-stops the current match and returns to the title flow.
	var mm_btn := Button.new()
	mm_btn.name = "MainMenuBtn"
	mm_btn.text = "Main Menu"
	mm_btn.custom_minimum_size = Vector2(220, 48)   # match the scene's buttons
	var vbox: VBoxContainer = $Pause/Panel/VBox
	vbox.add_child(mm_btn)
	vbox.move_child(mm_btn, ($Pause/Panel/VBox/SettingsBtn as Control).get_index() + 1)
	mm_btn.pressed.connect(_to_main_menu)
	# Build the tabbed settings UI in code (replaces the old flat scene rows).
	_build_settings_tabs()

# ============================================================================
# TABBED SETTINGS UI  (Gameplay / Graphics / Audio / Key Bindings)
# Built entirely in code inside the scene's SettingsPanel/Panel shell. Every
# control writes to _pending; nothing commits until Apply. Apply sits bottom-
# right, Back bottom-left.
# ============================================================================
var _ctl: Dictionary = {}          # setting key -> control node (for populate)
var _apply_btn: Button = null

func _build_settings_tabs() -> void:
	var panel := $SettingsPanel/Panel
	# clear whatever the scene placed inside Panel (old flat VBox). PanelContainer
	# holds one child, so remove immediately (not deferred) before adding Root.
	for c in panel.get_children():
		panel.remove_child(c)
		c.queue_free()

	var root := VBoxContainer.new()
	root.name = "Root"
	root.add_theme_constant_override("separation", 12)
	root.custom_minimum_size = Vector2(560, 460)
	panel.add_child(root)

	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	root.add_child(title)

	var tabs := TabContainer.new()
	tabs.name = "Tabs"
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.custom_minimum_size = Vector2(560, 380)
	root.add_child(tabs)

	# --- Gameplay tab ---
	var gp := _new_tab(tabs, "Gameplay")
	_add_check(gp, "sprint_fx", "Sprint FX (FOV punch)")
	_add_check(gp, "show_nametags", "Show Nametags")
	_add_slider(gp, "mouse_sensitivity", "Mouse Sensitivity", 0.2, 3.0, 0.05)

	# --- Graphics tab ---
	var gx := _new_tab(tabs, "Graphics")
	# one-click preset — batch-sets everything below (Performance is the
	# weak-hardware profile: 75% render scale, low shadows/grass, no GI/SSAO/AA)
	_add_option(gx, "graphics_preset", "Quality Preset", ["Performance", "Quality"])
	_add_check(gx, "fullscreen", "Fullscreen")
	_add_option(gx, "grass_quality", "Grass Quality", ["Off", "Low", "High"])
	_add_option(gx, "shadow_quality", "Shadow Quality", ["Off", "Low", "High"])
	_add_option(gx, "gi_quality", "Global Illumination", ["Off", "Low", "High"])
	_add_check(gx, "ambient_occlusion", "Ambient Occlusion")
	_add_check(gx, "reflections", "Reflections")
	_add_check(gx, "indirect_light", "Indirect Light")
	_add_check(gx, "bloom", "Bloom")
	_add_check(gx, "anti_aliasing", "Anti-Aliasing (TAA)")
	_add_slider(gx, "fov_first_person", "FOV (First Person)", 55.0, 110.0, 1.0)
	_add_slider(gx, "fov_third_person", "FOV (Third Person)", 50.0, 100.0, 1.0)

	# --- Audio tab ---
	var au := _new_tab(tabs, "Audio")
	_add_slider(au, "master_volume", "Master Volume", 0.0, 1.0, 0.05)
	_add_slider(au, "welcome_volume", "Welcome Volume", 0.0, 1.0, 0.05)
	_add_slider(au, "music_volume_menu", "Menu Music", 0.0, 1.0, 0.05)
	_add_slider(au, "music_volume_game", "In-Game Music", 0.0, 1.0, 0.05)

	# --- Key Bindings tab (read-only reference for now) ---
	var kb := _new_tab(tabs, "Key Bindings")
	_add_keybind_list(kb)

	# --- bottom bar: Back (left) | Apply (right) ---
	var bar := HBoxContainer.new()
	bar.name = "BottomBar"
	root.add_child(bar)
	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(140, 44)
	back.pressed.connect(_close_settings)
	bar.add_child(back)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	_apply_btn = Button.new()
	_apply_btn.text = "Apply"
	_apply_btn.custom_minimum_size = Vector2(140, 44)
	_apply_btn.pressed.connect(_apply)
	bar.add_child(_apply_btn)

## Create a scrollable tab page with a VBox inside, return the VBox.
func _new_tab(tabs: TabContainer, tab_name: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 10)
	scroll.add_child(vb)
	tabs.add_child(scroll)
	return vb

func _add_check(parent: VBoxContainer, key: String, label: String) -> void:
	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(300, 0)
	row.add_child(lbl)
	var chk := CheckBox.new()
	chk.toggled.connect(func(v): _pending[key] = v)
	row.add_child(chk)
	parent.add_child(row)
	_ctl[key] = chk

func _add_slider(parent: VBoxContainer, key: String, label: String, min_v: float, max_v: float, step_v: float) -> void:
	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(300, 0)
	row.add_child(lbl)
	var sld := HSlider.new()
	sld.min_value = min_v
	sld.max_value = max_v
	sld.step = step_v
	sld.custom_minimum_size = Vector2(180, 0)
	sld.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sld.value_changed.connect(func(v): _pending[key] = v)
	row.add_child(sld)
	parent.add_child(row)
	_ctl[key] = sld

func _add_option(parent: VBoxContainer, key: String, label: String, items: Array) -> void:
	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(300, 0)
	row.add_child(lbl)
	var opt := OptionButton.new()
	for it in items:
		opt.add_item(it)
	opt.item_selected.connect(func(i): _pending[key] = i)
	row.add_child(opt)
	parent.add_child(row)
	_ctl[key] = opt

## Read-only list of the current key bindings (rebindable later).
# --- rebindable keys UI ----------------------------------------------------
# Click a binding -> "Press any key..." -> next key/mouse press binds it (Esc
# cancels). Conflicts are stolen: the other action shows "— unbound —" in red.
# Changes apply IMMEDIATELY and persist (no Apply needed for keys).

const _BIND_LABELS := {
	"move_forward": "Move Forward", "move_back": "Move Back",
	"move_left": "Move Left", "move_right": "Move Right",
	"sprint": "Sprint", "jump": "Jump", "crouch": "Crouch",
	"interact": "Interact / Tag / Sit", "revive": "Revive Teammate",
	"toggle_cam": "Toggle Camera", "throw_ball": "Throw",
	"pass_ball": "Pass", "cycle_lock": "Cycle Lock-On Target",
	"catch_qte": "Catch (timing press)",
}
var _bind_buttons := {}          # action -> Button
var _capture_action := ""        # non-empty while waiting for a key press

func _add_keybind_list(parent: VBoxContainer) -> void:
	var note := Label.new()
	note.text = "Click a binding, then press the new key (Esc cancels). Applies instantly."
	note.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	parent.add_child(note)
	for action in Settings.REBINDABLE:
		var row := HBoxContainer.new()
		var k := Label.new()
		k.text = _BIND_LABELS.get(action, action)
		k.custom_minimum_size = Vector2(300, 0)
		row.add_child(k)
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(200, 36)
		btn.text = Settings.bind_label(action)
		btn.pressed.connect(_begin_capture.bind(action))
		_bind_buttons[action] = btn
		row.add_child(btn)
		parent.add_child(row)
	var pause_note := Label.new()
	pause_note.text = "Pause is fixed to Esc."
	pause_note.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	parent.add_child(pause_note)
	var reset := Button.new()
	reset.text = "Reset to Defaults"
	reset.custom_minimum_size = Vector2(220, 40)
	reset.pressed.connect(_reset_binds)
	parent.add_child(reset)

func _begin_capture(action: String) -> void:
	# cancel any previous half-finished capture display
	if _capture_action != "" and _bind_buttons.has(_capture_action):
		(_bind_buttons[_capture_action] as Button).text = Settings.bind_label(_capture_action)
	_capture_action = action
	(_bind_buttons[action] as Button).text = "Press any key..."

func _reset_binds() -> void:
	_capture_action = ""
	Settings.reset_keybinds()
	for action in _bind_buttons.keys():
		(_bind_buttons[action] as Button).text = Settings.bind_label(action)

func _input(event: InputEvent) -> void:
	if _capture_action == "":
		return
	# swallow everything while capturing so focused buttons don't react
	if event is InputEventKey and (event as InputEventKey).pressed:
		get_viewport().set_input_as_handled()
		var key := event as InputEventKey
		if key.physical_keycode == KEY_ESCAPE or key.keycode == KEY_ESCAPE:
			# cancel
			(_bind_buttons[_capture_action] as Button).text = Settings.bind_label(_capture_action)
			_capture_action = ""
			return
		_finish_capture(key)
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		get_viewport().set_input_as_handled()
		_finish_capture(event)

func _finish_capture(ev: InputEvent) -> void:
	var action := _capture_action
	_capture_action = ""
	var stolen := Settings.rebind(action, ev)
	(_bind_buttons[action] as Button).text = Settings.bind_label(action)
	if stolen != "" and _bind_buttons.has(stolen):
		var sb := _bind_buttons[stolen] as Button
		sb.text = Settings.bind_label(stolen)   # "— unbound —"
		sb.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and GameState.phase == GameState.Phase.PLAYING and not GameState.menu_open:
		if _paused:
			_resume()
		else:
			_pause()

func _pause() -> void:
	_paused = true
	visible = true
	$Pause.visible = true
	$SettingsPanel.visible = false
	_was_mouse_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# swap to the orbiting skycam for the pause backdrop. Keep the player visible
	# (it's their game, frozen behind the menu). The camera must keep processing
	# while the tree is paused so the orbit still animates.
	_saved_cam_mode = GameState.cam_mode
	var cam_rig := _find_camera_rig()
	if cam_rig != null:
		cam_rig.process_mode = Node.PROCESS_MODE_ALWAYS
		GameState.cam_mode = "orbit"
	# hide the HUD while paused — score/prompts/"Pass!" flashes shouldn't draw
	# over the pause menu's clean skycam backdrop
	var hud := get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.visible = false
	get_tree().paused = true
	Events.game_paused.emit(true)

func _resume() -> void:
	_paused = false
	visible = false
	get_tree().paused = false
	# restore the player's real camera mode
	var cam_rig := _find_camera_rig()
	if cam_rig != null:
		GameState.cam_mode = _saved_cam_mode
		cam_rig.process_mode = Node.PROCESS_MODE_INHERIT
	# bring the HUD back for play
	var hud := get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud.visible = true
	if _was_mouse_captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Events.game_paused.emit(false)

## Locate the camera rig (the menu sits outside the Match subtree).
func _find_camera_rig() -> Node:
	var m := get_tree().get_root().find_child("Match", true, false)
	if m != null and "camera_rig" in m:
		return m.camera_rig
	return null

## Open the settings panel directly from the MAIN MENU (no game to pause). The
## panel closes back to the menu rather than the in-game pause screen.
func open_settings_standalone() -> void:
	_standalone_settings = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = true
	_open_settings()
	$Pause.visible = false

func _open_settings() -> void:
	_load_settings_into_controls()
	$Pause.visible = false
	$SettingsPanel.visible = true

## Read every setting into the pending dict and reflect it into the controls.
## Called when the panel opens AND after Apply (so a preset's batch-write is
## immediately visible on the granular controls).
func _load_settings_into_controls() -> void:
	var keys := [
		"sprint_fx", "show_nametags", "mouse_sensitivity",
		"fullscreen", "graphics_preset", "grass_quality", "shadow_quality", "gi_quality",
		"ambient_occlusion", "reflections", "indirect_light", "bloom",
		"anti_aliasing", "fov_first_person", "fov_third_person",
		"master_volume", "welcome_volume", "music_volume_menu", "music_volume_game",
	]
	_pending = {}
	for k in keys:
		var val = Settings.get(k)
		_pending[k] = val
		var ctl = _ctl.get(k)
		if ctl == null:
			continue
		if ctl is CheckBox:
			(ctl as CheckBox).button_pressed = val
		elif ctl is HSlider:
			(ctl as HSlider).value = val
		elif ctl is OptionButton:
			(ctl as OptionButton).selected = int(val)

func _apply() -> void:
	Settings.apply_pending(_pending)
	# re-read everything back into the controls so a preset's batch is visible
	# immediately (grass/shadows/GI flip to the preset values on screen)
	_load_settings_into_controls()
	if _apply_btn != null:
		_apply_btn.text = "Applied ✓"
		await get_tree().create_timer(1.0).timeout
		if is_instance_valid(self) and _apply_btn != null:
			_apply_btn.text = "Apply"

func _close_settings() -> void:
	$SettingsPanel.visible = false
	if _standalone_settings:
		# opened from the main menu — hide the whole pause UI and return to menu
		_standalone_settings = false
		visible = false
		Events.settings_closed_standalone.emit()
	else:
		$Pause.visible = true

func _exit() -> void:
	get_tree().paused = false
	get_tree().quit()

## Hard-stop the current match and go back to the main menu. Match.return_to_menu
## does the heavy lifting (GameState reset, teardown, demo backdrop respin) and
## its returned_to_menu signal re-shows the menu, hides the HUD, frees the mouse.
func _to_main_menu() -> void:
	_paused = false
	visible = false
	get_tree().paused = false
	Events.main_menu_requested.emit()
