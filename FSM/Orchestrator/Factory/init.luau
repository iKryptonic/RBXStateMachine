--!strict
-- @Name Factory.lua
-- @Author iKrypto
-- @Description Generic factory for compiling and retrieving game classes.

local Types = require(script.Parent.Types)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LoadableSubclasses = {};

local function CreateConfiguration(configurationName: string)
    local folder = ReplicatedStorage:FindFirstChild(configurationName) :: Folder
    if not folder then
		return { Folder = nil, Registry = {}, Base = nil }
    end
    local registryModule = folder:FindFirstChild(folder.Name :: string .. "Registry"):: ModuleScript
    if not registryModule then
		return { Folder = folder, Registry = {}, Base = nil }
    else
        local successLoad, result = pcall(require, registryModule)
        if not successLoad or type(result) ~= "table" then
		    warn(string.format("[Factory] Failed to require '%s': %s", registryModule:GetFullName(), tostring(result)))
			return { Folder = folder, Registry = {}, Base = nil }
        end

        -- Register states
        for index, Subclass in pairs(folder:GetChildren()) do
            if Subclass:IsA("ModuleScript") and Subclass ~= registryModule then
                table.insert(LoadableSubclasses, Subclass)
            end
        end

        registryModule = result
    end

    local configurationBaseName = "Base" .. configurationName
    local configurationBase = script:FindFirstChild(configurationBaseName)
    if not configurationBase then
        warn(string.format("[Factory] Base '%s' missing in %s", configurationBaseName, script.Name))
		return { Folder = folder, Registry = registryModule, Base = nil }
    end
    
    
    return {
        Folder = folder,
		Registry = registryModule,
        Base = require(configurationBase)::any,
    }
end

-- Configuration Map
local TYPES = {
    StateMachine = CreateConfiguration("StateMachine"),
    Entity = CreateConfiguration("Entity"),
}
local CompiledClasses = {
    StateMachine = {},
    Entity = {}
};

local Factory = {};

--[[
    Retrieves a compiled class.
]]
function Factory.Get(typeName: string, name: string): any
    local category = CompiledClasses[typeName]
    if not category then error(`Type {typeName} not found`) end
    
    return category[name] or error(`{typeName} '{name}' is not registered or compiled.`)
end

--[[
    Returns the compiled classes table for a type.
    Note: the returned table is shared (do not mutate it).
]]
function Factory.GetAll(typeName: string): any
    local category = CompiledClasses[typeName]
    if not category then error(`Type {typeName} not found`) end
    return category
end

--[[
    Compiles a raw definition into a proper subclass using the base's .Extend method.
]]
local function Compile(typeName: string, name: string, classDef: any)
    local config = TYPES[typeName]
    if not config then error(`Invalid type: {typeName}`) end

	-- Optional validation (warn instead of error to support script-only usage)
	if config.Folder and not config.Folder:FindFirstChild(name) then
		warn(string.format("[Factory] Model '%s' missing in %s", name, config.Folder.Name))
	end

    -- Load the base class to register states

    return config.Base.Extend(classDef)
end

--[[
    Load all LoadableSubclasses
]]
function Factory.LoadSubclasses()
    if not next(LoadableSubclasses) then return end

    for _, Subclass in pairs(LoadableSubclasses) do
        local success, result = pcall(require, Subclass)
        if not success or type(result) ~= "table" then
            warn(string.format("[Factory] Failed to require '%s': %s", Subclass:GetFullName(), tostring(result)))
        end

        print(string.format("[Factory] Loaded subclass '%s'", Subclass.Name))
    end
    LoadableSubclasses = {};
end

-- Initialization: Process all registries
for typeName, config in pairs(TYPES) do
    if config.Base and config.Registry then
        for className, classDef in pairs(config.Registry) do
            CompiledClasses[typeName][className] = Compile(typeName, className, classDef)
        end
    end
end

if next(CompiledClasses.Entity) == nil and next(CompiledClasses.StateMachine) == nil then
    warn("[Factory] No classes compiled. Ensure ReplicatedStorage.Entities/EntityRegistry and ReplicatedStorage.StateMachines/StateMachineRegistry exist.")
else
    print("[Factory] Load sub-classes before using Factory.Get to retrieve compiled classes.")
end

return Factory