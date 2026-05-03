--!strict
-- @Name UnEquipJob
-- @Author iKrypto
-- @Description Handles unequipping an item from a hand: validates, resolves current item, stows or drops it, updates entity state, emits intent

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers, "Helpers folder not found")
local ModuleLoader = require(Helpers:WaitForChild("ModuleLoader"))
local StateTransitionHelpers = require(Helpers:WaitForChild("StateTransitionHelpers"))

local UnEquipJob = {
	Name = "UnEquipJob",
	className = "UnEquipJob",
	validStates = {
		"ValidateRequest",
		"AcquireEquipLock",
		"ResolveExistingItem",
		"DoUnEquip",
		"CommitState",
		"EmitIntent",
		"ReleaseEquipLock",
		"Rollback",
		"Completed",
		"Failed",
	},
	terminalStates = { "Completed", "Failed" },
	initialState = "ValidateRequest",
}

local cachedEquipHelpers = nil :: any
local cachedIntentSchema = nil :: any

local function getEquipHelpers(orchestrator: any)
	if not cachedEquipHelpers then
		cachedEquipHelpers = ModuleLoader.requireSharedModule(orchestrator, "EquipHelpers")
	end
	return cachedEquipHelpers
end

local function getIntentSchema(orchestrator: any)
	if not cachedIntentSchema then
		cachedIntentSchema = ModuleLoader.requireSharedModule(orchestrator, "IntentSchema")
	end
	return cachedIntentSchema
end

local function getHandProperty(hand: string): string
	return if hand == "Right" then "EquippedRight" else "EquippedLeft"
end

local function ensureEntitiesAlive(fsm): (any?, any?, any?)
	local orchestrator = fsm:GetOrchestrator()
	local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
	if not charEntity then
		return nil, nil, nil
	end

	local playerEntityId = fsm.PlayerEntityId
	if type(playerEntityId) ~= "string" or playerEntityId == "" then
		playerEntityId = charEntity.PlayerEntityId
	end
	local playerEntity = if type(playerEntityId) == "string" and playerEntityId ~= ""
		then orchestrator.GetEntity(playerEntityId)
		else nil
	if not playerEntity then
		return nil, nil, nil
	end

	local character = charEntity.Instance
	if not character or not character.Parent then
		local Players = game:GetService("Players")
		local userId = charEntity.UserId or charEntity:GetContext("UserId")
		if userId then
			for _, player in Players:GetPlayers() do
				if player.UserId == userId and player.Character and player.Character.Parent then
					character = player.Character
					break
				end
			end
		end
	end
	if not character or not character.Parent then
		return nil, nil, nil
	end
	return charEntity, playerEntity, character
end

