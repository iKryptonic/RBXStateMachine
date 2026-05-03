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

			local hand = fsm.Hand or "Right"
			if hand ~= "Right" and hand ~= "Left" then
				fsm:Fail("Invalid hand: " .. tostring(hand))
				return
			end

			local inventory = playerEntity.Inventory
			if typeof(inventory) == "table" and not table.find(inventory, itemId) then
				fsm:Fail("Item " .. itemId .. " not in inventory")
				return
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
				fsm:Fail("EquipLock already held for hand: " .. hand)
				return
			end

			equipLock[hand] = true
			charEntity.EquipLock = equipLock
			charEntity:UpdateEntity()
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
							local existingData = equipHelpers.GetItemData(existingItem)
							if existingData and existingData.Stowable then
								equipHelpers.StowItem(existingItem, character, weld, existingData)
							else
								equipHelpers.DropItem(existingItem, weld)
							end
						end
					end
				end
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
			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			equipHelpers.MountItem(fsm.Context._clonedItem, fsm.Context._handPart)
			fsm.State = "CommitState"
		end,
	}, { "CommitState", "Rollback", "Failed" })

	self:AddState("CommitState", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			local playerEntity = orchestrator.GetEntity(fsm.PlayerEntityId)
			if not charEntity then
				StateTransitionHelpers.queueRollback(fsm, "CharacterEntity no longer exists")
				return
			end
			if not playerEntity then
				StateTransitionHelpers.queueRollback(fsm, "PlayerEntity no longer exists")
				return
			end

			local hand = fsm.Hand :: string
			local propertyName = getHandProperty(hand)
			charEntity[propertyName] = fsm.ItemId
			charEntity:UpdateEntity()

			local equipped = if typeof(playerEntity.Equipped) == "table" then table.clone(playerEntity.Equipped) else {}
			equipped[hand] = fsm.ItemId
			playerEntity.Equipped = equipped
			playerEntity:UpdateEntity()

			fsm.State = "EmitIntent"
		end,
	}, { "EmitIntent", "Rollback", "Failed" })

	self:AddState("EmitIntent", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local intentSchema = getIntentSchema(orchestrator)
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				StateTransitionHelpers.queueRollback(fsm, "CharacterEntity no longer exists")
				return
			end

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
			if charEntity then
				local equipLock = if typeof(charEntity.EquipLock) == "table"
					then table.clone(charEntity.EquipLock)
					else {}
				equipLock[fsm.Hand] = nil
				charEntity.EquipLock = equipLock
				charEntity:UpdateEntity()
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
			fsm.State = "ReleaseEquipLock"
		end,
	}, { "ReleaseEquipLock" })

	self:AddState("Completed", function(_fsm) end, {})
	self:AddState("Failed", function(_fsm) end, {})
end

return EquipJob
