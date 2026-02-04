--!strict
-- @Name BaseEntity
-- @Author iKrypto
-- @Description Abstract Base Entity class for managing Roblox Instances with schema validation and logging.
if not shared.Entity then shared.Entity = {} end

local OrchestratorRoot = script.Parent.Parent
local Types = require(OrchestratorRoot.Types)

-- Allow BaseEntity to be required before Orchestrator:RegisterComponents() runs.
local Logger = shared.Logger or require(OrchestratorRoot.Logger)
local Signal = shared.Signal or require(OrchestratorRoot.Signal)
shared.Logger = shared.Logger or Logger
shared.Signal = shared.Signal or Signal

-- Use shared types
type LogLevel = Types.LogLevel
type PropertyDef = Types.PropertyDef

local BaseEntity = {}
local ActiveEntities = setmetatable({}, {__mode="k"})
shared.Entity.ActiveEntities = ActiveEntities

-- Metamethods for property syntax (fsm.State = "Name")

local function __index(proxyTable: any, key: any)
	-- Support inheritance by looking up the key in the class (metatable) 
	local mt: any = getmetatable(proxyTable)
	if mt then
		return (mt :: any)[key]
	end
	return rawget(proxyTable :: any, key)
end

local function __newindex(proxyTable: any, key: any, value: any)
	rawset(proxyTable :: any, key, value)
end

BaseEntity.__index = __index
BaseEntity.__newindex = __newindex
BaseEntity.__tostring = function(self)
	return string.format("BaseEntity(%s) %s : [%s]", self.OwnerId or "-id-", self.entityName or "-name-", ((self.IsValid==true and "Valid") or (self.IsValid==false and "Invalid")) or "-state-")
end

-- PropertyDef is now imported from Types

