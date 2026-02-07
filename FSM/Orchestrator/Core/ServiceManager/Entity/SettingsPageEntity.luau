--!strict
-- @Name SettingsPageEntity
-- @Author iKrypto
-- @Description Settings Page entity managing configuration state.
-- Migrated from legacy SettingsPage.luau controller pattern.

local BasePageEntity = require(script.Parent.BasePageEntity)

local SettingsPageEntity = BasePageEntity.Extend({
	Name = "SettingsPageEntity",
	Schema = {
		-- Data State
		Initialized = { Type = "boolean", Persist = false },
	}
})

--[[
	@description Extracts context from initialization parameters.
	@param params { Context: { ... } }
	@return { [string]: any }
]]
function SettingsPageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	
	-- Add settings-specific cached GUI elements
	baseContext.SettingsList = nil
	
	return baseContext
end

--[[
	@description Initializes settings entity state.
	@return ()
]]
function SettingsPageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	-- Initialize data state
	self.Initialized = false
	
	-- Initialize GUI references
	self.SettingsList = nil
	
	self:Log({ Level = "INFO", Message = "SettingsPageEntity initialized" })
end

--[[
	@description Applies entity state changes to GUI.
	@param changes { [string]: any }
	@return ()
]]
function SettingsPageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
	
	if changes.Initialized ~= nil then
		self:Log({ Level = "DEBUG", Message = string.format("Settings initialized: %s", tostring(self.Initialized)) })
	end
end

--[[
	@description Marks the page as initialized.
	@return ()
]]
function SettingsPageEntity:MarkInitialized()
	self.Initialized = true
end

--[[
	@description Cleanup handler.
	@return ()
]]
function SettingsPageEntity:Cleanup()
	self.SettingsList = nil
	self.Initialized = false
	
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "SettingsPageEntity cleanup complete" })
end

return SettingsPageEntity
