class_name NavManager
extends Node3D
## Builds a runtime NavigationRegion3D over the playable field so AI bots path
## AROUND the border-cone field instead of straight through it.
##
## Why runtime (not an editor-baked navmesh): the field ground is built
## procedurally in Field.gd at match start, so there is no authored scene
## geometry for the editor's "Bake NavMesh" button to read. We instead bake from
## procedural source geometry: a flat quad over the known field bounds as the
## traversable surface, plus one projected obstruction per border cone (carved
## out), then bake via NavigationServer3D. (Pattern per Godot 4.6 docs:
## NavigationMeshSourceGeometryData3D.add_faces + add_projected_obstruction +
## NavigationServer3D.bake_from_source_geometry_data.)
##
## Fail-safe & additive: AIController._seek() reads the next path corner from each
## actor's NavigationAgent3D. If this region never built or the bake hasn't
## finished, the agent returns the raw target position, so movement simply falls
## back to the old straight-line seek. Nothing breaks if navigation is off.

var _region: NavigationRegion3D = null
var _source: NavigationMeshSourceGeometryData3D = null
var _navmesh: NavigationMesh = null
# pending cone obstructions: each is [center: Vector3, radius: float]
var _cone_obstructions: Array = []

## Register a border cone to be carved out of the navmesh. Call BEFORE build()
## (ConeManager spawns cones first, then Match calls build()). center is the
## cone's world position; radius is its footprint plus clearance.
func add_cone_obstruction(center: Vector3, radius: float) -> void:
	_cone_obstructions.append([center, radius])

## Build + bake the field navmesh. Call AFTER Field.build() and ConeManager so
## the bounds are known and the cone list is populated.
func build() -> void:
	_region = NavigationRegion3D.new()
	add_child(_region)

	_navmesh = NavigationMesh.new()
	# bake agent radius matched to the actors' NavigationAgent3D radius (~2.0) so
	# carved corridors aren't narrower than the bots that path through them.
	_navmesh.agent_radius = 2.0
	_navmesh.agent_height = 4.0
	_navmesh.cell_size = 0.5
	_navmesh.cell_height = 0.5
	# keep agent_max_climb a clean multiple of cell_height (0.5) to avoid the
	# "floored to cell_height voxel units" precision warning, and generous so the
	# flat field plane is fully walkable despite tiny y variation.
	_navmesh.agent_max_climb = 0.5
	_navmesh.agent_max_slope = 45.0
	_region.navigation_mesh = _navmesh

	_source = NavigationMeshSourceGeometryData3D.new()

	# Traversable ground: a flat quad at y=0 over the field, two triangles.
	# add_faces expects triangle vertices in CLOCKWISE winding (per Godot docs).
	var hx := Config.FIELD_X - 2.0
	var hz := Config.FIELD_Z + 4.0
	var p0 := Vector3(-hx, 0.0, -hz)
	var p1 := Vector3(hx, 0.0, -hz)
	var p2 := Vector3(hx, 0.0, hz)
	var p3 := Vector3(-hx, 0.0, hz)
	# clockwise (viewed from +Y down): p0 -> p3 -> p2 and p0 -> p2 -> p1
	var faces := PackedVector3Array([p0, p3, p2, p0, p2, p1])
	_source.add_faces(faces, Transform3D.IDENTITY)

	# Carve each border cone as a projected obstruction (a small square outline
	# around the cone center). carve=true makes it a clean stencil through the
	# already-offset navmesh so agents route around it.
	for entry in _cone_obstructions:
		var center: Vector3 = entry[0]
		var r: float = entry[1]
		var outline := PackedVector3Array([
			Vector3(center.x - r, 0.0, center.z - r),
			Vector3(center.x + r, 0.0, center.z - r),
			Vector3(center.x + r, 0.0, center.z + r),
			Vector3(center.x - r, 0.0, center.z + r),
		])
		_source.add_projected_obstruction(outline, 0.0, 4.0, true)

	# Bake deferred: per Godot docs, runtime geometry parsing/baking wants to run
	# after the first frame settles (avoids common first-frame parse issues). The
	# region auto-registers on the world's default 3D navigation map when added to
	# the tree; assigning the baked mesh updates it.
	_bake.call_deferred()

func _bake() -> void:
	if _navmesh == null or _source == null:
		return
	NavigationServer3D.bake_from_source_geometry_data(_navmesh, _source)
	_region.navigation_mesh = _navmesh
	# DIAGNOSTIC (remove once nav is confirmed): report whether the bake produced
	# walkable polygons. If this prints 0, the bake is empty (geometry/winding/
	# param problem). If it prints >0 but bots still freeze, it's a map-sync or
	# agent-query problem, not the bake. Either way the _seek guard keeps bots
	# moving via straight-line fallback.
	var poly_count := _navmesh.get_polygon_count()
	var vert_count := _navmesh.get_vertices().size()
	print("[NavManager] navmesh baked: %d polygons, %d vertices" % [poly_count, vert_count])