--[[
	@summary Creates a new BaseEntity instance.
	@param params { Name: string, Instance: Instance, OwnerId: string? }
	@param class any? -- Optional subclass table for method/definition lookup
	@return any -- BaseEntity instance (proxy)
]]
function BaseEntity.new(params: { Name: string, Instance: Instance, OwnerId: string? }, class: any?): any
	local proxy = {}
	local entityName = params.Name
	local privateProperties = {
		Instance = params.Instance :: any,
		EntityLocked = false,
		IsValid = true,
		Schema = class and class.Definition.Schema or {} :: { [string]: PropertyDef },
		Pending = {} :: { [string]: any },
		Data = {} :: { [string]: any },
		InstanceDestroyedConn = nil :: RBXScriptConnection?,
		Context = {},
		OwnerId = params.OwnerId,
		Mutable = class and class.ApplyChanges and class.ApplyChanges ~= BaseEntity.ApplyChanges,
		_stateUpdatedEvent = Signal.new(),
		_entityDestroyedEvent = Signal.new(),
		_cleanupTasks = {} :: { any },
	}

	local mt = {
		__index = function(originalTable, key)
			-- Lookup order: class methods, pending, data, context, public props, schema, instance fallback
			if class then
				local val = class[key]
				if val then return val end
			elseif BaseEntity[key] then 
				return BaseEntity[key] 
			end
			
			if key == "IsValid" then return privateProperties.IsValid end

			if privateProperties.Pending[key] ~= nil then return privateProperties.Pending[key] end

			if privateProperties.Data[key] ~= nil then return privateProperties.Data[key] end

			if privateProperties.Context[key] ~= nil then return privateProperties.Context[key] end

			if key == "Name" then return entityName end
			if key == "OwnerId" then return privateProperties.OwnerId end
			if key == "Instance" then return privateProperties.Instance end

			local isDefinedKey = privateProperties.Schema[key]
			if not isDefinedKey then
				-- Optional: Warn on strict access, or return nil
				return nil
			end	

			if not privateProperties.IsValid then
				originalTable:Log({ Level = "WARN", Message = string.format("[Entity] Attempt to access destroyed entity property '%s'.", key) })
				return nil
			end

			local success, val = pcall(function()
				return (privateProperties.Instance :: any)[key]
			end)
			if success then return val end

			return nil
		end,
		__newindex = function(originalTable, key, value)
			local def = privateProperties.Schema[key]
			if not def then
				-- Prevent the entity from being "mutated" unless ApplyChanges is explicitly overridden
				if key == "ApplyChanges" then
					if privateProperties.Mutable then
						originalTable:Log
						{ 
							Level = "WARN", 
							Message = string.format("[Entity] Cannot override method '%s' after ApplyChanges has been called.", key) 
						}
						return
					end

					-- Allow ApplyChanges override
					privateProperties.Mutable = true
					rawset(originalTable, key, value)
					originalTable:Log
					{ 
						Level = "INFO", 
						Message = string.format("[Entity] Method '%s' set as mutable.", key) 
					}
					return
				end

				originalTable:Log
				{ 
					Level = "WARN", 
					Message = string.format("[Entity] Cannot set property '%s' as it does not exist in the Schema.", tostring(key)) 
				}
				return
			end

			if not privateProperties.IsValid then
				originalTable:Log
				{ 
					Level = "WARN", 
					Message = string.format("[Entity] Attempt to modify destroyed entity property '%s'.", key) 
				}
				return
			end

			local typeMatches = typeof(value) == def.Type
			if not typeMatches and typeof(value) == "Instance" then
				-- Allow ClassName matching (e.g. Type="Part" for a Part instance)
				local success, isA = pcall(value.IsA, value, def.Type)
				if success and isA then typeMatches = true end
			end

			if not typeMatches then
				originalTable:Log
				{ 
					Level = "WARN", 
					Message = string.format("[Entity] Type Mismatch for '%s'. Expected %s, got %s", key, def.Type, typeof(value)) 
				}
				return
			end
			privateProperties.Pending[key] = value
		end,
		-- Set context via function call syntax: entity({ Key = Value })
		__call = function(self, entityContextTable)
			if entityContextTable and typeof(entityContextTable) == "table" then
				for key, value in pairs(entityContextTable) do
					rawset(privateProperties.Context, key, value)
				end
			end
			return entityContextTable
		end,
		__tostring = function()
			local clsName = (class and class.Definition and class.Definition.Name) or "BaseEntity"
			return string.format("%s(%s)", clsName, entityName or "Unnamed")
		end,
	}

	proxy.StateUpdated = privateProperties._stateUpdatedEvent
	proxy.Destroyed = privateProperties._entityDestroyedEvent

	proxy.Instance = params.Instance
	proxy._privateProperties = privateProperties
	proxy._logger = Logger.new
	{ 
		Name = entityName or "BaseEntity" 
	}

	if params.Instance and (params.Instance :: any).AncestryChanged then
		privateProperties.InstanceDestroyedConn = (params.Instance :: any).AncestryChanged:Connect(function(_, parent)
			if not parent then BaseEntity.Destroy(proxy::any) end
		end)
	end

	ActiveEntities[proxy::any] = true
	return setmetatable(proxy, mt)
end

--[[
	@summary Creates a BaseEntity subclass (class table) from a definition.
	@param extensionParams { Name: string, Schema: { [string]: any }? }
	@return any -- Subclass (class table) with a .new constructor
]]
function BaseEntity.Extend(extensionParams: { Name: string, Schema: { [string]: any }? })
	-- This is the Class Table (where methods like MyEntity:Method() will live)
	local Subclass: any = {}
	local SubclassAny: any = Subclass
	Subclass.Definition = extensionParams
	local subclassMetaTable = {}

	subclassMetaTable.__index = BaseEntity
	subclassMetaTable.__newindex = BaseEntity.__newindex
	subclassMetaTable.__tostring = function()
		return Subclass.Definition.Name or "UnnamedEntity"
	end;
	setmetatable(Subclass, subclassMetaTable)

	--[[
		@summary Creates a new instance of this subclass Entity.
		@param params { Name: string, Instance: Instance, OwnerId: string?, [any]: any }
		@return any -- BaseEntity instance (proxy)
	]]
	function SubclassAny.new(params)
		local subclassEntity = BaseEntity.new(params, SubclassAny);
		SubclassAny.Super = subclassEntity

		local genericGetContextMethod = SubclassAny.GetContext
		if type(genericGetContextMethod) ~= "function" then
			BaseEntity:Log
			{ 
				Level = "WARN", 
				Message = string.format("Subclass '%s' did not implement 'GetContext'. No context set.", subclassEntity.entityName or "UnnamedEntity"),
			}
		end;

		-- Allow GetContext(self, params) to initialize cached parts, default state, etc.
		local EntityContext = (type(genericGetContextMethod) == "function" and genericGetContextMethod(subclassEntity, params)) or nil

		if EntityContext then
			for contextKey, contextValue in pairs(EntityContext) do
				subclassEntity:SetContext(contextKey, contextValue)
			end
		end

		return subclassEntity;
	end

	return Subclass
