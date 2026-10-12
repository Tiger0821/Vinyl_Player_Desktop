"""Builds and renders Wax's scenes in Blender.

    /Applications/Blender.app/Contents/MacOS/Blender -b -P Art/room_scene.py -- --out Resources/Scenes
    /Applications/Blender.app/Contents/MacOS/Blender -b -P Art/room_scene.py -- --out Resources/Scenes --scene desk

The first renders the two rooms, the second the turntable seen from above.
Add --preview for a quick quarter-size render while adjusting a scene.

The rooms write, into the output folder:
    listening-room.jpg, after-hours.jpg        the room with the tonearm parked
    listening-room-arm.jpg, after-hours-arm.jpg  the turntable alone, tonearm on the record
    listening-room-light.jpg, after-hours-light.jpg  the light falling on the tabletop where
                       the pile of played records builds up
    room-mask.png      white where the app paints artwork (sleeve, record label)
    room.json          where those surfaces sit in the picture, and how to find any other
                       point of the room in it

The sleeve front and the record label are left plain white, so their pixels record nothing
but the light falling on them. The app lays the artwork over them and multiplies it by those
pixels, which lights the cover the way the room is lit.

The pile of played records is not in the render at all, because it grows. The app draws it,
using the camera exported here to put each sleeve in perspective, and a white card rendered
where the pile stands to light them.

The view from above writes turntable.jpg, -light.jpg, -mask.png and .json in the same way.
Its tonearm is different: seen from straight above, swinging the arm is just turning its
picture, so the arm is left out of the photograph and rendered alone on a clear background
(turntable-arm.png), with its shadow alone beside it (turntable-arm-shadow.png). The app
turns both about the pivot, which lets the needle track smoothly across the whole record.
"""

import json
import math
import os
import random
import sys

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Matrix, Vector

