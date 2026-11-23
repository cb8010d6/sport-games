// Building walls. UV is in metres (u along the wall, v up from street level); the wall colour
// comes from the vertex colour so every building shares one material. Scanned plaster, a grid of
// windows with frames, sills and louvred shutters, and behind the glass a room drawn with
// interior mapping (a box intersected per pixel, so it shifts with the view like a real room).
// The ground floor is shops: lit display windows or roller shutters.
shader_type spatial;

#if defined(RT)
#include "res://shaders/rt_pixel_footprint.gdshaderinc"
#endif

uniform sampler2D plaster_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D plaster_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D plaster_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float plaster_size = 3.0;
uniform vec4 frame_color : source_color = vec4(0.92, 0.91, 0.87, 1.0);
uniform vec4 stone_color : source_color = vec4(0.82, 0.79, 0.73, 1.0);
uniform vec4 lit_color : source_color = vec4(1.0, 0.74, 0.45, 1.0);
uniform float lit_energy = 1.6;
uniform float cell_w = 3.0;
uniform float cell_h = 3.2;
uniform float shop_h = 4.0;
uniform float shop_w = 6.0;
// The glass reflects a stand-in street (screen-space reflections can't see what is beside or
// behind the camera, and the sky's lower half is bare ground): the row of buildings opposite,
// the paving, and the scanned sky above them.
uniform sampler2D sky_pano : filter_linear_mipmap, repeat_enable;
uniform float sky_energy = 0.85;
uniform float street_w = 28.8;
uniform vec3 sun_dir = vec3(0.61, 0.52, -0.78);

varying vec3 wpos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

float box(vec2 p, vec2 lo, vec2 hi, vec2 rt_footprint) {
#if defined(RT)
	vec2 w = rt_footprint * 0.75;
#else
	// The supplied RT footprint is unused here; preserve the raster derivative.
	vec2 w = fwidth(p) * 0.75;
#endif
	vec2 a = smoothstep(lo - w, lo + w, p) * (1.0 - smoothstep(hi - w, hi + w, p));
	return a.x * a.y;
}

// Room behind a window. p: point on the glass in window-local metres (x across, y up, origin at
// the window's bottom-left), rd: view ray in the same frame with z going into the building.
// Returns the room colour; .a carries how much it should glow when lit.
vec4 room(vec2 p, vec3 rd, vec2 win, float depth, float seed, bool shop) {
	vec3 lo = vec3(-0.6, -0.9, 0.0);
	vec3 hi = vec3(win.x + 0.6, win.y + 0.5, depth);
	vec3 ro = vec3(p, 0.0);
	vec3 inv = 1.0 / rd;
	vec3 t1 = (lo - ro) * inv;
	vec3 t2 = (hi - ro) * inv;
	vec3 tf = max(t1, t2);
	float t = min(min(tf.x, tf.y), tf.z);
	vec3 h = ro + rd * t;
	float r1 = hash(vec2(seed, 1.7));
	float r2 = hash(vec2(seed, 9.1));
	vec3 wall = mix(vec3(0.72, 0.62, 0.5), vec3(0.5, 0.58, 0.62), r1) * mix(0.6, 1.0, r2);
	vec3 col;
	float glow = 1.0;
	if (t == tf.z) {
		col = wall;
		if (shop) {
			// Shelves full of goods on the back wall.
			float shelf = step(0.82, fract(h.y * 2.2));
			float goods = step(0.35, hash(floor(vec2(h.x * 6.0, h.y * 2.2)) + seed));
			vec3 g = mix(vec3(0.85, 0.3, 0.25), vec3(0.25, 0.45, 0.8), hash(floor(vec2(h.x * 6.0, h.y * 2.2)) + 4.0 + seed));
			col = mix(mix(col, g, goods * (1.0 - shelf) * step(0.2, h.y)), vec3(0.35, 0.3, 0.27), shelf);
		} else {
			// A picture frame on some walls.
			vec2 c = h.xy - vec2(win.x * 0.5 + (r1 - 0.5), win.y * 0.6);
			float pic = step(abs(c.x), 0.35) * step(abs(c.y), 0.25) * step(0.5, r2);
			col = mix(col, mix(vec3(0.2, 0.3, 0.45), vec3(0.75, 0.5, 0.3), r1), pic);
		}
	} else if (t == tf.y) {
		if (rd.y < 0.0) {
			// Floor: wooden boards.
			col = mix(vec3(0.42, 0.28, 0.18), vec3(0.55, 0.38, 0.24), hash(vec2(floor(h.x * 5.0), seed)));
			glow = 0.6;
		} else {
			col = vec3(0.9, 0.88, 0.84);   // ceiling, where the lamp is
			glow = 1.4;
		}
	} else {
		col = wall * 0.82;
	}
	// Darker toward the back, like real rooms.
	col *= mix(1.0, 0.55, clamp(h.z / depth, 0.0, 1.0));
	return vec4(col, glow);
}

