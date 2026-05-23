--[[
	════════════════════════════════════════════════════════════
	  VFX SYSTEM — Exire Reanimate Compatible
	  Converted from VFX System Builder HTML tool
	  
	  FEATURES:
	  • Part / Beam / Trail / ParticleEmitter / BillboardGui
	  • Infinite rotation (X, Y, Z axes, individual speeds)
	  • Sin-wave position offset (X, Y, Z with amplitude + speed)
	  • Sin-wave angle (X, Y, Z with amplitude + speed)
	  • Sin-wave size pulse
	  • Parent to any body part by name
	  • Custom export/instance name per VFX
	  • Trigger: onStart / loop (throttled) / onEnd / modeEnter
	  • Destroy: attackEnd / modeLeave / timer
	  • Full GUI builder (Orange theme matching your reanimate GUI)
	
	  HOW TO USE:
	  1. Paste this whole file into your reanimate script, inside C_c(),
	     after the "local t = reanimate()" block.
	  2. Call VFX_Builder.open() to open the GUI builder.
	  3. Press "Export" in the GUI to get ready-to-paste Lua code,
	     OR just wire up VFX directly (see bottom of file for examples).
	
	  DIRECT API (no GUI):
	    local vfx = VFX.new(config)   -- create a VFX group
	    vfx:spawnOnce(cframes, getPart, cfMul, cf, angles, v3, ws)
	    vfx:spawn(...)                -- throttled version
	    vfx:destroyAll()
	    vfx:update(sine, deltaTime, cframes, getPart, cfMul, cf, angles)
	    -- call vfx:update() every heartbeat for animations
	════════════════════════════════════════════════════════════
--]]

-- ─── Services ────────────────────────────────────────────────
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UIS          = game:GetService("UserInputService")
local lp           = Players.LocalPlayer
local pg           = lp:WaitForChild("PlayerGui")
local ws           = game:GetService("Workspace")

-- ─── Math shortcuts ──────────────────────────────────────────
local sin   = math.sin
local cos   = math.cos
local rad   = math.rad
local abs   = math.abs
local clamp = math.clamp
local pi    = math.pi
local pi2   = pi * 2
local floor = math.floor

-- ─── Color helper ────────────────────────────────────────────
local function hexToC3(hex)
	hex = hex:gsub("#","")
	local r = tonumber(hex:sub(1,2),16)/255
	local g = tonumber(hex:sub(3,4),16)/255
	local b = tonumber(hex:sub(5,6),16)/255
	return Color3.new(r,g,b)
end

local function c3ToHex(c3)
	return string.format("#%02X%02X%02X",
		math.floor(c3.R*255+0.5),
		math.floor(c3.G*255+0.5),
		math.floor(c3.B*255+0.5))
end

-- ════════════════════════════════════════════════════════════
--   VFX RUNTIME CORE
-- ════════════════════════════════════════════════════════════

local VFX = {}
VFX.__index = VFX

--[[
  config = {
    exportName    = "MyVFX",        -- name used in generated code
    lifetime      = 0,              -- 0 = no timer destroy
    throttle      = 0.3,            -- seconds between loop spawns
    destroyOn     = { attackEnd=true, modeLeave=true, timer=false },
    spawnOn       = { onStart=true, loop=false, onEnd=false, modeEnter=false },
    elements      = { ... }         -- array of element configs (see below)
  }

  Element configs:

  PART:
  {
    type         = "part",
    name         = "MyPart",        -- Instance.Name
    parentPart   = "Torso",         -- body part to parent to (nil = workspace root)
    shape        = "Ball",          -- Ball / Block / Cylinder / Wedge
    color        = "#b4b0ff",
    material     = "Neon",
    size         = 1.2,
    transparency = 0.25,
    offsetX=0, offsetY=1.5, offsetZ=0,
    rot          = 0,               -- static Z rotation in degrees

    -- Infinite rotation (studs/sec in radians/sec effectively)
    infRotX = 0,  infRotY = 2,  infRotZ = 0,

    -- Sin position (adds to offset each frame)
    sinPosX={amp=0,spd=0}, sinPosY={amp=0.3,spd=2}, sinPosZ={amp=0,spd=0},

    -- Sin angle (radians amplitude)
    sinAngX={amp=0,spd=0}, sinAngY={amp=0,spd=0}, sinAngZ={amp=0.2,spd=3},

    -- Sin size pulse
    sinSize={amp=0.2,spd=2},  -- adds amp*sin to base size
  }

  BEAM:
  {
    type    = "beam",
    name    = "MyBeam",
    parentPart = "Right Arm",
    color0  = "#ffffff", color1 = "#7f77dd",
    width0  = 0.6,  width1 = 0,
    length  = 5,
    infRotY = 1,    -- rotates the host part
  }

  TRAIL:
  {
    type       = "trail",
    name       = "MyTrail",
    parentPart = "Right Arm",
    color0     = "#ffffff", color1 = "#7f77dd",
    lifetime   = 0.5,
    width      = 0.5,
  }

  PARTICLES:
  {
    type       = "particles",
    name       = "MySparks",
    parentPart = "Torso",
    color      = "#b4b0ff",
    rate       = 30,
    speed      = 3,
    pLifetime  = 0.6,
    size       = 0.4,
    spread     = 180,
  }

  BILLBOARD:
  {
    type      = "billboard",
    name      = "MyLabel",
    parentPart= "Head",
    text      = "!",
    textColor = "#ffffff",
    bgColor   = "#1a1a2e",
    size      = 1,
    offsetY   = 2.5,
    sinPosY   = {amp=0.2, spd=1.5},
  }
--]]

function VFX.new(config)
	local self = setmetatable({}, VFX)
	self.config      = config or {}
	self.active      = {}   -- { inst, cfg, spawnTime, rotX, rotY, rotZ }
	self._lastSpawn  = 0
	self._sine       = 0
	return self
end

-- Resolve which real part to parent to
local function resolveParent(parentPartName, getPart, rootCF)
	if not parentPartName then return ws, rootCF end
	if getPart then
		local p = getPart(parentPartName)
		if p and p.p then
			return p.p, p.p.CFrame
		end
	end
	return ws, rootCF
end

function VFX:_spawnElement(elem, cframes, getPart, cfMul, cf, angles, v3)
	local rootJointPart = nil
	-- try to find root from cframes
	if cframes then
		for k,v in next, cframes do
			if k.Name == "HumanoidRootPart" or k.Name == "Torso" then
				rootJointPart = v
				break
			end
		end
	end
	local rootCF = rootJointPart or CFrame.new(0,0,0)

	-- parent resolution
	local parentInst, parentCF
	if elem.parentPart and getPart then
		local partTable = getPart(elem.parentPart)
		if partTable then
			-- if it's a real part table from cframes
			if cframes then
				parentCF = cframes[partTable] or rootCF
			end
			if partTable.p then
				parentInst = partTable.p
			end
		end
	end
	parentCF   = parentCF or rootCF
	parentInst = parentInst or ws

	local t = elem.type

	if t == "part" then
		local p = Instance.new("Part")
		p.Name         = elem.name or "VFX_Part"
		p.Anchored     = true
		p.CanCollide   = false
		p.CanQuery     = false
		p.CanTouch     = false
		p.CastShadow   = false
		p.Massless     = true

		local shapeMap = {sphere="Ball",block="Block",cylinder="Cylinder",wedge="Wedge",Ball="Ball",Block="Block",Cylinder="Cylinder",Wedge="Wedge"}
		p.Shape        = Enum.PartType[shapeMap[elem.shape] or "Ball"]
		p.Color        = hexToC3(elem.color or "#b4b0ff")
		p.Material     = Enum.Material[elem.material or "Neon"]
		p.Transparency = elem.transparency or 0.25
		local sz = elem.size or 1.2
		p.Size         = Vector3.new(sz, sz, sz)

		-- base offset
		local ox = elem.offsetX or 0
		local oy = elem.offsetY or 1.5
		local oz = elem.offsetZ or 0
		local staticRot = CFrame.fromEulerAngles(0, 0, math.rad(elem.rot or 0))
		p.CFrame = parentCF * CFrame.new(ox, oy, oz) * staticRot

		p.Parent = parentInst

		table.insert(self.active, {
			inst      = p,
			cfg       = elem,
			spawnTime = os.clock(),
			rotX      = 0,
			rotY      = 0,
			rotZ      = 0,
			parentInst= parentInst,
			parentCF_fn = function()
				if cframes and getPart then
					local pt = getPart(elem.parentPart or "HumanoidRootPart")
					if pt and cframes[pt] then return cframes[pt] end
				end
				return rootCF
			end
		})

	elseif t == "beam" then
		local hp = Instance.new("Part")
		hp.Name        = (elem.name or "VFX_Beam") .. "_Host"
		hp.Anchored    = true
		hp.CanCollide  = false
		hp.Transparency= 1
		hp.Size        = Vector3.new(0.1,0.1,0.1)
		hp.CFrame      = parentCF
		hp.Parent      = ws  -- always workspace so beam renders

		local a0 = Instance.new("Attachment", hp)
		a0.Name  = "A0"
		local a1 = Instance.new("Attachment", hp)
		a1.Name  = "A1"
		a1.Position = Vector3.new(0, 0, -(elem.length or 5))

		local bm = Instance.new("Beam")
		bm.Attachment0 = a0
		bm.Attachment1 = a1
		bm.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, hexToC3(elem.color0 or "#ffffff")),
			ColorSequenceKeypoint.new(1, hexToC3(elem.color1 or "#7f77dd"))
		})
		bm.Width0      = elem.width0 or 0.6
		bm.Width1      = elem.width1 or 0
		bm.FaceCamera  = true
		bm.Parent      = hp

		table.insert(self.active, {
			inst      = hp,
			cfg       = elem,
			spawnTime = os.clock(),
			rotX=0, rotY=0, rotZ=0,
			parentCF_fn = function()
				if cframes and getPart then
					local pt = getPart(elem.parentPart or "HumanoidRootPart")
					if pt and cframes[pt] then return cframes[pt] end
				end
				return rootCF
			end
		})

	elseif t == "trail" then
		local tp = Instance.new("Part")
		tp.Name        = (elem.name or "VFX_Trail") .. "_Host"
		tp.Anchored    = true
		tp.CanCollide  = false
		tp.Transparency= 1
		tp.Size        = Vector3.new(0.1,0.1,0.1)
		tp.CFrame      = parentCF
		tp.Parent      = parentInst

		local ta0 = Instance.new("Attachment", tp)
		local ta1 = Instance.new("Attachment", tp)
		ta1.Position   = Vector3.new(0, elem.width or 0.5, 0)

		local tr = Instance.new("Trail")
		tr.Attachment0 = ta0
		tr.Attachment1 = ta1
		tr.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, hexToC3(elem.color0 or "#ffffff")),
			ColorSequenceKeypoint.new(1, hexToC3(elem.color1 or "#7f77dd"))
		})
		tr.Lifetime    = elem.lifetime or 0.5
		tr.MinDistance = 0.05
		tr.Parent      = tp

		table.insert(self.active, {
			inst      = tp,
			cfg       = elem,
			spawnTime = os.clock(),
			rotX=0, rotY=0, rotZ=0,
			parentCF_fn = function()
				if cframes and getPart then
					local pt = getPart(elem.parentPart or "HumanoidRootPart")
					if pt and cframes[pt] then return cframes[pt] end
				end
				return rootCF
			end
		})

	elseif t == "particles" then
		local ep = Instance.new("Part")
		ep.Name        = (elem.name or "VFX_Emitter") .. "_Host"
		ep.Anchored    = true
		ep.CanCollide  = false
		ep.Transparency= 1
		ep.Size        = Vector3.new(0.1,0.1,0.1)
		ep.CFrame      = parentCF
		ep.Parent      = parentInst

		local pe = Instance.new("ParticleEmitter", ep)
		pe.Name        = elem.name or "VFX_Particles"
		pe.Color       = ColorSequence.new(hexToC3(elem.color or "#b4b0ff"))
		pe.Rate        = elem.rate or 30
		pe.Speed       = NumberRange.new(elem.speed or 3)
		pe.Lifetime    = NumberRange.new(elem.pLifetime or 0.6)
		pe.Size        = NumberSequence.new(elem.size or 0.4)
		local half     = (elem.spread or 180) / 2
		pe.SpreadAngle = Vector2.new(-half, half)
		pe.LightInfluence = 0

		table.insert(self.active, {
			inst      = ep,
			cfg       = elem,
			spawnTime = os.clock(),
			rotX=0,rotY=0,rotZ=0,
			parentCF_fn = function()
				if cframes and getPart then
					local pt = getPart(elem.parentPart or "HumanoidRootPart")
					if pt and cframes[pt] then return cframes[pt] end
				end
				return rootCF
			end
		})

	elseif t == "billboard" then
		local bp = Instance.new("Part")
		bp.Name        = (elem.name or "VFX_Billboard") .. "_Host"
		bp.Anchored    = true
		bp.CanCollide  = false
		bp.Transparency= 1
		bp.Size        = Vector3.new(0.1,0.1,0.1)
		bp.CFrame      = parentCF * CFrame.new(0, elem.offsetY or 2.5, 0)
		bp.Parent      = ws

		local bb = Instance.new("BillboardGui", bp)
		local sz = math.floor((elem.size or 1)*60)
		bb.Size        = UDim2.new(0, sz*2, 0, sz)
		bb.AlwaysOnTop = true
		bb.Adornee     = bp

		local lbl = Instance.new("TextLabel", bb)
		lbl.Size                = UDim2.new(1,0,1,0)
		lbl.BackgroundColor3    = hexToC3(elem.bgColor or "#1a1a2e")
		lbl.TextColor3          = hexToC3(elem.textColor or "#ffffff")
		lbl.Text                = elem.text or "!"
		lbl.TextScaled          = true
		lbl.BackgroundTransparency = 0.1
		lbl.BorderSizePixel     = 0

		table.insert(self.active, {
			inst      = bp,
			cfg       = elem,
			spawnTime = os.clock(),
			rotX=0,rotY=0,rotZ=0,
			parentCF_fn = function()
				if cframes and getPart then
					local pt = getPart(elem.parentPart or "Head")
					if pt and cframes[pt] then return cframes[pt] end
				end
				return rootCF
			end
		})
	end
