local actor = script:GetActor()

local Jobs = {}

-- Register jobs here (pure compute only)
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