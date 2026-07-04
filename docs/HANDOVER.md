# Recess Raiders — Handover Guide

**Read this first.** It gets a fresh session up to speed on the project, the working
conventions, the hard-won lessons, and the current open items. Written at the end of
the "V5 / audio + settings + structural terrain" work cycle, then updated with the
1.1 "consolidate and deepen" plan.

---

## 1. What the game is

**Recess Raiders** — a 3D 14-v-14 schoolyard "capture the loot" game built in
**Godot 4.6** with **GDScript**. One human player + 13 AI on the blue team vs 14 AI on red.

Core loop ("the omelet" — do not lose sight of this):
- Two teams of kids on a field split at the midline (Z=0).
- You raid the enemy half, grab their stuff (cones + balls), haul it back to your goal, and bank it.
- Win by draining the enemy's stash to zero.
- Crossing onto enemy turf makes you taggable. Tagged-while-carrying = you flop and drop the loot.
- Revive a downed teammate with R, or they auto-revive after 30s.
- "Safe zones" (pods) let you rest — but you CANNOT use them while carrying enemy loot (no camping).

Tennis mode has been **REMOVED** (gameplay code, menu dropdown, and tennis-only props all deleted in this session). The `mode` field stays as "raiders" for the mode seam, but Raiders is the only mode.
Don't invest in it unless the user explicitly asks. Most code paths gate it off.

---

## 2. The single most important working rule

**You cannot run Godot OR Blender in this environment. You can only statically verify.**
Every build you hand over is UNTESTED by you. Be honest about this with the user every time.

What you CAN do:
- Edit GDScript, build procedural meshes via SurfaceTool, write procedural-pose animation code,
  author Godot `.tres`/`.gd` resource files.
- Statically check syntax and a few error classes (see §4).

What you CANNOT do:
- Boot the game, playtest, tune feel, see rendering/lighting/shaders, generate audio, author or
  RE-IMPORT GLBs, change Godot import settings, or run Blender.
- GitHub is blocked from the sandbox. Only pypi / npm registries are reachable.

**Always tell the user: "static-verified only, never booted — needs your playtest + any OUTPUT-PANEL errors."**

---

## 3. Project layout

Working dir: `/home/claude/gauntlet/godot/`  (NOTE: the sandbox filesystem RESETS between sessions —
the project must be re-uploaded as a zip each new chat. Source assets — GLBs, mp3s — may still be in
`/mnt/user-data/uploads/`, but the scripts/scenes/project.godot only live inside the project zip.)

Architecture is a clean 3-layer split: **Input → Intent → Simulation → Presentation.**

Autoloads (`scripts/autoload/`): `Events` (global signal bus), `GameState`, `Config`, `Settings`, `AudioManager`.

Key scripts:
- `scripts/actor/` — `Actor.gd` (CharacterBody3D, the player/bot body), `CharacterRig.gd` (animated model),
  `CharacterDef.gd` (Resource describing one character — see §8b), `Perception.gd`, `Intent.gd`,
  `PlayCaller.gd`, and `controllers/{Base,Player,AI}Controller.gd`.
- `scripts/autoload/CharacterDefs.gd` — autoload registry that loads `assets/character/defs/*.tres` (§8b).
- `scripts/match/` — `Match.gd` (lifecycle), `TeamManager`, `BallManager`, `ConeManager`,
  `SafeZoneManager`, `Coach`, `Juice` (screen shake / hit-pause), `Environment` (terrain, trees, clouds,
  school, parking lot, road), `Field` (ground collision), `CameraRig` (all camera modes incl. debug fly-cam),
  `SkySun`, `GrassField`.
- `scripts/ui/` — `Hud.gd`, `MenuOverlay.gd` (main menu), `PauseMenu.gd` (in-game + settings panel).
- `scripts/Main.gd` — entry point; wires menu ↔ match.

Character assets: `assets/character/` holds per-body folders (`bluegirl/`, `red/`, `girl/`, `coach/`,
`fatboy/`, `indianboy/`) plus the loose `boy_*.glb` blue-boy clips. `assets/character/defs/*.tres` holds the
`CharacterDef` resources.

Docs: `HANDOVER.md` (this file, source of truth), `README.md`, `GLB_IMPORT_STRIP_GUIDE.md`, and
`docs/STATE_OF_PROJECT.md` (the current project snapshot) are the LIVE docs. `docs/archive/` holds the stale
pre-rename "Gauntlet"-era planning docs (banner-marked, history only — do not follow their instructions).

Scenes: `scenes/Main.tscn`, `scenes/Match.tscn`.

Config highlights (`scripts/autoload/Config.gd`): `TEAM_SIZE=14`, `FIELD_X=55`, `FIELD_Z=100`,
`WALK_SPEED=17`, `SPRINT_SPEED=31`, `SPRINT_FOV_BONUS=12`, `REVIVE_AUTO_TIMEOUT=30`,
`ai_can_fumble=true` (reversible flag). `intruding_into(team,z)`, `goal_pos(team)->Vector3`, `enemy_of(team)`.

Input actions live in `project.godot`: WASD, Shift sprint, Space jump, E interact/tag, R revive,
LeftClick throw, RightClick pass, V camera-cycle, **N debug fly-cam** (physical_keycode 78), Tab/Esc pause.

---

## 4. The verification battery — RUN THIS BEFORE EVERY PACKAGE

This is non-negotiable. Twice, errors reached the user because a package went out without re-running
the battery. **Always run all of it, immediately before zipping.**

1. **Syntax:** `gdparse <file>` on every `.gd`. (Installed via `pip install gdtoolkit --break-system-packages`.)

2. **Whole-vector inference sweep (CRITICAL — gdparse MISSES this).**
   `gdparse` does NOT catch the inference error Godot's compiler throws for
   `var x := some_vector_expr` where an operand defeats inference — e.g.
   `var to_goal := goal - a.global_position` fails in Godot even though both are Vector3.
   This class of bug reached the user TWICE. The fix is always: add an explicit type, e.g.
   `var to_goal: Vector3 = goal - a.global_position`.
   Sweep pattern: flag `var NAME :=` lines doing `+`/`-` arithmetic on a whole `.global_position`
   or `goal_pos(...)` (but NOT on `.x`/`.y`/`.z` float components, and not `Vector3(...)` constructors —
   those infer fine).

3. **Base-class shadowing.** Local vars/params named like Node3D properties (`scale`, `position`,
   `rotation`, `name`, `visible`, `velocity`, etc.) throw warnings. NOTE: `velocity` on an Area3D
   (e.g. `GoalCone.gd`) is a FALSE POSITIVE — Area3D has no `velocity`. Real cases: rename them
   (we use `tree_scale`, `time_scale`, etc.).

4. **Duplicate function defs** in a file.

5. **Unreachable code** after `return`/`break`/`continue` at the same indent. This once caught a REAL bug:
   inserting a new function accidentally ate the `func` header of the next one, orphaning its body.

6. **Enum member validity** — references like `Phase.PLAYING` must exist in the enum.

Inline lambda gotcha: GDScript does NOT allow a single-line statement-style `if` inside a one-line lambda,
e.g. `func(): if cond: foo()` is a PARSE ERROR. Use a named function instead.

---

## 5. Packaging (~198 MB after the asset strip; was ~422 MB)

Always the same output path (overwrite it):
```
cd /home/claude/gauntlet/godot
rm -f /home/claude/gauntlet/RecessRaiders_V2_Godot.zip
zip -rq /home/claude/gauntlet/RecessRaiders_V2_Godot.zip . -x "*.DS_Store" "*/.godot/*" ".godot/*" "*.import"
cd /home/claude/gauntlet && rm -f /mnt/user-data/outputs/RecessRaiders_V2_Godot.zip && cp RecessRaiders_V2_Godot.zip /mnt/user-data/outputs/ && sync
```
Then call `present_files` on `/mnt/user-data/outputs/RecessRaiders_V2_Godot.zip`.

