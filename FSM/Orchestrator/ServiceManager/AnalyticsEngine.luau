--!strict


local AnalyticsEngine = {}
AnalyticsEngine.__index = AnalyticsEngine

export type Insight = {
	Id: string,
	Severity:"CRITICAL" |"WARNING" |"INFO" |"SUGGESTION",
	Subsystem: string,
	Title: string,
	Description: string,
	Metric: number?,
	Threshold: number?,
	Timestamp: number,
	RelatedIds: { string }?,
	Dismissed: boolean,
	Snoozed: boolean?,
	SnoozedUntil: number?,
	RepeatCount: number?,
	ActionableHints: { { Label: string, Command: string? } }?,
	FirstSeen: number?,
}

export type RuleFn = (nexus: any, emit: (Insight) -> ()) -> ()


function AnalyticsEngine.new(): any
	local self = setmetatable({}, AnalyticsEngine)
	self._insights = {} :: { [string]: Insight }
	self._rules = {} :: { RuleFn }
	self._lastCycle = 0
	self._cycleInterval = 1.0 -- run analysis every 1s
	self._pendingWork = false
	self._history = {} :: { Insight }
	self._maxHistory = 200

	-- Register built-in detection rules
	self:_RegisterBuiltinRules()
	return self
end


function AnalyticsEngine:HasPendingWork(): boolean
	return os.clock() - self._lastCycle >= self._cycleInterval
end


function AnalyticsEngine:RunCycle(nexus: any)
	self._lastCycle = os.clock()
	local newInsights = {} :: { Insight }
	local emit = function(insight: Insight)
		table.insert(newInsights, insight)
	end

	for _, rule in ipairs(self._rules) do
		local success, err = pcall(rule, nexus, emit)
		if not success then
			warn("[AnalyticsEngine] Rule error: " .. tostring(err))
		end
	end

	-- Merge new insights, update existing or add new
	for _, insight in ipairs(newInsights) do
		local existing = self._insights[insight.Id]
		if existing then
			-- Update metric/description but keep dismissed/snoozed state
			existing.Metric = insight.Metric
			existing.Description = insight.Description
			existing.Timestamp = insight.Timestamp
			existing.RepeatCount = (existing.RepeatCount or 1) + 1
			-- Severity escalation: persistent issues escalate from WARNING -> CRITICAL
			if (existing.RepeatCount or 0) >= 10 and existing.Severity == "WARNING" then
				existing.Severity = "CRITICAL"
			end
			-- Auto-unsnooze when timer elapses
			if existing.Snoozed and existing.SnoozedUntil and os.clock() >= existing.SnoozedUntil then
				existing.Snoozed = false
				existing.SnoozedUntil = nil
			end
		else
			insight.RepeatCount = 1
			insight.FirstSeen = os.clock()
			self._insights[insight.Id] = insight
			-- Add to history
			if #self._history >= self._maxHistory then
				table.remove(self._history, 1)
			end
			table.insert(self._history, insight)
		end
	end

	-- Prune insights that are no longer relevant (not re-produced in this cycle)
	local activeIds = {}
	for _, ins in ipairs(newInsights) do
		activeIds[ins.Id] = true
	end
	for id, ins in pairs(self._insights) do
		if not activeIds[id] and not ins.Dismissed then
			-- Auto-resolve if old
			if os.clock() - ins.Timestamp > 10 then
				self._insights[id] = nil
			end
		end
	end
end


function AnalyticsEngine:GetActiveInsights(): { Insight }
	local result = {}
	for _, insight in pairs(self._insights) do
		if insight.Dismissed then continue end
		if insight.Snoozed and insight.SnoozedUntil and os.clock() < insight.SnoozedUntil then continue end
		table.insert(result, insight)
	end
	-- Sort by severity, then repeat count desc, then timestamp desc
	local severityOrder = { CRITICAL = 1, WARNING = 2, INFO = 3, SUGGESTION = 4 }
	table.sort(result, function(a, b)
		local sa = severityOrder[a.Severity] or 99
		local sb = severityOrder[b.Severity] or 99
		if sa ~= sb then return sa < sb end
		local ra = a.RepeatCount or 0
		local rb = b.RepeatCount or 0
		if ra ~= rb then return ra > rb end
		return (a.Timestamp or 0) > (b.Timestamp or 0)
	end)
	return result
