--!strict
-- @Name BasePageFSM
-- @Author iKrypto
-- @Description Base FSM pattern for ServiceManager pages.
-- Provides an Extend() factory that merges base lifecycle states with page-specific
-- states. Returns plain definition tables that Factory.CompileFolder compiles
-- into proper BaseStateMachine subclasses via BaseStateMachine.Extend.
--
-- Lifecycle: Initializing → Idle ⇄ DataFetching → Rendering → Idle
--            Idle → Transitioning → Idle
--            * → Destroyed (terminal)

local BasePageFSM = {}

-- States shared by every page FSM.
BasePageFSM.BaseValidStates = {
	"Initializing",   -- One-time UI setup, hook event listeners
	"Idle",           -- Wait for state changes or user interactions
	"DataFetching",   -- Retrieve data from services / server
	"Rendering",      -- Update UI elements based on entity state
	"Transitioning",  -- Handle page hide/show animations
	"Destroyed",      -- Terminal state for cleanup
}

BasePageFSM.BaseTerminalStates = { "Destroyed" }

--[[
	@description Creates a page-FSM class definition by merging the base states
	with the subclass states and copying base methods as defaults.
	@param extensionDef { className: string, validStates: {string}?, terminalStates: {string}?, InitialState: string?, Priority: number? }
	@return any -- Plain definition table consumed by Factory
]]
function BasePageFSM.Extend(extensionDef: { className: string, validStates: {string}?, terminalStates: {string}?, InitialState: string?, Priority: number? })
	-- 1. Merge valid states (de-duplicate)
	local stateSet = {}
	local mergedStates = {}
	for _, s in ipairs(BasePageFSM.BaseValidStates) do
		if not stateSet[s] then
			table.insert(mergedStates, s)
			stateSet[s] = true
		end
	end
	if extensionDef.validStates then
		for _, s in ipairs(extensionDef.validStates) do
			if not stateSet[s] then
				table.insert(mergedStates, s)
				stateSet[s] = true
			end
		end
	end

	-- 2. Merge terminal states
	local termSet = {}
	local mergedTerminal = {}
	for _, s in ipairs(BasePageFSM.BaseTerminalStates) do
		if not termSet[s] then table.insert(mergedTerminal, s); termSet[s] = true end
	end
	if extensionDef.terminalStates then
		for _, s in ipairs(extensionDef.terminalStates) do
			if not termSet[s] then table.insert(mergedTerminal, s); termSet[s] = true end
		end
	end

	-- 3. Build the class definition table
	local PageFSM: any = {
		Definition = {
			className      = extensionDef.className,
			validStates    = mergedStates,
			terminalStates = mergedTerminal,
			InitialState   = extensionDef.InitialState or "Initializing",
			Priority       = extensionDef.Priority or 6,
		},
	}

	-- 4. Copy base methods as defaults (subclasses can override after Extend)
	for k, v in pairs(BasePageFSM) do
		if type(v) == "function" and k ~= "Extend" then
			PageFSM[k] = v
		end
	end

	return PageFSM
end

--------------------------------------------------------------------------------
-- BASE METHODS (mixed into every page FSM via Extend)
--------------------------------------------------------------------------------

