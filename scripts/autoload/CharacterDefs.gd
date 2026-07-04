extends Node
## Registry that loads every CharacterDef (.tres) from the defs folder once at
## startup and serves them by id / by team. This is the "add a character = drop
## a file" mechanism: nothing here is hardcoded per-character.
##
## ROLLOUT STATUS (1.1, first pass): ADDITIVE / PROOF-OF-ONE.
## Currently only blue_boy.tres exists, so this registry holds exactly one def.
## CharacterRig falls back to its hardcoded constants whenever a def is absent,
## so an empty or partial registry can NEVER break the known-good path — it just
## means nobody goes through the data-driven route yet.
##
## Registered as an autoload (see project.godot) named "CharacterDefs".

const DEFS_DIR := "res://assets/character/defs"

# id (String) -> CharacterDef
var _by_id: Dictionary = {}

func _ready() -> void:
	_load_all()

## Scan the defs folder for *.tres, load each, validate, and index by id.
## Invalid or unreadable files are skipped with a warning rather than fatal —
## the rig fallback keeps the game playable either way.
func _load_all() -> void:
	_by_id.clear()
	var dir := DirAccess.open(DEFS_DIR)
	if dir == null:
		# folder missing is fine in the additive phase — just means no defs yet
		push_warning("CharacterDefs: defs folder not found at %s (using rig fallback)" % DEFS_DIR)
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and _is_def_file(fname):
			var path := "%s/%s" % [DEFS_DIR, fname]
			var res: Resource = load(path)
			if res is CharacterDef:
				var def: CharacterDef = res
				if def.is_valid():
					_by_id[String(def.id)] = def
				else:
					push_warning("CharacterDefs: %s is not a valid CharacterDef (skipped)" % path)
			else:
				push_warning("CharacterDefs: %s did not load as a CharacterDef (skipped)" % path)
		fname = dir.get_next()
	dir.list_dir_end()

# Godot exports .tres as .tres.remap / .res in some pipelines; accept the common
# editor and exported forms so the registry works in both.
func _is_def_file(fname: String) -> bool:
	return fname.ends_with(".tres") or fname.ends_with(".tres.remap") or fname.ends_with(".res")

## Look up a def by its id. Returns null if none registered (caller should fall
## back to the rig's hardcoded path).
func get_def(id: String) -> CharacterDef:
	return _by_id.get(id, null)

## True if a def with this id is registered.
func has_def(id: String) -> bool:
	return _by_id.has(id)

## All defs for a team, e.g. for the menu's model list. Empty array if none.
func defs_for_team(team: String) -> Array:
	var out: Array = []
	for def in _by_id.values():
		if def.team == team:
			out.append(def)
	return out

## Every registered def (any team).
func all_defs() -> Array:
	return _by_id.values()

## Count of loaded defs — handy for a sanity check / the verification battery.
func count() -> int:
	return _by_id.size()