vec3 sky(vec3 d) {
	vec2 suv = vec2(atan(d.x, -d.z) / 6.2831853 + 0.5, acos(clamp(d.y, -1.0, 1.0)) / 3.1415927);
	return textureLod(sky_pano, suv, 2.0).rgb * sky_energy;
}

// What a window at uv (metres along the wall, height) sees mirrored: rd is the view ray in the
// wall frame (z into the building), n_w / ray the wall normal and view ray in world space.
vec3 street_reflection(vec2 uv, vec3 rd, vec3 n_w, vec3 ray) {
	vec3 rw = reflect(ray, n_w);
	float t = street_w / max(rd.z, 0.02);
	float y_hit = uv.y + rd.y * t;
	float x_hit = uv.x + rd.x * t;
	float lit = max(dot(-n_w, normalize(sun_dir)), 0.0);
	if (rd.y < 0.0 && uv.y / -rd.y < t) {
		// The paving between here and the far side.
		return vec3(0.42, 0.36, 0.31) * (0.35 + 0.9 * clamp(sun_dir.y, 0.0, 1.0));
	}
	float bid = floor(x_hit / 17.0);
	float bh = 9.0 + 12.0 * hash(vec2(bid, 3.1));
	if (y_hit < bh) {
		vec3 plaster = mix(vec3(0.78, 0.55, 0.42), vec3(0.85, 0.78, 0.62), hash(vec2(bid, 7.7)));
		plaster = mix(plaster, vec3(0.55, 0.62, 0.68), step(0.75, hash(vec2(bid, 1.3))));
		vec2 c = vec2(fract(x_hit / 3.0) * 3.0, fract((y_hit - 4.0) / 3.2) * 3.2);
		float win = step(4.0, y_hit) * step(0.85, c.x) * step(c.x, 2.15) * step(0.8, c.y) * step(c.y, 2.65);
		float shop = step(y_hit, 3.2) * step(0.5, fract(x_hit / 6.0) * 6.0) * step(fract(x_hit / 6.0) * 6.0, 5.5);
		vec3 col = plaster * (0.3 + 1.6 * lit);
		col = mix(col, vec3(0.05, 0.06, 0.07) + sky(vec3(rw.x, abs(rw.y), rw.z)) * 0.15, max(win, shop));
		return col;
	}
	return sky(vec3(rw.x, max(rw.y, 0.02), rw.z));
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = UV;
	vec3 wall = COLOR.rgb;

	// Tangent frame in world space: n out of the wall, up, and u's direction along it.
	vec3 n_w = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 up = vec3(0.0, 1.0, 0.0);
	// Unused on raster; the box helper still computes fwidth(p).
	vec2 box_footprint = vec2(0.0);
#if defined(RT)
	// RSSkateCourse generates tangents from each facade's explicit UVs. This follows
	// increasing U on both street sides and end walls, including mirrored UV frames.
	vec3 t_w = normalize((INV_VIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
	box_footprint = rs_rt_pixel_footprint(wpos, n_w, t_w, up,
		CAMERA_POSITION_WORLD, INV_VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
#else
	vec3 t_w = normalize(cross(up, n_w));
	vec3 dpx = dFdx(wpos);
	vec3 dpy = dFdy(wpos);
	float su = dot(dpx, t_w) * dFdx(uv.x) + dot(dpy, t_w) * dFdy(uv.x);
	t_w *= su < 0.0 ? -1.0 : 1.0;
#endif
	vec3 ray = normalize(wpos - CAMERA_POSITION_WORLD);
	vec3 rd = vec3(dot(ray, t_w), dot(ray, up), -dot(ray, n_w));

	vec2 puv = uv / plaster_size;
	vec3 alb = texture(plaster_albedo, puv).rgb * wall * 1.25;
	vec3 nrm = texture(plaster_normal, puv).rgb;
	vec3 orm = texture(plaster_orm, puv).rgb;
	float rough = orm.g;
	float metal = 0.0;
	float spec = 0.5;
	vec3 emit = vec3(0.0);
	float grime = smoothstep(1.4, 0.0, uv.y) * 0.25;   // splash dirt at the foot of the wall
	alb *= 1.0 - grime;

	if (uv.y < shop_h) {
		vec2 id = vec2(floor(uv.x / shop_w), 7.0);
		vec2 c = vec2(fract(uv.x / shop_w) * shop_w, uv.y);
		float seed = hash(id + floor(wpos.x * 0.01));
		float plinth = box(c, vec2(-1.0, -1.0), vec2(shop_w + 1.0, 0.45), box_footprint);
		float sign_band = box(c, vec2(0.0, 3.25), vec2(shop_w, 3.9), box_footprint);
		vec2 g0 = vec2(0.45, 0.5);
		vec2 g1 = vec2(shop_w - 0.45, 3.05);
		float glass = box(c, g0, g1, box_footprint);
		float frame = box(c, g0 - 0.1, g1 + 0.1, box_footprint) - glass;
		bool shutter = seed < 0.3;
		if (!shutter) {
			// Shopfront joinery: two mullions (one side of the door) and a transom over it.
			float m1 = box(c, vec2(shop_w * 0.36 - 0.05, g0.y), vec2(shop_w * 0.36 + 0.05, g1.y), box_footprint);
			float m2 = box(c, vec2(shop_w * 0.64 - 0.05, g0.y), vec2(shop_w * 0.64 + 0.05, g1.y), box_footprint);
			float tr = box(c, vec2(shop_w * 0.36, 2.45), vec2(shop_w * 0.64, 2.55), box_footprint);
			float handle = box(c, vec2(shop_w * 0.6 - 0.03, 1.0), vec2(shop_w * 0.6, 1.5), box_footprint);
			float bars = clamp(m1 + m2 + tr + handle, 0.0, 1.0) * glass;
			glass -= bars;
			frame += bars;
		}
		alb = mix(alb, stone_color.rgb * texture(plaster_albedo, puv * 1.7).rgb * 1.3, plinth);
		alb = mix(alb, mix(vec3(0.12, 0.25, 0.3), vec3(0.45, 0.12, 0.1), hash(id + 2.0)), sign_band);
		if (shutter) {
			// Roller shutter: corrugated metal, painted, with some tags.
			float ribs = sin(c.y * 40.0);
			vec3 paint = mix(vec3(0.62, 0.63, 0.62), vec3(0.3, 0.45, 0.55), hash(id + 5.0));
			float tag = smoothstep(0.55, 0.6, sin(c.x * 2.3 + sin(c.y * 3.1) * 1.5 + seed * 20.0)) * step(c.y, 2.4) * step(0.9, c.y);
			paint = mix(paint, mix(vec3(0.9, 0.2, 0.5), vec3(0.2, 0.8, 0.4), hash(id + 9.0)), tag * 0.8);
			alb = mix(alb, paint, glass);
			nrm = mix(nrm, vec3(0.5, 0.5 + ribs * 0.35, 1.0), glass);
			rough = mix(rough, 0.45, glass);
			metal = 0.6 * glass;
		} else {
			vec4 rm = room(c - g0, rd, g1 - g0, 5.0, seed * 31.0, true);
			float fres = 0.04 + 0.96 * pow(1.0 - clamp(rd.z, 0.0, 1.0), 5.0);
			// Glass has no diffuse colour of its own: the shop shows through it as light (dimmer
			// than the sunny street, the back darker), the rest is the reflection of the street.
			float smear = vnoise(c * vec2(1.3, 0.6) + seed * 10.0);
			alb = mix(alb, vec3(0.01), glass);
			emit += rm.rgb * rm.rgb * lit_color.rgb * lit_energy * 0.3 * rm.a * glass * (1.0 - fres);
			emit += street_reflection(uv, rd, n_w, ray) * fres * (0.7 - 0.2 * smear) * glass;
			rough = mix(rough, mix(0.02, 0.09, smear * smear), glass);
			metal = mix(metal, 0.0, glass);
			spec = mix(spec, 0.0, glass);
		}
		alb = mix(alb, vec3(0.08, 0.08, 0.09), frame);
		rough = mix(rough, 0.35, frame);
		metal = mix(metal, 0.8, frame);
	} else {
		vec2 id = floor(vec2(uv.x / cell_w, (uv.y - shop_h) / cell_h));
		vec2 c = vec2(fract(uv.x / cell_w) * cell_w, fract((uv.y - shop_h) / cell_h) * cell_h);
		float seed = hash(id + floor(wpos.x * 0.01) * 3.0 + floor(wpos.z * 0.05));
		float bseed = hash(vec2(floor(wpos.x * 0.01), floor(uv.x / 37.0)));
		vec2 g0 = vec2(0.85, 0.8);
		vec2 g1 = vec2(cell_w - 0.85, cell_h - 0.55);
		float glass = box(c, g0, g1, box_footprint);
		float frame = box(c, g0 - 0.09, g1 + 0.09, box_footprint) - glass;
		float mullion = box(c, vec2(cell_w * 0.5 - 0.03, g0.y), vec2(cell_w * 0.5 + 0.03, g1.y), box_footprint) * glass;
		float sill = box(c, vec2(g0.x - 0.18, g0.y - 0.2), vec2(g1.x + 0.18, g0.y - 0.06), box_footprint);
		float lintel = box(c, vec2(g0.x - 0.12, g1.y + 0.09), vec2(g1.x + 0.12, g1.y + 0.24), box_footprint);
		// Louvred shutters each side on some buildings, open flat against the wall.
		float sh = step(0.45, bseed) * (box(c, vec2(g0.x - 0.62, g0.y), vec2(g0.x - 0.12, g1.y), box_footprint) + box(c, vec2(g1.x + 0.12, g0.y), vec2(g1.x + 0.62, g1.y), box_footprint));
		vec3 sh_col = mix(vec3(0.16, 0.38, 0.3), vec3(0.2, 0.33, 0.5), step(0.7, bseed));
		sh_col = mix(sh_col, vec3(0.55, 0.32, 0.2), step(0.85, bseed));
		float slats = sin(c.y * 48.0);

		vec4 rm = room(c - g0, rd, g1 - g0, 3.4, seed * 17.0, false);
		bool lit = seed > 0.62;
		// Half-drawn curtains in some windows.
		vec2 wl = (c - g0) / (g1 - g0);
		float curtain = step(0.5, hash(id + 3.3)) * (step(wl.x, 0.22 + 0.1 * sin(wl.y * 30.0) * 0.1) + step(0.78, wl.x));
		vec3 cur_col = mix(vec3(0.85, 0.82, 0.72), vec3(0.65, 0.3, 0.25), hash(id + 6.1));
		vec3 inside = mix(rm.rgb, cur_col, curtain);
		float fres = 0.04 + 0.96 * pow(1.0 - clamp(rd.z, 0.0, 1.0), 5.0);
		float pane = glass * (1.0 - mullion);
		// As in the shops: the room comes through as light, the pane itself only reflects.
		alb = mix(alb, vec3(0.01), pane);
		emit += inside * (lit ? lit_color.rgb * lit_energy * 0.7 * rm.a : vec3(0.1)) * pane * (1.0 - fres);
		emit += street_reflection(uv, rd, n_w, ray) * fres * 0.75 * pane;
		rough = mix(rough, 0.03, pane);
		spec = mix(spec, 0.0, pane);

		alb = mix(alb, sh_col * (0.85 + 0.15 * slats), clamp(sh, 0.0, 1.0));
		nrm = mix(nrm, vec3(0.5, 0.5 + slats * 0.3, 1.0), clamp(sh, 0.0, 1.0));
		float trim = clamp(frame + mullion, 0.0, 1.0);
		alb = mix(alb, frame_color.rgb, trim);
		rough = mix(rough, 0.5, trim);
		float stone = clamp(sill + lintel, 0.0, 1.0);
		alb = mix(alb, stone_color.rgb * texture(plaster_albedo, puv * 2.3).rgb * 1.3, stone);
		// Sills stand out of the wall a little: tilt their normal.
		nrm = mix(nrm, vec3(0.5, 0.15, 1.0), sill * 0.5);
		// Faint line at each floor.
		alb *= 1.0 - 0.07 * box(c, vec2(-1.0, 0.0), vec2(cell_w + 1.0, 0.12), box_footprint);
	}

	ALBEDO = alb;
	ROUGHNESS = rough;
	METALLIC = metal;
	SPECULAR = spec;
	AO = orm.r;
	AO_LIGHT_AFFECT = 0.3;
	NORMAL_MAP = nrm;
	EMISSION = emit;
}
