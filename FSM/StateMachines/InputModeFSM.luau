--!strict


local InputModeFSM = {
	Name = "InputModeFSM",
	className = "InputModeFSM",
	validStates = {"CombatInput","UIInput","Completed","Failed" },
	terminalStates = {"Completed","Failed" },
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


function InputModeFSM:RegisterStates()


	self:AddState("CombatInput", {
		OnEnter = function(_, fsm)
			writeInputMode(fsm, true,"Combat")
		end,
	}, {"UIInput" })


	self:AddState("UIInput", {
		OnEnter = function(_, fsm)
			writeInputMode(fsm, false,"UI")
		end,
	}, {"CombatInput" })
	--[=[
	@state Completed
	@description Terminal success sink reserved for explicit teardown of the combat/UI mode FSM. Normal operation only toggles between `CombatInput` and `UIInput`, so `OnEnter` is a no-op.
		Transitions: none.
		Writes: none.
]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink reserved for future input-mode errors. The current helper-driven flow never enters it, and `OnEnter` performs no writes.
		Transitions: none.
		Writes: none.
]=]

	self:AddState("Failed", function() end, {})
end
--[=[
	@description Moves an active input-mode FSM back into `CombatInput` when it is not already there. Use this to relock the mouse and restore combat-facing controls; the helper returns no value.
]=]

function InputModeFSM.SetCombatInput(fsm: any)
	if fsm and fsm.State ~= "CombatInput" then
		fsm.State = "CombatInput"
	end
end
--[=[
	@description Moves an active input-mode FSM into `UIInput` when it is not already there. Use this to unlock the mouse and hand control over to UI navigation; the helper returns no value.
]=]

function InputModeFSM.SetUIInput(fsm: any)
	if fsm and fsm.State ~= "UIInput" then
		fsm.State = "UIInput"
	end
end


function InputModeFSM.Toggle(fsm: any): string
	if fsm.State == "UIInput" then
		fsm.State = "CombatInput"
	else
		fsm.State = "UIInput"
	end
	return fsm.State
end

return InputModeFSM