end

function VFX:spawnOnce(cframes, getPart, cfMul, cf, angles, v3)
	local elems = self.config.elements or {}
	for _, elem in ipairs(elems) do
		self:_spawnElement(elem, cframes, getPart, cfMul, cf, angles, v3)
	end

	local life = self.config.lifetime or 0
	if life > 0 and self.config.destroyOn and self.config.destroyOn.timer then
		task.delay(life, function() self:destroyAll() end)
	end
end

function VFX:spawn(cframes, getPart, cfMul, cf, angles, v3)
	local now = os.clock()
	local thr = self.config.throttle or 0.3
	if (now - self._lastSpawn) < thr then return end
	self._lastSpawn = now
	self:spawnOnce(cframes, getPart, cfMul, cf, angles, v3)
end

function VFX:destroyAll()
	for i = #self.active, 1, -1 do
		local entry = self.active[i]
		local inst  = entry.inst
		if inst and inst.Parent then
			-- disable particle emitters before destroying so they fade
			for _, ch in ipairs(inst:GetChildren()) do
				if ch:IsA("ParticleEmitter") then ch.Enabled = false end
			end
			task.delay(0.5, function()
				if inst and inst.Parent then inst:Destroy() end
			end)
		end
		table.remove(self.active, i)
	end
end

--[[
  Call this every Heartbeat / PreAnimation to animate:
    inf rotation, sin position, sin angle, sin size
  sine = os.clock() value (same one your reanimate uses)
  delta = deltaTime
--]]
function VFX:update(sine, delta, cframes, getPart)
	for _, entry in ipairs(self.active) do
		local inst = entry.inst
		local cfg  = entry.cfg
		if not (inst and inst.Parent) then continue end

		-- get live parent CFrame
		local parentCF = entry.parentCF_fn and entry.parentCF_fn() or CFrame.new(0,0,0)

		-- accumulate infinite rotation
		local irx = (cfg.infRotX or 0) * delta
		local iry = (cfg.infRotY or 0) * delta
		local irz = (cfg.infRotZ or 0) * delta
		entry.rotX = (entry.rotX or 0) + irx
		entry.rotY = (entry.rotY or 0) + iry
		entry.rotZ = (entry.rotZ or 0) + irz

		-- sin position
		local spx = cfg.sinPosX and cfg.sinPosX.amp * sin(sine * (cfg.sinPosX.spd or 1)) or 0
		local spy = cfg.sinPosY and cfg.sinPosY.amp * sin(sine * (cfg.sinPosY.spd or 1)) or 0
		local spz = cfg.sinPosZ and cfg.sinPosZ.amp * sin(sine * (cfg.sinPosZ.spd or 1)) or 0

		-- sin angle (added on top of inf rotation)
		local sax = cfg.sinAngX and cfg.sinAngX.amp * sin(sine * (cfg.sinAngX.spd or 1)) or 0
		local say = cfg.sinAngY and cfg.sinAngY.amp * sin(sine * (cfg.sinAngY.spd or 1)) or 0
		local saz = cfg.sinAngZ and cfg.sinAngZ.amp * sin(sine * (cfg.sinAngZ.spd or 1)) or 0

		if cfg.type == "part" then
			-- sin size
			local baseSz = cfg.size or 1.2
			local ss = cfg.sinSize and cfg.sinSize.amp * sin(sine * (cfg.sinSize.spd or 1)) or 0
			local sz = math.max(0.05, baseSz + ss)
			if inst.Size ~= Vector3.new(sz,sz,sz) then
				inst.Size = Vector3.new(sz,sz,sz)
			end

			-- base offset + sin pos
			local ox = (cfg.offsetX or 0) + spx
			local oy = (cfg.offsetY or 1.5) + spy
			local oz = (cfg.offsetZ or 0) + spz

			-- rotation = static base + inf accumulated + sin angle
			local staticR = math.rad(cfg.rot or 0)
			local rotCF = CFrame.fromEulerAngles(
				entry.rotX + sax,
				entry.rotY + say,
				entry.rotZ + saz + staticR
			)
			inst.CFrame = parentCF * CFrame.new(ox, oy, oz) * rotCF

		elseif cfg.type == "beam" or cfg.type == "trail" then
			local ox = (cfg.offsetX or 0) + spx
			local oy = (cfg.offsetY or 0) + spy
			local oz = (cfg.offsetZ or 0) + spz
			local rotCF = CFrame.fromEulerAngles(
				entry.rotX + sax,
				entry.rotY + say,
				entry.rotZ + saz
			)
			inst.CFrame = parentCF * CFrame.new(ox, oy, oz) * rotCF

		elseif cfg.type == "particles" then
			local ox = spx
			local oy = spy
			local oz = spz
			inst.CFrame = parentCF * CFrame.new(ox, oy, oz)

		elseif cfg.type == "billboard" then
			local baseY = cfg.offsetY or 2.5
			inst.CFrame = parentCF * CFrame.new(spx, baseY + spy, spz)
		end
	end
end

-- ════════════════════════════════════════════════════════════
--   LUA CODE GENERATOR  (mirrors the HTML tool output)
-- ════════════════════════════════════════════════════════════

