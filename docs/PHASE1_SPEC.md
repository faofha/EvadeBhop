# EvadeClone — Phase 1 Architectural & System Specification

Source of truth: `place_9872472334_HLWN_Evade1.rbxl` (a decompiled client dump made with UniversalSynSaveInstance + the Sabre decompiler).
I parsed the binary place format directly and read the client modules that ship with it. Server scripts are **not** in the dump
(they say "Server Scripts are IMPOSSIBLE to save").

Legend: **MEASURED** = read directly from decompiled source or serialized instance properties in the place file.
**ESTIMATED** = inferred; each one has a verification method.

Units: Evade stores horizontal velocity in **internal units (u) = studs/s × 90**. `LinearVelocity.PlaneVelocity = V/90`.
The HUD speed reading is `floor(|V|/90 × 10)/10`, so it shows **studs/s**. In the formulas below, `s` means the HUD speed in studs/s.

---

## 0. Architecture & update order (MEASURED)

Evade runs **one `RenderStepped` tick** per character (`Services/Asset/CharacterService` → `Character:Update(dt)`). Nothing
movement-related runs on Heartbeat. The only Heartbeat use is `JumpReact`, which waits on Heartbeat for the jump key to be released.

| # | Step (inside `Character:Update(dt)`) | Source module |
|---|---|---|
| 1 | `UpdateDistance` (every 0.2 s: distance to camera, on-screen test) | `Objects/Game/Character` |
| 2 | `Registry.Health = Humanoid.Health` | `Character` |
| 3 | Local only: `LookCFrame = CameraService:GetLookCFrame()`, `ActualVelocity = HRP.AssemblyLinearVelocity`, `Speedlines.Set(Speed)` | `Character` |
| 4 | `Movement:UpdateTerms` → Grounded, MoveDirection, GlobalMoveDirection, Gyro, LookY, Crouching, WallrunDirection, Swimming | `Client/Movement/Terms` |
| 5 | `State:Update` → `FindBestState()` (priority scan) and RootPart resize lerp | `Character/State` + `Shared/StateInfo` |
| 6 | `Tasks:Update` | `Objects/Game/Tasks` |
| 7 | `Movement:Update` → SetState (constraints, speed mults), `MoveFunction[MoveType]`, writes `Velocity`, `Speed`, `RelativeSpeed`, `RelativeMoveDirection`, `RootPartOrienter` | `Client/Movement/*` |
| 8 | `Camera:Update` (camera type/zoom, 3rd-person root offset) | `Client/Camera` |
| 9 | Visibility → Actions → Generics → `Joints:Update` | — |
| 10 | `Animations:Update` (state anim, blend weights, footsteps) | `Character/Animations` |
| 11 | `Rig:Update` → `DataRegistry:UpdateCycle` (**network flush at 10 Hz**) | `Character/DataRegistry` |
| 12 | `ToolProfile:Update` → `ViewmodelVisuals` → spring deviation → `CameraService:SetCameraOffset("Viewmodel")` and `AdjustFOV("Sprint")` | `ToolProfile/ViewmodelVisuals/*` |
| — | `CameraService` has its own `RenderStepped` connection that writes `FieldOfView = BaseFOV × Π(FOVAdjusters)` | `Services/Client/CameraService` |

State selection (step 5) reads the `RelativeSpeed` and `Grounded` values from the previous step 7, so there is **one frame of
lag** between the measured speed and the state change. This lag comes from the game itself, and the clone must reproduce it.

---

## A. Movement & Camera Mechanics

### A1. Movement constants (`Movement/MoveStats/BaseStats`) — all MEASURED

| Parameter | Value | Meaning |
|---|---|---|
| `Speed` | 1500 u (16.67 st/s) | base wish speed |
| `SprintCap` | 2 | max sprint multiplier (wish speed 3000 u = 33.3 st/s) |
| `SprintAcceleration` | 1 | sprint ramp: `Sprint += 0.5·1·dt` (1 → 2 takes 2.0 s) |
| `RunAccel` | 1 | ground accel = `12 × RunAccel` = 12 |
| `Friction` | 5 | — |
| `RunDeaccel` | 700 u | friction control-speed floor (Quake `stopspeed`) |
| `AirAcceleration` | 1 | ×2 when `V·wishdir ≥ 0` |
| `AirStrafeAcceleration` | 182 | wish-speed cap **and** accel for pure A/D input |
| `JumpHeight` | 3 studs | `Humanoid.JumpHeight` (`CharacterUseJumpPower=false`) |
| `JumpSpeedMultiplier` | 1.45 | ground-jump speed boost |
| `JumpCap` | 1 | extra (double) jumps allowed — needs `Grounded=false and JumpAmount<JumpCap` (perk-gated in practice) |
| `BhopEnabled` | **false** | when true, Run skips friction while jump is held |
| `GroundedDistCheck` | 2.9 | ground raycast length = `2.9 × Size` |
| `WalkSpeedMultiplier` | 1 | `lerp(Sprint, SprintCap, WSM−1)` |
| `workspace.Gravity` | 50 | MEASURED from the saved Workspace. ESTIMATED that maps keep it; verify with `print(workspace.Gravity)` in a round |
| Jump vertical velocity | √(2·50·3) = **17.32 st/s** | derived; airtime ≈ 0.69 s on flat ground |

