--!strict

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers,"Helpers folder not found")
local ResourceHelpers = require(Helpers:WaitForChild("ResourceHelpers"))

--[=[
	@module DashFSM
	@description Validates dash requests, spends stamina, applies the dash impulse and overlay, waits through the active window, then clears the overlay and cooldown.
]=]

local DashFSM = {
	Name = "DashFSM",
	className = "DashFSM",
	validStates = {
		"Ready",
		"ValidateDash",
		"ValidateStamina",
		"DeductStamina",
		"ApplyImpulse",
		"PlaySound",
		"TriggerAnimation",
		"WriteOverlay",
		"DashActive",
		"ClearOverlay",
		"Cooldown",
		"Completed",
		"Failed",
	},
	terminalStates = {"Completed","Failed" },
	initialState = "Ready",
}

local IMPULSE = 75
local IMPULSE_DURATION = 0.1
local ACTIVE_DURATION = 0.25
local COOLDOWN = 0.75
local DASH_STAMINA_COST = 15
local DASH_SOUND_ID = "rbxassetid://541909814"

local DIRECTION_MAP = {
	W = "Dashing",
	A = "DashLeft",
	S = "DashEnd",
	D = "DashRight",
}

--[=[
	@description Returns the character entity for this FSM, or `nil` when it cannot be found.
	@param fsm any  -- DashFSM instance carrying the queued dash direction and cached runtime parts.
	@return any -- Resolved character entity, or `nil` when unavailable.
]=]

local function getCharacterEntity(fsm: any): any?
	return fsm:GetEntity(fsm.CharacterEntityId)
end

--[=[
	@description Returns the root part for this FSM, or `nil` when it cannot be found.
	@param fsm any  -- DashFSM instance carrying the queued dash direction and cached runtime parts.
	@return any -- Resolved root part, or `nil` when unavailable.
]=]

local function getRootPart(fsm: any): BasePart?
	local charEntity = getCharacterEntity(fsm)
	if charEntity and charEntity.Instance then
		local root = charEntity.Instance:FindFirstChild("HumanoidRootPart")
		if root then return root :: BasePart? end
	end
	-- Fallback: get from LocalPlayer.Character directly
	local Players = game:GetService("Players")
	local localPlayer = Players.LocalPlayer
	if localPlayer and localPlayer.Character then
		return localPlayer.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	return nil
end

--[=[
	@description Returns the impulse direction for this FSM, or `nil` when it cannot be found.
	@param rootPart any  -- Root part used for movement or positioning.
	@param direction any  -- Requested movement or attack direction.
	@return any -- Resolved impulse direction, or `nil` when unavailable.
]=]

local function getImpulseDirection(rootPart: BasePart, direction: string): Vector3?
	local lookVector = rootPart.CFrame.LookVector
	local rightVector = rootPart.CFrame.RightVector
	if direction == "W" then
		return lookVector
	elseif direction == "S" then
		return -lookVector
	elseif direction == "A" then
		return -rightVector
	elseif direction == "D" then
		return rightVector
	end
	return nil
end

