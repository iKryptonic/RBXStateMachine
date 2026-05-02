--!strict
-- @Name ToggleWeaponJob
-- @Description FSM state machine module.

local HttpService = game:GetService("HttpService")

local ToggleWeaponJob = {
	Name = "ToggleWeaponJob",
	className = "ToggleWeaponJob",
	validStates = { "Validate", "ResolveCurrentState", "ChooseBranch", "RunEquip", "RunUnEquip", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

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
		fsm:Fail(failureLabel .. " job is unavailable")
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
		fsm:Fail("Failed to create " .. failureLabel .. " job")
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
			local suffix = if reason and tostring(reason) ~= "" then ": " .. tostring(reason) else ""
			fsm:Fail(failureLabel .. " failed" .. suffix)
		end
	end))
	fsm:Manage(subJob.Cancelled:Connect(function()
		if fsm.IsActive and fsm.State == stateName then
			fsm:Fail(failureLabel .. " cancelled")
		end
	end))

	subJob:Start({ State = initialState })
end

function ToggleWeaponJob:RegisterStates()
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
	}, { "ResolveCurrentState", "Failed" })

	self:AddState("ResolveCurrentState", {
		OnEnter = function(_, fsm)
			local equippedRight = fsm.CharacterEntity.EquippedRight
			fsm.IsEquipped = type(equippedRight) == "string" and equippedRight ~= ""
			fsm.State = "ChooseBranch"
		end,
	}, { "ChooseBranch", "Failed" })

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

			fsm.ItemId = itemId
			fsm.State = "RunEquip"
		end,
	}, { "RunEquip", "RunUnEquip", "Failed" })

	self:AddState("RunEquip", {
		OnEnter = function(_, fsm)
			beginChildJob(fsm, fsm:GetOrchestrator(), "RunEquip", "EquipJob", "ValidateRequest", {
				CharacterEntityId = fsm.CharacterEntityId,
				PlayerEntityId = fsm.PlayerEntityId,
				ItemId = fsm.ItemId,
				Hand = fsm.Hand,
			}, "Sub-equip")
		end,
	}, { "Completed", "Failed" })

	self:AddState("RunUnEquip", {
		OnEnter = function(_, fsm)
			beginChildJob(fsm, fsm:GetOrchestrator(), "RunUnEquip", "UnEquipJob", "ValidateRequest", {
				CharacterEntityId = fsm.CharacterEntityId,
				PlayerEntityId = fsm.PlayerEntityId,
				ItemId = fsm.CharacterEntity.EquippedRight,
				Hand = fsm.Hand,
			}, "Sub-unequip")
		end,
	}, { "Completed", "Failed" })
end

return ToggleWeaponJob
