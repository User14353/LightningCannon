--[[
	╔══════════════════════════════════════════════════════════════════════╗
	║           VFX Animator  •  Executor Edition  v1.1  (bugfixed)       ║
	║  Spawn / animate / parent VFX parts to any body part                ║
	║  Position sin • Rotation sin • Infinite spin • Scale pulse          ║
	╚══════════════════════════════════════════════════════════════════════╝

	BUGS FIXED:
	  1. ParticleEmitter has no LightInfluence property — removed
	  2. makeColorRow: unused track frames removed; RGB inputs now work correctly
	  3. makeVec3Row: table reference mutation fixed so el.xxx updates properly
	  4. generateCode() called twice on Export — cached to local
	  5. Sin size animation added to spawner AND code export
	  6. spawnElement: scale pulse reads animSizeAmp/Speed correctly
	  7. Code export: animRot target expression built before use (was referencing
	     variables before they were assigned in some branches)
	  8. Beam/Trail/PE/BB host parts had CanQuery/CanTouch missing
	  9. Body collapse toggle checked wrong button region (whole header clickable
	     including action buttons) — header click guard added
	 10. Duplicate: table copy now does deep copy for nested tables correctly
--]]

-- ═══════════════════════════════════════════════════════════════════════
--  SERVICES
-- ═══════════════════════════════════════════════════════════════════════
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local CoreGui          = game:GetService("CoreGui")
local Camera           = workspace.CurrentCamera

local lp   = Players.LocalPlayer
local char = lp.Character or lp.CharacterAdded:Wait()

-- ═══════════════════════════════════════════════════════════════════════
--  MATH / HELPERS
-- ═══════════════════════════════════════════════════════════════════════
local sin, cos, rad, pi = math.sin, math.cos, math.rad, math.pi
local fmt  = string.format
local cfn  = CFrame.new
local cfaa = CFrame.Angles
local v3n  = Vector3.new
local c3r  = Color3.fromRGB

local ALPHA = 0.15

-- ═══════════════════════════════════════════════════════════════════════
--  BODY PARTS
-- ═══════════════════════════════════════════════════════════════════════
local BODY_PARTS = {
	"HumanoidRootPart","Torso","Head",
	"Left Arm","Right Arm","Left Leg","Right Leg",
	"UpperTorso","LowerTorso",
	"LeftUpperArm","RightUpperArm","LeftLowerArm","RightLowerArm",
	"LeftHand","RightHand",
	"LeftUpperLeg","RightUpperLeg","LeftLowerLeg","RightLowerLeg",
	"LeftFoot","RightFoot",
}

local function getBodyPart(name)
	local c = lp.Character
	if not c then return nil end
	return c:FindFirstChild(name) or c:FindFirstChild(name, true)
end

-- ═══════════════════════════════════════════════════════════════════════
--  VFX ELEMENT DATA
-- ═══════════════════════════════════════════════════════════════════════
local vfxList   = {}
local vfxNextId = 1
local vfxConns  = {}

-- FIX: deep copy helper for nested tables
local function deepCopy(t)
	if type(t) ~= "table" then return t end
	local c = {}
	for k, v in pairs(t) do c[k] = deepCopy(v) end
	return c
end

local function newElement(typ)
	local id = vfxNextId; vfxNextId = vfxNextId + 1
	return {
		id=id, type=typ, name=typ.." "..id,
		parentPart="HumanoidRootPart", enabled=true,

		-- appearance (Part / SpecialMesh)
		color={180,170,255}, material="Neon", transparency=0.2, castShadow=false,
		shape="Ball", size={1,1,1},
		meshType="Sphere", meshId="", textureId="", meshScale={1,1,1},

		-- base transform
		offsetPos={0,2,0}, offsetRot={0,0,0},

		-- lerp position sine bob
		animPos=false,   animPosAmp={0,0.5,0}, animPosSpeed=2,
		-- lerp rotation sine oscillate
		animRot=false,   animRotAmp={0,20,0},  animRotSpeed=1.5,
		-- infinite spin
		infRot=false,    infRotAxis={0,1,0},   infRotSpeed=90,
		-- scale pulse (sin size)
		animScale=false, animScaleAmp=0.3,     animScaleSpeed=1.5,

		-- Beam
		color0={255,255,255}, color1={127,119,221},
		width0=0.5, width1=0, beamLength=6, segments=12,
		faceCamera=true, lightInfluence=0,

		-- Trail
		trailLifetime=0.5, trailWidth=0.5, trailMinDist=0.05,

		-- ParticleEmitter  (FIX: no lightInfluence field here — PE doesn't have it)
		peColor={180,170,255}, peRate=30,
		peSpeedMin=2, peSpeedMax=5,
		peLifetimeMin=0.4, peLifetimeMax=0.8,
		peSize=0.35, peSpread=180,

		-- BillboardGui
		bbText="VFX!", bbTextColor={255,255,255}, bbBgColor={20,20,50},
		bbBgTrans=0.1, bbSizeX=80, bbSizeY=40, bbOffsetY=3, bbAlwaysOnTop=true,

		-- runtime
		_instances={}, _infAngle=0, _sine=0,
	}
end

-- ═══════════════════════════════════════════════════════════════════════
--  SPAWN / DESTROY
-- ═══════════════════════════════════════════════════════════════════════
local function c3(t)
	return c3r(math.round(t[1]), math.round(t[2]), math.round(t[3]))
end

-- FIX: helper to make invisible host parts consistently
local function makeHost(name)
	local p = Instance.new("Part")
	p.Name        = name
	p.Anchored    = true
	p.CanCollide  = false
	p.CanQuery    = false
	p.CanTouch    = false
	p.CastShadow  = false
	p.Transparency = 1
	p.Size        = v3n(0.1, 0.1, 0.1)
	p.Parent      = workspace
	return p
end

local function destroyElement(el)
	if vfxConns[el.id] then
		vfxConns[el.id]:Disconnect()
		vfxConns[el.id] = nil
	end
	for _, inst in ipairs(el._instances) do
		if inst and inst.Parent then
			-- disable particle emitters so particles fade naturally
			for _, ch in ipairs(inst:GetDescendants()) do
				if ch:IsA("ParticleEmitter") then ch.Enabled = false end
			end
			task.delay(0.6, function()
				if inst and inst.Parent then inst:Destroy() end
			end)
		end
	end
	el._instances = {}
end

local function spawnElement(el)
	destroyElement(el)
	el._infAngle = 0
	el._sine     = 0

	local pp = getBodyPart(el.parentPart)
	if not pp then
		warn("[VFX] body part not found: " .. el.parentPart)
		return
	end

	local rootPart
	local meshInst

	-- ── Part ──────────────────────────────────────────────────────────
	if el.type == "Part" then
		local p = Instance.new("Part")
		p.Name         = el.name:gsub("%s", "_")
		p.Anchored     = true
		p.CanCollide   = false
		p.CanQuery     = false
		p.CanTouch     = false
		p.CastShadow   = el.castShadow
		p.Color        = c3(el.color)
		p.Material     = Enum.Material[el.material] or Enum.Material.Neon
		p.Transparency = el.transparency
		p.Shape        = Enum.PartType[el.shape] or Enum.PartType.Ball
		p.Size         = v3n(table.unpack(el.size))
		p.Parent       = workspace
		table.insert(el._instances, p)
		rootPart = p

	-- ── SpecialMesh ───────────────────────────────────────────────────
	elseif el.type == "SpecialMesh" then
		local p = Instance.new("Part")
		p.Name         = el.name:gsub("%s", "_")
		p.Anchored     = true
		p.CanCollide   = false
		p.CanQuery     = false
		p.CanTouch     = false
		p.CastShadow   = false
		p.Color        = c3(el.color)
		p.Material     = Enum.Material[el.material] or Enum.Material.Neon
		p.Transparency = el.transparency
		p.Size         = v3n(2, 2, 2)
		local m = Instance.new("SpecialMesh", p)
		m.MeshType     = Enum.MeshType[el.meshType] or Enum.MeshType.Sphere
		m.Scale        = v3n(table.unpack(el.meshScale))
		if el.meshId    ~= "" then m.MeshId    = el.meshId    end
		if el.textureId ~= "" then m.TextureId = el.textureId end
		meshInst = m
		p.Parent = workspace
		table.insert(el._instances, p)
		rootPart = p

	-- ── Beam ──────────────────────────────────────────────────────────
	elseif el.type == "Beam" then
		local hp = makeHost("VFX_BeamHost_" .. el.id)
		local a0 = Instance.new("Attachment", hp)
		local a1 = Instance.new("Attachment", hp)
		a1.Position = v3n(0, 0, -el.beamLength)
		local bm = Instance.new("Beam", hp)
		bm.Attachment0 = a0; bm.Attachment1 = a1
		bm.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, c3(el.color0)),
			ColorSequenceKeypoint.new(1, c3(el.color1)),
		})
		bm.Width0         = el.width0
		bm.Width1         = el.width1
		bm.Segments       = el.segments
		bm.FaceCamera     = el.faceCamera
		bm.LightInfluence = el.lightInfluence
		table.insert(el._instances, hp)
		rootPart = hp

	-- ── Trail ─────────────────────────────────────────────────────────
	elseif el.type == "Trail" then
		local tp = makeHost("VFX_TrailHost_" .. el.id)
		local ta0 = Instance.new("Attachment", tp)
		local ta1 = Instance.new("Attachment", tp)
		ta1.Position = v3n(0, el.trailWidth, 0)
		local tr = Instance.new("Trail", tp)
		tr.Attachment0 = ta0; tr.Attachment1 = ta1
		tr.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, c3(el.color0)),
			ColorSequenceKeypoint.new(1, c3(el.color1)),
		})
		tr.Lifetime    = el.trailLifetime
		tr.MinDistance = el.trailMinDist
		table.insert(el._instances, tp)
		rootPart = tp

	-- ── ParticleEmitter ───────────────────────────────────────────────
	elseif el.type == "ParticleEmitter" then
		local ep = makeHost("VFX_EmitHost_" .. el.id)
		local pe = Instance.new("ParticleEmitter", ep)
		pe.Color       = ColorSequence.new(c3(el.peColor))
		pe.Rate        = el.peRate
		pe.Speed       = NumberRange.new(el.peSpeedMin, el.peSpeedMax)
		pe.Lifetime    = NumberRange.new(el.peLifetimeMin, el.peLifetimeMax)
		pe.Size        = NumberSequence.new(el.peSize)
		pe.SpreadAngle = Vector2.new(-el.peSpread, el.peSpread)
		-- FIX: ParticleEmitter has no LightInfluence — removed
		table.insert(el._instances, ep)
		rootPart = ep

	-- ── BillboardGui ──────────────────────────────────────────────────
	elseif el.type == "BillboardGui" then
		local bp = makeHost("VFX_BBHost_" .. el.id)
		local bb = Instance.new("BillboardGui", bp)
		bb.Size        = UDim2.new(0, el.bbSizeX, 0, el.bbSizeY)
		bb.AlwaysOnTop = el.bbAlwaysOnTop
		bb.Adornee     = bp
		local lbl2 = Instance.new("TextLabel", bb)
		lbl2.Size                = UDim2.new(1, 0, 1, 0)
		lbl2.BackgroundColor3    = c3(el.bbBgColor)
		lbl2.BackgroundTransparency = el.bbBgTrans
		lbl2.TextColor3          = c3(el.bbTextColor)
		lbl2.Text                = el.bbText
		lbl2.TextScaled          = true
		lbl2.BorderSizePixel     = 0
		Instance.new("UICorner", lbl2).CornerRadius = UDim.new(0.3, 0)
		table.insert(el._instances, bp)
		rootPart = bp
	end

	if not rootPart then return end

	-- ── Per-frame animation ───────────────────────────────────────────
	vfxConns[el.id] = RunService.Heartbeat:Connect(function(dt)
		if not el.enabled then return end
		local pp2 = getBodyPart(el.parentPart)
		if not pp2 or not rootPart.Parent then return end

		el._sine = el._sine + dt

		-- position with optional sine bob
		local ox = el.offsetPos[1]
		local oy = el.offsetPos[2]
		local oz = el.offsetPos[3]
		if el.animPos then
			local t = el._sine * el.animPosSpeed * (2 * pi)
			ox = ox + el.animPosAmp[1] * sin(t)
			oy = oy + el.animPosAmp[2] * sin(t)
			oz = oz + el.animPosAmp[3] * sin(t)
		end

		-- rotation with optional sine oscillation
		local rx = rad(el.offsetRot[1])
		local ry = rad(el.offsetRot[2])
		local rz = rad(el.offsetRot[3])
		if el.animRot then
			local t = el._sine * el.animRotSpeed * (2 * pi)
			rx = rx + rad(el.animRotAmp[1]) * sin(t)
			ry = ry + rad(el.animRotAmp[2]) * sin(t)
			rz = rz + rad(el.animRotAmp[3]) * sin(t)
		end

		-- lerp speed factor
		local lf = math.min(1, ALPHA * 60 * dt + 0.3)

		-- build target CFrame
		local baseCF = pp2.CFrame * cfn(ox, oy, oz) * cfaa(rx, ry, rz)

		if el.infRot then
			el._infAngle = el._infAngle + rad(el.infRotSpeed) * dt
			local ax = v3n(el.infRotAxis[1], el.infRotAxis[2], el.infRotAxis[3])
			local safeAxis = ax.Magnitude > 0 and ax.Unit or v3n(0, 1, 0)
			local spinCF = CFrame.fromAxisAngle(safeAxis, el._infAngle)
			rootPart.CFrame = rootPart.CFrame:Lerp(baseCF * spinCF, lf)
		else
			rootPart.CFrame = rootPart.CFrame:Lerp(baseCF, lf)
		end

		-- billboard Y offset override (applied on top of base)
		if el.type == "BillboardGui" then
			local bbCF = pp2.CFrame * cfn(ox, oy + el.bbOffsetY, oz)
			rootPart.CFrame = rootPart.CFrame:Lerp(bbCF, lf)
		end

		-- FIX: scale pulse (sin size) — works for Part and SpecialMesh
		if el.animScale then
			local sc = 1 + el.animScaleAmp * sin(el._sine * el.animScaleSpeed * 2 * pi)
			sc = math.max(0.01, sc) -- never go zero/negative
			if el.type == "Part" then
				rootPart.Size = v3n(
					el.size[1] * sc,
					el.size[2] * sc,
					el.size[3] * sc
				)
			elseif el.type == "SpecialMesh" and meshInst then
				meshInst.Scale = v3n(
					el.meshScale[1] * sc,
					el.meshScale[2] * sc,
					el.meshScale[3] * sc
				)
			end
		end
	end)
