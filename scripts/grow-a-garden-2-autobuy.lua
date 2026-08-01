--[[
  Grow A Garden 2 — Auto Buy / Harvest / Sell / Stats
  Clean, readable, no obfuscation, no external network calls beyond the
  game's own remotes. Everything it does is visible below.

  Four tabs:
    Buy     — toggle exactly which seeds/gears/crates get auto-bought,
              item lists built live from the game's own stock folders
    Harvest — auto-harvests fruit, ripe ones first, then attempts
              still-growing ones too
    Sell    — auto-sells your inventory on an adjustable delay
    Stats   — Sheckles earned/spent/net so far, elapsed time, and your
              average income per second/minute/hour/day
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local Networking = require(ReplicatedStorage.SharedModules.Networking)

local PurchaseSeeds = Networking.SeedShop.PurchaseSeed
local SeedsStock = ReplicatedStorage.StockValues.SeedShop.Items

local PurchaseGears = Networking.GearShop.PurchaseGear
local GearsStock = ReplicatedStorage.StockValues.GearShop.Items

local PurchaseCrates = Networking.CrateShop.PurchaseCrate
local CratesStock = ReplicatedStorage.StockValues.CrateShop.Items

local CollectFruit = Networking.Garden.CollectFruit
local SellAll = Networking.NPCS.SellAll

--========================================================
-- Pull prices + player currency straight out of the game's own
-- RestockStoreController, so we don't have to guess the data shape.
-- The same live `playerdata` table backs both affordability checks
-- (Buy tab) and Sheckles tracking (Stats tab).
--
-- getgc() can return thousands of live functions, and debug.info(v,"s")
-- returns nil for some of them (certain closures/C functions) — calling
-- :match() on that nil would throw and kill the whole scan before it
-- ever reaches the real target, so every debug.info call here is
-- defended individually. The scan also retries for up to ~20s instead
-- of running once at script start, since if this runs immediately on
-- join (e.g. via Auto Execute) the game's own shop controller may not
-- have loaded yet — a single early attempt can fail permanently for
-- the whole session with no indication why.
--========================================================
local prices = {}
local playerdata = nil

-- Stats state — declared here (not down in the STATS section) because
-- the retry loop below needs to set these the moment playerdata
-- resolves, which can happen well after script start.
local StatsStartTime = tick()
local StatsStartingSheckles = nil
local TotalEarned = 0
local TotalSpent = 0
local lastSheckles = nil

-- Recognizes playerdata / a prices table by shape rather than by a
-- hardcoded upvalue index, so this keeps working even if the game's
-- controller script gets recompiled and its upvalues shift around
-- (a hardcoded index or line number breaks silently the instant that
-- happens — this doesn't care what index anything is at).
local function looksLikePlayerData(t)
	return type(t) == "table" and type(t.Data) == "table" and type(t.Data.Sheckles) == "number"
end

local function looksLikePrices(t)
	if type(t) ~= "table" then return false end
	for _, entry in pairs(t) do
		if type(entry) == "table" and type(entry.price) == "number" then
			return true
		end
	end
	return false
end

local function tryFindPlayerData()
	local ok = pcall(function()
		for _, v in pairs(getgc()) do
			if type(v) == "function" then
				local src = debug.info(v, "s")
				if src and src:match("RestockStoreController") then
					local i = 1
					while true do
						local ok2, name, value = pcall(debug.getupvalue, v, i)
						if not ok2 or not name then break end
						if not playerdata and looksLikePlayerData(value) then
							playerdata = value
						end
						if #prices == 0 and looksLikePrices(value) then
							table.insert(prices, value)
						end
						i += 1
					end
				end
			end
		end
	end)
	return ok and playerdata ~= nil
end

local PlayerDataSearchFailed = false

-- Exact number only — no leaderstats fallback. If this never resolves,
-- Stats stays honestly unavailable rather than showing an approximate
-- number silently rounded to whatever leaderstats displays.
local function getCurrentSheckles()
	if playerdata and playerdata.Data and type(playerdata.Data.Sheckles) == "number" then
		return playerdata.Data.Sheckles
	end
	return nil
end

task.spawn(function()
	local attempts = 0
	while not playerdata and attempts < 40 do
		tryFindPlayerData()
		if playerdata then break end
		attempts += 1
		task.wait(0.5)
	end
	if playerdata and playerdata.Data and type(playerdata.Data.Sheckles) == "number" then
		StatsStartTime = tick()
		StatsStartingSheckles = playerdata.Data.Sheckles
		lastSheckles = StatsStartingSheckles
	else
		PlayerDataSearchFailed = true
		warn("[SCRIPTEXER] Couldn't find the exact Sheckles value after retrying for 20s. Buy still works (it no longer needs this). Stats tracking will stay disabled.")
	end
end)

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
-- BUY — selection state + buy loop (one per shop)
--========================================================
local Selected = { Seeds = {}, Gears = {}, Crates = {} }

local function isSelected(category, name)
	local v = Selected[category][name]
	if v == nil then return false end -- default off until toggled
	return v
end

local function countSelected()
	local n = 0
	for _, items in pairs(Selected) do
		for _, on in pairs(items) do
			if on then n += 1 end
		end
	end
	return n
end

local BuyInterval = 0.5

-- Live proof-of-activity state.
local BuyFiredCount = 0 -- selected items that got a Fire() call
local BuyLastFired = ""

-- Fires the purchase remote for every selected item on every pass,
-- unconditionally — regardless of stock status or whether you can
-- currently afford it. The server decides whether the purchase goes
-- through; this just keeps asking. (canAfford still exists and is
-- used elsewhere, but is intentionally NOT checked here anymore.)
local function runBuyLoop(stockFolder, remote, category)
	task.spawn(function()
		while task.wait(BuyInterval) do
			for _, item in pairs(stockFolder:GetChildren()) do
				if item and typeof(item) == "Instance" and isSelected(category, item.Name) then
					BuyFiredCount += 1
					BuyLastFired = category .. " · " .. item.Name
					print(string.format("[SCRIPTEXER] Buy fired #%d: %s (%s)", BuyFiredCount, item.Name, category))
					pcall(function()
						remote:Fire(item.Name)
					end)
				end
			end
		end
	end)
end

--========================================================
-- HARVEST — finds your plot, harvests ripe fruit first, then
-- attempts still-growing ones too.
--========================================================
local OwnerPlot = nil
task.spawn(function()
	local gardens = game.Workspace:WaitForChild("Gardens")
	while not OwnerPlot do
		task.wait(0.1)
		for _, plot in pairs(gardens:GetChildren()) do
			if plot:GetAttribute("Owner") == Players.LocalPlayer.Name then
				OwnerPlot = plot
				break
			end
		end
	end
end)

local function isGrown(plant)
	local maxAge = plant:GetAttribute("MaxAge")
	local currentAge = plant:GetAttribute("Age")
	if maxAge == nil or currentAge == nil then return false end
	return currentAge >= maxAge
end

local function getHarvestTargets()
	local targets = {}
	local plantsFolder = OwnerPlot and OwnerPlot:FindFirstChild("Plants")
	if not plantsFolder then return targets end

	for _, plant in pairs(plantsFolder:GetChildren()) do
		local fruitsFolder = plant:FindFirstChild("Fruits")
		if fruitsFolder then
			for _, fruit in pairs(fruitsFolder:GetChildren()) do
				if fruit:IsA("Model") then
					table.insert(targets, fruit)
				end
			end
		elseif plant:IsA("Model") then
			table.insert(targets, plant)
		end
	end

	-- Ripe (fully grown) first; still-growing ones are attempted after.
	table.sort(targets, function(a, b)
		local ra, rb = isGrown(a), isGrown(b)
		if ra ~= rb then return ra end
		return false
	end)
	return targets
end

local function harvestOne(target)
	local id = target:GetAttribute("PlantId")
	local fruitId = target:GetAttribute("FruitId") or ""
	if id then
		CollectFruit:Fire(id, fruitId)
	end
end

local HarvestEnabled = false
local HarvestInterval = 0.5

task.spawn(function()
	while task.wait(HarvestInterval) do
		if HarvestEnabled and OwnerPlot then
			for _, target in ipairs(getHarvestTargets()) do
				harvestOne(target)
			end
		end
	end
end)

--========================================================
-- SELL — fires the game's own "sell everything" remote on a delay.
--========================================================
local SellEnabled = false
local SellInterval = 0.5

task.spawn(function()
	while task.wait(SellInterval) do
		if SellEnabled then
			SellAll:Fire()
		end
	end
end)

--========================================================
-- STATS — tracks Sheckles earned/spent by polling the same live
-- playerdata table used for affordability checks, once a second.
-- (State declared earlier alongside the playerdata retry loop, which
-- sets StatsStartingSheckles/lastSheckles once it actually resolves.)
--========================================================

local function formatElapsed(seconds)
	local h = math.floor(seconds / 3600)
	local m = math.floor((seconds % 3600) / 60)
	local s = math.floor(seconds % 60)
	return string.format("%02d:%02d:%02d", h, m, s)
end

local function formatNumber(n)
	n = math.floor(n + 0.5)
	local sign = n < 0 and "-" or ""
	local digits = tostring(math.abs(n))
	local result = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return sign .. result
end

--========================================================
-- UI — solid dark panel, top-level tabs (Buy / Harvest / Sell / Stats)
--========================================================
local gui = Instance.new("ScreenGui")
gui.Name = "ScriptexerAutoBuyUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local PAGE_HEIGHTS = { Buy = 398, Harvest = 130, Sell = 90, Stats = 232 }
local TOP_OFFSET = 74 -- title + top tab bar

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.AnchorPoint = Vector2.new(1, 0)
frame.Position = UDim2.new(1, -18, 0, 18)
frame.Size = UDim2.new(0, 300, 0, TOP_OFFSET + PAGE_HEIGHTS.Buy + 8)
frame.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
frame.BackgroundTransparency = 0.04
frame.BorderSizePixel = 0
frame.ClipsDescendants = true
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
title.Text = "⚡ SCRIPTEXER"
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

--========================================================
-- Shared UI helpers
--========================================================
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

-- A draggable slider row: label + track + fill + knob. Calls onChange(value)
-- live while dragging, and once on creation with the default value.
local function createSlider(parent, y, labelText, min, max, default, unit, onChange)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Position = UDim2.new(0, 16, 0, y)
	row.Size = UDim2.new(1, -32, 0, 40)
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -56, 0, 16)
	label.Font = Enum.Font.Gotham
	label.TextColor3 = Color3.fromRGB(200, 200, 205)
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	-- Type an exact value directly instead of dragging.
	local valueBox = Instance.new("TextBox")
	valueBox.Position = UDim2.new(1, -50, 0, -1)
	valueBox.Size = UDim2.new(0, 50, 0, 18)
	valueBox.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	valueBox.BackgroundTransparency = 0.9
	valueBox.Font = Enum.Font.GothamBold
	valueBox.TextColor3 = Color3.fromRGB(255, 255, 255)
	valueBox.TextSize = 11
	valueBox.ClearTextOnFocus = false
	valueBox.Parent = row

	local valueBoxCorner = Instance.new("UICorner")
	valueBoxCorner.CornerRadius = UDim.new(0, 6)
	valueBoxCorner.Parent = valueBox

	-- Invisible, larger hit-zone around the thin visual track — 6px is
	-- fine for a mouse cursor but far too thin to reliably grab and
	-- drag with a finger on a touchscreen.
	local hitZone = Instance.new("Frame")
	hitZone.Active = true
	hitZone.BackgroundTransparency = 1
	hitZone.Position = UDim2.new(0, 0, 0, 16)
	hitZone.Size = UDim2.new(1, 0, 0, 24)
	hitZone.Parent = row

	local track = Instance.new("Frame")
	track.Position = UDim2.new(0, 0, 0.5, -3)
	track.Size = UDim2.new(1, 0, 0, 6)
	track.BackgroundColor3 = Color3.fromRGB(50, 50, 54)
	track.BorderSizePixel = 0
	track.Parent = hitZone

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = Color3.fromRGB(120, 255, 170)
	fill.BorderSizePixel = 0
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Size = UDim2.new(0, 14, 0, 14)
	knob.Position = UDim2.new(0, 0, 0.5, 0)
	knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	knob.BorderSizePixel = 0
	knob.ZIndex = 2
	knob.Parent = track

	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = knob

	local currentValue = default
	local editingBox = false

	local function setFromAlpha(alpha)
		alpha = math.clamp(alpha, 0, 1)
		currentValue = min + (max - min) * alpha
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		label.Text = string.format("%s (%s):", labelText, unit)
		if not editingBox then
			valueBox.Text = string.format("%.3f", currentValue)
		end
		onChange(currentValue)
	end

	local dragging = false
	local function alphaFromX(x)
		return (x - hitZone.AbsolutePosition.X) / hitZone.AbsoluteSize.X
	end

	hitZone.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromAlpha(alphaFromX(input.Position.X))
		end
	end)
	hitZone.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	-- Two independent paths for drag continuation: InputChanged covers
	-- mouse movement, TouchMoved is Roblox's dedicated touch-drag event
	-- and is the more reliable of the two specifically for fingers.
	UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			setFromAlpha(alphaFromX(input.Position.X))
		end
	end)
	UserInputService.TouchMoved:Connect(function(touch)
		if dragging then
			setFromAlpha(alphaFromX(touch.Position.X))
		end
	end)

	valueBox.Focused:Connect(function()
		editingBox = true
	end)
	valueBox.FocusLost:Connect(function()
		editingBox = false
		local num = tonumber(valueBox.Text)
		if num then
			setFromAlpha((math.clamp(num, min, max) - min) / (max - min))
		else
			valueBox.Text = string.format("%.3f", currentValue)
		end
	end)

	setFromAlpha((default - min) / (max - min))
	return row
