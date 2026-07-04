class_name SplashScreen
extends Control
## Startup splash: two gold "R"s fall from the top (staggered, with an inertial
## bounce), then the remaining letters of "Recess Raiders" extend rightward out of
## each R, a gold underline grows from the middle outward, and the whole thing
## fades to the menu — triggering the Welcome audio as it fades.
##
## This is NOT a physics simulation: every motion is a scripted tween so it looks
## the same every time while still reading as semi-realistic (gravity-style ease-in
## on the fall, an overshoot + settle bounce, a squash-jiggle on impact). The
## skycam demo match behind the menu shows through as the backdrop.

signal finished    ## emitted when the splash is done and the menu should take over

const GOLD := Color(1.0, 0.85, 0.3)
const TRIM := Color(0.1, 0.1, 0.2)

var _title_font_size := 84
var _root: Control            # holds all splash visuals, faded out at the end
var _letters: Array = []      # all letter labels, for cleanup
var _done := false

## Delay before the welcome voice line starts. Computed from the clip's waveform:
## the VO says "Recess" at ~0.85s into the clip, and the splash letters emerge at
## 1.8s — so 1.8 - 0.85 = 0.95 lands the phrase on the emergence. ("Raiders!" then
## hits ~2.4s, while the 'aiders' letters are still popping out.) Nudge ±0.1-0.2
## to taste.
const WELCOME_AUDIO_DELAY := 0.95

func _ready() -> void:
	# full-screen, transparent so the skycam backdrop shows through
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # eat clicks during the splash
	# Welcome voice line starts a beat after the splash so the VO's "Recess Raiders"
	# syncs with the letters emerging (~1.8s in). Connected straight to the
	# AudioManager autoload so the timer still fires even if the splash is skipped
	# and freed before the delay elapses; the _welcome_started guard keeps it
	# once-only either way. Music rolls on after the welcome clip as before.
	get_tree().create_timer(WELCOME_AUDIO_DELAY).timeout.connect(AudioManager.play_welcome_then_music)
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_run.call_deferred()

## Allow skipping the splash with any key / click.
func _unhandled_input(event: InputEvent) -> void:
	if _done:
		return
	if (event is InputEventKey and event.pressed) or (event is InputEventMouseButton and event.pressed):
		_finish()

func _run() -> void:
	var vw: float = size.x if size.x > 0 else 1280.0
	var vh: float = size.y if size.y > 0 else 720.0
	var cx := vw * 0.5
	var ground_y := vh * 0.42

	# Measure the real pixel width of each letter so spacing is natural (fixed-width
	# advance made "i" too wide and left a gap before "ders"). We build the whole
	# title "Recess Raiders" and record each glyph's x from a running cursor.
	var full := "Recess Raiders"
	var font := ThemeDB.fallback_font
	var fs := _title_font_size
	# per-letter advance widths
	var advances: Array = []
	var total_w := 0.0
	for i in range(full.length()):
		var ch := full[i]
		var adv: float = font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		# add a little tracking between letters for a titley look
		adv += 4.0
		advances.append(adv)
		total_w += adv
	# starting x so the whole title is centered
	var start_x := cx - total_w * 0.5
	# compute each letter's left x
	var xs: Array = []
	var cursor := start_x
	for i in range(full.length()):
		xs.append(cursor)
		cursor += advances[i]

	# the two R's are at index 0 and index 7 ("Recess "=7 chars incl. space)
	var r1_x: float = xs[0]
	var r2_x: float = xs[7]

	# create the two falling R's
	var r1 := _make_letter("R", Vector2(r1_x, -160.0))
	var r2 := _make_letter("R", Vector2(r2_x, -160.0))

	# --- staggered fall with wind-sway + bounce -------------------------------
	_drop_letter(r1, ground_y, 0.0)
	_drop_letter(r2, ground_y, 0.5)

	await get_tree().create_timer(1.8).timeout
	if _done: return
	# extend each tail using the measured x positions of the following letters.
	# (Was 2.8s — left an odd dead gap after the R's landed. Now fires as soon as
	# the second R settles. The R fall speed itself is untouched.)
	_extend_tail_xs(full, xs, 1, 6, ground_y)     # "ecess" = indices 1..6
	_extend_tail_xs(full, xs, 8, 13, ground_y)    # "aiders" = indices 8..13

	await get_tree().create_timer(2.0).timeout
	if _done: return
	# underline clearly BELOW the glyphs (label positions by top-left; glyphs are
	# ~fs tall, so 1.12*fs clears the descenders — matches the mockup).
	_grow_underline(cx, ground_y + float(fs) * 1.12, total_w)

	await get_tree().create_timer(1.4).timeout
	if _done: return
	_finish()

## Extend a run of letters (indices from..to inclusive) into place, each starting
## faded/offset near its owning R and sliding to its measured x. Deterministic.
func _extend_tail_xs(full: String, xs: Array, from_i: int, to_i: int, ground_y: float) -> void:
	var origin_x: float = xs[from_i] - 30.0
	var step := 0
	for i in range(from_i, to_i + 1):
		var ch := full[i]
		var final_x: float = xs[i]
		var l := _make_letter(ch, Vector2(origin_x, ground_y))
		l.modulate.a = 0.0
		var t := create_tween()
		t.tween_interval(0.11 * float(step))
		t.set_parallel(true)
		t.tween_property(l, "position:x", final_x, 0.5).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		t.tween_property(l, "modulate:a", 1.0, 0.42)
		step += 1