# ----------------------------------------------------------------------------- arguments

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def option(name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default


OUT = os.path.abspath(option("--out", "Resources/Scenes"))
PREVIEW = "--preview" in argv
ONLY = option("--only", "all")  # day | night | all
ARM_ONLY = "--arm-only" in argv  # re-render just the tonearm patches
SCENE = option("--scene", "room")  # room | desk
WIDTH = int(option("--width", "756" if PREVIEW else "3024"))
HEIGHT = round(WIDTH * 982 / 1512)
SAMPLES = int(option("--samples", "48" if PREVIEW else "420"))

os.makedirs(OUT, exist_ok=True)
random.seed(7)

# ----------------------------------------------------------------------------- layout (metres, Z up)

WALL_Y = 0.34
TABLE_FRONT_Y = -0.85

DECK = Vector((0.06, -0.03, 0.0))  # centre of the turntable's footprint
DECK_SIZE = (0.44, 0.35, 0.046)
PLATTER = Vector((DECK.x - 0.045, DECK.y, 0.0))
RECORD_RADIUS = 0.150
LABEL_RADIUS = 0.050
PIVOT = Vector((DECK.x + 0.165, DECK.y + 0.105, 0.0))
ARM_LENGTH = 0.225

SLEEVE = 0.315
SLEEVE_BASE = Vector((-0.40, 0.03, 0.0))
SLEEVE_LEAN = math.radians(-13)
SLEEVE_TURN = math.radians(9)

# Where played records pile up. The app draws the pile; these only describe it.
PILE_CENTRE = Vector((0.50, -0.15, 0.0))
PILE_TURN = -10.0  # degrees, the lie of a sleeve dropped there
SLEEVE_THICKNESS = 0.004
LIGHT_CARD = 0.58  # a white card this wide, laid where the pile stands, to measure the light
LIGHT_CARD_HEIGHT = 0.02

LAMP = Vector((0.66, 0.12, 0.0))
PLANT = Vector((-0.71, 0.10, 0.0))

# ----------------------------------------------------------------------------- helpers


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def material(name, **values):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    for key, value in values.items():
        bsdf.inputs[key].default_value = value
    return mat


def rgb(r, g, b):
    return (r, g, b, 1.0)


def node(tree, kind, **props):
    made = tree.nodes.new(kind)
    for key, value in props.items():
        setattr(made, key, value)
    return made


def finish(obj, mat=None, bevel=0.0, segments=7, smooth=True):
    if bevel:
        mod = obj.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = segments
        mod.limit_method = "ANGLE"
        mod.angle_limit = math.radians(40)
    if mat:
        obj.data.materials.append(mat)
    if smooth:
        bpy.context.view_layer.objects.active = obj
        obj.select_set(True)
        bpy.ops.object.shade_auto_smooth(angle=math.radians(40))
        obj.select_set(False)
    return obj


def box(name, size, location, mat=None, bevel=0.0, rotation=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.select_set(False)
    return finish(obj, mat, bevel)


def cylinder(name, radius, depth, location, mat=None, bevel=0.0, rotation=(0, 0, 0), vertices=200, top_radius=None):
    if top_radius is None:
        bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=location, rotation=rotation)
    else:
        bpy.ops.mesh.primitive_cone_add(vertices=vertices, radius1=radius, radius2=top_radius, depth=depth, location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.select_set(False)
    return finish(obj, mat, bevel)


def sphere(name, radius, location, mat=None):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=radius, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.select_set(False)
    return finish(obj, mat)


def quad(name, corners, mat):
    """A flat four-cornered face from world-space corners, listed TL, TR, BR, BL of the picture it will carry."""
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([tuple(c) for c in corners], [], [(3, 2, 1, 0)])
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(mat)
    return obj


def parent(child, to):
    child.parent = to
    child.matrix_parent_inverse = to.matrix_world.inverted()


# ----------------------------------------------------------------------------- materials


def wood(name, dark, mid, light, grain=1.0, roughness=0.34, coat=0.3, plank=0.0):
    """Long straight grain along the object's X axis, with darker growth bands and fine pores.
    Give `plank` a width in metres to lay the surface as boards, each with its own figure."""
    mat = material(name)
    tree = mat.node_tree
    bsdf = tree.nodes["Principled BSDF"]
    link = tree.links.new

    coords = node(tree, "ShaderNodeTexCoord")
    source = coords.outputs["Object"]
    seam = board_tone = None
    if plank:
        split = node(tree, "ShaderNodeSeparateXYZ")
        link(coords.outputs["Object"], split.inputs["Vector"])
        counted = node(tree, "ShaderNodeMath", operation="MULTIPLY")
        counted.inputs[1].default_value = 1 / plank
        link(split.outputs["Y"], counted.inputs[0])
        board = node(tree, "ShaderNodeMath", operation="FLOOR")
        link(counted.outputs["Value"], board.inputs[0])
        within = node(tree, "ShaderNodeMath", operation="FRACT")
        link(counted.outputs["Value"], within.inputs[0])
        seam = node(tree, "ShaderNodeMath", operation="LESS_THAN")
        seam.inputs[1].default_value = 0.012
        link(within.outputs["Value"], seam.inputs[0])
        board_tone = node(tree, "ShaderNodeTexWhiteNoise", noise_dimensions="1D")
        link(board.outputs["Value"], board_tone.inputs["W"])
        # Slide each board along its length so the figure doesn't run across the joins.
        slide = node(tree, "ShaderNodeCombineXYZ")
        far = node(tree, "ShaderNodeMath", operation="MULTIPLY")
        far.inputs[1].default_value = 37.0
        link(board_tone.outputs["Value"], far.inputs[0])
        link(far.outputs["Value"], slide.inputs["X"])
        link(far.outputs["Value"], slide.inputs["Z"])
        moved = node(tree, "ShaderNodeVectorMath", operation="ADD")
        link(coords.outputs["Object"], moved.inputs[0])
        link(slide.outputs["Vector"], moved.inputs[1])
        source = moved.outputs["Vector"]

    stretch = node(tree, "ShaderNodeMapping")
    stretch.inputs["Scale"].default_value = (0.2 * grain, 3.6 * grain, 3.6 * grain)
    link(source, stretch.inputs["Vector"])

    # Stretched noise gives the wandering figure of flat-sawn boards.
    bands = node(tree, "ShaderNodeTexNoise")
    bands.inputs["Scale"].default_value = 2.4
    bands.inputs["Detail"].default_value = 7.0
    bands.inputs["Roughness"].default_value = 0.62
    bands.inputs["Distortion"].default_value = 0.9
    link(stretch.outputs["Vector"], bands.inputs["Vector"])

    ramp = node(tree, "ShaderNodeValToRGB")
    stops = ramp.color_ramp.elements
    stops[0].position, stops[0].color = 0.3, rgb(*dark)
    stops[1].position, stops[1].color = 0.72, rgb(*light)
    middle = stops.new(0.5)
    middle.color = rgb(*mid)
    link(bands.outputs["Fac"], ramp.inputs["Fac"])

    pores_map = node(tree, "ShaderNodeMapping")
    pores_map.inputs["Scale"].default_value = (1.4 * grain, 110.0 * grain, 110.0 * grain)
    link(source, pores_map.inputs["Vector"])
    pores = node(tree, "ShaderNodeTexNoise")
    pores.inputs["Scale"].default_value = 1.0
    pores.inputs["Detail"].default_value = 5.0
    link(pores_map.outputs["Vector"], pores.inputs["Vector"])

    fibre_map = node(tree, "ShaderNodeMapping")
    fibre_map.inputs["Scale"].default_value = (5.0 * grain, 620.0 * grain, 620.0 * grain)
    link(source, fibre_map.inputs["Vector"])
    fibre = node(tree, "ShaderNodeTexNoise")
    fibre.inputs["Scale"].default_value = 1.0
    fibre.inputs["Detail"].default_value = 3.0
    link(fibre_map.outputs["Vector"], fibre.inputs["Vector"])
    texture = node(tree, "ShaderNodeMath", operation="MULTIPLY")
    link(pores.outputs["Fac"], texture.inputs[0])
    link(fibre.outputs["Fac"], texture.inputs[1])
    spread = node(tree, "ShaderNodeMapRange")
    spread.inputs["From Min"].default_value = 0.12
    spread.inputs["From Max"].default_value = 0.42
    link(texture.outputs["Value"], spread.inputs["Value"])

    tint = node(tree, "ShaderNodeMixRGB", blend_type="MULTIPLY")
    tint.inputs["Fac"].default_value = 0.5
    link(ramp.outputs["Color"], tint.inputs["Color1"])
    link(spread.outputs["Result"], tint.inputs["Color2"])
    colour = tint.outputs["Color"]

    # Open grain is duller than the polished wood between it.
    sheen = node(tree, "ShaderNodeMapRange")
    sheen.inputs["To Min"].default_value = roughness + 0.2
    sheen.inputs["To Max"].default_value = roughness - 0.06
    link(spread.outputs["Result"], sheen.inputs["Value"])
    link(sheen.outputs["Result"], bsdf.inputs["Roughness"])

    if plank:
        # Boards differ a little in tone, and a dark hairline marks each join.
        lift = node(tree, "ShaderNodeMath", operation="MULTIPLY_ADD")
        lift.inputs[1].default_value = 0.34
        lift.inputs[2].default_value = 0.83
        link(board_tone.outputs["Value"], lift.inputs[0])
        toned = node(tree, "ShaderNodeMixRGB", blend_type="MULTIPLY")
        toned.inputs["Fac"].default_value = 1.0
        link(colour, toned.inputs["Color1"])
        link(lift.outputs["Value"], toned.inputs["Color2"])
        joined = node(tree, "ShaderNodeMixRGB", blend_type="MIX")
        joined.inputs["Color2"].default_value = rgb(dark[0] * 0.3, dark[1] * 0.3, dark[2] * 0.3)
        strength = node(tree, "ShaderNodeMath", operation="MULTIPLY")
        strength.inputs[1].default_value = 0.75
        link(seam.outputs["Value"], strength.inputs[0])
        link(strength.outputs["Value"], joined.inputs["Fac"])
        link(toned.outputs["Color"], joined.inputs["Color1"])
        colour = joined.outputs["Color"]

    link(colour, bsdf.inputs["Base Color"])

    bump = node(tree, "ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.05
    bump.inputs["Distance"].default_value = 0.002
    link(spread.outputs["Result"], bump.inputs["Height"])
    link(bump.outputs["Normal"], bsdf.inputs["Normal"])

    bsdf.inputs["Coat Weight"].default_value = coat
    bsdf.inputs["Coat Roughness"].default_value = 0.18
    return mat


def plaster(name, colour):
    """Hand-trowelled wall: broad uneven patches over a fine sandy tooth."""
    mat = material(name, Roughness=0.93)
    tree = mat.node_tree
    bsdf = tree.nodes["Principled BSDF"]
    link = tree.links.new
    coords = node(tree, "ShaderNodeTexCoord")

    broad = node(tree, "ShaderNodeTexNoise")
    broad.inputs["Scale"].default_value = 3.5
    broad.inputs["Detail"].default_value = 5.0
    broad.inputs["Roughness"].default_value = 0.55
    link(coords.outputs["Object"], broad.inputs["Vector"])

    fine = node(tree, "ShaderNodeTexNoise")
    fine.inputs["Scale"].default_value = 260.0
    fine.inputs["Detail"].default_value = 3.0
    link(coords.outputs["Object"], fine.inputs["Vector"])

    shade = node(tree, "ShaderNodeValToRGB")
    shade.color_ramp.elements[0].position = 0.25
    shade.color_ramp.elements[0].color = rgb(*[c * 0.9 for c in colour])
    shade.color_ramp.elements[1].position = 0.8
    shade.color_ramp.elements[1].color = rgb(*colour)
    link(broad.outputs["Fac"], shade.inputs["Fac"])
    link(shade.outputs["Color"], bsdf.inputs["Base Color"])

    height = node(tree, "ShaderNodeMath", operation="ADD")
    scaled = node(tree, "ShaderNodeMath", operation="MULTIPLY")
    scaled.inputs[1].default_value = 0.18
    link(fine.outputs["Fac"], scaled.inputs[0])
    link(broad.outputs["Fac"], height.inputs[0])
    link(scaled.outputs["Value"], height.inputs[1])

    bump = node(tree, "ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.28
    bump.inputs["Distance"].default_value = 0.012
    link(height.outputs["Value"], bump.inputs["Height"])
    link(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


def vinyl(name):
    """Black and glossy, with concentric grooves fine enough to smear highlights into a streak."""
    mat = material(name, Roughness=0.2)
    mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.006, 0.006, 0.007)
    tree = mat.node_tree
    bsdf = tree.nodes["Principled BSDF"]
    link = tree.links.new
    coords = node(tree, "ShaderNodeTexCoord")
    rings = node(tree, "ShaderNodeTexWave", wave_type="RINGS", rings_direction="Z")
    rings.inputs["Scale"].default_value = 520.0
    link(coords.outputs["Object"], rings.inputs["Vector"])
    bump = node(tree, "ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.35
    bump.inputs["Distance"].default_value = 0.0004
    link(rings.outputs["Fac"], bump.inputs["Height"])
    link(bump.outputs["Normal"], bsdf.inputs["Normal"])
    # Grooves run round the record, so light smears across them into the two bright wedges
    # every record shows, whichever way it faces.
    around = node(tree, "ShaderNodeTangent", direction_type="RADIAL", axis="Z")
    link(around.outputs["Tangent"], bsdf.inputs["Tangent"])
    bsdf.inputs["Roughness"].default_value = 0.29
    bsdf.inputs["Anisotropic"].default_value = 0.9
    return mat


def painting(name):
    """A print for the wall: soft overlapping fields of colour, like a mid-century gouache."""
    mat = material(name, Roughness=0.7)
    tree = mat.node_tree
    bsdf = tree.nodes["Principled BSDF"]
    link = tree.links.new
    coords = node(tree, "ShaderNodeTexCoord")
    cells = node(tree, "ShaderNodeTexVoronoi", feature="SMOOTH_F1")
    cells.inputs["Scale"].default_value = 2.3
    cells.inputs["Smoothness"].default_value = 0.35
    cells.inputs["Randomness"].default_value = 0.9
    warp = node(tree, "ShaderNodeTexNoise")
    warp.inputs["Scale"].default_value = 1.4
    mix = node(tree, "ShaderNodeMixRGB")
    mix.inputs["Fac"].default_value = 0.12
    link(coords.outputs["UV"], mix.inputs["Color1"])
    link(coords.outputs["UV"], warp.inputs["Vector"])
    link(warp.outputs["Color"], mix.inputs["Color2"])
    link(mix.outputs["Color"], cells.inputs["Vector"])
    ramp = node(tree, "ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = "CONSTANT"
    palette = [(0.0, (0.05, 0.16, 0.17)), (0.2, (0.72, 0.36, 0.14)), (0.4, (0.82, 0.74, 0.58)),
               (0.6, (0.14, 0.27, 0.22)), (0.8, (0.56, 0.2, 0.12))]
    elements = ramp.color_ramp.elements
    elements[0].position, elements[0].color = palette[0][0], rgb(*palette[0][1])
    elements[1].position, elements[1].color = palette[1][0], rgb(*palette[1][1])
    for position, colour in palette[2:]:
        elements.new(position).color = rgb(*colour)
    link(cells.outputs["Color"], ramp.inputs["Fac"])
    link(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


# ----------------------------------------------------------------------------- the room


def build_room():
    walnut = wood("walnut", (0.105, 0.042, 0.016), (0.2, 0.088, 0.032), (0.31, 0.15, 0.058), roughness=0.4, coat=0.18, plank=0.19)
    oak = wood("oak", (0.2, 0.12, 0.06), (0.36, 0.23, 0.12), (0.5, 0.34, 0.19), grain=2.2, roughness=0.5, coat=0.05)
    wall_mat = plaster("plaster", (0.82, 0.74, 0.61))

    # A deep tabletop, so the wood runs out of the bottom of the picture.
    depth = WALL_Y - TABLE_FRONT_Y
    box("table", (4.2, depth, 0.05), (0, (WALL_Y + TABLE_FRONT_Y) / 2, -0.025), walnut, bevel=0.004)

    bpy.ops.mesh.primitive_plane_add(size=1, location=(0, WALL_Y, 1.0), rotation=(math.radians(90), 0, 0))
    wall = bpy.context.object
    wall.name = "wall"
    wall.scale = (6.0, 4.0, 1.0)
    wall.data.materials.append(wall_mat)
    wall.select_set(False)

    # A skirting-height rail where table meets wall hides the hard join.
    box("rail", (4.2, 0.012, 0.03), (0, WALL_Y - 0.006, 0.015), walnut, bevel=0.003)

    build_frame(oak)
    return walnut, oak


def build_frame(oak):
    centre = Vector((-0.03, WALL_Y - 0.014, 0.69))
    width, height, rail = 0.38, 0.46, 0.024
    for name, size, offset in [
        ("frame-top", (width, 0.028, rail), (0, 0, height / 2 - rail / 2)),
        ("frame-bottom", (width, 0.028, rail), (0, 0, -height / 2 + rail / 2)),
        ("frame-left", (rail, 0.028, height - 2 * rail), (-width / 2 + rail / 2, 0, 0)),
        ("frame-right", (rail, 0.028, height - 2 * rail), (width / 2 - rail / 2, 0, 0)),
    ]:
        box(name, size, centre + Vector(offset), oak, bevel=0.002)

    mat_board = material("mat-board", Roughness=0.85)
    mat_board.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.86, 0.83, 0.76)
    box("mat-board", (width - rail, 0.004, height - rail), centre + Vector((0, 0.008, 0)), mat_board)

    art_w, art_h = 0.24, 0.31
    bpy.ops.mesh.primitive_plane_add(size=1, location=centre + Vector((0, 0.0055, 0)), rotation=(math.radians(90), 0, 0))
    art = bpy.context.object
    art.name = "print"
    art.scale = (art_w, art_h, 1)
    art.data.materials.append(painting("print"))
    art.select_set(False)


def build_turntable(white):
    cream = material("deck-paint", Roughness=0.42)
    cream.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.78, 0.74, 0.65)
    cream.node_tree.nodes["Principled BSDF"].inputs["Coat Weight"].default_value = 0.25
    steel = material("steel", Metallic=1.0, Roughness=0.24)
    steel.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.74, 0.74, 0.73)
    dark = material("dark-metal", Metallic=1.0, Roughness=0.38)
    dark.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.03, 0.03, 0.032)
    rubber = material("rubber", Roughness=0.8)
    rubber.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.015, 0.015, 0.015)

    foot = 0.012
    w, d, h = DECK_SIZE
    top = foot + h
    box("deck", (w, d, h), (DECK.x, DECK.y, foot + h / 2), cream, bevel=0.012)
    for sx in (-1, 1):
        for sy in (-1, 1):
            cylinder("foot", 0.022, foot, (DECK.x + sx * (w / 2 - 0.045), DECK.y + sy * (d / 2 - 0.045), foot / 2), rubber, vertices=32)

    platter_h = 0.016
    cylinder("platter", 0.153, platter_h, (PLATTER.x, PLATTER.y, top + platter_h / 2), steel, bevel=0.002)
    record_z = top + platter_h + 0.0012
    cylinder("record", RECORD_RADIUS, 0.0024, (PLATTER.x, PLATTER.y, record_z), vinyl("vinyl"), bevel=0.0006, vertices=256)
    cylinder("spindle", 0.0035, 0.014, (PLATTER.x, PLATTER.y, record_z + 0.006), steel, bevel=0.001, vertices=24)

    label_z = record_z + 0.0015
    r = LABEL_RADIUS
    label_corners = [
        Vector((PLATTER.x - r, PLATTER.y + r, label_z)), Vector((PLATTER.x + r, PLATTER.y + r, label_z)),
        Vector((PLATTER.x + r, PLATTER.y - r, label_z)), Vector((PLATTER.x - r, PLATTER.y - r, label_z)),
    ]
    cylinder("dyn-label", r, 0.0004, (PLATTER.x, PLATTER.y, label_z), white, vertices=160)

    # Controls on the front-right corner.
    cylinder("knob", 0.017, 0.014, (DECK.x + w / 2 - 0.05, DECK.y - d / 2 + 0.05, top + 0.007), steel, bevel=0.002, vertices=48)
    box("switch", (0.03, 0.012, 0.004), (DECK.x + w / 2 - 0.105, DECK.y - d / 2 + 0.05, top + 0.002), dark, bevel=0.001)

    # Tonearm: everything hangs off an empty at the pivot, pointing along its +X.
    pivot_z = top + 0.034
    cylinder("arm-base", 0.024, 0.006, (PIVOT.x, PIVOT.y, top + 0.003), dark, bevel=0.001, vertices=48)
    cylinder("arm-post", 0.009, 0.034, (PIVOT.x, PIVOT.y, top + 0.017), steel, bevel=0.001, vertices=32)

    bpy.ops.object.empty_add(location=(PIVOT.x, PIVOT.y, pivot_z))
    arm = bpy.context.object
    arm.name = "arm"
    arm.select_set(False)
    quarter = math.radians(90)
    parts = [
        cylinder("arm-tube", 0.0036, ARM_LENGTH - 0.02, (PIVOT.x + (ARM_LENGTH - 0.02) / 2, PIVOT.y, pivot_z), steel, rotation=(0, quarter, 0), vertices=24),
        cylinder("arm-gimbal", 0.013, 0.02, (PIVOT.x, PIVOT.y, pivot_z), dark, bevel=0.002, vertices=32),
        cylinder("arm-stub", 0.0045, 0.05, (PIVOT.x - 0.03, PIVOT.y, pivot_z), steel, rotation=(0, quarter, 0), vertices=24),
        cylinder("arm-weight", 0.015, 0.032, (PIVOT.x - 0.058, PIVOT.y, pivot_z), dark, bevel=0.002, rotation=(0, quarter, 0), vertices=48),
        box("headshell", (0.04, 0.019, 0.004), (PIVOT.x + ARM_LENGTH - 0.012, PIVOT.y, pivot_z - 0.001), dark, bevel=0.001),
        box("cartridge", (0.022, 0.015, 0.012), (PIVOT.x + ARM_LENGTH - 0.008, PIVOT.y, pivot_z - 0.008), dark, bevel=0.001),
    ]
    for part in parts:
        parent(part, arm)

    # Where the parked arm rests.
    rest_heading = arm_heading(RECORD_RADIUS + 0.035)
    rest = Vector((PIVOT.x + math.cos(rest_heading) * ARM_LENGTH * 0.66, PIVOT.y + math.sin(rest_heading) * ARM_LENGTH * 0.66, 0))
    cylinder("arm-rest", 0.005, pivot_z - top - 0.006, (rest.x, rest.y, top + (pivot_z - top - 0.006) / 2), dark, vertices=24)

    return arm, label_corners


def arm_heading(stylus_radius):
    """Angle of the arm about Z that puts its tip `stylus_radius` from the spindle, on the camera's side."""
    to_centre = Vector((PLATTER.x - PIVOT.x, PLATTER.y - PIVOT.y))
    distance = to_centre.length
    cosine = (ARM_LENGTH ** 2 + distance ** 2 - stylus_radius ** 2) / (2 * ARM_LENGTH * distance)
    swing = math.acos(max(-1.0, min(1.0, cosine)))
    return math.atan2(to_centre.y, to_centre.x) + swing


def build_sleeve(white, oak):
    card = material("card", Roughness=0.75)
    card.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.82, 0.8, 0.75)

    thickness = 0.005
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 0))
    sleeve = bpy.context.object
    sleeve.name = "sleeve"
    sleeve.scale = (SLEEVE, thickness, SLEEVE)
    bpy.ops.object.transform_apply(scale=True)
    # Origin on the bottom front edge, so it pivots where it touches the table.
    for vertex in sleeve.data.vertices:
        vertex.co.z += SLEEVE / 2
        vertex.co.y += thickness / 2
    sleeve.select_set(False)
    finish(sleeve, card, smooth=False)

    transform = Matrix.Translation(SLEEVE_BASE + Vector((0, 0, 0.014))) @ Matrix.Rotation(SLEEVE_TURN, 4, "Z") @ Matrix.Rotation(SLEEVE_LEAN, 4, "X")
    sleeve.matrix_world = transform

    half, front = SLEEVE / 2, -0.0005
    corners = [transform @ Vector(p) for p in [(-half, front, SLEEVE), (half, front, SLEEVE), (half, front, 0), (-half, front, 0)]]
    quad("dyn-sleeve", corners, white)

    # A low oak stand: a lip in front, a prop behind.
    stand = Matrix.Translation(SLEEVE_BASE) @ Matrix.Rotation(SLEEVE_TURN, 4, "Z")
    for name, size, offset in [
        ("stand-base", (0.24, 0.12, 0.014), (0, 0.045, 0.007)),
        ("stand-lip", (0.24, 0.012, 0.03), (0, -0.012, 0.015)),
        ("stand-prop", (0.24, 0.014, 0.12), (0, 0.075, 0.06)),
    ]:
        part = box(name, size, (0, 0, 0), oak, bevel=0.002)
        part.matrix_world = stand @ Matrix.Translation(offset)
    return corners