end


function AnalyticsEngine:GetHistory(): { Insight }
	return self._history
end


function AnalyticsEngine:GetInsight(id: string): Insight?
	return self._insights[id]
end


function AnalyticsEngine:DismissInsight(id: string)
	local insight = self._insights[id]
	if insight then
		insight.Dismissed = true
	end
end


function AnalyticsEngine:SnoozeInsight(id: string, seconds: number?)
	local insight = self._insights[id]
	if insight then
		insight.Snoozed = true
		insight.SnoozedUntil = os.clock() + (seconds or 60)
	end
end


function AnalyticsEngine:ResolveInsight(id: string)
	-- Resolution removes from active and history (user marked it done)
	self._insights[id] = nil
end


function AnalyticsEngine:AddRule(rule: RuleFn)
	table.insert(self._rules, rule)
end


function AnalyticsEngine:GetRuleCount(): number
	return #self._rules
end


function AnalyticsEngine:Destroy()
	table.clear(self._insights)
	table.clear(self._rules)
	table.clear(self._history)
end


function AnalyticsEngine:_CreateInsight(params: {
	Id: string,
	Severity:"CRITICAL" |"WARNING" |"INFO" |"SUGGESTION",
	Subsystem: string,
	Title: string,
	Description: string,
	Metric: number?,
	Threshold: number?,
	RelatedIds: { string }?,
	ActionableHints: { { Label: string, Command: string? } }?,
	}): Insight
	return {
		Id = params.Id,
		Severity = params.Severity,
		Subsystem = params.Subsystem,
		Title = params.Title,
		Description = params.Description,
		Metric = params.Metric,
		Threshold = params.Threshold,
		Timestamp = os.clock(),
		RelatedIds = params.RelatedIds,
		Dismissed = false,
		ActionableHints = params.ActionableHints,
	}
end


