--!strict
--[[
    @module BaseEntity
    @author iKrypto
    @version 3.0
    @description Abstract base Entity class for managing Roblox Instances with
    schema validation, pending/commit data model, and rollback support.
    
    Architecture:
        The entity uses a proxy pattern with closures for encapsulation.
        All authoritative state lives in the closure-captured `privateState` table.
        The proxy table is what consumers interact with; metamethods route reads
        through the lookup chain: cache → committed data → context → class → schema defaults.
        
        Writes go through schema validation and land in the Pending table.
        Call :UpdateEntity() to commit pending changes to Data (with rollback on failure).
    
    IMPORTANT: privateState is NEVER cloned onto the proxy. All access goes through
    the closure to maintain a single source of truth. External access to internal
    state is provided via typed getter methods.
    
    Usage:
        local BaseEntity = require(path.to.BaseEntity)
        BaseEntity.Initialize(Util)
        
        local DoorEntity = BaseEntity.Extend({
            Name = "Door",
            Schema = {
                IsOpen = { Type = "boolean", Default = false, Persist = true, Replicate = true },
                Health = { Type = "number", Default = 100, Validator = function(v) return v >= 0, "Must be >= 0" end },
            },
        })
        
        local door = DoorEntity.new({ Name = "FrontDoor", Instance = workspace.Door })
        door.IsOpen = true
        door:UpdateEntity()
]]

local Enums = require(script.Parent.Enums)
local ContextObject = require(script.Parent.ContextObject)

local BaseEntity = {}

local Logger, Signal, Settings
local Initialized = false

--============================================================================--
-- Module Initialization
--============================================================================--

--[[
    @description Initializes the BaseEntity module.
    @param Util FrameworkUtil
]]
function BaseEntity.Initialize(Util: any)
    if Initialized then return end
    Initialized = true
    Settings = Util.Settings
    Logger = Util.Logger
    Signal = Util.Signal

    local log = Logger.new({ Name = "BaseEntity" })
    log:Log({ Level = Enums.LogLevel.INFO, Message = "BaseEntity initialized (v3.0)" })
end

--============================================================================--
-- Helpers
--============================================================================--

--- Returns a sorted list of string keys from a table (for error messages).
local function getSchemaKeys(schema: { [string]: any }): { string }
    local keys = {}
    for k in pairs(schema) do
        table.insert(keys, tostring(k))
    end
    table.sort(keys)
    return keys
end

--============================================================================--
-- Constructor
--============================================================================--

