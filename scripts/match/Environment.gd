class_name GameEnvironment
extends Node3D
## Presentation-only environment (spec §4a) + brief additions: blue sky with sun
## and scattered clouds, the forest ring, fog, and the reactive grass field. No
## colliders, no nav impact; the AI never references any of this.

const GrassFieldScript := preload("res://scripts/match/GrassField.gd")

@export_group("Environment")
@export var tree_band_depth: int = Config.TREE_BAND_DEPTH
@export var tree_gap: float = Config.TREE_GAP
@export var tree_scale_min: float = Config.TREE_SCALE_MIN
@export var tree_scale_max: float = Config.TREE_SCALE_MAX
@export var fog_start: float = Config.FOG_START
@export var fog_end: float = Config.FOG_END
@export var fog_color: Color = Config.FOG_COLOR
@export var environment_seed: int = Config.ENVIRONMENT_SEED

# terrain noise generators (shared by the mesh builder and the tree placer so
# trees sit exactly on the terrain surface)
var _tnoise: FastNoiseLite = null
var _tnoise2: FastNoiseLite = null
var _tridge: FastNoiseLite = null

## Lazily build the terrain noise generators.
func _ensure_terrain_noise() -> void:
	if _tnoise != null:
		return
	_tnoise = FastNoiseLite.new()
	_tnoise.seed = environment_seed + 13
	_tnoise.frequency = 0.0035
	_tnoise.fractal_octaves = 4
	_tnoise2 = FastNoiseLite.new()
	_tnoise2.seed = environment_seed + 47
	_tnoise2.frequency = 0.011
	_tridge = FastNoiseLite.new()
	_tridge.seed = environment_seed + 91
	_tridge.frequency = 0.0014

## The terrain surface height at world (x,z) — same math the mesh uses, so trees
## (and anything else) can be placed exactly on the ground. Includes the -0.1
## mesh offset so callers get the true world Y of the terrain top.
func _terrain_height(x: float, z: float) -> float:
	_ensure_terrain_noise()
	var flat: float = _terrain_flatten(x, z)
	if flat >= 1.0:
		return 0.0
	var dist: float = sqrt(x * x + z * z)
	var far: float = clampf((dist - 180.0) / 420.0, 0.0, 1.0)
	var local_amp: float = lerpf(28.0, 130.0, far)
	var n: float = _tnoise.get_noise_2d(x, z) * 0.6 + _tnoise2.get_noise_2d(x, z) * 0.2
	var r: float = 1.0 - absf(_tridge.get_noise_2d(x, z))
	r = r * r
	var combined: float = n + (r - 0.5) * far * 1.4
	return combined * local_amp * (1.0 - flat) - 0.1
@export var cloud_count := 7
var _clouds: Array = []
var _cloud_mat: StandardMaterial3D = null

func build(full: bool = true) -> void:
	_setup_sky_and_fog()
	_build_clouds()
	if full:
		# raiders: full park dressing (grass, props, forest).
		# court, not a field) and keeps only sky, clouds, and fog.
		_build_forest()
		_build_grass()
		_build_props()
		_build_distant_scenery()

## Distant cosmetic scenery beyond the tree ring — a school building, rolling
## hills, and far tree clusters — so the world has depth and a sense of place
## instead of a flat empty green expanse (very visible now under the skycam).
## Purely visual, far outside the play area: zero gameplay impact.
func _build_distant_scenery() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = environment_seed + 7

	# --- a school building at the end of the sidewalk, on the +X side, facing
	# the field so the connecting walk leads up to its entrance ---
	_school_building(Vector3(Config.FIELD_X + 240.0, 0, 0))
	_build_parking_and_road()

	# --- rolling terrain: a real displaced ground mesh surrounding the play area.
	# Each vertex is raised by layered noise, but FLATTENED to y=0 wherever
	# gameplay needs flat ground (the field, the sidewalk corridor, and the
	# school grounds), with a smooth falloff so the terrain rises gently as it
	# leaves those zones. The flat playable areas are never disturbed. ---
	_build_rolling_terrain()
	# --- forest the mountains and valleys: scatter trees across the rolling
	# terrain, sampling the ground height at each so they grow OUT of the
	# terrain (never floating), with varied sizes. ---
	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.32, 0.22, 0.12)
	trunk_mat.roughness = 1.0
	for i in range(320):
		var ang2 := rng.randf_range(0, TAU)
		var dist2 := rng.randf_range(150.0, 620.0)
		var tx := cos(ang2) * dist2
		var tz := sin(ang2) * dist2
		# keep the school grounds clear (it sits out on +X around z=0)
		# keep the school grounds, parking lot, and road clear (all out on +X)
		if tx > Config.FIELD_X + 130.0 and absf(tz) < 110.0:
			continue
		# also keep the road corridor clear all the way to the map edge
		if tx > Config.FIELD_X + 130.0 and absf(tz) < 24.0:
			continue
		# only forest where the terrain actually rolls — skip flat gameplay zones
		if _terrain_flatten(tx, tz) > 0.6:
			continue
		# Plant the tree on the terrain surface. The mesh is flat triangles
		# between grid points; sampling the FOUR grid corners of the cell the tree
		# is in and using their average matches the triangle surface closely, so
		# trees neither float above peaks nor sink deep into the ground. A tiny
		# fixed sink keeps the trunk visually rooted.
		var gx0: float = floor(tx / 12.0) * 12.0
		var gz0: float = floor(tz / 12.0) * 12.0
		var ha: float = _terrain_height(gx0, gz0)
		var hb: float = _terrain_height(gx0 + 12.0, gz0)
		var hc: float = _terrain_height(gx0, gz0 + 12.0)
		var hd: float = _terrain_height(gx0 + 12.0, gz0 + 12.0)
		var plant_y: float = (ha + hb + hc + hd) * 0.25 - 0.3
		# vary size: distant mountain trees a bit bigger/taller for scale
		var tree_scale := rng.randf_range(0.7, 1.6)
		_tree_on_ground(rng, Vector3(tx, plant_y, tz), trunk_mat, tree_scale)

