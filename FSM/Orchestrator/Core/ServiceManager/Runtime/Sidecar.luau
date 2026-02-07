--!strict
-- Sidecar
-- Developer-facing convenience API for working with Orchestrator, Factory, StateMachines, Entities.
-- This module is intentionally UI-agnostic.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type Sidecar = {
	GetOrchestrator: (self: Sidecar) -> any?,
	GetFactory: (self: Sidecar) -> any?,

	-- Requests (client->server)
	Request: (self: Sidecar, requestName: string, ...any) -> any,
	GetServerSyncData: (self: Sidecar) -> any?,

	-- Entities
	CreateEntity: (self: Sidecar, classOrName: any, params: { EntityId: string?, Context: { [any]: any } }) -> any?,
	GetEntity: (self: Sidecar, entityId: string) -> any?,
	SendEntityCommand: (self: Sidecar, entityId: string, command: string, ...any) -> (),

	-- FSM / StateMachines
	CreateStateMachine: (self: Sidecar, classOrName: any, params: { StateMachineId: string?, Context: { [any]: any }? }) -> any?,
	GetStateMachine: (self: Sidecar, stateMachineId: string) -> any?,
	CancelStateMachine: (self: Sidecar, stateMachineId: string) -> boolean,
	RetryStateMachine: (self: Sidecar, stateMachineId: string) -> (),
}

local SidecarImpl = {}
SidecarImpl.__index = SidecarImpl
SidecarImpl.__index = SidecarImpl

local function getOrchestratorModule(): ModuleScript?
	local m = ReplicatedStorage:FindFirstChild("Orchestrator")
	if m and m:IsA("ModuleScript") then
		return m
	end
	return nil
end


function SidecarImpl:_getOrchestrator(): any?
	local module = getOrchestratorModule()
	if not module then return nil end
	local ok, orchestrator = pcall(require, module)
	return ok and orchestrator or nil
end

function SidecarImpl:GetOrchestrator_Unsafe(): any
	local orchestrator = self:_getOrchestrator()
	if not orchestrator then
		error("[ServiceManager.Sidecar] Orchestrator module not found/require failed")
	end
	return orchestrator
end

function SidecarImpl:GetOrchestrator(): any?
	return self:_getOrchestrator()
end

function SidecarImpl:GetFactory(): any?
	-- Prefer shared.fsm.Factory since it is set during Orchestrator:RegisterComponents()
	local orch = self:_getOrchestrator()
	return orch and orch.Factory or nil
end

function SidecarImpl:Request(requestName: string, ...: any): any
	local orch = self:GetOrchestrator_Unsafe()
	if type(orch.Request) ~= "function" then
		error("[ServiceManager.Sidecar] Orchestrator.Request unavailable")
	end
	return orch.Request(requestName, ...)
end

function SidecarImpl:GetServerSyncData(): any?
	if not RunService:IsClient() then return nil end
	-- Directly invoke the RemoteFunction used by Orchestrator.
	-- Directly invoke the RemoteFunction used by Orchestrator.
	local orch = self:_getOrchestrator()
	if orch and orch.Request then
		local ok2, result2 = pcall(function()
			return orch.Request("GetSyncData")
		end)
		return ok2 and result2 or nil
	end
	return nil
end

function SidecarImpl:CreateEntity(classOrName: any, params: { EntityId: string?, Context: { [any]: any } }): any?
	local orch = self:GetOrchestrator_Unsafe()
	if type(orch.CreateEntity) ~= "function" then
		error("[ServiceManager.Sidecar] Orchestrator.CreateEntity unavailable")
	end
	return orch.CreateEntity({
		EntityClass = classOrName,
		EntityId = params.EntityId,
		Context = params.Context,
	})
end

function SidecarImpl:GetEntity(entityId: string): any?
	local orch = self:_getOrchestrator()
	return orch and orch.GetEntity and orch.GetEntity(entityId) or nil
end

function SidecarImpl:SendEntityCommand(entityId: string, command: string, ...: any)
	local orch = self:_getOrchestrator()
	if orch and type((orch :: any).SendCommand) == "function" then
		(orch :: any).SendCommand(entityId, command, ...)
		return
	end
	-- Fallback to RemoteEvent used by Orchestrator
	local remote = ReplicatedStorage:FindFirstChild("EntityCommandEvent")
	if remote and remote:IsA("RemoteEvent") then
		(remote :: RemoteEvent):FireServer(entityId, command, ...)
	end
end

function SidecarImpl:CreateStateMachine(classOrName: any, params: { StateMachineId: string?, Context: { [any]: any }? }): any?
	local orch = self:GetOrchestrator_Unsafe()
	if type(orch.CreateStateMachine) ~= "function" then
		error("[ServiceManager.Sidecar] Orchestrator.CreateStateMachine unavailable")
	end
	return orch.CreateStateMachine({
		StateMachineClass = classOrName,
		StateMachineId = params.StateMachineId,
		Context = params.Context,
	})
end

function SidecarImpl:GetStateMachine(stateMachineId: string): any?
	local orch = self:_getOrchestrator()
	return orch and orch.GetStateMachine and orch.GetStateMachine(stateMachineId) or nil
end

function SidecarImpl:CancelStateMachine(stateMachineId: string): boolean
	local orch = self:_getOrchestrator()
	return (orch and orch.CancelStateMachine and orch.CancelStateMachine(stateMachineId)) or false
end

function SidecarImpl:RetryStateMachine(stateMachineId: string)
	local orch = self:_getOrchestrator()
	if orch and orch.RetryStateMachine then
		orch.RetryStateMachine(stateMachineId)
	end
end

local function new(): Sidecar
	return setmetatable({}, SidecarImpl) :: any
end

return {
	new = new,
}
