--!strict
--[[
	@Name Templates
	@Author iKrypto
	@Description Provides stable references to UI template Instances stored in the
	References folder, along with a type-safe Clone helper.
]]

export type Templates = {
	TaskCardReference: TextButton,
	TaskDataReference: Frame,
	SettingReference: Frame,
	LogLineReference: TextLabel,
	ConsoleLineReference: TextLabel,
	Clone: (self: Templates, templateName: string) -> Instance,
}

local TemplatesModule = {}

--[[
	@description Constructs a Templates object from the given References folder.
	Waits for each child by name and casts to the expected type.
	@param referencesFolder Folder -- The folder containing template Instances.
	@return Templates -- A table of references with a :Clone() helper.
]]
function TemplatesModule.new(referencesFolder: Folder): Templates
	local t = {
		TaskCardReference = referencesFolder:WaitForChild("TaskCardReference") :: TextButton,
		TaskDataReference = referencesFolder:WaitForChild("TaskDataReference") :: Frame,
		SettingReference = referencesFolder:WaitForChild("SettingReference") :: Frame,
		LogLineReference = referencesFolder:WaitForChild("LogLineReference") :: TextLabel,
		ConsoleLineReference = referencesFolder:WaitForChild("ConsoleLineReference") :: TextLabel,
	} :: any

	function t:Clone(templateName: string): Instance
		local inst = (t :: any)[templateName]
		if not inst then
			error("[ServiceManager.Templates] Unknown template: " .. tostring(templateName))
		end
		return (inst :: Instance):Clone()
	end

	return t
end

return TemplatesModule
