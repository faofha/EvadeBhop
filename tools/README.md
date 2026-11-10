# Tools

## `rbxl/`: binary Roblox place parser (Python 3, needs `pip install lz4 zstandard`)
- `parse.py <place.rbxl> <outdir>`: writes `outdir/tree.txt` (every instance path and class) and
  `outdir/src/**` (the Source of every Script/LocalScript/ModuleScript).
- `props.py <place.rbxl> '<path regex>'`: dumps decoded properties (UDim2, Color3, Font, NumberSequence,
  NumberRange, Vector3, enums as numbers, …) of matching instances, e.g. the HUD layout.
- `anims.py <place.rbxl> '<path regex>'`: lists Animation/Sound IDs and Attributes of matching instances.

Run with `python3 -I` and keep downloaded place files in their own folder.

### Without Python (Windows: Git for Windows + the executor)
- `unpack_rbxl.pl <place.rbxl> <workdir> <out.rbxl>`: writes a copy of the place with every chunk
  uncompressed. Run it with Git's Perl (`"C:\Program Files\Git\usr\bin\perl.exe"`). Perl walks the chunk
  structure, and Windows `tar` (libarchive with libzstd) decompresses all the zstd chunks in one pass.
  Each chunk is wrapped as a tar entry inside a zstd stream built from hand-made raw frames.
- `rbxl_reader.luau`: run it in the executor on the uncompressed copy (saved as
  `EvadeCloneDev/evade_raw.rbxl` in the workspace). It installs `getgenv().RBXL` with:
  `find(pattern)` (instance paths), `props(path, withDescendants)`, `source(path)` (script source), and
  `export(path)` (Luau constructor rows with non-default properties only). The `EVADE_HUD` table in
  `EvadeClone.lua` was generated with `export("ReplicatedStorage/Assets/UI/Game/HUD/Overlay/CharacterStatus")`.
- `gen_ui_data.pl <dir>`: builds the `EVADE_UI` table in `EvadeClone.lua` (settings view, Slider,
  Boolean, TopButton, TopExit, and the Crouch/POV/Menu mobile buttons) from `export()` dumps saved in
  `<dir>` (`exp_view_settings.luau`, `exp_slider.luau`, `exp_boolean.luau`, `exp_topbutton.luau`,
  `exp_topexit.luau`, `exp_mobile.luau`).

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
