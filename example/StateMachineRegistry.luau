--!strict
-- @Name StateMachineRegistry
-- @Author iKrypto
-- @Description Registry module for storing StateMachine class definitions.
return
{
    ["DoorJob"] = 
    {
        className = "DoorJob",
        validStates = { "Validate", "CreatingMessage", "Opening", "Closing", "Completed", "Failed" },
        terminalStates = { "Completed" },
        context = {
            DesiredState = nil,
            DoorEntity = nil,
            IsSealedForcefield = false,
        }
    }
}