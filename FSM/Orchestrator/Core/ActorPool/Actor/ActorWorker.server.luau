--[[
	@Name ActorWorker
	@Author iKrypto
	@Description Worker script running inside an Actor. Receives jobs via
	"RunJob" message, executes them in a parallel (desynchronized) context,
	then sends results back via "JobResult". Only pure-compute functions
	should be registered here — no Instance creation or Roblox API calls.
]]
local actor = script:GetActor()

local Jobs = {}

--[[
	@description Sorts a cloned list of tables by a specified key.
	@param input { list: { { [string]: any } }, key: string, descending: boolean } -- Sort parameters.
	@return { { [string]: any } } -- The sorted list.
]]
Jobs.SortByKey = function(input)
    -- input = { list = {...}, key = "time", descending = true }
    local list = table.clone(input.list)
    local key = input.key
    local desc = input.descending

    table.sort(list, function(a, b)
        if desc then
            return a[key] > b[key]
        end
        return a[key] < b[key]
    end)

    return list
end

--[[
	@description Aggregates a list of numeric samples into count + average.
	@param input { samples: { number } } -- The samples to aggregate.
	@return { count: number, avg: number } -- Aggregated result.
]]
Jobs.AggregatePerf = function(input)
    -- input = { samples = {...} }
    local sum = 0
    local n = 0
    for _, v in ipairs(input.samples) do
        sum += v
        n += 1
    end
    return {
        count = n,
        avg = (n > 0) and (sum / n) or 0,
    }
end

-- Listens for "RunJob" messages from the pool, executes the named job
-- in a desynchronized (parallel) context, then replies with "JobResult".
actor:BindToMessage("RunJob", function(jobId: number, jobName: string, jobInput: any)
	-- Enter parallel
	task.desynchronize()

    local ok, out = pcall(function()
        local fn = Jobs[jobName]
        if not fn then
            error(("Unknown job '%s'"):format(jobName))
        end
        return fn(jobInput)
    end)

    -- Back to serial for messaging (safer for engine interactions)
    task.synchronize()
    actor:SendMessage("JobResult", jobId, ok, out)
end)