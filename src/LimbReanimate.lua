--[[
	LimbReanimate
	Standalone limb reanimator for Roblox exploit environments.

	Limb-reanimation logic derived from the "Uhhhhhh" script by STEVETHEREALONE
	(LimbReanimator only). Everything else here -- UI, control, packaging -- is new.

	Repo: https://github.com/HiddenProto/LimbReanimate
]]

local SCRIPT_VERSION = "1.11.1"

--==============================================================================
-- 0. SINGLE INSTANCE GUARD
--==============================================================================

if _G.LimbReanimate and _G.LimbReanimate.Unload then
	pcall(_G.LimbReanimate.Unload)
end
local App = {}
App.Version = SCRIPT_VERSION
_G.LimbReanimate = App

--==============================================================================
-- 1. SERVICES
--==============================================================================

local cloneref = cloneref or function(o) return o end

local Players          = cloneref(game:GetService("Players"))
local RunService       = cloneref(game:GetService("RunService"))
local UserInputService = cloneref(game:GetService("UserInputService"))
local Debris           = cloneref(game:GetService("Debris"))
local Workspace        = cloneref(game:GetService("Workspace"))
local CoreGui          = cloneref(game:GetService("CoreGui"))

local Player = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- IsDescendantOf compares instance identity, and a cloneref'd service is not
-- guaranteed to compare equal to the real one on every executor. If it does
-- not, every joint looks detached and none are ever driven. The reference
-- script uses the raw global here, so we do too.
local RawWorkspace = workspace

--==============================================================================
-- 2. EXECUTOR CAPABILITY SHIM
--==============================================================================

local genv = (getgenv and getgenv()) or getfenv()

local Env = {}
Env.sethiddenproperty = rawget(genv, "sethiddenproperty")
Env.gethiddenproperty = rawget(genv, "gethiddenproperty")
Env.firetouchinterest = rawget(genv, "firetouchinterest")
Env.replicatesignal   = rawget(genv, "replicatesignal")
Env.gethui            = rawget(genv, "gethui")
local setscriptable   = rawget(genv, "setscriptable")

if not Env.sethiddenproperty and setscriptable then
	Env.sethiddenproperty = function(inst, prop, val)
		local old = setscriptable(inst, prop, true)
		inst[prop] = val
		setscriptable(inst, prop, old)
	end
end

App.HasHiddenProps = Env.sethiddenproperty ~= nil

local function SetHidden(inst, prop, val)
	if not Env.sethiddenproperty then return false end
	return (pcall(Env.sethiddenproperty, inst, prop, val))
end

--==============================================================================
-- 3. UTIL
--==============================================================================

local Util = {}

-- Cached destroy height. Read BEFORE anything NaNs it; a NaN read means another
-- script got here first, so fall back to the engine default.
local FallenPartsDestroyHeight = Workspace.FallenPartsDestroyHeight
if FallenPartsDestroyHeight ~= FallenPartsDestroyHeight then
	FallenPartsDestroyHeight = -500
end
App.FallenPartsDestroyHeight = FallenPartsDestroyHeight

function Util.Instance(class, parent)
	local inst = Instance.new(class)
	if parent then inst.Parent = parent end
	return inst
end

-- Ties a connection's lifetime to an instance: when the instance leaves the
-- tree for good, the connection is dropped. Prevents leaked render hooks.
function Util.LinkDestroyI2C(inst, conn)
	local link
	link = inst.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			task.defer(function()
				if inst.Parent == nil then
					conn:Disconnect()
					link:Disconnect()
				end
			end)
		end
	end)
	return conn
end

function Util.ScaleCFrame(cf, scale)
	return cf.Rotation + cf.Position * scale
end

--[[
	THE CORE WRITE.

	Motor6D.Transform is an unbounded relative CFrame -- the engine never clamps
	it. Writing it drives the joint on OUR client only. To make the server (and
	every other client) see it, we write the two hidden replicated fields the
	engine itself uses for Motor6D replication:

		ReplicateCurrentOffset6D -- the positional half
		ReplicateCurrentAngle6D  -- the rotational half, as axis * angle

	MaxVelocity = 9e9 makes the motor snap to the new angle instead of easing
	toward it, which matters because the root joint's transform can be tens of
	thousands of studs long.
]]
function Util.SetMotor6DTransform(motor, transform)
	motor.MaxVelocity = 9e9

	local _, _, zangle = transform:ToEulerAngles(Enum.RotationOrder.ZYX)
	motor:SetDesiredAngle(zangle)

	local axis, angle = transform:ToAxisAngle()
	SetHidden(motor, "ReplicateCurrentOffset6D", transform.Position)
	SetHidden(motor, "ReplicateCurrentAngle6D", axis * angle)

	-- Local-only fallback so the rig still looks right to you without
	-- hidden-property support. Does not replicate.
	if not App.HasHiddenProps then
		pcall(function() motor.Transform = transform end)
	end
end

-- offset = where we want Part1 to sit, expressed in Part0's object space.
function Util.SetMotor6DOffset(motor, offset)
	Util.SetMotor6DTransform(motor, motor.C0:Inverse() * offset * motor.C1)
end

function Util.ShowPartHitbox(part)
	if not part then return end
	local w = Instance.new("WireframeHandleAdornment")
	w.Adornee = part
	w.AlwaysOnTop = true
	w.Color3 = Color3.new(0, 1, 0)
	w.ZIndex = 5
	local h = part.Size * 0.5
	local c = {
		Vector3.new( h.X,  h.Y,  h.Z), Vector3.new(-h.X,  h.Y,  h.Z),
		Vector3.new(-h.X, -h.Y,  h.Z), Vector3.new( h.X, -h.Y,  h.Z),
		Vector3.new( h.X,  h.Y, -h.Z), Vector3.new(-h.X,  h.Y, -h.Z),
		Vector3.new(-h.X, -h.Y, -h.Z), Vector3.new( h.X, -h.Y, -h.Z),
	}
	local edges = {
		{1,2},{2,3},{3,4},{4,1},
		{5,6},{6,7},{7,8},{8,5},
		{1,5},{2,6},{3,7},{4,8},
	}
	for _, e in edges do
		w:AddLine(c[e[1]], c[e[2]])
	end
	w.Parent = part
	Debris:AddItem(w, 5)
end

-- Resolves a fling target down to a BasePart.
function Util.PredictionFlingPart(target)
	if typeof(target) == "Instance" then
		if target:IsA("Model") then
			target = target:FindFirstChild("HumanoidRootPart")
				or target.PrimaryPart
				or target:FindFirstChildWhichIsA("BasePart")
		end
		if target and target:IsA("BasePart") then
			return target
		end
	end
	return nil
end

-- Returns (whereToPutTheRoot, done). Leads the target by its own velocity so
-- the root part meets it instead of trailing behind.
function Util.PredictionFling(target)
	if typeof(target) == "Instance" then
		local part = Util.PredictionFlingPart(target)
		if part then
			if not part:IsDescendantOf(Workspace) then
				return CFrame.identity, true
			end
			local t = os.clock()
			local t2 = math.sin(t * 15) + 1
			local cf = part.CFrame * CFrame.Angles(1.57, 0, 0)
			cf += part.AssemblyLinearVelocity * t2
				+ Vector3.new(0, -Workspace.Gravity * 0.5 * t2 * t2 + math.sin(t * 60), 0)
			if cf.Position.Y < part.Position.Y - 1 then
				cf = cf.Rotation + Vector3.new(cf.Position.X, part.Position.Y - 1, cf.Position.Z)
			end
			local oldpos = part:GetAttribute("_LR_LastPosition")
			if not oldpos then
				oldpos = part.Position
				part:SetAttribute("_LR_LastPosition", oldpos)
			end
			if (part.Position - oldpos).Magnitude > 200 then
				part:SetAttribute("_LR_LastPosition", nil)
				return cf, true
			end
			return cf, false
		end
	end
	if typeof(target) == "CFrame" then return target, false end
	if typeof(target) == "Vector3" then return CFrame.new(target), false end
	return CFrame.identity, true
end

local RIGHTGRIP_C0 = CFrame.new(0, -1, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0)

--==============================================================================
-- 4. LIMB MAP (vendored from Uhhhhhh content/d_limbmap.lua)
--
--   Part0/Part1   : joint identity on the REAL character
--   RPart0/RPart1 : which fake-rig parts drive it ("ROOT" = real HumanoidRootPart)
--   Type 1        : R6  -- straight object-space copy
--   Type 2        : R15 -- copy with C0/C1 attachment offsets applied
--==============================================================================

local function MakeLimbMap()
	return {
		-- R6
		{ Part0 = "HumanoidRootPart", Part1 = "Torso",     Type = 1, RPart0 = "ROOT",  RPart1 = "Torso" },
		{ Part0 = "Torso",            Part1 = "Head",      Type = 1, RPart0 = "Torso", RPart1 = "Head" },
		{ Part0 = "Torso",            Part1 = "Left Arm",  Type = 1, RPart0 = "Torso", RPart1 = "Left Arm" },
		{ Part0 = "Torso",            Part1 = "Right Arm", Type = 1, RPart0 = "Torso", RPart1 = "Right Arm" },
		{ Part0 = "Torso",            Part1 = "Left Leg",  Type = 1, RPart0 = "Torso", RPart1 = "Left Leg" },
		{ Part0 = "Torso",            Part1 = "Right Leg", Type = 1, RPart0 = "Torso", RPart1 = "Right Leg" },
		-- R15
		{ Part0 = "HumanoidRootPart", Part1 = "LowerTorso",    Type = 2, RPart0 = "ROOT",  RPart1 = "Torso",
		  C0 = Vector3.new(0, 0, 0),     C1 = Vector3.new(0, 0, 0) },
		{ Part0 = "UpperTorso",       Part1 = "Head",          Type = 2, RPart0 = "Torso", RPart1 = "Head",
		  C0 = Vector3.new(0, 1, 0),     C1 = Vector3.new(0, -0.5, 0) },
		{ Part0 = "UpperTorso",       Part1 = "LeftUpperArm",  Type = 2, RPart0 = "Torso", RPart1 = "Left Arm",
		  C0 = Vector3.new(-1, 0.5, 0),  C1 = Vector3.new(0.5, 0.5, 0) },
		{ Part0 = "UpperTorso",       Part1 = "RightUpperArm", Type = 2, RPart0 = "Torso", RPart1 = "Right Arm",
		  C0 = Vector3.new(1, 0.5, 0),   C1 = Vector3.new(-0.5, 0.5, 0) },
		{ Part0 = "LowerTorso",       Part1 = "LeftUpperLeg",  Type = 2, RPart0 = "Torso", RPart1 = "Left Leg",
		  C0 = Vector3.new(-0.5, -1, 0), C1 = Vector3.new(0, 1, 0) },
		{ Part0 = "LowerTorso",       Part1 = "RightUpperLeg", Type = 2, RPart0 = "Torso", RPart1 = "Right Leg",
		  C0 = Vector3.new(0.5, -1, 0),  C1 = Vector3.new(0, 1, 0) },
	}
end

--==============================================================================
-- 5. FAKE RIG
--
-- A locally-created R6 model with a real Humanoid. It is what you actually
-- walk around as. Nobody else can see it -- it exists only on your client.
-- Its part CFrames are the SOURCE POSES the real joints get driven to.
--==============================================================================

