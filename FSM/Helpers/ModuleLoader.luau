--!strict

--[=[
	@description Resolves shared ModuleScripts for FSM helpers and state machines by checking orchestrator-provided modules first, then falling back to ReplicatedStorage. This loader centralizes shared dependency lookup so helper modules can run in both orchestrated and standalone environments.
	Used by combat, intent, and transition helpers plus FSM implementations that need shared schema or utility modules.
	Assumes shared modules are either exposed through orchestrator.GetModule or stored under ReplicatedStorage/shared or elsewhere in ReplicatedStorage.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModuleLoader = {}
--[=[
	@description Resolves a shared module by name using the loader's fallback chain. It first asks the
	orchestrator for an already-registered module, then checks ReplicatedStorage.shared for a direct child,
	and finally performs a recursive ReplicatedStorage search before warning and returning nil.

	@param orchestrator any -- Optional orchestrator that may expose GetModule for pre-registered shared modules.
	@param name string -- Module name to resolve.
	@return any -- Module value returned by orchestrator.GetModule or require(...), or nil when no matching ModuleScript exists.
	@reads orchestrator.GetModule, ReplicatedStorage
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
	@description Resolves a shared module exactly like getSharedModule, but enforces that the dependency
	exists. Missing modules raise an error immediately so callers fail fast instead of proceeding with nil.

	@param orchestrator any -- Optional orchestrator used during shared-module lookup.
	@param name string -- Module name that must be present.
	@return any -- Resolved shared module value.
	@throws Error when the requested module cannot be found.
]=]

function ModuleLoader.requireSharedModule(orchestrator: any, name: string): any
	local mod = ModuleLoader.getSharedModule(orchestrator, name)
	if mod == nil then
		error("[ModuleLoader] Required module not found: " .. tostring(name))
	end
	return mod
end

return ModuleLoader
