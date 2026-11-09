-- Minimal Roblox mock for executing EvadeClone.lua headlessly with the luau CLI.
-- Flat floor at Y=0, simple vertical physics, LinearVelocity drives XZ.
MOCK = { time = 0, frame = 0, keys = {}, logs = {}, waiting = {}, renderSteps = {}, moveVector = nil }

local function vec(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3MT) end
Vector3MT = {}
Vector3MT.__index = function(v, k)
	if k == "Magnitude" or k == "magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
	if k == "Unit" or k == "unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z); if m == 0 then return vec(0/0, 0/0, 0/0) end return vec(v.X / m, v.Y / m, v.Z / m) end
	if k == "Dot" then return function(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end end
	if k == "Cross" then return function(a, b) return vec(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X) end end
	if k == "Lerp" then return function(a, b, t) return a + (b - a) * t end end
	error("Vector3 has no member " .. tostring(k))
end
local function isv(x) return type(x) == "table" and getmetatable(x) == Vector3MT end
Vector3MT.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
Vector3MT.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
Vector3MT.__unm = function(a) return vec(-a.X, -a.Y, -a.Z) end
Vector3MT.__mul = function(a, b)
	if type(a) == "number" then return vec(a * b.X, a * b.Y, a * b.Z) end
	if type(b) == "number" then return vec(a.X * b, a.Y * b, a.Z * b) end
	return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
Vector3MT.__div = function(a, b)
	if type(b) == "number" then return vec(a.X / b, a.Y / b, a.Z / b) end
	return vec(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
Vector3MT.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
Vector3MT.__tostring = function(v) return ("(%.3f, %.3f, %.3f)"):format(v.X, v.Y, v.Z) end
Vector3 = { new = vec, zero = vec(0, 0, 0), one = vec(1, 1, 1) }

Vector2MT = {}
local function vec2(x, y) return setmetatable({ X = x or 0, Y = y or 0 }, Vector2MT) end
Vector2MT.__index = function(v, k)
	if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y) end
	error("Vector2 member " .. k)
end
Vector2MT.__mul = function(a, b) if type(b) == "number" then return vec2(a.X * b, a.Y * b) end return vec2(a.X * b, a.Y * b) end
Vector2MT.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
Vector2 = { new = vec2, zero = vec2(0, 0) }

-- CFrame: position p + rotation columns (r = right, u = up, b = back)  i.e. matrix [r u b]
CFrameMT = {}
local function cf(p, r, u, b) return setmetatable({ p = p, r = r or vec(1, 0, 0), u = u or vec(0, 1, 0), b = b or vec(0, 0, 1) }, CFrameMT) end
local function rotate(c, v) return c.r * v.X + c.u * v.Y + c.b * v.Z end
local function unrotate(c, v) return vec(c.r:Dot(v), c.u:Dot(v), c.b:Dot(v)) end
CFrameMT.__index = function(c, k)
	if k == "Position" or k == "p" then return c.p end
	if k == "LookVector" or k == "lookVector" then return -c.b end
	if k == "RightVector" or k == "rightVector" then return c.r end
	if k == "UpVector" then return c.u end
	if k == "X" then return c.p.X end
	if k == "Y" then return c.p.Y end
	if k == "Z" then return c.p.Z end
	if k == "VectorToWorldSpace" then return function(self, v) return rotate(self, v) end end
	if k == "VectorToObjectSpace" then return function(self, v) return unrotate(self, v) end end
	if k == "PointToWorldSpace" then return function(self, v) return self.p + rotate(self, v) end end
	if k == "ToOrientation" then
		return function(self)
			-- YXZ: R = Ry(y) Rx(x) Rz(z); m = rows
			local m12 = self.b.Y -- row1 col2 (y component of back column)
			local x = math.asin(math.clamp(-m12, -1, 1))
			local y = math.atan2(self.b.X, self.b.Z)
			local z = math.atan2(self.r.Y, self.u.Y)
			return x, y, z
		end
	end
	if k == "Lerp" or k == "lerp" then
		return function(a, bb, t)
			local function L(x, y) return x + (y - x) * t end
			local r, u = L(a.r, bb.r), L(a.u, bb.u)
			local rm = r.Magnitude; if rm > 1e-6 then r = r / rm end
			u = u - r * r:Dot(u); local um = u.Magnitude; if um > 1e-6 then u = u / um end
			return cf(L(a.p, bb.p), r, u, r:Cross(u))
		end
	end
	if k == "GetComponents" then
		return function(s) return s.p.X, s.p.Y, s.p.Z, s.r.X, s.u.X, s.b.X, s.r.Y, s.u.Y, s.b.Y, s.r.Z, s.u.Z, s.b.Z end
	end
	error("CFrame member " .. tostring(k))
end
CFrameMT.__mul = function(a, b)
	if isv(b) then return a.p + rotate(a, b) end
	return cf(a.p + rotate(a, b.p), rotate(a, b.r), rotate(a, b.u), rotate(a, b.b))
end
CFrameMT.__add = function(a, v) return cf(a.p + v, a.r, a.u, a.b) end
CFrameMT.__sub = function(a, v) return cf(a.p - v, a.r, a.u, a.b) end
CFrameMT.__eq = function(a, b) return a.p == b.p and a.r == b.r and a.u == b.u and a.b == b.b end
local function axisAngle(axis, ang)
	axis = axis.Unit
	local c, s = math.cos(ang), math.sin(ang)
	local function rot(v) return v * c + axis:Cross(v) * s + axis * (axis:Dot(v) * (1 - c)) end
	return cf(vec(), rot(vec(1, 0, 0)), rot(vec(0, 1, 0)), rot(vec(0, 0, 1)))
end
local function lookAt(at, target)
	local f = (target - at)
	if f.Magnitude < 1e-9 then return cf(at) end
	f = f.Unit
	local r = f:Cross(vec(0, 1, 0))
	if r.Magnitude < 1e-6 then r = vec(1, 0, 0) else r = r.Unit end
	local u = r:Cross(f)
	return cf(at, r, u, -f)
end
CFrame = {
	new = function(a, b, c)
		if isv(a) and b == nil then return cf(a) end
		if isv(a) and isv(b) then return lookAt(a, b) end
		if type(b) ~= "number" then error("CFrame.new bad args") end
		return cf(vec(a or 0, b or 0, c or 0))
	end,
	lookAt = lookAt,
	Angles = function(x, y, z) return axisAngle(vec(1, 0, 0), x) * axisAngle(vec(0, 1, 0), y) * axisAngle(vec(0, 0, 1), z) end,
	fromAxisAngle = axisAngle,
}
CFrame.identity = cf(vec())

UDim = { new = function(s, o) return { Scale = s, Offset = o } end }
UDim2 = {
	new = function(a, b, c, d) return { X = { Scale = a, Offset = b }, Y = { Scale = c, Offset = d } } end,
	fromScale = function(a, b) return { X = { Scale = a, Offset = 0 }, Y = { Scale = b, Offset = 0 } } end,
}
Color3 = { new = function(r, g, b) return { R = r, G = g, B = b } end, fromRGB = function(r, g, b) return { R = r / 255, G = g / 255, B = b / 255 } end }
NumberRange = { new = function(a, b) return { Min = a, Max = b or a } end }
NumberSequence = { new = function(v) return { v } end }
NumberSequenceKeypoint = { new = function(t, v) return { t, v } end }
TweenInfo = { new = function(...) return { ... } end }
Font = { new = function(f, w) return { Family = f, Weight = w } end }

-- Enum proxy
local enumCache = {}
Enum = setmetatable({}, { __index = function(_, enumName)
	enumCache[enumName] = enumCache[enumName] or setmetatable({}, { __index = function(t, item)
		local values = { First = 0, Camera = 200, Input = 100, Character = 300, Last = 2000 }
		local it = { Name = item, Value = values[item] or 0, EnumType = enumName }
		rawset(t, item, it)
		return it
	end })
	return enumCache[enumName]
end })

-- Signals
local function Signal()
	local s = { conns = {} }
	function s:Connect(fn)
		local c = { fn = fn, Connected = true }
		function c:Disconnect() self.Connected = false end
		table.insert(s.conns, c)
		return setmetatable(c, { __type = "RBXScriptConnection" })
	end
	s.connect = s.Connect
	function s:Fire(...)
		for _, c in ipairs(s.conns) do if c.Connected then c.fn(...) end end
	end
	function s:Wait()
		table.insert(MOCK.waiting, { co = coroutine.running(), frame = MOCK.frame + 1 })
		return coroutine.yield()
	end
	return s
end

local realTypeof = typeof
function typeof(x)
	if type(x) == "table" then
		local mt = getmetatable(x)
		if mt == Vector3MT then return "Vector3" end
		if mt == Vector2MT then return "Vector2" end
		if mt == CFrameMT then return "CFrame" end
		if mt and mt.__type then return mt.__type end
		if rawget(x, "__instance") then return "Instance" end
	end
	return realTypeof(x)
end

-- Instances
local ClassDefaults = {
	Humanoid = { Health = 100, MaxHealth = 100, HipHeight = 2, JumpHeight = 7.2, JumpPower = 50, UseJumpPower = false, WalkSpeed = 16, AutoRotate = true, RigType = "R15", CameraOffset = vec() },
	Part = { Size = vec(2, 2, 1), CanCollide = true, CollisionGroup = "Default", AssemblyMass = 15 },
	Sound = { Volume = 0.5, SoundId = "", IsPlaying = false },
	TextLabel = { TextBounds = setmetatable({ X = 24, Y = 12 }, {}) },
}
local Inst = {}
function Instance_new(className, parent)
	local props = { __instance = true, ClassName = className, Name = className, Parent = nil, _children = {}, Changed = Signal(), Enabled = true }
	for k, v in pairs(ClassDefaults[className] or {}) do props[k] = v end
	local obj = setmetatable(props, Inst)
	if className == "Humanoid" then
		obj.Died = Signal(); obj.StateChanged = Signal(); obj._enabledStates = {}
	elseif className == "Animator" then
		obj.AnimationPlayed = Signal(); obj._tracks = {}
	elseif className == "NumberValue" then obj.Value = 0
	end
	if parent then obj.Parent = parent end
	return obj
end
Inst.__index = function(o, k)
	local m = rawget(Inst, k)
	if m then return m end
	if k == "Parent" then return rawget(o, "_parent") end
	if k == "CFrame" and rawget(o, "_cf") then return rawget(o, "_cf") end
	if k == "Position" and rawget(o, "_cf") then return rawget(o, "_cf").p end
	return nil
end
Inst.__newindex = function(o, k, v)
	if k == "Parent" then
		local old = rawget(o, "_parent")
		if old then for i, c in ipairs(old._children) do if c == o then table.remove(old._children, i) break end end end
		rawset(o, "_parent", v)
		if v then table.insert(v._children, o) end
		return
	end
	if k == "CFrame" then rawset(o, "_cf", v); return end
	if k == "Position" and rawget(o, "_cf") then rawset(o, "_cf", rawget(o, "_cf") + (v - rawget(o, "_cf").p)); return end
	rawset(o, k, v)
end
function Inst:GetFullName() local n, p = self.Name, rawget(self, "_parent"); while p do n = p.Name .. "." .. n; p = rawget(p, "_parent") end return n end
function Inst:GetChildren() return table.clone(self._children) end
function Inst:FindFirstChild(name, rec)
	for _, c in ipairs(self._children) do if c.Name == name then return c end end
	if rec then for _, c in ipairs(self._children) do local f = c:FindFirstChild(name, true) if f then return f end end end
	return nil
end
function Inst:WaitForChild(name) return self:FindFirstChild(name) end
function Inst:IsA(cn)
	if cn == self.ClassName then return true end
	if cn == "BasePart" and (self.ClassName == "Part" or self.ClassName == "MeshPart") then return true end
	if cn == "GuiObject" or cn == "GuiBase2d" then return self.ClassName:find("Frame") or self.ClassName:find("Label") end
	return false
end
function Inst:FindFirstChildOfClass(cn) for _, c in ipairs(self._children) do if c.ClassName == cn then return c end end return nil end
function Inst:FindFirstChildWhichIsA(cn, rec)
	for _, c in ipairs(self._children) do if c:IsA(cn) then return c end end
	if rec then for _, c in ipairs(self._children) do local f = c:FindFirstChildWhichIsA(cn, true) if f then return f end end end
	return nil
end
function Inst:IsDescendantOf(a) local p = rawget(self, "_parent"); while p do if p == a then return true end p = rawget(p, "_parent") end return false end
function Inst:Destroy() self.Parent = nil; rawset(self, "_destroyed", true) end
function Inst:GetAttribute() return nil end
-- Humanoid
function Inst:SetStateEnabled(st, en) self._enabledStates[st.Name] = en end
function Inst:GetStateEnabled(st) local v = self._enabledStates[st.Name]; return v ~= false end
function Inst:ChangeState(st)
	if st.Name == "Jumping" then
		if self._enabledStates.Jumping == false then return end
		local root = rawget(self, "_parent"):FindFirstChild("HumanoidRootPart")
		root._vy = math.sqrt(2 * MOCK.gravity * self.JumpHeight)
		root._airborne = true
		MOCK.jumps = (MOCK.jumps or 0) + 1
		self.StateChanged:Fire(nil, st)
	end
end
-- Animator
local Track = {}
Track.__index = Track
function Inst:LoadAnimation(anim)
	local t = setmetatable({ Animation = anim, IsPlaying = false, WeightCurrent = 0, WeightTarget = 1, Speed = 1, Length = 1, TimePosition = 0, Priority = { Name = "Core" }, Looped = true, Name = anim.Name }, Track)
	table.insert(self._tracks, t)
	return t
end
function Inst:GetPlayingAnimationTracks() local o = {} for _, t in ipairs(self._tracks or {}) do if t.IsPlaying then table.insert(o, t) end end return o end
function Track:Play(fade, w, s) self.IsPlaying = true; self.WeightCurrent = w or 1; self.Speed = s or 1; MOCK.played = MOCK.played or {}; MOCK.played[#MOCK.played + 1] = { MOCK.time, self.Animation.Name, fade } end
function Track:Stop(fade) self.IsPlaying = false; self.WeightCurrent = 0 end
function Track:AdjustSpeed(s) self.Speed = s end
function Track:AdjustWeight(w) self.WeightCurrent = w end
function Track:Destroy() end
-- Sounds
function Inst:Play() self.IsPlaying = true; if self.ClassName == "Sound" then MOCK.sounds = (MOCK.sounds or 0) + 1 end end
function Inst:Stop() self.IsPlaying = false end
Instance = { new = Instance_new }

-- World
local function folder(name, parent) local f = Instance_new("Folder", parent); f.Name = name; return f end
DataModel = Instance_new("DataModel"); DataModel.Name = "game"
workspaceObj = folder("Workspace", DataModel)
workspaceObj.Gravity = 50
MOCK.gravity = 50
local camera = Instance_new("Camera", workspaceObj)
camera.Name = "Camera"; camera.CFrame = CFrame.new(0, 4.5, 0); camera.FieldOfView = 70
workspaceObj.CurrentCamera = camera
local RS = folder("ReplicatedStorage", DataModel)
local function rayFloor(origin, dir)
	-- floor at y=0 ; optional wall at x = MOCK.wallX (normal -X)
	local best
	if dir.Y < 0 and origin.Y >= 0 and origin.Y + dir.Y <= 0 then
		local t = origin.Y / -dir.Y
		best = { t = t, Normal = vec(0, 1, 0), Position = origin + dir * t, Material = { Name = "Plastic" }, Instance = { CanCollide = true } }
	end
	if MOCK.wallX and dir.X > 0 and origin.X < MOCK.wallX and origin.X + dir.X >= MOCK.wallX then
		local t = (MOCK.wallX - origin.X) / dir.X
		if not best or t < best.t then best = { t = t, Normal = vec(-1, 0, 0), Position = origin + dir * t, Material = { Name = "Plastic" }, Instance = { CanCollide = true } } end
	end
	return best
end
function workspaceObj:Raycast(o, d) return rayFloor(o, d) end
function workspaceObj:Spherecast(o, r, d) return rayFloor(o - vec(0, r, 0), d) end
function workspaceObj:Blockcast(c, size, d) return rayFloor(c.p + vec(size.X / 2, 0, 0) * 0, d) end
workspace = workspaceObj

RaycastParams = { new = function() return {} end }

local Players = folder("Players", DataModel)
local lp = Instance_new("Player", Players); lp.Name = "LocalPlayer"
lp.CameraMode = Enum.CameraMode.Classic; lp.CameraMinZoomDistance = 0.5; lp.CameraMaxZoomDistance = 128
lp.CharacterAdded = Signal(); lp.CharacterRemoving = Signal()
local ps = folder("PlayerScripts", lp)
folder("PlayerGui", lp)
Players.LocalPlayer = lp
Players.PlayerAdded = Signal()
function Players:GetPlayers() return { lp } end

-- character
local char = Instance_new("Model", workspaceObj); char.Name = "Char"
local hum = Instance_new("Humanoid", char); hum.Name = "Humanoid"; hum.RigType = Enum.HumanoidRigType.R15
local root = Instance_new("Part", char); root.Name = "HumanoidRootPart"; root.CFrame = CFrame.new(0, 3, 0)
root.AssemblyLinearVelocity = vec(); root.AssemblyAngularVelocity = vec(); root._vy = 0
local animate = Instance_new("LocalScript", char); animate.Name = "Animate"
lp.Character = char

-- RunService
local RunService = Instance_new("RunService"); RunService.Heartbeat = Signal(); RunService.RenderStepped = Signal()
function RunService:BindToRenderStep(name, prio, fn) MOCK.renderSteps[name] = { prio = prio, fn = fn } end
function RunService:UnbindFromRenderStep(name) MOCK.renderSteps[name] = nil end
local UIS = Instance_new("UserInputService"); UIS.JumpRequest = Signal(); UIS.InputBegan = Signal(); UIS.InputEnded = Signal(); UIS.TouchEnded = Signal()
UIS.MouseBehavior = Enum.MouseBehavior.Default
function UIS:IsKeyDown(k) return MOCK.keys[k.Name] == true end
function UIS:GetFocusedTextBox() return nil end
function UIS:GetConnectedGamepads() return {} end
local TweenService = Instance_new("TweenService")
function TweenService:Create(obj, info, goal)
	local t = { Completed = Signal() }
	function t:Play() for k, v in pairs(goal) do obj[k] = v end; if obj.Changed then obj.Changed:Fire(goal.Value) end; t.Completed:Fire() end
	function t:Cancel() end
	return t
end
local Debris = Instance_new("Debris"); function Debris:AddItem() end
local services = { Players = Players, RunService = RunService, UserInputService = UIS, ReplicatedStorage = RS, TweenService = TweenService, Debris = Debris, CoreGui = folder("CoreGui", DataModel), KeyframeSequenceProvider = Instance_new("KeyframeSequenceProvider"), InsertService = Instance_new("InsertService") }
function DataModel:GetService(n) return services[n] or error("no service " .. n) end
game = DataModel

-- executor functions: in-memory file system with one fake KeyframeSequence per .rbxm
MOCK.files = { ["EvadeClone/Animations/Idle.rbxm"] = 1, ["EvadeClone/Animations/WalkRun.rbxm"] = 1, ["EvadeClone/Animations/Jump.rbxm"] = 1,
	["EvadeClone/Animations/Land.rbxm"] = 1, ["EvadeClone/Animations/Slide.rbxm"] = 1, ["EvadeClone/Animations/Crouch.rbxm"] = 1 }
MOCK.written = {}
local genv = {}
genv.getcustomasset = function(p) return "rbxasset://custom/" .. p end
genv.isfile = function(p) return MOCK.files[p] ~= nil or MOCK.written[p] ~= nil end
genv.isfolder = function(p) return true end
genv.makefolder = function() end
genv.listfiles = function() return {} end
genv.readfile = function(p) return MOCK.written[p] end
genv.writefile = function(p, c) MOCK.written[p] = c end
genv.gethui = function() return services.CoreGui end
function getgenv() return genv end
function DataModel:GetObjects(id)
	local ks = Instance_new("KeyframeSequence"); ks.Name = id:match("([^/]+)%.rbxm$"); ks.Priority = { Name = "Movement" }; ks.Loop = true
	return { ks }
end
local ksp = services.KeyframeSequenceProvider
function ksp:RegisterKeyframeSequence(ks) return "rbxassetid://temp-" .. ks.Name end

-- task / scheduler
task = {}
function task.spawn(f, ...) local co = coroutine.create(f); local ok, err = coroutine.resume(co, ...); if not ok then error(err) end return co end
function task.defer(f, ...) return task.spawn(f, ...) end
function task.wait(n) table.insert(MOCK.waiting, { co = coroutine.running(), time = MOCK.time + (n or 0), frame = MOCK.frame + 1 }); coroutine.yield(); return n end
local realOs = os; os = setmetatable({ clock = function() return MOCK.time end }, { __index = realOs })
function warn(...) local s = table.concat({ ... }, " "); table.insert(MOCK.logs, "WARN " .. s); print("WARN " .. s) end

-- Physics + frame stepping
function MOCK.step(dt)
	MOCK.time += dt
	MOCK.frame += 1
	-- input: JumpRequest while space held (Roblox fires repeatedly)
	if MOCK.keys.Space then UIS.JumpRequest:Fire() end
	-- render steps by priority
	local list = {}
	for n, s in pairs(MOCK.renderSteps) do table.insert(list, s) end
	table.sort(list, function(a, b) return a.prio < b.prio end)
	for _, s in ipairs(list) do s.fn(dt) end
	MOCK.renderedCam = camera.CFrame
	-- physics: plane velocity from LinearVelocity, vertical from gravity
	local lv = root:FindFirstChild("EvadeClone_BaseMover")
	local vxz = (lv and lv.Enabled) and lv.PlaneVelocity or vec2(0, 0)
	local vy = root._vy - MOCK.gravity * dt
	local pos = root.Position + vec(vxz.X, 0, vxz.Y) * dt + vec(0, vy * dt, 0)
	if pos.Y <= 3 then pos = vec(pos.X, 3, pos.Z); if vy < 0 then vy = 0 end end
	root._vy = vy
	root.AssemblyLinearVelocity = vec(vxz.X, vy, vxz.Y)
	root.CFrame = root.CFrame + (pos - root.Position)
	-- camera follows head (default camera emulation): keep yaw/pitch from MOCK.look
	local y, p = MOCK.yaw or 0, MOCK.pitch or 0
	camera.CFrame = CFrame.new(root.Position + vec(0, 1.5, 0)) * CFrame.Angles(0, y, 0) * CFrame.Angles(p, 0, 0)
	RunService.Heartbeat:Fire(dt)
	-- resume waiters
	local w = MOCK.waiting; MOCK.waiting = {}
	for _, it in ipairs(w) do
		if it.frame <= MOCK.frame and (it.time == nil or it.time <= MOCK.time) then
			local ok, err = coroutine.resume(it.co, dt)
			if not ok then print("COROUTINE ERROR " .. tostring(err)) ; MOCK.errors = (MOCK.errors or 0) + 1 end
		else table.insert(MOCK.waiting, it) end
	end
end
function MOCK.press(key) MOCK.keys[key] = true; UIS.InputBegan:Fire({ KeyCode = Enum.KeyCode[key], UserInputType = {} }, false) end
function MOCK.release(key) MOCK.keys[key] = false; UIS.InputEnded:Fire({ KeyCode = Enum.KeyCode[key] }) end
MOCK.root, MOCK.hum, MOCK.camera, MOCK.char, MOCK.lp = root, hum, camera, char, lp
