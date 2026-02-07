--!strict
-- Templates
-- Provides stable access to UI template instances and safe cloning.

export type Templates = {
	TaskCardReference: TextButton,
	TaskDataReference: Frame,
	SettingReference: Frame,
	LogLineReference: TextLabel,
	ConsoleLineReference: TextLabel,
	Clone: (self: Templates, templateName: string) -> Instance,
}

local TemplatesModule = {}

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
