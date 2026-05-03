--!strict
--[=[
	@Name ProductionBootstrapExample
	@Author Copilot
	@Description Production reference bootstrap showing the recommended RBXStateMachine
	server + client startup pattern. Copy SECTION 1 into ServerScriptService as a
	Script and SECTION 2 into StarterPlayerScripts as a LocalScript.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--[[ ══════════════════════════════════════════════
     SECTION 1: SERVER BOOTSTRAP
     Place in ServerScriptService as a Script (.server.luau)
     ══════════════════════════════════════════════ ]]
if RunService:IsServer() then
	local Players = game:GetService("Players")

	local playerRuntimeByUserId: { [number]: { EntityId: string, SetupStateMachineId: string } } = {}

	--[[
		@description Waits for ReplicatedStorage.Orchestrator, then safely requires it.
		This keeps the bootstrap deterministic and surfaces a clear warning instead of
		failing with an opaque require error during server startup.
		@param timeoutSeconds number -- Maximum wait for the Orchestrator module
		@return any? -- Required Orchestrator table on success, nil on failure
		@reads ReplicatedStorage.Orchestrator
		@writes None
	]]
	local function requireServerOrchestrator(timeoutSeconds: number): any?
		local orchestratorModule = ReplicatedStorage:WaitForChild("Orchestrator", timeoutSeconds)
		if not orchestratorModule then
			warn("[ProductionBootstrapExample][Server] Timed out waiting for ReplicatedStorage.Orchestrator.")
			return nil
		end

		local requireOk, orchestratorOrError = pcall(require, orchestratorModule)
		if not requireOk then
			warn("[ProductionBootstrapExample][Server] Failed to require Orchestrator:", orchestratorOrError)
			return nil
		end

		return orchestratorOrError
	end

	--[[
		@description Produces a sanitized snapshot for a single entity.
		Only fields marked Replicate or Persist are included so request handlers do not
		accidentally leak transient server-only context.
		@param orchestrator any -- Initialized Orchestrator facade
		@param entityId string -- Entity identifier to snapshot
		@return { [string]: any } -- Success/error payload safe to return through remotes
		@reads Orchestrator.GetEntity, entity schema/data/version
		@writes None
	]]
	local function buildEntitySnapshot(orchestrator: any, entityId: string): { [string]: any }
		local entity = orchestrator.GetEntity(entityId)
		if not entity then
			return {
				Success = false,
				Error = "EntityNotFound",
				EntityId = entityId,
			}
		end

		local privateProperties = entity._privateProperties
		local snapshotData = {}
		local snapshotVersion = 0
		local className = "UnknownEntity"

		if privateProperties then
			snapshotVersion = privateProperties.Version or 0
			className = privateProperties.Name or className

			for fieldName, definition in pairs(privateProperties.Schema or {}) do
				if definition and (definition.Replicate or definition.Persist) then
					snapshotData[fieldName] = (privateProperties.Data and privateProperties.Data[fieldName]) or entity[fieldName]
				end
			end
		end

		return {
			Success = true,
			EntityId = entityId,
			ClassName = className,
			Version = snapshotVersion,
			Data = snapshotData,
		}
	end

	--[[
		@description Registers request/response handlers used by clients.
		Ping provides a cheap health check, while GetEntitySnapshot demonstrates a
		validated one-shot query for authoritative server data.
		@param orchestrator any -- Initialized Orchestrator facade
		@return ()
		@reads Orchestrator.RegisterServerRequestCallback
		@writes NetworkManager server request callback tables
	]]
	local function registerServerRequestHandlers(orchestrator: any)
		orchestrator.RegisterServerRequestCallback("Ping", function(player: Player)
			return {
				Success = true,
				PlayerUserId = player.UserId,
				ServerTime = workspace:GetServerTimeNow(),
				UnixTime = os.time(),
			}
		end, false)

		orchestrator.RegisterServerRequestCallback("GetEntitySnapshot", function(player: Player, requestedEntityId: string?)
			local ownEntityId = "Player_" .. player.UserId
			local entityId = if type(requestedEntityId) == "string" and requestedEntityId ~= "" then requestedEntityId else ownEntityId

			if entityId ~= ownEntityId and not RunService:IsStudio() then
				return {
					Success = false,
					Error = "UnauthorizedEntityRequest",
					EntityId = entityId,
				}
			end

			local snapshotOk, snapshotOrError = pcall(buildEntitySnapshot, orchestrator, entityId)
			if not snapshotOk then
				warn("[ProductionBootstrapExample][Server] GetEntitySnapshot failed:", snapshotOrError)
				return {
					Success = false,
					Error = "SnapshotBuildFailed",
					EntityId = entityId,
				}
			end

			return snapshotOrError
		end, false)
	end

	--[[
		@description Registers validated client->server entity commands for one player entity.
		The callback verifies ownership and payload shape before touching runtime context.
		@param orchestrator any -- Initialized Orchestrator facade
		@param player Player -- Player that owns the entity
		@param entityId string -- Target entity identifier
		@return ()
		@reads Orchestrator.RegisterEntityCommandCallback, Orchestrator.GetEntity
		@writes Entity context and optional client broadcast acknowledgement
	]]
	local function registerPlayerEntityCommands(orchestrator: any, player: Player, entityId: string)
		orchestrator.RegisterEntityCommandCallback(entityId, "MoveIntent", function(commandingPlayer: Player, moveVector: Vector3, clientTimestamp: number?)
			if commandingPlayer ~= player then
				warn(string.format(
					"[ProductionBootstrapExample][Server] Rejected MoveIntent for %s from unexpected player %s.",
					entityId,
					commandingPlayer.Name
				))
				return
			end

			if typeof(moveVector) ~= "Vector3" then
				warn(string.format("[ProductionBootstrapExample][Server] Rejected MoveIntent for %s due to invalid payload type.", entityId))
				return
			end

			local clampedMoveVector = moveVector
			if clampedMoveVector.Magnitude > 1 then
				clampedMoveVector = clampedMoveVector.Unit
			end

			local entity = orchestrator.GetEntity(entityId)
			if not entity then
				warn(string.format("[ProductionBootstrapExample][Server] Player entity %s no longer exists.", entityId))
				return
			end

			if type(entity.SetContext) == "function" then
				entity:SetContext("LastMoveIntent", clampedMoveVector)
				entity:SetContext("LastMoveIntentAt", workspace:GetServerTimeNow())
				entity:SetContext("LastClientTimestamp", if type(clientTimestamp) == "number" then clientTimestamp else 0)
			end

			local broadcastOk, broadcastError = pcall(function()
				orchestrator.BroadcastEntityCommand(entityId, "InputAcknowledged", {
					ReceivedAt = workspace:GetServerTimeNow(),
					Magnitude = clampedMoveVector.Magnitude,
				})
			end)
			if not broadcastOk then
				warn("[ProductionBootstrapExample][Server] Failed to broadcast InputAcknowledged:", broadcastError)
			end
		end)
	end

	--[[
		@description Creates the player's persistent entity, registers per-entity network
		commands, and starts the player setup FSM.
		@param orchestrator any -- Initialized Orchestrator facade
		@param player Player -- Player joining the server
		@return ()
		@reads Orchestrator.CreateEntity, Orchestrator.CreateStateMachine
		@writes playerRuntimeByUserId, entity registry, state-machine registry
	]]
	local function startPlayerRuntime(orchestrator: any, player: Player)
		if playerRuntimeByUserId[player.UserId] then
			return
		end

		local entityId = "Player_" .. player.UserId
		local setupStateMachineId = entityId .. "_Setup"

		local createEntityOk, playerEntityOrError = pcall(function()
			return orchestrator.CreateEntity({
				EntityClass = "PlayerEntity",
				EntityId = entityId,
				Persistent = true,
				PersistenceKey = entityId,
				Context = {
					Player = player,
					PlayerName = player.Name,
					UserId = player.UserId,
					OwnerId = tostring(player.UserId),
				},
			})
		end)
		if not createEntityOk or not playerEntityOrError then
			warn("[ProductionBootstrapExample][Server] Failed to create player entity:", playerEntityOrError)
			return
		end

		registerPlayerEntityCommands(orchestrator, player, entityId)

		local createStateMachineOk, setupStateMachineOrError = pcall(function()
			return orchestrator.CreateStateMachine({
				StateMachineClass = "PlayerSetupStateMachine",
				StateMachineId = setupStateMachineId,
				Context = {
					Player = player,
					Entity = playerEntityOrError,
					EntityId = entityId,
					UserId = player.UserId,
				},
			})
		end)
		if not createStateMachineOk or not setupStateMachineOrError then
			warn("[ProductionBootstrapExample][Server] Failed to create player setup FSM:", setupStateMachineOrError)
			pcall(function()
				orchestrator.DeleteEntity(entityId)
			end)
			return
		end

		local startStateMachineOk, startStateMachineError = pcall(function()
			setupStateMachineOrError:Start()
		end)
		if not startStateMachineOk then
			warn("[ProductionBootstrapExample][Server] Failed to start player setup FSM:", startStateMachineError)
			pcall(function()
				orchestrator.CancelStateMachine(setupStateMachineId)
			end)
			pcall(function()
				orchestrator.DeleteEntity(entityId)
			end)
			return
		end

		playerRuntimeByUserId[player.UserId] = {
			EntityId = entityId,
			SetupStateMachineId = setupStateMachineId,
		}
	end

	--[[
		@description Performs deterministic teardown for a departing player.
		Explicitly flushes persistence before deleting the entity, then cancels any live
		FSMs so teardown remains predictable even if the player leaves mid-transition.
		@param orchestrator any -- Initialized Orchestrator facade
		@param player Player -- Player leaving the server
		@return ()
		@reads playerRuntimeByUserId, Orchestrator registries
		@writes persistence, entity registry, state-machine registry
	]]
	local function stopPlayerRuntime(orchestrator: any, player: Player)
		local runtimeRecord = playerRuntimeByUserId[player.UserId]
		local entityId = runtimeRecord and runtimeRecord.EntityId or ("Player_" .. player.UserId)
		local setupStateMachineId = runtimeRecord and runtimeRecord.SetupStateMachineId or (entityId .. "_Setup")

		local cancelOk, cancelResult = pcall(function()
			return orchestrator.CancelStateMachine(setupStateMachineId)
		end)
		if not cancelOk then
			warn("[ProductionBootstrapExample][Server] Failed to cancel setup FSM:", cancelResult)
		end

		local entity = orchestrator.GetEntity(entityId)
		local persistenceManager = orchestrator.Factory and orchestrator.Factory.PersistenceManager
		if entity and persistenceManager and type(persistenceManager.SaveState) == "function" then
			local saveOk, saveError = pcall(persistenceManager.SaveState, entity)
			if not saveOk then
				warn("[ProductionBootstrapExample][Server] Failed to flush persistent entity state:", saveError)
			end
		end

		local deleteOk, deleteResult = pcall(function()
			return orchestrator.DeleteEntity(entityId)
		end)
		if not deleteOk then
			warn("[ProductionBootstrapExample][Server] Failed to delete player entity:", deleteResult)
		end

		playerRuntimeByUserId[player.UserId] = nil
	end

	--[[
		@description Bootstraps the production server runtime.
		This is the recommended order: require Orchestrator, register components,
		optionally start the ServiceManager in Studio, register network handlers,
		then wire PlayerAdded/PlayerRemoving plus late joiners.
		@return ()
		@reads ReplicatedStorage.Orchestrator, Players, RunService:IsStudio
		@writes Global framework runtime, player lifecycle connections
	]]
	local function bootstrapServer()
		local orchestrator = requireServerOrchestrator(10)
		if not orchestrator then
			return
		end

		local registerOk, registerResult = pcall(function()
			return orchestrator:RegisterComponents()
		end)
		if not registerOk or registerResult ~= true then
			warn("[ProductionBootstrapExample][Server] RegisterComponents failed:", registerResult)
			return
		end

		if RunService:IsStudio() then
			local serviceManagerOk, serviceManagerError = pcall(function()
				orchestrator:StartServiceManager()
			end)
			if not serviceManagerOk then
				warn("[ProductionBootstrapExample][Server] StartServiceManager failed:", serviceManagerError)
			end
		end

		registerServerRequestHandlers(orchestrator)

		Players.PlayerAdded:Connect(function(player)
			startPlayerRuntime(orchestrator, player)
		end)

		Players.PlayerRemoving:Connect(function(player)
			stopPlayerRuntime(orchestrator, player)
		end)

		for _, player in ipairs(Players:GetPlayers()) do
			startPlayerRuntime(orchestrator, player)
		end
	end

	bootstrapServer()
end

--[[ ══════════════════════════════════════════════
     SECTION 2: CLIENT BOOTSTRAP
     Place in StarterPlayerScripts as a LocalScript (.client.luau)
     ══════════════════════════════════════════════ ]]
if RunService:IsClient() then
	local Players = game:GetService("Players")
	local UserInputService = game:GetService("UserInputService")

	local LocalPlayer = Players.LocalPlayer
	if not LocalPlayer then
		warn("[ProductionBootstrapExample][Client] LocalPlayer is unavailable; aborting client bootstrap.")
		return
	end

	local clientConnections: { RBXScriptConnection } = {}
	local clientState = {
		IsRunning = true,
		CharacterReady = LocalPlayer.Character ~= nil,
		EntityId = "",
		LastSeenVersion = -1,
		LastInputAcknowledgement = nil :: any,
		HeldDirections = {} :: { [Enum.KeyCode]: boolean },
	}

	local movementVectors: { [Enum.KeyCode]: Vector3 } = {
		[Enum.KeyCode.W] = Vector3.new(0, 0, -1),
		[Enum.KeyCode.S] = Vector3.new(0, 0, 1),
		[Enum.KeyCode.A] = Vector3.new(-1, 0, 0),
		[Enum.KeyCode.D] = Vector3.new(1, 0, 0),
	}

	--[[
		@description Tracks a connection so the LocalScript can disconnect everything on shutdown.
		@param connection RBXScriptConnection -- Connection returned by :Connect
		@return RBXScriptConnection -- The same connection for inline use
		@reads None
		@writes clientConnections
	]]
	local function trackConnection(connection: RBXScriptConnection): RBXScriptConnection
		table.insert(clientConnections, connection)
		return connection
	end

	--[[
		@description Disconnects every tracked connection.
		This is the last line of defense against leaked listeners when the client
		script is destroyed or disabled.
		@return ()
		@reads clientConnections
		@writes clientConnections
	]]
	local function disconnectAllClientConnections()
		for index = #clientConnections, 1, -1 do
			local connection = clientConnections[index]
			if connection then
				connection:Disconnect()
			end
			clientConnections[index] = nil
		end
	end

	--[[
		@description Waits for ReplicatedStorage.Orchestrator, then safely requires it.
		The client path mirrors the server path so both bootstraps fail loudly and predictably.
		@param timeoutSeconds number -- Maximum wait for the Orchestrator module
		@return any? -- Required Orchestrator table on success, nil on failure
		@reads ReplicatedStorage.Orchestrator
		@writes None
	]]
	local function requireClientOrchestrator(timeoutSeconds: number): any?
		local orchestratorModule = ReplicatedStorage:WaitForChild("Orchestrator", timeoutSeconds)
		if not orchestratorModule then
			warn("[ProductionBootstrapExample][Client] Timed out waiting for ReplicatedStorage.Orchestrator.")
			return nil
		end

		local requireOk, orchestratorOrError = pcall(require, orchestratorModule)
		if not requireOk then
			warn("[ProductionBootstrapExample][Client] Failed to require Orchestrator:", orchestratorOrError)
			return nil
		end

		return orchestratorOrError
	end

	--[[
		@description Polls until the local player's replicated entity appears on the client.
		The framework sync is asynchronous, so production code should always use a timeout
		instead of assuming the entity exists immediately after RegisterComponents.
		@param orchestrator any -- Initialized Orchestrator facade
		@param entityId string -- Expected replicated entity identifier
		@param timeoutSeconds number -- Maximum time to wait for replication
		@return any? -- Replicated entity on success, nil on timeout
		@reads Orchestrator.GetEntity
		@writes None
	]]
	local function waitForReplicatedEntity(orchestrator: any, entityId: string, timeoutSeconds: number): any?
		local startedAt = os.clock()
		while os.clock() - startedAt <= timeoutSeconds do
			local getEntityOk, entityOrError = pcall(function()
				return orchestrator.GetEntity(entityId)
			end)
			if getEntityOk and entityOrError then
				return entityOrError
			end

			task.wait(0.25)
		end

		warn(string.format("[ProductionBootstrapExample][Client] Timed out waiting for replicated entity %s.", entityId))
		return nil
	end

	--[[
		@description Computes a normalized move vector from currently-held keyboard inputs.
		@param ()
		@return Vector3 -- Zero when no movement keys are held, otherwise a clamped vector
		@reads clientState.HeldDirections, movementVectors
		@writes None
	]]
	local function getMoveVector(): Vector3
		local moveVector = Vector3.new()
		for keyCode, isHeld in pairs(clientState.HeldDirections) do
			if isHeld then
				moveVector += movementVectors[keyCode]
			end
		end

		if moveVector.Magnitude > 1 then
			moveVector = moveVector.Unit
		end

		return moveVector
	end

	--[[
		@description Sends the client's current move intent to the authoritative server.
		This is the recommended pattern for player input: thin client command, server-side validation.
		@param orchestrator any -- Initialized Orchestrator facade
		@return ()
		@reads clientState.EntityId, clientState.CharacterReady
		@writes NetworkManager client entity command transport
	]]
	local function sendMoveIntent(orchestrator: any)
		if clientState.EntityId == "" or not clientState.CharacterReady then
			return
		end

		local sendOk, sendError = pcall(function()
			orchestrator.ServerCommandEntity(clientState.EntityId, "MoveIntent", getMoveVector(), workspace:GetServerTimeNow())
		end)
		if not sendOk then
			warn("[ProductionBootstrapExample][Client] Failed to send MoveIntent:", sendError)
		end
	end

	--[[
		@description Requests lightweight server diagnostics once the client is online.
		This demonstrates the recommended request/response path for one-shot reads.
		@param orchestrator any -- Initialized Orchestrator facade
		@param entityId string -- Player entity identifier to request back from the server
		@return ()
		@reads Orchestrator.ServerRequest
		@writes None
	]]
	local function requestServerDiagnostics(orchestrator: any, entityId: string)
		local pingOk, pingResponse = pcall(function()
			return orchestrator.ServerRequest("Ping")
		end)
		if not pingOk then
			warn("[ProductionBootstrapExample][Client] Ping request failed:", pingResponse)
		else
			print("[ProductionBootstrapExample][Client] Ping response:", pingResponse)
		end

		local snapshotOk, snapshotResponse = pcall(function()
			return orchestrator.ServerRequest("GetEntitySnapshot", entityId)
		end)
		if not snapshotOk then
			warn("[ProductionBootstrapExample][Client] GetEntitySnapshot request failed:", snapshotResponse)
		else
			print("[ProductionBootstrapExample][Client] Entity snapshot:", snapshotResponse)
		end
	end

	--[[
		@description Starts a simple polling watcher for replicated entity version changes.
		Polling is the safest cross-project option because replicated updates do not always
		fire local StateUpdated listeners in every integration style.
		@param orchestrator any -- Initialized Orchestrator facade
		@param entityId string -- Replicated entity identifier to watch
		@return ()
		@reads Orchestrator.GetEntity, entity version/raw data
		@writes clientState.LastSeenVersion
	]]
	local function startEntityPolling(orchestrator: any, entityId: string)
		task.spawn(function()
			while clientState.IsRunning and clientState.EntityId == entityId do
				local entity = orchestrator.GetEntity(entityId)
				if entity and entity._privateProperties then
					local currentVersion = entity._privateProperties.Version or 0
					if currentVersion ~= clientState.LastSeenVersion then
						clientState.LastSeenVersion = currentVersion

						local rawData = if type(entity.GetRawData) == "function" then entity:GetRawData() else nil
						local snapshotData = if rawData then table.clone(rawData) else {}
						print("[ProductionBootstrapExample][Client] Replicated entity updated:", entityId, currentVersion, snapshotData)
					end
				end

				task.wait(0.25)
			end
		end)
	end

	--[[
		@description Wires the production client flow after the player's entity has replicated.
		This covers server requests, client->server commands, server->client command callbacks,
		poll-based state watching, and respawn-safe cleanup.
		@param orchestrator any -- Initialized Orchestrator facade
		@param entity any -- Replicated player entity
		@return ()
		@reads UserInputService, LocalPlayer.CharacterRemoving/CharacterAdded
		@writes clientState, client connections, entity command callback table
	]]
	local function bindClientRuntime(orchestrator: any, entity: any)
		clientState.EntityId = "Player_" .. LocalPlayer.UserId
		clientState.LastSeenVersion = (entity._privateProperties and entity._privateProperties.Version) or 0

		orchestrator.RegisterEntityCommandCallback(clientState.EntityId, "InputAcknowledged", function(_player: Player?, acknowledgement: any)
			clientState.LastInputAcknowledgement = acknowledgement
			print("[ProductionBootstrapExample][Client] Server acknowledged latest input:", acknowledgement)
		end)

		requestServerDiagnostics(orchestrator, clientState.EntityId)
		startEntityPolling(orchestrator, clientState.EntityId)

		trackConnection(UserInputService.InputBegan:Connect(function(inputObject: InputObject, gameProcessedEvent: boolean)
			if gameProcessedEvent then
				return
			end

			if movementVectors[inputObject.KeyCode] then
				clientState.HeldDirections[inputObject.KeyCode] = true
				sendMoveIntent(orchestrator)
			end
		end))

		trackConnection(UserInputService.InputEnded:Connect(function(inputObject: InputObject, gameProcessedEvent: boolean)
			if gameProcessedEvent then
				return
			end

			if movementVectors[inputObject.KeyCode] then
				clientState.HeldDirections[inputObject.KeyCode] = nil
				sendMoveIntent(orchestrator)
			end
		end))

		trackConnection(LocalPlayer.CharacterAdded:Connect(function()
			clientState.CharacterReady = true
		end))

		trackConnection(LocalPlayer.CharacterRemoving:Connect(function()
			table.clear(clientState.HeldDirections)
			sendMoveIntent(orchestrator)
			clientState.CharacterReady = false
		end))
	end

	--[[
		@description Bootstraps the production client runtime.
		The startup order mirrors the server: require Orchestrator, register components,
		optionally start the ServiceManager dev panel in Studio, then wait for the player's
		replicated entity before wiring UI/input/gameplay listeners.
		@return ()
		@reads ReplicatedStorage.Orchestrator, RunService:IsStudio, Players.LocalPlayer
		@writes Global client framework runtime, clientState, client connections
	]]
	local function bootstrapClient()
		local orchestrator = requireClientOrchestrator(10)
		if not orchestrator then
			return
		end

		local registerOk, registerResult = pcall(function()
			return orchestrator:RegisterComponents()
		end)
		if not registerOk or registerResult ~= true then
			warn("[ProductionBootstrapExample][Client] RegisterComponents failed:", registerResult)
			return
		end

		if RunService:IsStudio() then
			local serviceManagerOk, serviceManagerError = pcall(function()
				orchestrator:StartServiceManager()
			end)
			if not serviceManagerOk then
				warn("[ProductionBootstrapExample][Client] StartServiceManager failed:", serviceManagerError)
			end
		end

		local entityId = "Player_" .. LocalPlayer.UserId
		local entity = waitForReplicatedEntity(orchestrator, entityId, 15)
		if not entity then
			return
		end

		bindClientRuntime(orchestrator, entity)
		trackConnection(script.Destroying:Connect(function()
			clientState.IsRunning = false
			disconnectAllClientConnections()
		end))
	end

	bootstrapClient()
end

--[[ ══════════════════════════════════════════════
     SECTION 3: COMMON PATTERNS
     Copy, uncomment, and adapt these snippets as needed.
     ══════════════════════════════════════════════ ]]

--[[
-- EventBus pub/sub between server systems
local CombatBus = Orchestrator.RegisterEventBus("Combat")
local disconnectCombatSubscription = CombatBus:Connect(function(eventName, payload)
	print("Combat event:", eventName, payload)
end)
Orchestrator.FireEventBus("Combat", "PlayerDamaged", { UserId = 42, Amount = 15 })

-- Server request from client
local pingResponse = Orchestrator.ServerRequest("Ping")
if pingResponse and pingResponse.Success then
	print("Server clock:", pingResponse.ServerTime)
end

-- Entity command from client with validation
Orchestrator.RegisterEntityCommandCallback("Player_42", "MoveIntent", function(player, moveVector)
	if player.UserId ~= 42 then
		warn("Rejected spoofed command")
		return
	end
	if typeof(moveVector) ~= "Vector3" then
		warn("Rejected malformed payload")
		return
	end
	print("Accepted command:", moveVector)
end)
Orchestrator.ServerCommandEntity("Player_42", "MoveIntent", Vector3.new(1, 0, 0), workspace:GetServerTimeNow())

-- Graceful shutdown / persistence flush
game:BindToClose(function()
	for _, entity in pairs(Orchestrator.GetEntities()) do
		local persistenceManager = Orchestrator.Factory and Orchestrator.Factory.PersistenceManager
		if persistenceManager and entity and entity._privateProperties and entity._privateProperties.Persistent then
			pcall(persistenceManager.SaveState, entity)
		end
	end
	Orchestrator.CancelAll()
	Orchestrator.DeleteAllEntities()
end)
]]
