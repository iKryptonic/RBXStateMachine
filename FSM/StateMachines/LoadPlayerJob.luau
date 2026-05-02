--!strict
-- @Name LoadPlayerJob
-- @Author iKrypto
-- @Description Handles player initialization: creates PlayerEntity (persistent), waits for character, creates CharacterEntity, registers command handlers

local LoadPlayerJob = {
	Name = "LoadPlayerJob",
	className = "LoadPlayerJob",
	validStates = { "Start", "ValidatePlayer", "CreatePlayerEntity", "LoadData", "AwaitCharacter", "CreateCharacterEntity", "RegisterCommands", "PublishLoaded", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Start",
}

local DEFAULT_INVENTORY = { "1", "2", "3", "4", "5", "6", "7" }

local function getOrchestrator()
	-- Try shared.fsm / shared.FSM (legacy pattern)
	local lower = (shared :: any).fsm
	if lower ~= nil then
		return lower.Orchestrator or lower
	end
	local upper = (shared :: any).FSM
	if upper ~= nil and upper.Orchestrator then
		return upper.Orchestrator
	end

	-- Fallback: require from ReplicatedStorage (new canonical pattern)
	local rs = game:GetService("ReplicatedStorage")
	local orchModule = rs:FindFirstChild("Orchestrator")
	if orchModule and orchModule:IsA("ModuleScript") then
		local ok, result = pcall(require, orchModule)
		if ok and result then return result end
	end

	error("Orchestrator is not registered")
end

local function registerEntityCommand(orchestrator: any, entityId: string, command: string, handler: (Player, ...any) -> ())
	local registerCallback = (orchestrator :: any).RegisterEntityCommandCallback or (orchestrator :: any).RegisterCommandHandler
	assert(type(registerCallback) == "function", "Orchestrator command registration API is unavailable")
	registerCallback(entityId, command, handler)
end

local function createAndStartStateMachine(className: string, stateMachineId: string, context: { [string]: any }, initialState: string)
	local orchestrator = getOrchestrator()
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

local function applyPlayerDefaults(playerEntity: any, player: Player, userId: number)
	playerEntity:SetContext("Instance", player)
	playerEntity:SetContext("OwnerId", tostring(userId))

	local dirty = false

	if playerEntity.UserId ~= userId then
		playerEntity.UserId = userId
		dirty = true
	end

	if type(playerEntity.Class) ~= "string" or playerEntity.Class == "" then
		playerEntity.Class = "Beginner"
		dirty = true
	end

	if typeof(playerEntity.Inventory) ~= "table" or #playerEntity.Inventory == 0 then
		playerEntity.Inventory = table.clone(DEFAULT_INVENTORY)
		dirty = true
	end

	if typeof(playerEntity.Equipped) ~= "table" then
		playerEntity.Equipped = {}
		dirty = true
	end

	if type(playerEntity.WeaponEqp) ~= "string" or playerEntity.WeaponEqp == "" then
		playerEntity.WeaponEqp = "1"
		dirty = true
	end

	if typeof(playerEntity.ActionBar) ~= "table" then
		playerEntity.ActionBar = {}
		dirty = true
	end

	if typeof(playerEntity.Settings) ~= "table" then
		playerEntity.Settings = {}
		dirty = true
	end

	if typeof(playerEntity.Cooldowns) ~= "table" then
		playerEntity.Cooldowns = {}
		dirty = true
	end

	if type(playerEntity.Revision) ~= "number" then
		playerEntity.Revision = 0
		dirty = true
	end

	if type(playerEntity.DataVersion) ~= "number" or playerEntity.DataVersion < 1 then
		playerEntity.DataVersion = 1
		dirty = true
	end

	if dirty then
		playerEntity:UpdateEntity()
	end
end

local function applyCharacterDefaults(charEntity: any, character: Model, userId: number, playerEntityId: string)
	charEntity:SetContext("Instance", character)
	charEntity:SetContext("OwnerId", tostring(userId))

	local dirty = false

	if charEntity.PlayerEntityId ~= playerEntityId then
		charEntity.PlayerEntityId = playerEntityId
		dirty = true
	end

	if charEntity.UserId ~= userId then
		charEntity.UserId = userId
		dirty = true
	end

	if charEntity.IsBlocking ~= false then
		charEntity.IsBlocking = false
		dirty = true
	end

	if charEntity.CanAnimate ~= true then
		charEntity.CanAnimate = true
		dirty = true
	end

	if charEntity.IsStunned ~= false then
		charEntity.IsStunned = false
		dirty = true
	end

	if charEntity.IsKnocked ~= false then
		charEntity.IsKnocked = false
		dirty = true
	end

	if charEntity.CanMove ~= true then
		charEntity.CanMove = true
		dirty = true
	end

	if charEntity.MoveSpeedCap ~= 16 then
		charEntity.MoveSpeedCap = 16
		dirty = true
	end

	if charEntity.MouseLocked ~= true then
		charEntity.MouseLocked = true
		dirty = true
	end

	if charEntity.EquippedRight ~= "" then
		charEntity.EquippedRight = ""
		dirty = true
	end

	if charEntity.EquippedLeft ~= "" then
		charEntity.EquippedLeft = ""
		dirty = true
	end

	if typeof(charEntity.EquipLock) ~= "table" or next(charEntity.EquipLock) ~= nil then
		charEntity.EquipLock = {}
		dirty = true
	end

	if charEntity.CombatLock ~= false then
		charEntity.CombatLock = false
		dirty = true
	end

	if charEntity.CCLock ~= false then
		charEntity.CCLock = false
		dirty = true
	end

	if charEntity.ActionSeq ~= 0 then
		charEntity.ActionSeq = 0
		dirty = true
	end

	if typeof(charEntity.RecentActions) ~= "table" or #charEntity.RecentActions > 0 then
		charEntity.RecentActions = {}
		dirty = true
	end

	if dirty then
		charEntity:UpdateEntity()
	end
end

function LoadPlayerJob:RegisterStates()
	self:AddState("Start", {
		OnEnter = function(_, fsm)
			local userId = fsm.UserId
			local player = fsm.Player
			if type(userId) ~= "number" and player and player:IsA("Player") then
				userId = player.UserId
			end
			fsm:Log({ Level = "INFO", Message = "LoadPlayerJob starting for " .. tostring(userId) })
			fsm.State = "ValidatePlayer"
		end,
	}, { "ValidatePlayer", "Failed" })

	self:AddState("ValidatePlayer", {
		OnEnter = function(_, fsm)
			local player = fsm.Player
			if not player or not player:IsA("Player") then
				fsm:Fail("Invalid player reference")
				return
			end

			if player.UserId == 0 then
				fsm:Fail("Invalid UserId: " .. tostring(player.UserId))
				return
			end

			fsm.Context.UserId = player.UserId
			fsm.State = "CreatePlayerEntity"
		end,
	}, { "CreatePlayerEntity", "Failed" })

	self:AddState("CreatePlayerEntity", {
		OnEnter = function(_, fsm)
			local orchestrator = getOrchestrator()
			local player = fsm.Player :: Player
			local userId = fsm.UserId :: number
			local entityId = "Player_" .. tostring(userId)

			local playerEntity = orchestrator.GetEntity(entityId)
			if not playerEntity then
				playerEntity = orchestrator.CreateEntity({
					EntityClass = "PlayerEntity",
					EntityId = entityId,
					Persistent = true,
					PersistenceKey = tostring(userId),
					Context = {
						OwnerId = tostring(userId),
						Instance = player,
						UserId = userId,
					},
				})
			end

			if not playerEntity then
				fsm:Fail("Failed to create PlayerEntity")
				return
			end

			applyPlayerDefaults(playerEntity, player, userId)
			fsm.Context.PlayerEntityId = entityId
			fsm.State = "LoadData"
		end,
	}, { "LoadData", "Failed" })

	self:AddState("LoadData", {
		OnEnter = function(_, fsm)
			fsm.State = "AwaitCharacter"
		end,
	}, { "AwaitCharacter", "Failed" })

	self:AddState("AwaitCharacter", {
		OnEnter = function(_, fsm)
			local player = fsm.Player :: Player
			if player.Character then
				fsm.Context.Character = player.Character
				fsm.State = "CreateCharacterEntity"
				return
			end

			fsm.Context._awaitStart = os.clock()
		end,
		OnHeartbeat = function(_, fsm, _dt)
			local player = fsm.Player
			if not player or not player.Parent then
				fsm:Fail("Player left during character await")
				return
			end

			if player.Character then
				fsm.Context.Character = player.Character
				fsm.State = "CreateCharacterEntity"
				return
			end

			local awaitStart = fsm.Context._awaitStart or os.clock()
			if os.clock() - awaitStart > 30 then
				fsm:Fail("Character did not spawn within 30s")
			end
		end,
	}, { "CreateCharacterEntity", "Failed" })

	self:AddState("CreateCharacterEntity", {
		OnEnter = function(_, fsm)
			local orchestrator = getOrchestrator()
			local userId = fsm.UserId :: number
			local character = fsm.Character
			local playerEntityId = fsm.PlayerEntityId
			local entityId = "Char_" .. tostring(userId)

			if not character or not character:IsA("Model") then
				fsm:Fail("Character missing for CharacterEntity creation")
				return
			end

			local charEntity = orchestrator.GetEntity(entityId)
			if not charEntity then
				charEntity = orchestrator.CreateEntity({
					EntityClass = "CharacterEntity",
					EntityId = entityId,
					Context = {
						OwnerId = tostring(userId),
						Instance = character,
						UserId = userId,
						PlayerEntityId = playerEntityId,
					},
				})
			end

			if not charEntity then
				fsm:Fail("Failed to create CharacterEntity")
				return
			end

			applyCharacterDefaults(charEntity, character, userId, playerEntityId)
			fsm.Context.CharacterEntityId = entityId
			fsm.State = "RegisterCommands"
		end,
	}, { "RegisterCommands", "Failed" })

	self:AddState("RegisterCommands", {
		OnEnter = function(_, fsm)
			local orchestrator = getOrchestrator()
			local charEntityId = fsm.CharacterEntityId :: string
			local playerEntityId = fsm.PlayerEntityId :: string
			local ownerUserId = fsm.UserId :: number

			local function isAuthorized(player: Player): boolean
				return player ~= nil and player.UserId == ownerUserId
			end

			registerEntityCommand(orchestrator, charEntityId, "RequestEquip", function(player, itemId, hand)
				if not isAuthorized(player) then return end
				createAndStartStateMachine("EquipJob", "Equip_" .. charEntityId .. "_" .. tostring(os.clock()), {
					CharacterEntityId = charEntityId,
					PlayerEntityId = playerEntityId,
					ItemId = tostring(itemId or ""),
					Hand = hand or "Right",
				}, "ValidateRequest")
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestUnEquip", function(player, hand)
				if not isAuthorized(player) then return end
				createAndStartStateMachine("UnEquipJob", "UnEquip_" .. charEntityId .. "_" .. tostring(os.clock()), {
					CharacterEntityId = charEntityId,
					Hand = hand or "Right",
				}, "ValidateRequest")
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestDamage", function(player, victimUserId, attackName)
				if not isAuthorized(player) then return end
				createAndStartStateMachine("DamageJob", "Damage_" .. charEntityId .. "_" .. tostring(os.clock()), {
					AttackerCharEntityId = charEntityId,
					VictimUserId = victimUserId,
					AttackName = attackName,
				}, "Validate")
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestAction", function(player, kind, payload)
				if not isAuthorized(player) then return end
				createAndStartStateMachine("ReplicateIntentJob", "Intent_" .. charEntityId .. "_" .. tostring(os.clock()), {
					CharacterEntityId = charEntityId,
					Kind = kind,
					Payload = payload,
				}, "Validate")
			end)

			registerEntityCommand(orchestrator, charEntityId, "SetBlocking", function(player, isBlocking)
				if not isAuthorized(player) then return end
				local charEntity = orchestrator.GetEntity(charEntityId)
				if not charEntity then
					return
				end

				local nextValue = isBlocking == true
				if charEntity.IsBlocking ~= nextValue then
					charEntity.IsBlocking = nextValue
					charEntity:UpdateEntity()
				end
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestAttack", function(player, comboSlot)
				if not isAuthorized(player) then return end
				createAndStartStateMachine("AttackJob", "Attack_" .. charEntityId .. "_" .. tostring(os.clock()), {
					CharacterEntityId = charEntityId,
					PlayerEntityId = playerEntityId,
					ComboSlot = comboSlot,
				}, "Validate")
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestMeleeAttack", function(player, comboSlot)
				if not isAuthorized(player) then return end
				createAndStartStateMachine("MeleeAttackJob", "Melee_" .. charEntityId .. "_" .. tostring(os.clock()), {
					CharacterEntityId = charEntityId,
					PlayerEntityId = playerEntityId,
					ComboSlot = comboSlot,
				}, "Validate")
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestRangedAttack", function(player)
				if not isAuthorized(player) then return end
				createAndStartStateMachine("ProjectileAttackJob", "Ranged_" .. charEntityId .. "_" .. tostring(os.clock()), {
					CharacterEntityId = charEntityId,
					PlayerEntityId = playerEntityId,
				}, "Validate")
			end)

			registerEntityCommand(orchestrator, charEntityId, "ToggleWeapon", function(player)
				if not isAuthorized(player) then return end
				createAndStartStateMachine("ToggleWeaponJob", "Toggle_" .. charEntityId .. "_" .. tostring(os.clock()), {
					CharacterEntityId = charEntityId,
					PlayerEntityId = playerEntityId,
				}, "Validate")
			end)

			fsm.State = "PublishLoaded"
		end,
	}, { "PublishLoaded", "Failed" })

	self:AddState("PublishLoaded", {
		OnEnter = function(_, fsm)
			local orchestrator = getOrchestrator()
			orchestrator.RegisterEventBus("Player/Loaded")
			orchestrator.FireEventBus("Player/Loaded", fsm.UserId, fsm.PlayerEntityId, fsm.CharacterEntityId)
			fsm:Log({ Level = "INFO", Message = "LoadPlayerJob completed for userId " .. tostring(fsm.UserId) })
			fsm.State = "Completed"
		end,
	}, { "Completed", "Failed" })

	self:AddState("Completed", function(_fsm) end, {})
	self:AddState("Failed", function(_fsm) end, {})
end

return LoadPlayerJob