--[[
    @description Creates a new BaseEntity instance backed by a proxy table.
    
    @param params EntityConstructorParams
    @param class any? -- Optional subclass table for method/definition lookup
    @return any -- Proxy entity instance
]]
function BaseEntity.new(
    params: {
        Name: string,
        Instance: Instance?,
        OwnerId: string?,
        Context: { [any]: any }?,
        Mutable: boolean?,
    },
    class: any?
): any
    assert(Initialized, "BaseEntity not initialized. Call BaseEntity.Initialize(Util) first.")

    -- ================================================================
    -- SINGLE SOURCE OF TRUTH: captured by closure, never cloned.
    -- ================================================================
    local privateState = {
        Name = params.Name,
        Instance = params.Instance,
        Schema = (class and class.Definition and class.Definition.Schema) or {} :: { [string]: any },
        Pending = {} :: { [string]: any },
        Data = {} :: { [string]: any },
        Context = params.Context or {} :: { [any]: any },
        OwnerId = params.OwnerId,
        Mutable = if params.Mutable ~= nil then params.Mutable else false,
        EntityLocked = false :: (string | false),
        IsValid = true,
        _cache = {} :: { [string]: any },
        _stateUpdatedEvent = Signal.new(),
        _entityDestroyedEvent = Signal.new(),
        _cleanupTasks = {} :: { any },
        _logger = Logger.new({ Name = params.Name or "BaseEntity" }),
        Version = 0,
        InstanceDestroyedConn = nil :: any?,
    }

    local proxy = {} :: any
    local schema = privateState.Schema

    -- ================================================================
    -- Metamethods
    -- ================================================================
    local mt = {
        __index = function(_self: any, key: string)
            -- 1. Pending cache (staged writes)
            local cachedValue = privateState._cache[key]
            if cachedValue ~= nil then return cachedValue end

            -- 2. Committed data
            local committedValue = privateState.Data[key]
            if committedValue ~= nil then return committedValue end

            -- 3. Context
            local contextValue = privateState.Context[key]
            if contextValue ~= nil then return contextValue end

            -- 4. Class / Base methods
            local classValue = (class and (class :: any)[key]) or BaseEntity[key]
            if classValue ~= nil then return classValue end

            -- 5. Schema defaults
            local def = schema[key]
            if def and def.Default ~= nil then
                return def.Default
            end

            return nil
        end,

        __newindex = function(_self: any, key: string, value: any)
            -- Guard: destroyed entity
            if not privateState.IsValid then
                privateState._logger:Log({
                    Level = Enums.LogLevel.WARN,
                    Message = string.format("Attempt to set '%s' on destroyed entity.", key),
                })
                return
            end

            local def = schema[key]

            -- Guard: not in schema
            if not def then
                privateState._logger:Log({
                    Level = Enums.LogLevel.WARN,
                    Message = string.format(
                        "Property '%s' not in schema. Available: %s",
                        tostring(key),
                        table.concat(getSchemaKeys(schema), ", ")
                    ),
                })
                return
            end

            -- Guard: type validation (skip for nil and "any")
            if value ~= nil and def.Type ~= "any" and typeof(value) ~= def.Type then
                if not (typeof(value) == "Instance" and (value :: Instance):IsA(def.Type)) then
                    privateState._logger:Log({
                        Level = Enums.LogLevel.WARN,
                        Message = string.format(
                            "Type mismatch for '%s': expected %s, got %s",
                            key, def.Type, typeof(value)
                        ),
                    })
                    return
                end
            end

            -- Guard: custom validator
            if def.Validator and type(def.Validator) == "function" then
                local isValid, errorMsg = def.Validator(value, _self)
                if not isValid then
                    privateState._logger:Log({
                        Level = Enums.LogLevel.WARN,
                        Message = string.format(
                            "Validation failed for '%s': %s",
                            key, errorMsg or "Unknown"
                        ),
                    })
                    return
                end
            end

            -- Guard: read-only after initial commit
            if def.ReadOnly and privateState.Data[key] ~= nil then
                privateState._logger:Log({
                    Level = Enums.LogLevel.WARN,
                    Message = string.format("Cannot modify read-only property '%s'", key),
                })
                return
            end

            -- Stage in pending + cache
            privateState.Pending[key] = value
            privateState._cache[key] = value
        end,

        __call = function(self: any, setContextFn: any)
            if setContextFn and type(setContextFn) == "function" then
                setContextFn(privateState.Context)
            end
            return self
        end,

        __tostring = function()
            local clsName = (class and class.Definition and class.Definition.Name) or "BaseEntity"
            return string.format("%s(%s)", clsName, params.Name or "Unnamed")
        end,
    }

    -- ================================================================
    -- Public event signals (directly on proxy)
    -- ================================================================
    rawset(proxy, "StateUpdated", privateState._stateUpdatedEvent)
    rawset(proxy, "Destroyed", privateState._entityDestroyedEvent)
    rawset(proxy, "Instance", params.Instance)

    -- ================================================================
    -- Typed accessor methods (replaces the broken _privateProperties clone)
    -- ================================================================

    --- Returns a shallow clone of the committed data.
    rawset(proxy, "GetRawData", function(): { [string]: any }
        return table.clone(privateState.Data)
    end)

    --- Returns a shallow clone of the pending changes.
    rawset(proxy, "GetPendingChanges", function(): { [string]: any }
        return table.clone(privateState.Pending)
    end)

    --- Returns the current version number.
    rawset(proxy, "GetVersion", function(): number
        return privateState.Version
    end)

    --- Returns whether the entity is still valid (not destroyed).
    rawset(proxy, "IsValid", function(): boolean
        return privateState.IsValid
    end)

    --- Returns the OwnerId.
    rawset(proxy, "GetOwnerId", function(): string?
        return privateState.OwnerId
    end)

    -- ================================================================
    -- Internal accessor for systems that need direct state access
    -- (Factory replication, persistence, etc.)
    -- Returns the LIVE reference — callers must not cache this.
    -- ================================================================
    rawset(proxy, "_getPrivateState", function(): any
        return privateState
    end)

    -- ================================================================
    -- Logger on proxy for method calls
    -- ================================================================
    rawset(proxy, "_logger", privateState._logger)

    -- ================================================================
    -- Auto-destroy on Instance removal
    -- ================================================================
    if params.Instance and typeof(params.Instance) == "Instance" then
        privateState.InstanceDestroyedConn = (params.Instance :: any).AncestryChanged:Connect(
            function(_: Instance, parent: Instance?)
                if not parent then
                    BaseEntity.Destroy(proxy :: any)
                end
            end
        )
    end

    setmetatable(proxy, mt)
    return proxy
