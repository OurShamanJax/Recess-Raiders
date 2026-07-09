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
var _tweens: Array = []   # every splash tween, killed on skip so callbacks can't fire on freed nodes
# title layout, stashed in _run() so _finish() can COMPLETE the title instantly
# if the player skips mid-sequence (otherwise only the fallen R's hand off).
var _full_text := ""
var _letter_xs: Array = []
var _ground_y := 0.0
var _total_w := 0.0
var _center_x := 0.0
var _tail_built := false       # "ecess"/"aiders" letters created
var _underline_built := false  # underline + trim created

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

## Measure the title layout (letter x positions, width, centre, baseline) — pure
## math, no awaits, so BOTH the animated path and an instant skip can compute it.
## The previous skip bug: skipping on frame 0 bailed _run() before the layout was
## stashed, so the instant-completion had nothing to build from.
func _compute_layout() -> void:
	var vw: float = size.x if size.x > 0 else 1280.0
	var vh: float = size.y if size.y > 0 else 720.0
	_center_x = vw * 0.5
	_ground_y = vh * 0.42
	_full_text = "Recess Raiders"
	var font := ThemeDB.fallback_font
	var fs := _title_font_size
	var advances: Array = []
	_total_w = 0.0
	for i in range(_full_text.length()):
		var adv: float = font.get_string_size(_full_text[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 4.0
		advances.append(adv)
		_total_w += adv
	_letter_xs = []
	var cursor := _center_x - _total_w * 0.5
	for i in range(_full_text.length()):
		_letter_xs.append(cursor)
		cursor += advances[i]

func _run() -> void:
	# let fonts/theme/layout settle one frame before measuring letter positions —
	# measuring at frame 0 occasionally raced layout and scrambled the splash
	# (rare, random, no errors: the classic symptom of a first-frame measure)
	await get_tree().process_frame
	if _done: return
	_compute_layout()
	var xs: Array = _letter_xs
	var cx := _center_x
	var ground_y := _ground_y
	var total_w := _total_w
	var full := _full_text
	var fs := _title_font_size

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
	_tail_built = true

	await get_tree().create_timer(2.0).timeout
	if _done: return
	# underline clearly BELOW the glyphs (label positions by top-left; glyphs are
	# ~fs tall, so 1.12*fs clears the descenders — matches the mockup).
	_grow_underline(cx, ground_y + float(fs) * 1.12, total_w)
	_underline_built = true

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
		_tweens.append(t)
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
	_tweens.append(t)
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
	_tweens.append(sway)
	sway.tween_interval(delay)
	sway.tween_property(letter, "position:x", base_x - 7.0, fall_time * 0.4).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	sway.tween_property(letter, "position:x", base_x, fall_time * 0.6).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)

## A quick squash-and-recover scale jiggle to sell the impact.
func _impact_squash(letter: Label) -> void:
	# the skip path frees letters mid-flight; a queued tween callback can then
	# hand us a freed/null node — just ignore it, the rebuilt title is final
	if letter == null or not is_instance_valid(letter):
		return
	var t := create_tween()
	_tweens.append(t)
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
	_tweens.append(t)
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

	# If the player skipped before the title finished animating in, the tail
	# letters and/or underline don't exist yet — the menu would adopt just the
	# two R's. Build whatever's missing INSTANTLY (no tweens) so the handed-off
	# title is always the complete "Recess Raiders" with its underline.
	_complete_title_instantly()

	var vw: float = size.x if size.x > 0 else 1280.0
	var vh: float = size.y if size.y > 0 else 720.0
	var menu_title_topleft_y := vh * 0.5 - 200.0
	var splash_topleft_y := vh * 0.42
	var scale_ratio := 52.0 / float(_title_font_size)
	_root.pivot_offset = Vector2(vw * 0.5, splash_topleft_y)
	var dy := menu_title_topleft_y - splash_topleft_y

	var t := create_tween()
	_tweens.append(t)
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
		# stash the layout this title was built for, so the menu can RE-SEAT it
		# at the correct spot after matches / window resizes (the tween-end
		# transform goes stale — that was the mispositioned-title bug)
		keep.set_meta("splash_vw", vw)
		keep.set_meta("splash_vh", vh)
		keep.set_meta("splash_fs", float(_title_font_size))
		remove_child(keep)
		menu.adopt_splash_title(keep)
		_root = null
	finished.emit()
	queue_free()

## Build any not-yet-created title pieces instantly (final positions, full opacity,
## no tweens). Used when the player skips the splash mid-animation so the title
## handed to the menu is always complete. Guards against re-building on the normal
## (non-skipped) path via the _tail_built / _underline_built flags.
func _complete_title_instantly() -> void:
	# BULLETPROOF version: whatever partial state the skip caught (no letters,
	# R's mid-fall, tail half-typed, underline mid-grow), wipe it and rebuild
	# the entire finished title at final positions. Rebuilding from scratch is
	# the only approach that's correct at EVERY possible skip timing.
	if _root == null:
		return
	if _letter_xs.is_empty():
		_compute_layout()   # skipped before _run() measured — do it now
	# wipe EVERYTHING under _root, not just tracked refs — after a match the
	# handoff can orphan letter nodes (lost refs), and rebuilding on top of
	# them doubled the title on menu return.
	for tw in _tweens:
		if tw != null and tw.is_valid():
			tw.kill()
	_tweens.clear()
	for n in _root.get_children():
		n.queue_free()
	_letters.clear()
	for i in range(_full_text.length()):
		if _full_text[i] == " ":
			continue
		var l := _make_letter(_full_text[i], Vector2(_letter_xs[i], _ground_y))
		l.modulate.a = 1.0
		l.rotation = 0.0
		l.scale = Vector2.ONE
	_tail_built = true
	# underline at full width (snap the grow-tween pieces to done)
	_grow_underline(_center_x, _ground_y + float(_title_font_size) * 1.12, _total_w)
	for node in [_letters[_letters.size() - 2], _letters[_letters.size() - 1]]:
		if node is ColorRect:
			(node as ColorRect).scale = Vector2(1.0, 1.0)
	_underline_built = true