--[[
	@description Registers the standard page lifecycle states.
	Subclasses should call BasePageFSM.RegisterStates(self) first, then add custom states.
]]
--[[
	@description Registers the base lifecycle states shared by all page FSMs:
	Initializing, Idle, DataFetching, Rendering, Transitioning, and Destroyed.
]]
function BasePageFSM:RegisterStates()

	-- Initializing ----------------------------------------------------------
	self:AddState("Initializing", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "INFO", Message = string.format("%s: page initializing...", fsm.Name) })

			local entity = fsm.Context.PageEntity
			if not entity then
				fsm:Log({ Level = "WARN", Message = "PageEntity not in context; skipping OnInitializeUI" })
			end

			-- Call subclass hook for custom UI initialization
			if fsm.OnInitializeUI then
				local ok, err = pcall(fsm.OnInitializeUI, fsm, entity)
				if not ok then
					fsm:Log({ Level = "ERROR", Message = "OnInitializeUI failed: " .. tostring(err) })
				end
			end

			if entity then
				entity.ToolbarInitialized = true
			end

			fsm:ChangeState({ Name = "Idle" })
		end,
	})

	-- Idle ------------------------------------------------------------------
	self:AddState("Idle", {
		OnEnter = function(fsm)
			fsm.Context._idleStartTime = os.clock()
		end,

		OnHeartbeat = function(fsm, dt)
			local entity = fsm.Context.PageEntity

			-- React to flags set by subclass helpers
			if fsm.Context._needsDataFetch then
				fsm.Context._needsDataFetch = false
				fsm:ChangeState({ Name = "DataFetching" })
				return
			end

			if fsm.Context._needsRender then
				fsm.Context._needsRender = false
				fsm:ChangeState({ Name = "Rendering" })
				return
			end

			-- Subclass idle update
			if fsm.OnIdleUpdate then
				fsm:OnIdleUpdate(entity, dt)
			end
		end,
	})

	-- DataFetching ----------------------------------------------------------
	self:AddState("DataFetching", {
		OnEnter = function(fsm)
			local entity = fsm.Context.PageEntity

			if fsm.OnFetchData then
				local ok, err = pcall(fsm.OnFetchData, fsm, entity)
				if not ok then
					fsm:Log({ Level = "ERROR", Message = "OnFetchData failed: " .. tostring(err) })
				end
			end

			fsm:ChangeState({ Name = "Rendering" })
		end,
	})

	-- Rendering -------------------------------------------------------------
	self:AddState("Rendering", {
		OnEnter = function(fsm)
			local entity = fsm.Context.PageEntity

			-- Primary rendering path: delegate to the legacy page controller if available
			local pageController = fsm.Context.PageController
			if pageController and pageController.UpdateFunction then
				local ok, err = pcall(pageController.UpdateFunction, pageController)
				if not ok then
					fsm:Log({ Level = "ERROR", Message = "PageController.UpdateFunction failed: " .. tostring(err) })
				end
			end

			-- Secondary: subclass hook for extra rendering
			if fsm.OnRenderUI then
				local ok, err = pcall(fsm.OnRenderUI, fsm, entity)
				if not ok then
					fsm:Log({ Level = "ERROR", Message = "OnRenderUI failed: " .. tostring(err) })
				end
			end

			fsm:ChangeState({ Name = "Idle" })
		end,
	})

	-- Transitioning ---------------------------------------------------------
	self:AddState("Transitioning", {
		OnEnter = function(fsm)
			local entity = fsm.Context.PageEntity

			if fsm.OnTransition then
				local ok, err = pcall(fsm.OnTransition, fsm, entity)
				if not ok then
					fsm:Log({ Level = "ERROR", Message = "OnTransition failed: " .. tostring(err) })
				end
			end

			fsm.WaitSpan = 0.18 -- default transition duration
			fsm:ChangeState({ Name = "Idle" })
		end,
	})

	-- Destroyed (terminal) --------------------------------------------------
	self:AddState("Destroyed", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "INFO", Message = string.format("%s destroyed", fsm.Name) })
		end,
	})
end

--------------------------------------------------------------------------------
-- VIRTUAL HOOKS (subclasses override these)
--------------------------------------------------------------------------------

--[[
	@description Virtual hook called during the Initializing state for page-specific UI setup.
	Subclasses override this to hook input elements and construct UI.
	@param _entity any -- The page entity instance.
]]
function BasePageFSM:OnInitializeUI(_entity: any) end

--[[
	@description Virtual hook called during the DataFetching state to retrieve data.
	Subclasses override this to load data from services.
	@param _entity any -- The page entity instance.
]]
function BasePageFSM:OnFetchData(_entity: any) end

--[[
	@description Virtual hook called during the Rendering state for page-specific UI updates.
	Subclasses override this to render lists, graphs, or detail panels.
	@param _entity any -- The page entity instance.
]]
function BasePageFSM:OnRenderUI(_entity: any) end

--[[
	@description Virtual hook called during the Transitioning state for page animations.
	Subclasses override this for custom show/hide transitions.
	@param _entity any -- The page entity instance.
]]
function BasePageFSM:OnTransition(_entity: any) end

--[[
	@description Virtual hook called every heartbeat while the FSM is in Idle state.
	Subclasses override this for periodic polling or live updates.
	@param _entity any -- The page entity instance.
	@param _dt number -- Delta time since last heartbeat.
]]
function BasePageFSM:OnIdleUpdate(_entity: any, _dt: number) end

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

--[[
	@description Flags the FSM to transition from Idle to DataFetching on the next heartbeat.
]]
function BasePageFSM:RequestDataFetch()
	self.Context._needsDataFetch = true
end

--[[
	@description Flags the FSM to transition from Idle to Rendering on the next heartbeat.
]]
function BasePageFSM:RequestRender()
	self.Context._needsRender = true
end

--------------------------------------------------------------------------------
-- CLEANUP
--------------------------------------------------------------------------------

--[[
	@description Clears internal context flags (_needsDataFetch, _needsRender, _idleStartTime).
]]
function BasePageFSM:OnCleanup()
	if self.Context then
		self.Context._needsDataFetch = nil
		self.Context._needsRender    = nil
		self.Context._idleStartTime  = nil
	end
end

return BasePageFSM
