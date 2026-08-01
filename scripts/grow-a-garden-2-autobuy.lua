--[[
  Grow A Garden 2 — Auto Buy (Seeds / Gears / Crates)
  Clean, readable, no obfuscation, no external network calls beyond the
  game's own remotes. Everything it does is visible below.

  UI lets you toggle exactly which seeds, gears, and crates get
  auto-bought. Item lists are built LIVE from the game's own stock
  folders (ReplicatedStorage.StockValues) — nothing hardcoded, so it
  always matches whatever's actually in the shop right now.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Networking = require(ReplicatedStorage.SharedModules.Networking)

local PurchaseSeeds = Networking.SeedShop.PurchaseSeed
local SeedsStock = ReplicatedStorage.StockValues.SeedShop.Items

local PurchaseGears = Networking.GearShop.PurchaseGear
local GearsStock = ReplicatedStorage.StockValues.GearShop.Items

local PurchaseCrates = Networking.CrateShop.PurchaseCrate
local CratesStock = ReplicatedStorage.StockValues.CrateShop.Items

--========================================================
-- Pull prices + player currency straight out of the game's own
-- RestockStoreController, so we don't have to guess the data shape.
--========================================================
local prices = {}
local playerdata = nil
for _, v in pairs(getgc()) do
	if type(v) == "function" then
		if debug.info(v, "s"):match("RestockStoreController") then
			if debug.info(v, "l") == 575 then
				pcall(function()
					table.insert(prices, debug.getupvalue(v, 3))
					playerdata = debug.getupvalue(v, 9)
				end)
			end
		end
	end
end

local function canAfford(item)
	if not prices or not playerdata then return false end
	for _, options in pairs(prices) do
		local success, result = pcall(function()
			local itemData = options[item]
			if not itemData then return false end
			return (playerdata.Data.Sheckles or 0) >= itemData.price
		end)
		if success and result then return true end
	end
	return false
end

--========================================================
-- Selection state — which items are enabled per category.
-- Defaults to everything OFF; nothing gets auto-bought until you
-- explicitly toggle items on (or use one of the select-all shortcuts).
--========================================================
local Selected = { Seeds = {}, Gears = {}, Crates = {} }

local function isSelected(category, name)
	local v = Selected[category][name]
	if v == nil then return false end -- default off until toggled
	return v
end

--========================================================
-- Buy interval — shared across all three shops, adjustable live from
-- the slider in the UI below (0.01s - 10s).
--========================================================
local BuyInterval = 0.5

--========================================================
-- Buy loop — one per shop, same structure as the confirmed working
-- example, gated by the Selected[] toggle state from the UI. Reads
-- BuyInterval fresh every pass, so dragging the slider takes effect
-- on the very next cycle.
--========================================================
local function runBuyLoop(stockFolder, remote, category)
	task.spawn(function()
		while task.wait(BuyInterval) do
			for _, item in pairs(stockFolder:GetChildren()) do
				if item and typeof(item) == "Instance" and item.Value and item.Value > 0 then
					if isSelected(category, item.Name) and canAfford(item.Name) then
						pcall(function()
							remote:Fire(item.Name)
						end)
					end
				end
			end
		end
	end)
end

--========================================================
-- UI — solid dark panel with tabs (Seeds / Gears / Crates), each a
-- scrollable list of toggle rows built live from the stock folders.
--========================================================
local gui = Instance.new("ScreenGui")
gui.Name = "ScriptexerAutoBuyUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.AnchorPoint = Vector2.new(1, 0)
frame.Position = UDim2.new(1, -18, 0, 18)
frame.Size = UDim2.new(0, 300, 0, 458)
frame.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
frame.BackgroundTransparency = 0.04
frame.BorderSizePixel = 0
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 16)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 255, 255)
stroke.Transparency = 0.88
stroke.Thickness = 1
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 16, 0, 12)
title.Size = UDim2.new(1, -32, 0, 18)
title.Font = Enum.Font.GothamBold
title.Text = "⚡ SCRIPTEXER — Auto Buy"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Active = true
title.Parent = frame

-- Drag support
do
	local dragging, dragStart, startPos = false, nil, nil
	frame.Active = true
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

-- Tab bar
local tabBar = Instance.new("Frame")
tabBar.BackgroundTransparency = 1
tabBar.Position = UDim2.new(0, 16, 0, 38)
tabBar.Size = UDim2.new(1, -32, 0, 28)
tabBar.Parent = frame

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 6)
tabLayout.Parent = tabBar