function UnEquipJob:RegisterStates()
	self:AddState("ValidateRequest", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end

			local hand = fsm.Hand or "Right"
			if hand ~= "Right" and hand ~= "Left" then
				fsm:Fail("Invalid hand: " .. tostring(hand))
				return
			end

			fsm.Context.Hand = hand
			fsm.State = "AcquireEquipLock"
		end,
	}, { "AcquireEquipLock", "Failed" })

	self:AddState("AcquireEquipLock", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity no longer exists")
				return
			end

			local hand = fsm.Hand :: string
			local equipLock = if typeof(charEntity.EquipLock) == "table" then table.clone(charEntity.EquipLock) else {}
			if equipLock[hand] then
				local retryCount = tonumber(fsm.Context._equipLockRetryCount) or 0
				if retryCount < 5 then
					fsm.Context._equipLockRetryCount = retryCount + 1
					fsm.WaitSpan = 0.3
					fsm.State = "AcquireEquipLock"
				else
					fsm:Fail("Timed out waiting for EquipLock for hand: " .. hand)
				end
				return
			end

			fsm.Context._equipLockRetryCount = 0
			fsm.Context._equipLockHeld = true
			equipLock[hand] = true
			charEntity.EquipLock = equipLock
			charEntity:UpdateEntity()
			fsm.State = "ResolveExistingItem"
		end,
	}, { "ResolveExistingItem", "Rollback", "Failed" })

	self:AddState("ResolveExistingItem", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm, "Entities no longer alive during ResolveExistingItem")
				return
			end

			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local hand = fsm.Hand :: string
			local handPart = equipHelpers.GetHandPart(character, hand)
			if not handPart then
				StateTransitionHelpers.queueRollback(fsm, "Hand part not found for hand: " .. hand)
				return
			end

			local weld = equipHelpers.FindHandleWeld(handPart)
			local item = if weld and weld.Part1 then weld.Part1.Parent else nil
			local itemData = if item then equipHelpers.GetItemData(item) else nil
			local currentItemId = charEntity[getHandProperty(hand)]
			if (type(currentItemId) ~= "string" or currentItemId == "") and item then
				currentItemId = item.Name
			end

			fsm.Context._resolvedHandPart = handPart
			fsm.Context._resolvedWeld = weld
			fsm.Context._resolvedItem = item
			fsm.Context._resolvedItemData = itemData
			fsm.Context._resolvedItemId = currentItemId or ""
			fsm.State = "DoUnEquip"
		end,
	}, { "DoUnEquip", "Rollback", "Failed" })

	self:AddState("DoUnEquip", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm, "Entities no longer alive during DoUnEquip")
				return
			end

			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local weld = fsm.Context._resolvedWeld
			local item = fsm.Context._resolvedItem
			local itemData = fsm.Context._resolvedItemData
			if not weld or not item then
				local message = string.format(
					"UnEquipJob proceeding without physical item for hand %s (weld=%s, item=%s)",
					tostring(fsm.Hand),
					tostring(weld ~= nil),
					tostring(item ~= nil)
				)
				if type(fsm.Log) == "function" then
					fsm:Log({ Level = "WARN", Message = message })
				else
					warn(message)
				end
			else
				-- ForceRemove: always destroy (e.g. explicit unequip from inventory)
				-- Otherwise: stow if possible, else drop
				if fsm.Context.ForceRemove or not (itemData and itemData.Stowable) then
					equipHelpers.DropItem(item, weld)
				else
					equipHelpers.StowItem(item, character, weld, itemData)
					fsm.Context._wasStowed = true
				end
			end

			fsm.State = "CommitState"
		end,
	}, { "CommitState", "Rollback", "Failed" })

	self:AddState("CommitState", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm, "Entities no longer alive during CommitState")
				return
			end

			local hand = fsm.Hand :: string

			-- When stowed, the weapon is still equipped (just on the character's back).
			-- Only clear equipped state and return to inventory for non-stow unequips.
			if fsm.Context._wasStowed then
				-- Keep EquippedRight/Left, Equipped table, and WeaponEqp intact.
				-- The item stays "equipped" but visually stowed.
				charEntity:UpdateEntity()
				playerEntity:UpdateEntity()
			else
				charEntity[getHandProperty(hand)] = ""
				charEntity:UpdateEntity()

				local equipped = if typeof(playerEntity.Equipped) == "table"
					then table.clone(playerEntity.Equipped)
					else {}
				equipped[hand] = nil
				playerEntity.Equipped = equipped
				if hand == "Right" and not fsm.Context._resolvedItemId then
					playerEntity.WeaponEqp = ""
				end
				-- Return item to inventory
				local inventory = playerEntity.Inventory
				if typeof(inventory) == "table" and fsm.Context._resolvedItemId and fsm.Context._resolvedItemId ~= "" then
					if not table.find(inventory, fsm.Context._resolvedItemId) then
						inventory = table.clone(inventory)
						table.insert(inventory, fsm.Context._resolvedItemId)
						playerEntity.Inventory = inventory
					end
				end
				playerEntity:UpdateEntity()
			end

			fsm.State = "EmitIntent"
		end,
	}, { "EmitIntent", "Rollback", "Failed" })

	self:AddState("EmitIntent", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm, "Entities no longer alive during EmitIntent")
				return
			end

			local orchestrator = fsm:GetOrchestrator()
			local intentSchema = getIntentSchema(orchestrator)
			intentSchema.AppendIntent(charEntity, {
				Kind = "UnEquip",
				Payload = {
					Hand = fsm.Hand,
					ItemId = fsm.Context._resolvedItemId,
				},
			})

			fsm.State = "ReleaseEquipLock"
		end,
	}, { "ReleaseEquipLock", "Rollback", "Failed" })

	self:AddState("ReleaseEquipLock", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if charEntity and fsm.Context._equipLockHeld then
				local equipLock = if typeof(charEntity.EquipLock) == "table"
					then table.clone(charEntity.EquipLock)
					else {}
				equipLock[fsm.Hand] = nil
				charEntity.EquipLock = equipLock
				charEntity:UpdateEntity()
				fsm.Context._equipLockHeld = false
			end

			if fsm.Context._failureReason then
				fsm:Log({ Level = "ERROR", Message = tostring(fsm.Context._failureReason) })
				fsm.State = "Failed"
			else
				fsm.State = "Completed"
			end
		end,
	}, { "Completed", "Failed" })

	self:AddState("Rollback", {
		OnEnter = function(_, fsm)
			fsm.State = "ReleaseEquipLock"
		end,
	}, { "ReleaseEquipLock" })

	self:AddState("Completed", function(_fsm) end, {})
	self:AddState("Failed", function(_fsm) end, {})
end

return UnEquipJob
