
--[[
	╔══════════════════════════════════════════════════════════════════════╗
	║           VFX Animator  •  Executor Edition  v1.0                   ║
	║  Spawn / animate / parent VFX parts to any body part                ║
	║  Position lerp • Rotation lerp • Infinite spin • Scale pulse        ║
	╚══════════════════════════════════════════════════════════════════════╝
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

local function lerp(a,b,t) return a+(b-a)*t end
local function cfLerp(a,b,t) return a:Lerp(b,t) end

local ALPHA = 0.15  -- lerp speed for animations

-- ═══════════════════════════════════════════════════════════════════════
--  BODY PARTS LIST
-- ═══════════════════════════════════════════════════════════════════════
local BODY_PARTS = {
	"HumanoidRootPart","Torso","Head",
	"Left Arm","Right Arm","Left Leg","Right Leg",
	-- R15
	"UpperTorso","LowerTorso",
	"LeftUpperArm","RightUpperArm","LeftLowerArm","RightLowerArm",
	"LeftHand","RightHand",
	"LeftUpperLeg","RightUpperLeg","LeftLowerLeg","RightLowerLeg",
	"LeftFoot","RightFoot",
}

local function getBodyPart(name)
	local c = lp.Character
	if not c then return nil end
	return c:FindFirstChild(name) or c:FindFirstChild(name,true)
end

-- ═══════════════════════════════════════════════════════════════════════
--  VFX ELEMENT DATA
-- ═══════════════════════════════════════════════════════════════════════
--[[
Each element:
  type         : "Part" | "Beam" | "Trail" | "ParticleEmitter" | "BillboardGui" | "SpecialMesh"
  name         : display name
  parentPart   : body part name string
  enabled      : bool

  -- Part / SpecialMesh shared
  color        : {r,g,b}
  material     : Enum.Material name string
  transparency : 0-1
  castShadow   : bool
  -- Part specific
  shape        : "Ball"|"Block"|"Cylinder"|"Wedge"|"CornerWedge"
  size         : {x,y,z}
  -- SpecialMesh specific
  meshType     : "Sphere"|"Cylinder"|"Brick"|"FileMesh"|"Head"|"Torso"|"Wedge"
  meshId       : string
  textureId    : string
  meshScale    : {x,y,z}

  -- BASE transform (applied every frame)
  offsetPos    : {x,y,z}  offset from parent part CFrame
  offsetRot    : {x,y,z}  base rotation in degrees

  -- LERP POSITION animation
  animPos      : bool
  animPosAmp   : {x,y,z}  amplitude studs
  animPosSpeed : number    cycles per second

  -- LERP ROTATION animation (sine oscillation)
  animRot      : bool
  animRotAmp   : {x,y,z}  amplitude degrees
  animRotSpeed : number

  -- INFINITE SPIN (accumulates every frame, never resets)
  infRot       : bool
  infRotAxis   : {x,y,z}  direction (normalised)
  infRotSpeed  : number    degrees per second

  -- SCALE PULSE
  animScale    : bool
  animScaleAmp : number    0-2 multiplier amplitude
  animScaleSpeed: number

  -- Beam
  color0/1      : {r,g,b}
  width0/1      : number
  beamLength    : number
  segments      : number
  faceCamera    : bool
  lightInfluence: number

  -- Trail
  trailLifetime : number
  trailWidth    : number
  trailMinDist  : number

  -- ParticleEmitter
  peColor       : {r,g,b}
  peRate        : number
  peSpeedMin    : number
  peSpeedMax    : number
  peLifetimeMin : number
  peLifetimeMax : number
  peSize        : number
  peSpread      : number

  -- BillboardGui
  bbText        : string
  bbTextColor   : {r,g,b}
  bbBgColor     : {r,g,b}
  bbBgTrans     : number
  bbSizeX       : number  pixels
  bbSizeY       : number  pixels
  bbOffsetY     : number  studs above parentPart
  bbAlwaysOnTop : bool

  -- Runtime (set by spawner)
  _instances    : {} list of spawned instances
  _infAngle     : number accumulated spin angle
  _sine         : number local time
]]

local vfxList   = {}   -- array of element data tables
local vfxNextId = 1
local vfxConns  = {}   -- {elementId = RBXScriptConnection}

-- ═══════════════════════════════════════════════════════════════════════
--  DEFAULT ELEMENT
-- ═══════════════════════════════════════════════════════════════════════
local function newElement(type)
	local id = vfxNextId; vfxNextId = vfxNextId+1
	return {
		id=id, type=type, name=type.." "..id, parentPart="HumanoidRootPart", enabled=true,

		color={180,170,255}, material="Neon", transparency=0.2, castShadow=false,
		shape="Ball", size={1,1,1},
		meshType="Sphere", meshId="", textureId="", meshScale={1,1,1},

		offsetPos={0,2,0}, offsetRot={0,0,0},

		animPos=false,   animPosAmp={0,0.5,0}, animPosSpeed=2,
		animRot=false,   animRotAmp={0,20,0},  animRotSpeed=1.5,
		infRot=false,    infRotAxis={0,1,0},   infRotSpeed=90,
		animScale=false, animScaleAmp=0.3,     animScaleSpeed=1.5,

		color0={255,255,255}, color1={127,119,221},
		width0=0.5, width1=0, beamLength=6, segments=12, faceCamera=true, lightInfluence=0,

		trailLifetime=0.5, trailWidth=0.5, trailMinDist=0.05,

		peColor={180,170,255}, peRate=30,
		peSpeedMin=2, peSpeedMax=5,
		peLifetimeMin=0.4, peLifetimeMax=0.8,
		peSize=0.35, peSpread=180,

		bbText="VFX!", bbTextColor={255,255,255}, bbBgColor={20,20,50},
		bbBgTrans=0.1, bbSizeX=80, bbSizeY=40, bbOffsetY=3, bbAlwaysOnTop=true,

		_instances={}, _infAngle=0, _sine=0,
	}
end

-- ═══════════════════════════════════════════════════════════════════════
--  SPAWN / DESTROY
-- ═══════════════════════════════════════════════════════════════════════
local function c3(t) return c3r(math.round(t[1]),math.round(t[2]),math.round(t[3])) end

local function destroyElement(el)
	if vfxConns[el.id] then vfxConns[el.id]:Disconnect(); vfxConns[el.id]=nil end
	for _,inst in ipairs(el._instances) do
		if inst and inst.Parent then
			for _,ch in ipairs(inst:GetDescendants()) do
				if ch:IsA("ParticleEmitter") then ch.Enabled=false end
			end
			task.delay(0.6,function() if inst and inst.Parent then inst:Destroy() end end)
		end
	end
	el._instances={}
end

local function spawnElement(el)
	destroyElement(el)
	el._infAngle=0; el._sine=0

	local pp = getBodyPart(el.parentPart)
	if not pp then warn("[VFX] body part not found: "..el.parentPart); return end

	local rootPart  -- the main Part that moves each frame
	local meshInst  -- SpecialMesh if applicable

	if el.type=="Part" or el.type=="SpecialMesh" then
		local p = Instance.new("Part")
		p.Name        = el.name:gsub("%s","_")
		p.Anchored    = true
		p.CanCollide  = false
		p.CanQuery    = false
		p.CanTouch    = false
		p.CastShadow  = el.type=="Part" and el.castShadow or false
		p.Color       = c3(el.color)
		p.Material    = Enum.Material[el.material] or Enum.Material.Neon
		p.Transparency= el.transparency
		if el.type=="Part" then
			p.Shape = Enum.PartType[el.shape] or Enum.PartType.Ball
			p.Size  = v3n(table.unpack(el.size))
		else
			p.Size  = v3n(2,2,2)
			local m = Instance.new("SpecialMesh",p)
			m.MeshType  = Enum.MeshType[el.meshType] or Enum.MeshType.Sphere
			m.Scale     = v3n(table.unpack(el.meshScale))
			if el.meshId~=""    then m.MeshId    = el.meshId    end
			if el.textureId~="" then m.TextureId = el.textureId end
			meshInst = m
		end
		p.Parent = workspace
		table.insert(el._instances, p)
		rootPart = p

	elseif el.type=="Beam" then
		local hp = Instance.new("Part")
		hp.Name="VFX_BeamHost_"..el.id; hp.Anchored=true; hp.CanCollide=false
		hp.Transparency=1; hp.Size=v3n(0.1,0.1,0.1); hp.Parent=workspace
		local a0 = Instance.new("Attachment",hp); a0.Position=v3n(0,0,0)
		local a1 = Instance.new("Attachment",hp); a1.Position=v3n(0,0,-el.beamLength)
		local bm = Instance.new("Beam",hp)
		bm.Attachment0=a0; bm.Attachment1=a1
		bm.Color=ColorSequence.new({
			ColorSequenceKeypoint.new(0,c3(el.color0)),
			ColorSequenceKeypoint.new(1,c3(el.color1))
		})
		bm.Width0=el.width0; bm.Width1=el.width1
		bm.Segments=el.segments; bm.FaceCamera=el.faceCamera
		bm.LightInfluence=el.lightInfluence
		table.insert(el._instances,hp); rootPart=hp

	elseif el.type=="Trail" then
		local tp = Instance.new("Part")
		tp.Name="VFX_TrailHost_"..el.id; tp.Anchored=true; tp.CanCollide=false
		tp.Transparency=1; tp.Size=v3n(0.1,0.1,0.1); tp.Parent=workspace
		local ta0=Instance.new("Attachment",tp)
		local ta1=Instance.new("Attachment",tp); ta1.Position=v3n(0,el.trailWidth,0)
		local tr=Instance.new("Trail",tp)
		tr.Attachment0=ta0; tr.Attachment1=ta1
		tr.Color=ColorSequence.new({
			ColorSequenceKeypoint.new(0,c3(el.color0)),
			ColorSequenceKeypoint.new(1,c3(el.color1))
		})
		tr.Lifetime=el.trailLifetime; tr.MinDistance=el.trailMinDist
		table.insert(el._instances,tp); rootPart=tp

	elseif el.type=="ParticleEmitter" then
		local ep=Instance.new("Part")
		ep.Name="VFX_EmitHost_"..el.id; ep.Anchored=true; ep.CanCollide=false
		ep.Transparency=1; ep.Size=v3n(0.1,0.1,0.1); ep.Parent=workspace
		local pe=Instance.new("ParticleEmitter",ep)
		pe.Color       = ColorSequence.new(c3(el.peColor))
		pe.Rate        = el.peRate
		pe.Speed       = NumberRange.new(el.peSpeedMin,el.peSpeedMax)
		pe.Lifetime    = NumberRange.new(el.peLifetimeMin,el.peLifetimeMax)
		pe.Size        = NumberSequence.new(el.peSize)
		pe.SpreadAngle = Vector2.new(-el.peSpread,el.peSpread)
		pe.LightInfluence = el.lightInfluence or 0
		table.insert(el._instances,ep); rootPart=ep

	elseif el.type=="BillboardGui" then
		local bp=Instance.new("Part")
		bp.Name="VFX_BBHost_"..el.id; bp.Anchored=true; bp.CanCollide=false
		bp.Transparency=1; bp.Size=v3n(0.1,0.1,0.1); bp.Parent=workspace
		local bb=Instance.new("BillboardGui",bp)
		bb.Size=UDim2.new(0,el.bbSizeX,0,el.bbSizeY)
		bb.AlwaysOnTop=el.bbAlwaysOnTop; bb.Adornee=bp
		local lbl=Instance.new("TextLabel",bb)
		lbl.Size=UDim2.new(1,0,1,0)
		lbl.BackgroundColor3=c3(el.bbBgColor)
		lbl.BackgroundTransparency=el.bbBgTrans
		lbl.TextColor3=c3(el.bbTextColor)
		lbl.Text=el.bbText; lbl.TextScaled=true
		Instance.new("UICorner",lbl).CornerRadius=UDim.new(0.3,0)
		table.insert(el._instances,bp); rootPart=bp
	end

	if not rootPart then return end

	-- Animation loop
	vfxConns[el.id] = RunService.Heartbeat:Connect(function(dt)
		if not el.enabled then return end
		local pp2=getBodyPart(el.parentPart)
		if not pp2 then return end

		el._sine = el._sine + dt

		-- base offset + position animation
		local ox,oy,oz = el.offsetPos[1],el.offsetPos[2],el.offsetPos[3]
		if el.animPos then
			local t = el._sine * el.animPosSpeed * (2*pi)
			ox = ox + el.animPosAmp[1]*sin(t)
			oy = oy + el.animPosAmp[2]*sin(t)
			oz = oz + el.animPosAmp[3]*sin(t)
		end

		-- base rotation + rotation animation
		local rx = rad(el.offsetRot[1])
		local ry = rad(el.offsetRot[2])
		local rz = rad(el.offsetRot[3])
		if el.animRot then
			local t = el._sine * el.animRotSpeed * (2*pi)
			rx = rx + rad(el.animRotAmp[1])*sin(t)
			ry = ry + rad(el.animRotAmp[2])*sin(t)
			rz = rz + rad(el.animRotAmp[3])*sin(t)
		end

		-- infinite spin accumulation
		if el.infRot then
			el._infAngle = el._infAngle + rad(el.infRotSpeed)*dt
			local ax = v3n(el.infRotAxis[1],el.infRotAxis[2],el.infRotAxis[3])
			local spinCF = CFrame.fromAxisAngle(ax.Magnitude>0 and ax.Unit or v3n(0,1,0), el._infAngle)
			local baseCF = pp2.CFrame * cfn(ox,oy,oz) * cfaa(rx,ry,rz)
			local targetCF = baseCF * spinCF
			rootPart.CFrame = cfLerp(rootPart.CFrame, targetCF, math.min(1,ALPHA*60*dt+0.3))
		else
			local targetCF = pp2.CFrame * cfn(ox,oy,oz) * cfaa(rx,ry,rz)
			rootPart.CFrame = cfLerp(rootPart.CFrame, targetCF, math.min(1,ALPHA*60*dt+0.3))
		end

		-- scale pulse
		if el.animScale and (el.type=="Part" or el.type=="SpecialMesh") then
			local sc = 1 + el.animScaleAmp * sin(el._sine * el.animScaleSpeed * 2*pi)
			if el.type=="Part" then
				rootPart.Size = v3n(
					el.size[1]*sc, el.size[2]*sc, el.size[3]*sc
				)
			elseif meshInst then
				meshInst.Scale = v3n(
					el.meshScale[1]*sc, el.meshScale[2]*sc, el.meshScale[3]*sc
				)
			end
		end

		-- billboard Y offset override
		if el.type=="BillboardGui" then
			rootPart.CFrame = cfLerp(rootPart.CFrame,
				pp2.CFrame*cfn(ox,oy+el.bbOffsetY,oz),
				math.min(1,ALPHA*60*dt+0.3))
		end
	end)
end

-- ═══════════════════════════════════════════════════════════════════════
--  CODE EXPORT
-- ═══════════════════════════════════════════════════════════════════════
local function fmtN(n) return fmt("%.4g",n) end
local function fmtV3(t) return fmt("Vector3.new(%s,%s,%s)",fmtN(t[1]),fmtN(t[2]),fmtN(t[3])) end
local function fmtC3(t) return fmt("Color3.fromRGB(%d,%d,%d)",math.round(t[1]),math.round(t[2]),math.round(t[3])) end

local function generateCode()
	local lines={}
	table.insert(lines,"-- VFX Animator export")
	table.insert(lines,"local RunService = game:GetService('RunService')")
	table.insert(lines,"local lp = game:GetService('Players').LocalPlayer")
	table.insert(lines,"local function getP(n) local c=lp.Character; return c and (c:FindFirstChild(n) or c:FindFirstChild(n,true)) end")
	table.insert(lines,"local _vfxInsts={} local _vfxConns={}  -- store for cleanup")
	table.insert(lines,"local function cleanupVFX() for _,c in ipairs(_vfxConns) do c:Disconnect() end _vfxConns={} for _,i in ipairs(_vfxInsts) do if i and i.Parent then i:Destroy() end end _vfxInsts={} end")
	table.insert(lines,"")

	for _,el in ipairs(vfxList) do
		if not el.enabled then
			table.insert(lines,"-- (disabled) "..el.name)
		else
			table.insert(lines,"do -- "..el.name.." ("..el.type..")")
			local vn="vfx_"..el.id
			if el.type=="Part" or el.type=="SpecialMesh" then
				table.insert(lines,fmt("  local %s=Instance.new('Part')",vn))
				table.insert(lines,fmt("  %s.Name='%s'",vn,el.name:gsub("%s","_")))
				table.insert(lines,fmt("  %s.Anchored=true %s.CanCollide=false %s.CanQuery=false %s.CanTouch=false",vn,vn,vn,vn))
				table.insert(lines,fmt("  %s.Color=%s %s.Material=Enum.Material.%s %s.Transparency=%s",vn,fmtC3(el.color),vn,el.material,vn,fmtN(el.transparency)))
				if el.type=="Part" then
					table.insert(lines,fmt("  %s.Shape=Enum.PartType.%s %s.Size=%s",vn,el.shape,vn,fmtV3(el.size)))
				else
					table.insert(lines,fmt("  %s.Size=Vector3.new(2,2,2)",vn))
					table.insert(lines,fmt("  local sm%d=Instance.new('SpecialMesh',%s)",el.id,vn))
					table.insert(lines,fmt("  sm%d.MeshType=Enum.MeshType.%s sm%d.Scale=%s",el.id,el.meshType,el.id,fmtV3(el.meshScale)))
					if el.meshId~="" then table.insert(lines,fmt("  sm%d.MeshId='%s'",el.id,el.meshId)) end
					if el.textureId~="" then table.insert(lines,fmt("  sm%d.TextureId='%s'",el.id,el.textureId)) end
				end
				table.insert(lines,fmt("  %s.Parent=workspace table.insert(_vfxInsts,%s)",vn,vn))
			elseif el.type=="Beam" then
				table.insert(lines,fmt("  local %s=Instance.new('Part') %s.Anchored=true %s.CanCollide=false %s.Transparency=1 %s.Size=Vector3.new(0.1,0.1,0.1) %s.Parent=workspace",vn,vn,vn,vn,vn,vn))
				table.insert(lines,fmt("  local a0_%d=Instance.new('Attachment',%s) local a1_%d=Instance.new('Attachment',%s) a1_%d.Position=Vector3.new(0,0,-%s)",el.id,vn,el.id,vn,el.id,fmtN(el.beamLength)))
				table.insert(lines,fmt("  local bm%d=Instance.new('Beam',%s) bm%d.Attachment0=a0_%d bm%d.Attachment1=a1_%d",el.id,vn,el.id,el.id,el.id,el.id))
				table.insert(lines,fmt("  bm%d.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,%s),ColorSequenceKeypoint.new(1,%s)})",el.id,fmtC3(el.color0),fmtC3(el.color1)))
				table.insert(lines,fmt("  bm%d.Width0=%s bm%d.Width1=%s bm%d.Segments=%d bm%d.FaceCamera=%s bm%d.LightInfluence=%s",el.id,fmtN(el.width0),el.id,fmtN(el.width1),el.id,el.segments,el.id,tostring(el.faceCamera),el.id,fmtN(el.lightInfluence)))
				table.insert(lines,fmt("  table.insert(_vfxInsts,%s)",vn))
			elseif el.type=="Trail" then
				table.insert(lines,fmt("  local %s=Instance.new('Part') %s.Anchored=true %s.CanCollide=false %s.Transparency=1 %s.Size=Vector3.new(0.1,0.1,0.1) %s.Parent=workspace",vn,vn,vn,vn,vn,vn))
				table.insert(lines,fmt("  local ta0_%d=Instance.new('Attachment',%s) local ta1_%d=Instance.new('Attachment',%s) ta1_%d.Position=Vector3.new(0,%s,0)",el.id,vn,el.id,vn,el.id,fmtN(el.trailWidth)))
				table.insert(lines,fmt("  local tr%d=Instance.new('Trail',%s) tr%d.Attachment0=ta0_%d tr%d.Attachment1=ta1_%d",el.id,vn,el.id,el.id,el.id,el.id))
				table.insert(lines,fmt("  tr%d.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,%s),ColorSequenceKeypoint.new(1,%s)})",el.id,fmtC3(el.color0),fmtC3(el.color1)))
				table.insert(lines,fmt("  tr%d.Lifetime=%s tr%d.MinDistance=%s table.insert(_vfxInsts,%s)",el.id,fmtN(el.trailLifetime),el.id,fmtN(el.trailMinDist),vn))
			elseif el.type=="ParticleEmitter" then
				table.insert(lines,fmt("  local %s=Instance.new('Part') %s.Anchored=true %s.CanCollide=false %s.Transparency=1 %s.Size=Vector3.new(0.1,0.1,0.1) %s.Parent=workspace",vn,vn,vn,vn,vn,vn))
				table.insert(lines,fmt("  local pe%d=Instance.new('ParticleEmitter',%s)",el.id,vn))
				table.insert(lines,fmt("  pe%d.Color=ColorSequence.new(%s) pe%d.Rate=%d",el.id,fmtC3(el.peColor),el.id,el.peRate))
				table.insert(lines,fmt("  pe%d.Speed=NumberRange.new(%s,%s) pe%d.Lifetime=NumberRange.new(%s,%s)",el.id,fmtN(el.peSpeedMin),fmtN(el.peSpeedMax),el.id,fmtN(el.peLifetimeMin),fmtN(el.peLifetimeMax)))
				table.insert(lines,fmt("  pe%d.Size=NumberSequence.new(%s) pe%d.SpreadAngle=Vector2.new(-%s,%s) table.insert(_vfxInsts,%s)",el.id,fmtN(el.peSize),el.id,fmtN(el.peSpread),fmtN(el.peSpread),vn))
			elseif el.type=="BillboardGui" then
				table.insert(lines,fmt("  local %s=Instance.new('Part') %s.Anchored=true %s.CanCollide=false %s.Transparency=1 %s.Size=Vector3.new(0.1,0.1,0.1) %s.Parent=workspace",vn,vn,vn,vn,vn,vn))
				table.insert(lines,fmt("  local bb%d=Instance.new('BillboardGui',%s) bb%d.Size=UDim2.new(0,%d,0,%d) bb%d.AlwaysOnTop=%s bb%d.Adornee=%s",el.id,vn,el.id,el.bbSizeX,el.bbSizeY,el.id,tostring(el.bbAlwaysOnTop),el.id,vn))
				table.insert(lines,fmt("  local lbl%d=Instance.new('TextLabel',bb%d) lbl%d.Size=UDim2.new(1,0,1,0) lbl%d.BackgroundColor3=%s lbl%d.BackgroundTransparency=%s",el.id,el.id,el.id,el.id,fmtC3(el.bbBgColor),el.id,fmtN(el.bbBgTrans)))
				table.insert(lines,fmt("  lbl%d.TextColor3=%s lbl%d.Text='%s' lbl%d.TextScaled=true table.insert(_vfxInsts,%s)",el.id,fmtC3(el.bbTextColor),el.id,el.bbText,el.id,vn))
			end

			-- animation heartbeat
			table.insert(lines,fmt("  local _s%d,_ia%d=0,0",el.id,el.id))
			table.insert(lines,fmt("  local _c%d=RunService.Heartbeat:Connect(function(dt)",el.id))
			table.insert(lines,fmt("    local pp=getP('%s') if not pp then return end",el.parentPart))
			table.insert(lines,fmt("    _s%d=_s%d+dt",el.id,el.id))
			local ox,oy,oz = fmtN(el.offsetPos[1]),fmtN(el.offsetPos[2]),fmtN(el.offsetPos[3])
			if el.animPos then
				table.insert(lines,fmt("    local _t=_s%d*%s*(2*math.pi)",el.id,fmtN(el.animPosSpeed)))
				ox=fmt("%s+%s*math.sin(_t)",ox,fmtN(el.animPosAmp[1]))
				oy=fmt("%s+%s*math.sin(_t)",oy,fmtN(el.animPosAmp[2]))
				oz=fmt("%s+%s*math.sin(_t)",oz,fmtN(el.animPosAmp[3]))
			end
			local rx=fmt("math.rad(%s)",fmtN(el.offsetRot[1]))
			local ry=fmt("math.rad(%s)",fmtN(el.offsetRot[2]))
			local rz=fmt("math.rad(%s)",fmtN(el.offsetRot[3]))
			if el.animRot then
				table.insert(lines,fmt("    local _rt=_s%d*%s*(2*math.pi)",el.id,fmtN(el.animRotSpeed)))
				rx=fmt("%s+math.rad(%s)*math.sin(_rt)",rx,fmtN(el.animRotAmp[1]))
				ry=fmt("%s+math.rad(%s)*math.sin(_rt)",ry,fmtN(el.animRotAmp[2]))
				rz=fmt("%s+math.rad(%s)*math.sin(_rt)",rz,fmtN(el.animRotAmp[3]))
			end
			local targetExpr
			if el.infRot then
				table.insert(lines,fmt("    _ia%d=_ia%d+math.rad(%s)*dt",el.id,el.id,fmtN(el.infRotSpeed)))
				table.insert(lines,fmt("    local _ax=Vector3.new(%s,%s,%s)",fmtN(el.infRotAxis[1]),fmtN(el.infRotAxis[2]),fmtN(el.infRotAxis[3])))
				table.insert(lines,fmt("    local _sp=CFrame.fromAxisAngle(_ax.Magnitude>0 and _ax.Unit or Vector3.new(0,1,0),_ia%d)",el.id))
				targetExpr=fmt("pp.CFrame*CFrame.new(%s,%s,%s)*CFrame.Angles(%s,%s,%s)*_sp",ox,oy,oz,rx,ry,rz)
			else
				targetExpr=fmt("pp.CFrame*CFrame.new(%s,%s,%s)*CFrame.Angles(%s,%s,%s)",ox,oy,oz,rx,ry,rz)
			end
			table.insert(lines,fmt("    %s.CFrame=%s:Lerp(%s,math.min(1,0.15*60*dt+0.3))",vn,vn,targetExpr))
			if el.animScale and (el.type=="Part") then
				table.insert(lines,fmt("    local _sc=1+%s*math.sin(_s%d*%s*2*math.pi)",fmtN(el.animScaleAmp),el.id,fmtN(el.animScaleSpeed)))
				table.insert(lines,fmt("    %s.Size=Vector3.new(%s*_sc,%s*_sc,%s*_sc)",vn,fmtN(el.size[1]),fmtN(el.size[2]),fmtN(el.size[3])))
			elseif el.animScale and el.type=="SpecialMesh" then
				table.insert(lines,fmt("    local _sc=1+%s*math.sin(_s%d*%s*2*math.pi)",fmtN(el.animScaleAmp),el.id,fmtN(el.animScaleSpeed)))
				table.insert(lines,fmt("    sm%d.Scale=Vector3.new(%s*_sc,%s*_sc,%s*_sc)",el.id,fmtN(el.meshScale[1]),fmtN(el.meshScale[2]),fmtN(el.meshScale[3])))
			end
			table.insert(lines,fmt("  end) table.insert(_vfxConns,_c%d)",el.id))
			table.insert(lines,"end")
		end
		table.insert(lines,"")
	end

	table.insert(lines,"-- To destroy all VFX: cleanupVFX()")
	return table.concat(lines,"\n")
end

-- ═══════════════════════════════════════════════════════════════════════
--  SCREEN SCALING
-- ═══════════════════════════════════════════════════════════════════════
local BASE_W,BASE_H=1920,1080
local function calcScale()
	local vp=Camera.ViewportSize
	return math.min(vp.X/BASE_W,vp.Y/BASE_H)
end
local S=calcScale()
local function px(n) return math.max(1,math.round(n*S)) end
local function ud(s,o) return UDim.new(s,px(o)) end
local FS={tiny=math.max(8,px(10)),sm=math.max(9,px(11)),md=math.max(10,px(13))}

-- ═══════════════════════════════════════════════════════════════════════
--  GUI SETUP
-- ═══════════════════════════════════════════════════════════════════════
local old=CoreGui:FindFirstChild("VFXAnimatorGUI")
if old then old:Destroy() end

local SG=Instance.new("ScreenGui")
SG.Name="VFXAnimatorGUI"; SG.ResetOnSpawn=false
SG.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
SG.IgnoreGuiInset=true; SG.DisplayOrder=999
if not pcall(function() SG.Parent=CoreGui end) then SG.Parent=lp.PlayerGui end

local C={
	bg      =c3r(10,10,14),   panel  =c3r(18,18,25),
	elevated=c3r(26,26,36),   border =c3r(40,40,56),
	accent  =c3r(78,228,196), accent2=c3r(158,128,255),
	warn    =c3r(251,191,36), red    =c3r(248,96,96),
	green   =c3r(68,220,118), text   =c3r(212,212,228),
	muted   =c3r(105,105,135),white  =c3r(255,255,255),
	code    =c3r(120,255,190),revOn  =c3r(248,150,60),
	axisX   =c3r(255,90,90),  axisY  =c3r(90,220,90), axisZ=c3r(90,150,255),
	sub     =c3r(22,22,32),
}

local WIN_W=px(560); local WIN_H=px(720)
local TITLE_H=px(34); local TOOL_H=px(32)
local CODE_H=px(90)
local SCROLL_H=WIN_H-TITLE_H-TOOL_H-px(4)-CODE_H-px(2)
local vp=Camera.ViewportSize
local WX=math.round(vp.X*0.03); local WY=math.round(vp.Y*0.03)

-- helpers
local function make(cls,props,parent)
	local i=Instance.new(cls); for k,v in pairs(props) do i[k]=v end
	if parent then i.Parent=parent end; return i
end
local function frm(props,par)
	props.BackgroundColor3=props.BackgroundColor3 or C.panel
	props.BorderSizePixel=props.BorderSizePixel or 0
	return make("Frame",props,par)
end
local function lbl(props,par)
	props.BackgroundTransparency=props.BackgroundTransparency or 1
	props.TextColor3=props.TextColor3 or C.text
	props.Font=props.Font or Enum.Font.Gotham
	props.TextSize=props.TextSize or FS.sm
	return make("TextLabel",props,par)
end
local function btn(props,par)
	props.BackgroundColor3=props.BackgroundColor3 or C.elevated
	props.BorderSizePixel=0
	props.Font=props.Font or Enum.Font.GothamBold
	props.TextSize=props.TextSize or FS.tiny
	props.TextColor3=props.TextColor3 or C.text
	props.AutoButtonColor=false
	local b=make("TextButton",props,par)
	local orig=props.BackgroundColor3
	b.MouseEnter:Connect(function()
		TweenService:Create(b,TweenInfo.new(0.1),{BackgroundColor3=Color3.new(
			math.min(1,orig.R+0.08),math.min(1,orig.G+0.08),math.min(1,orig.B+0.08))}):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(b,TweenInfo.new(0.1),{BackgroundColor3=orig}):Play()
	end)
	return b
end
local function crn(r,par) return make("UICorner",{CornerRadius=ud(0,r)},par) end
local function pad(t,b,l,r,par)
	return make("UIPadding",{PaddingTop=ud(0,t),PaddingBottom=ud(0,b),PaddingLeft=ud(0,l),PaddingRight=ud(0,r)},par)
end
local function strk(col,th,par) return make("UIStroke",{Color=col,Thickness=th},par) end
local function listL(dir,gap,va,par)
	return make("UIListLayout",{FillDirection=dir or Enum.FillDirection.Vertical,
		Padding=ud(0,gap or 3),VerticalAlignment=va or Enum.VerticalAlignment.Top,
		SortOrder=Enum.SortOrder.LayoutOrder},par)
end

-- Main window
local Main=frm({Name="Main",Size=UDim2.fromOffset(WIN_W,WIN_H),
	Position=UDim2.fromOffset(WX,WY),BackgroundColor3=C.bg,ClipsDescendants=true},SG)
crn(9,Main); strk(C.border,1.5,Main)

-- Title
local TitleBar=frm({Size=UDim2.new(1,0,0,TITLE_H),BackgroundColor3=C.panel},Main)
crn(9,TitleBar)
frm({Size=UDim2.new(1,0,0,px(9)),Position=UDim2.new(0,0,1,-px(9)),BackgroundColor3=C.panel},TitleBar)
frm({Size=UDim2.fromOffset(px(3),TITLE_H),BackgroundColor3=C.accent},TitleBar)
lbl({Size=UDim2.new(1,-px(100),1,0),Position=UDim2.new(0,px(10),0,0),
	Text="VFX Animator",TextColor3=C.white,Font=Enum.Font.GothamBold,TextSize=FS.md,
	TextXAlignment=Enum.TextXAlignment.Left},TitleBar)
local vbadge=frm({Size=UDim2.fromOffset(px(34),px(14)),Position=UDim2.new(1,-px(90),0.5,-px(7)),BackgroundColor3=C.accent2},TitleBar)
crn(3,vbadge); lbl({Size=UDim2.new(1,0,1,0),Text="v1.0",Font=Enum.Font.GothamBold,TextSize=FS.tiny,TextColor3=C.white,BackgroundTransparency=0},vbadge)
local CloseBtn=btn({Size=UDim2.fromOffset(px(20),px(20)),Position=UDim2.new(1,-px(24),0.5,-px(10)),BackgroundColor3=C.red,Text="X",TextSize=FS.tiny,TextColor3=C.white},TitleBar)
crn(4,CloseBtn); CloseBtn.MouseButton1Click:Connect(function() Main.Visible=false end)
local MinBtn=btn({Size=UDim2.fromOffset(px(20),px(20)),Position=UDim2.new(1,-px(48),0.5,-px(10)),BackgroundColor3=C.elevated,Text="-",TextSize=FS.tiny,TextColor3=C.muted},TitleBar)
crn(4,MinBtn)
local minimised=false
MinBtn.MouseButton1Click:Connect(function()
	minimised=not minimised
	TweenService:Create(Main,TweenInfo.new(0.18,Enum.EasingStyle.Quint),{
		Size=minimised and UDim2.fromOffset(WIN_W,TITLE_H) or UDim2.fromOffset(WIN_W,WIN_H)}):Play()
end)

-- Drag
do
	local dragging,ds,sp_
	TitleBar.InputBegan:Connect(function(inp)
		if inp.UserInputType==Enum.UserInputType.MouseButton1 then dragging=true;ds=inp.Position;sp_=Main.Position end
	end)
	UserInputService.InputChanged:Connect(function(inp)
		if dragging and inp.UserInputType==Enum.UserInputType.MouseMovement then
			local d=inp.Position-ds; Main.Position=UDim2.fromOffset(sp_.X.Offset+d.X,sp_.Y.Offset+d.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(inp)
		if inp.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end
	end)
end

-- Toolbar
local Toolbar=frm({Size=UDim2.new(1,0,0,TOOL_H),Position=UDim2.new(0,0,0,TITLE_H),BackgroundColor3=C.panel},Main)
pad(px(4),px(4),px(6),px(6),Toolbar)
listL(Enum.FillDirection.Horizontal,px(3),Enum.VerticalAlignment.Center,Toolbar)
local function tbBtn(txt,bgCol,txCol)
	local b=btn({Size=UDim2.new(0,0,0,px(22)),AutomaticSize=Enum.AutomaticSize.X,BackgroundColor3=bgCol or C.elevated,
		Text=" "..txt.." ",TextSize=FS.tiny,Font=Enum.Font.GothamBold,TextColor3=txCol or C.text},Toolbar)
	pad(0,0,px(5),px(5),b); crn(4,b); return b
end
local AddPartBtn     = tbBtn("+ Part",Color3.fromRGB(14,30,48),C.accent)
local AddBeamBtn     = tbBtn("+ Beam")
local AddTrailBtn    = tbBtn("+ Trail")
local AddEmitterBtn  = tbBtn("+ Emitter")
local AddBBBtn       = tbBtn("+ Label")
local AddMeshBtn     = tbBtn("+ Mesh")
local SpawnAllBtn    = tbBtn("▶ Spawn All",Color3.fromRGB(14,48,38),C.green)
local KillAllBtn     = tbBtn("■ Kill All",Color3.fromRGB(48,14,14),C.red)
local ExportBtn      = tbBtn(">> Export",Color3.fromRGB(14,30,48),C.accent)

-- Scroll
local ScrollY=TITLE_H+TOOL_H+px(2)
local ScrollFrame=make("ScrollingFrame",{
	Size=UDim2.new(1,-px(6),0,SCROLL_H),Position=UDim2.new(0,px(3),0,ScrollY),
	BackgroundColor3=C.bg,BorderSizePixel=0,
	ScrollBarThickness=px(4),ScrollBarImageColor3=C.accent,
	CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
	ClipsDescendants=true},Main)
listL(Enum.FillDirection.Vertical,px(3),Enum.VerticalAlignment.Top,ScrollFrame)
pad(px(3),px(3),px(3),px(3),ScrollFrame)

-- Code panel
local CodeY=WIN_H-CODE_H
local CodePanel=frm({Size=UDim2.new(1,0,0,CODE_H),Position=UDim2.new(0,0,0,CodeY),BackgroundColor3=C.panel},Main)
strk(C.border,1,CodePanel)
local codeHdr=frm({Size=UDim2.new(1,0,0,px(18)),BackgroundColor3=C.elevated},CodePanel)
lbl({Size=UDim2.new(1,-px(30),1,0),Position=UDim2.new(0,px(6),0,0),
	Text="EXPORT CODE  (auto-updates every 0.5s)",TextColor3=C.muted,TextSize=FS.tiny,
	Font=Enum.Font.GothamBold,TextXAlignment=Enum.TextXAlignment.Left},codeHdr)
local CopyCodeBtn=btn({Size=UDim2.fromOffset(px(24),px(14)),Position=UDim2.new(1,-px(26),0.5,-px(7)),
	BackgroundColor3=C.accent,Text="⎘",TextSize=FS.tiny,TextColor3=C.bg},codeHdr)
crn(3,CopyCodeBtn)
local CodeLabel=lbl({Size=UDim2.new(1,-px(8),1,-px(22)),Position=UDim2.new(0,px(4),0,px(20)),
	Text="-- add elements and click Spawn All",TextColor3=C.code,Font=Enum.Font.Code,
	TextSize=FS.tiny,TextXAlignment=Enum.TextXAlignment.Left,
	TextYAlignment=Enum.TextYAlignment.Top,TextWrapped=true},CodePanel)

CopyCodeBtn.MouseButton1Click:Connect(function()
	local code=generateCode()
	if setclipboard then pcall(setclipboard,code)
	elseif syn and syn.clipboard then pcall(syn.clipboard.set,code)
	elseif writeclipboard then pcall(writeclipboard,code) end
	CopyCodeBtn.Text="✓"; task.delay(1.5,function() CopyCodeBtn.Text="⎘" end)
end)

-- ═══════════════════════════════════════════════════════════════════════
--  WIDGET HELPERS (shared with joint sections)
-- ═══════════════════════════════════════════════════════════════════════
local loCounter=0; local function nlo() loCounter=loCounter+1; return loCounter end

local function makeSliderRow(parent,labelTxt,sMin,sMax,initV,onChange,lo)
	local row=frm({Size=UDim2.new(1,-px(6),0,px(22)),BackgroundTransparency=1,LayoutOrder=lo or nlo()},parent)
	lbl({Size=UDim2.new(0,px(72),1,0),Text=labelTxt,TextColor3=C.muted,TextSize=FS.tiny,
		Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left},row)
	local range=math.max(sMax-sMin,1e-6)
	local track=frm({Size=UDim2.new(1,-px(126),0,px(4)),Position=UDim2.new(0,px(74),0.5,-px(2)),BackgroundColor3=C.border},row)
	crn(px(2),track)
	local initT=math.clamp((initV-sMin)/range,0,1)
	local fill=frm({Size=UDim2.new(initT,0,1,0),BackgroundColor3=C.accent},track)
	crn(px(2),fill)
	local thumb=frm({Size=UDim2.fromOffset(px(10),px(10)),Position=UDim2.new(initT,-px(5),0.5,-px(5)),BackgroundColor3=C.white},track)
	crn(px(5),thumb)
	local numBox=make("TextBox",{Size=UDim2.fromOffset(px(46),px(18)),Position=UDim2.new(1,-px(48),0.5,-px(9)),
		BackgroundColor3=C.sub,BorderSizePixel=0,Text=fmt("%.3f",initV),
		Font=Enum.Font.Code,TextSize=FS.tiny,TextColor3=C.accent,ClearTextOnFocus=true},row)
	crn(px(3),numBox)
	local function setVal(v,clampIt)
		local dv=clampIt and math.clamp(v,sMin,sMax) or v
		local t=math.clamp((dv-sMin)/range,0,1)
		fill.Size=UDim2.new(t,0,1,0); thumb.Position=UDim2.new(t,-px(5),0.5,-px(5))
		numBox.Text=fmt("%.3f",v); onChange(v)
	end
	local drag=false
	track.InputBegan:Connect(function(inp)
		if inp.UserInputType==Enum.UserInputType.MouseButton1 then
			drag=true
			local ap=track.AbsolutePosition;local as=track.AbsoluteSize
			setVal(sMin+math.clamp((inp.Position.X-ap.X)/as.X,0,1)*range,true)
		end
	end)
	UserInputService.InputChanged:Connect(function(inp)
		if drag and inp.UserInputType==Enum.UserInputType.MouseMovement then
			local ap=track.AbsolutePosition;local as=track.AbsoluteSize
			setVal(sMin+math.clamp((inp.Position.X-ap.X)/as.X,0,1)*range,true)
		end
	end)
	UserInputService.InputEnded:Connect(function(inp)
		if inp.UserInputType==Enum.UserInputType.MouseButton1 then drag=false end
	end)
	numBox.FocusLost:Connect(function()
		local v=tonumber(numBox.Text); if v then setVal(v,false) end
	end)
	return row,setVal
end

local function makeToggle(parent,labelTxt,initState,onChange,lo)
	local row=frm({Size=UDim2.new(1,-px(6),0,px(20)),BackgroundTransparency=1,LayoutOrder=lo or nlo()},parent)
	lbl({Size=UDim2.new(1,-px(50),1,0),Text=labelTxt,TextColor3=C.muted,TextSize=FS.tiny,
		Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left},row)
	local trk=frm({Size=UDim2.fromOffset(px(32),px(16)),Position=UDim2.new(1,-px(36),0.5,-px(8)),
		BackgroundColor3=initState and C.accent or C.border},row)
	crn(px(8),trk)
	local knob=frm({Size=UDim2.fromOffset(px(12),px(12)),
		Position=initState and UDim2.new(1,-px(14),0.5,-px(6)) or UDim2.new(0,px(2),0.5,-px(6)),
		BackgroundColor3=C.white},trk)
	crn(px(6),knob)
	local state=initState
	local function setState(v)
		state=v
		TweenService:Create(trk,TweenInfo.new(0.12),{BackgroundColor3=v and C.accent or C.border}):Play()
		TweenService:Create(knob,TweenInfo.new(0.12),{Position=v and UDim2.new(1,-px(14),0.5,-px(6)) or UDim2.new(0,px(2),0.5,-px(6))}):Play()
	end
	trk.InputBegan:Connect(function(inp)
		if inp.UserInputType==Enum.UserInputType.MouseButton1 then state=not state;setState(state);onChange(state) end
	end)
	return row,setState
end

local function makeSep(parent,txt,lo)
	local s=frm({Size=UDim2.new(1,-px(6),0,px(12)),BackgroundTransparency=1,LayoutOrder=lo or nlo()},parent)
	lbl({Size=UDim2.new(1,0,1,0),Text=txt,TextColor3=Color3.fromRGB(55,55,78),
		TextSize=math.max(7,FS.tiny-1),Font=Enum.Font.GothamBold,TextXAlignment=Enum.TextXAlignment.Left},s)
end

local function makeDropdown(parent,labelTxt,options,initVal,onChange,lo)
	local row=frm({Size=UDim2.new(1,-px(6),0,px(22)),BackgroundTransparency=1,LayoutOrder=lo or nlo()},parent)
	lbl({Size=UDim2.new(0,px(72),1,0),Text=labelTxt,TextColor3=C.muted,TextSize=FS.tiny,
		Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left},row)
	local cur=initVal
	local display=btn({Size=UDim2.new(1,-px(78),0,px(18)),Position=UDim2.new(0,px(74),0.5,-px(9)),
		BackgroundColor3=C.sub,Text=tostring(initVal).." ▾",TextSize=FS.tiny,TextColor3=C.text},row)
	crn(px(3),display)

	local dropOpen=false
	local dropFrame=frm({Size=UDim2.new(0,px(180),0,0),AutomaticSize=Enum.AutomaticSize.Y,
		Position=UDim2.new(0,px(74),1,0),BackgroundColor3=C.elevated,ZIndex=10,Visible=false},row)
	crn(px(4),dropFrame); strk(C.border,1,dropFrame)
	listL(Enum.FillDirection.Vertical,px(1),Enum.VerticalAlignment.Top,dropFrame)
	pad(px(2),px(2),px(2),px(2),dropFrame)

	for _,opt in ipairs(options) do
		local ob=btn({Size=UDim2.new(1,-px(4),0,px(18)),BackgroundColor3=C.elevated,
			Text=tostring(opt),TextSize=FS.tiny,TextColor3=C.text,ZIndex=11},dropFrame)
		crn(px(3),ob)
		ob.MouseButton1Click:Connect(function()
			cur=opt; display.Text=tostring(opt).." ▾"
			dropOpen=false; dropFrame.Visible=false; onChange(opt)
		end)
	end

	display.MouseButton1Click:Connect(function()
		dropOpen=not dropOpen; dropFrame.Visible=dropOpen
	end)
	return row
end

local function makeVec3Row(parent,labelTxt,vals,minV,maxV,onChange,lo)
	local row=frm({Size=UDim2.new(1,-px(6),0,px(22*3+6)),BackgroundTransparency=1,LayoutOrder=lo or nlo()},parent)
	lbl({Size=UDim2.new(1,0,0,px(14)),Text=labelTxt,TextColor3=C.muted,TextSize=FS.tiny,Font=Enum.Font.Gotham},row)
	local axes={"X","Y","Z"}; local axCols={C.axisX,C.axisY,C.axisZ}
	for i,ax in ipairs(axes) do
		local sub=frm({Size=UDim2.new(1,0,0,px(20)),Position=UDim2.new(0,0,0,px(14+(i-1)*22)),BackgroundTransparency=1},row)
		lbl({Size=UDim2.fromOffset(px(14),px(20)),Text=ax,TextColor3=axCols[i],TextSize=FS.tiny,Font=Enum.Font.GothamBold},sub)
		local track=frm({Size=UDim2.new(1,-px(70),0,px(4)),Position=UDim2.new(0,px(16),0.5,-px(2)),BackgroundColor3=C.border},sub)
		crn(px(2),track)
		local range=math.max(maxV-minV,1e-6)
		local initT=math.clamp((vals[i]-minV)/range,0,1)
		local fill=frm({Size=UDim2.new(initT,0,1,0),BackgroundColor3=axCols[i]},track); crn(px(2),fill)
		local thumb=frm({Size=UDim2.fromOffset(px(10),px(10)),Position=UDim2.new(initT,-px(5),0.5,-px(5)),BackgroundColor3=C.white},track); crn(px(5),thumb)
		local nb=make("TextBox",{Size=UDim2.fromOffset(px(44),px(18)),Position=UDim2.new(1,-px(46),0.5,-px(9)),
			BackgroundColor3=C.sub,BorderSizePixel=0,Text=fmt("%.2f",vals[i]),
			Font=Enum.Font.Code,TextSize=FS.tiny,TextColor3=axCols[i],ClearTextOnFocus=true},sub)
		crn(px(3),nb)
		local function setV(v,cl)
			vals[i]=cl and math.clamp(v,minV,maxV) or v
			local t=math.clamp((vals[i]-minV)/range,0,1)
			fill.Size=UDim2.new(t,0,1,0); thumb.Position=UDim2.new(t,-px(5),0.5,-px(5))
			nb.Text=fmt("%.2f",vals[i]); onChange(vals)
		end
		local drag=false
		track.InputBegan:Connect(function(inp)
			if inp.UserInputType==Enum.UserInputType.MouseButton1 then drag=true
				local ap=track.AbsolutePosition;local as=track.AbsoluteSize
				setV(minV+math.clamp((inp.Position.X-ap.X)/as.X,0,1)*range,true) end
		end)
		UserInputService.InputChanged:Connect(function(inp)
			if drag and inp.UserInputType==Enum.UserInputType.MouseMovement then
				local ap=track.AbsolutePosition;local as=track.AbsoluteSize
				setV(minV+math.clamp((inp.Position.X-ap.X)/as.X,0,1)*range,true) end
		end)
		UserInputService.InputEnded:Connect(function(inp)
			if inp.UserInputType==Enum.UserInputType.MouseButton1 then drag=false end
		end)
		nb.FocusLost:Connect(function() local v=tonumber(nb.Text);if v then setV(v,false) end end)
	end
	return row
end

local function makeColorRow(parent,labelTxt,vals,onChange,lo)
	local row=frm({Size=UDim2.new(1,-px(6),0,px(22)),BackgroundTransparency=1,LayoutOrder=lo or nlo()},parent)
	lbl({Size=UDim2.new(0,px(72),1,0),Text=labelTxt,TextColor3=C.muted,TextSize=FS.tiny,
		Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left},row)
	local swatch=frm({Size=UDim2.fromOffset(px(22),px(16)),Position=UDim2.new(0,px(74),0.5,-px(8)),
		BackgroundColor3=c3(vals)},row); crn(px(3),swatch)
	-- R G B sliders
	local axes={"R","G","B"}; local axCols={C.axisX,C.axisY,C.axisZ}
	for i=1,3 do
		local track=frm({Size=UDim2.new(1,-px(108),0,px(3)),Position=UDim2.new(0,px(100)+(i-1)*px(0),0,px(3+(i-1)*6)),BackgroundColor3=C.border},row)
		-- simplified: text inputs for RGB
	end
	-- Just show R,G,B text boxes
	for i=1,3 do
		local nb=make("TextBox",{Size=UDim2.fromOffset(px(34),px(18)),
			Position=UDim2.new(0,px(100)+(i-1)*px(38),0.5,-px(9)),
			BackgroundColor3=C.sub,BorderSizePixel=0,Text=tostring(math.round(vals[i])),
			Font=Enum.Font.Code,TextSize=FS.tiny,TextColor3=axCols[i],ClearTextOnFocus=true},row)
		crn(px(3),nb)
		nb.FocusLost:Connect(function()
			local v=tonumber(nb.Text)
			if v then vals[i]=math.clamp(math.round(v),0,255); swatch.BackgroundColor3=c3(vals); onChange(vals) end
		end)
	end
	lbl({Size=UDim2.fromOffset(px(10),px(22)),Position=UDim2.new(0,px(98),0,0),
		Text="R",TextColor3=C.axisX,TextSize=FS.tiny,Font=Enum.Font.GothamBold},row)
	lbl({Size=UDim2.fromOffset(px(10),px(22)),Position=UDim2.new(0,px(136),0,0),
		Text="G",TextColor3=C.axisY,TextSize=FS.tiny,Font=Enum.Font.GothamBold},row)
	lbl({Size=UDim2.fromOffset(px(10),px(22)),Position=UDim2.new(0,px(174),0,0),
		Text="B",TextColor3=C.axisZ,TextSize=FS.tiny,Font=Enum.Font.GothamBold},row)
	return row
end

-- ═══════════════════════════════════════════════════════════════════════
--  BUILD ELEMENT SECTION
-- ═══════════════════════════════════════════════════════════════════════
local elementSections={}

local function buildElementSection(el)
	local collapsed=false

	local header=frm({Size=UDim2.new(1,-px(6),0,px(28)),BackgroundColor3=C.elevated,LayoutOrder=nlo()},ScrollFrame)
	crn(px(5),header); strk(C.border,1,header)

	local arrowL=lbl({Size=UDim2.fromOffset(px(16),px(28)),Position=UDim2.new(0,px(5),0,0),
		Text="▼",TextColor3=C.accent,TextSize=FS.tiny,Font=Enum.Font.GothamBold},header)
	local typeBadge=frm({Size=UDim2.fromOffset(px(46),px(14)),Position=UDim2.new(0,px(22),0.5,-px(7)),BackgroundColor3=C.accent2},header)
	crn(px(3),typeBadge); lbl({Size=UDim2.new(1,0,1,0),Text=el.type,Font=Enum.Font.GothamBold,TextSize=FS.tiny,TextColor3=C.white,BackgroundTransparency=0},typeBadge)
	lbl({Size=UDim2.new(1,-px(160),1,0),Position=UDim2.new(0,px(72),0,0),
		Text=el.name,TextColor3=C.text,TextSize=FS.sm,Font=Enum.Font.GothamBold,
		TextXAlignment=Enum.TextXAlignment.Left},header)

	local enBtn=btn({Size=UDim2.fromOffset(px(38),px(15)),Position=UDim2.new(1,-px(80),0.5,-px(7)),
		BackgroundColor3=el.enabled and Color3.fromRGB(16,50,38) or C.elevated,
		Text=el.enabled and "ON" or "OFF",TextSize=FS.tiny,Font=Enum.Font.GothamBold,
		TextColor3=el.enabled and C.green or C.muted},header)
	crn(px(3),enBtn)
	enBtn.MouseButton1Click:Connect(function()
		el.enabled=not el.enabled
		enBtn.BackgroundColor3=el.enabled and Color3.fromRGB(16,50,38) or C.elevated
		enBtn.Text=el.enabled and "ON" or "OFF"; enBtn.TextColor3=el.enabled and C.green or C.muted
	end)

	local spawnBtn=btn({Size=UDim2.fromOffset(px(42),px(15)),Position=UDim2.new(1,-px(36),0.5,-px(7)),
		BackgroundColor3=Color3.fromRGB(14,48,38),Text="▶ Run",TextSize=FS.tiny,TextColor3=C.green},header)
	crn(px(3),spawnBtn); spawnBtn.MouseButton1Click:Connect(function() spawnElement(el) end)

	local body=frm({Size=UDim2.new(1,-px(6),0,0),AutomaticSize=Enum.AutomaticSize.Y,
		BackgroundColor3=C.panel,LayoutOrder=nlo()},ScrollFrame)
	crn(px(5),body)
	listL(Enum.FillDirection.Vertical,px(2),Enum.VerticalAlignment.Top,body)
	pad(px(5),px(6),px(5),px(5),body)

	header.InputBegan:Connect(function(inp)
		if inp.UserInputType==Enum.UserInputType.MouseButton1 then
			collapsed=not collapsed; body.Visible=not collapsed
			arrowL.Text=collapsed and "▶" or "▼"
		end
	end)

	-- NAME
	makeSep(body,"── NAME / PARENT")
	local nameRow=frm({Size=UDim2.new(1,-px(6),0,px(22)),BackgroundTransparency=1,LayoutOrder=nlo()},body)
	lbl({Size=UDim2.new(0,px(72),1,0),Text="Name",TextColor3=C.muted,TextSize=FS.tiny,
		Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left},nameRow)
	local nameBox=make("TextBox",{Size=UDim2.new(1,-px(78),0,px(18)),Position=UDim2.new(0,px(74),0.5,-px(9)),
		BackgroundColor3=C.sub,BorderSizePixel=0,Text=el.name,
		Font=Enum.Font.Gotham,TextSize=FS.tiny,TextColor3=C.text,ClearTextOnFocus=false},nameRow)
	crn(px(3),nameBox)
	nameBox.FocusLost:Connect(function() el.name=nameBox.Text end)

	-- PARENT PART dropdown
	makeDropdown(body,"Parent Part",BODY_PARTS,el.parentPart,function(v) el.parentPart=v end)

	-- TYPE-SPECIFIC PROPERTIES
	if el.type=="Part" or el.type=="SpecialMesh" then
		makeSep(body,"── APPEARANCE")
		makeColorRow(body,"Color",el.color,function(v) el.color=v end)
		makeDropdown(body,"Material",{"Neon","SmoothPlastic","Glass","Metal","ForceField","Plastic","Wood","Concrete","Granite","Marble","Sand","Fabric","Ice"},el.material,function(v) el.material=v end)
		makeSliderRow(body,"Transparency",0,0.99,el.transparency,function(v) el.transparency=v end)
		makeToggle(body,"Cast Shadow",el.castShadow,function(v) el.castShadow=v end)
		if el.type=="Part" then
			makeSep(body,"── SHAPE / SIZE")
			makeDropdown(body,"Shape",{"Ball","Block","Cylinder","Wedge","CornerWedge"},el.shape,function(v) el.shape=v end)
			makeVec3Row(body,"Size",el.size,0.05,20,function(v) el.size=v end)
		else
			makeSep(body,"── MESH")
			makeDropdown(body,"Mesh Type",{"Sphere","Cylinder","Brick","FileMesh","Head","Torso","Wedge"},el.meshType,function(v) el.meshType=v end)
			makeVec3Row(body,"Scale",el.meshScale,0.1,20,function(v) el.meshScale=v end)
			local mIdRow=frm({Size=UDim2.new(1,-px(6),0,px(22)),BackgroundTransparency=1,LayoutOrder=nlo()},body)
			lbl({Size=UDim2.new(0,px(72),1,0),Text="Mesh ID",TextColor3=C.muted,TextSize=FS.tiny,Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left},mIdRow)
			local mib=make("TextBox",{Size=UDim2.new(1,-px(78),0,px(18)),Position=UDim2.new(0,px(74),0.5,-px(9)),BackgroundColor3=C.sub,BorderSizePixel=0,Text=el.meshId,Font=Enum.Font.Code,TextSize=FS.tiny,TextColor3=C.accent,ClearTextOnFocus=false,PlaceholderText="rbxassetid://..."},mIdRow)
			crn(px(3),mib); mib.FocusLost:Connect(function() el.meshId=mib.Text end)
			local txRow=frm({Size=UDim2.new(1,-px(6),0,px(22)),BackgroundTransparency=1,LayoutOrder=nlo()},body)
			lbl({Size=UDim2.new(0,px(72),1,0),Text="Texture ID",TextColor3=C.muted,TextSize=FS.tiny,Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left},txRow)
			local txb=make("TextBox",{Size=UDim2.new(1,-px(78),0,px(18)),Position=UDim2.new(0,px(74),0.5,-px(9)),BackgroundColor3=C.sub,BorderSizePixel=0,Text=el.textureId,Font=Enum.Font.Code,TextSize=FS.tiny,TextColor3=C.accent,ClearTextOnFocus=false,PlaceholderText="rbxassetid://..."},txRow)
			crn(px(3),txb); txb.FocusLost:Connect(function() el.textureId=txb.Text end)
		end
	elseif el.type=="Beam" then
		makeSep(body,"── BEAM")
		makeColorRow(body,"Color start",el.color0,function(v) el.color0=v end)
		makeColorRow(body,"Color end",el.color1,function(v) el.color1=v end)
		makeSliderRow(body,"Width start",0,5,el.width0,function(v) el.width0=v end)
		makeSliderRow(body,"Width end",0,5,el.width1,function(v) el.width1=v end)
		makeSliderRow(body,"Length",0.5,30,el.beamLength,function(v) el.beamLength=v end)
		makeSliderRow(body,"Segments",2,50,el.segments,function(v) el.segments=math.round(v) end)
		makeSliderRow(body,"Light Infl.",0,1,el.lightInfluence,function(v) el.lightInfluence=v end)
		makeToggle(body,"Face Camera",el.faceCamera,function(v) el.faceCamera=v end)
	elseif el.type=="Trail" then
		makeSep(body,"── TRAIL")
		makeColorRow(body,"Color start",el.color0,function(v) el.color0=v end)
		makeColorRow(body,"Color end",el.color1,function(v) el.color1=v end)
		makeSliderRow(body,"Lifetime",0.05,8,el.trailLifetime,function(v) el.trailLifetime=v end)
		makeSliderRow(body,"Width",0.05,5,el.trailWidth,function(v) el.trailWidth=v end)
		makeSliderRow(body,"Min Distance",0,2,el.trailMinDist,function(v) el.trailMinDist=v end)
	elseif el.type=="ParticleEmitter" then
		makeSep(body,"── EMITTER")
		makeColorRow(body,"Color",el.peColor,function(v) el.peColor=v end)
		makeSliderRow(body,"Rate",1,500,el.peRate,function(v) el.peRate=math.round(v) end)
		makeSliderRow(body,"Speed min",0,50,el.peSpeedMin,function(v) el.peSpeedMin=v end)
		makeSliderRow(body,"Speed max",0,50,el.peSpeedMax,function(v) el.peSpeedMax=v end)
		makeSliderRow(body,"Lifetime min",0.05,10,el.peLifetimeMin,function(v) el.peLifetimeMin=v end)
		makeSliderRow(body,"Lifetime max",0.05,10,el.peLifetimeMax,function(v) el.peLifetimeMax=v end)
		makeSliderRow(body,"Size",0.05,5,el.peSize,function(v) el.peSize=v end)
		makeSliderRow(body,"Spread",0,180,el.peSpread,function(v) el.peSpread=v end)
	elseif el.type=="BillboardGui" then
		makeSep(body,"── BILLBOARD")
		local txtRow=frm({Size=UDim2.new(1,-px(6),0,px(22)),BackgroundTransparency=1,LayoutOrder=nlo()},body)
		lbl({Size=UDim2.new(0,px(72),1,0),Text="Text",TextColor3=C.muted,TextSize=FS.tiny,Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left},txtRow)
		local tb=make("TextBox",{Size=UDim2.new(1,-px(78),0,px(18)),Position=UDim2.new(0,px(74),0.5,-px(9)),BackgroundColor3=C.sub,BorderSizePixel=0,Text=el.bbText,Font=Enum.Font.Gotham,TextSize=FS.tiny,TextColor3=C.text,ClearTextOnFocus=false},txtRow)
		crn(px(3),tb); tb.FocusLost:Connect(function() el.bbText=tb.Text end)
		makeColorRow(body,"Text Color",el.bbTextColor,function(v) el.bbTextColor=v end)
		makeColorRow(body,"Bg Color",el.bbBgColor,function(v) el.bbBgColor=v end)
		makeSliderRow(body,"Bg Trans.",0,1,el.bbBgTrans,function(v) el.bbBgTrans=v end)
		makeSliderRow(body,"Size X px",20,400,el.bbSizeX,function(v) el.bbSizeX=math.round(v) end)
		makeSliderRow(body,"Size Y px",10,200,el.bbSizeY,function(v) el.bbSizeY=math.round(v) end)
		makeSliderRow(body,"Offset Y",0,10,el.bbOffsetY,function(v) el.bbOffsetY=v end)
		makeToggle(body,"Always On Top",el.bbAlwaysOnTop,function(v) el.bbAlwaysOnTop=v end)
	end

	-- TRANSFORM
	makeSep(body,"── BASE TRANSFORM")
	makeVec3Row(body,"Offset Pos",el.offsetPos,-15,15,function(v) el.offsetPos=v end)
	makeVec3Row(body,"Offset Rot°",el.offsetRot,-180,180,function(v) el.offsetRot=v end)

	-- LERP POSITION ANIM
	makeSep(body,"── LERP POSITION (sine bob)")
	makeToggle(body,"Enable",el.animPos,function(v) el.animPos=v end)
	makeVec3Row(body,"Amplitude",el.animPosAmp,-5,5,function(v) el.animPosAmp=v end)
	makeSliderRow(body,"Speed (Hz)",0.1,10,el.animPosSpeed,function(v) el.animPosSpeed=v end)

	-- LERP ROTATION ANIM
	makeSep(body,"── LERP ROTATION (sine oscillate)")
	makeToggle(body,"Enable",el.animRot,function(v) el.animRot=v end)
	makeVec3Row(body,"Amplitude°",el.animRotAmp,-180,180,function(v) el.animRotAmp=v end)
	makeSliderRow(body,"Speed (Hz)",0.1,10,el.animRotSpeed,function(v) el.animRotSpeed=v end)

	-- INFINITE SPIN
	makeSep(body,"── INFINITE SPIN (accumulates)")
	makeToggle(body,"Enable",el.infRot,function(v) el.infRot=v end)
	makeVec3Row(body,"Spin Axis",el.infRotAxis,-1,1,function(v) el.infRotAxis=v end)
	makeSliderRow(body,"Speed °/s",5,720,el.infRotSpeed,function(v) el.infRotSpeed=v end)

	-- SCALE PULSE
	if el.type=="Part" or el.type=="SpecialMesh" then
		makeSep(body,"── SCALE PULSE")
		makeToggle(body,"Enable",el.animScale,function(v) el.animScale=v end)
		makeSliderRow(body,"Amplitude",0,2,el.animScaleAmp,function(v) el.animScaleAmp=v end)
		makeSliderRow(body,"Speed (Hz)",0.1,10,el.animScaleSpeed,function(v) el.animScaleSpeed=v end)
	end

	-- ACTIONS ROW
	makeSep(body,"── ACTIONS")
	local actRow=frm({Size=UDim2.new(1,-px(6),0,px(24)),BackgroundTransparency=1,LayoutOrder=nlo()},body)
	listL(Enum.FillDirection.Horizontal,px(4),Enum.VerticalAlignment.Center,actRow)
	local function aBtn(txt,bgC,txC)
		local b=btn({Size=UDim2.new(0,0,0,px(20)),AutomaticSize=Enum.AutomaticSize.X,
			BackgroundColor3=bgC or C.elevated,Text=" "..txt.." ",TextSize=FS.tiny,TextColor3=txC or C.text},actRow)
		pad(0,0,px(5),px(5),b); crn(px(3),b); return b
	end
	local spawnSingleBtn=aBtn("▶ Spawn",Color3.fromRGB(14,48,38),C.green)
	local killSingleBtn=aBtn("■ Kill",Color3.fromRGB(48,14,14),C.red)
	local duplicateBtn=aBtn("⧉ Dupe",C.elevated,C.accent2)
	local removeBtn=aBtn("✕ Remove",Color3.fromRGB(48,14,14),C.red)

	spawnSingleBtn.MouseButton1Click:Connect(function() spawnElement(el) end)
	killSingleBtn.MouseButton1Click:Connect(function() destroyElement(el) end)
	duplicateBtn.MouseButton1Click:Connect(function()
		-- deep copy element
		local newEl=newElement(el.type)
		for k,v in pairs(el) do
			if k~="id" and k~="_instances" and k~="_infAngle" and k~="_sine" then
				if type(v)=="table" then
					local t={}; for i,w in ipairs(v) do t[i]=w end; newEl[k]=t
				else newEl[k]=v end
			end
		end
		newEl.name=el.name.." (copy)"
		table.insert(vfxList,newEl)
		buildElementSection(newEl)
	end)
	removeBtn.MouseButton1Click:Connect(function()
		destroyElement(el)
		for i,e in ipairs(vfxList) do if e.id==el.id then table.remove(vfxList,i); break end end
		if elementSections[el.id] then
			elementSections[el.id].header:Destroy()
			elementSections[el.id].body:Destroy()
			elementSections[el.id]=nil
		end
	end)

	elementSections[el.id]={header=header,body=body}
end

-- ═══════════════════════════════════════════════════════════════════════
--  TOOLBAR ACTIONS
-- ═══════════════════════════════════════════════════════════════════════
local function addAndBuild(type)
	local el=newElement(type); table.insert(vfxList,el); buildElementSection(el)
end

AddPartBtn.MouseButton1Click:Connect(function()    addAndBuild("Part")            end)
AddBeamBtn.MouseButton1Click:Connect(function()    addAndBuild("Beam")            end)
AddTrailBtn.MouseButton1Click:Connect(function()   addAndBuild("Trail")           end)
AddEmitterBtn.MouseButton1Click:Connect(function() addAndBuild("ParticleEmitter") end)
AddBBBtn.MouseButton1Click:Connect(function()      addAndBuild("BillboardGui")    end)
AddMeshBtn.MouseButton1Click:Connect(function()    addAndBuild("SpecialMesh")     end)

SpawnAllBtn.MouseButton1Click:Connect(function()
	for _,el in ipairs(vfxList) do spawnElement(el) end
end)

KillAllBtn.MouseButton1Click:Connect(function()
	for _,el in ipairs(vfxList) do destroyElement(el) end
end)

ExportBtn.MouseButton1Click:Connect(function()
	CodeLabel.Text=generateCode()
	if setclipboard then pcall(setclipboard,generateCode())
	elseif syn and syn.clipboard then pcall(syn.clipboard.set,generateCode()) end
	ExportBtn.Text=" ✓ Copied "; task.delay(2,function() ExportBtn.Text=" >> Export " end)
end)

-- ═══════════════════════════════════════════════════════════════════════
--  LIVE CODE PREVIEW
-- ═══════════════════════════════════════════════════════════════════════
local previewTimer=0
RunService.RenderStepped:Connect(function(dt)
	previewTimer=previewTimer+dt
	if previewTimer>=0.5 then
		previewTimer=0
		local lines,i={},0
		for line in generateCode():gmatch("[^\n]+") do
			i=i+1; lines[i]=line; if i>=5 then break end
		end
		CodeLabel.Text=i>0 and table.concat(lines,"\n")..(#vfxList>0 and "\n..." or "") or "-- add elements above"
	end
end)

-- ═══════════════════════════════════════════════════════════════════════
--  RESPAWN CLEANUP
-- ═══════════════════════════════════════════════════════════════════════
lp.CharacterAdded:Connect(function(newChar)
	char=newChar
	for _,el in ipairs(vfxList) do destroyElement(el) end
end)