end

--============================================================================--
-- Extend (Subclass Factory)
--============================================================================--

--[[
    @description Creates a BaseEntity subclass from a definition table.
    The returned class has a .new() constructor that produces proxy instances.
    
    @param extensionParams EntityDefinition
    @return any -- Subclass table
]]
function BaseEntity.Extend(extensionParams: {
    Name: string,
    Schema: { [string]: any }?,
    DefaultMutable: boolean?,
})
    local Subclass: any = {}
    Subclass.Definition = extensionParams

    setmetatable(Subclass, {
        __index = BaseEntity,
        __tostring = function()
            return extensionParams.Name or "UnnamedEntity"
        end,
    })

    --[[
        @description Creates a new instance of this subclass.
        @param params EntityConstructorParams
        @return any -- Proxy entity instance
    ]]
    function Subclass.new(params: any)
        -- Apply class-level default mutability
        if params.Mutable == nil and extensionParams.DefaultMutable ~= nil then
            params.Mutable = extensionParams.DefaultMutable
        end

        local entity = BaseEntity.new(params, Subclass)
        Subclass.Super = BaseEntity

        -- Call GetDefaultContext if implemented
        if type(Subclass.GetDefaultContext) == "function" then
            local defaults = Subclass.GetDefaultContext(entity, params)
            if defaults then
                for k, v in pairs(defaults) do
                    BaseEntity.SetContext(entity, k, v)
                end
            end
        end

        return entity
    end

    return Subclass
end

--============================================================================--
-- Instance Methods
--============================================================================--

--[[
    @description Records a log entry for this entity.
    @param params { Level: string, Message: string }
]]
function BaseEntity:Log(params: { Level: string, Message: string })
    local logger = self._logger
    if logger then
        logger:Log({
            Level = params.Level,
            Message = params.Message,
            OperationId = self:_ps().OwnerId or "",
        })
    else
        print(string.format("[%s] %s", params.Level, params.Message))
    end
end

