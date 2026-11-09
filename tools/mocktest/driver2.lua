
local R = MOCK
local dt = 1/60
local function hs() local v = R.root.AssemblyLinearVelocity; return math.sqrt(v.X*v.X + v.Z*v.Z) end
local function velYaw() local v = R.root.AssemblyLinearVelocity; return math.atan2(-v.X, -v.Z) end
local function grounded() return R.root.Position.Y <= 3.0001 end
local function steps(n, f) for i = 1, n do if f then f(i) end R.step(dt) end end
local function camRoll() local _,_,z = R.renderedCam:ToOrientation(); return math.deg(z) end
local function camPitch() local x = R.renderedCam:ToOrientation(); return math.deg(x) end
local function waitLand(f) local n = 0; repeat if f then f() end R.step(dt); n += 1 until (grounded() and n > 3) or n > 200; return n end
local function jump() R.press("Space"); R.step(dt); R.release("Space") end

R.keys.W = true; steps(200)
print(("A) sprint speed %.2f st/s (Evade: 33.33), FOV %.2f (Evade: 77.00)"):format(hs(), R.camera.FieldOfView))
jump(); R.keys.W = false
print(("B) speed after ground jump %.2f st/s (Evade: min(33.33*1.45, 48.33) = 48.33)"):format(hs()))
local pitchMin = 0
local n = waitLand()
local landSpeed = hs()
steps(12, function() pitchMin = math.min(pitchMin, camPitch()) end)
print(("C) airtime %.2fs, landing speed %.2f, after 12 ground frames %.2f (8.3%%/frame friction toward walk 16.67)"):format(n*dt, landSpeed, hs()))
print(("   landing camera pitch punch min %.2f deg (|vy|~17.3 -> k=0.42 -> target -0.72 deg + overshoot)"):format(pitchMin))
-- aligned bhop chain: jump on the first grounded frame, look along velocity
R.keys.W = true; steps(150); R.keys.W = false
local s = {}
for j = 1, 6 do
	jump()
	local takeoff = hs()
	waitLand(function() R.yaw = velYaw() end)
	table.insert(s, ("%.1f->%.1f"):format(takeoff, hs()))
end
print("D) aligned bhop chain takeoff->landing st/s: " .. table.concat(s, "  "))
-- optimal air strafe: hold D, look along velocity (wish perpendicular to V)
R.keys.W = true; steps(150); R.keys.W = false
jump()
R.keys.D = true
local a0, a1, ta, tb
local t = waitLand(function()
	R.yaw = velYaw()
	if R.root.Position.Y > 3.95 then if not a0 then a0, ta = hs(), R.time end a1, tb = hs(), R.time end
end)
R.keys.D = false
print(("E) optimal air-strafe, fully-airborne phase: %.2f -> %.2f st/s over %.2fs = %.2f st/s per s (theory at 60fps ~ 182^2/(2|V|) u/frame = %.2f)"):format(a0, a1, tb-ta, (a1-a0)/(tb-ta), 182*182/(2*a0*90)/90*60))
-- ground strafe roll at sprint: move diagonally right-forward
R.keys.W = true; steps(150); R.keys.D = true; local roll = 0
steps(60, function() roll = camRoll() end)
print(("F) grounded strafe roll at %.1f st/s holding W+D: %.3f deg (Evade max 1.65 deg)"):format(hs(), roll))
R.keys.D = false
-- air roll check
jump(); local airRoll = 0
R.keys.D = true; steps(20, function() airRoll = math.max(airRoll, math.abs(camRoll())) end); R.keys.D = false
waitLand()
print(("G) max |roll| while air-strafing: %.3f deg (Evade: decays to 0 in air)"):format(airRoll))
-- slide from sprint
R.keys.W = true; steps(150); jump(); waitLand(function() R.yaw = velYaw() end)
R.press("C"); local sl = {}
local slideFrames = 0
steps(150, function(i) if i % 30 == 1 then table.insert(sl, ("%.1f"):format(hs())) end end)
print("H) slide (crouch held at speed, W held) every 0.5s: " .. table.concat(sl, " "))
R.release("C"); R.keys.W = false; steps(200)
print(("I) stop: speed %.2f, FOV %.2f"):format(hs(), R.camera.FieldOfView))
-- states/anims seen
local seen = {}
for _, p in ipairs(R.played or {}) do seen[p[2]] = (seen[p[2]] or 0) + 1 end
local names = {} for k, v in pairs(seen) do table.insert(names, k .. "x" .. v) end table.sort(names)
print("J) tracks played: " .. table.concat(names, ", "))
print("K) sounds played: " .. tostring(R.sounds) .. ", coroutine errors: " .. tostring(R.errors or 0) .. ", warnings: " .. #R.logs)
for _, l in ipairs(R.logs) do print("   " .. l) end
