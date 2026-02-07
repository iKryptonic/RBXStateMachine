--!strict

-- Runtime/Pages/SettingsPage.luau
-- Extracted Settings page controller.

export type Deps = {
	SettingReference: Instance,
}

local SettingsPage = {}

function SettingsPage.Create(ServiceManager: any, deps: Deps)
	local page: any = {
		Container = ServiceManager.GUI.BodyContainer:WaitForChild("SettingsView"):WaitForChild("Container"),
		Tab = ServiceManager.GUI.TabContainer:WaitForChild("Settings"),
		Constants = { Initialized = false },
		Connections = {},
	}

	page.UpdateFunction = function(this)
		local service = ServiceManager.Services[ServiceManager.ActiveService]
		if not this.Container or not service then
			return
		end
		this.Connections = this.Connections or {}

		local function updateSettingField(uniqueName: string, value: any)
			local field = this.Container:FindFirstChild(uniqueName)
			if not field then
				return
			end
			local input = field:FindFirstChild(typeof(value) == "boolean" and "Bool" or "Text")
			if input then
				(input :: any).Text = (typeof(value) == "boolean") and (value and "Enabled" or "Disabled") or tostring(value)
			end
		end

		local function createField(settingName: string, settingValue: any, settingsSubsection: string?)
			local uniqueName = settingsSubsection and (settingsSubsection .. "_" .. settingName) or settingName
			if this.Container:FindFirstChild(uniqueName) then
				return
			end

			local field = deps.SettingReference:Clone()
			local input = field:FindFirstChild(typeof(settingValue) == "boolean" and "Bool" or "Text")
			if not input then
				return
			end

			field.Name = uniqueName
			local titleObj = field:FindFirstChild("Title")
			if titleObj then
				(titleObj :: any).Text = settingsSubsection and (settingsSubsection .. "." .. settingName) or settingName
			end

			local connection
			if typeof(settingValue) == "boolean" then
				connection = (input :: any).MouseButton1Click:Connect(function()
					local settingsGroup = settingsSubsection and service.Settings[settingsSubsection] or service.Settings
					local newValue = not settingsGroup[settingName]
					service:UpdateSetting(settingsSubsection, settingName, newValue)
					updateSettingField(uniqueName, newValue)
				end)
			else
				connection = (input :: any).FocusLost:Connect(function(enter: boolean)
					if not enter then
						return
					end
					local settingsGroup = settingsSubsection and service.Settings[settingsSubsection] or service.Settings
					local current = settingsGroup[settingName]
					local newValue = current
					if type(current) == "number" then
						local num = tonumber((input :: any).Text)
						if num then
							newValue = num
						else
							(input :: any).Text = tostring(current)
						end
					else
						newValue = tonumber((input :: any).Text) or (input :: any).Text
					end
					service:UpdateSetting(settingsSubsection, settingName, newValue)
					updateSettingField(uniqueName, newValue)
				end)
			end

			table.insert(this.Connections, connection)
			field.Parent = (this.Container :: any)
			local fieldGui = field :: any
			fieldGui.Visible = true
			(input :: any).Visible = true
		end

		local serviceSettings = service.Settings
		if not serviceSettings then
			for _, child in pairs(this.Container:GetChildren()) do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
			return
		end

		for sectionName, sectionValue in pairs(serviceSettings) do
			if type(sectionValue) == "table" then
				for settingName, settingValue in pairs(sectionValue) do
					createField(settingName, settingValue, sectionName)
					updateSettingField(sectionName .. "_" .. settingName, settingValue)
				end
			else
				createField(sectionName, sectionValue, nil)
				updateSettingField(sectionName, sectionValue)
			end
		end

		this.Constants.Initialized = true
	end

	return page
end

return SettingsPage
