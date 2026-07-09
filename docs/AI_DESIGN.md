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

## Fairness (team asymmetry)

The human replaces a bot, so the player's team is structurally 9 bots + 1 human
vs 10. Two rules keep that fair: allies have a 'skilled' trait floor in real
matches (Config.ai_val_for), and all prediction math is scaled by the anticip
trait so difficulty tiers gate the geometry, not just the reflexes.

## The math (implemented equations)

1. PURSUIT INTERCEPTION (_intercept_point): target P, velocity v; pursuer O,
   speed s. Meet time t solves |P + vt - O| = st:
     (v.v - s^2)t^2 + 2(d.v)t + d.d = 0,  d = P - O
   Faster pursuer => one positive root; run to P + vt (t capped 1.6s since
   kids change direction). Numerically verified: |intercept - O| = s*t.
   Equal-speed dead-flee has no root => t=0, degrades to plain chase.

2. POTENTIAL-FIELD CARRIER ROUTING (_evasive_home_point):
     steer = normalize( home_dir + SUM_i (away_i/|away_i|) * k/|away_i|^2 ), k=140
   Inverse-square repulsion from enemies within 20u; waypoint 18u along steer.
   At d=10u an enemy pushes ~1.4x the goal pull (real swerve); at 20u ~0.35x
   (gentle drift). Composes with the sine-weave that dodges the chaser behind.

3. WEAK-SIDE LANE SELECTION (_weak_side_lane): per candidate lane x_L,
     cost(x_L) = 0.012|x_L - x_base| + SUM_ahead 1/(1 + 0.1|x_e - x_L|)
   Only enemies ahead of the crossing count; stickiness term prevents
   zig-zag; final lane = lerp(base, argmin, 0.65). Raids flow to the side
   the defense left open.

## Risk model (the balancing framework)

Every job score has the same shape: **value x urgency / risk**. When behavior
feels dumb, identify which term is missing or mis-weighted - do not nudge
random constants. Current terms:

- RESCUE: value = teammate back (115 base, revive trait, close-kick),
  urgency = team crisis (down ratio), risk = _danger_at(body) enemy pressure (30u, includes belief threats) - each
  enemy close to the downed kid discounts the score, scaled by the rescuer's
  bravery. A guarded body is a trap, not a job; kids should not feed. Crisis
  urgency competes with danger, so in a true emergency a brave kid will still
  risk a guarded grab - the schoolyard-heroics moment we want.
- CHASE/ENGAGE: value = stopping a threat, urgency = carrier/intrusion,
  risk = implicit (their-turf rules).
- RAID: value = points, urgency = play-caller bias, risk = opening-phase
  suppression for holders.

Tuning rule: bots cowardly -> raise value/urgency; suicidal -> raise risk;
uniform -> widen the personality spread on the relevant trait.

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