def build_light_card(white, at=None):
    """A white card where the pile of records stands. It is left out of the pictures and
    rendered on its own, so the app knows how the tabletop there is lit."""
    half = LIGHT_CARD / 2
    at = at or PILE_CENTRE
    centre = Vector((at.x, at.y, LIGHT_CARD_HEIGHT))
    corners = [centre + Vector(p) for p in [(-half, half, 0), (half, half, 0), (half, -half, 0), (-half, -half, 0)]]
    card = quad("light-card", corners, white)
    card.hide_render = True
    return card, corners


def build_lamp():
    brass = material("brass", Metallic=1.0, Roughness=0.3)
    brass.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.72, 0.5, 0.2)
    cylinder("lamp-base", 0.055, 0.014, (LAMP.x, LAMP.y, 0.007), brass, bevel=0.003, vertices=64)
    cylinder("lamp-stem", 0.006, 0.11, (LAMP.x, LAMP.y, 0.014 + 0.055), brass, vertices=24)
    cylinder("lamp-collar", 0.02, 0.018, (LAMP.x, LAMP.y, 0.014 + 0.11 + 0.006), brass, bevel=0.002, vertices=48)

    globe_centre = Vector((LAMP.x, LAMP.y, 0.014 + 0.11 + 0.085))
    glass = bpy.data.materials.new("opal-glass")
    glass.use_nodes = True
    globe = sphere("lamp-globe", 0.078, globe_centre, glass)
    globe.modifiers.new("smooth", "SUBSURF").render_levels = 2
    for polygon in globe.data.polygons:
        polygon.use_smooth = True
    # The glow comes from a light inside; the globe itself must not shadow it.
    globe.visible_shadow = False

    bpy.ops.object.light_add(type="POINT", location=globe_centre)
    bulb = bpy.context.object
    bulb.name = "lamp-bulb"
    bulb.data.shadow_soft_size = 0.07
    bulb.select_set(False)
    return glass, bulb


