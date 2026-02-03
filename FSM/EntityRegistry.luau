--!strict
-- @Name EntityRegistry
-- @Author iKrypto
-- @Description Registry module for storing entity class definitions.
return
{
    --[[
    ["ExampleEntity"] = 
    {
        Name = "ExampleEntity",
        Schema = {
            ExampleEntityProperty = { Type = "boolean", Persist = true, Replicate = true, Description = "Boolean property description" },
            ExampleEntityProperty2  = { Type = "Color3", Replicate = true,  Description = "Color property description" },
            ExampleEntityProperty3 = { Type = "Instance", Replicate = true, Description = "Instance property description" },
            ExampleEntityProperty4 = { Type = "BasePart" },
            ExampleEntityProperty5 = { Type = "CFrame", Persist = true, Description = "CFrame property description" },
        },
    },
    ]]
}