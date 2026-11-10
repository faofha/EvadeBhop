# EvadeClone — Asset Checklist, Evade Animation IDs, Validation & Tuning

Script: `EvadeClone.lua` (single file). Spec: `docs/PHASE1_SPEC.md`.

---

## 1. Asset checklist

**Animations need no manual setup.** The 19 R6 clips live in this repo's `Animations/` folder. On
startup the script downloads any missing ones (`game:HttpGet` from `CONFIG.AssetDownload.BaseUrl`) into
`EvadeClone/Animations/` and loads them with `getcustomasset` → `GetObjects`. If you move the files to
another branch or repo, change `BaseUrl`. Set `Redownload = true` to refresh local copies.

`RegisterKeyframeSequence` only works in Studio, so in live games the script plays each
KeyframeSequence with its own keyframe player, which writes `Motor6D.Transform` every `Stepped`.
Because of this, the animations run without any uploaded AnimationId. The clips were made for Evade's
Classic rig, which has `HumanoidRootPart > TorsoRot > { Torso > Head, legs, ArmRot > arms }` with
torso-aligned joint frames. The player rebuilds that rig in torso space and solves the stock R6
Motor6Ds from it. The `ArmRot` pivot (shoulder line) is estimated.

Other players can't see these animations. `Motor6D.Transform` doesn't replicate, and an AnimationTrack
replicates only as an AnimationId that every other client loads itself. `rbxasset://` (getcustomasset)
and `active://` (KeyframeSequenceProvider) IDs exist only on your machine, and Evade's uploaded IDs
only load in Evade's own games. Infinite Yield's `dance`/`emote` commands are visible to others
because they use Roblox-owned animation and catalog emote IDs.

Everything else optional goes inside your executor's **workspace** folder:

```
EvadeClone/
├── Animations/                      (filled automatically; see AnimationMap in the script)
├── UI/
│   └── HUD.rbxm  or  HUD.rbxmx     (optional — native Evade layout is built if absent)
├── Sounds/                          (optional — Evade sound IDs are used if absent)
│   ├── Whoosh.ogg  Slide.ogg  DoubleJump.ogg
│   └── Footsteps/<Land|Sprinting|Walking|Wander>/<Material>/*.ogg  and  Footsteps/Cloth/*.ogg
└── Logs/                            (created automatically)
```

Each animation `.rbxm` must contain a **KeyframeSequence** (an animation exported from the Animation
Editor: right-click the KeyframeSequence → *Save to File*). Its `Priority` and `Loop` are applied to the track.
Recommended: `Loop = true` for Idle / WalkRun / Jump / Slide / Crouch, `Loop = false` for Land.

**Fall.rbxm, AirStrafeLeft.rbxm and AirStrafeRight.rbxm are not used.** Evade has no fall or air-strafe
animations. Its single `Jumping/Jump` track runs from takeoff to landing, and air strafing only changes
velocity and the camera. Mapping them would break the "exactly like Evade" requirement.

### AnimationMap: Evade slots and your files
| Evade slot | Default file | Driven by (Evade formula) |
|---|---|---|
| `Idle/Idle` | Idle.rbxm | state Idle, fade 0.5/0.5 |
| `Moving/MoveForward/Backward/Left/Right` | WalkRun.rbxm | speed `s/10.5` (`s/15` ≥ 25), weight dir² × (1 − clamp((s−25)/5)) |
| `Moving/SprintForward/ForwardLeft/ForwardRight` | WalkRun.rbxm | weight dir × clamp((s−25)/5), 0 below 25 |
| `Crouching/Idle` + `Crouching/Move*` | Crouch.rbxm | crouch states, Idle weight 0 at s ≥ 0.5 |
| `Jumping/Jump` | Jump.rbxm | state Air, fade in 0.5 / out 0.1 (R15) |
| `Sliding/Slide` | Slide.rbxm | Slide / SlideAir, fade 0.4/0.4 |
| `WallrunningLeft/Right/SprintForward` | WalkRun.rbxm | wallrun states |
| `Transitions/Jumping/End` | Land.rbxm | Jumping → Idle/Moving/Crouching, 0.05 in / 0.4 out (R15) |
| `Transitions/Moving/End` | `false` (not supplied) | Evade's stop-settle one-shot. Add a file to enable it |

