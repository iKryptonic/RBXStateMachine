--!strict
--[=[
	@Name VotingBoothExample
	@Author Copilot
	@Description End-to-end networking example showing replicated entity state,
	server-authoritative entity commands, synchronous server requests, EventBus
	notifications, and a timed voting FSM built on RBXStateMachine.
]=]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Orchestrator = require(ReplicatedStorage:WaitForChild("Orchestrator"))

type VoteResults = {
	TopicName: string,
	OptionA: string,
	OptionB: string,
	VotesA: number,
	VotesB: number,
	TotalVotes: number,
	Winner: string,
	WinningChoice: string,
	IsTie: boolean,
	VotingClosed: boolean,
}

type VotingSessionContext = {
	BoothInstance: Instance,
	BoothEntityId: string,
	BoothEntityClass: any?,
	BoothEntity: any?,
	TopicName: string,
	OptionA: string,
	OptionB: string,
	Results: VoteResults?,
	_voteWindowLogged: boolean?,
	_busListenerConnected: boolean?,
}

local VOTE_COMPLETED_BUS = "VoteCompleted"
local RESULTS_REQUEST_NAME = "GetVotingResults"

local compiledBoothEntityClass: any? = nil
local compiledVotingSessionClass: any? = nil

local VotingBoothEntity = {
	Name = "VotingBoothEntity",
	Replication = {
		Enabled = true,
		RateLimit = 15,
	},
	Schema = {
		TopicName = { Type = "string", Replicate = true, Description = "Question shown above the booth." },
		OptionA = { Type = "string", Replicate = true, Description = "Display label for option A." },
		OptionB = { Type = "string", Replicate = true, Description = "Display label for option B." },
		VotesA = { Type = "number", Replicate = true, Description = "Server-authoritative vote count for option A." },
		VotesB = { Type = "number", Replicate = true, Description = "Server-authoritative vote count for option B." },
		IsOpen = { Type = "boolean", Replicate = true, Description = "True while the booth accepts votes." },
		_voters = { Type = "any", Description = "Server-only set of userIds that have already voted." },
	},
}

local VotingSessionFSM = {
	Name = "VotingSessionFSM",
	ValidStates = { "Setup", "OpenVoting", "WaitForVotes", "CloseVoting", "AnnounceResults", "Completed" },
	TerminalStates = { "Completed" },
	InitialState = "Setup",
}

--[[
	@description Returns an existing child with the requested name/class, or creates it.
	@param parent Instance
	@param className string
	@param name string
	@return Instance
	@reads parent children
	@writes parent children
]]
local function ensureChild(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local child = Instance.new(className :: any)
	child.Name = name
	child.Parent = parent
	return child
end

--[[
	@description Resolves the BasePart used as the BillboardGui adornee.
	@param boothInstance Instance
	@return BasePart?
	@reads boothInstance hierarchy
	@writes None
]]
local function getBoothAdornee(boothInstance: Instance): BasePart?
	if boothInstance:IsA("BasePart") then
		return boothInstance
	end

	if boothInstance:IsA("Model") then
		return boothInstance.PrimaryPart or boothInstance:FindFirstChildWhichIsA("BasePart", true)
	end

	return boothInstance:FindFirstChildWhichIsA("BasePart", true)
end

--[[
	@description Renders or updates a single voting row inside the booth billboard.
	@param root Frame
	@param rowName string
	@param yOffset number
	@param labelText string
	@param fillColor Color3
	@param votes number
	@param totalVotes number
	@return ()
	@reads existing UI instances
	@writes row visuals and text
]]
local function renderVoteRow(
	root: Frame,
	rowName: string,
	yOffset: number,
	labelText: string,
	fillColor: Color3,
	votes: number,
	totalVotes: number
): ()
	local row = ensureChild(root, "Frame", rowName) :: Frame
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, -16, 0, 28)
	row.Position = UDim2.fromOffset(8, yOffset)

	local label = ensureChild(row, "TextLabel", "Label") :: TextLabel
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamMedium
	label.TextColor3 = Color3.fromRGB(240, 240, 240)
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Size = UDim2.new(0.34, 0, 1, 0)
	label.Text = labelText

	local barBackground = ensureChild(row, "Frame", "BarBackground") :: Frame
	barBackground.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
	barBackground.BorderSizePixel = 0
	barBackground.Position = UDim2.new(0.36, 0, 0.5, -8)
	barBackground.Size = UDim2.new(0.46, 0, 0, 16)
	barBackground.ClipsDescendants = true

	local barCorner = ensureChild(barBackground, "UICorner", "Corner") :: UICorner
	barCorner.CornerRadius = UDim.new(0, 6)

	local barFill = ensureChild(barBackground, "Frame", "Fill") :: Frame
	barFill.BackgroundColor3 = fillColor
	barFill.BorderSizePixel = 0
	barFill.Size = UDim2.new(math.clamp(totalVotes > 0 and (votes / totalVotes) or 0, 0, 1), 0, 1, 0)

	local fillCorner = ensureChild(barFill, "UICorner", "Corner") :: UICorner
	fillCorner.CornerRadius = UDim.new(0, 6)

	local percentage = if totalVotes > 0 then math.floor(((votes / totalVotes) * 100) + 0.5) else 0
	local countLabel = ensureChild(row, "TextLabel", "Count") :: TextLabel
	countLabel.BackgroundTransparency = 1
	countLabel.BorderSizePixel = 0
	countLabel.Font = Enum.Font.Gotham
	countLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
	countLabel.TextSize = 13
	countLabel.TextXAlignment = Enum.TextXAlignment.Right
	countLabel.Position = UDim2.new(0.84, 0, 0, 0)
	countLabel.Size = UDim2.new(0.16, 0, 1, 0)
	countLabel.Text = string.format("%d (%d%%)", votes, percentage)
