--!strict

--[=[
	@module LocomotionFSM
	@description Observes humanoid movement and writes `Idle`, `Walking`, `Running`, or `Airborne` locomotion state back to the character entity.
]=]

local LocomotionFSM = {
	Name = "LocomotionFSM",
	className = "LocomotionFSM",
	validStates = {"Idle","Walking","Running","Airborne","Completed","Failed" },
	terminalStates = {"Completed","Failed" },
	initialState = "Idle",
}

local WALK_THRESHOLD = 2
local RUN_THRESHOLD = 22

--[=[
	@description Resolves the observed character entity, humanoid, and root part used to classify locomotion.
	@param fsm any  -- LocomotionFSM instance observing the character and writing locomotion state.
	@return any -- Character entity, humanoid, and root part, or `nil` values when the character cannot be resolved.
]=]

local function getCharacterParts(fsm: any): (any?, any?, any?)
	local orchestrator = (shared :: any).fsm
	if not orchestrator then
		return nil, nil, nil
	end
	local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
	if not charEntity then
		return nil, nil, nil
	end
	local character = charEntity.Instance
	if not character then
		local Players = game:GetService("Players")
		local localPlayer = Players.LocalPlayer
		character = localPlayer and localPlayer.Character
	end
	if not character then
		return nil, nil, nil
	end
	return charEntity, character:FindFirstChildOfClass("Humanoid"), character:FindFirstChild("HumanoidRootPart")
end

--[=[
	@description Reports whether the humanoid is currently jumping, freefalling, or falling down.
	@param humanoid any  -- Humanoid to inspect or update.
	@return boolean -- Whether the helper completed successfully.
]=]

local function isAirborne(humanoid: any): boolean
	local state = humanoid:GetState()
	return state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.FallingDown
end

--[=[
	@description Returns the horizontal speed for this FSM, or `nil` when it cannot be found.
	@param rootPart any  -- Root part used for movement or positioning.
	@return number -- Numeric value derived for downstream logic.
]=]

