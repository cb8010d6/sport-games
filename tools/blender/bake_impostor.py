"""Blender (headless) script: bake a hemi-octahedral impostor of a (heavy) tree model.

    blender --background --factory-startup --python tools/blender/bake_impostor.py -- in.gltf out_dir name [object] [frames] [px]

The model is rendered with Cycles from frames x frames directions over the upper hemisphere
(hemi-octahedral layout: grid cell (i, j) looks along hemi_dir(u, v)), orthographic, framed on
its bounding sphere. Two atlases come out:

    <name>_albedo.png   rgb = surface colour (times a little baked ambient occlusion), a = coverage
    <name>_normal.png   rgb = surface normal in Godot axes (x right, y up, z back) * 0.5 + 0.5,
                        a = 1 on leaves / needles, 0 on bark (for back lighting)

and <name>.json with the bounding sphere (centre above the ground point, radius) in metres.
Transparent texels are filled with the nearest colours so mipmaps don't fringe. Godot draws one
camera-facing quad per tree and picks the frames for the view (shaders/impostor.gdshader).
"""
import json
import os
import sys

import bpy
import numpy as np
from mathutils import Vector

LEAF_HINTS = ("leaves", "leaf", "twig", "needle", "foliage")


def hemi_dir(u, v):
    """Grid coordinates in [-1, 1]^2 -> unit direction (Blender axes, z up), z >= 0."""
    x = (u + v) * 0.5
    y = (u - v) * 0.5
    z = 1.0 - abs(x) - abs(y)
    d = Vector((x, y, z))
    return d.normalized()


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    src, out_dir, name = os.path.abspath(argv[0]), os.path.abspath(argv[1]), argv[2]
    pick = argv[3] if len(argv) > 3 and argv[3] != "-" else None
    frames = int(argv[4]) if len(argv) > 4 else 8
    px = int(argv[5]) if len(argv) > 5 else 384
    os.makedirs(out_dir, exist_ok=True)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)
    scene = bpy.context.scene
    meshes = [o for o in scene.objects if o.type == "MESH"]
    if pick:
        for o in meshes:
            if o.name != pick:
                bpy.data.objects.remove(o, do_unlink=True)
        meshes = [o for o in scene.objects if o.type == "MESH"]
    # Leaves get pass index 1 (mask), and render opaque where the texture is (no alpha blend).
    for m in bpy.data.materials:
        leafy = any(h in m.name.lower() for h in LEAF_HINTS)
        m.pass_index = 1 if leafy else 0
        if hasattr(m, "blend_method"):
            m.blend_method = "HASHED" if m.blend_method in ("BLEND", "HASHED") else m.blend_method

    # Bounding sphere around the vertices (centre = bbox centre), ground point = lowest point.
    pts = []
    for o in meshes:
        n = len(o.data.vertices)
        co = np.empty(n * 3, np.float32)
        o.data.vertices.foreach_get("co", co)
        co = co.reshape(-1, 3)
        mw = np.array(o.matrix_world, np.float32)
        pts.append(co @ mw[:3, :3].T + mw[:3, 3])
    pts = np.concatenate(pts)
    lo, hi = pts.min(0), pts.max(0)
    c = (lo + hi) * 0.5
    r = float(np.sqrt(((pts - c) ** 2).sum(1)).max()) * 1.01
    ground = Vector((float(c[0]), float(c[1]), float(lo[2])))
    centre = Vector((float(c[0]), float(c[1]), float(c[2])))
    print(f"[impostor] {name}: {len(pts)} verts, size {hi - lo}, radius {r:.2f}")

    # Render setup: Cycles, transparent film, diffuse colour + normal + AO + material index.
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 24
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 2
    scene.render.film_transparent = True
    scene.render.resolution_x = px * 2
    scene.render.resolution_y = px * 2
    scene.render.resolution_percentage = 100
    scene.world = bpy.data.worlds.new("w")
    scene.world.color = (1, 1, 1)
    vl = scene.view_layers[0]
    vl.use_pass_diffuse_color = True
    vl.use_pass_normal = True
    vl.use_pass_ambient_occlusion = True
    vl.use_pass_material_index = True
    scene.world.light_settings.distance = r * 0.12

    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = r * 2.0
    cam_data.clip_start = 0.01
    cam_data.clip_end = r * 4.0
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam

    # Compositor: write the passes as EXR layers so they can be read back as floats.
    scene.use_nodes = True
    tree = scene.node_tree
    tree.nodes.clear()
    rl = tree.nodes.new("CompositorNodeRLayers")
    out = tree.nodes.new("CompositorNodeOutputFile")
    out.format.file_format = "OPEN_EXR_MULTILAYER"
    out.format.color_depth = "16"
    out.base_path = os.path.join(out_dir, "_frames", name + "_")
    out.file_slots.clear()
    for slot in ("DiffCol", "Normal", "AO", "Alpha", "IndexMA"):
        out.file_slots.new(slot)
        tree.links.new(rl.outputs[slot], out.inputs[slot])

    atlas_a = np.zeros((frames * px, frames * px, 4), np.float32)
    atlas_n = np.zeros((frames * px, frames * px, 4), np.float32)
    for j in range(frames):
        for i in range(frames):
            u = (i + 0.5) / frames * 2.0 - 1.0
            v = (j + 0.5) / frames * 2.0 - 1.0
            d = hemi_dir(u, v)
            # Camera on the sphere, looking at the centre; "up" = world up as far as it goes
            # (the same rule as the game's billboard), +y for straight down.
            up = Vector((0, 0, 1)) if abs(d.z) < 0.999 else Vector((0, 1, 0))
            right = up.cross(d).normalized()
            cup = d.cross(right).normalized()
            cam.location = centre + d * (r * 2.0)
            m = cam.matrix_world.copy()
            m.col[0][:3] = right
            m.col[1][:3] = cup
            m.col[2][:3] = d
            m.col[3][:3] = cam.location
            cam.matrix_world = m
            scene.frame_current = j * frames + i
            bpy.ops.render.render(write_still=False)
            path = out.base_path + f"{scene.frame_current:04d}.exr"
            layers = read_exr_layers(path)
            os.remove(path)
            col, nor, ao, alpha, idx = (layers[k] for k in ("DiffCol", "Normal", "AO", "Alpha", "IndexMA"))
            col = downsample(col[..., :3])
            nor = downsample(nor[..., :3])
            ao = downsample(ao[..., :1])
            alpha = downsample(alpha[..., :1])
            leaf = downsample((idx[..., :1] > 0.5).astype(np.float32))
            a = np.clip(alpha, 0.0, 1.0)
            safe = np.maximum(a, 1e-4)
            col = col / safe
            nor = nor / safe
            ao = ao / safe
            shade = 0.55 + 0.45 * np.clip(ao, 0.0, 1.0)
            rgb = np.clip(col * shade, 0.0, 1.0)
            # Blender world normal (x, y, z up) -> Godot (x, z, -y).
            n = np.stack([nor[..., 0], nor[..., 2], -nor[..., 1]], -1)
            n /= np.maximum(np.linalg.norm(n, axis=-1, keepdims=True), 1e-5)
            y0 = (frames - 1 - j) * px      # image rows run top-down; frame row j=0 at the bottom
            x0 = i * px
            atlas_a[y0:y0 + px, x0:x0 + px, :3] = rgb
            atlas_a[y0:y0 + px, x0:x0 + px, 3:] = a
            atlas_n[y0:y0 + px, x0:x0 + px, :3] = n * 0.5 + 0.5
            atlas_n[y0:y0 + px, x0:x0 + px, 3:] = np.clip(leaf / safe, 0.0, 1.0)
            print(f"[impostor] frame {j * frames + i + 1}/{frames * frames}")

    fill_transparent(atlas_a, atlas_n)
    save_png(atlas_a, os.path.join(out_dir, name + "_albedo.png"), srgb=True)
    save_png(atlas_n, os.path.join(out_dir, name + "_normal.png"), srgb=False)
    meta = {"frames": frames, "radius": r, "centre_up": float(centre.z - ground.z),
            "height": float(hi[2] - lo[2]), "width": float(max(hi[0] - lo[0], hi[1] - lo[1]))}
    with open(os.path.join(out_dir, name + ".json"), "w") as f:
        json.dump(meta, f, indent=1)
    print(f"[impostor] wrote {name}: {meta}")


