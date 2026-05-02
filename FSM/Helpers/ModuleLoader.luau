--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModuleLoader = {}

function ModuleLoader.getSharedModule(orchestrator: any, name: string): any
	if orchestrator and type(orchestrator.GetModule) == "function" then
		local mod = orchestrator.GetModule(name)
		if mod ~= nil then
			return mod
		end
	end

	local sharedFolder = ReplicatedStorage:FindFirstChild("shared")
	if sharedFolder then
		local mod = sharedFolder:FindFirstChild(name)
		if mod and mod:IsA("ModuleScript") then
			return require(mod)
		end
	end

	local replicatedMod = ReplicatedStorage:FindFirstChild(name, true)
	if replicatedMod and replicatedMod:IsA("ModuleScript") then
		return require(replicatedMod)
	end

	warn("[ModuleLoader] Module not found: " .. tostring(name))
	return nil
end

function ModuleLoader.requireSharedModule(orchestrator: any, name: string): any
	local mod = ModuleLoader.getSharedModule(orchestrator, name)
	if mod == nil then
		error("[ModuleLoader] Required module not found: " .. tostring(name))
	end
	return mod
end

return ModuleLoader
