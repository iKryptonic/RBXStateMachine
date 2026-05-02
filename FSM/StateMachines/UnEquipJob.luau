--!strict
-- @Name UnEquipJob
-- @Author iKrypto
-- @Description Handles unequipping an item from a hand: validates, resolves current item, stows or drops it, updates entity state, emits intent

local UnEquipJob = {
	Name = "UnEquipJob",
	className = "UnEquipJob",
	validStates = { "ValidateRequest", "AcquireEquipLock", "ResolveExistingItem", "DoUnEquip", "CommitState", "EmitIntent", "ReleaseEquipLock", "Rollback", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "ValidateRequest",
}

local cachedEquipHelpers = nil :: any
local cachedIntentSchema = nil :: any

local function requireSharedModule(orchestrator: any, moduleName: string)
	local getModule = orchestrator and orchestrator.GetModule
	if type(getModule) == "function" then
		local module = getModule(moduleName)
		if module ~= nil then
			return module
		end
	end

	local replicatedStorage = game:GetService("ReplicatedStorage")

	local sharedFolder = replicatedStorage:FindFirstChild("shared")
	if sharedFolder then
		local mod = sharedFolder:FindFirstChild(moduleName)
		if mod and mod:IsA("ModuleScript") then
			return require(mod)
		end
	end

	local fallback = replicatedStorage:FindFirstChild(moduleName, true)
	if fallback and fallback:IsA("ModuleScript") then
		return require(fallback)
	end

	error("Shared module not found: " .. moduleName)
end

local function getEquipHelpers(orchestrator: any)
	if not cachedEquipHelpers then
		cachedEquipHelpers = requireSharedModule(orchestrator, "EquipHelpers")
	end
	return cachedEquipHelpers
end

local function getIntentSchema(orchestrator: any)
	if not cachedIntentSchema then
		cachedIntentSchema = requireSharedModule(orchestrator, "IntentSchema")
	end
	return cachedIntentSchema
end

local function queueRollback(fsm, reason: string)
	fsm.Context._failureReason = reason
	fsm:Log({ Level = "ERROR", Message = reason })
	fsm.State = "Rollback"
end

local function getHandProperty(hand: string): string
	return if hand == "Right" then "EquippedRight" else "EquippedLeft"
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
				fsm:Fail("EquipLock already held for hand: " .. hand)
				return
			end

			equipLock[hand] = true
			charEntity.EquipLock = equipLock
			charEntity:UpdateEntity()
			fsm.State = "ResolveExistingItem"
		end,
	}, { "ResolveExistingItem", "Rollback", "Failed" })

	self:AddState("ResolveExistingItem", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				queueRollback(fsm, "CharacterEntity no longer exists")
				return
			end

			local character = charEntity.Instance
			if not character or not character:IsA("Model") then
				queueRollback(fsm, "Character model is unavailable")
				return
			end

			local hand = fsm.Hand :: string
			local handPart = equipHelpers.GetHandPart(character, hand)
			if not handPart then
				queueRollback(fsm, "Hand part not found for hand: " .. hand)
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
			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				queueRollback(fsm, "CharacterEntity no longer exists")
				return
			end

			local character = charEntity.Instance
			if not character or not character:IsA("Model") then
				queueRollback(fsm, "Character model is unavailable")
				return
			end

			local weld = fsm.Context._resolvedWeld
			local item = fsm.Context._resolvedItem
			local itemData = fsm.Context._resolvedItemData
			if weld and item then
				if itemData and itemData.Stowable then
					equipHelpers.StowItem(item, character, weld, itemData)
				else
					equipHelpers.DropItem(item, weld)
				end
			end

			fsm.State = "CommitState"
		end,
	}, { "CommitState", "Rollback", "Failed" })

	self:AddState("CommitState", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				queueRollback(fsm, "CharacterEntity no longer exists")
				return
			end

			local hand = fsm.Hand :: string
			charEntity[getHandProperty(hand)] = ""
			charEntity:UpdateEntity()

			local playerEntityId = charEntity.PlayerEntityId
			if type(playerEntityId) == "string" and playerEntityId ~= "" then
				local playerEntity = orchestrator.GetEntity(playerEntityId)
				if playerEntity then
					local equipped = if typeof(playerEntity.Equipped) == "table" then table.clone(playerEntity.Equipped) else {}
					equipped[hand] = nil
					playerEntity.Equipped = equipped
					playerEntity:UpdateEntity()
				end
			end

			fsm.State = "EmitIntent"
		end,
	}, { "EmitIntent", "Rollback", "Failed" })

	self:AddState("EmitIntent", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local intentSchema = getIntentSchema(orchestrator)
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				queueRollback(fsm, "CharacterEntity no longer exists")
				return
			end

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
			if charEntity then
				local equipLock = if typeof(charEntity.EquipLock) == "table" then table.clone(charEntity.EquipLock) else {}
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
			fsm.State = "ReleaseEquipLock"
		end,
	}, { "ReleaseEquipLock" })

	self:AddState("Completed", function(_fsm) end, {})
	self:AddState("Failed", function(_fsm) end, {})
end

return UnEquipJob
