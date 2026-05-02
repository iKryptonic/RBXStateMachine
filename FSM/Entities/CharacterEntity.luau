--!strict
-- @Name CharacterEntity
-- @Author iKrypto
-- @Description Entity implementation for in-game character state (combat, movement, action replication)

local RunService = game:GetService("RunService")

local CharacterEntity = {
	Name = "CharacterEntity",
	Mutable = true,
	Replication = { Enabled = true, RateLimit = 60 },
	Schema = {
		PlayerEntityId = { Type = "string",  Replicate = true,  Persist = false },
		UserId         = { Type = "number",  Replicate = true,  Persist = false },
		IsBlocking     = { Type = "boolean", Replicate = true,  Persist = false },
		CanAnimate     = { Type = "boolean", Replicate = true,  Persist = false },
		IsStunned      = { Type = "boolean", Replicate = true,  Persist = false },
		IsKnocked      = { Type = "boolean", Replicate = true,  Persist = false },
		CanMove        = { Type = "boolean", Replicate = true,  Persist = false },
		MoveSpeedCap   = { Type = "number",  Replicate = true,  Persist = false },
		MouseLocked    = { Type = "boolean", Replicate = true,  Persist = false },
		EquippedRight  = { Type = "string",  Replicate = true,  Persist = false },
		EquippedLeft   = { Type = "string",  Replicate = true,  Persist = false },
		EquipLock      = { Type = "any",     Replicate = false, Persist = false },
		CombatLock     = { Type = "boolean", Replicate = false, Persist = false },
		CCLock         = { Type = "boolean", Replicate = false, Persist = false },
		ActionSeq      = { Type = "number",  Replicate = true,  Persist = false },
		RecentActions  = { Type = "any",     Replicate = true,  Persist = false },
		-- Client-derived state, replicated so other clients can drive remote animations
		LocomotionState = { Type = "string",  Replicate = true, Persist = false },
		ActionOverlay   = { Type = "string",  Replicate = true, Persist = false },
		SprintIntent    = { Type = "boolean", Replicate = false, Persist = false },
		InputMode       = { Type = "string",  Replicate = false, Persist = false },
	},
}

function CharacterEntity:GetContext(params: { [any]: any })
	local context = params.Context or params
	local userId = context.UserId or 0
	local playerEntityId = context.PlayerEntityId or ("Player_" .. tostring(userId))

	return {
		PlayerEntityId = playerEntityId,
		UserId = userId,
		IsBlocking = false,
		CanAnimate = true,
		IsStunned = false,
		IsKnocked = false,
		CanMove = true,
		MoveSpeedCap = 16,
		MouseLocked = true,
		EquippedRight = "",
		EquippedLeft = "",
		EquipLock = {},
		CombatLock = false,
		CCLock = false,
		ActionSeq = 0,
		RecentActions = {},
		LocomotionState = "Idle",
		ActionOverlay = "None",
		SprintIntent = false,
		InputMode = "Normal",
	}
end

function CharacterEntity:ApplyChanges(changes: { [string]: any })
	if not RunService:IsClient() then return end

	if changes.RecentActions or changes.ActionSeq then
		local renderRouter = self._renderRouter
		if renderRouter then
			local actions = self.RecentActions
			if typeof(actions) == "table" then
				renderRouter:ProcessRecentActions(actions, self.ActionSeq)
			end
		end
	end

	if changes.EquippedRight ~= nil or changes.EquippedLeft ~= nil then
		local renderRouter = self._renderRouter
		if renderRouter then
			renderRouter:_handleEquipVisual({
				Kind = if changes.EquippedRight ~= nil then "Equip" else "UnEquip",
				Payload = { Hand = if changes.EquippedRight ~= nil then "Right" else "Left" },
			})
		end
	end

	if changes.MoveSpeedCap ~= nil then
		local character = self.Instance
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.WalkSpeed = changes.MoveSpeedCap
			end
		end
	end
end

return CharacterEntity
