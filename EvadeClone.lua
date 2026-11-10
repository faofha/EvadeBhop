--!nocheck
--[[
================================================================================
  EvadeClone  —  single-file client executor script
  Reproduces Evade's movement, camera, animation, HUD (speed + health) and
  remote-integration systems in NON-Evade games, using YOUR assets from the
  executor workspace folder  EvadeClone/ .

  Source of truth: decompiled Evade client (place 9872472334, HLWN build).
  Every constant below is tagged:
     MEASURED  = read verbatim from Evade's decompiled modules / serialized props
     ESTIMATED = inferred (verification method given next to it)
  Phase 1 spec with full derivations: docs/PHASE1_SPEC.md

  Architecture (mirrors Evade's script split and update order):
    Config      -> CONFIG (Evade BaseStats, camera, anim, UI constants)
    Evade data  -> EVADE (state table, anim infos, transition attrs, footstep sounds, anim IDs)
    Mapping     -> AnimationMap / UIMap / RemoteMap / SoundMap
    Assets      -> capability report, file checks, getcustomasset -> GetObjects pipeline
    Registry    -> Evade "DataRegistry" (term store + change hooks + 10 Hz outgoing flush)
    Movement    -> Terms, State machine, MoveFunctions (Run/Air/Slide), Jump, RootPartOrienter
    Camera      -> CameraService FOV adjusters + ViewmodelDeviation "Camera"/"Grounded" springs
    Animator    -> Evade Animations module (SetCurrentAnimation / UpdateAnimations / SetValues)
    Footsteps   -> timer-driven footsteps, land/wander, slide sound+particles, wind whoosh
    Remotes     -> RemoteMap resolution, listen-only hooks, outgoing "would-send" mirror
    UI          -> Evade CharacterStatus (Speedometer + Health)
    Validation  -> F8 logger, REAL/CLONE CSV, jump-aligned comparison, >5% alerts
    Cleanup     -> Maid-based full teardown / restore

  Update order per frame (Evade CharacterService RenderStepped -> Character:Update):
    [RenderPriority.First]      camera base restore (removes last frame's offset)
    [RenderPriority.Camera + 1] Health/LookCFrame/ActualVelocity -> Movement:UpdateTerms
                                -> State:Update -> Movement:Update -> CameraType:Update
                                -> Animations:Update (+Footsteps) -> Registry:UpdateCycle
                                -> CameraService FOV write -> ToolProfile springs (offset + FOV adjuster)
    Event-driven: JumpRequest -> Movement:JumpReact ; Input C/LCtrl -> CrouchKey ;
                  Registry term changes -> UI.SetSpeed / UI.SetHealth / Animator.SetState
================================================================================
]]

local VERSION = "1.0.0"

--==============================================================================
-- SECTION 0 : SERVICES, GLOBAL ENV, SINGLE-INSTANCE GUARD
--==============================================================================
-- Services go through cloneref when the executor has it, so the game's scripts can't detect this script
-- through the shared service references.  Without it the plain service is used.
local cloneRef = (typeof(cloneref) == "function" and cloneref) or (typeof(clonereference) == "function" and clonereference) or nil
local function getService(name)
	local service = game:GetService(name)
	if cloneRef then
		local ok, ref = pcall(cloneRef, service)
		if ok and typeof(ref) == "Instance" then
			return ref
		end
	end
	return service
end

local Players = getService("Players")
local RunService = getService("RunService")
local UserInputService = getService("UserInputService")
local ReplicatedStorage = getService("ReplicatedStorage")
local TweenService = getService("TweenService")
local Debris = getService("Debris")
local HttpService = getService("HttpService")
local LocalPlayer = Players.LocalPlayer

-- Random instance names (32 hex chars, new each run) for everything this script creates, so the GUIs and
-- the constraints/sounds on the character can't be found by a fixed name.
local function hiddenName()
	return (string.gsub(HttpService:GenerateGUID(false), "-", ""))
end
local PRECAMERA_BIND, CHARACTER_BIND = hiddenName(), hiddenName() -- RenderStep binding names

-- Executor global table (falls back to _G so the guard still works without getgenv).
local GENV = _G
do
	local ok, env = pcall(function()
		return getgenv()
	end)
	if ok and type(env) == "table" then
		GENV = env
	end
end

-- Re-executing the script unloads the previous instance first (no double hooks).
if type(GENV.EvadeClone) == "table" and type(GENV.EvadeClone.Unload) == "function" then
	pcall(GENV.EvadeClone.Unload)
end

--==============================================================================
-- SECTION 1 : CONFIG  (populated with Phase 1 parameters)
--==============================================================================
local CONFIG = {
	-- "CLONE" = run the Evade engine on your character.
	-- "REAL"  = passive logger only (run this inside Evade to record the baseline).
	Mode = "CLONE",
	Root = "EvadeClone", -- workspace folder of your executor
	Verbose = false, -- extra per-step logging

	-- Animation files referenced by AnimationMap are fetched from this URL into <Root>/Animations/
	-- when missing, so nobody has to download them by hand.  Set Enabled = false to use local files only.
	AssetDownload = {
		Enabled = true,
		BaseUrl = "https://raw.githubusercontent.com/faofha/EvadeBhop/main/Animations/",
		Redownload = false, -- true = overwrite local copies on every run
	},

	Movement = { -- MEASURED: Objects/Game/Character/Client/Movement/MoveStats/BaseStats
		Speed = 1500, -- internal units (studs/s * 90)
		SprintCap = 2,
		SprintAcceleration = 1, -- Sprint += 0.5 * SprintAcceleration * dt
		RunAccel = 1, -- ground accel = 12 * RunAccel
		Friction = 5,
		RunDeaccel = 700, -- friction control-speed floor
		AirStrafeAcceleration = 182,
		AirAcceleration = 1,
		JumpHeight = 3,
		-- Evade's workspace.Gravity (MEASURED 50).  Other games usually run 196.2, which cut airtime to
		-- ~0.44 s; a VectorForce on the character makes its effective gravity this value (nothing else in
		-- the game is affected).  Set to nil to use the game's own gravity.
		Gravity = 50,
		JumpCap = 1,
		WalkSpeedMultiplier = 1,
		JumpSpeedMultiplier = 1.45,
		BhopEnabled = false,
		GroundedDistCheck = 2.9,
		-- MEASURED engine constants (Movement / Functions / Constraints / StateInfo)
		VelocityScale = 90, -- PlaneVelocity = V / 90
		LinearVelocityMaxForce = 100000,
		SlideFriction = 0.1,
		SlideSlopeGain = 8000,
		SlideMaxSpeed = 5000,
		SlideSlopeRayLength = 4,
		WallrunJumpPush = 30, -- studs/s added along wall normal
		WallrunCheckExtra = 0.9, -- studs past half root width
		WallrunNormalMinDeg = 85,
		WallrunNormalMaxDeg = 95,
		WallSlideMinDeg = 60, -- surfaces steeper than this block velocity
		IgnoreXMoveTime = 0.3,
		CarryJumpLockTime = 0.6,
		-- MEASURED: Evade disables these Humanoid states (Dead is NOT disabled here: non-Evade
		-- games rely on Humanoid death; Evade handles death server-side).
		DisableHumanoidStates = { Enum.HumanoidStateType.Swimming, Enum.HumanoidStateType.FallingDown, Enum.HumanoidStateType.GettingUp },
	},

	Hull = {
		-- MEASURED: Evade's HumanoidRootPart is a (2,4,2) full-body hull resting on the floor; crouch/slide
		-- shrink it to (2,2.55,2) (lerp clamp(dt*20), snap within 0.02, Slide waits RootDelay 0.25 s).
		-- ESTIMATED adaptation: on a stock R6/R15 rig we emulate that hull (raycast origins, camera drop);
		-- physical collision size is not changed.  Verify: crouch under a 3-stud gap in Evade vs here.
		StandSize = Vector3.new(2, 4, 2),
		ResizeRate = 20,
		SnapEpsilon = 0.02,
	},

	Keys = { -- MEASURED: Config/Player/Controls
		Crouch = { Enum.KeyCode.C, Enum.KeyCode.LeftControl, Enum.KeyCode.ButtonR2 },
		ThirdPerson = { Enum.KeyCode.O, Enum.KeyCode.ButtonR3 },
		Settings = Enum.KeyCode.P, -- opens the settings panel (FOV slider)
		GamepadJump = Enum.KeyCode.ButtonA,
		Validation = Enum.KeyCode.F8,
		Unload = Enum.KeyCode.End,
	},

	Camera = {
		BaseFOV = 70, -- MEASURED: Settings FOV default 70 (range 70-100); set live from the settings panel
		FOVMin = 70,
		FOVMax = 100,
		-- Third person is a script-driven shift-lock camera: the mouse turns it without right-click.
		-- Mouse wheel (MEASURED Camera.TestThirdPerson): each notch adds 1 to a counter that drains at
		-- 4/s; above 3 it toggles (scroll out -> third person, scroll in -> first person) and resets.
		ScrollToggleThreshold = 3,
		ScrollDecayRate = 4,
		ThirdPersonRootOffset = 0.4, -- MEASURED: Camera/Types ThirdPerson RootOffset
		-- First-person body visibility (MEASURED Character/Client/Visibility): "NoArms" shows legs + torso;
		-- head, arms, root and accessories are hidden.  FOV above 90 hides everything ("None").
		FirstPersonVisibility = "NoArms",
		ZoomRate = 12, -- zoom smoothing (1/s)
		MaxPitch = math.rad(80), -- MEASURED: MaxY/MinY +-80
		GamepadLookSpeed = Vector2.new(4.5, 3), -- rad/s at full right-stick deflection
		SprintFOVMax = 1.1, -- MEASURED: lerp(1, 1.1, clamp((s-25)/8, 0, 1))
		SprintFOVStart = 25,
		SprintFOVRange = 8,
		SprintFOVRate = 6, -- MEASURED: min(dt*6, 1)
		Viewbob = true, -- MEASURED: Settings Viewbob default true
		ForwardOffset = 1.1, -- MEASURED: + Angles(-pitch,0,0).LookVector * 1.1
		FirstPersonZoom = 0.5, -- MEASURED: Camera/Types FirstPerson
		ThirdPersonZoom = 6, -- MEASURED: Camera/Types ThirdPerson
		CameraOffset = Vector3.new(0, 0.21, 0), -- MEASURED: FirstPerson CameraOffset
		ThirdPersonShiftLockOffset = Vector3.new(2, 0.5, 0), -- MEASURED: ThirdPerson ShiftLockOffset
		TweenLength = 0.16, -- MEASURED: FirstPerson/ThirdPerson TweenLength
		StartThirdPerson = false, -- MEASURED: desktop default ThirdPersonChoiceActive=false
		CameraSpring = { Speed = 20, Damping = 0.6 }, -- MEASURED: SpringList.Camera
		GroundedSpring = { Speed = 12, Damping = 0.7 }, -- MEASURED: SpringList.Grounded
	},

	Animation = {
		-- Rescale PlaybackSpeed by (yourLength / evadeLength) when both are known.
		-- Evade lengths are filled from EvadeClone/Logs/evade_tracks.csv (recorded by REAL mode inside Evade)
		-- or from EvadeLengths below (seconds, keyed by slot e.g. ["Jumping/Jump"] = 0.8).
		RescaleToEvadeLength = true,
		EvadeLengths = {},
		-- Optional: AnimationIds you uploaded yourself, used when a .rbxm can't be registered.
		IdOverrides = {},
		-- ESTIMATED priorities (Evade's are inside hosted assets). Only applied when ForceEstimatedPriority
		-- is true or when the source gives no priority.  Verify in Evade with REAL mode (evade_tracks.csv).
		ForceEstimatedPriority = false,
		EstimatedPriority = {
			Idle = Enum.AnimationPriority.Idle,
			Moving = Enum.AnimationPriority.Movement,
			Crouching = Enum.AnimationPriority.Movement,
			Jumping = Enum.AnimationPriority.Movement,
			Sliding = Enum.AnimationPriority.Movement,
			WallrunningLeft = Enum.AnimationPriority.Movement,
			WallrunningRight = Enum.AnimationPriority.Movement,
			Transitions = Enum.AnimationPriority.Action,
		},
	},

	Audio = {
		Footsteps = true,
		Whoosh = true,
		Slide = true,
		HearingDistance = 25, -- MEASURED: footsteps only within 25 studs of camera
	},

	UI = { Enabled = true },

	Remotes = {
		-- "Count" = listen-only, outgoing registry terms are counted, never sent (default, safe).
		-- "Fire"  = FireServer(table) on the mapped outgoing remote (only for remotes YOU own).
		OutgoingMode = "Count",
		FlushPeriod = 0.1, -- MEASURED: DataRegistry.UpdatePeriod
		SendableTerms = { State = "Reliable", Speed = "Reliable", RelativeMoveDirection = "Reliable", LookY = "Unreliable", Gyro = "Unreliable" }, -- MEASURED: Shared/Networking/Terms
	},

	Validation = {
		Enabled = true,
		SampleInterval = 0.05,
		Duration = 12, -- seconds (10-15 requested)
		Threshold = 0.05, -- 5 %
		ExportCSV = true,
		AutoCompare = true, -- after a CLONE run, compare against Logs/real.csv if present
	},
}

--==============================================================================
-- SECTION 2 : EVADE DATA (MEASURED tables copied from the decompiled client)
--==============================================================================
local EVADE = {}

-- Shared/StateInfo (subset relevant outside Evade's map-specific systems: ladders, water, carry,
-- emotes, downed, vehicles are skipped). Order and priorities are verbatim; first-highest wins.
EVADE.States = {
	{
		State = "Idle", Priority = 0, Animation = "Idle",
		Requirements = { RelativeSpeedTest = { "<", 0.1 }, Grounded = true, Crouching = false },
		Movement = { MoveType = "Run", Constraints = { "BaseMover" }, RootPartOrientation = "Camera" },
	},
	{
		State = "Move", Priority = 0, Animation = "Moving", ViewmodelMoveType = "Moving",
		Requirements = { RelativeSpeedTest = { ">", 0.1 }, Grounded = true, Crouching = false },
		Movement = { MoveType = "Run", Constraints = { "BaseMover" }, RootPartOrientation = "Camera" },
	},
	{
		State = "CrouchIdle", Priority = 0, Animation = "Crouching", RootSize = Vector3.new(2, 2.549999952316284, 2),
		Requirements = { RelativeSpeedTest = { "<", 0.1 }, Grounded = true, Crouching = true },
		Movement = { MoveType = "Run", Constraints = { "BaseMover" }, RootPartOrientation = "Camera", DisableSprinting = true },
	},
	{
		State = "CrouchMove", Priority = 0, Animation = "Crouching", ViewmodelMoveType = "Moving", RootSize = Vector3.new(2, 2.549999952316284, 2),
		Requirements = { RelativeSpeedTest = { ">", 0.1 }, Grounded = true, Crouching = true },
		Movement = { MoveType = "Run", Constraints = { "BaseMover" }, RootPartOrientation = "Camera", SpeedMult = 0.6, DisableSprinting = true },
	},
	{
		State = "WallrunLeft", Priority = 3, Animation = "WallrunningLeft", ViewmodelMoveType = "WallrunningLeft",
		Requirements = { RelativeSpeedTest = { ">", 20 }, Grounded = false, Crouching = false, WallrunDirection = 1 },
		Movement = { MoveType = "Air", Constraints = { "BaseMover", "WallrunForce" }, RootPartOrientation = "Velocity", Wallrunning = true },
	},
	{
		State = "WallrunRight", Priority = 3, Animation = "WallrunningRight", ViewmodelMoveType = "WallrunningRight",
		Requirements = { RelativeSpeedTest = { ">", 20 }, Grounded = false, Crouching = false, WallrunDirection = -1 },
		Movement = { MoveType = "Air", Constraints = { "BaseMover", "WallrunForce" }, RootPartOrientation = "Velocity", Wallrunning = true },
	},
	{
		State = "Slide", Priority = 3, Animation = "Sliding", ViewmodelAnimationType = "Slide",
		RootSize = Vector3.new(2, 2.549999952316284, 2), RootDelay = 0.25,
		Requirements = { RelativeSpeedTest = { ">", 19 }, Grounded = true, Crouching = true },
		Movement = { MoveType = "Slide", Constraints = { "BaseMover" }, RootPartOrientation = "Velocity", BreakDoors = true },
	},
	{
		State = "SlideAir", Priority = 3, Animation = "Sliding", ViewmodelAnimationType = "Slide", RootSize = Vector3.new(2, 4, 2),
		Requirements = { RelativeSpeedTest = { ">", 19 }, Grounded = false, Crouching = true },
		Movement = { MoveType = "Air", Constraints = { "BaseMover" }, RootPartOrientation = "Velocity", BreakDoors = true },
	},
	{
		State = "Air", Priority = 1, Animation = "Jumping", ViewmodelAnimationType = "Air",
		Requirements = { Grounded = false },
		Movement = { MoveType = "Air", Constraints = { "BaseMover" }, RootPartOrientation = "Camera" },
	},
}
EVADE.StateByName = {}
for _, s in EVADE.States do
	EVADE.StateByName[s.State] = s
end
-- "Inert": Evade's fallback when no state matches / character disabled (Movement.CanJump=false).
EVADE.StateByName.Inert = { State = "Inert", Priority = -1000, Animation = "Default", Requirements = {}, Movement = { CanJump = false } }

-- Objects/Game/Character/Animations/Types/<R15|Classic>/Default  (verbatim)
EVADE.AnimInfo = {
	R15 = {
	    {
	        Names = {"Default"}, StopTransitionTime = 0.4, PlayTransitionTime = 0.4,
	        PlaybackInfo = {}, FootstepsEnabled = false, CanTurnWaist = false
	    },
	    {
	        Names = {"Jumping"}, StopTransitionTime = 0.1, PlayTransitionTime = 0.5,
	        PlaybackInfo = {}, FootstepsEnabled = false,
	        PlayLanded = {"Idle", "Moving", "Moving_RootStraight"}
	    },
	    {
	        Names = {"Idle"}, StopTransitionTime = 0.5, PlayTransitionTime = 0.5,
	        PlaybackInfo = {},
	        Transitions = {Jumping = {"End"}, Moving = {"End"}, Moving_RootStraight = {"End"}},
	        FootstepsEnabled = false, CanTurnWaist = true
	    },
	    {
	        Names = {"WallrunningLeft", "WallrunningRight"}, StopTransitionTime = 0.4, PlayTransitionTime = 0.4,
	        Transitions = {}, FootstepsEnabled = true,
	        PlaybackInfo = {
	            {
	                Animations = {"SprintForward"},
	                SpeedInfo = {
	                    UseMovementSpeed = true, SpeedDivision = 10.5, SpeedDivisionPastSpeed = {25, 15}, Return = true
	                }
	            }
	        }
	    },
	    {
	        Names = {"Moving", "Moving_RootStraight"}, StopTransitionTime = 0.4, PlayTransitionTime = 0.4,
	        Transitions = {Jumping = {"End"}}, FootstepsEnabled = true, PlayWander = true,
	        PlaybackInfo = {
	            {
	                Animations = {"MoveForward", "MoveLeft", "MoveRight", "MoveBackward"}, CopyTimePosition = "MoveForward",
	                Directions = {MoveForward = "Forward", MoveLeft = "Left", MoveRight = "Right", MoveBackward = "Backward"},
	                SpeedInfo = {
	                    UseMovementSpeed = true, SpeedDivision = 10.5, SpeedDivisionPastSpeed = {25, 15}, Return = true
	                },
	                WeightInfo = {
	                    TransitionTime = 0.15, SpeedChanges = {Subtract = 25, Division = 5, Reversed = true},
	                    ReverseLeftRightIfBackwards = true
	                }
	            },
	            {
	                Animations = {"SprintForward", "SprintForwardLeft", "SprintForwardRight"},
	                Directions = {SprintForward = "ForwardForward", SprintForwardLeft = "ForwardLeft", SprintForwardRight = "ForwardRight"},
	                SpeedInfo = {UseMovementSpeed = true, SpeedDivision = 10.5, SpeedDivisionPastSpeed = {25, 15}},
	                WeightInfo = {TransitionTime = 0.1, ZeroBeforeSpeed = 25, SpeedChanges = {Subtract = 25, Division = 5}}
	            }
	        }
	    },
	    {
	        Names = {"Crouching", "Crouching_RootStraight"}, StopTransitionTime = 0.2, PlayTransitionTime = 0.4,
	        FootstepsEnabled = true, PlayWander = true, Transitions = {Jumping = {"End"}},
	        PlaybackInfo = {
	            {
	                Animations = {"MoveForward", "MoveLeft", "MoveRight", "MoveBackward"}, CopyTimePosition = "MoveForward",
	                Directions = {MoveForward = "Forward", MoveLeft = "Left", MoveRight = "Right", MoveBackward = "Backward"},
	                SpeedInfo = {
	                    UseMovementSpeed = true, SpeedDivision = 10.5, SpeedDivisionPastSpeed = {25, 15}, Return = true
	                },
	                WeightInfo = {
	                    TransitionTime = 0.15, SpeedChanges = {Subtract = 25, Division = 5, Reversed = true},
	                    ReverseLeftRightIfBackwards = true
	                }
	            },
	            {Animations = {"Idle"}, WeightInfo = {TransitionTime = 0.15, ZeroAfterSpeed = 0.5}}
	        }
	    },
	    {
	        Names = {"Downed"}, StopTransitionTime = 0.2, PlayTransitionTime = 0.4, FootstepsEnabled = false,
	        Transitions = {},
	        PlaybackInfo = {
	            {
	                Animations = {"Crawl"},
	                SpeedInfo = {UseMovementSpeed = true, SpeedDivision = 4},
	                WeightInfo = {TransitionTime = 0.15, ZeroBeforeSpeed = 0.5}
	            },
	            {Animations = {"Idle"}, WeightInfo = {TransitionTime = 0.15, ZeroAfterSpeed = 0.5}}
	        }
	    },
	    {
	        Names = {"Climbing"}, StopTransitionTime = 0.2, PlayTransitionTime = 0.4,
	        Transitions = {}, FootstepsEnabled = true, PlayWander = false, IgnoreSpeedCheck = true,
	        PlaybackInfo = {
	            {Animations = {"Climbing"}, SpeedInfo = {YVelocitySpeed = true, Return = true}}
	        }
	    },
	    {
	        Names = {"Swimming"}, StopTransitionTime = 0.2, PlayTransitionTime = 0.4,
	        Transitions = {}, FootstepsEnabled = true, PlayWander = true, IgnoreSpeedCheck = true,
	        PlaybackInfo = {
	            {
	                Animations = {"Swimming"},
	                WeightInfo = {TransitionTime = 0.15, SpeedChanges = {Subtract = 0, Division = 5}}
	            },
	            {Animations = {"Idle"}, WeightInfo = {TransitionTime = 0.15, ZeroAfterSpeed = 0.5}}
	        }
	    }
	},
	Classic = {
	    {
	        Names = {"Default"}, StopTransitionTime = 0.4, PlayTransitionTime = 0.4,
	        PlaybackInfo = {}, FootstepsEnabled = false
	    },
	    {
	        Names = {"Jumping"}, StopTransitionTime = 0.4, PlayTransitionTime = 0.4,
	        PlaybackInfo = {}, FootstepsEnabled = false,
	        PlayLanded = {"Idle", "Moving", "Moving_RootStraight"}
	    },
	    {
	        Names = {"Idle"}, StopTransitionTime = 0.4, PlayTransitionTime = 0.4,
	        PlaybackInfo = {},
	        Transitions = {Jumping = {"End"}, Moving = {"End"}, Moving_RootStraight = {"End"}},
	        FootstepsEnabled = false
	    },
	    {
	        Names = {"WallrunningLeft", "WallrunningRight"}, StopTransitionTime = 0.2, PlayTransitionTime = 0.4,
	        Transitions = {}, FootstepsEnabled = true,
	        PlaybackInfo = {
	            {
	                Animations = {"SprintForward"},
	                SpeedInfo = {
	                    UseMovementSpeed = true, SpeedDivision = 10.5, SpeedDivisionPastSpeed = {25, 15}, Return = true
	                }
	            }
	        }
	    },
	    {
	        Names = {"Moving", "Moving_RootStraight"}, StopTransitionTime = 0.2, PlayTransitionTime = 0.4,
	        Transitions = {}, FootstepsEnabled = true, PlayWander = true,
	        PlaybackInfo = {
	            {
	                Animations = {"MoveForward", "MoveLeft", "MoveRight", "MoveBackward"}, CopyTimePosition = "MoveForward",
	                Directions = {MoveForward = "Forward", MoveLeft = "Left", MoveRight = "Right", MoveBackward = "Backward"},
	                SpeedInfo = {
	                    UseMovementSpeed = true, SpeedDivision = 10.5, SpeedDivisionPastSpeed = {25, 15}, Return = true
	                },
	                WeightInfo = {
	                    TransitionTime = 0.15, SpeedChanges = {Subtract = 25, Division = 5, Reversed = true},
	                    ReverseLeftRightIfBackwards = true
	                }
	            },
	            {
	                Animations = {"SprintForward", "SprintForwardLeft", "SprintForwardRight"},
	                Directions = {SprintForward = "ForwardForward", SprintForwardLeft = "ForwardLeft", SprintForwardRight = "ForwardRight"},
	                SpeedInfo = {UseMovementSpeed = true, SpeedDivision = 10.5, SpeedDivisionPastSpeed = {25, 15}},
	                WeightInfo = {TransitionTime = 0.1, ZeroBeforeSpeed = 25, SpeedChanges = {Subtract = 25, Division = 5}}
	            }
	        }
	    },
	    {
	        Names = {"Crouching", "Crouching_RootStraight"}, StopTransitionTime = 0.2, PlayTransitionTime = 0.4,
	        FootstepsEnabled = true, PlayWander = true, Transitions = {},
	        PlaybackInfo = {
	            {
	                Animations = {"MoveForward", "MoveLeft", "MoveRight", "MoveBackward"}, CopyTimePosition = "MoveForward",
	                Directions = {MoveForward = "Forward", MoveLeft = "Left", MoveRight = "Right", MoveBackward = "Backward"},
	                SpeedInfo = {
	                    UseMovementSpeed = true, SpeedDivision = 10.5, SpeedDivisionPastSpeed = {25, 15}, Return = true
	                },
	                WeightInfo = {
	                    TransitionTime = 0.15, SpeedChanges = {Subtract = 25, Division = 5, Reversed = true},
	                    ReverseLeftRightIfBackwards = true
	                }
	            },
	            {Animations = {"Idle"}, WeightInfo = {TransitionTime = 0.15, ZeroAfterSpeed = 0.5}}
	        }
	    },
	    {
	        Names = {"Downed"}, StopTransitionTime = 0.2, PlayTransitionTime = 0.4, FootstepsEnabled = false,
	        Transitions = {},
	        PlaybackInfo = {
	            {
	                Animations = {"Crawl"},
	                SpeedInfo = {UseMovementSpeed = true, SpeedDivision = 4},
	                WeightInfo = {TransitionTime = 0.15, ZeroBeforeSpeed = 0.5}
	            },
	            {Animations = {"Idle"}, WeightInfo = {TransitionTime = 0.15, ZeroAfterSpeed = 0.5}}
	        }
	    },
	    {
	        Names = {"Climbing"}, StopTransitionTime = 0.2, PlayTransitionTime = 0.4,
	        Transitions = {}, FootstepsEnabled = true, PlayWander = false, IgnoreSpeedCheck = true,
	        PlaybackInfo = {
	            {Animations = {"Climbing"}, SpeedInfo = {YVelocitySpeed = true, Return = true}}
	        }
	    },
	    {
	        Names = {"Swimming"}, StopTransitionTime = 0.2, PlayTransitionTime = 0.4,
	        Transitions = {}, FootstepsEnabled = true, PlayWander = true, IgnoreSpeedCheck = true,
	        PlaybackInfo = {
	            {
	                Animations = {"Swimming"},
	                WeightInfo = {TransitionTime = 0.15, SpeedChanges = {Subtract = 0, Division = 5}}
	            },
	            {Animations = {"Idle"}, WeightInfo = {TransitionTime = 0.15, ZeroAfterSpeed = 0.5}}
	        }
	    }
	},
}

-- Transition Animation instance attributes (MEASURED from serialized AttributesSerialize).
EVADE.TransitionAttributes = {
	R15 = {
		["Jumping/End"] = { PlayWeightLength = 0.05, Speed = 1.0, StopWeightLength = 0.4 },
		["Moving/End"] = { PlayWeightLength = 0.3, Speed = 1.0, StopWeightLength = 0.5 },
		["Sliding/End"] = { PlayWeightLength = 0.2, Speed = 1.0, StopWeightLength = 0.5 },
	},
	Classic = {
		["Jumping/End"] = { PlayWeightLength = 0.1, Speed = 0.8, StopWeightLength = 0.5 },
		["Moving/End"] = { PlayWeightLength = 0.2, Speed = 1.0, StopWeightLength = 0.5 },
		["Moving_RootStraight/End"] = { PlayWeightLength = 0.2, Speed = 1.0, StopWeightLength = 0.5 },
	},
}

-- Evade's own animation asset IDs (MEASURED). Reference only: Roblox only plays animations in
-- experiences owned by the uploader, so these will NOT play in other games. They are used by
-- REAL mode (inside Evade) to name the tracks it observes, and to list every slot Evade has.
EVADE.AnimationIds = {
	R15 = {
		["Idle/Idle"] = "rbxassetid://129795924166036",
		["Moving/MoveForward"] = "rbxassetid://12447623469",
		["Moving/MoveBackward"] = "rbxassetid://12448032204",
		["Moving/MoveLeft"] = "rbxassetid://12448098021",
		["Moving/MoveRight"] = "rbxassetid://12448138419",
		["Moving/SprintForward"] = "rbxassetid://15106195597",
		["Moving/SprintForwardLeft"] = "rbxassetid://15106196403",
		["Moving/SprintForwardRight"] = "rbxassetid://15106197139",
		["Crouching/Idle"] = "rbxassetid://95125111935172",
		["Crouching/MoveForward"] = "rbxassetid://12309801846",
		["Crouching/MoveBackward"] = "rbxassetid://12309803554",
		["Crouching/MoveLeft"] = "rbxassetid://12309943175",
		["Crouching/MoveRight"] = "rbxassetid://12309987585",
		["Jumping/Jump"] = "rbxassetid://15248598868",
		["Sliding/Slide"] = "rbxassetid://12311697817",
		["WallrunningLeft/SprintForward"] = "rbxassetid://128947555199648",
		["WallrunningRight/SprintForward"] = "rbxassetid://138041445823479",
		["Transitions/Jumping/End"] = "rbxassetid://15091442697",
		["Transitions/Moving/End"] = "rbxassetid://79119378308668",
		["Transitions/Sliding/End"] = "rbxassetid://12311699754",
	},
	Classic = {
		["Idle/Idle"] = "rbxassetid://11544336826",
		["Moving/MoveForward"] = "rbxassetid://17418691532",
		["Moving/MoveBackward"] = "rbxassetid://17418712872",
		["Moving/MoveLeft"] = "rbxassetid://17418770762",
		["Moving/MoveRight"] = "rbxassetid://17418788540",
		["Moving/SprintForward"] = "rbxassetid://17418483149",
		["Moving/SprintForwardLeft"] = "rbxassetid://17418484618",
		["Moving/SprintForwardRight"] = "rbxassetid://17418485963",
		["Crouching/Idle"] = "rbxassetid://17418836643",
		["Crouching/MoveForward"] = "rbxassetid://17418862116",
		["Crouching/MoveBackward"] = "rbxassetid://17418871218",
		["Crouching/MoveLeft"] = "rbxassetid://17418881872",
		["Crouching/MoveRight"] = "rbxassetid://17418893680",
		["Jumping/Jump"] = "rbxassetid://17524391617",
		["Sliding/Slide"] = "rbxassetid://17418821942",
		["WallrunningLeft/SprintForward"] = "rbxassetid://18688623622",
		["WallrunningRight/SprintForward"] = "rbxassetid://18688628477",
		["Transitions/Jumping/End"] = "rbxassetid://18582452487",
		["Transitions/Moving/End"] = "rbxassetid://18582642963",
	},
}

-- Footstep sound tables (MEASURED: Animations/Footsteps/FootstepTypes + MaterialRefersTo).
EVADE.FootstepTypes = {
	    Land = {
	        Asphalt = {13166992034, 13166991938},
	        Brick = {5761648082, 6214472296},
	        Concrete = {
	            {5761648082, 0.2},
	            {6214472296, 0.2}
	        },
	        DiamondPlate = {13166955611},
	        Grass = {
	            {10240342505, 0.3},
	            {10240343126, 0.3},
	            {10240343716, 0.3},
	            {10240344371, 0.3}
	        },
	        Ground = {
	            13166856201, 13166856086, 13166855971, 13166855861
	        },
	        Metal = {13166955611},
	        Water = {
	            12343481838, 12343481897, 12343482104,
	            {12343481984, 0.375},
	            {12343482056, 0.375},
	            {12343482017, 0.375}
	        },
	        Wood = {8310790094},
	        WoodPlanks = {8310790094}
	    },
	    Sprinting = {
	        Asphalt = {
	            13166978744, 13166978465, 13166978678, 13166978802, 13166978539, 13166978241, 13166978135, 13166978623,
	            13166978402, 13166978052
	        },
	        Brick = {
	            13166921617, 13166921176, 13166921024, 13166921671, 13166921566, 13166921521, 13166921471, 13166921413,
	            13166921313, 13166921245, 13166921103
	        },
	        Concrete = {
	            {13166829143, 0.2},
	            {13166828840, 0.2},
	            {13166828529, 0.2},
	            {13166829073, 0.2},
	            {13166829002, 0.2},
	            {13166828619, 0.2},
	            {13166828735, 0.2},
	            {13166828942, 0.2},
	            {13166828785, 0.2},
	            {13166828689, 0.2},
	            {13166828910, 0.2}
	        },
	        DiamondPlate = {
	            13166999099, 13166998537, 13166999029, 13166998984, 13166998842, 13166998908, 13166998783, 13166998717,
	            13166998647, 13166998599
	        },
	        Grass = {
	            10240342505, 10240343126, 10240343716, 10240344371
	        },
	        Ground = {
	            13166845908, 13166846041, 13166845778, 13166845869, 13166845959, 13166845829, 13166845724, 13166845595,
	            13166845670, 13166845533, 13166845431
	        },
	        Marble = {
	            13166938246, 13166937613, 13166937665, 13166938115, 13166938042, 13166937979, 13166937942, 13166937901,
	            13166937848, 13166937788, 13166937732
	        },
	        Metal = {
	            13166958209, 13166957735, 13166957557, 13166958382, 13166958292, 13166958123, 13166957883, 13166958010,
	            13166957803, 13166957645, 13166957681
	        },
	        Sand = {
	            13166860575, 13166860033, 13166859942, 13166860528, 13166860631, 13166860242, 13166860392, 13166860198,
	            13166860337, 13166860465, 13166860105
	        },
	        Snow = {
	            13166869233, 13166869005, 13166868729, 13166869190, 13166869127, 13166868947, 13166868891, 13166869280,
	            13166868820, 13166868691, 13166869065
	        }
	    },
	    Walking = {
	        Asphalt = {
	            13166983583, 13166983016, 13166982929, 13166983532, 13166983459, 13166983387, 13166983240, 13166983317,
	            13166983200, 13166983148, 13166983060
	        },
	        Brick = {
	            13166926485, 13166925441, 13166926283, 13166926576, 13166926373, 13166926174, 13166926069, 13166926011,
	            13166925932, 13166925682, 13166925586
	        },
	        RoofShingles = {
	            13166926485, 13166925441, 13166926283, 13166926576, 13166926373, 13166926174, 13166926069, 13166926011,
	            13166925932, 13166925682, 13166925586
	        },
	        ClayRoofTiles = {
	            13166926485, 13166925441, 13166926283, 13166926576, 13166926373, 13166926174, 13166926069, 13166926011,
	            13166925932, 13166925682, 13166925586
	        },
	        Concrete = {
	            {13166834834, 0.2},
	            {13166834527, 0.2},
	            {13166834709, 0.2},
	            {13166834762, 0.2},
	            {13166834871, 0.2},
	            {13166834643, 0.2},
	            {13166834460, 0.2},
	            {13166834407, 0.2},
	            {13166834592, 0.2},
	            {13166834330, 0.2},
	            {13166834362, 0.2}
	        },
	        DiamondPlate = {
	            13167001895, 13167001757, 13167001801, 13167001535, 13167001709, 13167001643, 13167001846, 13167001485,
	            13167001589
	        },
	        Duct = {
	            12334058868, 12334059191, 12334058902, 12334059241, 12334058984, 12334059089
	        },
	        Fabric = {
	            13166912209, 13166912284, 13166911378, 13166912137, 13166912044, 13166911957, 13166911883, 13166911796,
	            13166911646, 13166911512, 13166911740
	        },
	        Carpet = {
	            13166912209, 13166912284, 13166911378, 13166912137, 13166912044, 13166911957, 13166911883, 13166911796,
	            13166911646, 13166911512, 13166911740
	        },
	        Glass = {
	            12343595337, 12343595466, 12343595373, 12343595402, 12343595492, 12343595528, 12343595563
	        },
	        Grass = {
	            10240342505, 10240343126, 10240343716, 10240344371
	        },
	        Ground = {
	            13166850004, 13166849544, 13166849495, 13166849962, 13166849919, 13166849865, 13166849818, 13166849638,
	            13166849590, 13166849715, 13166849763
	        },
	        Ladder = {
	            12334059297, 12334059485, 12334059427, 12334059549, 12334059582, 12334059650
	        },
	        Marble = {
	            13166943574, 13166943052, 13166942933, 13166943694, 13166943501, 13166943429, 13166943370, 13166943298,
	            13166943257, 13166943203, 13166943125
	        },
	        CeramicTiles = {
	            13166943574, 13166943052, 13166942933, 13166943694, 13166943501, 13166943429, 13166943370, 13166943298,
	            13166943257, 13166943203, 13166943125
	        },
	        Metal = {
	            13166963255, 13166962808, 13166962727, 13166963357, 13166963294, 13166963203, 13166963146, 13166963063,
	            13166962980, 13166962931, 13166962876
	        },
	        Mud = {
	            13167058143, 13167057958, 13167058040, 13167057751, 13167057849, 13167057666
	        },
	        Sand = {
	            13166864285, 13166863915, 13166863854, 13166864217, 13166864149, 13166864093, 13166863952, 13166864361,
	            13166864003, 13166864042, 13166864421
	        },
	        Snow = {
	            13166875036, 13166874752, 13166874676, 13166874936, 13166874989, 13166874896, 13166874504, 13166874854,
	            13166874801, 13166874596, 13166874405
	        },
	        Wade = {
	            12343481838, 12343481897, 12343482104, 12343481984, 12343482056, 12343482017
	        },
	        Water = {
	            12343481950, 12343481518, 12343481604, 12343481569, 12343481771, 12343481670
	        },
	        Wood = {
	            13167032045, 13167031355, 13167031054, 13167031927, 13167031839, 13167031735, 13167031632, 13167031443,
	            13167031525, 13167031244, 13167031144
	        },
	        WoodPlanks = {
	            13167039736, 13167039584, 13167039475, 13167039677, 13167039628, 13167039534, 13167039396, 13167039228,
	            13167039297, 13167039173, 13167039092
	        }
	    },
	    Wander = {
	        Asphalt = {
	            {13166988862, 0.3},
	            {13166988597, 0.3},
	            {13166988759, 0.3}
	        },
	        Brick = {
	            {13166931010, 0.375},
	            {13166930851, 0.375},
	            {13166930954, 0.375},
	            {13166930724, 0.375},
	            {13166931131, 0.375}
	        },
	        Concrete = {
	            13166839903, 13166839689, 13166839818, 13166839739, 13166839623
	        },
	        DiamondPlate = {
	            {13167004572, 0.375},
	            {13167004673, 0.375},
	            {13167004625, 0.375},
	            {13167004479, 0.375}
	        },
	        Grass = {
	            {10240342505, 0.3},
	            {10240343126, 0.3},
	            {10240343716, 0.3},
	            {10240344371, 0.3}
	        },
	        Ground = {
	            {13166856201, 0.375},
	            {13166856086, 0.375},
	            {13166855971, 0.375},
	            {13166855861, 0.375}
	        },
	        Marble = {
	            {13166949171, 0.375},
	            {13166949102, 0.375},
	            {13166949028, 0.375},
	            {13166948970, 0.375},
	            {13166948878, 0.375},
	            {13166948819, 0.375},
	            {13166948735, 0.375}
	        },
	        Metal = {
	            {13166967992, 0.375},
	            {13166968098, 0.375},
	            {13166967916, 0.375},
	            {13166967817, 0.375},
	            {13166967683, 0.375},
	            {13166967564, 0.375}
	        },
	        Mud = {
	            {13167055663, 0.375},
	            {13167055461, 0.375},
	            {13167055572, 0.375},
	            {13167055384, 0.375}
	        },
	        Snow = {
	            {13166879408, 0.375},
	            {13166879210, 0.375},
	            {13166879253, 0.375},
	            {13166879361, 0.375},
	            {13166879308, 0.375}
	        },
	        Wood = {
	            {13167050931, 0.375},
	            {13167050867, 0.375},
	            {13167050994, 0.375},
	            {13167050796, 0.375},
	            {13167050721, 0.375}
	        },
	        WoodPlanks = {
	            {13167050931, 0.375},
	            {13167050867, 0.375},
	            {13167050994, 0.375},
	            {13167050796, 0.375},
	            {13167050721, 0.375}
	        }
	    },
	    Cloth = {
	        13168171180, 13168171127, 13168171044, 13168170809, 13168170717, 13168170625, 13168170877, 13168170933,
	        13168170050, 13168170497, 13168170394, 13168170259, 13168169988, 13168170171, 13168169911, 13168170092
	    }
	}
EVADE.MaterialRefersTo = {
	ForceField = "Glass", Neon = "Glass", Cobblestone = "Asphalt", Plastic = "Concrete", SmoothPlastic = "Concrete",
	Pavement = "Brick", Basalt = "Brick", CorrodedMetal = "Metal", Glacier = "Snow", Granite = "Marble", Ice = "Marble",
	Rock = "Marble", LeafyGrass = "Grass", Pebble = "Asphalt", Sandstone = "Ground", Slate = "Brick", Carpet = "Cloth",
	Rubber = "Cloth", Cardboard = "Marble", CeramicTiles = "Concrete", ClayRoofTiles = "Metal", CrackedLava = "Concrete",
	Leather = "Marble", Limestone = "Concrete", Plaster = "Marble", RoofShingles = "Concrete", Salt = "Sand",
}
-- Sound templates (MEASURED serialized properties).
EVADE.Sounds = {
	Footstep = { Volume = 0.225, RollOffMode = Enum.RollOffMode.InverseTapered, RollOffMinDistance = 10, RollOffMaxDistance = 25 },
	Whoosh = { SoundId = "rbxassetid://12547448228", Volume = 0, Looped = true, RollOffMode = Enum.RollOffMode.Inverse, RollOffMinDistance = 10, RollOffMaxDistance = 10000 },
	Slide = { SoundId = "rbxassetid://13743906533", Volume = 0.15, Looped = true, RollOffMode = Enum.RollOffMode.InverseTapered, RollOffMinDistance = 10, RollOffMaxDistance = 100 },
	DoubleJump = { SoundId = "rbxassetid://6870001835" },
}
-- SlideParticles (MEASURED, StarterCharacter/HumanoidRootPart/Slide/SlideParticles).
EVADE.SlideParticles = {
	Texture = "rbxassetid://4770542473",
	Lifetime = NumberRange.new(0.4, 0.7),
	Speed = NumberRange.new(7, 12),
	Rotation = NumberRange.new(-180, 180),
	RotSpeed = NumberRange.new(0, 0),
	SpreadAngle = Vector2.new(2.5, 7.5),
	Acceleration = Vector3.new(0, -40, 0),
	Drag = 1,
	EmissionDirection = Enum.NormalId.Top,
	LightEmission = 0,
	LightInfluence = 1,
	Size = NumberSequence.new(1.5),
	Squash = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, -0.51) }),
	Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.55, 0.77), NumberSequenceKeypoint.new(1, 1) }),
	ActiveRate = 70,
}

