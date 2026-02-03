--!strict
-- @Name EntityRegistry (Test Fixture)
-- @Description Registry for DummyEntity used in unit/e2e tests.

return {
	DummyEntity = {
		Name = "DummyEntity",
		Schema = {
			Value = { Type = "number", Replicate = true },
			Label = { Type = "string", Replicate = true },
			_conn = { Type = "RBXScriptConnection" },
		},
	},
}
