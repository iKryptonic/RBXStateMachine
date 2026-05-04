--!strict
--[=[
	@Name UnEquipJob
	@Author iKrypto
	@Description Unequips the current item from a requested hand by validating the request, serializing access with the per-hand equip lock, resolving the currently mounted asset, either dropping or stowing that asset, committing replicated entity and inventory state, emitting the unequip intent, and releasing the lock. Failures route through `Rollback`, which currently performs no physical restoration beyond ensuring the lock is released before the terminal `Failed` state. Historical integrations must target `Completed`; the deprecated `Complete` spelling is intentionally not used.

	State flow diagram:
	ValidateRequest → AcquireEquipLock → ResolveExistingItem → DoUnEquip → CommitState → EmitIntent → ReleaseEquipLock → Completed
					↘ Rollback → ReleaseEquipLock → Failed

	Context fields:
	- Hand: string -- normalized hand name (`Right` or `Left`).
	- _equipLockRetryCount: number -- retry counter while waiting for the per-hand equip lock.
	- _equipLockHeld: boolean -- whether this job currently owns the per-hand equip lock.
	- _resolvedHandPart: BasePart? -- hand part resolved from the live character.
	- _resolvedWeld: WeldConstraint? -- weld binding the currently mounted item to the hand.
	- _resolvedItem: Instance? -- currently mounted item model, if one exists.
	- _resolvedItemData: any? -- resolved metadata for the mounted item.
	- _resolvedItemId: string -- best-effort item id inferred from entity state or the mounted model name.
	- _wasStowed: boolean -- set only when `DoUnEquip` stows a stowable item instead of dropping it. `CommitState` uses this flag to keep equipped fields and `WeaponEqp` intact so the item remains logically equipped while visually moved to a stowed position.
	- _failureReason: string? -- reason recorded by rollback helpers and logged during lock release.

	Required params:
	- CharacterEntityId: string -- character entity whose hand will be processed.
	- PlayerEntityId: string? -- optional player entity id; falls back to the character link when omitted.
	- Hand: string? -- optional hand override; defaults to `Right`.
	- ForceRemove: boolean? -- when true, always drops/destroys the physical item instead of stowing it.

	Notes:
	- Unlike `EquipJob`, this FSM does not use tracked clone bookkeeping; it works against the already-mounted item resolved from the live character.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers,"Helpers folder not found")
local ModuleLoader = require(Helpers:WaitForChild("ModuleLoader"))
local StateTransitionHelpers = require(Helpers:WaitForChild("StateTransitionHelpers"))

--[=[
	@module UnEquipJob
	@description Unequips an item from a character hand, clears attachments, and updates the backing inventory and character state.
]=]

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
	terminalStates = {"Completed","Failed" },
	initialState = "ValidateRequest",
}

local cachedEquipHelpers = nil :: any
local cachedIntentSchema = nil :: any

--[=[
	@description Lazily resolves and caches the shared `EquipHelpers` module for repeated use across states.
	@param orchestrator any -- Orchestrator passed into `ModuleLoader.requireSharedModule`.
	@return any -- Cached `EquipHelpers` module table.
]=]
local function getEquipHelpers(orchestrator: any)
	if not cachedEquipHelpers then
		cachedEquipHelpers = ModuleLoader.requireSharedModule(orchestrator,"EquipHelpers")
	end
	return cachedEquipHelpers
end

--[=[
	@description Lazily resolves and caches the shared `IntentSchema` module used to append unequip intents.
	@param orchestrator any -- Orchestrator passed into `ModuleLoader.requireSharedModule`.
	@return any -- Cached `IntentSchema` module table.
]=]
local function getIntentSchema(orchestrator: any)
	if not cachedIntentSchema then
		cachedIntentSchema = ModuleLoader.requireSharedModule(orchestrator,"IntentSchema")
	end
	return cachedIntentSchema
end

--[=[
	@description Maps a hand name to the matching character entity equipped-property field.
	@param hand string -- `Right` or `Left`.
	@return string -- `EquippedRight` for the right hand, otherwise `EquippedLeft`.
]=]
local function getHandProperty(hand: string): string
	return if hand == "Right" then"EquippedRight" else"EquippedLeft"
end

--[=[
	@description Re-resolves the character entity, player entity, and live character model, falling back to the Roblox `Players` service if the cached character instance was replaced server-side.
	@param fsm any -- Active unequip FSM instance.
	@return any? -- Current character entity.
	@return any? -- Current player entity.
	@return any? -- Live character model.
]=]
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


--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `UnEquipJob`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function UnEquipJob:RegisterStates()


