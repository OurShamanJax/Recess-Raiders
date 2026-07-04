class_name SkySun
extends Node3D
## A big, bright sun that slowly revolves around the player. The player is always
## at the centre of its orbit, so it tracks with them — the sky never looks empty.
## Unshaded + no-depth-test so it can never clip through the camera or geometry.

const ORBIT_RADIUS := 300.0      # how far out the sun sits
const ORBIT_HEIGHT := 220.0      # how high above the player
const ORBIT_SPEED := 0.04        # radians/sec — a very slow drift across the sky

var _target: Node3D = null
var _angle := 0.9                # starting position in the orbit
var _sun_light: DirectionalLight3D = null   # the real light, aimed from the sun

func setup(target: Node3D, sun_scene: PackedScene, sun_light: DirectionalLight3D = null) -> void:
	_target = target
	_sun_light = sun_light
	if sun_scene != null:
		var sun := sun_scene.instantiate()
		sun.scale = Vector3(28, 28, 28)
		_make_sky_object(sun)
		add_child(sun)

func _process(delta: float) -> void:
	_angle += ORBIT_SPEED * delta
	var cx := 0.0
	var cz := 0.0
	# during the orbiting skycam (menu/pause), centre the sun's orbit on the
	# field centre so it stays in frame; otherwise centre it on the player.
	if GameState.cam_mode == "orbit":
		cx = 0.0
		cz = 0.0
	elif _target != null and is_instance_valid(_target):
		cx = _target.global_position.x
		cz = _target.global_position.z
	# orbit on a tilted circle centred on the player, kept high in the sky
	global_position = Vector3(
		cx + cos(_angle) * ORBIT_RADIUS,
		ORBIT_HEIGHT,
		cz + sin(_angle) * ORBIT_RADIUS)
	# always face the CAMERA (the viewer), not the player — so the textured sun
	# front is what we see no matter where the player is or how the camera
	# orbits. Facing the player broke during the skycam orbit (player hidden /
	# camera moving independently), leaving the sun edge-on or backwards.
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var look := cam.global_position
		if global_position.distance_to(look) > 0.1:
			look_at(look, Vector3.UP)

	# Drive the REAL directional light from the sun's position: it shines from
	# where the sun mesh is, toward the field centre. As the sun orbits across
	# the sky, the light direction (and therefore all shadows) move with it, so
	# the lighting always correlates with the visible sun. The mesh is unshaded
	# and doesn't block its own light.
	if _sun_light != null and is_instance_valid(_sun_light):
		# A directional light only cares about its ROTATION, not its position —
		# its rays are parallel. We keep it at the origin and just aim it along
		# the sun→field-centre direction. (Previously we also moved its position
		# out to the sun, which shifted the shadow cascade origin and made
		# shadows pop in and out as the sun orbited.)
		var to_centre: Vector3 = Vector3(cx, 0.0, cz) - global_position
		if to_centre.length() > 0.1:
			_sun_light.global_position = Vector3(cx, 0.0, cz)
			_sun_light.look_at(Vector3(cx, 0.0, cz) + to_centre, Vector3.UP)

func _make_sky_object(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = false   # trees/terrain must be able to occlude the sun
		mat.disable_receive_shadows = true
		mat.albedo_color = Color(1.0, 0.84, 0.2)         # bright yellow
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.8, 0.15)
		mat.emission_energy_multiplier = 6.0             # glow strongly, not matte
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in node.get_children():
		_make_sky_object(c)