State speed multipliers (`Shared/StateInfo`): CrouchMove `SpeedMult 0.6` + `DisableSprinting` (cap → 1); Downed 0.3.

### A1b. Algorithms (verbatim from `MoveFunction/Functions` + `Helpers`) — MEASURED

**Accelerate (Quake):** `add = wishspeed − V·wishdir; if add ≤ 0 return V; acc = accel·dt·wishspeed; V += min(add, acc)·wishdir`
(swimming: accel×0.4, wishspeed×1.3).

**ApplyFriction(k):** `ctrl = (|V| < RunDeaccel) ? RunDeaccel : |V|; drop = ctrl·Friction·dt·k; V *= max(|V|−drop, 0)/|V|`.

**Run (grounded Idle/Move/Crouch):**
1. If `(BhopEnabled and JumpingActive) or JumpQueued` → return (no friction, no accel).
2. `V = ApplyFriction(k=1)`.
3. `wishdir = flat(GlobalMoveDirection).Unit`.
4. Sprint: `if MoveDirection.Z < 0 (forward held) and not CapSprint and not ADS → Sprint = clamp(Sprint + 0.5·SprintAcceleration·dt, 1, SprintCap)`, else `Sprint = 1`.
5. `wishspeed = |dir| · Speed · lerp(Sprint, SprintCap, WSM−1)`; `V = Accelerate(V, wishdir, wishspeed, 12·RunAccel, dt)`.
6. Wall-slide projection (`WallImpact`: a blockcast at 10% height plus two ±45° rays, removing the velocity component into walls steeper than 60°).

**Air (Air / WallrunL/R / SlideAir):**
1. `md = MoveDirection` (camera-relative). **If `md.Z < 0` (W held), Z is zeroed, so forward input does nothing in the air.**
2. If `md.Z > 0` (S held) → `ApplyFriction(k=1)` in the air.
3. `wishdir = LookCFrame:VectorToWorldSpace(md)` (this includes the look pitch; it is the full camera look, not yaw-only), `wishspeed = |wishdir|·Speed`.
4. `accel = (V·wishdir < 0) ? AirAcceleration : 2·AirAcceleration`.
5. **Air-strafe rule:** `if md.Z == 0 and md.X ~= 0` (pure A or D) → `wishspeed = min(wishspeed, 182)`, `accel = 182`.
6. `V = Accelerate(...)`, then `AirControl` (flattens Y when |md.Z| ≥ 0.001), then `WallImpact`.
7. Outputs `Sprint = clamp(|V|/(Speed·2)·2, 1, SprintCap)` (sprint is re-derived from speed while airborne).
8. Wallrun: adds a `VectorForce` of `mass·g·0.5` upward and blocks input toward/away from the wall.

**Air-strafe gain vs. yaw (derived from the rule above):** with pure A/D held and the camera turning so that `wishdir ⟂ V`,
each frame adds `min(182 − V·ŵ, 182·dt·182)` u along ŵ. At 60 fps that is ≤ 552 u ≈ **6.1 st/s of perpendicular velocity per
frame**. Because `wishspeed` is capped at 182 u, the gain only happens while `V·ŵ < 182 u` (2.02 st/s). That means the turn
rate must keep ŵ within roughly `acos(182/|V|)` of perpendicular. Net speed gain per frame ≈ `√(|V|² + add²) − |V|`. This is
the same optimal-angle behaviour as Source/Quake.

**Slide (grounded, Crouching, RelativeSpeed ≥ 19):** `ApplyFriction(k=0.1)`; steering like Air, but wishspeed = current
`|V|` and the Z input is removed. A slope term raycasts 4 studs down against `workspace.Map.Parts`, takes the hit point in
root object space, and sets `|V| = clamp(|V| − p.Z·dt·8000, 0, 5000)` (downhill accelerates; the hard cap is 5000 u = 55.6 st/s).
Root size goes to (2, 2.55, 2) after a `RootDelay` of 0.25 s.

