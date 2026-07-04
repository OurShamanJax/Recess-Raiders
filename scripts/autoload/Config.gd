extends Node
## Central tunables (spec §8) + expanded design from the field-layout brief.
## Per-second values. One place to tune feel. Dictionary lookups use bracket
## access (ai_val) so the GDScript parser stays happy under static typing.

# Movement
const WALK_SPEED := 17.0
const SPRINT_SPEED := 31.0
const CROUCH_SPEED_MULT := 0.45     # crouch walk is slower
const JUMP_VELOCITY := 18.0
const GRAVITY := 45.0

# Stamina
const STAMINA_MAX := 100.0
const SPRINT_DRAIN := 42.0
const SPRINT_RECOVER_FRAC := 0.25  # once gassed (0 stamina), must recover to 25% before sprinting again
const TAG_HEIGHT_TOL := 3.0        # can't tag someone this far above/below you (jump apex is 3.6, so a jump now dodges through most of its arc)
const REVIVE_TAG_GRACE := 1.2      # seconds of untaggable after a revive (stops tag-camping)  # once gassed (0 stamina), must recover to 25% before sprinting again
const WALK_REGEN := 14.0            # slower on-the-move recovery, so pods matter
const POD_REGEN := 72.0

# Interaction radii
const PICKUP_RADIUS := 6.0          # must be within this to grab a goal cone/ball
const LOOK_DOT := 0.55              # how directly you must face a target to grab (dot of facing vs to-target)
const TAG_RADIUS := 6.5             # contact-tag reach: ~arm's length beyond touching capsules (5.0 felt unresponsive at sprint closing speeds)
const PLAYER_ACTION_RANGE := 9.0    # range for the player's E-to-tag / R-to-revive prompts
const CATCH_RADIUS := 4.0
const PASS_RANGE := 60.0
const PASS_LOCK_RANGE := 95.0       # you can LOCK onto a teammate from farther than you'd normally pass
const SAFE_POD_RADIUS := 10.0
const GOAL_BANK_RADIUS := 20.0
const REVIVE_RADIUS := 9.0          # teammate must be this close to revive a tagged player

# Match
const BALLS_PER_TEAM := 2           # footballs per side (from the brief)
const GOAL_CONES_PER_TEAM := 14     # stealable goal cones per side (2 balls + 14 cones = 16 to win)
const TEAM_SIZE := 14               # 14 v 14 (1 human + 13 AI vs 14 AI)

# Revive (hybrid): wait for a teammate, but auto-return after this timeout.
const REVIVE_AUTO_TIMEOUT := 30.0

# --- Perception (per-NPC vision) ---
const VISION_FOV_DEG := 140.0       # full field-of-view angle of the vision cone
const VISION_RANGE := 75.0          # how far the bot can see
const PROXIMITY_RANGE := 14.0       # felt even outside the cone (someone right behind you)
const VISION_USE_RAYCAST := true    # border cones can block line of sight

# --- AI team brain (PlayCaller) ---
const AI_COMMIT_TIME := 1.5          # seconds a bot commits to a chosen job (kills twitching)

# Team raid bias 0..1 (0 = full defense, 1 = full offense), published by each
# team's PlayCaller and read by every bot's utility scorer.
var _raid_bias := {"blue": 0.55, "red": 0.55}
# the currently-called play per team (PlayCaller publishes, bots read)
var _team_play := {"blue": 0, "red": 0}
var _team_flank := {"blue": 0, "red": 0}

func set_team_play(team: String, play: int, flank: int) -> void:
	_team_play[team] = play
	_team_flank[team] = flank

func team_play(team: String) -> int:
	return _team_play.get(team, 0)

func team_flank(team: String) -> int:
	return _team_flank.get(team, 0)

func set_team_raid_bias(team: String, v: float) -> void:
	_raid_bias[team] = clampf(v, 0.0, 1.0)

func team_raid_bias(team: String) -> float:
	return _raid_bias.get(team, 0.55)

# live threat level per team — how many enemies are pressuring our half and how
# many are actively carrying our loot. Bots read this to react team-wide.
var _team_threat := {"blue": 0, "red": 0}
var _team_carrier_threat := {"blue": 0, "red": 0}

func set_team_threat(team: String, threat: int, carrier_threat: int) -> void:
	_team_threat[team] = threat
	_team_carrier_threat[team] = carrier_threat

func team_threat(team: String) -> int:
	return _team_threat.get(team, 0)

func team_carrier_threat(team: String) -> int:
	return _team_carrier_threat.get(team, 0)
const GASSED_STAMINA := 40.0        # below this, bots downshift to rest in a safe zone
const RESCUE_MAX_DIST := 70.0       # conductor won't send a rescuer further than this

