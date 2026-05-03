--!strict

--[=[
	@description Resolves shared ModuleScripts for FSM helpers and state machines by checking orchestrator-provided modules first, then falling back to ReplicatedStorage. This loader centralizes shared dependency lookup so helper modules can run in both orchestrated and standalone environments.
	Used by combat, intent, and transition helpers plus FSM implementations that need shared schema or utility modules.
	Assumes shared modules are either exposed through orchestrator.GetModule or stored under ReplicatedStorage/shared or elsewhere in ReplicatedStorage.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModuleLoader = {}

--[=[
	@description Attempts to resolve a shared module by name. Lookup order is orchestrator.GetModule, ReplicatedStorage.shared, then a recursive ReplicatedStorage search. Emits a warning and returns nil when no ModuleScript can be found.
	@param orchestrator any -- FSM orchestrator or service object that may expose GetModule(name).
	@param name string -- Shared module name to resolve.
	@return any -- Required module result when found, or nil when lookup fails.
	@reads orchestrator.GetModule, ReplicatedStorage.shared, descendants of ReplicatedStorage
	@writes Output warning stream when lookup fails
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
	@description Resolves a shared module using getSharedModule and raises an error if the module is unavailable. Use this when the caller cannot safely proceed without the dependency.
	@param orchestrator any -- FSM orchestrator or service object that may expose GetModule(name).
	@param name string -- Shared module name to resolve.
	@return any -- Required module result.
	@reads orchestrator.GetModule, ReplicatedStorage.shared, descendants of ReplicatedStorage
	@writes Output warning stream through getSharedModule and throws an error when lookup fails
]=]
function ModuleLoader.requireSharedModule(orchestrator: any, name: string): any
	local mod = ModuleLoader.getSharedModule(orchestrator, name)
	if mod == nil then
		error("[ModuleLoader] Required module not found: " .. tostring(name))
	end
	return mod
end

return ModuleLoader