local function generateCode(config)
	local L = {}
	local name     = config.exportName or "VFX"
	local life     = config.lifetime   or 0
	local thr      = config.throttle   or 0.3
	local spawnOn  = config.spawnOn    or { onStart=true }
	local dOn      = config.destroyOn  or { attackEnd=true, modeLeave=true }
	local elems    = config.elements   or {}

	local triggers = {}
	for k,v in pairs(spawnOn)  do if v then table.insert(triggers, k) end end
	local destroys = {}
	for k,v in pairs(dOn) do if v then table.insert(destroys, k) end end

	table.insert(L, "-- ════════════════════════════════════════════")
	table.insert(L, "-- VFX System — " .. name)
	table.insert(L, "-- Spawn on:   " .. table.concat(triggers,", "))
	table.insert(L, "-- Destroy on: " .. table.concat(destroys,", ") .. (dOn.timer and " ("..life.."s)" or ""))
	table.insert(L, "-- ════════════════════════════════════════════")
	table.insert(L, "")
	table.insert(L, "local "..name.." = (function()")
	table.insert(L, "  local active = {}")
	table.insert(L, "  local _lastSpawn = 0")
	table.insert(L, "  local _animData  = {}  -- per-instance animation state")
	table.insert(L, "")
	table.insert(L, "  local function spawnAll(cframes, getPart, cfMul, cf, angles, v3, ws)")
	table.insert(L, "    local rootCF = CFrame.new(0,0,0)")
	table.insert(L, "    for k,v in next, cframes do")
	table.insert(L, '      if k.Name == "HumanoidRootPart" or k.Name == "Torso" then rootCF = v break end')
	table.insert(L, "    end")
	table.insert(L, "")

	-- Helper to write parentCF resolution
	local function writePCF(indent, parentPart)
		local pp = parentPart or "HumanoidRootPart"
		table.insert(L, indent..'local parentCF = rootCF')
		table.insert(L, indent..'do')
		table.insert(L, indent..'  local _pt = getPart("'..pp..'")')
		table.insert(L, indent..'  if _pt and cframes[_pt] then parentCF = cframes[_pt] end')
		table.insert(L, indent..'end')
	end

	for _, elem in ipairs(elems) do
		local ename = (elem.name or elem.type):gsub("%s","_")
		table.insert(L, "    do -- "..ename)

		if elem.type == "part" then
			writePCF("      ", elem.parentPart)
			table.insert(L, '      local p = Instance.new("Part")')
			table.insert(L, '      p.Name = "'..ename..'"')
			local shapeMap = {sphere="Ball",block="Block",cylinder="Cylinder",wedge="Wedge",
			                  Ball="Ball",Block="Block",Cylinder="Cylinder",Wedge="Wedge"}
			table.insert(L, '      p.Shape = Enum.PartType.'..(shapeMap[elem.shape or "sphere"] or "Ball"))
			local c = elem.color or "#b4b0ff"
			local r = tonumber(c:sub(2,3),16)/255
			local g = tonumber(c:sub(4,5),16)/255
			local b2= tonumber(c:sub(6,7),16)/255
			table.insert(L, ('      p.Color = Color3.new(%.2f, %.2f, %.2f)'):format(r,g,b2))
			table.insert(L, '      p.Material = Enum.Material.'..(elem.material or "Neon"))
			table.insert(L, ('      p.Transparency = %.2f'):format(elem.transparency or 0.25))
			local sz = elem.size or 1.2
			table.insert(L, ('      p.Size = Vector3.new(%.2f, %.2f, %.2f)'):format(sz,sz,sz))
			table.insert(L, '      p.Anchored=true; p.CanCollide=false; p.CanQuery=false; p.CanTouch=false; p.CastShadow=false')
			table.insert(L, ('      p.CFrame = parentCF * CFrame.new(%.2f, %.2f, %.2f) * CFrame.fromEulerAngles(0,0,math.rad(%d))'):format(
				elem.offsetX or 0, elem.offsetY or 1.5, elem.offsetZ or 0, elem.rot or 0))
			table.insert(L, '      p.Parent = workspace')
			-- animation state
			local hasAnim = (elem.infRotX or 0)~=0 or (elem.infRotY or 0)~=0 or (elem.infRotZ or 0)~=0
				or elem.sinPosX or elem.sinPosY or elem.sinPosZ
				or elem.sinAngX or elem.sinAngY or elem.sinAngZ
				or elem.sinSize
			if hasAnim then
				table.insert(L, '      table.insert(active, { inst=p, type="part", cfg={')
				table.insert(L, ('        parentPart="%s", offsetX=%.2f, offsetY=%.2f, offsetZ=%.2f, rot=%d, size=%.2f,'):format(
					elem.parentPart or "HumanoidRootPart",
					elem.offsetX or 0, elem.offsetY or 1.5, elem.offsetZ or 0, elem.rot or 0, sz))
				table.insert(L, ('        infRotX=%s, infRotY=%s, infRotZ=%s,'):format(
					tostring(elem.infRotX or 0), tostring(elem.infRotY or 0), tostring(elem.infRotZ or 0)))
				local function sinStr(s)
					if not s then return "nil" end
					return ("{amp=%.2f, spd=%.2f}"):format(s.amp or 0, s.spd or 1)
				end
				table.insert(L, ('        sinPosX=%s, sinPosY=%s, sinPosZ=%s,'):format(sinStr(elem.sinPosX),sinStr(elem.sinPosY),sinStr(elem.sinPosZ)))
				table.insert(L, ('        sinAngX=%s, sinAngY=%s, sinAngZ=%s,'):format(sinStr(elem.sinAngX),sinStr(elem.sinAngY),sinStr(elem.sinAngZ)))
				table.insert(L, ('        sinSize=%s'):format(sinStr(elem.sinSize)))
				table.insert(L, '      }, rotX=0, rotY=0, rotZ=0 })')
			else
				table.insert(L, '      table.insert(active, { inst=p, type="part_static" })')
			end

		elseif elem.type == "beam" then
			writePCF("      ", elem.parentPart)
			table.insert(L, '      local hp = Instance.new("Part")')
			table.insert(L, '      hp.Name = "'..ename..'_Host"')
			table.insert(L, '      hp.Anchored=true; hp.CanCollide=false; hp.Transparency=1; hp.Size=Vector3.new(0.1,0.1,0.1)')
			table.insert(L, '      hp.CFrame = parentCF; hp.Parent = workspace')
			table.insert(L, '      local a0=Instance.new("Attachment",hp)')
			table.insert(L, '      local a1=Instance.new("Attachment",hp)')
			table.insert(L, ('      a1.Position = Vector3.new(0,0,-%.1f)'):format(elem.length or 5))
			table.insert(L, '      local bm = Instance.new("Beam")')
			table.insert(L, '      bm.Attachment0=a0; bm.Attachment1=a1')
			local c0 = elem.color0 or "#ffffff"
			local c1 = elem.color1 or "#7f77dd"
			local r0,g0,b0_ = tonumber(c0:sub(2,3),16)/255, tonumber(c0:sub(4,5),16)/255, tonumber(c0:sub(6,7),16)/255
			local r1,g1,b1_ = tonumber(c1:sub(2,3),16)/255, tonumber(c1:sub(4,5),16)/255, tonumber(c1:sub(6,7),16)/255
			table.insert(L, ('      bm.Color = ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.new(%.2f,%.2f,%.2f)),ColorSequenceKeypoint.new(1,Color3.new(%.2f,%.2f,%.2f))})'):format(r0,g0,b0_,r1,g1,b1_))
			table.insert(L, ('      bm.Width0=%.2f; bm.Width1=%.2f'):format(elem.width0 or 0.6, elem.width1 or 0))
			table.insert(L, '      bm.FaceCamera=true; bm.Parent=hp')
			table.insert(L, '      table.insert(active, { inst=hp, type="beam", cfg={ parentPart="'..(elem.parentPart or "HumanoidRootPart")..'", infRotX='..(elem.infRotX or 0)..', infRotY='..(elem.infRotY or 0)..', infRotZ='..(elem.infRotZ or 0)..' }, rotX=0,rotY=0,rotZ=0 })')

		elseif elem.type == "trail" then
			writePCF("      ", elem.parentPart)
			table.insert(L, '      local tp = Instance.new("Part")')
			table.insert(L, '      tp.Name = "'..ename..'_Host"')
			table.insert(L, '      tp.Anchored=true; tp.CanCollide=false; tp.Transparency=1; tp.Size=Vector3.new(0.1,0.1,0.1)')
			table.insert(L, '      tp.CFrame = parentCF; tp.Parent = workspace')
			table.insert(L, '      local ta0=Instance.new("Attachment",tp)')
			table.insert(L, '      local ta1=Instance.new("Attachment",tp)')
			table.insert(L, ('      ta1.Position=Vector3.new(0,%.2f,0)'):format(elem.width or 0.5))
			table.insert(L, '      local tr = Instance.new("Trail")')
			table.insert(L, '      tr.Attachment0=ta0; tr.Attachment1=ta1')
			local c0 = elem.color0 or "#ffffff"
			local c1 = elem.color1 or "#7f77dd"
			local r0,g0,b0_ = tonumber(c0:sub(2,3),16)/255, tonumber(c0:sub(4,5),16)/255, tonumber(c0:sub(6,7),16)/255
			local r1,g1,b1_ = tonumber(c1:sub(2,3),16)/255, tonumber(c1:sub(4,5),16)/255, tonumber(c1:sub(6,7),16)/255
			table.insert(L, ('      tr.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.new(%.2f,%.2f,%.2f)),ColorSequenceKeypoint.new(1,Color3.new(%.2f,%.2f,%.2f))})'):format(r0,g0,b0_,r1,g1,b1_))
			table.insert(L, ('      tr.Lifetime=%.2f; tr.MinDistance=0.05'):format(elem.lifetime or 0.5))
			table.insert(L, '      tr.Parent=tp')
			table.insert(L, '      table.insert(active, { inst=tp, type="trail", cfg={ parentPart="'..(elem.parentPart or "HumanoidRootPart")..'" }, rotX=0,rotY=0,rotZ=0 })')

		elseif elem.type == "particles" then
			writePCF("      ", elem.parentPart)
			table.insert(L, '      local ep = Instance.new("Part")')
			table.insert(L, '      ep.Name = "'..ename..'_Host"')
			table.insert(L, '      ep.Anchored=true; ep.CanCollide=false; ep.Transparency=1; ep.Size=Vector3.new(0.1,0.1,0.1)')
			table.insert(L, '      ep.CFrame = parentCF; ep.Parent = workspace')
			table.insert(L, '      local pe = Instance.new("ParticleEmitter",ep)')
			table.insert(L, '      pe.Name = "'..ename..'"')
			local c = elem.color or "#b4b0ff"
			local r,g,b2 = tonumber(c:sub(2,3),16)/255, tonumber(c:sub(4,5),16)/255, tonumber(c:sub(6,7),16)/255
			table.insert(L, ('      pe.Color = ColorSequence.new(Color3.new(%.2f,%.2f,%.2f))'):format(r,g,b2))
			table.insert(L, '      pe.Rate = '..(elem.rate or 30))
			table.insert(L, ('      pe.Speed = NumberRange.new(%.1f)'):format(elem.speed or 3))
			table.insert(L, ('      pe.Lifetime = NumberRange.new(%.2f)'):format(elem.pLifetime or 0.6))
			table.insert(L, ('      pe.Size = NumberSequence.new(%.2f)'):format(elem.size or 0.4))
			local half = (elem.spread or 180)/2
			table.insert(L, ('      pe.SpreadAngle = Vector2.new(-%.0f,%.0f)'):format(half,half))
			table.insert(L, '      pe.LightInfluence = 0')
			table.insert(L, '      table.insert(active, { inst=ep, type="particles", cfg={ parentPart="'..(elem.parentPart or "HumanoidRootPart")..'" }, rotX=0,rotY=0,rotZ=0 })')

		elseif elem.type == "billboard" then
			writePCF("      ", elem.parentPart)
			table.insert(L, '      local bp = Instance.new("Part")')
			table.insert(L, '      bp.Name = "'..ename..'_Host"')
			table.insert(L, '      bp.Anchored=true; bp.CanCollide=false; bp.Transparency=1; bp.Size=Vector3.new(0.1,0.1,0.1)')
			table.insert(L, ('      bp.CFrame = parentCF * CFrame.new(0,%.2f,0)'):format(elem.offsetY or 2.5))
			table.insert(L, '      bp.Parent = workspace')
			table.insert(L, '      local bb = Instance.new("BillboardGui",bp)')
			local bsz = math.floor((elem.size or 1)*60)
			table.insert(L, ('      bb.Size = UDim2.new(0,%d,0,%d)'):format(bsz*2,bsz))
			table.insert(L, '      bb.AlwaysOnTop=true; bb.Adornee=bp')
			table.insert(L, '      local lbl2 = Instance.new("TextLabel",bb)')
			table.insert(L, '      lbl2.Size=UDim2.new(1,0,1,0); lbl2.BackgroundTransparency=0.1; lbl2.TextScaled=true; lbl2.BorderSizePixel=0')
			local tc = elem.textColor or "#ffffff"
			local bg = elem.bgColor or "#1a1a2e"
			local tr,tg,tb = tonumber(tc:sub(2,3),16)/255, tonumber(tc:sub(4,5),16)/255, tonumber(tc:sub(6,7),16)/255
			local br,bgg,bb2= tonumber(bg:sub(2,3),16)/255, tonumber(bg:sub(4,5),16)/255, tonumber(bg:sub(6,7),16)/255
			table.insert(L, ('      lbl2.TextColor3=Color3.new(%.2f,%.2f,%.2f)'):format(tr,tg,tb))
			table.insert(L, ('      lbl2.BackgroundColor3=Color3.new(%.2f,%.2f,%.2f)'):format(br,bgg,bb2))
			table.insert(L, '      lbl2.Text="'..(elem.text or "!") ..'"')
			local spySin = elem.sinPosY
			local spyStr = spySin and ('{amp='..tostring(spySin.amp or 0)..', spd='..tostring(spySin.spd or 1)..'}') or "nil"
			table.insert(L, '      table.insert(active, { inst=bp, type="billboard", cfg={ parentPart="'..(elem.parentPart or "Head")..'", offsetY='..(elem.offsetY or 2.5)..', sinPosY='..spyStr..' }, rotX=0,rotY=0,rotZ=0 })')
		end

		table.insert(L, "    end")
		table.insert(L, "")
	end

	if life > 0 and dOn.timer then
		table.insert(L, ('    task.delay(%.1f, function() '..name..'.destroyAll() end)'):format(life))
	end

	table.insert(L, "  end")
	table.insert(L, "")
	-- update function
	table.insert(L, "  local function updateAll(sine, delta, cframes, getPart)")
	table.insert(L, "    for _, entry in ipairs(active) do")
	table.insert(L, "      local inst = entry.inst")
	table.insert(L, "      local cfg2  = entry.cfg")
	table.insert(L, "      if not (inst and inst.Parent and cfg2) then continue end")
	table.insert(L, "      local parentCF = CFrame.new(0,0,0)")
	table.insert(L, '      if cframes and getPart and cfg2.parentPart then')
	table.insert(L, '        local _pt = getPart(cfg2.parentPart)')
	table.insert(L, '        if _pt and cframes[_pt] then parentCF = cframes[_pt] end')
	table.insert(L, '      end')
	table.insert(L, "      entry.rotX = (entry.rotX or 0) + (cfg2.infRotX or 0)*delta")
	table.insert(L, "      entry.rotY = (entry.rotY or 0) + (cfg2.infRotY or 0)*delta")
	table.insert(L, "      entry.rotZ = (entry.rotZ or 0) + (cfg2.infRotZ or 0)*delta")
	table.insert(L, "      local spx = cfg2.sinPosX and cfg2.sinPosX.amp*math.sin(sine*(cfg2.sinPosX.spd or 1)) or 0")
	table.insert(L, "      local spy = cfg2.sinPosY and cfg2.sinPosY.amp*math.sin(sine*(cfg2.sinPosY.spd or 1)) or 0")
	table.insert(L, "      local spz = cfg2.sinPosZ and cfg2.sinPosZ.amp*math.sin(sine*(cfg2.sinPosZ.spd or 1)) or 0")
	table.insert(L, "      local sax = cfg2.sinAngX and cfg2.sinAngX.amp*math.sin(sine*(cfg2.sinAngX.spd or 1)) or 0")
	table.insert(L, "      local say = cfg2.sinAngY and cfg2.sinAngY.amp*math.sin(sine*(cfg2.sinAngY.spd or 1)) or 0")
	table.insert(L, "      local saz = cfg2.sinAngZ and cfg2.sinAngZ.amp*math.sin(sine*(cfg2.sinAngZ.spd or 1)) or 0")
	table.insert(L, '      if entry.type == "part" then')
	table.insert(L, "        local ss = cfg2.sinSize and cfg2.sinSize.amp*math.sin(sine*(cfg2.sinSize.spd or 1)) or 0")
	table.insert(L, "        local sz2 = math.max(0.05,(cfg2.size or 1.2)+ss)")
	table.insert(L, "        inst.Size = Vector3.new(sz2,sz2,sz2)")
	table.insert(L, "        local ox = (cfg2.offsetX or 0)+spx")
	table.insert(L, "        local oy = (cfg2.offsetY or 1.5)+spy")
	table.insert(L, "        local oz = (cfg2.offsetZ or 0)+spz")
	table.insert(L, "        local rotCF = CFrame.fromEulerAngles(entry.rotX+sax, entry.rotY+say, entry.rotZ+saz+math.rad(cfg2.rot or 0))")
	table.insert(L, "        inst.CFrame = parentCF * CFrame.new(ox,oy,oz) * rotCF")
	table.insert(L, '      elseif entry.type == "beam" or entry.type == "trail" then')
	table.insert(L, "        local rotCF = CFrame.fromEulerAngles(entry.rotX+sax, entry.rotY+say, entry.rotZ+saz)")
	table.insert(L, "        inst.CFrame = parentCF * CFrame.new(spx,spy,spz) * rotCF")
	table.insert(L, '      elseif entry.type == "particles" then')
	table.insert(L, "        inst.CFrame = parentCF * CFrame.new(spx,spy,spz)")
	table.insert(L, '      elseif entry.type == "billboard" then')
	table.insert(L, "        inst.CFrame = parentCF * CFrame.new(spx,(cfg2.offsetY or 2.5)+spy,spz)")
	table.insert(L, "      end")
	table.insert(L, "    end")
	table.insert(L, "  end")
	table.insert(L, "")
	table.insert(L, "  local function destroyAll()")
	table.insert(L, "    for i = #active, 1, -1 do")
	table.insert(L, "      local entry = active[i]")
	table.insert(L, "      local inst = entry.inst")
	table.insert(L, "      if inst and inst.Parent then")
	table.insert(L, '        for _,ch in ipairs(inst:GetChildren()) do')
	table.insert(L, '          if ch:IsA("ParticleEmitter") then ch.Enabled=false end')
	table.insert(L, "        end")
	table.insert(L, "        task.delay(0.5, function() if inst and inst.Parent then inst:Destroy() end end)")
	table.insert(L, "      end")
	table.insert(L, "      table.remove(active, i)")
	table.insert(L, "    end")
	table.insert(L, "  end")
	table.insert(L, "")
	table.insert(L, "  local function trySpawn(cframes, getPart, cfMul, cf, angles, v3, ws)")
	if spawnOn.loop then
		table.insert(L, "    local now = os.clock()")
		table.insert(L, ('    if (now - _lastSpawn) < %.2f then return end'):format(thr))
		table.insert(L, "    _lastSpawn = now")
	end
	table.insert(L, "    spawnAll(cframes, getPart, cfMul, cf, angles, v3, ws)")
	table.insert(L, "  end")
	table.insert(L, "")
	table.insert(L, "  return { spawn=trySpawn, spawnOnce=spawnAll, update=updateAll, destroyAll=destroyAll }")
	table.insert(L, "end)()")
	table.insert(L, "")
	table.insert(L, "-- ─────────────────────────────────────────────")
	table.insert(L, "-- Wire "..name.." into your attacks like this:")
	table.insert(L, "-- (replace MyVFX with your export name)")
	table.insert(L, "--")
	if spawnOn.onStart then
		table.insert(L, "-- attacks[\"f\"][\"z\"] = {")
		table.insert(L, "--   duration = 2,")
		table.insert(L, "--   fn = function()")
		table.insert(L, "--     if getAttackProgress() < 0.02 then")
		table.insert(L, ("--       %s.spawnOnce(cframes, getPart, cfMul, cf, angles, v3, workspace)"):format(name))
		table.insert(L, "--     end")
		table.insert(L, ("--     %s.update(sine, deltaTime, cframes, getPart)"):format(name))
		table.insert(L, "--     -- ... your joint lerps ...")
		table.insert(L, "--   end")
		table.insert(L, "-- }")
	end
	if spawnOn.loop then
		table.insert(L, "-- In heartbeat / mainFunction (throttled):")
		table.insert(L, ("-- %s.spawn(cframes, getPart, cfMul, cf, angles, v3, workspace)"):format(name))
		table.insert(L, ("-- %s.update(sine, deltaTime, cframes, getPart)"):format(name))
	end
	if dOn.attackEnd then
		table.insert(L, "-- When attack ends (attackProgress >= 1):")
		table.insert(L, ("-- %s.destroyAll()"):format(name))
	end
	if dOn.modeLeave then
		table.insert(L, "-- In modeLeft callback:")
		table.insert(L, ("-- %s.destroyAll()"):format(name))
	end

	return table.concat(L, "\n")
