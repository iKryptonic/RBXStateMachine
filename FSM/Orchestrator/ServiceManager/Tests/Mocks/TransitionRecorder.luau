--!strict

local TransitionRecorder = {}
TransitionRecorder.__index = TransitionRecorder

local function shallowClone(source: any): any
	if type(source) ~= "table" then
		return source
	end

	local clone = {}
	for key, value in pairs(source) do
		clone[key] = value
	end
	return clone
end

local function normalizeExpected(fromOrExpected: any, toState: any?, fsmId: string?): any
	if type(fromOrExpected) == "table" then
		return {
			From = fromOrExpected.From,
			To = fromOrExpected.To,
			FsmId = fromOrExpected.FsmId or fromOrExpected.FSMId or fromOrExpected.Id,
		}
	end

	return {
		From = fromOrExpected,
		To = toState,
		FsmId = fsmId,
	}
end

function TransitionRecorder.new(): any
	local self = setmetatable({
		records = {},
		cursors = {},
	}, TransitionRecorder)
	self.Transitions = self.records
	return self
end

function TransitionRecorder:Reset()
	table.clear(self.records)
	table.clear(self.cursors)
end

function TransitionRecorder:Record(fromOrEntry: any, toState: any?, fsmId: string?, timeStamp: number?): any
	local entry = if type(fromOrEntry) == "table"
		then {
			From = fromOrEntry.From,
			To = fromOrEntry.To,
			FsmId = fromOrEntry.FsmId or fromOrEntry.FSMId or fromOrEntry.Id,
			Time = fromOrEntry.Time or timeStamp or os.clock(),
		}
		else {
			From = fromOrEntry,
			To = toState,
			FsmId = fsmId,
			Time = timeStamp or os.clock(),
		}
	table.insert(self.records, shallowClone(entry))
	return entry
end

function TransitionRecorder:SyncMachine(machine: any)
	if type(machine) ~= "table" then
		return
	end

	local resolvedFsmId = machine.Id or machine.StateMachineId or tostring(machine)
	local history = machine.TransitionHistory
	if type(history) ~= "table" then
		return
	end

	local cursor = self.cursors[resolvedFsmId] or 0
	for index = cursor + 1, #history do
		local entry = history[index]
		if type(entry) == "table" then
			self:Record({
				From = entry.From,
				To = entry.To,
				FsmId = resolvedFsmId,
				Time = entry.Time,
			})
		end
	end
	self.cursors[resolvedFsmId] = #history
end

function TransitionRecorder:SyncAll(stateMachines: any)
	if type(stateMachines) ~= "table" then
		return
	end
	for _, machine in pairs(stateMachines) do
		self:SyncMachine(machine)
	end
end

function TransitionRecorder:GetTransitions(fsmId: string?): { any }
	if fsmId == nil then
		return self.records
	end

	local filtered = {}
	for _, entry in ipairs(self.records) do
		if entry.FsmId == fsmId then
			table.insert(filtered, entry)
		end
	end
	return filtered
end

function TransitionRecorder:containsTransition(fromOrExpected: any, toState: any?, fsmId: string?): boolean
	local expected = normalizeExpected(fromOrExpected, toState, fsmId)
	for _, entry in ipairs(self.records) do
		if expected.FsmId ~= nil and entry.FsmId ~= expected.FsmId then
			continue
		end
		if expected.From ~= nil and entry.From ~= expected.From then
			continue
		end
		if expected.To ~= nil and entry.To ~= expected.To then
			continue
		end
		return true
	end
	return false
end

function TransitionRecorder:transitionCount(fsmId: string?): number
	return #self:GetTransitions(fsmId)
end

function TransitionRecorder:assertContainsTransition(fromOrExpected: any, toState: any?, fsmId: string?)
	assert(self:containsTransition(fromOrExpected, toState, fsmId), string.format("Expected transition %s -> %s", tostring(type(fromOrExpected) == "table" and fromOrExpected.From or fromOrExpected), tostring(type(fromOrExpected) == "table" and fromOrExpected.To or toState)))
	return true
end

return TransitionRecorder
