--!strict
-- @Name SettingsPageEntity
-- @Author iKrypto (AI Assistant)
-- @Description Settings Page entity managing setting values and pending changes.

local BasePageEntity = require(script.Parent.BasePageEntity)

local SettingsPageEntity = BasePageEntity.Extend({
	Name = "SettingsPageEntity",
	Schema = {
		-- Data State
		InitializedSettings = { Type = "boolean", Persist = false },
		PendingChanges = { Type = "table", Persist = false }, -- { [settingName]: newValue }
	}
})

function SettingsPageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	baseContext.SettingFields = {} -- Cache setting input elements
	return baseContext
end

function SettingsPageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	self.InitializedSettings = false
	self.PendingChanges = {}
	
	self:Log({ Level = "INFO", Message = "SettingsPageEntity initialized" })
end

function SettingsPageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
	
	if changes.PendingChanges ~= nil then
		self:Log({ Level = "DEBUG", Message = string.format("Settings pending changes: %d", 
			(function()
				local count = 0
				for _ in pairs(self.PendingChanges) do count += 1 end
				return count
			end)()
		)})
	end
end

function SettingsPageEntity:SetPendingChange(settingName: string, value: any)
	local newPending = table.clone(self.PendingChanges)
	newPending[settingName] = value
	self.PendingChanges = newPending
end

function SettingsPageEntity:ClearPendingChanges()
	self.PendingChanges = {}
end

function SettingsPageEntity:HasPendingChanges(): boolean
	return next(self.PendingChanges) ~= nil
end

function SettingsPageEntity:Cleanup()
	self.SettingFields = {}
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "SettingsPageEntity cleanup complete" })
end

return SettingsPageEntity
