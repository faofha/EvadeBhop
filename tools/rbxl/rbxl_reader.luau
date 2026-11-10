-- Reader for an UNCOMPRESSED binary .rbxl (every chunk cl == 0). Installs getgenv().RBXL.
local data = buffer.fromstring(readfile("EvadeCloneDev/evade_raw.rbxl"))
local len = buffer.len(data)

local function u32(b, o) return buffer.readu32(b, o) end
local function interU32(b, o, n, i)
	return bit32.bor(bit32.lshift(buffer.readu8(b, o + i), 24), bit32.lshift(buffer.readu8(b, o + n + i), 16), bit32.lshift(buffer.readu8(b, o + 2 * n + i), 8), buffer.readu8(b, o + 3 * n + i))
end
local function zigzag(v) return bit32.band(v, 1) == 1 and -(bit32.rshift(v, 1)) - 1 or bit32.rshift(v, 1) end
local tmp = buffer.create(4)
local function rbxF32(v)
	v = bit32.bor(bit32.rshift(v, 1), bit32.lshift(bit32.band(v, 1), 31))
	buffer.writeu32(tmp, 0, v)
	return buffer.readf32(tmp, 0)
end
local function refs(b, o, n)
	local out, acc = table.create(n), 0
	for i = 0, n - 1 do acc += zigzag(interU32(b, o, n, i)); out[i + 1] = acc end
	return out
end

local classes, parent, props, cls, propChunks = {}, {}, {}, {}, {}
local p = 32
while p < len do
	local name = buffer.readstring(data, p, 4)
	local ul = u32(data, p + 8)
	local start = p + 16
	p = start + ul
	if name == "INST" then
		local cid, ln = u32(data, start), u32(data, start + 4)
		local cn = buffer.readstring(data, start + 8, ln)
		local q = start + 8 + ln + 1
		local n = u32(data, q)
		classes[cid] = { cn, refs(data, q + 4, n) }
	elseif name == "PROP" then
		table.insert(propChunks, { start, ul })
	elseif name == "PRNT" then
		local n = u32(data, start + 1)
		local c, pa = refs(data, start + 5, n), refs(data, start + 5 + 4 * n, n)
		for i = 1, n do parent[c[i]] = pa[i] end
	elseif name == "END\0" then
		break
	end
end
for _, c in classes do for _, r in c[2] do cls[r] = c[1] end end

