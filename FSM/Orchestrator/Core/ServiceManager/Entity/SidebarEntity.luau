--!strict
-- @Name SidebarEntity
-- @Author iKrypto
-- @Description Entity managing sidebar status indicators (mode, service, ping).

local SidebarEntity = {
	Definition = {
		Name = "SidebarEntity",
		Schema = {
			Mode = { Type = "string", Persist = false },           -- "client" | "server"
			ActiveService = { Type = "string", Persist = false },  -- "Scheduler" | "FSM"
			Ping = { Type = "number", Persist = false },
			IsDisconnected = { Type = "boolean", Persist = false },
		}
	}
}

-- Color constants (match ServiceManager)
local COLORS = {
	Accent = Color3.fromRGB(0, 200, 255),
	Warning = Color3.fromRGB(255, 220, 140),
	ClientMode = Color3.fromRGB(0, 120, 255),
	ServerMode = Color3.fromRGB(200, 50, 50),
}

--[[
	@description Extracts the sidebar container and ServiceManager reference from creation params.
	@param params any -- Entity creation parameters containing Context table.
	@return table -- The resolved context with SidebarContainer and ServiceManager.
]]
function SidebarEntity:GetContext(params: any)
	return {
		SidebarContainer = params.Context and params.Context.SidebarContainer,
		ServiceManager = params.Context and params.Context.ServiceManager,
	}
end

--[[
	@description Initializes sidebar state, caches button/label GUI references, and applies initial visuals.
]]
function SidebarEntity:Initialize()
	self.Mode = "client"
	self.ActiveService = "Scheduler"
	self.Ping = nil
	self.IsDisconnected = false
	
	-- Cache UI references
	if self.SidebarContainer then
		self.ModeToggleBtn = self.SidebarContainer:FindFirstChild("ModeToggle")
		self.ServiceToggleBtn = self.SidebarContainer:FindFirstChild("ServiceToggle")
		self.PingLabel = self.SidebarContainer:FindFirstChild("PingIndicator")
	end
	
	self:UpdateModeButton()
	self:UpdateServiceButton()
	self:UpdatePingLabel()
	
	self:Log({ Level = "INFO", Message = "SidebarEntity initialized" })
end

--[[
	@description Updates the mode toggle button text and color based on current client/server mode.
]]
function SidebarEntity:UpdateModeButton()
	if not self.ModeToggleBtn then return end
	
	local isClient = (self.Mode == "client")
	self.ModeToggleBtn.Text = isClient and "CLIENT" or "SERVER"
	self.ModeToggleBtn.BackgroundColor3 = isClient and COLORS.ClientMode or COLORS.ServerMode
end

--[[
	@description Updates the service toggle button text (TASKS/FSM) and color.
]]
function SidebarEntity:UpdateServiceButton()
	if not self.ServiceToggleBtn then return end
	
	local isScheduler = (self.ActiveService == "Scheduler")
	self.ServiceToggleBtn.Text = isScheduler and "TASKS" or "FSM"
	self.ServiceToggleBtn.BackgroundColor3 = isScheduler and COLORS.Accent or COLORS.Warning
end

--[[
	@description Updates the ping indicator label (shows ms value, OFFLINE, or ---).
]]
function SidebarEntity:UpdatePingLabel()
	if not self.PingLabel then return end
	
	if self.IsDisconnected then
		self.PingLabel.Text = "<font color='#FF7878'>OFFLINE</font>"
	elseif self.Ping then
		self.PingLabel.Text = string.format("PING: <font color='#A0FFA0'>%dms</font>", self.Ping)
	else
		self.PingLabel.Text = "<font color='#888888'>---</font>"
	end
end

--[[
	@description Applies granular state changes and batches the appropriate UI updates.
	@param changes { [string]: any } -- Key-value pairs of changed fields.
]]
function SidebarEntity:ApplyChanges(changes: { [string]: any })
	local needsModeUpdate = false
	local needsServiceUpdate = false
	local needsPingUpdate = false
	
	if changes.Mode ~= nil then
		self.Mode = changes.Mode
		needsModeUpdate = true
	end
	
	if changes.ActiveService ~= nil then
		self.ActiveService = changes.ActiveService
		needsServiceUpdate = true
	end
	
	if changes.Ping ~= nil then
		self.Ping = changes.Ping
		needsPingUpdate = true
	end
	
	if changes.IsDisconnected ~= nil then
		self.IsDisconnected = changes.IsDisconnected
		needsPingUpdate = true
	end
	
	-- Batch UI updates
	if needsModeUpdate then self:UpdateModeButton() end
	if needsServiceUpdate then self:UpdateServiceButton() end
	if needsPingUpdate then self:UpdatePingLabel() end
end

return SidebarEntity