end

-- A labeled on/off switch row.
local function createToggleRow(parent, y, labelText, default, onChange)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Position = UDim2.new(0, 16, 0, y)
	row.Size = UDim2.new(1, -32, 0, 28)
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -46, 1, 0)
	label.Font = Enum.Font.Gotham
	label.Text = labelText
	label.TextColor3 = Color3.fromRGB(230, 230, 235)
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

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

	local state = default
	local function paint()
		toggle.BackgroundColor3 = state and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(60, 60, 64)
		knob.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
		knob.Position = state and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)
	end
	paint()

	toggle.MouseButton1Click:Connect(function()
		state = not state
		paint()
		onChange(state)
	end)

	return row
end

-- A "label ... value" stat row. Returns the value label so callers can
-- update its text later.
local function createStatRow(parent, y, labelText)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Position = UDim2.new(0, 16, 0, y)
	row.Size = UDim2.new(1, -32, 0, 20)
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(0.5, 0, 1, 0)
	label.Font = Enum.Font.Gotham
	label.Text = labelText
	label.TextColor3 = Color3.fromRGB(190, 190, 195)
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	local value = Instance.new("TextLabel")
	value.BackgroundTransparency = 1
	value.Size = UDim2.new(0.5, 0, 1, 0)
	value.Font = Enum.Font.GothamBold
	value.Text = "—"
	value.TextColor3 = Color3.fromRGB(255, 255, 255)
	value.TextSize = 12
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Parent = row

	return value
