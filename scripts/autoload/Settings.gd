extends Node
## Persistent user settings (spec: "remember preferences, apply button, stick").
## Saved to user://settings.cfg and loaded on launch. The pause/settings menu
## edits a pending copy and only commits on Apply, so changes "take effect and
## stick" deliberately rather than live.

const PATH := "user://settings.cfg"

# Live, applied values (read by the game).
var sprint_fx := true               # FOV punch / motion feedback while sprinting
var mouse_sensitivity := 1.0        # multiplier on look speed
var master_volume := 0.8
var welcome_volume := 0.9        # the launch Welcome clip
var music_volume_menu := 0.6     # menu / skycam music
var music_volume_game := 0.4     # in-game music (quieter under gameplay)
var show_nametags := true
var grass_quality := 2              # 0 off, 1 low, 2 high (scaffolding for VFX)
var shadow_quality := 2             # 0 off, 1 low, 2 high
var fullscreen := false
# advanced graphics — let players optimize. Each toggles a real engine effect.
var gi_quality := 2                 # global illumination: 0 off, 1 low, 2 high (SDFGI) — main fidelity driver
var reflections := false            # screen-space reflections (SSR) — costly, off by default
var ambient_occlusion := true       # SSAO — cheap, big visual gain, keep on
var indirect_light := false         # SSIL — costly, off by default
var bloom := true                   # glow — cheap, keep on
var anti_aliasing := true           # TAA
# 3D render resolution scale — THE biggest lever for weak hardware. 1.0 = native;
# the Performance preset drops it to 0.75 (image upscales to window size).
var render_scale := 1.0
# One-click quality preset (0 = Performance, 1 = Quality). Setting it batch-writes
# the granular video values below; granular edits after that simply diverge.
var graphics_preset := 1:
	set(v):
		graphics_preset = v
		_batch_preset(v)
var fov_first_person := 70.0        # FOV in first person (degrees)
var fov_third_person := 62.0        # FOV in third person (degrees)

## Actions the player may rebind (pause and debug cam stay fixed so nobody can
## soft-lock themselves out of the menu).
const REBINDABLE := ["move_forward", "move_back", "move_left", "move_right",
	"sprint", "jump", "crouch", "interact", "revive", "toggle_cam",
	"throw_ball", "pass_ball", "cycle_lock", "catch_qte"]
# action -> serialized event dict ({"t":"key","code":int} / {"t":"mouse","btn":int}
# / {"t":"none"} for deliberately unbound). Empty dict = project defaults.
var keybinds := {}

