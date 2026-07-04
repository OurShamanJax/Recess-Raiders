# Recess Raiders — Backlog

A single, current list of what's left. Ordered roughly by impact / how much the
game needs it. Updated as of the current session.

## Recently finished (so we don't re-do them)
- Splash → menu handoff (adopted title, no flash, no dim, tightened letter timing).
- New model **Asian Girl Blue** imported and animating (walk/run/sprint/jump/dead/arise).
- Animated **bench sitting** for models that ship sit clips (girl + Red Hoodie Boy).
- **Jump desync** fixed via per-clip leading trims.
- **Sprint rubberbanding** fixed (momentum tracks its own velocity, not the physics one).
- **Pickup priority** now aim-weighted (reticle decides among clustered items).
- **Variable kid heights**; coach stays a constant adult height.
- Character-select DONE: title hides there, team buttons full opacity, uniform cards,
  per-model two-bone headshot framing (posed, zoomed, no clipping).
- Sprint slingshot fixed (fall-through net now restores to last safe ground, not
  spawn, and warns with coordinates when it fires — watch console for terrain holes).
- Welcome voice line now starts with the splash; menu music follows it.
- HUD no longer leaks "Pass!"/score onto the menu or during pause.

## High impact — core game feel / loop
1. **Throwing animation — DONE for the 3 pack models** (girl, hoodie boy, indian boy):
   pitch anim with kinematically-timed release (0.38s), ball rides the RightHand bone
   while carried. Remaining: playtest the windup feel, and the other 5 models have no
   pitching clip yet (they release instantly).
2. **Player controller feel, continued.** Momentum is in; keep tuning accel/decel,
   turn speed, sprint ramp until movement feels immersive and fun rather than just
   functional. This is the "keeps players coming back" work.
3. **Revived-NPC slide bug.** Revived NPCs slide while the stationary arise clip
   plays. A prior fix (arise state + movement lock) BROKE THE GAME and was reverted —
   capture the exact failure before retrying. Safer idea: short lock or a root-motion
   nudge, not an immediate state change.

## Medium — content & polish already half-built
4. **Import remaining anim-update packs.** Blue Indian Boy pack and the rest of the
   Red Hoodie Boy pack (Run_02, crouch, alert, sit-idle variations) still need
   importing with the skin-keeping strip.
5. **Crouch state.** All packs have `CrouchLookAroundBow`. Needs a new rig crouch
   state + Actor wiring (crouch key already exists in controls).
6. **Sit-idle variations for NPCs.** Red pack has Sit_Finger_Wag_No,
   Sit_Shout_Hands_on_Mouth, Sit_Thumbs_Up_Right — flavor for benched NPCs.
7. **Sit offset fine-tuning.** "Fine for now" per playtest — revisit only if it
   bugs anyone. Values live in each def (.tres) as `sit_raise`/`sit_forward`.
8. **Coach remaster.** Model + animations + AI; the user wants "more fun stuff with
   him." Biggest single content item — its own session.
9. **After-stand-on-seat.** After standing from a bench a kid can end up on top of the
   seat slab (walkable). Minor; tune the release point.

## Lower / bigger swings (user must weigh in or it's a whole project)
10. **Drivable cars** — enter/exit, drive with spinning wheels, respawn beside car.
    Whole new control mode; its own project.
11. **Rebindable keybinds** — settings page with conflict detection. Own UI pass.
12. **FatBoy directional/strafe** — 2D blendspace so he strafes instead of only F/B.
13. **School doors + navmesh** — hinged doors (currently gaps); navmesh only if
    school-interior NPCs are added.
14. **Material direction** — low-poly vs a PBR/realism pass. A big art call for the user.
15. **Editor-only niceties** (can't do headless from here): DoF, HDR sky, LightmapGI.

## Needs playtest confirmation (claimed fixed, unverified)
- Terrain collision smooth on up/down height changes (claimed fixed several times — stay humble).
- Trees not floating/buried; school + sidewalk + lot + road align spatially.
- Welcome audio plays in full; pause keeps music; settings button works.

## Standing note
Everything tuning-related (terrain heights, juke/fumble strength, cloud speed, coach
scale, FOV, volumes, sit offsets) is first-draft — iterate from feedback, don't expect
to nail it blind.
