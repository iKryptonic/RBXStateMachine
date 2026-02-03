--!strict
-- @Interface EntityFactoryInterface
-- @Description Formal interface definition for the Entity factory module.
-- This module is responsible for registering and retrieving Entity class definitions.

--[[
	@Interface EntityFactory
	@Description The static singleton used to manage Entity classes.
]]
export type EntityFactory = {
	--[[
		@Method Register
		@Description Registers a new Entity class definition under a specific name.
		This method looks for a ModuleScript in ReplicatedStorage.Entities with the matching name,
		and extends the provided class definition using BaseEntity.Extend.
		
		@Param entityName string -- The unique name of the Entity (must match a ModuleScript in ReplicatedStorage.Entities).
		@Param entityClassDefinition any -- The table definition containing the Entity's schema and logic.
		@Return void
	]]
	Register: (entityName: string, entityClassDefinition: any) -> (),

	--[[
		@Method get
		@Description Retrieves a registered Entity class by its name.
		Throws an error if the Entity has not been registered.
		
		@Param entityName string -- The name of the Entity to retrieve.
		@Param params { [any]: any }? -- (Optional) Reserved parameter for future factory overrides or configuration.
		@Return any -- The Entity class (subclass of BaseEntity).
	]]
	get: (entityName: string, params: { [any]: any }?) -> any
}

return {} :: EntityFactory