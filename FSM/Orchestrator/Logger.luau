--!strict
-- @Name Logger
-- @Author iKrypto
-- @Description Standardized logging utility with history and rich text support.

local Types = require(script.Parent.Types)
local Logger = {}
Logger.__index = Logger

-- Use shared types
type LogLevel = Types.LogLevel
type LogEntry = {
	Timestamp: number,
	OperationId: string?,
	Level: LogLevel,
	Message: string,
	Data: any?
}

-- Configuration
local SHOW_TIMESTAMP = true
local USE_RICH_TEXT = false
local MAX_LOG_HISTORY = 500

--[[
	@summary Creates a new Logger instance.
	@param params { Name: string? }
	@return Logger
]]
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
	self.Enabled = true
	self.History = {} :: {LogEntry}
	return self
end

--[[
	@summary Logs a message with the specified level.
	@param params { Level: LogLevel, Message: string, OperationId: string?, Data: any? }
	@return ()
]]
function Logger:Log(params: { Level: LogLevel, Message: string, OperationId: string?, Data: any? })
	if not self.Enabled then return end

	local level = params.Level or "INFO"
	local message = params.Message or ""
	local operationId = params.OperationId

	-- Store in History
	local entry: LogEntry = {
		Timestamp = os.time(),
		OperationId = operationId,
		Level = level,
		Message = message,
		Data = params.Data
	}
	table.insert(self.History, entry)
	if #self.History > MAX_LOG_HISTORY then
		table.remove(self.History, 1)
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

--[[
	@summary Returns the log history.
	@return {LogEntry}
]]
function Logger:GetHistory()
	return self.History
end

return Logger