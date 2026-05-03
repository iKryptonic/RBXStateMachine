--!strict
--[=[
	@Name BankVaultExample
	@Author Copilot
	@Description Shared bank-vault example that demonstrates entity-wide locking,
	locked UpdateEntity commits, optimistic concurrency, and two competing FSMs
	serializing access to the same entity.

	This file intentionally keeps the Entity and both StateMachine definitions in
	one place so the concurrency pattern is easy to study. In a production game,
	split the tables below into separate ModuleScripts under your Entity/ and
	StateMachine/ folders so Orchestrator:RegisterComponents() can compile them.
]=]

local RunService = game:GetService("RunService")

local LOCK_RETRY_LIMIT = 5
local LOCK_RETRY_WAIT = 0.5

type VaultSnapshot = {
	Balance: number,
	LastTransaction: string,
	TransactionCount: number,
	IsProcessing: boolean,
}

type VaultTransactionContext = {
	VaultEntity: any?,
	VaultEntityId: string?,
	Amount: number,
	RetryCount: number?,
	LockHeld: boolean?,
	PreTransactionVersion: number?,
	Snapshot: VaultSnapshot?,
	FailureReason: string?,
	ReleaseTargetState: string?,
}

local BankVaultExample = {}

local function formatCurrency(amount: number): string
	return string.format("$%.2f", amount)
end

--[[
	@description Resolves the shared vault entity from either Context.VaultEntity or
	Context.VaultEntityId, caching the result on the FSM context for later states.
	@param fsm any
	@return any?
]]
local function resolveVaultEntity(fsm: any): any?
	local context = (fsm.Context :: VaultTransactionContext)
	if context.VaultEntity then
		return context.VaultEntity
	end

	if type(context.VaultEntityId) ~= "string" then
		return nil
	end

	local entity = fsm:GetEntity(context.VaultEntityId)
	if entity then
		context.VaultEntity = entity
	end

	return entity
end

--[[
	@description Moves the FSM onto the rollback path with a standardized failure reason.
	@param fsm any
	@param reason string
	@return ()
]]
local function failToRollback(fsm: any, reason: string)
	local context = (fsm.Context :: VaultTransactionContext)
	context.FailureReason = reason
	context.ReleaseTargetState = "Failed"
	fsm.State = "Rollback"
end