end

--[[
	@description Updates the client-side BillboardGui bar chart for the replicated booth.
	@param boothInstance Instance
	@param topicName string
	@param optionA string
	@param optionB string
	@param votesA number
	@param votesB number
	@param isOpen boolean
	@return ()
	@reads boothInstance hierarchy
	@writes BillboardGui descendants
]]
local function renderBoothBillboard(
	boothInstance: Instance,
	topicName: string,
	optionA: string,
	optionB: string,
	votesA: number,
	votesB: number,
	isOpen: boolean
): ()
	local adornee = getBoothAdornee(boothInstance)
	if not adornee then
		return
	end

	local billboard = ensureChild(boothInstance, "BillboardGui", "VotingBillboard") :: BillboardGui
	billboard.Name = "VotingBillboard"
	billboard.Adornee = adornee
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(240, 128)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.MaxDistance = 120

	local root = ensureChild(billboard, "Frame", "Root") :: Frame
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Color3.fromRGB(19, 24, 33)
	root.BackgroundTransparency = 0.15
	root.BorderSizePixel = 0

	local rootCorner = ensureChild(root, "UICorner", "Corner") :: UICorner
	rootCorner.CornerRadius = UDim.new(0, 10)

	local stroke = ensureChild(root, "UIStroke", "Stroke") :: UIStroke
	stroke.Color = Color3.fromRGB(85, 170, 255)
	stroke.Transparency = 0.2
	stroke.Thickness = 1

	local title = ensureChild(root, "TextLabel", "Topic") :: TextLabel
	title.BackgroundTransparency = 1
	title.BorderSizePixel = 0
	title.Font = Enum.Font.GothamBold
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 15
	title.TextWrapped = true
	title.TextYAlignment = Enum.TextYAlignment.Top
	title.Position = UDim2.fromOffset(8, 8)
	title.Size = UDim2.new(1, -16, 0, 34)
	title.Text = topicName ~= "" and topicName or "Voting Booth"

	local status = ensureChild(root, "TextLabel", "Status") :: TextLabel
	status.BackgroundTransparency = 1
	status.BorderSizePixel = 0
	status.Font = Enum.Font.GothamMedium
	status.TextColor3 = isOpen and Color3.fromRGB(120, 255, 120) or Color3.fromRGB(255, 170, 120)
	status.TextSize = 13
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Position = UDim2.fromOffset(8, 38)
	status.Size = UDim2.new(1, -16, 0, 18)
	status.Text = isOpen and "Voting is OPEN" or "Voting is CLOSED"

	local totalVotes = votesA + votesB
	renderVoteRow(root, "OptionARow", 62, optionA ~= "" and optionA or "Option A", Color3.fromRGB(95, 205, 255), votesA, totalVotes)
	renderVoteRow(root, "OptionBRow", 92, optionB ~= "" and optionB or "Option B", Color3.fromRGB(255, 170, 0), votesB, totalVotes)
end

--[[
	@description Normalizes the incoming vote choice to "A" or "B".
	@param choice any
	@return string?
	@reads None
	@writes None
]]
local function normalizeVoteChoice(choice: any): string?
	if type(choice) ~= "string" then
		return nil
	end

	local normalized = string.upper(choice)
	if normalized == "A" or normalized == "B" then
		return normalized
	end

	return nil