end

--[[
	@summary Records a log entry for this Entity.
	@param params { Level: Logger.LogLevel, Message: string }
	@return ()
]]
function BaseEntity:Log(params: { Level: LogLevel, Message: string })
	if not self._logger then
		print(params.Message, params.Level)
		return
	end
	self._logger:Log{
		Level = params.Level,
		Message = params.Message,
		OperationId = self._privateProperties and self._privateProperties.OwnerId or ""
	}
end

--[[
	@summary Sets the schema definition for the entity.
	@param schema { [string]: PropertyDef }
	@return ()
]]
function BaseEntity:DefineSchema(schema: { [string]: PropertyDef })
	self._privateProperties.Schema = schema
end

--[[
	@summary Stores non-schema data used for internal logic.
	@param key any
	@param value any
	@return ()
]]
function BaseEntity:SetContext(key: any, value: any)
	self._privateProperties.Context[key] = value
end

--[[
	@summary Registers a disposable object for cleanup when the Entity is destroyed.
	@param object any
	@return any
]]
function BaseEntity:Manage(object: any)
	table.insert(self._privateProperties._cleanupTasks, object)
	return object
end

--[[
	@summary Serializes the entity's persistent data.
	@return { [string]: any }
]]
function BaseEntity:Serialize()
	local data = {}
	local schema = self._privateProperties.Schema
	
	for key, def in pairs(schema) do
		if def.Persist then
			local value = self[key]
			if value ~= nil then
				data[key] = value
			end
		end
	end
	
	return data
end

--[[
	@summary Deserializes data into the entity.
	@param data { [string]: any }
	@return ()
]]
function BaseEntity:Deserialize(data: { [string]: any })
	if not data then return end
	
	for key, value in pairs(data) do
		-- We rely on __newindex for validation
		-- Only load if it's in the schema and marked as persistent
		local def = self._privateProperties.Schema[key]
		if def and def.Persist then
			self[key] = value
		end
	end
end

--[[
	@summary Commits pending changes to the entity's state and visual representation.
	@param lockingCallerId string -- Caller id that must hold the entity lock (pass the same id used in AcquireLock)
	@return boolean -- True if changes were applied successfully
]]
function BaseEntity:UpdateEntity(lockingCallerId: string?)
	local privateProperties = self._privateProperties
	local fastFailReason = ""
	if not privateProperties.IsValid then
		fastFailReason ..= "Attempt to call UpdateEntity on destroyed entity. "
	end
	if lockingCallerId ~= nil and privateProperties.EntityLocked ~= lockingCallerId then
		fastFailReason ..= "Attempt to call UpdateEntity without holding the lock. "
	end
	if next(privateProperties.Pending) == nil then
		fastFailReason ..= "No pending changes to apply in UpdateEntity. "
	end
	if not privateProperties.Mutable then
		fastFailReason ..= "Attempt to call UpdateEntity on immutable entity without ApplyChanges override. "
	end
	if fastFailReason ~= "" then
		self:Log({ Level = "ERROR", Message = "UpdateEntity failed: " .. fastFailReason })
		return false
	end

	-- Snapshot pending changes so ApplyChanges receives stable data. Do NOT alias
	-- the Pending table itself; it may be cleared/reset during this call.
	local changes: { [string]: any } = table.clone(privateProperties.Pending)

	-- Commit changes to authoritative Data first. Visual updates are best-effort.
	for propertyName, propertyValue in pairs(changes) do
		privateProperties.Data[propertyName] = propertyValue
	end
	table.clear(privateProperties.Pending)
	privateProperties._stateUpdatedEvent:Fire(changes)

	-- Apply Changes (Visual/Instance updates)
	local success, err = xpcall(function()
		self:ApplyChanges(changes)
	end, function(e) return debug.traceback(tostring(e)) end)
	if not success then
		self:Log({ Level = "ERROR", Message = string.format("ApplyChanges failed: %s", tostring(err)) })
	end
	return success
