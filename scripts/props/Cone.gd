class_name BorderCone
extends RigidBody3D
## Mid-field divider cone. VISUAL-ONLY marker: it has NO collision and does not
## interact with actors, the ball, or anything else. Players and NPCs pass
## straight through it — it just marks the center line. (Previously it was a
## knockable physics prop, which was removed as an annoying feature.)

var home_xform: Transform3D
var id: int = 0

func setup(home: Transform3D, p_id: int) -> void:
	id = p_id
	home_xform = home
	global_transform = home
	# Freeze it and strip all collision so it is purely decorative. freeze keeps
	# it perfectly still; clearing layer + mask means nothing collides with it.
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	gravity_scale = 0.0
	collision_layer = 0
	collision_mask = 0
	add_to_group("border_cones")
