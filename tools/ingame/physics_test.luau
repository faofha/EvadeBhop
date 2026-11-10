-- EvadeClone in-game physics checks on a client-only test floor (y = 1001) and wall (face at x = 299).
-- Drives input with VirtualInputManager and the camera with EvadeClone.Current().Camera (third person).
-- Run while EvadeClone is loaded:  loadstring(readfile("EvadeClone/physics_test.luau"))()
local arena = Instance.new("Folder")
arena.Name = "EvadeTestArena"
do
	local floor = Instance.new("Part")
	floor.Anchored, floor.Size, floor.CFrame = true, Vector3.new(2048, 2, 2048), CFrame.new(0, 1000, 0)
	floor.Parent = arena
	local wall = Instance.new("Part")
	wall.Anchored, wall.Size, wall.CFrame = true, Vector3.new(2, 30, 600), CFrame.new(300, 1016, 0)
	wall.Parent = arena
	arena.Parent = workspace
end
local returnTo = getgenv().EvadeClone.Current().Root.CFrame
local VIM = game:GetService("VirtualInputManager")
local RunService = game:GetService("RunService")
local E = getgenv().EvadeClone
local c = E.Current()
local cam = c.Camera
local hrp = c.Root

local function key(k, down) VIM:SendKeyEvent(down, k, false, game) end
local function tap(k) key(k, true) task.wait(0.03) key(k, false) end
local function hspeed() local v = hrp.AssemblyLinearVelocity return Vector3.new(v.X, 0, v.Z).Magnitude end
local function releaseAll()
	for _, k in { Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.C, Enum.KeyCode.Space } do key(k, false) end
end
local function reset(pos, yaw)
	releaseAll()
	if not cam.ThirdPerson then cam:ToggleThirdPerson() end
	cam.Yaw, cam.Pitch = yaw or 0, 0
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.CFrame = CFrame.new(pos or Vector3.new(0, 1005, 0)) * CFrame.fromOrientation(0, yaw or 0, 0)
	task.wait(0.8)
end
local function grounded() return c.Registry:Get("Grounded") end
local function state() return c.Registry:Get("State") end

local R = {}

-- A) sprint ramp + FOV (first-person FOV is what Evade scales; check the Sprint adjuster value)
reset(Vector3.new(-900, 1005, 0), math.rad(-90)) -- facing +X
key(Enum.KeyCode.W, true)
local samples = {}
for i = 1, 6 do task.wait(0.5) table.insert(samples, string.format("%.1f", hspeed())) end
R.A_sprint = { speeds_every_0_5s = table.concat(samples, " "), expect = "16.7 -> 33.3 over 2 s", sprintFOVmult = string.format("%.3f", cam.SprintFOV) }

-- B/C) ground jump at full sprint: boost and airtime
local before = hspeed()
key(Enum.KeyCode.Space, true)
local t0 = os.clock()
local peak, left, landT = 0, false, nil
while os.clock() - t0 < 2 do
	RunService.Heartbeat:Wait()
	peak = math.max(peak, hspeed())
	if not grounded() then left = true end
	if left and grounded() then landT = os.clock() - t0 break end
end
key(Enum.KeyCode.Space, false)
R.B_jump = { before = string.format("%.1f", before), peakAir = string.format("%.1f", peak), expect = "~44.3 (48.3 cap minus friction frame)" }
R.C_airtime = { seconds = landT and string.format("%.2f", landT) or "no landing", expect = "~0.67-0.69" }
key(Enum.KeyCode.W, false)

-- D) bhop chain: hold W, press space on each landing (no air-strafe)
reset(Vector3.new(-900, 1005, 40), math.rad(-90))
key(Enum.KeyCode.W, true)
task.wait(2.2)
local chain = { string.format("%.1f", hspeed()) }
for hop = 1, 5 do
	-- wait until grounded then press
	local t1 = os.clock()
	while not grounded() and os.clock() - t1 < 2 do RunService.Heartbeat:Wait() end
	tap(Enum.KeyCode.Space)
	task.wait(0.15)
	local t2 = os.clock()
	while not grounded() and os.clock() - t2 < 2 do RunService.Heartbeat:Wait() end
	table.insert(chain, string.format("%.1f", hspeed()))
end
R.D_bhop_W_held = { landing_speeds = table.concat(chain, " "), note = "Evade: holding W in air does nothing; loss expected without strafing" }
key(Enum.KeyCode.W, false)

-- E) air strafe: sprint, jump, release W, hold D and turn the camera right
reset(Vector3.new(-900, 1005, 80), math.rad(-90))
key(Enum.KeyCode.W, true)
task.wait(2.2)
key(Enum.KeyCode.Space, true)
task.wait(0.05)
key(Enum.KeyCode.W, false)
key(Enum.KeyCode.Space, false)
local startS = hspeed()
key(Enum.KeyCode.D, true)
local t3 = os.clock()
local maxS = startS
while os.clock() - t3 < 0.6 do
	local dt = RunService.Heartbeat:Wait()
	cam.Yaw -= math.rad(150) * dt -- turning right while strafing right
	maxS = math.max(maxS, hspeed())
	if grounded() and os.clock() - t3 > 0.1 then break end
end
key(Enum.KeyCode.D, false)
R.E_airstrafe = { start = string.format("%.1f", startS), max = string.format("%.1f", maxS), expect = "gain (> start)" }

-- F) slide decay
reset(Vector3.new(-900, 1005, 120), math.rad(-90))
key(Enum.KeyCode.W, true)
task.wait(2.3)
key(Enum.KeyCode.C, true)
task.wait(0.05)
key(Enum.KeyCode.W, false)
local slide = { string.format("%.1f", hspeed()) }
for i = 1, 3 do task.wait(0.5) table.insert(slide, string.format("%.1f(%s)", hspeed(), tostring(state()))) end
key(Enum.KeyCode.C, false)
R.F_slide = { every_0_5s = table.concat(slide, " "), expect = "33.3 -> 25.9 -> 20.2 then crouch" }

-- H) crouch walk speed
reset(Vector3.new(-900, 1005, 160), math.rad(-90))
key(Enum.KeyCode.C, true)
task.wait(0.4)
key(Enum.KeyCode.W, true)
task.wait(1.5)
R.H_crouch = { speed = string.format("%.1f", hspeed()), state = tostring(state()) }
releaseAll()

-- G) wallrun: sprint alongside the wall (face at x=299, on the left), jump, hold A toward it
reset(Vector3.new(297.4, 1005, -280), math.rad(180)) -- heading +Z
key(Enum.KeyCode.W, true)
task.wait(2.3)
key(Enum.KeyCode.Space, true) task.wait(0.05) key(Enum.KeyCode.Space, false)
key(Enum.KeyCode.A, true) -- Evade: hold the strafe key toward the wall
local wallT, t4 = 0, os.clock()
while os.clock() - t4 < 2.5 do
	local dt = RunService.Heartbeat:Wait()
	if tostring(state()):find("Wallrun") then wallT += dt end
end
releaseAll()
R.G_wallrun = { seconds_wallrunning = string.format("%.2f", wallT), expect = "> 0 (about 1.3 s)" }

releaseAll()
hrp.AssemblyLinearVelocity = Vector3.zero
hrp.CFrame = returnTo
arena:Destroy()
return R
