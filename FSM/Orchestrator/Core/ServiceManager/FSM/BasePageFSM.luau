--!strict
-- @Name BasePageFSM
-- @Author iKrypto (AI Assistant)
-- @Description Base FSM pattern for ServiceManager pages.
-- Defines standard page lifecycle states and provides hooks for subclass customization.

local BasePageFSM = {
	Definition = {
		Name = "BasePageFSM",
		ValidStates = { 
			"Initializing",  -- One-time UI setup, hook event listeners
			"Idle",          -- Wait for state changes or user interactions
			"DataFetching",  -- Retrieve data from services/server
			"Rendering",     -- Update UI elements based on entity state
			"Transitioning", -- Handle page hide/show animations
			"Destroyed"      -- Terminal state for cleanup
		},
		TerminalStates = { "Destroyed" },
		InitialState = "Initializing",
		Priority = 6 -- Medium-high priority for UI responsiveness
	}
}

--[[
	@description Registers states for the base page FSM.
	Subclasses should override this and call the base implementation first,
	then add their own state-specific logic.
	@return ()
]]
function BasePageFSM:RegisterStates()
	
	-- State: Initializing
	-- Purpose: One-time setup of UI elements, event listeners, and initial data fetch
	self:AddState("Initializing", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "INFO", Message = "Page initializing..." })
			
			-- Get page entity from context
			local entity = fsm.Context.PageEntity
			if not entity then
				fsm:Log({ Level = "ERROR", Message = "PageEntity not found in context" })
				fsm:Fail("Missing PageEntity")
				return
			end
			
			-- Call subclass hook for custom initialization
			if fsm.OnInitializeUI then
				local success, err = pcall(function()
					fsm:OnInitializeUI(entity)
				end)
				
				if not success then
					fsm:Log({ Level = "ERROR", Message = string.format("OnInitializeUI failed: %s", tostring(err)) })
					fsm:Fail("Initialization failed")
					return
				end
			end
			
			-- Mark toolbar as initialized
			entity.ToolbarInitialized = true
			
			-- Transition to Idle
			fsm:ChangeState({ Name = "Idle" })
		end
	})
	
	-- State: Idle
	-- Purpose: Wait for entity state changes or user interactions
	self:AddState("Idle", {
		OnEnter = function(fsm)
			fsm.Context._idleStartTime = os.clock()
		end,
		
		OnHeartbeat = function(fsm, dt)
			local entity = fsm.Context.PageEntity
			if not entity then return end
			
			-- Check if we need to fetch new data
			if fsm.Context._needsDataFetch then
				fsm.Context._needsDataFetch = false
				fsm:ChangeState({ Name = "DataFetching" })
				return
			end
			
			-- Check if we need to re-render
			if fsm.Context._needsRender then
				fsm.Context._needsRender = false
				fsm:ChangeState({ Name = "Rendering" })
				return
			end
			
			-- Call subclass hook for custom idle logic
			if fsm.OnIdleUpdate then
				fsm:OnIdleUpdate(entity, dt)
			end
		end
	})
	
	-- State: DataFetching
	-- Purpose: Retrieve data from services or server
	self:AddState("DataFetching", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "DEBUG", Message = "Fetching data..." })
			
			local entity = fsm.Context.PageEntity
			if not entity then
				fsm:ChangeState({ Name = "Idle" })
				return
			end
			
			-- Call subclass hook to fetch data
			if fsm.OnFetchData then
				local success, err = pcall(function()
					fsm:OnFetchData(entity)
				end)
				
				if not success then
					fsm:Log({ Level = "ERROR", Message = string.format("OnFetchData failed: %s", tostring(err)) })
				end
			end
			
			-- Transition to Rendering
			fsm:ChangeState({ Name = "Rendering" })
		end
	})
	
	-- State: Rendering
	-- Purpose: Update UI elements based on entity state
	self:AddState("Rendering", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "DEBUG", Message = "Rendering UI..." })
			
			local entity = fsm.Context.PageEntity
			if not entity then
				fsm:ChangeState({ Name = "Idle" })
				return
			end
			
			-- Call subclass hook to render UI
			if fsm.OnRenderUI then
				local success, err = pcall(function()
					fsm:OnRenderUI(entity)
				end)
				
				if not success then
					fsm:Log({ Level = "ERROR", Message = string.format("OnRenderUI failed: %s", tostring(err)) })
				end
			end
			
			-- Transition back to Idle
			fsm:ChangeState({ Name = "Idle" })
		end
	})
	
	-- State: Transitioning
	-- Purpose: Handle page visibility animations
	self:AddState("Transitioning", {
		OnEnter = function(fsm)
			local entity = fsm.Context.PageEntity
			if not entity then
				fsm:ChangeState({ Name = "Idle" })
				return
			end
			
			-- Call subclass hook for custom transitions
			if fsm.OnTransition then
				local success, err = pcall(function()
					fsm:OnTransition(entity)
				end)
				
				if not success then
					fsm:Log({ Level = "ERROR", Message = string.format("OnTransition failed: %s", tostring(err)) })
				end
			end
			
			-- Transition back to Idle after animation
			fsm.WaitSpan = 0.18 -- Default transition duration
			fsm:ChangeState({ Name = "Idle" })
		end
	})
	
	-- State: Destroyed
	-- Terminal state for cleanup
	self:AddState("Destroyed", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "INFO", Message = "Page FSM destroyed" })
		end
	})
end

--[[
	@description Virtual hook for subclasses to initialize UI elements.
	Called once during Initializing state.
	@param entity any -- The page entity
	@return ()
]]
function BasePageFSM:OnInitializeUI(entity: any)
	-- Virtual method - subclasses should override
end

--[[
	@description Virtual hook for subclasses to fetch data.
	Called when entering DataFetching state.
	@param entity any -- The page entity
	@return ()
]]
function BasePageFSM:OnFetchData(entity: any)
	-- Virtual method - subclasses should override
end

--[[
	@description Virtual hook for subclasses to render UI.
	Called when entering Rendering state.
	@param entity any -- The page entity
	@return ()
]]
function BasePageFSM:OnRenderUI(entity: any)
	-- Virtual method - subclasses should override
end

--[[
	@description Virtual hook for subclasses to handle transitions.
	Called when entering Transitioning state.
	@param entity any -- The page entity
	@return ()
]]
function BasePageFSM:OnTransition(entity: any)
	-- Virtual method - subclasses should override
end

--[[
	@description Virtual hook for subclasses to perform idle updates.
	Called every frame while in Idle state.
	@param entity any -- The page entity
	@param dt number -- Delta time
	@return ()
]]
function BasePageFSM:OnIdleUpdate(entity: any, dt: number)
	-- Virtual method - subclasses should override
end

--[[
	@description Helper to trigger a data fetch on next update.
	@return ()
]]
function BasePageFSM:RequestDataFetch()
	self.Context._needsDataFetch = true
end

--[[
	@description Helper to trigger a render on next update.
	@return ()
]]
function BasePageFSM:RequestRender()
	self.Context._needsRender = true
end

--[[
	@description Cleanup handler for FSM destruction.
	@return ()
]]
function BasePageFSM:OnCleanup()
	-- Clear context flags
	if self.Context then
		self.Context._needsDataFetch = nil
		self.Context._needsRender = nil
		self.Context._idleStartTime = nil
	end
	
	self:Log({ Level = "INFO", Message = "BasePageFSM cleanup complete" })
end

return BasePageFSM