end

-- ════════════════════════════════════════════════════════════
--   GUI BUILDER
-- ════════════════════════════════════════════════════════════

local Builder = {}

-- Default element configs (mirrors HTML defs)
local DEFS = {
	part      = { type="part",      name="Part",    shape="sphere", color="#b4b0ff", size=1.2,  offsetX=0, offsetY=1.5, offsetZ=0, rot=0, transparency=0.25, material="Neon",  parentPart="Torso",     infRotX=0, infRotY=0, infRotZ=0 },
	beam      = { type="beam",      name="Beam",    color0="#ffffff", color1="#7f77dd", width0=0.6, width1=0, length=5, parentPart="Right Arm", infRotY=0 },
	trail     = { type="trail",     name="Trail",   color0="#ffffff", color1="#7f77dd", lifetime=0.5, width=0.5, parentPart="Right Arm" },
	particles = { type="particles", name="Emitter", color="#b4b0ff", rate=30, speed=3, pLifetime=0.6, size=0.4, spread=180, parentPart="Torso" },
	billboard = { type="billboard", name="Label",   text="!", textColor="#ffffff", bgColor="#1a1a2e", size=1, offsetY=2.5, parentPart="Head" },
}

local function deepcopy(t)
	if type(t) ~= "table" then return t end
	local c = {}
	for k,v in pairs(t) do c[k] = deepcopy(v) end
	return c
end

local function cloneElem(t)
	return deepcopy(DEFS[t])
end

local BODY_PARTS = { "HumanoidRootPart","Torso","Head","Left Arm","Right Arm","Left Leg","Right Leg" }
local SHAPES     = { "sphere","block","cylinder","wedge" }
local MATERIALS  = { "Neon","SmoothPlastic","Glass","Metal","ForceField" }

-- ── GUI State ────────────────────────────────────────────────
local guiOpen    = false
local elements   = {}
local selIdx     = nil
local nextId     = 1
local spawnOn    = { onStart=true, loop=false, onEnd=false, modeEnter=false }
local destroyOn  = { attackEnd=true, modeLeave=true, timer=false }
local cfgLife    = 1.0
local cfgThr     = 0.3
local exportName = "MyVFX"
local activeTab  = "elements"  -- "elements" | "motion" | "code"

-- ── GUI refs ─────────────────────────────────────────────────
local screenGui, mainFrame, listFrame, propFrame, codeFrame, tabCode, tabProps, tabList
local exportBox  -- TextBox for export name

-- ── Colours (matching your reanimate orange theme) ───────────
local COL_BG     = Color3.fromRGB(12, 8, 4)
local COL_BG2    = Color3.fromRGB(25, 16, 10)
local COL_BG3    = Color3.fromRGB(40, 25, 14)
local COL_ACCENT = Color3.fromRGB(255, 170, 80)
local COL_TEXT   = Color3.fromRGB(245, 167, 100)
local COL_TEXT2  = Color3.fromRGB(200, 120, 60)
local COL_SEL    = Color3.fromRGB(60, 35, 15)
local COL_WHITE  = Color3.fromRGB(255, 255, 255)
local COL_RED    = Color3.fromRGB(220, 80, 80)
local COL_GREEN  = Color3.fromRGB(80, 200, 100)

-- ── UI Helpers ───────────────────────────────────────────────
local function makeCorner(parent, radius)
	local c = Instance.new("UICorner", parent)
	c.CornerRadius = UDim.new(0, radius or 6)
	return c
end

local function makeLabel(parent, text, size, color, xScale, yScale, xOff, yOff, bold)
	local l = Instance.new("TextLabel", parent)
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.Text = text
	l.TextSize = size or 13
	l.TextColor3 = color or COL_TEXT
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	l.Size = UDim2.new(xScale or 1, 0, yScale or 0, size and (size+4) or 18)
	l.Position = UDim2.new(0, xOff or 0, 0, yOff or 0)
	return l
end