**Jump (`Movement:Jump`, ground or wallrun):** if not crouching and `V ≠ 0`:
`cap = Sprint · Speed · 1.45 · (HRP.Look · V̂)²`; `if |V| < cap → |V| = min(|V|·1.45, cap)`.
At full sprint, facing the velocity direction, the cap is **4350 u = 48.3 st/s**. Above the cap the jump adds no speed.
Strafing sideways makes the dot² term ≈ 0, so the boost is ≈ 0. Then `Humanoid.JumpHeight = 3`, `ChangeState(Jumping)`.

**Jump input / "bhop buffer" (`Movement:JumpReact` + `InputService`):**
- `UserInputService.JumpRequest` → `JumpReact()`. It returns if `CanJump == false`. Otherwise it sets `JumpHeldDown = true`,
  calls `AttemptJump`, then sets **`CanJump = false` until the jump key is released** (it polls on Heartbeat).
  Holding Space therefore **does not** auto-repeat; each hop needs a fresh press (scroll-wheel binds re-trigger it).
- `Humanoid` Jumping state is disabled while `CanJump == false`.
- There is **no timed buffer window**. Ground friction applies on every grounded frame. With `BhopEnabled=false`, a 60 fps landing
  costs `max(|V|,700)·5/60` ≈ **8.3% of speed per grounded frame**. The effective "window" is how many frames you spend on the
  ground. A jump fires on the same frame the press arrives if `Grounded` was true for that frame.
- The user spec asks for "auto-jump when holding Space on touchdown". That is **not** Evade behaviour. Phase 2 will expose it as
  `CONFIG.AutoHop` (default **false** = Evade-exact).

**Grounded (`Terms.Grounded`):** 5 downward raycasts from HRP at offsets {0, ±0.5·SizeX on X and Z}, length `2.9·Size`.
Non-collidable hits are added to the ignore list and the cast is retried.

**State priority machine (`Shared/StateInfo` + `State:FindBestState`):** the highest `Priority` whose requirements all pass
wins; ties keep the earlier entry. Relevant entries: Idle(0, RS<0.1, grounded), Move(0, RS≥0.1), CrouchIdle/CrouchMove(0),
Air(1, not grounded), Slide(3, RS≥19, grounded, crouch), SlideAir(3, RS≥19, air, crouch), WallrunL/R(3, RS≥20, air, wall ±1).
`RelativeSpeed = s / (BaseSpeed/1500)`.

**Driver:** a `LinearVelocity` named "BaseMover" (Plane mode, PrimaryTangent X, SecondaryTangent Z, MaxForce 100000,
Attachment0 at the root centre) sets `PlaneVelocity = V/90`. Vertical motion is left to Humanoid and physics. Root orientation
for Camera-type states snaps yaw to the camera; for Slide/Wallrun it uses `CFrame.new(p, p+V)`.

### A2. Camera & FOV (`CameraService`, `ViewmodelDeviation/SpringList/*`) — MEASURED unless noted

