--!strict
--[=[
	@module SpawnCharacterJob
	@description Defines the `SpawnCharacterJob` state machine module and its exported API.
]=]

local SpawnCharacterJob = {
	Name = "SpawnCharacterJob",
	className = "SpawnCharacterJob",
	validStates = { "Validate", "BindEntity", "ApplyLoadout", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

local function createAndStartStateMachine(
	orchestrator: any,
	className: string,
	stateMachineId: string,
	context: { [string]: any },
	initialState: string
)
	local machine = orchestrator.CreateStateMachine({
		StateMachineClass = className,
		StateMachineId = stateMachineId,
		Context = context,
	})

	if machine then
		machine:Start({ State = initialState })
	end

	return machine
end
--[=[
	@description Handles `RegisterStates` for `SpawnCharacterJob`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function SpawnCharacterJob:RegisterStates()
	--[=[
		@state Validate
		@description Handles the `Validate` state for `SpawnCharacterJob`.
	]=]

	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			local player = fsm.Player
			local character = fsm.Character
			if not player or not player:IsA("Player") or not character or not character:IsA("Model") then
				fsm:Fail("Missing Player or Character in context")
				return
			end

			if not fsm.CharacterEntityId or not fsm.PlayerEntityId then
				fsm:Fail("Missing CharacterEntityId or PlayerEntityId")
				return
			end

			fsm.State = "BindEntity"
		end,
	}, { "BindEntity", "Failed" })
	--[=[
		@state BindEntity
		@description Handles the `BindEntity` state for `SpawnCharacterJob`.
	]=]

	self:AddState("BindEntity", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntity = fsm:GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found: " .. tostring(fsm.CharacterEntityId))
				return
			end

			charEntity:SetContext("Instance", fsm.Character)
			charEntity.IsBlocking = false
			charEntity.CanAnimate = true
			charEntity.IsStunned = false
			charEntity.IsKnocked = false
			charEntity.CanMove = true
			charEntity.MoveSpeedCap = 16
			charEntity.MouseLocked = true
			charEntity.EquippedRight = ""
			charEntity.EquippedLeft = ""
			charEntity.EquipLock = {}
			charEntity.CombatLock = false
			charEntity.CCLock = false
			charEntity.ActionSeq = 0
			charEntity.RecentActions = {}
			charEntity:UpdateEntity()

			fsm.State = "ApplyLoadout"
		end,
	}, { "ApplyLoadout", "Failed" })
	--[=[
		@state ApplyLoadout
		@description Handles the `ApplyLoadout` state for `SpawnCharacterJob`.
	]=]

	self:AddState("ApplyLoadout", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local playerEntity = fsm:GetEntity(fsm.PlayerEntityId)
			if not playerEntity then
				fsm:Log({ Level = "WARN", Message = "PlayerEntity not found, skipping loadout" })
				fsm.State = "Completed"
				return
			end

			local equipped = playerEntity.Equipped
			if typeof(equipped) == "table" then
				for hand, itemId in equipped do
					local itemText = tostring(itemId)
					if itemText ~= "" and itemText ~= "0" and hand ~= nil then
						createAndStartStateMachine(
							orchestrator,
							"EquipJob",
							"SpawnEquip_"
								.. tostring(fsm.CharacterEntityId)
								.. "_"
								.. tostring(hand)
								.. "_"
								.. tostring(os.clock()),
							{
								CharacterEntityId = fsm.CharacterEntityId,
								PlayerEntityId = fsm.PlayerEntityId,
								ItemId = itemText,
								Hand = tostring(hand),
							},
							"ValidateRequest"
						)
					end
				end
			end

			fsm.State = "Completed"
		end,
	}, { "Completed", "Failed" })
	--[=[
		@state Completed
		@description Handles the `Completed` terminal state for `SpawnCharacterJob`.
	]=]

	self:AddState("Completed", function(_fsm) end, {})
	--[=[
		@state Failed
		@description Handles the `Failed` terminal state for `SpawnCharacterJob`.
	]=]

	self:AddState("Failed", function(_fsm) end, {})
end

return SpawnCharacterJob