end

--[[
	@description Builds a read-only results snapshot from the replicated booth state.
	@param boothEntity any
	@return VoteResults
	@reads boothEntity replicated fields
	@writes None
]]
local function buildResultsSnapshot(boothEntity: any): VoteResults
	local votesA = boothEntity.VotesA or 0
	local votesB = boothEntity.VotesB or 0
	local isTie = votesA == votesB
	local winningChoice = if isTie then "Tie" elseif votesA > votesB then "A" else "B"
	local winner = if isTie then "Tie" elseif votesA > votesB then boothEntity.OptionA else boothEntity.OptionB

	return {
		TopicName = boothEntity.TopicName or "",
		OptionA = boothEntity.OptionA or "Option A",
		OptionB = boothEntity.OptionB or "Option B",
		VotesA = votesA,
		VotesB = votesB,
		TotalVotes = votesA + votesB,
		Winner = winner,
		WinningChoice = winningChoice,
		IsTie = isTie,
		VotingClosed = boothEntity.IsOpen ~= true,
	}
end

--[[
	@description Initializes client/server context for the voting booth entity.
	@param params { [any]: any }
	@return { [string]: any }
	@reads self.Instance, replicated fields
	@writes None
]]
function VotingBoothEntity:GetContext(params: { [any]: any }): { [string]: any }
	return {
		Instance = self.Instance or params.Instance,
		TopicName = self.TopicName or "",
		OptionA = self.OptionA or "",
		OptionB = self.OptionB or "",
		VotesA = self.VotesA or 0,
		VotesB = self.VotesB or 0,
		IsOpen = false,
		_voters = {},
	}
end

--[[
	@description Applies replicated changes on the client by redrawing the vote chart.
	@param changes { [string]: any }
	@return ()
	@reads self.Instance, replicated booth data
	@writes BillboardGui descendants
]]
function VotingBoothEntity:ApplyChanges(changes: { [string]: any }): ()
	if not RunService:IsClient() then
		return
	end

	if not self.Instance then
		return
	end

	if next(changes) == nil then
		return
	end

	renderBoothBillboard(
		self.Instance,
		self.TopicName or "",
		self.OptionA or "Option A",
		self.OptionB or "Option B",
		self.VotesA or 0,
		self.VotesB or 0,
		self.IsOpen == true
	)
end

