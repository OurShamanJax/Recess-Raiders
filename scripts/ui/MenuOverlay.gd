extends Control
## Main menu — a multi-step flow built in code so selections carry cleanly into
## the match via GameState:
##   1. pick your team
##   2. pick a side (blue / red)
##   3. pick your player model (that team's models only)
##   4. pick AI difficulty -> play
## The chosen mode, team, and model are written to GameState so the match reads
## them at spawn.

signal join_requested(team: String, cam_mode: String)

enum Step { LANDING, MODEL }

## Fixed number of character slots shown in the select grid. The roster fills into
## these; any unused slots show as greyed placeholders. Adding a new character just
## fills the next empty slot — no layout change until the roster exceeds this, at
## which point bump this number (keep it a multiple of the 4-column grid width).
const MODEL_SLOTS := 28

var _step: int = Step.LANDING
var _mode := "raiders"
var _team := "blue"
var _model := ""
var _diff := "casual"

var _root: VBoxContainer = null
var _title: Label = null
var _title_underline: Control = null
var _subtitle: Label = null
var _options: VBoxContainer = null
var _back_btn: Button = null
var _preview_box: SubViewportContainer = null
var _preview_frame: Panel = null
var _preview_vp: SubViewport = null
var _preview_holder: Node3D = null
var _preview_model: Node3D = null
# Redesigned character-select grid (AAA-style): a grid of model cards to the right
# of the big viewer. Clicking a card selects it (outline), updates the viewer +
# name, and enables Start. _model_cards maps model id -> its card Button.
var _model_grid: GridContainer = null
var _model_layer: Control = null
var _model_cards: Dictionary = {}
var _model_name_label: Label = null
var _start_btn: Button = null
var _selected_model_id: String = ""
# team-merged character page: which team each card belongs to, + the team toggles
var _card_team: Dictionary = {}
var _blue_btn: Button = null
var _red_btn: Button = null
var _preview_dragging := false
var _preview_yaw := 0.0

func _ready() -> void:
	add_to_group("menu_overlay")
	# the menu always needs a visible cursor to click buttons — make sure nothing
	# (like a camera that captured the mouse) leaves it hidden here
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# re-show this menu when a finished match returns to the title
	if not Events.returned_to_menu.is_connected(_on_returned_to_menu):
		Events.returned_to_menu.connect(_on_returned_to_menu)
	# re-show this menu when settings (opened from here) are closed
	if not Events.settings_closed_standalone.is_connected(_on_settings_closed):
		Events.settings_closed_standalone.connect(_on_settings_closed)
	if has_node("Panel"):
		$Panel.visible = false
	# The menu background is now a LIVE orbiting view of the field (set up by
	# Main), so make the old solid BG transparent and lay a gentle blur + a soft
	# dark tint over it for text legibility.
	if has_node("BG"):
		$BG.color = Color(0.10, 0.16, 0.28, 0.0)   # transparent — show the live field
	_build_blur_layer()
	_build_ui()
	_show_step(Step.LANDING)

## The menu shows the raw skycam backdrop, exactly like the splash — no tint, no
## fisheye. (A legibility tint used to darken the view here; it made the handoff
## from the splash visibly dim, so it's gone. Title/buttons carry their own
## outlines and panels for readability.)
func _build_blur_layer() -> void:
	pass

func _build_ui() -> void:
	_root = VBoxContainer.new()
	_root.set_anchors_preset(Control.PRESET_CENTER)
	_root.custom_minimum_size = Vector2(440, 0)
	_root.position = Vector2(-220, -200)
	_root.add_theme_constant_override("separation", 14)
	add_child(_root)

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 52)
	_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))   # warm schoolyard gold
	_title.add_theme_color_override("font_outline_color", Color(0.1, 0.1, 0.2))
	_title.add_theme_constant_override("outline_size", 10)
	_root.add_child(_title)

	# gold underline under the title (matches the splash), with a thin black trim.
	_title_underline = _make_title_underline()
	_root.add_child(_title_underline)

	_subtitle = Label.new()
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_font_size_override("font_size", 18)
	_subtitle.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	_root.add_child(_subtitle)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	_root.add_child(spacer)

	_options = VBoxContainer.new()
	_options.add_theme_constant_override("separation", 10)
	_root.add_child(_options)

	_back_btn = Button.new()
	_back_btn.text = "Back"
	_back_btn.custom_minimum_size = Vector2(120, 36)
	_back_btn.pressed.connect(_on_back)
	_root.add_child(_back_btn)

	_build_preview()

