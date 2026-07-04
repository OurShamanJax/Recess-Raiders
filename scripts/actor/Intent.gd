class_name Intent
extends RefCounted
## A single frame of input desire (spec §2.5, §9). Controllers fill one of these
## and hand it to the Actor. The Actor never reads Input directly. A future
## NetworkController fills the exact same struct from synced remote data.

var move: Vector3 = Vector3.ZERO   # world-space unit direction (or zero)
var aim: Vector3 = Vector3.FORWARD # world-space unit direction for throws / look
var sprint: bool = false
var want_throw: bool = false
var want_pass: bool = false
var want_interact: bool = false    # grab a looked-at target / revive a teammate
var want_tag: bool = false         # explicit player tag (E / left-click on enemy)
var want_revive: bool = false      # explicit player revive (R / left-click on teammate)
var want_jump: bool = false
var crouch: bool = false

func clear() -> void:
	move = Vector3.ZERO
	aim = Vector3.FORWARD
	sprint = false
	want_throw = false
	want_pass = false
	want_interact = false
	want_tag = false
	want_revive = false
	want_jump = false
	crouch = false
