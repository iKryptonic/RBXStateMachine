--!strict
--[[
	@Name Sidecar
	@Author iKrypto
	@Description Developer-facing convenience API for working with Orchestrator,
	Factory, StateMachines, and Entities. Intentionally UI-agnostic so it can
	be used from game scripts without pulling in any ServiceManager GUI code.
]]

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

--[[
	@description Searches ReplicatedStorage for the Orchestrator ModuleScript.
	@return ModuleScript? -- The module if found, otherwise nil.
]]
local function getOrchestratorModule(): ModuleScript?
	local m = ReplicatedStorage:FindFirstChild("Orchestrator")
	if m and m:IsA("ModuleScript") then
		return m
	end
	return nil
end


--[[
	@description Internal helper that locates and requires the Orchestrator module.
	@return any? -- The required Orchestrator table, or nil on failure.
]]
function SidecarImpl:_getOrchestrator(): any?
	local module = getOrchestratorModule()
	if not module then return nil end
	local ok, orchestrator = pcall(require, module)
	return ok and orchestrator or nil
end

--[[
	@description Returns the Orchestrator or throws if it cannot be found.
	@return any -- The Orchestrator table.
]]
function SidecarImpl:GetOrchestrator_Unsafe(): any
	local orchestrator = self:_getOrchestrator()
	if not orchestrator then
		error("[ServiceManager.Sidecar] Orchestrator module not found/require failed")
	end
	return orchestrator
end

--[[
	@description Returns the Orchestrator module, or nil if unavailable.
	@return any? -- The Orchestrator table.
]]
function SidecarImpl:GetOrchestrator(): any?
	return self:_getOrchestrator()
end

--[[
	@description Returns the Factory instance from the Orchestrator.
	@return any? -- The Factory table, or nil if Orchestrator is unavailable.
]]
function SidecarImpl:GetFactory(): any?
	local orch = self:_getOrchestrator()
	return orch and orch.Factory or nil
end

--[[
	@description Forwards a named request to Orchestrator.Request.
	@param requestName string -- The request key (e.g. "GetSyncData").
	@param ... any -- Additional arguments passed through.
	@return any -- The result from the Orchestrator.
]]
function SidecarImpl:Request(requestName: string, ...: any): any
	local orch = self:GetOrchestrator_Unsafe()
	if type(orch.Request) ~= "function" then
		error("[ServiceManager.Sidecar] Orchestrator.Request unavailable")
	end
	return orch.Request(requestName, ...)
end

--[[
	@description Client-only helper that fetches the latest server sync payload
	via Orchestrator.Request("GetSyncData"). Returns nil on the server.
	@return any? -- Sync data table, or nil on failure / server context.
]]
function SidecarImpl:GetServerSyncData(): any?
	if not RunService:IsClient() then return nil end
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

--[[
	@description Creates an Entity via the Orchestrator factory.
	@param classOrName any -- Entity class reference or registered name string.
	@param params { EntityId: string?, Context: { [any]: any } } -- Creation parameters.
	@return any? -- The newly created entity instance.
]]
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

--[[
	@description Looks up a live entity by its ID.
	@param entityId string -- The unique entity identifier.
	@return any? -- The entity instance, or nil if not found.
]]
function SidecarImpl:GetEntity(entityId: string): any?
	local orch = self:_getOrchestrator()
	return orch and orch.GetEntity and orch.GetEntity(entityId) or nil
end

--[[
	@description Sends a command to the entity identified by entityId.
	Falls back to a RemoteEvent if Orchestrator.SendCommand is unavailable.
	@param entityId string -- Target entity identifier.
	@param command string -- The command name.
	@param ... any -- Additional command arguments.
	@return ()
]]
function SidecarImpl:SendEntityCommand(entityId: string, command: string, ...: any)
	local orch = self:_getOrchestrator()
	if orch and type((orch :: any).SendCommand) == "function" then
		(orch :: any).SendCommand(entityId, command, ...)
		return
	end
	-- Fallback to RemoteEvent used by Orchestrator
	local remote = ReplicatedStorage:FindFirstChild("EntityCommandRemote")
	if remote and remote:IsA("RemoteEvent") then
		(remote :: RemoteEvent):FireServer(entityId, command, ...)
	end
end

--[[
	@description Creates a StateMachine via the Orchestrator factory.
	@param classOrName any -- FSM class reference or registered name string.
	@param params { StateMachineId: string?, Context: { [any]: any }? } -- Creation parameters.
	@return any? -- The newly created state machine instance.
]]
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

--[[
	@description Looks up a live state machine by its ID.
	@param stateMachineId string -- The unique state machine identifier.
	@return any? -- The state machine instance, or nil if not found.
]]
function SidecarImpl:GetStateMachine(stateMachineId: string): any?
	local orch = self:_getOrchestrator()
	return orch and orch.GetStateMachine and orch.GetStateMachine(stateMachineId) or nil
end

--[[
	@description Cancels a running state machine.
	@param stateMachineId string -- The state machine to cancel.
	@return boolean -- True if cancellation succeeded.
]]
function SidecarImpl:CancelStateMachine(stateMachineId: string): boolean
	local orch = self:_getOrchestrator()
	return (orch and orch.CancelStateMachine and orch.CancelStateMachine(stateMachineId)) or false
end

--[[
	@description Retries a failed or cancelled state machine.
	@param stateMachineId string -- The state machine to retry.
	@return ()
]]
function SidecarImpl:RetryStateMachine(stateMachineId: string)
	local orch = self:_getOrchestrator()
	if orch and orch.RetryStateMachine then
		orch.RetryStateMachine(stateMachineId)
	end
end

--[[
	@description Constructs a new Sidecar instance.
	@return Sidecar -- A fresh Sidecar ready for use.
]]
local function new(): Sidecar
	return setmetatable({}, SidecarImpl) :: any
end

return {
	new = new,
}
