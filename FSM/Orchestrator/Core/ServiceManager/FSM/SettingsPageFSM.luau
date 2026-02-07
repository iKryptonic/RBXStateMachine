--!strict
-- @Name SettingsPageFSM
-- @Author iKrypto
-- @Description Settings Page FSM managing configuration toggles and inputs.
-- Migrated from legacy SettingsPage.luau controller pattern.

local BasePageFSM = require(script.Parent.BasePageFSM)

local SettingsPageFSM = BasePageFSM.Extend({
	className = "SettingsPageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "Rendering",
		"EditingSetting", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 8
})

--[[
	@description Registers states for the settings page FSM.
	@return ()
]]
function SettingsPageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	self:AddState("EditingSetting", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "DEBUG", Message = "Editing setting..." })
			fsm:ChangeState({ Name = "Idle" })
		end
	})
end

--[[
	@description Hook for initializing settings UI elements.
	@param entity any
	@return ()
]]
function SettingsPageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing Settings Page UI..." })
	
	local container = entity.Container
	if not container then
		self:Log({ Level = "ERROR", Message = "Settings container not found" })
		return
	end
	
	-- Ensure scrolling frame for settings list
	local settingsList = container:FindFirstChild("SettingsList")
	if not settingsList then
		settingsList = Instance.new("ScrollingFrame")
		settingsList.Name = "SettingsList"
		settingsList.Size = UDim2.new(1, 0, 1, 0)
		settingsList.BackgroundTransparency = 1
		settingsList.ScrollBarThickness = 2
		settingsList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		settingsList.Parent = container
		
		local layout = Instance.new("UIListLayout", settingsList)
		layout.Padding = UDim.new(0, 5)
		local padding = Instance.new("UIPadding", settingsList)
		padding.PaddingLeft = UDim.new(0, 10)
		padding.PaddingTop = UDim.new(0, 10)
	end
	entity.SettingsList = settingsList
	
	self:Log({ Level = "INFO", Message = "Settings Page UI initialized successfully" })
end

--[[
	@description Hook for fetching settings data.
	@param entity any
	@return ()
]]
function SettingsPageFSM:OnFetchData(entity: any)
	local serviceManager = self.Context.ServiceManager
	if not serviceManager then return end
	
	local activeService = serviceManager.ActiveService
	local service = serviceManager.Services and serviceManager.Services[activeService]
	local settings = service and service.Settings or {}
	
	self.Context._settings = settings
	self.Context._activeService = service
	self:Log({ Level = "DEBUG", Message = string.format("Fetched settings for service: %s", tostring(activeService)) })
end

--[[
	@description Hook for rendering settings UI.
	@param entity any
	@return ()
]]
function SettingsPageFSM:OnRenderUI(entity: any)
	local settingsList = entity.SettingsList
	if not settingsList then return end
	
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	local settings = self.Context._settings or {}
	local service = self.Context._activeService
	
	-- If no settings, clear container
	if not service or not settings or next(settings) == nil then
		for _, child in ipairs(settingsList:GetChildren()) do
			if child:IsA("Frame") then child:Destroy() end
		end
		return
	end
	
	-- Render settings fields
	for sectionName, sectionValue in pairs(settings) do
		if type(sectionValue) == "table" then
			-- Nested subsection
			for settingName, settingValue in pairs(sectionValue) do
				self:EnsureSettingField(entity, settingName, settingValue, sectionName, service)
			end
		else
			-- Top-level setting
			self:EnsureSettingField(entity, sectionName, sectionValue, nil, service)
		end
	end
	
	self:Log({ Level = "DEBUG", Message = "Rendered settings fields" })
end

