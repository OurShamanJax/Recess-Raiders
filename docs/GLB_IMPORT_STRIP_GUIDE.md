# GLB Import-Strip Guide — cutting character asset size

**Audience:** you, in the Godot editor. Claude cannot do any of this — re-importing
GLBs and changing import settings is in-editor work. This is the manual half of the
1.1 asset-pipeline task. The code half (the `CharacterDef` resource + registry +
the blue-boy migration) is already done; this doc is what shrinks the files.

---

## Why the project is huge (~422 MB)

Every character currently ships **one GLB per animation clip**, and each of those
GLBs re-bakes the **full mesh + skeleton + materials** even though we only want the
animation tracks. So the blue boy carries its mesh ~6 times (base + alert + walk +
run + dead + arise); the girl/red carry it ~9 times. The mesh is the heavy part, so
this multiplies size for no benefit — at runtime `CharacterRig._harvest_clips()`
throws away everything except the animation track from each clip GLB anyway.

**The fix:** keep the mesh in ONE base GLB per character, and tell Godot to import
the clip GLBs as **animation-only** (drop their mesh + materials + skin on import).
Expected result for the girl: ~160 MB → ~20 MB. Same idea for every character.

There are two ways to do it. **Method A (per-clip import flag) is the safe one and
needs no Blender** — do that first. Method B (merge into one multi-take GLB) is
optional and only worth it later.

---

## Method A — import each clip GLB as animation-only (recommended, no Blender)

Do this for **every clip GLB that is NOT a `*_base.glb`**. The base GLBs keep their
mesh; only the clip GLBs get stripped.

For one clip file, e.g. `assets/character/boy_walk.glb`:

1. In the Godot **FileSystem** dock, double-click `boy_walk.glb` (or click it once
   and look at the **Import** dock, usually tabbed next to the Scene dock,
   top-left).
2. In the **Import** dock, set **Import As** to **Animation Library** (not the
   default "Scene"). This tells Godot the file is a source of animations, not a
   scene to instance.
   - If you don't see "Animation Library" as an option in your build, use **Scene**
     and rely on steps 3–4 to strip the mesh instead — the size win is the same;
     it's the mesh removal that matters.
3. Expand **Meshes** (or **Scene > Meshes**, depending on version) and turn the
   mesh import **off**:
   - Untick / disable mesh creation. The exact label varies by Godot point release
     — look for **"Import"** under a Meshes/Materials group, or a per-node toggle in
     the **Advanced Import Settings** (next step). The goal: no MeshInstance3D and
     no materials survive the import; only the AnimationPlayer + its tracks do.
4. Click **Advanced Import Settings…** (button at the bottom of the Import dock) for
   precise control:
   - In the node tree on the left, select the **mesh node(s)** and set their import
     mode to **skip / remove** (the dropdown by each node). Keep the **Skeleton3D**
     and the **AnimationPlayer**.
   - Confirm the **animation** you need is still listed under the AnimationPlayer
     with its original name — these must stay byte-identical, because the code
     matches them by name (see the name list below). Do **not** rename clips.