## A simple block school building (primitives only, no GLB needed).
func _school_building(origin: Vector3) -> void:
	var wall := StandardMaterial3D.new()
	wall.albedo_color = Color(0.74, 0.58, 0.46)   # warm brick
	wall.roughness = 0.95
	var roof := StandardMaterial3D.new()
	roof.albedo_color = Color(0.40, 0.30, 0.28)
	roof.roughness = 1.0
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.62, 0.60, 0.55)   # tile
	floor_mat.roughness = 0.9
	var door_mat := StandardMaterial3D.new()
	door_mat.albedo_color = Color(0.45, 0.30, 0.20)    # wood doors
	door_mat.roughness = 0.85

	# The school is an ENTERABLE building for the player to explore in downtime.
	# Footprint runs along Z (broad as seen from the field); the player enters
	# from the -X side where the walk arrives. Game-mode bots never come here.
	var W := 60.0    # X depth of the building
	var L := 90.0    # Z length
	var H := 16.0    # wall height
	var WALL := 1.5  # wall thickness
	var ent_half := 6.0   # half-width of the front entrance gap (at z=0)

	# floor: a thin flush visual tile (NO collision — the existing ground plane
	# is what the player walks on, so there's no lip at the entrance to catch on)
	var floor_tile := MeshInstance3D.new()
	var fplane := BoxMesh.new()
	fplane.size = Vector3(W, 0.1, L)
	floor_tile.mesh = fplane
	floor_tile.material_override = floor_mat
	floor_tile.position = origin + Vector3(0, 0.06, 0)
	add_child(floor_tile)
	# roof slab
	_scenery_box(Vector3(W + 4, 2.0, L + 4), roof, origin + Vector3(0, H + 1.0, 0))

	# --- perimeter walls (solid, the player collides with these) ---
	# back wall (-X, facing the field — the sidewalk connects to THIS side)
	_school_solid(Vector3(WALL, H, L), wall, origin + Vector3(-W * 0.5, H * 0.5, 0))
	# side walls (±Z ends)
	_school_solid(Vector3(W, H, WALL), wall, origin + Vector3(0, H * 0.5, L * 0.5))
	_school_solid(Vector3(W, H, WALL), wall, origin + Vector3(0, H * 0.5, -L * 0.5))
	# FRONT wall (+X, facing AWAY from the field toward the parking lot) split
	# around a central entrance doorway — this is the school's main entrance
	var front_seg := (L * 0.5 - ent_half)
	_school_solid(Vector3(WALL, H, front_seg), wall, origin + Vector3(W * 0.5, H * 0.5, (ent_half + L * 0.5) * 0.5))
	_school_solid(Vector3(WALL, H, front_seg), wall, origin + Vector3(W * 0.5, H * 0.5, -(ent_half + L * 0.5) * 0.5))
	# entrance header above the door gap
	_scenery_box(Vector3(WALL, H - 8.0, ent_half * 2.0), wall, origin + Vector3(W * 0.5, H - (H - 8.0) * 0.5, 0))

	# --- central hallway divider with classroom doorways on each side ---
	# hallway runs along Z down the middle; classrooms open off a dividing wall
	# at x = -6 (the field/back half is classrooms, the front half is the hall)
	var div_x := -6.0
	# four classroom doorway gaps along the divider
	var room_zs := [-30.0, -10.0, 10.0, 30.0]
	_school_wall_with_gaps(Vector3(div_x, H * 0.5, 0) + origin, true, L, H, WALL, room_zs, 4.0, wall, door_mat)

	# cross-walls separating the classrooms behind the divider (on the -X side)
	for cz in [-20.0, 0.0, 20.0]:
		_school_solid(Vector3(W * 0.5 - absf(div_x), H, WALL), wall, origin + Vector3(-(W * 0.5 + absf(div_x)) * 0.5, H * 0.5, cz))

	# --- a clock-tower landmark on the ROOF (above the +X entrance) ---
	_scenery_box(Vector3(10, 12.0, 10), wall, origin + Vector3(W * 0.25, H + 2.0 + 6.0, 0))
	_scenery_box(Vector3(12, 3.0, 12), roof, origin + Vector3(W * 0.25, H + 2.0 + 12.0, 0))