| Effect | Formula / constants | Status |
|---|---|---|
| Base FOV | `CameraService.BaseFOV` = user setting `FOV` (default **70**, range 70–100) | MEASURED |
| Final FOV | `FieldOfView = BaseFOV × Π FOVAdjusters` (Sprint, ADS, Fear, Portal), written every RenderStepped | MEASURED |
| **Speed FOV** ("Sprint" adjuster) | `target = lerp(1, 1.1, clamp((s−25)/8, 0, 1))`; `adj = lerp(adj, target, min(dt·6, 1))`. **70 → 77 between s = 25 and 33 st/s.** Forced toward 1 if ADS is held or the Fear adjuster is > 1.1 | MEASURED. Your requested "95–110" range does **not** match Evade. Phase 2 uses Evade's ×1.10; a range scale is available in CONFIG |
| Viewbob setting off | camera spring returns only the `+lookVec·1.1` offset (no bob, no tilt) | MEASURED |
| **Strafe roll** ("Camera" spring, Speed 20, Damping 0.6) | `r10 = clamp((s−20)/12, 0, 1)` only when the state's `ViewmodelMoveType == "Moving"` (Move, Move_RootStraight, CrouchMove, Crouch_RootStraight, CarryMove). `roll = −(RelMoveDir.Unit.X · 0.025 · r10) · 1.15` rad (max ≈ **1.65°**). WallrunLeft = **−3°** (−0.05236 rad), WallrunRight = **+3°**. Spring target `t = (sin²(12T)·0.0025·r10·1.2, sin(12T)·0.0025·r10·1.2, cos(12T)·0.002·r10·1.2 + roll)` with `T = tick()`. `RelMoveDir` is the **velocity** direction in root space, not the input | MEASURED |
| **Air-strafe roll** | **None in Evade.** The Air state has no `ViewmodelMoveType`, so roll is 0 while airborne (except wallrun) | MEASURED. Optional `CONFIG.AirStrafeRoll` (default off) |
| **Head bob** ("OtherBob", lerp α = `min(dt·20,1)`) | Active only if grounded, s > 1, and MoveType "Moving"; otherwise it lerps to identity. With `T = tick()·10`: r10 = 0 → `CFrame(cos T·0.02, −sin(T)^12·0.08, 0)·Angles(cos²T·0.001, 0, cos(T+0.8)·0.0003)`. r10 ≥ 0.5 → `CFrame(0, r10·sin(24·tick())·0.24, 0)`. 0 < r10 < 0.5 → `walk:Lerp(I, 2−2r10) · sprint:Lerp(I, 2r10)` (decompiled blend, reproduced as-is). Frequency: walk 10 rad/s (≈1.59 Hz), sprint 24 rad/s (≈3.82 Hz) | MEASURED |
| **Landing punch** ("Grounded" spring, initial Speed 12, Damping 0.7) | On the grounded false→true edge: `k = clamp((|ActualVelocity.Y| − 9)/10, 0, 3)·0.5`; set `s=17, d=0.5, t = (−0.03k, 0, 0), v = (−0.025k, 0, 0)` (pitch-down, max 0.045 rad ≈ 2.6°). When `|p−t| ≤ 0.008` → `t = 0`. On the true→false edge (jump/fall): `v = (−0.2, 0, 0), t = 0` (takeoff pitch kick) | MEASURED |
| Slide camera punch | `Slide` spring exists only in the **Legacy** camera list (`LegacyCamera` setting, default false): on entering slide `s=16, d=0.7, t=(−0.022,0,0)`; once settled `t=(0.044,0,0)`; then `s=8, t=0` | MEASURED (legacy only) |
| Composition | `CamDev = HRP.CamPart.Transform · Angles(CameraSpring.p) · OtherBob + Angles(−pitch,0,0).LookVector·1.1`, then × Grounded spring. Applied via `SetCameraOffset("Viewmodel")` → `cam = CFrame(p)·CenterOffset·rot·ΠOffsets` | MEASURED |
| Spring model | analytic critically/under-damped spring (`p, v, t, s, d`, evaluated at `tick()`), so it is frame-rate independent | MEASURED |
| First person | zoom 0.5/0.5, `CameraOffset (0, 0.21, 0)`, MaxY/MinY ±80°, tween 0.16 s | MEASURED |

The FOV and spring effects only run while a viewmodel exists and is visible, i.e. first person. In third person the viewmodel is
hidden and `Reset()` lerps the Sprint FOV back to 1. MEASURED.

---

## B. Animation System & bhop flow

### B1. What Evade actually has vs. your 9 slots

Evade's R15 "Default" module (`Character/Animations/Types/R15/Default`) has these **state folders**: Idle, Moving (MoveF/B/L/R +
SprintF/FL/FR), Moving_RootStraight, Crouching (MoveF/B/L/R + Idle), Crouching_RootStraight, **Jumping (one track: "Jump")**,
**Sliding ("Slide")**, Downed, Climbing, Swimming, WallrunningLeft/Right. It also has **Transitions**: Jumping/End (the land
one-shot), Moving/End (the stop one-shot), Sliding/End.

| Your slot | Evade equivalent | Fidelity note |
|---|---|---|
| Idle | `Idle/Idle` | exact |
| Walk/Run | `Moving/MoveForward` (+ directional/sprint set) | Evade blends **7 tracks**. With one Walk/Run file, Phase 2 maps it to MoveForward and SprintForward and drives the same weight/speed formulas |
| Jump | `Jumping/Jump` | Evade plays **this single track for the whole airtime** (takeoff → apex → fall) |
| Fall | — | **does not exist in Evade** |
| Land | `Transitions/Jumping/End` | exact role: a one-shot on Jumping → Idle/Moving/Crouching |
| Air-strafe L / R | — | **do not exist in Evade.** There is no directional air animation; the Jump track is not weighted by input |
| Slide | `Sliding/Slide` | exact |
| Crouch | `Crouching/*` (Idle + MoveF/B/L/R) | one file → used for both idle and move with the same weight rules |