**VERIFY THE SHIPPED ARTIFACT, not just the working dir.** A package once went out stale: the working
dir was correct but the file written to outputs was an OLD build (the copy hadn't persisted), and the user
tested the wrong thing for a full round. After copying, always re-read the bytes in outputs: `unzip -t` for
integrity, and `unzip -p <zip> <changed_file>` / `unzip -l <zip> | grep` to confirm THIS round's changes are
actually inside the shipped zip. Do not trust the reported size from `present_files`.

**Download size cap:** the chat download path fails on very large files. The 542 MB build (un-stripped new
GLBs) errored with "Failed to download and open file"; the strip (§5b) brought it back under control. Keep
builds lean — strip new clip GLBs before they ever ship.

---

## 5b. The GLB strip pipeline — how character assets stay small

**The problem:** Meshy exports one GLB per animation clip, and each clip GLB re-bakes the FULL mesh +
materials + a ~6 MB embedded texture. At runtime nothing uses that — `CharacterRig._harvest_clips()` (and
`Coach._harvest_clips()`) only pull the named animation track out of each clip GLB; the mesh comes solely
from the `*_base.glb`. So every clip GLB carries a redundant mesh.

**The fix (done for blue girl, red, girl, coach):** a source-level GLB strip that removes
meshes/materials/textures/images from each CLIP GLB while keeping its nodes, skeleton (skins +
inverseBindMatrices), and animation channels. The base GLB is NEVER stripped (it provides the mesh).
Result: clip GLBs drop from 6–18 MB to 30–180 KB each, with zero behavior change.

This is a STRONGER version of the in-editor import-strip in `GLB_IMPORT_STRIP_GUIDE.md` — it shrinks the
source files themselves, so it works headless and the user doesn't have to do anything in the editor.

The stripper is a standalone Python script (pygltflib not required for the strip itself — it parses the GLB
binary container directly). It was written ad-hoc each round and deleted after; if needed again, it:
parses the 12-byte GLB header + JSON/BIN chunks, marks accessors used by animations + skins, drops
mesh/material/texture/image/sampler arrays, prunes unused accessors/bufferViews, repacks the BIN buffer,
and re-emits a valid GLB v2. **Always verify after stripping:** every clip must still report its exact
internal animation name (the rig/coach match by name — a lost name = that state silently won't play) and
`skins>0`; the base must still report `meshes>0`.

**Hard rule:** only strip files whose mesh is unused. Before stripping a folder, grep the consuming script
for which GLBs it references and HOW (mesh-source vs animation-source). The coach round caught this:
`coach_walk_unsteady.glb` IS used by `Coach.gd`, and 4 other coach GLBs (`coach_arise/dead/walk/dance_night`)
are NOT referenced at all (stripped, not deleted — deletion needs user sign-off).

---

## 6. The recurring structural pain: TERRAIN + COLLISION

This has bitten us more than any other area. Read carefully before touching `Environment.gd` or `Field.gd`.

**Root cause of repeated jank:** there were historically THREE overlapping ground surfaces — an infinite
WorldBoundary plane, a flat collision box, and the rolling-terrain trimesh — and the *seams* between them
were where the player caught/janked when the ground height changed.

**Current (intended) structure after the last fix:**
- The **rolling terrain mesh** (`Environment._build_rolling_terrain`) is ONE continuous visual surface —
  flat at y≈0 in the gameplay zones, rolling into hills/mountains outside, with a smooth ramp between
  (`_terrain_flatten`). Winding is `p00→p11→p01, p00→p10→p11` with material `CULL_DISABLED` as a safety net
  (a past bug culled half the terrain; another carved away half via a bad asymmetric `in_box` skip — both removed).
  `cast_shadow = OFF` (a huge terrain shadow caster thrashed the shadow cascades).
- **Terrain COLLISION** is now a single continuous trimesh (no flat-box-footprint skip), on layer 16
  (player-only), positioned at y=0 so its flat zones line up exactly with the flat box (no step/seam).
- `Field.gd` keeps a deep WorldBoundary safety net far below (catches falls), plus a flat collision box
  on layer 8 for BOTS and the BALL (their masks include 8, not 16).
- Player has `floor_snap_length=4.0`, `floor_max_angle=70°`, `floor_stop_on_slope=false`,
  `floor_constant_speed=true` (set in `Actor._ready`) — this is what keeps the player glued to slopes.

**If collision jank is reported again:** do NOT just patch numbers. Check whether two collision surfaces
overlap at different heights (that's always been the cause). The structural answer is one continuous surface,
not stitched pieces. Verify height-sampling agreement between the visual mesh, the collision mesh, and
`_terrain_height()`.

**Trees:** the mesh is flat triangles between grid points, so a point-sampled height floats above the
triangle on slopes. Current fix in the forest builder samples the FOUR grid-cell corners, averages them, and
sinks ~0.3 so trunks sit in the triangulated surface. Over-sinking buries them; under-sinking floats them.
This is a known fiddly spot — if trees float OR bury, adjust the corner-average + sink, don't revert to
point-sampling.

---

## 7. Map layout (the school was flipped — get the orientation right)

Everything is out on +X from the field (which is centered at origin, spans ±FIELD_X=55, ±FIELD_Z=100).

- **School** at `FIELD_X+240`. Its ENTRANCE faces **+X (away from the field)**. The sidewalk connects to the
  **BACK** (-X, field side). The FRONT (+X) opens onto the parking lot. (This was flipped from an earlier
  version where the entrance wrongly faced the field.)
- **Sidewalk** wraps from the field, around both ±Z sides of the school, to the parking lot — 3 segments per side.
- **Parking lot** at `FIELD_X+360` — asphalt pad, painted stalls, parked low-poly cars (`_parked_car`:
  body + glass cabin + 4 cylinder wheels, varied colors, ~25% stalls left empty).
- **Main road** at `FIELD_X+520`, runs to the +X map edge, dashed center line.
- Terrain is flattened under the school/lot/road via `_terrain_flatten` rects. If terrain clips through the
  road/lot, the flatten rect is too small — widen it to cover the mesh footprint + margin.

---

## 8. Subsystem notes & current state

**Audio (`AudioManager.gd`).** User-supplied mp3s live in `assets/audio/music/`:
`welcome.mp3` (one-shot launch clip) and `menu.mp3` (the looping bed, used in menu AND in-game).
Flow: `play_welcome_then_music()` plays welcome once, and a `_welcome_playing` guard QUEUES any music
request (`_pending_track`) so the welcome can't be cut off — this was the "welcome cut off after 2s" bug
(the demo background's `match_started` was overriding it). Music loops via `stream.loop=true`.
Audio manager + players use `PROCESS_MODE_ALWAYS` so ESC pause doesn't silence music.
Separate volumes: `welcome_volume`, `music_volume_menu`, `music_volume_game` (in `Settings.gd`),
context auto-picked by `_apply_music_volume()`. NOTE: a one-line lambda with an inline `if` is invalid
GDScript — we use the named `_on_settings_applied_volume()` instead.

**Debug fly-cam (N key) — `CameraRig.gd`.** "God mode": hides player model, frees the camera, WASD along
look, Space=up, Ctrl=down, sprint=2.5x boost. Scroll wheel = FOV zoom (scroll DOWN = zoom IN; the user had
us REVERSE this once — respect that). Entering FREEZES the player (`set_physics_process(false)`, velocity=0)
so they return to the exact spot on exit. Sets `GameState.debug_mode=true`, which hides the HUD (Hud `_process`
early-returns) and makes NPCs ignore the player (`can_tag` returns false for the user; AI proximity loop skips
the user). Blocked in the menu/orbit mode (must be `phase==PLAYING and cam_mode != "orbit"`); also cleared in
`GameState.reset()` so it can't leak into the menu and break the skycam.

**Settings menu (`PauseMenu.gd`).** Built programmatically and appended to the `.tscn` panel's VBox.
Includes graphics toggles (GI/AO/reflections/SSIL/bloom/AA), grass/shadow quality, fullscreen, nametags,
sensitivity, master volume, the 3 audio volume sliders, and dual FOV sliders (`fov_first_person`,
`fov_third_person`, wired per camera mode in `CameraRig._update_fov`). The VBox is reparented into a
**ScrollContainer** at runtime (`_make_settings_scrollable`) because options overflow — this BREAKS the
hardcoded `$SettingsPanel/Panel/VBox/...` node paths, so populate/apply now use a stored `_settings_vbox`
reference + `get_node()` relative lookups. The `.connect()` calls run in `_ready` BEFORE the wrap, so they
bind to node refs and survive. **Main-menu settings:** the landing screen has a Settings button →
`Events.open_settings_request` → `PauseMenu.open_settings_standalone()` (shows the panel without pausing,
closes back to the menu via `Events.settings_closed_standalone`).

**Fullscreen.** Uses `WINDOW_MODE_EXCLUSIVE_FULLSCREEN` applied via `call_deferred` (plain FULLSCREEN was
unreliable and applying at `_ready` was too early). If alt-tab issues appear, switch to borderless.

**Win/lose end screen (`Hud.gd`).** The aiming reticle + lock ring now hide while `$EndScreen.visible`
(both in `_on_match_won` and guarded in the per-frame crosshair update). The single button became TWO:
**MAIN MENU** (`_on_main_menu_pressed` → `Match.return_to_menu()`, which tears down the match and restarts
the demo/skycam WITHOUT replaying the welcome audio — music keeps looping) and **QUIT**
(`_on_quit_pressed` → `get_tree().quit()`).

**NPC AI.** Carrier fumble (`ai_can_fumble`, reversible). Evasion: a chased carrier jukes perpendicular to
the nearest chaser instead of running straight (`_nearest_chaser()`, `_juke_phase`/`_juke_seed` per bot).
Perception is staggered (`_SENSE_INTERVAL`) so 27 bots don't all sense every frame. The user is PROTECTIVE
of AI feel — any AI change must be reversible / flagged, and called out explicitly. KNOWN WEAK SPOT (see §9):
bots currently query the world omnisciently instead of through `Perception`, so vision cones are cosmetic;
and they steer with separation pushes but don't navigate around the border-cone field.

**Jump-tag freeze (fixed).** Tagged-while-airborne used to freeze mid-air (velocity zeroed with no gravity).
Now the tagged branch keeps applying gravity until `is_on_floor()`, and `on_tagged` keeps GROUND collision
(mask 8|16 for user, 8 for bot) so the body falls and lands and is revivable.

**Player tagging (`Actor.best_tag_target`).** Tag reach is a MIX of proximity + aim (changed from a flat
`PLAYER_ACTION_RANGE` proximity gate that ignored where you point). Per-target reach = `TAG_RADIUS` (5.0,
the no-aim contact floor — tag anyone this close even facing away) + an aim-scaled bonus out to
`PLAYER_ACTION_RANGE` (9.0) when the reticle is dead-on (aim_dot=1). So aiming at an enemy extends your reach;
you can't tag a distant enemy you aren't looking at. In fp/third modes `heading` tracks the camera/reticle, so
the aim term reflects where you point. The HUD "Press E to tag" prompt and the actual tag both call
`best_tag_target()`, so prompt and action never desync. NPCs use `_npc_tag_target()` (no aim term — no camera).

**AI separation steering (`AIController._avoid_and_steer`).** Teammate spacing + threat-avoidance is applied
as a `push` blended into `intent.move`. The raw push flips direction as a bot passes teammates, which caused
(a) a side-to-side STUTTER while moving forward and (b) a rigid "whole team moves as one blob" feel. FIX: the
push is now SMOOTHED over time (`_smoothed_push.lerp(push, 1-exp(-8·delta))`) so it can't reverse in one frame,
and `intent.move` is weighted 2.2:1 over the push (was 1.4:1, with push clamp 2.2 able to overpower intent) so
each bot follows its OWN goal and merely drifts apart instead of moving in lockstep. Target-claim penalties
(0.4-0.5× for already-claimed targets, in `_choose_job`) already spread bots across different objectives —
that half was working and wasn't touched.

**Character select (`MenuOverlay` MODEL step).** Team + model choice MERGED on one screen: big rotating 3D
viewer (left), team buttons (Blue/Red) under it, and a FIXED grid of `MODEL_SLOTS` (28 = full 14-v-14 roster)
headshot slots (`_build_model_grid`, 7x4) on a free-positioned `_model_layer`. ALL models from both teams
fill the grid; the non-selected team greys out (`_pick_team_in_place`); unused slots are greyed
`_make_empty_slot` placeholders, so adding a def just fills the next slot. Cards are headshot-only at this
density (name in the big label up top); size auto-scales to fit. Start (`_on_start_pressed`) launches directly
on casual (the difficulty-select step was removed). Data-driven
from `CharacterDefs.defs_for_team`. Cards show a rendered HEADSHOT (front-facing head shot of the base
model), produced once each by a single reusable snapshot SubViewport (`_render_headshot`/`_process_shot_queue`)
that loads the model, frames the head, waits a few frames, then copies the viewport texture into the card's
TextureRect — serial, so no 8 live viewports. `_clear_options` frees `_model_layer` + clears the shot queue.

**Settings (tabbed, `PauseMenu._build_settings_tabs`).** Rebuilt in code as a `TabContainer` (Gameplay /
Graphics / Audio / Key Bindings) inside the scene's `SettingsPanel/Panel` shell. Every control writes to
`_pending` via a `_ctl` id→control dict; commits only on Apply (`Settings.apply_pending`). Back bottom-left,
Apply bottom-right. Key Bindings tab is a read-only reference list for now (rebinding TBD). The old flat-list
builders + scroll hack + per-control member vars were removed.

**Height pulse on movement + splash race + tag responsiveness.** (1) HEIGHT PULSE: both girls' WALK clips
carried a constant Hips SCALE of 1.176 (Meshy artifact) — idle 1.0, blend into walk = grow 18%, blend to run =
shrink. Node-level scale lock could not see it (bone scale). Fixed: channels neutralized to 1.0 in both walk
GLBs AND a harvest-level guard now strips EVERY scale track from every harvested clip (these rigs never
legitimately animate bone scale) — this class of bug is now impossible. (2) SPLASH: rare random scramble = a
first-frame layout race; _run now awaits one process_frame before measuring letter positions. (3) TAGGING:
TAG_RADIUS 5.0->6.5 (contact reach was ~2.6 units beyond touching capsules — frames-wide window at sprint
closing speeds), TAG_HEIGHT_TOL 3.5->3.0 (jump apex is 3.6; dodge now works through most of the arc, ground
tags unaffected), tag cooldown 0.4->0.25 both sites (player + NPC share the tuning; cooldown fires only on
successful tags, whiffs never locked out).

**SPRINT RUBBERBAND — TRUE ROOT CAUSE (baked root motion) + juice pass + caching cleanup.** The persistent
per-character sprint rubberband was IN THE CLIPS: blueasiangirl run_fast had +248 units and bluegirl run_fast
+418 units of baked Hips Z drift per loop — the body runs forward then SNAPS BACK at the loop point. Only the
two girls' run_fast clips were dirty (all other locomotion clips verified in-place), and variant kids pick
run/run_fast randomly per spawn = why it was random/per-character and survived three real-but-different
movement fixes. FIX: linear de-drift baked into both GLBs (progressive (t/T)*drift subtracted from Hips X/Z,
bob preserved, verified 0.0 drift). RUN THE DRIFT CHECK on every future locomotion import (hips first->last
key delta; >3 units = bad). JUICE: Events.actor_landed(actor, impact) emitted on air->floor with fall speed
captured pre-move_and_slide; Juice adds hit_pause(0.05) + orange burst on near-player tags, dust puff on
landings (impact>12), CPUParticles3D one-shot _burst helper (self-freeing, low-end safe). CACHING: GameState
frame-stamped actors() cache already existed and AI/Actor used it; converted the 3 remaining direct scans
(BallManager/SafeZoneManager/Match). DEFERRED with reasons: Actor decomposition (risky blind, needs its own
session with a plan), rebindable keys (own UI session), FatBoy strafe (NO strafe clips exist in any pack —
user must generate via Meshy first).

**Triple fix: preset stomp / sprint jitter / sit-idle pop.** (1) PRESET: the settings panel PRE-POPULATES
_pending with every current value on open; Apply then let those stale values overwrite the preset batch =
"nothing changes". apply_pending now detects a preset CHANGE, applies it, and DROPS the granular video keys
from that commit (preset wins). Performance = LOWEST (grass 0/off, shadow 0/off via DirectionalLight
shadow_enabled toggle in apply_runtime_video, gi 0, all fx off, 0.75 scale). PauseMenu refreshes controls
post-Apply (_load_settings_into_controls, extracted from _open_settings). (2) SPRINT rubberband (3rd
mechanism): physics interpolation renders bodies INTERPOLATED but camera followed raw physics
global_position -> camera/body desync jitter at speed, varying with each model run-bob (why it seemed
per-character/random). CameraRig now follows target.get_global_transform_interpolated().origin. (3) SIT-IDLE
POP: sit clips END at hips z=-49 (root motion walks back onto the seat) but idle clips play at z=+9 -> 58-unit
forward pop. Baked (sit_end - idle_mean) into every idle GLB Hips translation accessor (sway preserved,
min/max fixed, verified 0.0000 diff). Re-run this bake for ANY future sit-idle import.

**Smart Boy completion + SIT-IDLE system.** Imported (skin-kept strip) indianboy jump/sit/sit_exit/sit_idle
+ asianboy 3 sit-idles. Measured: IND jump takeoff 0.57 (trim 0.5), sit onset 0.1 (trim 0.1), sit_exit onset
0.6 (trim 0.55). NOTE: IND sit/sit_exit motion runs nearly full length (4.5/6.0s of 4.8/6.2) — NOT dead tail,
just leisurely clips; no cuts (cutting would freeze mid-motion). Long stand is blended off by the existing
1.0s _stand_lock -> locomotion self-heal (same as other models). SIT-IDLE: def keys sit_idle/_2/_3; rig picks
one at random per BUILD, adds looping "sit_idle" state, sit->sit_idle AT_END AUTO, sit_idle->sit_exit
IMMEDIATE. Only exact keys sit/sit_exit are one-shot, so sit_idle* loops automatically. indianboy sit_raise
1.0 / sit_forward 1.8 (BLIND — tune from playtest).

**Kid-height SCALE LOCK.** User report: per-game heights apply at spawn but revert to default when running
starts (all actors). Static hunt came up empty: clips have NO non-joint channels (verified via pygltflib),
facing uses rotation.y only, no runtime scale writers anywhere. Suspect = animation-system internals post
tree-restructure. Mitigation: CharacterRig stores _model_inst + _locked_scale at build; _process re-asserts
both the model scale and rig scale (Vector3.ONE) every frame, with a ONE-TIME push_warning naming which node
drifted and from what value — the console warning is the root-cause diagnostic. If the warning ever fires,
report the values; if heights stay put WITHOUT the warning, the bug was perceptual (FOV) or elsewhere.

**Settings live-apply fix + signal-bus convention.** Every Events signal needs @warning_ignore("unused_signal")
(the bus emits from other scripts; convention documented in the file header — forgetting it = UNUSED_SIGNAL
warning at boot). Settings WERE mostly live (apply_runtime ends with settings_applied.emit -> render scale,
shadow atlas, grass, TAA, fullscreen, volumes all fire) — but the WorldEnvironment effects (SSAO/SDFGI/SSIL/
SSR/glow) were BUILD-TIME ONLY, so the most visible preset changes only appeared next match. Environment now
stores _env_res + _apply_env_quality() on settings_applied (mirrors build values in _setup_sky_and_fog — keep
in sync). Toggling the Performance preset is now instantly visible (GI/SSAO/bloom pop off live).

**Main Menu button (pause -> title).** PauseMenu builds a "Main Menu" button IN CODE at _ready (scene file
untouched), inserted between SettingsBtn and Exit (custom_minimum_size 220x48 to match). _to_main_menu():
unpause + hide, then Events.main_menu_requested -> Main -> Match.return_to_menu() (which already existed,
doc-commented for this exact button, and does GameState.reset + teardown + begin_demo + returned_to_menu
emit; MenuOverlay re-shows LANDING, HUD hides, mouse frees). New match via Start re-shows HUD in _on_join.

**Graphics Quality Preset (Performance/Quality).** Settings.graphics_preset (int, setter batch-writes the
granular video vars via _batch_preset; load order in load_settings puts preset FIRST so saved granular values
survive restarts). NEW Settings.render_scale (root viewport scaling_3d_scale, 0.75 on Performance) +
apply_runtime_video() (also drives directional shadow atlas 2048/4096 + soft-filter quality via
RenderingServer — no node lookups). Hooked at boot (call_deferred) + Events.settings_applied. PauseMenu
Graphics tab has the "Quality Preset" dropdown (uses the existing _add_option/_pending machinery). Environment
grass now REBUILDS on settings_applied and quality 0 means OFF (used to still draw 8000 blades); low=14000,
high=38000. docs/BACKLOG.md is now GITIGNORED (internal to-do, not published).

**GODOT VERSION POLICY (mystery of the laptop errors, SOLVED).** The user's laptop runs Godot 4.7; the
project + main PC are 4.6. The "84 errors" are ONE benign 4.7 deprecation warning x 3 blend points x 28 kids:
AnimationNodeBlendSpace1D::add_blend_point wants an explicit name in 4.7+ (CharacterRig _build_tree lines
~329-331). DO NOT add the name argument while the project targets 4.6 — the parameter doesn't exist there and
the call would fail. The earlier "86 errors on weak hardware" were the same version skew (the Vulkan-driver
hypothesis was wrong). WHEN THE PROJECT UPGRADES to 4.7+: add explicit names to the three add_blend_point
calls and re-audit for other deprecations. Until then: run 4.6 on every test machine for apples-to-apples.

**AnimationTree v2: upper-body throw + locomotion speed sync (V1.1).** ROOT RESTRUCTURE — all tree param
paths changed. Root is now a BlendTree: node "sm" (the whole prior state machine, throw STATE removed) ->
optional filtered AnimationNodeOneShot "throw_shot" (shot input = "throw_anim"). The OneShot filter is built
DYNAMICALLY from the harvested rig/throw clip's track paths whose bone is in UPPER_BODY_BONES (Spine02 up +
arms/head) — legs+Hips stay with locomotion, so pitching overlays a run. play_throw() = set
parameters/throw_shot/request FIRE (no more _throwing guard/timer, all removed); play_dead ABORTs the shot.
Locomotion state is itself a BlendTree {bs: BlendSpace1D -> ts: TimeScale}; set_locomotion(ratio, delta,
speed=-1) drives parameters/sm/locomotion/bs/blend_position + ts/scale = clamp(speed/expected, 0.6, 1.4)
(expected = WALK at 0.5 blend, lerp to SPRINT at 1.0) — feet track actual velocity, no skating. Actor passes
Vector2(velocity.x, velocity.z).length(). PATHS NOW: parameters/sm/playback, parameters/sm/locomotion/bs/...,
parameters/sm/locomotion/ts/scale, parameters/throw_shot/request. Anything touching the tree must use these.

**Boot music glitch + interpolated-camera warning.** The boot DEMO match emits match_started at launch,
which started menu music at t=0 — then the welcome VO (0.95s) swapped the stream and music resumed after =
the music->welcome->music cutting glitch. _on_match_music now only QUEUES the track (no play, no whistle)
while the welcome hasn't finished; _on_welcome_finished starts the queued track. CameraRig camera is moved in
_process (render-frame smoothing), so it is exempted from physics interpolation in _ready
(PHYSICS_INTERPOLATION_MODE_OFF) — kills the 11x "Interpolated Camera3D triggered from outside physics
process" warnings. Low-spec hardware note stands (86 errors on a weak laptop, likely Vulkan/forward_plus
driver issues — Low graphics preset remains on the backlog).

**Ball size, tag polish, physics interpolation.** Ball RADIUS 1.5->1.25 (Ball.gd const + scenes/Ball.tscn
collision — BOTH must match). Tagging: TAG_HEIGHT_TOL 3.5 vertical gate in can_tag (jumping over a tagger now
dodges; also stops cross-height tags) + REVIVE_TAG_GRACE 1.2s (_tag_grace, set in revive(), checked in
can_tag — anti tag-camping). project.godot: physics common/physics_interpolation=true (render-interpolated
motion, smoother at any framerate). LOW-SPEC NOTE: renderer is forward_plus (Vulkan) with 4096 soft shadows +
30k grass blades w/ per-blade actor loop — weak-GPU machines may spew driver/pipeline errors and chug; test
with --rendering-method gl_compatibility to confirm, consider a Low graphics preset if confirmed.

**Sprint surge fix #3 (release-gated latch) + THROW ANIMATION.** The gassed latch auto-resumed sprint at 25%
stamina while shift was HELD -> slow sprint-burst/walk surge cycles on long runs (the "reintroduced" glitch;
the audit's constant removal was verified innocent). Latch now clears only when recovered AND sprint released
(AI already self-gates at stamina>8 so bots are unaffected).
THROW: all 3 packs' baseball_pitching imported (girl/redasianboy/indianboy _throw.glb). Kinematic analysis
(composed RightHand world trajectory): all clips 4.0s, release = peak hand speed at 1.63s. Trim 1.25 + NEW
clip_cuts dict (end cut) 1.1s -> release 0.38s in. Rig: throw state, AT_END auto-return, _throwing guard,
play_throw()/has_throw(). Actor: _begin_throw stashes want_pass/aim, plays anim, releases ball after
Config.THROW_ANIM_RELEASE_DELAY (0.38); tagged mid-windup cancels (ball already drops). Ball-carry visual
already rides the RightHand BoneAttachment3D (_hand_attach). Models without a throw clip release instantly.

**Full-system audit (all clean).** Parse 36/36; no shadows/dups/dead-funcs; inference sweep clean; every
res:// path in scripts exists; group wiring verified; all 8 defs cross-checked against their GLBs (paths exist,
anim names match, every clip keeps its skin — the automated T-pose guard). Removed 9 dead Config constants
(TARGETS_TO_WIN, THROW_SPEED/UP, PASS_SPEED, CATCH_COOLDOWN, CAM_HEIGHT/BACK/LERP, BORDER_CONE_RESET —
superseded by newer systems, confirmed unreferenced incl. scenes/dynamic). The def<->GLB cross-check script
pattern (integrity of clip_paths + clip_anim_names + skins via pygltflib) is worth re-running after any model
import.

**Welcome audio at splash start + headshot zoom.** `play_welcome_then_music()` moved from the splash's
_finish() to _ready() — the voice line starts WITH the splash, music rolls on after it as before (the
_welcome_started guard + AudioManager's 6s boot fallback still cover splash-skipped paths). Headshot distance
tightened to `3.1*head_h + 1.0` (~42% frame height) after user confirmed framing but wanted faces bigger.
CONFIRMED FIXED by playtest: sprint slingshot, char-select framing/pose, sitting ("fine for now").

**Sprint SLINGSHOT across the map (the real remaining sprint bug).** Distinct from the stamina flicker: the
user's "slingshot back and forth across the map" was the FALL-THROUGH SAFETY NET teleporting to SPAWN.
Sprint over a terrain seam (esp. beyond the field edge, where the player may roam but collision may gap) →
fall below y=-20 → silent snap to spawn (map-scale jump) → run back → repeat. Fix: actors track
`_last_safe_pos` (last on-floor spot with sane y); the net now restores THERE (+2y) and `push_warning`s with
coordinates so remaining terrain holes are visible in console. `_move_vel` is zeroed on restore. If slingshot
recurs WITHOUT the warning, the cause is elsewhere (camera/separation) — the warning is the diagnostic.

**Headshot framing v3 (two-bone).** Head bone alone fixed centering but not zoom variance/crown clipping.
Now frames from Head (chin/neck) + head_end (crown): their span = the model's actual head size; camera distance
= 3.6*head_h + 1.2 so every head fills ~the same frame fraction with crown headroom. Pattern: bone-pair
proportional framing.

**Sprint rubberbanding — ROOT CAUSE (3rd occurrence, now structural).** NOT the momentum lerp (that was
already isolated to _move_vel). The real cause: `can_sprint` required `stamina > 0`; at empty stamina sprint
flicked OFF, regen ticked stamina just above 0, sprint flicked back ON and drained it — oscillating
walk<->sprint SPEED every frame, which momentum turned into rubberbanding. Fixed with a hysteresis latch
`_gassed`: set true at 0 stamina, cleared only once stamina recovers past `Config.SPRINT_RECOVER_FRAC` (0.25).
Exhaustion is now a clean recover-from state, not a per-frame flip. (CameraRig already had a comment
band-aiding "momentary stamina dips" — that was the same flicker; root-fixed now.)

**Headshot T-pose + crop + per-model framing.** The base GLB's only clip is its static bind pose (T-pose), so
raw-instancing it photographed arms-out. `_pose_shot_model` pulls the model's walk clip (same source as the
live preview), seeks to ~25% stride (arms at sides), and pauses. Framing: mesh AABBs are UNRELIABLE on these
skinned rigs (aimed the camera at feet), and a fixed camera framed each model differently (heights/origins
vary). The reliable anchor is the SKELETON: after the pose applies (1 frame), `_find_skeleton` +
`find_bone("Head")` (fallback head_end; all 24-joint Meshy bipeds have it) gives the exact world head position
via `skel.global_transform * skel.get_bone_global_pose(bi)`; camera sits at head_y+0.3 and look_ats head_y-0.1.
Head-bone framing is the pattern for ANY future per-model camera work — never mesh AABBs on these rigs.

**Headshot auto-framing.** The first card looked cropped because the snapshot camera was FIXED at (0,8.6,7)
while models differ in origin/height (the girl sits higher in her base than the boys). 
now computes each model's union AABB (/) after a settle frame and re-frames
 to that model's head height + depth, so every headshot is consistent regardless of source
proportions.

**Character-select fixes.** (1) The ADOPTED splash title (`_adopted_title`, the flown-in letters that became
the menu title) is a separate node from `_title`, so `_show_step` now hides it on any non-LANDING step — it was
showing behind the character box. (2) Team buttons stay 100% opacity; active team shown by border color/width
via `_style_team_button`, NOT by dimming (only the opposite team's CARDS grey out). (3) `_card_style` now uses
UNIFORM border width (3) + content margins for all states — varying border width shifted the content box so the
selected card's headshot rendered smaller than the rest.

**Sprint rubberbanding (momentum feedback loop, FIXED AGAIN).** The momentum lerp read back
`velocity` as its current value, but `move_and_slide` rewrites `velocity` on every collision (benches, other
kids, varied-height bodies) — lerping toward target from that collision-reflected value oscillated =
rubberbanding. Now tracks its own `_move_vel: Vector2` independent of the physics velocity; zeroed in the
sit-lock. If sprint ever rubberbands again, suspect anything that reads back post-move_and_slide velocity.

**Per-def sit offsets.** `CharacterDef.sit_raise` / `sit_forward` (world units) tune where each model rests on
a bench — different sit clips drop the hips differently (girl -33, boy -27), so one hardcoded raise was wrong
for both. Actor._toggle_sit reads them via `rig.get_def()`. Current: girl 0.9/1.0, boy 0.6/1.0 (blind — tune
from playtest).

**HUD self-reshow bug (the "Pass!"-on-menu leak, FIXED).** `Hud._process`'s debug-fly-cam restore did
`elif not visible: visible = true` — re-showing the HUD EVERY FRAME it was hidden with debug off. Every
hide (boot demo, returned_to_menu, pause) lasted one frame; the scoreboard stayed self-hidden so the HUD
looked gone, but the flash label drew "Pass!" over the menu. Now gated by `_hidden_for_debug` — the restore
only re-shows what the debug path itself hid. If a HUD hide ever "doesn't stick" again, check for another
per-frame self-heal first.

**Sit positioning + red_asianboy sit clips.** Animated sitters snap to bench center RAISED 0.9 + 1.0 toward
the bench's front (+basis.z) so the seated pose rests ON the seat (ground-level center pin sank the body into
the bench). Both offsets first-draft tunables in Actor._toggle_sit; after standing the kid may release on top
of the seat slab (walkable, tune later). red_asianboy now has sit/sit_exit (Stand_to_Sit_M / Sit_to_Stand_M,
trims 1.3/1.4 — both clips ship >1.3s of static hold before the motion, measured from Hips curves). Menu
legibility tint fully removed (backdrop now matches the splash exactly; _build_blur_layer is an empty stub).

**Clip trims + animated bench sitting (per-model).** `CharacterDef.clip_trims: Dictionary` (key -> seconds)
trims a clip's LEADING dead time at harvest (`CharacterRig._trim_leading`: drop keys < trim, shift the rest,
shrink length). Fixes the jump desync — Meshy jump clips bake a ground windup (girl launches at ~0.5s of 1.93s;
red_asianboy at ~0.7s of 3.70s — both measured from the Hips Y-curve via pygltflib), so physics was airborne
during the windup. Trims: blue_asiangirl {jump 0.5, sit 0.4, sit_exit 2.3}, red_asianboy {jump 0.7}.
ANIMATED SITTING: defs with "sit"+"sit_exit" clips get rig states (sit holds the final seated pose like dead
holds the flop; sit_exit plays the stand-up). `_has_sit`/`_seated` guard `set_locomotion`'s self-heal (same
pattern as `_airborne`); API `has_sit/play_sit/play_stand/end_sit`; `play_dead`/`play_arise` clear `_seated`.
Actor: `_toggle_sit` plays the clips; standing holds a 1.0s `_stand_lock` (pinned while the stand anim's
front-loaded motion plays) then `end_sit()`. Models without sit clips keep the rigid stand. The girl's
Sit_to_Stand clip had 2.3s of SITTING STILL before the actual rise (hence the sit_exit trim) — always inspect
the Hips curve for dead time before wiring a Meshy transition clip.