## A left-side panel with a 3D model on a turntable you can drag to spin 360°.
func _build_preview() -> void:
	var box_w := 320.0
	var box_h := 440.0
	var box_x := 70.0
	var box_y := 150.0

	# framing background behind the viewport — use a fixed rect via offsets only
	# (no anchor preset, which was fighting the explicit size and overriding it)
	var frame := Panel.new()
	frame.anchor_left = 0.0
	frame.anchor_top = 0.0
	frame.anchor_right = 0.0
	frame.anchor_bottom = 0.0
	frame.offset_left = box_x
	frame.offset_top = box_y
	frame.offset_right = box_x + box_w
	frame.offset_bottom = box_y + box_h
	var fs := StyleBoxFlat.new()
	fs.bg_color = Color(0.05, 0.09, 0.15, 0.95)
	fs.border_color = Color(0.4, 0.65, 0.95, 0.9)
	fs.set_border_width_all(3)
	fs.set_corner_radius_all(12)
	frame.add_theme_stylebox_override("panel", fs)
	frame.visible = false
	add_child(frame)
	_preview_frame = frame

	# the viewport container, sized to match the frame interior exactly
	_preview_box = SubViewportContainer.new()
	_preview_box.anchor_left = 0.0
	_preview_box.anchor_top = 0.0
	_preview_box.anchor_right = 0.0
	_preview_box.anchor_bottom = 0.0
	_preview_box.offset_left = box_x + 4
	_preview_box.offset_top = box_y + 4
	_preview_box.offset_right = box_x + box_w - 4
	_preview_box.offset_bottom = box_y + box_h - 4
	_preview_box.stretch = true
	_preview_box.clip_contents = true
	_preview_box.visible = false
	add_child(_preview_box)

	_preview_vp = SubViewport.new()
	_preview_vp.size = Vector2i(int(box_w) - 8, int(box_h) - 8)
	_preview_vp.transparent_bg = true
	_preview_vp.own_world_3d = true
	_preview_box.add_child(_preview_vp)

	# camera framed to fit a whole kid model head-to-toe (model scaled x5 below,
	# so it stands roughly 0..10 units tall; aim the camera at mid-torso)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 5.5, 26)        # back far enough to see head-to-toe
	cam.rotation.x = deg_to_rad(-4)           # nearly level, aimed at mid-body
	cam.fov = 42
	_preview_vp.add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-45), deg_to_rad(40), 0)
	light.light_energy = 1.3
	_preview_vp.add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation = Vector3(deg_to_rad(-20), deg_to_rad(-130), 0)
	fill.light_energy = 0.5
	_preview_vp.add_child(fill)
	_preview_holder = Node3D.new()
	_preview_vp.add_child(_preview_holder)
	_preview_box.gui_input.connect(_on_preview_input)

func _clear_options() -> void:
	for c in _options.get_children():
		c.queue_free()
	# also tear down the free-positioned character-select layer, if present
	if _model_layer != null and is_instance_valid(_model_layer):
		_model_layer.queue_free()
	_model_layer = null
	_model_grid = null
	_model_cards = {}
	_model_name_label = null
	_start_btn = null
	_card_team = {}
	_blue_btn = null
	_red_btn = null
	_shot_queue.clear()

func _make_button(label: String) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(460, 58)
	b.add_theme_font_size_override("font_size", 24)
	b.add_theme_color_override("font_color", Color(1, 1, 1))
	b.add_theme_color_override("font_color_hover", Color(1.0, 0.95, 0.6))
	b.add_theme_color_override("font_outline_color", Color(0.1, 0.1, 0.15))
	b.add_theme_constant_override("outline_size", 4)
	# chunky rounded "playground sign" styling, with a lively hover
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.16, 0.35, 0.62, 0.95)
	normal.set_corner_radius_all(14)
	normal.set_border_width_all(3)
	normal.border_color = Color(0.3, 0.55, 0.85)
	normal.content_margin_left = 18
	normal.content_margin_right = 18
	var hover := normal.duplicate()
	hover.bg_color = Color(0.22, 0.48, 0.78, 1.0)
	hover.border_color = Color(1.0, 0.85, 0.35)
	var pressed := normal.duplicate()
	pressed.bg_color = Color(0.12, 0.28, 0.5, 1.0)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", hover)
	_options.add_child(b)
	return b

## Play the intro when the splash hands off: fade the subtitle + buttons in,
## staggered, so they appear to surface under the title. We only animate ALPHA —
## these live inside a VBoxContainer that owns their positions, so animating
## position would fight the layout (that caused the stacked/overlapping bug).
## Build the gold-with-black-trim underline that sits under the menu title.
## Both bars are centered horizontally in the box via center anchors (no manual
## offset fighting), so it stays put wherever the VBox places the container.
func _make_title_underline() -> Control:
	var ul_box := Control.new()
	ul_box.custom_minimum_size = Vector2(300, 14)
	ul_box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var trim := ColorRect.new()
	trim.color = Color(0.1, 0.1, 0.2)
	trim.custom_minimum_size = Vector2(272, 10)
	# anchor to the box's horizontal+vertical center, then offset by half-size so
	# the rect is centered. anchors 0.5 on all sides = a point at center; the
	# offsets expand it symmetrically.
	trim.anchor_left = 0.5
	trim.anchor_right = 0.5
	trim.anchor_top = 0.5
	trim.anchor_bottom = 0.5
	trim.offset_left = -136.0
	trim.offset_right = 136.0
	trim.offset_top = -5.0
	trim.offset_bottom = 5.0
	trim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ul_box.add_child(trim)

	var line := ColorRect.new()
	line.color = Color(1.0, 0.85, 0.3)
	line.anchor_left = 0.5
	line.anchor_right = 0.5
	line.anchor_top = 0.5
	line.anchor_bottom = 0.5
	line.offset_left = -132.0
	line.offset_right = 132.0
	line.offset_top = -3.0
	line.offset_bottom = 3.0
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ul_box.add_child(line)
	return ul_box

