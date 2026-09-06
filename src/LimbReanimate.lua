--[[
	LimbReanimate
	Standalone limb reanimator for Roblox exploit environments.

	Limb-reanimation logic derived from the "Uhhhhhh" script by STEVETHEREALONE
	(LimbReanimator only). Everything else here -- UI, control, packaging -- is new.

	Repo: https://github.com/HiddenProto/LimbReanimate
]]

local SCRIPT_VERSION = "1.0.1"

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

	local RC = BuildFakeRig()
	pcall(function() RC.ModelStreamingMode = Enum.ModelStreamingMode.Persistent end)
	-- Without this the engine unloads the void-parked real root and our writes
	-- stop landing.
	pcall(function() Player.ReplicationFocus = Workspace end)

	RC:ScaleTo(Reanimate.CharacterScale)
	RC.Parent = Workspace

	local RCRoot = RC.HumanoidRootPart
	local RCHum = RC.Humanoid
	RCRoot.RootPriority = 67
	RCRoot.CFrame = cf

	local bf = Util.Instance("BodyForce", RCRoot)
	bf.Force = Vector3.zero

	Reanimate.Character = RC

	-- Drive the fake rig from real player input.
	RigDriveConn = RunService.PreSimulation:Connect(function()
		if not RC.Parent then return end
		local mv = Vector3.zero
		if Controls then
			local ok, v = pcall(function() return Controls:GetMoveVector() end)
			if ok and typeof(v) == "Vector3" then mv = v end
		end
		if mv.Magnitude > 1 then mv = mv.Unit end
		RCHum:Move(mv, true)
		RCHum.Jump = os.clock() < JumpUntil
		-- The rig is client-only; if it falls past the destroy plane, catch it.
		if RCRoot.Position.Y < FallenPartsDestroyHeight + 3 * Reanimate.CharacterScale then
			RCRoot.CFrame = CFrame.new(Camera.Focus.Position)
			RCRoot.AssemblyLinearVelocity = Vector3.zero
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
-- 0 = Reset Character      1 = CDSB + Reset      2 = CDSB + SSE + Kill

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
	local LimbNames = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }

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

	local InitCFrame = nil
	if Player.Character then
		local h = Player.Character:FindFirstChildOfClass("Humanoid")
		if h and h.RootPart then
			InitCFrame = h.RootPart.CFrame
			DoInit(h)
		end
	end

	local LimbMapping = MakeLimbMap()

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
		RightGrip.Part0 = Reanimate.Character and Reanimate.Character:FindFirstChild("Right Arm")
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
				v.CanCollide = false
				v:GetPropertyChangedSignal("CanCollide"):Connect(function()
					if v.CanCollide then v.CanCollide = false end
				end)
			end
		elseif v:IsA("Motor6D") then
			repeat task.wait() until (not v:IsDescendantOf(Workspace)) or (v.Part0 and v.Part1)
			if not v:IsDescendantOf(Workspace) then return end
			local p0, p1 = v.Part0, v.Part1
			if p0 and p1 then
				p0, p1 = p0.Name, p1.Name
				for _, map in LimbMapping do
					if map.Part0 == p0 and map.Part1 == p1 then
						map.Reference = v
						return
					end
				end
			end
			table.insert(UnknownMotor6Ds, v)
		elseif v:IsA("Animator") then
			-- The single most important cleanup. An Animator will fight every
			-- transform we write, one frame at a time, and win.
			task.defer(v.Destroy, v)
		elseif v:IsA("LocalScript") and v.Parent == Player.Character then
			v.Enabled = false
			v:GetPropertyChangedSignal("Enabled"):Connect(function()
				if v.Enabled then v.Enabled = false end
			end)
			v:GetPropertyChangedSignal("Disabled"):Connect(function()
				if not v.Disabled then v.Disabled = true end
			end)
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
	local CharConn = Player.CharacterAdded:Connect(function(character)
		-- The engine snaps the camera to the new character. Put it back before
		-- the frame is drawn so respawns are not visible as a camera jolt.
		local camcfr = Camera.CFrame
		RunService.PreRender:Once(function()
			RunService.PreAnimation:Wait()
			Camera.CFrame = camcfr
		end)
		lastspawn = os.clock()
		table.clear(BaseParts)
		table.clear(UnknownMotor6Ds)
		for _, map in LimbMapping do
			map.Reference = nil
		end
		character.DescendantAdded:Connect(CharOnDesc)
		for _, v in character:GetDescendants() do
			task.spawn(CharOnDesc, v)
		end
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid then
			local anim = humanoid:FindFirstChildWhichIsA("Animator")
			if anim then anim:Destroy() end
		end
		local animate = character:FindFirstChild("Animate")
		local deadline = os.clock() + 5
		while not animate and os.clock() < deadline do
			character.ChildAdded:Wait()
			animate = character:FindFirstChild("Animate")
		end
		if animate then animate:Destroy() end
	end)

	-- Bounded wait for the respawn. An unbounded CharacterAdded:Wait() strands
	-- the whole coroutine in games where the kill does not take, and the
	-- Deanimate button then has nothing to stop.
	LR.Status = "WAITING FOR RESPAWN"
	do
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

	Reanimate.CreateCharacter(InitCFrame)
	LR.Status = "RUNNING"

	----------------------------------------------------------------------------
	-- Per-frame write.
	----------------------------------------------------------------------------
	local lastrep = 0
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
				else
					local cf = CFrame.identity
					local p0 = RC:FindFirstChild(map.RPart0)
					local p1 = RC:FindFirstChild(map.RPart1)
					-- "ROOT" means the REAL root part, the one in the void.
					-- This single substitution is what makes the root joint
					-- absorb the entire void offset.
					if map.RPart0 == "ROOT" then p0 = RootPart end
					if p0 and p1 then
						if map.Type == 1 then
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
			local RCTorso = RC:FindFirstChild("Torso")

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
			for _, v in RC:GetChildren() do
				if v:IsA("BasePart") and table.find(LimbNames, v.Name) then
					v.Transparency = ReanimOkay and 1 or Reanimate.PlaceholderTransparency
				end
			end

			if Character and Humanoid and RootPart then
				RunService.Heartbeat:Wait()
				local t = os.clock()

				if RCRootPart and RCTorso then
					if LR.Mode == 1 then
						rootcf = CFrame.new(rootposition2)
					end
					-- Streaming forces mode 2: a root 70k studs away unstreams
					-- and the writes stop landing.
					if LR.Mode == 2 or Workspace.StreamingEnabled then
						rootcf = CFrame.new(RCRootPart.Position + Vector3.new(0, -16, 0))
					end
					if LR.Mode == 3 then rootcf = RCRootPart.CFrame end
					if LR.Mode == 4 then rootcf = RCTorso.CFrame end

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

	-- Leaving the loop with the real character still puppeted would strand you
	-- in the void, so kill it once more and let the server respawn you clean.
	if Player.Character then
		local h = Player.Character:FindFirstChildOfClass("Humanoid")
		if h then
			h:SetStateEnabled(Enum.HumanoidStateType.Dead, true)
			h:ChangeState(Enum.HumanoidStateType.Dead)
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
	l.Size = UDim2.new(1, 0, 0, size + 8)
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

	return b, function() return state end
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

	for i, opt in options do
		local ob = baseButton(body, 21)
		ob.LayoutOrder = i
		ob.Text = "  " .. opt
		ob.TextSize = 12
		ob.TextXAlignment = Enum.TextXAlignment.Left
		ob.BackgroundColor3 = COL.BG
		ob.MouseEnter:Connect(function() ob.BackgroundColor3 = COL.ITEM end)
		ob.MouseLeave:Connect(function() ob.BackgroundColor3 = COL.BG end)
		ob.Activated:Connect(function()
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

	head.Activated:Connect(function()
		open = not open
		body.Visible = open
		resize()
	end)

	paint()
	resize()

	return holder, function() return index end
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
}, LR.InitMode + 1, function(i) LR.InitMode = i - 1 end)