5. Click **Reimport**. Watch the file size of the generated import in
   `.godot/imported/` shrink (the source `.glb` on disk stays the same size — Godot
   keeps the original but the *imported* artifact is what ships and what's small).

Repeat for every clip GLB in:
- `assets/character/` (boy_*)
- `assets/character/girl/`
- `assets/character/red/`
- `assets/character/coach/`  ← the coach has the most clips, biggest single win

**Leave the four `*_base.glb` files alone** — those must keep their mesh.

### The animation names must NOT change

`CharacterRig` and the `CharacterDef` `.tres` files match clips by their exact
in-GLB animation name. If you rename anything on import, the rig won't find the clip
and that state will silently not play. The names currently in use:

| clip key | in-GLB animation name           |
|----------|---------------------------------|
| alert    | `Armature\|Alert\|baselayer`     |
| walk     | `Armature\|walking_man\|baselayer` |
| run      | `Armature\|running\|baselayer`   |
| dead     | `Armature\|Dead\|baselayer`      |
| arise    | `Armature\|Arise\|baselayer`     |

Red/girl variants additionally use: `Armature\|Casual_Walk\|baselayer`,
`Armature\|RunFast\|baselayer`, `Armature\|Run_03\|baselayer`.

(If you ever DO need to rename, that's fine — but then update the matching
`clip_anim_names` in the character's `.tres`, or the hardcoded `*_NAMES` dict in
`CharacterRig.gd` for the not-yet-migrated characters, to match.)

---

## Method B — merge clips into one multi-take GLB (optional, needs Blender)

Only worth doing if Method A doesn't shrink things enough, or you're consolidating a
brand-new character. The idea: one GLB holding the base mesh **plus all takes** as
separate animation actions, replacing the whole pile of per-clip files.

Rough flow in Blender:
1. Open the base model.
2. For each clip, import its animation and **Push Down** into the NLA editor as a
   named action/strip — name each strip to match the table above exactly.
3. Export a single GLB with **Animation > Group by NLA Track** (or your exporter's
   "export all actions") enabled.
4. In Godot, import it once; point a `CharacterDef`'s `base_model_path` at it and set
   every `clip_paths` entry to that same GLB (the harvester pulls each named track
   out of the one file).

This is more work and easy to get subtly wrong, so prefer Method A unless you have a
specific reason.

---

## How to verify it worked (without me)

After re-importing:
1. **Size:** check the project / export size dropped. The big wins are coach, girl,
   red.
2. **Boot the game and playtest** — specifically watch the **blue boy** (he now
   loads through the new `CharacterDef` path) and confirm:
   - he spawns with a mesh (not invisible / not a T-pose),
   - he **walks and runs** (locomotion blend works),
   - he **flops when tagged** (dead) and **gets back up** (arise),
   - carried loot still sits in his right hand.
3. If a clip is missing after stripping, the symptom is that one state not animating
   (e.g. he slides in T-pose instead of walking). That means the animation name got
   changed or dropped on import — re-check step 4 / the name table.

---

## What changed in code (so you know what you're testing)

- New `scripts/actor/CharacterDef.gd` — a `Resource` describing one character
  (model path, clip map, scale, run-variant flag).
- New `scripts/autoload/CharacterDefs.gd` — autoload that loads every
  `assets/character/defs/*.tres` and serves them by id.
- New `assets/character/defs/blue_boy.tres` — the blue boy, migrated as proof.
- `CharacterRig.build()` — now takes an **optional** `CharacterDef`. With a def it
  loads data-driven; **without one it runs the exact old hardcoded path**, so red,
  girl, and coach are untouched and known-good.
- `TeamManager._spawn()` — blue non-girl kids now fetch the `blue_boy` def; if it's
  missing/invalid they fall back automatically. Nothing else routes through a def
  yet.

Once you've confirmed the blue boy looks right, we convert red, girl, and coach to
defs the same way and delete the hardcoded dicts.


---

## CRITICAL LESSON: keep the SKIN when stripping clips

When stripping a clip GLB programmatically (dropping mesh/material/texture to shrink
it), you MUST keep the **skin + skeleton joints** (`skins`/`joints` in the glTF).
If you strip the skin too, Godot imports the clip's animation as raw node-path
tracks (`Armature/Hips/...`) instead of `Skeleton3D:BoneName` bone tracks, and those
tracks CANNOT resolve against the base model's Skeleton3D at runtime. Symptom: the
model is stuck in **T-pose** and the console floods with hundreds of
"AnimationMixer: couldn't resolve track: 'Armature/Hips/...'" warnings (one per bone
per clip). The skin is what lets Godot build a proper Skeleton3D and rewrite the
tracks into resolvable bone tracks. Verify a stripped clip with pygltflib: it should
report `skins=1, joints=24, meshes=0`. If `skins=0`, it will T-pose.