def read_exr_layers(path):
    """Multilayer EXR -> {pass name: (h, w, c) float array}, rows top-down."""
    import OpenImageIO as oiio  # bundled with Blender 4.x
    out = {}
    inp = oiio.ImageInput.open(path)
    spec = inp.spec()
    data = inp.read_image(0, 0, 0, spec.nchannels, "float")
    inp.close()
    data = np.asarray(data).reshape(spec.height, spec.width, spec.nchannels)
    names = list(spec.channelnames)
    groups = {}
    for k, ch in enumerate(names):
        layer = ch.rsplit(".", 1)[0]
        layer = layer.split(".")[-1]
        groups.setdefault(layer, []).append((ch.rsplit(".", 1)[-1], k))
    order = {"R": 0, "G": 1, "B": 2, "A": 3, "X": 0, "Y": 1, "Z": 2, "V": 0}
    for layer, chans in groups.items():
        chans.sort(key=lambda t: order.get(t[0], 9))
        out[layer] = np.stack([data[..., k] for _, k in chans], -1)
    return out


def downsample(a):
    h, w, c = a.shape
    return a.reshape(h // 2, 2, w // 2, 2, c).mean((1, 3))


def fill_transparent(alb, nor, iters=24):
    """Bleed the colours of covered texels into the empty ones (premultiplied blur, few passes)."""
    a = alb[..., 3:].copy()
    known = (a > 0.02).astype(np.float32)
    ca = alb[..., :3] * known
    cn = nor[..., :3] * known
    w = known.copy()
    for _ in range(iters):
        def blur(x):
            p = np.pad(x, ((1, 1), (1, 1), (0, 0)), mode="edge")
            return (p[:-2, 1:-1] + p[2:, 1:-1] + p[1:-1, :-2] + p[1:-1, 2:] + p[1:-1, 1:-1]) / 5.0
        ca = np.where(known > 0, ca, blur(ca))
        cn = np.where(known > 0, cn, blur(cn))
        w = np.where(known > 0, w, blur(w))
    fill = known < 0.5
    far = w < 1e-4
    mean = alb[..., :3][known[..., 0] > 0].mean(0) if known.any() else np.full(3, 0.3)
    alb[..., :3] = np.where(fill, np.where(far, mean, ca / np.maximum(w, 1e-5)), alb[..., :3])
    nor[..., :3] = np.where(fill, np.where(far, np.array([0.5, 1.0, 0.5]), cn / np.maximum(w, 1e-5)), nor[..., :3])


def save_png(arr, path, srgb):
    h, w, _ = arr.shape
    img = bpy.data.images.new(os.path.basename(path), w, h, alpha=True, float_buffer=False)
    img.colorspace_settings.name = "sRGB" if srgb else "Non-Color"
    data = arr[::-1].copy()          # bpy pixels run bottom-up
    if srgb:
        rgb = data[..., :3]
        data[..., :3] = np.where(rgb <= 0.0031308, rgb * 12.92, 1.055 * np.power(np.maximum(rgb, 0), 1 / 2.4) - 0.055)
    img.pixels.foreach_set(data.astype(np.float32).ravel())
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)


main()