### B2. Track management (MEASURED)
- Tracks are loaded with **`Humanoid:LoadAnimation`** (it routes to the Animator) for every Animation in every state folder and
  every transition. They are cached in `Animations[folder] = {{Animation=track, Name=...}}`.
- `SetModule()` first stops **every** playing track with `Stop(0)` (this is how default animations are suppressed), then loads
  the set. Evade's `StarterCharacterScripts/Animate` is a server-class `Script` placeholder (its contents can't be saved; ESTIMATED
  to be an empty override that replaces Roblox's default Animate LocalScript). Verify with
  `print(char.Animate.ClassName, char.Animate.Enabled)`.
- Per frame, every track in the **current** folder gets `Play(PlayTransitionTime)` once on state entry. Every other folder's
  tracks get `Stop(<their own group's> StopTransitionTime)`. Tracks are never destroyed between states.

### B3. Track table

| Folder (state anim) | Tracks | Play fade | Stop fade | Speed formula | Weight formula | Footsteps |
|---|---|---|---|---|---|---|
| Default (fallback for Sliding, None, Inert) | — | 0.4 | 0.4 | 1 | 1 | off |
| Idle | Idle | 0.5 | 0.5 | 1 | 1 | off |
| Jumping | Jump | **0.5** | **0.1** | 1 | 1 | off |
| Moving / Moving_RootStraight — group 1 | MoveForward, MoveLeft, MoveRight, MoveBackward (time-synced to MoveForward) | 0.4 | 0.4 | `s/10.5` if s < 25, else `s/15`; ×−1 when L/R is swapped for backward motion | `dirWeight · (1 − clamp((s−25)/5, 0, 1))`, fade 0.15 | on |
| Moving — group 2 | SprintForward, SprintForwardLeft, SprintForwardRight | 0.4 | 0.4 | same | `dirWeight · clamp((s−25)/5, 0, 1)`; 0 if s < 25; fade 0.1 | on |
| Crouching(_RootStraight) | MoveF/L/R/B | 0.4 | 0.2 | same as Moving group 1 | same as Moving group 1 | on |
| Crouching — Idle track | Idle | 0.4 | 0.2 | 1 | 0 if s ≥ 0.5, fade 0.15 | on |
| Sliding | Slide | 0.4 | 0.4 | 1 | 1 | off (slide sound + particles instead) |
| WallrunningL/R | SprintForward | 0.4 | 0.4 | Moving speed formula | 1 | on |
| Transition Jumping/End (Land) | End | `PlayWeightLength` 0.05 | `StopWeightLength` 0.4, starts after 0.05 s | `Speed` attr 1.0 | 1 | — |
| Transition Moving/End (stop) | End | 0.3 | 0.5 after 0.3 s | 1.0 | 1 | — |
| Transition Sliding/End | End | 0.2 | 0.5 | 1.0 | — | **never fires**: no state's info lists `Transitions.Sliding` (MEASURED dead path) |

Direction weights use `d = RelativeMoveDirection` (velocity in root space, with `d.Z` forced to −0.01 when `|d.Z| < 0.1`):
Forward = `clamp(d.Z,−1,0)²`, Backward = `clamp(d.Z,0,1)²`, Left = `clamp(d.X,−1,0)²`, Right = `clamp(d.X,0,1)²`,
ForwardLeft/Right = `|clamp(d.X)|/0.7071`, ForwardForward = `|clamp(d.Z,−1,−0.7071)+0.7071| / 0.2929`.
Weights are floored at 0.01 (`AdjustWeight(max(w,0.01), fade)`). They update only when Speed or RelMoveDir changes.

**Priority / Looped / Length:** these live in the hosted KeyframeSequence assets, not in the place file. **ESTIMATED:** locomotion
tracks Looped=true at Core/Idle/Movement priority, and Jump/End/Slide at Movement or Action. To verify in Evade:
`for _,t in hum.Animator:GetPlayingAnimationTracks() do print(t.Animation.AnimationId, t.Priority, t.Looped, t.Length) end`.
Phase 2 will read Priority/Looped from **your** .rbxm KeyframeSequences, and fall back to the estimate if they are missing.