local function getHorizontalSpeed(rootPart: any): number
	return (rootPart.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude
end

--[=[
	@description Writes the derived locomotion state string back onto the active character entity.
	@param fsm any  -- LocomotionFSM instance observing the character and writing locomotion state.
	@param state any  -- State name to write.
	@return nil -- Performs this helper's work in place.
]=]

local function writeState(fsm: any, state: string)
	local orchestrator = (shared :: any).fsm
	if not orchestrator then
		return
	end
	local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
	if charEntity then
		charEntity.LocomotionState = state
	end
end

--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `LocomotionFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function LocomotionFSM:RegisterStates()

	--[=[
	@state Idle
	@description Writes locomotion state `Idle`.
	Transitions:
	- `Airborne` when this state's transition condition passes.
	- `Running` when this state's transition condition passes.
	- `Walking` when this state's transition condition passes.
	Writes: none.

]=]

	self:AddState("Idle", {
		OnEnter = function(_, fsm)
			writeState(fsm,"Idle")
		end,
		Transitions = {
			{
				Condition = function(fsm)
					local _, hum, root = getCharacterParts(fsm)
					return hum and root and isAirborne(hum)
				end,
				TargetState = "Airborne",
			},
			{
				Condition = function(fsm)
					local _, hum, root = getCharacterParts(fsm)
					return hum and root and not isAirborne(hum) and getHorizontalSpeed(root) > RUN_THRESHOLD
				end,
				TargetState = "Running",
			},
			{
				Condition = function(fsm)
					local _, hum, root = getCharacterParts(fsm)
					return hum and root and not isAirborne(hum) and getHorizontalSpeed(root) > WALK_THRESHOLD
				end,
				TargetState = "Walking",
			},
		},
	}, {"Walking","Running","Airborne" })

	--[=[
	@state Walking
	@description Writes locomotion state `Walking`.
	Transitions:
	- `Airborne` when this state's transition condition passes.
	- `Running` when this state's transition condition passes.
	- `Idle` when this state's transition condition passes.
	Writes: none.

]=]

	self:AddState("Walking", {
		OnEnter = function(_, fsm)
			writeState(fsm,"Walking")
		end,
		Transitions = {
			{
				Condition = function(fsm)
					local _, hum = getCharacterParts(fsm)
					return hum and isAirborne(hum)
				end,
				TargetState = "Airborne",
			},
			{
				Condition = function(fsm)
					local _, hum, root = getCharacterParts(fsm)
					return hum and root and not isAirborne(hum) and getHorizontalSpeed(root) > RUN_THRESHOLD
				end,
				TargetState = "Running",
			},
			{
				Condition = function(fsm)
					local _, hum, root = getCharacterParts(fsm)
					return hum and root and not isAirborne(hum) and getHorizontalSpeed(root) <= WALK_THRESHOLD
				end,
				TargetState = "Idle",
			},
		},
	}, {"Idle","Running","Airborne" })

	--[=[
	@state Running
	@description Writes locomotion state `Running`.
	Transitions:
	- `Airborne` when this state's transition condition passes.
	- `Idle` when this state's transition condition passes.
	- `Walking` when this state's transition condition passes.
	Writes: none.

]=]

	self:AddState("Running", {
		OnEnter = function(_, fsm)
			writeState(fsm,"Running")
		end,
		Transitions = {
			{
				Condition = function(fsm)
					local _, hum = getCharacterParts(fsm)
					return hum and isAirborne(hum)
				end,
				TargetState = "Airborne",
			},
			{
				Condition = function(fsm)
					local _, hum, root = getCharacterParts(fsm)
					return hum and root and not isAirborne(hum) and getHorizontalSpeed(root) <= WALK_THRESHOLD
				end,
				TargetState = "Idle",
			},
			{
				Condition = function(fsm)
					local _, hum, root = getCharacterParts(fsm)
					return hum
						and root
						and not isAirborne(hum)
						and getHorizontalSpeed(root) <= RUN_THRESHOLD
						and getHorizontalSpeed(root) > WALK_THRESHOLD
				end,
				TargetState = "Walking",
			},
		},
	}, {"Idle","Walking","Airborne" })

	--[=[
	@state Airborne
	@description Writes locomotion state `Airborne`.
	Transitions:
	- `Running` when this state's transition condition passes.
	- `Walking` when this state's transition condition passes.
	- `Idle` when this state's transition condition passes.
	Writes: none.

]=]

	self:AddState("Airborne", {
		OnEnter = function(_, fsm)
			writeState(fsm,"Airborne")
		end,
		Transitions = {
			{
				Condition = function(fsm)
					local _, hum, root = getCharacterParts(fsm)
					if not hum or isAirborne(hum) then
						return false
					end
					return root and getHorizontalSpeed(root) > RUN_THRESHOLD
				end,
				TargetState = "Running",
			},
			{
				Condition = function(fsm)
					local _, hum, root = getCharacterParts(fsm)
					if not hum or isAirborne(hum) then
						return false
					end
					return root and getHorizontalSpeed(root) > WALK_THRESHOLD
				end,
				TargetState = "Walking",
			},
			{
				Condition = function(fsm)
					local _, hum = getCharacterParts(fsm)
					return hum and not isAirborne(hum)
				end,
				TargetState = "Idle",
			},
		},
	}, {"Idle","Walking","Running" })
	--[=[
	@state Completed
	@description Terminal success sink reserved for explicit shutdown of the locomotion observer. Normal operation continuously cycles between `Idle`, `Walking`, `Running`, and `Airborne`.
	Transitions: none.
	Writes: none.

]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink reserved for future locomotion errors. The current movement observer never routes here, and `OnEnter` is a no-op.
	Transitions: none.
	Writes: none.

]=]

	self:AddState("Failed", function() end, {})
end

return LocomotionFSM
