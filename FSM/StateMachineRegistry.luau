--!strict
-- @Name StateMachineRegistry
-- @Author iKrypto
-- @Description Registry module for storing StateMachine class definitions.
return
{
    --[[
    ["ExampleJob"] = 
    {
        className = "ExampleJob",
        validStates = { "Start", "Process", "WaitProcess", "PrepareOperation", "WaitOperation", "ValidateOperation", "Complete", "Fail" },
        terminalStates = { "Complete", "Fail" },
        initialState = "Start",
        context = {
            ExampleProperty = nil,
        }
    }
    ]]
}