--!strict
-- @Name LoadPlayerJob
-- @Description FSM state machine module.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers, "Helpers folder not found")
local ModuleLoader = require(Helpers:WaitForChild("ModuleLoader"))
local EntityHelpers = require(Helpers:WaitForChild("EntityHelpers"))
-- @Name LoadPlayerJob
-- @Author iKrypto
-- @Description Handles player initialization: creates PlayerEntity (persistent), waits for character, creates CharacterEntity, registers command handlers

local LoadPlayerJob = {
	Name = "LoadPlayerJob",
	className = "LoadPlayerJob",
	validStates = {
		"Start",
		"ValidatePlayer",
		"CreatePlayerEntity",
		"LoadData",
		"AwaitCharacter",
		"CreateCharacterEntity",
		"RegisterCommands",
		"RegisterCombatCommands",
		"RegisterEquipCommands",
		"RegisterAbilityCommands",
		"RegisterUtilityCommands",
		"PublishLoaded",
		"Completed",
		"Failed",
	},
	terminalStates = { "Completed", "Failed" },
	initialState = "Start",
}

local DEFAULT_INVENTORY = {
	"1", "2", "3", "4", "5", "6", "7", "8",
	"Artura", "ArturaUnleash",
	"Gale", "GaleUnleash",
	"Kama", "KamaUnleash",
	"Shade", "ShadeUnleash",
	"Zephyr", "ZephyrUnleash",
}

local COMMAND_COOLDOWN = 0.4 -- 400ms between commands per player
local lastCommandTime: { [number]: number } = {} -- userId → os.clock()

local function isRateLimited(userId: number): boolean
	local now = os.clock()
	local last = lastCommandTime[userId]
	if last and (now - last) < COMMAND_COOLDOWN then
		return true
	end
	lastCommandTime[userId] = now
	return false
end

local function registerEntityCommand(
	orchestrator: any,
	entityId: string,
	command: string,
	handler: (Player, ...any) -> ()
)
	local registerCallback = (orchestrator :: any).RegisterEntityCommandCallback
		or (orchestrator :: any).RegisterCommandHandler
	assert(type(registerCallback) == "function", "Orchestrator command registration API is unavailable")
	registerCallback(entityId, command, handler)
end

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

-- Initialization helper only: seeds persistent player defaults before behavioral states run.
local function applyPlayerDefaults(orchestrator: any, playerEntity: any, player: Player, userId: number)
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
	else
		-- Ensure all default items are present (migration for existing saves)
		local inv = playerEntity.Inventory
		local added = false
		for _, itemId in ipairs(DEFAULT_INVENTORY) do
			if not table.find(inv, itemId) then
				table.insert(inv, itemId)
				added = true
			end
		end
		if added then
			playerEntity.Inventory = inv
			dirty = true
		end
	end

	if typeof(playerEntity.Equipped) ~= "table" then
		playerEntity.Equipped = {}
		dirty = true
	end

	if type(playerEntity.WeaponEqp) ~= "string" or playerEntity.WeaponEqp == "1" then
		playerEntity.WeaponEqp = ""
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

	if typeof(playerEntity.LearnedAbilities) ~= "table" then
		playerEntity.LearnedAbilities = {}
		dirty = true
	end

	local talentTreeDefs = ModuleLoader.requireSharedModule(orchestrator, "TalentTreeDefs")
	local remainingSkillPoints = talentTreeDefs.GetRemainingSkillPoints(playerEntity)
	if type(playerEntity.SkillPoints) ~= "number" or playerEntity.SkillPoints ~= remainingSkillPoints then
		playerEntity.SkillPoints = remainingSkillPoints
		dirty = true
	end

	for _, statName in ipairs({ "StatPoints", "Strength", "Agility", "Vitality", "Endurance", "Intelligence", "Luck" }) do
		if type(playerEntity[statName]) ~= "number" then
			playerEntity[statName] = 0
			dirty = true
		end
	end

	if typeof(playerEntity.AbilityBindings) ~= "table" then
		playerEntity.AbilityBindings = { Q = "", E = "", R = "", F = "" }
		dirty = true
	else
		local nextBindings = table.clone(playerEntity.AbilityBindings)
		for _, key in ipairs({ "Q", "E", "R", "F" }) do
			if typeof(nextBindings[key]) ~= "string" then
				nextBindings[key] = ""
				dirty = true
			end
		end
		playerEntity.AbilityBindings = nextBindings
	end

	if typeof(playerEntity.QuickItemSlots) ~= "table" then
		playerEntity.QuickItemSlots = { "", "", "", "" }
		dirty = true
	else
		local nextQuickSlots = table.clone(playerEntity.QuickItemSlots)
		for index = 1, 4 do
			if typeof(nextQuickSlots[index]) ~= "string" then
				nextQuickSlots[index] = ""
				dirty = true
			end
		end
		playerEntity.QuickItemSlots = nextQuickSlots
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

