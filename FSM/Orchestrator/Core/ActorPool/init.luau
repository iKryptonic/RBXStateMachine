--[[
	@Name ActorPool
	@Author iKrypto
	@Description Round-robin Actor worker pool that distributes pure-compute
	jobs across multiple Actors for parallel execution. Uses a blocking
	Submit() pattern — the caller yields until the worker replies.
]]
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

--[[
	@description Creates a new ActorPool from the supplied worker Actors.
	Each worker is bound to a "JobResult" message handler that resolves
	the corresponding pending promise.
	@param workers { Actor } -- Array of Actor instances to use as workers.
	@return ActorPool -- The pool instance.
]]
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

--[[
	@description Selects the next worker using round-robin scheduling.
	@return Actor -- The chosen worker.
]]
function ActorPool:_pickWorker(): Actor
    self._rr = (self._rr % #self._workers) + 1
    return self._workers[self._rr]
end

--[[
	@description Submits a job to the next available worker and blocks until
	the result is received. The worker executes the named job function
	in a parallel context and replies via "JobResult".
	@param job Job -- { name: string, input: any } describing the work.
	@return Result -- { ok: boolean, output: any?, error: string? }.
]]
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

    -- Simple blocking wait; if your Scheduler is async, switch to a Promise pattern instead.
    while not done do
        task.wait()
    end

    return result
end

return ActorPool