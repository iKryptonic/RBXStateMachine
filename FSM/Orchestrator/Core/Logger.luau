--!strict


--[=[
	@module Logger
	@description Structured logger with per-instance message history, level-based filtering, and optional RichText formatting. Module-level `Settings` are shared across all instances and must be seeded via `Logger.Initialize` before use.
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
	@description One-time initialization that reads `Util.Settings.Logger` into the module-level `Settings` table and sets the `Initialized` guard. Silently no-ops on subsequent calls. Must be called before `Logger.new` or any log operation.
	@param Util table -- Shared utility table; `Util.Settings.Logger` must contain `DebuggingEnabled: boolean` and `MinimumLoggingLevel: number`.
	@writes Initialized, Settings
]=]

function Logger.Initialize(Util)
	if Initialized then return end
	Initialized = true
	Settings = Util.Settings.Logger
end

local function ValidateRequest()
	assert(Initialized,"Logger not initialized")
	assert(type(Settings) == "table","Logger not initialized")
	assert(type(Settings.DebuggingEnabled) == "boolean","Logger not initialized")
	assert(type(Settings.MinimumLoggingLevel) == "number","Logger not initialized")
end


--[=[
	@description Creates a new Logger instance with an empty `History` ring and an optional source name label. When `params.Name` is absent the constructor auto-detects the calling script's short name via `debug.info(2, "s")` and strips the leading dot-path prefix.
	@param params { Name: string? } -- Optional table; `Name` becomes `self.Source` and appears in every formatted log line.
	@return Logger -- New Logger instance with `Source` and `History` initialised.
]=]

function Logger.new(params: { Name: string? })
	local self = setmetatable({}, Logger)
	local sourceName = params and params.Name

	if not sourceName then
		-- Attempt to automatically detect the calling script's name
		local source = debug.info(2,"s")
		-- Parse the script name from the path (e.g. "game.ServerScriptService.Manager" -> "Manager")
		sourceName = source and string.match(source,"([^%.]+)$") or source
	end

	self.Source = sourceName
	self.History = {} :: {LogEntry}
	return self
end


--[=[
	@description Appends a `LogEntry` to `self.History`, evicting the oldest entry into a compressed `self.Summary` ring when the history exceeds `MAX_LOG_HISTORY` (50). Skips output when `Settings.DebuggingEnabled` is false or the level falls below `Settings.MinimumLoggingLevel`. WARN and ERROR levels route through `warn()`; INFO/DEBUG use `print()`, optionally wrapped in a RichText color tag when `USE_RICH_TEXT` is true.
	@param params { Level: string, Message: string, OperationId: string?, Data: any? } -- `Level` must be one of `"INFO"`, `"WARN"`, `"ERROR"`, or `"DEBUG"`.
	@reads Settings.DebuggingEnabled, Settings.MinimumLoggingLevel
	@writes self.History, self.Summary
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
			then string.sub(evicted.Message, 1, 57) .."..."
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
	local opIdStr = operationId ~= nil and typeof(operationId) == "string" and string.format(" (%s)", operationId) or ""
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
	@description Overrides the shared logger threshold used by every `Logger:Log` call after initialization. Lower values allow more severe logs only, while higher values enable increasingly verbose output such as debug messages.
	@param level number -- Minimum logging level written into `Settings.MinimumLoggingLevel` for subsequent log filtering.
	@writes Settings.MinimumLoggingLevel
]=]

function Logger:SetMinimumLoggingLevel(level: number)
	Settings.MinimumLoggingLevel = level
end


--[=[
	@description Returns the instance's in-memory `History` array containing up to `MAX_LOG_HISTORY` (50) recent `LogEntry` objects, each with `Timestamp`, `Level`, `Message`, `OperationId?`, and `Data?` fields. Older entries are compressed into `self.Summary` and are not included.
	@return { LogEntry } -- Direct reference to the live history array.
	@reads self.History
]=]

function Logger:GetHistory()
	return self.History
end

return Logger