end

-- ═══════════════════════════════════════════════════════════════════════
--  CODE EXPORT
-- ═══════════════════════════════════════════════════════════════════════
local function fmtN(n)  return fmt("%.4g", n) end
local function fmtV3(t) return fmt("Vector3.new(%s,%s,%s)", fmtN(t[1]), fmtN(t[2]), fmtN(t[3])) end
local function fmtC3(t) return fmt("Color3.fromRGB(%d,%d,%d)", math.round(t[1]), math.round(t[2]), math.round(t[3])) end

local function generateCode()
	local L = {}
	local function push(s) L[#L+1] = s end

	push("-- VFX Animator export  (v1.1 bugfixed)")
	push("local RunService = game:GetService('RunService')")
	push("local lp = game:GetService('Players').LocalPlayer")
	push("local function getP(n) local c=lp.Character; return c and (c:FindFirstChild(n) or c:FindFirstChild(n,true)) end")
	push("local _vfxI={} local _vfxC={}  -- instances / connections")
	push("local function cleanupVFX()")
	push("  for _,c in ipairs(_vfxC) do c:Disconnect() end _vfxC={}")
	push("  for _,i in ipairs(_vfxI) do if i and i.Parent then i:Destroy() end end _vfxI={}")
	push("end")
	push("")

	for _, el in ipairs(vfxList) do
		if not el.enabled then
			push("-- (disabled) " .. el.name)
			push("")
		else
			push("do -- " .. el.name .. " (" .. el.type .. ")")
			local vn = "vfx_" .. el.id

			-- ── spawn instance ──────────────────────────────────────
			if el.type == "Part" then
				push(fmt("  local %s=Instance.new('Part')", vn))
				push(fmt("  %s.Name='%s'", vn, el.name:gsub("%s","_")))
				push(fmt("  %s.Anchored=true %s.CanCollide=false %s.CanQuery=false %s.CanTouch=false %s.CastShadow=%s", vn,vn,vn,vn,vn,tostring(el.castShadow)))
				push(fmt("  %s.Color=%s %s.Material=Enum.Material.%s %s.Transparency=%s", vn,fmtC3(el.color),vn,el.material,vn,fmtN(el.transparency)))
				push(fmt("  %s.Shape=Enum.PartType.%s %s.Size=%s", vn,el.shape,vn,fmtV3(el.size)))
				push(fmt("  %s.Parent=workspace table.insert(_vfxI,%s)", vn,vn))

			elseif el.type == "SpecialMesh" then
				push(fmt("  local %s=Instance.new('Part')", vn))
				push(fmt("  %s.Name='%s'", vn, el.name:gsub("%s","_")))
				push(fmt("  %s.Anchored=true %s.CanCollide=false %s.CanQuery=false %s.CanTouch=false", vn,vn,vn,vn))
				push(fmt("  %s.Color=%s %s.Material=Enum.Material.%s %s.Transparency=%s", vn,fmtC3(el.color),vn,el.material,vn,fmtN(el.transparency)))
				push(fmt("  %s.Size=Vector3.new(2,2,2) %s.Parent=workspace", vn,vn))
				push(fmt("  local sm%d=Instance.new('SpecialMesh',%s)", el.id,vn))
				push(fmt("  sm%d.MeshType=Enum.MeshType.%s sm%d.Scale=%s", el.id,el.meshType,el.id,fmtV3(el.meshScale)))
				if el.meshId    ~= "" then push(fmt("  sm%d.MeshId='%s'",    el.id, el.meshId))    end
				if el.textureId ~= "" then push(fmt("  sm%d.TextureId='%s'", el.id, el.textureId)) end
				push(fmt("  table.insert(_vfxI,%s)", vn))

			elseif el.type == "Beam" then
				push(fmt("  local %s=Instance.new('Part') %s.Anchored=true %s.CanCollide=false %s.CanQuery=false %s.CanTouch=false %s.Transparency=1 %s.Size=Vector3.new(0.1,0.1,0.1) %s.Parent=workspace", vn,vn,vn,vn,vn,vn,vn,vn))
				push(fmt("  local a0_%d=Instance.new('Attachment',%s)", el.id,vn))
				push(fmt("  local a1_%d=Instance.new('Attachment',%s) a1_%d.Position=Vector3.new(0,0,-%s)", el.id,vn,el.id,fmtN(el.beamLength)))
				push(fmt("  local bm%d=Instance.new('Beam',%s)", el.id,vn))
				push(fmt("  bm%d.Attachment0=a0_%d bm%d.Attachment1=a1_%d", el.id,el.id,el.id,el.id))
				push(fmt("  bm%d.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,%s),ColorSequenceKeypoint.new(1,%s)})", el.id,fmtC3(el.color0),fmtC3(el.color1)))
				push(fmt("  bm%d.Width0=%s bm%d.Width1=%s bm%d.Segments=%d bm%d.FaceCamera=%s bm%d.LightInfluence=%s", el.id,fmtN(el.width0),el.id,fmtN(el.width1),el.id,el.segments,el.id,tostring(el.faceCamera),el.id,fmtN(el.lightInfluence)))
				push(fmt("  table.insert(_vfxI,%s)", vn))

			elseif el.type == "Trail" then
				push(fmt("  local %s=Instance.new('Part') %s.Anchored=true %s.CanCollide=false %s.CanQuery=false %s.CanTouch=false %s.Transparency=1 %s.Size=Vector3.new(0.1,0.1,0.1) %s.Parent=workspace", vn,vn,vn,vn,vn,vn,vn,vn))
				push(fmt("  local ta0_%d=Instance.new('Attachment',%s)", el.id,vn))
				push(fmt("  local ta1_%d=Instance.new('Attachment',%s) ta1_%d.Position=Vector3.new(0,%s,0)", el.id,vn,el.id,fmtN(el.trailWidth)))
				push(fmt("  local tr%d=Instance.new('Trail',%s)", el.id,vn))
				push(fmt("  tr%d.Attachment0=ta0_%d tr%d.Attachment1=ta1_%d", el.id,el.id,el.id,el.id))
				push(fmt("  tr%d.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,%s),ColorSequenceKeypoint.new(1,%s)})", el.id,fmtC3(el.color0),fmtC3(el.color1)))
				push(fmt("  tr%d.Lifetime=%s tr%d.MinDistance=%s", el.id,fmtN(el.trailLifetime),el.id,fmtN(el.trailMinDist)))
				push(fmt("  table.insert(_vfxI,%s)", vn))

			elseif el.type == "ParticleEmitter" then
				-- FIX: no LightInfluence on ParticleEmitter
				push(fmt("  local %s=Instance.new('Part') %s.Anchored=true %s.CanCollide=false %s.CanQuery=false %s.CanTouch=false %s.Transparency=1 %s.Size=Vector3.new(0.1,0.1,0.1) %s.Parent=workspace", vn,vn,vn,vn,vn,vn,vn,vn))
				push(fmt("  local pe%d=Instance.new('ParticleEmitter',%s)", el.id,vn))
				push(fmt("  pe%d.Color=ColorSequence.new(%s) pe%d.Rate=%d", el.id,fmtC3(el.peColor),el.id,el.peRate))
				push(fmt("  pe%d.Speed=NumberRange.new(%s,%s) pe%d.Lifetime=NumberRange.new(%s,%s)", el.id,fmtN(el.peSpeedMin),fmtN(el.peSpeedMax),el.id,fmtN(el.peLifetimeMin),fmtN(el.peLifetimeMax)))
				push(fmt("  pe%d.Size=NumberSequence.new(%s) pe%d.SpreadAngle=Vector2.new(-%s,%s)", el.id,fmtN(el.peSize),el.id,fmtN(el.peSpread),fmtN(el.peSpread)))
				push(fmt("  table.insert(_vfxI,%s)", vn))

			elseif el.type == "BillboardGui" then
				push(fmt("  local %s=Instance.new('Part') %s.Anchored=true %s.CanCollide=false %s.CanQuery=false %s.CanTouch=false %s.Transparency=1 %s.Size=Vector3.new(0.1,0.1,0.1) %s.Parent=workspace", vn,vn,vn,vn,vn,vn,vn,vn))
				push(fmt("  local bb%d=Instance.new('BillboardGui',%s) bb%d.Size=UDim2.new(0,%d,0,%d) bb%d.AlwaysOnTop=%s bb%d.Adornee=%s", el.id,vn,el.id,el.bbSizeX,el.bbSizeY,el.id,tostring(el.bbAlwaysOnTop),el.id,vn))
				push(fmt("  local lbl%d=Instance.new('TextLabel',bb%d) lbl%d.Size=UDim2.new(1,0,1,0) lbl%d.BorderSizePixel=0", el.id,el.id,el.id,el.id))
				push(fmt("  lbl%d.BackgroundColor3=%s lbl%d.BackgroundTransparency=%s", el.id,fmtC3(el.bbBgColor),el.id,fmtN(el.bbBgTrans)))
				push(fmt("  lbl%d.TextColor3=%s lbl%d.Text='%s' lbl%d.TextScaled=true", el.id,fmtC3(el.bbTextColor),el.id,el.bbText,el.id))
				push(fmt("  table.insert(_vfxI,%s)", vn))
			end

			-- ── heartbeat ───────────────────────────────────────────
			push(fmt("  local _s%d,_ia%d=0,0", el.id,el.id))
			push(fmt("  local _c%d=RunService.Heartbeat:Connect(function(dt)", el.id))
			push(fmt("    local pp=getP('%s') if not pp or not %s.Parent then return end", el.parentPart,vn))
			push(fmt("    _s%d=_s%d+dt", el.id,el.id))

			-- position expression
			local ox = fmtN(el.offsetPos[1])
			local oy = fmtN(el.offsetPos[2])
			local oz = fmtN(el.offsetPos[3])
			if el.animPos then
				push(fmt("    local _pt=_s%d*%s*(2*math.pi)", el.id, fmtN(el.animPosSpeed)))
				ox = fmt("(%s)+%s*math.sin(_pt)", ox, fmtN(el.animPosAmp[1]))
				oy = fmt("(%s)+%s*math.sin(_pt)", oy, fmtN(el.animPosAmp[2]))
				oz = fmt("(%s)+%s*math.sin(_pt)", oz, fmtN(el.animPosAmp[3]))
			end

			-- rotation expression
			local rx = fmt("math.rad(%s)", fmtN(el.offsetRot[1]))
			local ry = fmt("math.rad(%s)", fmtN(el.offsetRot[2]))
			local rz = fmt("math.rad(%s)", fmtN(el.offsetRot[3]))
			if el.animRot then
				push(fmt("    local _rt=_s%d*%s*(2*math.pi)", el.id, fmtN(el.animRotSpeed)))
				rx = fmt("(%s)+math.rad(%s)*math.sin(_rt)", rx, fmtN(el.animRotAmp[1]))
				ry = fmt("(%s)+math.rad(%s)*math.sin(_rt)", ry, fmtN(el.animRotAmp[2]))
				rz = fmt("(%s)+math.rad(%s)*math.sin(_rt)", rz, fmtN(el.animRotAmp[3]))
			end

			local lf = "math.min(1,0.15*60*dt+0.3)"

			-- FIX: build target expression AFTER all variables are pushed
			if el.infRot then
				push(fmt("    _ia%d=_ia%d+math.rad(%s)*dt", el.id,el.id,fmtN(el.infRotSpeed)))
				push(fmt("    local _ax=Vector3.new(%s,%s,%s)", fmtN(el.infRotAxis[1]),fmtN(el.infRotAxis[2]),fmtN(el.infRotAxis[3])))
				push(fmt("    local _sa=_ax.Magnitude>0 and _ax.Unit or Vector3.new(0,1,0)"))
				push(fmt("    local _sp=CFrame.fromAxisAngle(_sa,_ia%d)", el.id))
				push(fmt("    local _tgt=pp.CFrame*CFrame.new(%s,%s,%s)*CFrame.Angles(%s,%s,%s)*_sp", ox,oy,oz,rx,ry,rz))
			else
				push(fmt("    local _tgt=pp.CFrame*CFrame.new(%s,%s,%s)*CFrame.Angles(%s,%s,%s)", ox,oy,oz,rx,ry,rz))
			end

			-- billboard Y offset
			if el.type == "BillboardGui" then
				push(fmt("    _tgt=pp.CFrame*CFrame.new(%s,%s+%s,%s)", ox, oy, fmtN(el.bbOffsetY), oz))
			end

			push(fmt("    %s.CFrame=%s:Lerp(_tgt,%s)", vn,vn,lf))

			-- FIX: scale pulse exported correctly for both Part and SpecialMesh
			if el.animScale then
				if el.type == "Part" then
					push(fmt("    local _sc=math.max(0.01,1+%s*math.sin(_s%d*%s*2*math.pi))",
						fmtN(el.animScaleAmp), el.id, fmtN(el.animScaleSpeed)))
					push(fmt("    %s.Size=Vector3.new(%s*_sc,%s*_sc,%s*_sc)",
						vn, fmtN(el.size[1]), fmtN(el.size[2]), fmtN(el.size[3])))
				elseif el.type == "SpecialMesh" then
					push(fmt("    local _sc=math.max(0.01,1+%s*math.sin(_s%d*%s*2*math.pi))",
						fmtN(el.animScaleAmp), el.id, fmtN(el.animScaleSpeed)))
					push(fmt("    sm%d.Scale=Vector3.new(%s*_sc,%s*_sc,%s*_sc)",
						el.id, fmtN(el.meshScale[1]), fmtN(el.meshScale[2]), fmtN(el.meshScale[3])))
				end
			end

			push(fmt("  end) table.insert(_vfxC,_c%d)", el.id))
			push("end")
			push("")
		end
	end

	push("-- To destroy all VFX: cleanupVFX()")
	return table.concat(L, "\n")
end

-- ═══════════════════════════════════════════════════════════════════════
--  SCREEN SCALING
-- ═══════════════════════════════════════════════════════════════════════
local BASE_W, BASE_H = 1920, 1080
local function calcScale()
	local vp = Camera.ViewportSize
	return math.min(vp.X / BASE_W, vp.Y / BASE_H)
end
local S = calcScale()
local function px(n)  return math.max(1, math.round(n * S)) end
local function ud(s,o) return UDim.new(s, px(o)) end
local FS = { tiny = math.max(8, px(10)), sm = math.max(9, px(11)), md = math.max(10, px(13)) }

-- ═══════════════════════════════════════════════════════════════════════
--  GUI SETUP
-- ═══════════════════════════════════════════════════════════════════════
local old = CoreGui:FindFirstChild("VFXAnimatorGUI")
if old then old:Destroy() end

local SG = Instance.new("ScreenGui")
SG.Name            = "VFXAnimatorGUI"
SG.ResetOnSpawn    = false
SG.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
SG.IgnoreGuiInset  = true
SG.DisplayOrder    = 999
if not pcall(function() SG.Parent = CoreGui end) then
	SG.Parent = lp.PlayerGui
end

local C = {
	bg      = c3r(10,10,14),    panel   = c3r(18,18,25),
	elevated= c3r(26,26,36),    border  = c3r(40,40,56),
	accent  = c3r(78,228,196),  accent2 = c3r(158,128,255),
	warn    = c3r(251,191,36),  red     = c3r(248,96,96),
	green   = c3r(68,220,118),  text    = c3r(212,212,228),
	muted   = c3r(105,105,135), white   = c3r(255,255,255),
	code    = c3r(120,255,190), revOn   = c3r(248,150,60),
	axisX   = c3r(255,90,90),   axisY   = c3r(90,220,90),  axisZ = c3r(90,150,255),
	sub     = c3r(22,22,32),
}

local WIN_W   = px(560); local WIN_H   = px(720)
local TITLE_H = px(34);  local TOOL_H  = px(32)
local CODE_H  = px(90)
local SCROLL_H = WIN_H - TITLE_H - TOOL_H - px(4) - CODE_H - px(2)
local vp = Camera.ViewportSize
local WX = math.round(vp.X * 0.03)
local WY = math.round(vp.Y * 0.03)

-- ── GUI helpers ──────────────────────────────────────────────────────
local function make(cls, props, parent)
	local inst = Instance.new(cls)
	for k, v in pairs(props) do inst[k] = v end
	if parent then inst.Parent = parent end
	return inst
end
local function frm(props, par)
	props.BackgroundColor3 = props.BackgroundColor3 or C.panel
	props.BorderSizePixel  = props.BorderSizePixel  or 0
	return make("Frame", props, par)
end
local function lbl(props, par)
	props.BackgroundTransparency = props.BackgroundTransparency or 1
	props.TextColor3             = props.TextColor3 or C.text
	props.Font                   = props.Font       or Enum.Font.Gotham
	props.TextSize               = props.TextSize   or FS.sm
	return make("TextLabel", props, par)
end
local function btn(props, par)
	props.BackgroundColor3 = props.BackgroundColor3 or C.elevated
	props.BorderSizePixel  = 0
	props.Font             = props.Font or Enum.Font.GothamBold
	props.TextSize         = props.TextSize or FS.tiny
	props.TextColor3       = props.TextColor3 or C.text
	props.AutoButtonColor  = false
	local b = make("TextButton", props, par)
	local orig = props.BackgroundColor3
	b.MouseEnter:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.1), {BackgroundColor3 = Color3.new(
			math.min(1, orig.R + 0.08), math.min(1, orig.G + 0.08), math.min(1, orig.B + 0.08)
		)}):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.1), {BackgroundColor3 = orig}):Play()
	end)
	return b
