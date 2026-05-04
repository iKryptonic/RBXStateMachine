--!strict


local HttpService = game:GetService("HttpService")

--[=[
	@Name ToggleWeaponJob
	@Author iKrypto
	@Description Server-authoritative weapon draw/stow toggle FSM. Checks current equipped
	state: if weapon is drawn, spawns UnEquipJob (stow mode, not ForceRemove). If weapon
	is stowed, spawns EquipJob to re-draw from WeaponEqp. Z key triggers this FSM.

	State flow:
	Validate → ResolveCurrentState → ChooseBranch → RunEquip or RunUnEquip → Completed

	Required params:
	- CharacterEntityId: string — character entity
	- PlayerEntityId: string — player entity for inventory/WeaponEqp
	- Hand: string — "Right" or "Left"
]=]

local ToggleWeaponJob = {
	Name = "ToggleWeaponJob",
	className = "ToggleWeaponJob",
	validStates = {"Validate","ResolveCurrentState","ChooseBranch","RunEquip","RunUnEquip","Completed","Failed" },
	terminalStates = {"Completed","Failed" },
	initialState = "Validate",
}

--[=[
	@description Helper for the begin child job step used by this state machine.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function beginChildJob(
	fsm: any,
	orchestrator: any,
	stateName: string,
	childClass: any,
	initialState: string,
	context: { [string]: any },
	failureLabel: string
)
	if not childClass then
		fsm:Fail(failureLabel .." job is unavailable")
		return
	end

	local subJob = orchestrator.CreateStateMachine({
		StateMachineClass = childClass,
		StateMachineId = string.format(
			"%s_%s_%s",
			tostring(fsm.Id or "ToggleWeaponJob"),
			stateName,
			HttpService:GenerateGUID(false)
		),
		Context = context,
		AutoStart = false,
	})
	if not subJob then
		fsm:Fail("Failed to create " .. failureLabel .." job")
		return
	end

	fsm._activeSubJob = subJob
	fsm:Manage(function()
		if subJob.IsActive then
			subJob:Cancel()
		end
	end)
	fsm:Manage(subJob.Completed:Connect(function()
		if fsm.IsActive and fsm.State == stateName then
			fsm.State = "Completed"
		end
	end))
	fsm:Manage(subJob.Failed:Connect(function(reason)
		if fsm.IsActive and fsm.State == stateName then
			local suffix = if reason and tostring(reason) ~= "" then": " .. tostring(reason) else""
			fsm:Fail(failureLabel .." failed" .. suffix)
		end
	end))
	fsm:Manage(subJob.Cancelled:Connect(function()
		if fsm.IsActive and fsm.State == stateName then
			fsm:Fail(failureLabel .." cancelled")
		end
	end))

	subJob:Start({ State = initialState })
end


--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `ToggleWeaponJob`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function ToggleWeaponJob:RegisterStates()


	--[=[
		@state Validate
		@description Validates the required runtime context and prerequisites.
			Transitions:
			- `ResolveCurrentState` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
	]=]

	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			if type(fsm.CharacterEntityId) ~= "string" or fsm.CharacterEntityId == "" then
				fsm:Fail("Missing CharacterEntityId")
				return
			end

			local charEntity = fsm:GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end

			local playerEntityId = fsm.PlayerEntityId
			if type(playerEntityId) ~= "string" or playerEntityId == "" then
				playerEntityId = charEntity.PlayerEntityId
			end
			if type(playerEntityId) ~= "string" or playerEntityId == "" then
				fsm:Fail("Missing PlayerEntityId")
				return
			end

			local playerEntity = fsm:GetEntity(playerEntityId)
			if not playerEntity then
				fsm:Fail("PlayerEntity not found")
				return
			end

			fsm.CharacterEntity = charEntity
			fsm.PlayerEntity = playerEntity
			fsm.PlayerEntityId = playerEntityId
			fsm.Hand = "Right"
			fsm.State = "ResolveCurrentState"
		end,
	}, {"ResolveCurrentState","Failed" })


	--[=[
		@state ResolveCurrentState
		@description Resolves the data needed for the `ResolveCurrentState` step.
			Transitions:
			- `ChooseBranch` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("ResolveCurrentState", {
		OnEnter = function(_, fsm)
			local selectedItemId = fsm.PlayerEntity.WeaponEqp
			local equippedRight = fsm.CharacterEntity.EquippedRight
			local equippedLeft = fsm.CharacterEntity.EquippedLeft
			local rightItemId = if type(equippedRight) == "string" and equippedRight ~= "" then equippedRight else nil
			local leftItemId = if type(equippedLeft) == "string" and equippedLeft ~= "" then equippedLeft else nil
			local equippedItemId: string? = nil
			local equippedHand = "Right"

			if type(selectedItemId) == "string" and selectedItemId ~= "" then
				if rightItemId == selectedItemId then
					equippedItemId = rightItemId
					equippedHand = "Right"
				elseif leftItemId == selectedItemId then
					equippedItemId = leftItemId
					equippedHand = "Left"
				end
			end

			if equippedItemId == nil then
				if rightItemId ~= nil then
					equippedItemId = rightItemId
					equippedHand = "Right"
				elseif leftItemId ~= nil then
					equippedItemId = leftItemId
					equippedHand = "Left"
				end
			end

			fsm.Hand = equippedHand
			fsm.EquippedItemId = equippedItemId
			fsm.IsEquipped = equippedItemId ~= nil
			fsm.State = "ChooseBranch"
		end,
	}, {"ChooseBranch","Failed" })


	--[=[
		@state ChooseBranch
		@description Runs the `choose branch` stage of `ToggleWeaponJob`.
			Transitions:
			- `RunUnEquip` when this stage finishes its immediate work or falls through its guard checks.
			- `RunEquip` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
	]=]

	self:AddState("ChooseBranch", {
		OnEnter = function(_, fsm)
			if fsm.IsEquipped then
				fsm.State = "RunUnEquip"
				return
			end

			local itemId = fsm.PlayerEntity.WeaponEqp
			if type(itemId) ~= "string" or itemId == "" then
				fsm:Fail("No weapon selected to equip")
				return
			end

			local inventory = fsm.PlayerEntity.Inventory
			if typeof(inventory) == "table" and #inventory > 0 and not table.find(inventory, itemId) then
				fsm:Fail("Weapon " .. itemId .." not in inventory")
				return
			end

			fsm.ItemId = itemId
			fsm.State = "RunEquip"
		end,
	}, {"RunEquip","RunUnEquip","Failed" })


	--[=[
		@state RunEquip
		@description Runs the `run equip` stage of `ToggleWeaponJob`.
			Transitions:
			- External transitions allow: `Completed`, `Failed`.
			Writes: none.
	]=]

	self:AddState("RunEquip", {
		OnEnter = function(_, fsm)
			beginChildJob(fsm, fsm:GetOrchestrator(),"RunEquip","EquipJob","ValidateRequest", {
				CharacterEntityId = fsm.CharacterEntityId,
				PlayerEntityId = fsm.PlayerEntityId,
				ItemId = fsm.ItemId,
				Hand = fsm.Hand,
			},"Sub-equip")
		end,
	}, {"Completed","Failed" })


	--[=[
		@state RunUnEquip
		@description Runs the `run un equip` stage of `ToggleWeaponJob`.
			Transitions:
			- External transitions allow: `Completed`, `Failed`.
			Writes: none.
	]=]

	self:AddState("RunUnEquip", {
		OnEnter = function(_, fsm)
			beginChildJob(fsm, fsm:GetOrchestrator(),"RunUnEquip","UnEquipJob","ValidateRequest", {
				CharacterEntityId = fsm.CharacterEntityId,
				PlayerEntityId = fsm.PlayerEntityId,
				ItemId = fsm.EquippedItemId,
				Hand = fsm.Hand,
			},"Sub-unequip")
		end,
	}, {"Completed","Failed" })
end

return ToggleWeaponJob
