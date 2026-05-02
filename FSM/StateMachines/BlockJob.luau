--!strict
-- @Name BlockJob
-- @Description FSM state machine module.

local BlockJob = {
	Name = "BlockJob",
	className = "BlockJob",
	validStates = {
		"Validate",
		"AcquireBlockState",
		"ApplyMovementRestriction",
		"BroadcastBlockUpdate",
		"EmitBlockIntent",
		"WaitForRelease",
		"ReleaseBlockState",
		"RestoreMovement",
		"BroadcastUnblockUpdate",
		"Completed",
		"Failed",
	},
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

local function getSharedModule(orchestrator: any, name)
	local getModule = orchestrator and orchestrator.GetModule
	if type(getModule) == "function" then
		local module = getModule(name)
		if module ~= nil then
			return module
		end
	end

	local sharedFolder = game:GetService("ReplicatedStorage"):FindFirstChild("shared")
	if sharedFolder then
		local mod = sharedFolder:FindFirstChild(name)
		if mod then
			return require(mod)
		end
	end
	error("Shared module not found: " .. name)
end

local function getIntentSchema(orchestrator: any)
	return getSharedModule(orchestrator, "IntentSchema")
end

function BlockJob:RegisterStates()
	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			if type(fsm.CharacterEntityId) ~= "string" or fsm.CharacterEntityId == "" then
				fsm:Fail("Missing CharacterEntityId")
				return
			end

			local charEntity = fsm:GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end

			fsm.CharacterEntity = charEntity
			fsm.State = "AcquireBlockState"
		end,
	}, { "AcquireBlockState", "Failed" })

	self:AddState("AcquireBlockState", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing")
				return
			end
			charEntity.IsBlocking = true
			fsm.State = "ApplyMovementRestriction"
		end,
	}, { "ApplyMovementRestriction", "Failed" })

	self:AddState("ApplyMovementRestriction", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing")
				return
			end
			charEntity.MoveSpeedCap = 0
			fsm.State = "BroadcastBlockUpdate"
		end,
	}, { "BroadcastBlockUpdate", "Failed" })

	self:AddState("BroadcastBlockUpdate", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing")
				return
			end
			if charEntity:UpdateEntity() == false then
				fsm:Fail("Failed to start blocking")
				return
			end
			fsm._startedBlocking = true
			fsm.State = "EmitBlockIntent"
		end,
	}, { "EmitBlockIntent", "Failed" })

	self:AddState("EmitBlockIntent", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			local IntentSchema = getIntentSchema(fsm:GetOrchestrator())
			local ok, err = pcall(function()
				IntentSchema.AppendIntent(charEntity, {
					Kind = "Animation",
					Payload = { Name = "Blocking" },
				})
			end)
			if not ok then
				fsm:Fail("Failed to emit blocking intent: " .. tostring(err))
				return
			end
			fsm.State = "WaitForRelease"
		end,
	}, { "WaitForRelease", "Failed" })

	self:AddState("WaitForRelease", {
		OnHeartbeat = function(_, fsm, _dt)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing while blocking")
				return
			end
			if charEntity.IsBlocking == false then
				fsm.State = "ReleaseBlockState"
			end
		end,
	}, { "ReleaseBlockState", "Failed" })

	self:AddState("ReleaseBlockState", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing")
				return
			end
			charEntity.IsBlocking = false
			fsm.State = "RestoreMovement"
		end,
	}, { "RestoreMovement", "Failed" })

	self:AddState("RestoreMovement", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing")
				return
			end
			charEntity.MoveSpeedCap = 16
			fsm.State = "BroadcastUnblockUpdate"
		end,
	}, { "BroadcastUnblockUpdate", "Failed" })

	self:AddState("BroadcastUnblockUpdate", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing")
				return
			end
			if charEntity:UpdateEntity() == false then
				fsm:Fail("Failed to stop blocking")
				return
			end
			fsm._startedBlocking = false
			fsm.State = "Completed"
		end,
	}, { "Completed", "Failed" })

	self:AddState("Completed", function() end, {})
	self:AddState("Failed", function() end, {})
end

function BlockJob:OnCleanup()
	if not self._startedBlocking then
		return
	end

	local charEntity = self.CharacterEntity
	if not charEntity then
		return
	end

	charEntity.IsBlocking = false
	charEntity.MoveSpeedCap = 16
	self._startedBlocking = false
	charEntity:UpdateEntity()
end

return BlockJob
