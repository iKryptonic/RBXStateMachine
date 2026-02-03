--!strict
export type RetryConfig = {
	enabled: boolean?,
	retries: number?,
	baseDelay: number?,
	jitter: number?,
}

export type DataStore = {
	-- Properties
	CachingTime: number,
	RetryConfig: RetryConfig,

	-- Configuration Methods
	SetRetryConfig: (self: DataStore, config: RetryConfig?) -> (),
	EnableRetry: (self: DataStore, enabled: boolean) -> (),
	SetCachingTime: (self: DataStore, TimeInSeconds: number) -> (),
	
	-- Metadata
	GetDBName: (self: DataStore) -> string,

	-- Data Methods
	GetAsync: (self: DataStore, Key: string) -> (boolean, any, string?),
	SetAsync: (self: DataStore, Key: string, value: any) -> (boolean, nil, string?),
	UpdateAsync: (self: DataStore, Key: string, transformFunction: (any) -> any) -> (boolean, any, string?),
	IncrementAsync: (self: DataStore, Key: string, delta: number) -> (boolean, number?, string?),
	RemoveAsync: (self: DataStore, Key: string) -> (boolean, any, string?),
	
	-- OrderedDataStore Methods (Only available if orderedBool was true)
	GetSortedAsync: ((self: DataStore, ascending: boolean, pagesize: number, minValue: number?, maxValue: number?) -> (boolean, any, string?))?,
	
	OnUpdate: any,
}

export type DataStoreHandler = {
	get: (databaseName: string, scope: string?, orderedBool: boolean?) -> DataStore
}

return nil
