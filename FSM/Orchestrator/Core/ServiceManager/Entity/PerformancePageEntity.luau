--!strict
-- @Name PerformancePageEntity
-- @Author iKrypto (AI Assistant)
-- @Description Performance Page entity managing performance graph and metrics state.

local BasePageEntity = require(script.Parent.BasePageEntity)

local PerformancePageEntity = BasePageEntity.Extend({
	Name = "PerformancePageEntity",
	Schema = {
		-- Data State
		GraphHistory = { Type = "table", Persist = false },
		IsGraphPaused = { Type = "boolean", Persist = false },
		GraphMode = { Type = "string", Persist = false }, -- "Standard" | "Heatmap"
		SortMode = { Type = "string", Persist = false }, -- "Name" | "Avg" | "Max" | "Count"
	}
})

function PerformancePageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	baseContext.GraphContainer = nil
	baseContext.MetricsContainer = nil
	baseContext.TooltipFrame = nil
	return baseContext
end

function PerformancePageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	self.GraphHistory = {}
	self.IsGraphPaused = false
	self.GraphMode = "Standard"
	self.SortMode = "Avg"
	
	self:Log({ Level = "INFO", Message = "PerformancePageEntity initialized" })
end

function PerformancePageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
	
	if changes.GraphMode ~= nil then
		self:Log({ Level = "DEBUG", Message = string.format("Graph mode changed to: %s", self.GraphMode) })
	end
end

function PerformancePageEntity:TogglePause()
	self.IsGraphPaused = not self.IsGraphPaused
end

function PerformancePageEntity:AddSample(sample: any)
	table.insert(self.GraphHistory, sample)
	if #self.GraphHistory > 100 then
		table.remove(self.GraphHistory, 1)
	end
end

function PerformancePageEntity:ClearHistory()
	self.GraphHistory = {}
end

function PerformancePageEntity:Cleanup()
	self.GraphContainer = nil
	self.MetricsContainer = nil
	self.TooltipFrame = nil
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "PerformancePageEntity cleanup complete" })
end

return PerformancePageEntity