local categories = {
	{ key = "Seeds", stock = SeedsStock, remote = PurchaseSeeds },
	{ key = "Gears", stock = GearsStock, remote = PurchaseGears },
	{ key = "Crates", stock = CratesStock, remote = PurchaseCrates },
}

local tabButtons = {}
local activeTab = "All"

--========================================================
-- Buy interval slider (0.01s – 10s)
--========================================================
local SLIDER_MIN, SLIDER_MAX = 0.01, 10

local intervalRow = Instance.new("Frame")
intervalRow.BackgroundTransparency = 1
intervalRow.Position = UDim2.new(0, 16, 0, 72)
intervalRow.Size = UDim2.new(1, -32, 0, 40)
intervalRow.Parent = frame

local intervalLabel = Instance.new("TextLabel")
intervalLabel.BackgroundTransparency = 1
intervalLabel.Size = UDim2.new(1, 0, 0, 16)
intervalLabel.Font = Enum.Font.Gotham
intervalLabel.Text = string.format("Buy interval: %.2fs", BuyInterval)
intervalLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
intervalLabel.TextSize = 12
intervalLabel.TextXAlignment = Enum.TextXAlignment.Left
intervalLabel.Parent = intervalRow

local sliderTrack = Instance.new("Frame")
sliderTrack.Name = "SliderTrack"
sliderTrack.Active = true
sliderTrack.Position = UDim2.new(0, 0, 0, 24)
sliderTrack.Size = UDim2.new(1, 0, 0, 6)
sliderTrack.BackgroundColor3 = Color3.fromRGB(50, 50, 54)
sliderTrack.BorderSizePixel = 0
sliderTrack.Parent = intervalRow

local sliderTrackCorner = Instance.new("UICorner")
sliderTrackCorner.CornerRadius = UDim.new(1, 0)
sliderTrackCorner.Parent = sliderTrack

local sliderFill = Instance.new("Frame")
sliderFill.BackgroundColor3 = Color3.fromRGB(120, 255, 170)
sliderFill.BorderSizePixel = 0
sliderFill.Size = UDim2.new(0, 0, 1, 0)
sliderFill.Parent = sliderTrack

local sliderFillCorner = Instance.new("UICorner")
sliderFillCorner.CornerRadius = UDim.new(1, 0)
sliderFillCorner.Parent = sliderFill

local sliderKnob = Instance.new("Frame")
sliderKnob.AnchorPoint = Vector2.new(0.5, 0.5)
sliderKnob.Size = UDim2.new(0, 14, 0, 14)
sliderKnob.Position = UDim2.new(0, 0, 0.5, 0)
sliderKnob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
sliderKnob.BorderSizePixel = 0
sliderKnob.ZIndex = 2
sliderKnob.Parent = sliderTrack

local sliderKnobCorner = Instance.new("UICorner")
sliderKnobCorner.CornerRadius = UDim.new(1, 0)
sliderKnobCorner.Parent = sliderKnob

local function setIntervalFromAlpha(alpha)
	alpha = math.clamp(alpha, 0, 1)
	BuyInterval = SLIDER_MIN + (SLIDER_MAX - SLIDER_MIN) * alpha
	sliderFill.Size = UDim2.new(alpha, 0, 1, 0)
	sliderKnob.Position = UDim2.new(alpha, 0, 0.5, 0)
	intervalLabel.Text = string.format("Buy interval: %.2fs", BuyInterval)
end

setIntervalFromAlpha((BuyInterval - SLIDER_MIN) / (SLIDER_MAX - SLIDER_MIN))

local draggingSlider = false
local function alphaFromInput(input)
	return (input.Position.X - sliderTrack.AbsolutePosition.X) / sliderTrack.AbsoluteSize.X
end

sliderTrack.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		draggingSlider = true
		setIntervalFromAlpha(alphaFromInput(input))
	end
end)
sliderTrack.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		draggingSlider = false
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if draggingSlider and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		setIntervalFromAlpha(alphaFromInput(input))
	end
end)

