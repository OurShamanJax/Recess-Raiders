class_name CharacterDef
extends Resource
## Data-driven description of one playable character (model + animation set).
##
## This is the additive replacement for the hand-written *_CLIPS / *_NAMES
## dictionaries that live in CharacterRig.gd. Instead of editing GDScript to add
## a character, you drop a CharacterDef .tres into res://assets/character/defs/
## and the rig (and, later, the menu) pick it up automatically.
##
## ROLLOUT STATUS (1.1, first pass): ADDITIVE / PROOF-OF-ONE.
## Only the blue boy currently ships as a .tres and flows through this path.
## The red boy and girl still load via CharacterRig's hardcoded constants as the
## known-good fallback. Do NOT delete the CharacterRig constants until every
## character has a verified .tres and the user has playtested them.
##
## A CharacterDef is intentionally a flat bag of data with NO logic — all the
## loading/harvesting/animation behavior stays in CharacterRig. That keeps the
## resource trivially editable in the inspector and serialization-stable.

## Stable identifier, e.g. "blue_boy". Used as the registry key and as the menu's
## model id. Keep it lowercase_snake and unique across the defs folder.
@export var id: StringName = &""

## Human-facing label shown in the menu, e.g. "Blue Kid".
@export var display_name: String = ""

## Which team this character belongs to ("blue" or "red"). The menu groups its
## model list by this; the sim uses it to pick a team's available bodies.
@export var team: String = "blue"

## The base model GLB (the rigged mesh; animation tracks come from the clips).
## Path string rather than a preloaded PackedScene so the resource stays pure
## data and the rig controls when/if it loads. Example:
##   "res://assets/character/blueboy/blueboy_base.glb"
@export var base_model_path: String = ""

## clip key -> source GLB path. Keys are the rig's logical states:
##   "alert", "walk", "run", "dead", "arise"  (+ optional variants below).
## Mirrors the old *_CLIPS dictionaries exactly.
@export var clip_paths: Dictionary = {}

## clip key -> the animation's internal name INSIDE that GLB, e.g.
##   "walk" -> "Armature|walking_man|baselayer".
## Mirrors the old *_NAMES dictionaries exactly. Keys must match clip_paths.
@export var clip_anim_names: Dictionary = {}

## Uniform model scale (was CharacterRig.model_scale, default 2.7). Some Meshy
## exports come in smaller and need a touch more; bake that here per-character
## instead of in branchy rig code.
@export var model_scale: float = 2.7

## Extra multiplier on top of model_scale, for bodies that export smaller than
## the others (the red boy used 1.12). Leave at 1.0 for normal bodies.
@export var scale_mult: float = 1.0

## Yaw applied to the instanced model so its forward aligns with Godot -Z.
## The Meshy rigs all face +Z by default, so 0.0 fits them; kept exported in
## case a future model is authored facing another way.
@export var facing_offset_deg: float = 0.0

## If true, this character has multiple run clips ("run", "run_fast", "run_03")
## and the rig picks one per-kid for visual variety (the old red/girl behavior).
## The blue boy has a single "run", so this is false for it.
@export var has_run_variants: bool = false

## The locomotion run clip keys this character can pick from when
## has_run_variants is true. Ignored otherwise.
@export var run_variant_keys: PackedStringArray = PackedStringArray(["run"])

## If true, this character has a jump clip ("jump" in clip_paths/clip_anim_names)
## and the rig plays it while the actor is airborne. Bodies without a jump clip
## leave this false and simply keep their locomotion pose mid-air (the old
## behavior), so this is purely additive per-model.
@export var has_jump: bool = false

## Optional per-clip leading trim (seconds), applied at harvest. Meshy clips often
## ship with dead time baked in (a windup crouch before a jump, seconds of sitting
## still before a stand-up). Trimming at harvest syncs the visible motion with the
## physics: e.g. {"jump": 0.5} starts the jump clip at the actual launch frame.
## Keys match clip_paths keys; missing keys mean no trim.
@export var clip_trims: Dictionary = {}

## Optional per-clip MAX LENGTH (seconds), applied after the leading trim. Meshy
## clips often carry seconds of dead tail (a 4s pitch with 2.4s of follow-through
## hold); cutting the length keeps one-shot states snappy. Keys match clip_paths.
@export var clip_cuts: Dictionary = {}

## Fine-tune where this model sits on a bench (world units). Different sit clips
## drop the hips by different amounts, so seat height isn't one-size-fits-all.
## sit_raise lifts the body onto the seat; sit_forward nudges toward the seat front.
@export var sit_raise: float = 0.9
@export var sit_forward: float = 1.0


## Returns true only if the def has the minimum data the rig needs to build:
## an id, a base model, and at least the core clip set. Used by the registry to
## skip malformed/placeholder files instead of crashing the rig.
func is_valid() -> bool:
	if String(id) == "":
		return false
	if base_model_path == "":
		return false
	for key in ["alert", "walk", "run", "dead", "arise"]:
		if not clip_paths.has(key):
			return false
		if not clip_anim_names.has(key):
			return false
	return true