--==============================================================================
-- SECTION 3 : MAPPING LAYER  (edit ONLY these tables to swap assets / remotes)
--==============================================================================

-- AnimationMap: [EvadeSlot] = "file in EvadeClone/Animations/".  Slots are Evade's folder/track names.
-- Evade blends several tracks per state; with one Walk/Run file the same clip fills every directional
-- slot, so the blend weights/speeds still follow Evade's formulas exactly.
-- Evade has NO Fall / Air-strafe-Left / Air-strafe-Right tracks: the single Jumping/Jump track covers the
-- whole airtime, so those files are intentionally not mapped (Evade-exact).
-- Files live in the repo's Animations/ folder (R6 / Evade "Classic" clips) and are auto-downloaded,
-- see CONFIG.AssetDownload.
local AnimationMap = {
	["Idle/Idle"] = "idlefixed_11544336826.rbxm",
	["Moving/MoveForward"] = "clsic_wlkfwrd_17418691532.rbxm",
	["Moving/MoveBackward"] = "clsc_walkbackward_17418712872.rbxm",
	["Moving/MoveLeft"] = "clsic_walkleft_17418770762.rbxm",
	["Moving/MoveRight"] = "clsic_walkright_17418788540.rbxm",
	["Moving/SprintForward"] = "sprntfwrd_classic_17418483149.rbxm",
	["Moving/SprintForwardLeft"] = "sprntleft_classic_17418484618.rbxm",
	["Moving/SprintForwardRight"] = "sprntrght_classic_17418485963.rbxm",
	["Crouching/Idle"] = "clsic_Crouch_17418836643.rbxm",
	["Crouching/MoveForward"] = "clsc_crouchforward_17418862116.rbxm",
	["Crouching/MoveBackward"] = "clsc_crouchbckwrd_17418871218.rbxm",
	["Crouching/MoveLeft"] = "clsc_crouchleft_17418881872.rbxm",
	["Crouching/MoveRight"] = "clsc_crouchright_17418893680.rbxm",
	["Jumping/Jump"] = "r6_jump_17524391617.rbxm",
	["Sliding/Slide"] = "clsic_slide_17418821942.rbxm",
	["WallrunningLeft/SprintForward"] = "wallrun_left_18688623622.rbxm",
	["WallrunningRight/SprintForward"] = "wallrun_right_18688628477.rbxm",
	["Transitions/Jumping/End"] = "r6jumptransition_18582452487.rbxm",
	["Transitions/Moving/End"] = "walktransition_18582642963.rbxm",
	-- Evade slot not supplied by you -> set to a file name to enable, or false to silence the warning.
	["Transitions/Sliding/End"] = false,
	["Transitions/Moving_RootStraight/End"] = false,
}

-- UIMap: element role -> path inside your HUD ScreenGui (UI/HUD.rbxm|.rbxmx).  The defaults are Evade's
-- native paths; if HUD.rbxm is missing or a required role can't be resolved, the native Evade layout
-- is built in code with the same paths.  false = role not present in your HUD.
local UIMap = {
	Root = "HUD/Overlay/CharacterStatus",
	Speed = "HUD/Overlay/CharacterStatus/BottomLeft/Speedometer/Speed",
	SpeedFront = "HUD/Overlay/CharacterStatus/BottomLeft/Speedometer/Front",
	Health = "HUD/Overlay/CharacterStatus/BottomLeft/Health/Health",
	HealthIcon = "HUD/Overlay/CharacterStatus/BottomLeft/Health/HealthIcon",
	HealthStroke = "HUD/Overlay/CharacterStatus/BottomLeft/Health/BackgroundStroke/UIStroke",
	-- Evade's health element has no fill bar. Point this at a Frame in your HUD to drive Size.X = HP/MaxHP.
	HealthFill = false,
}