## Receive the splash screen's flown-in title node and keep it as our title. The
## exact letters that fell become the menu title (seamless — no second title to
## match). Our own Label title + underline are hidden; the adopted node floats over
## the reserved title space. Buttons/subtitle then fade in beneath it.
var _adopted_title: Control = null

func adopt_splash_title(title_node: Control) -> void:
	_adopted_title = title_node
	add_child(title_node)
	# hide our own title + underline; the adopted letters stand in for them
	if _title != null:
		_title.modulate.a = 0.0
	if _title_underline != null:
		_title_underline.modulate.a = 0.0

func play_intro() -> void:
	if _step != Step.LANDING:
		return
	# NOTE: no await before the alpha-zeroing below. An awaited frame here let the
	# menu render fully visible for exactly one frame (own title stacked on the
	# adopted splash title, buttons at full alpha) before snapping hidden — that
	# was the split-second flash between splash and menu. Alpha-only animation
	# needs no layout wait, so everything is zeroed synchronously.
	var adopted := _adopted_title != null
	# If the splash handed us its title, keep our own title + underline hidden (the
	# adopted letters ARE the title). Otherwise show our own title instantly.
	if _title != null:
		_title.modulate.a = 0.0 if adopted else 1.0
		_title.scale = Vector2(1, 1)
	if _title_underline != null and adopted:
		_title_underline.modulate.a = 0.0
	var targets: Array = []
	if _title_underline != null and not adopted:
		targets.append(_title_underline)
	if _subtitle != null:
		targets.append(_subtitle)
	if _options != null:
		for c in _options.get_children():
			targets.append(c)
	for i in range(targets.size()):
		var node: CanvasItem = targets[i]
		node.modulate.a = 0.0
		var t := create_tween()
		t.tween_interval(0.12 + 0.09 * float(i))
		t.tween_property(node, "modulate:a", 1.0, 0.4)

func _show_step(step: int) -> void:
	_step = step
	_clear_options()
	_set_preview_visible(false)
	_back_btn.visible = (step != Step.LANDING)
	# The MODEL step uses a full-screen custom layout (viewer + headshot grid) built
	# in _model_layer, so hide the centered title/subtitle/options/back stack to
	# avoid overlap. All other steps use that centered stack normally.
	var use_root := step != Step.MODEL
	_title.visible = use_root
	# the adopted splash-title letters are a SEPARATE node from _title, so they need
	# their own visibility gate — otherwise "Recess Raiders" shows behind the
	# character-select box on the MODEL step.
	if _adopted_title != null:
		_adopted_title.visible = (step == Step.LANDING)
	# reset transforms/opacity to defaults; play_intro (if it runs) re-animates them
	_title.modulate.a = 1.0
	_title.scale = Vector2(1, 1)
	if _title_underline != null:
		_title_underline.visible = use_root and step == Step.LANDING
		_title_underline.modulate.a = 1.0
	_subtitle.visible = use_root
	_subtitle.modulate.a = 1.0
	_options.visible = use_root
	_back_btn.visible = use_root and (step != Step.LANDING)
	match step:
		Step.LANDING:
			_title.text = "RECESS RAIDERS"
			_subtitle.text = "Schoolyard mayhem"
			var play := _make_button("Play")
			play.pressed.connect(func(): _show_step(Step.MODEL))
			var settings_btn := _make_button("Settings")
			settings_btn.pressed.connect(func():
				hide()
				Events.open_settings_request.emit())
			var quit := _make_button("Quit")
			quit.pressed.connect(func(): get_tree().quit())
		Step.MODEL:
			# title/name/grid/back/start are all built inside _model_layer
			_set_preview_visible(true)
			_build_model_grid()