## Build the parking lot in front of the school (the +X entrance side), with
## parked low-poly cars, painted stalls, and a main road running to the map edge.
func _build_parking_and_road() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = environment_seed + 555
	var fx := Config.FIELD_X

	var asphalt := StandardMaterial3D.new()
	asphalt.albedo_color = Color(0.13, 0.13, 0.15)
	asphalt.roughness = 0.95
	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color(0.85, 0.85, 0.6)
	paint.roughness = 0.9

	# --- parking lot pad (in front of school entrance, +X side) ---
	var lot_cx := fx + 360.0
	var lot := MeshInstance3D.new()
	var lplane := BoxMesh.new()
	lplane.size = Vector3(130.0, 0.12, 170.0)
	lot.mesh = lplane
	lot.material_override = asphalt
	lot.position = Vector3(lot_cx, 0.06, 0.0)
	add_child(lot)

	# --- parking stall lines (rows of short painted stripes) ---
	for row in [-1, 1]:
		for i in range(10):
			var sz := -76.5 + i * 17.0
			var stripe := MeshInstance3D.new()
			var sp := BoxMesh.new()
			sp.size = Vector3(22.0, 0.14, 0.6)
			stripe.mesh = sp
			stripe.material_override = paint
			stripe.position = Vector3(lot_cx + row * 26.0, 0.13, sz)
			add_child(stripe)

	# --- parked cars: two rows facing the school, varied colors ---
	var car_colors := [Color(0.75, 0.2, 0.2), Color(0.2, 0.35, 0.7), Color(0.85, 0.8, 0.2),
		Color(0.9, 0.9, 0.9), Color(0.15, 0.15, 0.18), Color(0.3, 0.55, 0.35), Color(0.6, 0.6, 0.65)]
	for row2 in [-1, 1]:
		for i in range(9):
			# skip a few stalls so the lot isn't perfectly full
			if rng.randf() < 0.25:
				continue
			var cz: float = -68.0 + i * 17.0
			var cx: float = lot_cx + row2 * 26.0
			var col: Color = car_colors[rng.randi() % car_colors.size()]
			# cars in the +X row face -X (toward school), -X row faces +X
			_parked_car(Vector3(cx, 0.0, cz), col, row2 < 0)

	# --- main road: runs from the lot out to the +X map edge ---
	var road := MeshInstance3D.new()
	var rplane := BoxMesh.new()
	rplane.size = Vector3(300.0, 0.12, 26.0)
	road.mesh = rplane
	road.material_override = asphalt
	road.position = Vector3(fx + 520.0, 0.07, 0.0)
	add_child(road)
	# center dashed line
	for i in range(20):
		var dash := MeshInstance3D.new()
		var dp := BoxMesh.new()
		dp.size = Vector3(8.0, 0.14, 1.2)
		dash.mesh = dp
		dash.material_override = paint
		dash.position = Vector3(fx + 380.0 + i * 14.0, 0.14, 0.0)
		add_child(dash)

## A simple low-poly car (body + cabin + 4 wheels), placed with its base on the
## ground. `face_neg_x` orients it; color sets the body paint.
func _parked_car(pos: Vector3, body_color: Color, _face_neg_x: bool) -> void:
	var g := Node3D.new()
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = body_color
	body_mat.roughness = 0.5
	body_mat.metallic = 0.3
	var glass_mat := StandardMaterial3D.new()
	glass_mat.albedo_color = Color(0.3, 0.4, 0.5)
	glass_mat.roughness = 0.2
	glass_mat.metallic = 0.5
	var tire_mat := StandardMaterial3D.new()
	tire_mat.albedo_color = Color(0.08, 0.08, 0.09)
	tire_mat.roughness = 1.0

	# body (lower box)
	var body := MeshInstance3D.new()
	var bb := BoxMesh.new()
	bb.size = Vector3(9.0, 2.4, 4.4)
	body.mesh = bb
	body.material_override = body_mat
	body.position.y = 2.0
	g.add_child(body)
	# cabin (upper box, shorter)
	var cabin := MeshInstance3D.new()
	var cb := BoxMesh.new()
	cb.size = Vector3(4.6, 2.0, 4.0)
	cabin.mesh = cb
	cabin.material_override = glass_mat
	cabin.position = Vector3(-0.3, 3.9, 0.0)
	g.add_child(cabin)
	# wheels
	for wx in [-3.0, 3.0]:
		for wz in [-2.2, 2.2]:
			var wheel := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 1.1; cyl.bottom_radius = 1.1; cyl.height = 0.8
			wheel.mesh = cyl
			wheel.material_override = tire_mat
			wheel.rotation.x = PI * 0.5   # lay the cylinder on its side (axle along Z)
			wheel.position = Vector3(wx, 1.0, wz)
			g.add_child(wheel)

	g.position = pos
	add_child(g)

## A wall running along Z with doorway gaps at the given z-offsets. Builds solid
## segments between the gaps (with collision) and a low header over each gap so
## it reads as a doorway. `center` is the wall's center; `axis_z` true = along Z.
func _school_wall_with_gaps(center: Vector3, _axis_z: bool, length: float, h: float, thick: float, gaps: Array, gap_half: float, wall_mat: Material, _door_mat: Material) -> void:
	# sort gap positions and fill solid wall between them
	var sorted_gaps: Array = gaps.duplicate()
	sorted_gaps.sort()
	var z0 := -length * 0.5
	var cursor := z0
	for gz in sorted_gaps:
		var seg_end: float = gz - gap_half
		if seg_end > cursor:
			var seg_len: float = seg_end - cursor
			var seg_z: float = cursor + seg_len * 0.5
			_school_solid(Vector3(thick, h, seg_len), wall_mat, Vector3(center.x, center.y, center.z + seg_z))
		cursor = gz + gap_half
		# header above the doorway gap — sits in the upper portion of the wall
		var header_h: float = h - 9.0
		var header_y: float = center.y + (h * 0.5) - (header_h * 0.5)
		_scenery_box(Vector3(thick, header_h, gap_half * 2.0), wall_mat, Vector3(center.x, header_y, center.z + gz))
	if cursor < length * 0.5:
		var tail: float = length * 0.5 - cursor
		var tail_z: float = cursor + tail * 0.5
		_school_solid(Vector3(thick, h, tail), wall_mat, Vector3(center.x, center.y, center.z + tail_z))