end

--========================================================
-- Top-level tabs + page containers
--========================================================
local topTabBar = Instance.new("Frame")
topTabBar.BackgroundTransparency = 1
topTabBar.Position = UDim2.new(0, 16, 0, 38)
topTabBar.Size = UDim2.new(1, -32, 0, 26)
topTabBar.Parent = frame

local topTabLayout = Instance.new("UIListLayout")
topTabLayout.FillDirection = Enum.FillDirection.Horizontal
topTabLayout.Padding = UDim.new(0, 4)
topTabLayout.Parent = topTabBar

local pageOrder = { "Buy", "Harvest", "Sell", "Stats" }
local pages = {}
local topTabButtons = {}
local activePage = "Buy"

local function paintTopTabs()
	for key, btn in pairs(topTabButtons) do
		local on = key == activePage
		btn.BackgroundTransparency = on and 0.75 or 0.94
		btn.TextColor3 = on and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(180, 180, 185)
	end
end

local function setActivePage(name)
	activePage = name
	for key, page in pairs(pages) do
		page.Visible = key == name
	end
	frame.Size = UDim2.new(0, 300, 0, TOP_OFFSET + PAGE_HEIGHTS[name] + 8)
	paintTopTabs()
end

for _, key in ipairs(pageOrder) do
	local btn = pillButton(topTabBar, key, 61)
	btn.TextSize = 11
	topTabButtons[key] = btn
	btn.MouseButton1Click:Connect(function()
		setActivePage(key)
	end)

	local page = Instance.new("Frame")
	page.Name = key .. "Page"
	page.BackgroundTransparency = 1
	page.Position = UDim2.new(0, 0, 0, TOP_OFFSET)
	page.Size = UDim2.new(1, 0, 0, PAGE_HEIGHTS[key])
	page.Visible = key == "Buy"
	page.Parent = frame
	pages[key] = page
