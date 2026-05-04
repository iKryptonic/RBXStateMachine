--!strict

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local MAX_LOCK_DISTANCE = 50
local BREAK_LOCK_DISTANCE = 60

--[=[
	@module TargetLockFSM
	@description Scans for the best target near the cursor, maintains a lock and indicator while valid, and clears the lock when the target or request ends.
]=]

local TargetLockFSM = {
	Name = "TargetLockFSM",
	className = "TargetLockFSM",
	validStates = {
		"Idle",
		"Scanning",
		"Locked",
		"Completed",
		"Failed",
	},
	terminalStates = {"Completed","Failed" },
	initialState = "Idle",
}

--[=[
	@description Resolves an entity id from the live entity table first, then from its private context fallback.
	@param entity any  -- Candidate entity whose id should be read for lock-on bookkeeping.
	@return string -- Entity id string, or `nil` when the candidate exposes no usable id.
]=]

local function getEntityId(entity: any): string?
	local entityId = entity and entity.EntityId
	if typeof(entityId) == "string" and entityId ~= "" then
		return entityId
	end
	local privateProperties = entity and entity._privateProperties
	local context = privateProperties and privateProperties.Context
	entityId = context and context.EntityId
	if typeof(entityId) == "string" and entityId ~= "" then
		return entityId
	end
	return nil
end

--[=[
	@description Resolves a target model, humanoid, and root part for lock-on, rejecting the local character and invalid or dead targets.
	@param player any  -- Local player who owns the lock-on request.
	@param entity any  -- Candidate entity being evaluated as a lock target.
	@return any -- Target model, humanoid, and root part, or `nil` values when the candidate is not lockable.
]=]

local function getTargetParts(player: Player, entity: any): (Model?, Humanoid?, BasePart?)
	local character = entity and entity.Instance
	if not character or character == player.Character or not character:IsA("Model") or not character.Parent then
		return nil, nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not rootPart or not rootPart:IsA("BasePart") then
		return nil, nil, nil
	end
	return character, humanoid, rootPart
end

-- Indicator management (module-level helpers operating on FSM context)
--[=[
	@description Destroys indicator.
	@param fsm any  -- TargetLockFSM instance carrying the local player, current target id, and indicator state.

]=]
local function destroyIndicator(fsm: any)
	local indicator = fsm.Context._indicator
	if indicator then
		indicator:Destroy()
		fsm.Context._indicator = nil
		fsm.Context._indicatorLabel = nil
		fsm.Context._indicatorAdornee = nil
	end
end

--[=[
	@description Resolves the character model's Humanoid and HumanoidRootPart. Falls back to LocalPlayer.Character if the entity Instance is unavailable.
]=]
local function ensureIndicator(fsm: any, targetCharacter: Model)
	local adornPart = targetCharacter:FindFirstChild("Head")
		or targetCharacter:FindFirstChild("HumanoidRootPart")
	if not adornPart then
		destroyIndicator(fsm)
		return
	end

	local existingIndicator = fsm.Context._indicator
	if existingIndicator and fsm.Context._indicatorAdornee == adornPart and existingIndicator.Parent == adornPart then
		return
	end

	destroyIndicator(fsm)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "LockOnIndicator"
	billboard.Size = UDim2.fromOffset(36, 36)
	billboard.AlwaysOnTop = true
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.ResetOnSpawn = false
	billboard.Parent = adornPart
	fsm:TrackInstance(billboard,"LockOnIndicator")

	local label = Instance.new("TextLabel")
	label.Name = "Diamond"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = "◆"
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 221, 85)
	label.TextStrokeTransparency = 0.2
	label.Parent = billboard

	fsm.Context._indicator = billboard
	fsm.Context._indicatorLabel = label
	fsm.Context._indicatorAdornee = adornPart
end