end
local function crn(r, par)  return make("UICorner",   {CornerRadius = ud(0, r)}, par) end
local function pad(t,b,l,r,par)
	return make("UIPadding", {
		PaddingTop    = ud(0,t), PaddingBottom = ud(0,b),
		PaddingLeft   = ud(0,l), PaddingRight  = ud(0,r)
	}, par)
end
local function strk(col,th,par) return make("UIStroke", {Color=col, Thickness=th}, par) end
local function listL(dir, gap, va, par)
	return make("UIListLayout", {
		FillDirection    = dir or Enum.FillDirection.Vertical,
		Padding          = ud(0, gap or 3),
		VerticalAlignment= va or Enum.VerticalAlignment.Top,
		SortOrder        = Enum.SortOrder.LayoutOrder,
	}, par)
end

-- ── Main window ───────────────────────────────────────────────────────
local Main = frm({
	Name="Main", Size=UDim2.fromOffset(WIN_W, WIN_H),
	Position=UDim2.fromOffset(WX, WY),
	BackgroundColor3=C.bg, ClipsDescendants=true,
}, SG)
crn(9, Main); strk(C.border, 1.5, Main)

-- Title bar
local TitleBar = frm({Size=UDim2.new(1,0,0,TITLE_H), BackgroundColor3=C.panel}, Main)
crn(9, TitleBar)
frm({Size=UDim2.new(1,0,0,px(9)), Position=UDim2.new(0,0,1,-px(9)), BackgroundColor3=C.panel}, TitleBar)
frm({Size=UDim2.fromOffset(px(3), TITLE_H), BackgroundColor3=C.accent}, TitleBar)
lbl({
	Size=UDim2.new(1,-px(100),1,0), Position=UDim2.new(0,px(10),0,0),
	Text="VFX Animator", TextColor3=C.white, Font=Enum.Font.GothamBold, TextSize=FS.md,
	TextXAlignment=Enum.TextXAlignment.Left,
}, TitleBar)
local vbadge = frm({
	Size=UDim2.fromOffset(px(34),px(14)),
	Position=UDim2.new(1,-px(90),0.5,-px(7)),
	BackgroundColor3=C.accent2,
}, TitleBar)
crn(3, vbadge)
lbl({Size=UDim2.new(1,0,1,0), Text="v1.1", Font=Enum.Font.GothamBold,
	TextSize=FS.tiny, TextColor3=C.white, BackgroundTransparency=0}, vbadge)

