// Camera-projected footprint for RT course materials, in world metres along unit axes.
// This intersects a one-pixel camera offset with the local surface plane; it is a
// primary-camera approximation, not propagated differentials for secondary rays.
// Stage built-ins are supplied by fragment(); this helper only reads parameters.
vec2 rs_rt_pixel_footprint(vec3 world_pos, vec3 world_normal, vec3 axis_u, vec3 axis_v,
		vec3 camera_pos, mat4 inv_view, mat4 projection, vec2 viewport_size) {
	vec3 camera_right = normalize(inv_view[0].xyz);
	vec3 camera_up = normalize(inv_view[1].xyz);
	vec3 camera_back = normalize(inv_view[2].xyz);
	vec3 camera_delta = world_pos - camera_pos;
	bool orthographic = abs(projection[3][3]) > 0.5;
	float depth = orthographic ? 1.0 : max(abs(dot(camera_delta, camera_back)), 0.001);
	vec2 projection_scale = max(abs(vec2(projection[0][0], projection[1][1])), vec2(0.0001));
	vec2 pixel_span = 2.0 * depth / (projection_scale * max(viewport_size, vec2(1.0)));
	vec3 ray = orthographic ? -camera_back : camera_delta / max(length(camera_delta), 0.001);
	vec3 surface_normal = normalize(world_normal);
	float incidence = dot(surface_normal, ray);
	// Bound the grazing-angle expansion instead of dividing by a near-zero cosine.
	float denominator = (incidence < 0.0 ? -1.0 : 1.0) * max(abs(incidence), 0.05);
	vec3 dx = camera_right * pixel_span.x;
	vec3 dy = camera_up * pixel_span.y;
	dx -= ray * (dot(surface_normal, dx) / denominator);
	dy -= ray * (dot(surface_normal, dy) / denominator);
	return max(vec2(abs(dot(dx, axis_u)) + abs(dot(dy, axis_u)),
		abs(dot(dx, axis_v)) + abs(dot(dy, axis_v))), vec2(0.00001));
}
