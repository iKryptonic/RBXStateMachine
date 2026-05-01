--!strict
--[[
    @module NetworkManager
    @author iKrypto
    @version 3.0
    @description Handles network communications (Remotes) for the framework.
    Manages orchestrator events, entity commands, event buses, and invocation stats.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(script.Parent.Enums)

local Signal: any = nil
local Initialized = false

local NetworkManager = {
    _initialized = false,

    OrchestratorEvent = nil :: RemoteEvent?,
    OrchestratorFunction = nil :: RemoteFunction?,
    EntityUpdateEvent = nil :: RemoteEvent?,
    EntityCommandEvent = nil :: RemoteEvent?,

    ServerRequestCallbacksSync = {} :: { [string]: (Player, ...any) -> any },
    ServerRequestCallbacksAsync = {} :: { [string]: (Player, ...any) -> any },
    EntityCommandCallbacks = {} :: { [string]: { [string]: (Player?, ...any) -> () } },
    EventBuses = {} :: { [string]: any },

    _invokeStats = {} :: { [string]: { Count: number, LastInvoked: number } },
    _busStats = {} :: { [string]: { Count: number, LastFired: number } },
    Logger = nil :: any,
    EventBusRegistered = nil :: any,
}

local function ValidateRequest(context: string?)
    assert(Initialized, "NetworkManager not initialized")
    if context then
        if context == "Server" then
            assert(RunService:IsServer(), "Cannot make server call from client")
        elseif context == "Client" then
            assert(RunService:IsClient(), "Cannot make client call from server")
        end
    end
end

local function CreateRemote(name: string, className: string): any
    if RunService:IsClient() then
        return ReplicatedStorage:WaitForChild(name)
    end
    local existing = ReplicatedStorage:FindFirstChild(name)
    if existing and existing:IsA(className) then return existing end
    local remote = Instance.new(className)
    remote.Name = name
    remote.Parent = ReplicatedStorage
    return remote
end

function NetworkManager.Log(params: { Level: string, Message: string, OperationId: string? })
    if NetworkManager.Logger then
        NetworkManager.Logger:Log(params)
    end
end

function NetworkManager.Initialize(Util: any)
    if Initialized then return end
    Initialized = true

    NetworkManager.Logger = Util.Logger.new({ Name = "NetworkManager" })
    Signal = Util.Signal

    local Strings = Util.Settings.StaticStrings
    NetworkManager.OrchestratorEvent = CreateRemote(Strings.Instance.OrchestratorEventName, "RemoteEvent")
    NetworkManager.OrchestratorFunction = CreateRemote(Strings.Instance.OrchestratorFunctionName, "RemoteFunction")
    NetworkManager.EntityUpdateEvent = CreateRemote(Strings.Instance.EntityUpdateEventName, "RemoteEvent")
    NetworkManager.EntityCommandEvent = CreateRemote(Strings.Instance.EntityCommandEventName, "RemoteEvent")
    NetworkManager.EventBusRegistered = Signal.new()

    if RunService:IsServer() then
        NetworkManager._RegisterServerListeners()
    else
        NetworkManager._RegisterClientListeners()
    end

    NetworkManager.Log({ Level = Enums.LogLevel.INFO, Message = "NetworkManager initialized (v3.0)" })
end

function NetworkManager.RegisterServerRequest(name: string, handler: (Player, ...any) -> any, isAsync: boolean?)
    ValidateRequest("Server")
    if isAsync then
        NetworkManager.ServerRequestCallbacksAsync[name] = handler
    else
        NetworkManager.ServerRequestCallbacksSync[name] = handler
    end
end

function NetworkManager.RegisterEntityCommand(entityId: string, command: string, handler: (Player?, ...any) -> ())
    ValidateRequest()
    if not NetworkManager.EntityCommandCallbacks[entityId] then
        NetworkManager.EntityCommandCallbacks[entityId] = {}
    end
    NetworkManager.EntityCommandCallbacks[entityId][command] = handler
end

function NetworkManager.UnregisterEntityCommands(entityId: string)
    ValidateRequest("Server")
    NetworkManager.EntityCommandCallbacks[entityId] = nil
end

function NetworkManager.ServerCommandEntity(entityId: string, command: string, ...: any)
    ValidateRequest("Client")
    if NetworkManager.EntityCommandEvent then
        NetworkManager.EntityCommandEvent:FireServer(entityId, command, ...)
    end
end

function NetworkManager.BroadcastEntityCommand(entityId: string, command: string, ...: any)
    ValidateRequest("Server")
    if NetworkManager.EntityCommandEvent then
        NetworkManager.EntityCommandEvent:FireAllClients(entityId, command, ...)
    end
end

function NetworkManager.BroadcastEntityUpdate(entityId: string, changes: { [string]: any })
    ValidateRequest("Server")
    if NetworkManager.EntityUpdateEvent then
        NetworkManager.EntityUpdateEvent:FireAllClients(entityId, changes)
    end
end

function NetworkManager.ServerRequest(requestName: string, ...: any): any
    ValidateRequest("Client")
    if NetworkManager.OrchestratorFunction then
        return NetworkManager.OrchestratorFunction:InvokeServer("AppRequestSync", requestName, ...)
    end
    return nil
end

function NetworkManager.ServerRequestAsync(requestName: string, ...: any)
    ValidateRequest("Client")
    if NetworkManager.OrchestratorEvent then
        NetworkManager.OrchestratorEvent:FireServer("AppRequestAsync", requestName, ...)
    end
end

function NetworkManager.RegisterEventBus(name: string): any
    ValidateRequest()
    if not NetworkManager.EventBuses[name] then
        NetworkManager.EventBuses[name] = Signal.new()
        NetworkManager.EventBusRegistered:Fire(name)
    end
    return NetworkManager.EventBuses[name]
end

function NetworkManager.UnregisterEventBus(name: string)
    ValidateRequest()
    local bus = NetworkManager.EventBuses[name]
    if bus and bus.Destroy then bus:Destroy() end
    NetworkManager.EventBuses[name] = nil
end

function NetworkManager.GetEventBus(name: string): any?
    ValidateRequest()
    return NetworkManager.EventBuses[name]
end

function NetworkManager.FireEventBus(name: string, ...: any)
    ValidateRequest()
    local bus = NetworkManager.EventBuses[name]
    if bus then
        local stats = NetworkManager._busStats[name]
        if not stats then
            stats = { Count = 0, LastFired = 0 }
            NetworkManager._busStats[name] = stats
        end
        stats.Count += 1
        stats.LastFired = os.clock()
        bus:Fire(...)
    end
end

function NetworkManager.AwaitEventBus(name: string, timeout: number?): any?
    ValidateRequest()
    local start = os.clock()
    while not NetworkManager.EventBuses[name] do
        if timeout and (os.clock() - start >= timeout) then return nil end
        task.wait(0.1)
    end
    return NetworkManager.EventBuses[name]
end

-- Private listeners

function NetworkManager._RegisterServerListeners()
    local function HandleAppRequest(player: Player, requestType: string, ...: any): any
        local requestName = select(1, ...)
        if type(requestName) ~= "string" or requestName == "" then return nil end

        local handler
        if requestType == "AppRequestSync" then
            handler = NetworkManager.ServerRequestCallbacksSync[requestName]
        elseif requestType == "AppRequestAsync" then
            handler = NetworkManager.ServerRequestCallbacksAsync[requestName]
        end

        if handler then
            local key = requestName
            local stats = NetworkManager._invokeStats[key]
            if not stats then
                stats = { Count = 0, LastInvoked = 0 }
                NetworkManager._invokeStats[key] = stats
            end
            stats.Count += 1
            stats.LastInvoked = os.clock()

            local ok, result = pcall(handler, player, select(2, ...))
            if not ok then
                NetworkManager.Log({
                    Level = Enums.LogLevel.ERROR,
                    Message = string.format("Request '%s' failed: %s", requestName, tostring(result)),
                })
            end
            return ok and result or nil
        end
        return nil
    end

    if NetworkManager.OrchestratorFunction then
        NetworkManager.OrchestratorFunction.OnServerInvoke = HandleAppRequest
    end
    if NetworkManager.OrchestratorEvent then
        NetworkManager.OrchestratorEvent.OnServerEvent:Connect(HandleAppRequest)
    end
    if NetworkManager.EntityCommandEvent then
        NetworkManager.EntityCommandEvent.OnServerEvent:Connect(function(player, entityId, command, ...)
            local handlers = NetworkManager.EntityCommandCallbacks[entityId]
            if handlers and handlers[command] then
                local key = entityId .. ":" .. command
                local stats = NetworkManager._invokeStats[key]
                if not stats then
                    stats = { Count = 0, LastInvoked = 0 }
                    NetworkManager._invokeStats[key] = stats
                end
                stats.Count += 1
                stats.LastInvoked = os.clock()
                handlers[command](player, ...)
            end
        end)
    end
end

function NetworkManager._RegisterClientListeners()
    if NetworkManager.EntityCommandEvent then
        NetworkManager.EntityCommandEvent.OnClientEvent:Connect(function(entityId, command, ...)
            local handlers = NetworkManager.EntityCommandCallbacks[entityId]
            if handlers and handlers[command] then
                handlers[command](nil, ...)
            end
        end)
    end
end

return NetworkManager