def set_lamp(glass, bulb, lit):
    tree = glass.node_tree
    bsdf = tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = rgb(0.9, 0.87, 0.8)
    bsdf.inputs["Roughness"].default_value = 0.35
    bsdf.inputs["Subsurface Weight"].default_value = 0.0
    bsdf.inputs["Transmission Weight"].default_value = 0.0 if lit else 0.35
    bsdf.inputs["Emission Color"].default_value = rgb(1.0, 0.56, 0.2)
    bsdf.inputs["Emission Strength"].default_value = 14.0 if lit else 0.0
    bulb.data.color = (1.0, 0.6, 0.28)
    bulb.data.energy = 30.0 if lit else 0.0


def build_plant(centre=None, all_round=False):
    """`all_round` lets the leaves fan out in every direction, for a pot with no wall behind it."""
    PLANT = centre or globals()["PLANT"]
    terracotta = material("terracotta", Roughness=0.85)
    terracotta.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.5, 0.21, 0.11)
    soil = material("soil", Roughness=1.0)
    soil.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.03, 0.02, 0.015)

    pot_h = 0.15
    cylinder("pot", 0.07, pot_h, (PLANT.x, PLANT.y, pot_h / 2), terracotta, bevel=0.003, vertices=64, top_radius=0.092)
    cylinder("pot-rim", 0.098, 0.022, (PLANT.x, PLANT.y, pot_h - 0.006), terracotta, bevel=0.004, vertices=64)
    cylinder("soil", 0.086, 0.004, (PLANT.x, PLANT.y, pot_h - 0.004), soil, vertices=48)

    leaf_mats = []
    for index, colour in enumerate([(0.03, 0.11, 0.035), (0.045, 0.15, 0.04), (0.06, 0.18, 0.05)]):
        mat = material(f"leaf-{index}", Roughness=0.38)
        bsdf = mat.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Base Color"].default_value = rgb(*colour)
        bsdf.inputs["Subsurface Weight"].default_value = 0.25
        bsdf.inputs["Subsurface Radius"].default_value = (0.02, 0.05, 0.01)
        bsdf.inputs["Coat Weight"].default_value = 0.2
        leaf_mats.append(mat)

    count = 19
    for index in range(count):
        # Fan out from the pot, but keep clear of the wall behind it.
        azimuth = math.radians(random.uniform(-200, 20) if index % 4 or all_round and index % 8 else random.uniform(40, 140))
        if all_round:
            azimuth = math.radians(random.uniform(0, 360))
        lift = math.radians(random.uniform(48, 82) if 40 < math.degrees(azimuth) < 140 else random.uniform(22, 72))
        length = random.uniform(0.24, 0.42)
        leaf = leaf_object(f"leaf-{index}", length, random.uniform(0.075, 0.115), random.uniform(0.25, 0.7), random.choice(leaf_mats))
        base = Vector((PLANT.x + random.uniform(-0.03, 0.03), PLANT.y + random.uniform(-0.03, 0.03), pot_h - 0.004))
        leaf.matrix_world = (
            Matrix.Translation(base) @ Matrix.Rotation(azimuth, 4, "Z") @ Matrix.Rotation(lift, 4, "X")
            @ Matrix.Rotation(math.radians(random.uniform(-25, 25)), 4, "Y")
        )