func _ready() -> void:
	load_settings()
	apply_runtime()
	# defer: the tree root isn't ready for viewport writes during autoload _ready
	apply_runtime_video.call_deferred()
	Events.settings_applied.connect(apply_runtime_video)

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	# preset loads FIRST (its setter batch-writes granular values), then the saved
	# granular values below overwrite that batch — so custom tweaks survive restarts
	graphics_preset = cfg.get_value("video", "graphics_preset", graphics_preset)
	render_scale = cfg.get_value("video", "render_scale", render_scale)
	# keybinds load + apply to the live InputMap
	if cfg.has_section("keybinds"):
		for action in cfg.get_section_keys("keybinds"):
			keybinds[action] = cfg.get_value("keybinds", action)
	_apply_keybinds()
	sprint_fx = cfg.get_value("gameplay", "sprint_fx", sprint_fx)
	mouse_sensitivity = cfg.get_value("gameplay", "mouse_sensitivity", mouse_sensitivity)
	show_nametags = cfg.get_value("gameplay", "show_nametags", show_nametags)
	master_volume = cfg.get_value("audio", "master_volume", master_volume)
	welcome_volume = cfg.get_value("audio", "welcome_volume", welcome_volume)
	music_volume_menu = cfg.get_value("audio", "music_volume_menu", music_volume_menu)
	music_volume_game = cfg.get_value("audio", "music_volume_game", music_volume_game)
	grass_quality = cfg.get_value("video", "grass_quality", grass_quality)
	shadow_quality = cfg.get_value("video", "shadow_quality", shadow_quality)
	fullscreen = cfg.get_value("video", "fullscreen", fullscreen)
	gi_quality = cfg.get_value("video", "gi_quality", gi_quality)
	reflections = cfg.get_value("video", "reflections", reflections)
	ambient_occlusion = cfg.get_value("video", "ambient_occlusion", ambient_occlusion)
	indirect_light = cfg.get_value("video", "indirect_light", indirect_light)
	bloom = cfg.get_value("video", "bloom", bloom)
	anti_aliasing = cfg.get_value("video", "anti_aliasing", anti_aliasing)
	fov_first_person = cfg.get_value("video", "fov_first_person", fov_first_person)
	fov_third_person = cfg.get_value("video", "fov_third_person", fov_third_person)

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("gameplay", "sprint_fx", sprint_fx)
	cfg.set_value("gameplay", "mouse_sensitivity", mouse_sensitivity)
	cfg.set_value("gameplay", "show_nametags", show_nametags)
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("audio", "welcome_volume", welcome_volume)
	cfg.set_value("audio", "music_volume_menu", music_volume_menu)
	cfg.set_value("audio", "music_volume_game", music_volume_game)
	for action in keybinds.keys():
		cfg.set_value("keybinds", action, keybinds[action])
	cfg.set_value("video", "graphics_preset", graphics_preset)
	cfg.set_value("video", "render_scale", render_scale)
	cfg.set_value("video", "grass_quality", grass_quality)
	cfg.set_value("video", "shadow_quality", shadow_quality)
	cfg.set_value("video", "fullscreen", fullscreen)
	cfg.set_value("video", "gi_quality", gi_quality)
	cfg.set_value("video", "reflections", reflections)
	cfg.set_value("video", "ambient_occlusion", ambient_occlusion)
	cfg.set_value("video", "indirect_light", indirect_light)
	cfg.set_value("video", "bloom", bloom)
	cfg.set_value("video", "anti_aliasing", anti_aliasing)
	cfg.set_value("video", "fov_first_person", fov_first_person)
	cfg.set_value("video", "fov_third_person", fov_third_person)
	cfg.save(PATH)

