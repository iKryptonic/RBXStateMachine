--!strict
-- @Name EntityRegistry
-- @Author iKrypto
-- @Description Registry module for storing entity class definitions.
return
{
    ["DoorEntity"] = 
    {
        Name = "DoorEntity",
        Schema = {
            IsOpen = { Type = "boolean", Replicate = true, Description = "True = Open, False = Closed" },
            Locked = { Type = "boolean", Replicate = true, Description = "Part is locked" },
            Color  = { Type = "Color3", Replicate = true,  Description = "Status light color" },
            _lockUI = { Type = "Instance" },
            _hinge = { Type = "BasePart" },
            _door = { Type = "BasePart" },
            _closedCFrame = { Type = "CFrame" },
            _statusLight = { Type = "BasePart" },
        },
    },
}