If you supply separate directional clips (e.g. `WalkLeft.rbxm`), change only that row of `AnimationMap`.

### Fallback chain if animations can't load
1. `getcustomasset` → `game:GetObjects` (or `InsertService:LoadLocalAsset`) → KeyframeSequence →
   `KeyframeSequenceProvider:RegisterKeyframeSequence`
2. an `Animation` instance inside the .rbxm (its `AnimationId`)
3. `CONFIG.Animation.IdOverrides["<slot>"] = "rbxassetid://<your uploaded id>"`. This is the guaranteed path
   on executors without `getcustomasset`/`GetObjects`. Upload your animations to **your own** account or group.
   They only play in experiences that owner owns, or where the owner has granted access.
4. Otherwise the slot is disabled with one warning, and movement, camera and UI keep running.

### UIMap (only needed for a custom HUD.rbxm)
| Role | Default path inside the ScreenGui |
|---|---|
| `Root` | `HUD/Overlay/CharacterStatus` (hidden on death) |
| `Speed` (TextLabel) | `HUD/Overlay/CharacterStatus/BottomLeft/Speedometer/Speed` |
| `SpeedFront` (Frame) | `HUD/Overlay/CharacterStatus/BottomLeft/Speedometer/Front` |
| `Health` (TextLabel) | `HUD/Overlay/CharacterStatus/BottomLeft/Health/Health` |
| `HealthIcon` (ImageLabel) | `HUD/Overlay/CharacterStatus/BottomLeft/Health/HealthIcon` |
| `HealthStroke` (UIStroke) | `HUD/Overlay/CharacterStatus/BottomLeft/Health/BackgroundStroke/UIStroke` |
| `HealthFill` (Frame) | `false`. Evade has no fill bar. Set a path to drive `Size.X = HP/MaxHP` |

If `Speed` or `Health` can't be resolved, the script logs it and builds Evade's native layout.

### RemoteMap
In non-Evade games every Evade remote reports `MISSING -> no-op stub` at startup. This is expected, and
nothing depends on them. To hook the host game's own remotes, set these roles:

| Role | Effect |
|---|---|
| `HealthUpdate` | first numeric argument overrides the displayed health |
| `VelocityCorrection` | first `Vector3` argument (studs/s) replaces horizontal velocity |
| `Respawn` | re-initialises the character modules |
| `RegistryOut` / `RegistryOutUnreliable` | targets for the 10 Hz term mirror (`State`, `Speed`, `RelativeMoveDirection` / `LookY`, `Gyro`) when `CONFIG.Remotes.OutgoingMode = "Fire"`. The default `"Count"` sends nothing |

### Controls (Evade defaults)
Jump `Space` / `ButtonA` (gamepad A held = auto-hop, as in Evade) · Crouch/slide hold `C` / `LeftControl` / `ButtonR2`
· Third person `O` / `ButtonR3`, or the mouse wheel: it has two fixed positions, as in Evade. Scrolling
out goes to third person at 6 studs and stays there; scrolling in returns to first person. The mouse turns
the third-person camera directly, shift-lock style, with no right-click needed
· Settings (FOV slider 70–100, saved to `EvadeClone/settings.json`) `P` · Validation `F8` · Unload `End`.

### Gravity
Evade runs at `workspace.Gravity = 50`. Most games use 196.2, which shortened airtime to about 0.44 s.
`CONFIG.Movement.Gravity = 50` adds a VectorForce to your character only, so it falls as it does in
Evade (airtime about 0.7 s), and the jump uses `JumpPower = sqrt(2·g·JumpHeight)`. Set it to `nil` to use
the game's gravity.

### In-game physics test
`tools/ingame/physics_test.luau`: copy it to your executor workspace and run
`loadstring(readfile("EvadeClone/physics_test.luau"))()` while EvadeClone is running. It builds a
client-only test floor and wall, drives the inputs, and returns sprint, jump, airtime, bhop, air-strafe,
slide, crouch and wallrun numbers.

