--!strict
-- @Name ServiceManager/ServiceBrain.luau
-- @Author iKrypto
-- @Description Top-level Behavior Tree that orchestrates all Nexus subsystem modules.
-- Uses the framework's BehaviorTree to coordinate rendering, data fetching, insights, and animations.

local ServiceBrain = {}

local BehaviorTree: any = nil
local Status: any = nil

--[[
	Cache the framework BehaviorTree references used by the Nexus brain.
	Must run before Build so the returned tree can construct condition/action
	nodes against the orchestrator's factory.
]]
function ServiceBrain.Initialize(Orchestrator: any)
	BehaviorTree = Orchestrator.Factory.BehaviorTree
	Status = BehaviorTree.BehaviorTreeStatus
end

-- ══════════════════════════════════════════════════════════════
-- CONDITION NODES
-- ══════════════════════════════════════════════════════════════

local function IsInitialized(ctx: any): string
	if ctx.Nexus and ctx.Nexus._initialized then
		return Status.Success
	end
	return Status.Failure
end

local function HasActiveSubsystem(ctx: any): string
	if ctx.Nexus and ctx.Nexus.ActiveSubsystem then
		return Status.Success
	end
	return Status.Failure
end

local function NeedsDataRefresh(ctx: any): string
	local nexus = ctx.Nexus
	if not nexus then return Status.Failure end
	local now = os.clock()
	local lastRefresh = nexus._lastDataRefresh or 0
	local intervalValue = nexus._dataRefreshInterval
	local interval = if type(intervalValue) == "number" and intervalValue >= 0 then intervalValue else 0.5
	if now - lastRefresh >= interval then
		return Status.Success
	end
	return Status.Failure
end

local function HasPendingInsights(ctx: any): string
	local nexus = ctx.Nexus
	if not nexus then return Status.Failure end
	local analytics = nexus._analyticsEngine
	if analytics and analytics:HasPendingWork() then
		return Status.Success
	end
	return Status.Failure
end

local function HasDirtyUI(ctx: any): string
	local nexus = ctx.Nexus
	if not nexus then return Status.Failure end
	local store = nexus.Store
	if store then
		-- Check if any key is dirty
		local snapshot = store:GetSnapshot()
		for key, _ in pairs(snapshot) do
			if store:IsDirty(key) then
				return Status.Success
			end
		end
	end
	return Status.Failure
end

-- ══════════════════════════════════════════════════════════════
-- ACTION NODES
-- ══════════════════════════════════════════════════════════════

local function FetchSubsystemData(ctx: any): string
	local nexus = ctx.Nexus
	if not nexus then return Status.Failure end

	local subsystem = nexus.ActiveSubsystem
	if not subsystem then return Status.Failure end

	local module = nexus._subsystemModules[subsystem]
	if module and module.FetchData then
		local success, err = pcall(module.FetchData, module, nexus)
		if not success then
			local logFn = nexus._Log
			if logFn then logFn("WARN", "FetchData failed for " .. subsystem .. ": " .. tostring(err))
			else warn("[ServiceManager] FetchData failed for " .. subsystem .. ": " .. tostring(err)) end
			return Status.Failure
		end
	end

	nexus._lastDataRefresh = os.clock()
	return Status.Success
end

local function RunInsightAnalysis(ctx: any): string
	local nexus = ctx.Nexus
	if not nexus then return Status.Failure end

	local analytics = nexus._analyticsEngine
	if analytics then
		analytics:RunCycle(nexus)
	end
	return Status.Success
end

local function RenderActiveSubsystem(ctx: any): string
	local nexus = ctx.Nexus
	if not nexus then return Status.Failure end

	local subsystem = nexus.ActiveSubsystem
	if not subsystem then return Status.Failure end

	-- Re-render the currently visible layer. Root layers (depth 0) always
	-- rebuild; drill-down layers (depth ≥ 1) rebuild only if they've opted
	-- in via `layer.Context.LiveUpdate = true`. The FSM visualizer in live
	-- mode sets that flag so the active state, transition history, and
	-- highlighted edge follow the running FSM in real time.
	local navigator = nexus._navigator
	if navigator and navigator.RebuildCurrentLayer then
		local currentLayer = navigator.GetCurrentLayer and navigator:GetCurrentLayer()
		if currentLayer and currentLayer.Depth > 0 then
			local liveOptIn = currentLayer.Context and currentLayer.Context.LiveUpdate == true
			if not liveOptIn then
				if nexus.Store then nexus.Store:ClearDirty() end
				return Status.Success
			end
		end

		local success, err = pcall(function()
			navigator:RebuildCurrentLayer({ Nexus = nexus })
		end)
		if not success then
			local logFn = nexus._Log
			if logFn then logFn("WARN", "RebuildCurrentLayer failed for " .. subsystem .. ": " .. tostring(err))
			else warn("[ServiceManager] RebuildCurrentLayer failed for " .. subsystem .. ": " .. tostring(err)) end
			return Status.Failure
		end
	end

	-- Clear dirty flags after render
	if nexus.Store then
		nexus.Store:ClearDirty()
	end
	return Status.Success
end

local function UpdateAnimations(ctx: any): string
	local nexus = ctx.Nexus
	if not nexus then return Status.Failure end

	local animator = nexus._animationController
	if animator and animator.Tick then
		animator:Tick()
	end
	return Status.Success
end

local function SyncContextData(ctx: any): string
	local nexus = ctx.Nexus
	if not nexus then return Status.Failure end

	if nexus._contextMode == "client" then
		if nexus._SyncClientContext then
			nexus:_SyncClientContext()
		end
	end
	-- Server mode is handled by ConnectionFSM polling
	return Status.Success
end

-- ══════════════════════════════════════════════════════════════
-- TREE CONSTRUCTION
-- ══════════════════════════════════════════════════════════════

--[[
	Build the top-level behavior tree tick function.
	The resulting tree syncs context, refreshes subsystem data when needed,
	renders dirty UI, and always advances animation work.
]]
function ServiceBrain.Build(): (context: any) -> string
	-- The root tree:
	-- Sequence: must be initialized
	--   1. Sync context data (client/server)
	--   2. Selector: try refresh + insights + render
	--     a. Sequence: needs data? -> fetch -> analyze -> render
	--     b. Sequence: dirty UI? -> render only
	--     c. Succeeder: run animations anyway
	--   3. Always: tick animations

	local tree = BehaviorTree.Sequence({
		-- Gate: abort if not initialized
		BehaviorTree.Condition(function(ctx) return ctx.Nexus and ctx.Nexus._initialized end),

		-- Always sync context first
		SyncContextData,

		-- Main work selector
		BehaviorTree.Selector({
			-- Full data cycle: fetch → analyze → render
			BehaviorTree.Sequence({
				NeedsDataRefresh,
				FetchSubsystemData,
				BehaviorTree.Succeeder(RunInsightAnalysis),
				RenderActiveSubsystem,
			}),

			-- Partial: only render if UI is dirty
			BehaviorTree.Sequence({
				HasDirtyUI,
				RenderActiveSubsystem,
			}),

			-- Fallback: report success without double-ticking animations.
			function()
				return Status.Success
			end,
		}),

		-- Always tick animations
		BehaviorTree.Succeeder(UpdateAnimations),
	})

	return tree
end

return ServiceBrain
