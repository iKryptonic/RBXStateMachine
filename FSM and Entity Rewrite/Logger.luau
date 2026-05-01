--!strict
--[[
    @module Logger
    @author iKrypto
    @version 3.0
    @description Standardized logging utility with history, rich text support,
    and enum-based level filtering.
    
    Log levels (from least to most verbose):
        ERROR (1) → WARN (2) → INFO (3) → DEBUG (4)
    
    Set MinimumLoggingLevel to control verbosity:
        1 = Errors only
        2 = Errors + Warnings
        3 = Errors + Warnings + Info
        4 = All (including Debug)
    
    Usage:
        local Logger = require(path.to.Logger)
        Logger.Initialize(Util)
        
        local log = Logger.new({ Name = "MySystem" })
        log:Log({ Level = "INFO", Message = "System started" })
]]

local Enums = require(script.Parent.Enums)

local Logger = {}
Logger.__index = Logger

--============================================================================--
-- Constants
--============================================================================--

local MAX_LOG_HISTORY = 500
local SHOW_TIMESTAMP = true
local USE_RICH_TEXT = false

--- Maps level strings to their numeric weight for comparison.
local LEVEL_WEIGHTS: { [string]: number } = {
    [Enums.LogLevel.ERROR] = Enums.LogLevelWeight.ERROR,
    [Enums.LogLevel.WARN]  = Enums.LogLevelWeight.WARN,
    [Enums.LogLevel.INFO]  = Enums.LogLevelWeight.INFO,
    [Enums.LogLevel.DEBUG] = Enums.LogLevelWeight.DEBUG,
}

--- Maps level strings to rich text colors.
local LEVEL_COLORS: { [string]: string } = {
    [Enums.LogLevel.ERROR] = "rgb(255, 80, 80)",
    [Enums.LogLevel.WARN]  = "rgb(255, 170, 0)",
    [Enums.LogLevel.INFO]  = "rgb(100, 200, 255)",
    [Enums.LogLevel.DEBUG] = "rgb(180, 180, 180)",
}

--============================================================================--
-- Module State
--============================================================================--

local Initialized = false
local Settings: { DebuggingEnabled: boolean, MinimumLoggingLevel: number } = {
    DebuggingEnabled = false,
    MinimumLoggingLevel = 3,
}

--============================================================================--
-- Public API
--============================================================================--

--[[
    @description Initializes the Logger module with framework settings.
    Must be called before any Logger instances can print.
    
    @param Util FrameworkUtil -- Framework utility bag with Settings.Logger
]]
function Logger.Initialize(Util: any)
    if Initialized then return end
    Initialized = true

    local loggerSettings = Util.Settings and Util.Settings.Logger
    if loggerSettings then
        Settings = {
            DebuggingEnabled = loggerSettings.DebuggingEnabled or false,
            MinimumLoggingLevel = loggerSettings.MinimumLoggingLevel or 3,
        }
    end
end

--[[
    @description Creates a new Logger instance bound to a source name.
    
    @param params { Name: string? } -- Source name for log prefixing
    @return Logger
]]
function Logger.new(params: { Name: string? })
    local self = setmetatable({}, Logger)

    local sourceName = params and params.Name
    if not sourceName then
        local source = debug.info(2, "s")
        sourceName = source and string.match(source, "([^%.]+)$") or source or "Unknown"
    end

    self.Source = sourceName :: string
    self.History = {} :: { any }
    return self
end

--[[
    @description Logs a message at the specified level.
    The message is always stored in history regardless of print settings.
    
    @param params { Level: string, Message: string, OperationId: string?, Data: any? }
]]
function Logger:Log(params: { Level: string, Message: string, OperationId: string?, Data: any? })
    local level = params.Level or Enums.LogLevel.INFO
    local message = params.Message or ""
    local operationId = params.OperationId

    -- Always store in history
    local entry = {
        Timestamp = os.time(),
        OperationId = operationId,
        Level = level,
        Message = message,
        Data = params.Data,
    }
    table.insert(self.History, entry)
    if #self.History > MAX_LOG_HISTORY then
        table.remove(self.History, 1)
    end

    -- Gate printing behind initialization and settings
    if not Initialized or not Settings.DebuggingEnabled then
        return
    end

    -- Check level weight against minimum
    local levelWeight = LEVEL_WEIGHTS[level] or 0
    if levelWeight > Settings.MinimumLoggingLevel then
        return
    end

    -- Format the output
    local timeStr = SHOW_TIMESTAMP and string.format("[%s] ", os.date("%H:%M:%S")) or ""
    local header = string.format("[%s]", level)
    local opIdStr = ""
    if operationId ~= nil and type(operationId) == "string" and operationId ~= "" then
        opIdStr = string.format(" (%s)", operationId)
    end
    local finalMsg = string.format("%s%s [%s]%s %s", timeStr, header, self.Source, opIdStr, message)

    -- Output using appropriate Roblox function
    if level == Enums.LogLevel.ERROR or level == Enums.LogLevel.WARN then
        warn(finalMsg)
    elseif USE_RICH_TEXT then
        local color = LEVEL_COLORS[level] or "rgb(200, 200, 200)"
        print(string.format('<font color="%s">%s</font>', color, finalMsg))
    else
        print(finalMsg)
    end
end

--[[
    @description Updates the minimum logging level at runtime.
    
    @param level number -- 1=ERROR only, 2=+WARN, 3=+INFO, 4=+DEBUG
]]
function Logger:SetMinimumLoggingLevel(level: number)
    Settings.MinimumLoggingLevel = level
end

--[[
    @description Returns the full log history for this logger instance.
    @return { LogEntry }
]]
function Logger:GetHistory(): { any }
    return self.History
end

--[[
    @description Clears the log history for this logger instance.
]]
function Logger:ClearHistory()
    table.clear(self.History)
end

return Logger