---

## 2. Evade animation IDs (reference)

Extracted from `ReplicatedStorage/Objects/Game/Character/Animations/Types/<R15|Classic>/Default`.
Roblox only lets an animation play in experiences owned by its uploader, so **these will not play in
other games**. Use them as reference for timing and pose, then upload your own versions.

| Slot | R15 | Classic (R6) |
|---|---|---|
| Idle/Idle | 129795924166036 | 11544336826 |
| Moving/MoveForward | 12447623469 | 17418691532 |
| Moving/MoveBackward | 12448032204 | 17418712872 |
| Moving/MoveLeft | 12448098021 | 17418770762 |
| Moving/MoveRight | 12448138419 | 17418788540 |
| Moving/SprintForward | 15106195597 | 17418483149 |
| Moving/SprintForwardLeft | 15106196403 | 17418484618 |
| Moving/SprintForwardRight | 15106197139 | 17418485963 |
| Crouching/Idle | 95125111935172 | 17418836643 |
| Crouching/MoveForward | 12309801846 | 17418862116 |
| Crouching/MoveBackward | 12309803554 | 17418871218 |
| Crouching/MoveLeft | 12309943175 | 17418881872 |
| Crouching/MoveRight | 12309987585 | 17418893680 |
| Jumping/Jump | 15248598868 | 17524391617 |
| Sliding/Slide | 12311697817 | 17418821942 |
| WallrunningLeft/SprintForward | 128947555199648 | 18688623622 |
| WallrunningRight/SprintForward | 138041445823479 | 18688628477 |
| Transitions/Jumping/End (land) | 15091442697 (in 0.05, speed 1.0, out 0.4) | 18582452487 (in 0.1, speed 0.8, out 0.5) |
| Transitions/Moving/End (stop) | 79119378308668 (0.3 / 1.0 / 0.5) | 18582642963 (0.2 / 1.0 / 0.5) |
| Transitions/Sliding/End | 12311699754 (never triggered in Evade) | — |

Other Evade animations, for completeness (not used by the clone):

| Slot | R15 | Classic (R6) |
|---|---|---|
| Moving_RootStraight/MoveLeft | 15718324695 | = Moving |
| Moving_RootStraight/MoveRight | 15718322492 | = Moving |
| Moving_RootStraight/SprintForward / ForwardLeft / ForwardRight | 15718327985 / 15718328864 / 15718329940 | = Moving |
| Crouching_RootStraight/MoveLeft / MoveRight | 15718330679 / 15718331314 | = Crouching |
| Downed/Crawl | 116759198024827 | 93621535654157 |
| Downed/Idle | 96402836801090 | 82896831826787 |
| Climbing/Climbing | 105240946699958 | 17524089804 |
| Swimming/Swimming | 913384386 | 17524264113 |
| Swimming/Idle | 913389285 | 17524219278 |
| Spin/TurnLeft, TurnRight | 12448249855, 12448354484 | — |
| Overlay/LookBack | — | 77301532184803 |

Sound IDs used as defaults: whoosh 12547448228, slide loop 13743906533, double jump 6870001835, and
footsteps from Evade's `FootstepTypes` table (embedded in the script). Audio may also be restricted to its
owner's experiences. If a sound is silent, drop your own file into `Sounds/`.

---

## 3. Validation & calibration guide (REAL vs CLONE)

Both modes use the same logger: `F8` starts recording, and it stops after `CONFIG.Validation.Duration`
(12 s) or on a second `F8`. It samples every 0.05 s: horizontal and vertical speed, grounded, jump count,
active animation slots, rendered speed text, health fill/text, camera FOV and roll, and remote fire counts.

**Step 1: record the baseline inside Evade (REAL mode).**
1. Set `CONFIG.Mode = "REAL"` and execute in Evade. The engine stays idle and nothing on your character changes.
2. Press `F8` and perform a fixed routine, for example: sprint 2 s → 5 hops facing forward → 3 hops strafing
   with A/D → crouch-slide → stop.
