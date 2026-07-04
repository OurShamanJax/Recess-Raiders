class_name Field
extends Node3D
## Field geometry + zone visuals following the map-layout brief:
##   - playable green field, split by a midline (the cone border line)
##   - point zones (goal zones) at each end
##   - safe zones (circles) near each team's stealing area
##   - coach zones: strips OUTSIDE the playable area on the long (X) sides
## Zones are visuals; the simulation reads zone math from Config.

func build() -> void:
	# Deep safety-net plane far below the lowest valley — only catches the ball
	# or player from falling out of the world. It used to sit at Y=0, which
	# blocked the player from ever descending into terrain valleys (you could
	# only walk at or above ground level). Now the flat gameplay collision (below)
	# and the terrain's own collision provide the real walking surfaces.
	var ground := StaticBody3D.new()
	ground.collision_layer = 8
	ground.collision_mask = 0
	var gcol := CollisionShape3D.new()
	var wb := WorldBoundaryShape3D.new()
	wb.plane = Plane(Vector3.UP, -200.0)   # infinite plane at Y=-200
	gcol.shape = wb
	ground.add_child(gcol)
	add_child(ground)

	# Flat solid collision covering the gameplay zones (field + sidewalk + school
	# approach) at Y=0, so the player and ball have proper flat ground there. The
	# terrain handles everything outside these zones.
	var flat := StaticBody3D.new()
	flat.collision_layer = 8
	flat.collision_mask = 0
	flat.position = Vector3(120, -0.05, 0)
	var fcol := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(720, 0.1, 360)
	fcol.shape = fbox
	flat.add_child(fcol)
	add_child(flat)

	# (The big flat visual ground box was removed: the rolling-terrain mesh now
	# renders one continuous surface across the whole world — flat in the
	# gameplay zones, rolling outside — so there's no separate plane to seam
	# against. The flat collision box above still gives solid ground in the
	# gameplay zones; the small green pitch plane below sits on top for looks.)

	# Coach zones: darker strips just outside the playable area on +/-X
	var cz := Config.COACH_ZONE_WIDTH
	_box(Vector3(cz, 0.1, 210), Color(0.22, 0.35, 0.17), Vector3(-Config.FIELD_X - cz * 0.5, 0.02, 0))
	_box(Vector3(cz, 0.1, 210), Color(0.22, 0.35, 0.17), Vector3(Config.FIELD_X + cz * 0.5, 0.02, 0))

	# Playable field
	_plane(Vector2(120, 210), Color(0.33, 0.58, 0.27), 0.0, false)

	# Mow stripes for readability
	for i in range(14):
		var c := Color(0.35, 0.60, 0.30) if i % 2 == 0 else Color(0.31, 0.55, 0.25)
		_box(Vector3(120, 0.02, 15), c, Vector3(0, 0.011, -105 + i * 15 + 7.5))

	# Boundary + midline
	var lm := Color(1, 1, 1, 0.55)
	_box(Vector3(110, 0.05, 1), lm, Vector3(0, 0.05, -100))
	_box(Vector3(110, 0.05, 1), lm, Vector3(0, 0.05, 100))
	_box(Vector3(1, 0.05, 200), lm, Vector3(-55, 0.05, 0))
	_box(Vector3(1, 0.05, 200), lm, Vector3(55, 0.05, 0))

	# Point zones (goal zones)
	_zone_rect(Vector2(90, 30), Vector3(0, 0.04, 95), Color(0.18, 0.43, 0.84))
	_zone_rect(Vector2(90, 30), Vector3(0, 0.04, -95), Color(0.88, 0.32, 0.25))

	# Safe zones (circles). Config.pod_positions returns each team's safe spots,
	# which sit near the ENEMY goal (where that team steals).
	for p in Config.pod_positions("blue"):
		_ring(p, Color(0.35, 0.75, 1.0))
	for p in Config.pod_positions("red"):
		_ring(p, Color(1.0, 0.5, 0.4))

# --- helpers ----------------------------------------------------------------
func _plane(size: Vector2, color: Color, y: float, _unused: bool) -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	mi.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	mi.material_override = mat
	mi.position.y = y
	add_child(mi)

func _box(size: Vector3, color: Color, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if color.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	mi.position = pos
	add_child(mi)

func _zone_rect(size: Vector2, pos: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	mi.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.20)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	mi.position = pos
	add_child(mi)

func _ring(pos: Vector3, color: Color) -> void:
	# filled translucent disk
	var disk := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = Config.SAFE_POD_RADIUS
	cyl.bottom_radius = Config.SAFE_POD_RADIUS
	cyl.height = 0.06
	disk.mesh = cyl
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(color.r, color.g, color.b, 0.22)
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disk.mesh.material = dm
	disk.position = Vector3(pos.x, 0.05, pos.z)
	add_child(disk)
	# bright rim
	var rim := MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = Config.SAFE_POD_RADIUS - 0.5
	tor.outer_radius = Config.SAFE_POD_RADIUS
	rim.mesh = tor
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = color
	rmat.emission_enabled = true
	rmat.emission = color * 0.5
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rim.mesh.material = rmat
	rim.position = Vector3(pos.x, 0.08, pos.z)
	add_child(rim)