--[[
	@description Creates a concrete transaction FSM definition that uses entity-wide
	locking to serialize access to the shared vault.
	@param jobName string
	@param signedDirection number
	@param requiresFunds boolean
	@return any
]]
local function createVaultJob(jobName: string, signedDirection: number, requiresFunds: boolean): any
	local operationLabel = if signedDirection > 0 then "Deposit" else "Withdrawal"
	local job: any = {
		Name = jobName,
		ValidStates = { "Validate", "AcquireLock", "Process", "Commit", "ReleaseLock", "Rollback", "Completed", "Failed" },
		TerminalStates = { "Completed", "Failed" },
		InitialState = "Validate",
	}

	--[[
		@description Registers the Validate -> AcquireLock -> Process -> Commit -> ReleaseLock
		flow plus the Rollback -> ReleaseLock -> Failed recovery path.
		@return ()
	]]
	function job:RegisterStates()
		self:AddState("Validate", function(fsm)
			local context = (fsm.Context :: VaultTransactionContext)
			local vaultEntity = resolveVaultEntity(fsm)
			local amount = context.Amount

			if type(amount) ~= "number" or amount <= 0 then
				failToRollback(fsm, string.format("%s amount must be greater than zero.", operationLabel))
				return
			end

			if not vaultEntity then
				failToRollback(fsm, "Vault entity could not be resolved.")
				return
			end

			context.RetryCount = 0
			context.LockHeld = false
			context.PreTransactionVersion = nil
			context.Snapshot = nil
			context.FailureReason = nil
			context.ReleaseTargetState = "Completed"
			fsm.State = "AcquireLock"
		end, { "AcquireLock", "Rollback" })

		self:AddState("AcquireLock", function(fsm)
			local context = (fsm.Context :: VaultTransactionContext)
			local vaultEntity = resolveVaultEntity(fsm)
			if not vaultEntity then
				failToRollback(fsm, "Vault entity disappeared before the lock step.")
				return
			end

			local acquired = vaultEntity:AcquireLock(fsm.Id)
			if acquired then
				context.LockHeld = true
				fsm:Log({
					Level = "INFO",
					Message = string.format("%s acquired lock on %s.", fsm.Id, tostring(context.VaultEntityId or vaultEntity.Name or "vault")),
				})
				fsm.State = "Process"
				return
			end

			local retryCount = (context.RetryCount or 0) + 1
			context.RetryCount = retryCount
			if retryCount >= LOCK_RETRY_LIMIT then
				failToRollback(fsm, string.format(
					"%s could not acquire the entity lock after %d attempts.",
					operationLabel,
					LOCK_RETRY_LIMIT
				))
				return
			end

			fsm:Log({
				Level = "WARN",
				Message = string.format(
					"%s lock busy; retry %d/%d in %.1fs.",
					operationLabel,
					retryCount,
					LOCK_RETRY_LIMIT,
					LOCK_RETRY_WAIT
				),
			})
			fsm.WaitSpan = LOCK_RETRY_WAIT
			fsm.State = "AcquireLock"
		end, { "AcquireLock", "Process", "Rollback" })

		self:AddState("Process", function(fsm)
			local context = (fsm.Context :: VaultTransactionContext)
			local vaultEntity = resolveVaultEntity(fsm)
			if not vaultEntity then
				failToRollback(fsm, "Vault entity disappeared during processing.")
				return
			end

			local amount = context.Amount
			local currentBalance = vaultEntity.Balance or 0
			if requiresFunds and currentBalance < amount then
				failToRollback(fsm, string.format(
					"Insufficient funds: attempted to withdraw %s from balance %s.",
					formatCurrency(amount),
					formatCurrency(currentBalance)
				))
				return
			end

			context.PreTransactionVersion = vaultEntity.Version
			context.Snapshot = {
				Balance = currentBalance,
				LastTransaction = vaultEntity.LastTransaction or "Vault initialized.",
				TransactionCount = vaultEntity.TransactionCount or 0,
				IsProcessing = vaultEntity.IsProcessing == true,
			}

			local nextBalance = currentBalance + (amount * signedDirection)
			vaultEntity.IsProcessing = true
			vaultEntity.Balance = nextBalance
			vaultEntity.TransactionCount = (context.Snapshot :: VaultSnapshot).TransactionCount + 1
			vaultEntity.LastTransaction = string.format(
				"%s %s by %s -> balance %s",
				operationLabel,
				formatCurrency(amount),
				fsm.Id,
				formatCurrency(nextBalance)
			)
			fsm.State = "Commit"
		end, { "Commit", "Rollback" })

		self:AddState("Commit", function(fsm)
			local context = (fsm.Context :: VaultTransactionContext)
			local vaultEntity = resolveVaultEntity(fsm)
			if not vaultEntity then
				failToRollback(fsm, "Vault entity disappeared before commit.")
				return
			end

			-- Even while holding a lock, a version check is useful as a final sanity
			-- guard if some external system modified the entity unexpectedly.
			if vaultEntity.Version ~= context.PreTransactionVersion then
				failToRollback(fsm, string.format(
					"Optimistic version check failed in Commit (expected v%d, found v%d).",
					context.PreTransactionVersion or -1,
					vaultEntity.Version
				))
				return
			end

			-- Locked commit: UpdateEntity(fsm.Id) only succeeds because this FSM holds
			-- the entity-wide lock acquired in AcquireLock.
			local committed = vaultEntity:UpdateEntity(fsm.Id)
			if not committed then
				failToRollback(fsm, string.format("%s commit failed while lock was held.", operationLabel))
				return
			end

			context.ReleaseTargetState = "Completed"
			fsm.State = "ReleaseLock"
		end, { "ReleaseLock", "Rollback" })

		self:AddState("Rollback", function(fsm)
			local context = (fsm.Context :: VaultTransactionContext)
			local vaultEntity = resolveVaultEntity(fsm)
			if vaultEntity and context.LockHeld then
				local hasRollbackChanges = false
				local snapshot = context.Snapshot
				if snapshot then
					vaultEntity.Balance = snapshot.Balance
					vaultEntity.LastTransaction = snapshot.LastTransaction
					vaultEntity.TransactionCount = snapshot.TransactionCount
					hasRollbackChanges = true
				end
				if vaultEntity.IsProcessing == true then
					vaultEntity.IsProcessing = false
					hasRollbackChanges = true
				end

				if hasRollbackChanges then
					local rollbackCommitted = vaultEntity:UpdateEntity(fsm.Id)
					if not rollbackCommitted then
						fsm:Log({
							Level = "ERROR",
							Message = string.format("Rollback commit failed for %s.", fsm.Id),
						})
					end
				end
			end

			context.ReleaseTargetState = "Failed"
			fsm.State = "ReleaseLock"
		end, { "ReleaseLock" })

		self:AddState("ReleaseLock", function(fsm)
			local context = (fsm.Context :: VaultTransactionContext)
			local vaultEntity = resolveVaultEntity(fsm)
			local targetState = context.ReleaseTargetState or "Completed"

			if vaultEntity and context.LockHeld then
				if targetState == "Completed" and vaultEntity.IsProcessing == true then
					vaultEntity.IsProcessing = false
					local processingCleared = vaultEntity:UpdateEntity(fsm.Id)
					if not processingCleared then
						fsm:Log({
							Level = "WARN",
							Message = "Committed transaction succeeded, but clearing IsProcessing failed.",
						})
					end
				end

				local released = vaultEntity:ReleaseLock(fsm.Id)
				if not released then
					fsm:Log({
						Level = "ERROR",
						Message = string.format("%s failed to release the vault lock.", fsm.Id),
					})
				else
					context.LockHeld = false
				end
			end

			fsm.State = targetState
		end, { "Completed", "Failed" })

		self:AddState("Completed", function(fsm)
			fsm:Log({
				Level = "INFO",
				Message = string.format("%s completed successfully.", operationLabel),
			})
		end)

		self:AddState("Failed", function(fsm)
			local context = (fsm.Context :: VaultTransactionContext)
			fsm:Log({
				Level = "ERROR",
				Message = string.format("%s failed: %s", operationLabel, tostring(context.FailureReason or "Unknown error")),
			})
		end)
	end

	--[[
		@description Safety cleanup so a cancelled/destroyed job cannot leak a held
		lock on the shared vault entity.
		@return ()
	]]
	function job:OnCleanup()
		local context = (self.Context :: VaultTransactionContext)
		local vaultEntity = resolveVaultEntity(self)
		if not vaultEntity or not context.LockHeld then
			return
		end

		if vaultEntity.IsProcessing == true then
			vaultEntity.IsProcessing = false
			vaultEntity:UpdateEntity(self.Id)
		end

		vaultEntity:ReleaseLock(self.Id)
		context.LockHeld = false
	end

	return job