--[=[
	@state ValidateRequest
	@description Validates the required runtime context and prerequisites.
		Transitions:
		- `AcquireEquipLock` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: stores `Context.Hand`, sets `Hand`.
]=]

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
	}, {"AcquireEquipLock","Failed" })


--[=[
	@state AcquireEquipLock
	@description On enter, stores `Context._equipLockRetryCount`, stores `Context._equipLockHeld`, sets `_equipLockRetryCount`.
		Transitions:
		- `AcquireEquipLock` when this stage finishes its immediate work or falls through its guard checks.
		- `ResolveExistingItem` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: stores `Context._equipLockRetryCount`, stores `Context._equipLockHeld`, sets `_equipLockRetryCount`, sets `_equipLockHeld`, sets `EquipLock`.
]=]

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
	}, {"ResolveExistingItem","Rollback","Failed" })


--[=[
	@state ResolveExistingItem
	@description Resolves the data needed for the `ResolveExistingItem` step.
		Transitions:
		- `DoUnEquip` when this stage finishes its immediate work or falls through its guard checks.
		Writes: stores `Context._resolvedHandPart`, stores `Context._resolvedWeld`, stores `Context._resolvedItem`, stores `Context._resolvedItemData`, stores `Context._resolvedItemId`.
]=]

self:AddState("ResolveExistingItem", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm,"Entities no longer alive during ResolveExistingItem")
				return
			end

			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local hand = fsm.Hand :: string
			local handPart = equipHelpers.GetHandPart(character, hand)
			if not handPart then
				StateTransitionHelpers.queueRollback(fsm,"Hand part not found for hand: " .. hand)
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
	}, {"DoUnEquip","Rollback","Failed" })


--[=[
	@state DoUnEquip
	@description On enter, stores `Context._wasStowed`, sets `_wasStowed`, writes to the log.
		Transitions:
		- `CommitState` when this stage finishes its immediate work or falls through its guard checks.
		Writes: stores `Context._wasStowed`, sets `_wasStowed`, writes to the log.
]=]

self:AddState("DoUnEquip", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm,"Entities no longer alive during DoUnEquip")
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
	}, {"CommitState","Rollback","Failed" })


--[=[
	@state CommitState
	@description On enter, sets `Equipped`, sets `WeaponEqp`, sets `Inventory`.
		Transitions:
		- `EmitIntent` when this stage finishes its immediate work or falls through its guard checks.
		Writes: sets `Equipped`, sets `WeaponEqp`, sets `Inventory`, replicates entity changes.
]=]

self:AddState("CommitState", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm,"Entities no longer alive during CommitState")
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
	}, {"EmitIntent","Rollback","Failed" })


--[=[
	@state EmitIntent
	@description On enter, emits an intent.
		Transitions:
		- `ReleaseEquipLock` when this stage finishes its immediate work or falls through its guard checks.
		Writes: emits an intent.
]=]

self:AddState("EmitIntent", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm,"Entities no longer alive during EmitIntent")
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
	}, {"ReleaseEquipLock","Rollback","Failed" })


--[=[
	@state ReleaseEquipLock
	@description On enter, stores `Context._equipLockHeld`, sets `EquipLock`, sets `_equipLockHeld`.
		Transitions:
		- `Failed` when this stage finishes its immediate work or falls through its guard checks.
		- `Completed` when this stage finishes its immediate work or falls through its guard checks.
		Writes: stores `Context._equipLockHeld`, sets `EquipLock`, sets `_equipLockHeld`, replicates entity changes, writes to the log.
]=]

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
	}, {"Completed","Failed" })


--[=[
	@state Rollback
	@description Runs the `rollback` stage of `UnEquipJob`.
		Transitions:
		- `ReleaseEquipLock` when this stage finishes its immediate work or falls through its guard checks.
		Writes: none.
]=]

self:AddState("Rollback", {
		OnEnter = function(_, fsm)
			fsm.State = "ReleaseEquipLock"
		end,
	}, {"ReleaseEquipLock" })
--[=[
	@state Completed
	@description Terminal success sink reached after `ReleaseEquipLock` persists the unequipped state and frees the per-hand equip lock. `OnEnter` is a no-op because the entity and inventory writes already happened.
		Transitions: none.
		Writes: none.
]=]

self:AddState("Completed", function(_fsm) end, {})
--[=[
	@state Failed
	@description Terminal failure sink reached when `ReleaseEquipLock` sees `Context._failureReason` after rollback. `OnEnter` is a no-op because rollback and lock release occur before entry.
		Transitions: none.
		Writes: none.
]=]

self:AddState("Failed", function(_fsm) end, {})
end

return UnEquipJob