-- RemoteMap: [EvadeRemoteRole] = path under ReplicatedStorage (or a bare name searched in
-- ReplicatedStorage then Workspace).  false = intentionally unmapped (silent).  Missing remotes are
-- logged once and replaced with no-op stubs; kinematics/UI never depend on them.
local RemoteMap = {
	-- Incoming (Server -> Client), MEASURED Evade paths
	CharacterRegistry = "Remotes/Registry/UpdateCharacterDataRegistry",
	CharacterRegistryUnreliable = "Remotes/Registry/UpdateCharacterDataRegistryUnreliable",
	ServerStateRegistry = "Remotes/Registry/UpdateServerStateRegistry",
	ServerStateRegistryUnreliable = "Remotes/Registry/UpdateServerStateRegistryUnreliable",
	CharacterTask = "Remotes/Character/CharacterTask",
	CharacterAction = "Remotes/Character/Action",
	GenericImpulse = "Remotes/Items/GenericImpulse",
	GameUISetType = "Remotes/UI/GameUISetType",
	-- Generic hooks for the host game (map these to that game's own remotes if it has them):
	HealthUpdate = false, -- first number argument overrides the displayed health
	VelocityCorrection = false, -- first Vector3 argument (studs/s) replaces horizontal velocity
	Respawn = false, -- any fire re-initialises the character modules
	-- Outgoing (Client -> Server), MEASURED Evade paths (used only when OutgoingMode = "Fire")
	RegistryOut = "Remotes/Registry/UpdateCharacterDataRegistry",
	RegistryOutUnreliable = "Remotes/Registry/UpdateCharacterDataRegistryUnreliable",
}

-- SoundMap: optional overrides from EvadeClone/Sounds/.  Footstep overrides are picked up from
-- Sounds/Footsteps/<Land|Sprinting|Walking|Wander>/<Material>/*.ogg|mp3 and Sounds/Footsteps/Cloth/*.
local SoundMap = {
	Whoosh = "Whoosh.ogg",
	Slide = "Slide.ogg",
	DoubleJump = "DoubleJump.ogg",
}

--==============================================================================
-- SECTION 4 : UTILITIES (logging, math, maid, spring)
--==============================================================================
local Log = {}
local warnedKeys = {}
function Log.info(section, msg)
	print(("[EvadeClone][%s] %s"):format(section, msg))
end
function Log.debug(section, msg)
	if CONFIG.Verbose then
		print(("[EvadeClone][%s] %s"):format(section, msg))
	end
end
function Log.warn(section, msg)
	warn(("[EvadeClone][%s] %s"):format(section, msg))
end
function Log.warnOnce(key, section, msg)
	if warnedKeys[key] then
		return
	end
	warnedKeys[key] = true
	Log.warn(section, msg)
end

local function lerp(a, b, t)
	return a + (b - a) * t
end
local function clamp(x, lo, hi)
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end
local function antiNan(x)
	if x == x then
		return x
	end
	return 0
end
local function isFiniteValue(v)
	local t = typeof(v)
	if t == "Vector3" then
		return v.X == v.X and v.Y == v.Y and v.Z == v.Z and math.abs(v.X) < 1e9 and math.abs(v.Y) < 1e9 and math.abs(v.Z) < 1e9
	elseif t == "Vector2" then
		return v.X == v.X and v.Y == v.Y and math.abs(v.X) < 1e9 and math.abs(v.Y) < 1e9
	elseif t == "CFrame" then
		return isFiniteValue(v.Position) and isFiniteValue(v.LookVector)
	elseif t == "number" then
		return v == v and math.abs(v) < 1e9
	end
	return true
end
-- Evade's Movement.sanitize: replaces non-finite leaves with zero of the same type.
local function sanitize(tbl)
	for k, v in tbl do
		if type(v) == "table" then
			sanitize(v)
		elseif not isFiniteValue(v) then
			local t = typeof(v)
			tbl[k] = (t == "Vector3" and Vector3.zero) or (t == "Vector2" and Vector2.zero) or (t == "number" and 0) or nil
		end
	end
end
local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end
local function commaval(n)
	local s = tostring(n)
	while true do
		local k
		s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
		if k == 0 then
			break
		end
	end
	return s
end

-- Maid: owns connections, instances, callbacks; Clean() runs them in reverse order.
local Maid = {}
Maid.__index = Maid
function Maid.new()
	return setmetatable({ _items = {} }, Maid)
end
function Maid:Give(item)
	table.insert(self._items, item)
	return item
end
function Maid:Clean()
	local items = self._items
	self._items = {}
	for i = #items, 1, -1 do
		local item = items[i]
		local t = typeof(item)
		if t == "RBXScriptConnection" then
			pcall(function()
				item:Disconnect()
			end)
		elseif t == "Instance" then
			pcall(function()
				item:Destroy()
			end)
		elseif t == "function" then
			local ok, err = pcall(item)
			if not ok then
				Log.warn("Cleanup", tostring(err))
			end
		elseif type(item) == "table" and type(item.Destroy) == "function" then
			pcall(item.Destroy, item)
		end
	end
end

-- Spring: exact port of ViewmodelDeviation/Spring (analytic damped spring evaluated on the clock,
-- therefore frame-rate independent). Properties: p (position), v (velocity), t (target), s (speed), d (damper).
local Spring = {}
Spring.__index = Spring
local function clockNow()
	return os.clock()
end
function Spring.new(speed, damper)
	return setmetatable({ _p = Vector3.zero, _v = Vector3.zero, _t = Vector3.zero, _s = speed or 1, _d = damper or 1, _t0 = clockNow() }, Spring)
end
function Spring:_pv(now)
	local dt = now - self._t0
	local x = self._p - self._t
	local s, d, v = self._s, self._d, self._v
	if s == 0 then
		return self._p, Vector3.zero
	end
	if d < 1 then
		local c = math.sqrt(1 - d * d)
		local k = (v / s + x * d) / c
		local co, si = math.cos(c * s * dt), math.sin(c * s * dt)
		local e = math.exp(d * s * dt)
		return self._t + (x * co + k * si) / e, ((k * c - x * d) * co - (x * c + k * d) * si) * s / e
	end
	local k = v / s + x
	local e = math.exp(s * dt)
	return self._t + (x + k * (s * dt)) / e, (k - x - k * (s * dt)) * s / e
end
function Spring:GetP()
	local p = self:_pv(clockNow())
	return p
end
function Spring:SetP(value)
	local now = clockNow()
	local _, v = self:_pv(now)
	self._p, self._v, self._t0 = value, v, now
end
function Spring:SetV(value)
	local now = clockNow()
	local p = self:_pv(now)
	self._p, self._v, self._t0 = p, value, now
end
function Spring:SetT(value)
	local now = clockNow()
	self._p, self._v = self:_pv(now)
	self._t, self._t0 = value, now
end
function Spring:SetS(value)
	local now = clockNow()
	self._p, self._v = self:_pv(now)
	self._s, self._t0 = math.max(value, 0), now
end
function Spring:SetD(value)
	local now = clockNow()
	self._p, self._v = self:_pv(now)
	self._d, self._t0 = clamp(value, 0, 1), now
end
function Spring:GetT()
	return self._t
end

--==============================================================================
-- SECTION 5 : CAPABILITIES (startup report; nothing ever hard-errors on a missing function)
--==============================================================================
local Cap = {}
local function resolveGlobal(...)
	for _, name in { ... } do
		local ok, v = pcall(function()
			return GENV[name]
		end)
		if ok and v ~= nil then
			return v
		end
	end
	return nil
end
Cap.getcustomasset = resolveGlobal("getcustomasset", "getsynasset")
Cap.gethui = resolveGlobal("gethui", "get_hidden_gui")
Cap.readfile = resolveGlobal("readfile")
Cap.writefile = resolveGlobal("writefile")
Cap.isfolder = resolveGlobal("isfolder")
Cap.makefolder = resolveGlobal("makefolder")
Cap.isfile = resolveGlobal("isfile")
Cap.listfiles = resolveGlobal("listfiles")
do
	local pg = resolveGlobal("protect_gui", "protectgui")
	if pg == nil then
		local syn = resolveGlobal("syn")
		if type(syn) == "table" and type(syn.protect_gui) == "function" then
			pg = syn.protect_gui
		end
	end
	Cap.protect_gui = pg
end
do
	local ok, fn = pcall(function()
		return game.GetObjects
	end)
	Cap.GetObjects = (ok and type(fn) == "function") and fn or nil
end
do
	local ok, ksp = pcall(function()
		return getService("KeyframeSequenceProvider")
	end)
	Cap.KeyframeSequenceProvider = ok and ksp or nil
end

local function capabilityReport()
	Log.info("Boot", ("EvadeClone v%s  mode=%s"):format(VERSION, CONFIG.Mode))
	local order = { "getcustomasset", "gethui", "readfile", "writefile", "isfolder", "makefolder", "isfile", "listfiles", "protect_gui", "GetObjects" }
	for _, name in order do
		Log.info("Capability", ("%-15s %s"):format(name, Cap[name] and "OK" or "MISSING"))
	end
	Log.info("Capability", ("%-15s %s"):format("KeyframeSeqProv", Cap.KeyframeSequenceProvider and "OK" or "MISSING"))
end

-- Safe wrappers (return nil on failure, never throw).
local function safeCall(fn, ...)
	if type(fn) ~= "function" then
		return false, "missing function"
	end
	return pcall(fn, ...)
end

--==============================================================================
-- SECTION 6 : ASSETS PIPELINE  (EvadeClone/Animations, EvadeClone/UI, EvadeClone/Sounds, EvadeClone/Logs)
--==============================================================================
local Assets = { ObjectCache = {}, Report = {} }

function Assets.Path(...)
	return table.concat({ CONFIG.Root, ... }, "/")
end
function Assets.IsFolder(path)
	local ok, r = safeCall(Cap.isfolder, path)
	return ok and r == true
end
function Assets.IsFile(path)
	local ok, r = safeCall(Cap.isfile, path)
	return ok and r == true
end
function Assets.List(path)
	local ok, r = safeCall(Cap.listfiles, path)
	if ok and type(r) == "table" then
		return r
	end
	return {}
end
function Assets.EnsureFolders()
	for _, sub in { "", "Animations", "UI", "Sounds", "Logs" } do
		local p = sub == "" and CONFIG.Root or Assets.Path(sub)
		if not Assets.IsFolder(p) then
			local ok = safeCall(Cap.makefolder, p)
			Log.debug("Assets", ("makefolder %s -> %s"):format(p, ok and "ok" or "unavailable"))
		end
	end
end
function Assets.ReadFile(path)
	if not Assets.IsFile(path) then
		return nil
	end
	local ok, r = safeCall(Cap.readfile, path)
	if ok and type(r) == "string" then
		return r
	end
	return nil
end
function Assets.WriteFile(path, content)
	local ok, err = safeCall(Cap.writefile, path, content)
	if not ok then
		Log.warnOnce("write:" .. path, "Assets", ("writefile %s failed (%s)"):format(path, tostring(err)))
	end
	return ok
end
-- Fetches every file named in AnimationMap from CONFIG.AssetDownload.BaseUrl into <Root>/Animations/
-- when it isn't there yet, so the getcustomasset pipeline below finds it.
function Assets.DownloadAnimations()
	local cfg = CONFIG.AssetDownload
	if not (cfg and cfg.Enabled) then
		return
	end
	if not Cap.writefile then
		Log.warnOnce("dl:nowrite", "Assets", "writefile missing: cannot auto-download animations")
		return
	end
	local seen, fetched, failed = {}, 0, 0
	for _, fileName in AnimationMap do
		if type(fileName) == "string" and not seen[fileName] then
			seen[fileName] = true
			local path = Assets.Path("Animations", fileName)
			if cfg.Redownload or not Assets.IsFile(path) then
				local url = cfg.BaseUrl .. fileName
				local ok, body = pcall(function()
					return game:HttpGet(url)
				end)
				-- A valid binary .rbxm starts with "<roblox!"; anything else is an error page.
				if ok and type(body) == "string" and string.sub(body, 1, 8) == "<roblox!" then
					if Assets.WriteFile(path, body) then
						fetched += 1
					else
						failed += 1
					end
				else
					failed += 1
					Log.warnOnce("dl:" .. fileName, "Assets", ("download failed: %s (%s)"):format(url, ok and "not an .rbxm" or tostring(body)))
				end
			end
		end
	end
	Log.info("Assets", ("animation download: %d fetched, %d failed"):format(fetched, failed))
end

function Assets.CustomAsset(path)
	if not Assets.IsFile(path) then
		Assets.Report[path] = "missing file"
		return nil
	end
	local ok, id = safeCall(Cap.getcustomasset, path)
	if ok and type(id) == "string" and id ~= "" then
		return id
	end
	Assets.Report[path] = "getcustomasset failed: " .. tostring(id)
	return nil
end

-- getcustomasset -> pcall(game.GetObjects, game, id) ; fallback InsertService:LoadLocalAsset(id).
function Assets.LoadObjects(path)
	if Assets.ObjectCache[path] ~= nil then
		return Assets.ObjectCache[path] or nil
	end
	local id = Assets.CustomAsset(path)
	local objects = nil
	if id then
		if Cap.GetObjects then
			local ok, res = pcall(Cap.GetObjects, game, id)
			if ok and type(res) == "table" and #res > 0 then
				objects = res
			else
				Log.debug("Assets", ("GetObjects(%s) failed: %s"):format(path, tostring(res)))
			end
		end
		if not objects then
			local ok, res = pcall(function()
				return getService("InsertService"):LoadLocalAsset(id)
			end)
			if ok and typeof(res) == "Instance" then
				objects = { res }
			end
		end
	end
	Assets.ObjectCache[path] = objects or false
	Assets.Report[path] = objects and ("loaded " .. #objects .. " root object(s)") or (Assets.Report[path] or "could not deserialize")
	Log.info("Assets", ("%-40s %s"):format(path, Assets.Report[path]))
	return objects
end

function Assets.FindFirstOfClass(objects, className)
	if not objects then
		return nil
	end
	for _, o in objects do
		if o:IsA(className) then
			return o
		end
		local d = o:FindFirstChildWhichIsA(className, true)
		if d then
			return d
		end
	end
	return nil
end

-- Resolves an Animation for one slot. Fallback chain:
--   1. KeyframeSequence in the .rbxm -> KeyframeSequenceProvider:RegisterKeyframeSequence (Studio only)
--   1b. same KeyframeSequence -> built-in KeyframePlayer (live games; drives Motor6D.Transform)
--   2. Animation instance inside the .rbxm (its AnimationId)
--   3. CONFIG.Animation.IdOverrides[slot]
--   -> nil (slot disabled, warned once)
local registeredIdsByFile = {}
function Assets.ResolveAnimation(slot, fileName)
	local path = Assets.Path("Animations", fileName)
	local cached = registeredIdsByFile[path]
	if cached then
		return cached.id, cached.source, cached.ks
	end
	local objects = Assets.LoadObjects(path)
	local ks = Assets.FindFirstOfClass(objects, "KeyframeSequence")
	if ks and Cap.KeyframeSequenceProvider and not Assets.KSPStudioOnly then
		local ok, id = pcall(function()
			return Cap.KeyframeSequenceProvider:RegisterKeyframeSequence(ks)
		end)
		if ok and type(id) == "string" and id ~= "" then
			registeredIdsByFile[path] = { id = id, source = "RegisterKeyframeSequence", ks = ks }
			return id, "RegisterKeyframeSequence", ks
		end
		-- Live servers reject it ("can only be called in Studio"); stop asking after the first refusal.
		if string.find(tostring(id), "Studio", 1, true) then
			Assets.KSPStudioOnly = true
			Log.info("Assets", "RegisterKeyframeSequence is Studio-only here; using the built-in keyframe player")
		else
			Log.warnOnce("ksp:" .. path, "Assets", ("RegisterKeyframeSequence failed for %s (%s); trying fallbacks"):format(fileName, tostring(id)))
		end
	end
	-- Play the KeyframeSequence ourselves by driving Motor6D.Transform (see KeyframePlayer).
	if ks then
		registeredIdsByFile[path] = { id = "keyframes", source = "KeyframePlayer", ks = ks }
		return "keyframes", "KeyframePlayer", ks
	end
	local anim = Assets.FindFirstOfClass(objects, "Animation")
	if anim and anim.AnimationId ~= "" then
		registeredIdsByFile[path] = { id = anim.AnimationId, source = "rbxm Animation.AnimationId" }
		return anim.AnimationId, "rbxm Animation.AnimationId", nil
	end
	local override = CONFIG.Animation.IdOverrides[slot]
	if type(override) == "string" and override ~= "" then
		return override, "IdOverrides", nil
	end
	return nil, "unresolved", nil
end

-- Reads Logs/evade_tracks.csv (written by REAL mode inside Evade) to learn Evade's track lengths.
function Assets.LoadEvadeTrackLengths()
	local text = Assets.ReadFile(Assets.Path("Logs", "evade_tracks.csv"))
	if not text then
		return 0
	end
	local n = 0
	for line in string.gmatch(text, "[^\r\n]+") do
		local slot, _, length = string.match(line, "^([^,]+),([^,]*),([%d%.]+)")
		if slot and slot ~= "slot" and tonumber(length) and tonumber(length) > 0 and CONFIG.Animation.EvadeLengths[slot] == nil then
			CONFIG.Animation.EvadeLengths[slot] = tonumber(length)
			n += 1
		end
	end
	Log.info("Assets", ("loaded %d Evade track lengths from Logs/evade_tracks.csv"):format(n))
	return n
end

-- Sound id: Sounds/<file> via getcustomasset, else Evade's id.
function Assets.SoundId(role, evadeId)
	local file = SoundMap[role]
	if type(file) == "string" then
		local id = Assets.CustomAsset(Assets.Path("Sounds", file))
		if id then
			return id
		end
	end
	return evadeId
end

-- Footstep overrides from Sounds/Footsteps/<Kind>/<Material>/*  (kind folders mirror Evade's tables).
function Assets.LoadFootstepOverrides()
	local overrides = {}
	local base = Assets.Path("Sounds", "Footsteps")
	if not Assets.IsFolder(base) then
		return overrides
	end
	local function collect(folder)
		local ids = {}
		for _, f in Assets.List(folder) do
			if string.match(string.lower(f), "%.ogg$") or string.match(string.lower(f), "%.mp3$") or string.match(string.lower(f), "%.wav$") then
				local ok, id = safeCall(Cap.getcustomasset, f)
				if ok and type(id) == "string" then
					table.insert(ids, id)
				end
			end
		end
		return ids
	end
	for _, kind in { "Land", "Sprinting", "Walking", "Wander" } do
		local kp = base .. "/" .. kind
		if Assets.IsFolder(kp) then
			overrides[kind] = {}
			for _, matFolder in Assets.List(kp) do
				if Assets.IsFolder(matFolder) then
					local mat = string.match(matFolder, "([^/\\]+)$")
					local ids = collect(matFolder)
					if #ids > 0 then
						overrides[kind][mat] = ids
					end
				end
			end
		end
	end
	local cloth = collect(base .. "/Cloth")
	if #cloth > 0 then
		overrides.Cloth = cloth
	end
	return overrides
end

--==============================================================================
-- SECTION 7 : INPUT (move vector via PlayerModule ControlModule, WASD fallback)
--==============================================================================
local Input = { Controls = nil }
function Input.Init()
	local ok, controls = pcall(function()
		local ps = LocalPlayer:WaitForChild("PlayerScripts", 5)
		local pm = ps and ps:WaitForChild("PlayerModule", 5)
		if not pm then
			return nil
		end
		local module = require(pm)
		return module:GetControls()
	end)
	if ok and controls then
		Input.Controls = controls
		Log.info("Input", "ControlModule move vector: OK")
	else
		Log.warn("Input", "ControlModule unavailable; using keyboard/gamepad fallback move vector")
	end
end
function Input.GetMoveVector()
	if Input.Controls then
		local ok, v = pcall(Input.Controls.GetMoveVector, Input.Controls)
		if ok and typeof(v) == "Vector3" then
			return v
		end
	end
	-- Fallback: camera-relative vector, -Z forward (same convention as ControlModule).
	if UserInputService:GetFocusedTextBox() then
		return Vector3.zero
	end
	local x, z = 0, 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		z -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		z += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		x -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		x += 1
	end
	local v = Vector3.new(x, 0, z)
	for _, pad in UserInputService:GetConnectedGamepads() do
		for _, st in UserInputService:GetGamepadState(pad) do
			if st.KeyCode == Enum.KeyCode.Thumbstick1 and st.Position.Magnitude > 0.2 then
				v = Vector3.new(st.Position.X, 0, -st.Position.Y)
			end
		end
	end
	if v.Magnitude > 1 then
		v = v.Unit
	end
	return v
end

--==============================================================================
-- SECTION 8 : REMOTES (identify / map / mirror; listen-only by default)
--==============================================================================
local Remotes = { Resolved = {}, Counters = { In = {}, Out = {} }, Handlers = {}, Queue = {}, LastFlush = 0 }
local REMOTE_DIRECTION = {
	CharacterRegistry = "In", CharacterRegistryUnreliable = "In", ServerStateRegistry = "In",
	ServerStateRegistryUnreliable = "In", CharacterTask = "In", CharacterAction = "In", GenericImpulse = "In",
	GameUISetType = "In", HealthUpdate = "In", VelocityCorrection = "In", Respawn = "In",
	RegistryOut = "Out", RegistryOutUnreliable = "Out",
}
local function isRemote(inst)
	return typeof(inst) == "Instance" and (inst:IsA("RemoteEvent") or inst:IsA("UnreliableRemoteEvent") or inst:IsA("RemoteFunction"))
end
function Remotes.Find(target)
	if type(target) ~= "string" or target == "" then
		return nil
	end
	local node = ReplicatedStorage
	for part in string.gmatch(target, "[^/]+") do
		node = node and node:FindFirstChild(part)
	end
	if isRemote(node) then
		return node
	end
	local name = string.match(target, "([^/]+)$")
	for _, root in { ReplicatedStorage, workspace } do
		local found = root:FindFirstChild(name, true)
		if isRemote(found) then
			return found
		end
	end
	return nil
end
function Remotes.Init(maid)
	for role, dir in REMOTE_DIRECTION do
		Remotes.Counters[dir][role] = 0
		local target = RemoteMap[role]
		if target == false then
			Log.debug("Remotes", role .. ": unmapped (silent)")
		elseif target == nil then
			Log.warnOnce("remote-unmapped:" .. role, "Remotes", role .. ": no RemoteMap entry; stubbed")
		else
			local remote = Remotes.Find(target)
			Remotes.Resolved[role] = remote
			if not remote then
				Log.info("Remotes", ("%-30s MISSING (%s) -> no-op stub"):format(role, target))
			else
				Log.info("Remotes", ("%-30s OK  %s [%s]"):format(role, remote:GetFullName(), remote.ClassName))
				if dir == "In" and (remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent")) then
					maid:Give(remote.OnClientEvent:Connect(function(...)
						Remotes.Counters.In[role] += 1
						local handler = Remotes.Handlers[role]
						if handler then
							local ok, err = pcall(handler, ...)
							if not ok then
								Log.warnOnce("remote-handler:" .. role, "Remotes", role .. " handler error: " .. tostring(err))
							end
						end
					end))
				end
			end
		end
	end
end
-- Outgoing mirror: Registry terms marked sendable are queued and flushed every FlushPeriod (10 Hz),
-- exactly like DataRegistry:UpdateCycle. "Count" never touches the network.
function Remotes.QueueTerm(term, value)
	local channel = CONFIG.Remotes.SendableTerms[term]
	if not channel then
		return
	end
	Remotes.Queue[channel] = Remotes.Queue[channel] or {}
	Remotes.Queue[channel][term] = value
end
function Remotes.Flush()
	local now = os.clock()
	if now - Remotes.LastFlush < CONFIG.Remotes.FlushPeriod then
		return
	end
	Remotes.LastFlush = now
	for channel, payload in Remotes.Queue do
		local role = channel == "Reliable" and "RegistryOut" or "RegistryOutUnreliable"
		Remotes.Counters.Out[role] += 1
		if CONFIG.Remotes.OutgoingMode == "Fire" then
			local remote = Remotes.Resolved[role]
			if remote and (remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent")) then
				local ok, err = pcall(remote.FireServer, remote, payload)
				if not ok then
					Log.warnOnce("fire:" .. role, "Remotes", role .. " FireServer failed: " .. tostring(err))
				end
			end
		end
	end
	table.clear(Remotes.Queue)
end
function Remotes.TotalFires()
	local i, o = 0, 0
	for _, n in Remotes.Counters.In do
		i += n
	end
	for _, n in Remotes.Counters.Out do
		o += n
	end
	return i, o
end

--==============================================================================
-- SECTION 9 : CHARACTER CONTEXT + REGISTRY (Evade DataRegistry)
--==============================================================================
-- Registry.Set fires TermUpdated(name, value) on change, like DataRegistry:SetTerm ->
-- Character:RegistryTermUpdated + GameUIService:CharacterRegistryTermUpdated.
local Registry = {}
Registry.__index = Registry
function Registry.new(onChanged)
	return setmetatable({ Data = {}, OnChanged = onChanged }, Registry)
end
function Registry:Get(k)
	return self.Data[k]
end
function Registry:Set(k, v)
	if self.Data[k] == v then
		return
	end
	self.Data[k] = v
	Remotes.QueueTerm(k, v)
	if self.OnChanged then
		self.OnChanged(k, v)
	end
end

-- Builds a RaycastParams excluding every player character and the camera (Evade excludes
-- workspace.Players / Rigs / Effects / CurrentCamera / Map.Ignore).
local function buildExcludeList(character)
	local list = { workspace.CurrentCamera }
	if character then
		table.insert(list, character)
	end
	for _, p in Players:GetPlayers() do
		if p.Character and p.Character ~= character then
			table.insert(list, p.Character)
		end
	end
	return list
end

--==============================================================================
-- SECTION 10 : MOVEMENT ENGINE  (Terms -> State -> MoveFunction -> Constraints -> Orienter)
--==============================================================================
local Movement = {}
Movement.__index = Movement

local GROUND_OFFSETS = { Vector3.zero, Vector3.new(0.5, 0, 0), Vector3.new(-0.5, 0, 0), Vector3.new(0, 0, 0.5), Vector3.new(0, 0, -0.5) }
local UP = Vector3.new(0, 1, 0)

function Movement.new(ctx)
	local self = setmetatable({
		Ctx = ctx,
		R = ctx.Registry,
		Humanoid = ctx.Humanoid,
		Root = ctx.Root,
		Character = ctx.Character,
		Disabled = false,
		JumpAmount = 0,
		CanJump = true,
		JumpHeldDown = false,
		XboxJumping = false,
		State = nil,
		Stats = table.clone(CONFIG.Movement),
		SpeedChanges = {},
		DisableSprinting = false,
		JumpCount = 0,
	}, Movement)
	self.Stats.BaseSpeed = self.Stats.Speed
	self.Stats.BaseSprintCap = self.Stats.SprintCap
	return self
end

-- Effective gravity for this character (Evade's 50 unless CONFIG.Movement.Gravity is nil).
function Movement:Gravity()
	return self.Stats.Gravity or workspace.Gravity
end

-- Humanoid derives jump speed from workspace.Gravity, so with a custom gravity give it the
-- equivalent JumpPower: v = sqrt(2 * g * h).
function Movement:SetJumpHeight(h)
	local hum = self.Humanoid
	if self.Stats.Gravity then
		hum.UseJumpPower = true
		hum.JumpPower = math.sqrt(2 * self.Stats.Gravity * h)
	else
		hum.UseJumpPower = false
		hum.JumpHeight = h
	end
end

function Movement:UpdateGravityComp()
	local gc = self.GravityComp
	if gc and self.Stats.Gravity then
		gc.Force = Vector3.new(0, self.Root.AssemblyMass * (workspace.Gravity - self.Stats.Gravity), 0)
	end
end

-- ---------- Init: humanoid state, constraints (Constraints.Init), registry defaults ----------
function Movement:Init(maid)
	local hum, root = self.Humanoid, self.Root
	for _, st in self.Stats.DisableHumanoidStates do
		pcall(hum.SetStateEnabled, hum, st, false)
	end
	pcall(function()
		self:SetJumpHeight(self.Stats.JumpHeight)
		hum.WalkSpeed = 0 -- MEASURED: StarterPlayer.CharacterWalkSpeed = 0
		hum.AutoRotate = false -- root yaw is driven by RootPartOrienter every frame
	end)

	local att = Instance.new("Attachment")
	att.Name = hiddenName()
	att.Parent = root
	maid:Give(att)

	-- BaseMover: LinearVelocity, Plane mode, X/Z tangents, MaxForce 100000 (MEASURED Constraints.Init).
	local lv = Instance.new("LinearVelocity")
	lv.Name = hiddenName()
	lv.Attachment0 = att
	lv.MaxForce = self.Stats.LinearVelocityMaxForce
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	lv.PrimaryTangentAxis = Vector3.new(1, 0, 0)
	lv.SecondaryTangentAxis = Vector3.new(0, 0, 1)
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.PlaneVelocity = Vector2.zero
	lv.Enabled = false
	lv.Parent = root
	maid:Give(lv)

	-- WallrunForce: VectorForce, world-relative (MEASURED).
	local vf = Instance.new("VectorForce")
	vf.Name = hiddenName()
	vf.Attachment0 = att
	vf.RelativeTo = Enum.ActuatorRelativeTo.World
	vf.Force = Vector3.zero
	vf.Enabled = false
	vf.Parent = root
	maid:Give(vf)

	-- GravityComp: lifts the character by (game gravity - Evade gravity) so it falls like in Evade.
	local gc = Instance.new("VectorForce")
	gc.Name = hiddenName()
	gc.Attachment0 = att
	gc.RelativeTo = Enum.ActuatorRelativeTo.World
	gc.ApplyAtCenterOfMass = true
	gc.Force = Vector3.zero
	gc.Enabled = self.Stats.Gravity ~= nil
	gc.Parent = root
	maid:Give(gc)

	self.Constraints = { BaseMover = lv, WallrunForce = vf }
	self.GravityComp = gc

	self.GroundParams = RaycastParams.new()
	self.GroundParams.FilterType = Enum.RaycastFilterType.Exclude
	self.GroundParams.IgnoreWater = true
	self.GroundParams.RespectCanCollide = true
	self.WallrunParams = RaycastParams.new()
	self.WallrunParams.FilterType = Enum.RaycastFilterType.Exclude
	self.WallrunParams.IgnoreWater = true
	self.WallrunParams.RespectCanCollide = true
	self:RefreshFilters()

	local R = self.R
	R:Set("Velocity", Vector3.zero)
	R:Set("Sprint", 1)
	R:Set("Speed", 0)
	R:Set("RelativeSpeed", 0)
	R:Set("Grounded", false)
	R:Set("Crouching", false)
	R:Set("CrouchKey", false)
	R:Set("MoveDirection", Vector3.zero)
	R:Set("GlobalMoveDirection", Vector3.zero)
	R:Set("RelativeMoveDirection", Vector3.zero)
	R:Set("WallrunDirection", 0)
	R:Set("IgnoreXMove", 0)
	self:UpdateAttributes()
end

function Movement:RefreshFilters()
	local list = buildExcludeList(self.Character)
	self.GroundParams.FilterDescendantsInstances = list
	self.WallrunParams.FilterDescendantsInstances = list
	self.ExcludeList = list
end

-- ---------- MoveStats (SpeedChange / DisableSprint / UpdateAttributes) ----------
function Movement:UpdateAttributes()
	local s = self.Stats
	s.SprintCap = self.DisableSprinting and 1 or s.BaseSprintCap
	local speed = s.BaseSpeed
	for _, m in self.SpeedChanges do
		speed *= m
	end
	s.Speed = speed
end
function Movement:SpeedChange(key, value)
	if self.SpeedChanges[key] == value then
		return
	end
	self.SpeedChanges[key] = value
	self:UpdateAttributes()
end
function Movement:DisableSprint(v)
	if self.DisableSprinting == v then
		return
	end
	self.DisableSprinting = v
	self:UpdateAttributes()
end

-- ---------- Terms (Movement/Terms CalculateFunctions, evaluated in Evade's order) ----------
function Movement:CalcGrounded()
	local stats = self.Stats
	local center = self.Ctx:HullCenter()
	local len = -stats.GroundedDistCheck * self.Ctx.SizeScale
	local hullX = CONFIG.Hull.StandSize.X * self.Ctx.SizeScale
	for _, o in GROUND_OFFSETS do
		local hit = workspace:Raycast(center + o * hullX, Vector3.new(0, len, 0), self.GroundParams)
		if hit then
			return true
		end
	end
	return false
end
function Movement:CalcMoveDirection()
	local mv = Input.GetMoveVector()
	if os.clock() - (self.R:Get("IgnoreXMove") or 0) <= self.Stats.IgnoreXMoveTime then
		mv = mv * Vector3.new(0, 1, 1)
	end
	return mv
end
function Movement:CalcWallrunDirection()
	local R = self.R
	if R:Get("Grounded") or os.clock() - (R:Get("IgnoreXMove") or 0) <= 0.2 then
		return 0
	end
	local md = R:Get("MoveDirection")
	if md.X == 0 then
		return nil -- MEASURED quirk: bare return -> requirement fails
	end
	local root = self.Root
	local origin = self.Ctx:HullCenter()
	local reach = CONFIG.Hull.StandSize.X * self.Ctx.SizeScale / 2 + self.Stats.WallrunCheckExtra
	local function wallAt(sign)
		local hit = workspace:Raycast(origin, root.CFrame.RightVector * (reach * sign), self.WallrunParams)
		if hit then
			local deg = math.deg(math.acos(clamp(hit.Normal:Dot(UP), -1, 1)))
			if deg >= self.Stats.WallrunNormalMinDeg and deg <= self.Stats.WallrunNormalMaxDeg then
				return hit.Normal
			end
		end
		return nil
	end
	if md.X > 0 then
		local n = wallAt(1)
		if n then
			R:Set("WallrunDir", n)
			return -1
		end
	end
	if md.X < 0 then
		local n = wallAt(-1)
		if n then
			R:Set("WallrunDir", n)
			return 1
		end
	end
	return 0
end
function Movement:UpdateTerms()
	local R = self.R
	if self.Disabled then
		R:Set("Grounded", false)
		R:Set("MoveDirection", Vector3.zero)
		R:Set("GlobalMoveDirection", Vector3.zero)
		R:Set("Crouching", false)
		R:Set("WallrunDirection", 0)
		return
	end
	R:Set("Grounded", self:CalcGrounded())
	R:Set("MoveDirection", self:CalcMoveDirection())
	R:Set("GlobalMoveDirection", R:Get("LookCFrame"):VectorToWorldSpace(R:Get("MoveDirection")))
	-- Gyro / LookY: replicated look terms (MEASURED formulas) — mirrored for the outgoing queue.
	local look = R:Get("LookCFrame").LookVector
	local flatLook = flat(look)
	if flatLook.Magnitude > 1e-4 then
		local angle = math.atan2(look:Cross(flatLook.Unit).Magnitude, look:Dot(flatLook.Unit))
		local sign = math.sign(self.Root.CFrame.LookVector:Cross(look).Y)
		R:Set("Gyro", math.floor((1 + angle * (sign / math.pi)) * 100 + 0.5) / 100)
	end
	R:Set("LookY", math.floor(math.asin(clamp(look.Y, -1, 1)) * 40 + 0.5) / 40)
	R:Set("Crouching", R:Get("CrouchKey") == true)
	R:Set("WallrunDirection", self:CalcWallrunDirection())
end

-- ---------- Helpers (MoveFunction/Functions/Helpers) ----------
function Movement:ApplyFriction(dt, info, k)
	local stats = self.Stats
	local V = self.R:Get("Velocity")
	local speed = V.Magnitude
	local runDeaccel, friction = stats.RunDeaccel, stats.Friction
	if info.Swimming == true then
		runDeaccel *= 0.6
		friction *= 0.6
	end
	local control = (speed < runDeaccel) and runDeaccel or speed
	local drop = control * friction * dt * k
	local newSpeed = speed - drop
	if newSpeed < 0 then
		newSpeed = 0
	end
	if speed > 0 then
		newSpeed /= speed
	end
	return V * newSpeed
end
local function accelerate(V, wishdir, wishspeed, accel, dt, swimming)
	if swimming == true then
		accel *= 0.4
		wishspeed *= 1.3
	end
	local add = wishspeed - V:Dot(wishdir)
	if add <= 0 then
		return V
	end
	local accelSpeed = accel * dt * wishspeed
	return V + ((add < accelSpeed) and add or accelSpeed) * wishdir
end
Movement.Accelerate = accelerate
local function airControl(_wishdir, wishspeed, md, V, _dt)
	if math.abs(md.Z) < 0.001 or math.abs(wishspeed) < 0.001 then
		return V
	end
	local mag = V.Magnitude
	if mag < 0.0001 then
		return V * Vector3.new(1, 0, 1)
	end
	return V.Unit * Vector3.new(mag, 0, mag)
end
Movement.AirControl = airControl

-- WallImpact (client branch): blockcast + two +-45 deg rays, then project velocity off every wall
-- normal steeper than 60 deg. Door-breaking (testInteraction) is Evade-map specific and omitted.
function Movement:WallImpact(V)
	local root = self.Root
	if not root or V.Magnitude ~= V.Magnitude or V.Magnitude == math.huge then
		return V
	end
	if V.Magnitude <= 0.01 then
		return V
	end
	local normals = {}
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter = table.clone(self.ExcludeList)
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true
	params.CollisionGroup = root.CollisionGroup
	local size = self.Ctx:HullSize()
	local rot = root.CFrame - root.CFrame.Position
	local hullCF = CFrame.new(self.Ctx:HullCenter()) * rot
	local dir = CFrame.lookAt(Vector3.zero, V).LookVector
	local minAngle = math.rad(self.Stats.WallSlideMinDeg)

	local hit
	for _ = 1, 16 do
		hit = workspace:Blockcast(hullCF * CFrame.new(0, size.Y * 0.1 * 0.5, 0), size * Vector3.new(1, 0.1, 1), dir * size.X * 1.01 * 0.5, params)
		if hit and hit.Instance and not hit.Instance.CanCollide then
			table.insert(filter, hit.Instance)
			params.FilterDescendantsInstances = filter
			continue
		end
		break
	end
	if hit and math.acos(clamp(hit.Normal:Dot(UP), -1, 1)) >= minAngle then
		table.insert(normals, hit.Normal)
	end
	local function smallcast(angleDeg)
		local origin = (hullCF * CFrame.new(0, size.Y / 3, 0)).Position
		local look = (CFrame.lookAt(Vector3.zero, V) * CFrame.Angles(0, math.rad(angleDeg), 0)).LookVector
		local r
		for _ = 1, 16 do
			r = workspace:Raycast(origin, look * size.X * 1.01, params)
			if r and r.Instance and not r.Instance.CanCollide then
				table.insert(filter, r.Instance)
				params.FilterDescendantsInstances = filter
				continue
			end
			break
		end
		if r and math.acos(clamp(r.Normal:Dot(UP), -1, 1)) >= minAngle then
			table.insert(normals, r.Normal)
		end
	end
	smallcast(-45)
	smallcast(45)
	for _, n in normals do
		local a = math.atan2(n.Z, n.X)
		local rotated = CFrame.fromAxisAngle(UP, a):VectorToWorldSpace(V) * Vector3.new(0, 0, 1)
		V = CFrame.fromAxisAngle(UP, -a):VectorToWorldSpace(rotated)
	end
	return V
end

-- ---------- MoveFunctions (Run / Air / Slide) ----------
local MoveFunctions = {}
function MoveFunctions.Run(self, dt, info)
	local R, stats = self.R, self.Stats
	local jumpingActive = R:Get("JumpingActive")
	local md = R:Get("MoveDirection")
	local wishdir = R:Get("GlobalMoveDirection")
	if not info.Swimming then
		wishdir = flat(wishdir)
	end
	if (stats.BhopEnabled and jumpingActive) or R:Get("JumpQueued") == true then
		return nil
	end
	local sprint = R:Get("Sprint") or 1
	local V = self:ApplyFriction(dt, info, 1)
	if wishdir ~= Vector3.zero then
		wishdir = wishdir.Unit
		if info.Swimming ~= true and md.Z < 0 and info.CapSprint ~= true and R:Get("ADS") ~= true then
			sprint = clamp(sprint + 0.5 * stats.SprintAcceleration * dt, 1, stats.SprintCap or 2)
		else
			sprint = 1
		end
	else
		sprint = 1
	end
	local mult = sprint
	if stats.WalkSpeedMultiplier then
		mult = lerp(sprint, stats.SprintCap, stats.WalkSpeedMultiplier - 1)
	end
	local wishspeed = wishdir.Magnitude * stats.Speed * mult
	V = accelerate(V, wishdir, wishspeed, 12 * stats.RunAccel, dt, info.Swimming)
	V = self:WallImpact(V)
	local outSprint = info.CapSprint and 1 or sprint
	return { BaseMover = { PlaneVelocity = Vector2.new(V.X, V.Z) } }, { Sprint = outSprint, Velocity = V }
end
function MoveFunctions.Air(self, dt, info)
	local R, stats = self.R, self.Stats
	local V = R:Get("Velocity")
	local md = R:Get("MoveDirection")
	if md.Z < 0 then
		md = md * Vector3.new(1, 1, 0) -- forward input ignored in the air (MEASURED)
	end
	if md.Z > 0 then
		V = self:ApplyFriction(dt, info, 1) -- back input brakes in the air (MEASURED)
	end
	local wd = R:Get("WallrunDirection")
	if info.Wallrunning and wd then
		if wd <= -0.99 then
			if md.X > 0 then
				md = md * Vector3.new(0, 0, 1)
			end
		elseif wd >= 0.99 and md.X < 0 then
			md = md * Vector3.new(0, 0, 1)
		end
		if md.Z < 0 then
			md = md * Vector3.new(1, 0, 0)
		end
	end
	local wish = R:Get("LookCFrame"):VectorToWorldSpace(md)
	local wishspeed = wish.Magnitude * stats.Speed
	if wish ~= Vector3.zero then
		wish = wish.Unit
	end
	local rawWishspeed = wishspeed
	local accel = (V:Dot(wish) < 0) and stats.AirAcceleration or stats.AirAcceleration * 2
	if md.Z == 0 and md.X ~= 0 then
		if stats.AirStrafeAcceleration < wishspeed then
			wishspeed = stats.AirStrafeAcceleration
		end
		accel = stats.AirStrafeAcceleration
	end
	V = accelerate(V, wish, wishspeed, accel, dt, info.Swimming)
	V = airControl(wish, rawWishspeed, md, V, dt)
	local sprint = R:Get("Velocity").Magnitude / (stats.Speed * 2) * 2
	V = self:WallImpact(V)
	local constraints = { BaseMover = { PlaneVelocity = Vector2.new(V.X, V.Z) } }
	if info.Wallrunning then
		constraints.WallrunForce = { Force = Vector3.new(0, self.Root.AssemblyMass * self:Gravity() * 0.5, 0) }
	end
	return constraints, { Sprint = antiNan(clamp(sprint, 1, stats.SprintCap or 2)), Velocity = V }
end
function MoveFunctions.Slide(self, dt, info)
	local R, stats = self.R, self.Stats
	local V = self:ApplyFriction(dt, info, stats.SlideFriction)
	local md = R:Get("MoveDirection")
	if md.Z < 0 then
		md = md * Vector3.new(1, 1, 0)
	end
	local wish = flat(R:Get("LookCFrame"):VectorToWorldSpace(md))
	local currentSpeed = R:Get("Velocity").Magnitude
	local wishspeed = wish.Magnitude * currentSpeed
	if wish ~= Vector3.zero then
		wish = wish.Unit
	end
	local rawWishspeed = wishspeed
	local accel = (R:Get("Velocity"):Dot(wish) < 0) and stats.AirAcceleration or stats.AirAcceleration * 2
	local mdX = Vector3.new(md.X, 0, 0)
	if mdX.Z == 0 and mdX.X ~= 0 then
		if stats.AirStrafeAcceleration < wishspeed then
			wishspeed = stats.AirStrafeAcceleration
		end
		accel = stats.AirStrafeAcceleration
	end
	V = accelerate(V, wish, wishspeed, accel, dt)
	V = airControl(wish, rawWishspeed, R:Get("MoveDirection"), V, dt)
	-- Slope term: surface normal in root object space; downhill (normal.Z < 0) speeds up.
	local hit = workspace:Raycast(self.Ctx:HullCenter(), Vector3.new(0, -stats.SlideSlopeRayLength, 0), self.GroundParams)
	local normal = hit and hit.Normal or Vector3.zero
	local nObj = self.Root.CFrame:VectorToObjectSpace(normal)
	if V.Magnitude > 0.0001 then
		V = V.Unit * clamp(V.Magnitude - nObj.Z * dt * stats.SlideSlopeGain, 0, stats.SlideMaxSpeed)
	end
	V = self:WallImpact(V)
	return { BaseMover = { PlaneVelocity = Vector2.new(V.X, V.Z) } },
		{ Sprint = antiNan(clamp(V.Magnitude / (stats.Speed * 2) * 2, 1, stats.SprintCap or 2)), Velocity = V }
end
Movement.MoveFunctions = MoveFunctions

-- ---------- State machine (Character/State FindBestState + SetState) ----------
local Requirement = {
	Grounded = function(R, want)
		return R:Get("Grounded") == want
	end,
	Crouching = function(R, want)
		local c = R:Get("Crouching")
		if c == nil then
			R:Set("Crouching", false)
			c = false
		end
		return c == want
	end,
	RelativeSpeedTest = function(R, test)
		if test[1] == "<" then
			return (R:Get("RelativeSpeed") or 0) < test[2]
		end
		return test[2] <= (R:Get("RelativeSpeed") or 0)
	end,
	WallrunDirection = function(R, want)
		local w = R:Get("WallrunDirection")
		if w == nil or (w ~= -1 and w ~= 1) then
			return nil
		end
		return w == want
	end,
}
function Movement:FindBestState()
	local bestState, bestPriority
	for _, s in EVADE.States do
		if bestPriority and s.Priority <= bestPriority then
			continue
		end
		local ok = true
		for key, want in s.Requirements do
			local fn = Requirement[key]
			if not fn then
				Log.warnOnce("req:" .. key, "State", key .. " wasn't found in state requirements")
				continue
			end
			if fn(self.R, want) ~= true then
				ok = false
				break
			end
		end
		if ok and (bestPriority == nil or bestPriority < s.Priority) then
			bestState, bestPriority = s.State, s.Priority
		end
	end
	return bestState
end

-- State:SetState + State:Update (root-size goal, RootDelay) — adapted to the emulated hull.
function Movement:StateUpdate(dt)
	local ctx = self.Ctx
	if ctx.RootSizeGoal and (not ctx.RootDelay or ctx.RootDelay < os.clock()) then
		local alpha = clamp(dt * CONFIG.Hull.ResizeRate, 0, 1)
		ctx.RootSize = ctx.RootSize:Lerp(ctx.RootSizeGoal * ctx.SizeScale, alpha)
		if math.abs((ctx.RootSize - ctx.RootSizeGoal * ctx.SizeScale).Y) <= CONFIG.Hull.SnapEpsilon then
			ctx.RootSize = ctx.RootSizeGoal * ctx.SizeScale
			ctx.RootSizeGoal = nil
		end
	end
	local best = self.Disabled and "Inert" or (self:FindBestState() or "Inert")
	if self.R:Get("State") ~= best then
		local info = EVADE.StateByName[best]
		ctx.RootSizeGoal = info.RootSize or CONFIG.Hull.StandSize
		ctx.RootDelay = info.RootDelay and (os.clock() + info.RootDelay) or nil
		self.R:Set("ViewmodelAnimationType", info.ViewmodelAnimationType or 0)
		self.R:Set("State", best)
	end
end

-- Movement:SetState: speed modifiers, sprint disable, constraint enabling.
function Movement:SetState(name)
	if self.State == name then
		return
	end
	local info = EVADE.StateByName[name] or EVADE.StateByName.Inert
	local mv = info.Movement
	if mv then
		self:SpeedChange("State", mv.SpeedMult)
		self:DisableSprint(mv.DisableSprinting == true)
	else
		self:SpeedChange("State", nil)
		self:DisableSprint(false)
	end
	self.State = name
	for _, c in self.Constraints do
		c.Enabled = false
	end
	if name ~= "Inert" and mv and mv.Constraints then
		for _, id in mv.Constraints do
			if self.Constraints[id] then
				self.Constraints[id].Enabled = true
			end
		end
	end
end

-- ---------- Jump (JumpReact / AttemptJump / testMultipleJumps / Jump / UpdateCanJump) ----------
function Movement:UpdateCanJump()
	local hum = self.Humanoid
	if self.Disabled or hum.Health <= 0 or self.CanJump == false then
		hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		return
	end
	local info = EVADE.StateByName[self.State or "Inert"]
	if not info or not info.Movement then
		return
	end
	hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, info.Movement.CanJump ~= false)
end
function Movement:JumpReact(fromGamepad)
	if self.CanJump == false or self.Disabled or self.Destroyed then
		return
	end
	self.JumpHeldDown = true
	self:UpdateCanJump()
	self:AttemptJump()
	if fromGamepad == true then
		return
	end
	self.CanJump = false
	local token = {}
	self._jumpToken = token
	RunService.Heartbeat:Wait()
	while self.JumpHeldDown and self._jumpToken == token and not self.Destroyed do
		RunService.Heartbeat:Wait()
	end
	if self._jumpToken == token then
		self.CanJump = true
	end
end
function Movement:AttemptJump(stats, fromGamepadHold)
	if self.Disabled or self.Destroyed then
		return
	end
	local grounded = self.R:Get("Grounded")
	if not grounded and self.JumpAmount == 0 then
		self.JumpAmount = 1
	elseif grounded then
		self.JumpAmount = 0
	end
	local info = EVADE.StateByName[self.State or "Inert"]
	if info == nil or (info.Movement and info.Movement.CanJump == false) then
		return
	end
	stats = stats or self.Stats
	if grounded or self.State == "WallrunLeft" or self.State == "WallrunRight" or self.JumpAmount < 1 then
		self:Jump(stats, true)
		return
	end
	if fromGamepadHold ~= true then
		self:TestMultipleJumps(stats)
	end
end
function Movement:TestMultipleJumps(stats)
	if self.JumpAmount < stats.JumpCap then
		self.JumpAmount += 1
		if self.Ctx.Footsteps then
			self.Ctx.Footsteps:PlayDoubleJump()
		end
		self:Jump(stats)
	end
end
function Movement:Jump(stats, fromGround, heightOverride)
	stats = stats or self.Stats
	if stats.Speed == 0 then
		return
	end
	local R = self.R
	local V = R:Get("Velocity")
	local sprint = R:Get("Sprint") or 1
	if V ~= Vector3.zero and R:Get("Crouching") ~= true and fromGround == true then
		local dot = self.Root.CFrame.LookVector:Dot(V.Unit)
		local capFactor = stats.JumpSpeedMultiplier * dot ^ 2
		local mag = V.Magnitude
		if mag < sprint * stats.Speed * capFactor then
			local newMag = math.min(mag * stats.JumpSpeedMultiplier, sprint * stats.Speed * capFactor)
			R:Set("Velocity", (V * Vector3.new(1, 0, 1)).Unit * newMag)
		end
	end
	self:SetJumpHeight(heightOverride or stats.JumpHeight)
	self.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	self.JumpCount += 1
	if self.State == "WallrunRight" or self.State == "WallrunLeft" then
		R:Set("IgnoreXMove", os.clock())
		local vy = self.Root.AssemblyLinearVelocity.Y
		R:Set("Velocity", R:Get("Velocity") + (R:Get("WallrunDir") or Vector3.zero) * stats.VelocityScale * stats.WallrunJumpPush)
		task.spawn(function()
			task.wait()
			if self.Root and self.Root.Parent then
				local cur = self.Root.AssemblyLinearVelocity
				self.Root.AssemblyLinearVelocity = Vector3.new(cur.X, vy * 0.1 + 10, cur.Z)
			end
		end)
	end
end

-- ---------- RootPartOrienter (client branch) ----------
function Movement:Orient()
	if self.Stats.Speed == 0 then
		return
	end
	local info = EVADE.StateByName[self.State or "Inert"]
	local mv = info and info.Movement
	if not mv or not mv.RootPartOrientation then
		return
	end
	local root = self.Root
	if mv.RootPartOrientation == "Camera" then
		local _, yaw, _ = self.R:Get("LookCFrame"):ToOrientation()
		root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
	elseif mv.RootPartOrientation == "Velocity" then
		local V = self.R:Get("Velocity")
		if V == nil or flat(V).Magnitude < 1e-4 then
			return
		end
		root.CFrame = CFrame.lookAt(root.Position, root.Position + flat(V))
	end
end

-- ---------- Movement:Update (DoFunction + derived terms) ----------
function Movement:Update(dt)
	local R, hum, root = self.R, self.Humanoid, self.Root
	if self.Destroyed or not root.Parent then
		return
	end
	self.Disabled = hum.Health <= 0
	self:UpdateGravityComp()
	R:Set("JumpingActive", self.JumpHeldDown == true)
	if self.Disabled then
		self:SetState("Inert")
		self:UpdateCanJump()
		return
	end
	if self.Stats.Speed == 0 then
		R:Set("Velocity", Vector3.zero)
	end
	self:SetState(R:Get("State"))
	self:UpdateCanJump()

	-- DoFunction("Move"): NaN guard on the root CFrame (Evade LastFiniteCFrame).
	if isFiniteValue(root.CFrame) then
		self.LastFiniteCFrame = root.CFrame
	elseif self.LastFiniteCFrame then
		root.CFrame = self.LastFiniteCFrame
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		R:Set("Velocity", Vector3.zero)
	end
	local info = EVADE.StateByName[self.State or "Inert"]
	local mv = info and info.Movement
	if mv and mv.MoveType and MoveFunctions[mv.MoveType] then
		local constraints, terms = MoveFunctions[mv.MoveType](self, dt, mv)
		if constraints then
			sanitize(constraints)
			local scale = 1 / self.Stats.VelocityScale
			for id, props in constraints do
				local c = self.Constraints[id]
				if c then
					if props.PlaneVelocity then
						c.PlaneVelocity = props.PlaneVelocity * scale
					end
					if props.Force then
						c.Force = props.Force
					end
				end
			end
		end
		if terms then
			sanitize(terms)
			for k, v in terms do
				R:Set(k, v)
			end
		end
	end

	if self.XboxJumping == true then
		self:AttemptJump(self.Stats, true)
	elseif self.JumpAmount > 0 and R:Get("Grounded") then
		self.JumpAmount = 0
	end

	local V = R:Get("Velocity") or Vector3.zero
	local speed = math.floor(V.Magnitude / self.Stats.VelocityScale * 10) / 10
	R:Set("Speed", speed)
	local baseSpeed = self.Stats.BaseSpeed or 0
	R:Set("RelativeSpeed", baseSpeed > 0 and speed / (baseSpeed / 1500) or 0)
	local rel = (V == Vector3.zero) and Vector3.zero or (root.CFrame - root.CFrame.Position):VectorToObjectSpace(V.Unit)
	R:Set("RelativeMoveDirection", rel)
	self:Orient()
end

-- External velocity correction hook (RemoteMap.VelocityCorrection): studs/s -> internal units.
function Movement:ApplyCorrection(velocity)
	if typeof(velocity) ~= "Vector3" or not isFiniteValue(velocity) then
		return
	end
	self.R:Set("Velocity", flat(velocity) * self.Stats.VelocityScale)
end

function Movement:Destroy()
	self.Destroyed = true
	self._jumpToken = nil
	self.JumpHeldDown = false
	self.CanJump = true
end

--==============================================================================
-- SECTION 11 : CAMERA  (CameraService FOV + ViewmodelDeviation Camera/Grounded springs + camera type)
--==============================================================================
-- State shared between the camera and the settings panel (UI is declared later in the file).
local Shared = { SettingsOpen = false }

local CameraFX = {}
CameraFX.__index = CameraFX

function CameraFX.new(ctx)
	return setmetatable({
		Ctx = ctx,
		R = ctx.Registry,
		SprintFOV = 1,
		CameraSpring = Spring.new(CONFIG.Camera.CameraSpring.Speed, CONFIG.Camera.CameraSpring.Damping),
		GroundedSpring = Spring.new(CONFIG.Camera.GroundedSpring.Speed, CONFIG.Camera.GroundedSpring.Damping),
		OtherBob = CFrame.identity,
		Grounded = nil,
		PlayingAnim = false,
		ThirdPerson = CONFIG.Camera.StartThirdPerson,
		Offset = CFrame.identity,
		Roll = 0,
		Yaw = 0,
		Pitch = 0,
		Zoom = CONFIG.Camera.ThirdPersonZoom, -- MEASURED: fixed third-person distance
		ZoomCurrent = CONFIG.Camera.FirstPersonZoom,
		GamepadLook = Vector2.zero,
	}, CameraFX)
end

function CameraFX:Init(maid)
	local cam = workspace.CurrentCamera
	local hum = self.Ctx.Humanoid
	self.Saved = {
		FieldOfView = cam.FieldOfView,
		CameraMode = LocalPlayer.CameraMode,
		CameraType = cam.CameraType,
		MinZoom = LocalPlayer.CameraMinZoomDistance,
		MaxZoom = LocalPlayer.CameraMaxZoomDistance,
		CameraOffset = hum.CameraOffset,
		MouseBehavior = UserInputService.MouseBehavior,
	}
	self:ApplyCameraType(true)
	maid:Give(function()
		self:Restore()
	end)
end

-- Camera type switch (Character/Client/Camera.Change): zoom, CameraMode, offsets, tween 0.16 s Sine InOut.
-- Third person is driven by UpdateThirdPerson (Scriptable camera); first person stays on Roblox's
-- camera in LockFirstPerson, which already turns with the mouse.
function CameraFX:ApplyCameraType(instant)
	local cam = workspace.CurrentCamera
	if self.ZoomTween then
		self.ZoomTween:Cancel()
		self.ZoomTween = nil
	end
	if self.ThirdPerson then
		local pitch, yaw = cam.CFrame:ToOrientation()
		self.Pitch = clamp(pitch, -CONFIG.Camera.MaxPitch, CONFIG.Camera.MaxPitch)
		self.Yaw = yaw
		self.ZoomCurrent = instant and self.Zoom or CONFIG.Camera.FirstPersonZoom
		LocalPlayer.CameraMode = Enum.CameraMode.Classic
		cam.CameraType = Enum.CameraType.Scriptable
		return
	end
	-- back to first person: hand the camera to Roblox from where the third-person camera is looking,
	-- zooming in from the current distance.
	cam.CameraType = Enum.CameraType.Custom
	LocalPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
	local zoom = CONFIG.Camera.FirstPersonZoom
	if not instant and self.ZoomCurrent > zoom then
		LocalPlayer.CameraMaxZoomDistance = self.ZoomCurrent
		LocalPlayer.CameraMinZoomDistance = self.ZoomCurrent
	end
	local function setZoom(z)
		if z >= LocalPlayer.CameraMaxZoomDistance then
			LocalPlayer.CameraMaxZoomDistance = z
			LocalPlayer.CameraMinZoomDistance = z
		else
			LocalPlayer.CameraMinZoomDistance = z
			LocalPlayer.CameraMaxZoomDistance = z
		end
	end
	if instant then
		setZoom(zoom)
		return
	end
	local value = Instance.new("NumberValue")
	value.Value = LocalPlayer.CameraMaxZoomDistance
	local conn = value.Changed:Connect(setZoom)
	local tween = TweenService:Create(value, TweenInfo.new(CONFIG.Camera.TweenLength, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Value = zoom })
	self.ZoomTween = tween
	tween.Completed:Connect(function()
		conn:Disconnect()
		value:Destroy()
		setZoom(zoom)
	end)
	tween:Play()
end

function CameraFX:ToggleThirdPerson()
	self.ThirdPerson = not self.ThirdPerson
	self:ApplyCameraType(false)
end

-- Mouse wheel (MEASURED Camera.TestThirdPerson): two fixed positions.  Each notch adds 1 to
-- ScrollAmt (drained at ScrollDecayRate/s in Update); once it passes the threshold it resets and
-- toggles if the direction matches: scroll out (Z < 0) in first person -> third person at the fixed
-- 6 studs, scroll in (Z > 0) in third person -> first person.
function CameraFX:OnWheel(z)
	self.ScrollAmt = (self.ScrollAmt or 0) + 1
	if self.ScrollAmt <= CONFIG.Camera.ScrollToggleThreshold then
		return
	end
	self.ScrollAmt = 0
	if z < 0 and not self.ThirdPerson then
		self:ToggleThirdPerson()
	elseif z > 0 and self.ThirdPerson then
		self:ToggleThirdPerson()
	end
end

-- Evade Visibility.Types.Classic (MEASURED): limb names left visible per type.
local FP_VISIBILITY = {
	All = { "Left Arm", "Right Arm", "Left Leg", "Right Leg", "Head", "Torso", "HumanoidRootPart" },
	NoArms = { "Left Leg", "Right Leg", "Torso" },
	LeftArm = { "Left Leg", "Right Leg", "Torso", "Left Arm" },
	BothArms = { "Left Leg", "Right Leg", "Torso", "Left Arm", "Right Arm" },
	None = {},
}

-- First person: Evade decides limb visibility itself (Visibility.GetType / SetVisibility) instead of
-- Roblox's distance fade, so the head and hats never show when looking down.  Runs after Roblox's
-- camera each frame, so it wins over Roblox's TransparencyController.
function CameraFX:ApplyFirstPersonVisibility()
	local typeName = workspace.CurrentCamera.FieldOfView > 90 and "None" or CONFIG.Camera.FirstPersonVisibility
	local visible = FP_VISIBILITY[typeName] or FP_VISIBILITY.NoArms
	local char = self.Ctx.Character
	for _, d in char:GetDescendants() do
		local part = d:IsA("BasePart") and d or (d:IsA("Decal") and d.Parent) or nil
		if part then
			-- accessory handles are not direct children of the character -> always hidden (Accoutrement rule)
			local show = part.Parent == char and table.find(visible, part.Name) ~= nil
			local v = show and 0 or 1
			if d.LocalTransparencyModifier ~= v then
				d.LocalTransparencyModifier = v
			end
		end
	end
end

-- Third person: shift-lock style camera (Evade ShiftLockOffset (2, 0.5, 0)), mouse turns it directly.
-- Runs before the frame reads LookCFrame, so movement uses this frame's camera direction.
function CameraFX:UpdateThirdPerson(dt)
	local cam = workspace.CurrentCamera
	local c = CONFIG.Camera
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end
	if not Shared.SettingsOpen then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		local d = UserInputService:GetMouseDelta()
		local sens = 1
		pcall(function()
			sens = UserSettings():GetService("UserGameSettings").MouseSensitivity
		end)
		local perPixel = math.rad(0.5) * sens -- Roblox CameraInput mouse speed
		self.Yaw -= d.X * perPixel
		self.Pitch -= d.Y * perPixel * 0.77
		local g = self.GamepadLook
		if g.Magnitude > 0.15 then
			self.Yaw -= g.X * c.GamepadLookSpeed.X * dt
			self.Pitch += g.Y * c.GamepadLookSpeed.Y * dt
		end
		self.Pitch = clamp(self.Pitch, -c.MaxPitch, c.MaxPitch)
	end
	self.ZoomCurrent = lerp(self.ZoomCurrent, self.Zoom, math.min(dt * c.ZoomRate, 1))
	local ctx = self.Ctx
	-- Evade's camera subject is its root box (the hull), so the focus is hull centre + 1.5.
	local focus = ctx.Root.Position + Vector3.new(0, 1.5 + self:HullEyeDelta(), 0)
	local rot = CFrame.fromOrientation(self.Pitch, self.Yaw, 0)
	local pivot = CFrame.new(focus) * rot * CFrame.new(c.ThirdPersonShiftLockOffset * math.min(self.ZoomCurrent / c.ThirdPersonZoom, 1))
	local desired = pivot * CFrame.new(0, 0, self.ZoomCurrent)
	-- MEASURED Camera/Types ThirdPerson RootOffset 0.4: camera offset by TorsoRot.Transform.p * 0.4
	local kp = ctx.Animator and ctx.Animator.KeyframePlayer
	local torsoRot = kp and kp.TorsoRotPose
	if torsoRot and torsoRot.Position.Magnitude <= 10 then
		desired *= CFrame.new(torsoRot.Position * c.ThirdPersonRootOffset)
	end
	-- keep the camera out of walls
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ctx.Character }
	local dir = desired.Position - focus
	local hit = dir.Magnitude > 1e-3 and workspace:Raycast(focus, dir, params)
	if hit then
		desired = rot + (hit.Position - dir.Unit * 0.3)
	end
	cam.CFrame = desired
	-- Roblox's first-person camera hides the character via LocalTransparencyModifier and stops
	-- updating it while the camera is Scriptable, so show the body again here.
	for _, d in ctx.Character:GetDescendants() do
		if (d:IsA("BasePart") or d:IsA("Decal")) and d.LocalTransparencyModifier ~= 0 then
			d.LocalTransparencyModifier = 0
		end
	end
end

-- Height of Evade's camera subject (its root box = the hull, centred RootSize.Y/2 above the floor)
-- relative to this rig's HumanoidRootPart.  Standing on stock R6: 2 - 3 = -1 stud.  Crouching lowers it.
function CameraFX:HullEyeDelta()
	local ctx = self.Ctx
	return ctx.RootSize.Y / 2 - ctx.CenterToFloor
end

-- Per-frame camera-type upkeep (Camera:Update): first-person eye height.
-- Evade: camera = root(hull centre) + 1.5 (Roblox head offset) + OriginOffset (0, 0.21, 0) (MEASURED),
-- i.e. 3.71 studs above the floor standing.  Roblox's camera here starts from this rig's HRP, so the
-- hull delta goes into Humanoid.CameraOffset.  Third person applies its own offsets in UpdateThirdPerson.
function CameraFX:UpdateType()
	local ctx = self.Ctx
	ctx.Humanoid.CameraOffset = self.ThirdPerson and Vector3.zero or (CONFIG.Camera.CameraOffset + Vector3.new(0, self:HullEyeDelta(), 0))
	-- Both camera types keep the mouse locked (Evade: first person and shift-lock third person).
	-- Roblox's camera caches the mode it last set and won't reapply it after anything else changes it,
	-- so the lock is enforced here every frame; the settings panel frees it while open.
	if not Shared.SettingsOpen and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end
end

-- CameraService.Update: FieldOfView = BaseFOV * product(adjusters). Written BEFORE the springs update the
-- Sprint adjuster, reproducing Evade's one-frame FOV latency.
function CameraFX:WriteFOV()
	workspace.CurrentCamera.FieldOfView = CONFIG.Camera.BaseFOV * self.SprintFOV
end

-- SpringList "Camera" (Order 6): strafe roll, micro-sway, head bob, sprint FOV, forward offset.
function CameraFX:CameraDeviation(dt)
	local R = self.R
	local look = R:Get("LookCFrame")
	local pitch = look:ToOrientation()
	local forward = CFrame.Angles(-pitch, 0, 0).LookVector * CONFIG.Camera.ForwardOffset
	if not CONFIG.Camera.Viewbob then
		return CFrame.identity + forward
	end
	local relDir = R:Get("RelativeMoveDirection") or Vector3.zero
	local s = R:Get("Speed") or 0
	local groundedFlag = R:Get("Grounded") or true -- MEASURED quirk: always truthy
	local info = EVADE.StateByName[R:Get("State") or "Inert"]
	local vmt = info and info.ViewmodelMoveType
	local roll, r10 = 0, 0
	if vmt == "Moving" then
		r10 = clamp((s - 20) / 12, 0, 1)
	end
	if vmt == "WallrunningLeft" then
		roll = -0.05235987755982989
	elseif vmt == "WallrunningRight" then
		roll = 0.05235987755982989
	elseif relDir ~= Vector3.zero and vmt == "Moving" then
		roll = -(relDir.Unit.X * 0.025 * r10) * 1.15
	end
	local now = os.clock()
	local T = now * 12
	self.CameraSpring:SetT(Vector3.new(math.sin(T) ^ 2 * 0.0025 * r10 * 1.2, math.sin(T) * 0.0025 * r10 * 1.2, math.cos(T) * 0.002 * r10 * 1.2 + roll))

	-- Sprint FOV adjuster (no ADS/Fear outside Evade -> always the speed branch).
	local f = clamp((s - CONFIG.Camera.SprintFOVStart) / CONFIG.Camera.SprintFOVRange, 0, 1)
	self.SprintFOV = lerp(self.SprintFOV, lerp(1, CONFIG.Camera.SprintFOVMax, f), math.min(dt * CONFIG.Camera.SprintFOVRate, 1))

	local alpha = math.min(dt * 20, 1)
	if groundedFlag == false or s <= 1 or vmt ~= "Moving" then
		self.OtherBob = self.OtherBob:Lerp(CFrame.identity, alpha)
	else
		local t10 = now * 10
		local walk = CFrame.new(math.cos(t10) * 0.02, -math.sin(t10) ^ 12 * 0.08, 0) * CFrame.Angles(math.cos(t10) ^ 2 * 0.001, 0, math.cos(t10 + 0.8) * 0.0003)
		if r10 == 0 then
			self.OtherBob = self.OtherBob:Lerp(walk, alpha)
		else
			local t24 = now * 12 * 2
			local sprint = CFrame.new(0, clamp(1 - r10 * 2, 0, 1) * math.sin(t24) * 0.025 + r10 * math.sin(t24) * 0.24, 0)
			if r10 >= 0.5 then
				self.OtherBob = self.OtherBob:Lerp(sprint, alpha)
			else
				-- MEASURED (decompiled blend, extrapolating lerp kept verbatim)
				local target = walk:Lerp(CFrame.identity, 2 - r10 * 2) * sprint:Lerp(CFrame.identity, r10 * 2)
				self.OtherBob = self.OtherBob:Lerp(target, alpha)
			end
		end
	end
	local sp = self.CameraSpring:GetP()
	self.Roll = sp.Z
	return self.Ctx:CamPartTransform() * CFrame.Angles(sp.X, sp.Y, sp.Z) * self.OtherBob + forward
end

-- SpringList "Grounded" (Order 7): landing pitch punch / takeoff kick.
function CameraFX:GroundedDeviation()
	local R = self.R
	local grounded = R:Get("Grounded")
	local sp = self.GroundedSpring
	if self.Grounded == grounded then
		if self.PlayingAnim and (sp:GetP() - sp:GetT()).Magnitude <= 0.008 then
			self.PlayingAnim = false
			sp:SetT(Vector3.zero)
		end
	else
		self.Grounded = grounded
		if grounded then
			local vy = math.abs((R:Get("ActualVelocity") or Vector3.zero).Y)
			local k = clamp((vy - 9) / 10, 0, 3) * 0.5
			sp:SetS(17)
			sp:SetD(0.5)
			sp:SetT(Vector3.new(k * -0.03, 0, 0))
			sp:SetV(Vector3.new(k * -0.025, 0, 0))
			self.PlayingAnim = true
		else
			sp:SetV(Vector3.new(-0.2, 0, 0))
			sp:SetT(Vector3.zero)
			self.PlayingAnim = false
		end
	end
	local p = sp:GetP()
	return CFrame.Angles(p.X, p.Y, p.Z)
end

-- ToolProfile/ViewmodelVisuals.Update -> SetCameraOffset("Viewmodel") ; Reset() when hidden (3rd person).
function CameraFX:Update(dt)
	self.ScrollAmt = math.max((self.ScrollAmt or 0) - dt * CONFIG.Camera.ScrollDecayRate, 0)
	self:WriteFOV()
	if not self.ThirdPerson then
		self:ApplyFirstPersonVisibility()
	end
	if self.ThirdPerson then
		self.SprintFOV = lerp(self.SprintFOV, 1, math.min(dt * 6, 1))
		self.Offset = CFrame.identity
		self.Roll = 0
		return
	end
	local camDev = self:CameraDeviation(dt)
	local groundDev = self:GroundedDeviation()
	local offset = camDev * groundDev
	if not isFiniteValue(offset) then
		self.CameraSpring = Spring.new(CONFIG.Camera.CameraSpring.Speed, CONFIG.Camera.CameraSpring.Damping)
		self.GroundedSpring = Spring.new(CONFIG.Camera.GroundedSpring.Speed, CONFIG.Camera.GroundedSpring.Damping)
		self.OtherBob = CFrame.identity
		offset = CFrame.identity
	end
	self.Offset = offset
end

function CameraFX:Restore()
	local s = self.Saved
	if not s then
		return
	end
	if self.ZoomTween then
		self.ZoomTween:Cancel()
	end
	pcall(function()
		workspace.CurrentCamera.FieldOfView = s.FieldOfView
		workspace.CurrentCamera.CameraType = s.CameraType == Enum.CameraType.Scriptable and Enum.CameraType.Custom or s.CameraType
		LocalPlayer.CameraMode = s.CameraMode
		LocalPlayer.CameraMaxZoomDistance = math.max(s.MaxZoom, s.MinZoom)
		LocalPlayer.CameraMinZoomDistance = s.MinZoom
		LocalPlayer.CameraMaxZoomDistance = s.MaxZoom
		UserInputService.MouseBehavior = s.MouseBehavior
		if self.Ctx.Humanoid and self.Ctx.Humanoid.Parent then
			self.Ctx.Humanoid.CameraOffset = s.CameraOffset
		end
	end)
end

--==============================================================================
-- SECTION 12 : FOOTSTEPS (Animations/Footsteps)
--==============================================================================
local Footsteps = {}
Footsteps.__index = Footsteps

function Footsteps.new(ctx)
	return setmetatable({ Ctx = ctx, R = ctx.Registry, LastPlayedFootstep = 0, SlidingActive = nil }, Footsteps)
end

function Footsteps:Init(maid, overrides)
	local root = self.Ctx.Root
	self.Overrides = overrides or {}
	local function attachment(name, pos)
		local a = Instance.new("Attachment")
		a.Name = name
		a.Position = pos
		a.Parent = root
		maid:Give(a)
		return a
	end
	-- ESTIMATED positions (Evade's attachment CFrames are not decodable from the dump): HeadPos ~ head
	-- height, SoundPos at hull centre, Slide at the feet.  Verify by ear; positions only affect 3D panning.
	local floorOffset = -self.Ctx.CenterToFloor
	self.HeadPos = attachment(hiddenName(), Vector3.new(0, floorOffset + 3.5, 0))
	self.SoundPos = attachment(hiddenName(), Vector3.new(0, floorOffset + 2, 0))
	self.SlideAttachment = attachment(hiddenName(), Vector3.new(0, floorOffset, 0))

	if CONFIG.Audio.Whoosh then
		local w = Instance.new("Sound")
		w.Name = hiddenName()
		for k, v in EVADE.Sounds.Whoosh do
			w[k] = v
		end
		w.SoundId = Assets.SoundId("Whoosh", EVADE.Sounds.Whoosh.SoundId)
		w.Parent = self.SoundPos
		w:Play()
		w.Volume = 0
		self.Whoosh = w
	end
	if CONFIG.Audio.Slide then
		local s = Instance.new("Sound")
		s.Name = hiddenName()
		for k, v in EVADE.Sounds.Slide do
			s[k] = v
		end
		s.SoundId = Assets.SoundId("Slide", EVADE.Sounds.Slide.SoundId)
		s.Parent = self.SlideAttachment
		self.SlideSound = s
		local pe = Instance.new("ParticleEmitter")
		pe.Name = hiddenName()
		for k, v in EVADE.SlideParticles do
			if k ~= "ActiveRate" then
				pe[k] = v
			end
		end
		pe.Rate = 0
		pe.Enabled = false
		pe.Parent = self.SlideAttachment
		self.SlideParticles = pe
	end
end

function Footsteps:GetMaterial(animState)
	local root = self.Ctx.Root
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = buildExcludeList(self.Ctx.Character)
	local hullX = CONFIG.Hull.StandSize.X * self.Ctx.SizeScale
	local hit
	if animState == "WallrunningLeft" then
		hit = workspace:Raycast(self.Ctx:HullCenter(), root.CFrame.RightVector * -hullX, params)
	elseif animState == "WallrunningRight" then
		hit = workspace:Raycast(self.Ctx:HullCenter(), root.CFrame.RightVector * hullX, params)
	else
		hit = workspace:Spherecast(self.Ctx:HullCenter(), hullX / 2, Vector3.new(0, -self.Ctx.RootSize.Y / 2, 0), params)
	end
	if hit and hit.Material then
		return hit.Material.Name
	end
	return nil
end

local function pick(list)
	return list[math.random(1, #list)]
end
function Footsteps:SetSoundInfo(sound, entry)
	sound.Name = "FootstepSound"
	if type(entry) == "table" then
		sound.SoundId = "rbxassetid://" .. tostring(entry[1])
		sound.Volume = entry[2] ~= nil and entry[2] or 0.225
		return
	end
	if type(entry) == "string" then
		sound.SoundId = entry -- user override (getcustomasset id)
		return
	end
	sound.SoundId = "rbxassetid://" .. tostring(entry)
end
function Footsteps:NewFootstepSound()
	local s = Instance.new("Sound")
	for k, v in EVADE.Sounds.Footstep do
		s[k] = v
	end
	return s
end
function Footsteps:Source(kind, material)
	local o = self.Overrides[kind]
	if o and material and o[material] then
		return o[material]
	end
	local t = EVADE.FootstepTypes[kind]
	return t and material and t[material] or nil
end
function Footsteps:PlaySound(kind, material)
	if not CONFIG.Audio.Footsteps then
		return
	end
	if material ~= nil and EVADE.MaterialRefersTo[material] ~= nil then
		material = EVADE.MaterialRefersTo[material]
	end
	local sound
	if kind == "Wander" then
		sound = self:NewFootstepSound()
		self:SetSoundInfo(sound, pick(self:Source("Wander", material) or self:Source("Wander", "Concrete")))
	elseif kind == "Land" then
		sound = self:NewFootstepSound()
		self:SetSoundInfo(sound, pick(self:Source("Land", material) or self:Source("Land", "Concrete")))
	elseif kind == "Walk" then
		sound = self:NewFootstepSound()
		local list = self:Source("Walking", material)
		if list then
			self:SetSoundInfo(sound, pick(list))
		elseif material == nil then
			self:SetSoundInfo(sound, pick(self:Source("Walking", "Concrete")))
		end
	elseif kind == "Run" then
		sound = self:NewFootstepSound()
		local list = self:Source("Sprinting", material) or self:Source("Walking", material)
		if list then
			self:SetSoundInfo(sound, pick(list))
		elseif material == nil then
			self:SetSoundInfo(sound, pick(self:Source("Sprinting", "Concrete")))
		end
	elseif kind == "Cloth" then
		sound = self:NewFootstepSound()
		self:SetSoundInfo(sound, pick(self.Overrides.Cloth or EVADE.FootstepTypes.Cloth))
		sound.Volume = 0.06
	end
	if sound ~= nil then
		if sound.SoundId == "" then
			sound:Destroy() -- MEASURED: Evade plays an empty sound here; skipping it is inaudible
			return
		end
		sound.Parent = self.HeadPos
		sound:Play()
		Debris:AddItem(sound, 1)
	end
end
function Footsteps:Land()
	self:PlaySound("Land", self:GetMaterial())
end
function Footsteps:Wander()
	self:PlaySound("Wander", self:GetMaterial())
end
function Footsteps:PlayDoubleJump()
	local s = Instance.new("Sound")
	s.SoundId = Assets.SoundId("DoubleJump", EVADE.Sounds.DoubleJump.SoundId)
	s.Parent = self.SoundPos
	s:Play()
	Debris:AddItem(s, 1)
end
function Footsteps:UpdateSliding(animState)
	if not self.SlideSound then
		return
	end
	local active = animState == "Sliding" and self.R:Get("Grounded") == true
	if active ~= self.SlidingActive then
		self.SlidingActive = active
		if active then
			if not self.SlideSound.IsPlaying then
				self.SlideSound:Play()
			end
			self.SlideParticles.Rate = EVADE.SlideParticles.ActiveRate
			self.SlideParticles.Enabled = true
		else
			if self.SlideSound.IsPlaying then
				self.SlideSound:Stop()
			end
			self.SlideParticles.Rate = 0
			self.SlideParticles.Enabled = false
		end
	end
end
function Footsteps:UpdateWhoosh(animState)
	if not self.Whoosh then
		return
	end
	local mag = self.R:Get("ActualVelocityMagnitude") or 0
	local target = clamp((mag - 50) / 125, 0, 1)
	if animState == "Moving" or animState == "Swimming" or animState == "Dead" or animState == "Downed" then
		target = 0
	end
	self.Whoosh.Volume = lerp(self.Whoosh.Volume, target * 0.1, 0.1)
end
function Footsteps:Update(_dt, enabled, animSpeed, animState)
	self:UpdateSliding(animState)
	self:UpdateWhoosh(animState)
	if enabled == false or animSpeed == nil then
		return
	end
	local s = self.R:Get("Speed") or 0
	local dist = (workspace.CurrentCamera.CFrame.Position - self.Ctx.Root.Position).Magnitude
	local now = os.clock()
	if s > 0 and animState ~= "Swimming" and dist < CONFIG.Audio.HearingDistance and 0.5 / animSpeed <= now - self.LastPlayedFootstep then
		self.LastPlayedFootstep = now
		local material = self:GetMaterial(animState)
		if s >= 25 then
			self:PlaySound("Run", material)
		else
			self:PlaySound("Walk", material)
		end
		self:PlaySound("Cloth")
	end
end

--==============================================================================
-- SECTION 13 : ANIMATOR (Character/Animations: SetModule / SetCurrentAnimation / UpdateAnimations)
--==============================================================================
--------------------------------------------------------------------------------
-- KeyframePlayer: plays a KeyframeSequence without an AnimationId, for live games where
-- KeyframeSequenceProvider:RegisterKeyframeSequence is Studio-only.  Each KPTrack exposes the
-- AnimationTrack members the Animator uses (Play/Stop/AdjustSpeed/AdjustWeight/Destroy, Length,
-- TimePosition, Speed, IsPlaying, WeightCurrent, Priority, Looped), and the player blends all
-- tracks per joint into Motor6D.Transform every Stepped.
-- Blend: higher priority layers take their (capped) weight first, the rest falls to lower layers;
-- tracks in one layer are weight-averaged; any weight left over keeps the joint's rest pose.
--------------------------------------------------------------------------------
local KPTrack = {}
KPTrack.__index = KPTrack

local DEFAULT_FADE = 0.100000001
local EASING_STYLE = {
	Linear = Enum.EasingStyle.Linear,
	Cubic = Enum.EasingStyle.Cubic,
	CubicV2 = Enum.EasingStyle.Cubic,
	Elastic = Enum.EasingStyle.Elastic,
	Bounce = Enum.EasingStyle.Bounce,
}
-- PoseEasingDirection In/Out are mirrored relative to TweenService's.
local EASING_DIR = { In = Enum.EasingDirection.Out, Out = Enum.EasingDirection.In, InOut = Enum.EasingDirection.InOut }

local function priorityRank(p)
	if p == Enum.AnimationPriority.Core then
		return -1
	end
	return p.Value
end

-- KeyframeSequence -> { [jointName] = { {t, cf, style, dir}, ... sorted by t } }, length
local function compileSequence(ks)
	local curves, length = {}, 0
	for _, kf in ks:GetKeyframes() do
		length = math.max(length, kf.Time)
		for _, pose in kf:GetDescendants() do
			if pose:IsA("Pose") and pose.Weight > 0 then
				local list = curves[pose.Name]
				if not list then
					list = {}
					curves[pose.Name] = list
				end
				table.insert(list, { kf.Time, pose.CFrame, pose.EasingStyle.Name, pose.EasingDirection.Name })
			end
		end
	end
	for _, list in curves do
		table.sort(list, function(a, b)
			return a[1] < b[1]
		end)
	end
	return curves, length
end

local function sampleCurve(list, t)
	local n = #list
	if t <= list[1][1] then
		return list[1][2]
	end
	if t >= list[n][1] then
		return list[n][2]
	end
	local lo, hi = 1, n
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if list[mid][1] <= t then
			lo = mid
		else
			hi = mid
		end
	end
	local a, b = list[lo], list[hi]
	if a[3] == "Constant" then
		return a[2]
	end
	local alpha = (t - a[1]) / (b[1] - a[1])
	local style = EASING_STYLE[a[3]]
	if style and style ~= Enum.EasingStyle.Linear then
		alpha = TweenService:GetValue(alpha, style, EASING_DIR[a[4]] or Enum.EasingDirection.In)
	end
	return a[2]:Lerp(b[2], alpha)
end

function KPTrack.new(player, ks, name)
	local curves, length = compileSequence(ks)
	return setmetatable({
		Player = player,
		Curves = curves,
		Name = name,
		Length = length,
		Looped = ks.Loop,
		Priority = ks.Priority,
		TimePosition = 0,
		Speed = 1,
		IsPlaying = false,
		WeightCurrent = 0,
		WeightTarget = 0,
		FadeRate = math.huge,
	}, KPTrack)
end

function KPTrack:SetTarget(target, fade)
	fade = fade or DEFAULT_FADE
	self.WeightTarget = target
	self.FadeRate = fade > 0 and math.max(math.abs(target - self.WeightCurrent), 1e-3) / fade or math.huge
end

function KPTrack:Play(fade, weight, speed)
	if not self.IsPlaying then
		self.TimePosition = 0
		self.IsPlaying = true
		self.Player.Active[self] = true
	end
	self.Speed = speed or 1
	self:SetTarget(weight or 1, fade)
end

function KPTrack:Stop(fade)
	if self.IsPlaying then
		self:SetTarget(0, fade)
	end
end

function KPTrack:AdjustSpeed(speed)
	self.Speed = speed or 1
end

function KPTrack:AdjustWeight(weight, fade)
	self:SetTarget(weight or 1, fade)
end

function KPTrack:Destroy()
	self.IsPlaying = false
	self.WeightCurrent = 0
	self.Player.Active[self] = nil
end

function KPTrack:Step(dt)
	local diff = self.WeightTarget - self.WeightCurrent
	local stepW = self.FadeRate * dt
	self.WeightCurrent = math.abs(diff) <= stepW and self.WeightTarget or self.WeightCurrent + math.sign(diff) * stepW
	if self.WeightTarget <= 0 and self.WeightCurrent <= 0 then
		self.IsPlaying = false
		self.Player.Active[self] = nil
		return
	end
	local len = self.Length
	local t = self.TimePosition + dt * self.Speed
	if len <= 0 then
		t = 0
	elseif self.Looped then
		t %= len
	elseif t >= len or t <= 0 then
		t = math.clamp(t, 0, len)
		if self.WeightTarget > 0 then
			self:SetTarget(0, DEFAULT_FADE) -- non-looped track ends, holding its last pose while fading
		end
	end
	self.TimePosition = t
end

local KeyframePlayer = {}
KeyframePlayer.__index = KeyframePlayer

-- Evade's Classic rig (from the pose tree in its KeyframeSequences):
--   HumanoidRootPart > TorsoRot > { Torso > Head, Left Leg, Right Leg, ArmRot > { Left Arm, Right Arm } }
-- Every joint frame is axis-aligned with the torso (X = pitch, Y = yaw), unlike stock R6 whose
-- hips/shoulders are turned 90 degrees.  We rebuild that rig in torso space and solve each stock
-- Motor6D.Transform so the stock parts land where Evade's would.
local function about(pivot, t)
	return CFrame.new(pivot) * t * CFrame.new(-pivot)
end

function KeyframePlayer:SetupR6Retarget(character)
	local hrp, torso = character:FindFirstChild("HumanoidRootPart"), character:FindFirstChild("Torso")
	if not (hrp and torso) then
		return
	end
	local function motor(parent, name)
		local m = parent:WaitForChild(name, 3) -- joints can arrive a moment after the character
		return (m and m:IsA("Motor6D")) and m or nil
	end
	local rig = {}
	for key, spec in { RootJoint = { hrp, "RootJoint" }, Neck = { torso, "Neck" }, ["Left Arm"] = { torso, "Left Shoulder" }, ["Right Arm"] = { torso, "Right Shoulder" }, ["Left Leg"] = { torso, "Left Hip" }, ["Right Leg"] = { torso, "Right Hip" } } do
		rig[key] = motor(spec[1], spec[2])
		if not rig[key] then
			Log.warnOnce("kp-r6", "Animator", ("R6 joint %s missing; animations play without Evade-rig retargeting"):format(spec[2]))
			return
		end
	end
	rig.TorsoRest = rig.RootJoint.C0 * rig.RootJoint.C1:Inverse()
	rig.TorsoRestInv = rig.TorsoRest:Inverse()
	-- Pivots in torso space, MEASURED from Evade's rig (ReplicatedStorage/Assets/Character/R6): every joint
	-- has identity-rotation C0/C1.  Neck (0,1,0), ArmRot (0,0.5,0) on TorsoRot, arms (+-1,0) on ArmRot,
	-- hips (+-0.5,-1,0) on TorsoRot (stock R6 hips sit at +-1).
	rig.Pivot = {
		Head = Vector3.new(0, 1, 0),
		["Left Arm"] = Vector3.new(-1, 0.5, 0),
		["Right Arm"] = Vector3.new(1, 0.5, 0),
		["Left Leg"] = Vector3.new(-0.5, -1, 0),
		["Right Leg"] = Vector3.new(0.5, -1, 0),
		ArmRot = Vector3.new(0, 0.5, 0),
	}
	self.R6 = rig
end

function KeyframePlayer.new(character, maid)
	local self = setmetatable({ Active = {}, Motors = {}, Character = character }, KeyframePlayer)
	for _, m in character:GetDescendants() do
		if m:IsA("Motor6D") and m.Part1 then
			self.Motors[m.Part1.Name] = m
		end
	end
	self:SetupR6Retarget(character)
	maid:Give(RunService.Stepped:Connect(function(_, dt)
		self:Step(dt)
	end))
	maid:Give(function()
		for _, m in self.Motors do
			pcall(function()
				m.Transform = CFrame.identity
			end)
		end
	end)
	return self
end

function KeyframePlayer:NewTrack(ks, name)
	return KPTrack.new(self, ks, name)
end

function KeyframePlayer:Step(dt)
	local layers = {}
	for track in self.Active do
		track:Step(dt)
		if self.Active[track] and track.WeightCurrent > 0 then
			local rank = priorityRank(track.Priority)
			layers[rank] = layers[rank] or {}
			table.insert(layers[rank], track)
		end
	end
	local ranks = {}
	for r in layers do
		table.insert(ranks, r)
	end
	table.sort(ranks, function(a, b)
		return a > b
	end)
	local function blend(boneName)
		local acc, total, remaining = CFrame.identity, 0, 1
		for _, r in ranks do
			local sum = 0
			for _, track in layers[r] do
				if track.Curves[boneName] then
					sum += track.WeightCurrent
				end
			end
			if sum > 0 then
				local share = remaining * math.min(sum, 1) / sum
				for _, track in layers[r] do
					local curve = track.Curves[boneName]
					if curve then
						local w = track.WeightCurrent * share
						total += w
						acc = acc:Lerp(sampleCurve(curve, track.TimePosition), w / total)
					end
				end
				remaining *= 1 - math.min(sum, 1)
				if remaining <= 0 then
					break
				end
			end
		end
		if total < 1 then
			acc = CFrame.identity:Lerp(acc, total)
		end
		return acc
	end
	local rig = self.R6
	if not rig then
		for jointName, motor in self.Motors do
			motor.Transform = blend(jointName)
		end
		return
	end
	-- Evade rig forward kinematics in torso space (deltas from the rest pose).
	local wTorsoRot = blend("TorsoRot")
	self.TorsoRotPose = wTorsoRot -- third-person camera follows its translation (Evade RootOffset)
	local wTorso = wTorsoRot * blend("Torso")
	local wArmRot = wTorsoRot * about(rig.Pivot.ArmRot, blend("ArmRot"))
	local delta = {
		Torso = wTorso,
		Head = wTorso * about(rig.Pivot.Head, blend("Head")),
		["Left Arm"] = wArmRot * about(rig.Pivot["Left Arm"], blend("Left Arm")),
		["Right Arm"] = wArmRot * about(rig.Pivot["Right Arm"], blend("Right Arm")),
		["Left Leg"] = wTorsoRot * about(rig.Pivot["Left Leg"], blend("Left Leg")),
		["Right Leg"] = wTorsoRot * about(rig.Pivot["Right Leg"], blend("Right Leg")),
	}
	-- Stock motors: Part1 = Part0 * C0 * Transform * C1^-1, all in HRP space.
	-- Animated torso (HRP space) = TorsoRest * delta.Torso; animated limb = that * C0 * C1^-1 under delta.
	local root = rig.RootJoint
	local torsoAnim = rig.TorsoRest * wTorso
	root.Transform = root.C0:Inverse() * torsoAnim * root.C1
	local torsoInv = wTorso:Inverse()
	for part, m in { Head = rig.Neck, ["Left Arm"] = rig["Left Arm"], ["Right Arm"] = rig["Right Arm"], ["Left Leg"] = rig["Left Leg"], ["Right Leg"] = rig["Right Leg"] } do
		-- limb in torso space: rest = C0 * C1^-1, animated = torsoInv * delta * rest
		m.Transform = m.C0:Inverse() * torsoInv * delta[part] * m.C0
	end
end

local Animator = {}
Animator.__index = Animator

function Animator.new(ctx)
	return setmetatable({
		Ctx = ctx,
		R = ctx.Registry,
		Animations = {},
		Transitions = {},
		Weights = {},
		Speed = 0,
		MoveDirection = Vector3.zero,
		State = nil,
		CurrentStateAnimation = "Default",
		FootstepsEnabled = false,
		AnimationSpeed = nil,
		OwnedTracks = {},
		SlotByTrack = {},
	}, Animator)
end

-- Default animation suppression: disable the rig's Animate LocalScript, stop its tracks with Stop(0)
-- (Evade SetModule does the same), and stop any track it starts afterwards (flicker-free).
function Animator:SuppressDefault(maid)
	local char = self.Ctx.Character
	local animate = char:FindFirstChild("Animate")
	if animate and (animate:IsA("LocalScript") or animate:IsA("Script")) then
		local was = animate.Enabled
		animate.Enabled = false
		maid:Give(function()
			if animate.Parent then
				animate.Enabled = was
			end
		end)
		self.AnimateScript = animate
	end
	for _, track in self.AnimatorInstance:GetPlayingAnimationTracks() do
		if not self.OwnedTracks[track] then
			track:Stop(0)
		end
	end
	maid:Give(self.AnimatorInstance.AnimationPlayed:Connect(function(track)
		if self.OwnedTracks[track] then
			return
		end
		local anim = track.Animation
		if self.AnimateScript and anim and anim:IsDescendantOf(self.AnimateScript) then
			track:Stop(0)
		end
	end))
end

function Animator:Init(maid)
	local hum = self.Ctx.Humanoid
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
		maid:Give(animator)
	end
	self.AnimatorInstance = animator
	self.RigType = (hum.RigType == Enum.HumanoidRigType.R15) and "R15" or "Classic"
	self.AnimationInfo = EVADE.AnimInfo[self.RigType]
	self.TransitionAttributes = EVADE.TransitionAttributes[self.RigType]
	self.Report = {}
	self:SuppressDefault(maid)
	self:LoadTracks(maid)
	maid:Give(function()
		self:ReleaseTracks()
	end)
end

function Animator:EstimatedPriority(slot)
	local folder = string.match(slot, "^([^/]+)")
	return CONFIG.Animation.EstimatedPriority[folder]
end

function Animator:LoadTrack(slot, fileName, maid)
	local id, source, ks = Assets.ResolveAnimation(slot, fileName)
	if not id then
		self.Report[slot] = "UNRESOLVED (" .. fileName .. ")"
		Log.warnOnce("anim-unresolved:" .. slot, "Animator", ("slot %s: could not load %s; slot disabled"):format(slot, fileName))
		return nil
	end
	if source == "KeyframePlayer" then
		if not self.KeyframePlayer then
			self.KeyframePlayer = KeyframePlayer.new(self.Ctx.Character, maid)
		end
		local track = self.KeyframePlayer:NewTrack(ks, string.match(slot, "([^/]+)$"))
		if CONFIG.Animation.ForceEstimatedPriority then
			track.Priority = self:EstimatedPriority(slot) or track.Priority
		end
		self.OwnedTracks[track] = true
		self.SlotByTrack[track] = slot
		self.Report[slot] = ("OK via KeyframePlayer (%s, %.2fs)"):format(fileName, track.Length)
		return track
	end
	local anim = Instance.new("Animation")
	anim.Name = string.match(slot, "([^/]+)$")
	anim.AnimationId = id
	maid:Give(anim)
	local ok, track = pcall(self.AnimatorInstance.LoadAnimation, self.AnimatorInstance, anim)
	if not ok or not track then
		self.Report[slot] = "LoadAnimation failed: " .. tostring(track)
		Log.warnOnce("anim-load:" .. slot, "Animator", ("slot %s: LoadAnimation failed (%s)"):format(slot, tostring(track)))
		return nil
	end
	-- Priority / Looped: from your KeyframeSequence when present, else ESTIMATED table.
	if ks then
		pcall(function()
			track.Priority = ks.Priority
			track.Looped = ks.Loop
		end)
	end
	if CONFIG.Animation.ForceEstimatedPriority or (not ks and source == "IdOverrides") then
		local p = self:EstimatedPriority(slot)
		if p then
			track.Priority = p
		end
	end
	self.OwnedTracks[track] = true
	self.SlotByTrack[track] = slot
	self.Report[slot] = ("OK via %s (%s)"):format(source, fileName)
	return track
end

-- Rescale factor = yourLength / evadeLength (toggle CONFIG.Animation.RescaleToEvadeLength).
function Animator:Rescale(entry)
	if not CONFIG.Animation.RescaleToEvadeLength then
		return 1
	end
	local evadeLen = CONFIG.Animation.EvadeLengths[entry.Slot]
	local len = entry.Animation.Length
	if evadeLen and evadeLen > 0 and len and len > 0 then
		return len / evadeLen
	end
	return 1
end

function Animator:LoadTracks(maid)
	local ids = EVADE.AnimationIds[self.RigType] or EVADE.AnimationIds.R15
	local slots = {}
	for slot in AnimationMap do
		table.insert(slots, slot)
	end
	for slot in ids do
		if AnimationMap[slot] == nil then
			table.insert(slots, slot)
		end
	end
	table.sort(slots)
	for _, slot in slots do
		local fileName = AnimationMap[slot]
		if fileName == nil then
			Log.warnOnce("anim-unmapped:" .. slot, "Animator", ("Evade slot %s is unmapped in AnimationMap (skipped)"):format(slot))
		elseif fileName ~= false then
			local track = self:LoadTrack(slot, fileName, maid)
			if track then
				local parts = string.split(slot, "/")
				if parts[1] == "Transitions" then
					local folder, name = parts[2], parts[3]
					self.Transitions[folder] = self.Transitions[folder] or {}
					table.insert(self.Transitions[folder], { Animation = track, Name = name, ParentName = folder, Slot = slot, Attributes = self.TransitionAttributes[folder .. "/" .. name] or {} })
				else
					local folder, name = parts[1], parts[2]
					self.Animations[folder] = self.Animations[folder] or {}
					table.insert(self.Animations[folder], { Animation = track, Name = name, Slot = slot })
				end
			end
		end
	end
	for slot, status in self.Report do
		Log.info("Animator", ("%-34s %s"):format(slot, status))
	end
end

function Animator:ReleaseTracks()
	for _, group in { self.Animations, self.Transitions } do
		for _, list in group do
			for _, e in list do
				pcall(function()
					e.Animation:Stop(0)
					e.Animation:Destroy()
				end)
			end
		end
	end
	self.Animations, self.Transitions = {}, {}
	table.clear(self.OwnedTracks)
end

function Animator:GetInfo(name)
	for _, info in self.AnimationInfo do
		for _, n in info.Names do
			if n == name then
				return info
			end
		end
	end
	for _, info in self.AnimationInfo do
		for _, n in info.Names do
			if n == "Default" then
				return info
			end
		end
	end
	return nil
end

-- Registry "State" -> CurrentStateAnimation (Animations:SetState).
function Animator:OnStateChanged(stateName)
	local info = EVADE.StateByName[stateName or "Inert"] or EVADE.StateByName.Inert
	self.CurrentStateAnimation = info.Animation
end

function Animator:PlayTransitionAnimation(entry, targetState)
	if entry.Name == "End" then
		local info = self:GetInfo(targetState)
		if info.Transitions == nil or info.Transitions[entry.ParentName] == nil then
			return
		end
		local found = false
		for _, v in info.Transitions[entry.ParentName] do
			if v == "End" then
				found = true
			end
		end
		if not found then
			return
		end
	end
	local attrs = entry.Attributes
	task.spawn(function()
		local playLen = attrs.PlayWeightLength or 0.2
		entry.Animation:Play(playLen)
		entry.Animation:AdjustSpeed((attrs.Speed or 1) * self:Rescale(entry))
		if attrs.PlayWeightLength ~= 0 then
			task.wait(playLen)
		else
			task.wait()
		end
		if entry and self.OwnedTracks[entry.Animation] then
			entry.Animation:Stop(attrs.StopWeightLength or 0.2)
		end
	end)
end

function Animator:SetCurrentAnimation(new)
	if self.State == new then
		return
	end
	local fs = self.Ctx.Footsteps
	local oldTransitions = self.State and self.Transitions[self.State]
	if oldTransitions then
		for _, t in oldTransitions do
			if t.Name == "End" then
				self:PlayTransitionAnimation(t, new)
			end
		end
	end
	local oldInfo = self:GetInfo(self.State)
	if oldInfo.PlayWander == true and fs then
		fs:Wander()
	end
	if oldInfo.PlayLanded and fs then
		for _, n in oldInfo.PlayLanded do
			if new == n then
				fs:Land()
			end
		end
	end
	self.State = new
	local newTransitions = self.Transitions[new]
	if newTransitions then
		for _, t in newTransitions do
			if t.Name == "Start" then
				self:PlayTransitionAnimation(t, new)
			elseif t.Name == "End" then
				t.Animation:Stop(0.25)
			end
		end
	end
	local info = self:GetInfo(new)
	self.FootstepsEnabled = info.FootstepsEnabled or false
	for folder, list in self.Animations do
		if folder == new then
			for _, e in list do
				e.Animation:Play(info.PlayTransitionTime, 1, self:Rescale(e))
			end
		else
			local fi = self:GetInfo(folder)
			for _, e in list do
				e.Animation:Stop(fi.StopTransitionTime)
			end
		end
	end
end

function Animator:SetDirectionWeights(d)
	local w = self.Weights
	w.Forward = math.abs(clamp(d.Z, -1, 0)) ^ 2
	w.Backward = math.abs(clamp(d.Z, 0, 1)) ^ 2
	w.Left = math.abs(clamp(d.X, -1, 0)) ^ 2
	w.Right = math.abs(clamp(d.X, 0, 1)) ^ 2
	w.ForwardLeft = math.abs(clamp(d.X, -1, 0)) / 0.7071067811865476
	w.ForwardRight = math.abs(clamp(d.X, 0, 1)) / 0.7071067811865476
	w.ForwardForward = math.max(math.abs(clamp(d.Z, -1, -0.7071067811865476) + 0.7071067811865476) / 0.2928932188134524, 0)
end

function Animator:SetValues(entry, speedInfo, weightInfo, direction)
	local track = entry.Animation
	local speed = 1
	if speedInfo ~= nil then
		if speedInfo.YVelocitySpeed == true then
			local vy = (self.R:Get("ActualVelocity") or Vector3.zero).Y
			if math.abs(vy) <= 0.4 then
				vy = 0
			end
			speed = clamp(vy / 6, -2.5, 2.5)
			self.AnimationSpeed = math.abs(speed)
		elseif speedInfo.UseMovementSpeed ~= true then
			track:AdjustSpeed(1 / (speedInfo.SpeedDivision or 1) * self:Rescale(entry))
			speed /= speedInfo.SpeedDivision or 1
		elseif self.Speed then
			if speedInfo.SpeedDivisionPastSpeed ~= nil and speedInfo.SpeedDivisionPastSpeed[1] <= self.Speed then
				speed = self.Speed / (speedInfo.SpeedDivisionPastSpeed[2] or 1)
			else
				speed = self.Speed / (speedInfo.SpeedDivision or 1)
			end
		end
	end
	local weight = 1
	if weightInfo and self.Speed then
		if weightInfo.ZeroBeforeSpeed ~= nil and self.Speed < weightInfo.ZeroBeforeSpeed then
			weight = 0
		elseif weightInfo.ZeroAfterSpeed ~= nil and weightInfo.ZeroAfterSpeed <= self.Speed then
			weight = 0
		elseif weightInfo.SpeedChanges ~= nil then
			local f = clamp((self.Speed - (weightInfo.SpeedChanges.Subtract or 0)) / weightInfo.SpeedChanges.Division, 0, 1)
			if weightInfo.SpeedChanges.Reversed == true then
				f = 1 - f
			end
			weight *= f
		end
	end
	if direction ~= nil then
		local reversed = false
		if weightInfo and weightInfo.ReverseLeftRightIfBackwards == true and self.MoveDirection.Z > 0 then
			if direction == "Left" then
				reversed, direction = true, "Right"
			elseif direction == "Right" then
				reversed, direction = true, "Left"
			end
		end
		local dw = self.Weights[direction]
		if dw ~= nil then
			weight *= dw
		end
		if reversed then
			speed *= -1
		end
	end
	if speedInfo ~= nil and speedInfo.Return == true and speedInfo.YVelocitySpeed ~= true then
		self.AnimationSpeed = math.abs(speed)
	end
	track:AdjustSpeed(speed * self:Rescale(entry))
	track:AdjustWeight(weight < 0.01 and 0.01 or weight, weightInfo and weightInfo.TransitionTime or nil)
end

function Animator:UpdateAnimations(name)
	local list = self.Animations[name]
	if list == nil then
		return
	end
	local info = self:GetInfo(name)
	local speed = self.R:Get("Speed")
	local dir = self.R:Get("RelativeMoveDirection")
	if info == nil or (info.IgnoreSpeedCheck ~= true and self.Speed == speed and self.MoveDirection == dir) then
		return
	end
	if not dir then
		return
	end
	self.Speed = speed
	if math.abs(dir.Z) < 0.1 then
		dir = Vector3.new(dir.X, dir.Y, -0.01)
	end
	if dir ~= self.MoveDirection then
		self:SetDirectionWeights(dir)
	end
	self.MoveDirection = dir
	for _, pb in info.PlaybackInfo do
		for _, e in list do
			if table.find(pb.Animations, e.Name) then
				local direction = pb.Directions and pb.Directions[e.Name] or nil
				self:SetValues(e, pb.SpeedInfo, pb.WeightInfo, direction)
			end
		end
		if pb.CopyTimePosition ~= nil then
			local src
			for _, e in list do
				if e.Name == pb.CopyTimePosition then
					src = e
				end
			end
			if src then
				for _, e in list do
					if e ~= src and table.find(pb.Animations, e.Name) then
						local track = e.Animation
						local len = track.Length
						local tp = src.Animation.TimePosition
						if track.Speed < 0 then
							if len and len > 0 then
								track.TimePosition = clamp(len - tp, 0, len)
							end
						elseif len and len > 0 then
							track.TimePosition = clamp(tp, 0, len)
						end
					end
				end
			end
		end
	end
end

function Animator:Update(dt)
	local stateAnim = self.CurrentStateAnimation
	self:SetCurrentAnimation(stateAnim)
	self:UpdateAnimations(stateAnim)
	if self.Ctx.Footsteps then
		self.Ctx.Footsteps:Update(dt, self.FootstepsEnabled, self.AnimationSpeed, self.State)
	end
end

-- Active slots (weight > 0.05) for validation logging.
function Animator:ActiveSlots()
	local out = {}
	for track, slot in self.SlotByTrack do
		if track.IsPlaying and track.WeightCurrent > 0.05 then
			table.insert(out, slot)
		end
	end
	table.sort(out)
	return out
end

--==============================================================================
-- SECTION 14 : UI (GameUIService/Types/CharacterStatus — Speedometer + Health)
--==============================================================================
local UI = { Elements = {}, Gui = nil }

local function guiParent(gui)
	if Cap.gethui then
		local ok, h = pcall(Cap.gethui)
		if ok and typeof(h) == "Instance" then
			return h, "gethui"
		end
	end
	if Cap.protect_gui then
		pcall(Cap.protect_gui, gui)
	end
	local ok = pcall(function()
		gui.Parent = getService("CoreGui")
	end)
	if ok and gui.Parent then
		return gui.Parent, Cap.protect_gui and "protect_gui+CoreGui" or "CoreGui"
	end
	return LocalPlayer:WaitForChild("PlayerGui"), "PlayerGui"
end

local function make(className, props, children)
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			inst[k] = v
		end
	end
	for _, c in children or {} do
		c.Parent = inst
	end
	return inst
end
local function corner(scale, offset)
	return make("UICorner", { CornerRadius = UDim.new(scale, offset) })
end
local function vGradient()
	return make("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0) })
end
local GOTHAM_BOLD = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)

-- Native Evade layout: generated from Evade's place file (ReplicatedStorage/Assets/UI/Game/HUD/Overlay/
-- CharacterStatus, Health + Speedometer subtrees; Tickets/Style/EventMachine/Attributes/VehicleHealth are
-- game-only and left out).  Values are exact; properties at their class default are omitted, enums are
-- stored as numbers.  Regenerate with tools/rbxl (see docs) instead of editing by hand.
local EVADE_HUD = {
	{ Path = "CharacterStatus", Class = "Frame", Props = { AnchorPoint=Vector2.new(0,1), BackgroundColor3=Color3.new(1,1,1), BackgroundTransparency=1, Position=UDim2.new(0,0,1,0), Size=UDim2.new(1,0,1,0) } },
	{ Path = "CharacterStatus/BottomLeft", Class = "Frame", Props = { AnchorPoint=Vector2.new(0,1), BackgroundColor3=Color3.new(1,1,1), BackgroundTransparency=1, Position=UDim2.new(0,0,1,0), Size=UDim2.new(1,0,1,0) } },
	{ Path = "CharacterStatus/UIAspectRatioConstraint", Class = "UIAspectRatioConstraint", Props = {} },
	{ Path = "CharacterStatus/BottomLeft/Health", Class = "Frame", Props = { AnchorPoint=Vector2.new(0,1), BackgroundColor3=Color3.new(0,0,0), BackgroundTransparency=0.8, BorderSizePixel=0, Position=UDim2.new(0.05,0,0.95,0), Size=UDim2.new(0.25,0,0.1,0) } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer", Class = "Frame", Props = { BackgroundColor3=Color3.new(0,0,0), BackgroundTransparency=1, Position=UDim2.new(0.32,0,0.85,0), Size=UDim2.new(0.045,0,0.045,0), ZIndex=0 } },
	{ Path = "CharacterStatus/BottomLeft/UISizeConstraint", Class = "UISizeConstraint", Props = { MaxSize=Vector2.new(600,600), MinSize=Vector2.new(420,420) } },
	{ Path = "CharacterStatus/BottomLeft/Health/Background", Class = "ImageLabel", Props = { AnchorPoint=Vector2.new(0.5,0.5), BackgroundColor3=Color3.new(1,1,1), BackgroundTransparency=1, Image="rbxassetid://196969716", ImageColor3=Color3.new(0.0823529,0.0823529,0.0823529), ImageTransparency=0.8, Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(1,0,1,0), ZIndex=0 } },
	{ Path = "CharacterStatus/BottomLeft/Health/BackgroundStroke", Class = "Frame", Props = { AnchorPoint=Vector2.new(0.5,0.5), BackgroundColor3=Color3.new(1,1,1), BackgroundTransparency=1, BorderSizePixel=0, Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(1,-6,1,-6) } },
	{ Path = "CharacterStatus/BottomLeft/Health/Frame", Class = "Frame", Props = { AnchorPoint=Vector2.new(0,0.5), BackgroundColor3=Color3.new(1,1,1), BackgroundTransparency=1, Position=UDim2.new(0.775,0,0.6,0), Size=UDim2.new(0.225,0,0.45,0) } },
	{ Path = "CharacterStatus/BottomLeft/Health/Health", Class = "TextLabel", Props = { AnchorPoint=Vector2.new(1,0.5), BackgroundColor3=Color3.new(1,1,1), BackgroundTransparency=1, FontFace={font="rbxasset://fonts/families/GothamSSm.json",w=700,s=0}, Position=UDim2.new(0.9,0,0.5,0), Size=UDim2.new(0.5,0,0.5,0), Text="100", TextColor3=Color3.new(0.439216,1,0.286275), TextScaled=true, TextSize=14, TextStrokeTransparency=0.95, TextWrapped=true } },
	{ Path = "CharacterStatus/BottomLeft/Health/HealthIcon", Class = "ImageLabel", Props = { AnchorPoint=Vector2.new(0,0.5), BackgroundColor3=Color3.new(1,1,1), BackgroundTransparency=1, Image="rbxassetid://18788896053", ImageColor3=Color3.new(0.439216,1,0.286275), Position=UDim2.new(0.08,0,0.52072,0), Size=UDim2.new(0.256576,0,0.641441,0), ZIndex=4 } },
	{ Path = "CharacterStatus/BottomLeft/Health/UICorner", Class = "UICorner", Props = { BottomLeftRadius=UDim.new(0.1,0), BottomRightRadius=UDim.new(0.1,0), TopLeftRadius=UDim.new(0.1,0), TopRightRadius=UDim.new(0.1,0) } },
	{ Path = "CharacterStatus/BottomLeft/Health/UIShadow", Class = "UIShadow", Props = { BlurRadius=UDim.new(0.12,0), Transparency=0.6 } },
	{ Path = "CharacterStatus/BottomLeft/Health/UIStroke", Class = "UIStroke", Props = { Transparency=0.8 } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/Background", Class = "ImageLabel", Props = { AnchorPoint=Vector2.new(0.5,0.5), BackgroundColor3=Color3.new(1,1,1), BackgroundTransparency=1, Image="rbxassetid://196969716", ImageColor3=Color3.new(0.0823529,0.0823529,0.0823529), ImageTransparency=0.4, Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(1.25,0,1.25,0) } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/Frame", Class = "Frame", Props = { BackgroundColor3=Color3.new(0,0,0), BackgroundTransparency=1, ClipsDescendants=true, Size=UDim2.new(1,0,1,0) } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/Front", Class = "Frame", Props = { BackgroundColor3=Color3.new(0,0,0), BackgroundTransparency=1, ClipsDescendants=true, Position=UDim2.new(1,0,0,0), Size=UDim2.new(2.6,0,1,0) } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/ImageLabel", Class = "ImageLabel", Props = { AnchorPoint=Vector2.new(0.5,0.5), BackgroundColor3=Color3.new(1,1,1), BackgroundTransparency=1, Image="rbxassetid://13492318225", ImageColor3=Color3.new(1,0.854902,0.419608), Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0.75,0,0.75,0) } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/Speed", Class = "TextLabel", Props = { AnchorPoint=Vector2.new(0,0.5), BackgroundColor3=Color3.new(1,1,1), BackgroundTransparency=1, FontFace={font="rbxasset://fonts/families/GothamSSm.json",w=700,s=0}, Position=UDim2.new(1.3,0,0.5,0), Size=UDim2.new(6,0,0.8,0), Text="0", TextColor3=Color3.new(1,0.854902,0.419608), TextScaled=true, TextSize=14, TextStrokeTransparency=0.9, TextWrapped=true, TextXAlignment=0, ZIndex=2 } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/UIAspectRatioConstraint", Class = "UIAspectRatioConstraint", Props = {} },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/UICorner", Class = "UICorner", Props = { BottomLeftRadius=UDim.new(0,4), BottomRightRadius=UDim.new(0,4), TopLeftRadius=UDim.new(0,4), TopRightRadius=UDim.new(0,4) } },
	{ Path = "CharacterStatus/BottomLeft/Health/Background/UICorner", Class = "UICorner", Props = { BottomLeftRadius=UDim.new(0,4), BottomRightRadius=UDim.new(0,4), TopLeftRadius=UDim.new(0,4), TopRightRadius=UDim.new(0,4) } },
	{ Path = "CharacterStatus/BottomLeft/Health/BackgroundStroke/UICorner", Class = "UICorner", Props = { BottomLeftRadius=UDim.new(0.06,0), BottomRightRadius=UDim.new(0.06,0), TopLeftRadius=UDim.new(0.06,0), TopRightRadius=UDim.new(0.06,0) } },
	{ Path = "CharacterStatus/BottomLeft/Health/BackgroundStroke/UIStroke", Class = "UIStroke", Props = { Color=Color3.new(0.439216,1,0.286275), Thickness=2, Transparency=0.7 } },
	{ Path = "CharacterStatus/BottomLeft/Health/Frame/UIListLayout", Class = "UIListLayout", Props = { FillDirection=0, HorizontalAlignment=2, SortOrder=2, VerticalAlignment=0 } },
	{ Path = "CharacterStatus/BottomLeft/Health/Health/UIGradient", Class = "UIGradient", Props = { Color=ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.new(1,1,1)),ColorSequenceKeypoint.new(1,Color3.new(0.647059,0.647059,0.647059))}), Rotation=90, Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0.00,0.00),NumberSequenceKeypoint.new(1.00,0.00)}) } },
	{ Path = "CharacterStatus/BottomLeft/Health/Health/UIStroke", Class = "UIStroke", Props = { Thickness=2, Transparency=0.5 } },
	{ Path = "CharacterStatus/BottomLeft/Health/HealthIcon/HealthIcon", Class = "ImageLabel", Props = { AnchorPoint=Vector2.new(0.5,0.5), BackgroundColor3=Color3.new(1,1,1), BackgroundTransparency=1, Image="rbxassetid://18788900977", ImageTransparency=0.5, Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(1,0,1,0), ZIndex=3 } },
	{ Path = "CharacterStatus/BottomLeft/Health/HealthIcon/UIAspectRatioConstraint", Class = "UIAspectRatioConstraint", Props = { AspectRatio=1.1 } },
	{ Path = "CharacterStatus/BottomLeft/Health/HealthIcon/UIGradient", Class = "UIGradient", Props = { Color=ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.new(1,1,1)),ColorSequenceKeypoint.new(1,Color3.new(0.647059,0.647059,0.647059))}), Rotation=90, Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0.00,0.00),NumberSequenceKeypoint.new(1.00,0.00)}) } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/Background/UICorner", Class = "UICorner", Props = { BottomLeftRadius=UDim.new(0,4), BottomRightRadius=UDim.new(0,4), TopLeftRadius=UDim.new(0,4), TopRightRadius=UDim.new(0,4) } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/Frame/Frame", Class = "Frame", Props = { BackgroundColor3=Color3.new(0,0,0), BackgroundTransparency=0.6, Size=UDim2.new(2,0,1,0) } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/Front/Frame", Class = "Frame", Props = { BackgroundColor3=Color3.new(0,0,0), BackgroundTransparency=0.9, Position=UDim2.new(-1,0,0,0), Size=UDim2.new(2,0,1,0) } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/ImageLabel/UICorner", Class = "UICorner", Props = { BottomLeftRadius=UDim.new(0,3), BottomRightRadius=UDim.new(0,3), TopLeftRadius=UDim.new(0,3), TopRightRadius=UDim.new(0,3) } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/ImageLabel/UIGradient", Class = "UIGradient", Props = { Color=ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.new(1,1,1)),ColorSequenceKeypoint.new(1,Color3.new(1,0.772549,0.239216))}), Rotation=90, Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0.00,0.00),NumberSequenceKeypoint.new(1.00,0.00)}) } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/Speed/UIGradient", Class = "UIGradient", Props = { Color=ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.new(1,1,1)),ColorSequenceKeypoint.new(1,Color3.new(1,0.772549,0.239216))}), Rotation=90, Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0.00,0.00),NumberSequenceKeypoint.new(1.00,0.00)}) } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/Speed/UIStroke", Class = "UIStroke", Props = { Thickness=2, Transparency=0.5 } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/Frame/Frame/UICorner", Class = "UICorner", Props = { BottomLeftRadius=UDim.new(0,4), BottomRightRadius=UDim.new(0,4), TopLeftRadius=UDim.new(0,4), TopRightRadius=UDim.new(0,4) } },
	{ Path = "CharacterStatus/BottomLeft/Speedometer/Front/Frame/UICorner", Class = "UICorner", Props = { BottomLeftRadius=UDim.new(0,4), BottomRightRadius=UDim.new(0,4), TopLeftRadius=UDim.new(0,4), TopRightRadius=UDim.new(0,4) } },
}

local function enumFromValue(enumType, value)
	for _, item in enumType:GetEnumItems() do
		if item.Value == value then
			return item
		end
	end
	return nil
end

local function applyProp(inst, key, value)
	if type(value) == "table" and value.font then
		value = Font.new(value.font, enumFromValue(Enum.FontWeight, value.w) or Enum.FontWeight.Regular, enumFromValue(Enum.FontStyle, value.s) or Enum.FontStyle.Normal)
	elseif type(value) == "number" then
		local ok, cur = pcall(function()
			return inst[key]
		end)
		if ok and typeof(cur) == "EnumItem" then
			value = enumFromValue(cur.EnumType, value)
			if value == nil then
				return
			end
		end
	end
	pcall(function()
		inst[key] = value
	end)
end

function UI.BuildNative()
	-- ScreenGui "Game" -> HUD -> Overlay (MEASURED: ScreenInsets CoreUISafeInsets, ZIndexBehavior Global)
	local gui = make("ScreenGui", {
		Name = hiddenName(), ResetOnSpawn = false,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets, ClipToDeviceSafeArea = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Global, DisplayOrder = 0,
	})
	local hud = make("Frame", { Name = "HUD", BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) })
	hud.Parent = gui
	local overlay = make("Frame", { Name = "Overlay", BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) })
	overlay.Parent = hud
	local byPath = {}
	for _, row in EVADE_HUD do
		local ok, inst = pcall(Instance.new, row.Class)
		if ok and inst then
			local parentPath, name = string.match(row.Path, "^(.*)/([^/]+)$")
			inst.Name = name or row.Path
			for key, value in row.Props do
				applyProp(inst, key, value)
			end
			inst.Parent = parentPath and byPath[parentPath] or overlay
			byPath[row.Path] = inst
		end
	end
	return gui
end

function UI.Resolve(gui, path)
	if type(path) ~= "string" then
		return nil
	end
	local node = gui
	for part in string.gmatch(path, "[^/]+") do
		node = node and node:FindFirstChild(part)
	end
	return node
end

function UI.LoadCustom()
	for _, name in { "HUD.rbxm", "HUD.rbxmx" } do
		local path = Assets.Path("UI", name)
		if Assets.IsFile(path) then
			local objects = Assets.LoadObjects(path)
			if objects then
				local root = objects[1]
				if root:IsA("ScreenGui") then
					return root
				end
				local gui = make("ScreenGui", { Name = hiddenName(), ResetOnSpawn = false, ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets, ClipToDeviceSafeArea = true, ZIndexBehavior = Enum.ZIndexBehavior.Global })
				for _, o in objects do
					o.Parent = gui
				end
				return gui
			end
		end
	end
	return nil
end

function UI.Init(maid)
	if not CONFIG.UI.Enabled then
		return
	end
	local gui = UI.LoadCustom()
	local source = "UI/HUD.rbxm"
	if gui then
		if not (UI.Resolve(gui, UIMap.Speed) and UI.Resolve(gui, UIMap.Health)) then
			Log.warn("UI", "custom HUD is missing the Speed or Health role from UIMap; using Evade native layout")
			gui:Destroy()
			gui = nil
		end
	end
	if not gui then
		gui = UI.BuildNative()
		source = "native Evade layout"
	end
	gui.Name = hiddenName()
	local parent, how = guiParent(gui)
	gui.Parent = parent
	maid:Give(gui)
	UI.Gui = gui
	for role, path in UIMap do
		if path ~= false then
			local el = UI.Resolve(gui, path)
			UI.Elements[role] = el
			if not el then
				Log.warnOnce("ui:" .. role, "UI", ("role %s not found at %s (skipped)"):format(role, tostring(path)))
			end
		end
	end
	Log.info("UI", ("HUD from %s mounted in %s"):format(source, how))
	UI.Speed, UI.HealthValue = nil, nil
	UI.BuildSettings(maid, parent)
end

--------------------------------------------------------------------------------
-- Settings panel (P): FOV slider 70-100 (Evade's FOV setting).  Saved to <Root>/settings.json.
-- The panel's Modal button frees the mouse while it is open, in first and third person.
--------------------------------------------------------------------------------
local SETTINGS_FILE = "settings.json"

function UI.LoadSettings()
	local text = Assets.ReadFile(Assets.Path(SETTINGS_FILE))
	if not text then
		return
	end
	local ok, data = pcall(function()
		return getService("HttpService"):JSONDecode(text)
	end)
	if ok and type(data) == "table" and tonumber(data.FOV) then
		CONFIG.Camera.BaseFOV = clamp(tonumber(data.FOV), CONFIG.Camera.FOVMin, CONFIG.Camera.FOVMax)
	end
end

function UI.SaveSettings()
	local ok, text = pcall(function()
		return getService("HttpService"):JSONEncode({ FOV = CONFIG.Camera.BaseFOV })
	end)
	if ok then
		Assets.WriteFile(Assets.Path(SETTINGS_FILE), text)
	end
end

function UI.BuildSettings(maid, parent)
	local c = CONFIG.Camera
	local gui = make("ScreenGui", { Name = hiddenName(), ResetOnSpawn = false, Enabled = false, DisplayOrder = 10, ZIndexBehavior = Enum.ZIndexBehavior.Global })
	local panel = make("TextButton", {
		-- Modal frees the locked mouse.  It is only switched on while the panel is open: a Modal button
		-- inside a disabled ScreenGui still kept the cursor unlocked, so third-person mouse look needed RMB.
		Name = "Panel", Text = "", AutoButtonColor = false, Modal = false,
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(360, 150),
		BackgroundColor3 = Color3.fromRGB(20, 20, 24), BackgroundTransparency = 0.1, BorderSizePixel = 0,
	}, { corner(0, 12), make("UIStroke", { Color = Color3.fromRGB(255, 255, 255), Transparency = 0.85, Thickness = 1 }) })
	panel.Parent = gui
	local function label(props)
		props.BackgroundTransparency = 1
		props.FontFace = GOTHAM_BOLD
		props.TextColor3 = props.TextColor3 or Color3.fromRGB(235, 235, 240)
		local l = make("TextLabel", props)
		l.Parent = panel
		return l
	end
	label({ Text = "SETTINGS", TextSize = 18, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(20, 14), Size = UDim2.fromOffset(200, 22) })
	local close = make("TextButton", {
		Text = "X", TextSize = 16, FontFace = GOTHAM_BOLD, TextColor3 = Color3.fromRGB(200, 200, 205), AutoButtonColor = true,
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 10), Size = UDim2.fromOffset(28, 28),
		BackgroundColor3 = Color3.fromRGB(45, 45, 52), BorderSizePixel = 0,
	}, { corner(0, 6) })
	close.Parent = panel
	label({ Text = "Field of View", TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(20, 56), Size = UDim2.fromOffset(200, 20) })
	local valueText = label({ Text = "", TextSize = 15, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20, 0, 56), Size = UDim2.fromOffset(80, 20), TextColor3 = Color3.fromRGB(112, 255, 73) })
	local bar = make("TextButton", {
		Name = "Bar", Text = "", AutoButtonColor = false, Position = UDim2.fromOffset(20, 92), Size = UDim2.new(1, -40, 0, 10),
		BackgroundColor3 = Color3.fromRGB(60, 60, 70), BorderSizePixel = 0,
	}, { corner(1, 0) })
	bar.Parent = panel
	local fill = make("Frame", { BackgroundColor3 = Color3.fromRGB(112, 255, 73), BorderSizePixel = 0, Size = UDim2.fromScale(0, 1) }, { corner(1, 0) })
	fill.Parent = bar
	local knob = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(18, 18),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255), BorderSizePixel = 0, ZIndex = 2,
	}, { corner(1, 0) })
	knob.Parent = bar
	label({ Text = ("%d"):format(c.FOVMin), TextSize = 12, TextColor3 = Color3.fromRGB(140, 140, 150), TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(20, 110), Size = UDim2.fromOffset(40, 16) })
	label({ Text = ("%d"):format(c.FOVMax), TextSize = 12, TextColor3 = Color3.fromRGB(140, 140, 150), TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20, 0, 110), Size = UDim2.fromOffset(40, 16) })

	local function render()
		local a = (c.BaseFOV - c.FOVMin) / (c.FOVMax - c.FOVMin)
		fill.Size = UDim2.fromScale(a, 1)
		knob.Position = UDim2.fromScale(a, 0.5)
		valueText.Text = ("%d"):format(c.BaseFOV)
	end
	local function setFromX(x)
		local a = clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
		c.BaseFOV = math.floor(c.FOVMin + a * (c.FOVMax - c.FOVMin) + 0.5)
		render()
	end
	local dragging = false
	maid:Give(bar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end))
	maid:Give(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end))
	maid:Give(UserInputService.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			UI.SaveSettings()
		end
	end))
	maid:Give(close.MouseButton1Click:Connect(function()
		UI.ToggleSettings(false)
	end))
	render()
	gui.Parent = parent
	maid:Give(gui)
	maid:Give(function()
		Shared.SettingsOpen = false
	end)
	UI.SettingsGui = gui
	UI.RenderSettings = render
end

function UI.ToggleSettings(open)
	local gui = UI.SettingsGui
	if not gui then
		return
	end
	if open == nil then
		open = not gui.Enabled
	end
	if open == gui.Enabled then
		return
	end
	gui.Enabled = open
	gui.Panel.Modal = open
	Shared.SettingsOpen = open
	if open then
		-- Roblox's camera caches the mouse mode it last set and won't reapply it, so remember it here
		-- and put it back on close (otherwise first person stays unlocked).
		UI.MouseBehaviorBeforeSettings = UserInputService.MouseBehavior
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UI.RenderSettings()
	else
		UserInputService.MouseBehavior = UI.MouseBehaviorBeforeSettings or Enum.MouseBehavior.Default
		UI.SaveSettings()
	end
end

-- CharacterStatus.SetSpeed: floor to 0.1, comma format, resize Front to text width. No tween.
function UI.SetSpeed(value)
	local el = UI.Elements
	if not el.Speed then
		return
	end
	value = math.floor(value * 10) / 10
	if UI.Speed == value then
		return
	end
	UI.Speed = value
	el.Speed.Text = commaval(value)
	if el.SpeedFront then
		el.SpeedFront.Size = UDim2.new(0.5, el.Speed.TextBounds.X, 1, 0)
	end
end

-- CharacterStatus.SetHealth: raw tostring, red under 25 else green on icon/text/stroke. No tween.
function UI.SetHealth(value, maxHealth)
	local el = UI.Elements
	-- Evade's server keeps health integral; a stock Humanoid regenerates fractionally, so round up
	-- (never shows 0 while alive).
	value = math.max(math.ceil(value - 1e-6), 0)
	if UI.HealthValue == value then
		return
	end
	UI.HealthValue = value
	local color = value < 25 and Color3.fromRGB(255, 78, 78) or Color3.fromRGB(112, 255, 73)
	if el.Health then
		el.Health.Text = tostring(value)
		el.Health.TextColor3 = color
	end
	if el.HealthIcon then
		el.HealthIcon.ImageColor3 = color
	end
	if el.HealthStroke then
		el.HealthStroke.Color = color
	end
	if el.HealthFill and maxHealth and maxHealth > 0 then
		el.HealthFill.Size = UDim2.new(clamp(value / maxHealth, 0, 1), 0, el.HealthFill.Size.Y.Scale, el.HealthFill.Size.Y.Offset)
	end
end

function UI.SetVisible(visible)
	if UI.Elements.Root then
		UI.Elements.Root.Visible = visible
	end
end

--==============================================================================
-- SECTION 15 : CHARACTER (Objects/Game/Character: build modules, per-frame update in Evade order)
--==============================================================================
local Character = {}
Character.__index = Character

function Character.new(model)
	local self = setmetatable({ Character = model, Maid = Maid.new(), HealthOverride = nil }, Character)
	self.Registry = Registry.new(function(term, value)
		self:TermUpdated(term, value)
	end)
	return self
end

-- Emulated Evade hull (see CONFIG.Hull). CenterToFloor = HRP centre height above the floor on this rig.
function Character:ComputeRigMetrics()
	local hum, root = self.Humanoid, self.Root
	if hum.HipHeight <= 0 and root.Size.Y >= 3 then
		self.CenterToFloor = root.Size.Y / 2 -- Evade-style full-body root
	elseif hum.RigType == Enum.HumanoidRigType.R15 then
		self.CenterToFloor = hum.HipHeight + root.Size.Y / 2
	else
		local leg = self.Character:FindFirstChild("Left Leg") or self.Character:FindFirstChild("Right Leg")
		self.CenterToFloor = root.Size.Y / 2 + (leg and leg.Size.Y or 2) + math.max(hum.HipHeight, 0)
	end
	self.SizeScale = 1
	self.RootSize = CONFIG.Hull.StandSize
	self.RootSizeGoal = nil
	self.RootDelay = nil
end
function Character:HullCenter()
	return self.Root.Position - Vector3.new(0, self.CenterToFloor - self.RootSize.Y / 2, 0)
end
function Character:HullSize()
	return Vector3.new(CONFIG.Hull.StandSize.X * self.SizeScale, self.RootSize.Y, CONFIG.Hull.StandSize.Z * self.SizeScale)
end
-- HRP.CamPart (Evade's animated camera Motor6D) — identity on rigs that don't have it.
function Character:CamPartTransform()
	local cp = self.Root:FindFirstChild("CamPart")
	if cp and cp:IsA("Motor6D") then
		return cp.Transform
	end
	return CFrame.identity
end

function Character:TermUpdated(term, value)
	if term == "State" then
		if self.Animator then
			self.Animator:OnStateChanged(value)
		end
	elseif term == "Speed" then
		UI.SetSpeed(value)
	elseif term == "Health" then
		UI.SetHealth(value, self.Humanoid and self.Humanoid.MaxHealth)
	end
end

function Character:Init()
	local model = self.Character
	self.Humanoid = model:WaitForChild("Humanoid", 10)
	self.Root = model:WaitForChild("HumanoidRootPart", 10)
	if not self.Humanoid or not self.Root then
		Log.warn("Character", "Humanoid/HumanoidRootPart not found; character skipped")
		return false
	end
	local hum = self.Humanoid
	local saved = {
		WalkSpeed = hum.WalkSpeed, JumpHeight = hum.JumpHeight, JumpPower = hum.JumpPower,
		UseJumpPower = hum.UseJumpPower, AutoRotate = hum.AutoRotate, States = {},
	}
	for _, st in CONFIG.Movement.DisableHumanoidStates do
		saved.States[st] = hum:GetStateEnabled(st)
	end
	saved.States[Enum.HumanoidStateType.Jumping] = hum:GetStateEnabled(Enum.HumanoidStateType.Jumping)
	self.Maid:Give(function()
		if hum.Parent then
			pcall(function()
				hum.WalkSpeed = saved.WalkSpeed
				hum.UseJumpPower = saved.UseJumpPower
				hum.JumpHeight = saved.JumpHeight
				hum.JumpPower = saved.JumpPower
				hum.AutoRotate = saved.AutoRotate
				for st, enabled in saved.States do
					hum:SetStateEnabled(st, enabled)
				end
			end)
		end
	end)
	self:ComputeRigMetrics()
	self.Registry:Set("LookCFrame", workspace.CurrentCamera.CFrame)
	self.Registry:Set("ActualVelocity", Vector3.zero)

	self.Movement = Movement.new(self)
	self.Movement:Init(self.Maid)
	self.Maid:Give(self.Movement)
	self.Camera = CameraFX.new(self)
	self.Camera:Init(self.Maid)
	self.Footsteps = Footsteps.new(self)
	self.Footsteps:Init(self.Maid, Assets.FootstepOverrides)
	self.Animator = Animator.new(self)
	self.Animator:Init(self.Maid)
	self.Animator:OnStateChanged(self.Registry:Get("State"))

	self.Maid:Give(hum.Died:Connect(function()
		UI.SetVisible(false)
	end))
	UI.SetVisible(true)
	self.Maid:Give(Players.PlayerAdded:Connect(function(p)
		p.CharacterAdded:Connect(function()
			if self.Movement then
				self.Movement:RefreshFilters()
			end
		end)
	end))
	for _, p in Players:GetPlayers() do
		if p ~= LocalPlayer then
			self.Maid:Give(p.CharacterAdded:Connect(function()
				task.defer(function()
					if self.Movement and not self.Movement.Destroyed then
						self.Movement:RefreshFilters()
					end
				end)
			end))
		end
	end
	Log.info("Character", ("initialised (%s rig, centre-to-floor %.2f)"):format(self.Animator.RigType, self.CenterToFloor))
	return true
end

-- Camera base restore (RenderPriority.First) so the default camera never integrates our offset.
function Character:PreCamera()
	if self.AppliedBase then
		local cam = workspace.CurrentCamera
		if cam.CFrame == self.AppliedFinal then
			cam.CFrame = self.AppliedBase
		end
		self.AppliedBase = nil
	end
end

-- Character:Update(dt) — Evade order.
function Character:Update(dt)
	if self.Destroyed or not self.Root or not self.Root.Parent then
		return
	end
	local R = self.Registry
	local cam = workspace.CurrentCamera
	if self.Camera.ThirdPerson then
		self.Camera:UpdateThirdPerson(dt)
	end
	R:Set("Health", self.HealthOverride or self.Humanoid.Health)
	R:Set("LookCFrame", cam.CFrame)
	local av = self.Root.AssemblyLinearVelocity
	R:Set("ActualVelocity", av)
	R:Set("ActualVelocityMagnitude", av.Magnitude)

	self.Movement:UpdateTerms()
	self.Movement:StateUpdate(dt)
	self.Movement:Update(dt)
	self.Camera:UpdateType()
	self.Animator:Update(dt)
	Remotes.Flush()
	self.Camera:Update(dt)

	-- Apply camera deviation (SetCameraOffset("Viewmodel")) on top of the default camera's result.
	local base = cam.CFrame
	local final = base * self.Camera.Offset
	cam.CFrame = final
	self.AppliedBase, self.AppliedFinal = base, final
end

function Character:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	self:PreCamera()
	self.Maid:Clean()
	UI.Speed, UI.HealthValue = nil, nil
end

--==============================================================================
-- SECTION 16 : VALIDATION (F8 logger, REAL/CLONE CSV, jump-aligned comparison, >5 % alerts)
--==============================================================================
local Validation = { Recording = false, Rows = {}, JumpTimes = {} }
local CSV_HEADER = "t,hspeed,vspeed,grounded,jumps,slots,speedtext,healthfill,healthtext,fov,roll,remote_in,remote_out"

-- Reverse lookup Evade AnimationId -> slot (REAL mode names Evade's own tracks).
local EVADE_ID_TO_SLOT = {}
for _, set in EVADE.AnimationIds do
	for slot, id in set do
		EVADE_ID_TO_SLOT[string.match(id, "%d+$")] = slot
	end
end

local function findPath(root, path)
	local node = root
	for part in string.gmatch(path, "[^/]+") do
		node = node and node:FindFirstChild(part)
	end
	return node
end

function Validation.Sample(state)
	local t = os.clock() - Validation.StartTime
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum then
		return
	end
	local av = root.AssemblyLinearVelocity
	local cam = workspace.CurrentCamera
	local _, _, roll = cam.CFrame:ToOrientation()
	local row = {
		t = t, hspeed = flat(av).Magnitude, vspeed = av.Y, jumps = #Validation.JumpTimes,
		fov = cam.FieldOfView, roll = math.deg(roll), healthfill = hum.MaxHealth > 0 and hum.Health / hum.MaxHealth or 0,
	}
	local slots, speedText, healthText = {}, nil, nil
	if CONFIG.Mode == "REAL" then
		-- Grounded: same 5-ray test on the emulated hull.
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = buildExcludeList(char)
		params.RespectCanCollide = true
		local ctf = (hum.HipHeight <= 0 and root.Size.Y >= 3) and root.Size.Y / 2 or (hum.HipHeight + root.Size.Y / 2)
		local center = root.Position - Vector3.new(0, ctf - 2, 0)
		local g = false
		for _, o in GROUND_OFFSETS do
			if workspace:Raycast(center + o * 2, Vector3.new(0, -CONFIG.Movement.GroundedDistCheck, 0), params) then
				g = true
				break
			end
		end
		row.grounded = g and 1 or 0
		local animator = hum:FindFirstChildOfClass("Animator")
		for _, track in animator and animator:GetPlayingAnimationTracks() or {} do
			local id = track.Animation and string.match(track.Animation.AnimationId, "%d+$")
			local slot = id and EVADE_ID_TO_SLOT[id] or ("id:" .. tostring(id))
			if track.WeightCurrent > 0.05 then
				table.insert(slots, slot)
			end
			if id and not Validation.TrackInfo[slot] then
				Validation.TrackInfo[slot] = { id = id, length = track.Length, priority = track.Priority.Name, looped = track.Looped }
			end
		end
		local pg = LocalPlayer:FindFirstChild("PlayerGui")
		local speedLabel = pg and findPath(pg, "Game/HUD/Overlay/CharacterStatus/BottomLeft/Speedometer/Speed")
		local healthLabel = pg and findPath(pg, "Game/HUD/Overlay/CharacterStatus/BottomLeft/Health/Health")
		speedText = speedLabel and speedLabel.Text
		healthText = healthLabel and healthLabel.Text
	else
		row.grounded = (state and state.Registry:Get("Grounded")) and 1 or 0
		slots = state and state.Animator:ActiveSlots() or {}
		speedText = UI.Elements.Speed and UI.Elements.Speed.Text
		healthText = UI.Elements.Health and UI.Elements.Health.Text
	end
	table.sort(slots)
	row.slots = table.concat(slots, "|")
	row.speedtext = speedText and tonumber((string.gsub(speedText, ",", ""))) or -1
	row.healthtext = healthText and tonumber(healthText) or -1
	row.remote_in, row.remote_out = Remotes.TotalFires()
	table.insert(Validation.Rows, row)
end

function Validation.ToCSV(rows)
	local lines = { CSV_HEADER }
	for _, r in rows do
		table.insert(lines, ("%.3f,%.3f,%.3f,%d,%d,%s,%.1f,%.4f,%.2f,%.3f,%.4f,%d,%d"):format(
			r.t, r.hspeed, r.vspeed, r.grounded, r.jumps, r.slots, r.speedtext, r.healthfill, r.healthtext, r.fov, r.roll, r.remote_in, r.remote_out))
	end
	return table.concat(lines, "\n")
end
function Validation.FromCSV(text)
	local rows = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		if string.sub(line, 1, 2) ~= "t," then
			local f = string.split(line, ",")
			if #f >= 13 then
				table.insert(rows, {
					t = tonumber(f[1]), hspeed = tonumber(f[2]), vspeed = tonumber(f[3]), grounded = tonumber(f[4]),
					jumps = tonumber(f[5]), slots = f[6], speedtext = tonumber(f[7]), healthfill = tonumber(f[8]),
					healthtext = tonumber(f[9]), fov = tonumber(f[10]), roll = tonumber(f[11]), remote_in = tonumber(f[12]), remote_out = tonumber(f[13]),
				})
			end
		end
	end
	return rows
end

-- Per-jump metrics, aligned by jump index (a jump = jumps counter increment).
local function expectedFOV(hs)
	return CONFIG.Camera.BaseFOV * lerp(1, CONFIG.Camera.SprintFOVMax, clamp((hs - CONFIG.Camera.SprintFOVStart) / CONFIG.Camera.SprintFOVRange, 0, 1))
end
function Validation.Segments(rows)
	local segs = {}
	local startIdx = {}
	for i, r in rows do
		if i > 1 and r.jumps > rows[i - 1].jumps then
			table.insert(startIdx, i)
		end
	end
	for k, s in startIdx do
		local e = (startIdx[k + 1] or (#rows + 1)) - 1
		local peak, sum, n, txtErr, fovErr = 0, 0, 0, 0, 0
		local landIdx
		local slotLatency
		for i = s, e do
			local r = rows[i]
			peak = math.max(peak, r.hspeed)
			sum += r.hspeed
			n += 1
			if r.speedtext >= 0 then
				txtErr += math.abs(r.speedtext - r.hspeed)
			end
			fovErr += math.abs(r.fov - expectedFOV(r.hspeed))
			if not landIdx and i > s and r.grounded == 1 and rows[i - 1].grounded == 0 then
				landIdx = i
			end
			if not slotLatency and string.find(r.slots, "Jumping/Jump", 1, true) then
				slotLatency = r.t - rows[s].t
			end
		end
		local seg = {
			PeakSpeed = peak, MeanSpeed = n > 0 and sum / n or 0,
			SpeedTextError = n > 0 and txtErr / n or 0, FOVError = n > 0 and fovErr / n or 0,
			SlotLatency = slotLatency or (rows[e].t - rows[s].t),
		}
		if landIdx then
			local airtime = rows[landIdx].t - rows[s].t
			seg.Airtime = airtime
			seg.AirStrafeGain = airtime > 0 and (rows[landIdx].hspeed - rows[s].hspeed) / airtime or 0
			local nextStart = startIdx[k + 1]
			if nextStart and rows[landIdx].hspeed > 0 then
				seg.LandingRetention = rows[nextStart].hspeed / rows[landIdx].hspeed
			end
		end
		table.insert(segs, seg)
	end
	return segs
end

local METRIC_PARAM = {
	PeakSpeed = "CONFIG.Movement.AirStrafeAcceleration / JumpSpeedMultiplier",
	MeanSpeed = "CONFIG.Movement.Speed / SprintCap / SprintAcceleration",
	LandingRetention = "CONFIG.Movement.Friction / RunDeaccel (ground frames)",
	AirStrafeGain = "CONFIG.Movement.AirStrafeAcceleration / AirAcceleration",
	Airtime = "CONFIG.Movement.JumpHeight (and workspace.Gravity)",
	SlotLatency = "AnimationMap['Jumping/Jump'] / EVADE.AnimInfo Jumping.PlayTransitionTime",
	SpeedTextError = "UIMap.Speed (label path) / VelocityScale",
	FOVError = "CONFIG.Camera.SprintFOVMax / SprintFOVStart / SprintFOVRange / SprintFOVRate",
}
local METRIC_ORDER = { "PeakSpeed", "MeanSpeed", "LandingRetention", "AirStrafeGain", "Airtime", "SlotLatency", "SpeedTextError", "FOVError" }

local function stats(segs, key, maxN)
	local vals = {}
	for i, s in segs do
		if i <= maxN and s[key] ~= nil then
			table.insert(vals, s[key])
		end
	end
	if #vals == 0 then
		return nil
	end
	local sum = 0
	for _, v in vals do
		sum += v
	end
	local mean = sum / #vals
	local var = 0
	for _, v in vals do
		var += (v - mean) ^ 2
	end
	return mean, math.sqrt(var / math.max(#vals - 1, 1)), #vals
end

function Validation.Compare(realRows, cloneRows)
	local rs, cs = Validation.Segments(realRows), Validation.Segments(cloneRows)
	local n = math.min(#rs, #cs)
	local out = { ("==== EvadeClone validation: %d aligned jumps (REAL %d, CLONE %d) ===="):format(n, #rs, #cs) }
	if n == 0 then
		table.insert(out, "No aligned jumps: make sure both runs contain at least one jump.")
		return table.concat(out, "\n")
	end
	table.insert(out, ("%-17s %12s %12s %9s %9s  %s"):format("metric", "real", "clone", "delta%", "allow%", "status"))
	for _, key in METRIC_ORDER do
		local rm, rsd = stats(rs, key, n)
		local cm = stats(cs, key, n)
		if rm and cm then
			local denom = math.max(math.abs(rm), 1e-6)
			local delta = math.abs(cm - rm) / denom
			local allow = CONFIG.Validation.Threshold + (rsd or 0) / denom
			local status = delta > allow and ("DIVERGES -> adjust " .. METRIC_PARAM[key]) or "ok"
			table.insert(out, ("%-17s %12.3f %12.3f %8.1f%% %8.1f%%  %s"):format(key, rm, cm, delta * 100, allow * 100, status))
		else
			table.insert(out, ("%-17s %12s %12s %9s %9s  %s"):format(key, rm and ("%.3f"):format(rm) or "n/a", cm and ("%.3f"):format(cm) or "n/a", "-", "-", "insufficient data"))
		end
	end
	return table.concat(out, "\n")
end

function Validation.Stop()
	if not Validation.Recording then
		return
	end
	Validation.Recording = false
	if Validation.Conn then
		Validation.Conn:Disconnect()
		Validation.Conn = nil
	end
	if Validation.JumpConn then
		Validation.JumpConn:Disconnect()
		Validation.JumpConn = nil
	end
	local modeName = CONFIG.Mode == "REAL" and "real" or "clone"
	Log.info("Validation", ("stopped: %d samples, %d jumps"):format(#Validation.Rows, #Validation.JumpTimes))
	if CONFIG.Validation.ExportCSV then
		Assets.WriteFile(Assets.Path("Logs", modeName .. ".csv"), Validation.ToCSV(Validation.Rows))
		Log.info("Validation", ("exported Logs/%s.csv"):format(modeName))
		if CONFIG.Mode == "REAL" then
			local lines = { "slot,id,length,priority,looped" }
			for slot, info in Validation.TrackInfo do
				table.insert(lines, ("%s,%s,%.4f,%s,%s"):format(slot, info.id, info.length, info.priority, tostring(info.looped)))
			end
			Assets.WriteFile(Assets.Path("Logs", "evade_tracks.csv"), table.concat(lines, "\n"))
			Log.info("Validation", "exported Logs/evade_tracks.csv (Evade track lengths/priorities)")
		end
	end
	if CONFIG.Mode == "CLONE" and CONFIG.Validation.AutoCompare then
		local text = Assets.ReadFile(Assets.Path("Logs", "real.csv"))
		if text then
			local report = Validation.Compare(Validation.FromCSV(text), Validation.Rows)
			print(report)
			Assets.WriteFile(Assets.Path("Logs", "report.txt"), report)
		else
			Log.info("Validation", "no Logs/real.csv yet: record a REAL run inside Evade to compare")
		end
	end
end

function Validation.Start(getState)
	if not CONFIG.Validation.Enabled or Validation.Recording then
		return
	end
	Validation.Recording = true
	Validation.Rows, Validation.JumpTimes, Validation.TrackInfo = {}, {}, {}
	Validation.StartTime = os.clock()
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		Validation.JumpConn = hum.StateChanged:Connect(function(_, new)
			if new == Enum.HumanoidStateType.Jumping then
				table.insert(Validation.JumpTimes, os.clock() - Validation.StartTime)
			end
		end)
	end
	local acc = 0
	Validation.Conn = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		while acc >= CONFIG.Validation.SampleInterval do
			acc -= CONFIG.Validation.SampleInterval
			local ok, err = pcall(Validation.Sample, getState())
			if not ok then
				Log.warnOnce("val-sample", "Validation", tostring(err))
			end
		end
		if os.clock() - Validation.StartTime >= CONFIG.Validation.Duration then
			Validation.Stop()
		end
	end)
	Log.info("Validation", ("recording %s for %ds every %.2fs (F8 to stop early)"):format(CONFIG.Mode, CONFIG.Validation.Duration, CONFIG.Validation.SampleInterval))
end

--==============================================================================
-- SECTION 17 : BOOTSTRAP + CLEANUP
--==============================================================================
local App = { Maid = Maid.new(), Current = nil }

local function teardownCharacter()
	if App.Current then
		App.Current:Destroy()
		App.Current = nil
	end
end

local function setupCharacter(model)
	teardownCharacter()
	if CONFIG.Mode ~= "CLONE" then
		return
	end
	local c = Character.new(model)
	local ok, res = pcall(c.Init, c)
	if ok and res then
		App.Current = c
	else
		if not ok then
			Log.warn("Character", "init error: " .. tostring(res))
		end
		c:Destroy()
	end
end

local function bindInput()
	local function isKey(list, input)
		for _, k in list do
			if input.KeyCode == k then
				return true
			end
		end
		return false
	end
	App.Maid:Give(UserInputService.JumpRequest:Connect(function()
		local c = App.Current
		if c and c.Movement then
			task.spawn(c.Movement.JumpReact, c.Movement)
		end
	end))
	App.Maid:Give(UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == CONFIG.Keys.Validation then
			if Validation.Recording then
				Validation.Stop()
			else
				Validation.Start(function()
					return App.Current
				end)
			end
			return
		end
		if input.KeyCode == CONFIG.Keys.Unload and not processed then
			GENV.EvadeClone.Unload()
			return
		end
		local c = App.Current
		if not c or processed then
			return
		end
		if input.KeyCode == CONFIG.Keys.GamepadJump then
			task.spawn(c.Movement.JumpReact, c.Movement, true)
			c.Movement.XboxJumping = true
		elseif isKey(CONFIG.Keys.Crouch, input) then
			c.Registry:Set("CrouchKey", true)
		elseif isKey(CONFIG.Keys.ThirdPerson, input) then
			c.Camera:ToggleThirdPerson()
		end
	end))
	App.Maid:Give(UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == CONFIG.Keys.Settings and not processed then
			UI.ToggleSettings()
		end
	end))
	App.Maid:Give(UserInputService.InputChanged:Connect(function(input, processed)
		local c = App.Current
		if not c then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel and not processed and not Shared.SettingsOpen then
			c.Camera:OnWheel(input.Position.Z)
		elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
			c.Camera.GamepadLook = Vector2.new(input.Position.X, input.Position.Y)
		end
	end))
	App.Maid:Give(UserInputService.InputEnded:Connect(function(input)
		local c = App.Current
		if not c then
			return
		end
		if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == CONFIG.Keys.GamepadJump then
			c.Movement.XboxJumping = false
			c.Movement.JumpHeldDown = false
		elseif isKey(CONFIG.Keys.Crouch, input) then
			c.Registry:Set("CrouchKey", false)
		end
	end))
	-- Touch jump button releases (mobile) also end the hold.
	App.Maid:Give(UserInputService.TouchEnded:Connect(function()
		local c = App.Current
		if c and not UserInputService:IsKeyDown(Enum.KeyCode.Space) then
			c.Movement.JumpHeldDown = false
		end
	end))
end

local function installRemoteHandlers()
	Remotes.Handlers.HealthUpdate = function(...)
		local c = App.Current
		for _, a in { ... } do
			if type(a) == "number" and c then
				c.HealthOverride = a
				return
			end
		end
	end
	Remotes.Handlers.VelocityCorrection = function(...)
		local c = App.Current
		for _, a in { ... } do
			if typeof(a) == "Vector3" and c then
				c.Movement:ApplyCorrection(a)
				return
			end
		end
	end
	Remotes.Handlers.Respawn = function()
		local char = LocalPlayer.Character
		if char then
			task.defer(setupCharacter, char)
		end
	end
end

local function unload()
	Validation.Stop()
	pcall(RunService.UnbindFromRenderStep, RunService, PRECAMERA_BIND)
	pcall(RunService.UnbindFromRenderStep, RunService, CHARACTER_BIND)
	teardownCharacter()
	App.Maid:Clean()
	if GENV.EvadeClone and GENV.EvadeClone.Unload == unload then
		GENV.EvadeClone = nil
	end
	Log.info("Cleanup", "unloaded: connections, remotes, tracks, UI, camera and humanoid state restored")
end

local function main()
	capabilityReport()
	GENV.EvadeClone = {
		Unload = unload, Config = CONFIG, Version = VERSION, Validation = Validation,
		Current = function() -- debug/testing: the live Character (Camera, Movement, Registry, ...)
			return App.Current
		end,
	}
	Assets.EnsureFolders()
	UI.LoadSettings()
	Assets.DownloadAnimations()
	Assets.LoadEvadeTrackLengths()
	Assets.FootstepOverrides = Assets.LoadFootstepOverrides()
	Input.Init()
	installRemoteHandlers()
	Remotes.Init(App.Maid)
	bindInput()

	if CONFIG.Mode == "CLONE" then
		UI.Init(App.Maid)
		RunService:BindToRenderStep(PRECAMERA_BIND, Enum.RenderPriority.First.Value, function()
			local c = App.Current
			if c then
				c:PreCamera()
			end
		end)
		RunService:BindToRenderStep(CHARACTER_BIND, Enum.RenderPriority.Camera.Value + 1, function(dt)
			local c = App.Current
			if c then
				local ok, err = pcall(c.Update, c, dt)
				if not ok then
					Log.warnOnce("update:" .. tostring(err), "Character", "update error: " .. tostring(err))
				end
			end
		end)
		App.Maid:Give(LocalPlayer.CharacterAdded:Connect(setupCharacter))
		App.Maid:Give(LocalPlayer.CharacterRemoving:Connect(teardownCharacter))
		if LocalPlayer.Character then
			task.spawn(setupCharacter, LocalPlayer.Character)
		end
	else
		Log.info("Boot", "REAL mode: engine idle, press F8 to log the unmodified character")
	end
	Log.info("Boot", ("ready. F8 = validation log, %s = unload"):format(CONFIG.Keys.Unload.Name))
end

local ok, err = pcall(main)
if not ok then
	Log.warn("Boot", "startup error (unloading): " .. tostring(err))
	pcall(unload)
end