-- List area (shared between tabs — rebuilt on tab switch)
local listHolder = Instance.new("ScrollingFrame")
listHolder.BackgroundTransparency = 1
listHolder.Position = UDim2.new(0, 16, 0, 122)
listHolder.Size = UDim2.new(1, -32, 1, -204)
listHolder.CanvasSize = UDim2.new(0, 0, 0, 0)
listHolder.AutomaticCanvasSize = Enum.AutomaticSize.Y
listHolder.ScrollBarThickness = 3
listHolder.ScrollBarImageTransparency = 0.4
listHolder.BorderSizePixel = 0
listHolder.Parent = frame

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.Parent = listHolder

-- Per-category quick-select row: "All Seeds" / "All Gears" / "All Crates"
-- — selects every item in that one category regardless of which tab
-- you're currently viewing.
local categoryBulkRow = Instance.new("Frame")
categoryBulkRow.BackgroundTransparency = 1
categoryBulkRow.Position = UDim2.new(0, 16, 1, -72)
categoryBulkRow.Size = UDim2.new(1, -32, 0, 26)
categoryBulkRow.Parent = frame

local categoryBulkLayout = Instance.new("UIListLayout")
categoryBulkLayout.FillDirection = Enum.FillDirection.Horizontal
categoryBulkLayout.Padding = UDim.new(0, 6)
categoryBulkLayout.Parent = categoryBulkRow

-- Select All / None row (applies to whatever tab is currently visible)
local bulkRow = Instance.new("Frame")
bulkRow.BackgroundTransparency = 1
bulkRow.Position = UDim2.new(0, 16, 1, -38)
bulkRow.Size = UDim2.new(1, -32, 0, 26)
bulkRow.Parent = frame

local bulkLayout = Instance.new("UIListLayout")
bulkLayout.FillDirection = Enum.FillDirection.Horizontal
bulkLayout.Padding = UDim.new(0, 8)
bulkLayout.Parent = bulkRow

local function pillButton(parent, text, width)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0, width, 1, 0)
	btn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	btn.BackgroundTransparency = 0.9
	btn.AutoButtonColor = false
	btn.Font = Enum.Font.GothamBold
	btn.Text = text
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.TextSize = 12
	btn.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = btn
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(255, 255, 255)
	s.Transparency = 0.8
	s.Parent = btn
	btn.MouseEnter:Connect(function() btn.BackgroundTransparency = 0.75 end)
	btn.MouseLeave:Connect(function() btn.BackgroundTransparency = 0.9 end)
	return btn
end

local selectAllBtn = pillButton(bulkRow, "Select All", 90)
local selectNoneBtn = pillButton(bulkRow, "None", 90)

local rowEntries = {} -- current tab's row instances, for bulk toggling
local rowConnections = {} -- stock .Value change connections, disconnected on every rebuild