### B4. Bhop flow & transition rules (MEASURED)
1. **Takeoff:** a jump press makes the Humanoid jump. The next frame's Grounded raycast is false, so the state becomes **Air**,
   the animation state becomes "Jumping", and the `Jump` track plays with a 0.5 s fade-in. Leaving Moving does not play
   Moving/End, because the Jumping info has no `Transitions` table. The grounded spring gives the camera a pitch kick of
   `v = −0.2`.
2. **Airborne:** the `Jump` track holds for the whole flight. Air-strafe input changes **only velocity and camera** (and in
   Evade the camera does not roll in the air). No animation blending.
3. **Touchdown, speed > 0.1:** state → Move (or Idle). Old state Jumping, new state in `PlayLanded` → `Footsteps:Land()` (land
   sound). The new info has `Transitions.Jumping = {"End"}`, so **Jumping/End plays** (0.05 in / 0.4 out). Moving tracks fade
   in over 0.4 s. Jump fades out over 0.1 s. The landing camera punch fires.
4. **Re-jump within 1–2 frames (bhop):** state goes Air again. Land End is already playing and keeps running its own fade, so
   it overlaps the new Jump fade-in. Evade has no special case for a "bhop landing" vs. a "hard landing": both go through
   step 3. The only difference is how long the player stays grounded.
5. **Crouch held at touchdown with s ≥ 19:** the Slide state wins (priority 3 > 0). The Sliding track plays (fade 0.4). There is
   no land sound (Sliding is not in `PlayLanded`) and no Jumping/End (the Default info has no Transitions). Slide sound and
   particles start (`SlideAttachment.SlideParticles.Rate = 70`).
6. **Crouch mid-air with s ≥ 19:** SlideAir. The **Sliding** animation plays in the air and replaces Jump. Root size returns to
   (2,4,2).
7. **Interruption hierarchy** follows state priority: Ragdoll 10000 > Carried 9999 > Downed 100 > Stunned 99 > Lunge 98 >
   Emoting 5–7 > Climbing 4 > Slide/SlideAir/Wallrun 3 > Air/RootStraight 1 > ground states 0.
8. **Markers:** Evade uses **no** `GetMarkerReachedSignal`. Footsteps are **timer-driven**: when FootstepsEnabled and s > 0, a
   sound plays every `0.5 / AnimationSpeed` s (`AnimationSpeed = |speed formula result|`). "Run" sounds play at s ≥ 25, else
   "Walk", plus a "Cloth" layer (vol 0.06). Sounds only play within 25 studs of the camera. A wind "Whoosh" loop (asset
   12547448228) has volume `lerp(v, clamp((|ActualVel|−50)/125,0,1)·0.1, 0.1)` per frame, and is muted while Moving or Swimming.
   A "Wander" sound plays when entering Moving/Crouching (`PlayWander`).

---

## C. Remote & Network Architecture (MEASURED from the client)

Evade does **not** use one remote per gameplay event. All character state is replicated through a **binary-serialized data
registry** (`Character/DataRegistry` + `Shared/Networking/Serializer` + `Terms`). The client flushes changed `ClientSendable`
terms every **0.1 s** (in step 11).

### C1. Incoming (Server → Client)

| Remote (path under `ReplicatedStorage.Remotes`) | Class | Drives |
|---|---|---|
| `Registry/UpdateCharacterDataRegistry` | RemoteEvent | Per-character packets: `Create`/`Destroy`, `Tag`, `State`, `Speed`, `Downed`, `Carrying`, `Carried`, `Emote`, `Perks`, `Size`, `Seated`, `Climbing`, `RotationLocked`, … For other characters, the `State` term drives remote animation; their footsteps are simulated locally from replicated State + Speed. For the local character it applies server-forced terms, and `OwnerEcho` filters out echoes of terms we sent |
| `Registry/UpdateCharacterDataRegistryUnreliable` | UnreliableRemoteEvent | Same, for unreliable terms (`LookY`, `Gyro`, `TurretAim`, `OwnerEchoUnreliable`) |
| `Registry/UpdateServerStateRegistry` (+`Unreliable`) | RemoteEvent / Unreliable | Round and global state: `Gamemode`, `SpecialRound`, `MapLoading` (pauses all character updates). Changes trigger a `MoveStats:Reset()` |
| `Character/CharacterTask`, `Character/Task`, `Character/Action`, `Character/ToolAction` | RemoteEvent | Server-initiated character tasks/actions (ESTIMATED: knockback, stuns, tool FX). Verify by hooking `OnClientEvent` and printing args |
| `Items/GenericImpulse` | RemoteEvent | Impulses / knockback, which change velocity outside the movement step. ESTIMATED |
| `UI/GameUISetType`, `UI/SharedUISetType`, `UI/PopupUISetType` | RemoteEvent | HUD type switches (death hide/show, respawn, round state). ESTIMATED from naming |
| **Health** | — (no remote) | `Humanoid.Health` property replication, read every frame into `Registry.Health` |
| **Server velocity correction** | — (no dedicated remote) | The server can move the HRP (network ownership / CFrame set). Registry terms `ShiftMoveDirection` / `ShiftY` (set locally by portals) redirect velocity. `GenericImpulse` adds velocity |
| **Respawn** | — | A new character arrives through a registry `Create` packet. Locally, `Reset` is requested via `CharacterTask:FireServer("Reset")` |

