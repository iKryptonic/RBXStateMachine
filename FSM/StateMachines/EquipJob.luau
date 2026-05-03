--!strict
-- @Name EquipJob
-- @Author iKrypto
-- @Description Handles equipping an item to a hand: validates, clones asset, creates weld, mounts, emits intent

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers, "Helpers folder not found")
local ModuleLoader = require(Helpers:WaitForChild("ModuleLoader"))
local StateTransitionHelpers = require(Helpers:WaitForChild("StateTransitionHelpers"))

local EquipJob = {
	Name = "EquipJob",
	className = "EquipJob",
	validStates = {
		"ValidateRequest",
		"AcquireEquipLock",
		"ResolveItemMeta",
		"PreUnEquip",
		"CloneAsset",
		"CreateWeld",
		"MountItem",
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
	local playerEntity = orchestrator.GetEntity(fsm.PlayerEntityId)
	if not charEntity or not playerEntity then
		return nil, nil, nil
	end
	local character = charEntity.Instance
	if not character or not character.Parent then
		-- Server-side fallback: find player's character directly
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

function EquipJob:RegisterStates()
	self:AddState("ValidateRequest", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			local playerEntity = orchestrator.GetEntity(fsm.PlayerEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end
			if not playerEntity then
				fsm:Fail("PlayerEntity not found")
				return
			end

			local itemId = tostring(fsm.ItemId or "")
			if itemId == "" then
				fsm:Fail("No ItemId provided")
				return
			end

			local assets = ReplicatedStorage:FindFirstChild("Assets")
			if not assets or not assets:FindFirstChild(itemId, true) then
				fsm:Fail("Asset not found for item: " .. itemId)
				return
			end

			local hand = fsm.Hand or "Right"
			if hand ~= "Right" and hand ~= "Left" then
				fsm:Fail("Invalid hand: " .. tostring(hand))
				return
			end

			-- Inventory ownership check
			local bag = playerEntity.BagContents
			local inventory = playerEntity.Inventory
			local hasBag = typeof(bag) == "table" and #bag > 0
			local hasInventory = typeof(inventory) == "table" and #inventory > 0
			if hasBag or hasInventory then
				local found = false
				if hasBag and table.find(bag, itemId) then found = true end
				if not found and hasInventory and table.find(inventory, itemId) then found = true end
				if not found then
					fsm:Fail("Item " .. itemId .. " not in inventory")
					return
				end
			end

			fsm.Context.Hand = hand
			fsm.Context.ItemId = itemId
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
				if retryCount < 3 then
					fsm.Context._equipLockRetryCount = retryCount + 1
					fsm.WaitSpan = 0.2
					fsm.State = "AcquireEquipLock"
				else
					-- Force-clear stale lock after retries
					equipLock[hand] = nil
					charEntity.EquipLock = equipLock
					pcall(function() charEntity:UpdateEntity() end)
				end
				if equipLock[hand] then return end
			end

			fsm.Context._equipLockRetryCount = 0
			fsm.Context._equipLockHeld = true
			equipLock[hand] = true
			charEntity.EquipLock = equipLock
			pcall(function() charEntity:UpdateEntity() end)
			fsm.State = "ResolveItemMeta"
		end,
	}, { "ResolveItemMeta", "Rollback", "Failed" })

	self:AddState("ResolveItemMeta", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local item, itemData = equipHelpers.CloneItem(fsm.ItemId)
			if not item then
				StateTransitionHelpers.queueRollback(fsm, "Item not found in assets: " .. tostring(fsm.ItemId))
				return
			end
			fsm:TrackInstance(item, "WeaponClone:" .. tostring(fsm.ItemId))
			if not itemData then
				item:Destroy()
				StateTransitionHelpers.queueRollback(fsm, "Item has no Data module: " .. tostring(fsm.ItemId))
				return
			end

			local handle = item:FindFirstChild("Handle")
			if not handle or not handle:IsA("BasePart") then
				-- Fallback: use PrimaryPart or first BasePart child
				handle = item.PrimaryPart
				if not handle then
					for _, child in item:GetChildren() do
						if child:IsA("BasePart") then
							handle = child
							break
						end
					end
				end
			end
			if not handle or not handle:IsA("BasePart") then
				item:Destroy()
				StateTransitionHelpers.queueRollback(fsm, "Item has no Handle part: " .. tostring(fsm.ItemId))
				return
			end

			fsm.Context._clonedItem = item
			fsm.Context._itemData = itemData
			fsm.Context._handle = handle
			fsm.State = "PreUnEquip"
		end,
	}, { "PreUnEquip", "Rollback", "Failed" })

	self:AddState("PreUnEquip", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				StateTransitionHelpers.queueRollback(fsm, "CharacterEntity no longer exists")
				return
			end

			local character = charEntity.Instance
			if not character or not character:IsA("Model") then
				StateTransitionHelpers.queueRollback(fsm, "Character model is unavailable")
				return
			end

			local hand = fsm.Hand :: string
			local currentProperty = getHandProperty(hand)
			local currentEquipped = charEntity[currentProperty]
			if type(currentEquipped) == "string" and currentEquipped ~= "" then
				local handPart = equipHelpers.GetHandPart(character, hand)
				if handPart then
					local weld = equipHelpers.FindHandleWeld(handPart)
					if weld and weld.Part1 then
						local existingItem = weld.Part1.Parent
						if existingItem then
							fsm.Context._previousItemId = currentEquipped
							-- Always destroy the old clone when swapping via inventory
							weld:Destroy()
							existingItem:Destroy()
						end
					end
				end
				-- Clear stowed duplicate if any
				equipHelpers.ClearStowedDuplicate(character, currentEquipped)
			end

			fsm.State = "CloneAsset"
		end,
	}, { "CloneAsset", "Rollback", "Failed" })

	self:AddState("CloneAsset", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				StateTransitionHelpers.queueRollback(fsm, "CharacterEntity no longer exists")
				return
			end

			local character = charEntity.Instance
			if not character or not character:IsA("Model") then
				StateTransitionHelpers.queueRollback(fsm, "Character model is unavailable")
				return
			end

			equipHelpers.ClearStowedDuplicate(character, fsm.ItemId)
			fsm.State = "CreateWeld"
		end,
	}, { "CreateWeld", "Rollback", "Failed" })

	self:AddState("CreateWeld", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				StateTransitionHelpers.queueRollback(fsm, "CharacterEntity no longer exists")
				return
			end

			local character = charEntity.Instance
			if not character or not character:IsA("Model") then
				StateTransitionHelpers.queueRollback(fsm, "Character model is unavailable")
				return
			end

			local handPart = equipHelpers.GetHandPart(character, fsm.Hand)
			if not handPart then
				StateTransitionHelpers.queueRollback(fsm, "Hand part not found for hand: " .. tostring(fsm.Hand))
				return
			end

			local weld =
				equipHelpers.CreateWeld(handPart, fsm.Context._handle, fsm.Context._itemData.GripC1 or CFrame.new())
			fsm.Context._weld = weld
			fsm.Context._handPart = handPart
			fsm.State = "MountItem"
		end,
	}, { "MountItem", "Rollback", "Failed" })

	self:AddState("MountItem", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm, "Entities no longer alive during MountItem")
				return
			end

			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local ok, err = pcall(function()
				equipHelpers.MountItem(fsm.Context._clonedItem, fsm.Context._handPart)
			end)
			if not ok then
				StateTransitionHelpers.queueRollback(fsm, "MountItem failed: " .. tostring(err))
				return
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
			local propertyName = getHandProperty(hand)
			charEntity[propertyName] = fsm.ItemId
			pcall(function() charEntity:UpdateEntity() end)

			local equipped = if typeof(playerEntity.Equipped) == "table" then table.clone(playerEntity.Equipped) else {}
			equipped[hand] = fsm.ItemId
			playerEntity.Equipped = equipped
			if hand == "Right" then
				playerEntity.WeaponEqp = fsm.ItemId
			end

			local inventory = if typeof(playerEntity.Inventory) == "table"
				then table.clone(playerEntity.Inventory)
				else {}

			-- Return previously equipped item to inventory
			local prevItemId = fsm.Context._previousItemId
			if typeof(prevItemId) == "string" and prevItemId ~= "" then
				if not table.find(inventory, prevItemId) then
					table.insert(inventory, prevItemId)
				end
			end

			-- Remove newly equipped item from inventory
			local newIdx = table.find(inventory, fsm.ItemId)
			if newIdx then
				table.remove(inventory, newIdx)
			end

			playerEntity.Inventory = inventory
			pcall(function() playerEntity:UpdateEntity() end)

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
				Kind = "Equip",
				Payload = {
					Hand = fsm.Hand,
					ItemId = fsm.ItemId,
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
			local clonedItem = fsm.Context._clonedItem
			if clonedItem and clonedItem.Parent then
				clonedItem:Destroy()
			end

			local previousItem = fsm.Context._previousItem
			if previousItem then
				local action = tostring(fsm.Context._previousItemAction or "unknown action")
				local function logRollbackWarning(message: string)
					if type(fsm.Log) == "function" then
						fsm:Log({ Level = "WARN", Message = message })
					else
						warn(message)
					end
				end

				local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
				if charEntity and playerEntity and character and previousItem.Parent then
					local orchestrator = fsm:GetOrchestrator()
					local equipHelpers = getEquipHelpers(orchestrator)
					local handPart = equipHelpers.GetHandPart(character, fsm.Hand)
					local previousData = fsm.Context._previousItemData or equipHelpers.GetItemData(previousItem)
					local handle = previousItem:FindFirstChild("Handle")
					if not handle or not handle:IsA("BasePart") then
						handle = previousItem.PrimaryPart
						if not handle then
							for _, child in previousItem:GetChildren() do
								if child:IsA("BasePart") then
									handle = child
									break
								end
							end
						end
					end

					if handPart and handle and handle:IsA("BasePart") then
						local ok, err = pcall(function()
							equipHelpers.CreateWeld(handPart, handle, if previousData then previousData.GripC1 or CFrame.new() else CFrame.new())
							equipHelpers.MountItem(previousItem, handPart)
						end)
						if not ok then
							logRollbackWarning(
								string.format(
									"Equip rollback could not restore previous item '%s' after %s: %s",
									tostring(fsm.Context._previousItemId or previousItem.Name),
									action,
									tostring(err)
								)
							)
						end
					else
						logRollbackWarning(
							string.format(
								"Equip rollback could not restore previous item '%s' after %s: missing hand part or handle",
								tostring(fsm.Context._previousItemId or previousItem.Name),
								action
							)
						)
					end
				else
					logRollbackWarning(
						string.format(
							"Equip rollback may have lost previous item '%s' after %s",
							tostring(fsm.Context._previousItemId or previousItem.Name),
							action
						)
					)
				end
			end

			fsm.State = "ReleaseEquipLock"
		end,
	}, { "ReleaseEquipLock" })

	self:AddState("Completed", function(_fsm) end, {})
	self:AddState("Failed", function(_fsm) end, {})
end

return EquipJob
