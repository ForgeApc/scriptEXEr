--[[
  Grow A Garden 2 — Auto Buy / Harvest / Sell / Stats
  Clean, readable, no obfuscation, no external network calls beyond the
  game's own remotes. Everything it does is visible below.

  Tabs:
    Buy     — toggle exactly which seeds/gears/crates get auto-bought,
              item lists built live from the game's own stock folders
    Plant   — auto-plants selected seeds at you, randomly across your
              plot, or at one pinned spot
    Drops   — teleports to dropped items and holds E to pick them up
    Harvest — auto-harvests fruit, ripe ones first, then attempts
              still-growing ones too
    Sell    — auto-sells your inventory on an adjustable delay
    Stats   — Sheckles earned/spent/net so far, elapsed time, and your
              average income per second/minute/hour/day
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Networking = require(ReplicatedStorage.SharedModules.Networking)

local PurchaseSeeds = Networking.SeedShop.PurchaseSeed
local SeedsStock = ReplicatedStorage.StockValues.SeedShop.Items

local PurchaseGears = Networking.GearShop.PurchaseGear
local GearsStock = ReplicatedStorage.StockValues.GearShop.Items

local PurchaseCrates = Networking.CrateShop.PurchaseCrate
local CratesStock = ReplicatedStorage.StockValues.CrateShop.Items

local CollectFruit = Networking.Garden.CollectFruit
local SellAll = Networking.NPCS.SellAll
local PlantSeed = Networking.Plant.PlantSeed

-- Item prices, collected opportunistically while searching for the
-- Sheckles balance below. Only used by canAfford(), which the buy
-- loop no longer calls.
local prices = {}

-- Stats state — declared up here (not down in the STATS section)
-- because the search below needs to set these the moment the balance
-- resolves, which can happen well after script start.
local StatsStartTime = tick()
local StatsStartingSheckles = nil
local TotalEarned = 0
local TotalSpent = 0
local lastSheckles = nil

local function looksLikePrices(t)
	if type(t) ~= "table" then return false end
	for _, entry in pairs(t) do
		if type(entry) == "table" and type(entry.price) == "number" then
			return true
		end
	end
	return false
end

--========================================================
-- Finding the EXACT Sheckles balance.
--
-- The previous version only looked at upvalues of functions whose
-- source matched "RestockStoreController" — one hardcoded script
-- name. If that script was renamed, restructured, or simply hadn't
-- loaded, the search found nothing and Stats stayed dead with no way
-- to recover. This tries several independent strategies instead and
-- stops at the first that yields a live number.
--
-- Each strategy returns a *getter*, not a snapshot, so the value
-- stays live as the balance changes.
--========================================================
local sheckleGetter = nil -- function() -> number
local sheckleSource = nil -- short description of which strategy won
local SheckleSearchFailed = false

-- 1. A live table on the GC heap holding the balance. getgc(true)
--    includes tables (not just functions) on most executors, so this
--    can find the player's data table directly — no script name, no
--    upvalue traversal, nothing position-dependent.
local function findViaHeapTables()
	local ok, list = pcall(getgc, true)
	if not ok or type(list) ~= "table" then return nil end
	local scanned = 0
	for _, v in pairs(list) do
		-- getgc(true) can return tens of thousands of tables; yielding
		-- periodically keeps this from visibly freezing the game.
		scanned += 1
		if scanned % 2000 == 0 then task.wait() end
		if type(v) == "table" then
			local ok2, getter = pcall(function()
				local data = rawget(v, "Data")
				if type(data) == "table" and type(rawget(data, "Sheckles")) == "number" then
					return function() return v.Data.Sheckles end
				end
				if type(rawget(v, "Sheckles")) == "number" then
					return function() return v.Sheckles end
				end
				return nil
			end)
			if ok2 and getter then
				pcall(function()
					if #prices == 0 and looksLikePrices(v) then table.insert(prices, v) end
				end)
				return getter, "heap table"
			end
		end
	end
	return nil
end

-- 2. Upvalues of *any* function, not just one named script. Same
--    shape matching as before, just without the name restriction
--    that was likely causing the failure.
local function findViaUpvalues()
	local result, desc = nil, nil
	local scanned = 0
	pcall(function()
		for _, v in pairs(getgc()) do
			scanned += 1
			if scanned % 1000 == 0 then task.wait() end
			if type(v) == "function" then
				local i = 1
				while true do
					local ok, name, value = pcall(debug.getupvalue, v, i)
					if not ok or not name then break end
					if type(value) == "table" then
						local ok2 = pcall(function()
							local data = rawget(value, "Data")
							if type(data) == "table" and type(rawget(data, "Sheckles")) == "number" then
								result = function() return value.Data.Sheckles end
								desc = "upvalue .Data.Sheckles"
							elseif type(rawget(value, "Sheckles")) == "number" then
								result = function() return value.Sheckles end
								desc = "upvalue .Sheckles"
							end
						end)
						if ok2 and result then return end
						if #prices == 0 and looksLikePrices(value) then
							table.insert(prices, value)
						end
					end
					i += 1
				end
			end
		end
	end)
	if result then return result, desc end
	return nil
end

-- 3. A numeric attribute on the player (exact by definition).
local function findViaAttributes()
	local player = Players.LocalPlayer
	local ok, attrs = pcall(function() return player:GetAttributes() end)
	if not ok or type(attrs) ~= "table" then return nil end
	for name, value in pairs(attrs) do
		if type(value) == "number" and tostring(name):lower():match("sheckle") then
			return function() return player:GetAttribute(name) end, "attribute:" .. tostring(name)
		end
	end
	return nil
end

-- Parses a currency string from the game's own on-screen HUD, e.g.
-- "1,913,817" or "$1,913,817" -> 1913817. Deliberately REJECTS
-- abbreviated forms ("1.9M"), because stripping the suffix off those
-- would silently yield 1.9 instead of 1900000 — far worse than
-- reporting no value at all.
local function parseExactNumber(text)
	if type(text) ~= "string" then return nil end
	if text:match("%d%s*[KkMmBbTt]") then return nil end -- abbreviated, not exact
	local cleaned = text:gsub(",", ""):gsub("[^%d%.%-]", "")
	if cleaned == "" then return nil end
	return tonumber(cleaned)
end

-- 4. The game's own on-screen Sheckles counter. Roblox HUDs commonly
--    show the full comma-formatted number even when leaderstats only
--    carries the abbreviated version, so this can be exact where
--    leaderstats isn't.
local function findViaScreenText()
	local player = Players.LocalPlayer
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return nil end

	-- Never match our own panel's number labels — this script formats
	-- its stats with commas too, and reading its own output back in
	-- would be a self-referential feedback loop. (Our GUI normally
	-- lives in CoreGui/gethui() rather than PlayerGui, but guard
	-- anyway in case that ever changes.)
	local function isOurs(inst)
		local node, depth = inst, 0
		while node and depth < 8 do
			if tostring(node.Name):lower():match("scriptexer") then return true end
			node = node.Parent
			depth += 1
		end
		return false
	end

	local named, commaFormatted = nil, nil
	pcall(function()
		for _, inst in ipairs(playerGui:GetDescendants()) do
			if (inst:IsA("TextLabel") or inst:IsA("TextButton")) and not isOurs(inst) and parseExactNumber(inst.Text) then
				-- Prefer a label whose own name (or a nearby ancestor's)
				-- identifies it as the Sheckles display.
				if not named then
					local node, depth = inst, 0
					while node and depth < 4 do
						if tostring(node.Name):lower():match("sheckle") then
							named = inst
							break
						end
						node = node.Parent
						depth += 1
					end
				end
				-- Otherwise fall back to any comma-formatted number, which
				-- in practice is nearly always a currency readout.
				if not commaFormatted and inst.Text:match("%d,%d") then
					commaFormatted = inst
				end
			end
		end
	end)

	local target = named or commaFormatted
	if target then
		return function() return parseExactNumber(target.Text) end, "screen text:" .. tostring(target.Name)
	end
	return nil
end

-- 5. A NumberValue/IntValue somewhere under the player. Deliberately
--    excludes StringValue — a string balance is the abbreviated
--    display form ("1.9M") and isn't exact.
local function findViaValueObjects()
	local player = Players.LocalPlayer
	local ok, descendants = pcall(function() return player:GetDescendants() end)
	if not ok then return nil end
	for _, inst in ipairs(descendants) do
		if (inst:IsA("NumberValue") or inst:IsA("IntValue")) and inst.Name:lower():match("sheckle") then
			return function() return inst.Value end, "value object:" .. inst.Name
		end
	end
	return nil
end

local function getCurrentSheckles()
	if not sheckleGetter then return nil end
	local ok, value = pcall(sheckleGetter)
	if ok and type(value) == "number" then return value end
	return nil
end

task.spawn(function()
	-- Authoritative sources (the game's own data) before display
	-- scraping. Screen text is deliberately LAST: its fallback matches
	-- any comma-formatted number, so if PlayerGui happens to have
	-- rendered some other figure (a price, an inventory count) by the
	-- time we scan, it could win and silently feed Stats a wrong
	-- value. PlayerGui load timing varies between sessions, so letting
	-- it outrank the real data table would make correctness a race.
	-- The heap scan costs a few hundred ms with its yields — cheap
	-- insurance against reading the wrong number.
	local strategies = {
		{ fn = findViaHeapTables, name = "heap tables" },
		{ fn = findViaAttributes, name = "attributes" },
		{ fn = findViaValueObjects, name = "value objects" },
		{ fn = findViaUpvalues, name = "upvalues" },
		{ fn = findViaScreenText, name = "screen text" },
	}

	local attempts = 0
	while not sheckleGetter and attempts < 40 do
		for _, strategy in ipairs(strategies) do
			local ok, getter, desc = pcall(strategy.fn)
			if ok and getter then
				sheckleGetter = getter
				sheckleSource = desc or strategy.name
				break
			end
		end
		if sheckleGetter then break end
		attempts += 1
		task.wait(0.5)
	end

	local starting = getCurrentSheckles()
	if starting then
		StatsStartTime = tick()
		StatsStartingSheckles = starting
		lastSheckles = starting
	else
		SheckleSearchFailed = true
		warn("[SCRIPTEXER] Couldn't find the exact Sheckles balance after trying player attributes, value objects, on-screen text, heap tables and upvalues for 20s. Buy still works (it doesn't need this). Stats will stay unavailable.")
	end
end)

-- Kept for reference/possible future use. The buy loop deliberately
-- does NOT call this — it fires unconditionally and lets the server
-- decide, which is what actually got Buy working.
local function canAfford(item)
	local balance = getCurrentSheckles()
	if not balance or #prices == 0 then return false end
	for _, options in pairs(prices) do
		local success, result = pcall(function()
			local itemData = options[item]
			if not itemData then return false end
			return balance >= itemData.price
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
-- Finding your plot.
--
-- This previously did WaitForChild("Gardens") with no timeout and
-- stopped searching once it found a plot. Both broke on other worlds:
-- a world without a folder literally named "Gardens" made it yield
-- forever (killing harvest AND random-mode planting with no error),
-- and travelling to another world left it pointing at the old world's
-- plot because the search had already exited.
--
-- Now it scans any Workspace container for a plot attributed to you,
-- and keeps re-checking so world travel is picked up.
local OwnerPlot = nil

local function findOwnerPlot()
	local myName = Players.LocalPlayer.Name
	for _, container in ipairs(Workspace:GetChildren()) do
		if container:IsA("Folder") or container:IsA("Model") then
			local ok, children = pcall(function() return container:GetChildren() end)
			if ok then
				for _, plot in ipairs(children) do
					if plot:GetAttribute("Owner") == myName then
						return plot
					end
				end
			end
		end
	end
	return nil
end

task.spawn(function()
	while true do
		-- Re-resolve if we've never found one, or if the one we had has
		-- been unparented (which is what happens on world travel).
		if not OwnerPlot or not OwnerPlot.Parent then
			OwnerPlot = findOwnerPlot()
		end
		task.wait(OwnerPlot and 2 or 0.25)
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
-- PLANT — fires Networking.Plant.PlantSeed for each selected seed.
--
-- The remote's argument ORDER isn't discoverable from the module dump
-- (its Writes serializers are opaque), and guessing wrong would fail
-- silently. So instead of hardcoding a guess, the first plant attempt
-- tries position-first, and if that errors, seed-name-first — then
-- remembers whichever succeeded for the rest of the session. The
-- game's typed serializers reject mismatched argument types, which is
-- what makes this detectable rather than a coin flip.
--========================================================
local PlantEnabled = false
local PlantInterval = 0.5
local PlantSelected = {} -- seed name -> true
local PlantArgOrder = nil -- nil = not yet determined, then "pos_first" / "name_first"
local PlantFiredCount = 0
local PlantLastFired = ""
local PlantLastTool = "none"

local function isPlantSelected(name)
	return PlantSelected[name] == true
end

local function countPlantSelected()
	local n = 0
	for _, on in pairs(PlantSelected) do
		if on then n += 1 end
	end
	return n
end

-- Ground truth for "did a plant actually happen": the game tells the
-- client via Garden.PlantAdded. Without this, the counter only ever
-- proved we *sent* something — a fired request and a successful plant
-- looked identical, which is exactly why "it does not plant" was
-- invisible in the UI.
local PlantConfirmedCount = 0
pcall(function()
	Networking.Garden.PlantAdded.OnClientEvent:Connect(function()
		PlantConfirmedCount += 1
	end)
end)

-- How many arguments the remote actually takes. The Networking module
-- carries one serializer per argument in .Writes, so its length is the
-- arity — a fact, not a guess. Worlds added later (Maple) turned out to
-- differ here, which is why probing only the ORDER of two arguments was
-- never going to be enough.
local PlantArity = nil
pcall(function()
	local writes = PlantSeed.Writes
	if type(writes) == "table" then PlantArity = #writes end
end)

-- Seeds are Tools in the Backpack, and the world prefixes them ("Maple
-- Corn", not "Corn"), so the shop name the UI selects by is not the name
-- the plant remote expects. Resolve to the real Tool, equip it — the
-- server reads the held tool — and fire using its actual name.
local function resolveSeedTool(seedName)
	local player = Players.LocalPlayer
	local character = player.Character
	local backpack = player:FindFirstChildOfClass("Backpack")
	local wanted = seedName:lower()

	local function match(container)
		if not container then return nil end
		for _, tool in ipairs(container:GetChildren()) do
			if tool:IsA("Tool") then
				local n = tool.Name:lower()
				-- Skip harvested produce ("Maple Tulip [1.00kg]"), which
				-- is a different item from the plantable seed.
				if not n:find("%[") and (n == wanted or n:find(wanted, 1, true)) then
					return tool
				end
			end
		end
		return nil
	end

	local tool = match(character) or match(backpack)
	if not tool or not character then return nil end

	-- The captured call passes the Tool as it lives under the CHARACTER
	-- (Workspace.<player>.<tool>), i.e. equipped. Equipping is not
	-- instant, and swapping straight from one seed to another often
	-- doesn't take while another Tool is still held — which is why only
	-- whichever seed happened to be in hand was planting. So: unequip,
	-- equip, then confirm the reparent actually happened.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return nil end

	local function equipped()
		return tool.Parent == character
	end

	local function waitForEquip(seconds)
		local deadline = tick() + seconds
		while tick() < deadline and not equipped() do
			task.wait(0.03)
		end
		return equipped()
	end

	if not equipped() then
		-- Deliberately no UnequipTools here. Unequipping first left the
		-- character empty-handed whenever the follow-up equip did not
		-- take, and nothing could be planted at all until you swapped by
		-- hand. EquipTool swaps on its own; a failed swap now leaves the
		-- previous seed in hand, which is still plantable.
		pcall(function() humanoid:EquipTool(tool) end)
		if not waitForEquip(0.35) then
			-- EquipTool is unreliable in this game (tools carry custom
			-- equip behaviour). Reparenting is what equipping actually
			-- is, and the client may do it to its own Backpack tools —
			-- but only when nothing else is held, since forcing a second
			-- Tool into the character is what the game rejects.
			if not character:FindFirstChildOfClass("Tool") then
				pcall(function() tool.Parent = character end)
				waitForEquip(0.35)
			end
		end
	end

	-- Return it either way: firing while holding it is far more likely to
	-- work than not firing at all, and a refusal here is indistinguishable
	-- from a broken remote in the UI.
	return tool
end

-- Every plausible shape, each labelled so the winner can be shown in the
-- UI. Built per-call because they close over the actual values.
local function plantCandidates(seedName, position, tool)
	local cf = CFrame.new(position)
	local plot = OwnerPlot
	return {
		-- The real shape, captured off the game's own call with a hook on
		-- PlantSeed.Fire: (Vector3, seed name, the equipped Tool).
		{ name = "pos_name_tool", args = { position, seedName, tool }, n = 3 },
		-- Everything below is fallback for other worlds.
		{ name = "name_pos_plot", args = { seedName, position, plot } },
		{ name = "plot_name_pos", args = { plot, seedName, position } },
		{ name = "name_pos_rot", args = { seedName, position, 0 } },
		{ name = "name_cf_plot", args = { seedName, cf, plot } },
		{ name = "tool_pos_plot", args = { tool, position, plot } },
		{ name = "tool_name_pos", args = { tool, seedName, position } },
		{ name = "plot_tool_pos", args = { plot, tool, position } },
		{ name = "plot_pos_name", args = { plot, position, seedName } },
		{ name = "pos_name_plot", args = { position, seedName, plot } },
		{ name = "pos_plot_name", args = { position, plot, seedName } },
		{ name = "name_pos_tool", args = { seedName, position, tool } },
		{ name = "cf_name_plot", args = { cf, seedName, plot } },
		{ name = "name_cf_rot", args = { seedName, cf, 0 } },
		-- Fallbacks for other worlds.
		{ name = "pos_first", args = { position, seedName } },
		{ name = "name_first", args = { seedName, position } },
		{ name = "name_cf", args = { seedName, cf } },
		{ name = "cf_first", args = { cf, seedName } },
		{ name = "pos_only", args = { position } },
		{ name = "name_only", args = { seedName } },
	}
end

-- Argument counts are declared explicitly: a nil in the list (no plot
-- resolved yet, no Tool found) would otherwise shorten it silently and
-- make a 3-arg shape look like a 2-arg one.
local function argCount(candidate)
	return candidate.n or #candidate.args
end

local function fireCandidate(candidate)
	local n = argCount(candidate)
	return pcall(function() PlantSeed:Fire(table.unpack(candidate.args, 1, n)) end)
end

local function firePlant(seedName, position)
	local tool = resolveSeedTool(seedName)
	local character = Players.LocalPlayer.Character
	PlantLastTool = tool
		and (tool.Name .. (tool.Parent == character and " (held)" or " (NOT held)"))
		or "none"
	-- No equipped Tool means there's nothing to plant with — firing
	-- anyway would just spam the remote with a seed we don't hold.
	if not tool then return false end

	-- Use the Tool's real in-world name: the shop name and the item name
	-- differ in prefixed worlds like Maple.
	local candidates = plantCandidates(tool.Name, position, tool)

	if PlantArgOrder then
		for _, candidate in ipairs(candidates) do
			if candidate.name == PlantArgOrder then return fireCandidate(candidate) end
		end
	end

	-- Shape still unknown. pcall success alone is NOT proof it was right
	-- — the remote may accept mismatched arguments happily and simply do
	-- nothing server-side, which would lock in a silently broken shape
	-- forever. So each candidate is confirmed against PlantAdded before
	-- being committed to. When the arity is known, candidates that don't
	-- match it are skipped outright.
	for _, candidate in ipairs(candidates) do
		if not PlantArity or argCount(candidate) == PlantArity then
			local before = PlantConfirmedCount
			if fireCandidate(candidate) then
				local deadline = tick() + 0.6
				while tick() < deadline do
					if PlantConfirmedCount > before then
						PlantArgOrder = candidate.name
						return true
					end
					task.wait(0.05)
				end
			end
		end
	end
	return false
end

--------------------------------------------------------
-- Where to plant. Three modes:
--   "me"     — at your character, so it fills in as you walk
--   "random" — scattered randomly across your plot
--   "fixed"  — one pinned spot you set yourself
--------------------------------------------------------
local PlantMode = "me"
local PlantFixedPosition = nil

-- The plot's ground is taken to be its largest part by footprint,
-- which is what the farmland slab reliably is. Planting happens on
-- that part's top surface rather than at its centre, so seeds land on
-- the ground instead of inside it.
local function getPlotGround()
	if not OwnerPlot then return nil end
	local best, bestArea = nil, 0
	for _, part in ipairs(OwnerPlot:GetDescendants()) do
		if part:IsA("BasePart") then
			local area = part.Size.X * part.Size.Z
			if area > bestArea then
				best, bestArea = part, area
			end
		end
	end
	return best
end

local function randomPlotPosition()
	local ground = getPlotGround()
	if not ground then return nil end
	-- Inset from the edges so seeds don't land half off the plot.
	local offsetX = (math.random() * 2 - 1) * (ground.Size.X / 2) * 0.85
	local offsetZ = (math.random() * 2 - 1) * (ground.Size.Z / 2) * 0.85
	-- Go through the part's own CFrame so a rotated plot still works.
	local spot = ground.CFrame * CFrame.new(offsetX, 0, offsetZ)
	local topY = ground.Position.Y + (ground.Size.Y / 2)
	return Vector3.new(spot.Position.X, topY, spot.Position.Z)
end

local function getPlantPosition()
	if PlantMode == "fixed" then
		return PlantFixedPosition
	elseif PlantMode == "random" then
		return randomPlotPosition()
	end
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then return root.Position end
	return nil
end

-- Is the Tool currently in your hands one of the seeds you selected?
-- Selection is by shop name ("Carrot"); the held Tool carries the
-- world-prefixed name ("Maple Carrot"), so match loosely, and ignore
-- harvested produce, whose name carries a [1.00kg] weight.
local function heldSelectedSeed()
	local character = Players.LocalPlayer.Character
	if not character then return nil end
	for _, tool in ipairs(character:GetChildren()) do
		if tool:IsA("Tool") and not tool.Name:find("%[") then
			local held = tool.Name:lower()
			for seedName, on in pairs(PlantSelected) do
				if on then
					local wanted = seedName:lower()
					if held == wanted or held:find(wanted, 1, true) then
						return tool
					end
				end
			end
		end
	end
	return nil
end

-- Selected seeds in a stable order, so rotation goes round the list
-- instead of jumping about (pairs order is arbitrary).
local function selectedSeedNames()
	local names = {}
	for seedName, on in pairs(PlantSelected) do
		if on then table.insert(names, seedName) end
	end
	table.sort(names)
	return names
end

-- Equips the seed after the one currently held, wrapping around. The
-- earlier failures came from equipping and firing in the same breath;
-- the swap does take, it just isn't ready that instant. So this only
-- ever equips, and the plant happens on a later tick once the Tool has
-- actually arrived in your hands.
local PlantRotateIndex = 0

local function equipNextSelectedSeed()
	local names = selectedSeedNames()
	if #names == 0 then return end
	for _ = 1, #names do
		PlantRotateIndex = (PlantRotateIndex % #names) + 1
		if resolveSeedTool(names[PlantRotateIndex]) then return end
	end
end

-- How long to keep planting one seed before moving to the next. Short
-- enough that every selected seed gets planted, long enough that the
-- equip has time to land.
local PlantSwitchAfter = 1.5
local PlantCurrentSince = 0
local PlantCurrentName = nil

task.spawn(function()
	while task.wait(PlantInterval) do
		if PlantEnabled then
			local names = selectedSeedNames()
			-- Plant whatever selected seed is actually in your hands.
			-- Only a settled equip makes the server accept a plant.
			local tool = heldSelectedSeed()
			if tool then
				if tool.Name ~= PlantCurrentName then
					PlantCurrentName = tool.Name
					PlantCurrentSince = tick()
				end

				local position = getPlantPosition()
				if position then
					if firePlant(tool.Name, position) then
						PlantFiredCount += 1
						PlantLastFired = tool.Name
					end
				end

				-- Rotate to the next selected seed so the whole selection
				-- gets planted without you switching by hand. If the swap
				-- doesn't land, the seed already in hand stays held and
				-- planting simply continues — rotation must never be able
				-- to leave you holding nothing.
				if #names > 1 and tick() - PlantCurrentSince >= PlantSwitchAfter then
					PlantCurrentSince = tick()
					equipNextSelectedSeed()
					if not heldSelectedSeed() then
						resolveSeedTool(tool.Name)
					end
				end
			else
				-- Nothing selected is held, so there's nothing the game
				-- will let us plant — equip one and pick it up next tick.
				equipNextSelectedSeed()
			end
		end
	end
end)

--========================================================
-- DROPS — teleports to dropped items the moment they appear.
--
-- The Networking dump has DroppedItem.PickupFx and RequestDrop but no
-- "pick this up" remote, so collection is proximity-based: you hold E
-- on a ProximityPrompt. That means teleporting to it and triggering
-- the prompt, not firing a remote.
--
-- Detection watches for ProximityPrompts specifically, rather than any
-- new Model/BasePart. That's both more precise and much safer: an
-- earlier version matched every instance streamed into Workspace,
-- which with "collect everything" on would have teleported you to
-- essentially every part that loaded. Requiring a prompt means we only
-- ever target things that are genuinely pick-up-able, and it needs no
-- guesswork about which folder drops live in.
--========================================================

local CollectEnabled = false
local CollectEverything = true
local CollectSelected = {} -- item name -> true
local CollectReturn = true -- go back to where you were afterwards
local CollectDwell = 0.01 -- seconds to linger before triggering
local CollectedCount = 0
local CollectLast = ""
local CollectPending = {}

local function isCollectSelected(name)
	return CollectSelected[name] == true
end

local function countCollectSelected()
	local n = 0
	for _, on in pairs(CollectSelected) do
		if on then n += 1 end
	end
	return n
end

-- Exact (case-insensitive) name match. Gold / Rainbow / Mega are their
-- own distinct seeds here, not mutation prefixes on other seeds, so
-- substring matching would wrongly rope in unrelated items.
local function matchesCollectFilter(name)
	if CollectEverything then return true end
	local lower = tostring(name):lower()
	for selected, on in pairs(CollectSelected) do
		if on and tostring(selected):lower() == lower then
			return true
		end
	end
	return false
end

local function getRoot()
	local character = Players.LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

-- What to call a prompt's item, for filtering and for the status line.
local function promptName(prompt)
	if prompt.ObjectText and prompt.ObjectText ~= "" then
		return prompt.ObjectText
	end
	local parent = prompt.Parent
	return parent and parent.Name or "?"
end

local function promptPosition(prompt)
	local node = prompt.Parent
	local depth = 0
	while node and depth < 4 do
		if node:IsA("BasePart") then return node.Position end
		if node:IsA("Model") then
			local part = node.PrimaryPart or node:FindFirstChildWhichIsA("BasePart")
			if part then return part.Position end
		end
		node = node.Parent
		depth += 1
	end
	return nil
end

-- Zeroing HoldDuration is what makes "hold E" instant. InputHoldBegin/
-- InputHoldEnd are ordinary LocalScript APIs, so this works even on
-- executors without fireproximityprompt — that's only the fallback.
local function triggerPrompt(prompt)
	pcall(function()
		prompt.HoldDuration = 0
		prompt.Enabled = true
		prompt.MaxActivationDistance = math.max(prompt.MaxActivationDistance, 50)
	end)
	local ok = pcall(function()
		prompt:InputHoldBegin()
		task.wait()
		prompt:InputHoldEnd()
	end)
	if not ok and fireproximityprompt then
		pcall(fireproximityprompt, prompt)
	end
end

local function collectDrop(prompt)
	if not prompt or not prompt.Parent then return false end
	local root = getRoot()
	if not root then return false end
	local position = promptPosition(prompt)
	if not position then return false end

	local origin = root.CFrame
	root.CFrame = CFrame.new(position + Vector3.new(0, 3, 0))
	task.wait(CollectDwell)
	triggerPrompt(prompt)

	if CollectReturn then
		local rootNow = getRoot()
		if rootNow then rootNow.CFrame = origin end
	end
	return true
end

Workspace.DescendantAdded:Connect(function(inst)
	-- Cheapest possible early-out: this fires constantly as parts
	-- stream in, and the class check rejects almost everything.
	if not CollectEnabled then return end
	if not inst:IsA("ProximityPrompt") then return end
	if not matchesCollectFilter(promptName(inst)) then return end
	table.insert(CollectPending, inst)
end)

task.spawn(function()
	while task.wait(0.05) do
		if CollectEnabled and #CollectPending > 0 then
			local target = table.remove(CollectPending, 1)
			local name = "?"
			pcall(function() name = promptName(target) end)
			local ok, collected = pcall(collectDrop, target)
			if ok and collected then
				CollectedCount += 1
				CollectLast = name
			end
		elseif #CollectPending > 0 then
			-- Disabled mid-queue; don't teleport to stale targets later.
			CollectPending = {}
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
-- STATS — polls the exact Sheckles balance once a second and
-- accumulates every increase as earned and every decrease as spent,
-- so selling shows up as cumulative income. (State is declared
-- earlier, alongside the balance search that sets it up.)
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

local PAGE_HEIGHTS = { Buy = 398, Plant = 384, Drops = 380, Harvest = 130, Sell = 90, Stats = 232 }
local TOP_OFFSET = 74 -- title + top tab bar

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.AnchorPoint = Vector2.new(1, 0)
frame.Position = UDim2.new(1, -18, 0, 18)
frame.Size = UDim2.new(0, 344, 0, TOP_OFFSET + PAGE_HEIGHTS.Buy + 8)
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
-- Setters for the widgets the site can drive, keyed by the same names
-- the remote config uses. Populated at each widget's call site.
local RemoteWidgets = {}

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

	-- Second return is a setter, so something other than the user's
	-- finger — the site, over remote control — can move the slider and
	-- have it look moved.
	return row, function(value)
		setFromAlpha((math.clamp(value, min, max) - min) / (max - min))
	end
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

	-- Second return lets remote control flip the switch for real: the
	-- knob slides over, not just the underlying value.
	return row, function(value)
		if state == value then return end
		state = value
		paint()
		onChange(state)
	end
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

local pageOrder = { "Buy", "Plant", "Drops", "Harvest", "Sell", "Stats" }
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
	frame.Size = UDim2.new(0, 344, 0, TOP_OFFSET + PAGE_HEIGHTS[name] + 8)
	paintTopTabs()
end

for _, key in ipairs(pageOrder) do
	-- 5 tabs across a 268px inner width with 4px gaps.
	local btn = pillButton(topTabBar, key, 48)
	btn.TextSize = 10
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

RemoteWidgets.buyInterval = select(2, createSlider(buyPage, 36, "Buy interval", 0.001, 10, BuyInterval, "s", function(v)
	BuyInterval = v
end))

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
-- PLANT page
--========================================================
local plantPage = pages.Plant

RemoteWidgets.plantEnabled = select(2, createToggleRow(plantPage, 0, "Enable Auto Plant", PlantEnabled, function(state)
	PlantEnabled = state
end))

RemoteWidgets.plantInterval = select(2, createSlider(plantPage, 32, "Plant delay", 0.001, 10, PlantInterval, "s", function(v)
	PlantInterval = v
end))

-- Placement mode selector
local plantModeRow = Instance.new("Frame")
plantModeRow.BackgroundTransparency = 1
plantModeRow.Position = UDim2.new(0, 16, 0, 76)
plantModeRow.Size = UDim2.new(1, -32, 0, 26)
plantModeRow.Parent = plantPage

local plantModeLayout = Instance.new("UIListLayout")
plantModeLayout.FillDirection = Enum.FillDirection.Horizontal
plantModeLayout.Padding = UDim.new(0, 8)
plantModeLayout.Parent = plantModeRow

local plantModeButtons = {}
local plantModes = {
	{ key = "me", label = "At me" },
	{ key = "random", label = "Random" },
	{ key = "fixed", label = "Fixed" },
}

local function paintPlantModes()
	for key, btn in pairs(plantModeButtons) do
		local on = key == PlantMode
		btn.BackgroundTransparency = on and 0.75 or 0.94
		btn.TextColor3 = on and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(180, 180, 185)
	end
end

for _, mode in ipairs(plantModes) do
	local btn = pillButton(plantModeRow, mode.label, 84)
	plantModeButtons[mode.key] = btn
	btn.MouseButton1Click:Connect(function()
		PlantMode = mode.key
		paintPlantModes()
	end)
end
paintPlantModes()

-- Pins the fixed-mode spot to wherever you're standing right now.
local setFixedBtn = pillButton(plantPage, "Set fixed spot to where I'm standing", 268)
setFixedBtn.Position = UDim2.new(0, 16, 0, 108)
setFixedBtn.Size = UDim2.new(1, -32, 0, 26)
setFixedBtn.TextSize = 11
setFixedBtn.MouseButton1Click:Connect(function()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		PlantFixedPosition = root.Position
		PlantMode = "fixed"
		paintPlantModes()
	end
end)

local plantStatusLabel = Instance.new("TextLabel")
plantStatusLabel.BackgroundTransparency = 1
plantStatusLabel.Position = UDim2.new(0, 16, 0, 140)
plantStatusLabel.Size = UDim2.new(1, -32, 0, 28)
plantStatusLabel.Font = Enum.Font.Gotham
plantStatusLabel.Text = "Planting at your position as you move."
plantStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
plantStatusLabel.TextSize = 11
plantStatusLabel.TextWrapped = true
plantStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
plantStatusLabel.TextYAlignment = Enum.TextYAlignment.Top
plantStatusLabel.Parent = plantPage

task.spawn(function()
	while task.wait(0.2) do
		local selectedCount = countPlantSelected()
		if PlantConfirmedCount > 0 then
			plantStatusLabel.Text = string.format(
				"Planted: %d · sent: %d · last: %s (%s)",
				PlantConfirmedCount, PlantFiredCount, PlantLastFired, PlantArgOrder or "?"
			)
			plantStatusLabel.TextColor3 = Color3.fromRGB(120, 255, 170)
		elseif PlantFiredCount > 0 then
			-- Requests are going out but the game never reported a plant:
			-- wrong spot, no seeds, or this world rejects it.
			plantStatusLabel.Text = string.format(
				"Sent %d requests · %s args · tool: %s — none planted yet.",
				PlantFiredCount, PlantArity and tostring(PlantArity) or "?", PlantLastTool
			)
			plantStatusLabel.TextColor3 = Color3.fromRGB(255, 140, 140)
		elseif PlantMode == "fixed" and not PlantFixedPosition then
			plantStatusLabel.Text = "No fixed spot set — tap the button above to pin one."
			plantStatusLabel.TextColor3 = Color3.fromRGB(255, 140, 140)
		elseif PlantMode == "random" and not OwnerPlot then
			plantStatusLabel.Text = "Still locating your plot for random placement…"
			plantStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
		elseif PlantEnabled and selectedCount > 0 then
			plantStatusLabel.Text = "Trying to plant… make sure you own the selected seeds."
			plantStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
		elseif PlantMode == "random" then
			plantStatusLabel.Text = "Scattering randomly across your plot."
			plantStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
		elseif PlantMode == "fixed" then
			plantStatusLabel.Text = "Planting at your pinned spot."
			plantStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
		else
			plantStatusLabel.Text = "Planting at your position as you move."
			plantStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
		end
	end
end)

local plantBulkRow = Instance.new("Frame")
plantBulkRow.BackgroundTransparency = 1
plantBulkRow.Position = UDim2.new(0, 16, 0, 172)
plantBulkRow.Size = UDim2.new(1, -32, 0, 26)
plantBulkRow.Parent = plantPage

local plantBulkLayout = Instance.new("UIListLayout")
plantBulkLayout.FillDirection = Enum.FillDirection.Horizontal
plantBulkLayout.Padding = UDim.new(0, 8)
plantBulkLayout.Parent = plantBulkRow

local plantAllBtn = pillButton(plantBulkRow, "Select All", 90)
local plantNoneBtn = pillButton(plantBulkRow, "None", 90)

local plantList = Instance.new("ScrollingFrame")
plantList.BackgroundTransparency = 1
plantList.Position = UDim2.new(0, 16, 0, 206)
plantList.Size = UDim2.new(1, -32, 0, PAGE_HEIGHTS.Plant - 206 - 8)
plantList.CanvasSize = UDim2.new(0, 0, 0, 0)
plantList.AutomaticCanvasSize = Enum.AutomaticSize.Y
plantList.ScrollBarThickness = 3
plantList.ScrollBarImageTransparency = 0.4
plantList.BorderSizePixel = 0
plantList.Parent = plantPage

local plantListLayout = Instance.new("UIListLayout")
plantListLayout.Padding = UDim.new(0, 4)
plantListLayout.Parent = plantList

local plantRowEntries = {}

do
	-- Seed names come from the shop's stock folder, same source the Buy
	-- tab uses — it's the full catalog regardless of what you own, and
	-- the server rejects planting anything you don't have, consistent
	-- with how Buy fires unconditionally and lets the server decide.
	local names = {}
	for _, item in ipairs(SeedsStock:GetChildren()) do
		table.insert(names, item.Name)
	end
	table.sort(names)

	for _, name in ipairs(names) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 28)
		row.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		row.BackgroundTransparency = 0.93
		row.Parent = plantList

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 8)
		rowCorner.Parent = row

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.new(0, 10, 0, 0)
		label.Size = UDim2.new(1, -46, 1, 0)
		label.Font = Enum.Font.Gotham
		label.Text = name
		label.TextColor3 = Color3.fromRGB(230, 230, 235)
		label.TextSize = 12
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
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

		local function paint()
			local on = isPlantSelected(name)
			toggle.BackgroundColor3 = on and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(60, 60, 64)
			knob.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
			knob.Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)
		end
		paint()

		toggle.MouseButton1Click:Connect(function()
			PlantSelected[name] = not isPlantSelected(name)
			paint()
		end)

		table.insert(plantRowEntries, { name = name, paint = paint })
	end
end

plantAllBtn.MouseButton1Click:Connect(function()
	for _, entry in ipairs(plantRowEntries) do
		PlantSelected[entry.name] = true
		entry.paint()
	end
end)
plantNoneBtn.MouseButton1Click:Connect(function()
	for _, entry in ipairs(plantRowEntries) do
		PlantSelected[entry.name] = false
		entry.paint()
	end
end)

--========================================================
-- DROPS page
--========================================================
local dropsPage = pages.Drops

RemoteWidgets.collectEnabled = select(2, createToggleRow(dropsPage, 0, "Enable Auto Collect", CollectEnabled, function(state)
	CollectEnabled = state
end))

RemoteWidgets.collectReturn = select(2, createToggleRow(dropsPage, 30, "Return to my spot after", CollectReturn, function(state)
	CollectReturn = state
end))

RemoteWidgets.collectEverything = select(2, createToggleRow(dropsPage, 60, "Collect everything dropped", CollectEverything, function(state)
	CollectEverything = state
end))

RemoteWidgets.collectDwell = select(2, createSlider(dropsPage, 94, "Pickup dwell", 0.01, 2, CollectDwell, "s", function(v)
	CollectDwell = v
end))

local dropsStatusLabel = Instance.new("TextLabel")
dropsStatusLabel.BackgroundTransparency = 1
dropsStatusLabel.Position = UDim2.new(0, 16, 0, 138)
dropsStatusLabel.Size = UDim2.new(1, -32, 0, 28)
dropsStatusLabel.Font = Enum.Font.Gotham
dropsStatusLabel.Text = "Teleports to drops and holds E for you."
dropsStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
dropsStatusLabel.TextSize = 11
dropsStatusLabel.TextWrapped = true
dropsStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
dropsStatusLabel.TextYAlignment = Enum.TextYAlignment.Top
dropsStatusLabel.Parent = dropsPage

task.spawn(function()
	while task.wait(0.2) do
		if CollectedCount > 0 then
			dropsStatusLabel.Text = string.format("Collected: %d · last: %s", CollectedCount, CollectLast)
			dropsStatusLabel.TextColor3 = Color3.fromRGB(120, 255, 170)
		elseif CollectEnabled and not CollectEverything and countCollectSelected() == 0 then
			dropsStatusLabel.Text = "Nothing selected below, and 'collect everything' is off."
			dropsStatusLabel.TextColor3 = Color3.fromRGB(255, 140, 140)
		elseif CollectEnabled then
			dropsStatusLabel.Text = "Watching for drops…"
			dropsStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
		else
			dropsStatusLabel.Text = "Teleports to drops and holds E for you."
			dropsStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
		end
	end
end)

local dropsBulkRow = Instance.new("Frame")
dropsBulkRow.BackgroundTransparency = 1
dropsBulkRow.Position = UDim2.new(0, 16, 0, 168)
dropsBulkRow.Size = UDim2.new(1, -32, 0, 26)
dropsBulkRow.Parent = dropsPage

local dropsBulkLayout = Instance.new("UIListLayout")
dropsBulkLayout.FillDirection = Enum.FillDirection.Horizontal
dropsBulkLayout.Padding = UDim.new(0, 8)
dropsBulkLayout.Parent = dropsBulkRow

local dropsAllBtn = pillButton(dropsBulkRow, "Select All", 90)
local dropsNoneBtn = pillButton(dropsBulkRow, "None", 90)

local dropsList = Instance.new("ScrollingFrame")
dropsList.BackgroundTransparency = 1
dropsList.Position = UDim2.new(0, 16, 0, 202)
dropsList.Size = UDim2.new(1, -32, 0, PAGE_HEIGHTS.Drops - 202 - 8)
dropsList.CanvasSize = UDim2.new(0, 0, 0, 0)
dropsList.AutomaticCanvasSize = Enum.AutomaticSize.Y
dropsList.ScrollBarThickness = 3
dropsList.ScrollBarImageTransparency = 0.4
dropsList.BorderSizePixel = 0
dropsList.Parent = dropsPage

local dropsListLayout = Instance.new("UIListLayout")
dropsListLayout.Padding = UDim.new(0, 4)
dropsListLayout.Parent = dropsList

local dropsRowEntries = {}

do
	-- Filter names come from the live seed stock, same as everywhere
	-- else, so they're real in-game names rather than guesses. Matched
	-- exactly — Gold, Rainbow and Mega are their own seeds, not
	-- prefixes on other seeds.
	local names = {}
	for _, item in ipairs(SeedsStock:GetChildren()) do
		table.insert(names, item.Name)
	end
	table.sort(names)

	for _, name in ipairs(names) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 28)
		row.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		row.BackgroundTransparency = 0.93
		row.Parent = dropsList

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 8)
		rowCorner.Parent = row

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.new(0, 10, 0, 0)
		label.Size = UDim2.new(1, -46, 1, 0)
		label.Font = Enum.Font.Gotham
		label.Text = name
		label.TextColor3 = Color3.fromRGB(230, 230, 235)
		label.TextSize = 12
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
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

		local function paint()
			local on = isCollectSelected(name)
			toggle.BackgroundColor3 = on and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(60, 60, 64)
			knob.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
			knob.Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)
		end
		paint()

		toggle.MouseButton1Click:Connect(function()
			CollectSelected[name] = not isCollectSelected(name)
			paint()
		end)

		table.insert(dropsRowEntries, { name = name, paint = paint })
	end
end

dropsAllBtn.MouseButton1Click:Connect(function()
	for _, entry in ipairs(dropsRowEntries) do
		CollectSelected[entry.name] = true
		entry.paint()
	end
end)
dropsNoneBtn.MouseButton1Click:Connect(function()
	for _, entry in ipairs(dropsRowEntries) do
		CollectSelected[entry.name] = false
		entry.paint()
	end
end)

--========================================================
-- HARVEST page
--========================================================
local harvestPage = pages.Harvest

RemoteWidgets.harvestEnabled = select(2, createToggleRow(harvestPage, 0, "Enable Auto Harvest", HarvestEnabled, function(state)
	HarvestEnabled = state
end))

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

RemoteWidgets.harvestInterval = select(2, createSlider(harvestPage, 76, "Harvest delay", 0.001, 10, HarvestInterval, "s", function(v)
	HarvestInterval = v
end))

--========================================================
-- SELL page
--========================================================
local sellPage = pages.Sell

RemoteWidgets.sellEnabled = select(2, createToggleRow(sellPage, 0, "Enable Auto Sell", SellEnabled, function(state)
	SellEnabled = state
end))

RemoteWidgets.sellInterval = select(2, createSlider(sellPage, 36, "Sell delay", 0.001, 10, SellInterval, "s", function(v)
	SellInterval = v
end))

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
		if SheckleSearchFailed then
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

	statsStatusLabel.Text = "Tracking · " .. tostring(sheckleSource or "?")
	statsStatusLabel.TextColor3 = Color3.fromRGB(120, 255, 170)

	earnedValue.Text = formatNumber(TotalEarned)
	earnedValue.TextColor3 = Color3.fromRGB(120, 255, 170)

	spentValue.Text = formatNumber(TotalSpent)
	spentValue.TextColor3 = Color3.fromRGB(255, 140, 140)

	local net = TotalEarned - TotalSpent
	netValue.Text = formatNumber(net)
	netValue.TextColor3 = net >= 0 and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(255, 140, 140)

	-- Small rates need decimals: formatNumber rounds to whole Sheckles,
	-- so a real per-second rate of 0.4 was displaying as a flat 0 and
	-- reading like the tracking was broken.
	local function formatRate(n)
		if math.abs(n) < 100 then
			return string.format("%.2f", n)
		end
		return formatNumber(n)
	end

	local rate = elapsed > 0 and (net / elapsed) or 0
	perSecValue.Text = formatRate(rate)
	perMinValue.Text = formatRate(rate * 60)
	perHourValue.Text = formatRate(rate * 3600)
	perDayValue.Text = formatRate(rate * 86400)
end

-- Sampling runs every frame, NOT on the UI's refresh interval.
--
-- This used to poll once a second, which silently corrupted the
-- earned/spent split: with auto-buy and auto-sell running, many
-- transactions land inside a single second, and diffing only the
-- endpoints collapses them into one net figure. Earn 1,000 and spend
-- 800 in the same tick and it recorded +200 earned, 0 spent — both
-- totals wrong, while the net still looked plausible, which is what
-- made it hard to notice.
--
-- Reading a table field per frame is cheap; the expensive part is
-- redrawing text, so that stays on a slower loop below.
game:GetService("RunService").Heartbeat:Connect(function()
	local current = getCurrentSheckles()
	if not current then return end
	if lastSheckles then
		local delta = current - lastSheckles
		if delta > 0 then
			TotalEarned += delta
		elseif delta < 0 then
			TotalSpent += (-delta)
		end
	end
	lastSheckles = current
end)

task.spawn(function()
	while task.wait(0.2) do
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

--========================================================
-- REMOTE CONTROL
--
-- Shows a short link code in the panel. Enter that code at
-- scriptexer's /control page and the site can flip the same
-- switches from your phone or PC, without touching the game.
--
-- Config is a single row in Supabase keyed by the code. The script
-- polls it and applies whatever changed; it also writes back a little
-- status so the site can show what's actually happening in-game.
--========================================================
do
	local HttpService = game:GetService("HttpService")

	local SUPABASE_URL = "https://fscazttvhgwaqxkdphsp.supabase.co"
	local SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZzY2F6dHR2aGd3YXF4a2RwaHNwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU1MzI0NTYsImV4cCI6MjEwMTEwODQ1Nn0.WWKLNM6ZQZKF2DVne0diOaT3ZB7apbbbuk1lTH-b4L8"

	-- Executors expose their raw HTTP function under several names.
	local httpRequest = (syn and syn.request)
		or (http and http.request)
		or http_request
		or request

	-- Ambiguous characters are left out so a code read off a screen and
	-- typed on a phone can't turn into a different one.
	local ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	local function makeCode()
		local out = {}
		for _ = 1, 6 do
			local i = math.random(1, #ALPHABET)
			table.insert(out, ALPHABET:sub(i, i))
		end
		return table.concat(out)
	end

	local Code = makeCode()

	local function call(method, path, body)
		if not httpRequest then return nil end
		local ok, res = pcall(httpRequest, {
			Url = SUPABASE_URL .. "/rest/v1/" .. path,
			Method = method,
			Headers = {
				["apikey"] = SUPABASE_KEY,
				["Authorization"] = "Bearer " .. SUPABASE_KEY,
				["Content-Type"] = "application/json",
				["Prefer"] = "resolution=merge-duplicates,return=representation",
			},
			Body = body and HttpService:JSONEncode(body) or nil,
		})
		if not ok or not res then return nil end
		local okDecode, decoded = pcall(function()
			return HttpService:JSONDecode(res.Body)
		end)
		return okDecode and decoded or nil
	end

	--------------------------------------------------------
	-- Applying config from the site.
	--
	-- Every key is optional: the site only sends what it changed, and a
	-- missing key must leave the in-game value alone rather than reset
	-- it to a default.
	--------------------------------------------------------
	local function num(value, current, min, max)
		if type(value) ~= "number" then return current end
		if value < min then return min end
		if value > max then return max end
		return value
	end

	local function bool(value, current)
		if type(value) ~= "boolean" then return current end
		return value
	end

	-- Drive the on-screen widget rather than the variable directly. The
	-- widget's own onChange sets the variable, so the switch and the
	-- value can never disagree — a remote change looks exactly like one
	-- made by hand.
	local function applyConfig(config)
		if type(config) ~= "table" then return end

		local function slider(key, value, current, min, max)
			local v = num(value, current, min, max)
			local set = RemoteWidgets[key]
			if set and v ~= current then set(v) end
			return v
		end

		local function switch(key, value, current)
			local v = bool(value, current)
			local set = RemoteWidgets[key]
			if set and v ~= current then set(v) end
			return v
		end

		BuyInterval = slider("buyInterval", config.buyInterval, BuyInterval, 0.001, 10)

		PlantEnabled = switch("plantEnabled", config.plantEnabled, PlantEnabled)
		PlantInterval = slider("plantInterval", config.plantInterval, PlantInterval, 0.001, 10)

		HarvestEnabled = switch("harvestEnabled", config.harvestEnabled, HarvestEnabled)
		HarvestInterval = slider("harvestInterval", config.harvestInterval, HarvestInterval, 0.001, 10)

		SellEnabled = switch("sellEnabled", config.sellEnabled, SellEnabled)
		SellInterval = slider("sellInterval", config.sellInterval, SellInterval, 0.001, 10)

		CollectEnabled = switch("collectEnabled", config.collectEnabled, CollectEnabled)
		CollectEverything = switch("collectEverything", config.collectEverything, CollectEverything)
		CollectReturn = switch("collectReturn", config.collectReturn, CollectReturn)
		CollectDwell = slider("collectDwell", config.collectDwell, CollectDwell, 0.01, 2)

		-- Seed selection, sent as a list of names.
		if type(config.plantSeeds) == "table" then
			PlantSelected = {}
			for _, name in ipairs(config.plantSeeds) do
				if type(name) == "string" then PlantSelected[name] = true end
			end
		end
	end

	local function currentStatus()
		return {
			place = tostring(game.PlaceId),
			player = Players.LocalPlayer.Name,
			planted = PlantConfirmedCount,
			plantSent = PlantFiredCount,
			lastSeed = PlantLastFired,
			bought = BuyFiredCount,
			plantEnabled = PlantEnabled,
			harvestEnabled = HarvestEnabled,
			sellEnabled = SellEnabled,
			collectEnabled = CollectEnabled,
		}
	end

	--------------------------------------------------------
	-- The code label, tucked under the title.
	--------------------------------------------------------
	local codeLabel = Instance.new("TextLabel")
	codeLabel.BackgroundTransparency = 1
	codeLabel.Position = UDim2.new(0, 16, 0, 30)
	codeLabel.Size = UDim2.new(1, -32, 0, 14)
	codeLabel.Font = Enum.Font.Code
	codeLabel.Text = httpRequest and ("link code: " .. Code) or "link code: unavailable (no HTTP)"
	codeLabel.TextColor3 = httpRequest and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(255, 140, 140)
	codeLabel.TextSize = 11
	codeLabel.TextXAlignment = Enum.TextXAlignment.Left
	codeLabel.Parent = frame

	if httpRequest then
		-- Register, then poll. Registration is retried by the same loop,
		-- so a hiccup at startup doesn't leave the code dead forever.
		local registered = false
		task.spawn(function()
			while true do
				if not registered then
					local rows = call("POST", "sessions", {
						{ code = Code, config = {}, status = currentStatus() },
					})
					registered = rows ~= nil
				else
					local rows = call(
						"GET",
						"sessions?code=eq." .. Code .. "&select=config",
						nil
					)
					if type(rows) == "table" and rows[1] then
						applyConfig(rows[1].config)
					end
					call("PATCH", "sessions?code=eq." .. Code, { status = currentStatus() })
				end
				task.wait(2)
			end
		end)

		if setclipboard then
			pcall(setclipboard, Code)
		end
	end
end