def leaf_object(name, length, width, droop, mat):
    """A stalk that broadens into a pointed blade, folded slightly along its midrib and arching over."""
    along, across = 22, 8
    stalk = 0.42
    vertices, faces = [], []
    for i in range(along + 1):
        u = i / along
        if u < stalk:
            half = 0.0028
        else:
            t = (u - stalk) / (1 - stalk)
            half = max(0.0028, width / 2 * math.sin(math.pi * t ** 0.72) ** 0.85)
        for j in range(across + 1):
            v = j / across * 2 - 1
            blade = max(0.0, (u - stalk) / (1 - stalk))
            x = v * half
            y = u * length
            z = -droop * length * u * u + abs(v) * half * 0.45 * blade
            vertices.append((x, y, z))
    for i in range(along):
        for j in range(across):
            a = i * (across + 1) + j
            faces.append((a, a + 1, a + across + 2, a + across + 1))
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    for polygon in mesh.polygons:
        polygon.use_smooth = True
    obj.data.materials.append(mat)
    return obj


# ----------------------------------------------------------------------------- light


def build_window(direction, aim, opening=(1.5, 1.05), slat=0.058, gap=0.05, upright=0.18):
    """A window with slatted blinds, somewhere off to the left, for the sun to shine through.
    Only its shadow is ever seen. Wide gaps make glazing bars instead of blinds."""
    blocker = bpy.data.materials.new("blocker")
    distance = 3.0
    origin = aim - direction * distance
    across = direction.cross(Vector((0, 0, 1))).normalized()
    up = across.cross(direction).normalized()
    frame = Matrix((
        (across.x, up.x, direction.x, origin.x),
        (across.y, up.y, direction.y, origin.y),
        (across.z, up.z, direction.z, origin.z),
        (0, 0, 0, 1),
    ))

    opening_w, opening_h, far = opening[0], opening[1], 9.0
    panels = [
        ((far, far), (-(far + opening_w) / 2, 0)), ((far, far), ((far + opening_w) / 2, 0)),
        ((opening_w, far), (0, (far + opening_h) / 2)), ((opening_w, far), (0, -(far + opening_h) / 2)),
    ]
    count = int(opening_h / (slat + gap)) + 1
    for index in range(count):
        offset = -opening_h / 2 + index * (slat + gap) + slat / 2
        panels.append(((opening_w, slat), (0, offset)))
    # One upright, as a window has between its panes.
    panels.append(((0.045, opening_h), (upright, 0)))

    for index, (size, centre) in enumerate(panels):
        bpy.ops.mesh.primitive_plane_add(size=1)
        panel = bpy.context.object
        panel.name = f"window-{index}"
        panel.scale = (size[0], size[1], 1)
        panel.matrix_world = frame @ Matrix.Translation((centre[0], centre[1], 0)) @ Matrix.Diagonal((size[0], size[1], 1, 1))
        panel.data.materials.append(blocker)
        panel.visible_camera = False
        panel.visible_diffuse = False
        panel.visible_glossy = False
        panel.visible_transmission = False
        panel.select_set(False)


def build_lights():
    direction = Vector((0.80, 0.42, -0.43)).normalized()
    bpy.ops.object.light_add(type="SUN")
    sun = bpy.context.object
    sun.name = "sun"
    sun.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    sun.data.angle = math.radians(1.3)
    sun.data.color = (1.0, 0.79, 0.56)
    sun.select_set(False)
    build_window(direction, Vector((-0.22, 0.2, 0.42)))

    # Night: a second warm lamp behind the viewer's left shoulder, so the sleeve isn't lost in the dark.
    glow_at = Vector((-1.0, -1.0, 0.6))
    bpy.ops.object.light_add(type="AREA", location=glow_at)
    glow = bpy.context.object
    glow.name = "side-glow"
    glow.data.shape = "DISK"
    glow.data.size = 0.5
    glow.data.color = (1.0, 0.58, 0.3)
    glow.rotation_euler = (Vector((-0.38, 0.03, 0.17)) - glow_at).normalized().to_track_quat("-Z", "Y").to_euler()
    glow.select_set(False)

    world = bpy.data.worlds.new("world")
    world.use_nodes = True
    bpy.context.scene.world = world
    return sun, glow, world


