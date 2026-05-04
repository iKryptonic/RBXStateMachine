--!strict

--[=[
	@module InputFSM
	@description Tracks the client combat-input mode between `Normal`, `ComboMode`, and `HeldAttack`, including combo buffer setup and hold release handling.
]=]

local InputFSM = {
	Name = "InputFSM",
	className = "InputFSM",
	validStates = {"Normal","ComboMode","HeldAttack","Completed","Failed" },
	terminalStates = {"Completed","Failed" },
	initialState = "Normal",
}

local KEYSTROKE_TIMEOUT = 1.75

--[=[
	@description Writes the derived input mode data back onto the active entity or FSM context.
	@param fsm any  -- InputFSM instance tracking combo-buffer and held-attack input state.
	@param mode any  -- Mode name to apply.
	@return nil -- Performs this helper's work in place.
]=]

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
	@description Registers the runtime states, transitions, and terminal behavior for `InputFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function InputFSM:RegisterStates()

	--[=[
	@state Normal
	@description Default input state with normal combat bindings active until combo buffering or held-attack logic takes over.
	Transitions:
	- Other input handlers may switch to `ComboMode` or `HeldAttack` when those interactions begin.
	Writes: none.

]=]

	self:AddState("Normal", {
		OnEnter = function(_, _fsm)
			-- Normal input mode — all bindings active
		end,
	}, {"ComboMode","HeldAttack" })

	--[=[
	@state ComboMode
	@description Switches the input mode to combo capture, clears `_comboBuffer`, and resets `_comboPointer`; `OnLeave` clears both again before returning to normal input.
	Transitions:
	- `Normal` when the `KEYSTROKE_TIMEOUT` timeout expires.
	Writes: stores `Context._comboBuffer`, stores `Context._comboPointer`, sets `_comboBuffer`, sets `_comboPointer`.

]=]

	self:AddState("ComboMode", {
		OnEnter = function(_, fsm)
			writeInputMode(fsm,"ComboMode")
			fsm.Context._comboBuffer = {}
			fsm.Context._comboPointer = 1
		end,
		OnLeave = function(_, fsm)
			fsm.Context._comboBuffer = {}
			fsm.Context._comboPointer = 0
		end,
		Timeout = KEYSTROKE_TIMEOUT,
		OnTimeout = "Normal",
	}, {"Normal" })

	--[=[
	@state HeldAttack
	@description Writes held-attack mode on enter and clears it back to `None` on leave.
	Transitions:
	- Input release logic returns here to `Normal` when the held attack ends.
	Writes: none.

]=]

	self:AddState("HeldAttack", {
		OnEnter = function(_, fsm)
			writeInputMode(fsm,"HeldAttack")
		end,
		OnLeave = function(_, fsm)
			writeInputMode(fsm,"None")
		end,
	}, {"Normal" })
	--[=[
	@state Completed
	@description Terminal success sink reserved for explicit shutdown of the input-mode FSM. Runtime behavior normally stays inside `Normal`, `ComboMode`, and `HeldAttack`, so `OnEnter` is a no-op.
	Transitions: none.
	Writes: none.

]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink reserved for future input-processing errors. The current implementation does not route here, and `OnEnter` performs no writes.
	Transitions: none.
	Writes: none.

]=]

	self:AddState("Failed", function() end, {})
end

--[=[
	@description Switches the FSM into `ComboMode` when its current state allows the change.
	@param fsm any  -- InputFSM instance tracking combo-buffer and held-attack input state.
	@return boolean -- `true` when the request is accepted.
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
	@description Switches the FSM into `HeldAttack` when its current state allows the change.
	@param fsm any  -- InputFSM instance tracking combo-buffer and held-attack input state.
	@return boolean -- `true` when the request is accepted.
]=]

function InputFSM.EnterHeldAttack(fsm: any): boolean
	if fsm.State ~= "Normal" then
		return false
	end
	fsm.State = "HeldAttack"
	return true
end

--[=[
	@description Releases the active `held attack` mode and returns control to the default path when the current state allows it.
	@param fsm any  -- InputFSM instance tracking combo-buffer and held-attack input state.
	@return nil -- Updates FSM state as a side effect.
]=]

function InputFSM.ReleaseHeldAttack(fsm: any)
	if fsm.State == "HeldAttack" then
		fsm.State = "Normal"
	end
end

--[=[
	@description Returns whether the FSM is currently in the `ComboMode` branch.
	@param fsm any  -- InputFSM instance tracking combo-buffer and held-attack input state.
	@return boolean -- `true` when combo mode is true.
]=]

function InputFSM.IsComboMode(fsm: any): boolean
	return fsm.State == "ComboMode"
end

--[=[
	@description Returns whether the FSM is currently in the `HeldAttack` branch.
	@param fsm any  -- InputFSM instance tracking combo-buffer and held-attack input state.
	@return boolean -- `true` when held attack is true.
]=]

function InputFSM.IsHeldAttack(fsm: any): boolean
	return fsm.State == "HeldAttack"
end

return InputFSM