local CloseBtn = btn({
	Size=UDim2.fromOffset(px(20),px(20)),
	Position=UDim2.new(1,-px(24),0.5,-px(10)),
	BackgroundColor3=C.red, Text="✕", TextSize=FS.tiny, TextColor3=C.white,
}, TitleBar)
crn(4, CloseBtn)
CloseBtn.MouseButton1Click:Connect(function() Main.Visible = false end)

local MinBtn = btn({
	Size=UDim2.fromOffset(px(20),px(20)),
	Position=UDim2.new(1,-px(48),0.5,-px(10)),
	BackgroundColor3=C.elevated, Text="−", TextSize=FS.tiny, TextColor3=C.muted,
}, TitleBar)
crn(4, MinBtn)
local minimised = false
MinBtn.MouseButton1Click:Connect(function()
	minimised = not minimised
	TweenService:Create(Main, TweenInfo.new(0.18, Enum.EasingStyle.Quint), {
		Size = minimised and UDim2.fromOffset(WIN_W, TITLE_H)
		              or UDim2.fromOffset(WIN_W, WIN_H)
	}):Play()
end)

-- Drag
do
	local dragging, ds, sp_
	TitleBar.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true; ds = inp.Position; sp_ = Main.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(inp)
		if dragging and inp.UserInputType == Enum.UserInputType.MouseMovement then
			local d = inp.Position - ds
			Main.Position = UDim2.fromOffset(sp_.X.Offset + d.X, sp_.Y.Offset + d.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
	end)
end