# Ball physics
# Delay between starting the throw animation and the ball actually leaving the
# hand — measured kinematically: all 3 pitching clips release (peak hand speed) at
# 1.63s raw = 0.38s after the 1.25s windup trim. Models without a throw clip
# release instantly.
const THROW_ANIM_RELEASE_DELAY := 0.38
const THROW_GRAVITY := 55.0
const THROW_GRAVITY_SCALE := 2.2     # ball falls faster in flight -> football arc, no sailing
const MAX_THROW_DIST := 70.0         # a hard throw covers about this far
const PASS_ARC := 0.18               # peak height as fraction of distance (passes are flat-ish)
const THROW_ARC := 0.28              # lobbed throws arc more

# --- Uncertain catch model (the throw mechanic) ---
const CATCH_BASE := 0.85         # peak catch chance when perfectly placed & facing
const FUMBLE_BAND := 0.18        # band above the catch chance that becomes a fumble
const INTERCEPT_FACTOR := 0.7    # non-intended catchers (incl. enemies) are harder

# Field bounds (playable area; coach zones sit outside on +/-X)
const FIELD_X := 55.0
const FIELD_Z := 100.0
const COACH_ZONE_WIDTH := 12.0      # strip outside playable area on left/right

# Camera — top-down

# Camera — first person
const FP_EYE_HEIGHT := 5.4          # actual eye level on the ~6-unit-tall scaled model
const FP_FORWARD_OFFSET := 3.2
const FP_MOUSE_SENS := 0.0024
const FP_PITCH_CLAMP := 1.2

# Camera — third person (over-the-shoulder)
const THIRD_BACK := 13.0
const THIRD_HEIGHT := 6.0
const THIRD_SHOULDER := 3.2

# Sprint feedback
const SPRINT_FOV_BONUS := 12.0

# Environment
const TREE_BAND_DEPTH := 4
const TREE_GAP := 10.0
const TREE_SCALE_MIN := 0.8
const TREE_SCALE_MAX := 1.7
const FOG_START := 160.0
const FOG_END := 420.0
const FOG_COLOR := Color(0.62, 0.78, 0.92)
const ENVIRONMENT_SEED := 1337

# Border cones (mid-field divider line)
const BORDER_CONE_COUNT := 11       # cones along the midline

# Zone anchors
const GOAL_BLUE_Z := 95.0
const GOAL_RED_Z := -95.0

func goal_pos(team: String) -> Vector3:
	return Vector3(0, 0, GOAL_BLUE_Z) if team == "blue" else Vector3(0, 0, GOAL_RED_Z)

func pod_positions(team: String) -> Array:
	# Safe zones sit near the ENEMY's goal (you rest near where you steal from).
	# Blue attacks -Z, so blue's safe zones are at -Z; mirror for red.
	if team == "blue":
		return [Vector3(-40, 0, -75), Vector3(40, 0, -75)]
	return [Vector3(-40, 0, 75), Vector3(40, 0, 75)]

func enemy_of(team: String) -> String:
	return "red" if team == "blue" else "blue"

## True if z is on team's attacking half (where they go to steal).
func on_enemy_half(team: String, z: float) -> bool:
	return z < 0.0 if team == "blue" else z > 0.0

## True if z is intruding INTO the defender team's home half.
func intruding_into(defender_team: String, z: float) -> bool:
	return z > 0.0 if defender_team == "blue" else z < 0.0


# --- AI difficulty presets ---------------------------------------------------
const DIFFICULTY := {
	"casual":   {"react": 0.55, "aim": 0.55, "aggro": 0.7,  "anticip": 0.4, "pass_smart": 0.5,  "stam_mgmt": 0.6, "revive": 0.4},
	"skilled":  {"react": 0.85, "aim": 0.82, "aggro": 1.0,  "anticip": 0.8, "pass_smart": 0.85, "stam_mgmt": 0.9, "revive": 0.8},
	"ruthless": {"react": 1.0,  "aim": 0.96, "aggro": 1.25, "anticip": 1.0, "pass_smart": 1.0,  "stam_mgmt": 1.0, "revive": 1.0},
}
var ai_difficulty := "casual"
# Reversible flag for NPC fumbles: when true, carriers under pressure have a
# small chance to drop the ball loose. Set false to instantly revert to the
# old "never fumble" behavior if it hurts the AI feel.
var ai_can_fumble := true

# Name pools for nametags (placeholder kid names).
const NAMES_M := ["Sam", "Max", "Leo", "Eli", "Finn", "Jake", "Cole", "Ryan", "Zane", "Theo", "Drew", "Kai", "Beau", "Jude"]
const NAMES_F := ["Mia", "Ava", "Zoe", "Ivy", "Lila", "Nora", "Remi", "Tess", "Cleo", "June", "Wren", "Sky", "Faye", "Quinn"]

## Bracket-access helper so callers never do dot-access on a Dictionary.
func ai_val(key: String) -> float:
	return DIFFICULTY[ai_difficulty][key]
