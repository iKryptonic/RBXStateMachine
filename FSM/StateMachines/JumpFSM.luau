--!strict
-- @Name JumpFSM
-- @Author iKrypto
-- @Description Client-side FSM managing double jump lifecycle.
--   States: Grounded → InAir → ValidateFlip → DeductFlipStamina → PlayFlipSound → TriggerFlipAnimation → ApplyUpwardForce → RotateCharacter → Flipping → PlayLandSound → TriggerLandAnimation → Cooldown → Grounded

local Debris = game:GetService("Debris")

local JumpFSM = {
Name = "JumpFSM",
className = "JumpFSM",
validStates = { "Grounded", "InAir", "ValidateFlip", "DeductFlipStamina", "PlayFlipSound", "TriggerFlipAnimation", "ApplyUpwardForce", "RotateCharacter", "Flipping", "PlayLandSound", "TriggerLandAnimation", "Cooldown", "Completed", "Failed" },
terminalStates = { "Completed", "Failed" },
initialState = "Grounded",
}

local UPWARD_VELOCITY = 55
local JUMP_SOUND_ID = "rbxassetid://541909814"
local LAND_SOUND_ID = "rbxassetid://1248511833"
local FLIP_FRAMES = 12
local FLIP_ANGLE_STEP = 30
local COOLDOWN_DURATION = 1
local FLIP_TIMEOUT = 3
local DOUBLE_JUMP_STAMINA_COST = 20

local function getCharacterParts(fsm: any): (BasePart?, Humanoid?)
local orchestrator = (shared :: any).fsm
if not orchestrator then return nil, nil end
local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
if not charEntity or not charEntity.Instance then return nil, nil end
local character = charEntity.Instance
local rootPart = character:FindFirstChild("HumanoidRootPart")
local humanoid = character:FindFirstChildOfClass("Humanoid")
return rootPart :: BasePart?, humanoid :: Humanoid?
end

local function isAirborne(humanoid: Humanoid): boolean
local state = humanoid:GetState()
return state == Enum.HumanoidStateType.Jumping
or state == Enum.HumanoidStateType.Freefall
or state == Enum.HumanoidStateType.FallingDown
end

local function getCharacterEntity(fsm: any): any?
local orchestrator = (shared :: any).fsm
if not orchestrator then return nil end
return orchestrator.GetEntity(fsm.CharacterEntityId)
end

function JumpFSM:RegisterStates()
self:AddState("Grounded", {
OnEnter = function(_, fsm)
fsm.Context._flipRequested = false
fsm.Context._rootPart = nil
fsm.Context._humanoid = nil
fsm.Context._bodyVelocity = nil
end,
Transitions = {
{
Condition = function(fsm)
local _, humanoid = getCharacterParts(fsm)
if not humanoid then return false end
return isAirborne(humanoid)
end,
TargetState = "InAir",
},
},
}, { "InAir" })

self:AddState("InAir", {
OnEnter = function(_, fsm)
fsm.Context._flipRequested = false
end,
Transitions = {
{
Condition = function(fsm)
return fsm.Context._flipRequested == true
end,
TargetState = "ValidateFlip",
},
{
Condition = function(fsm)
local _, humanoid = getCharacterParts(fsm)
if not humanoid then return false end
return not isAirborne(humanoid)
end,
TargetState = "Grounded",
},
},
}, { "ValidateFlip", "Grounded" })

self:AddState("ValidateFlip", {
OnEnter = function(_, fsm)
local rootPart, humanoid = getCharacterParts(fsm)
if not rootPart or not humanoid or humanoid.Health <= 0 then
fsm.State = "Grounded"
return
end

fsm.Context._rootPart = rootPart
fsm.Context._humanoid = humanoid
fsm.State = "DeductFlipStamina"
end,
}, { "DeductFlipStamina", "Grounded" })

self:AddState("DeductFlipStamina", {
OnEnter = function(_, fsm)
local charEntity = getCharacterEntity(fsm)
local stamina = tonumber(charEntity and charEntity.Stamina) or 0
if not charEntity or stamina < DOUBLE_JUMP_STAMINA_COST then
fsm.Context._flipRequested = false
fsm.State = "InAir"
return
end

charEntity.Stamina = math.max(0, stamina - DOUBLE_JUMP_STAMINA_COST)
pcall(function()
charEntity:UpdateEntity()
end)
fsm.State = "PlayFlipSound"
end,
}, { "PlayFlipSound", "InAir" })

