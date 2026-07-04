extends Node
## Entry point (spec §3, §10). Holds the Match plus the menu and HUD, and wires
## the join request to starting a match.

@onready var match_node := $Match
@onready var menu := $UI/MenuOverlay
@onready var hud := $UI/Hud

func _ready() -> void:
	menu.join_requested.connect(_on_join)
	# whenever a match ends and we're back at the title, the skycam demo backdrop
	# must be HUD-free — otherwise the background match's "Pass!"/"Tagged Out!"
	# flashes and score draw over the menu.
	Events.returned_to_menu.connect(func(): hud.visible = false)
	# pause menu's "Main Menu" button: hard-stop the match, back to the title
	Events.main_menu_requested.connect(func(): match_node.return_to_menu())
	# Live menu background: spin up a bot-vs-bot Raiders match behind the menu,
	# filmed by the orbiting skycam. Hidden player, no HUD — pure backdrop.
	_start_demo_background()
	# Startup splash over the skycam backdrop; it hands off to the menu when done.
	_show_splash()

func _show_splash() -> void:
	# hide the menu overlay until the splash finishes
	menu.visible = false
	var splash := SplashScreen.new()
	# put it above the menu in the same UI CanvasLayer
	$UI.add_child(splash)
	splash.finished.connect(func():
		menu.visible = true
		if menu.has_method("play_intro"):
			menu.play_intro())

func _start_demo_background() -> void:
	GameState.mode = "raiders"
	# pure backdrop: keep the HUD fully hidden so demo events (score, "Pass!",
	# catch flashes, etc.) never draw over the menu's skycam background.
	hud.visible = false
	match_node.begin_demo()

func _on_join(team: String, cam_mode: String) -> void:
	hud.visible = true
	match_node.begin(team, cam_mode)
	hud.bind(match_node.team_manager.player_actor, match_node, match_node.camera_rig.camera)
