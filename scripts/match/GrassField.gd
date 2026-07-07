class_name GrassField
extends MultiMeshInstance3D
## Cheap reactive grass (the "nice but reliable" option). A MultiMesh scatters
## thousands of blades over the playable field. A shader bends blades away from up
## to 8 nearby actors whose positions we push in as uniforms each frame, giving a
## footstep-displacement feel without per-blade CPU work or physics.

@export var blade_count := 9000
@export var area_x := 120.0
@export var area_z := 215.0
@export var influence_radius := 6.0
@export var bend_strength := 0.7

var _mat: ShaderMaterial

const GRASS_SHADER := """
shader_type spatial;
render_mode cull_disabled, world_vertex_coords;

uniform vec4 base_color : source_color = vec4(0.30, 0.55, 0.24, 1.0);
uniform vec4 tip_color  : source_color = vec4(0.55, 0.78, 0.35, 1.0);
uniform float influence_radius = 6.0;
uniform float bend_strength = 1.4;
uniform float sway_amp = 0.12;
uniform vec3 actors[8];
uniform int actor_count = 0;
uniform float time_s = 0.0;

varying float vheight;

void vertex() {
	vheight = clamp(VERTEX.y / 0.5, 0.0, 1.0); // blade local height (tip=1)
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// idle sway on the tip
	float s = sin(time_s * 1.6 + world.x * 0.25 + world.z * 0.25) * sway_amp * vheight;
	world.x += s;
	// bend away from nearby actors (footstep displacement)
	for (int i = 0; i < 8; i++) {
		if (i >= actor_count) break;
		vec3 a = actors[i];
		vec2 d = world.xz - a.xz;
		float dist = length(d);
		if (dist < influence_radius) {
			float f = (1.0 - dist / influence_radius);
			f = f * f;
			vec2 dir = (dist > 0.001) ? normalize(d) : vec2(1.0, 0.0);
			world.xz += dir * f * bend_strength * vheight;
			world.y -= f * bend_strength * 0.55 * vheight; // press down
		}
	}
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
}

void fragment() {
	ALBEDO = mix(base_color.rgb, tip_color.rgb, vheight);
	ROUGHNESS = 1.0;
}
"""

func build() -> void:
	var blade := _make_blade_mesh()
	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = GRASS_SHADER
	_mat.shader = sh
	_mat.set_shader_parameter("influence_radius", influence_radius)
	_mat.set_shader_parameter("bend_strength", bend_strength)
	blade.surface_set_material(0, _mat)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = blade
	mm.instance_count = blade_count
	var rng := RandomNumberGenerator.new()
	rng.seed = Config.ENVIRONMENT_SEED + 7
	for i in range(blade_count):
		var x := rng.randf_range(-area_x * 0.5, area_x * 0.5)
		var z := rng.randf_range(-area_z * 0.5, area_z * 0.5)
		var b := Basis()
		b = b.rotated(Vector3.UP, rng.randf() * TAU)
		var sc := rng.randf_range(0.8, 1.2)
		b = b.scaled(Vector3(sc, rng.randf_range(0.7, 1.1), sc))
		mm.set_instance_transform(i, Transform3D(b, Vector3(x, 0, z)))
	multimesh = mm
	# grass is presentation-only; don't cast heavy shadows
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _make_blade_mesh() -> ArrayMesh:
	# A tuft of several curved, tapered blades (not a single flat spike). Each
	# blade is built from stacked segments that taper to a point and curve over
	# slightly, so from a distance the field reads as soft lawn grass rather than
	# spiky triangles. A few blades per instance at varied angles make each
	# scattered point a small clump.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var blades_per_tuft := 5
	var segments := 4
	var base_h := 0.5

	for b in range(blades_per_tuft):
		# spread the blades of a tuft out in a small fan with varied lean + height
		var ang := (float(b) / float(blades_per_tuft)) * TAU
		var lean := 0.12 + 0.06 * float(b % 3)          # how far it curves over
		var bh := base_h * (0.75 + 0.5 * fmod(float(b) * 0.37, 1.0))
		var half_w := 0.055                              # blade half-width at base
		var off := Vector3(cos(ang), 0.0, sin(ang)) * 0.06 * float(b)
		var curve_dir := Vector3(cos(ang + 0.6), 0.0, sin(ang + 0.6))

		var prev_l: Vector3
		var prev_r: Vector3
		for s in range(segments + 1):
			var t := float(s) / float(segments)
			# taper width to a point at the tip
			var w := half_w * (1.0 - t)
			# height rises, curve pushes sideways more toward the tip (quadratic)
			var y := bh * t
			var bend := curve_dir * lean * t * t
			var center := off + Vector3(bend.x, y, bend.z)
			# blade faces roughly outward; width axis perpendicular to curve dir
			var side := Vector3(-curve_dir.z, 0.0, curve_dir.x) * w
			var l := center - side
			var r := center + side
			if s > 0:
				# two triangles for the quad between this segment and the last
				st.set_normal(Vector3.UP); st.add_vertex(prev_l)
				st.set_normal(Vector3.UP); st.add_vertex(prev_r)
				st.set_normal(Vector3.UP); st.add_vertex(l)
				st.set_normal(Vector3.UP); st.add_vertex(r)
				st.set_normal(Vector3.UP); st.add_vertex(l)
				st.set_normal(Vector3.UP); st.add_vertex(prev_r)
			prev_l = l
			prev_r = r
	return st.commit()

func _process(_delta: float) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("time_s", float(Time.get_ticks_msec()) * 0.001)
	# gather up to 8 actors near the camera target for blade-displacement
	var arr: Array = GameState.actors()
	var pts: PackedVector3Array = PackedVector3Array()
	var n := mini(arr.size(), 8)
	for i in range(n):
		pts.append(arr[i].global_position)
	_mat.set_shader_parameter("actors", pts)
	_mat.set_shader_parameter("actor_count", n)