--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `TargetLockFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function TargetLockFSM:RegisterStates()

	--[=[
	@state Idle
	@description Clears any stale target lock on enter, wipes `TargetEntityId`, and destroys the current lock indicator.
	Transitions:
	- Input code may jump to `Scanning` to acquire a lock, or to `Completed` for explicit shutdown.
	Writes: stores `Context._targetEntityId`, sets `TargetEntityId`, sets `_targetEntityId`.

]=]

	self:AddState("Idle", {
		OnEnter = function(_, fsm)
			-- Clear any stale target
			local orchestrator = fsm:GetOrchestrator()
			if not orchestrator then return end
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if charEntity and charEntity.TargetEntityId ~= "" then
				charEntity.TargetEntityId = ""
			end
			fsm.Context._targetEntityId = ""
			destroyIndicator(fsm)
		end,
	}, {"Scanning","Completed" })

	--[=[
	@state Scanning
	@description Scans visible entities nearest the mouse cursor, writes the chosen `TargetEntityId`, and shows the lock indicator; invalid context falls back to `Idle`.
	Transitions:
	- `Idle` when OnEnter finishes or falls through its guard checks.
	- `Locked` when OnEnter finishes or falls through its guard checks.
	Writes: stores `Context._targetEntityId`, sets `_targetEntityId`, sets `TargetEntityId`.

]=]

	self:AddState("Scanning", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			if not orchestrator then
				fsm.State = "Idle"
				return
			end

			local player = fsm.Context._player
			local rootPart = fsm.Context._rootPart
			if not player or not rootPart or not rootPart.Parent then
				fsm.State = "Idle"
				return
			end

			local currentCamera = Workspace.CurrentCamera
			if not currentCamera then
				fsm.State = "Idle"
				return
			end

			local origin = rootPart.Position
			local mouseLocation = UserInputService:GetMouseLocation()
			local bestTarget = nil
			local bestScreenDist = math.huge

			for _, entity in pairs(orchestrator.GetEntities()) do
				local character, _, targetRoot = getTargetParts(player, entity)
				if character and targetRoot then
					local worldDist = (targetRoot.Position - origin).Magnitude
					if worldDist < MAX_LOCK_DISTANCE and worldDist > 0.001 then
						local screenPos, onScreen = currentCamera:WorldToScreenPoint(targetRoot.Position)
						if onScreen then
							local screenDist = (Vector2.new(screenPos.X, screenPos.Y) - mouseLocation).Magnitude
							if screenDist < bestScreenDist then
								bestScreenDist = screenDist
								bestTarget = entity
							end
						end
					end
				end
			end

			if not bestTarget then
				fsm.State = "Idle"
				return
			end

			local targetId = getEntityId(bestTarget)
			if not targetId then
				fsm.State = "Idle"
				return
			end

			local targetCharacter = bestTarget.Instance
			if not targetCharacter or not targetCharacter:IsA("Model") then
				fsm.State = "Idle"
				return
			end

			-- Lock acquired
			fsm.Context._targetEntityId = targetId
			ensureIndicator(fsm, targetCharacter)

			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if charEntity then
				charEntity.TargetEntityId = targetId
			end

			fsm.State = "Locked"
		end,
	}, {"Locked","Idle" })

	--[=[
	@state Locked
	@description Keeps the indicator attached while OnHeartbeat validates target existence, target parts, and break-lock distance.
	Transitions:
	- `Idle` when OnEnter finishes or falls through its guard checks.
	Writes: none.

]=]

	self:AddState("Locked", {
		OnEnter = function(_, _fsm)
			-- Target is set, indicator is showing. OnHeartbeat handles validation.
		end,
		OnHeartbeat = function(_, fsm, _dt)
			local orchestrator = fsm:GetOrchestrator()
			if not orchestrator then
				fsm.State = "Idle"
				return
			end

			local targetEntityId = fsm.Context._targetEntityId
			if typeof(targetEntityId) ~= "string" or targetEntityId == "" then
				fsm.State = "Idle"
				return
			end

			local rootPart = fsm.Context._rootPart
			if not rootPart or not rootPart.Parent then
				fsm.State = "Idle"
				return
			end

			local entity = orchestrator.GetEntity(targetEntityId)
			if not entity then
				fsm.State = "Idle"
				return
			end

			local player = fsm.Context._player
			local character, _, targetRoot = getTargetParts(player, entity)
			if not character or not targetRoot then
				fsm.State = "Idle"
				return
			end

			if (targetRoot.Position - rootPart.Position).Magnitude > BREAK_LOCK_DISTANCE then
				fsm.State = "Idle"
				return
			end

			-- Still valid — refresh indicator
			ensureIndicator(fsm, character)
		end,
	}, {"Idle","Completed" })
	--[=[
	@state Completed
	@description Terminal success sink reserved for explicit shutdown of the target-lock FSM. Normal locking toggles between `Idle`, `Scanning`, and `Locked`, breaking back to `Idle` when the target is invalid.
	Transitions: none.
	Writes: none.

]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink reserved for future lock-acquisition errors. The current implementation never routes here, and `OnEnter` is a no-op.
	Transitions: none.
	Writes: none.

]=]

	self:AddState("Failed", function() end, {})
end

--[=[
	@description Flips between the two supported runtime modes and returns the resulting state name.
	@param fsm any  -- TargetLockFSM instance carrying the local player, current target id, and indicator state.
	@return nil -- Updates FSM state as a side effect.
]=]

function TargetLockFSM.ToggleLock(fsm: any)
	if fsm.State == "Locked" then
		fsm.State = "Idle"
	elseif fsm.State == "Idle" then
		fsm.State = "Scanning"
	end
end

--[=[
	@description Public helper for `TargetLockFSM.GetTarget`.
	@param fsm any  -- TargetLockFSM instance carrying the local player, current target id, and indicator state.
	@return nil -- Updates FSM state as a side effect.
]=]

function TargetLockFSM.GetTarget(fsm: any): any?
	local targetEntityId = fsm.Context._targetEntityId
	if typeof(targetEntityId) ~= "string" or targetEntityId == "" then
		return nil
	end
	local orchestrator = fsm:GetOrchestrator()
	if not orchestrator then return nil end
	return orchestrator.GetEntity(targetEntityId)
end

--[=[
	@description Returns whether the FSM is currently in the `Locked` branch.
	@param fsm any  -- TargetLockFSM instance carrying the local player, current target id, and indicator state.
	@return boolean -- `true` when locked is true.
]=]

function TargetLockFSM.IsLocked(fsm: any): boolean
	return fsm.State == "Locked"
end

return TargetLockFSM