local function BuildFakeRig()
	local char = Instance.new("Model")
	char.Name = "LimbReanimate_Rig"

	local ff = Util.Instance("ForceField", char)
	ff.Visible = false

	local hum = Util.Instance("Humanoid", char)
	hum.Name = "Humanoid"
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.RequiresNeck = false
	hum.BreakJointsOnDeath = false
	hum.UseJumpPower = true
	hum.WalkSpeed = 16
	hum.JumpPower = 50
	hum.Health = 100
	hum.MaxHealth = 100
	hum.MaxSlopeAngle = 89
	hum.HipHeight = 0
	hum.AutoRotate = true
	hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)

	local function makePart(name, size, pos)
		local part = Util.Instance("Part", char)
		part.Name = name
		part.Size = size
		part.Position = pos
		part.Anchored = false
		part.CanCollide = false
		part.Transparency = 1
		part.CastShadow = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.LeftSurface = Enum.SurfaceType.Smooth
		part.RightSurface = Enum.SurfaceType.Smooth
		part.FrontSurface = Enum.SurfaceType.Smooth
		part.BackSurface = Enum.SurfaceType.Smooth
		return part
	end

	local root     = makePart("HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.new(0, 0, 0))
	local torso    = makePart("Torso",            Vector3.new(2, 2, 1), Vector3.new(0, 0, 0))
	local head     = makePart("Head",             Vector3.new(2, 1, 1), Vector3.new(0, 1.5, 0))
	local leftArm  = makePart("Left Arm",         Vector3.new(1, 2, 1), Vector3.new(-1.5, 0, 0))
	local rightArm = makePart("Right Arm",        Vector3.new(1, 2, 1), Vector3.new(1.5, 0, 0))
	local leftLeg  = makePart("Left Leg",         Vector3.new(1, 2, 1), Vector3.new(-0.5, -2, 0))
	local rightLeg = makePart("Right Leg",        Vector3.new(1, 2, 1), Vector3.new(0.5, -2, 0))

	local function makeMotor(name, p0, p1, c0, c1)
		local motor = Instance.new("Motor6D")
		motor.Name = name
		motor.Part0 = p0
		motor.Part1 = p1
		motor.C0 = c0
		motor.C1 = c1
		motor.MaxVelocity = 0
		motor.Parent = p0
		-- Keeps the rig's own animation offsets correct if it ever gets scaled.
		Util.LinkDestroyI2C(motor, RunService.PreRender:Connect(function()
			local scale = char:GetScale()
			motor:SetAttribute("Transform", Util.ScaleCFrame(motor.Transform, 1 / scale))
			motor.Transform = Util.ScaleCFrame(motor:GetAttribute("Transform") or CFrame.identity, scale)
		end))
		return motor
	end

	makeMotor("RootJoint", root, torso,
		CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0),
		CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0))
	makeMotor("Neck", torso, head,
		CFrame.new(0, 1, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0),
		CFrame.new(0, -0.5, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0))
	makeMotor("Left Shoulder", torso, leftArm,
		CFrame.new(-1, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0),
		CFrame.new(0.5, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0))
	makeMotor("Right Shoulder", torso, rightArm,
		CFrame.new(1, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0),
		CFrame.new(-0.5, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0))
	makeMotor("Left Hip", torso, leftLeg,
		CFrame.new(-1, -1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0),
		CFrame.new(-0.5, 1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0))
	makeMotor("Right Hip", torso, rightLeg,
		CFrame.new(1, -1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0),
		CFrame.new(0.5, 1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0))

	local mesh = Util.Instance("SpecialMesh", head)
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = Vector3.new(1.25, 1.25, 1.25)

	char.PrimaryPart = root
	return char
end

--[[
	ORIGIN RIG.

	A clone of your real character, used as the rig instead of the built-in R6
	skeleton. Because it is structurally identical to the thing being puppeted,
	the limb mapping collapses to identity -- joint X drives joint X by name --
	and R6/R15 stops mattering.

	Everything that could animate it or talk to the server is stripped: scripts,
	Animators, tools. What is left is a bare posable assembly with a Humanoid so
	it can still walk. Nothing poses its limbs unless you do.
]]
local function BuildOriginRig()
	local src = Player.Character
	if not src then return nil, "no character to clone" end

	local ok, clone = pcall(function()
		-- Archivable is false on live character parts often enough to matter.
		local restore = {}
		for _, d in src:GetDescendants() do
			if not d.Archivable then
				table.insert(restore, d)
				d.Archivable = true
			end
		end
		local wasArchivable = src.Archivable
		src.Archivable = true
		local c = src:Clone()
		src.Archivable = wasArchivable
		for _, d in restore do
			d.Archivable = false
		end
		return c
	end)
	if not ok or not clone then
		return nil, "clone failed: " .. tostring(clone)
	end

	clone.Name = "LimbReanimate_OriginRig"

	-- Scripts and tools go. The Animator STAYS: an origin rig is meant to pass
	-- for a real character, so anything that wants to animate it -- the built-in
	-- driver, or an external animation script written against a reanimator --
	-- has something to load onto.
	for _, d in clone:GetDescendants() do
		if d:IsA("BaseScript") or d:IsA("ModuleScript") or d:IsA("Tool") then
			d:Destroy()
		end
	end

	local hum = clone:FindFirstChildOfClass("Humanoid")
	if not hum then
		clone:Destroy()
		return nil, "clone has no Humanoid"
	end
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.RequiresNeck = false
	hum.BreakJointsOnDeath = false
	hum.Health = hum.MaxHealth
	hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)

	local ff = Util.Instance("ForceField", clone)
	ff.Visible = false

	local root = clone:FindFirstChild("HumanoidRootPart")
	if not root then
		clone:Destroy()
		return nil, "clone has no HumanoidRootPart"
	end
	clone.PrimaryPart = root

	return clone
end

--[[
	SKELETON RIG.

	A plain-part copy of your real rig's STRUCTURE -- same part names, same
	sizes, same joints with the same C0/C1 -- and nothing else. No meshes, no
	accessories, no clothing, no attributes left behind by game scripts.

	This is what makes R15 a first-class rig rather than a 6-joint
	approximation. It is built from whatever rig you actually have, so it works
	for R6, R15 and custom rigs alike, and like the origin clone it maps
	identity: joint X drives joint X.

	Cheaper and far less fragile than cloning -- there is no Archivable problem
	and nothing to strip afterwards.
]]
--[[
	Standard joint layouts, for rebuilding a skeleton when the real body has no
	Motor6Ds left to mirror.

	R15 offsets are NOT hardcoded: every R15 part carries `<Joint>RigAttachment`
	attachments, and a joint's C0/C1 are exactly those two attachment CFrames.
	They survive when the joints do not, so the rebuilt skeleton has the real
	avatar's proportions rather than a guess.

	R6 has no such guarantee, so it uses the classic constants.
]]
local R15_JOINTS = {
	{ "Root", "HumanoidRootPart", "LowerTorso" },
	{ "Waist", "LowerTorso", "UpperTorso" },
	{ "Neck", "UpperTorso", "Head" },
	{ "LeftShoulder", "UpperTorso", "LeftUpperArm" },
	{ "LeftElbow", "LeftUpperArm", "LeftLowerArm" },
	{ "LeftWrist", "LeftLowerArm", "LeftHand" },
	{ "RightShoulder", "UpperTorso", "RightUpperArm" },
	{ "RightElbow", "RightUpperArm", "RightLowerArm" },
	{ "RightWrist", "RightLowerArm", "RightHand" },
	{ "LeftHip", "LowerTorso", "LeftUpperLeg" },
	{ "LeftKnee", "LeftUpperLeg", "LeftLowerLeg" },
	{ "LeftAnkle", "LeftLowerLeg", "LeftFoot" },
	{ "RightHip", "LowerTorso", "RightUpperLeg" },
	{ "RightKnee", "RightUpperLeg", "RightLowerLeg" },
	{ "RightAnkle", "RightLowerLeg", "RightFoot" },
}

local R6_JOINTS = {
	{ "RootJoint", "HumanoidRootPart", "Torso",
		CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0),
		CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0) },
	{ "Neck", "Torso", "Head",
		CFrame.new(0, 1, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0),
		CFrame.new(0, -0.5, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0) },
	{ "Left Shoulder", "Torso", "Left Arm",
		CFrame.new(-1, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0),
		CFrame.new(0.5, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0) },
	{ "Right Shoulder", "Torso", "Right Arm",
		CFrame.new(1, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0),
		CFrame.new(-0.5, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0) },
	{ "Left Hip", "Torso", "Left Leg",
		CFrame.new(-1, -1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0),
		CFrame.new(-0.5, 1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0) },
	{ "Right Hip", "Torso", "Right Leg",
		CFrame.new(1, -1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0),
		CFrame.new(0.5, 1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0) },
}

local function SynthesizeJoints(src, mirror, isR15)
	local layout = isR15 and R15_JOINTS or R6_JOINTS
	local made = 0
	for _, j in layout do
		local name, p0n, p1n, fc0, fc1 = j[1], j[2], j[3], j[4], j[5]
		local rp0, rp1 = src:FindFirstChild(p0n), src:FindFirstChild(p1n)
		if rp0 and rp1 and rp0:IsA("BasePart") and rp1:IsA("BasePart") then
			local c0, c1 = fc0, fc1
			if isR15 then
				local a0 = rp0:FindFirstChild(name .. "RigAttachment")
				local a1 = rp1:FindFirstChild(name .. "RigAttachment")
				if a0 and a1 and a0:IsA("Attachment") and a1:IsA("Attachment") then
					c0, c1 = a0.CFrame, a1.CFrame
				end
			end
			if c0 and c1 then
				local m = Instance.new("Motor6D")
				m.Name = name
				m.Part0 = mirror(rp0)
				m.Part1 = mirror(rp1)
				m.C0 = c0
				m.C1 = c1
				m.MaxVelocity = 0
				m.Parent = m.Part0
				made += 1
			end
		end
	end
	return made
end

local function BuildSkeletonRig()
	local src = Player.Character
	local srcHum = src and src:FindFirstChildOfClass("Humanoid")
	if not srcHum then return nil, "no Humanoid to mirror" end
	local srcRoot = srcHum.RootPart
	if not srcRoot then return nil, "no RootPart to mirror" end

	local char = Instance.new("Model")
	char.Name = "LimbReanimate_Skeleton"

	local ff = Util.Instance("ForceField", char)
	ff.Visible = false

	local hum = Util.Instance("Humanoid", char)
	hum.Name = "Humanoid"
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.RequiresNeck = false
	hum.BreakJointsOnDeath = false
	hum.UseJumpPower = true
	hum.WalkSpeed = 16
	hum.JumpPower = 50
	hum.MaxSlopeAngle = 89
	hum.AutoRotate = true
	-- RigType and HipHeight must match or an R15 Humanoid will not stand right.
	pcall(function() hum.RigType = srcHum.RigType end)
	pcall(function() hum.HipHeight = srcHum.HipHeight end)
	hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)

	local made = {}
	local function mirror(realPart)
		local existing = made[realPart.Name]
		if existing then return existing end
		local p = Instance.new("Part")
		p.Name = realPart.Name
		p.Size = realPart.Size
		p.CFrame = realPart.CFrame
		p.Transparency = 1
		p.CanCollide = false
		p.CastShadow = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.LeftSurface = Enum.SurfaceType.Smooth
		p.RightSurface = Enum.SurfaceType.Smooth
		p.FrontSurface = Enum.SurfaceType.Smooth
		p.BackSurface = Enum.SurfaceType.Smooth
		p.Parent = char
		made[realPart.Name] = p
		return p
	end

	-- Root first, so the model always has a primary part.
	mirror(srcRoot)

	local joints = 0
	for _, d in src:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 and d.Part1 then
			local m = Instance.new("Motor6D")
			m.Name = d.Name
			m.Part0 = mirror(d.Part0)
			m.Part1 = mirror(d.Part1)
			m.C0 = d.C0
			m.C1 = d.C1
			m.MaxVelocity = 0
			m.Parent = m.Part0
			joints += 1
		end
	end
	--[[
		Nothing to mirror means the real body's joints are gone. Rebuild them
		from the standard layout instead -- the rig needs joints even when your
		body has none, because a jointless rig can never be animated and Loose
		Parts would then copy a frozen pose onto you forever.
	]]
	if joints == 0 then
		joints = SynthesizeJoints(src, mirror, srcHum.RigType == Enum.HumanoidRigType.R15)
	end

	if joints == 0 then
		char:Destroy()
		return nil, "no joints to mirror and none could be rebuilt"
	end

	char.PrimaryPart = made[srcRoot.Name]
	return char
end

--==============================================================================
-- 6. REANIMATE STATE + CONTROL
--==============================================================================

local Reanimate = {}
Reanimate.Character = nil
Reanimate.Running = false
Reanimate.Starting = false
Reanimate.Stopping = false
Reanimate.CharacterScale = 1
Reanimate.PlaceholderTransparency = 0.5
Reanimate.LocalTransparencyModifier = 0
Reanimate.UsePhysicsRepRootPart = false
Reanimate.RigSource = 0
-- 0 = Built-in R6   -- a hardcoded invisible R6 skeleton, converted to your real
--                      rig by the limb map. Animated for you.
-- 1 = Origin Only   -- the rig is a structural CLONE of your real character:
--                      identity mapping, your real part and joint names, your
--                      real proportions, a real Animator. It passes for a real
--                      character, so external animation scripts can drive it.
Reanimate.ActiveRigSource = 0 -- latched at Start; the map is built against it
Reanimate.RigParts = {}       -- cached BaseParts of the rig, for the hide loop

