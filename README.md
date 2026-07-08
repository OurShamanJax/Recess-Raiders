# Recess Raiders — V1

**Recess Raiders** is a 3D schoolyard showdown: **10 vs 10** capture-the-loot chaos.
Two teams of kids face off across a field split by a wall of cones. Raid the enemy
half, snatch their cones and footballs, and haul the loot home before you get
tagged. **Steal their entire stash to win.**

*Inspired by 2 Berry — the gym game every kid in class begged to play.*

## Features

- **10v10 matches** — you plus 9 AI teammates against a full AI team. Every kid
  has its own vision cone and brain: they chase, raid, defend, grab, pass, and
  rescue on their own.
- **8 playable kids** across both teams, each a distinct character model, picked
  from a character-select screen with live 3D preview.
- **Fully animated play** — running with real momentum, jumps that dodge tags,
  a wind-up **pitching animation** when you throw, flopping when tagged, getting
  helped back up, and even sitting on the sideline benches.
- **Skill-based throwing** — a timing meter decides whether your throw flies true
  or fumbles loose. Lock onto a teammate to fire a guided pass.
- **Unlockable roster** — start with one kid per team; win matches to unlock more.
- **15-minute matches** with sudden-death overtime if the score is tied.
- **Smarter kids** — AI raids in lanes across the whole field width, contests the
  middle, revives fallen friends, and jumps to intercept your throws.
- **Smart tagging** — the game tags who you're *looking at*, not just whoever's
  closest. Jumping over a tagger dodges the tag. Freshly revived kids get a moment
  of protection. Tags land with a punchy hit-pause and impact burst; jumps kick up
  dust on landing.
- **Stamina strategy** — sprint hard, gas out, recover in safe-zone pods (which
  eject loot-carriers — no camping with the goods).
- **An animated splash intro** with a welcome voice-over, a living menu backdrop,
  and a coach who sprints the sideline, dances, stomps, backflips — and sneaks off for a bench break.
- **Runs on modest hardware** — a one-click **Performance preset** (Esc → Settings →
  Graphics) drops render scale, shadows, grass, and lighting effects for a big FPS
  boost; **Quality** restores full fidelity. Changes apply live, no restart.

## How to run it

1. Install **[Godot 4.6](https://godotengine.org/download)** (standard version).
   *(Godot 4.7 also runs the game but prints harmless deprecation warnings.)*
2. Open Godot → **Import** → select this folder's `project.godot`.
3. Let it import once, then press **F5**. Hit **Play**, pick a team and a kid, go.

## How to play

**The golden rules:**

1. **Your half is safe; their half is dangerous.** You can only be tagged while
   intruding on enemy ground — *or any time you're carrying their loot.*
2. **Grab loot** by getting close and looking at it.
3. **Carrying loot paints a target on your back** — taggable anywhere, no safe
   zones, until you bank it. The run home *is* the game.
4. **Bank it** by carrying it across the midline into your goal area.
5. **Get tagged and you drop everything** — you flop, and the loot snaps back to
   the enemy base.

**Tagging:** aim at an enemy and press **E** (or left-click). Your reticle decides —
in a crowd, you tag who you're *looking at*. Point-blank, proximity works without
aiming. You can only tag intruders on your half or loot-carriers.

**Reviving:** a tagged teammate is out until someone presses **R** next to them
(or 30 seconds pass). Reviving wins matches — be the hero.

## Controls

| Action | Key |
| --- | --- |
| Move | **WASD** |
| Look | **Mouse** |
| Sprint | **Shift** (drains stamina) |
| Jump | **Space** (dodges tags!) |
| Crouch | **C** |
| Tag / grab / sit on bench | **E** |
| Revive teammate | **R** |
| Throw / pass | **Left-click** (timing meter!) |
| Lock-on target | **Tab** |
| Switch camera | **V** |
| Pause / settings | **Esc** (Resume / Settings / Main Menu / Exit) |

**Tab** — toggle the live scoreboard (points, tags, saves, ranks).

## Tips

- Sprint in bursts — a gassed kid walks until stamina recovers *and* you re-press
  sprint.
- In a pile-up, aim at the *specific* kid you want to tag.
- A pass to a teammate near the midline beats running the whole way yourself.

## For developers

Technical reference lives in `docs/HANDOVER.md`, the roadmap in `docs/BACKLOG.md`,
and the character-model import pipeline in `docs/GLB_IMPORT_STRIP_GUIDE.md`.
Built with Godot 4.6 and GDScript.
