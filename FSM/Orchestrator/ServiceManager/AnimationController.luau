--!strict


local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local AnimationController = {}
AnimationController.__index = AnimationController

type AnimationEntry = {
	Id: string,
	Target: Instance,
	Properties: { [string]: any },
	TweenInfo: TweenInfo,
	Delay: number,
	OnComplete: (() -> ())?,
	State:"queued" |"playing" |"done",
	Tween: Tween?,
}

type PulseEntry = {
	Target: Instance,
	Property: string,
	OriginalValue: any,
	PulseValue: any,
	TweenInfo: TweenInfo,
	Tween: Tween?,
	Active: boolean,
}


function AnimationController.new(): any
	local self = setmetatable({}, AnimationController)
	self._queue = {} :: { AnimationEntry }
	self._activeTweens = {} :: { [string]: Tween }
	self._pulses = {} :: { [string]: PulseEntry }
	self._staggerDelay = 0.035 -- delay between staggered list items
	self._nextId = 0
	return self
end


function AnimationController:Animate(target: Instance, properties: { [string]: any }, tweenInfo: TweenInfo?, delay: number?, onComplete: (() -> ())?)
	self._nextId + = 1
	local id = "anim_" .. tostring(self._nextId)

	local entry: AnimationEntry = {
		Id = id,
		Target = target,
		Properties = properties,
		TweenInfo = tweenInfo or Theme.Tween.Med,
		Delay = delay or 0,
		OnComplete = onComplete,
		State = "queued",
		Tween = nil,
	}

	table.insert(self._queue, entry)
	return id
end


function AnimationController:StaggerIn(items: { Instance }, propertyFrom: { [string]: any }, propertyTo: { [string]: any }, tweenInfo: TweenInfo?)
	local ti = tweenInfo or Theme.Tween.Fast
	for i, item in ipairs(items) do
		-- Set initial state
		for prop, val in pairs(propertyFrom) do
			(item :: any)[prop] = val
		end

		self:Animate(item, propertyTo, ti, (i - 1) * self._staggerDelay)
	end
end


function AnimationController:StartPulse(id: string, target: Instance, property: string, pulseValue: any, tweenInfo: TweenInfo?)
	-- Stop existing pulse if any
	self:StopPulse(id)

	local original = (target :: any)[property]
	local ti = tweenInfo or Theme.Tween.Pulse

	local tween = TweenService:Create(target, ti, { [property] = pulseValue })
	tween:Play()

	self._pulses[id] = {
		Target = target,
		Property = property,
		OriginalValue = original,
		PulseValue = pulseValue,
		TweenInfo = ti,
		Tween = tween,
		Active = true,
	}
end


function AnimationController:StopPulse(id: string)
	local pulse = self._pulses[id]
	if not pulse then return end

	if pulse.Tween then
		pulse.Tween:Cancel()
	end
	-- Restore original value
	pcall(function()
		(pulse.Target :: any)[pulse.Property] = pulse.OriginalValue
	end)
	pulse.Active = false
	self._pulses[id] = nil
end


function AnimationController:ExpandIn(frame: Frame, fromScale: number?, duration: number?)
	local scale = fromScale or 0.92
	local dur = duration or 0.3

	-- Start small and transparent
	frame.Size = UDim2.new(scale, 0, scale, 0)
	frame.BackgroundTransparency = 1

	local content = frame:FindFirstChild("Content") :: Frame?
	if content then
		content.BackgroundTransparency = 1
	end

	local ti = TweenInfo.new(dur, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
	local tw = TweenService:Create(frame, ti, {
		Size = UDim2.new(1, 0, 1, 0),
	})
	tw:Play()

	if content then
		task.delay(dur * 0.15, function()
			local tw2 = TweenService:Create(content, ti, {
				BackgroundTransparency = Theme.GetDepthTransparency(0),
			})
			tw2:Play()
		end)
	end
end


function AnimationController:CollapseOut(frame: Frame, onDone: (() -> ())?)
	local ti = Theme.Tween.Collapse
	local content = frame:FindFirstChild("Content") :: Frame?
	if content then
		local tw = TweenService:Create(content, ti, {
			BackgroundTransparency = 1,
		})
		tw:Play()
	end

	local tw = TweenService:Create(frame, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Size = UDim2.new(0.95, 0, 0.95, 0),
	})
	tw:Play()
	tw.Completed:Connect(function()
		frame:Destroy()
		if onDone then onDone() end
	end)
end


function AnimationController:HoverGlow(button: GuiButton, glowColor: Color3?)
	local color = glowColor or Theme.Colors.Accent
	local origBG = button.BackgroundColor3
	local origTransparency = button.BackgroundTransparency

	button.MouseEnter:Connect(function()
		TweenService:Create(button, Theme.Tween.Fast, {
			BackgroundColor3 = color,
			BackgroundTransparency = math.max(0, origTransparency - Theme.Transparency.HoverLift),
		}):Play()
	end)

	button.MouseLeave:Connect(function()
		TweenService:Create(button, Theme.Tween.Fast, {
			BackgroundColor3 = origBG,
			BackgroundTransparency = origTransparency,
		}):Play()
	end)
end


function AnimationController:Tick()
	local i = 1
	while i <= #self._queue do
		local entry = self._queue[i]
		if entry.State == "queued" then
			-- Check if target is still valid
			if not entry.Target or not entry.Target.Parent then
				entry.State = "done"
				table.remove(self._queue, i)
				continue
			end

			-- Respect delay
			if entry.Delay > 0 then
				entry.Delay - = (1 / 60) -- approximate frame time
				i + = 1
				continue
			end

			-- Play the tween
			local tween = TweenService:Create(entry.Target, entry.TweenInfo, entry.Properties)
			entry.Tween = tween
			entry.State = "playing"
			tween:Play()

			tween.Completed:Connect(function()
				entry.State = "done"
				if entry.OnComplete then
					entry.OnComplete()
				end
			end)
		elseif entry.State == "done" then
			table.remove(self._queue, i)
			continue
		end
		i + = 1
	end
end


function AnimationController:Destroy()
	for _, entry in ipairs(self._queue) do
		if entry.Tween then entry.Tween:Cancel() end
	end
	table.clear(self._queue)

	for id, pulse in pairs(self._pulses) do
		self:StopPulse(id)
	end
	table.clear(self._pulses)
end

return AnimationController