-- Toolbar
local Toolbar = frm({
	Size=UDim2.new(1,0,0,TOOL_H),
	Position=UDim2.new(0,0,0,TITLE_H),
	BackgroundColor3=C.panel,
}, Main)
pad(px(4),px(4),px(6),px(6), Toolbar)
listL(Enum.FillDirection.Horizontal, px(3), Enum.VerticalAlignment.Center, Toolbar)

local function tbBtn(txt, bgCol, txCol)
	local b = btn({
		Size=UDim2.new(0,0,0,px(22)), AutomaticSize=Enum.AutomaticSize.X,
		BackgroundColor3=bgCol or C.elevated,
		Text=" "..txt.." ", TextSize=FS.tiny, Font=Enum.Font.GothamBold,
		TextColor3=txCol or C.text,
	}, Toolbar)
	pad(0,0,px(5),px(5),b); crn(4,b); return b
end

local AddPartBtn    = tbBtn("+ Part",    Color3.fromRGB(14,30,48), C.accent)
local AddBeamBtn    = tbBtn("+ Beam")
local AddTrailBtn   = tbBtn("+ Trail")
local AddEmitterBtn = tbBtn("+ Emitter")
local AddBBBtn      = tbBtn("+ Label")
local AddMeshBtn    = tbBtn("+ Mesh")
local SpawnAllBtn   = tbBtn("▶ All",  Color3.fromRGB(14,48,38), C.green)
local KillAllBtn    = tbBtn("■ Kill", Color3.fromRGB(48,14,14), C.red)
local ExportBtn     = tbBtn("⎘ Export", Color3.fromRGB(14,30,48), C.accent)

-- Scroll area
local ScrollY = TITLE_H + TOOL_H + px(2)
local ScrollFrame = make("ScrollingFrame", {
	Size=UDim2.new(1,-px(6),0,SCROLL_H),
	Position=UDim2.new(0,px(3),0,ScrollY),
	BackgroundColor3=C.bg, BorderSizePixel=0,
	ScrollBarThickness=px(4), ScrollBarImageColor3=C.accent,
	CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
	ClipsDescendants=true,
}, Main)
listL(Enum.FillDirection.Vertical, px(3), Enum.VerticalAlignment.Top, ScrollFrame)
pad(px(3),px(3),px(3),px(3), ScrollFrame)

-- Code panel
local CodeY = WIN_H - CODE_H
local CodePanel = frm({
	Size=UDim2.new(1,0,0,CODE_H),
	Position=UDim2.new(0,0,0,CodeY),
	BackgroundColor3=C.panel,
}, Main)
strk(C.border, 1, CodePanel)

local codeHdr = frm({Size=UDim2.new(1,0,0,px(18)), BackgroundColor3=C.elevated}, CodePanel)
lbl({
	Size=UDim2.new(1,-px(30),1,0), Position=UDim2.new(0,px(6),0,0),
	Text="EXPORT CODE  (auto-preview every 0.5s)",
	TextColor3=C.muted, TextSize=FS.tiny, Font=Enum.Font.GothamBold,
	TextXAlignment=Enum.TextXAlignment.Left,
}, codeHdr)

local CopyCodeBtn = btn({
	Size=UDim2.fromOffset(px(24),px(14)),
	Position=UDim2.new(1,-px(26),0.5,-px(7)),
	BackgroundColor3=C.accent, Text="⎘", TextSize=FS.tiny, TextColor3=C.bg,
}, codeHdr)
crn(3, CopyCodeBtn)

local CodeLabel = lbl({
	Size=UDim2.new(1,-px(8),1,-px(22)),
	Position=UDim2.new(0,px(4),0,px(20)),
	Text="-- add elements then click ▶ All",
	TextColor3=C.code, Font=Enum.Font.Code, TextSize=FS.tiny,
	TextXAlignment=Enum.TextXAlignment.Left,
	TextYAlignment=Enum.TextYAlignment.Top,
	TextWrapped=true,
}, CodePanel)

-- FIX: generate once, use result
CopyCodeBtn.MouseButton1Click:Connect(function()
	local code = generateCode()
	if setclipboard then pcall(setclipboard, code)
	elseif syn and syn.clipboard then pcall(syn.clipboard.set, code)
	elseif writeclipboard then pcall(writeclipboard, code) end
	CopyCodeBtn.Text = "✓"
	task.delay(1.5, function() CopyCodeBtn.Text = "⎘" end)
end)

-- ═══════════════════════════════════════════════════════════════════════
--  WIDGET HELPERS
-- ═══════════════════════════════════════════════════════════════════════
local loCounter = 0
local function nlo() loCounter = loCounter + 1; return loCounter end

local function makeSliderRow(parent, labelTxt, sMin, sMax, initV, onChange, lo)
	local row = frm({Size=UDim2.new(1,-px(6),0,px(22)), BackgroundTransparency=1, LayoutOrder=lo or nlo()}, parent)
	lbl({Size=UDim2.new(0,px(82),1,0), Text=labelTxt, TextColor3=C.muted, TextSize=FS.tiny,
		Font=Enum.Font.Gotham, TextXAlignment=Enum.TextXAlignment.Left}, row)

	local range = math.max(sMax - sMin, 1e-6)
	local track = frm({Size=UDim2.new(1,-px(136),0,px(4)), Position=UDim2.new(0,px(84),0.5,-px(2)), BackgroundColor3=C.border}, row)
	crn(px(2), track)
	local initT = math.clamp((initV - sMin) / range, 0, 1)
	local fill  = frm({Size=UDim2.new(initT,0,1,0), BackgroundColor3=C.accent}, track); crn(px(2), fill)
	local thumb = frm({Size=UDim2.fromOffset(px(10),px(10)), Position=UDim2.new(initT,-px(5),0.5,-px(5)), BackgroundColor3=C.white}, track); crn(px(5), thumb)

	local numBox = make("TextBox", {
		Size=UDim2.fromOffset(px(46),px(18)),
		Position=UDim2.new(1,-px(48),0.5,-px(9)),
		BackgroundColor3=C.sub, BorderSizePixel=0,
		Text=fmt("%.3f", initV),
		Font=Enum.Font.Code, TextSize=FS.tiny,
		TextColor3=C.accent, ClearTextOnFocus=true,
	}, row)
	crn(px(3), numBox)

	local function setVal(v, clampIt)
		local dv = clampIt and math.clamp(v, sMin, sMax) or v
		local t2 = math.clamp((dv - sMin) / range, 0, 1)
		fill.Size  = UDim2.new(t2, 0, 1, 0)
		thumb.Position = UDim2.new(t2, -px(5), 0.5, -px(5))
		numBox.Text = fmt("%.3f", dv)
		onChange(dv)
	end

	local drag = false
	track.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then
			drag = true
			local ap = track.AbsolutePosition; local as = track.AbsoluteSize
			setVal(sMin + math.clamp((inp.Position.X - ap.X) / as.X, 0, 1) * range, true)
		end
	end)
	UserInputService.InputChanged:Connect(function(inp)
		if drag and inp.UserInputType == Enum.UserInputType.MouseMovement then
			local ap = track.AbsolutePosition; local as = track.AbsoluteSize
			setVal(sMin + math.clamp((inp.Position.X - ap.X) / as.X, 0, 1) * range, true)
		end
	end)
	UserInputService.InputEnded:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then drag = false end
	end)
	numBox.FocusLost:Connect(function()
		local v = tonumber(numBox.Text); if v then setVal(v, false) end
	end)
	return row, setVal
end

local function makeToggle(parent, labelTxt, initState, onChange, lo)
	local row = frm({Size=UDim2.new(1,-px(6),0,px(20)), BackgroundTransparency=1, LayoutOrder=lo or nlo()}, parent)
	lbl({Size=UDim2.new(1,-px(50),1,0), Text=labelTxt, TextColor3=C.muted, TextSize=FS.tiny,
		Font=Enum.Font.Gotham, TextXAlignment=Enum.TextXAlignment.Left}, row)
	local trk = frm({
		Size=UDim2.fromOffset(px(32),px(16)),
		Position=UDim2.new(1,-px(36),0.5,-px(8)),
		BackgroundColor3=initState and C.accent or C.border,
	}, row)
	crn(px(8), trk)
	local knob = frm({
		Size=UDim2.fromOffset(px(12),px(12)),
		Position=initState and UDim2.new(1,-px(14),0.5,-px(6)) or UDim2.new(0,px(2),0.5,-px(6)),
		BackgroundColor3=C.white,
	}, trk)
	crn(px(6), knob)
	local state = initState
	local function setState(v)
		state = v
		TweenService:Create(trk, TweenInfo.new(0.12), {BackgroundColor3 = v and C.accent or C.border}):Play()
		TweenService:Create(knob, TweenInfo.new(0.12), {
			Position = v and UDim2.new(1,-px(14),0.5,-px(6)) or UDim2.new(0,px(2),0.5,-px(6))
		}):Play()
	end
	trk.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then
			state = not state; setState(state); onChange(state)
		end
	end)
	return row, setState
end

local function makeSep(parent, txt, lo)
	local s = frm({Size=UDim2.new(1,-px(6),0,px(12)), BackgroundTransparency=1, LayoutOrder=lo or nlo()}, parent)
	lbl({Size=UDim2.new(1,0,1,0), Text=txt, TextColor3=Color3.fromRGB(55,55,78),
		TextSize=math.max(7, FS.tiny-1), Font=Enum.Font.GothamBold, TextXAlignment=Enum.TextXAlignment.Left}, s)
