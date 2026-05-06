--!strict
--[=[
	@Name WaveSpawnerExample
	@Author GitHub Copilot
	@Description Example module bundling a schema-backed WaveSpawner entity with a
	scheduler-aware WaveSpawner FSM. Demonstrates scheduler integration, dynamic
	priority levels, WaitSpan polling, ScheduleTransition, Timeout + OnTimeout,
	and frame-budget-aware spawning driven by OnHeartbeat(dt).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseStateMachine = require(ReplicatedStorage:WaitForChild("Orchestrator").Core.Factory.BaseStateMachine)

export type WaveDefinition = {
	Count: number,
	NpcType: string,
}

local WaveSpawnerEntity = {
	Definition = {
		Name = "WaveSpawner",
		Mutable = true,
		Replication = {
			Enabled = true,
			RateLimit = 15,
		},
		Schema = {
			CurrentWave = { Type = "number", Replicate = true, Default = 0 },
			TotalWaves = { Type = "number", Replicate = true, Default = 0 },
			SpawnedThisWave = { Type = "number", Replicate = true, Default = 0 },
			TotalSpawned = { Type = "number", Replicate = true, Default = 0 },
			IsActive = { Type = "boolean", Replicate = true, Default = false },
		},
	},
}

--[[
	@description Initializes cached context for the example spawner entity.
	@param params {[any]: any}
	@return {[string]: any}
	@reads params.Context
	@writes None
]]
function WaveSpawnerEntity:GetContext(params: {[any]: any})
	local context = params.Context or {}

	return {
		Instance = context.Instance,
	}
end

--[[
	@description Mirrors committed schema changes onto the backing Instance as
	Attributes so the example exposes visible state without custom UI.
	@param changes {[string]: any}
	@return ()
	@reads self.Instance
	@writes backing Instance attributes
]]
function WaveSpawnerEntity:ApplyChanges(changes: {[string]: any})
	local host = self.Instance
	if typeof(host) ~= "Instance" then
		return
	end

	for key, value in pairs(changes) do
		if key ~= "_v" then
			host:SetAttribute(key, value)
		end
	end
end

local WaveSpawnerFSM = {
	Definition = {
		Name = "WaveSpawnerFSM",
		ValidStates = { "Preparing", "Spawning", "WaveCooldown", "AllWavesComplete", "Completed" },
		TerminalStates = { "Completed" },
		InitialState = "Preparing",
		Priority = BaseStateMachine.Priorities.Background,
	},
}

--[[
	@description Resolves the orchestrator reference from a state machine.
	@param fsm any
	@return any?
	@reads fsm.Context, fsm.GetOrchestrator
	@writes None
]]
local function getOrchestrator(fsm: any)
	if type(fsm.GetOrchestrator) == "function" then
		local orchestrator = fsm:GetOrchestrator()
		if orchestrator then
			return orchestrator
		end
	end

	if fsm.Context then
		return fsm.Context.Orchestrator or fsm.Context._Orchestrator
	end

	return nil
end

--[[
	@description Resolves the shared scheduler so the example can schedule
	background cleanup work outside the FSM heartbeat.
	@param fsm any
	@return any?
	@reads Orchestrator.Scheduler
	@writes None
]]
local function getScheduler(fsm: any)
	local orchestrator = getOrchestrator(fsm)
	if orchestrator then
		return orchestrator.Scheduler
	end

	return nil
end

--[[
	@description Resolves and caches the WaveSpawner entity referenced by Context.
	@param fsm any
	@return any?
	@reads fsm.Context.SpawnerEntity, fsm.Context.SpawnerEntityId
	@writes fsm.Context.SpawnerEntity
]]
local function getSpawnerEntity(fsm: any)
	if fsm.Context.SpawnerEntity then
		return fsm.Context.SpawnerEntity
	end

	local orchestrator = getOrchestrator(fsm)
	if orchestrator and fsm.Context.SpawnerEntityId then
		local entity = orchestrator.GetEntity(fsm.Context.SpawnerEntityId)
		if entity then
			fsm.Context.SpawnerEntity = entity
			return entity
		end
	end

	return nil
end

--[[
	@description Returns the configured wave definitions for this spawner.
	@param fsm any
	@return {WaveDefinition}
	@reads fsm.Context.WaveDefinitions
	@writes None
]]
local function getWaveDefinitions(fsm: any): {WaveDefinition}
	local definitions = fsm.Context.WaveDefinitions
	if type(definitions) == "table" then
		return definitions :: {WaveDefinition}
	end

	return {}
end

--[[
	@description Returns the active wave definition or nil when the index is out
	of range.
	@param fsm any
	@return WaveDefinition?
	@reads fsm.Context.CurrentWave, fsm.Context.WaveDefinitions
	@writes None
]]
local function getCurrentWave(fsm: any): WaveDefinition?
	local definitions = getWaveDefinitions(fsm)
	local currentWave = fsm.Context.CurrentWave or 1

	return definitions[currentWave]
end

--[[
	@description Resolves the Instance used as the origin for spawn-position
	precomputation and fallback spawn placement.
	@param fsm any
	@return Instance?
	@reads fsm.Context.Instance, fsm.Context.SpawnerEntity
	@writes None
]]
local function getSpawnAnchor(fsm: any): Instance?
	local spawnerEntity = getSpawnerEntity(fsm)
	if spawnerEntity then
		return spawnerEntity.Instance
	end

	local contextInstance = fsm.Context.Instance
	if typeof(contextInstance) == "Instance" then
		return contextInstance
	end

	return nil
end

--[[
	@description Resolves a world position from a BasePart, Model, Attachment, or
	other Instance-like context object.
	@param source Instance?
	@return Vector3
	@reads source transform state
	@writes None
]]
local function resolveWorldPosition(source: Instance?): Vector3
	if source == nil then
		return Vector3.zero
	end

	if source:IsA("Attachment") then
		return source.WorldPosition
	end

	if source:IsA("BasePart") then
		return source.Position
	end

	if source:IsA("Model") then
		return source:GetPivot().Position
	end

	return Vector3.zero
end

--[[
	@description Builds a deterministic ring of spawn positions around the bound
	zone Instance. Preparing runs at Background priority so this precomputation can
	stay inexpensive and infrequent.
	@param source Instance?
	@param count number
	@return {Vector3}
	@reads source world position
	@writes None
]]
local function buildSpawnPositions(source: Instance?, count: number): {Vector3}
	local origin = resolveWorldPosition(source)
	local positions = table.create(math.max(count, 0))
	local radius = math.max(8, count * 2)

	if count <= 0 then
		return positions
	end

	for index = 1, count do
		local alpha = ((index - 1) / count) * (math.pi * 2)
		positions[index] = origin + Vector3.new(math.cos(alpha) * radius, 2, math.sin(alpha) * radius)
	end

	return positions
end

--[[
	@description Creates a concrete marker Part for the spawned NPC so the example
	does real work instead of stubbing the spawn.
	@param fsm any
	@param wave WaveDefinition
	@param position Vector3
	@param spawnIndex number
	@return BasePart
	@reads fsm.Context.CurrentWave, fsm.Context.SpawnFolder
	@writes workspace descendants, fsm.Context.SpawnFolder, fsm.Context.SpawnedNpcMarkers
]]
local function createNpcMarker(fsm: any, wave: WaveDefinition, position: Vector3, spawnIndex: number): BasePart
	local spawnFolder = fsm.Context.SpawnFolder
	if typeof(spawnFolder) ~= "Instance" or not spawnFolder:IsA("Folder") or spawnFolder.Parent == nil then
		spawnFolder = Instance.new("Folder")
		spawnFolder.Name = string.format("%s_NPCs", fsm.Id)
		spawnFolder.Parent = workspace
		fsm.Context.SpawnFolder = fsm:Manage(spawnFolder)
	end

	local npcMarker = Instance.new("Part")
	npcMarker.Name = string.format("%s_Wave%d_%d", wave.NpcType, fsm.Context.CurrentWave or 0, spawnIndex)
	npcMarker.Anchored = true
	npcMarker.CanCollide = false
	npcMarker.Size = Vector3.new(2, 3, 2)
	npcMarker.Material = Enum.Material.Neon
	npcMarker.Position = position
	npcMarker.Color = if wave.NpcType == "Boss"
		then Color3.fromRGB(255, 85, 85)
		elseif wave.NpcType == "Scout"
		then Color3.fromRGB(85, 170, 255)
		else Color3.fromRGB(85, 255, 127)
	npcMarker.Parent = spawnFolder

	local spawnedMarkers = fsm.Context.SpawnedNpcMarkers
	if type(spawnedMarkers) ~= "table" then
		spawnedMarkers = {}
		fsm.Context.SpawnedNpcMarkers = spawnedMarkers
	end

	table.insert(spawnedMarkers, npcMarker)
	fsm:Manage(npcMarker)

	return npcMarker
end

--[[
	@description Pushes the FSM's current counters into the replicated entity.
	The helper only commits when a value actually changed to avoid noisy versions.
	@param fsm any
	@param isActive boolean
	@return ()
	@reads FSM context counters, entity snapshot
	@writes entity schema state via UpdateEntity()
]]
local function syncSpawnerEntity(fsm: any, isActive: boolean)
	local entity = getSpawnerEntity(fsm)
	if not entity then
		return
	end

	local dirty = false
	local totalWaves = #getWaveDefinitions(fsm)
	local desiredValues = {
		CurrentWave = fsm.Context.CurrentWave or 0,
		TotalWaves = totalWaves,
		SpawnedThisWave = fsm.Context.SpawnedThisWave or 0,
		TotalSpawned = fsm.Context.TotalSpawned or 0,
		IsActive = isActive,
	}

	for key, value in pairs(desiredValues) do
		if entity[key] ~= value then
			entity[key] = value
			dirty = true
		end
	end

	if dirty then
		entity:UpdateEntity()
	end
end

--[[
	@description Deschedules the recurring cleanup task used during
	AllWavesComplete.
	@param fsm any
	@return ()
	@reads fsm.Context.CompletionCleanupTaskName
	@writes scheduler task registry, fsm.Context.CompletionCleanupTaskName
]]
local function stopCompletionCleanupTask(fsm: any)
	local scheduler = getScheduler(fsm)
	local taskName = fsm.Context.CompletionCleanupTaskName
	if scheduler and type(taskName) == "string" and taskName ~= "" then
		scheduler:Deschedule(taskName)
	end
	fsm.Context.CompletionCleanupTaskName = nil
end

--[[
	@description Starts a background scheduler task that gradually retires spawned
	NPC markers while the FSM lingers in AllWavesComplete. This demonstrates direct
	scheduler access alongside the FSM's own Background priority.
	@param fsm any
	@return ()
	@reads Orchestrator.Scheduler, fsm.Context.SpawnedNpcMarkers
	@writes scheduler task registry, marker Instances
]]
local function ensureCompletionCleanupTask(fsm: any)
	local scheduler = getScheduler(fsm)
	if not scheduler then
		return
	end

	local taskName = fsm.Context.CompletionCleanupTaskName
	if type(taskName) == "string" and taskName ~= "" and scheduler:GetTask(taskName) then
		return
	end

	taskName = string.format("%s-completion-cleanup", fsm.Id)
	fsm.Context.CompletionCleanupTaskName = taskName

	-- Scheduler note: this repository currently uses TaskName/TaskAction keys.
	scheduler:Schedule({
		TaskName = taskName,
		TaskAction = function()
			if not fsm.IsActive or fsm.State ~= "AllWavesComplete" then
				scheduler:Deschedule(taskName)
				return
			end

			local markers = fsm.Context.SpawnedNpcMarkers
			if type(markers) ~= "table" then
				return
			end

			for index = #markers, 1, -1 do
				local marker = markers[index]
				if typeof(marker) ~= "Instance" or marker.Parent == nil then
					table.remove(markers, index)
				elseif marker:IsA("BasePart") then
					marker:Destroy()
					table.remove(markers, index)
					break
				end
			end
		end,
		TaskExecutionDelay = 1,
		IsRecurringTask = true,
		Priority = BaseStateMachine.Priorities.Background,
		Event = "Heartbeat",
	})
end

--[[
	@description Registers the WaveSpawner FSM states.
	@return ()
	@reads self.Context.WaveDefinitions, Orchestrator.Scheduler
	@writes FSM state registry and context counters
]]
function WaveSpawnerFSM:RegisterStates()
	self:AddState("Preparing", {
		OnEnter = function(_, fsm)
			fsm.Priority = BaseStateMachine.Priorities.Background
			fsm.Context.CurrentWave = fsm.Context.CurrentWave or 1
			fsm.Context.SpawnedThisWave = 0
			fsm.Context.SpawnBudgetAccumulator = 0
			fsm.Context.PreparedSpawnPositions = {}

			local wave = getCurrentWave(fsm)
			if not wave then
				fsm.State = "AllWavesComplete"
				return
			end

			fsm.Context.PreparedSpawnPositions = buildSpawnPositions(getSpawnAnchor(fsm), wave.Count)
			syncSpawnerEntity(fsm, true)
			fsm:Log({
				Level = "INFO",
				Message = string.format(
					"Preparing wave %d/%d at Background priority (%d). Precomputed %d spawn points and scheduled Spawning in 3s.",
					fsm.Context.CurrentWave,
					#getWaveDefinitions(fsm),
					fsm.Priority,
					#(fsm.Context.PreparedSpawnPositions :: {Vector3})
				),
			})
			fsm:ScheduleTransition(3, "Spawning")
		end,
	}, { "Spawning", "AllWavesComplete" })

	self:AddState("Spawning", {
		OnEnter = function(_, fsm)
			fsm.Priority = BaseStateMachine.Priorities.High
			fsm.Context.SpawnBudgetAccumulator = 0

			local wave = getCurrentWave(fsm)
			if not wave then
				fsm.State = "AllWavesComplete"
				return
			end

			if type(fsm.Context.PreparedSpawnPositions) ~= "table" or #fsm.Context.PreparedSpawnPositions == 0 then
				fsm.Context.PreparedSpawnPositions = buildSpawnPositions(getSpawnAnchor(fsm), wave.Count)
			end

			syncSpawnerEntity(fsm, true)
			fsm:Log({
				Level = "INFO",
				Message = string.format(
					"Spawning wave %d/%d at High priority (%d). High priority means OnHeartbeat receives accumulated dt roughly every other frame.",
					fsm.Context.CurrentWave,
					#getWaveDefinitions(fsm),
					fsm.Priority
				),
			})
		end,
		OnHeartbeat = function(_, fsm, dt)
			local wave = getCurrentWave(fsm)
			if not wave then
				fsm.State = "AllWavesComplete"
				return
			end

			local spawnSliceSeconds = 1 / 60
			local queuedBudget = math.min((fsm.Context.SpawnBudgetAccumulator or 0) + dt, spawnSliceSeconds * 3)
			fsm.Context.SpawnBudgetAccumulator = queuedBudget

			local remaining = wave.Count - (fsm.Context.SpawnedThisWave or 0)
			local allowedSpawns = math.min(remaining, math.floor(queuedBudget / spawnSliceSeconds))
			if allowedSpawns <= 0 then
				return
			end

			for _ = 1, allowedSpawns do
				local spawnIndex = (fsm.Context.SpawnedThisWave or 0) + 1
				local spawnPositions = fsm.Context.PreparedSpawnPositions :: {Vector3}
				local position = spawnPositions[spawnIndex] or resolveWorldPosition(getSpawnAnchor(fsm))
				createNpcMarker(fsm, wave, position, spawnIndex)
				fsm.Context.SpawnedThisWave = spawnIndex
				fsm.Context.TotalSpawned = (fsm.Context.TotalSpawned or 0) + 1
				fsm.Context.SpawnBudgetAccumulator = math.max(0, (fsm.Context.SpawnBudgetAccumulator or 0) - spawnSliceSeconds)
			end

			syncSpawnerEntity(fsm, true)
			fsm:Log({
				Level = "DEBUG",
				Message = string.format(
					"Spawning heartbeat dt=%.3f consumed %d slice(s); spawned %d/%d in wave %d.",
					dt,
					allowedSpawns,
					fsm.Context.SpawnedThisWave or 0,
					wave.Count,
					fsm.Context.CurrentWave or 0
				),
			})

			if (fsm.Context.SpawnedThisWave or 0) >= wave.Count then
				fsm.State = "WaveCooldown"
			end
		end,
	}, { "WaveCooldown", "AllWavesComplete" })

	self:AddState("WaveCooldown", {
		OnEnter = function(_, fsm)
			fsm.Priority = BaseStateMachine.Priorities.Medium
			if fsm.Context.CooldownArmed then
				fsm.Context.CooldownArmed = false
				if (fsm.Context.CurrentWave or 0) < #getWaveDefinitions(fsm) then
					fsm.Context.CurrentWave = (fsm.Context.CurrentWave or 0) + 1
					fsm.Context.SpawnedThisWave = 0
					fsm.State = "Preparing"
				else
					fsm.State = "AllWavesComplete"
				end
				return
			end

			fsm.Context.CooldownArmed = true
			fsm.WaitSpan = 5
			syncSpawnerEntity(fsm, true)
			fsm:Log({
				Level = "INFO",
				Message = string.format(
					"WaveCooldown entered at Medium priority (%d). WaitSpan=5 re-enters the same state, then polling decides the next hop.",
					fsm.Priority
				),
			})
		end,
	}, { "WaveCooldown", "Preparing", "AllWavesComplete" })

	self:AddState("AllWavesComplete", {
		Timeout = 60,
		OnTimeout = "Completed",
		OnEnter = function(_, fsm)
			fsm.Priority = BaseStateMachine.Priorities.Background
			fsm.Context.CleanupElapsed = 0
			fsm.Context.NextCleanupLogAt = 10
			ensureCompletionCleanupTask(fsm)
			syncSpawnerEntity(fsm, true)
			fsm:Log({
				Level = "INFO",
				Message = string.format(
					"All waves complete. Background priority (%d) keeps cleanup cheap while Timeout=60 waits for auto-transition to Completed.",
					fsm.Priority
				),
			})
		end,
		OnHeartbeat = function(_, fsm, dt)
			fsm.Context.CleanupElapsed = (fsm.Context.CleanupElapsed or 0) + dt
			local nextLogAt = fsm.Context.NextCleanupLogAt or 10
			if (fsm.Context.CleanupElapsed or 0) >= nextLogAt then
				fsm:Log({
					Level = "DEBUG",
					Message = string.format(
						"AllWavesComplete heartbeat dt=%.3f cleanupElapsed=%.1fs. Background cadence keeps this maintenance state lightweight.",
						dt,
						fsm.Context.CleanupElapsed or 0
					),
				})
				fsm.Context.NextCleanupLogAt = nextLogAt + 10
			end
		end,
		OnLeave = function(_, fsm)
			stopCompletionCleanupTask(fsm)
		end,
	}, { "Completed" })

	self:AddState("Completed", {
		OnEnter = function(_, fsm)
			fsm.Priority = BaseStateMachine.Priorities.Low
			stopCompletionCleanupTask(fsm)
			syncSpawnerEntity(fsm, false)
			fsm:Log({
				Level = "INFO",
				Message = string.format(
					"Wave spawner completed after %d total NPCs across %d waves. Final shutdown priority was lowered to %d.",
					fsm.Context.TotalSpawned or 0,
					#getWaveDefinitions(fsm),
					fsm.Priority
				),
			})
		end,
	}, nil)
end

--[[
	@description Deschedules background scheduler tasks and marks the spawner
	entity inactive if the FSM is torn down early.
	@return ()
	@reads scheduler registry, spawner entity state
	@writes scheduler registry, entity IsActive flag
]]
function WaveSpawnerFSM:OnCleanup()
	stopCompletionCleanupTask(self)
	syncSpawnerEntity(self, false)
end

--[[
	BootstrapUsageExample

	Move WaveSpawnerEntity into your Entities folder and WaveSpawnerFSM into your
	StateMachines folder if you want the Factory to resolve them by string name.

	Usage:
	local Orchestrator = require(...)
	Orchestrator:RegisterComponents()
	
	local spawner = Orchestrator.CreateEntity({
	    EntityClass = "WaveSpawner",
	    EntityId = "Spawner_Arena1",
	    Context = { Instance = workspace.Arena1.SpawnZone },
	})
	
	Orchestrator.CreateStateMachine({
	    StateMachineClass = "WaveSpawnerFSM",
	    StateMachineId = "WaveSpawner_Arena1",
	    Context = {
	        SpawnerEntityId = "Spawner_Arena1",
	        WaveDefinitions = {
	            { Count = 5, NpcType = "Grunt" },
	            { Count = 8, NpcType = "Scout" },
	            { Count = 3, NpcType = "Boss" },
	        },
	    },
	})
]]

return {
	WaveSpawnerEntity = WaveSpawnerEntity,
	WaveSpawnerFSM = WaveSpawnerFSM,
}