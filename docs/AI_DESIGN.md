# Recess Raiders — NPC AI Design (Remaster)

The goal: bots that *play the game we actually built* — raid, steal, defend, tag,
revive, intercept — reading as a team of individual kids, not a swarm sharing one
brain. This doc is the contract; AIController implements it.

## 1. Priority doctrine (what a kid cares about, in order)

Every ~1.5s each bot scores all options and takes the best. Scores are shaped so
that, all else equal, this is the natural priority ladder:

1. **SURVIVE** — if gassed, rest at a pod. If carrying and cornered, pass or dump.
2. **FINISH THE PLAY** — if carrying loot, get it home (or pass it forward).
3. **HELP A FALLEN FRIEND** — a downed teammate nearby is almost always worth a
   detour. Walking past a body is a design failure. (Revive trait floors at 0.7.)
4. **PUNISH INTRUDERS** — an enemy on our half (especially a carrier) gets chased
   by the closest 1-2 defenders, not the whole team (claims + local boost).
5. **CONTEST THE MIDDLE** — enemies in the neutral band are engaged if we're brave
   and close; the border is a battleground, not a force field.
6. **RAID** — push into enemy territory toward the stash, via a LANE (see §2).
7. **SUPPORT** — escort our carrier as a pass outlet.
8. **HOLD/IDLE** — hover near our goal line if nothing else scores.

Team-vs-individual balance: the PlayCaller publishes only a raid/defend *bias*;
each bot multiplies it into its own scores. Claims stop dogpiles (a claimed target
is worth ~half). Personality (brave/hustle/team_play + skill tier) spreads the
same doctrine across different kids.

## 2. Use the whole field — LANES

Problem: everyone pathing straight at the stash produces a single-file center
column and border pileups.

Fix: at setup each bot rolls a **preferred lane** — an X offset band:
`lane_x ∈ {-40, -20, 0, +20, +40}` (jittered ±8). All *travel* objectives
(RAID advance, returning home to defend, HOLD position) are biased toward the
bot's lane: target.x is pulled 60% toward lane_x while far from the objective,
releasing as they get close. Effects:
- raids arrive as a broad front (flanks!), not a conga line
- border crossings spread across multiple gaps
- defenders cover width naturally
Horizontal juking stays local (steering), lanes handle strategic width.

## 3. The border is not a wall

Past failure: mutual enemy-avoidance + "only chase on our half" made both teams
stall and slide past each other at the centerline.

Rules:
- CHASE considers enemies on our half **and** a 22u contested-middle bubble.
- Enemy-avoidance steering only applies when the *enemy could tag us* (their
  turf or we're carrying). Two raiders crossing in the middle ignore each other.
- RAID pathing uses lanes, so crossings don't funnel into one cone gap.

## 4. Jump-intercept (new)

When an enemy throw is IN_FLIGHT and its path crosses near a bot:
- if the ball will pass within ~6u horizontally and arrives within 0.9s,
  and its height at closest approach is between 2.5 and 6.5u → the bot moves to
  the crossing point and **jumps** just before arrival (reaction-skill gated:
  ruthless bots time it well, casual bots often don't try).
- an intercepted (touched) ball knocks to LOOSE at the touch point.
Player already can do this manually; bots doing it makes passing risky and lanes
matter.

## 5. What bots do NOT do

- No crouch: there's no crouch-walk clip, so moving-while-crouched looks static.
  AI never sets crouch. (Cosmetic player-only feature.)
- No omniscience: targeting stays perception-driven (vision cone + LOS + nearby).
- No full-team dogpiles: claims + crowding penalties as before.

## 6. Reaction model

Perception publishes visible/nearby sets; reaction latency scales with skill tier
(react trait): casual bots notice raids late, ruthless almost instantly. Belief
sharing ("heard about" intruders from teammates) stays — it reads as kids yelling.

## 7. Known past failure modes this design answers

| Failure | Answer |
|---|---|
| Border stalemate / mutual ignore | §3 contested middle + threat-only avoidance |
| Center conga line | §2 lanes |
| Downed teammates ignored | §1.3 revive floor + close-range kicker |
| Tag/revive jitter loop | Actor REVIVE_MIN_DOWNED (5s) |
| Whole team chases one raider | claims + local-closest boost (kept) |
| Bots frozen at unbaked navmesh | navmesh corner sanity guard (kept) |
