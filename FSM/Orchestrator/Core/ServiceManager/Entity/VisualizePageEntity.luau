--!strict
-- @Name VisualizePageEntity
-- @Author iKrypto
-- @Description Visualize Page entity managing graph state, nodes, and edges.
-- Migrated from legacy VisualizePage.luau controller pattern.

local BasePageEntity = require(script.Parent.BasePageEntity)

local VisualizePageEntity = BasePageEntity.Extend({
	Name = "VisualizePageEntity",
	Schema = {
		-- Graph State
		Nodes = { Type = "table", Persist = false },
		Edges = { Type = "table", Persist = false },
		Zoom = { Type = "number", Persist = false },
		Pan = { Type = "table", Persist = false }, -- Vector2 stored as table
		Running = { Type = "boolean", Persist = false },
		Alpha = { Type = "number", Persist = false },
		SelectedID = { Type = "string", Persist = false },
	}
})

--[[
	@description Extracts context from initialization parameters.
	@param params { Context: { ... } }
	@return { [string]: any }
]]
function VisualizePageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	
	-- Add visualize-specific cached GUI elements
	baseContext.StateMachineList = nil
	baseContext.World = nil
	
	return baseContext
end

--[[
	@description Initializes visualize entity state.
	@return ()
]]
function VisualizePageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	-- Initialize graph state
	self.Nodes = {}
	self.Edges = {}
	self.Zoom = 1
	self.Pan = Vector2.zero
	self.Running = false
	self.Alpha = 1
	self.SelectedID = nil
	
	-- Initialize GUI references
	self.StateMachineList = nil
	self.World = nil
	self._renderConnection = nil
	
	self:Log({ Level = "INFO", Message = "VisualizePageEntity initialized" })
end

--[[
	@description Applies entity state changes to GUI.
	@param changes { [string]: any }
	@return ()
]]
function VisualizePageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
	
	if changes.SelectedID ~= nil then
		self:Log({ Level = "DEBUG", Message = string.format("FSM selected: %s", tostring(self.SelectedID)) })
	end
	
	if changes.Zoom ~= nil then
		self:Log({ Level = "DEBUG", Message = string.format("Zoom: %.2f", self.Zoom) })
	end
end

--[[
	@description Selects an FSM by ID.
	@param fsmId string?
	@return ()
]]
function VisualizePageEntity:SelectFSM(fsmId: string?)
	self.SelectedID = fsmId
end

--[[
	@description Clears current selection.
	@return ()
]]
function VisualizePageEntity:ClearSelection()
	self.SelectedID = nil
	self.Nodes = {}
	self.Edges = {}
end

--[[
	@description Resets the graph view to default zoom and pan.
	@return ()
]]
function VisualizePageEntity:ResetView()
	self.Zoom = 1
	self.Pan = Vector2.zero
end

--[[
	@description Wakes up the physics simulation.
	@return ()
]]
function VisualizePageEntity:WakeSimulation()
	self.Running = true
	self.Alpha = 1
end

--[[
	@description Cleanup handler.
	@return ()
]]
function VisualizePageEntity:Cleanup()
	if self._renderConnection then
		self._renderConnection:Disconnect()
		self._renderConnection = nil
	end
	
	self.StateMachineList = nil
	self.World = nil
	self.Nodes = {}
	self.Edges = {}
	self.SelectedID = nil
	
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "VisualizePageEntity cleanup complete" })
end

return VisualizePageEntity
