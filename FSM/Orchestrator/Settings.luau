return {
    Scheduler = {
        PerformanceManagerSettings = {
            WarnOnLongThreadExecutions = true, -- Warn if a thread takes longer than this
            MaximumThreadWarningThreshold = 12.5, -- Maximum thread warning threshold
        },
        LoggerSettings = {
            DebuggingEnabled = true, -- Enable debugging
            MinimumLoggingLevel = 3, -- Minimum logging level
        },
        FrameBudget = 0.015 -- Frame budget
    },
    DataStore = {
        ResetAccessCountIntervalInSeconds = 60, -- Reset access count every minute
        DataStoreName = "EntityPersistence", -- Name of the data store
        KeyPrefix = "Entity", -- Prefix for the keys
    },
    FSMSettings = {
        Debug = true,
        LogLevel = 1
    },
    StaticStrings = {
        ServiceManagerEventName = "ServiceManagerEvent",
        ServiceManagerRemoteName = "ServiceManagerRemote",
        EntityUpdateRemoteName = "EntityUpdateRemote",
        EntityCommandRemoteName = "EntityCommandRemote",
        ResetDataStoreAccessCountTaskName = "ResetDataStoreAccessCount"
    }
}