end

local function makeDropdown(parent, labelTxt, options, initVal, onChange, lo)
	local row = frm({Size=UDim2.new(1,-px(6),0,px(22)), BackgroundTransparency=1, LayoutOrder=lo or nlo()}, parent)
	lbl({Size=UDim2.new(0,px(82),1,0), Text=labelTxt, TextColor3=C.muted, TextSize=FS.tiny,
		Font=Enum.Font.Gotham, TextXAlignment=Enum.TextXAlignment.Left}, row)

	local display = btn({
		Size=UDim2.new(1,-px(88),0,px(18)),
		Position=UDim2.new(0,px(84),0.5,-px(9)),
		BackgroundColor3=C.sub,
		Text=tostring(initVal).." ▾", TextSize=FS.tiny, TextColor3=C.text,
	}, row)
	crn(px(3), display)

	local dropOpen  = false
	local dropFrame = frm({
		Size=UDim2.new(0,px(180),0,0), AutomaticSize=Enum.AutomaticSize.Y,
		Position=UDim2.new(0,px(84),1,0),
		BackgroundColor3=C.elevated, ZIndex=10, Visible=false,
	}, row)
	crn(px(4), dropFrame); strk(C.border, 1, dropFrame)
	listL(Enum.FillDirection.Vertical, px(1), Enum.VerticalAlignment.Top, dropFrame)
	pad(px(2),px(2),px(2),px(2), dropFrame)

	for _, opt in ipairs(options) do
		local ob = btn({
			Size=UDim2.new(1,-px(4),0,px(18)),
			BackgroundColor3=C.elevated,
			Text=tostring(opt), TextSize=FS.tiny, TextColor3=C.text, ZIndex=11,
		}, dropFrame)
		crn(px(3), ob)
		ob.MouseButton1Click:Connect(function()
			display.Text = tostring(opt).." ▾"
			dropOpen = false; dropFrame.Visible = false
			onChange(opt)
		end)
	end

	display.MouseButton1Click:Connect(function()
		dropOpen = not dropOpen; dropFrame.Visible = dropOpen
	end)
	return row
end

-- FIX: makeVec3Row now correctly mutates the element's sub-table in place
local function makeVec3Row(parent, labelTxt, valTable, minV, maxV, onChange, lo)
	local row = frm({Size=UDim2.new(1,-px(6),0,px(14+3*22)), BackgroundTransparency=1, LayoutOrder=lo or nlo()}, parent)
	lbl({Size=UDim2.new(1,0,0,px(14)), Text=labelTxt, TextColor3=C.muted, TextSize=FS.tiny, Font=Enum.Font.Gotham}, row)

	local axes   = {"X","Y","Z"}
	local axCols = {C.axisX, C.axisY, C.axisZ}
	local range  = math.max(maxV - minV, 1e-6)

	for i, ax in ipairs(axes) do
		local sub = frm({
			Size=UDim2.new(1,0,0,px(20)),
			Position=UDim2.new(0,0,0,px(14+(i-1)*22)),
			BackgroundTransparency=1,
		}, row)

		lbl({Size=UDim2.fromOffset(px(14),px(20)), Text=ax, TextColor3=axCols[i],
			TextSize=FS.tiny, Font=Enum.Font.GothamBold}, sub)

		local track = frm({Size=UDim2.new(1,-px(70),0,px(4)), Position=UDim2.new(0,px(16),0.5,-px(2)), BackgroundColor3=C.border}, sub)
		crn(px(2), track)
		local initT = math.clamp((valTable[i] - minV) / range, 0, 1)
		local fill  = frm({Size=UDim2.new(initT,0,1,0), BackgroundColor3=axCols[i]}, track); crn(px(2), fill)
		local thumb = frm({Size=UDim2.fromOffset(px(10),px(10)), Position=UDim2.new(initT,-px(5),0.5,-px(5)), BackgroundColor3=C.white}, track); crn(px(5), thumb)

		local nb = make("TextBox", {
			Size=UDim2.fromOffset(px(44),px(18)),
			Position=UDim2.new(1,-px(46),0.5,-px(9)),
			BackgroundColor3=C.sub, BorderSizePixel=0,
			Text=fmt("%.2f", valTable[i]),
			Font=Enum.Font.Code, TextSize=FS.tiny,
			TextColor3=axCols[i], ClearTextOnFocus=true,
		}, sub)
		crn(px(3), nb)

		-- FIX: capture i properly with a local
		local idx = i
		local function setV(v, cl)
			local dv = cl and math.clamp(v, minV, maxV) or v
			valTable[idx] = dv  -- FIX: mutate the actual table in place
			local t2 = math.clamp((dv - minV) / range, 0, 1)
			fill.Size      = UDim2.new(t2, 0, 1, 0)
			thumb.Position = UDim2.new(t2, -px(5), 0.5, -px(5))
			nb.Text = fmt("%.2f", dv)
			onChange(valTable)
		end

		local drag = false
		track.InputBegan:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseButton1 then
				drag = true
				local ap = track.AbsolutePosition; local as = track.AbsoluteSize
				setV(minV + math.clamp((inp.Position.X - ap.X) / as.X, 0, 1) * range, true)
			end
		end)
		UserInputService.InputChanged:Connect(function(inp)
			if drag and inp.UserInputType == Enum.UserInputType.MouseMovement then
				local ap = track.AbsolutePosition; local as = track.AbsoluteSize
				setV(minV + math.clamp((inp.Position.X - ap.X) / as.X, 0, 1) * range, true)
			end
		end)
		UserInputService.InputEnded:Connect(function(inp)
			if inp.UserInputType == Enum.UserInputType.MouseButton1 then drag = false end
		end)
		nb.FocusLost:Connect(function()
			local v = tonumber(nb.Text); if v then setV(v, false) end
		end)
	end
	return row
end

-- FIX: makeColorRow — removed broken unused track frames; RGB boxes now work correctly
local function makeColorRow(parent, labelTxt, valTable, onChange, lo)
	local row = frm({Size=UDim2.new(1,-px(6),0,px(22)), BackgroundTransparency=1, LayoutOrder=lo or nlo()}, parent)
	lbl({Size=UDim2.new(0,px(82),1,0), Text=labelTxt, TextColor3=C.muted, TextSize=FS.tiny,
		Font=Enum.Font.Gotham, TextXAlignment=Enum.TextXAlignment.Left}, row)

	local swatch = frm({
		Size=UDim2.fromOffset(px(18),px(16)),
		Position=UDim2.new(0,px(84),0.5,-px(8)),
		BackgroundColor3=c3(valTable),
	}, row)
	crn(px(3), swatch)

	local channels = {"R","G","B"}
	local axCols   = {C.axisX, C.axisY, C.axisZ}
	local boxW     = px(36)
	local startX   = px(106)

	for i = 1, 3 do
		-- channel label
		lbl({
			Size=UDim2.fromOffset(px(10), px(22)),
			Position=UDim2.new(0, startX + (i-1)*(boxW+px(14)), 0, 0),
			Text=channels[i], TextColor3=axCols[i],
			TextSize=FS.tiny, Font=Enum.Font.GothamBold,
		}, row)

		local nb = make("TextBox", {
			Size=UDim2.fromOffset(boxW, px(18)),
			Position=UDim2.new(0, startX + px(12) + (i-1)*(boxW+px(14)), 0.5, -px(9)),
			BackgroundColor3=C.sub, BorderSizePixel=0,
			Text=tostring(math.round(valTable[i])),
			Font=Enum.Font.Code, TextSize=FS.tiny,
			TextColor3=axCols[i], ClearTextOnFocus=true,
		}, row)
		crn(px(3), nb)

		local idx = i
		nb.FocusLost:Connect(function()
			local v = tonumber(nb.Text)
			if v then
				valTable[idx] = math.clamp(math.round(v), 0, 255)
				swatch.BackgroundColor3 = c3(valTable)
				onChange(valTable)
			end
		end)
	end
	return row
end

-- ═══════════════════════════════════════════════════════════════════════
--  BUILD ELEMENT SECTION
-- ═══════════════════════════════════════════════════════════════════════
local elementSections = {}

