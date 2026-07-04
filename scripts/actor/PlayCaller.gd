class_name PlayCaller
extends RefCounted
## One per AI team. The V2 brain. Instead of publishing a continuous raid bias
## that gets averaged into mush (the old Conductor), it CALLS A PLAY: a discrete,
## named collective intent that holds for a stretch, then re-evaluates. This is
## what gives a match RHYTHM — pressure builds on one flank, breaks, resets —
## instead of 28 bots independently drifting toward the mean.
##
## A play does two things:
##   1. sets the team raid bias (offense/defense lean) the bots already read
##   2. publishes a PLAY TAG + FLANK that bots read to color their role choice
## Bots still make their own local decisions; the play tilts the whole team's
## tendencies in one readable direction.

enum Play { BALANCED, RAID_LEFT, RAID_RIGHT, WALL_GOAL, BAIT_COUNTER, ESCORT, REGROUP }

var team: String
var _hold := 0.0                  # time left on the current play (the wave length)
var _play: int = Play.BALANCED
var _bias := 0.55

# play definitions: target offense bias + a short flavor the bots read.
# flank: -1 = lean to -X side, +1 = +X side, 0 = none.
const PLAY_DEFS := {
	Play.BALANCED:     {"bias": 0.55, "flank": 0,  "hold": 9.0},
	Play.RAID_LEFT:    {"bias": 0.82, "flank": -1, "hold": 11.0},
	Play.RAID_RIGHT:   {"bias": 0.82, "flank": 1,  "hold": 11.0},
	Play.WALL_GOAL:    {"bias": 0.20, "flank": 0,  "hold": 10.0},
	Play.BAIT_COUNTER: {"bias": 0.30, "flank": 0,  "hold": 8.0},
	Play.ESCORT:       {"bias": 0.70, "flank": 0,  "hold": 9.0},
	Play.REGROUP:      {"bias": 0.45, "flank": 0,  "hold": 6.0},
}

func _init(p_team: String) -> void:
	team = p_team
	_apply(Play.BALANCED)

func conduct(bots: Array, delta: float) -> void:
	_hold -= delta
	# smooth the published bias toward the play's target every frame so the
	# transition between plays reads as a believable shift, not a snap
	var target: float = PLAY_DEFS[_play]["bias"]
	_bias = lerpf(_bias, target, clampf(delta * 1.5, 0.0, 1.0))
	Config.set_team_raid_bias(team, _bias)
	# publish the live threat EVERY FRAME (not just when a new play is called).
	# Previously threat was only recomputed on play-change (every 6-11s), so it
	# went stale: the whole team stayed defensive long after raiders had gone,
	# all parking at the endzone until the play timer happened to expire. That
	# staleness was the intermittent "everyone freezes at home" deadlock.
	_publish_threat()
	# allow an EARLY re-call if a defensive play is being held but the threat has
	# completely cleared — otherwise the team stays walled at the goal for the
	# full hold (up to ~11s) with nobody on the field, which reads as a freeze.
	if _hold > 0.0:
		var defensive: bool = _play in [Play.WALL_GOAL, Play.BAIT_COUNTER, Play.REGROUP]
		if defensive and Config.team_threat(team) == 0 and Config.team_carrier_threat(team) == 0:
			_hold = 0.0   # re-evaluate now; the danger has passed
	if _hold > 0.0:
		return
	# time to call a new play — read the board and pick one
	_call_new_play(bots)

## Read the board for current threat and publish it for the bots to react to.
## Cheap (one pass over actors) and run every frame to stay current.
func _publish_threat() -> void:
	var threat := 0
	var carrier_threat := 0
	for o in GameState.actors():
		if o.is_tagged() or o.team == team:
			continue
		if Config.intruding_into(team, o.global_position.z):
			threat += 1
			if o.has_target():
				carrier_threat += 1
	Config.set_team_threat(team, threat, carrier_threat)

func _call_new_play(bots: Array) -> void:
	if bots.is_empty():
		_apply(Play.BALANCED)
		return

	# --- read the board ---
	var threat := 0            # enemies on our half
	var carrier_threat := 0    # enemies stealing our stuff
	var carriers_ours := 0     # our kids carrying enemy loot (escort candidates)
	for o in GameState.actors():
		if o.is_tagged():
			continue
		if o.team == team:
			if o.has_target():
				carriers_ours += 1
		else:
			if Config.intruding_into(team, o.global_position.z):
				threat += 1
				if o.has_target():
					carrier_threat += 1

	var margin: int = GameState.score_for(team) - GameState.score_for(Config.enemy_of(team))

	# threat is already published every frame by _publish_threat(); the play
	# choice below just uses these local counts to pick a collective stance.

	# --- choose a play from the situation (this is the readable team narrative) ---
	var pick: int = Play.BALANCED

	if carrier_threat >= 1 or threat >= 3:
		# someone is stealing our stuff, or our half is swarmed — wall up and
		# answer it. Reacting to a SINGLE carrier (not waiting for two) is what
		# stops the "everyone ignores the raider" feel.
		pick = Play.WALL_GOAL
	elif carriers_ours >= 1:
		# we have the loot in hand — throw bodies around the carrier to get it home
		pick = Play.ESCORT
	elif margin >= 2 and threat >= 2:
		# we're ahead and they've over-committed forward — bait, then counter
		pick = Play.BAIT_COUNTER
	elif margin <= -2:
		# behind: press hard, pick a flank to overload
		pick = Play.RAID_LEFT if randf() < 0.5 else Play.RAID_RIGHT
	elif threat == 0:
		# our half is clear — go raid, overload a side
		pick = Play.RAID_LEFT if randf() < 0.5 else Play.RAID_RIGHT
	else:
		# mixed board: some pressure present, lean balanced but ready to react
		pick = Play.REGROUP if randf() < 0.3 else Play.BALANCED

	# avoid calling the exact same raid flank twice in a row (keeps it dynamic)
	if pick == _play and (pick == Play.RAID_LEFT or pick == Play.RAID_RIGHT):
		pick = Play.RAID_RIGHT if pick == Play.RAID_LEFT else Play.RAID_LEFT

	_apply(pick)

func _apply(play: int) -> void:
	_play = play
	var def: Dictionary = PLAY_DEFS[play]
	_hold = float(def["hold"]) * randf_range(0.85, 1.15)
	# publish the play so bots can read it for role coloring
	Config.set_team_play(team, play, int(def["flank"]))

## What play are we running (for bots to read).
func current_play() -> int:
	return _play
