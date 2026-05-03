--!strict
--[=[
	@Name ScoreboardExample
	@Author Copilot
	@Description Persistent scoreboard example that demonstrates DataStore-backed
	entity persistence. The file exposes a schema-driven `ScoreboardEntry` entity,
	a `ScoreManagerFSM` lifecycle controller, and small bootstrap helpers that can
	be required from a server script.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Orchestrator = require(ReplicatedStorage:WaitForChild("Orchestrator"))

local SCOREBOARD_GUI_NAME = "PersistentScoreboardGui"
local SCOREBOARD_LABEL_NAME = "ScoreboardText"

--[=[
	@description Builds the runtime entity id used by the persistent scoreboard.

	@param playerId number -- Roblox user id
	@return string -- Stable entity id for the player
	@reads None
	@writes None
]=]
local function getEntityId(playerId: number): string
	return string.format("Score_%d", playerId)
end

--[=[
	@description Builds the DataStore key used by the persistent scoreboard.

	@param playerId number -- Roblox user id
	@return string -- Stable persistence key for the player
	@reads None
	@writes None
]=]
local function getPersistenceKey(playerId: number): string
	return string.format("score:%d", playerId)
end

--[=[
	@description Formats the client-facing scoreboard label text.

	@param playerName string -- Display name shown on the scoreboard
	@param score number -- Current score value
	@param gamesPlayed number -- Number of scored rounds recorded
	@return string -- BillboardGui text payload
	@reads None
	@writes None
]=]
local function formatScoreboardText(playerName: string, score: number, gamesPlayed: number): string
	return string.format("%s\nScore: %.0f\nGames: %.0f", playerName, score, gamesPlayed)
end

--[=[
	@description Ensures a BillboardGui + TextLabel pair exists on the display part.
	Creates the UI lazily on the client the first time replicated state is applied.

	@param displayPart BasePart -- Part that should show the scoreboard data
	@return TextLabel -- Label used to render the scoreboard text
	@reads displayPart children
	@writes displayPart children
]=]
local function ensureScoreLabel(displayPart: BasePart): TextLabel
	local billboard = displayPart:FindFirstChild(SCOREBOARD_GUI_NAME)
	if billboard and not billboard:IsA("BillboardGui") then
		billboard:Destroy()
		billboard = nil
	end

	if not billboard then
		local createdBillboard = Instance.new("BillboardGui")
		createdBillboard.Name = SCOREBOARD_GUI_NAME
		createdBillboard.Size = UDim2.fromOffset(220, 96)
		createdBillboard.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
		createdBillboard.AlwaysOnTop = true
		createdBillboard.MaxDistance = 125
		createdBillboard.Parent = displayPart
		billboard = createdBillboard
	end

	local label = billboard:FindFirstChild(SCOREBOARD_LABEL_NAME)
	if label and not label:IsA("TextLabel") then
		label:Destroy()
		label = nil
	end

	if not label then
		local createdLabel = Instance.new("TextLabel")
		createdLabel.Name = SCOREBOARD_LABEL_NAME
		createdLabel.Size = UDim2.fromScale(1, 1)
		createdLabel.BackgroundTransparency = 0.25
		createdLabel.BackgroundColor3 = Color3.fromRGB(16, 16, 16)
		createdLabel.BorderSizePixel = 0
		createdLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		createdLabel.TextStrokeTransparency = 0.5
		createdLabel.TextScaled = true
		createdLabel.Font = Enum.Font.GothamBold
		createdLabel.Parent = billboard
		label = createdLabel
	end

	return label :: TextLabel
end

--[=[
	@description Detects whether persistence restored any fields into Pending state.
	The persistence loader calls `Deserialize()` automatically, so a loaded entity
	arrives with staged persistent values before the first `UpdateEntity()` commit.

	@param entity any -- Scoreboard entity instance
	@return boolean -- True when persistence staged at least one field
	@reads entity._privateProperties._pendingKeys
	@writes None
]=]
local function restoredFromPersistence(entity: any): boolean
	local privateProperties = entity and entity._privateProperties
	local pendingKeys = privateProperties and privateProperties._pendingKeys
	if type(pendingKeys) ~= "table" then
		return false
	end

	for _ in pairs(pendingKeys) do
		return true
	end

	return false
end

local ScoreboardEntryEntity = {
	Name = "ScoreboardEntry",
	Mutable = true,
	Replication = {
		Enabled = true,
		RateLimit = 15,
	},
	Schema = {
		PlayerName = { Type = "string", Replicate = true, Persist = true },
		Score = { Type = "number", Replicate = true, Persist = true },
		HighScore = { Type = "number", Replicate = false, Persist = true },
		GamesPlayed = { Type = "number", Replicate = true, Persist = true },
		LastPlayed = { Type = "number", Replicate = false, Persist = true },
		_displayPart = { Type = "BasePart", Replicate = false, Persist = false },
	},
}

--[=[
	@description Seeds non-persistent runtime context and readable defaults for the
	persistent scoreboard entity. Defaults are visible immediately and will be
	committed during the first `UpdateEntity()` after load/initialization.

	@param params { [string]: any } -- Factory creation params with Context data
	@return { [string]: any } -- Context defaults for the entity instance
	@reads params.Context, self.PlayerName, self.Score, self.HighScore, self.GamesPlayed, self.LastPlayed
	@writes None
]=]
function ScoreboardEntryEntity:GetContext(params: { [string]: any }): { [string]: any }
	local context = params.Context or {}
	local rawDisplayPart = context.Instance
	local displayPart = if typeof(rawDisplayPart) == "Instance" and rawDisplayPart:IsA("BasePart")
		then rawDisplayPart
		else nil
	local defaultName = context.PlayerName or (context.OwnerId and string.format("Player_%s", tostring(context.OwnerId))) or "Unknown"

	return {
		_displayPart = displayPart,
		PlayerName = self.PlayerName or defaultName,
		Score = self.Score or 0,
		HighScore = self.HighScore or 0,
		GamesPlayed = self.GamesPlayed or 0,
		LastPlayed = self.LastPlayed or 0,
	}
end

--[=[
	@description Applies replicated presentation changes to the display part.
	Only replicated fields are rendered; server-only stats such as `HighScore`
	and `LastPlayed` remain authoritative on the server.

	@param changes { [string]: any } -- Delta payload from `UpdateEntity()`
	@return ()
	@reads self._displayPart, self.PlayerName, self.Score, self.GamesPlayed
	@writes BillboardGui text on the display part
]=]
function ScoreboardEntryEntity:ApplyChanges(changes: { [string]: any })
	if not RunService:IsClient() then
		return
	end

	local displayPart = self._displayPart
	if not displayPart or not displayPart.Parent then
		return
	end

	if changes.PlayerName == nil and changes.Score == nil and changes.GamesPlayed == nil then
		return
	end

	local label = ensureScoreLabel(displayPart)
	label.Text = formatScoreboardText(
		tostring(self.PlayerName or "Unknown"),
		tonumber(self.Score or 0) or 0,
		tonumber(self.GamesPlayed or 0) or 0
	)
end

--[=[
	@description Stages a score increase, updates the stored high score, records
	another played round, stamps `LastPlayed`, and commits the persistent entity.

	@param points number -- Amount of score to add for this scoring event
	@return boolean -- True when the entity committed successfully
	@reads self.Score, self.HighScore, self.GamesPlayed
	@writes self.Score, self.HighScore, self.GamesPlayed, self.LastPlayed
]=]
function ScoreboardEntryEntity:AddScore(points: number): boolean
	local nextScore = (tonumber(self.Score) or 0) + points
	local nextHighScore = math.max(tonumber(self.HighScore) or 0, nextScore)

	self.Score = nextScore
	self.HighScore = nextHighScore
	self.GamesPlayed = (tonumber(self.GamesPlayed) or 0) + 1
	self.LastPlayed = os.time()

	return self:UpdateEntity()
end

--[=[
	@description Resets the live score while preserving the persistent high score.
	A commit is issued immediately so the reset is replicated and persisted.

	@return boolean -- True when the entity committed successfully
	@reads self.HighScore
	@writes self.Score, self.LastPlayed
]=]
function ScoreboardEntryEntity:ResetScore(): boolean
	self.Score = 0
	self.LastPlayed = os.time()

	return self:UpdateEntity()
end

local ScoreManagerFSM = {
	Name = "ScoreManagerFSM",
	ValidStates = { "Initialize", "WaitForPlayer", "LoadData", "Active", "SaveAndCleanup", "Completed" },
	TerminalStates = { "Completed" },
	InitialState = "Initialize",
}

--[=[
	@description Registers the lifecycle states for the persistent scoreboard
	controller. The FSM creates the entity, waits for the player, verifies loaded
	data, auto-saves every 30 seconds, and performs a final save + cleanup when
	the player leaves.

	@return ()
	@reads self.Context
	@writes self state registry
]=]
function ScoreManagerFSM:RegisterStates()
	self:AddState("Initialize", function(fsm)
		local playerId = fsm.Context.PlayerId
		local displayPart = fsm.Context.DisplayPart
		if type(playerId) ~= "number" then
			fsm:Fail("ScoreManagerFSM.Initialize requires Context.PlayerId")
			return
		end
		if typeof(displayPart) ~= "Instance" or not displayPart:IsA("BasePart") then
			fsm:Fail("ScoreManagerFSM.Initialize requires Context.DisplayPart to be a BasePart")
			return
		end

		local entityId = getEntityId(playerId)
		local persistenceKey = getPersistenceKey(playerId)
		local entityClass = fsm.Context.ScoreboardEntityClass or "ScoreboardEntry"
		local entity = Orchestrator.CreateEntity({
			EntityClass = entityClass,
			EntityId = entityId,
			Persistent = true,
			PersistenceKey = persistenceKey,
			Context = {
				Instance = displayPart,
				OwnerId = playerId,
				PlayerName = fsm.Context.PlayerName,
			},
		})

		if not entity then
			fsm:Fail(string.format("Unable to create persistent scoreboard entity '%s'", entityId))
			return
		end

		fsm.Context.ScoreboardEntry = entity
		fsm.Context.ScoreboardEntityId = entityId
		fsm.Context.PersistenceKey = persistenceKey
		fsm.Context.PendingExit = false
		fsm.Context.ExitReason = nil

		fsm:Manage(Players.PlayerRemoving:Connect(function(player)
			if player.UserId == playerId then
				fsm.Context.PendingExit = true
				fsm.Context.ExitReason = "PlayerRemoving"
				fsm.Context.Player = nil
				fsm.State = "SaveAndCleanup"
			end
		end))

		fsm.State = "WaitForPlayer"
	end, { "WaitForPlayer" })

	self:AddState("WaitForPlayer", {
		OnEnter = function(_state, fsm)
			fsm.Context.PlayerWaitDeadline = os.clock() + (fsm.Context.PlayerWaitTimeout or 15)
		end,
		OnHeartbeat = function(_state, fsm, _dt)
			local playerId = fsm.Context.PlayerId
			if type(playerId) ~= "number" then
				fsm:Fail("Player id disappeared while waiting for player")
				return
			end

			local player = Players:GetPlayerByUserId(playerId)
			if player then
				fsm.Context.Player = player
				fsm.Context.PlayerName = player.DisplayName
				fsm.State = "LoadData"
				return
			end

			if os.clock() >= (fsm.Context.PlayerWaitDeadline or 0) then
				fsm:Fail(string.format("Timed out waiting for player %d to join", playerId))
			end
		end,
	}, { "LoadData", "SaveAndCleanup" })

	self:AddState("LoadData", function(fsm)
		local entity = fsm.Context.ScoreboardEntry
		local player = fsm.Context.Player
		if not entity then
			fsm:Fail("LoadData requires a scoreboard entity")
			return
		end
		if not player then
			fsm:Fail("LoadData requires an active Player instance")
			return
		end

		local didRestore = restoredFromPersistence(entity)
		entity.PlayerName = player.DisplayName
		entity.Score = tonumber(entity.Score or 0) or 0
		entity.HighScore = tonumber(entity.HighScore or 0) or 0
		entity.GamesPlayed = tonumber(entity.GamesPlayed or 0) or 0
		entity.LastPlayed = tonumber(entity.LastPlayed or 0) or 0

		if not entity:UpdateEntity() then
			fsm:Fail("Failed to commit loaded scoreboard state")
			return
		end

		fsm.Context.RestoredFromPersistence = didRestore
		fsm:Log({
			Level = "INFO",
			Message = if didRestore
				then string.format("Loaded persisted scoreboard state from '%s'", fsm.Context.PersistenceKey)
				else string.format("No saved scoreboard state found at '%s'; seeded defaults", fsm.Context.PersistenceKey),
		})
		fsm.State = "Active"
	end, { "Active", "SaveAndCleanup" })

	self:AddState("Active", function(fsm)
		local entity = fsm.Context.ScoreboardEntry
		if not entity then
			fsm:Fail("Active requires a scoreboard entity")
			return
		end

		if fsm.Context.PendingExit then
			fsm.State = "SaveAndCleanup"
			return
		end

		entity.LastPlayed = os.time()
		if not entity:UpdateEntity() then
			fsm:Fail("Periodic scoreboard auto-save failed")
			return
		end

		fsm:Log({
			Level = "INFO",
			Message = string.format("Auto-saved scoreboard entity '%s' to '%s'", fsm.Context.ScoreboardEntityId, fsm.Context.PersistenceKey),
		})
		fsm.WaitSpan = 30
	end, { "Active", "SaveAndCleanup" })

	self:AddState("SaveAndCleanup", function(fsm)
		local entity = fsm.Context.ScoreboardEntry
		local entityId = fsm.Context.ScoreboardEntityId
		if entity then
			entity.LastPlayed = os.time()
			entity:UpdateEntity()
		end

		if type(entityId) == "string" then
			Orchestrator.DeleteEntity(entityId)
		end

		fsm.Context.ScoreboardEntry = nil
		fsm.State = "Completed"
	end, { "Completed" })

	self:AddState("Completed", function(fsm)
		fsm:Log({
			Level = "INFO",
			Message = string.format(
				"Score manager completed for player %s (%s)",
				tostring(fsm.Context.PlayerId),
				tostring(fsm.Context.ExitReason or "Completed")
			),
		})
	end)
end

--[=[
	@description Final cleanup guard for the score manager. If the FSM terminates
	unexpectedly before `SaveAndCleanup` runs, the entity is still removed so the
	persistent lifecycle remains create -> use -> cleanup.

	@return ()
	@reads self.Context.ScoreboardEntityId
	@writes Orchestrator entity registry
]=]
function ScoreManagerFSM:OnCleanup()
	local entityId = self.Context.ScoreboardEntityId
	if type(entityId) ~= "string" then
		return
	end

	if Orchestrator.GetEntity(entityId) then
		Orchestrator.DeleteEntity(entityId)
	end
end

local ScoreboardExample = {
	ScoreboardEntryEntity = ScoreboardEntryEntity,
	ScoreManagerFSM = ScoreManagerFSM,
}

--[=[
	@description Starts the persistence example for a specific player + display part.
	The helper passes the local entity table directly so this single-file example can
	be required as-is, while `ScoreManagerFSM.Initialize` still demonstrates the
	string-based `EntityClass = "ScoreboardEntry"` creation flow used by projects
	that register the module under an Entity folder.

	@param displayPart BasePart -- Part that should render the player scoreboard
	@param playerId number -- Roblox user id to bind persistence to
	@return any? -- Running `ScoreManagerFSM` instance, or nil on creation failure
	@reads Orchestrator
	@writes StateMachine registry
]=]
function ScoreboardExample.StartForPlayer(displayPart: BasePart, playerId: number)
	if not RunService:IsServer() then
		error("ScoreboardExample.StartForPlayer must be called on the server")
	end

	Orchestrator:RegisterComponents()
	local fsm = Orchestrator.CreateStateMachine({
		StateMachineClass = ScoreManagerFSM,
		StateMachineId = string.format("ScoreManager_%d", playerId),
		Context = {
			PlayerId = playerId,
			DisplayPart = displayPart,
			ScoreboardEntityClass = ScoreboardEntryEntity,
		},
	})
	if not fsm then
		return nil
	end

	fsm:Start({ State = "Initialize" })
	return fsm
end

--[=[
	@description Finds the active persistent scoreboard entity for a player and
	applies a staged score update through the entity convenience method.

	@param playerId number -- Roblox user id whose scoreboard should change
	@param points number -- Score delta to apply
	@return boolean -- True when the score commit succeeded
	@reads Orchestrator entity registry
	@writes ScoreboardEntry persistent fields
]=]
function ScoreboardExample.AddScore(playerId: number, points: number): boolean
	local entity = Orchestrator.GetEntity(getEntityId(playerId))
	if not entity or type(entity.AddScore) ~= "function" then
		return false
	end

	return entity:AddScore(points)
end

--[=[
	@description Finds the active persistent scoreboard entity for a player and
	resets the current score while preserving the stored high score.

	@param playerId number -- Roblox user id whose scoreboard should reset
	@return boolean -- True when the reset commit succeeded
	@reads Orchestrator entity registry
	@writes ScoreboardEntry.Score, ScoreboardEntry.LastPlayed
]=]
function ScoreboardExample.ResetScore(playerId: number): boolean
	local entity = Orchestrator.GetEntity(getEntityId(playerId))
	if not entity or type(entity.ResetScore) ~= "function" then
		return false
	end

	return entity:ResetScore()
end

return ScoreboardExample