3. The logger writes `EvadeClone/Logs/real.csv`, plus `EvadeClone/Logs/evade_tracks.csv` (Evade's real
   track lengths, priorities and looping, which the clone uses for length rescaling).

**Step 2: record the clone (CLONE mode)** in your target game, or on a flat baseplate for the cleanest
comparison. Set `CONFIG.Mode = "CLONE"`, press `F8`, and repeat **the same routine with the same jump
count**. On stop it writes `Logs/clone.csv`. If `Logs/real.csv` exists, it prints the comparison to the
console (F9) and to `Logs/report.txt`.

**Alignment:** runs are segmented by jump index (each Humanoid `Jumping` event starts a segment). Jump *k* of
REAL is compared with jump *k* of CLONE, across `min(realJumps, cloneJumps)` jumps.

| Metric | Definition |
|---|---|
| PeakSpeed / MeanSpeed | max / mean horizontal speed within the jump segment |
| LandingRetention | speed at next takeoff ÷ speed at landing (ground friction frames) |
| AirStrafeGain | (landing speed − takeoff speed) ÷ airtime |
| Airtime | takeoff → first grounded sample |
| SlotLatency | takeoff → first sample where `Jumping/Jump` is active |
| SpeedTextError | mean \|HUD number − measured speed\| |
| FOVError | mean \|FOV − 70·lerp(1, 1.1, clamp((s−25)/8))\| |

A metric is flagged `DIVERGES` when `|clone − real| / |real| > 5% + (std_real / |real|)`. The tolerance is
widened by REAL's own jump-to-jump variance so input noise isn't flagged. Each flag names the parameter to
adjust (see section 4).

---

## 4. Tuning note: deviations above 5%

Change **one parameter per run** and re-record CLONE with the same routine.

| Diverging metric | Check first | Then |
|---|---|---|
| Airtime | `workspace.Gravity` in Evade vs the host game. The clone uses the host's gravity, like Evade uses its own | `CONFIG.Movement.JumpHeight` (the airtime ratio scales with √(JumpHeight/g)) |
| LandingRetention | Grounded tolerance: the clone emulates Evade's (2,4,2) hull (centre 2 studs up, 2.9-stud ray). The character counts as grounded for ~0.9 studs above the floor, so friction (8.3 %/frame at 60 fps) also applies for the first ~3–4 frames after takeoff and ~3–4 frames before landing. This is in Evade's code and is the largest per-hop loss | `GroundedDistCheck`, then `Friction` / `RunDeaccel`. Compare at the same FPS |
| PeakSpeed | Is the camera facing the velocity on takeoff? The ×1.45 jump boost is scaled by (look · velocity)², capped at Sprint·Speed·1.45 = 48.3 st/s | `JumpSpeedMultiplier`, `SprintCap` |
| AirStrafeGain | **Frame rate.** Evade's air acceleration is Quake-style: gain per frame is capped at 182 u, so gain per second scales with FPS. Record both runs at the same FPS cap | `AirStrafeAcceleration`, `AirAcceleration` |
| MeanSpeed | sprint ramp (`SprintAcceleration`, 2 s to full), `Speed` | — |
| SlotLatency | the clip's first-frame pose and the 0.5 s Jump fade-in | `Animation.RescaleToEvadeLength`; re-record `evade_tracks.csv` |
| SpeedTextError | `UIMap.Speed` pointing at the right label; text is floored to 0.1 | — |
| FOVError | `CONFIG.Camera.BaseFOV` must equal your Evade FOV setting (default 70) | `SprintFOVMax` / `SprintFOVRate` |

Known, intentional differences from a live Evade session (not tunable without changing the host game):
- Stock R6/R15 collision can't shrink, so crouch and slide lower the camera by 0.725 studs (Evade's hull
  drop) but don't let you fit under lower gaps.
- Evade's ladders, water, carrying, emotes, downed state and door breaking depend on Evade's own map and
  server, and are not reproduced.
- `CamPart` (Evade's animated camera motor) only applies if your rig has `HumanoidRootPart.CamPart`.