-- Initialization helper only: seeds character defaults before command registration begins.
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

	if typeof(charEntity.AbilityCooldowns) ~= "table" then
		charEntity.AbilityCooldowns = {}
		dirty = true
	end

	if typeof(charEntity.ActiveStatusEffects) ~= "table" then
		charEntity.ActiveStatusEffects = {}
		dirty = true
	end

	if type(charEntity.ActiveCastId) ~= "string" then
		charEntity.ActiveCastId = ""
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

	EntityHelpers.syncHumanoidFromEntity(charEntity)
	if dirty then
		charEntity:UpdateEntity()
	end
end

local function applyDerivedCharacterStats(orchestrator: any, playerEntity: any, charEntity: any, refillResources: boolean?): boolean
	if not playerEntity or not charEntity then
		return false
	end

	local talentTreeDefs = ModuleLoader.getSharedModule(orchestrator, "TalentTreeDefs")
	local statDefs = ModuleLoader.getSharedModule(orchestrator, "StatDefs")
	local passiveEffects = if talentTreeDefs and type(talentTreeDefs.GetMergedPassiveEffects) == "function"
		then talentTreeDefs.GetMergedPassiveEffects(playerEntity)
		else {}
	local statBonuses = if statDefs and type(statDefs.ComputeBonuses) == "function" then statDefs.ComputeBonuses(playerEntity) else {}

	local nextMaxHealth = 100 + (tonumber(passiveEffects.MaxHealth) or 0) + (tonumber(statBonuses.MaxHealthBonus) or 0)
	local nextMaxStamina = 100 + (tonumber(passiveEffects.MaxStamina) or 0) + (tonumber(statBonuses.MaxStaminaBonus) or 0)
	local nextMaxMana = 50 + (tonumber(passiveEffects.MaxMana) or 0) + (tonumber(statBonuses.MaxManaBonus) or 0)
	local dirty = false

	if tonumber(charEntity.MaxHealth) ~= nextMaxHealth then
		charEntity.MaxHealth = nextMaxHealth
		dirty = true
	end
	if tonumber(charEntity.MaxStamina) ~= nextMaxStamina then
		charEntity.MaxStamina = nextMaxStamina
		dirty = true
	end
	if tonumber(charEntity.MaxMana) ~= nextMaxMana then
		charEntity.MaxMana = nextMaxMana
		dirty = true
	end

	local nextHealth = if refillResources then nextMaxHealth else math.clamp(tonumber(charEntity.Health) or nextMaxHealth, 0, nextMaxHealth)
	local nextStamina = if refillResources then nextMaxStamina else math.clamp(tonumber(charEntity.Stamina) or nextMaxStamina, 0, nextMaxStamina)
	local nextMana = if refillResources then nextMaxMana else math.clamp(tonumber(charEntity.Mana) or nextMaxMana, 0, nextMaxMana)
	if tonumber(charEntity.Health) ~= nextHealth then
		charEntity.Health = nextHealth
		dirty = true
	end
	if tonumber(charEntity.Stamina) ~= nextStamina then
		charEntity.Stamina = nextStamina
		dirty = true
	end
	if tonumber(charEntity.Mana) ~= nextMana then
		charEntity.Mana = nextMana
		dirty = true
	end

	return dirty
end