def set_time(sun, glow, world, glass, bulb, night):
    background = world.node_tree.nodes["Background"]
    scene = bpy.context.scene
    if night:
        sun.data.energy = 0.0
        glow.data.energy = 13.0
        background.inputs["Color"].default_value = rgb(0.05, 0.08, 0.2)
        background.inputs["Strength"].default_value = 0.05
        scene.view_settings.exposure = -1.7
    else:
        sun.data.energy = 5.6
        glow.data.energy = 0.0
        background.inputs["Color"].default_value = rgb(1.0, 0.9, 0.8)
        background.inputs["Strength"].default_value = 0.3
        scene.view_settings.exposure = 0.3
    set_lamp(glass, bulb, lit=night)


# ----------------------------------------------------------------------------- camera and render


def build_camera():
    bpy.ops.object.camera_add(location=(0.02, -1.74, 0.43))
    camera = bpy.context.object
    target = Vector((0.02, 0.0, 0.2))
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
    camera.data.lens = 40
    camera.data.sensor_width = 36
    camera.data.dof.use_dof = True
    camera.data.dof.focus_distance = (Vector((DECK.x, DECK.y, 0.06)) - camera.location).length
    camera.data.dof.aperture_fstop = 5.6
    bpy.context.scene.camera = camera
    camera.select_set(False)
    return camera


def configure_render():
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for device in prefs.devices:
        device.use = True
    scene.cycles.device = "GPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_adaptive_sampling = True
    scene.cycles.adaptive_threshold = 0.02 if PREVIEW else 0.006
    scene.cycles.use_denoising = True
    scene.cycles.denoiser = "OPENIMAGEDENOISE"
    scene.cycles.max_bounces = 10
    scene.cycles.seed = 11

    scene.render.resolution_x = WIDTH
    scene.render.resolution_y = HEIGHT
    scene.render.resolution_percentage = 100
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.render.image_settings.file_format = "JPEG"
    scene.render.image_settings.quality = 93
    add_bloom(scene)


def add_bloom(scene):
    """A soft halo round anything brighter than white — the lamp at night, glints by day."""
    try:
        scene.use_nodes = True
        tree = scene.node_tree
        tree.nodes.clear()
        layers = tree.nodes.new("CompositorNodeRLayers")
        glare = tree.nodes.new("CompositorNodeGlare")
        glare.glare_type = "BLOOM"
        # These moved from node properties to input sockets in Blender 4.4.
        for key, value in (("Threshold", 1.6), ("Strength", 0.55), ("Size", 0.62), ("Saturation", 1.0)):
            if key in glare.inputs:
                glare.inputs[key].default_value = value
        output = tree.nodes.new("CompositorNodeComposite")
        tree.links.new(layers.outputs["Image"], glare.inputs["Image"])
        tree.links.new(glare.outputs["Image"], output.inputs["Image"])
    except Exception as problem:  # A missing halo is not worth failing the render over.
        print("bloom unavailable:", problem)
        scene.use_nodes = False


def render(path, crop=None):
    """`crop` renders just one rectangle, given as fractions from the top-left."""
    scene = bpy.context.scene
    scene.render.use_border = crop is not None
    scene.render.use_crop_to_border = crop is not None
    if crop:
        scene.render.border_min_x, scene.render.border_max_x = crop[0], crop[2]
        scene.render.border_min_y, scene.render.border_max_y = 1 - crop[3], 1 - crop[1]
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    scene.render.use_border = False
    scene.render.use_crop_to_border = False
    print("wrote", path)


def render_patch(path, rect, clear=False):
    """Renders the whole picture and keeps one rectangle of it, given as fractions from the
    top-left. Rendering only the rectangle would be quicker but comes out a shade different:
    the lamp's halo is added afterwards and needs the lamp in the picture.

    `clear` keeps the background see-through and writes a PNG, for things cut out on their own."""
    import numpy

    scene = bpy.context.scene
    whole = os.path.join(bpy.app.tempdir, "wax-whole.png")
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA" if clear else "RGB"
    scene.render.film_transparent = clear
    bloom = scene.use_nodes
    if clear:
        scene.use_nodes = False  # a halo would smear the cut-out's edge
    scene.render.filepath = whole
    bpy.ops.render.render(write_still=True)
    scene.render.image_settings.file_format = "JPEG"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.film_transparent = False
    scene.use_nodes = bloom

    image = bpy.data.images.load(whole)
    width, height = image.size
    pixels = numpy.empty(width * height * 4, dtype=numpy.float32)
    image.pixels.foreach_get(pixels)
    pixels = pixels.reshape(height, width, 4)  # rows run bottom to top
    left, right = round(rect[0] * width), round(rect[2] * width)
    bottom, top = round((1 - rect[3]) * height), round((1 - rect[1]) * height)
    piece = numpy.ascontiguousarray(pixels[bottom:top, left:right, :])

    patch = bpy.data.images.new("patch", right - left, top - bottom, alpha=clear)
    patch.pixels.foreach_set(piece.ravel())
    patch.filepath_raw = path
    patch.file_format = "PNG" if clear else "JPEG"
    patch.save(quality=93)
    bpy.data.images.remove(image)
    bpy.data.images.remove(patch)
    os.remove(whole)
    print("wrote", path)


def projected(camera, point):
    """A world point as a fraction of the picture, origin top-left."""
    view = world_to_camera_view(bpy.context.scene, camera, point)
    return [round(view.x, 6), round(1 - view.y, 6)]


def projection(camera):
    """The camera as twelve numbers, row by row: multiply by (x, y, z, 1), divide the first
    two results by the third, and you have the point as a fraction of the picture."""
    focal = camera.data.lens / camera.data.sensor_width
    across, down = focal, focal * WIDTH / HEIGHT
    to_camera = camera.matrix_world.inverted()
    # The camera looks along its own -Z, with +Y up.
    lens = Matrix(((across, 0, -0.5, 0), (0, -down, -0.5, 0), (0, 0, -1, 0)))
    rows = lens @ to_camera

    check = Vector((0.31, -0.22, 0.07))
    u, v, w = rows @ Vector((*check, 1))
    expected = projected(camera, check)
    assert abs(u / w - expected[0]) < 1e-4 and abs(v / w - expected[1]) < 1e-4, "camera export is wrong"
    return [round(value, 8) for row in rows for value in row]


def snapped(rect):
    """Grows a rectangle to whole pixels, so a patch lands exactly where it was cut from."""
    return [math.floor(rect[0] * WIDTH) / WIDTH, math.floor(rect[1] * HEIGHT) / HEIGHT,
            math.ceil(rect[2] * WIDTH) / WIDTH, math.ceil(rect[3] * HEIGHT) / HEIGHT]


def bounds(points, pad=0.0):
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    return snapped([max(0, min(xs) - pad), max(0, min(ys) - pad), min(1, max(xs) + pad), min(1, max(ys) + pad)])


