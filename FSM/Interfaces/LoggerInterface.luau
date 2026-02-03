--!strict
-- @Interface LoggerInterface
-- @Description Formal interface definition for the Logger utility class.
-- This file serves as documentation and type definition for the Logger module.

export type LogLevel = "INFO" | "WARN" | "ERROR" | "DEBUG"

--[[
	@Type LogEntry
	@Description Represents a single record in the logger's history.
	@Field Timestamp number -- The os.time() when the log occurred.
	@Field OperationId string? -- Optional unique identifier for the operation context (e.g., a RequestId).
	@Field Level LogLevel -- The severity level of the log.
	@Field Message string -- The main log content.
	@Field Data any? -- Optional metadata or data structure attached to the log.
]]
export type LogEntry = {
	Timestamp: number,
	OperationId: string?,
	Level: LogLevel,
	Message: string,
	Data: any?
}

--[[
	@Interface LoggerInstance
	@Description Represents an instantiated Logger object.
]]
export type LoggerInstance = {
	--[[
		@Property Source
		@Description The name of the source (script or module) this logger is attached to.
	]]
	Source: string,

	--[[
		@Property Enabled
		@Description Controls whether the logger outputs to the console. Defaults to true.
	]]
	Enabled: boolean,

	--[[
		@Property History
		@Description Internal storage of recent log entries.
	]]
	History: {LogEntry},

	--[[
		@Method Log
		@Description Logs a message with a specific severity level, optional operation ID, and attached data.
		@Param params {
			Level: LogLevel -- The severity ("INFO", "WARN", "ERROR", "DEBUG").
			Message: string -- The text to log.
			OperationId: string? -- (Optional) A correlation ID to trace logs across systems.
			Data: any? -- (Optional) A table or value to store with the log entry for debugging.
		}
		@Return void
	]]
	Log: (self: LoggerInstance, params: { Level: LogLevel, Message: string, OperationId: string?, Data: any? }) -> (),

	--[[
		@Method GetHistory
		@Description Retrieves the list of recent log entries stored in memory.
		@Return {LogEntry} -- Array of LogEntry objects.
	]]
	GetHistory: (self: LoggerInstance) -> {LogEntry}
}

--[[
	@Interface LoggerStatic
	@Description Static interface for the Logger module constructor.
]]
export type LoggerStatic = {
	--[[
		@Method new
		@Description Creates a new Logger instance.
		@Param params {
			Name: string? -- (Optional) The name of the logger source. If omitted, attempts to detect the calling script's name.
		}
		@Return LoggerInstance -- The initialized Logger.
	]]
	new: (params: { Name: string? }) -> LoggerInstance
}

return {} :: LoggerStatic