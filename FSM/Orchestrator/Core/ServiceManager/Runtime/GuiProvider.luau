--!nocheck
-- GuiProvider
-- Responsible for locating or constructing the ServiceManager UI and returning stable references.

local Players = game:GetService("Players")

export type GuiRefs = {
	ScreenGui: ScreenGui,
	Main: Frame,
	Sidebar: Frame,
	BottomBar: Frame,
	Body: Frame,
	TabContainer: Frame,
	Title: TextLabel,
	References: Folder,
}

local GuiProvider = {}

local function findMainFrom(start: Instance?): Frame?
	if not start then return nil end
	local main = start:FindFirstChild("Main")
	if main and main:IsA("Frame") then
		return main
	end
	return nil
end

local function getPlayerGui(): PlayerGui
	local player = Players.LocalPlayer
	if not player then
		error("[ServiceManager.GuiProvider] LocalPlayer missing")
	end
	return player:WaitForChild("PlayerGui") :: PlayerGui
end

local function buildUI(): GuiRefs
	local parent = script.Parent
	if not parent then
		error("[ServiceManager.GuiProvider] GuiProvider has no parent")
	end
	local uiModuleInst = parent:FindFirstChild("Serialized_GUI")
	if not uiModuleInst or not uiModuleInst:IsA("ModuleScript") then
		error("[ServiceManager.GuiProvider] Missing ModuleScript 'Serialized_GUI' next to GuiProvider")
	end
	local ui = require(uiModuleInst :: ModuleScript)
	if type(ui) ~= "table" or type(ui.Build) ~= "function" then
		error("[ServiceManager.GuiProvider] Serialized_GUI must return { Build = function(...) }")
	end

	local screenGui, refs = ui.Build()
	if not screenGui or not screenGui:IsA("ScreenGui") then
		error("[ServiceManager.GuiProvider] Build() must return ScreenGui")
	end

	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = getPlayerGui()

	if refs and refs.Main and refs.Main:IsA("Frame") then
		-- ok
	else
		-- Fall back to name-based lookup.
		refs = {
			ScreenGui = screenGui,
			Main = screenGui:WaitForChild("Main") :: Frame,
			Sidebar = (screenGui.Main :: any):WaitForChild("Sidebar") :: Frame,
			BottomBar = (screenGui.Main :: any):WaitForChild("BottomBar") :: Frame,
			Body = (screenGui.Main :: any):WaitForChild("Body") :: Frame,
			TabContainer = ((screenGui.Main :: any).Sidebar :: any):WaitForChild("TabContainer") :: Frame,
			Title = ((screenGui.Main :: any).Sidebar :: any):WaitForChild("Title") :: TextLabel,
			References = (screenGui.Main :: any):WaitForChild("References") :: Folder,
		}
	end

	refs.ScreenGui = screenGui
	return refs :: GuiRefs
end

function GuiProvider.GetOrCreate(scriptParent: Instance?): GuiRefs
	-- 1) Try to find a Main frame near where this module is stored (compat with old layout)
	local main = findMainFrom(scriptParent)
	if not main then
		main = findMainFrom(scriptParent and scriptParent.Parent)
	end

	-- 2) Try to find existing GUI in PlayerGui
	if not main then
		local pg = getPlayerGui()
		local existingGui = pg:FindFirstChild("ServiceManagerUI")
		if existingGui and existingGui:IsA("ScreenGui") then
			main = existingGui:FindFirstChild("Main") :: any
		end
	end

	if not main then
		return buildUI()
	end

	local screenGui = main:FindFirstAncestorWhichIsA("ScreenGui")
	if not screenGui then
		error("[ServiceManager.GuiProvider] Main frame has no ScreenGui ancestor")
	end

	return {
		ScreenGui = screenGui,
		Main = main,
		Sidebar = main:WaitForChild("Sidebar") :: Frame,
		BottomBar = main:WaitForChild("BottomBar") :: Frame,
		Body = main:WaitForChild("Body") :: Frame,
		TabContainer = (main:WaitForChild("Sidebar") :: Frame):WaitForChild("TabContainer") :: Frame,
		Title = ((main:WaitForChild("Sidebar") :: Frame):WaitForChild("Title")) :: TextLabel,
		References = main:WaitForChild("References") :: Folder,
	}
end

return GuiProvider