function AnalyticsEngine:_RegisterBuiltinRules()
	-- Rule 1: FSM State Stall Detection (multi-emit: one per stalled FSM)
	self:AddRule(function(nexus: any, emit: (Insight) -> ())
		local orchestrator = nexus._orchestrator
		if not orchestrator then return end

		local machines = orchestrator.StateMachines
		if not machines then return end

		for id, fsm in pairs(machines) do
			if fsm.IsActive and fsm.StateDuration and fsm.StateDuration > 30 then
				emit(self:_CreateInsight({
					Id = "fsm_stall_" .. id,
					Severity = "WARNING",
					Subsystem = "FSM",
					Title = "State Stall Detected",
					Description = string.format(
						"FSM '%s' has been in state '%s' for %.1fs — possible infinite loop or missing transition.",
						fsm.Name or id,
						fsm.State or "unknown",
						fsm.StateDuration
					),
					Metric = fsm.StateDuration,
					Threshold = 30,
					RelatedIds = { id },
					ActionableHints = {
						{ Label = "Cancel FSM", Command = "fsm cancel " .. id },
						{ Label = "View Detail", Command = "switch fsm" },
					},
				}))
			end
		end
	end)

	-- Rule 2: High-Frequency Task Detection (multi-emit: one per slow task)
	self:AddRule(function(nexus: any, emit: (Insight) -> ())
		local orchestrator = nexus._orchestrator
		if not orchestrator or not orchestrator.Scheduler then return end

		local tasks = orchestrator.Scheduler.Tasks
		if not tasks then return end

		for name, taskDef in pairs(tasks) do
			local perf = taskDef.Perf or taskDef._perf
			if perf and perf.AvgExecutionTime and perf.AvgExecutionTime > 0.008 then
				emit(self:_CreateInsight({
					Id = "task_bottleneck_" .. name,
					Severity = "CRITICAL",
					Subsystem = "TASKS",
					Title = "Task Bottleneck",
					Description = string.format(
						"Task '%s' avg execution %.2fms (budget 8ms). This task is consuming excessive frame budget.",
						name,
						perf.AvgExecutionTime * 1000
					),
					Metric = perf.AvgExecutionTime * 1000,
					Threshold = 8,
					RelatedIds = { name },
					ActionableHints = {
						{ Label = "Inspect Task", Command = "tasks info " .. name },
						{ Label = "Kill Task", Command = "tasks kill " .. name },
					},
				}))
			end
		end
	end)

	-- Rule 3: Entity Count Spike (single-emit: aggregate count)
	self:AddRule(function(nexus: any, emit: (Insight) -> ())
		local orchestrator = nexus._orchestrator
		if not orchestrator then return end

		local entities = orchestrator.Entities
		if not entities then return end

		local count = 0
		for _ in pairs(entities) do
			count += 1
		end

		if count > 500 then
			emit(self:_CreateInsight({
				Id = "entity_count_high",
				Severity = "WARNING",
				Subsystem = "ENTITY",
				Title = "High Entity Count",
				Description = string.format(
					"%d active entities — consider pooling or destroying unused entities to reduce memory pressure.",
					count
				),
				Metric = count,
				Threshold = 500,
				ActionableHints = {
					{ Label = "Browse Entities", Command = "switch entity" },
				},
			}))
		end
	end)

	-- Rule 4: Memory Pressure Detection (single-emit: aggregate memory)
	self:AddRule(function(nexus: any, emit: (Insight) -> ())
		local memKB = collectgarbage("count")
		local memMB = memKB / 1024

		if memMB > 512 then
			emit(self:_CreateInsight({
				Id = "memory_pressure",
				Severity = if memMB > 800 then"CRITICAL" else"WARNING",
				Subsystem = "TASKS",
				Title = "Memory Pressure",
				Description = string.format(
					"Heap usage at %.1f MB — threshold 512 MB. Potential memory leak or excessive allocation.",
					memMB
				),
				Metric = memMB,
				Threshold = 512,
				ActionableHints = {
					{ Label = "View Performance", Command = "perf" },
				},
			}))
		end
	end)

	-- Rule 5: FSM Priority Inversion (single-emit: aggregate count)
	self:AddRule(function(nexus: any, emit: (Insight) -> ())
		local orchestrator = nexus._orchestrator
		if not orchestrator then return end

		local machines = orchestrator.StateMachines
		if not machines then return end

		local renderCount = 0
		for _, fsm in pairs(machines) do
			if fsm.IsActive and fsm.Priority == 1 then
				renderCount += 1
			end
		end

		if renderCount > 10 then
			emit(self:_CreateInsight({
				Id = "fsm_priority_inversion",
				Severity = "WARNING",
				Subsystem = "FSM",
				Title = "Too Many Render-Priority FSMs",
				Description = string.format(
					"%d FSMs running at Render priority (every frame). Consider lowering priority for non-critical machines.",
					renderCount
				),
				Metric = renderCount,
				Threshold = 10,
				ActionableHints = {
					{ Label = "View FSMs", Command = "switch fsm" },
				},
			}))
		end
	end)

	-- Rule 6: Network Event Bus Orphan Detection (multi-emit: one per orphan)
	self:AddRule(function(nexus: any, emit: (Insight) -> ())
		local orchestrator = nexus._orchestrator
		if not orchestrator then return end

		local nm = orchestrator.NetworkManager
		if not nm or not nm.EventBuses then return end

		for name, bus in pairs(nm.EventBuses) do
			local subCount = 0
			if bus._handlers then
				subCount = #bus._handlers
			elseif bus.Subscribers then
				subCount = bus.Subscribers
			end

			if subCount == 0 then
				emit(self:_CreateInsight({
					Id = "orphan_bus_" .. name,
					Severity = "SUGGESTION",
					Subsystem = "NETWORK",
					Title = "Orphaned Event Bus",
					Description = string.format(
						"Event bus '%s' has 0 subscribers. Consider removing it or ensuring handlers are connected.",
						name
					),
					RelatedIds = { name },
					ActionableHints = {
						{ Label = "View Network", Command = "switch network" },
					},
				}))
			end
		end
	end)

	-- Rule 7 (NEW): Failed FSM Cluster — emits one insight per failed FSM
	self:AddRule(function(nexus: any, emit: (Insight) -> ())
		local orchestrator = nexus._orchestrator
		if not orchestrator then return end
		local machines = orchestrator.StateMachines
		if not machines then return end

		for id, fsm in pairs(machines) do
			local failed = fsm.HasFailed or fsm.Failed or (fsm.State == "Failed") or (fsm.State == "Error")
			if failed then
				emit(self:_CreateInsight({
					Id = "fsm_failed_" .. id,
					Severity = "CRITICAL",
					Subsystem = "FSM",
					Title = "FSM in Failed State",
					Description = string.format(
						"FSM '%s' is in a failed state. Review transition history and reset if appropriate.",
						fsm.Name or id
					),
					RelatedIds = { id },
					ActionableHints = {
						{ Label = "View FSM", Command = "fsm info " .. id },
						{ Label = "Restart FSM", Command = "fsm cancel " .. id },
					},
				}))
			end
		end
	end)

	-- Rule 8 (NEW): Zero-Activity Scheduler — emits when scheduler exists but has no tasks at all
	self:AddRule(function(nexus: any, emit: (Insight) -> ())
		local orchestrator = nexus._orchestrator
		if not orchestrator or not orchestrator.Scheduler then return end
		local tasks = orchestrator.Scheduler.Tasks
		if not tasks then return end

		local taskCount = 0
		for _ in pairs(tasks) do
			taskCount += 1
		end

		-- Only fire when there are literally zero tasks registered (real misconfiguration).
		-- Idle status is normal — most tasks spend most time idle waiting for events.
		if taskCount == 0 then
			emit(self:_CreateInsight({
				Id = "scheduler_no_tasks",
				Severity = "WARNING",
				Subsystem = "TASKS",
				Title = "No Tasks Registered",
				Description = "Scheduler has zero tasks. Verify Orchestrator.RegisterComponents() ran and tasks were scheduled.",
				Metric = 0,
				ActionableHints = {
					{ Label = "View Tasks", Command = "switch tasks" },
				},
			}))
		end
	end)

	-- Rule 9 (NEW): Dead Entity Backlog — emits when many entities marked invalid
	self:AddRule(function(nexus: any, emit: (Insight) -> ())
		local orchestrator = nexus._orchestrator
		if not orchestrator then return end
		local entities = orchestrator.Entities
		if not entities then return end

		local deadCount = 0
		for _, entity in pairs(entities) do
			pcall(function()
				if entity._privateProperties and entity._privateProperties.IsValid == false then
					deadCount += 1
				end
			end)
		end

		if deadCount > 10 then
			emit(self:_CreateInsight({
				Id = "dead_entity_backlog",
				Severity = "WARNING",
				Subsystem = "ENTITY",
				Title = "Dead Entity Backlog",
				Description = string.format(
					"%d invalidated entities still in registry — consider GC or explicit removal.",
					deadCount
				),
				Metric = deadCount,
				Threshold = 10,
				ActionableHints = {
					{ Label = "View Entities", Command = "switch entity" },
				},
			}))
		end
	end)

	-- Rule 10 (NEW): Frame Rate Degradation
	self:AddRule(function(nexus: any, emit: (Insight) -> ())
		local fps = nexus._lastFPS or 60
		if fps < 30 then
			emit(self:_CreateInsight({
				Id = "fps_degraded",
				Severity = if fps < 15 then"CRITICAL" else"WARNING",
				Subsystem = "TASKS",
				Title = "Frame Rate Degraded",
				Description = string.format(
					"Frame rate %.1f fps (target 60). Investigate task budgets and render workload.",
					fps
				),
				Metric = fps,
				Threshold = 30,
				ActionableHints = {
					{ Label = "View Performance", Command = "perf" },
					{ Label = "View Tasks", Command = "switch tasks" },
				},
			}))
		end
	end)
end

return AnalyticsEngine