## A solid school element WITH collision on layer 5 (bit 16) — the player
## collides with these (walls/floor) but game-mode bots never path here so they
## ignore this layer entirely.
func _school_solid(size: Vector3, mat: Material, pos: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 16     # bit 5 — the player's mask includes this
	body.collision_mask = 0
	body.position = pos
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	add_child(body)

func _scenery_box(size: Vector3, mat: Material, pos: Vector3) -> void:
	var m := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	m.mesh = box
	m.material_override = mat
	m.position = pos
	add_child(m)

## Visual-only scene dressing (point: expanded park map). Goal posts frame each
## end, benches + a sidewalk line the right sideline. None of these have
## collision — they're cosmetic, like the trees. Gameplay field is unchanged.
func _build_props() -> void:
	var post_scene: PackedScene = load("res://assets/props/world/goalpost.glb")
	var bench_scene: PackedScene = load("res://assets/props/world/bench.glb")

	# goal posts: the model is centered on origin (y -1..1), so at scale S its
	# goal posts: one centered post behind each goal line. The model is centered
	# on origin (y -1..1), so at scale S its bottom is S below ground — lift by S
	# so it rests on Y=0.
	if post_scene != null:
		var post_scale := 9.0
		for z in [Config.FIELD_Z + 4.0, -(Config.FIELD_Z + 4.0)]:
			var post := post_scene.instantiate()
			post.scale = Vector3(post_scale, post_scale, post_scale)
			post.position = Vector3(0.0, post_scale, z)   # centered on X, on the ground
			add_child(post)

	# benches: along the +X sideline, between the field edge and the sidewalk,
	# facing the field. Skip Z near 0 so they don't sit on the crossing path.
	# Each bench gets a solid collision box (players/NPCs can't walk through) and
	# joins the "benches" group so the player can detect proximity for the sit prompt.
	if bench_scene != null:
		var bench_scale := 4.0
		for bz in [80.0, 45.0, -45.0, -80.0]:
			var bench := bench_scene.instantiate()
			bench.scale = Vector3(bench_scale, bench_scale, bench_scale)
			bench.position = Vector3(Config.FIELD_X + 10.0, bench_scale * 0.6, bz)
			bench.rotation.y = -PI / 2.0
			add_child(bench)
			# solid collision shaped like the bench: a horizontal SEAT slab plus a
			# vertical BACKREST slab, rather than one solid brick. Leaves the space
			# under the seat and in front of the back open, matching the real form.
			# The model (scale 4) is ~8 long x 4.1 tall x 3 deep in world units; shapes
			# are defined in the body's local frame (the body carries the -90° yaw).
			var body := StaticBody3D.new()
			body.position = bench.position
			# lower the body so shape offsets are measured from the ground up
			body.position.y = 0.0
			body.rotation.y = bench.rotation.y
			body.collision_layer = 1        # same layer as other solids
			body.collision_mask = 0

			# SEAT: long, shallow, seat-height slab (the part you sit on)
			var seat := CollisionShape3D.new()
			var seat_box := BoxShape3D.new()
			seat_box.size = Vector3(7.6, 0.8, 2.6)   # length, thickness, depth
			seat.shape = seat_box
			seat.position = Vector3(0.0, 2.0, 0.0)    # seat surface ~2 units up
			body.add_child(seat)

			# BACKREST: long, thin, taller slab at the back edge of the seat
			var back := CollisionShape3D.new()
			var back_box := BoxShape3D.new()
			back_box.size = Vector3(7.6, 2.2, 0.6)    # length, height, thin depth
			back.shape = back_box
			back.position = Vector3(0.0, 3.2, -1.0)   # raised + shifted to the back
			body.add_child(back)

			body.add_to_group("benches")
			add_child(body)

	# sidewalk: a flat concrete strip running the full sideline length, beyond
	# the benches on +X. Slightly raised so it doesn't z-fight with the grass.
	var walk := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(14.0, 2.0 * Config.FIELD_Z + 40.0)
	walk.mesh = plane
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.78, 0.77, 0.74)
	wm.roughness = 0.95
	walk.material_override = wm
	walk.position = Vector3(Config.FIELD_X + 30.0, 0.08, 0)
	add_child(walk)

	# a second walk crossing it perpendicular (the T-junction from the map
	# design) — runs out along +X from the sideline at the midline, all the way
	# to the school entrance so the path visibly connects field to building.
	var walk2 := MeshInstance3D.new()
	var plane2 := PlaneMesh.new()
	plane2.size = Vector2(200.0, 14.0)
	walk2.mesh = plane2
	walk2.material_override = wm
	walk2.position = Vector3(Config.FIELD_X + 110.0, 0.08, 0)
	add_child(walk2)

	# a courtyard pad in front of the school where the walk arrives
	var court := MeshInstance3D.new()
	var cplane := PlaneMesh.new()
	cplane.size = Vector2(70.0, 70.0)
	court.mesh = cplane
	court.material_override = wm
	court.position = Vector3(Config.FIELD_X + 205.0, 0.08, 0)
	add_child(court)

	# --- walkways WRAPPING around both sides of the school, connecting the back
	# courtyard (field side, x≈260) around the building sides to the parking lot
	# at the front (+X, x≈360). The school spans x:[265,325], z:[-45,45]. ---
	var court_x := Config.FIELD_X + 205.0    # back courtyard center (~260)
	var lot_front_x := Config.FIELD_X + 295.0  # parking lot near edge (~350)
	var wrap_z := 54.0                         # just outside the school's ±45 sides
	for side in [-1.0, 1.0]:
		# 1) a short link from the back courtyard out to the side lane
		var back_link := MeshInstance3D.new()
		var blp := PlaneMesh.new()
		blp.size = Vector2(12.0, wrap_z)         # runs in Z from courtyard to the side lane
		back_link.mesh = blp
		back_link.material_override = wm
		back_link.position = Vector3(court_x, 0.085, side * wrap_z * 0.5)
		add_child(back_link)
		# 2) the side lane running along the school side (in X) to the lot
		var side_lane := MeshInstance3D.new()
		var slp := PlaneMesh.new()
		slp.size = Vector2(lot_front_x - court_x, 12.0)
		side_lane.mesh = slp
		side_lane.material_override = wm
		side_lane.position = Vector3((court_x + lot_front_x) * 0.5, 0.085, side * wrap_z)
		add_child(side_lane)
		# 3) a link from the side lane into the lot front
		var lot_link := MeshInstance3D.new()
		var llp := PlaneMesh.new()
		llp.size = Vector2(12.0, wrap_z)
		lot_link.mesh = llp
		lot_link.material_override = wm
		lot_link.position = Vector3(lot_front_x, 0.085, side * wrap_z * 0.5)
		add_child(lot_link)

