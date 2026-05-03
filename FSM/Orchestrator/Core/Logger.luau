--!strict
--[=[
	@module Logger
	@description Defines the `Logger` module and its exported API.
]=]

local Logger = {}
Logger.__index = Logger

-- Use shared types
type LogEntry = {
	Timestamp: number,
	OperationId: string?,
	Level: string,
	Message: string,
	Data: any?
}

-- Configuration
local SHOW_TIMESTAMP = true
local USE_RICH_TEXT = false
local MAX_LOG_HISTORY = 50
local MAX_SUMMARY_HISTORY = 200 -- compressed summaries for long-term analysis

local Initialized, Settings = false, nil
--[=[
	@description Handles `Initialize` for `Logger`.
	@param Util any -- `Util` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Logger.Initialize(Util)
	if Initialized then return end
	Initialized = true
	Settings = Util.Settings.Logger
end

local function ValidateRequest()
	assert(Initialized, "Logger not initialized")
	assert(type(Settings) == "table", "Logger not initialized")
	assert(type(Settings.DebuggingEnabled) == "boolean", "Logger not initialized")
	assert(type(Settings.MinimumLoggingLevel) == "number", "Logger not initialized")
end
--[=[
	@description Implements `Logger.new`.
	@param params { Name: string? } -- `params` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Logger.new(params: { Name: string? })
	local self = setmetatable({}, Logger)
	local sourceName = params and params.Name

	if not sourceName then
		-- Attempt to automatically detect the calling script's name
		local source = debug.info(2, "s")
		-- Parse the script name from the path (e.g. "game.ServerScriptService.Manager" -> "Manager")
		sourceName = source and string.match(source, "([^%.]+)$") or source
	end

	self.Source = sourceName
	self.History = {} :: {LogEntry}
	return self
end
--[=[
	@description Implements `Logger.Log`.
	@param params { Level: string, Message: string, OperationId: string?, Data: any? } -- `params` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Logger:Log(params: { Level: string, Message: string, OperationId: string?, Data: any? })
	ValidateRequest()

	local level = params.Level or "INFO"
	local message = params.Message or ""
	local operationId = params.OperationId

	-- Store in History (full entries, recent)
	local entry: LogEntry = {
		Timestamp = os.time(),
		OperationId = operationId,
		Level = level,
		Message = message,
		Data = params.Data
	}
	table.insert(self.History, entry)
	if #self.History > MAX_LOG_HISTORY then
		-- Compress evicted entry into summary ring (level + short message, no Data)
		local evicted = table.remove(self.History, 1)
		if not self.Summary then self.Summary = {} end
		local shortMsg = if #evicted.Message > 60
			then string.sub(evicted.Message, 1, 57) .. "..."
			else evicted.Message
		table.insert(self.Summary, string.format("[%s] %s %s", evicted.Level, os.date("%H:%M:%S", evicted.Timestamp), shortMsg))
		if #self.Summary > MAX_SUMMARY_HISTORY then
			table.remove(self.Summary, 1)
		end
	end

	-- Format Timestamp
	local timeStr = SHOW_TIMESTAMP and string.format("[%s] ", os.date("%H:%M:%S")) or ""

	-- Format Header based on Level
	local header = ""
	local color = ""

	if level == "INFO" then
		header = "[INFO]"
		color = "rgb(100, 200, 255)"
	elseif level == "WARN" then
		header = "[WARN]"
		color = "rgb(255, 170, 0)"
	elseif level == "ERROR" then
		header = "[ERROR]"
		color = "rgb(255, 80, 80)"
	elseif level == "DEBUG" then
		header = "[DEBUG]"
		color = "rgb(180, 180, 180)"
	else
		header = string.format("[UNKNOWN (%s)]", level)
		color = "rgb(200, 200, 200)"
	end

	-- Construct Message
	local opIdStr = operationId~=nil and typeof(operationId)=="string" and string.format(" (%s)", operationId) or ""
	local finalMsg = string.format("%s%s [%s]%s %s", timeStr, header, self.Source, opIdStr, message)

	-- Print

	if not Settings.DebuggingEnabled then return end
	if level == "DEBUG" and Settings.MinimumLoggingLevel < 4 then return end
	if level == "INFO" and Settings.MinimumLoggingLevel < 3 then return end
	if level == "WARN" and Settings.MinimumLoggingLevel < 2 then return end
	if level == "ERROR" and Settings.MinimumLoggingLevel < 1 then return end

	if USE_RICH_TEXT and level ~= "WARN" and level ~= "ERROR" then
		print(string.format('<font color="%s">%s</font>', color, finalMsg))
	elseif level == "WARN" then
		warn(finalMsg)
	elseif level == "ERROR" then
		warn(finalMsg) -- Roblox errors stop execution, so warn the log error
	else
		print(finalMsg)
	end
end
--[=[
	@description Updates module state through `Logger.SetMinimumLoggingLevel`.
	@param level number -- `level` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Logger:SetMinimumLoggingLevel(level: number)
	Settings.MinimumLoggingLevel = level
end
--[=[
	@description Returns the data produced by `Logger.GetHistory`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function Logger:GetHistory()
	return self.History
end

return Logger