--[[
	@description Ensures a setting field exists and updates its value.
	@param entity any
	@param settingName string
	@param settingValue any
	@param subsection string?
	@param service any
	@return ()
]]
function SettingsPageFSM:EnsureSettingField(entity: any, settingName: string, settingValue: any, subsection: string?, service: any)
	local settingsList = entity.SettingsList
	if not settingsList then return end
	
	local colors = self.Context.COLORS or {}
	local serviceManager = self.Context.ServiceManager
	
	local uniqueName = subsection and (subsection .. "_" .. settingName) or settingName
	local displayName = subsection and (subsection .. "." .. settingName) or settingName
	local isBool = typeof(settingValue) == "boolean"
	
	local field = settingsList:FindFirstChild(uniqueName)
	
	-- Create field if missing
	if not field then
		field = Instance.new("Frame")
		field.Name = uniqueName
		field.Size = UDim2.new(1, -20, 0, 40)
		field.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
		field.Parent = settingsList
		
		Instance.new("UICorner", field).CornerRadius = UDim.new(0, 6)
		
		-- Title label
		local title = Instance.new("TextLabel", field)
		title.Name = "Title"
		title.Size = UDim2.new(0.6, -10, 1, 0)
		title.Position = UDim2.new(0, 10, 0, 0)
		title.BackgroundTransparency = 1
		title.Text = displayName
		title.TextColor3 = Color3.fromRGB(200, 200, 200)
		title.Font = Enum.Font.Gotham
		title.TextSize = 12
		title.TextXAlignment = Enum.TextXAlignment.Left
		
		if isBool then
			-- Boolean toggle button
			local btn = Instance.new("TextButton", field)
			btn.Name = "Bool"
			btn.Size = UDim2.new(0.4, -20, 0, 28)
			btn.Position = UDim2.new(0.6, 0, 0.5, -14)
			btn.BackgroundColor3 = settingValue and (colors.Success or Color3.fromRGB(160, 255, 160)) or (colors.Error or Color3.fromRGB(255, 120, 120))
			btn.Text = settingValue and "Enabled" or "Disabled"
			btn.TextColor3 = Color3.new(1, 1, 1)
			btn.Font = Enum.Font.GothamBold
			btn.TextSize = 11
			Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
			
			entity:Manage(btn.MouseButton1Click:Connect(function()
				local settingsGroup = subsection and service.Settings[subsection] or service.Settings
				local newValue = not settingsGroup[settingName]
				
				if service.UpdateSetting then
					service:UpdateSetting(subsection, settingName, newValue)
				else
					settingsGroup[settingName] = newValue
				end
				
				btn.Text = newValue and "Enabled" or "Disabled"
				btn.BackgroundColor3 = newValue and (colors.Success or Color3.fromRGB(160, 255, 160)) or (colors.Error or Color3.fromRGB(255, 120, 120))
				
				if serviceManager.Toast then
					serviceManager:Toast(string.format("Updated %s to %s", displayName, tostring(newValue)), "Success")
				end
			end))
		else
			-- Text/Number input
			local textBox = Instance.new("TextBox", field)
			textBox.Name = "Text"
			textBox.Size = UDim2.new(0.4, -20, 0, 28)
			textBox.Position = UDim2.new(0.6, 0, 0.5, -14)
			textBox.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
			textBox.Text = tostring(settingValue)
			textBox.TextColor3 = Color3.new(1, 1, 1)
			textBox.Font = Enum.Font.Gotham
			textBox.TextSize = 11
			textBox.ClearTextOnFocus = false
			Instance.new("UICorner", textBox).CornerRadius = UDim.new(0, 4)
			local pad = Instance.new("UIPadding", textBox)
			pad.PaddingLeft = UDim.new(0, 8)
			
			entity:Manage(textBox.FocusLost:Connect(function(enterPressed)
				if not enterPressed then return end
				
				local settingsGroup = subsection and service.Settings[subsection] or service.Settings
				local current = settingsGroup[settingName]
				local newValue = current
				
				if type(current) == "number" then
					local num = tonumber(textBox.Text)
					if num then
						newValue = num
					else
						textBox.Text = tostring(current)
						return
					end
				else
					newValue = tonumber(textBox.Text) or textBox.Text
				end
				
				if service.UpdateSetting then
					service:UpdateSetting(subsection, settingName, newValue)
				else
					settingsGroup[settingName] = newValue
				end
				
				if serviceManager.Toast then
					serviceManager:Toast(string.format("Updated %s", displayName), "Success")
				end
			end))
		end
	else
		-- Update existing field value
		local input = field:FindFirstChild(isBool and "Bool" or "Text")
		if input then
			if isBool then
				(input :: any).Text = settingValue and "Enabled" or "Disabled"
				(input :: any).BackgroundColor3 = settingValue and (colors.Success or Color3.fromRGB(160, 255, 160)) or (colors.Error or Color3.fromRGB(255, 120, 120))
			else
				-- Don't update text if focused
				if not (input :: any):IsFocused() then
					(input :: any).Text = tostring(settingValue)
				end
			end
		end
	end
end

--[[
	@description Request render by flagging context.
	@return ()
]]
function SettingsPageFSM:RequestRender()
	if self.Context then
		self.Context._needsRender = true
	end
end

--[[
	@description Cleanup handler.
	@return ()
]]
function SettingsPageFSM:OnCleanup()
	self.Context._settings = nil
	self.Context._activeService = nil
	BasePageFSM.OnCleanup(self)
end

return SettingsPageFSM
