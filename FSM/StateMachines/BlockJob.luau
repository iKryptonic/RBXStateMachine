--!strict

local BlockJob = {
	Name = "BlockJob",
	className = "BlockJob",
	validStates = { "Validate", "StartBlocking", "WaitForRelease", "StopBlocking", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

local sharedAny = shared :: any

local function getOrchestrator()
	local lower = sharedAny.fsm
	if lower ~= nil then
		return lower.Orchestrator or lower
	end

	local upper = sharedAny.FSM
	if upper ~= nil and upper.Orchestrator then
		return upper.Orchestrator
	end

	error("Orchestrator not found. Check RegisterComponents.")
end

local function getSharedModule(name)
	local sharedFolder = game:GetService("ReplicatedStorage"):FindFirstChild("shared")
	if sharedFolder then
			local mod = sharedFolder:FindFirstChild(name)
			if mod then return require(mod) end
	end
	error("Shared module not found: " .. name)
end

local IntentSchema = getSharedModule("IntentSchema")

function BlockJob:RegisterStates()
	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			if type(fsm.CharacterEntityId) ~= "string" or fsm.CharacterEntityId == "" then
				fsm:Fail("Missing CharacterEntityId")
				return
			end

			local charEntity = getOrchestrator().GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end

			fsm.CharacterEntity = charEntity
			fsm.State = "StartBlocking"
		end,
	}, { "StartBlocking", "Failed" })

	self:AddState("StartBlocking", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			charEntity.IsBlocking = true
			charEntity.MoveSpeedCap = 0
			if charEntity:UpdateEntity() == false then
				fsm:Fail("Failed to start blocking")
				return
			end

			fsm._startedBlocking = true
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
				fsm.State = "StopBlocking"
			end
		end,
	}, { "StopBlocking", "Failed" })

	self:AddState("StopBlocking", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			charEntity.IsBlocking = false
			charEntity.MoveSpeedCap = 16
			if charEntity:UpdateEntity() == false then
				fsm:Fail("Failed to stop blocking")
				return
			end

			fsm._startedBlocking = false
			fsm.State = "Completed"
		end,
	}, { "Completed", "Failed" })
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
