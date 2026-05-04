--!strict


local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[=[
	@module StatusEffectFSM
	@description Applies, refreshes, and expires timed status effects while keeping entity flags and replicated state synchronized.
]=]

local StatusEffectFSM = {
	Name = "StatusEffectFSM",
	className = "StatusEffectFSM",
	validStates = {
		"ValidateInput",
		"LoadEntities",
		"LoadEffectDef",
		"InitializeContext",
		"UpdateEffectsRegistry",
		"ApplyStatModifiers",
		"ApplyStatusFlags",
		"SyncResources",
		"BroadcastUpdate",
		"Ticking",
		"RemoveStatModifiers",
		"RemoveStatusFlags",
		"CleanupRegistry",
		"BroadcastCleanup",
		"Expired",
		"Failed",
	},
	terminalStates = {"Expired","Failed" },
	initialState = "ValidateInput",
}

--[=[
	@description Returns the status effect defs used by this state machine when it can be resolved.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function getStatusEffectDefs()
	return require(ReplicatedStorage:WaitForChild("shared"):WaitForChild("StatusEffectDefs"))
end

--[=[
	@description Helper for the clone active effects step used by this state machine.
	@param charEntity any -- Input consumed by `cloneActiveEffects`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function cloneActiveEffects(charEntity: any): { any }
	local current = charEntity and charEntity.ActiveStatusEffects
	if typeof(current) ~= "table" then
		return {}
	end

	local clone = table.clone(current)
	for index, value in ipairs(clone) do
		if typeof(value) == "table" then
			clone[index] = table.clone(value)
		end
	end
	return clone
end

--[=[
	@description Helper for the find effect entry index step used by this state machine.
	@param activeEffects any -- Input consumed by `findEffectEntryIndex`.
	@param instanceId any -- Input consumed by `findEffectEntryIndex`.
	@return number -- Numeric value derived for downstream logic.
]=]

local function findEffectEntryIndex(activeEffects: { any }, instanceId: string): number?
	for index, entry in ipairs(activeEffects) do
		if typeof(entry) == "table" and entry.InstanceId == instanceId then
			return index
		end
	end
	return nil
end

--[=[
	@description Returns the humanoid used by this state machine when it can be resolved.
	@param charEntity any -- Input consumed by `getHumanoid`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function getHumanoid(charEntity: any): Humanoid?
	local character = charEntity and charEntity.Instance
	if not character then
		local Players = game:GetService("Players")
		local localPlayer = Players.LocalPlayer
		character = localPlayer and localPlayer.Character
	end
	if character and character:IsA("Model") then
		return character:FindFirstChildOfClass("Humanoid")
	end
	return nil
end

--[=[
	@description Helper for the clamp resources step used by this state machine.
	@param charEntity any -- Input consumed by `clampResources`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function clampResources(charEntity: any)
	if typeof(charEntity.Health) == "number" and typeof(charEntity.MaxHealth) == "number" then
		charEntity.Health = math.clamp(charEntity.Health, 0, charEntity.MaxHealth)
	end
	if typeof(charEntity.Stamina) == "number" and typeof(charEntity.MaxStamina) == "number" then
		charEntity.Stamina = math.clamp(charEntity.Stamina, 0, charEntity.MaxStamina)
	end
	if typeof(charEntity.Mana) == "number" and typeof(charEntity.MaxMana) == "number" then
		charEntity.Mana = math.clamp(charEntity.Mana, 0, charEntity.MaxMana)
	end
end

--[=[
	@description Synchronizes humanoid with the latest derived runtime state.
	@param charEntity any -- Input consumed by `syncHumanoid`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function syncHumanoid(charEntity: any)
	local humanoid = getHumanoid(charEntity)
	if not humanoid then
		return
	end

	local maxHealth = tonumber(charEntity.MaxHealth)
	if maxHealth and maxHealth > 0 then
		humanoid.MaxHealth = maxHealth
	end
	local currentHealth = tonumber(charEntity.Health)
	if currentHealth then
		charEntity.Health = math.clamp(currentHealth, 0, humanoid.MaxHealth)
		humanoid.Health = charEntity.Health
	end
end

--[=[
	@description Returns the context used by this state machine when it can be resolved.
	@param fsm any -- Input consumed by `getContext`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function getContext(fsm: any): any
	fsm.Context = fsm.Context or {}
	return fsm.Context
end

--[=[
	@description Helper for the reverse stat modifiers step used by this state machine.
	@param fsm any -- Input consumed by `reverseStatModifiers`.
	@return boolean -- Whether the helper completed successfully.
]=]

local function reverseStatModifiers(fsm: any): boolean
	local context = getContext(fsm)
	local charEntity = context._charEntity or fsm.CharacterEntity
	local originals = context._statModifierOriginals
	if not charEntity or typeof(originals) ~= "table" or context._statModifiersRemoved then
		return false
	end

	local changed = false
	for stat, originalValue in pairs(originals) do
		charEntity[stat] = originalValue
		changed = true
	end

	context._statModifiersRemoved = true
	return changed
end

--[=[
	@description Helper for the reverse status flags step used by this state machine.
	@param fsm any -- Input consumed by `reverseStatusFlags`.
	@return boolean -- Whether the helper completed successfully.
]=]

local function reverseStatusFlags(fsm: any): boolean
	local context = getContext(fsm)
	local charEntity = context._charEntity or fsm.CharacterEntity
	local originals = context._flagOriginals
	if not charEntity or typeof(originals) ~= "table" or context._statusFlagsRemoved then
		return false
	end

	local changed = false
	for flagName, originalValue in pairs(originals) do
		charEntity[flagName] = originalValue
		changed = true
	end

	context._statusFlagsRemoved = true
	return changed
end

--[=[
	@description Helper for the cleanup registry step used by this state machine.
	@param fsm any -- Input consumed by `cleanupRegistry`.
	@return boolean -- Whether the helper completed successfully.
]=]

local function cleanupRegistry(fsm: any): boolean
	local context = getContext(fsm)
	local charEntity = context._charEntity or fsm.CharacterEntity
	if not charEntity or context._registryCleaned then
		return false
	end

	local activeEffects = cloneActiveEffects(charEntity)
	local index = findEffectEntryIndex(activeEffects, fsm.Id)
	if index then
		table.remove(activeEffects, index)
	end
	charEntity.ActiveStatusEffects = activeEffects
	context._registryCleaned = true
	return index ~= nil
end

--[=[
	@description Helper for the broadcast entity step used by this state machine.
	@param charEntity any -- Input consumed by `broadcastEntity`.
	@return boolean -- Whether the helper completed successfully.
]=]

local function broadcastEntity(charEntity: any): boolean
	if not charEntity then
		return false
	end

	pcall(function()
		charEntity:UpdateEntity()
	end)
	return true
end

--[=[
	@description Applies the tick work needed by the surrounding state flow.
	@param fsm any -- Input consumed by `applyTick`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function applyTick(fsm: any)
	local context = getContext(fsm)
	local charEntity = context._charEntity or fsm.CharacterEntity
	local def = context._effectDef or fsm.Definition
	if not charEntity or not def then
		return
	end

	local humanoid = getHumanoid(charEntity)
	local changed = false
	local tickDamage = tonumber(def.TickDamage) or 0
	local tickHeal = tonumber(def.TickHeal) or 0

	if tickDamage > 0 then
		if humanoid then
			humanoid:TakeDamage(tickDamage)
			charEntity.Health = humanoid.Health
		elseif typeof(charEntity.Health) == "number" then
			charEntity.Health = math.max(0, charEntity.Health - tickDamage)
		end
		changed = true
	end

	if tickHeal > 0 and typeof(charEntity.Health) == "number" then
		local maxHealth = tonumber(charEntity.MaxHealth) or charEntity.Health
		charEntity.Health = math.clamp(charEntity.Health + tickHeal, 0, maxHealth)
		if humanoid then
			syncHumanoid(charEntity)
		end
		changed = true
	end

	if changed then
		broadcastEntity(charEntity)
	end
end


--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `StatusEffectFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function StatusEffectFSM:RegisterStates()


	--[=[
		@state ValidateInput
		@description Validates the required runtime context and prerequisites.
			Transitions:
			- `LoadEntities` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
	]=]

	self:AddState("ValidateInput", {
		OnEnter = function(_, fsm)
			if typeof(fsm.CharacterEntityId) ~= "string" or fsm.CharacterEntityId == "" then
				fsm:Fail("Missing CharacterEntityId")
				return
			end
			fsm.State = "LoadEntities"
		end,
	}, {"LoadEntities","Failed" })


	--[=[
		@state LoadEntities
		@description Runs the `load entities` stage of `StatusEffectFSM`.
			Transitions:
			- `LoadEffectDef` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
	]=]

	self:AddState("LoadEntities", {
		OnEnter = function(_, fsm)
			local charEntity = fsm:GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end

			local context = getContext(fsm)
			context._charEntity = charEntity
			fsm.CharacterEntity = charEntity
			fsm.State = "LoadEffectDef"
		end,
	}, {"LoadEffectDef","Failed" })


	--[=[
		@state LoadEffectDef
		@description Runs the `load effect def` stage of `StatusEffectFSM`.
			Transitions:
			- `InitializeContext` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
	]=]

	self:AddState("LoadEffectDef", {
		OnEnter = function(_, fsm)
			local effectId = tostring(fsm.EffectId or "")
			local def = getStatusEffectDefs().Get(effectId)
			if not def then
				fsm:Fail("Status effect not found")
				return
			end

			local context = getContext(fsm)
			context._effectDef = def
			fsm.Definition = def
			fsm.State = "InitializeContext"
		end,
	}, {"InitializeContext","Failed" })


	--[=[
		@state InitializeContext
		@description Runs the `initialize context` stage of `StatusEffectFSM`.
			Transitions:
			- `UpdateEffectsRegistry` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("InitializeContext", {
		OnEnter = function(_, fsm)
			local context = getContext(fsm)
			local def = context._effectDef
			context._tickAccumulator = 0
			context._startedAt = os.clock()
			context._duration = math.max(tonumber(def and def.Duration) or 0, 0)
			context._stacks = 1
			context._statModifierOriginals = {}
			context._flagOriginals = {}
			context._statModifiersRemoved = false
			context._statusFlagsRemoved = false
			context._registryCleaned = false
			fsm.State = "UpdateEffectsRegistry"
		end,
	}, {"UpdateEffectsRegistry" })


	--[=[
		@state UpdateEffectsRegistry
		@description On enter, sets `ActiveStatusEffects`.
			Transitions:
			- `ApplyStatModifiers` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: sets `ActiveStatusEffects`.
	]=]

	self:AddState("UpdateEffectsRegistry", {
		OnEnter = function(_, fsm)
			local context = getContext(fsm)
			local charEntity = context._charEntity
			local def = context._effectDef
			if not charEntity or not def then
				fsm:Fail("Status effect context missing")
				return
			end

			local activeEffects = cloneActiveEffects(charEntity)
			local entry = {
				InstanceId = fsm.Id,
				EffectId = def.Id,
				StartedAt = context._startedAt,
				Duration = context._duration,
				Stacks = context._stacks,
			}
			local index = findEffectEntryIndex(activeEffects, fsm.Id)
			if index then
				activeEffects[index] = entry
			else
				table.insert(activeEffects, entry)
			end
			charEntity.ActiveStatusEffects = activeEffects
			fsm.State = "ApplyStatModifiers"
		end,
	}, {"ApplyStatModifiers","Failed" })


	--[=[
		@state ApplyStatModifiers
		@description Runs the `apply stat modifiers` stage of `StatusEffectFSM`.
			Transitions:
			- `ApplyStatusFlags` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
	]=]

	self:AddState("ApplyStatModifiers", {
		OnEnter = function(_, fsm)
			local context = getContext(fsm)
			local charEntity = context._charEntity
			local def = context._effectDef
			if not charEntity or not def then
				fsm:Fail("Status effect context missing")
				return
			end

			local originals = context._statModifierOriginals
			if typeof(def.StatModifiers) == "table" then
				for stat, modifier in pairs(def.StatModifiers) do
					if typeof(modifier) == "number" and typeof(charEntity[stat]) == "number" then
						originals[stat] = charEntity[stat]
						charEntity[stat] = (tonumber(charEntity[stat]) or 0) + modifier
					end
				end
			end
			fsm.State = "ApplyStatusFlags"
		end,
	}, {"ApplyStatusFlags","Failed" })


	--[=[
		@state ApplyStatusFlags
		@description Runs the `apply status flags` stage of `StatusEffectFSM`.
			Transitions:
			- `SyncResources` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
	]=]

	self:AddState("ApplyStatusFlags", {
		OnEnter = function(_, fsm)
			local context = getContext(fsm)
			local charEntity = context._charEntity
			local def = context._effectDef
			if not charEntity or not def then
				fsm:Fail("Status effect context missing")
				return
			end

			local originals = context._flagOriginals
			if typeof(def.ApplyFlags) == "table" then
				for flagName, flagValue in pairs(def.ApplyFlags) do
					if originals[flagName] == nil then
						originals[flagName] = charEntity[flagName]
					end
					charEntity[flagName] = flagValue
				end
			end


			fsm.State = "SyncResources"
		end,
	}, {"SyncResources","Failed" })


	--[=[
		@state SyncResources
		@description Runs the `sync resources` stage of `StatusEffectFSM`.
			Transitions:
			- `BroadcastUpdate` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
	]=]

	self:AddState("SyncResources", {
		OnEnter = function(_, fsm)
			local context = getContext(fsm)
			local charEntity = context._charEntity
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end

			clampResources(charEntity)
			syncHumanoid(charEntity)
			fsm.State = "BroadcastUpdate"
		end,
	}, {"BroadcastUpdate","Failed" })


	--[=[
		@state BroadcastUpdate
		@description Runs the `broadcast update` stage of `StatusEffectFSM`.
			Transitions:
			- `Ticking` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
	]=]

	self:AddState("BroadcastUpdate", {
		OnEnter = function(_, fsm)
			local charEntity = getContext(fsm)._charEntity
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end

			broadcastEntity(charEntity)
			fsm.State = "Ticking"
		end,
	}, {"Ticking","Failed" })


	--[=[
		@state Ticking
		@description Runs the `ticking` stage of `StatusEffectFSM`.
			Transitions:
			- `RemoveStatModifiers` when the scheduled transition completes.
			Writes: none.
	]=]

	self:AddState("Ticking", {
		OnEnter = function(_, fsm)
			local duration = tonumber(getContext(fsm)._duration) or 0
			fsm:ScheduleTransition(duration,"RemoveStatModifiers")
		end,
		OnHeartbeat = function(_, fsm, dt)
			local context = getContext(fsm)
			local def = context._effectDef
			if not def then
				return
			end

			local interval = tonumber(def.TickInterval) or 0
			if interval <= 0 then
				return
			end

			context._tickAccumulator = (tonumber(context._tickAccumulator) or 0) + dt
			while context._tickAccumulator >= interval do
				context._tickAccumulator -= interval
				applyTick(fsm)
			end
		end,
	}, {"RemoveStatModifiers","Failed" })


	--[=[
		@state RemoveStatModifiers
		@description Runs the `remove stat modifiers` stage of `StatusEffectFSM`.
			Transitions:
			- `RemoveStatusFlags` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("RemoveStatModifiers", {
		OnEnter = function(_, fsm)
			reverseStatModifiers(fsm)
			fsm.State = "RemoveStatusFlags"
		end,
	}, {"RemoveStatusFlags" })


	--[=[
		@state RemoveStatusFlags
		@description Runs the `remove status flags` stage of `StatusEffectFSM`.
			Transitions:
			- `CleanupRegistry` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("RemoveStatusFlags", {
		OnEnter = function(_, fsm)
			reverseStatusFlags(fsm)
			fsm.State = "CleanupRegistry"
		end,
	}, {"CleanupRegistry" })


	--[=[
		@state CleanupRegistry
		@description Runs the `cleanup registry` stage of `StatusEffectFSM`.
			Transitions:
			- `BroadcastCleanup` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("CleanupRegistry", {
		OnEnter = function(_, fsm)
			cleanupRegistry(fsm)
			fsm.State = "BroadcastCleanup"
		end,
	}, {"BroadcastCleanup" })


	--[=[
		@state BroadcastCleanup
		@description Runs the `broadcast cleanup` stage of `StatusEffectFSM`.
			Transitions:
			- `Expired` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("BroadcastCleanup", {
		OnEnter = function(_, fsm)
			local context = getContext(fsm)
			local charEntity = context._charEntity
			if charEntity then
				clampResources(charEntity)
				syncHumanoid(charEntity)
				broadcastEntity(charEntity)
			end
			fsm.State = "Expired"
		end,
	}, {"Expired" })


	--[=[
		@state Expired
		@description Runs the `expired` stage of `StatusEffectFSM`.
			Transitions:
			Writes: none.
	]=]

	self:AddState("Expired", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink for bad effect input or runtime errors while applying, ticking, or removing a status effect. `OnEnter` is a no-op; `OnCleanup` reverses stat/status changes, prunes registry state, reclamps resources, and rebroadcasts the entity when anything changed.
		Transitions: none.
		Writes: none in-state; rollback writes may still run.
	]=]

	self:AddState("Failed", function() end, {})
end


--[=[
	@description Restores any mutable runtime state that still needs cleanup if the FSM stops before its normal completion path.
	@return nil -- Performs state changes or cleanup as side effects.
]=]

function StatusEffectFSM:OnCleanup()
	local context = getContext(self)
	local charEntity = context._charEntity or self.CharacterEntity
	local changed = false

	changed = reverseStatModifiers(self) or changed
	changed = reverseStatusFlags(self) or changed
	changed = cleanupRegistry(self) or changed

	if charEntity and changed then
		clampResources(charEntity)
		syncHumanoid(charEntity)
		broadcastEntity(charEntity)
	end
end

return StatusEffectFSM
