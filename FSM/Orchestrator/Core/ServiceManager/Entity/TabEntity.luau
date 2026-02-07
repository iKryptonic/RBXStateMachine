--!strict
-- @Name TabEntity
-- @Author iKrypto
-- @Description Entity representing a single tab in the ServiceManager UI.

local TweenService = game:GetService("TweenService")

local TabEntity = {
	Definition = {
		Name = "TabEntity",
		Schema = {
			TabName = { Type = "string", Persist = false },
			IsActive = { Type = "boolean", Persist = false },
			IsEnabled = { Type = "boolean", Persist = false },
		}
	}
}

-- Color constants (match ServiceManager)
local COLORS = {
	Accent = Color3.fromRGB(0, 200, 255),
	Inactive = Color3.fromRGB(45, 45, 45),
	InactiveText = Color3.fromRGB(160, 160, 160),
	ActiveText = Color3.fromRGB(255, 255, 255),
	Hover = Color3.fromRGB(60, 60, 60),
}

--[[
	@description Extracts the tab name and frame GUI reference from creation params.
	@param params any -- Entity creation parameters containing Context table.
	@return table -- The resolved context with TabName and TabFrame.
]]
function TabEntity:GetContext(params: any)
	return {
		TabName = params.Context and params.Context.TabName,
		TabFrame = params.Context and params.Context.TabFrame,
	}
end

--[[
	@description Initializes tab state, caches button/indicator GUI references, and applies initial visuals.
]]
function TabEntity:Initialize()
	self.IsActive = false
	self.IsEnabled = true
	
	-- Cache UI references
	if self.TabFrame then
		self.Button = self.TabFrame:FindFirstChild("Button") or self.TabFrame:FindFirstChildWhichIsA("TextButton")
		self.Indicator = self.TabFrame:FindFirstChild("Indicator")
	end
	
	self:ApplyVisuals()
	
	self:Log({ Level = "INFO", Message = string.format("TabEntity initialized: %s", self.TabName or "Unknown") })
end

--[[
	@description Marks the tab as active and refreshes its visual appearance.
]]
function TabEntity:Activate()
	if not self.IsActive then
		self.IsActive = true
		self:ApplyVisuals()
	end
end

--[[
	@description Marks the tab as inactive and refreshes its visual appearance.
]]
function TabEntity:Deactivate()
	if self.IsActive then
		self.IsActive = false
		self:ApplyVisuals()
	end
end

--[[
	@description Enables the tab, allowing interaction, and refreshes visuals.
]]
function TabEntity:Enable()
	if not self.IsEnabled then
		self.IsEnabled = true
		self:ApplyVisuals()
	end
end

--[[
	@description Disables the tab, preventing interaction, and refreshes visuals.
]]
function TabEntity:Disable()
	if self.IsEnabled then
		self.IsEnabled = false
		self:ApplyVisuals()
	end
end

--[[
	@description Tweens button background/text color and indicator visibility based on active/enabled state.
]]
function TabEntity:ApplyVisuals()
	if not self.Button then return end
	
	local targetColor = self.IsActive and COLORS.Accent or COLORS.Inactive
	local targetTextColor = self.IsActive and COLORS.ActiveText or COLORS.InactiveText
	
	-- Apply with tweens for smooth transitions
	local tweenInfo = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(self.Button, tweenInfo, {
		BackgroundColor3 = targetColor,
		TextColor3 = targetTextColor
	})
	tween:Play()
	
	-- Update indicator visibility
	if self.Indicator then
		self.Indicator.Visible = self.IsActive
	end
	
	-- Update enabled state (no visual for now, just tracked for future use)
	if not self.IsEnabled then
		self.Button.BackgroundTransparency = 0.5
	else
		self.Button.BackgroundTransparency = 0
	end
end

--[[
	@description Connects MouseEnter/MouseLeave events on the tab button for hover color transitions.
]]
function TabEntity:SetupHoverEffects()
	if not self.Button then return end
	
	self:Manage(self.Button.MouseEnter:Connect(function()
		if not self.IsActive then
			local tweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local tween = TweenService:Create(self.Button, tweenInfo, { BackgroundColor3 = COLORS.Hover })
			tween:Play()
		end
	end))
	
	self:Manage(self.Button.MouseLeave:Connect(function()
		if not self.IsActive then
			local tweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local tween = TweenService:Create(self.Button, tweenInfo, { BackgroundColor3 = COLORS.Inactive })
			tween:Play()
		end
	end))
end

--[[
	@description Applies state changes and triggers a visual update if IsActive or IsEnabled changed.
	@param changes { [string]: any } -- Key-value pairs of changed fields.
]]
function TabEntity:ApplyChanges(changes: { [string]: any })
	local needsVisualUpdate = false
	
	if changes.TabName ~= nil then
		self.TabName = changes.TabName
	end
	
	if changes.IsActive ~= nil then
		self.IsActive = changes.IsActive
		needsVisualUpdate = true
	end
	
	if changes.IsEnabled ~= nil then
		self.IsEnabled = changes.IsEnabled
		needsVisualUpdate = true
	end
	
	if needsVisualUpdate then
		self:ApplyVisuals()
	end
end

return TabEntity