local function makeButton(parent, text, color, xScale, yScale, xOff, yOff, w, h)
	local btn = Instance.new("TextButton", parent)
	btn.BackgroundColor3 = color or COL_BG3
	btn.BorderSizePixel = 0
	btn.TextColor3 = COL_WHITE
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 11
	btn.Text = text
	btn.Size = UDim2.new(xScale or 0, w or 80, yScale or 0, h or 24)
	btn.Position = UDim2.new(0, xOff or 0, 0, yOff or 0)
	makeCorner(btn, 5)
	return btn
end

local function makeTextBox(parent, defaultText, xScale, yScale, xOff, yOff, w, h)
	local tb = Instance.new("TextBox", parent)
	tb.BackgroundColor3 = COL_BG3
	tb.BorderSizePixel = 0
	tb.TextColor3 = COL_TEXT
	tb.Font = Enum.Font.Gotham
	tb.TextSize = 11
	tb.Text = defaultText or ""
	tb.ClearTextOnFocus = false
	tb.Size = UDim2.new(xScale or 1, 0, yScale or 0, h or 20)
	tb.Position = UDim2.new(0, xOff or 0, 0, yOff or 0)
	makeCorner(tb, 4)
	return tb
end

local function makeSlider(parent, label, minV, maxV, defV, stepV, unit, onChange, yOff)
	local row = Instance.new("Frame", parent)
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 22)
	row.Position = UDim2.new(0, 0, 0, yOff or 0)
	row.BorderSizePixel = 0

	local lbl = Instance.new("TextLabel", row)
	lbl.BackgroundTransparency = 1
	lbl.BorderSizePixel = 0
	lbl.Text = label
	lbl.TextSize = 11
	lbl.TextColor3 = COL_TEXT2
	lbl.Font = Enum.Font.Gotham
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Size = UDim2.new(0, 90, 1, 0)

	local track = Instance.new("Frame", row)
	track.BackgroundColor3 = COL_BG3
	track.BorderSizePixel = 0
	track.Size = UDim2.new(1, -150, 0, 6)
	track.Position = UDim2.new(0, 95, 0.5, -3)
	makeCorner(track, 3)

	local fill = Instance.new("Frame", track)
	fill.BackgroundColor3 = COL_ACCENT
	fill.BorderSizePixel = 0
	fill.Size = UDim2.new((defV-minV)/(maxV-minV), 0, 1, 0)
	makeCorner(fill, 3)

	local valLbl = Instance.new("TextLabel", row)
	valLbl.BackgroundTransparency = 1
	valLbl.BorderSizePixel = 0
	valLbl.TextColor3 = COL_TEXT
	valLbl.Font = Enum.Font.GothamBold
	valLbl.TextSize = 11
	valLbl.TextXAlignment = Enum.TextXAlignment.Right
	valLbl.Size = UDim2.new(0, 50, 1, 0)
	valLbl.Position = UDim2.new(1, -50, 0, 0)
	local fmt = (stepV < 1) and "%.2f" or "%.0f"
	valLbl.Text = (fmt):format(defV) .. (unit or "")

	local curVal = defV
	local dragging = false

	local function updateFill(v)
		curVal = math.clamp(v, minV, maxV)
		local steps = math.round((curVal - minV) / stepV)
		curVal = minV + steps * stepV
		curVal = math.clamp(curVal, minV, maxV)
		fill.Size = UDim2.new((curVal-minV)/(maxV-minV), 0, 1, 0)
		valLbl.Text = (fmt):format(curVal) .. (unit or "")
		if onChange then onChange(curVal) end
	end

	track.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			local relX = inp.Position.X - track.AbsolutePosition.X
			local pct  = math.clamp(relX / track.AbsoluteSize.X, 0, 1)
			updateFill(minV + pct*(maxV-minV))
		end
	end)
	UIS.InputChanged:Connect(function(inp)
		if dragging and inp.UserInputType == Enum.UserInputType.MouseMovement then
			local relX = inp.Position.X - track.AbsolutePosition.X
			local pct  = math.clamp(relX / track.AbsoluteSize.X, 0, 1)
			updateFill(minV + pct*(maxV-minV))
		end
	end)
	UIS.InputEnded:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)

	return row, function() return curVal end, updateFill
end

