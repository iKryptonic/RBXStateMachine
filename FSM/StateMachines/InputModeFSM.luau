--!strict
--[=[
	@module InputModeFSM
	@description Defines the `InputModeFSM` state machine module and its exported API.
]=]

local InputModeFSM = {
	Name = "InputModeFSM",
	className = "InputModeFSM",
	validStates = { "CombatInput", "UIInput", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "CombatInput",
}

local function writeInputMode(fsm: any, mouseLocked: boolean, inputMode: string)
	local orchestrator = (shared :: any).fsm
	if not orchestrator then
		return
	end

	local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
	if charEntity then
		charEntity.MouseLocked = mouseLocked
		charEntity.InputMode = inputMode
	end
end
--[=[
	@description Handles `RegisterStates` for `InputModeFSM`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function InputModeFSM:RegisterStates()
	--[=[
		@state CombatInput
		@description Handles the `CombatInput` state for `InputModeFSM`.
	]=]

	self:AddState("CombatInput", {
		OnEnter = function(_, fsm)
			writeInputMode(fsm, true, "Combat")
		end,
	}, { "UIInput" })
	--[=[
		@state UIInput
		@description Handles the `UIInput` state for `InputModeFSM`.
	]=]

	self:AddState("UIInput", {
		OnEnter = function(_, fsm)
			writeInputMode(fsm, false, "UI")
		end,
	}, { "CombatInput" })
	--[=[
		@state Completed
		@description Handles the `Completed` terminal state for `InputModeFSM`.
	]=]

	self:AddState("Completed", function() end, {})
	--[=[
		@state Failed
		@description Handles the `Failed` terminal state for `InputModeFSM`.
	]=]

	self:AddState("Failed", function() end, {})
end
--[=[
	@description Updates module state through `InputModeFSM.SetCombatInput`.
	@param fsm any -- `fsm` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function InputModeFSM.SetCombatInput(fsm: any)
	if fsm and fsm.State ~= "CombatInput" then
		fsm.State = "CombatInput"
	end
end
--[=[
	@description Updates module state through `InputModeFSM.SetUIInput`.
	@param fsm any -- `fsm` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function InputModeFSM.SetUIInput(fsm: any)
	if fsm and fsm.State ~= "UIInput" then
		fsm.State = "UIInput"
	end
end
--[=[
	@description Implements `InputModeFSM.Toggle`.
	@param fsm any -- `fsm` input parameter.
	@return string -- Return value produced by the implementation, if any.
]=]

function InputModeFSM.Toggle(fsm: any): string
	if fsm.State == "UIInput" then
		fsm.State = "CombatInput"
	else
		fsm.State = "UIInput"
	end
	return fsm.State
end

return InputModeFSM