# ============================================================================
# CHARACTER SELECT GRID (AAA-style): a grid of model cards to the right of the
# big rotating viewer. Hover = pop/highlight, click = select (outline) + update
# the viewer + name label + enable Start. Cards are data-driven from the team's
# CharacterDefs, so new models appear automatically.
# ============================================================================
func _build_model_grid() -> void:
	_model_cards = {}
	# Full-screen layer (base 1280x720). Viewer left (x:70-390); character panel in
	# the right zone. Shows ALL models from BOTH teams; the chosen team's cards are
	# active, the other team's are greyed out. Team buttons sit under the viewer.
	var layer := Control.new()
	layer.name = "ModelSelectLayer"
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(layer)
	_model_layer = layer

	# Work out the roster + slot count first, so the backing panel can size to fit
	# however many rows we need. ALL models, grouped blue then red, sorted by id.
	var ordered: Array = []
	for tm in ["blue", "red"]:
		var td: Array = CharacterDefs.defs_for_team(tm)
		td.sort_custom(func(da, db): return String(da.id) < String(db.id))
		for d in td:
			ordered.append([String(d.id), d.display_name, tm])
	var real_count: int = ordered.size()
	# fixed grid capacity (full 14-v-14 roster = 28 slots). Roster fills into it,
	# remainder are greyed placeholders. Oversized rosters round up to a full row.
	var slot_count: int = MODEL_SLOTS
	if real_count > slot_count:
		slot_count = real_count
	var grid_cols: int = 7                          # 7x4 = 28 fits the box well
	if slot_count % grid_cols != 0:
		slot_count += grid_cols - (slot_count % grid_cols)
	var grid_rows: int = int(ceil(float(slot_count) / float(grid_cols)))

	# Fit the grid inside the box: max width ~760 (panel is 810 wide w/ padding),
	# max height ~350 (above the team buttons). Compute the largest card that fits
	# both, keeping the ~132:148 aspect. Cards are headshot-only at this density.
	var gap := 8.0
	var avail_w := 760.0
	var max_grid_h := 330.0
	var card_w: float = (avail_w - (grid_cols - 1) * gap) / float(grid_cols)
	var card_h: float = card_w * 148.0 / 132.0
	var grid_h: float = grid_rows * card_h + max(grid_rows - 1, 0) * gap
	if grid_h > max_grid_h and grid_rows > 0:
		var fit_scale: float = max_grid_h / grid_h
		card_w *= fit_scale
		card_h *= fit_scale
		grid_h = grid_rows * card_h + max(grid_rows - 1, 0) * gap
	var panel_h: float = grid_h + 90.0             # room for the name label on top

	# backing panel behind the name + full grid, sized to the row count
	var backing := Panel.new()
	backing.position = Vector2(430, 150)
	backing.size = Vector2(810, panel_h)
	backing.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bs := StyleBoxFlat.new()
	bs.bg_color = Color(0.06, 0.09, 0.15, 0.82)
	bs.set_corner_radius_all(16)
	bs.set_border_width_all(2)
	bs.border_color = Color(0.4, 0.6, 0.9, 0.5)
	backing.add_theme_stylebox_override("panel", bs)
	layer.add_child(backing)

	# title — centered across the whole screen
	var title := Label.new()
	title.text = "SELECT YOUR CHARACTER"
	title.position = Vector2(0, 40)
	title.size = Vector2(1280, 60)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	title.add_theme_color_override("font_outline_color", Color(0.1, 0.1, 0.2))
	title.add_theme_constant_override("outline_size", 8)
	layer.add_child(title)

	# selected model name — inside the top of the backing panel
	_model_name_label = Label.new()
	_model_name_label.position = Vector2(430, 162)
	_model_name_label.size = Vector2(810, 34)
	_model_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_model_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_model_name_label.add_theme_font_size_override("font_size", 24)
	_model_name_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
	_model_name_label.add_theme_color_override("font_outline_color", Color(0.05, 0.08, 0.12))
	_model_name_label.add_theme_constant_override("outline_size", 5)
	layer.add_child(_model_name_label)

	# ALL models, grouped blue then red, each sorted by id. _card_team tracks which
	# team each card belongs to so we can grey out the non-selected team.
	_card_team = {}

	# grid: 4 columns, centered in the panel
	_model_grid = GridContainer.new()
	_model_grid.columns = grid_cols
	_model_grid.add_theme_constant_override("h_separation", int(gap))
	_model_grid.add_theme_constant_override("v_separation", int(gap))
	layer.add_child(_model_grid)

	for entry in ordered:
		var id: String = entry[0]
		var lbl: String = entry[1]
		var tm: String = entry[2]
		var card := _make_model_card(id, lbl, card_w, card_h)
		_model_grid.add_child(card)
		_model_cards[id] = card
		_card_team[id] = tm

	# Pad with greyed placeholder boxes to reach the even slot_count (>= 1 spare)
	# computed above. Adding a new model just fills the next empty slot.
	for i in range(slot_count - real_count):
		_model_grid.add_child(_make_empty_slot(card_w, card_h))

	# center the grid within the panel (panel center x=835).
	var cols_used: int = min(slot_count, grid_cols)
	var row_w: float = cols_used * card_w + max(cols_used - 1, 0) * gap
	_model_grid.position = Vector2(835.0 - row_w * 0.5, 205.0)

	# --- team buttons under the viewer (mockup places them here) ---
	_blue_btn = _make_team_button("Blue Team", Color(0.25, 0.5, 0.95))
	_blue_btn.position = Vector2(70, 605)
	_blue_btn.pressed.connect(func(): _pick_team_in_place("blue"))
	layer.add_child(_blue_btn)
	_red_btn = _make_team_button("Red Team", Color(0.95, 0.4, 0.35))
	_red_btn.position = Vector2(232, 605)
	_red_btn.pressed.connect(func(): _pick_team_in_place("red"))
	layer.add_child(_red_btn)

	# Back bottom-left, Start bottom-right
	var back := Button.new()
	back.text = "Back"
	back.position = Vector2(70, 662)
	back.custom_minimum_size = Vector2(140, 44)
	back.add_theme_font_size_override("font_size", 20)
	back.pressed.connect(_on_back)
	layer.add_child(back)

	_start_btn = Button.new()
	_start_btn.text = "Start"
	_start_btn.position = Vector2(1070, 655)
	_start_btn.custom_minimum_size = Vector2(150, 50)
	_start_btn.add_theme_font_size_override("font_size", 22)
	_start_btn.pressed.connect(_on_start_pressed)
	layer.add_child(_start_btn)

	# apply the current team (greys the other side + selects a default model)
	_pick_team_in_place(_team)