**Splash→menu flash + HUD leaks (fixed).** The one-frame flash between splash and menu was `play_intro`
awaiting a process_frame BEFORE zeroing alphas — the menu rendered fully visible (own title stacked on the
adopted one) for that frame. Alpha-only intro needs no layout wait; zeroing is now synchronous. HUD leaks:
`Events.returned_to_menu` now re-hides the HUD in Main (background-match "Pass!"/"Tagged Out!" flashes were
drawing over the menu skycam after a match), and PauseMenu hides the HUD on pause / restores on resume.

**New model: Asian Girl Blue (blue_asiangirl).** Imported from BlueTeamAsianGirlUpdateAnim.zip via the strip
pipeline (base kept, clips stripped to skeleton+anim, ~83MB pack -> ~6MB on disk). Def at
assets/character/defs/blue_asiangirl.tres with core clips (walk=Walking_Woman, run=running, run_fast=run_fast_9,
dead, arise=Stand_Up4, alert, jump=Regular_Jump). Blue team now has 4 models (boy, girl, indianboy, asiangirl)
balancing red's 4. The pack also contains sit/crouch/throw(baseball_pitching) clips held for a later pass that
needs new rig states. Same still pending for the RedBoyAsian + BlueBoyIndian anim-update packs.

**Startup splash (`scripts/ui/SplashScreen.gd`, added to Main's UI layer).** Deterministic (not physics)
intro over the skycam demo backdrop: two gold "R"s fall from the top, staggered, with a wind-sway wobble +
impact squash + settle bounce; the rest of "Recess Raiders" extends out of each R via measured per-glyph x
positions (so spacing is natural); a gold+black-trim underline grows from the middle outward BELOW the glyphs
(y = ground + 1.12*fs, clears descenders). Then the whole title group flies up + scales to the menu title's
size/position and hands off — `finished` → Main shows the menu + `MenuOverlay.play_intro()` (fade the subtitle,
underline, and buttons in). AudioManager's boot welcome is DEFERRED so the splash triggers
`play_welcome_then_music()` at the fade (6s fallback timer if the splash is skipped/absent; `_welcome_started`
guard fires once). Skippable with any key/click. The menu's fisheye skycam shader was REMOVED (raw skycam like
the splash, subtle 0.18-alpha legibility tint). Demo HUD is hidden during the backdrop so "Pass!"/score never
draw over the menu.