def render_mask(path):
    """White wherever artwork gets painted and nothing stands in front of it."""
    scene = bpy.context.scene
    black = bpy.data.materials.new("mask-black")
    black.use_nodes = True
    black.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0, 0, 0)
    black.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 1.0
    black.node_tree.nodes["Principled BSDF"].inputs["Specular IOR Level"].default_value = 0.0
    white = bpy.data.materials.new("mask-white")
    white.use_nodes = True
    tree = white.node_tree
    tree.nodes.clear()
    emission = tree.nodes.new("ShaderNodeEmission")
    emission.inputs["Strength"].default_value = 1.0
    output = tree.nodes.new("ShaderNodeOutputMaterial")
    tree.links.new(emission.outputs["Emission"], output.inputs["Surface"])

    originals = {}
    for obj in scene.objects:
        if obj.type != "MESH":
            continue
        originals[obj.name] = [slot.material for slot in obj.material_slots]
        swap = white if obj.name.startswith("dyn-") else black
        for slot in obj.material_slots:
            slot.material = swap
    lights = {obj.name: obj.data.energy for obj in scene.objects if obj.type == "LIGHT"}
    for name in lights:
        scene.objects[name].data.energy = 0.0
    background = scene.world.node_tree.nodes["Background"]
    strength = background.inputs["Strength"].default_value
    background.inputs["Strength"].default_value = 0.0

    saved = (scene.view_settings.view_transform, scene.view_settings.look, scene.view_settings.exposure,
             scene.cycles.samples, scene.cycles.use_denoising)
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0.0
    scene.cycles.samples = 48
    scene.cycles.use_denoising = False
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "BW"
    render(path)

    scene.render.image_settings.file_format = "JPEG"
    scene.render.image_settings.color_mode = "RGB"
    (scene.view_settings.view_transform, scene.view_settings.look, scene.view_settings.exposure,
     scene.cycles.samples, scene.cycles.use_denoising) = saved
    background.inputs["Strength"].default_value = strength
    for name, energy in lights.items():
        scene.objects[name].data.energy = energy
    for name, mats in originals.items():
        for slot, mat in zip(scene.objects[name].material_slots, mats):
            slot.material = mat


# ----------------------------------------------------------------------------- main


def main():
    reset()
    configure_render()

    white = material("paper-white", Roughness=0.62)
    white.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.84, 0.84, 0.84)

    _, oak = build_room()
    arm, label_corners = build_turntable(white)
    sleeve_corners = build_sleeve(white, oak)
    card, card_corners = build_light_card(white)
    glass, bulb = build_lamp()
    build_plant()
    sun, glow, world = build_lights()
    camera = build_camera()
    # Nothing has been evaluated yet, and projecting needs the camera's final position.
    bpy.context.view_layer.update()

    parked = arm_heading(RECORD_RADIUS + 0.035)
    playing = arm_heading(0.118)

    # The part of the picture the tonearm can change: the deck, with a margin.
    w, d, _ = DECK_SIZE
    reach = [projected(camera, Vector((DECK.x + sx * w / 2, DECK.y + sy * d / 2, z)))
             for sx in (-1, 1) for sy in (-1, 1) for z in (0.0, 0.13)]
    arm_rect = bounds(reach, pad=0.012)
    card_rect = bounds([projected(camera, c) for c in card_corners], pad=0.004)

    # How far a shadow lands from the thing casting it, per metre of height, in each light.
    sun_way = sun.rotation_euler.to_matrix() @ Vector((0, 0, -1))
    from_lamp = Vector((PILE_CENTRE.x, PILE_CENTRE.y, 0.05)) - bulb.location
    shadows = {
        "listening-room": {"shadow": [round(sun_way.x / -sun_way.z, 4), round(sun_way.y / -sun_way.z, 4)],
                           "softness": 0.006, "strength": 0.5},
        "after-hours": {"shadow": [round(from_lamp.x / -from_lamp.z, 4), round(from_lamp.y / -from_lamp.z, 4)],
                        "softness": 0.022, "strength": 0.42},
    }

    for name, night in (("listening-room", False), ("after-hours", True)):
        if ONLY not in ("all", "night" if night else "day"):
            continue
        set_time(sun, glow, world, glass, bulb, night)
        if not ARM_ONLY:
            arm.rotation_euler = (0, 0, parked)
            render(os.path.join(OUT, f"{name}.jpg"))
        arm.rotation_euler = (0, 0, playing)
        render_patch(os.path.join(OUT, f"{name}-arm.jpg"), arm_rect)
        if not ARM_ONLY:
            arm.rotation_euler = (0, 0, parked)
            card.hide_render = False
            render(os.path.join(OUT, f"{name}-light.jpg"), crop=card_rect)
            card.hide_render = True

    if ARM_ONLY:
        return
    arm.rotation_euler = (0, 0, parked)
    render_mask(os.path.join(OUT, "room-mask.png"))

    layout = {
        "size": [WIDTH, HEIGHT],
        "camera": projection(camera),
        "cameraPosition": [round(v, 5) for v in camera.location],
        "sleeve": [projected(camera, c) for c in sleeve_corners],
        "label": [projected(camera, c) for c in label_corners],
        "armPatch": [round(v, 6) for v in arm_rect],
        "pile": {"centre": [PILE_CENTRE.x, PILE_CENTRE.y], "size": SLEEVE, "thickness": SLEEVE_THICKNESS, "turn": PILE_TURN},
        "lightCard": {"centre": [PILE_CENTRE.x, PILE_CENTRE.y], "size": LIGHT_CARD, "height": LIGHT_CARD_HEIGHT,
                      "patch": [round(v, 6) for v in card_rect]},
        "scenes": shadows,
    }
    with open(os.path.join(OUT, "room.json"), "w") as handle:
        json.dump(layout, handle, indent=2)
    print("wrote", os.path.join(OUT, "room.json"))


# ----------------------------------------------------------------------------- the view from above

DESK_VIEW = Vector((DECK.x - 0.33, DECK.y, 0.0))  # the point of the desk at the middle of the picture
DESK_WIDTH = 1.52  # metres of desk across the picture
DESK_SLEEVE = Vector((DECK.x - 0.50, DECK.y + 0.005, 0.0))
DESK_PILE = Vector((DECK.x - 0.87, DECK.y - 0.01, 0.0))
RECORD_TOP = 0.012 + DECK_SIZE[2] + 0.016 + 0.0024
ARM_HEIGHT = 0.012 + DECK_SIZE[2] + 0.034


def build_flat_sleeve(white):
    card = material("card", Roughness=0.75)
    card.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.82, 0.8, 0.75)
    thickness, turn = 0.005, math.radians(5)
    box("sleeve", (SLEEVE, SLEEVE, thickness), (DESK_SLEEVE.x, DESK_SLEEVE.y, thickness / 2), card, rotation=(0, 0, turn))

    half, top = SLEEVE / 2, thickness + 0.0004
    placed = Matrix.Translation(DESK_SLEEVE) @ Matrix.Rotation(turn, 4, "Z")
    corners = [placed @ Vector(p) for p in [(-half, half, top), (half, half, top), (half, -half, top), (-half, -half, top)]]
    quad("dyn-sleeve", corners, white)
    return corners


