--!strict


--[=[
	@module SpawnCharacterJob
	@description Spawns or reuses a player character model, positions it, and links it to the runtime character entity.
]=]

local SpawnCharacterJob = {
	Name = "SpawnCharacterJob",
	className = "SpawnCharacterJob",
	validStates = {"Validate","BindEntity","ApplyLoadout","Completed","Failed" },
	terminalStates = {"Completed","Failed" },
	initialState = "Validate",
}

--[=[
	@description Helper for the create and start state machine step used by this state machine.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

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
	@description Registers the runtime states, transitions, and terminal behavior for `SpawnCharacterJob`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function SpawnCharacterJob:RegisterStates()


	--[=[
		@state Validate
		@description Validates the required runtime context and prerequisites.
			Transitions:
			- `BindEntity` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
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
	}, {"BindEntity","Failed" })


	--[=[
		@state BindEntity
		@description On enter, sets `IsBlocking`, sets `CanAnimate`, sets `IsStunned`.
			Transitions:
			- `ApplyLoadout` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: sets `IsBlocking`, sets `CanAnimate`, sets `IsStunned`, sets `IsKnocked`, sets `CanMove`.
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
	}, {"ApplyLoadout","Failed" })


	--[=[
		@state ApplyLoadout
		@description On enter, writes to the log.
			Transitions:
			- `Completed` when this stage finishes its immediate work or falls through its guard checks.
			Writes: writes to the log.
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
								.."_"
								.. tostring(hand)
								.."_"
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
	}, {"Completed","Failed" })
	--[=[
	@state Completed
	@description Terminal success sink reached after the spawned character entity is initialized and any persisted loadout equip jobs have been queued. `OnEnter` is a no-op.
		Transitions: none.
		Writes: none.
	]=]

	self:AddState("Completed", function(_fsm) end, {})
	--[=[
	@state Failed
	@description Terminal failure sink for missing player, character, or entity context during spawn-time binding. `OnEnter` is a no-op because there is no extra rollback after failure.
		Transitions: none.
		Writes: none.
	]=]

	self:AddState("Failed", function(_fsm) end, {})
end

return SpawnCharacterJob