local function getCommandRegistrationContext(fsm: any)
	local orchestrator = fsm:GetOrchestrator()
	local charEntityId = fsm.CharacterEntityId :: string
	local playerEntityId = fsm.PlayerEntityId :: string
	local ownerUserId = fsm.UserId :: number

	local function isAuthorized(player: Player?): boolean
		return player ~= nil and player.UserId == ownerUserId
	end

	return orchestrator, charEntityId, playerEntityId, ownerUserId, isAuthorized
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
			local orchestrator = fsm:GetOrchestrator()
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

			applyPlayerDefaults(orchestrator, playerEntity, player, userId)
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
			local orchestrator = fsm:GetOrchestrator()
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

			charEntity.Instance = character
			applyCharacterDefaults(charEntity, character, userId, playerEntityId)
			local playerEntity = orchestrator.GetEntity(playerEntityId)
			if playerEntity then
				local passiveEffects =
					ModuleLoader.requireSharedModule(orchestrator, "TalentTreeDefs").GetMergedPassiveEffects(playerEntity)
				local appliedDerivedBonuses = false
				for stat, bonus in pairs(passiveEffects) do
					if stat ~= "MaxHealth" and stat ~= "MaxStamina" and stat ~= "MaxMana" then
						if typeof(bonus) == "number" and typeof(charEntity[stat]) == "number" then
							charEntity[stat] = (tonumber(charEntity[stat]) or 0) + bonus
							appliedDerivedBonuses = true
						end
					end
				end
				if applyDerivedCharacterStats(orchestrator, playerEntity, charEntity, true) then
					appliedDerivedBonuses = true
				end
				if appliedDerivedBonuses then
					EntityHelpers.syncHumanoidFromEntity(charEntity)
					charEntity:UpdateEntity()
				end
			end
			fsm.Context.CharacterEntityId = entityId
			fsm.State = "RegisterCommands"
		end,
	}, { "RegisterCommands", "Failed" })

	self:AddState("RegisterCommands", {
		OnEnter = function(_, fsm)
			fsm.State = "RegisterCombatCommands"
		end,
	}, { "RegisterCombatCommands", "Failed" })

	self:AddState("RegisterCombatCommands", {
		OnEnter = function(_, fsm)
			local orchestrator, charEntityId, playerEntityId, _, isAuthorized = getCommandRegistrationContext(fsm)

			registerEntityCommand(orchestrator, charEntityId, "RequestAttack", function(player, comboSlot)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				createAndStartStateMachine(
					orchestrator,
					"AttackJob",
					"Attack_" .. charEntityId .. "_" .. tostring(os.clock()),
					{
						CharacterEntityId = charEntityId,
						PlayerEntityId = playerEntityId,
						ComboSlot = comboSlot,
					},
					"Validate"
				)
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestMeleeAttack", function(player, comboSlot)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				createAndStartStateMachine(
					orchestrator,
					"MeleeAttackJob",
					"Melee_" .. charEntityId .. "_" .. tostring(os.clock()),
					{
						CharacterEntityId = charEntityId,
						PlayerEntityId = playerEntityId,
						ComboSlot = comboSlot,
					},
					"Validate"
				)
			end)

			registerEntityCommand(
				orchestrator,
				charEntityId,
				"RequestDamage",
				function(player, victimUserId, attackName)
					if not isAuthorized(player) then
						return
					end
					if isRateLimited(player.UserId) then
						return
					end
					if not player.Parent then
						return
					end
					createAndStartStateMachine(
						orchestrator,
						"DamageJob",
						"Damage_" .. charEntityId .. "_" .. tostring(os.clock()),
						{
							AttackerCharEntityId = charEntityId,
							VictimUserId = victimUserId,
							AttackName = attackName,
						},
						"Validate"
					)
				end
			)

			registerEntityCommand(orchestrator, charEntityId, "SetBlocking", function(player, isBlocking)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				local charEntity = orchestrator.GetEntity(charEntityId)
				if not charEntity then
					return
				end

				local nextValue = isBlocking == true
				if charEntity.IsBlocking ~= nextValue then
					charEntity.IsBlocking = nextValue
					-- Best-effort commit — entity may be locked by a combat FSM.
					-- The field is staged regardless; the next UpdateEntity from the
					-- lock holder will commit it.
					pcall(function() charEntity:UpdateEntity() end)
				end
			end)

			fsm.State = "RegisterEquipCommands"
		end,
	}, { "RegisterEquipCommands", "Failed" })

	self:AddState("RegisterEquipCommands", {
		OnEnter = function(_, fsm)
			local orchestrator, charEntityId, playerEntityId, _, isAuthorized = getCommandRegistrationContext(fsm)

			registerEntityCommand(orchestrator, charEntityId, "RequestEquip", function(player, itemId, hand)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				createAndStartStateMachine(
					orchestrator,
					"EquipJob",
					"Equip_" .. charEntityId .. "_" .. tostring(os.clock()),
					{
						CharacterEntityId = charEntityId,
						PlayerEntityId = playerEntityId,
						ItemId = tostring(itemId or ""),
						Hand = hand or "Right",
					},
					"ValidateRequest"
				)
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestUnEquip", function(player, hand)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				createAndStartStateMachine(
					orchestrator,
					"UnEquipJob",
					"UnEquip_" .. charEntityId .. "_" .. tostring(os.clock()),
					{
						CharacterEntityId = charEntityId,
						Hand = hand or "Right",
						ForceRemove = true,
					},
					"ValidateRequest"
				)
			end)

			registerEntityCommand(orchestrator, charEntityId, "ToggleWeapon", function(player)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				createAndStartStateMachine(
					orchestrator,
					"ToggleWeaponJob",
					"Toggle_" .. charEntityId .. "_" .. tostring(os.clock()),
					{
						CharacterEntityId = charEntityId,
						PlayerEntityId = playerEntityId,
					},
					"Validate"
				)
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestAddItem", function(player, itemId)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				createAndStartStateMachine(
					orchestrator,
					"InventoryItemFSM",
					"AddItem_" .. charEntityId .. "_" .. tostring(os.clock()),
					{
						Operation = "Add",
						PlayerEntityId = playerEntityId,
						ItemId = tostring(itemId or ""),
					},
					"Validate"
				)
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestDropItem", function(player, itemId)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				createAndStartStateMachine(
					orchestrator,
					"InventoryItemFSM",
					"Drop_" .. charEntityId .. "_" .. tostring(os.clock()),
					{
						Operation = "Drop",
						CharacterEntityId = charEntityId,
						PlayerEntityId = playerEntityId,
						ItemId = tostring(itemId or ""),
					},
					"Validate"
				)
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestMoveItem", function(player, itemId, direction)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				createAndStartStateMachine(
					orchestrator,
					"InventoryItemFSM",
					"MoveItem_" .. charEntityId .. "_" .. tostring(os.clock()),
					{
						Operation = "Move",
						PlayerEntityId = playerEntityId,
						ItemId = tostring(itemId or ""),
						Direction = tostring(direction or ""),
					},
					"Validate"
				)
			end)

			fsm.State = "RegisterAbilityCommands"
		end,
	}, { "RegisterAbilityCommands", "Failed" })

	self:AddState("RegisterAbilityCommands", {
		OnEnter = function(_, fsm)
			local orchestrator, charEntityId, playerEntityId, _, isAuthorized = getCommandRegistrationContext(fsm)

			registerEntityCommand(orchestrator, charEntityId, "RequestAbility", function(player, abilityId)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				createAndStartStateMachine(
					orchestrator,
					"CastFSM",
					"Cast_" .. charEntityId .. "_" .. tostring(os.clock()),
					{
						CharacterEntityId = charEntityId,
						PlayerEntityId = playerEntityId,
						AbilityId = abilityId,
					},
					"Validate"
				)
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestRangedAttack", function(player)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				createAndStartStateMachine(
					orchestrator,
					"ProjectileAttackJob",
					"Ranged_" .. charEntityId .. "_" .. tostring(os.clock()),
					{
						CharacterEntityId = charEntityId,
						PlayerEntityId = playerEntityId,
					},
					"Validate"
				)
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestUseItem", function(player, slotIndex)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				local playerEntity = orchestrator.GetEntity(playerEntityId)
				if not playerEntity then
					return
				end
				local slots = playerEntity.QuickItemSlots
				if typeof(slots) ~= "table" then
					return
				end
				local numericSlotIndex = tonumber(slotIndex)
				if typeof(numericSlotIndex) ~= "number" then
					return
				end
				local itemId = slots[numericSlotIndex]
				if typeof(itemId) ~= "string" or itemId == "" then
					return
				end
				createAndStartStateMachine(
					orchestrator,
					"CastFSM",
					"Item_" .. charEntityId .. "_" .. tostring(os.clock()),
					{
						CharacterEntityId = charEntityId,
						PlayerEntityId = playerEntityId,
						ConsumableId = itemId,
						SlotIndex = numericSlotIndex,
					},
					"Validate"
				)
			end)

			registerEntityCommand(orchestrator, charEntityId, "RequestUnlockTalent", function(player, nodeId)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end

				local talentTreeDefs = ModuleLoader.requireSharedModule(orchestrator, "TalentTreeDefs")
				local playerEntity = orchestrator.GetEntity(playerEntityId)
				if not playerEntity then
					return
				end

				local requestedNodeId = tostring(nodeId or "")
				local canUnlock, reason = talentTreeDefs.CanUnlock(requestedNodeId, playerEntity)
				if not canUnlock then
					warn("[TalentTree] Cannot unlock " .. requestedNodeId .. ": " .. tostring(reason))
					return
				end

				local node = talentTreeDefs.GetNode(requestedNodeId)
				if not node then
					return
				end

				local learned = if typeof(playerEntity.LearnedAbilities) == "table"
					then table.clone(playerEntity.LearnedAbilities)
					else {}
				table.insert(learned, requestedNodeId)
				playerEntity.LearnedAbilities = learned
				playerEntity.SkillPoints = talentTreeDefs.GetRemainingSkillPoints(playerEntity)
				playerEntity:UpdateEntity()

				if node.Type == "Passive" and typeof(node.Effect) == "table" then
					local charEntity = orchestrator.GetEntity(charEntityId)
					if charEntity then
						for stat, bonus in pairs(node.Effect) do
							if typeof(bonus) == "number" and typeof(charEntity[stat]) == "number" then
								charEntity[stat] = (tonumber(charEntity[stat]) or 0) + bonus
							end
						end
						EntityHelpers.syncHumanoidFromEntity(charEntity)
						charEntity:UpdateEntity()
					end
				end
			end)

			fsm.State = "RegisterUtilityCommands"
		end,
	}, { "RegisterUtilityCommands", "Failed" })

	self:AddState("RegisterUtilityCommands", {
		OnEnter = function(_, fsm)
			local orchestrator, charEntityId, playerEntityId, _, isAuthorized = getCommandRegistrationContext(fsm)

			registerEntityCommand(orchestrator, charEntityId, "RequestAction", function(player, kind, payload)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				createAndStartStateMachine(
					orchestrator,
					"ReplicateIntentJob",
					"Intent_" .. charEntityId .. "_" .. tostring(os.clock()),
					{
						CharacterEntityId = charEntityId,
						Kind = kind,
						Payload = payload,
					},
					"Validate"
				)
			end)

			registerEntityCommand(
				orchestrator,
				charEntityId,
				"ApplyStatusEffect",
				function(player, effectId, targetCharEntityId)
					if player ~= nil and not isAuthorized(player) then
						return
					end
					if player ~= nil and isRateLimited(player.UserId) then
						return
					end
					if player ~= nil and not player.Parent then
						return
					end

					local statusEffectHelper = ModuleLoader.requireSharedModule(orchestrator, "StatusEffectHelper")
					local requestedEffectId = tostring(effectId or "")
					local targetId = if typeof(targetCharEntityId) == "string" and targetCharEntityId ~= ""
						then targetCharEntityId
						else charEntityId
					statusEffectHelper.Apply(orchestrator, targetId, requestedEffectId)
				end
			)

			registerEntityCommand(orchestrator, charEntityId, "RequestAllocateStat", function(player, statName)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				local statDefs = ModuleLoader.getSharedModule(orchestrator, "StatDefs")
				if not statDefs or not statDefs.Stats or statDefs.Stats[statName] == nil then
					return
				end

				local playerEntity = orchestrator.GetEntity(playerEntityId)
				if not playerEntity then
					return
				end

				local statPoints = tonumber(playerEntity.StatPoints) or 0
				if statPoints <= 0 then
					return
				end

				local requestedStatName = tostring(statName or "")
				local currentValue = tonumber(playerEntity[requestedStatName]) or 0
				if currentValue >= (tonumber(statDefs.MAX_STAT_LEVEL) or 100) then
					return
				end

				local lockId = "AllocStat_" .. charEntityId
				if not playerEntity:AcquireLock(lockId) then
					return
				end

				local updateOk, updateErr = pcall(function()
					playerEntity[requestedStatName] = currentValue + 1
					playerEntity.StatPoints = statPoints - 1
					playerEntity:UpdateEntity(lockId)
				end)
				playerEntity:ReleaseLock(lockId)
				if not updateOk then
					warn("[StatGui] Failed to allocate stat: " .. tostring(updateErr))
					return
				end

				local charEntity = orchestrator.GetEntity(charEntityId)
				if charEntity then
					local charLockId = "StatBonus_" .. charEntityId
					if charEntity:AcquireLock(charLockId) then
						local shouldUpdate = applyDerivedCharacterStats(orchestrator, playerEntity, charEntity, false)
						if shouldUpdate then
							EntityHelpers.syncHumanoidFromEntity(charEntity)
							charEntity:UpdateEntity(charLockId)
						end
						charEntity:ReleaseLock(charLockId)
					end
				end
			end)

			registerEntityCommand(orchestrator, charEntityId, "SetSprinting", function(player, isSprinting)
				if not isAuthorized(player) then
					return
				end
				if isRateLimited(player.UserId) then
					return
				end
				if not player.Parent then
					return
				end
				local charEntity = orchestrator.GetEntity(charEntityId)
				if not charEntity then
					return
				end

				local nextValue = isSprinting == true
				if charEntity.SprintIntent ~= nextValue then
					charEntity.SprintIntent = nextValue
					pcall(function() charEntity:UpdateEntity() end)
				end
			end)

			fsm.State = "PublishLoaded"
		end,
	}, { "PublishLoaded", "Failed" })

	self:AddState("PublishLoaded", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
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
