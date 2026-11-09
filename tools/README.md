# Tools

## `rbxl/`: binary Roblox place parser (Python 3, needs `pip install lz4 zstandard`)
- `parse.py <place.rbxl> <outdir>`: writes `outdir/tree.txt` (every instance path and class) and
  `outdir/src/**` (the Source of every Script/LocalScript/ModuleScript).
- `props.py <place.rbxl> '<path regex>'`: dumps decoded properties (UDim2, Color3, Font, NumberSequence,
  NumberRange, Vector3, enums as numbers, …) of matching instances, e.g. the HUD layout.
- `anims.py <place.rbxl> '<path regex>'`: lists Animation/Sound IDs and Attributes of matching instances.

Run with `python3 -I` and keep downloaded place files in their own folder.

## `mocktest/`: headless mechanics test
`./tools/mocktest/run.sh` concatenates `mock.lua` (minimal Roblox API mock: flat floor at Y=0,
LinearVelocity integration, gravity, Humanoid jump, raycasts, in-memory executor file system) +
`EvadeClone.lua` + `driver2.lua` (scenarios) and runs it with the `luau` CLI. Expected output:

- A) sprint 33.33 st/s, FOV 77
- B) ground-jump speed 44.31 (×1.45 boost to 48.33 minus one friction frame)
- C) airtime 0.67 s
- D) aligned bhop chain (shows the per-hop friction loss)
- E) positive air-strafe gain while fully airborne
- F) grounded strafe roll about −1.15°
- G) roll decays in the air
- H) slide 33.3 → 25.9 → 20.2 → 10.0 (crouch walk)
- I) stop at 0, FOV 70
- J/K) tracks played, 0 coroutine errors

The mock is not Roblox: use it to catch script errors and formula regressions, then confirm in game.