end

local BankVaultEntity = {
	Name = "BankVaultEntity",
	Mutable = true,
	Replication = {
		Enabled = true,
		RateLimit = 30,
	},
	Schema = {
		Balance = { Type = "number", Replicate = true, Persist = true, Description = "Current vault balance." },
		LastTransaction = { Type = "string", Replicate = true, Description = "Description of the last committed transaction." },
		TransactionCount = { Type = "number", Replicate = true, Description = "Number of committed transactions." },
		IsProcessing = { Type = "boolean", Replicate = true, Description = "True while a job holds the lock and is mutating the vault." },
	},
}

--[[
	@description Initializes the shared vault defaults. The balance starts at 1000 so
	the demo can safely show both a deposit and a withdrawal.
	@param params { [any]: any }
	@return { [string]: any }
]]
function BankVaultEntity:GetContext(params: { [any]: any }): { [string]: any }
	local _ = params
	return {
		Balance = if type(self.Balance) == "number" then self.Balance else 1000,
		LastTransaction = if type(self.LastTransaction) == "string" then self.LastTransaction else "Vault initialized.",
		TransactionCount = if type(self.TransactionCount) == "number" then self.TransactionCount else 0,
		IsProcessing = self.IsProcessing == true,
	}
end

--[[
	@description Applies replicated vault changes on the client. The entity writes a
	few attributes for lightweight debug visibility, then updates optional UI labels
	if the model contains them.
	@param changes { [string]: any }
	@return ()
]]
function BankVaultEntity:ApplyChanges(changes: { [string]: any })
	if not RunService:IsClient() then
		return
	end

	local instance = self.Instance
	if not instance then
		return
	end

	instance:SetAttribute("VaultBalance", self.Balance)
	instance:SetAttribute("VaultLastTransaction", self.LastTransaction)
	instance:SetAttribute("VaultTransactionCount", self.TransactionCount)
	instance:SetAttribute("VaultIsProcessing", self.IsProcessing)

	local balanceLabel = instance:FindFirstChild("BalanceLabel", true)
	if balanceLabel and (balanceLabel:IsA("TextLabel") or balanceLabel:IsA("TextButton") or balanceLabel:IsA("TextBox")) then
		balanceLabel.Text = string.format("Balance: %s", formatCurrency(self.Balance or 0))
	end

	local lastTransactionLabel = instance:FindFirstChild("LastTransactionLabel", true)
	if lastTransactionLabel and (lastTransactionLabel:IsA("TextLabel") or lastTransactionLabel:IsA("TextButton") or lastTransactionLabel:IsA("TextBox")) then
		lastTransactionLabel.Text = string.format("Last: %s", tostring(self.LastTransaction or "-"))
	end

	local transactionCountLabel = instance:FindFirstChild("TransactionCountLabel", true)
	if transactionCountLabel and (transactionCountLabel:IsA("TextLabel") or transactionCountLabel:IsA("TextButton") or transactionCountLabel:IsA("TextBox")) then
		transactionCountLabel.Text = string.format("Transactions: %d", self.TransactionCount or 0)
	end

	local processingIndicator = instance:FindFirstChild("ProcessingIndicator", true)
	if processingIndicator and processingIndicator:IsA("GuiObject") then
		processingIndicator.Visible = self.IsProcessing == true
	end

	local vaultDoor = instance:FindFirstChild("VaultDoor", true)
	if vaultDoor and vaultDoor:IsA("BasePart") and changes.IsProcessing ~= nil then
		vaultDoor.Color = if self.IsProcessing == true then Color3.fromRGB(255, 170, 0) else Color3.fromRGB(0, 170, 255)
	end
