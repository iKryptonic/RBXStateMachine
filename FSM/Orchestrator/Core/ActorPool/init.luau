--!strict
--[=[
	@Name ActorPool
	@Author iKrypto
	@Description Round-robin Actor worker pool that distributes pure-compute
	jobs across multiple Actors for parallel execution. Each Actor is bound to a
	"JobResult" message handler on construction; incoming results are matched to
	pending callbacks by monotonic `jobId`. The `Submit` method yields the caller
	until the assigned worker replies or a 30-second timeout elapses.
]=]
local ActorPool = {}
ActorPool.__index = ActorPool

export type Job = {
	name: string,
	input: any,
}

export type Result = {
	ok: boolean,
	output: any?,
	error: string?,
}

type Pending = {
	resolve: (Result) -> (),
	createdAt: number,
}


--[=[
	@description Constructs an ActorPool over the provided array of Actor instances.
	Initializes the round-robin counter `_rr` to 0, a monotonic `_nextId` to 0, and an
	empty `_pending` map. Binds a "JobResult" message handler on each worker that reads
	`jobId` from the message, looks up the matching pending callback, removes it from
	`_pending`, and resolves it with a `Result` (success or error). Returns the new pool.
	@param workers { Actor } -- Array of Actor instances to distribute work across.
	@return ActorPool -- New pool instance with all workers registered.
]=]
function ActorPool.new(workers: { Actor })
	local self = setmetatable({}, ActorPool)
	self._workers = workers
	self._rr = 0
	self._nextId = 0
	self._pending = {} :: { [number]: Pending }

	for _, actor in ipairs(workers) do
		actor:BindToMessage("JobResult", function(jobId: number, ok: boolean, payload: any)
			local pending = self._pending[jobId]
			if not pending then
				return
			end
			self._pending[jobId] = nil

			if ok then
				pending.resolve({ ok = true, output = payload })
			else
				pending.resolve({ ok = false, error = tostring(payload) })
			end
		end)
	end

	return self
end


--[=[
	@description Selects the next worker using a wrapping round-robin counter. Advances
	`_rr` by 1 modulo `#_workers`, then returns `_workers[_rr]`. Mutates `_rr`. Errors
	if the worker array is empty.
	@return Actor -- The next Actor in the round-robin sequence.
]=]
function ActorPool:_pickWorker(): Actor
	assert(#self._workers > 0,"ActorPool has no workers")
	self._rr = (self._rr % #self._workers) + 1
	return self._workers[self._rr]
end


--[=[
	@description Dispatches `job` to the next round-robin worker and yields the calling
	coroutine until a result arrives. Increments `_nextId` to produce a unique `jobId`,
	stores a pending callback in `_pending`, and sends a "RunJob" message containing
	`jobId`, `job.name`, and `job.input` to the selected worker. Polls with `task.wait()`
	until the worker fires "JobResult" for this `jobId`. On resolution returns the
	`Result`. If no result arrives within 30 seconds, removes the pending entry and
	returns `{ ok = false, error = "Job timed out after 30s" }`.
	@param job Job -- Table with `name` (string) and `input` (any) to send to the worker.
	@return Result -- `{ ok = true, output = any }` on success, `{ ok = false, error = string }` on failure or timeout.
]=]
function ActorPool:Submit(job: Job): Result
	self._nextId += 1
	local jobId = self._nextId

	local worker = self:_pickWorker()

	local done = false
	local result: Result = { ok = false, error = "No result" }

	self._pending[jobId] = {
		createdAt = os.clock(),
		resolve = function(r: Result)
			result = r
			done = true
		end,
	}

	worker:SendMessage("RunJob", jobId, job.name, job.input)

	-- Simple blocking wait with timeout
	local TIMEOUT = 30
	local startTime = os.clock()
	while not done do
		if os.clock() - startTime > TIMEOUT then
			self._pending[jobId] = nil
			return { ok = false, error = "Job timed out after " .. TIMEOUT .."s" }
		end
		task.wait()
	end

	return result
end

return ActorPool