end

--========================================================
-- BUY page — sub-tabs (All/Seeds/Gears/Crates), interval slider,
-- scrollable item list, per-category quick-select, select all/none
--========================================================
local buyPage = pages.Buy

local subTabBar = Instance.new("Frame")
subTabBar.BackgroundTransparency = 1
subTabBar.Position = UDim2.new(0, 16, 0, 0)
subTabBar.Size = UDim2.new(1, -32, 0, 28)
subTabBar.Parent = buyPage

local subTabLayout = Instance.new("UIListLayout")
subTabLayout.FillDirection = Enum.FillDirection.Horizontal
subTabLayout.Padding = UDim.new(0, 6)
subTabLayout.Parent = subTabBar

local categories = {
	{ key = "Seeds", stock = SeedsStock, remote = PurchaseSeeds },
	{ key = "Gears", stock = GearsStock, remote = PurchaseGears },
	{ key = "Crates", stock = CratesStock, remote = PurchaseCrates },
}

local subTabButtons = {}
local activeSubTab = "All"

createSlider(buyPage, 36, "Buy interval", 0.001, 10, BuyInterval, "s", function(v)
	BuyInterval = v
end)

-- Live proof the loop is actually running: Selected is counted
-- directly from your toggles (independent of whether the loop has run
-- yet), Fired is how many purchase requests have actually gone out.
-- If Selected > 0 but Fired stays 0, the loop itself isn't running —
-- that's now the only remaining failure mode here since firing no
-- longer depends on canAfford.
local buyStatusLabel = Instance.new("TextLabel")
buyStatusLabel.BackgroundTransparency = 1
buyStatusLabel.Position = UDim2.new(0, 16, 0, 146)
buyStatusLabel.Size = UDim2.new(1, -32, 0, 16)
buyStatusLabel.Font = Enum.Font.Gotham
buyStatusLabel.Text = "Selected: 0 · Fired: 0"
buyStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
buyStatusLabel.TextSize = 11
buyStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
buyStatusLabel.TextTruncate = Enum.TextTruncate.AtEnd
buyStatusLabel.Parent = buyPage

