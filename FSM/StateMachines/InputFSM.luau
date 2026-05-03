--!strict
--[=[
	@module InputFSM
	@description Defines the `InputFSM` state machine module and its exported API.
]=]

local InputFSM = {
	Name = "InputFSM",
	className = "InputFSM",
	validStates = { "Normal", "ComboMode", "HeldAttack", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Normal",
}

local KEYSTROKE_TIMEOUT = 1.75

local function writeInputMode(fsm: any, mode: string)
	local orchestrator = (shared :: any).fsm
	if not orchestrator then
		return
	end
	local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
	if charEntity then
		charEntity.ActionOverlay = if mode == "Normal" then (charEntity.ActionOverlay or "None") else mode
	end
end
--[=[
	@description Handles `RegisterStates` for `InputFSM`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function InputFSM:RegisterStates()
	--[=[
		@state Normal
		@description Handles the `Normal` state for `InputFSM`.
	]=]

	self:AddState("Normal", {
		OnEnter = function(_, _fsm)
			-- Normal input mode — all bindings active
		end,
	}, { "ComboMode", "HeldAttack" })
	--[=[
		@state ComboMode
		@description Handles the `ComboMode` state for `InputFSM`.
	]=]

	self:AddState("ComboMode", {
		OnEnter = function(_, fsm)
			writeInputMode(fsm, "ComboMode")
			fsm.Context._comboBuffer = {}
			fsm.Context._comboPointer = 1
		end,
		OnLeave = function(_, fsm)
			fsm.Context._comboBuffer = {}
			fsm.Context._comboPointer = 0
		end,
		Timeout = KEYSTROKE_TIMEOUT,
		OnTimeout = "Normal",
	}, { "Normal" })
	--[=[
		@state HeldAttack
		@description Handles the `HeldAttack` state for `InputFSM`.
	]=]

	self:AddState("HeldAttack", {
		OnEnter = function(_, fsm)
			writeInputMode(fsm, "HeldAttack")
		end,
		OnLeave = function(_, fsm)
			writeInputMode(fsm, "None")
		end,
	}, { "Normal" })
	--[=[
		@state Completed
		@description Handles the `Completed` terminal state for `InputFSM`.
	]=]

	self:AddState("Completed", function() end, {})
	--[=[
		@state Failed
		@description Handles the `Failed` terminal state for `InputFSM`.
	]=]

	self:AddState("Failed", function() end, {})
end
--[=[
	@description Implements `InputFSM.EnterComboMode`.
	@param fsm any -- `fsm` input parameter.
	@return boolean -- Return value produced by the implementation, if any.
]=]

function InputFSM.EnterComboMode(fsm: any): boolean
	if fsm.State == "ComboMode" then
		fsm.State = "Normal"
		return false
	end
	fsm.State = "ComboMode"
	return true
end
--[=[
	@description Implements `InputFSM.EnterHeldAttack`.
	@param fsm any -- `fsm` input parameter.
	@return boolean -- Return value produced by the implementation, if any.
]=]

function InputFSM.EnterHeldAttack(fsm: any): boolean
	if fsm.State ~= "Normal" then
		return false
	end
	fsm.State = "HeldAttack"
	return true
end
--[=[
	@description Implements `InputFSM.ReleaseHeldAttack`.
	@param fsm any -- `fsm` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function InputFSM.ReleaseHeldAttack(fsm: any)
	if fsm.State == "HeldAttack" then
		fsm.State = "Normal"
	end
end
--[=[
	@description Returns whether `InputFSM` is combo mode.
	@param fsm any -- `fsm` input parameter.
	@return boolean -- Return value produced by the implementation, if any.
]=]

function InputFSM.IsComboMode(fsm: any): boolean
	return fsm.State == "ComboMode"
end
--[=[
	@description Returns whether `InputFSM` is held attack.
	@param fsm any -- `fsm` input parameter.
	@return boolean -- Return value produced by the implementation, if any.
]=]

function InputFSM.IsHeldAttack(fsm: any): boolean
	return fsm.State == "HeldAttack"
end

return InputFSM
