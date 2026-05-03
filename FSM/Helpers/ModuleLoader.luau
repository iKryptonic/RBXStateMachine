--!strict

--[=[
	@description Resolves shared ModuleScripts for FSM helpers and state machines by checking orchestrator-provided modules first, then falling back to ReplicatedStorage. This loader centralizes shared dependency lookup so helper modules can run in both orchestrated and standalone environments.
	Used by combat, intent, and transition helpers plus FSM implementations that need shared schema or utility modules.
	Assumes shared modules are either exposed through orchestrator.GetModule or stored under ReplicatedStorage/shared or elsewhere in ReplicatedStorage.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModuleLoader = {}
--[=[
	@description Implements `ModuleLoader.getSharedModule`.
	@param orchestrator any -- `orchestrator` input parameter.
	@param name string -- `name` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

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
--[=[
	@description Implements `ModuleLoader.requireSharedModule`.
	@param orchestrator any -- `orchestrator` input parameter.
	@param name string -- `name` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function ModuleLoader.requireSharedModule(orchestrator: any, name: string): any
	local mod = ModuleLoader.getSharedModule(orchestrator, name)
	if mod == nil then
		error("[ModuleLoader] Required module not found: " .. tostring(name))
	end
	return mod
end

return ModuleLoader