**Pickup priority (`Actor._try_pickup`).** Rewrote nearest-wins selection to aim-weighted scoring
(`aim_dot*2 + proximity`), same fix tagging got — the reticle now decides which of several clustered items you
grab, instead of always the closest.

**Player momentum (`Actor` movement).** Horizontal velocity now eases toward target (ground rate ~10-13, air
~2.5, frame-rate-independent) instead of snapping, so movement has weight (ramp up / glide to stop) rather than
feeling stiff/on-off. Applies to bots too (smooths their motion). Sit-lock still zeroes velocity before this.

**Variable kid heights (`CharacterRig.build` height_mult + `TeamManager`).** Each kid's `height_cm`
(120-145) now drives a visual stature multiplier (~0.93-1.08, clamped 0.9-1.1) so the crowd reads as individual
elementary kids. The coach (Coach.gd, fixed MODEL_SCALE 4.5) is a separate system and stays a constant adult
height.

**Benches (`Environment._build_props` + `Actor`).** The 4 sideline benches have a two-shape `StaticBody3D`
collision (a SEAT slab + a BACKREST slab, so it's bench-shaped not a brick; off-field at x~65 so it never
blocks play) and join the `benches` group. `Actor.nearest_bench()` finds one within 6 units; the HUD shows
"Press E To Sit" (`_update_action_prompt`, lowest priority after tag/revive). Pressing E there calls
`_toggle_sit`: it SNAPS the player to the bench center, faces the field, and LOCKS them (a sit-lock block near
the top of the physics step pins `global_position`, zeroes velocity, and returns early). Press E again → stand.
There's NO sit animation yet, so the model stands rigidly on the seat (janky by design). `_sit_cooldown`
debounces sit-vs-stand; `on_tagged` clears `_sitting`. Guarded to never steal a pickup/tag/revive.