task.spawn(function()
	while task.wait(0.2) do
		local selectedCount = countSelected()
		local text = string.format("Selected: %d · Fired: %d", selectedCount, BuyFiredCount)
		if BuyFiredCount > 0 then
			text = text .. " · last: " .. BuyLastFired
			buyStatusLabel.TextColor3 = Color3.fromRGB(120, 255, 170)
		elseif selectedCount > 0 then
			text = text .. " (loop hasn't fired yet — should within " .. string.format("%.2f", BuyInterval) .. "s)"
			buyStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
		else
			buyStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
		end
		buyStatusLabel.Text = text
	end
end)

local listHolder = Instance.new("ScrollingFrame")
listHolder.BackgroundTransparency = 1
listHolder.Position = UDim2.new(0, 16, 0, 170)
listHolder.Size = UDim2.new(1, -32, 0, PAGE_HEIGHTS.Buy - 170 - 8)
listHolder.CanvasSize = UDim2.new(0, 0, 0, 0)
listHolder.AutomaticCanvasSize = Enum.AutomaticSize.Y
listHolder.ScrollBarThickness = 3
listHolder.ScrollBarImageTransparency = 0.4
listHolder.BorderSizePixel = 0
listHolder.Parent = buyPage

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.Parent = listHolder

local categoryBulkRow = Instance.new("Frame")
categoryBulkRow.BackgroundTransparency = 1
categoryBulkRow.Position = UDim2.new(0, 16, 0, 84)
categoryBulkRow.Size = UDim2.new(1, -32, 0, 26)
categoryBulkRow.Parent = buyPage