self:AddState("PlayFlipSound", {
OnEnter = function(_, fsm)
local rootPart = fsm.Context._rootPart
if rootPart and rootPart.Parent then
local sound = Instance.new("Sound")
sound.SoundId = JUMP_SOUND_ID
sound.Volume = 0.5
sound.Parent = rootPart
sound:Play()
Debris:AddItem(sound, 2)
end
fsm.State = "TriggerFlipAnimation"
end,
}, { "TriggerFlipAnimation" })

self:AddState("TriggerFlipAnimation", {
OnEnter = function(_, fsm)
local onAnimate = fsm.Context._onAnimate
if onAnimate then
task.spawn(function()
onAnimate("FrontFlip", 0.1, 0.15)
end)
end
fsm.State = "ApplyUpwardForce"
end,
}, { "ApplyUpwardForce" })

self:AddState("ApplyUpwardForce", {
OnEnter = function(_, fsm)
local rootPart = fsm.Context._rootPart
if not rootPart or not rootPart.Parent then
fsm.State = "Grounded"
return
end

local bodyVelocity = Instance.new("BodyVelocity")
bodyVelocity.MaxForce = Vector3.new(0, math.huge, 0)
bodyVelocity.Velocity = Vector3.new(0, UPWARD_VELOCITY, 0)
bodyVelocity.Parent = rootPart
fsm.Context._bodyVelocity = bodyVelocity
fsm.State = "RotateCharacter"
end,
}, { "RotateCharacter", "Grounded" })

self:AddState("RotateCharacter", {
OnEnter = function(_, fsm)
local rootPart = fsm.Context._rootPart
local bodyVelocity = fsm.Context._bodyVelocity
if rootPart then
task.spawn(function()
local rootJoint = rootPart:FindFirstChild("RootJoint")
if rootJoint then
local origC0 = rootJoint.C0
for i = 1, FLIP_FRAMES do
rootJoint.C0 = origC0 * CFrame.Angles(math.rad(-FLIP_ANGLE_STEP * i), 0, 0)
task.wait()
end
rootJoint.C0 = origC0
end
if bodyVelocity and bodyVelocity.Parent then
bodyVelocity:Destroy()
end
end)
end
fsm.State = "Flipping"
end,
}, { "Flipping" })

self:AddState("Flipping", {
OnEnter = function(_, fsm)
fsm.Context._flipRequested = false
end,
Transitions = {
{
Condition = function(fsm)
local _, humanoid = getCharacterParts(fsm)
if not humanoid then return true end
return not isAirborne(humanoid)
end,
TargetState = "PlayLandSound",
},
},
Timeout = FLIP_TIMEOUT,
OnTimeout = "Cooldown",
}, { "PlayLandSound", "Cooldown" })

self:AddState("PlayLandSound", {
OnEnter = function(_, fsm)
local rootPart = fsm.Context._rootPart
if rootPart and rootPart.Parent then
local sound = Instance.new("Sound")
sound.SoundId = LAND_SOUND_ID
sound.Volume = 0.35
sound.PlaybackSpeed = 0.9
sound.Parent = rootPart
sound:Play()
Debris:AddItem(sound, 2)
end
fsm.State = "TriggerLandAnimation"
end,
}, { "TriggerLandAnimation" })

self:AddState("TriggerLandAnimation", {
OnEnter = function(_, fsm)
local onAnimate = fsm.Context._onAnimate
if onAnimate then
onAnimate("SummonGroundCast")
end
fsm.State = "Cooldown"
end,
}, { "Cooldown" })

self:AddState("Cooldown", {
OnEnter = function(_, fsm)
fsm:ScheduleTransition(COOLDOWN_DURATION, "Grounded")
end,
}, { "Grounded" })

self:AddState("Completed", function(_fsm) end, {})
self:AddState("Failed", function(_fsm) end, {})
end

function JumpFSM.TryDoubleJump(fsm: any): boolean
if fsm.State ~= "InAir" then
return false
end
local charEntity = getCharacterEntity(fsm)
if charEntity and (tonumber(charEntity.Stamina) or 0) < DOUBLE_JUMP_STAMINA_COST then
return false
end
fsm.Context._flipRequested = true
return true
end

return JumpFSM