**Throw QTE (`Actor._request_throw` + `Hud.start_throw_qte`).** The HUMAN's throw/pass is gated behind a
timing-bar QTE (same bar as catching): pressing throw opens the bar; hit the window and the throw fires
(`execute_pending_throw`), miss/timeout and the ball is FUMBLED (`fumble_throw` → `Ball.drop_loose`, must be
re-grabbed). The release press is the throw/pass mouse button (or E). NPCs throw directly — `_request_throw`
early-returns to `_release_ball` for `not is_user`. `_throw_qte_active` guards re-trigger while the QTE runs.

**Catch QTE (`Hud.gd`).** When a pass is thrown to the human, a catch QTE opens with one of TWO randomly-
chosen flavors (`_qte_mode`): "timing" = the classic sweeping-cursor bar (press `catch_qte`/E in the green
window); "key" = press a specific shown keyboard key within ~1.4s. The demanded key comes from `QTE_KEY_POOL`
(F G H J K L Q T Y Z X B M — all verified UNBOUND to any game action) and never repeats twice in a row
(`_qte_last_key`). In key mode, pressing the right key = perfect catch, a wrong pool key = fumble. The panel
(`_configure_qte_panel`) shows the bar pieces for timing mode, a big boxed letter (`KeyPrompt`) for key mode.