--- Internal helper: returns the live private state from the closure.
function BaseEntity:_ps(): any
    local getter = rawget(self, "_getPrivateState")
    if getter then
        return getter()
    end
    -- Fallback for direct calls on the class table (shouldn't happen in normal use)
    return {}
end

--[[
    @description Sets the schema definition for this entity.
    @param schema EntitySchema
]]
function BaseEntity:DefineSchema(newSchema: { [string]: any })
    self:_ps().Schema = newSchema
end

--[[
    @description Stores a non-schema key/value used for internal logic.
    @param key any
    @param value any
]]
function BaseEntity:SetContext(key: any, value: any)
    self:_ps().Context[key] = value
end

--[[
    @description Retrieves a context value.
    @param key any
    @return any
]]
function BaseEntity:GetContext(key: any): any
    return self:_ps().Context[key]
end

--[[
    @description Registers a disposable object for cleanup on Destroy.
    @param object any
    @return any
]]
function BaseEntity:Manage(object: any): any
    table.insert(self:_ps()._cleanupTasks, object)
    return object
end

--[[
    @description Returns the property schema definition table.
    @return EntitySchema
]]
function BaseEntity:GetValidProperties(): { [string]: any }
    return self:_ps().Schema
end

--============================================================================--
-- Serialization
--============================================================================--

--[[
    @description Serializes the entity's persistent data (committed only).
    @return { [string]: any }
]]
function BaseEntity:Serialize(): { [string]: any }
    local ps = self:_ps()
    local data = {}

    for key, def in pairs(ps.Schema) do
        if def.Persist then
            local value = ps.Data[key]
            if value ~= nil then
                if def.Serialize and type(def.Serialize) == "function" then
                    data[key] = def.Serialize(value)
                else
                    data[key] = value
                end
            end
        end
    end

    return data
end

--[[
    @description Deserializes data into the entity with validation.
    Writes directly to committed Data (bypasses pending system).
    
    @param data { [string]: any }
    @param skipValidation boolean? -- Skip type checks (use with caution)
    @return boolean, string? -- Success flag, error description
]]
function BaseEntity:Deserialize(data: { [string]: any }, skipValidation: boolean?): (boolean, string?)
    if not data then
        return false, "No data provided to Deserialize"
    end

    local ps = self:_ps()
    local schema = ps.Schema
    local errors = {} :: { string }

    for key, value in pairs(data) do
        local def = schema[key]

        -- Only accept schema properties marked as persistent
        if not def then
            table.insert(errors, string.format("Property '%s' not in schema", key))
            continue
        end
        if not def.Persist then
            table.insert(errors, string.format("Property '%s' is not marked Persist", key))
            continue
        end

        -- Type validation
        if not skipValidation and value ~= nil and def.Type ~= "any" and typeof(value) ~= def.Type then
            if not (typeof(value) == "Instance" and (value :: Instance):IsA(def.Type)) then
                table.insert(errors, string.format(
                    "Type mismatch for '%s': expected %s, got %s",
                    key, def.Type, typeof(value)
                ))
                continue
            end
        end

        -- Custom deserializer
        local finalValue = value
        if def.Deserialize and type(def.Deserialize) == "function" then
            local ok, result = pcall(def.Deserialize, value)
            if ok then
                finalValue = result
            else
                table.insert(errors, string.format("Deserialize failed for '%s': %s", key, tostring(result)))
                continue
            end
        end

        ps.Data[key] = finalValue
    end

    if #errors > 0 then
        local msg = table.concat(errors, "; ")
        self:Log({ Level = Enums.LogLevel.WARN, Message = "Deserialize warnings: " .. msg })
        return false, msg
    end

    ps._stateUpdatedEvent:Fire(data)
    return true, nil
end

--============================================================================--
-- Update / Commit
--============================================================================--

--[[
    @description Commits pending changes to committed Data with rollback on failure.
    
    LOCKING PROTOCOL:
        - Mutable must be true
        - If locked, only the lock holder (lockingCallerId) can commit
        - Acquire lock with :AcquireLock(id), release with :ReleaseLock(id)
    
    @param lockingCallerId string? -- Must match the lock holder if locked
    @return boolean, string? -- Success flag, error/info message
]]
function BaseEntity:UpdateEntity(lockingCallerId: string?): (boolean, string?)
    local ps = self:_ps()

    -- Validation
    if not ps.IsValid then
        local msg = "Cannot UpdateEntity on destroyed entity"
        self:Log({ Level = Enums.LogLevel.ERROR, Message = msg })
        return false, msg
    end

    if not ps.Mutable then
        local msg = "Entity is not mutable. Set Mutable=true or call :SetMutable(true)"
        self:Log({ Level = Enums.LogLevel.ERROR, Message = msg })
        return false, msg
    end

    if ps.EntityLocked and ps.EntityLocked ~= lockingCallerId then
        local msg = string.format(
            "Entity locked by '%s', cannot update from '%s'",
            tostring(ps.EntityLocked),
            lockingCallerId or "unlocked caller"
        )
        self:Log({ Level = Enums.LogLevel.ERROR, Message = msg })
        return false, msg
    end

    if next(ps.Pending) == nil then
        return true, "No pending changes"
    end

    -- Snapshot pending changes
    local changes = table.clone(ps.Pending)

    -- Create rollback backup
    local backup: { [string]: any } = {}
    for propName in pairs(changes) do
        backup[propName] = ps.Data[propName]
    end

    -- Commit to authoritative Data
    for propName, propValue in pairs(changes) do
        ps.Data[propName] = propValue
    end

    -- Clear pending + cache for committed keys
    for propName in pairs(changes) do
        ps.Pending[propName] = nil
        ps._cache[propName] = nil
    end

    -- Bump version
    ps.Version += 1
    changes._v = ps.Version

    -- Fire state update
    ps._stateUpdatedEvent:Fire(changes)

    -- Apply visual/physical changes with rollback
    local success, err = xpcall(function()
        self:ApplyChanges(changes)
    end, function(e)
        return debug.traceback(tostring(e))
    end)

    if not success then
        -- ROLLBACK
        for propName, oldValue in pairs(backup) do
            ps.Data[propName] = oldValue
        end

        local errorMsg = string.format("ApplyChanges failed (rolled back): %s", tostring(err))
        self:Log({ Level = Enums.LogLevel.ERROR, Message = errorMsg })

        ps._stateUpdatedEvent:Fire({
            _rollback = true,
            _restoredValues = backup,
        })

        return false, errorMsg
    end

    return true, nil
end

--============================================================================--
-- Mutability
--============================================================================--

--[[
    @description Sets the mutability flag.
    @param mutable boolean
]]
function BaseEntity:SetMutable(mutable: boolean)
    self:_ps().Mutable = mutable
    self:Log({
        Level = Enums.LogLevel.INFO,
        Message = string.format("Mutability set to %s", tostring(mutable)),
    })
end

--[[
    @description Returns the current mutability state.
    @return boolean
]]
function BaseEntity:IsMutable(): boolean
    return self:_ps().Mutable
end

--============================================================================--
-- Locking
--============================================================================--

--[[
    @description Acquires an exclusive lock for concurrent modification control.
    @param callerId string -- Unique identifier for the lock holder
    @return boolean -- True if the lock was acquired
]]
function BaseEntity:AcquireLock(callerId: string): boolean
    if not callerId or callerId == "" then
        self:Log({ Level = Enums.LogLevel.ERROR, Message = "AcquireLock requires a non-empty callerId" })
        return false
    end

    local ps = self:_ps()
    if not ps.EntityLocked then
        ps.EntityLocked = callerId
        self:Log({ Level = Enums.LogLevel.DEBUG, Message = string.format("Lock acquired by '%s'", callerId) })
        return true
    end

    self:Log({
        Level = Enums.LogLevel.WARN,
        Message = string.format("Lock denied — held by '%s'", tostring(ps.EntityLocked)),
    })
    return false
end

--[[
    @description Releases the lock. Must be called by the current lock holder.
    @param callerId string
    @return boolean
]]
function BaseEntity:ReleaseLock(callerId: string): boolean
    local ps = self:_ps()

    if not ps.EntityLocked then
        self:Log({ Level = Enums.LogLevel.WARN, Message = "ReleaseLock called but entity is not locked" })
        return false
    end
    if ps.EntityLocked ~= callerId then
        self:Log({
            Level = Enums.LogLevel.ERROR,
            Message = string.format("ReleaseLock by '%s' denied — held by '%s'", callerId, tostring(ps.EntityLocked)),
        })
        return false
    end

    ps.EntityLocked = false
    self:Log({ Level = Enums.LogLevel.DEBUG, Message = string.format("Lock released by '%s'", callerId) })
    return true
end

--============================================================================--
-- Virtual Methods (Override in Subclasses)
--============================================================================--

--[[
    @description Applies visual/physical updates for committed changes.
    Override in subclasses to implement entity-specific update logic.
    @param changes { [string]: any }
]]
function BaseEntity:ApplyChanges(changes: { [string]: any })
    -- Base implementation: no-op
end

--[[
    @description Custom cleanup hook called before managed resources are released.
    Override in subclasses.
]]
function BaseEntity:Cleanup()
    -- Override in subclasses
end

--============================================================================--
-- Destroy
--============================================================================--

--[[
    @description Destroys the entity, cleaning up all resources and signals.
    Safe to call multiple times.
]]
function BaseEntity:Destroy()
    local ps = self:_ps()
    if not ps.IsValid then return end

    self:Log({ Level = Enums.LogLevel.INFO, Message = "Destroying entity" })

    -- Call subclass Cleanup (via metatable chain)
    local success, err = pcall(self.Cleanup, self)
    if not success then
        self:Log({ Level = Enums.LogLevel.ERROR, Message = "Cleanup error: " .. tostring(err) })
    end

    -- Execute managed cleanup tasks (LIFO)
    for i = #ps._cleanupTasks, 1, -1 do
        local cleanupTask = ps._cleanupTasks[i]
        local ok, taskErr = pcall(function()
            if typeof(cleanupTask) == "Instance" then
                cleanupTask:Destroy()
            elseif typeof(cleanupTask) == "RBXScriptConnection" then
                cleanupTask:Disconnect()
            elseif type(cleanupTask) == "function" then
                cleanupTask(self)
            elseif type(cleanupTask) == "table" and type(cleanupTask.Destroy) == "function" then
                cleanupTask:Destroy()
            end
        end)
        if not ok then
            self:Log({ Level = Enums.LogLevel.ERROR, Message = "Cleanup task error: " .. tostring(taskErr) })
        end
    end
    table.clear(ps._cleanupTasks)

    -- Fire destroyed event
    ps._entityDestroyedEvent:Fire()

    -- Mark invalid
    ps.IsValid = false

    -- Disconnect instance listener
    if ps.InstanceDestroyedConn then
        ps.InstanceDestroyedConn:Disconnect()
        ps.InstanceDestroyedConn = nil
    end

    -- Destroy signals
    ps._entityDestroyedEvent:Destroy()
    ps._stateUpdatedEvent:Destroy()
end

return BaseEntity