end

--[[
	@summary Applies visual/physical updates for pending changes.
	@param changes { [string]: any }
	@return ()
]]
function BaseEntity:ApplyChanges(changes: { [string]: any })
	self:Log
	{ 
		Level = "WARN", 
		Message = "Abstract Method 'ApplyChanges' called with changes: " .. tostring(changes) 
	}
	self:Log
	{ 
		Level = "WARN", 
		Message = "Subclasses must implement 'ApplyChanges' to handle property updates." 
	}
end

--[[
	@summary Performs cleanup tasks before destruction.
	@return ()
]]
function BaseEntity:OnCleanup()
	-- Override in subclasses if needed
	self:Log
	{ 
		Level = "WARN", 
		Message = "Abstract Method 'OnCleanup' called."
	}
	self:Log
	{ 
		Level = "WARN", 
		Message = "Subclasses must implement 'OnCleanup' to handle cleanup tasks."
	}
end

--[[
	@summary Retrieves the property schema definition.
	@return { [string]: PropertyDef }
]]
function BaseEntity:GetValidProperties()
	return self._privateProperties.Schema
end

--[[
	@summary Attempts to acquire a lock for the entity.
	@param callerId string
	@return boolean -- True if lock was acquired successfully
]]
function BaseEntity:AcquireLock(callerId: string)
	if not callerId then
		self:Log
		{ 
			Level = "ERROR", 
			Message = "AcquireLock called without callerId." 
		}
		return false
	end;

	if not self._privateProperties.EntityLocked then
		self._privateProperties.EntityLocked = callerId
		return true
	end
	return false
end

--[[
	@summary Releases the acquired lock.
	@param callerId string
	@return boolean -- True if lock was released successfully
]]
function BaseEntity:ReleaseLock(callerId: string)
	if self._privateProperties.EntityLocked then
		if self._privateProperties.EntityLocked ~= callerId then
			self:Log
			{ 
				Level = "ERROR", 
				Message = "ReleaseLock called by non-owner." 
			}
			return false
		end

		self._privateProperties.EntityLocked = nil
		return true
	end
	return false
end

--[[
	@summary Cleans up the entity and disconnects listeners.
	@return ()
]]
function BaseEntity:Destroy()
	local privateProperties = self._privateProperties
	if not privateProperties.IsValid then return end

	for _, task in ipairs(privateProperties._cleanupTasks) do
		if typeof(task) == "Instance" then task:Destroy()
		elseif typeof(task) == "RBXScriptConnection" then task:Disconnect()
		elseif type(task) == "function" then task()
		elseif type(task) == "table" and task.Destroy then task:Destroy()
		end
	end
	privateProperties._cleanupTasks = {}

	self:OnCleanup() -- Call subclass cleanup
	privateProperties._entityDestroyedEvent:Fire()
	privateProperties.IsValid = false
	ActiveEntities[self] = nil
	if privateProperties.InstanceDestroyedConn then privateProperties.InstanceDestroyedConn:Disconnect() end
	if privateProperties._entityDestroyedEvent then privateProperties._entityDestroyedEvent:Destroy() end
	if privateProperties._stateUpdatedEvent then privateProperties._stateUpdatedEvent:Destroy() end
end

return BaseEntity