extends Node
## Audio system (point 4 of the remaster). Event-driven sound effects + ambience.
##
## This is the SYSTEM and all the hooks — it plays a sound the instant a matching
## .ogg/.wav is dropped into res://assets/audio/ with the expected name. Until
## then it runs silently (no errors), so the game ships audio-ready and sound is
## a pure content drop-in with zero further code.
##
## Expected files (any that exist will play; missing ones are skipped):
##   res://assets/audio/sfx/tag.ogg          - a tag lands (whistle/thunk)
##   res://assets/audio/sfx/bank.ogg         - a steal is banked (score pop)
##   res://assets/audio/sfx/grab.ogg         - an item is picked up
##   res://assets/audio/sfx/catch.ogg        - a pass is caught
##   res://assets/audio/sfx/intercept.ogg    - a pass is picked off
##   res://assets/audio/sfx/throw.ogg        - a ball is thrown
##   res://assets/audio/sfx/countdown.ogg    - each "3,2,1" tick
##   res://assets/audio/sfx/whistle.ogg      - match start/end
##   res://assets/audio/sfx/win.ogg          - victory sting
##   res://assets/audio/music/menu.ogg       - menu loop (streamed if present)
##   res://assets/audio/music/match.ogg      - in-match bed (streamed if present)

const SFX_DIR := "res://assets/audio/sfx/"
const MUSIC_DIR := "res://assets/audio/music/"
const POOL_SIZE := 8        # simultaneous one-shot voices

var _pool: Array = []
var _next := 0
var _music: AudioStreamPlayer = null
var _cache := {}            # name -> AudioStream (or null if absent)
var _welcome_playing := false       # true while the launch Welcome clip plays
var _welcome_started := false        # guard so the startup audio fires exactly once
var _pending_track := "menu"        # track to start once the welcome finishes
var _current_track := ""            # the music track currently playing

func _ready() -> void:
	# keep audio alive when the tree is paused (ESC pause menu) so the music
	# doesn't cut out — the whole audio manager ignores the pause state
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		p.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(p)
		_pool.append(p)
	_music = AudioStreamPlayer.new()
	_music.bus = "Master"
	_music.process_mode = Node.PROCESS_MODE_ALWAYS
	_music.volume_db = -8.0
	add_child(_music)

	Events.actor_tagged.connect(func(_a): play("tag"))
	Events.ball_banked.connect(func(_t): play("bank"))
	Events.item_grabbed.connect(func(_a, _i): play("grab"))
	Events.pass_caught.connect(func(_a): play("catch"))
	Events.pass_intercepted.connect(func(_a): play("intercept"))
	Events.pass_thrown.connect(func(_b, _r): play("throw"))
	Events.countdown_tick.connect(func(_n): play("countdown"))
	Events.match_started.connect(func(_t, _c): _on_match_music())
	Events.match_won.connect(func(_t): play("win"))

	# The startup audio (Welcome clip, then music loop) is kicked off by the splash
	# screen when it fades to the menu — see SplashScreen.gd calling
	# AudioManager.play_welcome_then_music(). If the splash is absent/disabled, a
	# fallback timer starts it so audio never gets stuck off.
	if not _welcome_started:
		get_tree().create_timer(6.0).timeout.connect(func():
			if not _welcome_started:
				play_welcome_then_music())

	# keep music volume correct as settings change and as we move between the
	# menu and in-game (separate volumes for each)
	Events.settings_applied.connect(_on_settings_applied_volume)
	Events.match_started.connect(func(_t, _c): _apply_music_volume())
	Events.returned_to_menu.connect(func(): _apply_music_volume())

## Play a one-shot SFX by name if its file exists; silently no-op otherwise.
func play(sfx_name: String, volume_db: float = 0.0) -> void:
	var stream: AudioStream = _load_cached(SFX_DIR + sfx_name + ".ogg")
	if stream == null:
		stream = _load_cached(SFX_DIR + sfx_name + ".wav")
	if stream == null:
		return                       # no file yet — stay silent, no error
	var p: AudioStreamPlayer = _pool[_next]
	_next = (_next + 1) % POOL_SIZE
	p.stream = stream
	p.volume_db = volume_db
	p.play()

func play_music(track: String) -> void:
	# don't let anything override the one-shot Welcome clip while it's still
	# playing — the music waits until the welcome finishes (this was the bug that
	# cut the welcome off after ~2 seconds when the demo background started).
	if _welcome_playing:
		_pending_track = track
		return
	var stream: AudioStream = _load_cached(MUSIC_DIR + track + ".mp3")
	if stream == null:
		stream = _load_cached(MUSIC_DIR + track + ".ogg")
	if stream == null:
		_music.stop()
		return
	if _music.stream == stream and _music.playing:
		return
	# loop the music bed
	if stream is AudioStreamMP3:
		stream.loop = true
	elif stream is AudioStreamOggVorbis:
		stream.loop = true
	_current_track = track
	_music.stream = stream
	_apply_music_volume()
	_music.play()

## The startup sequence: play the one-shot Welcome audio, then start the looping
## menu/in-game music the moment it finishes.
func play_welcome_then_music() -> void:
	if _welcome_started:
		return
	_welcome_started = true
	var welcome: AudioStream = _load_cached(MUSIC_DIR + "welcome.mp3")
	if welcome == null:
		welcome = _load_cached(MUSIC_DIR + "welcome.ogg")
	if welcome == null:
		# no welcome clip — go straight to the music loop
		play_music("menu")
		return
	if welcome is AudioStreamMP3:
		welcome.loop = false
	_welcome_playing = true
	_pending_track = "menu"
	_music.stream = welcome
	_apply_welcome_volume()
	if not _music.finished.is_connected(_on_welcome_finished):
		_music.finished.connect(_on_welcome_finished, CONNECT_ONE_SHOT)
	_music.play()

func _on_welcome_finished() -> void:
	_welcome_playing = false
	# now start whatever track was queued during the welcome (the menu loop)
	play_music(_pending_track)

func _on_match_music() -> void:
	# pick the bed: dedicated match track if one exists, else the menu loop
	var track := "menu"
	if _load_cached(MUSIC_DIR + "match.mp3") != null or _load_cached(MUSIC_DIR + "match.ogg") != null:
		track = "match"
	# The boot DEMO match also emits match_started — at launch, BEFORE the welcome
	# VO. Starting music here caused the music->welcome->music cutting glitch. If
	# the welcome hasn't played yet (or is playing), just QUEUE the track; it starts
	# when the welcome finishes. No whistle either (it blew over the splash).
	if not _welcome_started or _welcome_playing:
		_pending_track = track
		return
	play("whistle")
	play_music(track)

## Apply the right music volume for the current context (menu vs in-game), since
## the player can set those independently.
func _apply_music_volume() -> void:
	var in_game: bool = GameState.phase == GameState.Phase.PLAYING and GameState.cam_mode != "orbit"
	var vol: float = Settings.music_volume_game if in_game else Settings.music_volume_menu
	_music.volume_db = linear_to_db(clampf(vol, 0.0001, 1.0))

func _apply_welcome_volume() -> void:
	_music.volume_db = linear_to_db(clampf(Settings.welcome_volume, 0.0001, 1.0))

## Re-apply music volume when settings change (but never while the welcome clip
## is still playing — it has its own volume).
func _on_settings_applied_volume() -> void:
	if not _welcome_playing:
		_apply_music_volume()

func _load_cached(path: String) -> AudioStream:
	if _cache.has(path):
		return _cache[path]
	var res: AudioStream = load(path) if ResourceLoader.exists(path) else null
	_cache[path] = res
	return res