Reanimate.AnimateRig = true
Reanimate.AnimIds = nil       -- harvested off your real Animate script
Reanimate.Animator = nil      -- the rig's Animator, exposed for custom players
Reanimate.Tracks = nil        -- slot -> AnimationTrack
Reanimate.AnimConn = nil

--==============================================================================
-- 6a. RIG ANIMATION
--
-- Uhhhhhh never creates an Animator; its rig is posed procedurally by moveset
-- modules. This build does it the other way: the rig gets a real Animator and
-- plays your actual character animations on itself.
--
-- This is safe precisely BECAUSE the rig is client-only. The real character
-- must stay Animator-free -- an Animator there overwrites every joint we write.
-- On the rig there is nothing to fight, and the joint loop reads the rig's part
-- CFrames, which already carry whatever the Animator posed.
--==============================================================================

local DEFAULT_R6_ANIMS = {
	idle  = "rbxassetid://180435571",
	walk  = "rbxassetid://180426354",
	run   = "rbxassetid://180426354",
	jump  = "rbxassetid://125750702",
	fall  = "rbxassetid://180436148",
	climb = "rbxassetid://180436334",
	sit   = "rbxassetid://178130996",
}

-- Stock R15 set, for when there is no Animate script to harvest from. R6 ids
-- target R6 joint names and would move an R15 rig not at all, so the fallback
-- has to be picked by rig type.
local DEFAULT_R15_ANIMS = {
	idle  = "rbxassetid://507766666",
	walk  = "rbxassetid://507777826",
	run   = "rbxassetid://507767714",
	jump  = "rbxassetid://507765000",
	fall  = "rbxassetid://507767968",
	climb = "rbxassetid://507765644",
	sit   = "rbxassetid://2506281703",
}

local ANIM_SLOTS = { "idle", "walk", "run", "jump", "fall", "climb", "sit" }

-- Reads the animation ids out of the character's Animate script, so an owned
-- animation package is used instead of the stock set. Must be called BEFORE
-- that script is destroyed.
local function HarvestAnimIds(character, requireR6)
	if not character then return nil end
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum then return nil end
	-- The BUILT-IN rig is R6, and R15 ids target R15 joint names, so they would
	-- load fine and move nothing. An ORIGIN rig matches the character's own rig
	-- type, so there is nothing to guard against there.
	if requireR6 and hum.RigType ~= Enum.HumanoidRigType.R6 then return nil end
	local animate = character:FindFirstChild("Animate")
	if not animate then return nil end

	local out, found = {}, false
	for _, slot in ANIM_SLOTS do
		local folder = animate:FindFirstChild(slot)
		if folder then
			local a = folder:FindFirstChildWhichIsA("Animation")
			if a and a.AnimationId ~= "" then
				out[slot] = a.AnimationId
				found = true
			end
		end
	end
	return found and out or nil
end

local function SetupRigAnimation(RC, hum, root)
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end
	Reanimate.Animator = animator

	-- Fall back to the stock R6 set only when the rig really is R6. Loading R6
	-- ids onto an R15 origin rig succeeds and animates nothing, which looks
	-- exactly like a broken reanimate.
	local ids = Reanimate.AnimIds
	if not ids then
		ids = (hum.RigType == Enum.HumanoidRigType.R15)
			and DEFAULT_R15_ANIMS
			or DEFAULT_R6_ANIMS
	end
	local tracks = {}
	for slot, id in ids do
		local a = Instance.new("Animation")
		a.AnimationId = id
		local ok, track = pcall(function() return animator:LoadAnimation(a) end)
		if ok and track then tracks[slot] = track end
	end
	Reanimate.Tracks = tracks

	local current = nil
	local function play(slot, speed)
		local track = tracks[slot] or tracks.idle
		if track ~= current then
			if current then current:Stop(0.1) end
			current = track
			if track then track:Play(0.1) end
		end
		if track and speed then track:AdjustSpeed(speed) end
	end

	return RunService.Heartbeat:Connect(function()
		if not RC.Parent then return end
		-- Turn this off to drive the rig yourself. Leaving it on while a custom
		-- animator also poses the rig means the two fight every frame.
		if not Reanimate.AnimateRig then
			if current then
				current:Stop(0.1)
				current = nil
			end
			return
		end
		local st = hum:GetState()
		if hum.Sit or st == Enum.HumanoidStateType.Seated then
			play("sit", 1)
		elseif st == Enum.HumanoidStateType.Climbing then
			play("climb", 1)
		elseif st == Enum.HumanoidStateType.Jumping then
			play("jump", 1)
		elseif st == Enum.HumanoidStateType.Freefall then
			play("fall", 1)
		else
			local v = root.AssemblyLinearVelocity
			local sp = Vector3.new(v.X, 0, v.Z).Magnitude
			if sp > 0.5 then
				play(sp > 12 and "run" or "walk", math.clamp(sp / 14.5, 0.4, 3))
			else
				play("idle", 1)
			end
		end
	end)
end

-- Movement is read off the stock PlayerModule so keyboard, gamepad and the
-- mobile thumbstick all work without reimplementing an input layer.
local Controls do
	task.spawn(function()
		local ok, pm = pcall(function()
			return require(Player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
		end)
		if ok and pm then
			local ok2, c = pcall(function() return pm:GetControls() end)
			if ok2 then Controls = c end
		end
	end)
end

local JumpUntil = 0
local JumpConn = UserInputService.JumpRequest:Connect(function()
	JumpUntil = os.clock() + 0.15
end)

local RigDriveConn = nil

function Reanimate.DestroyCharacter()
	if RigDriveConn then RigDriveConn:Disconnect() RigDriveConn = nil end
	if Reanimate.AnimConn then Reanimate.AnimConn:Disconnect() Reanimate.AnimConn = nil end
	Reanimate.Animator = nil
	Reanimate.Tracks = nil
	if Reanimate.Character then
		Reanimate.Character:Destroy()
		Reanimate.Character = nil
	end
end

function Reanimate.CreateCharacter(InitCFrame)
	local cf = CFrame.new(Camera.Focus.Position)
	local old = Reanimate.Character
	if old then
		local r = old:FindFirstChild("HumanoidRootPart")
		if r then cf = r.CFrame end
	elseif Player.Character then
		local r = Player.Character:FindFirstChild("HumanoidRootPart")
		if r then cf = r.CFrame end
	end
	if InitCFrame then cf = InitCFrame end

	Reanimate.DestroyCharacter()

	local origin = Reanimate.ActiveRigSource == 1
	local RC, why

	--[[
		When the mapping is identity, the rig MUST structurally match the real
		character -- an identity map has nothing to resolve against otherwise,
		and a mismatched root entry would leave the body parked in the void. So
		the fallback chain stays inside the identity-capable rigs, and we abort
		rather than hand back something that cannot work.
	]]
	if Reanimate.WantIdentityRig then
		if origin then
			RC, why = BuildOriginRig()
			if not RC then RC, why = BuildSkeletonRig() end
		else
			RC, why = BuildSkeletonRig()
			if not RC then RC, why = BuildOriginRig() end
		end
		if not RC then
			warn("[LimbReanimate] could not build a rig: " .. tostring(why))
			return nil
		end
	else
		RC = BuildFakeRig()
	end

	-- A rig with no joints of its own can never be animated, so Loose Parts
	-- would copy a frozen pose onto you forever. Worth saying out loud.
	do
		local rj = 0
		for _, d in RC:GetDescendants() do
			if d:IsA("Motor6D") then rj += 1 end
		end
		if rj == 0 then
			warn("[LimbReanimate] the rig was built with NO joints, so nothing can "
				.. "animate it. If Rig Source is Origin Only on a body whose joints "
				.. "are already gone, the clone has none either -- switch to Built-in, "
				.. "which rebuilds a skeleton from your rig attachments.")
		end
	end

	Reanimate.IsOrigin = RC.Name == "LimbReanimate_OriginRig"
	Reanimate.RigKind = (RC.Name == "LimbReanimate_OriginRig" and "Origin clone")
		or (RC.Name == "LimbReanimate_Skeleton" and "Skeleton (auto)")
		or "Built-in R6"
	origin = Reanimate.IsOrigin

	pcall(function() RC.ModelStreamingMode = Enum.ModelStreamingMode.Persistent end)
	-- Without this the engine unloads the void-parked real root and our writes
	-- stop landing.
	pcall(function() Player.ReplicationFocus = Workspace end)

	-- An origin clone already carries the avatar's own body scale; ScaleTo would
	-- stomp it.
	if not origin then
		RC:ScaleTo(Reanimate.CharacterScale)
	end
	RC.Parent = Workspace

	local RCRoot = RC:FindFirstChild("HumanoidRootPart")
	local RCHum = RC:FindFirstChildOfClass("Humanoid")
	RCRoot.RootPriority = 67
	RCRoot.CFrame = cf

	local bf = Util.Instance("BodyForce", RCRoot)
	bf.Force = Vector3.zero

	Reanimate.Character = RC

	-- Cache the rig's parts once. The hide loop runs every frame and cannot
	-- afford a GetDescendants() walk, and it cannot use hardcoded R6 names
	-- either now that the rig may be an R15 clone.
	local parts = {}
	for _, d in RC:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	Reanimate.RigParts = parts

	-- Direct children only: the body parts the collision pass drives. Matches
	-- the reference, and keeps accessory handles out of it.
	local bodyParts = {}
	for _, d in RC:GetChildren() do
		if d:IsA("BasePart") then
			table.insert(bodyParts, d)
		end
	end
	Reanimate.RigBodyParts = bodyParts

	-- Both modes get a working Animator. Whether the built-in driver actually
	-- plays anything on it is the AnimateRig toggle.
	Reanimate.AnimConn = SetupRigAnimation(RC, RCHum, RCRoot)

	--[[
		The rig MUST collide with the world.

		Every rig part starts CanCollide = false -- the built-in rig is built
		that way, and an origin clone inherits it because the real character's
		parts were already forced non-colliding before the clone was taken. A
		Humanoid with no collision anywhere has nothing to stand on: it falls
		forever, your real limbs follow it down, and you vanish on both the
		client and the server.

		Only the ROOT collides during normal movement states, so the rig stands
		and walks without limbs snagging on geometry. In the odd states
		(ragdoll, physics, seated, ...) everything collides.
	]]
	local NOCLIP_STATES = { "Running", "Jumping", "Freefall", "Landed", "Climbing", "Swimming" }

	local groundParams = RaycastParams.new()
	groundParams.RespectCanCollide = true
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	groundParams.FilterDescendantsInstances = { RC }
	local lastSafest = cf

	RigDriveConn = RunService.PreSimulation:Connect(function()
		if not RC.Parent then return end

		local clip = not table.find(NOCLIP_STATES, RCHum:GetState().Name)
		for _, v in Reanimate.RigBodyParts do
			if v.Parent then
				v.CanCollide = clip or (v == RCRoot)
			end
		end

		local mv = Vector3.zero
		if Controls then
			local ok, v = pcall(function() return Controls:GetMoveVector() end)
			if ok and typeof(v) == "Vector3" then mv = v end
		end
		if mv.Magnitude > 1 then mv = mv.Unit end
		RCHum:Move(mv, true)
		RCHum.Jump = os.clock() < JumpUntil

		-- Remember the last spot that actually had ground under it, and fall
		-- back to THAT rather than to the camera focus, which follows the rig
		-- and so would just chase it down.
		local reach = 8 + RCHum.HipHeight + 3 * Reanimate.CharacterScale
		if Workspace:Raycast(RCRoot.Position, Vector3.new(0, -reach, 0), groundParams) then
			lastSafest = RCRoot.CFrame
		end
		if RCRoot.Position.Y < FallenPartsDestroyHeight + 3 * Reanimate.CharacterScale then
			RCRoot.CFrame = lastSafest
			RCRoot.AssemblyLinearVelocity = Vector3.new(0, 50, 0)
			RCRoot.AssemblyAngularVelocity = Vector3.zero
		end
	end)

	return RC
end

--==============================================================================
-- 7. THE LIMB REANIMATOR
--==============================================================================

local LR = {}

LR.Mode = 0
-- 0 = RootPart in very void   (Y ~ -70000, random X/Z)
-- 1 = RootPart in void        (just under FallenPartsDestroyHeight)
-- 2 = Keep RootPart Streamed  (16 studs under the rig; forced when streaming is on)
-- 3 = CurrentAngle Style      (root sits exactly on the rig root)
-- 4 = RootPart is Torso       (root sits on the rig torso; most interpolated)

LR.Velocity = 0
-- 0 = No Velocity   1 = Follow Character   2 = Fling-like

LR.InitMode = 2
-- 0 = Reset Character   1 = CDSB + Reset   2 = CDSB + SSE + Kill
-- 3 = No Kill -- never kills. Takes animation authority from the live body
--     and gives it back on Deanimate. Handled outside DoInit entirely.

LR.ReplicateFPS10 = false   -- "Show me how I look!" (throttle joint writes to 10/s)
LR.FlingEnabled   = false   -- Target Fling Enabled
LR.UseNaNFling    = false   -- Use NaN State Fling
LR.RootJitter     = false   -- per-frame 0.005 Z nudge on the root write.
                            -- Uhhhhhh hardcodes this ON; the edited build deletes
                            -- it outright because it visibly shakes the torso.
                            -- Default off, toggleable for when a game drops
                            -- identical consecutive CFrames.

LR.FlingTargets = {}
LR._TempNotFling = {}
LR.Status = "IDLE"

--[[
	Hidden limbs.

	Keyed by the joint's Part1 name, so the choice survives a respawn and a
	re-reanimate. A hidden limb is driven to a far-off hold position instead of
	to the rig -- it is never deleted and the joint is never broken, so it comes
	straight back the moment you un-hide it. Server-side deletion would not be
	reversible and is not worth the trade.

	The root entry is deliberately not listed: hiding it would take the whole
	body, which is what RootPart Mode already does properly.
]]
--[[
	Drive mode.

	Joints is the real reanimate: write Motor6D transforms, the assembly stays
	intact. It needs the body to HAVE joints.

	Loose Parts is for when it does not. Some games hand back a live character
	with no Motor6Ds at all, and a body whose joints are already broken is just
	a set of parts you own -- so each real part is written straight to its
	rig counterpart's CFrame instead. Part CFrames replicate for parts you own,
	so this drives limbs for everyone, no joints required.

	Auto picks Loose Parts only when nothing was matched, so a normal body is
	never downgraded.
]]
LR.DriveMode = 0
-- 0 = Auto   1 = Joints only   2 = Loose Parts only

LR.HiddenLimbs = {}
LR.LimbList = {}
LR.LimbListVersion = 0
LR._LimbSig = nil

-- Measured, not guessed. Drift is the distance between where we wrote the root
-- last frame and where it actually is now: a couple of studs is the normal
-- settle band, hundreds means something is winning against our writes.
LR.Diag = {
	RigType = "?",
	Mapped = 0,
	Unmapped = 0,
	-- How many Motor6Ds your real body actually has. Without this, "0 driven"
	-- cannot be told apart from "your body has no joints to drive".
	RealJoints = 0,
	RigParts = 0,
	-- Joints are destroyed by death. If the body we are driving is a corpse,
	-- it has none and never will, and no amount of rig work can fix that.
	BodyState = "?",
	Health = "?",
	Respawns = 0,
	-- Where the root is actually being sent. A mode that silently fails to
	-- apply used to be invisible; now it is not.
	RootMode = "-",
	RootY = 0,
	Drive = "-",
	-- The rig's OWN joint count. A rig with no joints cannot be animated by
	-- anything, so Loose Parts would copy a frozen pose forever. Without this
	-- number a rebuilt skeleton is indistinguishable from a jointless clone.
	RigJoints = 0,
	PartsDriven = 0,
	Drift = 0,
	MaxDrift = 0,
}

function LR.ShowHitboxes()
	pcall(function()
		Util.ShowPartHitbox(Player.Character.HumanoidRootPart)
	end)
end

function LR.Fling(target, duration)
	if not LR.FlingEnabled then return false end
	if not target then return false end
	for _, v in LR.FlingTargets do
		if v.Target == target then return false end
	end
	if target == Reanimate.Character then return false end
	if target == Player.Character then return false end
	if typeof(target) == "Instance" then
		if LR._TempNotFling[target] then return false end
		LR._TempNotFling[target] = true
		task.delay(1, function() LR._TempNotFling[target] = nil end)
	end
	table.insert(LR.FlingTargets, { Target = target, Duration = duration })
	if typeof(target) == "Instance" and target:IsA("Model") then
		local h = Instance.new("Highlight")
		h.Adornee = target
		h.FillColor = Color3.new(1, 0, 0)
		h.OutlineColor = Color3.new(1, 0, 0)
		h.FillTransparency = 0.5
		h.Parent = target
		Debris:AddItem(h, 5)
	end
	return true
end

--[[
	Init modes -- how the real character is put into the loose-limb state.

	SSE  = SetStateEnabled(Dead, true) then ChangeState(Dead). The client is
	       allowed to declare its own death; the server accepts it, breaks the
	       joints and queues a respawn.
	CDSB = Player.ConnectDiedSignalBackend, replicated directly. Historically
	       stopped the server respawning you at all. Patched on current clients;
	       kept for parity and only attempted if the executor exposes
	       replicatesignal.

	Mode 3 (No Kill) never reaches here -- there is nothing to kill.
]]
local function DoInit(humanoid)
	if LR.InitMode >= 1 and Env.replicatesignal then
		pcall(function() Env.replicatesignal(Player.ConnectDiedSignalBackend) end)
	end
	if LR.InitMode == 0 or LR.InitMode == 1 then
		pcall(function() humanoid.Health = 0 end)
	end
	if humanoid:GetState() ~= Enum.HumanoidStateType.Dead then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, true)
		humanoid:ChangeState(Enum.HumanoidStateType.Dead)
	end
