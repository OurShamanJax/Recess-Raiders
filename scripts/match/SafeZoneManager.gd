class_name SafeZoneManager
extends Node3D
## Owns the team safe circles and enforces the rules:
##  - only the OWNING team may use a circle (enemies are never "safe" there)
##  - each circle holds at most CAP players at once
##  - on entry a DWELL timer starts; if you're still inside at 0 you're knocked
##    out and LOCKED OUT for a cooldown; leaving before 0 = no penalty
##  - re-entering (when allowed) RESETS your dwell timer
##
## Actors ask this manager "am I safe right now?" each tick; the manager tracks
## per-actor dwell time, lockouts, and per-zone occupancy.

const CAP := 7                 # max occupants per circle
const DWELL := 45.0            # seconds you may stay before being knocked out
const LOCKOUT := 15.0          # seconds you can't re-enter after a knockout

# zone = { "team": String, "pos": Vector3, "radius": float }
var _zones: Array = []
# per-actor state keyed by actor instance id:
#   { dwell: float, zone: int, locked: float }
var _state := {}

func _ready() -> void:
	_build_zones()

func _build_zones() -> void:
	_zones.clear()
	for team in ["blue", "red"]:
		for p in Config.pod_positions(team):
			_zones.append({"team": team, "pos": p, "radius": Config.SAFE_POD_RADIUS})

## Which zone (index) is this position inside, for this team? -1 if none/!owned.
func _zone_at(team: String, pos: Vector3) -> int:
	for i in range(_zones.size()):
		var z: Dictionary = _zones[i]
		if z.team != team:
			continue
		var d := Vector2(pos.x - z.pos.x, pos.z - z.pos.z).length()
		if d <= z.radius:
			return i
	return -1

func _count_in_zone(zone_idx: int) -> int:
	var c := 0
	for k in _state.keys():
		if _state[k].zone == zone_idx:
			c += 1
	return c

## Called by the manager each physics tick for every actor.
func _physics_process(delta: float) -> void:
	if GameState.phase != GameState.Phase.PLAYING:
		return
	for a in get_tree().get_nodes_in_group("actors"):
		_update_actor(a, delta)
		_enforce_enemy_barrier(a)

## No one may enter the OPPOSING team's safe circle — not enemy NPCs, not the
## player. If an actor is inside a circle that isn't theirs, shove them back to
## its edge so the zone acts as a solid no-go area for the other side.
func _enforce_enemy_barrier(a: Node) -> void:
	if a.is_tagged():
		return
	for z in _zones:
		if z.team == a.team:
			continue                       # your own zone is fine
		var zpos: Vector3 = z.pos
		var zrad: float = z.radius
		var flat := Vector2(a.global_position.x - zpos.x, a.global_position.z - zpos.z)
		var d := flat.length()
		if d < zrad and d > 0.001:
			# push them out to just past the edge
			var push: Vector2 = flat.normalized() * (zrad + 0.5)
			a.global_position.x = zpos.x + push.x
			a.global_position.z = zpos.z + push.y

func _update_actor(a: Node, delta: float) -> void:
	var key: int = a.get_instance_id()
	if not _state.has(key):
		_state[key] = {"dwell": 0.0, "zone": -1, "locked": 0.0}
	var st: Dictionary = _state[key]

	# tick lockout
	if st.locked > 0.0:
		st.locked = maxf(0.0, st.locked - delta)

	# carriers can't use safe zones AT ALL — holding stolen loot, you're fair
	# game everywhere. If a carrier is physically inside one of our circles, push
	# them back out so they can't camp the pod with an enemy point.
	if a.is_tagged() or a.has_target():
		var in_zone: int = _zone_at(a.team, a.global_position)
		_exit_zone(st)
		a.set_safe(false)
		if in_zone != -1 and a.has_target() and not a.is_tagged():
			a.eject_from_safe(_zones[in_zone].pos)
		return

	var here: int = _zone_at(a.team, a.global_position)

	if here == -1:
		# not in any of our circles
		_exit_zone(st)
		a.set_safe(false)
		return

	# in one of our circles — but are we allowed in?
	if st.zone == here:
		# already counted in this zone: tick the dwell timer
		st.dwell += delta
		if st.dwell >= DWELL:
			# overstayed -> knock out + lock out
			_exit_zone(st)
			st.locked = LOCKOUT
			a.set_safe(false)
			a.eject_from_safe(_zones[here].pos)
		else:
			a.set_safe(true)
			a.set_safe_seconds_left(DWELL - st.dwell)   # live HUD countdown
		return

	# trying to ENTER this zone (st.zone != here)
	if st.locked > 0.0:
		a.set_safe(false)            # locked out, no entry benefit
		return
	if _count_in_zone(here) >= CAP:
		a.set_safe(false)            # zone full
		return
	# admit: occupy the slot, reset dwell (re-entry resets timer)
	st.zone = here
	st.dwell = 0.0
	a.set_safe(true)

func _exit_zone(st: Dictionary) -> void:
	st.zone = -1
	st.dwell = 0.0