end

local DepositJob = createVaultJob("DepositJob", 1, false)
local WithdrawJob = createVaultJob("WithdrawJob", -1, true)

--[[
	@description Alternative lock-free pattern for short-lived updates: capture the
	entity version, compute desired values off to the side, then verify the version
	is unchanged before staging and committing.
	@param entity any
	@param amount number
	@return boolean, string?
]]
function BankVaultExample.TryOptimisticDeposit(entity: any, amount: number): (boolean, string?)
	if type(amount) ~= "number" or amount <= 0 then
		return false, "Optimistic deposit amount must be greater than zero."
	end

	local startingVersion = entity.Version
	local startingBalance = entity.Balance or 0
	local startingCount = entity.TransactionCount or 0
	local projectedBalance = startingBalance + amount

	-- Do expensive lock-free work here. If another system updates the entity while
	-- you are thinking, the version changes and this optimistic commit must abort.
	if entity.Version ~= startingVersion then
		return false, "Vault changed while preparing the optimistic update."
	end

	entity.Balance = projectedBalance
	entity.TransactionCount = startingCount + 1
	entity.LastTransaction = string.format(
		"Optimistic deposit %s -> balance %s",
		formatCurrency(amount),
		formatCurrency(projectedBalance)
	)

	local committed = entity:UpdateEntity()
	if not committed then
		return false, "Optimistic UpdateEntity() failed."
	end

	return true, nil
end

--[[
	@description Convenience helper that shows the two competing jobs from the
	concurrency demo comment below.
	@param Orchestrator any
	@return { Vault: any, Deposit: any, Withdraw: any }
]]
function BankVaultExample.CreateCompetingJobs(Orchestrator: any)
	local vault = Orchestrator.CreateEntity({
		EntityClass = "BankVaultEntity",
		EntityId = "Vault_Main",
		Context = {
			OwnerId = "BankVaultExample",
			Instance = workspace:FindFirstChild("Vault_Main"),
		},
	})

	local deposit = Orchestrator.CreateStateMachine({
		StateMachineClass = "DepositJob",
		StateMachineId = "deposit-001",
		Context = {
			VaultEntityId = "Vault_Main",
			Amount = 500,
		},
	})

	local withdraw = Orchestrator.CreateStateMachine({
		StateMachineClass = "WithdrawJob",
		StateMachineId = "withdraw-001",
		Context = {
			VaultEntityId = "Vault_Main",
			Amount = 200,
		},
	})

	deposit:Start({ State = "Validate" })
	withdraw:Start({ State = "Validate" })

	return {
		Vault = vault,
		Deposit = deposit,
		Withdraw = withdraw,
	}
end

-- ConcurrencyDemo
-- Two jobs targeting the same entity — the lock ensures serial access:
--
-- local deposit = Orchestrator.CreateStateMachine({
--     StateMachineClass = "DepositJob",
--     StateMachineId = "deposit-001",
--     Context = { VaultEntityId = "Vault_Main", Amount = 500 },
-- })
--
-- local withdraw = Orchestrator.CreateStateMachine({
--     StateMachineClass = "WithdrawJob",
--     StateMachineId = "withdraw-001",
--     Context = { VaultEntityId = "Vault_Main", Amount = 200 },
-- })
--
-- Both start simultaneously. One acquires the lock first.
-- The other retries via WaitSpan until the lock is released.
-- Result: Balance = 1000 + 500 - 200 = 1300 (no race condition)
--
-- Optimistic alternative:
-- local version = vaultEntity.Version
-- local projectedBalance = vaultEntity.Balance + 50
-- -- ... do work without holding the lock ...
-- if vaultEntity.Version ~= version then
--     return -- another system changed the vault; abort instead of overwriting it
-- end
-- vaultEntity.Balance = projectedBalance
-- vaultEntity:UpdateEntity()

BankVaultExample.BankVaultEntity = BankVaultEntity
BankVaultExample.DepositJob = DepositJob
BankVaultExample.WithdrawJob = WithdrawJob

return BankVaultExample