func _setup_sky_and_fog() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	# Procedural blue sky with a sun disk.
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.18, 0.46, 0.92)
	sky_mat.sky_horizon_color = Color(0.66, 0.83, 0.99)
	sky_mat.ground_horizon_color = Color(0.66, 0.83, 0.99)
	sky_mat.ground_bottom_color = Color(0.42, 0.56, 0.46)
	sky_mat.sun_angle_max = 12.0
	sky_mat.sun_curve = 0.08
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.05
	# light distance fog, pushed far back so the world reads bright not gray
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_begin = maxf(fog_start, 240.0)
	env.fog_depth_end = maxf(fog_end, 560.0)
	env.fog_light_color = Color(0.72, 0.84, 0.98)
	env.fog_density = 0.35

	# --- ambient occlusion: soft contact shadows in crevices and where objects
	# meet the ground. The single biggest "things feel grounded" upgrade. ---
	env.ssao_enabled = Settings.ambient_occlusion if "ambient_occlusion" in Settings else true
	env.ssao_radius = 2.0
	env.ssao_intensity = 1.6
	env.ssao_power = 1.5
	env.ssao_detail = 0.5

	# --- SDFGI: real-time dynamic global illumination (bounced light). The
	# gi_quality setting controls it: 0 off, 1 low (fewer cascades), 2 high. ---
	var gi: int = Settings.gi_quality if "gi_quality" in Settings else 2
	env.sdfgi_enabled = gi > 0
	env.sdfgi_cascades = 4 if gi >= 2 else 2
	env.sdfgi_min_cell_size = 0.2
	env.sdfgi_use_occlusion = true
	env.sdfgi_bounce_feedback = 0.5
	env.sdfgi_energy = 1.0

	# --- screen-space indirect lighting: extra localized bounce based on what's
	# on screen, complements SDFGI for nearer detail ---
	env.ssil_enabled = Settings.indirect_light if "indirect_light" in Settings else true
	env.ssil_radius = 4.0
	env.ssil_intensity = 1.0

	# --- screen-space reflections: shiny surfaces (polished floors) reflect
	# dynamic on-screen objects ---
	env.ssr_enabled = Settings.reflections if "reflections" in Settings else true
	env.ssr_max_steps = 32
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0

	# --- subtle bloom: a gentle light bleed on the brightest areas (sky, sun-lit
	# surfaces) for warmth. Kept low so it reads as soft daylight, not neon. ---
	env.glow_enabled = Settings.bloom if "bloom" in Settings else true
	env.glow_intensity = 0.25
	env.glow_strength = 0.9
	env.glow_bloom = 0.1
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.glow_hdr_threshold = 1.1

	# --- color grading: filmic tonemap with a touch more contrast and saturation
	# so the flat low-poly colors read rich and sunny rather than washed out. ---
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.05
	env.tonemap_white = 1.1
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.02
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.12
	we.environment = env
	add_child(we)
	# keep the env around and RE-APPLY the quality-driven effects whenever settings
	# change — without this, toggling GI/SSAO/bloom (incl. the Performance preset)
	# only took effect on the NEXT match, which made the settings feel dead.
	_env_res = env
	if not Events.settings_applied.is_connected(_apply_env_quality):
		Events.settings_applied.connect(_apply_env_quality)

func _build_clouds() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = environment_seed + 99
	_cloud_mat = StandardMaterial3D.new()
	_cloud_mat.albedo_color = Color(1, 1, 1, 0.92)
	_cloud_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cloud_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_cloud_mat.roughness = 1.0
	# more clouds than before, each given a drifting, fading lifecycle
	for i in range(cloud_count + 9):
		var cloud := _make_cloud(rng)
		# stagger initial life so they don't all fade together
		var entry := {
			"node": cloud,
			"vel": Vector3(rng.randf_range(-2.2, 2.2), 0.0, rng.randf_range(-2.2, 2.2)) * rng.randf_range(0.4, 1.3),
			"life": rng.randf_range(0.0, 1.0),         # 0..1 normalized age
			"dur": rng.randf_range(40.0, 80.0),        # seconds for a full cycle (slower)
			"max_alpha": rng.randf_range(0.7, 0.95),
		}
		_clouds.append(entry)
		add_child(cloud)
	set_process(true)