## Make a title letter label at a start position.
func _make_letter(ch: String, pos: Vector2) -> Label:
	var l := Label.new()
	l.text = ch
	l.position = pos
	l.add_theme_font_size_override("font_size", _title_font_size)
	l.add_theme_color_override("font_color", GOLD)
	l.add_theme_color_override("font_outline_color", TRIM)
	l.add_theme_constant_override("outline_size", 10)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.pivot_offset = Vector2(float(_title_font_size) * 0.3, float(_title_font_size) * 0.5)
	_root.add_child(l)
	_letters.append(l)
	return l

## Drop a letter from its current y to ground_y. Heavy-object feel: a decisive,
## accelerating plunge (strong ease-in), a sharp impact squash, and a small crisp
## bounce — not a slow leaf-like float. `delay` staggers the two R's.
func _drop_letter(letter: Label, ground_y: float, delay: float) -> void:
	var fall_time := 0.85            # quicker, weightier plunge (was a floaty 1.5)
	var base_x := letter.position.x
	var t := create_tween()
	t.tween_interval(delay)
	# strong gravity-style acceleration: EXPO ease-in reads as real heavy falling
	t.tween_property(letter, "position:y", ground_y + 12.0, fall_time).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_EXPO)
	# sharp squash on impact
	t.tween_callback(func(): _impact_squash(letter))
	# small crisp bounce, then settle (short = heavy, not springy)
	t.tween_property(letter, "position:y", ground_y - 12.0, 0.16).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	t.tween_property(letter, "position:y", ground_y, 0.20).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)

	# a SMALL air wobble — just enough surface-area drift to not be robotic, but not
	# leaf-like. Tight amplitude, resolves well before impact.
	var sway := create_tween()
	sway.tween_interval(delay)
	sway.tween_property(letter, "position:x", base_x - 7.0, fall_time * 0.4).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	sway.tween_property(letter, "position:x", base_x, fall_time * 0.6).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)

## A quick squash-and-recover scale jiggle to sell the impact.
func _impact_squash(letter: Label) -> void:
	var t := create_tween()
	letter.scale = Vector2(1.28, 0.72)
	t.tween_property(letter, "scale", Vector2(0.9, 1.12), 0.12).set_trans(Tween.TRANS_SINE)
	t.tween_property(letter, "scale", Vector2(1.0, 1.0), 0.14).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

## Gold underline that grows from the middle outward under the title.
func _grow_underline(cx: float, y: float, width: float) -> void:
	var line := ColorRect.new()
	line.color = GOLD
	line.size = Vector2(width, 8.0)
	line.position = Vector2(cx, y)          # start as a zero-width sliver at center
	line.pivot_offset = Vector2(0, 4.0)
	line.scale = Vector2(0.0, 1.0)
	# center the rect on cx so scaling grows both directions from the middle
	line.position = Vector2(cx - width * 0.5, y)
	line.pivot_offset = Vector2(width * 0.5, 4.0)
	# thin black trim behind it
	var trim := ColorRect.new()
	trim.color = TRIM
	trim.size = Vector2(width + 6.0, 14.0)
	trim.position = Vector2(cx - (width + 6.0) * 0.5, y - 3.0)
	trim.pivot_offset = Vector2((width + 6.0) * 0.5, 7.0)
	trim.scale = Vector2(0.0, 1.0)
	_root.add_child(trim)
	_root.add_child(line)
	_letters.append(trim)
	_letters.append(line)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(trim, "scale:x", 1.0, 0.85).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_property(line, "scale:x", 1.0, 0.85).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)

## Hand off to the menu: fly + shrink the whole title group from its splash spot
## to the menu title's position/size, then reveal the menu (title already matches)
## and play the menu intro (buttons emerge from under the title). Welcome audio +
## music kick in as the handoff begins.
## Hand off to the menu with a truly seamless transition: fly the splash title up +
## shrink it to the menu title's spot/size, then REPARENT the actual title letters
## into the menu so they simply STAY as the menu title. There is only ever one
## title (these exact letters), so nothing needs to match and there's no fade-swap.
func _finish() -> void:
	if _done:
		return
	_done = true

	var vw: float = size.x if size.x > 0 else 1280.0
	var vh: float = size.y if size.y > 0 else 720.0
	var menu_title_topleft_y := vh * 0.5 - 200.0
	var splash_topleft_y := vh * 0.42
	var scale_ratio := 52.0 / float(_title_font_size)
	_root.pivot_offset = Vector2(vw * 0.5, splash_topleft_y)
	var dy := menu_title_topleft_y - splash_topleft_y

	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(_root, "scale", Vector2(scale_ratio, scale_ratio), 0.75).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_property(_root, "position:y", dy, 0.75).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
	await t.finished
	if not is_inside_tree():
		return
	# hand the actual flown title node to the menu; it keeps these exact letters as
	# its title, so the swap is invisible (there's no second title to reveal).
	var menu := get_tree().get_first_node_in_group("menu_overlay")
	if menu != null and menu.has_method("adopt_splash_title"):
		var keep := _root
		remove_child(keep)
		menu.adopt_splash_title(keep)
		_root = null
	finished.emit()
	queue_free()