end

function LR.Start()
	-- Latched here, not read live: the mapping is built against whichever rig
	-- this run uses, so switching source mid-run would leave every entry
	-- pointing at part names that no longer exist. Also decides whether the
	-- animation harvest below has to restrict itself to R6 ids.
	Reanimate.ActiveRigSource = Reanimate.RigSource
	local OriginMode = Reanimate.ActiveRigSource == 1

	--[[
		Which mapping to use has to be settled here, before the joints are
		discovered and before the rig is built.

		The hardcoded R6 rig needs the conversion table. Every other rig is
		structurally the real character, so the map is identity -- and that is
		what makes R15 first class instead of a 6-joint approximation: the
		built-in path builds a skeleton from your own rig when you are R15.
	]]
	local myRigType do
		local c = Player.Character
		local h = c and c:FindFirstChildOfClass("Humanoid")
		myRigType = h and h.RigType or Enum.HumanoidRigType.R6
	end
	local IdentityMap = OriginMode or (myRigType == Enum.HumanoidRigType.R15)
	Reanimate.WantIdentityRig = IdentityMap

	-- Origin mode exists to hand the rig to your own scripts, so the built-in
	-- driver starts out of the way. The Animator is still there for you to load
	-- onto -- this switches off our driver, not the rig's ability to animate.
	if OriginMode then
		Reanimate.AnimateRig = false
		if Reanimate.SyncAnimateToggle then
			Reanimate.SyncAnimateToggle(false)
		end
	end

	-- Reanimating in place: no kill, no respawn, and Deanimate restores the
	-- character you already have instead of throwing it away.
	local NoRespawn = LR.InitMode == 3

	-- Everything that has to be unhooked if we restore in place. Without this
	-- the CanCollide and LocalScript forcers keep running on a character we no
	-- longer own, and it stays broken after Deanimate.
	local Conns = {}
	local SavedCollide = {}
	local SavedScripts = {}

	-- Rolled ONCE per session, not per frame, and randomised in X/Z so two
	-- players never park their roots in the same spot.
	local rootposition = Vector3.new(
		math.random(-65536, 65536),
		math.random(-70000, -60000),
		math.random(-65536, 65536)
	)
	local rootposition2 = Vector3.new(
		math.random(-2048, 2048),
		math.random(-500, -100) + FallenPartsDestroyHeight,
		math.random(-2048, 2048)
	)
	-- Where hidden limbs are parked. Its own spot, well away from the root, so
	-- a hidden limb never lands on the body it came off.
	local limbholdposition = Vector3.new(
		math.random(-65536, 65536),
		math.random(-70000, -60000),
		math.random(-65536, 65536)
	)
	-- Spread them apart deterministically, so the same limb always goes to the
	-- same place and they do not pile up on one point.
	local function HoldPositionFor(name)
		local n = 0
		for i = 1, #name do
			n += string.byte(name, i)
		end
		return limbholdposition + Vector3.new((n % 16) * 8, 0, (n // 16 % 16) * 8)
	end

	local InitCFrame = nil
	if Player.Character then
		-- Harvest BEFORE the kill: the pre-kill character still has an intact
		-- Animate script to read the ids out of.
		Reanimate.AnimIds = HarvestAnimIds(Player.Character, not IdentityMap) or Reanimate.AnimIds
		local h = Player.Character:FindFirstChildOfClass("Humanoid")
		if h and h.RootPart then
			InitCFrame = h.RootPart.CFrame
			if not NoRespawn then
				DoInit(h)
			end
		end
	end

	-- Built-in mode needs the conversion table. Origin mode does not: the rig is
	-- a clone of the thing being driven, so the map is identity and is built
	-- from the real character's own joints as they are discovered.
	local LimbMapping = IdentityMap and {} or MakeLimbMap()

	----------------------------------------------------------------------------
	-- Tool mirroring: the real Tool stays on the real (puppeted) character, so
	-- a stand-in Tool is welded to the RIG's right arm to carry the tool
	-- animations and touch events.
	----------------------------------------------------------------------------
	local FakeTools = {}
	local function CreateFakeTool()
		local FakeTool = Instance.new("Tool")
		FakeTool.Name = "faketool"
		local Handle = Instance.new("Part")
		Handle.Name = "Handle"
		Handle.Transparency = 1
		Handle.CanCollide = false
		Handle.Massless = true
		Handle.Parent = FakeTool
		FakeTool.Parent = Reanimate.Character
		local RightGrip = Instance.new("Weld")
		RightGrip.Name = "RightGrip"
		RightGrip.Parent = Handle
		-- R6 calls it "Right Arm", R15 calls it "RightHand". An origin rig can be
		-- either, so do not assume.
		local rc = Reanimate.Character
		RightGrip.Part0 = rc and (rc:FindFirstChild("Right Arm") or rc:FindFirstChild("RightHand"))
		RightGrip.Part1 = Handle
		RightGrip.C0 = RIGHTGRIP_C0
		RightGrip.C1 = FakeTool.Grip
		Util.LinkDestroyI2C(FakeTool, FakeTool:GetPropertyChangedSignal("Grip"):Connect(function()
			RightGrip.C1 = FakeTool.Grip
		end))
		return FakeTool
	end

	local BaseParts = {}
	local UnknownMotor6Ds = {}

	local function CharOnDesc(v)
		if v:IsA("BasePart") then
			if not table.find(BaseParts, v) then
				table.insert(BaseParts, v)
				if SavedCollide[v] == nil then SavedCollide[v] = v.CanCollide end
				v.CanCollide = false
				table.insert(Conns, v:GetPropertyChangedSignal("CanCollide"):Connect(function()
					if v.CanCollide then v.CanCollide = false end
				end))
			end
		elseif v:IsA("Motor6D") then
			repeat task.wait() until (not v:IsDescendantOf(RawWorkspace)) or (v.Part0 and v.Part1)
			if not v:IsDescendantOf(RawWorkspace) then return end
			local p0, p1 = v.Part0, v.Part1
			if p0 and p1 then
				p0, p1 = p0.Name, p1.Name
				for _, map in LimbMapping do
					if map.Part0 == p0 and map.Part1 == p1 then
						map.Reference = v
						return
					end
				end
				-- Origin mode: identity. Same joint, same part names, no
				-- conversion. The root joint still substitutes the REAL root
				-- part so it keeps absorbing the void offset.
				if IdentityMap then
					table.insert(LimbMapping, {
						Part0 = p0,
						Part1 = p1,
						Type = 1,
						RPart0 = (p0 == "HumanoidRootPart") and "ROOT" or p0,
						RPart1 = p1,
						Reference = v,
					})
					return
				end
			end
			table.insert(UnknownMotor6Ds, v)
		elseif v:IsA("Animator") then
			-- The single most important cleanup. An Animator will fight every
			-- transform we write, one frame at a time, and win.
			task.defer(v.Destroy, v)
		elseif v:IsA("LocalScript") and v.Parent == Player.Character then
			if SavedScripts[v] == nil then SavedScripts[v] = v.Enabled end
			v.Enabled = false
			table.insert(Conns, v:GetPropertyChangedSignal("Enabled"):Connect(function()
				if v.Enabled then v.Enabled = false end
			end))
			table.insert(Conns, v:GetPropertyChangedSignal("Disabled"):Connect(function()
				if not v.Disabled then v.Disabled = true end
			end))
		elseif v:IsA("Tool") and v.Parent == Player.Character then
			if not FakeTools[v] then
				FakeTools[v] = true
				local fake = CreateFakeTool()
				fake.Grip = v.Grip
				local h = v:FindFirstChild("Handle")
				if h then fake.Handle.Size = h.Size end
				Util.LinkDestroyI2C(fake, RunService.PreSimulation:Connect(function()
					if v.Parent == Player.Character then
						fake.Grip = v.Grip
						local hh = v:FindFirstChild("Handle")
						if hh then fake.Handle.Size = hh.Size end
					else
						fake:Destroy()
						FakeTools[v] = nil
					end
				end))
				Util.LinkDestroyI2C(fake, v.ChildAdded:Connect(function(c)
					if c.ClassName == "StringValue" and c.Name == "toolanim" then
						local w = Instance.new("StringValue")
						w.Name = "toolanim"
						w.Value = c.Value
						w.Parent = fake
						Debris:AddItem(c, 1)
						Debris:AddItem(w, 1)
					end
				end))
				if Env.firetouchinterest then
					fake.Handle.Touched:Connect(function(t)
						local hh = v:FindFirstChild("Handle")
						if hh and t and hh:IsDescendantOf(Workspace) and t:IsDescendantOf(Workspace) then
							hh.CanTouch = true
							pcall(Env.firetouchinterest, hh, t, 0)
						end
					end)
					fake.Handle.TouchEnded:Connect(function(t)
						local hh = v:FindFirstChild("Handle")
						if hh and t and hh:IsDescendantOf(Workspace) and t:IsDescendantOf(Workspace) then
							hh.CanTouch = true
							pcall(Env.firetouchinterest, hh, t, 1)
						end
					end)
				end
			end
		end
	end

	local lastspawn = 0

	-- Takes animation authority away from a character. Used on the respawned
	-- body in the normal flow, and on the LIVE body in no-respawn mode.
	local function AdoptCharacter(character, fromRespawn)
		if fromRespawn then
			-- The engine snaps the camera to the new character. Put it back
			-- before the frame is drawn so respawns are not a camera jolt.
			local camcfr = Camera.CFrame
			RunService.PreRender:Once(function()
				RunService.PreAnimation:Wait()
				Camera.CFrame = camcfr
			end)
		end
		lastspawn = os.clock()
		table.clear(BaseParts)
		table.clear(UnknownMotor6Ds)
		if IdentityMap then
			-- Entries are discovered, not fixed, so drop them entirely.
			table.clear(LimbMapping)
		else
			for _, map in LimbMapping do
				map.Reference = nil
			end
		end
		table.insert(Conns, character.DescendantAdded:Connect(CharOnDesc))
		for _, v in character:GetDescendants() do
			task.spawn(CharOnDesc, v)
		end
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid then
			local anim = humanoid:FindFirstChildWhichIsA("Animator")
			if anim then anim:Destroy() end
		end
		local animate = character:FindFirstChild("Animate")
		if fromRespawn then
			-- A fresh character may not have it yet.
			local deadline = os.clock() + 5
			while not animate and os.clock() < deadline do
				character.ChildAdded:Wait()
				animate = character:FindFirstChild("Animate")
			end
		end
		if animate then
			Reanimate.AnimIds = HarvestAnimIds(character, not IdentityMap) or Reanimate.AnimIds
			-- In no-respawn mode it is only disabled (by the LocalScript branch
			-- above) so it can be switched back on when we hand the body back.
			if not NoRespawn then
				animate:Destroy()
			end
		end
	end

	local CharConn = Player.CharacterAdded:Connect(function(character)
		LR.Diag.Respawns += 1
		AdoptCharacter(character, true)
	end)

	-- Undoes AdoptCharacter, for no-respawn mode. Every joint back to rest,
	-- the body back out of the void, every hook unhooked, animation authority
	-- handed back to the game.
	local function RestoreCharacter()
		for _, c in Conns do
			pcall(function() c:Disconnect() end)
		end
		table.clear(Conns)

		for _, v in UnknownMotor6Ds do
			if v.Parent then
				Util.SetMotor6DTransform(v, CFrame.identity)
			end
		end
		for _, map in LimbMapping do
			if map.Reference and map.Reference.Parent then
				Util.SetMotor6DTransform(map.Reference, CFrame.identity)
			end
		end

		local character = Player.Character
		local RC = Reanimate.Character
		if character then
			local hum = character:FindFirstChildOfClass("Humanoid")
			local root = hum and hum.RootPart
			if root then
				SetHidden(root, "PhysicsRepRootPart", nil)
				-- Land where the rig was standing, not 70,000 studs down.
				local rigRoot = RC and RC:FindFirstChild("HumanoidRootPart")
				if rigRoot then
					root.CFrame = rigRoot.CFrame
				end
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
			end
			if hum then
				hum.AutoRotate = true
				-- Give animation authority back.
				if not hum:FindFirstChildOfClass("Animator") then
					Util.Instance("Animator", hum)
				end
			end
		end

		for part, collide in SavedCollide do
			if part.Parent then
				pcall(function() part.CanCollide = collide end)
			end
		end
		table.clear(SavedCollide)

		for scr, enabled in SavedScripts do
			if scr.Parent then
				pcall(function() scr.Enabled = enabled end)
			end
		end
		table.clear(SavedScripts)
	end

	if NoRespawn then
		-- Nothing died, so there is nothing to wait for. Take the body we
		-- already have.
		local character = Player.Character
		if not character then
			CharConn:Disconnect()
			Reanimate.Starting = false
			Reanimate.Stopping = false
			LR.Status = "NO CHARACTER"
			return
		end
		LR.Status = "ADOPTING IN PLACE"
		AdoptCharacter(character, false)
	else
		-- Bounded wait for the respawn. An unbounded CharacterAdded:Wait()
		-- strands the whole coroutine in games where the kill does not take,
		-- and the Deanimate button then has nothing to stop.
		LR.Status = "WAITING FOR RESPAWN"
		local spawned = false
		local waitConn = Player.CharacterAdded:Connect(function() spawned = true end)
		local deadline = os.clock() + 15
		repeat task.wait() until spawned or Reanimate.Stopping or os.clock() > deadline
		waitConn:Disconnect()
		if not spawned or Reanimate.Stopping then
			CharConn:Disconnect()
			pcall(function() Workspace.FallenPartsDestroyHeight = FallenPartsDestroyHeight end)
			Reanimate.Starting = false
			Reanimate.Stopping = false
			LR.Status = spawned and "IDLE" or "NO RESPAWN (init failed)"
			return
		end
	end

	--[[
		Wait for the joints to actually exist.

		CharacterAdded fires before the character is finished: its parts and
		Motor6Ds stream in over the following frames. Building the rig on that
		frame gives a rig with no joints -- the skeleton refuses to build, the
		clone falls out empty, and nothing is ever driven. Diagnostics for that
		read "0 driven" with a root drift near zero, because the root writes are
		landing fine and there is simply nothing hanging off it.
	]]
	local jointsFound = false
	do
		LR.Status = "WAITING FOR JOINTS"
		local deadline = os.clock() + 8
		while os.clock() < deadline and not Reanimate.Stopping do
			local c = Player.Character
			if c then
				for _, d in c:GetDescendants() do
					if d:IsA("Motor6D") and d.Part0 and d.Part1 then
						jointsFound = true
						break
					end
				end
			end
			if jointsFound then break end
			task.wait()
		end
	end

	if not jointsFound then
		-- Not necessarily a corpse: some games hand back a live, full-health
		-- character whose joints are simply gone. Nothing can drive joints that
		-- do not exist, so Auto falls through to writing part CFrames instead.
		warn("[LimbReanimate] your character has no Motor6D joints. Falling back "
			.. "to Loose Parts: each limb is written by CFrame instead of through "
			.. "a joint. Set Drive Mode manually if you want to force either one.")
	end

	if not Reanimate.CreateCharacter(InitCFrame) then
		-- No usable rig. Stopping here beats driving the body at a rig that
		-- cannot resolve, which would strand it in the void.
		CharConn:Disconnect()
		if NoRespawn then pcall(RestoreCharacter) end
		pcall(function() Workspace.FallenPartsDestroyHeight = FallenPartsDestroyHeight end)
		Reanimate.Starting = false
		Reanimate.Stopping = false
		LR.Status = "RIG BUILD FAILED"
		return
	end
	LR.Status = jointsFound and "RUNNING" or "RUNNING (no joints, loose parts)"

	----------------------------------------------------------------------------
	-- Per-frame write.
	----------------------------------------------------------------------------
	local lastrep = 0
	local DriveLoose = false
	local function UpdateTransforms(RC, RootPart, rootcf, rootvel, flingtarget, flingcf)
		-- IsGrounded() gates the ROOT write only. A grounded root (welded into
		-- an anchored assembly) cannot be moved, and writing it just spams the
		-- physics solver.
		if not RootPart:IsGrounded() then
			local jitter = LR.RootJitter and Vector3.new(0, 0, math.random(0, 1) * 0.005) or Vector3.zero
			if flingtarget then
				if LR.UseNaNFling then
					RootPart.CFrame = CFrame.new(flingcf.Position + jitter) * CFrame.Angles(0, os.clock() * 15, 0)
					RootPart.AssemblyLinearVelocity = Vector3.zero
					RootPart.AssemblyAngularVelocity = Vector3.zero
				else
					RootPart.CFrame = flingcf + jitter
					RootPart.AssemblyLinearVelocity = Vector3.new(0, -16384, 0)
					RootPart.AssemblyAngularVelocity = Vector3.one * 16384
				end
				SetHidden(RootPart, "PhysicsRepRootPart",
					Reanimate.UsePhysicsRepRootPart and Util.PredictionFlingPart(flingtarget.Target) or nil)
			else
				RootPart.CFrame = rootcf + jitter
				RootPart.AssemblyLinearVelocity = rootvel
				RootPart.AssemblyAngularVelocity = Vector3.zero
				SetHidden(RootPart, "PhysicsRepRootPart", nil)
			end
		end

		--[[
			LOOSE PARTS.

			No joints to drive, so drive the parts. Each real part is written
			straight to the rig part of the same name. They are already
			CanCollide = false with their velocities zeroed by the main loop, so
			nothing fights the write, and part CFrames replicate for parts you
			own -- which your own character's parts are.

			Matching is by name and non-recursive, so accessory Handles are left
			alone: they are still welded to their limb and follow it for free.
		]]
		if DriveLoose then
			local n = 0
			for _, v in BaseParts do
				if v ~= RootPart and v.Parent and not v:FindFirstAncestorWhichIsA("Tool") then
					local target = RC:FindFirstChild(v.Name)
					if target then
						if LR.HiddenLimbs[v.Name] then
							v.CFrame = CFrame.new(HoldPositionFor(v.Name))
						else
							v.CFrame = target.CFrame
						end
						n += 1
					end
				end
			end
			LR.Diag.PartsDriven = n
			return
		end

		-- "Show me how I look!": write the joints at 10 Hz instead of every
		-- frame, so what you see locally matches the coarser thing other
		-- players actually receive.
		local dorep = true
		if LR.ReplicateFPS10 then
			dorep = false
			local b = os.clock()
			local a = b - lastrep
			if a >= 1 / 10 then
				dorep = true
				a %= 1 / 10
				lastrep = b - a
			end
		end

		-- Any joint we have no mapping for is pinned to identity so it cannot
		-- drift off on its own.
		for _, v in UnknownMotor6Ds do
			Util.SetMotor6DTransform(v, CFrame.identity)
		end

		for _, map in LimbMapping do
			local v = map.Reference
			if v then
				if flingtarget then
					Util.SetMotor6DTransform(v, CFrame.identity)
				elseif map.RPart0 ~= "ROOT" and LR.HiddenLimbs[map.Part1] then
					-- Hidden: drive it to the hold position instead of the rig.
					-- Same offset form as everything else, so it lands exactly
					-- there, and nothing about the joint is destroyed.
					local p0 = RC:FindFirstChild(map.RPart0)
					if p0 then
						Util.SetMotor6DOffset(v,
							p0.CFrame:ToObjectSpace(CFrame.new(HoldPositionFor(map.Part1))))
					end
				else
					local cf = CFrame.identity
					local p0 = RC:FindFirstChild(map.RPart0)
					local p1 = RC:FindFirstChild(map.RPart1)
					-- "ROOT" means the REAL root part, the one in the void.
					-- This single substitution is what makes the root joint
					-- absorb the entire void offset.
					local isRoot = map.RPart0 == "ROOT"
					if isRoot then p0 = RootPart end
					if p0 and p1 then
						--[[
							The root entry is a PLACEMENT, not an angle
							transfer, and must use the offset form even on R15.

							Passing an offset makes the void translation cancel
							exactly: Part1 = Part0 * (Part0^-1 * target).

							The Type 2 form instead hands the engine a raw
							Transform, so the result is conjugated by the real
							joint's own C0:

							    Part0 * C0 * Transform * C1^-1

							Conjugation leaves a `t - R*t` term in the
							translation. With `t` 70,000 studs out and any
							rotation at all in C0 -- and R15's Root joint has
							one -- that term is a six-figure position error, so
							the body is flung somewhere unreachable and the
							reanimate looks like it simply never happened.
						]]
						if isRoot or map.Type == 1 then
							cf = p0.CFrame:ToObjectSpace(p1.CFrame)
						elseif map.Type == 2 then
							local offset = map.Offset or CFrame.identity
							local c0, c1 = CFrame.new(map.C0), CFrame.new(map.C1)
							local transform = offset * (p0.CFrame * c0):ToObjectSpace(p1.CFrame * c1) * offset:Inverse()
							cf = v.C0 * transform * v.C1:Inverse()
						end
					end
					if dorep or not map.CFrame then
						map.CFrame = cf
					end
					Util.SetMotor6DOffset(v, map.CFrame)
				end
			end
		end
	end

	Reanimate.Starting = false

	local lastRootTarget = nil
	local lastJointScan = 0
	LR.Diag.MaxDrift = 0

	while not Reanimate.Stopping do
		RunService.PreSimulation:Wait()

		-- Parking the root below the destroy plane only works because the plane
		-- is NaN. Re-applied every frame; other scripts reset it.
		Workspace.FallenPartsDestroyHeight = 0 / 0

		local ReanimOkay = false
		local Character, Humanoid, RootPart = Player.Character, nil, nil
		if Character then
			Humanoid = Character:FindFirstChildOfClass("Humanoid")
			if Humanoid then
				Humanoid.AutoRotate = false
				if Humanoid.WalkSpeed < 1 then Humanoid.WalkSpeed = 16 end
				if Humanoid.JumpPower < 1 then Humanoid.JumpPower = 50 end
				RootPart = Humanoid.RootPart
				if RootPart and Humanoid:GetState() ~= Enum.HumanoidStateType.Dead then
					-- Freefall stops the server running walk/land logic that
					-- would correct our root writes.
					Humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
					ReanimOkay = LR.FlingTargets[1] == nil
				end
			end
		end

		local rootcf = CFrame.new(rootposition)
		local rootvel = Vector3.zero
		local ltm = Reanimate.LocalTransparencyModifier
		local RC = Reanimate.Character
		local flingtarget, flingcf = nil, CFrame.identity

		if RC then
			local RCHumanoid = RC:FindFirstChildOfClass("Humanoid")
			local RCRootPart = RC:FindFirstChild("HumanoidRootPart")
			-- R6 calls it "Torso"; R15 has no such part, so an R15 rig -- clone
			-- or auto skeleton -- must be resolved to LowerTorso.
			local RCTorso = RC:FindFirstChild("Torso")
				or RC:FindFirstChild("LowerTorso")
				or RC:FindFirstChild("UpperTorso")

			if Camera then
				Camera.CameraSubject = RCHumanoid
			end

			for _, v in BaseParts do
				v.CanCollide = false
				v.AssemblyLinearVelocity = Vector3.zero
				v.AssemblyAngularVelocity = Vector3.zero
				if not v:FindFirstAncestorWhichIsA("Tool") then
					v.LocalTransparencyModifier = ltm
				end
			end

			-- The rig's own parts are the stand-in. Hide them while the real
			-- limbs are following; show them at 0.5 when they are not, so a
			-- broken reanimate is obvious instead of invisible.
			local ph = ReanimOkay and 1 or Reanimate.PlaceholderTransparency
			for _, v in Reanimate.RigParts do
				if v.Parent then
					v.Transparency = ph
				end
			end

			if Character and Humanoid and RootPart then
				RunService.Heartbeat:Wait()
				local t = os.clock()

				--[[
					Gated on the ROOT only. This used to require RCTorso too,
					which does not exist on an R15 rig -- so the whole block was
					skipped, every RootPart Mode silently became "very void",
					and the body was dragged to Y = -70000 no matter what you
					picked. Mode 4 is the only line that actually needs a torso.
				]]
				if RCRootPart then
					if LR.Mode == 1 then
						rootcf = CFrame.new(rootposition2)
					end
					-- Streaming forces mode 2: a root 70k studs away unstreams
					-- and the writes stop landing.
					if LR.Mode == 2 or Workspace.StreamingEnabled then
						rootcf = CFrame.new(RCRootPart.Position + Vector3.new(0, -16, 0))
					end
					if LR.Mode == 3 then rootcf = RCRootPart.CFrame end
					if LR.Mode == 4 then
						rootcf = (RCTorso and RCTorso.CFrame) or RCRootPart.CFrame
					end

					if LR.Velocity == 1 then
						rootvel = RCRootPart.AssemblyLinearVelocity
					elseif LR.Velocity == 2 then
						rootvel = Vector3.new(0, 16384, 0)
					end
				end

				flingtarget = LR.FlingTargets[1]
				if flingtarget then
					if flingtarget.Time then
						if t > flingtarget.Time then
							table.remove(LR.FlingTargets, 1)
							flingtarget = nil
						end
					else
						flingtarget.Time = t + (flingtarget.Duration
							or (Reanimate.UsePhysicsRepRootPart and (LR.UseNaNFling and 1 or 0.5) or 2))
					end
				end

				if flingtarget then
					local flinged
					flingcf, flinged = Util.PredictionFling(flingtarget.Target)
					if flinged then
						table.remove(LR.FlingTargets, 1)
						flingtarget = nil
					end
				end

				-- Drift against the PREVIOUS frame's target, measured before we
				-- overwrite it. This is the signal that says whether the writes
				-- are landing.
				if lastRootTarget and not flingtarget then
					local d = (RootPart.Position - lastRootTarget).Magnitude
					LR.Diag.Drift = d
					if d > LR.Diag.MaxDrift then LR.Diag.MaxDrift = d end
				end
				lastRootTarget = flingtarget and nil or rootcf.Position
				LR.Diag.RootY = rootcf.Position.Y
				LR.Diag.RootMode = ({
					"very void", "void", "streamed", "on rig root", "on rig torso",
				})[LR.Mode + 1] or "?"
				if Workspace.StreamingEnabled and LR.Mode ~= 2 then
					LR.Diag.RootMode ..= " (forced streamed)"
				end

				-- Count the driven joints and, in the same pass, notice when the
				-- set of them changes so the hide panel can rebuild itself from
				-- the real rig instead of a hardcoded list.
				local mapped = 0
				local sig = table.create(#LimbMapping)
				for _, m in LimbMapping do
					if m.Reference then
						mapped += 1
						table.insert(sig, m.Part1)
					end
				end
				-- Auto only downgrades when nothing matched, so a normal body is
				-- never dropped to loose parts by accident.
				if LR.DriveMode == 1 then
					DriveLoose = false
				elseif LR.DriveMode == 2 then
					DriveLoose = true
				else
					DriveLoose = mapped == 0
				end
				LR.Diag.Drive = DriveLoose and "loose parts" or "joints"

				-- Loose mode keys off the part count, since LimbMapping is empty.
				local sigstr = DriveLoose
					and ("L:" .. #BaseParts)
					or ("J:" .. table.concat(sig, ";"))
				if sigstr ~= LR._LimbSig then
					LR._LimbSig = sigstr
					local list = {}
					if DriveLoose then
						-- Loose mode hides whole PARTS, so list what can
						-- actually be driven: real parts with a rig twin.
						for _, v in BaseParts do
							if v ~= RootPart and v.Parent
								and not v:FindFirstAncestorWhichIsA("Tool")
								and RC and RC:FindFirstChild(v.Name)
							then
								table.insert(list, v.Name)
							end
						end
					else
						for _, m in LimbMapping do
							-- The root entry is excluded: hiding it would take
							-- the whole body, which is RootPart Mode's job.
							if m.Reference and m.RPart0 ~= "ROOT" then
								table.insert(list, m.Part1)
							end
						end
					end
					table.sort(list)
					LR.LimbList = list
					LR.LimbListVersion += 1
				end
				-- Throttled: a character with accessories is a lot of
				-- descendants to walk every frame.
				if os.clock() - lastJointScan > 0.5 then
					lastJointScan = os.clock()
					local real = 0
					for _, d in Character:GetDescendants() do
						if d:IsA("Motor6D") then real += 1 end
					end
					LR.Diag.RealJoints = real
					LR.Diag.RigParts = RC and #Reanimate.RigBodyParts or 0

					local rj = 0
					if RC then
						for _, d in RC:GetDescendants() do
							if d:IsA("Motor6D") then rj += 1 end
						end
					end
					LR.Diag.RigJoints = rj
					LR.Diag.BodyState = Humanoid:GetState().Name
					LR.Diag.Health = ("%d/%d"):format(
						math.floor(Humanoid.Health), math.floor(Humanoid.MaxHealth))
				end

				LR.Diag.Mapped = mapped
				LR.Diag.Unmapped = #UnknownMotor6Ds
				LR.Diag.RigType = (Humanoid.RigType == Enum.HumanoidRigType.R6) and "R6" or "R15"

				UpdateTransforms(RC, RootPart, rootcf, rootvel, flingtarget, flingcf)

				if LR.UseNaNFling then
					-- A NaN move direction makes the server humanoid solver
					-- produce garbage, which is what does the flinging.
					if os.clock() - lastspawn > 0.1 then
						SetHidden(Humanoid, "MoveDirectionInternal", Vector3.new(0 / 0, 0 / 0, 0 / 0))
					else
						SetHidden(Humanoid, "MoveDirectionInternal", Vector3.zero)
					end
					SetHidden(Humanoid, "NetworkHumanoidState", Enum.HumanoidStateType.Freefall)
				else
					SetHidden(Humanoid, "NetworkHumanoidState", Enum.HumanoidStateType[
						({ "Running", "PlatformStanding", "Jumping", "Ragdoll", "Seated", "Physics" })[math.random(1, 6)]
					])
				end
			end

			-- Second write of the same frame, after animation and right before
			-- the draw, so the pose you see is the pose that was sent.
			RunService.PreRender:Wait()
			if Character and Humanoid and RootPart then
				UpdateTransforms(RC, RootPart, rootcf, rootvel, flingtarget, flingcf)
			end
		end
	end

	LR.Status = "STOPPING"
	CharConn:Disconnect()

	if NoRespawn then
		-- Hand the same body back instead of throwing it away.
		LR.Status = "RESTORING"
		pcall(RestoreCharacter)
	else
		-- Leaving the loop with the real character still puppeted would strand
		-- you in the void, so kill it once more and let the server respawn you
		-- clean.
		if Player.Character then
			local h = Player.Character:FindFirstChildOfClass("Humanoid")
			if h then
				h:SetStateEnabled(Enum.HumanoidStateType.Dead, true)
				h:ChangeState(Enum.HumanoidStateType.Dead)
			end
		end
	end

	pcall(function() Workspace.FallenPartsDestroyHeight = FallenPartsDestroyHeight end)
	Reanimate.Stopping = false
	Reanimate.DestroyCharacter()
	if Camera then
		local c = Player.Character
		Camera.CameraSubject = c and c:FindFirstChildOfClass("Humanoid") or nil
	end
	LR.Status = "IDLE"
end

--==============================================================================
-- 8. GUI
--
-- Deliberately square: there is not a single UICorner in this file.
-- Draggable by the title bar, collapsible to the title bar, and removable.
--==============================================================================

local COL = {
	BG      = Color3.fromRGB(16, 16, 18),
	BAR     = Color3.fromRGB(26, 26, 30),
	ITEM    = Color3.fromRGB(34, 34, 40),
	ITEMHOV = Color3.fromRGB(48, 48, 56),
	LINE    = Color3.fromRGB(70, 70, 80),
	TEXT    = Color3.fromRGB(225, 225, 230),
	DIM     = Color3.fromRGB(140, 140, 150),
	ON      = Color3.fromRGB(90, 220, 130),
	OFF     = Color3.fromRGB(210, 80, 80),
	ACCENT  = Color3.fromRGB(120, 170, 255),
}

local FONT = Enum.Font.Code

local Gui = {}

local function stroke(inst, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or COL.LINE
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = inst
	return s
end

local function label(parent, text, size, color, align)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	-- Wrapped text needs to size itself. A fixed one-line height silently clips
	-- every explainer in this menu to its first line.
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.Font = FONT
	l.Text = text
	l.TextSize = size
	l.TextColor3 = color or COL.DIM
	l.TextXAlignment = align or Enum.TextXAlignment.Left
	l.TextWrapped = true
	l.Parent = parent
	return l
end

local function separator(parent)
	local f = Instance.new("Frame")
	f.BackgroundColor3 = COL.LINE
	f.BorderSizePixel = 0
	f.Size = UDim2.new(1, 0, 0, 1)
	f.Parent = parent
	return f
end

local function baseButton(parent, height)
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = COL.ITEM
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.Size = UDim2.new(1, 0, 0, height or 24)
	b.Font = FONT
	b.TextSize = 13
	b.TextColor3 = COL.TEXT
	b.Text = ""
	b.Parent = parent
	stroke(b)
	b.MouseEnter:Connect(function() b.BackgroundColor3 = COL.ITEMHOV end)
	b.MouseLeave:Connect(function() b.BackgroundColor3 = COL.ITEM end)
	return b
end

local function button(parent, text, cb, height)
	local b = baseButton(parent, height)
	b.Text = text
	b.Activated:Connect(function()
		local ok, err = pcall(cb, b)
		if not ok then warn("[LimbReanimate] " .. tostring(err)) end
	end)
	return b
end

local function toggle(parent, text, default, cb)
	local state = default and true or false
	local b = baseButton(parent)
	b.TextXAlignment = Enum.TextXAlignment.Left

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = b

	b.Text = text

	local ind = Instance.new("TextLabel")
	ind.BackgroundTransparency = 1
	ind.AnchorPoint = Vector2.new(1, 0.5)
	ind.Position = UDim2.new(1, 0, 0.5, 0)
	ind.Size = UDim2.new(0, 40, 1, 0)
	ind.Font = FONT
	ind.TextSize = 13
	ind.TextXAlignment = Enum.TextXAlignment.Right
	ind.Parent = b

	local function paint()
		ind.Text = state and "[ON]" or "[OFF]"
		ind.TextColor3 = state and COL.ON or COL.OFF
	end
	paint()

	b.Activated:Connect(function()
		state = not state
		paint()
		local ok, err = pcall(cb, state)
		if not ok then warn("[LimbReanimate] " .. tostring(err)) end
	end)

	-- Third return is a setter, so code can flip the value AND the widget
	-- together. Setting one without the other leaves the menu lying.
	return b, function() return state end, function(v)
		state = v and true or false
		paint()
	end
end

local function dropdown(parent, text, options, defaultIndex, cb)
	local index = defaultIndex or 1
	local open = false

	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.new(1, 0, 0, 24)
	holder.ClipsDescendants = false
	holder.Parent = parent

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 2)
	list.Parent = holder

	local head = baseButton(holder)
	head.LayoutOrder = 0
	head.TextXAlignment = Enum.TextXAlignment.Left
	local hp = Instance.new("UIPadding")
	hp.PaddingLeft = UDim.new(0, 6)
	hp.PaddingRight = UDim.new(0, 6)
	hp.Parent = head

	local val = Instance.new("TextLabel")
	val.BackgroundTransparency = 1
	val.AnchorPoint = Vector2.new(1, 0.5)
	val.Position = UDim2.new(1, 0, 0.5, 0)
	val.Size = UDim2.new(0.62, 0, 1, 0)
	val.Font = FONT
	val.TextSize = 12
	val.TextColor3 = COL.ACCENT
	val.TextXAlignment = Enum.TextXAlignment.Right
	val.TextTruncate = Enum.TextTruncate.AtEnd
	val.Parent = head

	local body = Instance.new("Frame")
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.LayoutOrder = 1
	body.Size = UDim2.new(1, 0, 0, 0)
	body.Visible = false
	body.Parent = holder

	local blist = Instance.new("UIListLayout")
	blist.SortOrder = Enum.SortOrder.LayoutOrder
	blist.Padding = UDim.new(0, 1)
	blist.Parent = body

	local optButtons = {}

	local function paint()
		head.Text = text
		val.Text = options[index] or "?"
		for i, ob in optButtons do
			ob.TextColor3 = (i == index) and COL.ACCENT or COL.DIM
		end
	end

	local function resize()
		local h = 24
		if open then
			body.Size = UDim2.new(1, 0, 0, #options * 21 + (#options - 1))
			h = h + 2 + body.Size.Y.Offset
		else
			body.Size = UDim2.new(1, 0, 0, 0)
		end
		holder.Size = UDim2.new(1, 0, 0, h)
	end

	local disabled = {}

	for i, opt in options do
		local ob = baseButton(body, 21)
		ob.LayoutOrder = i
		ob.Text = "  " .. opt
		ob.TextSize = 12
		ob.TextXAlignment = Enum.TextXAlignment.Left
		ob.BackgroundColor3 = COL.BG
		ob.MouseEnter:Connect(function()
			if not disabled[i] then ob.BackgroundColor3 = COL.ITEM end
		end)
		ob.MouseLeave:Connect(function() ob.BackgroundColor3 = COL.BG end)
		ob.Activated:Connect(function()
			if disabled[i] then return end
			index = i
			open = false
			body.Visible = false
			paint()
			resize()
			local ok, err = pcall(cb, i, opt)
			if not ok then warn("[LimbReanimate] " .. tostring(err)) end
		end)
		optButtons[i] = ob
	end

	-- Greys an option out and makes it unselectable.
	local function setDisabled(i, off, suffix)
		disabled[i] = off or nil
		local ob = optButtons[i]
		if ob then
			ob.Text = "  " .. options[i] .. (off and (suffix or " (unavailable)") or "")
			ob.TextTransparency = off and 0.45 or 0
		end
	end

	local function setIndex(i)
		index = i
		paint()
	end

	head.Activated:Connect(function()
		open = not open
		body.Visible = open
		resize()
	end)

	paint()
	resize()

	return holder, function() return index end, setDisabled, setIndex
end

-- A collapsible section. Unlike dropdown() this does not know how many rows it
-- will hold, so it sizes itself from its children.
local function foldout(parent, text)
	local open = false

	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.new(1, 0, 0, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.Parent = parent

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 2)
	list.Parent = holder

	local head = baseButton(holder)
	head.LayoutOrder = 0
	head.TextXAlignment = Enum.TextXAlignment.Left
	local hp = Instance.new("UIPadding")
	hp.PaddingLeft = UDim.new(0, 6)
	hp.PaddingRight = UDim.new(0, 6)
	hp.Parent = head

	local sect = Instance.new("Frame")
	sect.BackgroundTransparency = 1
	sect.BorderSizePixel = 0
	sect.LayoutOrder = 1
	sect.Size = UDim2.new(1, 0, 0, 0)
	sect.AutomaticSize = Enum.AutomaticSize.Y
	sect.Visible = false
	sect.Parent = holder

	local blist = Instance.new("UIListLayout")
	blist.SortOrder = Enum.SortOrder.LayoutOrder
	blist.Padding = UDim.new(0, 1)
	blist.Parent = sect

	local function paint()
		head.Text = (open and "v  " or ">  ") .. text
	end
	paint()

	head.Activated:Connect(function()
		open = not open
		sect.Visible = open
		paint()
	end)

	return sect
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local screen = Instance.new("ScreenGui")
screen.Name = "LR_" .. tostring(math.random(100000, 999999))
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.DisplayOrder = 999

do
	local parented = false
	if Env.gethui then
		parented = pcall(function() screen.Parent = Env.gethui() end)
	end
	if not parented then
		parented = pcall(function() screen.Parent = CoreGui end)
	end
	if not parented then
		screen.Parent = Player:WaitForChild("PlayerGui")
	end
end

local WIN_W, BAR_H, BODY_H = 268, 26, 372

local win = Instance.new("Frame")
win.Name = "Window"
win.BackgroundColor3 = COL.BG
win.BorderSizePixel = 0
win.Position = UDim2.new(0, 40, 0, 120)
win.Size = UDim2.new(0, WIN_W, 0, BAR_H + BODY_H)
win.Active = true
win.Parent = screen
stroke(win, COL.LINE, 1)

-- Title bar --------------------------------------------------------------
local bar = Instance.new("Frame")
bar.BackgroundColor3 = COL.BAR
bar.BorderSizePixel = 0
bar.Size = UDim2.new(1, 0, 0, BAR_H)
bar.Active = true -- required, or the Frame never receives InputBegan to drag with
bar.Parent = win

local barline = Instance.new("Frame")
barline.BackgroundColor3 = COL.LINE
barline.BorderSizePixel = 0
barline.AnchorPoint = Vector2.new(0, 1)
barline.Position = UDim2.new(0, 0, 1, 0)
barline.Size = UDim2.new(1, 0, 0, 1)
barline.Parent = bar

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 8, 0, 0)
title.Size = UDim2.new(1, -70, 1, 0)
title.Font = FONT
title.TextSize = 13
title.TextColor3 = COL.TEXT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "LimbReanimate v" .. SCRIPT_VERSION
title.Parent = bar

local function barButton(text, offsetFromRight, color)
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = COL.BAR
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.AnchorPoint = Vector2.new(1, 0)
	b.Position = UDim2.new(1, -offsetFromRight, 0, 0)
	b.Size = UDim2.new(0, BAR_H, 0, BAR_H)
	b.Font = FONT
	b.TextSize = 14
	b.TextColor3 = color or COL.TEXT
	b.Text = text
	b.Parent = bar
	b.MouseEnter:Connect(function() b.BackgroundColor3 = COL.ITEMHOV end)
	b.MouseLeave:Connect(function() b.BackgroundColor3 = COL.BAR end)
	return b
end

local btnClose = barButton("X", 0, COL.OFF)
local btnCollapse = barButton("-", BAR_H)

-- Body -------------------------------------------------------------------
local body = Instance.new("ScrollingFrame")
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.Position = UDim2.new(0, 0, 0, BAR_H)
body.Size = UDim2.new(1, 0, 1, -BAR_H)
body.CanvasSize = UDim2.new(0, 0, 0, 0)
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.ScrollBarThickness = 4
body.ScrollBarImageColor3 = COL.LINE
body.Parent = win

local bodyPad = Instance.new("UIPadding")
bodyPad.PaddingTop = UDim.new(0, 6)
bodyPad.PaddingLeft = UDim.new(0, 6)
bodyPad.PaddingRight = UDim.new(0, 8)
bodyPad.PaddingBottom = UDim.new(0, 6)
bodyPad.Parent = body

local bodyList = Instance.new("UIListLayout")
bodyList.SortOrder = Enum.SortOrder.LayoutOrder
bodyList.Padding = UDim.new(0, 4)
bodyList.Parent = body

-- Drag -------------------------------------------------------------------
do
	local dragging, dragStart, startPos = false, nil, nil
	bar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = win.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	Gui.DragConn = UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local d = input.Position - dragStart
			win.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y
			)
		end
	end)
end

-- Collapse ---------------------------------------------------------------
local collapsed = false
btnCollapse.Activated:Connect(function()
	collapsed = not collapsed
	body.Visible = not collapsed
	btnCollapse.Text = collapsed and "+" or "-"
	win.Size = collapsed
		and UDim2.new(0, WIN_W, 0, BAR_H)
		or UDim2.new(0, WIN_W, 0, BAR_H + BODY_H)
end)

--==============================================================================
-- 9. MENU CONTENT
--==============================================================================

local statusLabel

local function SetReanimating(on)
	if on == Reanimate.Running then return end
	if on then
		Reanimate.Starting = true
		Reanimate.Running = true
		task.spawn(function()
			local ok, err = pcall(LR.Start)
			if not ok then
				warn("[LimbReanimate] Start failed: " .. tostring(err))
				LR.Status = "ERROR"
			end
			Reanimate.Running = false
			Reanimate.Starting = false
			Reanimate.Stopping = false
		end)
	else
		Reanimate.Stopping = true
	end
end

label(body, "REANIMATOR: LIMBS", 13, COL.TEXT, Enum.TextXAlignment.Center)
statusLabel = label(body, "Running: NONE", 12, COL.DIM, Enum.TextXAlignment.Center)

local reanimBtn = button(body, "* Reanimate *", function(b)
	b.Interactable = false
	if Reanimate.Running then
		b.Text = "Stopping..."
		SetReanimating(false)
		repeat task.wait() until not Reanimate.Running
		task.wait(0.5)
		b.Text = "* Reanimate *"
	else
		b.Text = "Starting..."
		SetReanimating(true)
		repeat task.wait() until not Reanimate.Starting or not Reanimate.Running
		task.wait(0.5)
		b.Text = Reanimate.Running and "* Deanimate *" or "* Reanimate *"
	end
	b.Interactable = true
end, 30)
reanimBtn.TextSize = 15

button(body, "Show Reanimate Hitboxes", function()
	if not Reanimate.Character then return end
	LR.ShowHitboxes()
end)

button(body, "Refresh Reanimate Character", function()
	if not Reanimate.Character then return end
	Reanimate.CreateCharacter()
end)

separator(body)
label(body, "LIMBS CONFIG", 13, COL.TEXT, Enum.TextXAlignment.Center)
label(body,
	"Only works in SOME games. Games that recreate the Animator automatically will fight the joint writes and win.",
	11, COL.DIM, Enum.TextXAlignment.Center)

local _, _, rigSrcSetDisabled, rigSrcSetIndex = dropdown(body, "Rig Source", {
	"Built-in R6",
	"Origin Only (clone)",
}, Reanimate.RigSource + 1, function(i) Reanimate.RigSource = i - 1 end)
local rigSrcWarn = label(body, "", 11, COL.OFF, Enum.TextXAlignment.Center)
rigSrcWarn.Visible = false
label(body,
	"Origin Only uses a clone of your real character as the rig: identity mapping, R6 or R15, your real part names and a working Animator, so external animation scripts can drive it like a real character.",
	11, COL.DIM, Enum.TextXAlignment.Center)

dropdown(body, "RootPart Mode", {
	"RootPart in very void",
	"RootPart in void",
	"Keep RootPart Streamed",
	"CurrentAngle Style",
	"RootPart is Torso",
}, LR.Mode + 1, function(i) LR.Mode = i - 1 end)

dropdown(body, "RootPart Velocity", {
	"No Velocity",
	"Follow Character",
	"Fling-like",
}, LR.Velocity + 1, function(i) LR.Velocity = i - 1 end)

dropdown(body, "Init Mode", {
	"Reset Character",
	"CDSB + Reset",
	"CDSB + SSE + Kill",
	"No Kill (in-place)",
}, LR.InitMode + 1, function(i) LR.InitMode = i - 1 end)
label(body,
	"No Kill never kills you at all: it takes animation authority from the body you already have, and Deanimate hands that same body back. It is NOT the permadeath 'no respawn' reanimate.",
	11, COL.DIM, Enum.TextXAlignment.Center)

dropdown(body, "Drive Mode", {
	"Auto",
	"Joints only",
	"Loose Parts only",
}, LR.DriveMode + 1, function(i) LR.DriveMode = i - 1 end)
label(body,
	"Joints writes Motor6D transforms and keeps the body one assembly. Loose Parts writes each limb's CFrame directly, for bodies that come back with no joints at all. Auto only falls back when nothing matched.",
	11, COL.DIM, Enum.TextXAlignment.Center)

do
	local _, _, setAnim = toggle(body, "Animate Fake Rig", Reanimate.AnimateRig,
		function(v) Reanimate.AnimateRig = v end)
	Reanimate.SyncAnimateToggle = setAnim
end
label(body,
	"Plays your own character animations on the rig, which is what your real limbs then copy. Turn OFF to hand the rig's Animator to your own script instead.",
	11, COL.DIM, Enum.TextXAlignment.Center)

toggle(body, "Show me how I look!", LR.ReplicateFPS10, function(v) LR.ReplicateFPS10 = v end)
toggle(body, "Target Fling Enabled", LR.FlingEnabled, function(v) LR.FlingEnabled = v end)
label(body, "^ touch a player = they lose ownership", 11, COL.DIM, Enum.TextXAlignment.Center)
toggle(body, "Use NaN State Fling", LR.UseNaNFling, function(v) LR.UseNaNFling = v end)
toggle(body, "Root Jitter", LR.RootJitter, function(v) LR.RootJitter = v end)
label(body,
	"Root Jitter nudges the root 0.005 studs each frame so identical CFrames are not dropped before replicating. Off = steadier torso.",
	11, COL.DIM, Enum.TextXAlignment.Center)

separator(body)
local limbPanel = foldout(body, "Hide Limbs")
label(body,
	"Sends a limb to a hold spot far away instead of to the rig. Nothing is deleted and no joint is broken, so clicking again brings it straight back. The list is built from your real rig once you reanimate.",
	11, COL.DIM, Enum.TextXAlignment.Center)

local limbPanelVersion = -1
local function rebuildLimbRows()
	for _, c in limbPanel:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end

	local list = LR.LimbList
	if not list or #list == 0 then
		label(limbPanel, "  (reanimate to list your joints)", 11, COL.DIM, Enum.TextXAlignment.Left)
		return
	end

	for i, name in list do
		local b = baseButton(limbPanel, 21)
		b.LayoutOrder = i
		b.TextSize = 12
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.Text = name

		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 6)
		pad.PaddingRight = UDim.new(0, 6)
		pad.Parent = b

		local ind = Instance.new("TextLabel")
		ind.BackgroundTransparency = 1
		ind.AnchorPoint = Vector2.new(1, 0.5)
		ind.Position = UDim2.new(1, 0, 0.5, 0)
		ind.Size = UDim2.new(0, 62, 1, 0)
		ind.Font = FONT
		ind.TextSize = 12
		ind.TextXAlignment = Enum.TextXAlignment.Right
		ind.Parent = b

		local function paint()
			local hidden = LR.HiddenLimbs[name]
			ind.Text = hidden and "[HIDDEN]" or "[SHOWN]"
			ind.TextColor3 = hidden and COL.OFF or COL.ON
		end
		paint()

		b.Activated:Connect(function()
			LR.HiddenLimbs[name] = (not LR.HiddenLimbs[name]) or nil
			paint()
		end)
	end
end
rebuildLimbRows()

separator(body)
label(body, "DIAGNOSTICS", 13, COL.TEXT, Enum.TextXAlignment.Center)
local diagLabel = label(body, "(not running)", 11, COL.DIM, Enum.TextXAlignment.Left)
-- Five lines, not one: let it size itself.
diagLabel.TextWrapped = false
diagLabel.Size = UDim2.new(1, 0, 0, 0)
diagLabel.AutomaticSize = Enum.AutomaticSize.Y
label(body,
	"Drift is how far the root moved off target between frames. ~2 studs is the normal settle band. Hundreds means something is winning against the writes.",
	11, COL.DIM, Enum.TextXAlignment.Center)

separator(body)
label(body, "Rig Source and Init Mode apply on the NEXT reanimate. Everything else is live.", 11, COL.DIM, Enum.TextXAlignment.Center)
label(body, "RightControl hides/shows this window.", 11, COL.DIM, Enum.TextXAlignment.Center)

if not App.HasHiddenProps then
	separator(body)
	label(body,
		"WARNING: no sethiddenproperty / setscriptable in this executor. Joint writes will NOT replicate -- only you will see the reanimate.",
		11, COL.OFF, Enum.TextXAlignment.Center)
end

--==============================================================================
-- 10. LIFECYCLE
--==============================================================================

--[[
	There is no built-in R15 rig. On an R15 character the built-in R6 rig can
	only reach 6 of your ~14 joints -- everything below an elbow or knee has no
	R6 counterpart and stays pinned at rest -- so it is greyed out and Origin
	Only, whose mapping is identity, is selected instead.

	Only the dropdown entry is blocked. The internal fallback that catches a
	failed clone still reaches the built-in rig, because having no rig at all
	would be worse.
]]
--[[
	Built-in is no longer R6-only, so nothing is greyed out any more: on an R15
	character it builds a skeleton from your own rig instead of the hardcoded R6
	one, and the mapping switches to identity to match. This just says which one
	you are going to get.
]]
local r15Shown = nil
local function ShowRigSourceKind()
	local char = Player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	local isR15 = hum.RigType == Enum.HumanoidRigType.R15
	if isR15 == r15Shown then return end
	r15Shown = isR15

	rigSrcSetDisabled(1, false)
	rigSrcWarn.Visible = true
	rigSrcWarn.TextColor3 = COL.DIM
	rigSrcWarn.Text = isR15
		and "Your rig is R15. Built-in will auto-build an R15 skeleton from it, identity-mapped."
		or "Your rig is R6. Built-in will use the hardcoded R6 skeleton."
end

local statusConn = RunService.Heartbeat:Connect(function()
	if not statusLabel.Parent then return end

	pcall(ShowRigSourceKind)

	-- The joint set is only known once a reanimate has discovered it, and it
	-- changes with rig source and rig type, so the panel follows it.
	if LR.LimbListVersion ~= limbPanelVersion then
		limbPanelVersion = LR.LimbListVersion
		rebuildLimbRows()
	end

	if Reanimate.Running then
		statusLabel.Text = "Running: Limbs (" .. LR.Status .. ")"
		statusLabel.TextColor3 = COL.ON

		local d = LR.Diag
		local loose = d.Drive == "loose parts"
		diagLabel.Text = table.concat({
			("rig    : %s"):format(Reanimate.RigKind or "?"),
			("       : %d parts, %d joints"):format(d.RigParts, d.RigJoints),
			("body   : %s, %d joints, %s"):format(d.RigType, d.RealJoints, d.BodyState),
			("health : %s  resp %d"):format(d.Health, d.Respawns),
			loose
				and ("drive  : loose, %d parts driven"):format(d.PartsDriven)
				or ("drive  : joints, %d driven, %d pinned"):format(d.Mapped, d.Unmapped),
			("root   : %s, y %.0f"):format(d.RootMode, d.RootY),
			("drift  : %.2f now, %.2f max"):format(d.Drift, d.MaxDrift),
			("replic : %s"):format(App.HasHiddenProps and "yes" or "NO (local only)"),
		}, "\n")
		-- A rig with no joints of its own is the one state nothing recovers from.
		diagLabel.TextColor3 = (d.RigJoints == 0 or d.MaxDrift > 50) and COL.OFF or COL.DIM
	else
		statusLabel.Text = "Running: NONE"
		statusLabel.TextColor3 = COL.DIM
		diagLabel.Text = "(not running)"
		diagLabel.TextColor3 = COL.DIM
	end
end)

local hideConn = UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
	if input.KeyCode == Enum.KeyCode.RightControl then
		win.Visible = not win.Visible
	end
end)

function App.Unload()
	pcall(function()
		if Reanimate.Running then
			Reanimate.Stopping = true
			local deadline = os.clock() + 3
			repeat task.wait() until not Reanimate.Running or os.clock() > deadline
		end
	end)
	pcall(function() Reanimate.DestroyCharacter() end)
	pcall(function() Workspace.FallenPartsDestroyHeight = FallenPartsDestroyHeight end)
	if statusConn then statusConn:Disconnect() end
	if hideConn then hideConn:Disconnect() end
	if JumpConn then JumpConn:Disconnect() end
	if Gui.DragConn then Gui.DragConn:Disconnect() end
	pcall(function() screen:Destroy() end)
	if _G.LimbReanimate == App then _G.LimbReanimate = nil end
end

btnClose.Activated:Connect(function()
	task.spawn(App.Unload)
end)

App.Reanimate = Reanimate
App.LimbReanimator = LR
App.Util = Util
App.Gui = screen

return App