## Build one cloud node (a clump of soft puffs) with its own material instance so
## its alpha can be faded independently.
func _make_cloud(rng: RandomNumberGenerator) -> Node3D:
	var cloud := Node3D.new()
	var mat := _cloud_mat.duplicate()
	cloud.set_meta("mat", mat)
	var puffs := rng.randi_range(3, 9)
	for p in range(puffs):
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		var r := rng.randf_range(6.0, 26.0)
		sm.radius = r
		sm.height = r * 1.6
		mi.mesh = sm
		mi.material_override = mat
		mi.position = Vector3(rng.randf_range(-18, 18), rng.randf_range(-3, 3), rng.randf_range(-10, 10))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		cloud.add_child(mi)
	var ang := rng.randf() * TAU
	var rad := rng.randf_range(150, 340)
	cloud.position = Vector3(cos(ang) * rad, rng.randf_range(85, 150), sin(ang) * rad)
	return cloud

## Drift clouds and run their fade-in / drift / fade-out / respawn lifecycle.
func _process(delta: float) -> void:
	if _clouds.is_empty():
		return
	for entry in _clouds:
		var node: Node3D = entry["node"]
		if node == null or not is_instance_valid(node):
			continue
		# advance life; when a cloud completes its cycle, respawn it elsewhere
		entry["life"] += delta / float(entry["dur"])
		if entry["life"] >= 1.0:
			entry["life"] = 0.0
			var ang := randf() * TAU
			var rad := randf_range(150.0, 340.0)
			node.position = Vector3(cos(ang) * rad, randf_range(85.0, 150.0), sin(ang) * rad)
			entry["vel"] = Vector3(randf_range(-2.2, 2.2), 0.0, randf_range(-2.2, 2.2)) * randf_range(0.4, 1.3)
		# drift
		node.position += entry["vel"] * delta
		# fade in over the first 15%, hold, fade out over the last 15%
		var life: float = entry["life"]
		var a: float = 1.0
		if life < 0.15:
			a = life / 0.15
		elif life > 0.85:
			a = (1.0 - life) / 0.15
		var mat: StandardMaterial3D = node.get_meta("mat")
		if mat != null:
			var c := mat.albedo_color
			c.a = a * float(entry["max_alpha"])
			mat.albedo_color = c

var _grass: Node = null

func _build_grass() -> void:
	# rebuildable: quality changes (incl. the Performance preset) re-run this
	if _grass != null and is_instance_valid(_grass):
		_grass.queue_free()
		_grass = null
	var q: int = Settings.grass_quality if "grass_quality" in Settings else 2
	if q <= 0:
		return   # "Off" now actually means off (it used to still draw 8000 blades)
	var g := GrassFieldScript.new()
	g.blade_count = 14000 if q == 1 else 38000
	add_child(g)
	g.build()
	_grass = g
	if not Events.settings_applied.is_connected(_build_grass):
		Events.settings_applied.connect(_build_grass)

## How flat the terrain should be at a given world XZ (1 = fully flat/zero
## height, 0 = full rolling height). Returns 1.0 inside the field, sidewalk, and
## school footprints, smoothly falling to 0 just outside them.
func _terrain_flatten(x: float, z: float) -> float:
	var fx: float = Config.FIELD_X
	var fz: float = Config.FIELD_Z
	var field_flat: float = _rect_flatten(x, z, 0.0, 0.0, fx + 35.0, fz + 35.0, 40.0)
	var walk_flat: float = _rect_flatten(x, z, fx + 120.0, 0.0, 150.0, 20.0, 30.0)
	var school_flat: float = _rect_flatten(x, z, fx + 240.0, 0.0, 70.0, 70.0, 40.0)
	# parking lot + road in front of the school (the +X side), flattened so the
	# cars sit level and the road runs straight to the map edge
	var lot_flat: float = _rect_flatten(x, z, fx + 360.0, 0.0, 80.0, 95.0, 35.0)
	# road flatten must FULLY cover the road mesh (centered fx+520, 300 long, so
	# x:[fx+370, fx+670]) plus margin, or rolling terrain pokes through the ends
	var road_flat: float = _rect_flatten(x, z, fx + 520.0, 0.0, 160.0, 18.0, 22.0)
	return clampf(maxf(maxf(maxf(maxf(field_flat, walk_flat), school_flat), lot_flat), road_flat), 0.0, 1.0)

## Flatten weight for a rectangle centred at (cx,cz) with half-extents (hx,hz)
## and a smooth falloff band of `fade` units outside it. 1 inside, 0 past fade.
func _rect_flatten(x: float, z: float, cx: float, cz: float, hx: float, hz: float, fade: float) -> float:
	var dx: float = maxf(0.0, absf(x - cx) - hx)
	var dz: float = maxf(0.0, absf(z - cz) - hz)
	var d: float = sqrt(dx * dx + dz * dz)
	if d <= 0.0:
		return 1.0
	if d >= fade:
		return 0.0
	var t: float = d / fade
	return 1.0 - (t * t * (3.0 - 2.0 * t))   # smoothstep falloff