## A team toggle button (Blue / Red), styled with the team's accent.
func _make_team_button(label: String, accent: Color) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(150, 44)
	b.add_theme_font_size_override("font_size", 18)
	var s := StyleBoxFlat.new()
	s.bg_color = accent.darkened(0.3)
	s.set_corner_radius_all(10)
	s.set_border_width_all(2)
	s.border_color = accent
	b.add_theme_stylebox_override("normal", s)
	return b

## Choose a team without leaving the page: highlight the team button, grey out the
## other team's cards, and select a default model from the chosen team.
func _pick_team_in_place(tm: String) -> void:
	_team = tm
	# Both team buttons stay fully opaque — only the OPPOSITE team's character cards
	# grey out. The active team is shown by a brighter border (set in
	# _style_team_button), not by dimming the other button.
	if _blue_btn != null:
		_blue_btn.modulate = Color(1, 1, 1, 1)
		_style_team_button(_blue_btn, Color(0.25, 0.5, 0.95), tm == "blue")
	if _red_btn != null:
		_red_btn.modulate = Color(1, 1, 1, 1)
		_style_team_button(_red_btn, Color(0.95, 0.4, 0.35), tm == "red")
	# enable this team's cards, grey/disable the other team's
	var first_id := ""
	for cid in _model_cards.keys():
		var c: Button = _model_cards[cid]
		var mine: bool = _card_team.get(cid, "") == tm
		c.disabled = not mine
		c.modulate = Color(1, 1, 1, 1) if mine else Color(0.5, 0.5, 0.55, 0.6)
		if mine and first_id == "":
			first_id = cid
	# select a default model from this team
	if first_id != "":
		_select_model_card(first_id)

## Style a team button — full opacity always; the active one gets a bright thick
## border + filled background, the inactive one a subtler outline. This is how we
## show which team is selected without dimming either button.
func _style_team_button(btn: Button, accent: Color, active: bool) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = accent.darkened(0.15) if active else accent.darkened(0.55)
	s.set_corner_radius_all(10)
	s.set_border_width_all(4 if active else 2)
	s.border_color = accent.lightened(0.3) if active else accent.darkened(0.2)
	btn.add_theme_stylebox_override("normal", s)
	btn.add_theme_stylebox_override("hover", s)
	btn.add_theme_stylebox_override("pressed", s)

## An empty greyed-out placeholder slot — a spare box that keeps the grid at an
## even count. Not clickable; fills in automatically when a new model is added.
func _make_empty_slot(cw: float = 132.0, ch: float = 148.0) -> Control:
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(cw, ch)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.1, 0.12, 0.16, 0.5)
	s.set_corner_radius_all(12)
	s.set_border_width_all(2)
	s.border_color = Color(1, 1, 1, 0.08)
	slot.add_theme_stylebox_override("panel", s)
	# a faint "+" hint that this is an open slot
	var plus := Label.new()
	plus.text = "+"
	plus.set_anchors_preset(Control.PRESET_FULL_RECT)
	plus.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plus.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	plus.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plus.add_theme_font_size_override("font_size", 40)
	plus.add_theme_color_override("font_color", Color(1, 1, 1, 0.12))
	slot.add_child(plus)
	return slot

## One model card: a headshot thumbnail (rendered once via the snapshot viewport)
## with the name beneath it. Pops on hover, gold outline when selected.
func _make_model_card(id: String, label: String, cw: float = 132.0, ch: float = 148.0) -> Button:
	var card := Button.new()
	card.custom_minimum_size = Vector2(cw, ch)
	card.add_theme_stylebox_override("normal", _card_style(false, false))
	card.add_theme_stylebox_override("hover", _card_style(true, false))
	card.add_theme_stylebox_override("pressed", _card_style(true, true))
	card.add_theme_stylebox_override("focus", _card_style(true, false))
	card.pressed.connect(func(): _select_model_card(id))
	card.mouse_entered.connect(func(): _set_preview_model(_team, id))

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.add_theme_constant_override("separation", 2)
	card.add_child(vb)

	# small cards (dense 28-slot grid) are headshot-only; larger cards also show
	# the name beneath. The selected model's name always shows in the big label up top.
	var show_name := cw >= 110.0
	# the headshot image (filled in by _render_headshot). Fills the card.
	var tex := TextureRect.new()
	tex.name = "Shot"
	tex.custom_minimum_size = Vector2(cw - 10.0, ch - (26.0 if show_name else 8.0))
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(tex)

	if show_name:
		var nm := Label.new()
		nm.text = label
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nm.add_theme_font_size_override("font_size", 13)
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(nm)

	# render the headshot into `tex` (deferred so the card is in-tree first)
	_render_headshot.call_deferred(id, tex)
	return card

