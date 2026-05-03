--!strict
--[=[
	@module CrowdControlFSM
	@description Defines the `CrowdControlFSM` state machine module and its exported API.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers, "Helpers folder not found")
local CrowdControlHelpers = require(Helpers:WaitForChild("CrowdControlHelpers"))
local IntentHelpers = require(Helpers:WaitForChild("IntentHelpers"))
local StateTransitionHelpers = require(Helpers:WaitForChild("StateTransitionHelpers"))

type RouteConfig = {
	flagField: string,
	animName: string,
	logPrefix: string,
}

local CrowdControlFSM = {
	Name = "CrowdControlFSM",
	className = "CrowdControlFSM",
	validStates = {
		"Validate",
		"RouteBranch",
		"AcquireCCLock",
		"ApplyFlags",
		"EmitIntent",
		"WaitDuration",
		"ClearFlags",
		"ReleaseCCLock",
		"Completed",
		"Failed",
	},
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

local function resolveRouteConfig(operation: string?): RouteConfig?
	if operation == "Stun" then
		return {
			flagField = "IsStunned",
			animName = "Stunned",
			logPrefix = "Stun",
		}
	end
	if operation == "Knockdown" then
		return {
			flagField = "IsKnocked",
			animName = "Knocked",
			logPrefix = "Knockdown",
		}
	end
	return nil
end

local function getRouteConfig(fsm: any): RouteConfig?
	local context = fsm.Context
	if typeof(context) == "table" then
		local flagField = context._flagField
		local animName = context._animName
		local logPrefix = context._logPrefix
		if typeof(flagField) == "string" and typeof(animName) == "string" and typeof(logPrefix) == "string" then
			return {
				flagField = flagField,
				animName = animName,
				logPrefix = logPrefix,
			}
		end
	end
	return resolveRouteConfig(fsm.Operation)
end

local function getOperationLabel(routeConfig: RouteConfig): string
	return string.lower(routeConfig.logPrefix)
end
--[=[
	@description Handles `RegisterStates` for `CrowdControlFSM`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function CrowdControlFSM:RegisterStates()
	--[=[
		@state Validate
		@description Handles the `Validate` state for `CrowdControlFSM`.
	]=]

	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			if not fsm:GetOrchestrator() then
				fsm:Fail("Orchestrator not found")
				return
			end
			if type(fsm.Operation) ~= "string" or fsm.Operation == "" then
				fsm:Fail("Missing Operation")
				return
			end
			if type(fsm.CharacterEntityId) ~= "string" or fsm.CharacterEntityId == "" then
				fsm:Fail("Missing CharacterEntityId")
				return
			end
			if type(fsm.Duration) ~= "number" or fsm.Duration < 0 then
				fsm:Fail("Invalid crowd control duration")
				return
			end

			local charEntity = fsm:GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end

			fsm.CharacterEntity = charEntity
			fsm.State = "RouteBranch"
		end,
	}, { "RouteBranch", "Failed" })
	--[=[
		@state RouteBranch
		@description Handles the `RouteBranch` state for `CrowdControlFSM`.
	]=]

	self:AddState("RouteBranch", {
		OnEnter = function(_, fsm)
			local routeConfig = resolveRouteConfig(fsm.Operation)
			if not routeConfig then
				fsm:Fail("Unsupported crowd control operation: " .. tostring(fsm.Operation))
				return
			end

			local context = if typeof(fsm.Context) == "table" then fsm.Context else {}
			fsm.Context = context
			context._flagField = routeConfig.flagField
			context._animName = routeConfig.animName
			context._logPrefix = routeConfig.logPrefix
			fsm.State = "AcquireCCLock"
		end,
	}, { "AcquireCCLock", "Failed" })
	--[=[
		@state AcquireCCLock
		@description Handles the `AcquireCCLock` state for `CrowdControlFSM`.
	]=]

	self:AddState("AcquireCCLock", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			local ok, reason = CrowdControlHelpers.acquireCCLock(charEntity)
			if not ok then
				if reason == "CCLock already held" then
					fsm:Fail(reason)
				else
					fsm._failureReason = reason
					fsm.State = "ReleaseCCLock"
				end
				return
			end

			fsm._ccLockHeld = true
			fsm.State = "ApplyFlags"
		end,
	}, { "ApplyFlags", "ReleaseCCLock", "Failed" })
	--[=[
		@state ApplyFlags
		@description Handles the `ApplyFlags` state for `CrowdControlFSM`.
	]=]

	self:AddState("ApplyFlags", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			local routeConfig = getRouteConfig(fsm)
			if not routeConfig then
				StateTransitionHelpers.failOrRelease(fsm, "Crowd control route was not initialized")
				return
			end
			if not CrowdControlHelpers.applyFlags(charEntity, {
				[routeConfig.flagField] = true,
				CanMove = false,
				MoveSpeedCap = 0,
			}) then
				StateTransitionHelpers.failOrRelease(fsm, "Failed to apply " .. getOperationLabel(routeConfig) .. " flags")
				return
			end

			fsm._flagsApplied = true
			fsm.State = "EmitIntent"
		end,
	}, { "EmitIntent", "ReleaseCCLock", "Failed" })
	--[=[
		@state EmitIntent
		@description Handles the `EmitIntent` state for `CrowdControlFSM`.
	]=]

	self:AddState("EmitIntent", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			if not orchestrator then
				StateTransitionHelpers.failOrRelease(fsm, "Orchestrator not found")
				return
			end
			local routeConfig = getRouteConfig(fsm)
			if not routeConfig then
				StateTransitionHelpers.failOrRelease(fsm, "Crowd control route was not initialized")
				return
			end

			local ok, err = pcall(function()
				IntentHelpers.appendIntent(
					orchestrator,
					fsm.CharacterEntity,
					"Animation",
					{ Name = routeConfig.animName },
					fsm.CharacterEntityId,
					fsm.CharacterEntityId
				)
			end)
			if not ok then
				StateTransitionHelpers.failOrRelease(fsm, "Failed to emit " .. getOperationLabel(routeConfig) .. " intent: " .. tostring(err))
				return
			end

			fsm.State = "WaitDuration"
		end,
	}, { "WaitDuration", "ReleaseCCLock", "Failed" })
	--[=[
		@state WaitDuration
		@description Handles the `WaitDuration` state for `CrowdControlFSM`.
	]=]

	self:AddState("WaitDuration", {
		OnEnter = function(_, fsm)
			StateTransitionHelpers.scheduleTransitionCompat(fsm, fsm.Duration, "ClearFlags", "WaitDuration")
		end,
	}, { "ClearFlags", "ReleaseCCLock", "Failed" })
	--[=[
		@state ClearFlags
		@description Handles the `ClearFlags` state for `CrowdControlFSM`.
	]=]

	self:AddState("ClearFlags", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			local routeConfig = getRouteConfig(fsm)
			if not routeConfig then
				StateTransitionHelpers.failOrRelease(fsm, "Crowd control route was not initialized")
				return
			end
			if not CrowdControlHelpers.applyFlags(charEntity, {
				[routeConfig.flagField] = false,
				CanMove = true,
				MoveSpeedCap = 16,
			}) then
				StateTransitionHelpers.failOrRelease(fsm, "Failed to clear " .. getOperationLabel(routeConfig) .. " flags")
				return
			end

			fsm._flagsApplied = false
			fsm.State = "ReleaseCCLock"
		end,
	}, { "ReleaseCCLock", "Failed" })
	--[=[
		@state ReleaseCCLock
		@description Handles the `ReleaseCCLock` state for `CrowdControlFSM`.
	]=]

	self:AddState("ReleaseCCLock", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if charEntity and fsm._ccLockHeld then
				if not CrowdControlHelpers.releaseCCLock(charEntity) and not fsm._failureReason then
					fsm._failureReason = "Failed to release CCLock"
				end
			end

			fsm._ccLockHeld = false
			if fsm._failureReason then
				fsm:Fail(fsm._failureReason)
			else
				fsm.State = "Completed"
			end
		end,
	}, { "Completed", "Failed" })
end
--[=[
	@description Implements `CrowdControlFSM.OnCleanup`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function CrowdControlFSM:OnCleanup()
	local charEntity = self.CharacterEntity
	if not charEntity then
		return
	end

	local routeConfig = getRouteConfig(self)
	local flagField = if routeConfig then routeConfig.flagField else nil
	local shouldUpdate = false
	if self._flagsApplied then
		if typeof(flagField) == "string" then
			charEntity[flagField] = false
		end
		charEntity.CanMove = true
		charEntity.MoveSpeedCap = 16
		self._flagsApplied = false
		shouldUpdate = true
	end
	if self._ccLockHeld then
		charEntity.CCLock = false
		self._ccLockHeld = false
		shouldUpdate = true
	end
	if shouldUpdate then
		charEntity:UpdateEntity()
	end
end

return CrowdControlFSM