**HUD messages are center-top** (`_throw_flash`, `_respawn_label`, `_safe_label` all anchored CENTER_TOP, y≈70/
120/110) so flashes, the tagged-out timer, and the safe-zone countdown sit in one tidy band instead of scattered.

**Safe zones (`SafeZoneManager.gd`).** Carriers (`has_target()`) are EJECTED from their own pod
(`eject_from_safe`), not merely marked unsafe — no camping with stolen loot. Dwell timer + lockout.
Live HUD countdown via `Actor.set_safe_seconds_left` / `safe_seconds_left`.

**Coach (`Coach.gd`).** `MODEL_SCALE=4.5` (kids are 2.7) so he reads as an adult (~1.6x).

**Clouds (`Environment.gd`).** Dynamic lifecycle: fade in → drift → fade out → respawn elsewhere.
The user wanted them SLOWED with MORE variation — current speeds are gentle, puffs 3–9, radii 6–26.
Each cloud has its own duplicated material so alpha fades independently.

**Sprint FX.** FOV punch on sprint, smoothed via `_sprint_fx_amount = move_toward(...)` so brief sprint-state
flicker (stamina dips) doesn't make the FOV jitter. The user reported this "bugging out"; the smoothing is a
best-guess fix since we can't playtest — if still wrong, get the EXACT symptom (snapping? not firing? stuck?).

