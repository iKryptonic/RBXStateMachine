--!strict
-- @Name BottomBarEntity
-- @Author iKrypto
-- @Description Entity managing bottom status bar indicators (server tick, time, task count, running tasks, user info).

local BottomBarEntity = {
	Definition = {
		Name = "BottomBarEntity",
		Schema = {
			ServerTick = { Type = "number", Persist = false },
			ServerTime = { Type = "string", Persist = false },
			TaskCount = { Type = "number", Persist = false },
			RunningTaskCount = { Type = "number", Persist = false },
			UserName = { Type = "string", Persist = false },
		}
	}
}

--[[
	@description Extracts the bottom bar container and ServiceManager reference from creation params.
	@param params any -- Entity creation parameters containing Context table.
	@return table -- The resolved context with BottomBarContainer and ServiceManager.
]]
function BottomBarEntity:GetContext(params: any)
	return {
		BottomBarContainer = params.Context and params.Context.BottomBarContainer,
		ServiceManager = params.Context and params.Context.ServiceManager,
	}
end

--[[
	@description Initializes bottom bar state counters and caches label GUI references.
]]
function BottomBarEntity:Initialize()
	self.ServerTick = 0
	self.ServerTime = os.date("%I:%M:%S %p")
	self.TaskCount = 0
	self.RunningTaskCount = 0
	self.UserName = ""
	
	-- Cache UI label references
	if self.BottomBarContainer then
		self.ServerTickLabel = self.BottomBarContainer:FindFirstChild("ServerTick")
		self.ServerTimeLabel = self.BottomBarContainer:FindFirstChild("ServerTime")
		self.TaskCountLabel = self.BottomBarContainer:FindFirstChild("TaskCount")
		self.TaskQueueLabel = self.BottomBarContainer:FindFirstChild("TaskQueue")
		self.UserInfoLabel = self.BottomBarContainer:FindFirstChild("UserInfo")
	end
	
	self:UpdateLabels()
	
	self:Log({ Level = "INFO", Message = "BottomBarEntity initialized" })
end

--[[
	@description Refreshes all bottom bar label text with current state values
	(tick, time, task count, running count, user name).
]]
function BottomBarEntity:UpdateLabels()
	if self.ServerTickLabel then
		self.ServerTickLabel.Text = string.format(
			"<font color='#888888'>[TICK]</font> <font color='#A0FFA0'>%d</font>", 
			self.ServerTick
		)
	end
	
	if self.ServerTimeLabel then
		self.ServerTimeLabel.Text = string.format(
			"<font color='#888888'>[TIME]</font> %s", 
			self.ServerTime
		)
	end
	
	if self.TaskCountLabel then
		local label = "[TASKS]"
		if self.ServiceManager and self.ServiceManager.ActiveService == "FSM" then
			label = "[JOBS]"
		end
		
		self.TaskCountLabel.Text = string.format(
			"<font color='#888888'>%s</font> %d", 
			label, 
			self.TaskCount
		)
	end
	
	if self.TaskQueueLabel then
		self.TaskQueueLabel.Text = string.format(
			"<font color='#888888'>[RUNNING]</font> %d", 
			self.RunningTaskCount
		)
	end
	
	if self.UserInfoLabel then
		self.UserInfoLabel.Text = string.format(
			"<font color='#888888'>[USER]</font> %s", 
			self.UserName:lower()
		)
	end
end

--[[
	@description Applies schema-defined state changes and refreshes labels if any value changed.
	@param changes { [string]: any } -- Key-value pairs of changed fields.
]]
function BottomBarEntity:ApplyChanges(changes: { [string]: any })
	local needsUpdate = false
	
	for key, value in pairs(changes) do
		if self.Definition.Schema[key] then
			self[key] = value
			needsUpdate = true
		end
	end
	
	if needsUpdate then
		self:UpdateLabels()
	end
end

return BottomBarEntity