local categoryBulkLayout = Instance.new("UIListLayout")
categoryBulkLayout.FillDirection = Enum.FillDirection.Horizontal
categoryBulkLayout.Padding = UDim.new(0, 6)
categoryBulkLayout.Parent = categoryBulkRow

local bulkRow = Instance.new("Frame")
bulkRow.BackgroundTransparency = 1
bulkRow.Position = UDim2.new(0, 16, 0, 118)
bulkRow.Size = UDim2.new(1, -32, 0, 26)
bulkRow.Parent = buyPage

local bulkLayout = Instance.new("UIListLayout")
bulkLayout.FillDirection = Enum.FillDirection.Horizontal
bulkLayout.Padding = UDim.new(0, 8)
bulkLayout.Parent = bulkRow

local selectAllBtn = pillButton(bulkRow, "Select All", 90)
local selectNoneBtn = pillButton(bulkRow, "None", 90)

local rowEntries = {}
local rowConnections = {}

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

local function paintSubTabs()
	for key, btn in pairs(subTabButtons) do
		local on = key == activeSubTab
		btn.BackgroundTransparency = on and 0.75 or 0.94
		btn.TextColor3 = on and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(190, 190, 195)
	end
end

local subTabKeys = { "All", "Seeds", "Gears", "Crates" }
for _, key in ipairs(subTabKeys) do
	local btn = pillButton(subTabBar, key, 60)
	subTabButtons[key] = btn
	btn.MouseButton1Click:Connect(function()
		activeSubTab = key
		paintSubTabs()
		buildList(key)
	end)
end

paintSubTabs()
buildList(activeSubTab)

--========================================================
-- HARVEST page
--========================================================
local harvestPage = pages.Harvest

createToggleRow(harvestPage, 0, "Enable Auto Harvest", HarvestEnabled, function(state)
	HarvestEnabled = state
end)

local harvestNote = Instance.new("TextLabel")
harvestNote.BackgroundTransparency = 1
harvestNote.Position = UDim2.new(0, 16, 0, 34)
harvestNote.Size = UDim2.new(1, -32, 0, 32)
harvestNote.Font = Enum.Font.Gotham
harvestNote.Text = "Harvests ripe crops first, then attempts still-growing ones too."
harvestNote.TextColor3 = Color3.fromRGB(150, 150, 155)
harvestNote.TextSize = 11
harvestNote.TextWrapped = true
harvestNote.TextXAlignment = Enum.TextXAlignment.Left
harvestNote.TextYAlignment = Enum.TextYAlignment.Top
harvestNote.Parent = harvestPage

createSlider(harvestPage, 76, "Harvest delay", 0.001, 10, HarvestInterval, "s", function(v)
	HarvestInterval = v
end)

