--!strict
-- @Name StateMachineRegistry (Test Fixture)
-- @Description Registry for DummyFSM used in unit/e2e tests.

return {
	DummyFSM = {
		className = "DummyFSM",
		validStates = { "Idle", "Done" },
		terminalStates = { "Done" },
		context = {},
		Priority = 1,
	},
}
