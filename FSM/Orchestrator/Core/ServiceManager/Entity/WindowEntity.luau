--!strict
-- @Name WindowEntity
-- @Author iKrypto
-- @Description Entity managing the ServiceManager main window state (visibility, position, minimization).

local TweenService = game:GetService("TweenService")

local WindowEntity = {
	Definition = {
		Name = "WindowEntity",
		Schema = {
			IsVisible = { Type = "boolean", Persist = false },
			IsMinimized = { Type = "boolean", Persist = false },
			Position = { Type = "UDim2", Persist = false },
			Size = { Type = "UDim2", Persist = false },
		}
	}
}

--[[
	@description Extracts the main frame and ServiceManager reference from creation params.
	@param params any -- Entity creation parameters containing Context table.
	@return table -- The resolved context with MainFrame and ServiceManager.
]]
function WindowEntity:GetContext(params: any)
	return {
		MainFrame = params.Context and params.Context.MainFrame,
		ServiceManager = params.Context and params.Context.ServiceManager,
	}
end

--[[
	@description Initializes window state (hidden, not minimized) and caches position/size from the MainFrame.
]]
function WindowEntity:Initialize()
	self.IsVisible = false
	self.IsMinimized = false
	
	if self.MainFrame then
		self.Position = self.MainFrame.Position
		self.Size = self.MainFrame.Size
	end
	
	self:Log({ Level = "INFO", Message = "WindowEntity initialized" })
end

--[[
	@description Makes the window visible with a slide-in tween animation.
]]
function WindowEntity:Show()
	if not self.MainFrame then 
		self:Log({ Level = "WARN", Message = "WindowEntity: MainFrame not available" })
		return 
	end
	
	self.IsVisible = true
	self.MainFrame.Visible = true
	
	-- Tween in (slide from right)
	local targetPos = UDim2.new(0.5, 0, 0.5, 0)
	local tweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(self.MainFrame, tweenInfo, { Position = targetPos })
	tween:Play()
end

--[[
	@description Hides the window with a slide-out tween, then sets Visible to false.
]]
function WindowEntity:Hide()
	if not self.MainFrame then return end
	
	self.IsVisible = false
	
	-- Tween out (slide to right)
	local targetPos = UDim2.new(0.5, 20, 0.5, 0)
	local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local tween = TweenService:Create(self.MainFrame, tweenInfo, { Position = targetPos })
	
	tween.Completed:Connect(function()
		self.MainFrame.Visible = false
	end)
	tween:Play()
end

--[[
	@description Tweens the window to a minimized bar size.
]]
function WindowEntity:Minimize()
	if not self.MainFrame then return end
	
	self.IsMinimized = true
	
	-- Tween to minimized size
	local targetSize = UDim2.new(0.4, 0, 0, 40)
	local tweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(self.MainFrame, tweenInfo, { Size = targetSize })
	tween:Play()
end

--[[
	@description Restores the window from minimized state to its full stored size.
]]
function WindowEntity:Restore()
	if not self.MainFrame then return end
	
	self.IsMinimized = false
	
	-- Tween to full size
	local tweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(self.MainFrame, tweenInfo, { Size = self.Size })
	tween:Play()
end

--[[
	@description Routes visibility and minimization changes to Show/Hide/Minimize/Restore handlers.
	@param changes { [string]: any } -- Key-value pairs of changed fields.
]]
function WindowEntity:ApplyChanges(changes: { [string]: any })
	-- Handle IsVisible changes
	if changes.IsVisible ~= nil then
		if changes.IsVisible and not self.IsVisible then
			self:Show()
		elseif not changes.IsVisible and self.IsVisible then
			self:Hide()
		end
	end
	
	-- Handle IsMinimized changes
	if changes.IsMinimized ~= nil then
		if changes.IsMinimized and not self.IsMinimized then
			self:Minimize()
		elseif not changes.IsMinimized and self.IsMinimized then
			self:Restore()
		end
	end
	
	-- Handle position/size changes
	if changes.Position ~= nil then
		self.Position = changes.Position
	end
	if changes.Size ~= nil then
		self.Size = changes.Size
	end
end

return WindowEntity
