--[[
  SCRIPTEXER — Pet probe

  Stand near a pet that's for sale and run this. It lists every model
  within 120 studs of you, closest first, with its class, whether it has
  a Humanoid, where it lives, and its attributes.

  Whatever a purchasable pet actually is, it's in this list.
--]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local lines = {}

local function add(text, kind)
	table.insert(lines, { text = text, kind = kind or "info" })
end

local character = player.Character
local root = character and character:FindFirstChild("HumanoidRootPart")

if not root then
	add("No HumanoidRootPart — respawn and try again.", "bad")
else
	local origin = root.Position
	add("You are at " .. string.format("(%.0f, %.0f, %.0f)", origin.X, origin.Y, origin.Z))
	add("")

	local function positionOf(model)
		local part = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
		return part and part.Position or nil
	end

	-- Every model near you, whether or not it looks like anything.
	local found = {}
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst ~= character then
			local position = positionOf(inst)
			if position then
				local distance = (position - origin).Magnitude
				if distance <= 120 then
					table.insert(found, { model = inst, distance = distance })
				end
			end
		end
	end

	table.sort(found, function(a, b) return a.distance < b.distance end)

	add(#found .. " model(s) within 120 studs. Nearest 25:", "good")

	for index = 1, math.min(25, #found) do
		local entry = found[index]
		local model = entry.model
		local humanoid = model:FindFirstChildOfClass("Humanoid")

		add("")
		add(string.format("--- %.0f studs: %s ---", entry.distance, model.Name), "good")
		add("  Path: " .. model:GetFullName())
		add("  Humanoid: " .. (humanoid and "yes" or "no"), humanoid and "good" or "info")

		local ok, attrs = pcall(function() return model:GetAttributes() end)
		if ok and attrs then
			local any = false
			for key, value in pairs(attrs) do
				any = true
				add("  attr " .. tostring(key) .. " = " .. typeof(value) .. " " .. tostring(value))
			end
			if not any then add("  (no attributes)") end
		end

		-- Prompts and dialogs are how you'd interact with it, so they
		-- say a lot about what it is.
		for _, child in ipairs(model:GetDescendants()) do
			if child:IsA("ProximityPrompt") then
				add(string.format(
					"  prompt: action=%q object=%q",
					tostring(child.ActionText),
					tostring(child.ObjectText)
				), "good")
			elseif child:IsA("Dialog") then
				add("  has a Dialog (shopkeeper)", "info")
			end
		end
	end
end

--========================================================
-- Clipboard + UI
--========================================================
local dumpParts = { "SCRIPTEXER — Pet probe", "" }
for _, entry in ipairs(lines) do
	table.insert(dumpParts, entry.text)
end
local copied = false
if setclipboard then
	copied = pcall(setclipboard, table.concat(dumpParts, "\n"))
end

local gui = Instance.new("ScreenGui")
gui.Name = "ScriptexerPetProbe"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.new(0.5, 0, 0.5, 0)
frame.Size = UDim2.new(0, 400, 0, 460)
frame.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
frame.BackgroundTransparency = 0.04
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 16)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 255, 255)
stroke.Transparency = 0.88
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 16, 0, 12)
title.Size = UDim2.new(1, -60, 0, 20)
title.Font = Enum.Font.GothamBold
title.Text = "⚡ Pet probe"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Active = true
title.Parent = frame

local subtitle = Instance.new("TextLabel")
subtitle.BackgroundTransparency = 1
subtitle.Position = UDim2.new(0, 16, 0, 32)
subtitle.Size = UDim2.new(1, -32, 0, 16)
subtitle.Font = Enum.Font.Gotham
subtitle.Text = copied and "Copied to clipboard — paste it back" or "Clipboard unavailable — screenshot this"
subtitle.TextColor3 = copied and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(200, 200, 205)
subtitle.TextSize = 11
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.AnchorPoint = Vector2.new(1, 0)
closeBtn.Position = UDim2.new(1, -12, 0, 12)
closeBtn.Size = UDim2.new(0, 24, 0, 24)
closeBtn.BackgroundTransparency = 1
closeBtn.Text = "×"
closeBtn.TextColor3 = Color3.fromRGB(200, 200, 205)
closeBtn.TextSize = 20
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = frame
closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

do
	local dragging, dragStart, startPos = false, nil, nil
	title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
end

local scroll = Instance.new("ScrollingFrame")
scroll.Position = UDim2.new(0, 16, 0, 54)
scroll.Size = UDim2.new(1, -32, 1, -66)
scroll.BackgroundTransparency = 1
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.ScrollBarThickness = 4
scroll.BorderSizePixel = 0
scroll.Parent = frame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 2)
layout.Parent = scroll

local COLORS = {
	good = Color3.fromRGB(120, 255, 170),
	bad = Color3.fromRGB(255, 140, 140),
	info = Color3.fromRGB(200, 200, 205),
}

for _, entry in ipairs(lines) do
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.Font = Enum.Font.Code
	label.Text = entry.text
	label.TextColor3 = COLORS[entry.kind] or COLORS.info
	label.TextSize = 12
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = scroll
end
