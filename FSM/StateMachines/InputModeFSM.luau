--!strict

--[=[
	@module InputModeFSM
	@description Switches the character between combat input and UI input by updating `MouseLocked` and `InputMode` on the character entity.
]=]

local InputModeFSM = {
	Name = "InputModeFSM",
	className = "InputModeFSM",
	validStates = {"CombatInput","UIInput","Completed","Failed" },
	terminalStates = {"Completed","Failed" },
	initialState = "CombatInput",
}

--[=[
	@description Writes the derived input mode data back onto the active entity or FSM context.
	@param fsm any  -- InputModeFSM instance mirroring combat-vs-UI mode for this character.
	@param mouseLocked any  -- Whether the mouse should stay locked for combat input.
	@param inputMode any  -- Mode name to apply.
	@return nil -- Updates the character entity in place when it exists.
]=]

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
	@description Registers the runtime states, transitions, and terminal behavior for `InputModeFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function InputModeFSM:RegisterStates()

	--[=[
	@state CombatInput
	@description Writes combat input availability to the shared mode flag so gameplay bindings stay active.
	Transitions:
	- Menu or focus changes may switch to `UIInput` when gameplay controls should pause.
	Writes: none.

]=]

	self:AddState("CombatInput", {
		OnEnter = function(_, fsm)
			writeInputMode(fsm, true,"Combat")
		end,
	}, {"UIInput" })

	--[=[
	@state UIInput
	@description Writes UI-only input availability to the shared mode flag so combat bindings stay disabled.
	Transitions:
	- Gameplay flow switches back to `CombatInput` when UI focus closes.
	Writes: none.

]=]

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

--[=[
	@description Switches between `CombatInput` and `UIInput`, then returns the new state name.
	@param fsm any  -- InputModeFSM instance mirroring combat-vs-UI mode for this character.
	@return string -- The resulting state name after the toggle completes.
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