--[[
	@description Registers the voting FSM states and wires the full networking stack.
	@return ()
	@reads fsm.Context, Orchestrator networking APIs
	@writes entity state, server request registry, event buses
]]
function VotingSessionFSM:RegisterStates()
	self:AddState("Setup", function(fsm)
		local context = fsm.Context :: VotingSessionContext
		local boothEntityId = context.BoothEntityId or (context.BoothInstance.Name .. "_VotingBooth")
		local booth = Orchestrator.CreateEntity({
			EntityClass = context.BoothEntityClass or "VotingBoothEntity",
			EntityId = boothEntityId,
			Context = {
				Instance = context.BoothInstance,
				OwnerId = fsm.Id,
			},
		})

		if not booth then
			fsm:Fail("Failed to create VotingBoothEntity")
			return
		end

		booth.TopicName = context.TopicName
		booth.OptionA = context.OptionA
		booth.OptionB = context.OptionB
		booth.VotesA = 0
		booth.VotesB = 0
		booth.IsOpen = false
		booth._voters = {}

		if not booth:UpdateEntity() then
			fsm:Fail("Failed to initialize voting booth state")
			return
		end

		context.BoothEntity = booth
		context.BoothEntityId = boothEntityId

		Orchestrator.RegisterEventBus(VOTE_COMPLETED_BUS)
		local voteCompletedBus = Orchestrator.AwaitEventBus(VOTE_COMPLETED_BUS, 1)
		if voteCompletedBus and not context._busListenerConnected then
			context._busListenerConnected = true
			fsm:Manage(voteCompletedBus:Connect(function(topicName: string, results: VoteResults)
				fsm:Log({
					Level = "INFO",
					Message = string.format(
						"EventBus subscriber received vote completion for '%s' (winner: %s).",
						topicName,
						results.Winner
					),
				})
			end))
		end

		Orchestrator.RegisterServerRequestCallback(RESULTS_REQUEST_NAME, function(player: Player, requestedBoothEntityId: string?)
			if requestedBoothEntityId and requestedBoothEntityId ~= boothEntityId then
				return nil
			end

			local results = buildResultsSnapshot(booth)
			local voterSet = booth._voters
			local hasVoted = type(voterSet) == "table" and voterSet[player.UserId] == true
			(results :: any).CanVote = booth.IsOpen == true and not hasVoted
			return results
		end, false)

		fsm.State = "OpenVoting"
	end, { "OpenVoting" })

	self:AddState("OpenVoting", function(fsm)
		local context = fsm.Context :: VotingSessionContext
		local booth = context.BoothEntity
		if not booth then
			fsm:Fail("Voting booth was not created during setup")
			return
		end

		Orchestrator.RegisterEntityCommandCallback(context.BoothEntityId, "CastVote", function(player: Player, choice: any)
			local normalizedChoice = normalizeVoteChoice(choice)
			if booth.IsOpen ~= true then
				fsm:Log({
					Level = "WARN",
					Message = string.format("Rejected vote from %s because voting is closed.", player.Name),
				})
				return
			end

			if not normalizedChoice then
				fsm:Log({
					Level = "WARN",
					Message = string.format("Rejected invalid vote payload from %s.", player.Name),
				})
				return
			end

			local currentVoters = booth._voters
			local voters = if type(currentVoters) == "table" then table.clone(currentVoters) else {}
			if voters[player.UserId] == true then
				fsm:Log({
					Level = "WARN",
					Message = string.format("Rejected duplicate vote from %s.", player.Name),
				})
				return
			end

			voters[player.UserId] = true
			booth._voters = voters
			if normalizedChoice == "A" then
				booth.VotesA = (booth.VotesA or 0) + 1
			else
				booth.VotesB = (booth.VotesB or 0) + 1
			end

			if booth:UpdateEntity() then
				fsm:Log({
					Level = "INFO",
					Message = string.format("Accepted vote from %s for option %s.", player.Name, normalizedChoice),
				})
			else
				fsm:Log({
					Level = "ERROR",
					Message = string.format("Failed to commit vote from %s.", player.Name),
				})
			end
		end)

		booth.IsOpen = true
		if not booth:UpdateEntity() then
			fsm:Fail("Failed to open voting booth")
			return
		end

		fsm:Log({
			Level = "INFO",
			Message = string.format(
				"Voting opened for '%s'. Replicate=true fields now auto-sync to clients.",
				booth.TopicName
			),
		})
		fsm.State = "WaitForVotes"
	end, { "WaitForVotes" })

	self:AddState("WaitForVotes", function(fsm)
		local context = fsm.Context :: VotingSessionContext
		if not context._voteWindowLogged then
			context._voteWindowLogged = true
			fsm:Log({
				Level = "INFO",
				Message = "Voting window active for 30 seconds.",
			})
		end

		fsm:ScheduleTransition(30, "CloseVoting")
	end, { "CloseVoting" })

	self:AddState("CloseVoting", function(fsm)
		local booth = (fsm.Context :: VotingSessionContext).BoothEntity
		if not booth then
			fsm:Fail("Voting booth disappeared before close")
			return
		end

		booth.IsOpen = false
		if not booth:UpdateEntity() then
			fsm:Fail("Failed to close voting booth")
			return
		end

		fsm:Log({
			Level = "INFO",
			Message = "Voting window closed. Late votes will now be rejected by the server-authoritative command handler.",
		})
		fsm.State = "AnnounceResults"
	end, { "AnnounceResults" })

	self:AddState("AnnounceResults", function(fsm)
		local context = fsm.Context :: VotingSessionContext
		local booth = context.BoothEntity
		if not booth then
			fsm:Fail("Voting booth missing during result announcement")
			return
		end

		local results = buildResultsSnapshot(booth)
		context.Results = results
		Orchestrator.FireEventBus(VOTE_COMPLETED_BUS, results.TopicName, results)

		fsm:Log({
			Level = "INFO",
			Message = string.format(
				"Vote complete for '%s'. Winner: %s. Final tally: %d vs %d.",
				results.TopicName,
				results.Winner,
				results.VotesA,
				results.VotesB
			),
		})
		fsm.State = "Completed"
	end, { "Completed" })

	self:AddState("Completed", function(fsm)
		fsm:Log({
			Level = "INFO",
			Message = "Voting session reached its terminal state.",
		})
	end)
end