---

## 8b. The CharacterDef system (built in 1.1 — READ before touching character loading)

This is the data-driven character system that replaced (additively) the hand-written clip dictionaries.
The DESIGN INVARIANT is additive-with-fallback: defs drive loading when present, and the old hardcoded
`CharacterRig` constants remain as a never-removed safety net. Do not delete the constants.

**`CharacterDef.gd`** — a `Resource` (`class_name CharacterDef`), pure data, no logic. Fields: `id`,
`display_name`, `team`, `base_model_path`, `clip_paths` (key→GLB), `clip_anim_names` (key→internal anim
name), `model_scale`, `scale_mult`, `facing_offset_deg`, `has_run_variants`, `run_variant_keys`. Core clip
keys required by `is_valid()`: alert, walk, run, dead, arise.

**`CharacterDefs.gd`** (autoload) — scans `assets/character/defs/*.tres` at startup, validates, serves by
id (`get_def`, `has_def`, `defs_for_team`, `all_defs`). Missing/invalid files are skipped with a warning,
never fatal — an empty registry just means everyone uses the hardcoded fallback.

**`CharacterRig.build(team_color, role, team, use_girl, def=null)`** — the `def` param is OPTIONAL and last.
With a def: model/clips/scale/run-variants come from the def. With `def==null`: the exact old hardcoded
branch runs (blue boy / red boy / girl by `team`+`use_girl`). Both paths share `_harvest_clips()`,
`_build_tree()`, tint, hand-attachment. The run-variant node keys off `_has_run_variants` (set by the def OR
the legacy red path), NOT `_is_red`.

**`TeamManager._spawn()`** routes the def: blue splits half/half by slot parity (`blue_is_girl = slot%2==0`)
into `blue_girl`/`blue_boy`; red splits into `red_girl` (when `use_girl`) / `red_boy`. The human player's menu
choice (`GameState.player_model`, now a def id like `"blue_girl"`) overrides their own body. If `get_def`
returns null for any reason, `def` is null → hardcoded fallback → game still works.

**Menu (`MenuOverlay.gd`)** — `MODELS` table now lists def ids: blue `[blue_boy, blue_girl]`,
red `[red_boy, red_girl]`. `_set_preview_model` loads the def's `base_model_path` (the mesh) and
`_play_preview_walk` HARVESTS the walk clip from the def and loops it, so previews walk instead of T-posing.
(The old `_play_idle` that played `list[0]` showed the bind/T-pose — removed.) Selection writes the def id to
`GameState.player_model`; `_spawn`'s override reads it.

**MIGRATION STATUS (all playtest-confirmed working by the user):**
- `blue_boy` — def-driven. Clips are the loose `boy_*.glb` (NOT stripped; original assets).
- `blue_girl` — def-driven. New model (Meshy "Blue Sports Girl"). Clips STRIPPED. `scale_mult=1.10` (tuned
  by the user from an initial 1.15 that was too tall; she's ~5.70 effective vs blue boy 5.97, red girl 5.67).
  Has 3 run variants (running / run_fast_5 / Female_Head_Down_Charge). 3 of her 12 source clips unused.
- `red_boy` — def-driven. Clips STRIPPED. `scale_mult=1.12` (the old "red exports smaller" adjustment).
- `red_girl` — def-driven. Clips STRIPPED. `scale_mult=1.0`. Shares red's internal anim names.
- `coach` — NOT def-driven. `Coach.gd` is a separate system (its own `_harvest_clips`/`_build_tree`, larger
  clip set incl. dances/boxing/skills). Its GLBs were STRIPPED for size only; `Coach.gd` is byte-unchanged.
  Migrating the coach to a def would need `CharacterDef` extended for its extra clips — deferred, low value.

**The hardcoded `CharacterRig` constants** (`BLUE/RED/GIRL_CLIPS/NAMES`, `*_BASE`) are still present and still
the fallback. They are NOT dead code — they fire whenever a def is absent/invalid. Keep them until every body
is a confirmed def AND the user signs off on removing the net.

**Audit note 2 (menu cleanup).** With team-select merged into the character page and difficulty fixed to
casual, the following became dead and were removed: the `Step.CUSTOMIZE` and `Step.DIFF` cases + enum values
(enum is now just `LANDING, MODEL`), `_pick_team`, `_pick_diff`, and the `MODELS` fallback constant. The
difficulty PRESETS in `Config.DIFFICULTY` (casual/skilled/ruthless) are KEPT — the AI-tuning system is live;
only the player-facing selection step was dropped, so restoring difficulty choice later is just re-adding a step.

**Audit note (dead code removed).** `Conductor.gd` was the old team-brain; it was superseded by `PlayCaller`
(which `TeamManager` instantiates as `_play_callers[team]`) but the file lingered, never instantiated. It was
deleted, and the stale "Conductor" names/comments in `TeamManager`, `AIController`, and `Config` were renamed
to PlayCaller. The `_raid_bias`/`_team_play`/`_team_flank` Config values and their get/set helpers are LIVE
(PlayCaller writes, AIController reads) — verify with grep before touching. Dead `Config` consts
`CONDUCTOR_PERIOD`/`MIN_GOAL_GUARDS`/`INTRUDER_ENGAGE_DIST` were removed.

**Jump animation (per-model, optional).** A def can set `has_jump = true` and include a `jump` clip in
`clip_paths`/`clip_anim_names`. The rig then builds a "jump" state in its locomotion state machine, and
`Actor` calls `rig.set_airborne(not is_on_floor())` each frame: travel to "jump" on takeoff, back to
"locomotion" on landing (both IMMEDIATE). `set_locomotion` is GUARDED so it won't yank the rig out of "jump"
while airborne; `play_dead`/`play_arise` reset `_airborne`. Bodies WITHOUT a jump clip keep `has_jump=false`
and hold their locomotion pose mid-air (old behavior) — jump is purely additive per-model. First model with
it: red_asianboy (Hoodie Boy Red), using "Jump_with_Arms_Open". The jump clip is harvested non-looping.

**Anim-name discipline:** the rig/coach match clips by the GLB's INTERNAL animation name (e.g.
`Armature|walking_man|baselayer`). These vary per export and do NOT always match the key. ALWAYS verify a new
GLB's real anim names (pygltflib: `[a.name for a in GLTF2().load(p).animations]`) before writing a def or
stripping — a guessed name = a silently non-playing state.

---

## 9. The 1.1 plan — "consolidate the foundation, deepen what's already half-built"

This is the agreed roadmap for the next release. It is a tweaking-and-polish pass, NOT a new-systems release.
Sequence matters: the first two items unblock everything else and stop asset bloat from compounding.

**>> STATUS: items (1) asset pipeline, (2) CharacterDef refactor, and the model-list half of (3) are DONE and
playtest-confirmed (see §8b). Remaining: the rest of (3) — per-team accent pick + random option — then (4)
perception-gated AI + navmesh, (5) graphics/tint polish, (6) AI weight calibration. NEXT UP: (4).**

**(1) Asset pipeline — DONE.** Solved better than originally planned: instead of (only) the in-editor import
strip, a source-level GLB strip (§5b) shrank clip GLBs headlessly. blue_girl/red/girl/coach all stripped;
project went 422→198 MB. The in-editor `GLB_IMPORT_STRIP_GUIDE.md` still applies as an additional reduction
the user can do, but isn't required.