## Card background style. highlight = hover pop (brighter), selected = accent
## outline so the picked card is clearly indicated.
func _card_style(highlight: bool, selected: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	var team_accent := Color(0.3, 0.55, 0.95) if _team == "blue" else Color(0.95, 0.4, 0.35)
	s.bg_color = Color(0.12, 0.16, 0.24, 0.96) if not highlight else Color(0.18, 0.24, 0.34, 1.0)
	s.set_corner_radius_all(12)
	# UNIFORM border width (3) and content margins for every state — varying the
	# border width shifted the content box, which made the selected card's headshot
	# render at a different size than the rest. Selection/hover are shown by border
	# COLOR only, not width, so all headshots stay identical in size and position.
	s.set_border_width_all(3)
	if selected:
		s.border_color = Color(1.0, 0.85, 0.35)      # gold selected outline
	elif highlight:
		s.border_color = team_accent
	else:
		s.border_color = Color(1, 1, 1, 0.15)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	return s

func _select_model_card(id: String) -> void:
	_selected_model_id = id
	# restyle all cards: only the selected one gets the gold outline
	for cid in _model_cards.keys():
		var c: Button = _model_cards[cid]
		var is_sel: bool = cid == id
		c.add_theme_stylebox_override("normal", _card_style(is_sel, is_sel))
	# update the viewer + name label
	_set_preview_model(_team, id)
	if _model_name_label != null:
		var def: CharacterDef = CharacterDefs.get_def(id)
		_model_name_label.text = def.display_name if def != null else id
	if _start_btn != null:
		_start_btn.disabled = false

func _on_start_pressed() -> void:
	if _selected_model_id == "":
		return
	_model = _selected_model_id
	# difficulty is fixed to casual for now (the selection step is removed), so
	# Start launches straight into the match.
	_diff = "casual"
	_launch()

# ---- headshot snapshotter --------------------------------------------------
# A single reusable SubViewport renders each model's HEAD to a texture, one at a
# time, so cards get real front-facing headshots WITHOUT 8 permanent live
# viewports. Each render loads the base model, frames the head, waits a couple
# frames for the render, then copies the image into the card's TextureRect.
var _shot_vp: SubViewport = null
var _shot_holder: Node3D = null
var _shot_cam: Camera3D = null
var _shot_busy := false
var _shot_queue: Array = []        # [ [id, TextureRect], ... ]

func _ensure_shot_viewport() -> void:
	if _shot_vp != null:
		return
	_shot_vp = SubViewport.new()
	_shot_vp.size = Vector2i(160, 160)
	_shot_vp.transparent_bg = true
	_shot_vp.own_world_3d = true
	_shot_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_shot_vp)
	var cam := Camera3D.new()
	# Fixed head framing. Base models are ~1.7 units tall (x5 ≈ 8.5) with feet at
	# y≈0, so the head sits near y≈8. Put the camera at head height and aim it at the
	# head so the shot is head+shoulders, not cropped. (No AABB auto-frame — skinned
	# bounds on these rigs are unreliable and pointed the camera at the feet.)
	cam.position = Vector3(0, 7.8, 7.2)
	cam.fov = 34
	_shot_cam = cam
	_shot_vp.add_child(cam)
	cam.look_at(Vector3(0, 7.4, 0), Vector3.UP)   # after in-tree so the basis is valid
	var key := DirectionalLight3D.new()
	key.rotation = Vector3(deg_to_rad(-30), deg_to_rad(35), 0)
	key.light_energy = 1.4
	_shot_vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation = Vector3(deg_to_rad(-10), deg_to_rad(-120), 0)
	fill.light_energy = 0.5
	_shot_vp.add_child(fill)
	_shot_holder = Node3D.new()
	_shot_vp.add_child(_shot_holder)

## Queue a headshot render for model `id` into `target`. Renders serially.
func _render_headshot(id: String, target: TextureRect) -> void:
	_shot_queue.append([id, target])
	if not _shot_busy:
		_process_shot_queue()