## Push applied values into the engine (called after Apply and on launch).
func apply_runtime() -> void:
	var bus := AudioServer.get_bus_index("Master")
	if bus >= 0:
		AudioServer.set_bus_volume_db(bus, linear_to_db(clampf(master_volume, 0.0001, 1.0)))
	# Apply window mode deferred — calling window ops too early (during _ready)
	# can be ignored by the OS, leaving the game windowed despite the setting.
	# EXCLUSIVE_FULLSCREEN engages more reliably than plain FULLSCREEN in Godot 4.
	if fullscreen:
		DisplayServer.window_set_mode.call_deferred(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode.call_deferred(DisplayServer.WINDOW_MODE_WINDOWED)
	# temporal anti-aliasing on the main viewport
	var vp := get_viewport()
	if vp != null:
		vp.use_taa = anti_aliasing
	Events.settings_applied.emit()

## Commit a batch of pending changes (from the menu) then persist + apply.
func apply_pending(pending: Dictionary) -> void:
	var p := pending.duplicate()
	# PRESET WINS: the settings panel pre-populates pending with every CURRENT
	# value when it opens, so applying a new preset then iterating the dict let
	# those stale values overwrite the preset's batch right back (the "nothing
	# changes" bug). If the preset changed, apply it and DROP the granular video
	# keys from this commit — the preset is what the user asked for.
	if p.has("graphics_preset") and int(p["graphics_preset"]) != graphics_preset:
		graphics_preset = int(p["graphics_preset"])   # setter batch-writes granulars
		for gk in ["grass_quality", "shadow_quality", "gi_quality", "reflections",
				"ambient_occlusion", "indirect_light", "bloom", "anti_aliasing",
				"render_scale"]:
			p.erase(gk)
		p.erase("graphics_preset")
	for key in p.keys():
		if key in self:
			set(key, p[key])
	save_settings()
	apply_runtime()


## Batch-write the granular video settings for a preset. 0 = Performance (weak
## hardware: no GI/SSAO/AA/bloom, low shadows+grass, 75% render scale), 1 = Quality
## (the defaults). Does NOT save/emit — the settings Apply flow does that.
func _batch_preset(idx: int) -> void:
	if idx == 0:
		grass_quality = 0
		shadow_quality = 0
		gi_quality = 0
		reflections = false
		ambient_occlusion = false
		indirect_light = false
		bloom = false
		anti_aliasing = false
		render_scale = 0.75
	else:
		grass_quality = 2
		shadow_quality = 2
		gi_quality = 2
		reflections = false
		ambient_occlusion = true
		indirect_light = false
		bloom = true
		anti_aliasing = true
		render_scale = 1.0

## Apply the video values that live OUTSIDE the WorldEnvironment: render scale on
## the root viewport, and the directional shadow atlas/filter via RenderingServer
## (no node lookups — works wherever the sun lives). Runs at boot and on every
## settings apply.
func apply_runtime_video() -> void:
	var root := get_tree().root
	root.scaling_3d_scale = clampf(render_scale, 0.5, 1.0)
	var atlas := 4096 if shadow_quality >= 2 else 2048
	RenderingServer.directional_shadow_atlas_set_size(atlas, true)
	var filt := RenderingServer.SHADOW_QUALITY_SOFT_HIGH if shadow_quality >= 2 else RenderingServer.SHADOW_QUALITY_SOFT_LOW
	RenderingServer.directional_soft_shadow_filter_set_quality(filt)
	# shadow quality 0 = shadows fully OFF (the Performance preset's biggest win
	# after render scale). Toggles every directional light in the scene.
	for l in root.find_children("*", "DirectionalLight3D", true, false):
		(l as DirectionalLight3D).shadow_enabled = shadow_quality > 0


# ---------------------------------------------------------------- keybinds ----

## Turn an input event into our small serializable dict (or empty if unsupported).
func serialize_event(ev: InputEvent) -> Dictionary:
	if ev is InputEventKey:
		var k := ev as InputEventKey
		return {"t": "key", "code": int(k.physical_keycode if k.physical_keycode != 0 else k.keycode)}
	if ev is InputEventMouseButton:
		return {"t": "mouse", "btn": int((ev as InputEventMouseButton).button_index)}
	return {}

func _event_from(d: Dictionary) -> InputEvent:
	match str(d.get("t", "")):
		"key":
			var k := InputEventKey.new()
			k.physical_keycode = int(d.get("code", 0)) as Key
			return k
		"mouse":
			var m := InputEventMouseButton.new()
			m.button_index = int(d.get("btn", 1)) as MouseButton
			return m
	return null

## Human-readable label for an action's CURRENT binding.
func bind_label(action: String) -> String:
	var evs := InputMap.action_get_events(action)
	if evs.is_empty():
		return "— unbound —"
	var ev := evs[0]
	if ev is InputEventKey:
		var k := ev as InputEventKey
		var code: Key = k.physical_keycode if k.physical_keycode != 0 else k.keycode
		return OS.get_keycode_string(code)
	if ev is InputEventMouseButton:
		match (ev as InputEventMouseButton).button_index:
			MOUSE_BUTTON_LEFT: return "Mouse Left"
			MOUSE_BUTTON_RIGHT: return "Mouse Right"
			MOUSE_BUTTON_MIDDLE: return "Mouse Middle"
			_: return "Mouse " + str((ev as InputEventMouseButton).button_index)
	return ev.as_text()

## Which rebindable action currently uses this event (for conflict handling).
func action_using(ev: InputEvent) -> String:
	var want := serialize_event(ev)
	if want.is_empty():
		return ""
	for action in REBINDABLE:
		for e in InputMap.action_get_events(action):
			if serialize_event(e) == want:
				return action
	return ""

## Bind `ev` to `action`, stealing it from any conflicting action. Applies to the
## live InputMap immediately and persists. Returns the action it was stolen from
## ("" if none) so the UI can show both rows updating.
func rebind(action: String, ev: InputEvent) -> String:
	var stolen := action_using(ev)
	if stolen == action:
		stolen = ""
	if stolen != "":
		InputMap.action_erase_events(stolen)
		keybinds[stolen] = {"t": "none"}
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, ev)
	keybinds[action] = serialize_event(ev)
	save_settings()
	return stolen

## Restore every binding to the project defaults and forget custom binds.
func reset_keybinds() -> void:
	InputMap.load_from_project_settings()
	keybinds = {}
	save_settings()

func _apply_keybinds() -> void:
	for action in keybinds.keys():
		if not InputMap.has_action(action):
			continue
		var d: Dictionary = keybinds[action]
		if str(d.get("t", "")) == "none":
			InputMap.action_erase_events(action)
			continue
		var ev := _event_from(d)
		if ev != null:
			InputMap.action_erase_events(action)
			InputMap.action_add_event(action, ev)