## Build the rolling-terrain mesh: a grid displaced by layered noise, flattened
## to y=0 within the gameplay zones. Surrounds the flat play area with hills.
func _build_rolling_terrain() -> void:
	_ensure_terrain_noise()
	var noise := _tnoise
	var noise2 := _tnoise2
	var ridge := _tridge

	var size := 1400.0
	var step := 12.0
	var half := size * 0.5

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var heights := {}
	var gx := -half
	while gx <= half + 0.1:
		var gz := -half
		while gz <= half + 0.1:
			var flat: float = _terrain_flatten(gx, gz)
			var h: float = 0.0
			if flat < 1.0:
				# distance from the field centre drives how dramatic the terrain
				# gets: gentle rolling near the play area, big mountains + deep
				# valleys far out on the horizon.
				var dist: float = sqrt(gx * gx + gz * gz)
				var far: float = clampf((dist - 180.0) / 420.0, 0.0, 1.0)
				var local_amp: float = lerpf(28.0, 130.0, far)   # higher highs out far
				var n: float = noise.get_noise_2d(gx, gz) * 0.6 + noise2.get_noise_2d(gx, gz) * 0.2
				# ridged component for mountain peaks far out
				var r: float = 1.0 - absf(ridge.get_noise_2d(gx, gz))
				r = r * r
				var combined: float = n + (r - 0.5) * far * 1.4   # valleys + peaks
				h = combined * local_amp * (1.0 - flat)
			heights[Vector2(gx, gz)] = h
			gz += step
		gx += step

	var hmat := StandardMaterial3D.new()
	hmat.albedo_color = Color(0.29, 0.45, 0.22)
	hmat.roughness = 1.0
	hmat.cull_mode = BaseMaterial3D.CULL_DISABLED   # never cull — safety net

	# wind triangles counter-clockwise as seen from ABOVE so the top faces up
	# (the previous winding pointed normals down, so the top was being culled —
	# that was the "half the terrain disappears" bug)
	gx = -half
	while gx <= half - step + 0.1:
		var gz := -half
		while gz <= half - step + 0.1:
			# The terrain is generated EVERYWHERE as one continuous surface — flat
			# (y≈0) inside the gameplay zones, rolling outside, with a smooth ramp
			# between. This is what removes the harsh seam: there's no separate
			# flat plane fighting the terrain edge, just one mesh. (The small green
			# pitch plane still sits on top of the flat centre for the field look.)
			var p00 := Vector3(gx, heights[Vector2(gx, gz)], gz)
			var p10 := Vector3(gx + step, heights[Vector2(gx + step, gz)], gz)
			var p01 := Vector3(gx, heights[Vector2(gx, gz + step)], gz + step)
			var p11 := Vector3(gx + step, heights[Vector2(gx + step, gz + step)], gz + step)
			st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p01)
			st.add_vertex(p00); st.add_vertex(p10); st.add_vertex(p11)
			gz += step
		gx += step

	st.generate_normals()
	var terrain_mesh: ArrayMesh = st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = terrain_mesh
	mi.material_override = hmat
	mi.position = Vector3(0, -0.1, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	# COLLISION: build a SEPARATE collision mesh that omits the flat gameplay
	# footprint (x:[-240,480] z:[-180,180]). In that footprint the flat ground
	# box (Field.gd) is the player's surface; out in the hills the terrain is.
	# Keeping the two collision surfaces from OVERLAPPING removes the micro-
	# bouncing/jank the player felt where both existed at once.
	var cst := SurfaceTool.new()
	cst.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any_collision := false
	var cgx := -half
	while cgx <= half - step + 0.1:
		var cgz := -half
		while cgz <= half - step + 0.1:
			# STRUCTURAL FIX: emit collision EVERYWHERE as one continuous surface,
			# including the flat gameplay zones (which are flat at y≈0). Previously
			# we skipped the flat-box footprint and relied on a separate flat
			# collision box — but the seam between the two surfaces was the source
			# of the recurring height-change jank. One unbroken mesh = no seam.
			var q00 := Vector3(cgx, heights[Vector2(cgx, cgz)], cgz)
			var q10 := Vector3(cgx + step, heights[Vector2(cgx + step, cgz)], cgz)
			var q01 := Vector3(cgx, heights[Vector2(cgx, cgz + step)], cgz + step)
			var q11 := Vector3(cgx + step, heights[Vector2(cgx + step, cgz + step)], cgz + step)
			cst.add_vertex(q00); cst.add_vertex(q11); cst.add_vertex(q01)
			cst.add_vertex(q00); cst.add_vertex(q10); cst.add_vertex(q11)
			any_collision = true
			cgz += step
		cgx += step

	if any_collision:
		var collision_mesh: ArrayMesh = cst.commit()
		var body := StaticBody3D.new()
		body.collision_layer = 16     # player-only layer (same as the school walls)
		body.collision_mask = 0
		# collision sits at y=0 (not the visual's -0.1) so the terrain's flat
		# zones line up EXACTLY with the flat gameplay box — no half-unit step
		# between the two surfaces where the player would catch and jank.
		body.position = Vector3(0, 0.0, 0)
		var col := CollisionShape3D.new()
		col.shape = collision_mesh.create_trimesh_shape()
		body.add_child(col)
		add_child(body)

func _build_forest() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = environment_seed
	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.36, 0.24, 0.13)
	trunk_mat.roughness = 1.0

	var bx := 80.0
	var bz := 126.0
	for d in range(tree_band_depth):
		var x := -bx - d * tree_gap
		while x <= bx + d * tree_gap:
			_tree(rng, Vector3(x + rng.randf_range(-3, 3), 0, bz + d * tree_gap + rng.randf_range(-2.5, 2.5)), trunk_mat)
			_tree(rng, Vector3(x + rng.randf_range(-3, 3), 0, -(bz + d * tree_gap) + rng.randf_range(-2.5, 2.5)), trunk_mat)
			x += tree_gap + rng.randf_range(0, 6)
		var z := -bz - d * tree_gap
		while z <= bz + d * tree_gap:
			_tree(rng, Vector3(bx + d * tree_gap + rng.randf_range(-2.5, 2.5), 0, z + rng.randf_range(-3, 3)), trunk_mat)
			_tree(rng, Vector3(-(bx + d * tree_gap) + rng.randf_range(-2.5, 2.5), 0, z + rng.randf_range(-3, 3)), trunk_mat)
			z += tree_gap + rng.randf_range(0, 6)