func _process_shot_queue() -> void:
	if _shot_queue.is_empty():
		_shot_busy = false
		return
	_shot_busy = true
	var job: Array = _shot_queue.pop_front()
	var id: String = job[0]
	var target: TextureRect = job[1]
	# target card gone (left the step)? skip to next.
	if not is_instance_valid(target):
		_process_shot_queue()
		return
	_ensure_shot_viewport()

	# clear any previous model
	if is_instance_valid(_shot_holder):
		for c in _shot_holder.get_children():
			c.queue_free()

	var def: CharacterDef = CharacterDefs.get_def(id)
	var path := def.base_model_path if def != null and def.base_model_path != "" else ""
	if path == "" or not ResourceLoader.exists(path):
		_process_shot_queue()
		return
	var scene: PackedScene = load(path)
	if scene == null:
		_process_shot_queue()
		return
	var m: Node3D = scene.instantiate()
	m.scale = Vector3(5, 5, 5)
	_shot_holder.add_child(m)

	# The base GLB's only animation is its static bind pose (a T-pose), so a raw
	# instance photographs arms-out. Pull in the model's WALK clip (same trick the
	# live left-panel preview uses) and pose it a little way in — mid-stride has the
	# arms naturally down at the sides, which reads as a clean headshot.
	var walk_path := _preview_walk_path(_team, id, def)
	var walk_name := _preview_walk_anim_name(def)
	_pose_shot_model(m, walk_path, walk_name)

	# Let the pose apply, then frame the camera on this model's ACTUAL Head bone.
	# Models differ in origin/height, so a fixed camera framed each differently
	# (some wide, some cropped). Mesh AABBs were unreliable for this, but the
	# skeleton's Head bone world position is exact once the pose has applied.
	await get_tree().process_frame
	if is_instance_valid(m) and is_instance_valid(_shot_cam):
		# Frame from TWO bones: Head (neck/chin) and head_end (crown). Their span is
		# this model's actual head size, so we set the camera distance PROPORTIONAL
		# to it — every head then fills the same fraction of the frame (fixing the
		# some-wide/some-tight variance), with guaranteed headroom above the crown
		# (fixing the clipped hair).
		var skel := _find_skeleton(m)
		var center := Vector3(0, 7.4, 0)
		var dist := 7.2
		if skel != null:
			var bi: int = skel.find_bone("Head")
			var ti: int = skel.find_bone("head_end")
			if bi != -1 and ti != -1:
				var hp: Vector3 = (skel.global_transform * skel.get_bone_global_pose(bi)).origin
				var tp: Vector3 = (skel.global_transform * skel.get_bone_global_pose(ti)).origin
				var head_h: float = maxf(tp.y - hp.y, 0.5)
				center = Vector3(0, (tp.y + hp.y) * 0.5, 0)
				# distance scales with head size: head fills ~42% of frame height —
				# close enough to read faces easily, still with crown headroom
				dist = 3.1 * head_h + 1.0
			elif bi != -1:
				var hp2: Vector3 = (skel.global_transform * skel.get_bone_global_pose(bi)).origin
				center = Vector3(0, hp2.y + 0.5, 0)
		_shot_cam.position = Vector3(0, center.y + 0.15, dist)
		_shot_cam.look_at(center, Vector3.UP)

	# a couple more frames for the framed render, then capture
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(target) and is_instance_valid(_shot_vp):
		var img := _shot_vp.get_texture().get_image()
		if img != null and not img.is_empty():
			target.texture = ImageTexture.create_from_image(img)
	_process_shot_queue()

## First Skeleton3D under a node (the rigs have exactly one).
func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null

## Pose a headshot model out of its T-pose by loading its walk clip and parking it
## at a mid-stride frame (arms down). Mirrors _play_preview_walk but pauses on a
## frame instead of looping, since a headshot is a still.
func _pose_shot_model(model: Node, walk_path: String, walk_name: String) -> void:
	var ap := _find_anim_player(model)
	if ap == null:
		return
	if walk_path != "" and ResourceLoader.exists(walk_path):
		var src_scene: PackedScene = load(walk_path)
		if src_scene != null:
			var src_inst := src_scene.instantiate()
			var src_ap := _find_anim_player(src_inst)
			if src_ap != null:
				for lib_name in src_ap.get_animation_library_list():
					var lib := src_ap.get_animation_library(lib_name)
					for anim_name in lib.get_animation_list():
						if anim_name == walk_name:
							var clip: Animation = lib.get_animation(anim_name).duplicate()
							var dst_lib := AnimationLibrary.new()
							dst_lib.add_animation("pose", clip)
							if ap.has_animation_library("shot"):
								ap.remove_animation_library("shot")
							ap.add_animation_library("shot", dst_lib)
							ap.play("shot/pose")
							# park at ~25% through the stride: arms at sides, not T
							ap.seek(clip.length * 0.25, true)
							ap.pause()
							src_inst.queue_free()
							return
			src_inst.queue_free()
	# fallback: play whatever shipped, so at least it's not a hard T-pose
	var list := ap.get_animation_list()
	if list.size() > 0:
		ap.play(list[0])
		ap.seek(0.1, true)
		ap.pause()

## (Removed _model_aabb/_all_mesh_instances — headshot framing is fixed, not
## AABB-derived, since skinned-mesh bounds on these rigs were unreliable.)