--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `DashFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function DashFSM:RegisterStates()

	--[=[
	@state Ready
	@description Clears cached dash direction, character entity, and root part so the next request starts from fresh runtime data.
	Transitions:
	- Input or controller code may jump here to `ValidateDash` after writing `Context._dashDirection`.
	Writes: clears `Context._dashDirection`, clears `Context._charEntity`, clears `Context._rootPart`, stores `Context._dashDirection`, stores `Context._charEntity`.

]=]

	self:AddState("Ready", {
		OnEnter = function(_, fsm)
			fsm.Context._dashDirection = nil
			fsm.Context._charEntity = nil
			fsm.Context._rootPart = nil
		end,
	}, {"ValidateDash" })

	--[=[
	@state ValidateDash
	@description Requires a queued dash direction plus a live character entity and root part; otherwise it falls back to `Ready`.
	Transitions:
	- `Ready` when OnEnter finishes or falls through its guard checks.
	- `ValidateStamina` when OnEnter finishes or falls through its guard checks.
	Writes: stores `Context._charEntity`, stores `Context._rootPart`, sets `_charEntity`, sets `_rootPart`.

]=]

	self:AddState("ValidateDash", {
		OnEnter = function(_, fsm)
			local direction = fsm.Context._dashDirection
			local charEntity = getCharacterEntity(fsm)
			local rootPart = getRootPart(fsm)
			if not direction or not rootPart or not charEntity then
				fsm.State = "Ready"
				return
			end

			fsm.Context._charEntity = charEntity
			fsm.Context._rootPart = rootPart
			fsm.State = "ValidateStamina"
		end,
	}, {"ValidateStamina","Ready" })

	--[=[
	@state ValidateStamina
	@description Checks the resolved character has enough stamina for a dash before spending anything.
	Transitions:
	- `Ready` when OnEnter finishes or falls through its guard checks.
	- `DeductStamina` when OnEnter finishes or falls through its guard checks.
	Writes: none.

]=]

	self:AddState("ValidateStamina", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity or getCharacterEntity(fsm)
			local stamina = tonumber(charEntity and charEntity.Stamina) or 0
			if not charEntity or stamina < DASH_STAMINA_COST then
				fsm.State = "Ready"
				return
			end
			fsm.State = "DeductStamina"
		end,
	}, {"DeductStamina","Ready" })

	--[=[
	@state DeductStamina
	@description Spends `DASH_STAMINA_COST`, best-effort replicates the entity, and returns to `Ready` if the spend fails.
	Transitions:
	- `Ready` when OnEnter finishes or falls through its guard checks.
	- `ApplyImpulse` when OnEnter finishes or falls through its guard checks.
	Writes: replicates entity changes.

]=]

	self:AddState("DeductStamina", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			if not charEntity then
				fsm.State = "Ready"
				return
			end

			if not ResourceHelpers.deductStamina(charEntity, DASH_STAMINA_COST) then
				fsm.State = "Ready"
				return
			end
			pcall(function()
				charEntity:UpdateEntity()
			end)
			fsm.State = "ApplyImpulse"
		end,
	}, {"ApplyImpulse","Ready" })

	--[=[
	@state ApplyImpulse
	@description Creates a short-lived horizontal `BodyVelocity` impulse from the requested dash direction and only advances when the root still exists.
	Transitions:
	- `Ready` when OnEnter finishes or falls through its guard checks.
	- `PlaySound` when OnEnter finishes or falls through its guard checks.
	Writes: none.

]=]

	self:AddState("ApplyImpulse", {
		OnEnter = function(_, fsm)
			local direction = fsm.Context._dashDirection
			local rootPart = fsm.Context._rootPart
			if not direction or not rootPart or not rootPart.Parent then
				fsm.State = "Ready"
				return
			end

			local impulseDir = getImpulseDirection(rootPart, direction)
			if not impulseDir then
				fsm.State = "Ready"
				return
			end

			-- BodyVelocity impulse (matches legacy DashController)
			local bodyVelocity = Instance.new("BodyVelocity")
			bodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
			bodyVelocity.Velocity = impulseDir * IMPULSE
			bodyVelocity.Parent = rootPart
			Debris:AddItem(bodyVelocity, IMPULSE_DURATION)
			fsm.State = "PlaySound"
		end,
	}, {"PlaySound","Ready" })

	--[=[
	@state PlaySound
	@description Spawns and plays the dash sound on the root part before triggering animation.
	Transitions:
	- `TriggerAnimation` when OnEnter finishes or falls through its guard checks.
	Writes: none.

]=]

	self:AddState("PlaySound", {
		OnEnter = function(_, fsm)
			local rootPart = fsm.Context._rootPart
			if rootPart and rootPart.Parent then
				local sound = Instance.new("Sound")
				sound.SoundId = DASH_SOUND_ID
				sound.Volume = 0.5
				sound.Parent = rootPart
				sound:Play()
				Debris:AddItem(sound, 2)
			end
			fsm.State = "TriggerAnimation"
		end,
	}, {"TriggerAnimation" })

	--[=[
	@state TriggerAnimation
	@description Calls `_onAnimate` with the direction-specific dash animation name before overlay writeback.
	Transitions:
	- `WriteOverlay` when OnEnter finishes or falls through its guard checks.
	Writes: none.

]=]

	self:AddState("TriggerAnimation", {
		OnEnter = function(_, fsm)
			local direction = fsm.Context._dashDirection
			local onAnimate = fsm.Context._onAnimate
			local animationName = DIRECTION_MAP[direction] or "Dashing"
			if onAnimate then
				onAnimate(animationName)
			end
			fsm.State = "WriteOverlay"
		end,
	}, {"WriteOverlay" })

	--[=[
	@state WriteOverlay
	@description Sets `ActionOverlay` to `Dash_<direction>` and only enters `DashActive` when both entity and direction are still valid.
	Transitions:
	- `Ready` when OnEnter finishes or falls through its guard checks.
	- `DashActive` when OnEnter finishes or falls through its guard checks.
	Writes: sets `ActionOverlay`.

]=]

	self:AddState("WriteOverlay", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			local direction = fsm.Context._dashDirection
			if not charEntity or not direction then
				fsm.State = "Ready"
				return
			end

			charEntity.ActionOverlay = "Dash_" .. direction
			fsm.State = "DashActive"
		end,
	}, {"DashActive","Ready" })

	--[=[
	@state DashActive
	@description Schedules `ClearOverlay` after the fixed active window of `ACTIVE_DURATION` seconds.
	Transitions:
	- `ClearOverlay` when the scheduled transition completes.
	Writes: none.

]=]

	self:AddState("DashActive", {
		OnEnter = function(_, fsm)
			fsm:ScheduleTransition(ACTIVE_DURATION,"ClearOverlay")
		end,
	}, {"ClearOverlay" })

	--[=[
	@state ClearOverlay
	@description Writes `ActionOverlay = "None"` and hands off to cooldown.
	Transitions:
	- `Cooldown` when OnEnter finishes or falls through its guard checks.
	Writes: sets `ActionOverlay`.

]=]

	self:AddState("ClearOverlay", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity or getCharacterEntity(fsm)
			if charEntity then
				charEntity.ActionOverlay = "None"
			end
			fsm.State = "Cooldown"
		end,
	}, {"Cooldown" })

	--[=[
	@state Cooldown
	@description Arms the cooldown window before returning control.
	Transitions:
	- `Ready` when the scheduled transition completes.
	Writes: none.

]=]

	self:AddState("Cooldown", {
		OnEnter = function(_, fsm)
			fsm:ScheduleTransition(COOLDOWN,"Ready")
		end,
	}, {"Ready" })
	--[=[
	@state Completed
	@description Terminal success sink reserved for explicit shutdown of the dash FSM. Normal dash requests clear the overlay and return to `Ready` after cooldown instead of terminating here.
	Transitions: none.
	Writes: none.

]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink reserved for future hard dash errors. Current validation failures fall back to `Ready`, so `OnEnter` is a no-op.
	Transitions: none.
	Writes: none.

]=]

	self:AddState("Failed", function() end, {})
end

--[=[
	@description Public helper for `DashFSM.TryDash`.
	@param fsm any  -- DashFSM instance carrying the queued dash direction and cached runtime parts.
	@param direction any  -- Requested movement or attack direction.
	@return boolean -- `true` when the request is accepted.
]=]

function DashFSM.TryDash(fsm: any, direction: string): boolean
	if fsm.State ~= "Ready" then
		return false
	end
	fsm.Context._dashDirection = direction
	fsm.State = "ValidateDash"
	return true
end

return DashFSM