local function makeDropdown(parent, label, options, def, onChange, yOff)
	local row = Instance.new("Frame", parent)
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 22)
	row.Position = UDim2.new(0, 0, 0, yOff or 0)
	row.BorderSizePixel = 0

	local lbl = Instance.new("TextLabel", row)
	lbl.BackgroundTransparency = 1
	lbl.BorderSizePixel = 0
	lbl.Text = label
	lbl.TextSize = 11
	lbl.TextColor3 = COL_TEXT2
	lbl.Font = Enum.Font.Gotham
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Size = UDim2.new(0, 90, 1, 0)

	local btn = Instance.new("TextButton", row)
	btn.BackgroundColor3 = COL_BG3
	btn.BorderSizePixel = 0
	btn.TextColor3 = COL_TEXT
	btn.Font = Enum.Font.Gotham
	btn.TextSize = 11
	btn.Text = def or options[1] or ""
	btn.TextXAlignment = Enum.TextXAlignment.Left
	btn.Size = UDim2.new(1, -95, 1, -2)
	btn.Position = UDim2.new(0, 95, 0, 1)
	makeCorner(btn, 4)

	local cur = def or options[1]
	local open = false
	local dropFrame = nil

	btn.MouseButton1Click:Connect(function()
		open = not open
		if dropFrame then dropFrame:Destroy(); dropFrame = nil end
		if not open then return end
		dropFrame = Instance.new("Frame", btn)
		dropFrame.BackgroundColor3 = COL_BG2
		dropFrame.BorderSizePixel = 0
		dropFrame.Size = UDim2.new(1, 0, 0, #options * 20)
		dropFrame.Position = UDim2.new(0, 0, 1, 2)
		dropFrame.ZIndex = 20
		makeCorner(dropFrame, 4)
		for i, opt in ipairs(options) do
			local ob = Instance.new("TextButton", dropFrame)
			ob.BackgroundTransparency = 1
			ob.BorderSizePixel = 0
			ob.Text = opt
			ob.TextSize = 11
			ob.TextColor3 = COL_TEXT
			ob.Font = Enum.Font.Gotham
			ob.TextXAlignment = Enum.TextXAlignment.Left
			ob.Size = UDim2.new(1, -8, 0, 20)
			ob.Position = UDim2.new(0, 4, 0, (i-1)*20)
			ob.ZIndex = 21
			ob.MouseButton1Click:Connect(function()
				cur = opt
				btn.Text = opt
				open = false
				if dropFrame then dropFrame:Destroy(); dropFrame = nil end
				if onChange then onChange(opt) end
			end)
		end
	end)

	return row
end

-- ── Rebuild the full GUI ──────────────────────────────────────
local function buildMainGUI()
	if screenGui then screenGui:Destroy() end

	screenGui = Instance.new("ScreenGui", pg)
	screenGui.Name = "VFX_Builder"
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 999

	-- Main window
	mainFrame = Instance.new("Frame", screenGui)
	mainFrame.Name = "Main"
	mainFrame.BackgroundColor3 = COL_BG
	mainFrame.BorderSizePixel = 0
	mainFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	mainFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
	mainFrame.Size = UDim2.new(0, 660, 0, 500)
	makeCorner(mainFrame, 10)

	-- Gradient
	local grad = Instance.new("UIGradient", mainFrame)
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, COL_BG2),
		ColorSequenceKeypoint.new(1, COL_BG)
	})
	grad.Rotation = 90

	-- Stroke
	local stroke = Instance.new("UIStroke", mainFrame)
	stroke.Color = COL_ACCENT
	stroke.Thickness = 1.5
	stroke.Transparency = 0.4

	-- Title bar
	local titleBar = Instance.new("Frame", mainFrame)
	titleBar.BackgroundColor3 = COL_BG3
	titleBar.BorderSizePixel = 0
	titleBar.Size = UDim2.new(1, 0, 0, 36)
	makeCorner(titleBar, 10)

	local titleLbl = makeLabel(titleBar, "  ⚡ VFX Builder  —  Exire Reanimate", 14, COL_ACCENT, 1, 1, 0, 0, true)
	titleLbl.TextYAlignment = Enum.TextYAlignment.Center
	titleLbl.Size = UDim2.new(1, -40, 1, 0)

	-- Drag
	local dragStart, winStart
	titleBar.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then
			dragStart = inp.Position
			winStart  = mainFrame.Position
		end
	end)
	UIS.InputChanged:Connect(function(inp)
		if dragStart and inp.UserInputType == Enum.UserInputType.MouseMovement then
			local delta = inp.Position - dragStart
			mainFrame.Position = UDim2.new(
				winStart.X.Scale, winStart.X.Offset + delta.X,
				winStart.Y.Scale, winStart.Y.Offset + delta.Y)
		end
	end)
	UIS.InputEnded:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then
			dragStart = nil
		end
	end)

	-- Close button
	local closeBtn = makeButton(titleBar, "✕", COL_RED, 0, 0, 0, 4, 28, 28)
	closeBtn.Position = UDim2.new(1, -32, 0, 4)
	closeBtn.MouseButton1Click:Connect(function()
		screenGui:Destroy()
		screenGui = nil
		guiOpen = false
	end)

	-- ── Left column: elements list + add buttons ──────────────
	local leftCol = Instance.new("Frame", mainFrame)
	leftCol.BackgroundColor3 = COL_BG2
	leftCol.BorderSizePixel = 0
	leftCol.Size = UDim2.new(0, 175, 1, -36)
	leftCol.Position = UDim2.new(0, 0, 0, 36)
	makeCorner(leftCol, 8)

	-- Export name row
	local expLbl = makeLabel(leftCol, "Export name:", 11, COL_TEXT2, 1, 0, 8, 8)
	exportBox = makeTextBox(leftCol, exportName, 1, 0, 8, 28, 0, 22)
	exportBox.Size = UDim2.new(1, -16, 0, 22)
	exportBox.Position = UDim2.new(0, 8, 0, 26)
	exportBox.FocusLost:Connect(function()
		exportName = exportBox.Text ~= "" and exportBox.Text or "MyVFX"
	end)

	-- Elements section label
	makeLabel(leftCol, "Elements", 11, COL_TEXT2, 1, 0, 8, 55, true)

	-- Scrolling list of elements
	local listScroll = Instance.new("ScrollingFrame", leftCol)
	listScroll.BackgroundTransparency = 1
	listScroll.BorderSizePixel = 0
	listScroll.Size = UDim2.new(1, 0, 1, -180)
	listScroll.Position = UDim2.new(0, 0, 0, 72)
	listScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	listScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listScroll.ScrollBarThickness = 4
	listScroll.ScrollBarImageColor3 = COL_ACCENT

	listFrame = listScroll

	local listLayout = Instance.new("UIListLayout", listScroll)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 3)

	local listPad = Instance.new("UIPadding", listScroll)
	listPad.PaddingLeft   = UDim.new(0, 4)
	listPad.PaddingRight  = UDim.new(0, 4)
	listPad.PaddingTop    = UDim.new(0, 4)

	-- Add element buttons
	local addArea = Instance.new("Frame", leftCol)
	addArea.BackgroundTransparency = 1
	addArea.BorderSizePixel = 0
	addArea.Size = UDim2.new(1, 0, 0, 105)
	addArea.Position = UDim2.new(0, 0, 1, -110)

	local sep = Instance.new("Frame", addArea)
	sep.BackgroundColor3 = COL_ACCENT
	sep.BorderSizePixel = 0
	sep.Size = UDim2.new(1, -16, 0, 1)
	sep.Position = UDim2.new(0, 8, 0, 4)
	sep.BackgroundTransparency = 0.7

	makeLabel(addArea, "Add element:", 10, COL_TEXT2, 1, 0, 8, 10)

	local typeButtons = {
		{ "Part",     "part"      },
		{ "Beam",     "beam"      },
		{ "Trail",    "trail"     },
		{ "Emitter",  "particles" },
		{ "Label",    "billboard" },
	}
	local addGrid = Instance.new("Frame", addArea)
	addGrid.BackgroundTransparency = 1
	addGrid.BorderSizePixel = 0
	addGrid.Size = UDim2.new(1, -8, 0, 80)
	addGrid.Position = UDim2.new(0, 4, 0, 24)

	local addGL = Instance.new("UIGridLayout", addGrid)
	addGL.CellSize = UDim2.new(0.5, -3, 0, 22)
	addGL.CellPadding = UDim2.new(0, 3, 0, 3)

	for _, tb2 in ipairs(typeButtons) do
		local ab = Instance.new("TextButton", addGrid)
		ab.BackgroundColor3 = COL_BG3
		ab.BorderSizePixel = 0
		ab.TextColor3 = COL_TEXT
		ab.Font = Enum.Font.Gotham
		ab.TextSize = 10
		ab.Text = "+ " .. tb2[1]
		makeCorner(ab, 4)
		local t2 = tb2[2]
		ab.MouseButton1Click:Connect(function()
			local elem = cloneElem(t2)
			elem.name = elem.name .. " " .. nextId
			elem._id  = nextId
			nextId = nextId + 1
			table.insert(elements, elem)
			selIdx = #elements
			Builder.rebuild()
		end)
	end

	-- ── Right panel: tabs (Properties / Motion / Code) ────────
	local rightPanel = Instance.new("Frame", mainFrame)
	rightPanel.BackgroundTransparency = 1
	rightPanel.BorderSizePixel = 0
	rightPanel.Size = UDim2.new(1, -183, 1, -44)
	rightPanel.Position = UDim2.new(0, 179, 0, 40)

	-- Tabs
	local tabBar = Instance.new("Frame", rightPanel)
	tabBar.BackgroundTransparency = 1
	tabBar.BorderSizePixel = 0
	tabBar.Size = UDim2.new(1, 0, 0, 28)

	local tabBtns = {}
	local function switchTab(name)
		activeTab = name
		for n, btn2 in pairs(tabBtns) do
			btn2.BackgroundColor3 = (n == name) and COL_BG3 or COL_BG2
			btn2.TextColor3 = (n == name) and COL_ACCENT or COL_TEXT2
		end
		propFrame.Visible  = (name == "props")
		codeFrame.Visible  = (name == "code")
	end

	local tabNames = { {"props","Properties"}, {"code","Lua Output"} }
	for i, tn in ipairs(tabNames) do
		local tb3 = makeButton(tabBar, tn[2], COL_BG2, 0, 0, (i-1)*100, 2, 95, 24)
		tb3.TextColor3 = COL_TEXT2
		tabBtns[tn[1]] = tb3
		tb3.MouseButton1Click:Connect(function()
			if tn[1] == "code" then Builder.rebuildCode() end
			switchTab(tn[1])
		end)
	end

	-- Copy + Export buttons top right
	local copyBtn = makeButton(tabBar, "📋 Copy", COL_BG3, 0, 0, 0, 2, 70, 24)
	copyBtn.Position = UDim2.new(1, -150, 0, 2)
	copyBtn.MouseButton1Click:Connect(function()
		Builder.rebuildCode()
		local code = codeFrame:FindFirstChild("CodeLabel")
		if code then
			setclipboard(code.Text)
		end
	end)

	local presetBtn = makeButton(tabBar, "⚙ Presets ▾", COL_BG3, 0, 0, 0, 2, 80, 24)
	presetBtn.Position = UDim2.new(1, -78, 0, 2)
	presetBtn.MouseButton1Click:Connect(function()
		-- Simple preset picker
		local presets = { "Aura","Lightning","Dash trail","Impact burst","Smoke","Sword slash" }
		-- just load "aura" for demo
		local presetMap = {
			Aura = {
				{ type="particles", name="Aura Particles 1", parentPart="Torso", color="#7f77dd", rate=50, speed=2.5, pLifetime=1.2, size=0.35, spread=360 },
				{ type="part",      name="Aura Ring 1",      parentPart="Torso", shape="cylinder", color="#b4b0ff", size=2.5, transparency=0.6, material="Neon", offsetY=0, infRotY=1.5 },
			},
			Lightning = {
				{ type="beam",      name="Lightning Bolt 1", parentPart="Right Arm", color0="#ffffff", color1="#b4b0ff", width0=0.6, width1=0, length=8 },
				{ type="particles", name="Spark Shower 1",   parentPart="Right Arm", color="#ffffcc", rate=100, speed=10, pLifetime=0.15, size=0.12, spread=360 },
			},
			["Dash trail"] = {
				{ type="trail",     name="Dash Trail 1",  parentPart="Torso", color0="#88ffdd", color1="#0f6e56", lifetime=0.5, width=1.2 },
				{ type="particles", name="Dash Sparks 1", parentPart="Torso", color="#88ffdd", rate=40, speed=4, pLifetime=0.3, size=0.2, spread=120 },
			},
			["Sword slash"] = {
				{ type="part",  name="Slash Blade 1", parentPart="Right Arm", shape="wedge", color="#ffffff", size=0.15, offsetX=0, offsetY=0, rot=45, transparency=0.1, material="Neon" },
				{ type="trail", name="Slash Trail 1", parentPart="Right Arm", color0="#ffffff", color1="#b4b0ff", lifetime=0.35, width=0.8 },
			},
			["Impact burst"] = {
				{ type="part",      name="Ring 1",        parentPart="Torso", shape="sphere", color="#ffffff",  size=1,   transparency=0.2, material="Neon" },
				{ type="part",      name="Ring 2",        parentPart="Torso", shape="sphere", color="#ffdd88",  size=2,   transparency=0.4, material="Neon" },
				{ type="particles", name="Impact Sparks", parentPart="Torso", color="#ffaa44", rate=80, speed=8, pLifetime=0.4, size=0.3, spread=360 },
			},
			Smoke = {
				{ type="particles", name="Smoke Cloud 1", parentPart="Torso", color="#888888", rate=25, speed=1.5, pLifetime=2, size=1.2, spread=20 },
				{ type="trail",     name="Smoke Trail 1", parentPart="Torso", color0="#aaaaaa", color1="#333333", lifetime=1.2, width=1.8 },
			},
		}
		-- show a small pick menu
		local pickGui = Instance.new("Frame", mainFrame)
		pickGui.BackgroundColor3 = COL_BG2
		pickGui.BorderSizePixel = 0
		pickGui.Size = UDim2.new(0, 130, 0, #presets*26+8)
		pickGui.Position = UDim2.new(1, -210, 0, 30)
		pickGui.ZIndex = 30
		makeCorner(pickGui, 6)
		local pickStroke = Instance.new("UIStroke", pickGui)
		pickStroke.Color = COL_ACCENT
		pickStroke.Thickness = 1
		for pi, pname in ipairs(presets) do
			local pb = makeButton(pickGui, pname, COL_BG3, 1, 0, 4, (pi-1)*26+4, 0, 22)
			pb.Size = UDim2.new(1, -8, 0, 22)
			pb.ZIndex = 31
			pb.TextXAlignment = Enum.TextXAlignment.Left
			pb.MouseButton1Click:Connect(function()
				elements = {}
				nextId = 1
				selIdx = nil
				for _, elem in ipairs(presetMap[pname] or {}) do
					elem._id = nextId
					nextId = nextId + 1
					table.insert(elements, elem)
				end
				selIdx = #elements > 0 and 1 or nil
				pickGui:Destroy()
				Builder.rebuild()
			end)
		end
		-- close on outside click
		task.delay(0.05, function()
			local con
			con = UIS.InputBegan:Connect(function(inp)
				if inp.UserInputType == Enum.UserInputType.MouseButton1 then
					pickGui:Destroy()
					con:Disconnect()
				end
			end)
		end)
	end)

	-- Properties pane
	propFrame = Instance.new("ScrollingFrame", rightPanel)
	propFrame.BackgroundTransparency = 1
	propFrame.BorderSizePixel = 0
	propFrame.Size = UDim2.new(1, 0, 1, -32)
	propFrame.Position = UDim2.new(0, 0, 0, 32)
	propFrame.CanvasSize = UDim2.new(0,0,0,0)
	propFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	propFrame.ScrollBarThickness = 5
	propFrame.ScrollBarImageColor3 = COL_ACCENT
	propFrame.Visible = true

	-- Code pane
	codeFrame = Instance.new("Frame", rightPanel)
	codeFrame.BackgroundColor3 = COL_BG2
	codeFrame.BorderSizePixel = 0
	codeFrame.Size = UDim2.new(1, 0, 1, -32)
	codeFrame.Position = UDim2.new(0, 0, 0, 32)
	codeFrame.Visible = false
	makeCorner(codeFrame, 6)

	local codeScroll = Instance.new("ScrollingFrame", codeFrame)
	codeScroll.BackgroundTransparency = 1
	codeScroll.BorderSizePixel = 0
	codeScroll.Size = UDim2.new(1, 0, 1, 0)
	codeScroll.CanvasSize = UDim2.new(0,0,0,0)
	codeScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	codeScroll.ScrollBarThickness = 5
	codeScroll.ScrollBarImageColor3 = COL_ACCENT

	local codeLbl = Instance.new("TextLabel", codeScroll)
	codeLbl.Name = "CodeLabel"
	codeLbl.BackgroundTransparency = 1
	codeLbl.BorderSizePixel = 0
	codeLbl.TextColor3 = Color3.fromRGB(180, 230, 180)
	codeLbl.Font = Enum.Font.Code
	codeLbl.TextSize = 11
	codeLbl.TextXAlignment = Enum.TextXAlignment.Left
	codeLbl.TextYAlignment = Enum.TextYAlignment.Top
	codeLbl.TextWrapped = false
	codeLbl.Size = UDim2.new(1, -12, 0, 0)
	codeLbl.AutomaticSize = Enum.AutomaticSize.Y
	codeLbl.Position = UDim2.new(0, 8, 0, 8)
	codeLbl.Text = "-- Switch to 'Lua Output' tab to generate code"

	switchTab("props")
	Builder.rebuild()
end

-- ── Rebuild element list ──────────────────────────────────────
function Builder.rebuildList()
	if not listFrame then return end
	listFrame:ClearAllChildren()
	local layout = Instance.new("UIListLayout", listFrame)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 3)
	local pad = Instance.new("UIPadding", listFrame)
	pad.PaddingLeft = UDim.new(0,4); pad.PaddingRight = UDim.new(0,4); pad.PaddingTop = UDim.new(0,4)

	for i, elem in ipairs(elements) do
		local row = Instance.new("Frame", listFrame)
		row.BackgroundColor3 = (i == selIdx) and COL_SEL or COL_BG3
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, 0, 26)
		row.LayoutOrder = i
		makeCorner(row, 4)
		if i == selIdx then
			local rs = Instance.new("UIStroke", row)
			rs.Color = COL_ACCENT
			rs.Thickness = 1
		end

		-- colour swatch
		local sw = Instance.new("Frame", row)
		sw.BackgroundColor3 = hexToC3(elem.color or elem.color0 or "#888888")
		sw.BorderSizePixel = 0
		sw.Size = UDim2.new(0,10,0,10)
		sw.Position = UDim2.new(0,6,0.5,-5)
		makeCorner(sw, 2)

		local nm = Instance.new("TextLabel", row)
		nm.BackgroundTransparency = 1
		nm.BorderSizePixel = 0
		nm.Text = elem.name or elem.type
		nm.TextSize = 11
		nm.TextColor3 = COL_TEXT
		nm.Font = Enum.Font.Gotham
		nm.TextXAlignment = Enum.TextXAlignment.Left
		nm.Size = UDim2.new(1,-52,1,0)
		nm.Position = UDim2.new(0,20,0,0)

		local typeBadge = Instance.new("TextLabel", row)
		typeBadge.BackgroundTransparency = 1
		typeBadge.BorderSizePixel = 0
		typeBadge.Text = elem.type:sub(1,3):upper()
		typeBadge.TextSize = 9
		typeBadge.TextColor3 = COL_ACCENT
		typeBadge.Font = Enum.Font.GothamBold
		typeBadge.Size = UDim2.new(0,24,1,0)
		typeBadge.Position = UDim2.new(1,-48,0,0)

		local delBtn = makeButton(row, "✕", COL_RED, 0, 0, 0, 3, 20, 20)
		delBtn.Position = UDim2.new(1,-24,0,3)
		delBtn.TextSize = 10
		delBtn.MouseButton1Click:Connect(function()
			table.remove(elements, i)
			if selIdx == i then selIdx = #elements > 0 and math.min(i, #elements) or nil end
			Builder.rebuild()
		end)

		row.InputBegan:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseButton1 then
				selIdx = i
				Builder.rebuild()
			end
		end)
	end