local NORMALS = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis, -Vector3.xAxis, -Vector3.yAxis, -Vector3.zAxis }
-- decode one PROP chunk into props[ref][name]; only for instances in `want` (nil = all), only `onlyName` prop if given
local function decode(chunk, want, onlyName)
	local s = chunk[1]
	local cid, ln = u32(data, s), u32(data, s + 4)
	local pn = buffer.readstring(data, s + 8, ln)
	if onlyName and pn ~= onlyName then return end
	local c = classes[cid]
	if not c then return end
	local q = s + 8 + ln
	local t = buffer.readu8(data, q); q += 1
	local rs, n = c[2], #c[2]
	if want then
		local any = false
		for _, r in rs do if want[r] then any = true break end end
		if not any then return end
	end
	local vals = {}
	if t == 1 then
		for i = 1, n do local l = u32(data, q); q += 4; vals[i] = buffer.readstring(data, q, l); q += l end
	elseif t == 2 then
		for i = 1, n do vals[i] = buffer.readu8(data, q + i - 1) ~= 0 end
	elseif t == 3 then
		for i = 1, n do vals[i] = zigzag(interU32(data, q, n, i - 1)) end
	elseif t == 4 then
		for i = 1, n do vals[i] = rbxF32(interU32(data, q, n, i - 1)) end
	elseif t == 5 then
		for i = 1, n do vals[i] = buffer.readf64(data, q + (i - 1) * 8) end
	elseif t == 6 then
		for i = 1, n do vals[i] = UDim.new(rbxF32(interU32(data, q, n, i - 1)), zigzag(interU32(data, q + 4 * n, n, i - 1))) end
	elseif t == 7 then
		for i = 1, n do
			vals[i] = UDim2.new(rbxF32(interU32(data, q, n, i - 1)), zigzag(interU32(data, q + 8 * n, n, i - 1)), rbxF32(interU32(data, q + 4 * n, n, i - 1)), zigzag(interU32(data, q + 12 * n, n, i - 1)))
		end
	elseif t == 0xC then
		for i = 1, n do vals[i] = Color3.new(rbxF32(interU32(data, q, n, i - 1)), rbxF32(interU32(data, q + 4 * n, n, i - 1)), rbxF32(interU32(data, q + 8 * n, n, i - 1))) end
	elseif t == 0xD then
		for i = 1, n do vals[i] = Vector2.new(rbxF32(interU32(data, q, n, i - 1)), rbxF32(interU32(data, q + 4 * n, n, i - 1))) end
	elseif t == 0xE then
		for i = 1, n do vals[i] = Vector3.new(rbxF32(interU32(data, q, n, i - 1)), rbxF32(interU32(data, q + 4 * n, n, i - 1)), rbxF32(interU32(data, q + 8 * n, n, i - 1))) end
	elseif t == 0x10 then
		local rots = {}
		for i = 1, n do
			local id = buffer.readu8(data, q); q += 1
			if id == 0 then
				local m = {}
				for k = 1, 9 do m[k] = buffer.readf32(data, q); q += 4 end
				rots[i] = { Vector3.new(m[1], m[4], m[7]), Vector3.new(m[2], m[5], m[8]) }
			else
				local k = id - 1
				rots[i] = { NORMALS[k // 6 + 1], NORMALS[k % 6 + 1] }
			end
		end
		for i = 1, n do
			local x = rbxF32(interU32(data, q, n, i - 1))
			local y = rbxF32(interU32(data, q + 4 * n, n, i - 1))
			local z = rbxF32(interU32(data, q + 8 * n, n, i - 1))
			vals[i] = CFrame.fromMatrix(Vector3.new(x, y, z), rots[i][1], rots[i][2])
		end
	elseif t == 0x12 then
		for i = 1, n do vals[i] = interU32(data, q, n, i - 1) end
	elseif t == 0x13 then
		local v = refs(data, q, n)
		for i = 1, n do vals[i] = v[i] == -1 and "nil" or ("ref:" .. v[i]) end
	elseif t == 0x1A then
		for i = 1, n do vals[i] = Color3.fromRGB(buffer.readu8(data, q + i - 1), buffer.readu8(data, q + n + i - 1), buffer.readu8(data, q + 2 * n + i - 1)) end
	elseif t == 0x20 then
		for i = 1, n do
			local l = u32(data, q); q += 4
			local fam = buffer.readstring(data, q, l); q += l
			local w = buffer.readu16(data, q); q += 2
			local st = buffer.readu8(data, q); q += 1
			local l2 = u32(data, q); q += 4 + l2
			vals[i] = ("Font(%s,%d,%d)"):format(fam, w, st)
		end
	elseif t == 0x15 then
		for i = 1, n do
			local cnt = u32(data, q); q += 4
			local kp = {}
			for _ = 1, cnt do
				local tt, v = buffer.readf32(data, q), buffer.readf32(data, q + 4); q += 12
				table.insert(kp, ("%.2f:%.2f"):format(tt, v))
			end
			vals[i] = "NS[" .. table.concat(kp, " ") .. "]"
		end
	elseif t == 0x16 then
		for i = 1, n do
			local cnt = u32(data, q); q += 4
			local kps = {}
			for _ = 1, cnt do
				local tt, r, g, bb = buffer.readf32(data, q), buffer.readf32(data, q + 4), buffer.readf32(data, q + 8), buffer.readf32(data, q + 12)
				q += 20
				table.insert(kps, ColorSequenceKeypoint.new(math.clamp(tt, 0, 1), Color3.new(r, g, bb)))
			end
			vals[i] = ColorSequence.new(kps)
		end
	elseif t == 0x17 then
		for i = 1, n do vals[i] = NumberRange.new(buffer.readf32(data, q + (i - 1) * 8), buffer.readf32(data, q + (i - 1) * 8 + 4)) end
	elseif t == 0x18 then
		for i = 1, n do
			vals[i] = Rect.new(rbxF32(interU32(data, q, n, i - 1)), rbxF32(interU32(data, q + 4 * n, n, i - 1)), rbxF32(interU32(data, q + 8 * n, n, i - 1)), rbxF32(interU32(data, q + 12 * n, n, i - 1)))
		end
	else
		return
	end
	for i, r in rs do
		if not want or want[r] then
			props[r] = props[r] or {}
			props[r][pn] = vals[i]
		end
	end
end

-- names for all instances
for _, ch in propChunks do decode(ch, nil, "Name") end
local function nm(r) return props[r] and props[r].Name or "?" end
local pathCache = {}
local function path(r)
	if pathCache[r] then return pathCache[r] end
	local s = {}
	local x = r
	while x and cls[x] do table.insert(s, 1, nm(x)); x = parent[x] end
	local v = table.concat(s, "/")
	pathCache[r] = v
	return v
end
local children = {}
for r, pa in parent do children[pa] = children[pa] or {}; table.insert(children[pa], r) end

local API = {}
function API.find(pattern, limit)
	local out = {}
	for r in cls do
		local pth = path(r)
		if string.find(pth, pattern) then
			table.insert(out, pth .. " [" .. cls[r] .. "]")
			if #out >= (limit or 50) then break end
		end
	end
	table.sort(out)
	return out
end
local function refOf(fullPath)
	for r in cls do if path(r) == fullPath then return r end end
end
function API.props(fullPath, includeDesc)
	local root = refOf(fullPath)
	if not root then return "not found" end
	local want = { [root] = true }
	if includeDesc then
		local stack = { root }
		while #stack > 0 do
			local x = table.remove(stack)
			for _, ch in children[x] or {} do want[ch] = true; table.insert(stack, ch) end
		end
	end
	for _, ch in propChunks do decode(ch, want) end
	local lines = {}
	local list = {}
	for r in want do table.insert(list, r) end
	table.sort(list, function(a, b) return path(a) < path(b) end)
	local SKIP = { Name = true, AttributesSerialize = true, Tags = true, SourceAssetId = true, HistoryId = true, UniqueId = true, Capabilities = true, DefinesCapabilities = true, Source = true }
	for _, r in list do
		local kv = {}
		for k, v in props[r] or {} do
			if not SKIP[k] then table.insert(kv, k .. "=" .. tostring(v)) end
		end
		table.sort(kv)
		table.insert(lines, ("== %s [%s]\n   %s"):format(string.sub(path(r), #fullPath - #nm(root) + 1), cls[r], table.concat(kv, "; ")))
	end
	return table.concat(lines, "\n")
end
function API.source(fullPath)
	local r = refOf(fullPath)
	if not r then return "not found" end
	for _, ch in propChunks do decode(ch, { [r] = true }, "Source") end
	return props[r] and props[r].Source or "(no source)"
end
-- Luau literal for a decoded value (enums stay numbers; the builder resolves them per property).
local function lit(v)
	local t = typeof(v)
	if t == "string" then
		if string.sub(v, 1, 5) == "Font(" then
			local fam, w, st = string.match(v, "^Font%((.-),(%d+),(%d+)%)$")
			return ("{font=%q,w=%s,s=%s}"):format(fam, w, st)
		elseif string.sub(v, 1, 3) == "NS[" then
			local kp = {}
			for a, b in string.gmatch(v, "([%-%d%.]+):([%-%d%.]+)") do table.insert(kp, ("NumberSequenceKeypoint.new(%s,%s)"):format(a, b)) end
			return "NumberSequence.new({" .. table.concat(kp, ",") .. "})"
		elseif string.sub(v, 1, 4) == "ref:" or v == "nil" then
			return nil
		end
		return ("%q"):format(v)
	elseif t == "boolean" then return tostring(v)
	elseif t == "number" then return ("%.6g"):format(v)
	elseif t == "UDim" then return ("UDim.new(%.6g,%d)"):format(v.Scale, v.Offset)
	elseif t == "UDim2" then return ("UDim2.new(%.6g,%d,%.6g,%d)"):format(v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset)
	elseif t == "Color3" then return ("Color3.new(%.6g,%.6g,%.6g)"):format(v.R, v.G, v.B)
	elseif t == "Vector2" then return ("Vector2.new(%.6g,%.6g)"):format(v.X, v.Y)
	elseif t == "Vector3" then return ("Vector3.new(%.6g,%.6g,%.6g)"):format(v.X, v.Y, v.Z)
	elseif t == "Rect" then return ("Rect.new(%.6g,%.6g,%.6g,%.6g)"):format(v.Min.X, v.Min.Y, v.Max.X, v.Max.Y)
	elseif t == "NumberRange" then return ("NumberRange.new(%.6g,%.6g)"):format(v.Min, v.Max)
	elseif t == "ColorSequence" then
		local kp = {}
		for _, k in v.Keypoints do table.insert(kp, ("ColorSequenceKeypoint.new(%.6g,Color3.new(%.6g,%.6g,%.6g))"):format(k.Time, k.Value.R, k.Value.G, k.Value.B)) end
		return "ColorSequence.new({" .. table.concat(kp, ",") .. "})"
	end
	return nil
end
-- Export a subtree as Luau: { {Path="A/B", Class="Frame", Props={...}}, ... } (parents before children).
function API.export(fullPath, skipPattern)
	local root = refOf(fullPath)
	if not root then return "not found" end
	local want, order = { [root] = true }, { root }
	local i = 1
	while i <= #order do
		local x = order[i]
		local kids = children[x] or {}
		table.sort(kids, function(a, b) return nm(a) < nm(b) end)
		for _, ch in kids do
			if not (skipPattern and string.find(path(ch), skipPattern)) then
				want[ch] = true
				table.insert(order, ch)
			end
		end
		i += 1
	end
	for _, ch in propChunks do decode(ch, want) end
	local SKIP = { Name = true, AttributesSerialize = true, Tags = true, SourceAssetId = true, HistoryId = true, UniqueId = true, Capabilities = true, DefinesCapabilities = true, Source = true, SerializedOverrides = true, RootLocalizationTable = true, NextSelectionDown = true, NextSelectionLeft = true, NextSelectionRight = true, NextSelectionUp = true, SelectionImageObject = true, Archivable = true }
	local base = #fullPath - #nm(root) + 1
	local lines = {}
	local defaults = {}
	local function isDefault(class, k, v)
		local d = defaults[class]
		if d == nil then
			local ok, inst = pcall(Instance.new, class)
			d = ok and inst or false
			defaults[class] = d
		end
		if not d then return false end
		local ok, cur = pcall(function() return d[k] end)
		if not ok then return false end
		if typeof(cur) == "EnumItem" then return cur.Value == v end
		if typeof(cur) == "Font" and type(v) == "string" then
			local fam, w, st = string.match(v, "^Font%((.-),(%d+),(%d+)%)$")
			return cur.Family == fam and cur.Weight.Value == tonumber(w) and cur.Style.Value == tonumber(st)
		end
		if typeof(cur) == "number" and type(v) == "number" then return math.abs(cur - v) < 1e-4 end
		return cur == v
	end
	for _, r in order do
		local kv = {}
		for k, v in props[r] or {} do
			if not SKIP[k] and not isDefault(cls[r], k, v) then
				local l = lit(v)
				if l then table.insert(kv, ("%s=%s"):format(k, l)) end
			end
		end
		table.sort(kv)
		table.insert(lines, ("\t{ Path = %q, Class = %q, Props = { %s } },"):format(string.sub(path(r), base), cls[r], table.concat(kv, ", ")))
	end
	return "{\n" .. table.concat(lines, "\n") .. "\n}"
end
getgenv().RBXL = API
local n = 0
for _ in cls do n += 1 end
return "instances " .. n
