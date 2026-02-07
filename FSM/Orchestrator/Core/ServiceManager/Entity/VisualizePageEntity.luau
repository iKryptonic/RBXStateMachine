--!strict
-- @Name VisualizePageEntity
-- @Author iKrypto (AI Assistant)
-- @Description Visualize Page entity managing FSM graph visualization state.

local BasePageEntity = require(script.Parent.BasePageEntity)

local VisualizePageEntity = BasePageEntity.Extend({
	Name = "VisualizePageEntity",
	Schema = {
		SelectedStateMachineId = { Type = "string", Persist = false },
		GraphData = { Type = "table", Persist = false },
		ZoomLevel = { Type = "number", Persist = false },
	}
})

function VisualizePageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	baseContext.Canvas = nil
	baseContext.ZoomControls = nil
	baseContext.NodeFrames = {}
	baseContext.EdgeLines = {}
	return baseContext
end

function VisualizePageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	self.SelectedStateMachineId = nil
	self.GraphData = nil
	self.ZoomLevel = 1.0
	
	self:Log({ Level = "INFO", Message = "VisualizePageEntity initialized" })
end

function VisualizePageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
	
	if changes.ZoomLevel ~= nil then
		if self.Canvas then
			self.Canvas.Size = UDim2.new(self.ZoomLevel, 0, self.ZoomLevel, 0)
		end
	end
end

function VisualizePageEntity:SetZoom(level: number)
	self.ZoomLevel = math.clamp(level, 0.5, 2.0)
end

function VisualizePageEntity:ZoomIn()
	self:SetZoom(self.ZoomLevel + 0.1)
end

function VisualizePageEntity:ZoomOut()
	self:SetZoom(self.ZoomLevel - 0.1)
end

function VisualizePageEntity:Cleanup()
	self.Canvas = nil
	self.ZoomControls = nil
	self.NodeFrames = {}
	self.EdgeLines = {}
	BasePageEntity.Cleanup(self)
end

return VisualizePageEntity