func _set_preview_model(team: String, id: String) -> void:
	if _preview_holder == null:
		return
	if _preview_model != null and is_instance_valid(_preview_model):
		_preview_model.queue_free()
		_preview_model = null
	var path := ""
	# If this id is a CharacterDef, preview its BASE model (the one with the mesh).
	# The clip GLBs are animation-only (mesh stripped to cut file size), so loading
	# a clip here would show an invisible model — always use the base for preview.
	var def: CharacterDef = CharacterDefs.get_def(id)
	if def != null and def.base_model_path != "":
		path = def.base_model_path
	elif team == "blue":
		path = "res://assets/character/blueboy/blueboy_alert.glb"
	elif id == "girl":
		path = "res://assets/character/girl/girl_alert.glb"
	else:
		path = "res://assets/character/red/red_alert.glb"
	var scene: PackedScene = load(path) if ResourceLoader.exists(path) else null
	if scene == null:
		return
	_preview_model = scene.instantiate()
	_preview_model.position = Vector3(0, 0, 0)
	_preview_model.scale = Vector3(5, 5, 5)
	_preview_holder.add_child(_preview_model)
	# Pull the WALK clip into the model's own AnimationPlayer and loop it, so the
	# preview shows the kid walking on the spot instead of standing in the GLB's
	# default bind pose (the T-pose). Works for def-driven (blue) and the legacy
	# red/girl previews alike. Deferred so the instanced scene is fully in-tree.
	var walk_path := _preview_walk_path(team, id, def)
	var walk_name := _preview_walk_anim_name(def)
	call_deferred("_play_preview_walk", _preview_model, walk_path, walk_name)

## Resolve the GLB that holds this preview's walk animation.
func _preview_walk_path(team: String, id: String, def: CharacterDef) -> String:
	if def != null and def.clip_paths.has("walk"):
		return def.clip_paths["walk"]
	# legacy (no def yet): red boy / red girl walk clips
	if id == "girl":
		return "res://assets/character/girl/girl_walk.glb"
	if team == "red":
		return "res://assets/character/red/red_walk.glb"
	return "res://assets/character/blueboy/blueboy_walk.glb"

## The internal animation name inside that walk GLB.
func _preview_walk_anim_name(def: CharacterDef) -> String:
	if def != null and def.clip_anim_names.has("walk"):
		return def.clip_anim_names["walk"]
	return "Armature|walking_man|baselayer"

## Harvest the walk animation from walk_path and loop it on the preview model.
## Falls back to the model's own first animation if the walk clip can't be found,
## so a missing clip degrades to the old behavior rather than nothing.
func _play_preview_walk(model: Node, walk_path: String, walk_name: String) -> void:
	var ap := _find_anim_player(model)
	if ap == null:
		return
	if walk_path != "" and ResourceLoader.exists(walk_path):
		var src_scene: PackedScene = load(walk_path)
		if src_scene != null:
			var src_inst := src_scene.instantiate()
			var src_ap := _find_anim_player(src_inst)
			if src_ap != null:
				for lib_name in src_ap.get_animation_library_list():
					var lib := src_ap.get_animation_library(lib_name)
					for anim_name in lib.get_animation_list():
						if anim_name == walk_name:
							var clip: Animation = lib.get_animation(anim_name).duplicate()
							clip.loop_mode = Animation.LOOP_LINEAR
							var dst_lib := AnimationLibrary.new()
							dst_lib.add_animation("walk", clip)
							if ap.has_animation_library("preview"):
								ap.remove_animation_library("preview")
							ap.add_animation_library("preview", dst_lib)
							src_inst.queue_free()
							ap.play("preview/walk")
							return
			src_inst.queue_free()
	# fallback: play whatever the model shipped with (old behavior)
	var list := ap.get_animation_list()
	if list.size() > 0:
		ap.play(list[0])

func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for c in node.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null

func _on_preview_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_preview_dragging = event.pressed
	elif event is InputEventMouseMotion and _preview_dragging:
		_preview_yaw -= event.relative.x * 0.01
		if _preview_holder != null:
			_preview_holder.rotation.y = _preview_yaw

func _process(delta: float) -> void:
	if _preview_holder != null and _preview_box != null and _preview_box.visible \
			and not _preview_dragging:
		_preview_yaw += delta * 0.5
		_preview_holder.rotation.y = _preview_yaw

func _set_preview_visible(v: bool) -> void:
	if _preview_box != null:
		_preview_box.visible = v
	if _preview_frame != null:
		_preview_frame.visible = v

func _on_back() -> void:
	match _step:
		Step.MODEL: _show_step(Step.LANDING)

func _launch() -> void:
	Config.ai_difficulty = _diff
	GameState.mode = _mode
	GameState.player_model = _model
	GameState.menu_open = false
	join_requested.emit(_team, "fp")
	hide()

## Re-show the menu when a finished match returns to the title (Main Menu button).
func _on_returned_to_menu() -> void:
	show()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show_step(Step.LANDING)

## Re-show the menu after standalone settings (opened from the menu) are closed.
func _on_settings_closed() -> void:
	show()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show_step(Step.LANDING)
