return {
	Scheduler = {
		FrameBudget = 0.015 -- Frame budget
	},
	Logger = {
		DebuggingEnabled = true, -- Enable debugging
		MinimumLoggingLevel = 3, -- Minimum logging level
	},
	DataStore = {
		ResetAccessCountIntervalInSeconds = 60, -- Reset access count every minute
		DataStoreName = "EntityPersistence", -- Name of the data store
		KeyPrefix = "Entity", -- Prefix for the keys
		PersistenceEnabled = true, -- Enable persistence
	},
	FSMSettings = {
		Debug = true, -- Enable debugging for FSM
		LogLevel = 1 -- Minimum logging level for FSM
	},
	Orchestrator = {
		MaxSanitizationDepth = 8, -- Maximum depth for sanitization on tables sent to clients
	},
	StaticStrings = {
		Instance = {
			OrchestratorEventName = "OrchestratorEvent", -- Name of the orchestrator event
			OrchestratorFunctionName = "OrchestratorFunction", -- Name of the orchestrator function
			EntityUpdateEventName = "EntityUpdateEvent", -- Name of the entity update event
			EntityCommandEventName = "EntityCommandEvent", -- Name of the entity command event
			ResetDataStoreAccessCountTaskName = "ResetDataStoreAccessCount" -- Name of the task to reset data store access count
		},
		Error = {
			RemoteNotFoundErrorMessage = "CreateRemote called without a %s",
			FSMAlreadyFoundErrorMessage = "FSM already registered",
			UnresolvableConstructorErrorMessage = "%s called with nil/unresolvable %s",
			EntityRequiresInstanceErrorMessage = "Entity '%s' requires an 'Instance' in its context.",
			AlreadyExistsErrorMessage = "%s '%s' already exists. Returning existing instance.",
			InstantializationFailureErrorMessage = "Failed to instantiate %s '%s': %s",
			AttachServiceSingletonErrorMessage = "AttachServiceManager can only be called on the client",
			ServiceManagerDisabledErrorMessage = "ServiceManager is disabled in settings",
			ServiceManagerInitializationFailureErrorMessage = "Failed to initialize ServiceManager: %s",
			MissingServiceManagerChildErrorMessage = "Missing child 'ServiceManager' under Orchestrator module",
			FailedToCreateErrorMessage = "Failed to create %s '%s'.",
			AsyncRequestFailureErrorMessage = "Failed to handle async request '%s': %s",
			ServerRequestErrorMessage = "This API is inaccessible on the client.",
			ClientRequestErrorMessage = "This API is inaccessible on the server."
		},
	},
	ServiceManager = {
		Enabled = true -- Enable the service manager
	}
}