local function buildElementSection(el)
	local collapsed = false

	-- Header
	local header = frm({
		Size=UDim2.new(1,-px(6),0,px(28)),
		BackgroundColor3=C.elevated, LayoutOrder=nlo(),
	}, ScrollFrame)
	crn(px(5), header); strk(C.border, 1, header)

	local arrowL = lbl({
		Size=UDim2.fromOffset(px(16),px(28)), Position=UDim2.new(0,px(5),0,0),
		Text="▼", TextColor3=C.accent, TextSize=FS.tiny, Font=Enum.Font.GothamBold,
	}, header)

	local typeBadge = frm({
		Size=UDim2.fromOffset(px(56),px(14)),
		Position=UDim2.new(0,px(22),0.5,-px(7)),
		BackgroundColor3=C.accent2,
	}, header)
	crn(px(3), typeBadge)
	lbl({Size=UDim2.new(1,0,1,0), Text=el.type, Font=Enum.Font.GothamBold,
		TextSize=FS.tiny, TextColor3=C.white, BackgroundTransparency=0}, typeBadge)

	lbl({
		Size=UDim2.new(1,-px(165),1,0), Position=UDim2.new(0,px(82),0,0),
		Text=el.name, TextColor3=C.text, TextSize=FS.sm, Font=Enum.Font.GothamBold,
		TextXAlignment=Enum.TextXAlignment.Left,
	}, header)

	local enBtn = btn({
		Size=UDim2.fromOffset(px(38),px(15)),
		Position=UDim2.new(1,-px(84),0.5,-px(7)),
		BackgroundColor3=el.enabled and Color3.fromRGB(16,50,38) or C.elevated,
		Text=el.enabled and "ON" or "OFF", TextSize=FS.tiny, Font=Enum.Font.GothamBold,
		TextColor3=el.enabled and C.green or C.muted,
	}, header)
	crn(px(3), enBtn)
	enBtn.MouseButton1Click:Connect(function()
		el.enabled = not el.enabled
		enBtn.BackgroundColor3 = el.enabled and Color3.fromRGB(16,50,38) or C.elevated
		enBtn.Text      = el.enabled and "ON" or "OFF"
		enBtn.TextColor3 = el.enabled and C.green or C.muted
	end)

	local spawnBtn = btn({
		Size=UDim2.fromOffset(px(42),px(15)),
		Position=UDim2.new(1,-px(40),0.5,-px(7)),
		BackgroundColor3=Color3.fromRGB(14,48,38),
		Text="▶ Run", TextSize=FS.tiny, TextColor3=C.green,
	}, header)
	crn(px(3), spawnBtn)
	spawnBtn.MouseButton1Click:Connect(function() spawnElement(el) end)

	-- Body
	local body = frm({
		Size=UDim2.new(1,-px(6),0,0), AutomaticSize=Enum.AutomaticSize.Y,
		BackgroundColor3=C.panel, LayoutOrder=nlo(),
	}, ScrollFrame)
	crn(px(5), body)
	listL(Enum.FillDirection.Vertical, px(2), Enum.VerticalAlignment.Top, body)
	pad(px(5),px(6),px(5),px(5), body)

	-- FIX: collapse toggle only on arrow / left side, not on action buttons
	arrowL.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then
			collapsed   = not collapsed
			body.Visible = not collapsed
			arrowL.Text  = collapsed and "▶" or "▼"
		end
	end)
	-- Make the label area clickable too for convenience
	local clickZone = frm({
		Size=UDim2.new(1,-px(160),1,0), Position=UDim2.new(0,0,0,0),
		BackgroundTransparency=1, ZIndex=header.ZIndex,
	}, header)
	clickZone.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then
			collapsed   = not collapsed
			body.Visible = not collapsed
			arrowL.Text  = collapsed and "▶" or "▼"
		end
	end)

	-- ── Name / Parent ─────────────────────────────────────────────────
	makeSep(body, "── NAME / PARENT")

	local nameRow = frm({Size=UDim2.new(1,-px(6),0,px(22)), BackgroundTransparency=1, LayoutOrder=nlo()}, body)
	lbl({Size=UDim2.new(0,px(82),1,0), Text="Name", TextColor3=C.muted, TextSize=FS.tiny,
		Font=Enum.Font.Gotham, TextXAlignment=Enum.TextXAlignment.Left}, nameRow)
	local nameBox = make("TextBox", {
		Size=UDim2.new(1,-px(88),0,px(18)), Position=UDim2.new(0,px(84),0.5,-px(9)),
		BackgroundColor3=C.sub, BorderSizePixel=0, Text=el.name,
		Font=Enum.Font.Gotham, TextSize=FS.tiny, TextColor3=C.text, ClearTextOnFocus=false,
	}, nameRow)
	crn(px(3), nameBox)
	nameBox.FocusLost:Connect(function() el.name = nameBox.Text end)

	makeDropdown(body, "Parent Part", BODY_PARTS, el.parentPart, function(v) el.parentPart = v end)

	-- ── Type-specific ─────────────────────────────────────────────────
	if el.type == "Part" or el.type == "SpecialMesh" then
		makeSep(body, "── APPEARANCE")
		makeColorRow(body, "Color", el.color, function() end)  -- valTable mutated in place
		makeDropdown(body, "Material", {
			"Neon","SmoothPlastic","Glass","Metal","ForceField",
			"Plastic","Wood","Concrete","Granite","Marble","Sand","Fabric","Ice",
		}, el.material, function(v) el.material = v end)
		makeSliderRow(body, "Transparency", 0, 0.99, el.transparency, function(v) el.transparency = v end)
		makeToggle(body, "Cast Shadow", el.castShadow, function(v) el.castShadow = v end)

		if el.type == "Part" then
			makeSep(body, "── SHAPE / SIZE")
			makeDropdown(body, "Shape", {"Ball","Block","Cylinder","Wedge","CornerWedge"},
				el.shape, function(v) el.shape = v end)
			makeVec3Row(body, "Size", el.size, 0.05, 20, function() end)
		else
			makeSep(body, "── MESH")
			makeDropdown(body, "Mesh Type", {"Sphere","Cylinder","Brick","FileMesh","Head","Torso","Wedge"},
				el.meshType, function(v) el.meshType = v end)
			makeVec3Row(body, "Scale", el.meshScale, 0.1, 20, function() end)

			local function textRow(labelT, key, placeholder)
				local r = frm({Size=UDim2.new(1,-px(6),0,px(22)), BackgroundTransparency=1, LayoutOrder=nlo()}, body)
				lbl({Size=UDim2.new(0,px(82),1,0), Text=labelT, TextColor3=C.muted, TextSize=FS.tiny,
					Font=Enum.Font.Gotham, TextXAlignment=Enum.TextXAlignment.Left}, r)
				local tb = make("TextBox", {
					Size=UDim2.new(1,-px(88),0,px(18)), Position=UDim2.new(0,px(84),0.5,-px(9)),
					BackgroundColor3=C.sub, BorderSizePixel=0, Text=el[key],
					Font=Enum.Font.Code, TextSize=FS.tiny, TextColor3=C.accent,
					ClearTextOnFocus=false, PlaceholderText=placeholder or "",
				}, r)
				crn(px(3), tb)
				tb.FocusLost:Connect(function() el[key] = tb.Text end)
			end
			textRow("Mesh ID",    "meshId",    "rbxassetid://...")
			textRow("Texture ID", "textureId", "rbxassetid://...")
		end

	elseif el.type == "Beam" then
		makeSep(body, "── BEAM")
		makeColorRow(body, "Color start",   el.color0, function() end)
		makeColorRow(body, "Color end",     el.color1, function() end)
		makeSliderRow(body, "Width start",  0, 5,  el.width0,       function(v) el.width0        = v end)
		makeSliderRow(body, "Width end",    0, 5,  el.width1,       function(v) el.width1        = v end)
		makeSliderRow(body, "Length",       0.5, 30, el.beamLength,  function(v) el.beamLength   = v end)
		makeSliderRow(body, "Segments",     2, 50, el.segments,     function(v) el.segments      = math.round(v) end)
		makeSliderRow(body, "Light Infl.",  0, 1,  el.lightInfluence,function(v) el.lightInfluence=v end)
		makeToggle(body, "Face Camera", el.faceCamera, function(v) el.faceCamera = v end)

	elseif el.type == "Trail" then
		makeSep(body, "── TRAIL")
		makeColorRow(body, "Color start",  el.color0, function() end)
		makeColorRow(body, "Color end",    el.color1, function() end)
		makeSliderRow(body, "Lifetime",    0.05, 8,  el.trailLifetime, function(v) el.trailLifetime = v end)
		makeSliderRow(body, "Width",       0.05, 5,  el.trailWidth,    function(v) el.trailWidth    = v end)
		makeSliderRow(body, "Min Distance",0, 2,     el.trailMinDist,  function(v) el.trailMinDist  = v end)

	elseif el.type == "ParticleEmitter" then
		makeSep(body, "── EMITTER")
		makeColorRow(body, "Color",         el.peColor, function() end)
		makeSliderRow(body, "Rate",         1, 500,  el.peRate,        function(v) el.peRate        = math.round(v) end)
		makeSliderRow(body, "Speed min",    0, 50,   el.peSpeedMin,    function(v) el.peSpeedMin    = v end)
		makeSliderRow(body, "Speed max",    0, 50,   el.peSpeedMax,    function(v) el.peSpeedMax    = v end)
		makeSliderRow(body, "Lifetime min", 0.05, 10,el.peLifetimeMin, function(v) el.peLifetimeMin = v end)
		makeSliderRow(body, "Lifetime max", 0.05, 10,el.peLifetimeMax, function(v) el.peLifetimeMax = v end)
		makeSliderRow(body, "Size",         0.05, 5, el.peSize,        function(v) el.peSize        = v end)
		makeSliderRow(body, "Spread",       0, 180,  el.peSpread,      function(v) el.peSpread      = v end)

	elseif el.type == "BillboardGui" then
		makeSep(body, "── BILLBOARD")
		local txtRow = frm({Size=UDim2.new(1,-px(6),0,px(22)), BackgroundTransparency=1, LayoutOrder=nlo()}, body)
		lbl({Size=UDim2.new(0,px(82),1,0), Text="Text", TextColor3=C.muted, TextSize=FS.tiny,
			Font=Enum.Font.Gotham, TextXAlignment=Enum.TextXAlignment.Left}, txtRow)
		local tb = make("TextBox", {
			Size=UDim2.new(1,-px(88),0,px(18)), Position=UDim2.new(0,px(84),0.5,-px(9)),
			BackgroundColor3=C.sub, BorderSizePixel=0, Text=el.bbText,
			Font=Enum.Font.Gotham, TextSize=FS.tiny, TextColor3=C.text, ClearTextOnFocus=false,
		}, txtRow)
		crn(px(3), tb); tb.FocusLost:Connect(function() el.bbText = tb.Text end)
		makeColorRow(body, "Text Color",  el.bbTextColor, function() end)
		makeColorRow(body, "Bg Color",    el.bbBgColor,   function() end)
		makeSliderRow(body, "Bg Trans.",  0, 1,   el.bbBgTrans,  function(v) el.bbBgTrans  = v end)
		makeSliderRow(body, "Size X px",  20, 400, el.bbSizeX,   function(v) el.bbSizeX   = math.round(v) end)
		makeSliderRow(body, "Size Y px",  10, 200, el.bbSizeY,   function(v) el.bbSizeY   = math.round(v) end)
		makeSliderRow(body, "Offset Y",   0, 10,  el.bbOffsetY, function(v) el.bbOffsetY  = v end)
		makeToggle(body, "Always On Top", el.bbAlwaysOnTop, function(v) el.bbAlwaysOnTop = v end)
	end

	-- ── Transform ─────────────────────────────────────────────────────
	makeSep(body, "── BASE TRANSFORM")
	makeVec3Row(body, "Offset Pos", el.offsetPos, -15, 15, function() end)
	makeVec3Row(body, "Offset Rot°",el.offsetRot, -180, 180, function() end)

	-- ── Lerp position ─────────────────────────────────────────────────
	makeSep(body, "── LERP POSITION  (sine bob)")
	makeToggle(body, "Enable",      el.animPos,      function(v) el.animPos      = v end)
	makeVec3Row(body, "Amplitude",  el.animPosAmp,   -5, 5,   function() end)
	makeSliderRow(body, "Speed Hz", 0.1, 10, el.animPosSpeed, function(v) el.animPosSpeed = v end)

	-- ── Lerp rotation ─────────────────────────────────────────────────
	makeSep(body, "── LERP ROTATION  (sine oscillate)")
	makeToggle(body, "Enable",      el.animRot,      function(v) el.animRot      = v end)
	makeVec3Row(body, "Amplitude°", el.animRotAmp,   -180, 180, function() end)
	makeSliderRow(body, "Speed Hz", 0.1, 10, el.animRotSpeed, function(v) el.animRotSpeed = v end)

	-- ── Infinite spin ─────────────────────────────────────────────────
	makeSep(body, "── INFINITE SPIN  (accumulates, never resets)")
	makeToggle(body, "Enable",      el.infRot,       function(v) el.infRot       = v end)
	makeVec3Row(body, "Spin Axis",  el.infRotAxis,   -1, 1,   function() end)
	makeSliderRow(body, "Speed °/s",5, 720, el.infRotSpeed,  function(v) el.infRotSpeed  = v end)

	-- ── Sin size (scale pulse) ────────────────────────────────────────
	if el.type == "Part" or el.type == "SpecialMesh" then
		makeSep(body, "── SIN SIZE  (scale pulse)")
		makeToggle(body, "Enable",       el.animScale,     function(v) el.animScale     = v end)
		makeSliderRow(body, "Amplitude", 0, 2,  el.animScaleAmp,   function(v) el.animScaleAmp  = v end)
		makeSliderRow(body, "Speed Hz",  0.1, 10, el.animScaleSpeed, function(v) el.animScaleSpeed= v end)
	end

	-- ── Actions ───────────────────────────────────────────────────────
	makeSep(body, "── ACTIONS")
	local actRow = frm({Size=UDim2.new(1,-px(6),0,px(24)), BackgroundTransparency=1, LayoutOrder=nlo()}, body)
	listL(Enum.FillDirection.Horizontal, px(4), Enum.VerticalAlignment.Center, actRow)

	local function aBtn(txt, bgC, txC)
		local b = btn({
			Size=UDim2.new(0,0,0,px(20)), AutomaticSize=Enum.AutomaticSize.X,
			BackgroundColor3=bgC or C.elevated,
			Text=" "..txt.." ", TextSize=FS.tiny, TextColor3=txC or C.text,
		}, actRow)
		pad(0,0,px(5),px(5),b); crn(px(3),b); return b
	end

	local spawnSingleBtn = aBtn("▶ Spawn",  Color3.fromRGB(14,48,38), C.green)
	local killSingleBtn  = aBtn("■ Kill",   Color3.fromRGB(48,14,14), C.red)
	local duplicateBtn   = aBtn("⧉ Dupe",   C.elevated, C.accent2)
	local removeBtn      = aBtn("✕ Remove", Color3.fromRGB(48,14,14), C.red)

	spawnSingleBtn.MouseButton1Click:Connect(function() spawnElement(el) end)
	killSingleBtn.MouseButton1Click:Connect(function()  destroyElement(el) end)

	duplicateBtn.MouseButton1Click:Connect(function()
		-- FIX: proper deep copy so nested tables (color, size, etc.) aren't shared
		local newEl = newElement(el.type)
		for k, v in pairs(el) do
			if k ~= "id" and k ~= "_instances" and k ~= "_infAngle" and k ~= "_sine" then
				newEl[k] = deepCopy(v)
			end
		end
		newEl.id   = vfxNextId - 1  -- was already incremented by newElement
		newEl.name = el.name .. " (copy)"
		table.insert(vfxList, newEl)
		buildElementSection(newEl)
	end)

	removeBtn.MouseButton1Click:Connect(function()
		destroyElement(el)
		for i2, e2 in ipairs(vfxList) do
			if e2.id == el.id then table.remove(vfxList, i2); break end
		end
		if elementSections[el.id] then
			elementSections[el.id].header:Destroy()
			elementSections[el.id].body:Destroy()
			elementSections[el.id] = nil
		end
	end)

	elementSections[el.id] = {header = header, body = body}