### C2. Outgoing (Client → Server)

| Remote | Payload | Notes |
|---|---|---|
| `Registry/UpdateCharacterDataRegistry` | changed reliable terms: **`State`** (this carries slide on/off = "Slide"/"SlideAir", and stance = "CrouchIdle"/"CrouchMove"), **`Speed`**, `RelativeMoveDirection` (rounded to 0.01), `Equipped`, `Climbing`, `Underwater`, `CanBeCarried`, `Steer`, `ReviveQueue` | 10 Hz, only on change |
| `Registry/UpdateCharacterDataRegistryUnreliable` | `LookY` (`floor(asin(look.Y)·40+0.5)/40`), `Gyro`, `TurretAim` | 10 Hz |
| Footsteps | **none** | each client simulates them |
| Crouch / slide toggle | **none** as separate events | crouching is local-only; only the resulting `State` replicates |
| `Character/Interact` | `"Carry"` | — |
| `Character/CharacterTask` | `"Reset"` | reset button |
| `Session/SetPlayerMode` | bool | menu ↔ game |

### C3. Safe handling for client-only setups
Evade itself uses blocking `WaitForChild`. The clone will resolve every remote with a non-blocking `FindFirstChild` path walk
(with a timeout retry) and wrap each `Connect`/`FireServer` in `pcall`. Missing remotes are logged once as `MISSING` and
replaced by a no-op stub, so kinematics, camera and UI never depend on the network. **Default policy: listen-only.** The clone
will **not** fire outgoing registry packets, because hand-encoding Evade's binary protocol could desync or flag your account.
Outgoing mirroring stays a CONFIG flag that counts "would-send" events for validation.

---

## D. UI System — native design (MEASURED from `ReplicatedStorage/Assets/UI/Game`)

Hierarchy: `ScreenGui "Game"` (ResetOnSpawn=false, ScreenInsets=CoreUISafeInsets, ClipToDeviceSafeArea=true, ZIndexBehavior=Global,
DisplayOrder 0) → `HUD` (Frame, full screen, transparent) → `Overlay` (same) → `CharacterStatus` (Anchor 0,1; Pos {0,0,1,0};
Size full) → `BottomLeft` (same).

### D1. Speedometer (`BottomLeft/Speedometer`)
| Element | Key properties |
|---|---|
| `Speedometer` Frame | Pos {0.32,0,0.85,0}, Size {0.045,0,0.045,0}, AspectRatio 1.0, transparent, UICorner 4px |
| `Background` ImageLabel | Anchor .5,.5; Size 1.25×1.25; Image `rbxassetid://196969716`, ImageColor (21,21,21), ImageTransparency 0.4, UICorner 4px, ZIndex 1 |
| `ImageLabel` (icon) | Size 0.75×0.75 centred, Image `rbxassetid://13492318225`, color **(255,218,107)**, UICorner 3px, UIGradient rot 90 |
| `Frame/Frame` | Size {2,0,1,0}, black, BgTransparency 0.6, UICorner 4px |
| `Front` | Pos {1,0,0,0}, Size {2.6,0,1,0} (resized at runtime); child `Frame` Pos {−1,0,0,0}, Size {2,0,1,0}, black, BgTransparency 0.9, UICorner 4px |
| `Speed` TextLabel | Anchor 0,.5; Pos {1.3,0,0.5,0}; Size {6,0,0.8,0}; **GothamSSm Bold (700)**; TextScaled; color (255,218,107); XAlign Left; UIStroke black 2px @0.5; TextStroke 0.9; UIGradient rot 90; ZIndex 2 |
| Driver | `CharacterRegistryTermUpdated("Speed")`, event-driven but effectively every RenderStepped (Speed is recomputed each frame and only fires on change). Text = `commaval(floor(s·10)/10)` (thousands commas, e.g. `33.3`, `1,204.5`, `0`). Then `Front.Size = UDim2.new(0.5, Speed.TextBounds.X, 1, 0)`. **No tweening** |