--========================================================
-- SELL page
--========================================================
local sellPage = pages.Sell

createToggleRow(sellPage, 0, "Enable Auto Sell", SellEnabled, function(state)
	SellEnabled = state
end)

createSlider(sellPage, 36, "Sell delay", 0.001, 10, SellInterval, "s", function(v)
	SellInterval = v
end)

--========================================================
-- STATS page
--========================================================
local statsPage = pages.Stats

-- Explains *why* the numbers below aren't populating instead of just
-- showing dashes forever with no indication whether it's still
-- detecting, actually working, or has given up.
local statsStatusLabel = Instance.new("TextLabel")
statsStatusLabel.BackgroundTransparency = 1
statsStatusLabel.Position = UDim2.new(0, 16, 0, 0)
statsStatusLabel.Size = UDim2.new(1, -32, 0, 16)
statsStatusLabel.Font = Enum.Font.GothamBold
statsStatusLabel.Text = "Detecting game data..."
statsStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
statsStatusLabel.TextSize = 11
statsStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
statsStatusLabel.Parent = statsPage

local elapsedValue = createStatRow(statsPage, 20, "Elapsed time")
local earnedValue = createStatRow(statsPage, 44, "Earned so far")
local spentValue = createStatRow(statsPage, 68, "Spent so far")
local netValue = createStatRow(statsPage, 92, "Net so far")
local perSecValue = createStatRow(statsPage, 124, "Per second")
local perMinValue = createStatRow(statsPage, 148, "Per minute")
local perHourValue = createStatRow(statsPage, 172, "Per hour")
local perDayValue = createStatRow(statsPage, 196, "Per day")

local function refreshStatsUI()
	local elapsed = tick() - StatsStartTime
	elapsedValue.Text = formatElapsed(elapsed)

	if not StatsStartingSheckles then
		if PlayerDataSearchFailed then
			statsStatusLabel.Text = "Exact Sheckles value not found — Stats unavailable"
			statsStatusLabel.TextColor3 = Color3.fromRGB(255, 140, 140)
		else
			statsStatusLabel.Text = "Detecting game data..."
			statsStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
		end
		earnedValue.Text = "—"
		spentValue.Text = "—"
		netValue.Text = "—"
		perSecValue.Text = "—"
		perMinValue.Text = "—"
		perHourValue.Text = "—"
		perDayValue.Text = "—"
		return
	end

	statsStatusLabel.Text = "Tracking"
	statsStatusLabel.TextColor3 = Color3.fromRGB(120, 255, 170)

	earnedValue.Text = formatNumber(TotalEarned)
	earnedValue.TextColor3 = Color3.fromRGB(120, 255, 170)

	spentValue.Text = formatNumber(TotalSpent)
	spentValue.TextColor3 = Color3.fromRGB(255, 140, 140)

	local net = TotalEarned - TotalSpent
	netValue.Text = formatNumber(net)
	netValue.TextColor3 = net >= 0 and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(255, 140, 140)

	local rate = elapsed > 0 and (net / elapsed) or 0
	perSecValue.Text = formatNumber(rate)
	perMinValue.Text = formatNumber(rate * 60)
	perHourValue.Text = formatNumber(rate * 3600)
	perDayValue.Text = formatNumber(rate * 86400)
end

task.spawn(function()
	while task.wait(1) do
		local current = getCurrentSheckles()
		if current and lastSheckles then
			local delta = current - lastSheckles
			if delta > 0 then
				TotalEarned += delta
			elseif delta < 0 then
				TotalSpent += (-delta)
			end
			lastSheckles = current
		end
		refreshStatsUI()
	end
end)

refreshStatsUI()

--========================================================
-- Start the buy loops
--========================================================
runBuyLoop(SeedsStock, PurchaseSeeds, "Seeds")
runBuyLoop(GearsStock, PurchaseGears, "Gears")
runBuyLoop(CratesStock, PurchaseCrates, "Crates")

setActivePage("Buy")