def build_mug(at):
    glaze = material("glaze", Roughness=0.28)
    glaze.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.8, 0.76, 0.68)
    glaze.node_tree.nodes["Principled BSDF"].inputs["Coat Weight"].default_value = 0.4
    coffee = material("coffee", Roughness=0.06)
    coffee.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.05, 0.022, 0.01)

    cylinder("mug", 0.043, 0.088, (at.x, at.y, 0.044), glaze, bevel=0.004, vertices=96)
    cylinder("coffee", 0.0375, 0.002, (at.x, at.y, 0.0885), coffee, vertices=96)
    bpy.ops.mesh.primitive_torus_add(
        major_radius=0.024, minor_radius=0.0065, location=(at.x + 0.046, at.y + 0.02, 0.045),
        rotation=(math.radians(90), 0, math.radians(24)),
    )
    handle = bpy.context.object
    handle.name = "mug-handle"
    handle.select_set(False)
    finish(handle, glaze)


def footprint(camera, objects):
    """The rectangle of the picture a set of objects covers."""
    seen = []
    for obj in objects:
        for corner in obj.bound_box:
            seen.append(projected(camera, obj.matrix_world @ Vector(corner)))
    return seen


def main_desk():
    reset()
    configure_render()
    scene = bpy.context.scene

    white = material("paper-white", Roughness=0.62)
    white.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgb(0.84, 0.84, 0.84)
    walnut = wood("walnut", (0.105, 0.042, 0.016), (0.2, 0.088, 0.032), (0.31, 0.15, 0.058), roughness=0.4, coat=0.18, plank=0.19)

    box("table", (4.6, 3.4, 0.05), (DESK_VIEW.x, DESK_VIEW.y, -0.025), walnut)
    arm, label_corners = build_turntable(white)
    sleeve_corners = build_flat_sleeve(white)
    card, card_corners = build_light_card(white, at=DESK_PILE)
    build_mug(Vector((DECK.x + 0.27, DECK.y + 0.325)))
    build_plant(Vector((DESK_VIEW.x - 0.70, DESK_VIEW.y + 0.47, 0.0)), all_round=True)

    # Afternoon sun from the upper left, through a window with broad panes.
    direction = Vector((0.6, -0.38, -0.70)).normalized()
    bpy.ops.object.light_add(type="SUN")
    sun = bpy.context.object
    sun.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    sun.data.angle = math.radians(1.6)
    sun.data.color = (1.0, 0.8, 0.58)
    sun.data.energy = 5.4
    sun.select_set(False)
    build_window(direction, Vector((DESK_VIEW.x + 0.1, DESK_VIEW.y + 0.02, 0.0)), opening=(2.3, 1.75), slat=0.075, gap=0.5, upright=0.62)

    world = bpy.data.worlds.new("world")
    world.use_nodes = True
    scene.world = world
    world.node_tree.nodes["Background"].inputs["Color"].default_value = rgb(1.0, 0.9, 0.8)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.34
    scene.view_settings.exposure = 0.15

    height = DESK_WIDTH * 50 / 36
    bpy.ops.object.camera_add(location=(DESK_VIEW.x, DESK_VIEW.y, height))
    camera = bpy.context.object
    camera.data.lens = 50
    camera.data.sensor_width = 36
    scene.camera = camera
    camera.select_set(False)

    moving = [obj for obj in scene.objects if obj.parent == arm]
    parked, lead_in, run_out = arm_heading(RECORD_RADIUS + 0.035), arm_heading(0.146), arm_heading(0.062)
    arm.rotation_euler = (0, 0, lead_in)
    bpy.context.view_layer.update()

    # Per metre of height, how far a shadow lands from its caster.
    cast = Vector((direction.x / -direction.z, direction.y / -direction.z, 0))
    lift = ARM_HEIGHT - RECORD_TOP
    arm_rect = bounds(footprint(camera, moving), pad=0.012)
    shadow_rect = bounds(
        footprint(camera, moving) + [projected(camera, obj.matrix_world @ Vector(c) + cast * 0.05) for obj in moving for c in obj.bound_box],
        pad=0.016,
    )
    card_rect = bounds([projected(camera, c) for c in card_corners], pad=0.004)
    pivot = Vector((PIVOT.x, PIVOT.y, ARM_HEIGHT))

    # 1. The desk, without the moving part of the arm.
    for part in moving:
        part.hide_render = True
    render(os.path.join(OUT, "turntable.jpg"))
    card.hide_render = False
    render(os.path.join(OUT, "turntable-light.jpg"), crop=card_rect)
    card.hide_render = True
    render_mask(os.path.join(OUT, "turntable-mask.png"))

    # 2. The arm alone, lit by the same room but with nothing else in the picture.
    meshes = [obj for obj in scene.objects if obj.type == "MESH"]
    for part in moving:
        part.hide_render = False
    unseen = {obj.name: obj.visible_camera for obj in meshes if obj not in moving}
    for name in unseen:
        scene.objects[name].visible_camera = False
    render_patch(os.path.join(OUT, "turntable-arm.png"), arm_rect, clear=True)
    for name, was in unseen.items():
        scene.objects[name].visible_camera = was

    # 3. The arm's shadow alone, caught on a sheet at the height of the record.
    bpy.ops.mesh.primitive_plane_add(size=1.6, location=(DECK.x, DECK.y, RECORD_TOP))
    sheet = bpy.context.object
    sheet.name = "shadow-sheet"
    sheet.data.materials.append(white)
    sheet.is_shadow_catcher = True
    sheet.select_set(False)
    hidden = {obj.name: obj.hide_render for obj in meshes if obj not in moving}
    for name in hidden:
        scene.objects[name].hide_render = True
    for part in moving:
        part.visible_camera = False
    render_patch(os.path.join(OUT, "turntable-arm-shadow.png"), shadow_rect, clear=True)

    def turn(heading):
        # Anticlockwise on the desk is anticlockwise in the picture, which measures the other way.
        return round(-(heading - lead_in), 6)

    layout = {
        "size": [WIDTH, HEIGHT],
        "camera": projection(camera),
        "cameraPosition": [round(v, 5) for v in camera.location],
        "sleeve": [projected(camera, c) for c in sleeve_corners],
        "label": [projected(camera, c) for c in label_corners],
        "arm": {
            "pivot": projected(camera, pivot),
            "sprite": [round(v, 6) for v in arm_rect],
            "shadow": [round(v, 6) for v in shadow_rect],
            "shadowPivot": projected(camera, Vector((PIVOT.x, PIVOT.y, RECORD_TOP)) + cast * lift),
            "rest": turn(parked), "leadIn": turn(lead_in), "runOut": turn(run_out),
        },
        "pile": {"centre": [DESK_PILE.x, DESK_PILE.y], "size": SLEEVE, "thickness": SLEEVE_THICKNESS, "turn": 4.0},
        "lightCard": {"centre": [DESK_PILE.x, DESK_PILE.y], "size": LIGHT_CARD, "height": LIGHT_CARD_HEIGHT,
                      "patch": [round(v, 6) for v in card_rect]},
        "scenes": {"turntable": {"shadow": [round(cast.x, 4), round(cast.y, 4)], "softness": 0.006, "strength": 0.5}},
    }
    with open(os.path.join(OUT, "turntable.json"), "w") as handle:
        json.dump(layout, handle, indent=2)
    print("wrote", os.path.join(OUT, "turntable.json"))


if SCENE == "desk":
    main_desk()
else:
    main()