### D2. Health (`BottomLeft/Health`)
| Element | Key properties |
|---|---|
| `Health` Frame | Anchor 0,1; Pos {0.05,0,0.95,0}; Size {0.25,0,0.1,0}; black, BgTransparency 0.8; UICorner 0.1 scale; UIStroke black 1px @0.8; UIShadow blur 0.12 @0.6 |
| `Background` | Image 196969716, color (21,21,21) @0.8, UICorner 4px, ZIndex 0 |
| `BackgroundStroke` | Size {1,−6,1,−6} centred, UICorner 0.06, **UIStroke 2px (112,255,73) @0.7** |
| `HealthIcon` | Anchor 0,.5; Pos {0.08,0,0.5207,0}; Size {0.2566,0,0.6414,0}; Aspect 1.1; Image `18788896053` (112,255,73), ZIndex 4; child `HealthIcon` Image `18788900977` white @0.5, ZIndex 3 |
| `Health` TextLabel | Anchor 1,.5; Pos {0.9,0,0.5,0}; Size {0.5,0,0.5,0}; GothamSSm Bold; TextScaled; (112,255,73); XAlign Center; UIStroke 2px @0.5 |
| `Frame` + UIListLayout | Pos {0.775,0,0.6,0}, Size {0.225,0,0.45,0}, empty container (ESTIMATED: status icons) |
| Driver | `CharacterRegistryTermUpdated("Health")` ← `Humanoid.Health` every frame. Text = `tostring(health)` (raw, decimals possible). Colour = `health < 25 ? (255,78,78) : (112,255,73)`, applied to icon, text and BackgroundStroke stroke. **No fill bar, no tween.** Hidden on death (`Frame.Visible=false`) |

### D3. Skipped (not supplied → silently skipped)
Attributes/Streak, Tickets (currency, with its 0.3 s Sine slide-in/out tween), Speedlines overlay (s > 50), Interact, Objectives,
RoundState, PreRound, Respawn, DeathFeed, Deployables, MobileButtons, Fear (camera shake + FOV ×1.2), Tool, Safezone, Dialog,
Actions, HideUI, Interactors/Popups.

---

## E. Assumptions & Gaps

| # | Gap | Handling | How to verify |
|---|---|---|---|
| E1 | Animation Priority/Looped/Length are in hosted assets | read them from your .rbxm KeyframeSequences, fall back to the B3 estimate | print `GetPlayingAnimationTracks()` in Evade |
| E2 | **Fall, Air-strafe L/R** have no Evade equivalent | strict mode: ignored (the Jump track covers airtime). Extension mode (flag): Fall cross-fades from Jump after apex (`Vy<0`), and AirStrafe L/R weights follow `md.X` with A/D held | design decision, see question 1 |
| E3 | Evade **"health bar" has no fill**: it is an icon + number panel | `UIMap.HealthFill` is optional; the validation "health fill %" metric = Health/MaxHealth | — |
| E4 | `CamPart.Transform` (animation-driven camera motor) needs Evade's rig | identity if your rig has no `CamPart` motor | `HRP:FindFirstChild("CamPart")` |
| E5 | Server scripts are absent | server-side behaviour (damage, impulses, round flow) is inferred from client handlers only | hook `OnClientEvent` and log |
| E6 | Gravity 50 comes from the saved Workspace | read `workspace.Gravity` live, never hardcoded | print in a round |
| E7 | Decompiler artefacts: in `WallImpact` the speed-return branch is dead (`r9={}` before `#r9>0`), and the `AirControl` dot product is unused | reproduce the behaviour as decompiled | compare REAL vs CLONE logs on wall slides |
| E8 | Your requested FOV range (95–110), air-strafe roll, and hold-to-auto-hop are **not** Evade behaviour | Evade-exact by default. `CONFIG.FOVMaxMult`, `CONFIG.AirStrafeRoll`, `CONFIG.AutoHop` are opt-in | — |
| E9 | Outgoing remote mirroring | listen-only by default (C3) | — |
| E10 | `RegisterKeyframeSequence` / `GetObjects` support on "Real" executor is unverified | fallback chain in Phase 2: GetObjects(getcustomasset) → `game:GetObjects` via the rbxasset path → embedded `Animation.AnimationId` values in your rbxm → Evade's own asset IDs (B tables) → procedural no-anim | startup capability report |
| E11 | Root/Joints waist-turn (`Joints`, `CanTurnWaist`) | out of scope (not requested) | — |