end

-- ═══════════════════════════════════════════════════════════════════════
--  TOOLBAR ACTIONS
-- ═══════════════════════════════════════════════════════════════════════
local function addAndBuild(typ)
	local el = newElement(typ)
	table.insert(vfxList, el)
	buildElementSection(el)
end

AddPartBtn.MouseButton1Click:Connect(function()    addAndBuild("Part")            end)
AddBeamBtn.MouseButton1Click:Connect(function()    addAndBuild("Beam")            end)
AddTrailBtn.MouseButton1Click:Connect(function()   addAndBuild("Trail")           end)
AddEmitterBtn.MouseButton1Click:Connect(function() addAndBuild("ParticleEmitter") end)
AddBBBtn.MouseButton1Click:Connect(function()      addAndBuild("BillboardGui")    end)
AddMeshBtn.MouseButton1Click:Connect(function()    addAndBuild("SpecialMesh")     end)

SpawnAllBtn.MouseButton1Click:Connect(function()
	for _, el in ipairs(vfxList) do spawnElement(el) end
end)

KillAllBtn.MouseButton1Click:Connect(function()
	for _, el in ipairs(vfxList) do destroyElement(el) end
end)

-- FIX: generate once, store, use twice
ExportBtn.MouseButton1Click:Connect(function()
	local code = generateCode()
	CodeLabel.Text = code
	if setclipboard then pcall(setclipboard, code)
	elseif syn and syn.clipboard then pcall(syn.clipboard.set, code) end
	ExportBtn.Text = " ✓ Copied "
	task.delay(2, function() ExportBtn.Text = " ⎘ Export " end)
end)

-- ═══════════════════════════════════════════════════════════════════════
--  LIVE CODE PREVIEW (every 0.5s, 5 lines max)
-- ═══════════════════════════════════════════════════════════════════════
local previewTimer = 0
RunService.RenderStepped:Connect(function(dt)
	previewTimer = previewTimer + dt
	if previewTimer >= 0.5 then
		previewTimer = 0
		local lines, n = {}, 0
		for line in generateCode():gmatch("[^\n]+") do
			n = n + 1; lines[n] = line
			if n >= 5 then break end
		end
		CodeLabel.Text = n > 0
			and table.concat(lines, "\n") .. (#vfxList > 0 and "\n..." or "")
			or "-- add elements above"
	end
end)

-- ═══════════════════════════════════════════════════════════════════════
--  RESPAWN CLEANUP
-- ═══════════════════════════════════════════════════════════════════════
lp.CharacterAdded:Connect(function(newChar)
	char = newChar
	for _, el in ipairs(vfxList) do destroyElement(el) end
end)
