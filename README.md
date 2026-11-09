# EvadeClone

Single-file client script (`EvadeClone.lua`) that reproduces Evade's movement, camera, animation state
machine, speed/health HUD and remote integration in non-Evade games, using your own assets from the
executor workspace folder `EvadeClone/`.

- `EvadeClone.lua`: the script. Edit only `CONFIG`, `AnimationMap`, `UIMap`, `RemoteMap` and `SoundMap`.
- `docs/PHASE1_SPEC.md`: measured Evade specification (movement, camera, animation, remotes, UI).
- `docs/SETUP_AND_VALIDATION.md`: asset checklist, Evade animation IDs, REAL/CLONE validation, tuning.
- `tools/`: `.rbxl` parser and headless Luau mock test (`tools/README.md`).