toggle(body, "Show me how I look!", LR.ReplicateFPS10, function(v) LR.ReplicateFPS10 = v end)
toggle(body, "Target Fling Enabled", LR.FlingEnabled, function(v) LR.FlingEnabled = v end)
label(body, "^ touch a player = they lose ownership", 11, COL.DIM, Enum.TextXAlignment.Center)
toggle(body, "Use NaN State Fling", LR.UseNaNFling, function(v) LR.UseNaNFling = v end)
toggle(body, "Root Jitter", LR.RootJitter, function(v) LR.RootJitter = v end)
label(body,
	"Root Jitter nudges the root 0.005 studs each frame so identical CFrames are not dropped before replicating. Off = steadier torso.",
	11, COL.DIM, Enum.TextXAlignment.Center)

separator(body)
label(body, "Changes apply on the NEXT reanimate.", 11, COL.DIM, Enum.TextXAlignment.Center)
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

local statusConn = RunService.Heartbeat:Connect(function()
	if not statusLabel.Parent then return end
	if Reanimate.Running then
		statusLabel.Text = "Running: Limbs (" .. LR.Status .. ")"
		statusLabel.TextColor3 = COL.ON
	else
		statusLabel.Text = "Running: NONE"
		statusLabel.TextColor3 = COL.DIM
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
