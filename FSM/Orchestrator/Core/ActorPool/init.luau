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

function ActorPool:_pickWorker(): Actor
    self._rr = (self._rr % #self._workers) + 1
    return self._workers[self._rr]
end

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