--[[
	@description Cleans up the server-side entity command registration for this booth.
	@return ()
	@reads self.Context.BoothEntityId
	@writes NetworkManager command registry
]]
function VotingSessionFSM:OnCleanup(): ()
	local context = self.Context :: VotingSessionContext
	if context.BoothEntityId ~= nil then
		Orchestrator.NetworkManager.UnregisterEntityCommands(context.BoothEntityId)
	end
end

--[[
	@description Compiles an example definition table into a usable framework class.
	@param definition { [string]: any }
	@param baseClass any
	@return any
	@reads definition fields
	@writes compiled subclass table
]]
local function compileExampleClass(definition: { [string]: any }, baseClass: any): any
	local effectiveDefinition = table.clone(definition)
	if effectiveDefinition.Name == nil then
		effectiveDefinition.Name = "ExampleClass"
	end
	if effectiveDefinition.className == nil then
		effectiveDefinition.className = effectiveDefinition.Name
	end

	local subclass = baseClass.Extend(effectiveDefinition)
	for key, value in pairs(definition) do
		if key ~= "Name" and key ~= "Schema" and key ~= "ValidStates" and key ~= "Definition" then
			subclass[key] = value
		end
	end

	return subclass
end

--[[
	@description Lazily compiles the example Entity and FSM so StartServerExample can run directly.
	@return any, any
	@reads ReplicatedStorage.Orchestrator.Core.Factory modules
	@writes cached compiled classes
]]
local function getCompiledExampleClasses(): (any, any)
	if compiledBoothEntityClass and compiledVotingSessionClass then
		return compiledBoothEntityClass, compiledVotingSessionClass
	end

	local orchestratorModule = ReplicatedStorage:WaitForChild("Orchestrator")
	local coreFolder = orchestratorModule:WaitForChild("Core")
	local factoryFolder = coreFolder:WaitForChild("Factory")
	local BaseEntity = require(factoryFolder:WaitForChild("BaseEntity"))
	local BaseStateMachine = require(factoryFolder:WaitForChild("BaseStateMachine"))

	compiledBoothEntityClass = compileExampleClass(VotingBoothEntity, BaseEntity)
	compiledVotingSessionClass = compileExampleClass(VotingSessionFSM, BaseStateMachine)
	return compiledBoothEntityClass, compiledVotingSessionClass
end

local VotingBoothExample = {
	VotingBoothEntity = VotingBoothEntity,
	VotingSessionFSM = VotingSessionFSM,
}

--[[
	@description Bootstraps the voting example directly from a server script.
	@param params { BoothInstance: Instance, TopicName: string, OptionA: string, OptionB: string, BoothEntityId: string?, StateMachineId: string? }
	@return any
	@reads Orchestrator, compiled example classes
	@writes entity/FSM registries
]]
function VotingBoothExample.StartServerExample(params: {
	BoothInstance: Instance,
	TopicName: string,
	OptionA: string,
	OptionB: string,
	BoothEntityId: string?,
	StateMachineId: string?,
}): any
	Orchestrator:RegisterComponents()
	local boothEntityClass, votingSessionClass = getCompiledExampleClasses()

	return Orchestrator.CreateStateMachine({
		StateMachineClass = votingSessionClass,
		StateMachineId = params.StateMachineId or string.format("VotingSession_%s", params.BoothInstance.Name),
		Context = {
			BoothInstance = params.BoothInstance,
			BoothEntityId = params.BoothEntityId or string.format("%s_VotingBooth", params.BoothInstance.Name),
			BoothEntityClass = boothEntityClass,
			TopicName = params.TopicName,
			OptionA = params.OptionA,
			OptionB = params.OptionB,
		},
	})
end

-- SERVER USAGE (in a server script):
-- local VotingExample = require(ReplicatedStorage.Examples.VotingBoothExample)
-- VotingExample.StartServerExample({
-- 	BoothInstance = workspace.VotingBooth,
-- 	TopicName = "Best starter companion?",
-- 	OptionA = "Dragon",
-- 	OptionB = "Wolf",
-- })
--
-- CLIENT USAGE (in a client script):
-- Orchestrator.ServerCommandEntity(boothEntityId, "CastVote", "A")
-- local results = Orchestrator.ServerRequest("GetVotingResults")
--
-- EVENT BUS USAGE (server-side observer):
-- local voteCompletedBus = Orchestrator.AwaitEventBus("VoteCompleted", 30)
-- if voteCompletedBus then
-- 	local topicName, results = voteCompletedBus:Wait()
-- 	print(topicName, results.Winner)
-- end

return VotingBoothExample