-- "All" shows every item from every shop in one combined list, each
-- still tagged with (and toggled against) its real category — Seeds
-- buy loop only ever reads Selected["Seeds"], etc., so toggling an
-- item from the All tab does exactly the same thing as toggling it
-- from its own shop's tab.
local function buildList(tab)
	for _, child in ipairs(listHolder:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	rowEntries = {}

	for _, conn in ipairs(rowConnections) do
		conn:Disconnect()
	end
	rowConnections = {}

	local showAll = tab == "All"

	-- Every item that exists in each shop's stock folder, whether it's
	-- currently in stock or not — filtering by current stock would mean
	-- items disappear from the list the moment they sell out.
	local items = {}
	for _, cat in ipairs(categories) do
		if showAll or cat.key == tab then
			for _, item in ipairs(cat.stock:GetChildren()) do
				table.insert(items, { instance = item, category = cat.key })
			end
		end
	end
	table.sort(items, function(a, b)
		if showAll and a.category ~= b.category then
			return a.category < b.category
		end
		return a.instance.Name < b.instance.Name
	end)

	for _, entry in ipairs(items) do
		local item = entry.instance
		local name = item.Name
		local realCategory = entry.category

		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 28)
		row.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		row.BackgroundTransparency = 0.93
		row.Parent = listHolder

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 8)
		rowCorner.Parent = row

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.new(0, 10, 0, 0)
		label.Size = UDim2.new(1, showAll and -168 or -128, 1, 0)
		label.Font = Enum.Font.Gotham
		label.Text = name
		label.TextColor3 = Color3.fromRGB(230, 230, 235)
		label.TextSize = 12
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Parent = row

		if showAll then
			local tag = Instance.new("TextLabel")
			tag.BackgroundTransparency = 1
			tag.Position = UDim2.new(1, -158, 0, 0)
			tag.Size = UDim2.new(0, 44, 1, 0)
			tag.Font = Enum.Font.GothamBold
			tag.Text = realCategory
			tag.TextColor3 = Color3.fromRGB(150, 150, 155)
			tag.TextSize = 10
			tag.TextXAlignment = Enum.TextXAlignment.Left
			tag.Parent = row
		end

		local stockLabel = Instance.new("TextLabel")
		stockLabel.BackgroundTransparency = 1
		stockLabel.Position = UDim2.new(1, -114, 0, 0)
		stockLabel.Size = UDim2.new(0, 74, 1, 0)
		stockLabel.Font = Enum.Font.Gotham
		stockLabel.TextSize = 11
		stockLabel.TextXAlignment = Enum.TextXAlignment.Right
		stockLabel.Parent = row

		local toggle = Instance.new("TextButton")
		toggle.Position = UDim2.new(1, -34, 0.5, -9)
		toggle.Size = UDim2.new(0, 26, 0, 18)
		toggle.AutoButtonColor = false
		toggle.Text = ""
		toggle.Parent = row

		local toggleCorner = Instance.new("UICorner")
		toggleCorner.CornerRadius = UDim.new(1, 0)
		toggleCorner.Parent = toggle

		local knob = Instance.new("Frame")
		knob.Size = UDim2.new(0, 14, 0, 14)
		knob.Position = UDim2.new(0, 2, 0.5, -7)
		knob.Parent = toggle
		local knobCorner = Instance.new("UICorner")
		knobCorner.CornerRadius = UDim.new(1, 0)
		knobCorner.Parent = knob

		local function paint()
			local on = isSelected(realCategory, name)
			toggle.BackgroundColor3 = on and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(60, 60, 64)
			knob.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
			knob.Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)
		end
		paint()

		local function paintStock()
			local inStock = item.Value and item.Value > 0
			stockLabel.Text = inStock and "In stock" or "Out of stock"
			stockLabel.TextColor3 = inStock and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(130, 130, 135)
		end
		paintStock()
		table.insert(rowConnections, item:GetPropertyChangedSignal("Value"):Connect(paintStock))

		toggle.MouseButton1Click:Connect(function()
			Selected[realCategory][name] = not isSelected(realCategory, name)
			paint()
		end)

		table.insert(rowEntries, { name = name, category = realCategory, paint = paint })
	end
end

selectAllBtn.MouseButton1Click:Connect(function()
	for _, entry in ipairs(rowEntries) do
		Selected[entry.category][entry.name] = true
		entry.paint()
	end
end)
selectNoneBtn.MouseButton1Click:Connect(function()
	for _, entry in ipairs(rowEntries) do
		Selected[entry.category][entry.name] = false
		entry.paint()
	end
end)

-- Selects every item in one category's real stock folder — not just
-- whatever happens to be visible in the current tab — so "All Seeds"
-- works correctly even while you're looking at the Gears tab.
local function selectAllInCategory(categoryKey)
	local cat = nil
	for _, c in ipairs(categories) do
		if c.key == categoryKey then cat = c break end
	end
	if not cat then return end

	for _, item in ipairs(cat.stock:GetChildren()) do
		Selected[categoryKey][item.Name] = true
	end

	for _, entry in ipairs(rowEntries) do
		if entry.category == categoryKey then
			entry.paint()
		end
	end
end

for _, cat in ipairs(categories) do
	local btn = pillButton(categoryBulkRow, "All " .. cat.key, 84)
	btn.MouseButton1Click:Connect(function()
		selectAllInCategory(cat.key)
	end)
end

local function paintTabs()
	for key, btn in pairs(tabButtons) do
		local on = key == activeTab
		btn.BackgroundTransparency = on and 0.75 or 0.94
		btn.TextColor3 = on and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(190, 190, 195)
	end
end

local tabKeys = { "All", "Seeds", "Gears", "Crates" }
for _, key in ipairs(tabKeys) do
	local btn = pillButton(tabBar, key, 60)
	tabButtons[key] = btn
	btn.MouseButton1Click:Connect(function()
		activeTab = key
		paintTabs()
		buildList(key)
	end)
end

paintTabs()
buildList(activeTab)

--========================================================
-- Start the buy loops
--========================================================
runBuyLoop(SeedsStock, PurchaseSeeds, "Seeds")
runBuyLoop(GearsStock, PurchaseGears, "Gears")
runBuyLoop(CratesStock, PurchaseCrates, "Crates")
