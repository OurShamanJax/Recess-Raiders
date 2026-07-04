class_name GrassField
extends MultiMeshInstance3D
## Cheap reactive grass (the "nice but reliable" option). A MultiMesh scatters
## thousands of blades over the playable field. A shader bends blades away from up
## to 8 nearby actors whose positions we push in as uniforms each frame, giving a
## footstep-displacement feel without per-blade CPU work or physics.

@export var blade_count := 30000
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
	vheight = clamp(VERTEX.y / 0.55, 0.0, 1.0); // blade local height (tip=1)
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
	# a simple 2-triangle tapered blade — short lawn height so it carpets the
	# ground without towering over the players
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := 0.16
	var h := 0.55
	st.set_normal(Vector3.UP); st.add_vertex(Vector3(-w, 0, 0))
	st.set_normal(Vector3.UP); st.add_vertex(Vector3(w, 0, 0))
	st.set_normal(Vector3.UP); st.add_vertex(Vector3(0, h, 0))
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