**(2) `CharacterDef` resource refactor — DONE (see §8b).** Built additively as planned; all four team bodies
(blue boy/girl, red boy/girl) are now def-driven with the hardcoded dicts retained as fallback. Coach stays on
its own system.

**(3) Data-drive the menu off `CharacterDef` — PARTLY DONE.** The model list is now driven by def ids and
previews walk correctly (§8b). STILL TODO: (b) per-team color/accent pick, (c) a "random" option. The step
machine, orbiting background, and draggable preview were kept as-is (they were fine).

**(3) Data-drive the menu off `CharacterDef`.** Keep the existing step machine
(`LANDING → MODEL`, team+character merged, casual-only), live orbiting background, and draggable 3D preview — they're good.
Just: (a) drive the model list entirely from the `CharacterDef` folder so blue/red selectors stop being
hardcoded, (b) add a per-team color/accent pick (now that there's body-type variety), (c) add a "random" option.
Do NOT rebuild the menu — it's not where the problems are.

**(4) Perception-gated AI + navmesh.** **>> STATUS: perception-gating was ALREADY DONE (see below).
NAVMESH now CODE-COMPLETE (written this session, NOT yet playtested). Implementation: `NavManager.gd` (new,
in `Match.tscn` as node `NavManager`) builds a runtime navmesh — a flat field quad as traversable surface +
one carved projected obstruction per border cone — via `NavigationMeshSourceGeometryData3D.add_faces` (CW
winding) + `add_projected_obstruction(outline, 0, 4, carve=true)` + `NavigationServer3D.bake_from_source_
geometry_data` (deferred). `Match._begin_raiders` registers cone positions (from `ConeManager.
border_cone_positions`) and calls `nav_manager.build()` after cones, before team spawn. Each `Actor` has a
`NavigationAgent3D` (`nav_agent`, avoidance OFF — pathfinder only). `AIController._seek` sets the agent target
and steers toward `get_next_path_position()` instead of straight at the point; `_avoid_and_steer` separation
still layers on top. FAIL-SAFE: no baked mesh / unsynced map → agent returns the raw target → old straight-line
seek. RUNTIME-API RISK: the exact bake timing + map attachment have known first-frame gotchas that can only be
verified in-editor; if bots stand still or path oddly, check the Output for nav errors and that the region
attached to the world map. Perception-gating (already done, do NOT redo):
`AIController._grabbable_targets()` returns `perception.visible_targets`; `_threats_on_our_half()` filters
through `perception.visible_enemies` + `nearby_enemies` + `GameState.get_threat_beliefs`.**

**(5) Graphics/tint polish.** Forward+, TAA, 4096 shadows, soft shadows are already on. The deferred list
(claymation shading, vapor trails, day/night) stays deferred — needs in-editor iteration. The 1.1-appropriate
work: the team-tint lerps albedo 35% toward team color, which on a blue model over a blue jersey may read muddy
— look once both blue body types are side by side. A subtle per-team rim/outline separates the similar blue boy
and blue girl more reliably than albedo tint alone.

**(6) AI weight calibration pass.** Gameplay systems (carry/bank, safe zones, tagging, throw arcs) are solid —
treat 1.1 as calibration, not redesign. The utility weights are admittedly "first-pass." Put the key numbers
(catch probabilities, raid-bias thresholds, vision range) behind the existing difficulty presets and have the
user playtest the felt spread-vs-clump behavior. Resist adding mechanics.

**Sequence:** asset pipeline + `CharacterDef` → data-drive menu off it → perception-gated AI + navmesh →
graphics/tint polish → AI weight calibration.

---

## 10. Other open / deferred items (pre-1.1, still valid)

**Known issue + a FAILED fix attempt (don't repeat as-is):** revived NPCs SLIDE around the map briefly —
they move while the stationary arise ("tag back in") clip plays. A fix was tried (make `play_arise()` travel to
the real "arise" state + lock movement for the clip's ~1.87s via `Actor._arise_lock`) and it BROKE THE GAME
(reverted immediately; exact break not captured — get the symptom before retrying). The slide is still present.
A safer future approach: drive the arise pose without an immediate-move state change, or use a much shorter
lock / a small root-motion nudge — but confirm the failure mode first. `play_arise()` is currently back to its
original form (travels straight to "locomotion", returns void).

**Not yet built (user has asked, deferred as too big for a side-pass):**
- **Drivable cars** — press E near a parked car → hide player model, car becomes the controller, drive with
  spinning wheels, press E again → player respawns beside the car. A whole new control mode; its own project.
- **Keybinds page** — rebindable keys with conflict detection. Its own UI pass.
- Working hinged school doors (currently open gaps); school navmesh (only if school-NPCs are added).
- A possible PBR/realism material direction — a big call the user must make (low-poly vs realistic).
- Editor-only niceties we can't do from here: DoF, HDR sky, LightmapGI baking.

**Needs user playtest confirmation (claimed-fixed but unverified by us):**
- Structural terrain collision finally smooth on up/down height changes (claimed fixed multiple times — be humble).
- Trees neither floating nor buried.
- School flip + sidewalk wrap + lot + road all line up spatially (use the N debug cam to inspect).
- Welcome plays in full; pause keeps music; main-menu settings button works; sprint FX no longer bugs.

**Everything tuning-related is first-draft:** terrain heights, fumble/juke strength, cloud speeds, coach
scale, FOV defaults, audio volumes, floor-snap values. Expect to iterate from user feedback, not nail it blind.

---

## 11. Tone & how the user works

- Iterative, hands-on, sends real OUTPUT-PANEL errors — fix the exact error, then widen the relevant sweep so
  it can't recur. When the same class of bug repeats, the user (rightly) suspects a structural cause —
  step back and fix the structure, don't keep patching symptoms.
- Be honest and concise. Lead with what changed and why; always end with the caveat that it's static-verified
  only and list the specific things to playtest. Own mistakes plainly (we've shipped a couple of parse errors —
  acknowledge, fix, harden the check). Don't overclaim; flag what's a guess.
- Plan first for anything structural. Collapse duplicate rules to a single source of truth.

**Docs (V1 slim set):** this HANDOVER (authoritative technical reference), `BACKLOG.md` (roadmap),
`GLB_IMPORT_STRIP_GUIDE.md` (model pipeline), and the player-facing `README.md` (features + full how-to-play,
absorbed the old HOW_TO_PLAY). STATE_OF_PROJECT/PUSH_TO_GITHUB/HOW_TO_PLAY and docs/archive were removed for
the V1 repo reset. Fresh GitHub repo created at V1 (old repo deleted by user); project.godot carries
config/version="1.0".

---

*Logistics note: a conversation in the Claude app caps at ~20 file uploads AND ~100 files total, and neither
is reset by context compaction. The sandbox filesystem also resets between sessions. So each new chat:
re-upload the project zip (or a small scripts+scenes+project.godot zip — assets may still be in
`/mnt/user-data/uploads/`), extract to `/home/claude/gauntlet/godot/`, read THIS file, run the battery to
confirm the baseline, then continue.*


## VERIFICATION BATTERY

**KNOWN GAP:** the local `gdparse` checker does NOT do full type inference, so `:=` errors (Cannot infer type)
pass it but fail Godot's real parser. This has bitten 4x. A real Godot binary isn't available in the build
env (github releases are outside allowed egress). MITIGATION — before every package, run these inference
sweeps in addition to gdparse:
  1. Untyped-loop-var inference: any `for X in <call>()` (untyped Array source) followed by `var Y := X.method()`
     or `:= X[...]` — TYPE BOTH: `for xn in src(): var x: T = xn; var y: T2 = x.m()`.
  2. Variant-returning methods on := : `.get()`, `[...]` indexing untyped containers, `.front/.back/.pop_*/.pick_random`
     — always give the var an explicit type.
  3. When iterating `_all_mesh_instances()`/`GameState.actors()`/`get_nodes_in_group()` (all untyped Arrays),
     the loop var is Variant — type it before calling methods whose result you assign with :=.
  Rule of thumb: if the RHS receiver is a Variant, `:=` fails. Prefer explicit `: Type` on anything derived from
  an untyped Array/Dictionary/.get().