## A tree planted at an exact ground position (its base sits at pos.y, so it
## grows out of the terrain), with shape variety: tall pines, short round bushes,
## and layered firs. `tree_scale` multiplies the overall size.
func _tree_on_ground(rng: RandomNumberGenerator, pos: Vector3, trunk_mat: Material, tree_scale: float) -> void:
	var g := Node3D.new()
	var leaf_color := Color(0.16 + rng.randf() * 0.12, 0.34 + rng.randf() * 0.16, 0.15 + rng.randf() * 0.06)
	var leaf_mat := StandardMaterial3D.new()
	leaf_mat.albedo_color = leaf_color
	leaf_mat.roughness = 1.0

	var shape := rng.randi_range(0, 2)
	if shape == 0:
		# tall pine: thin trunk, three stacked cones
		var trunk := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.5; cyl.bottom_radius = 0.8; cyl.height = 7.0
		trunk.mesh = cyl; trunk.material_override = trunk_mat; trunk.position.y = 3.5
		g.add_child(trunk)
		var c1 := _cone(3.2, 8.0, leaf_mat); c1.position.y = 9.0; g.add_child(c1)
		var c2 := _cone(2.5, 6.0, leaf_mat); c2.position.y = 12.5; g.add_child(c2)
		var c3 := _cone(1.6, 4.2, leaf_mat); c3.position.y = 15.5; g.add_child(c3)
	elif shape == 1:
		# round broadleaf: short trunk, sphere canopy
		var trunk := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.6; cyl.bottom_radius = 0.9; cyl.height = 5.0
		trunk.mesh = cyl; trunk.material_override = trunk_mat; trunk.position.y = 2.5
		g.add_child(trunk)
		var ball := MeshInstance3D.new()
		var sph := SphereMesh.new()
		sph.radius = rng.randf_range(3.0, 4.2); sph.height = sph.radius * 1.8
		ball.mesh = sph; ball.material_override = leaf_mat; ball.position.y = 7.5
		g.add_child(ball)
	else:
		# squat fir: wide low cone
		var trunk := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.5; cyl.bottom_radius = 0.7; cyl.height = 3.0
		trunk.mesh = cyl; trunk.material_override = trunk_mat; trunk.position.y = 1.5
		g.add_child(trunk)
		var c1 := _cone(3.8, 7.0, leaf_mat); c1.position.y = 5.5; g.add_child(c1)
		var c2 := _cone(2.8, 5.0, leaf_mat); c2.position.y = 9.0; g.add_child(c2)

	g.position = pos
	g.scale = Vector3(tree_scale, tree_scale, tree_scale)
	g.rotation.y = rng.randf() * TAU
	add_child(g)

func _tree(rng: RandomNumberGenerator, pos: Vector3, trunk_mat: Material) -> void:
	# keep the +X sideline corridor (benches + both sidewalks) clear of trees.
	# The main walk runs at +30 and the crossing walk reaches far out on +X, so
	# we clear a generous band; the crossing strip (near Z=0) gets extra reach.
	var fx: float = Config.FIELD_X
	if pos.x > fx + 6.0 and pos.x < fx + 46.0:
		return
	if pos.x > fx + 10.0 and absf(pos.z) < 12.0:
		return
	var g := Node3D.new()
	var trunk := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.6
	cyl.bottom_radius = 0.9
	cyl.height = 6.0
	trunk.mesh = cyl
	trunk.material_override = trunk_mat
	trunk.position.y = 3.0
	g.add_child(trunk)

	var leaf_color := Color(0.18 + rng.randf() * 0.1, 0.36 + rng.randf() * 0.12, 0.16)
	var leaf_mat := StandardMaterial3D.new()
	leaf_mat.albedo_color = leaf_color
	leaf_mat.roughness = 1.0
	var cone1 := _cone(3.4, 9.0, leaf_mat); cone1.position.y = 9.5; g.add_child(cone1)
	var cone2 := _cone(2.4, 6.3, leaf_mat); cone2.position.y = 13.0; g.add_child(cone2)

	g.position = pos
	var s := rng.randf_range(tree_scale_min, tree_scale_max)
	g.scale = Vector3(s, s, s)
	g.rotation.y = rng.randf() * TAU
	add_child(g)

func _cone(radius: float, height: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0
	cm.bottom_radius = radius
	cm.height = height
	mi.mesh = cm
	mi.material_override = mat
	return mi


var _env_res: Environment = null

## Re-apply the Settings-driven quality switches to the live environment. Mirrors
## the build-time values in _setup_sky_and_fog — keep the two in sync.
func _apply_env_quality() -> void:
	if _env_res == null:
		return
	_env_res.ssao_enabled = Settings.ambient_occlusion
	var gi: int = Settings.gi_quality
	_env_res.sdfgi_enabled = gi > 0
	_env_res.sdfgi_cascades = 4 if gi >= 2 else 2
	_env_res.ssil_enabled = Settings.indirect_light
	_env_res.ssr_enabled = Settings.reflections
	_env_res.glow_enabled = Settings.bloom