end

-- ── Rebuild properties panel ──────────────────────────────────
function Builder.rebuildProps()
	if not propFrame then return end
	propFrame:ClearAllChildren()
	local layout = Instance.new("UIListLayout", propFrame)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	local pad = Instance.new("UIPadding", propFrame)
	pad.PaddingLeft = UDim.new(0,8); pad.PaddingRight = UDim.new(0,8); pad.PaddingTop = UDim.new(0,8)

	if not selIdx or not elements[selIdx] then
		local hint = Instance.new("TextLabel", propFrame)
		hint.BackgroundTransparency = 1
		hint.BorderSizePixel = 0
		hint.Text = "Select an element from the list."
		hint.TextSize = 12
		hint.TextColor3 = COL_TEXT2
		hint.Font = Enum.Font.Gotham
		hint.Size = UDim2.new(1,0,0,30)
		return
	end

	local elem = elements[selIdx]
	local order = 0

	local function nextOrder() order = order + 1; return order end

	-- Helper to make a section header
	local function section(label)
		local f = Instance.new("Frame", propFrame)
		f.BackgroundColor3 = COL_BG3
		f.BorderSizePixel = 0
		f.Size = UDim2.new(1,0,0,18)
		f.LayoutOrder = nextOrder()
		makeCorner(f,4)
		local l = makeLabel(f, "  "..label, 10, COL_ACCENT, 1, 1, 0, 0, true)
		l.TextYAlignment = Enum.TextYAlignment.Center
	end

	-- String field
	local function strField(label, key)
		local f = Instance.new("Frame", propFrame)
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Size = UDim2.new(1,0,0,22)
		f.LayoutOrder = nextOrder()
		makeLabel(f, label, 11, COL_TEXT2, 0, 1, 0, 0)
		local tb = makeTextBox(f, tostring(elem[key] or ""), 0, 0, 95, 1, 0, 20)
		tb.Size = UDim2.new(1,-98,0,20)
		tb.Position = UDim2.new(0,95,0,1)
		tb.FocusLost:Connect(function()
			elem[key] = tb.Text
			Builder.rebuildList()
		end)
	end

	-- Number slider
	local function numSlider(label, key, minV, maxV, step, unit)
		local f = Instance.new("Frame", propFrame)
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Size = UDim2.new(1,0,0,22)
		f.LayoutOrder = nextOrder()

		local lbl2 = makeLabel(f, label, 11, COL_TEXT2, 0, 1, 0, 0)
		lbl2.Size = UDim2.new(0,90,1,0)

		local track = Instance.new("Frame",f)
		track.BackgroundColor3 = COL_BG3
		track.BorderSizePixel = 0
		track.Size = UDim2.new(1,-148,0,6)
		track.Position = UDim2.new(0,93,0.5,-3)
		makeCorner(track,3)

		local fill = Instance.new("Frame",track)
		fill.BackgroundColor3 = COL_ACCENT
		fill.BorderSizePixel = 0
		local defV = tonumber(elem[key]) or minV
		fill.Size = UDim2.new(math.clamp((defV-minV)/(maxV-minV),0,1),0,1,0)
		makeCorner(fill,3)

		local valL = makeLabel(f,"", 11, COL_TEXT, 0, 1, 0, 0)
		valL.Size = UDim2.new(0,50,1,0)
		valL.Position = UDim2.new(1,-50,0,0)
		valL.TextXAlignment = Enum.TextXAlignment.Right
		local fmt = (step < 1) and "%.2f" or "%.0f"
		valL.Text = fmt:format(defV)..(unit or "")

		local dragging2 = false
		local function updateVal(v)
			local steps = math.round((v-minV)/step)
			v = math.clamp(minV + steps*step, minV, maxV)
			elem[key] = v
			fill.Size = UDim2.new((v-minV)/(maxV-minV),0,1,0)
			valL.Text = fmt:format(v)..(unit or "")
		end
		track.InputBegan:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseButton1 then
				dragging2 = true
				local pct = math.clamp((inp.Position.X - track.AbsolutePosition.X)/track.AbsoluteSize.X,0,1)
				updateVal(minV+pct*(maxV-minV))
			end
		end)
		UIS.InputChanged:Connect(function(inp)
			if dragging2 and inp.UserInputType == Enum.UserInputType.MouseMovement then
				local pct = math.clamp((inp.Position.X - track.AbsolutePosition.X)/track.AbsoluteSize.X,0,1)
				updateVal(minV+pct*(maxV-minV))
			end
		end)
		UIS.InputEnded:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging2 = false end
		end)
	end

	-- Colour picker (hex input)
	local function colorField(label, key)
		local f = Instance.new("Frame", propFrame)
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Size = UDim2.new(1,0,0,22)
		f.LayoutOrder = nextOrder()
		makeLabel(f, label, 11, COL_TEXT2, 0, 1, 0, 0)

		local swatch = Instance.new("Frame",f)
		swatch.BackgroundColor3 = hexToC3(elem[key] or "#ffffff")
		swatch.BorderSizePixel = 0
		swatch.Size = UDim2.new(0,16,0,16)
		swatch.Position = UDim2.new(0,93,0.5,-8)
		makeCorner(swatch,3)

		local tb = makeTextBox(f, elem[key] or "#ffffff", 0, 0, 0, 1, 0, 20)
		tb.Size = UDim2.new(1,-115,0,20)
		tb.Position = UDim2.new(0,113,0,1)
		tb.FocusLost:Connect(function()
			local hex = tb.Text
			if hex:match("^#%x%x%x%x%x%x$") then
				elem[key] = hex
				swatch.BackgroundColor3 = hexToC3(hex)
				Builder.rebuildList()
			end
		end)
	end

	-- Dropdown (simple)
	local function dropField(label, key, opts)
		local f = Instance.new("Frame", propFrame)
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Size = UDim2.new(1,0,0,22)
		f.LayoutOrder = nextOrder()
		makeLabel(f, label, 11, COL_TEXT2, 0, 1, 0, 0)
		local cur = elem[key] or opts[1]
		local db = makeButton(f, cur, COL_BG3, 0, 0, 93, 1, 0, 20)
		db.Size = UDim2.new(1,-98,0,20)
		db.Position = UDim2.new(0,95,0,1)
		db.TextXAlignment = Enum.TextXAlignment.Left
		db.TextSize = 11
		local open2 = false
		local dpf = nil
		db.MouseButton1Click:Connect(function()
			open2 = not open2
			if dpf then dpf:Destroy(); dpf = nil end
			if not open2 then return end
			dpf = Instance.new("Frame", f)
			dpf.BackgroundColor3 = COL_BG2
			dpf.BorderSizePixel = 0
			dpf.Size = UDim2.new(1,-98,0,#opts*22)
			dpf.Position = UDim2.new(0,95,0,22)
			dpf.ZIndex = 50
			makeCorner(dpf,4)
			local dstroke = Instance.new("UIStroke",dpf); dstroke.Color=COL_ACCENT; dstroke.Thickness=1
			for oi, opt in ipairs(opts) do
				local ob2 = Instance.new("TextButton",dpf)
				ob2.BackgroundTransparency = 1
				ob2.BorderSizePixel = 0
				ob2.Text = opt
				ob2.TextSize = 11
				ob2.TextColor3 = COL_TEXT
				ob2.Font = Enum.Font.Gotham
				ob2.TextXAlignment = Enum.TextXAlignment.Left
				ob2.Size = UDim2.new(1,-8,0,22)
				ob2.Position = UDim2.new(0,4,0,(oi-1)*22)
				ob2.ZIndex = 51
				ob2.MouseButton1Click:Connect(function()
					elem[key] = opt
					db.Text = opt
					open2 = false
					if dpf then dpf:Destroy(); dpf = nil end
					Builder.rebuild()
				end)
			end
		end)
	end

	-- Sin sub-table editor (amp + speed)
	local function sinField(label, key)
		local f = Instance.new("Frame", propFrame)
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Size = UDim2.new(1,0,0,46)
		f.LayoutOrder = nextOrder()

		makeLabel(f, label, 10, COL_ACCENT, 1, 0, 0, 0, true)

		if not elem[key] then elem[key] = {amp=0, spd=1} end
		local sub = elem[key]

		-- amp slider
		local ampRow = Instance.new("Frame",f)
		ampRow.BackgroundTransparency=1; ampRow.BorderSizePixel=0
		ampRow.Size=UDim2.new(1,0,0,20); ampRow.Position=UDim2.new(0,0,0,14)
		makeLabel(ampRow,"  Amplitude",11,COL_TEXT2,0,1,0,0).Size=UDim2.new(0,80,1,0)
		local atrack=Instance.new("Frame",ampRow); atrack.BackgroundColor3=COL_BG3; atrack.BorderSizePixel=0; atrack.Size=UDim2.new(1,-130,0,5); atrack.Position=UDim2.new(0,83,0.5,-2); makeCorner(atrack,2)
		local afill=Instance.new("Frame",atrack); afill.BackgroundColor3=COL_ACCENT; afill.BorderSizePixel=0; afill.Size=UDim2.new(math.clamp((sub.amp or 0)/5,0,1),0,1,0); makeCorner(afill,2)
		local aval=makeLabel(ampRow,"",11,COL_TEXT,0,1,0,0); aval.Size=UDim2.new(0,40,1,0); aval.Position=UDim2.new(1,-40,0,0); aval.TextXAlignment=Enum.TextXAlignment.Right; aval.Text=("%.2f"):format(sub.amp or 0)
		local adrag=false
		atrack.InputBegan:Connect(function(i2) if i2.UserInputType==Enum.UserInputType.MouseButton1 then adrag=true end end)
		UIS.InputChanged:Connect(function(i2) if adrag and i2.UserInputType==Enum.UserInputType.MouseMovement then local p2=math.clamp((i2.Position.X-atrack.AbsolutePosition.X)/atrack.AbsoluteSize.X,0,1); sub.amp=p2*5; afill.Size=UDim2.new(p2,0,1,0); aval.Text=("%.2f"):format(sub.amp) end end)
		UIS.InputEnded:Connect(function(i2) if i2.UserInputType==Enum.UserInputType.MouseButton1 then adrag=false end end)

		-- speed slider
		local spdRow = Instance.new("Frame",f)
		spdRow.BackgroundTransparency=1; spdRow.BorderSizePixel=0
		spdRow.Size=UDim2.new(1,0,0,20); spdRow.Position=UDim2.new(0,0,0,24)
		makeLabel(spdRow,"  Speed",11,COL_TEXT2,0,1,0,0).Size=UDim2.new(0,80,1,0)
		local strack=Instance.new("Frame",spdRow); strack.BackgroundColor3=COL_BG3; strack.BorderSizePixel=0; strack.Size=UDim2.new(1,-130,0,5); strack.Position=UDim2.new(0,83,0.5,-2); makeCorner(strack,2)
		local sfill=Instance.new("Frame",strack); sfill.BackgroundColor3=COL_GREEN; sfill.BorderSizePixel=0; sfill.Size=UDim2.new(math.clamp((sub.spd or 1)/20,0,1),0,1,0); makeCorner(sfill,2)
		local sval=makeLabel(spdRow,"",11,COL_TEXT,0,1,0,0); sval.Size=UDim2.new(0,40,1,0); sval.Position=UDim2.new(1,-40,0,0); sval.TextXAlignment=Enum.TextXAlignment.Right; sval.Text=("%.2f"):format(sub.spd or 1)
		local spdrag=false
		strack.InputBegan:Connect(function(i2) if i2.UserInputType==Enum.UserInputType.MouseButton1 then spdrag=true end end)
		UIS.InputChanged:Connect(function(i2) if spdrag and i2.UserInputType==Enum.UserInputType.MouseMovement then local p2=math.clamp((i2.Position.X-strack.AbsolutePosition.X)/strack.AbsoluteSize.X,0,1); sub.spd=p2*20; sfill.Size=UDim2.new(p2,0,1,0); sval.Text=("%.2f"):format(sub.spd) end end)
		UIS.InputEnded:Connect(function(i2) if i2.UserInputType==Enum.UserInputType.MouseButton1 then spdrag=false end end)
	end

	-- ── Build properties per type ─────────────────────────────
	section("General")
	strField("Name", "name")
	dropField("Parent part", "parentPart", BODY_PARTS)

	if elem.type == "part" then
		section("Appearance")
		dropField("Shape",    "shape",    SHAPES)
		colorField("Color",   "color")
		dropField("Material", "material", MATERIALS)
		numSlider("Size",         "size",        0.1, 8,    0.1, "")
		numSlider("Transparency", "transparency",0,   0.95, 0.05,"")
		numSlider("Offset X",     "offsetX",    -8,   8,    0.25,"")
		numSlider("Offset Y",     "offsetY",    -4,   10,   0.25,"")
		numSlider("Offset Z",     "offsetZ",    -8,   8,    0.25,"")
		numSlider("Rot (deg)",    "rot",        -180, 180,  5,   "°")

		section("Infinite Rotation (rad/s)")
		numSlider("Rot X", "infRotX", -10, 10, 0.1, "")
		numSlider("Rot Y", "infRotY", -10, 10, 0.1, "")
		numSlider("Rot Z", "infRotZ", -10, 10, 0.1, "")

		section("Sin Position")
		sinField("Sin Pos X", "sinPosX")
		sinField("Sin Pos Y", "sinPosY")
		sinField("Sin Pos Z", "sinPosZ")

		section("Sin Angle")
		sinField("Sin Ang X", "sinAngX")
		sinField("Sin Ang Y", "sinAngY")
		sinField("Sin Ang Z", "sinAngZ")

		section("Sin Size")
		sinField("Sin Size",  "sinSize")

	elseif elem.type == "beam" then
		section("Appearance")
		colorField("Color start", "color0")
		colorField("Color end",   "color1")
		numSlider("Width start",  "width0", 0, 4,  0.1,"")
		numSlider("Width end",    "width1", 0, 4,  0.1,"")
		numSlider("Length",       "length", 1, 20, 0.5,"")

		section("Infinite Rotation (rad/s)")
		numSlider("Rot X", "infRotX", -10, 10, 0.1,"")
		numSlider("Rot Y", "infRotY", -10, 10, 0.1,"")
		numSlider("Rot Z", "infRotZ", -10, 10, 0.1,"")

	elseif elem.type == "trail" then
		section("Appearance")
		colorField("Color start", "color0")
		colorField("Color end",   "color1")
		numSlider("Lifetime",     "lifetime", 0.05, 4, 0.05,"s")
		numSlider("Width",        "width",    0.05, 4, 0.05,"")

	elseif elem.type == "particles" then
		section("Appearance")
		colorField("Color",      "color")
		numSlider("Rate",        "rate",     1,   200, 1,    "/s")
		numSlider("Speed",       "speed",    0.5, 30,  0.5,  "")
		numSlider("Lifetime",    "pLifetime",0.05,5,   0.05, "s")
		numSlider("Size",        "size",     0.05,4,   0.05, "")
		numSlider("Spread",      "spread",   0,   360, 5,    "°")

		section("Sin Position (host part)")
		sinField("Sin Pos X", "sinPosX")
		sinField("Sin Pos Y", "sinPosY")
		sinField("Sin Pos Z", "sinPosZ")

	elseif elem.type == "billboard" then
		section("Appearance")
		strField("Text",       "text")
		colorField("Text color","textColor")
		colorField("BG color",  "bgColor")
		numSlider("Size",       "size",    0.3, 5, 0.1,"")
		numSlider("Offset Y",   "offsetY", 0,   8, 0.25,"")

		section("Sin Position")
		sinField("Sin Pos Y", "sinPosY")
	end
end

-- ── Rebuild code output ───────────────────────────────────────
function Builder.rebuildCode()
	local code = generateCode({
		exportName = exportName,
		lifetime   = cfgLife,
		throttle   = cfgThr,
		spawnOn    = spawnOn,
		destroyOn  = destroyOn,
		elements   = elements,
	})
	if not codeFrame then return end
	local cl = codeFrame:FindFirstChild("CodeLabel", true)
	if cl then cl.Text = code end
end

-- ── Full rebuild ──────────────────────────────────────────────
function Builder.rebuild()
	Builder.rebuildList()
	Builder.rebuildProps()
	if activeTab == "code" then Builder.rebuildCode() end
end

-- ── Open / toggle ─────────────────────────────────────────────
function Builder.open()
	if guiOpen and screenGui then
		screenGui:Destroy()
		screenGui = nil
		guiOpen = false
		return
	end
	guiOpen = true
	buildMainGUI()
end

-- ════════════════════════════════════════════════════════════
--   KEYBIND: hold RightAlt + B to open builder
-- ════════════════════════════════════════════════════════════
UIS.InputBegan:Connect(function(inp, gpe)
	if gpe then return end
	-- RightAlt + B
	if inp.KeyCode == Enum.KeyCode.B and UIS:IsKeyDown(Enum.KeyCode.RightAlt) then
		Builder.open()
	end
end)

-- ════════════════════════════════════════════════════════════
--   EXAMPLE WIRING  (copy this into your C_c reanimate block)
-- ════════════════════════════════════════════════════════════
--[[

  -- After local t = reanimate() and all the joint locals:

  -- Open the builder with RightAlt+B, configure your VFX,
  -- then click "Lua Output" tab and Copy. Paste the generated
  -- code in place of this example.

  -- ── EXAMPLE: Aura on mode F ──────────────────────────────
  local AuraVFX = VFX.new({
      exportName = "AuraVFX",
      lifetime   = 0,
      throttle   = 0.3,
      destroyOn  = { attackEnd=false, modeLeave=true, timer=false },
      spawnOn    = { onStart=false, loop=false },
      elements   = {
          {
              type        = "part",
              name        = "AuraRing",
              parentPart  = "Torso",
              shape       = "cylinder",
              color       = "#b4b0ff",
              material    = "Neon",
              size        = 2.5,
              transparency= 0.55,
              offsetX=0, offsetY=0, offsetZ=0,
              rot         = 0,
              infRotY     = 2,
              sinPosY     = { amp=0.2, spd=1.5 },
              sinSize     = { amp=0.3, spd=2   },
          },
          {
              type       = "particles",
              name       = "AuraSparks",
              parentPart = "Torso",
              color      = "#c8c0ff",
              rate       = 40,
              speed      = 2,
              pLifetime  = 0.8,
              size       = 0.2,
              spread     = 360,
          },
      },
  })

  -- In mode "f" modeEntered:
  addmode("f", {
      modeEntered = function()
          AuraVFX:spawnOnce(cframes, getPart, cfMul, cf, angles, v3)
      end,
      modeLeft = function()
          AuraVFX:destroyAll()
      end,
      idle = function()
          AuraVFX:update(sine, deltaTime, cframes, getPart)
          -- ... your joint lerps ...
      end,
      walk = function()
          AuraVFX:update(sine, deltaTime, cframes, getPart)
          -- ... your joint lerps ...
      end,
  })

  -- ── EXAMPLE: Attack Z burst on mode F ────────────────────
  local ZVfx = VFX.new({
      exportName = "ZBurst",
      destroyOn  = { attackEnd=true },
      spawnOn    = { onStart=true },
      elements   = {
          {
              type        = "part",
              name        = "ZOrb",
              parentPart  = "Right Arm",
              shape       = "sphere",
              color       = "#ffffff",
              material    = "Neon",
              size        = 0.8,
              transparency= 0.2,
              offsetX=0, offsetY=0.5, offsetZ=-1.5,
              infRotX     = 3,
              infRotY     = 1.5,
              sinSize     = { amp=0.4, spd=15 },
          },
      },
  })

  attacks["f"]["z"] = {
      duration = 2,
      fn = function()
          if getAttackProgress() < 0.02 then
              ZVfx:spawnOnce(cframes, getPart, cfMul, cf, angles, v3)
          end
          ZVfx:update(sine, deltaTime, cframes, getPart)
          -- ... your joint lerps ...
      end
  }
  -- In the attackActive end block (attackProgress >= 1):
  -- ZVfx:destroyAll()
  -- Add that check inside your mainFunction attack block.

  -- Open the builder at any time with RightAlt + B
--]]

-- Return the Builder API so you can call it from outside
return Builder
