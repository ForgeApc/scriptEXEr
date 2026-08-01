--[[
  SCRIPTEXER — Universal Loader
  Detects the Roblox game you're currently in (via game.PlaceId), shows
  a small clean HUD in the top-right corner, and runs the best matching
  script from the SCRIPTEXER catalog. A Switch button cycles through
  every script registered for that game, stopping the current one first.

  Every script's code is fetched live from the SCRIPTEXER database each
  time you launch or switch — nothing is ever bundled into this loader.

  Usage: paste this whole script into your executor and run it.
--]]

local SUPABASE_URL = "https://fscazttvhgwaqxkdphsp.supabase.co"
local ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZzY2F6dHR2aGd3YXF4a2RwaHNwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU1MzI0NTYsImV4cCI6MjEwMTEwODQ1Nn0.WWKLNM6ZQZKF2DVne0diOaT3ZB7apbbbuk1lTH-b4L8"

local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local placeId = game.PlaceId

--========================================================
-- Networking
--========================================================
local function httpGet(url)
	local ok, res = pcall(function()
		return game:HttpGet(url)
	end)
	if ok and res then return res end

	local req = (syn and syn.request) or (http and http.request) or http_request or request
	if req then
		local ok2, res2 = pcall(function()
			return req({ Url = url, Method = "GET" }).Body
		end)
		if ok2 then return res2 end
	end
	return nil
end

-- Turns "1.2M" / "847K" / "312" into a comparable number.
local function parseDownloads(s)
	if not s then return 0 end
	local num, suffix = s:match("([%d%.]+)%s*([KMB]?)")
	num = tonumber(num) or 0
	if suffix == "K" then num = num * 1e3
	elseif suffix == "M" then num = num * 1e6
	elseif suffix == "B" then num = num * 1e9 end
	return num
end

--========================================================
-- UI — minimal dark HUD, top-right corner, draggable
--========================================================
local gui = Instance.new("ScreenGui")
gui.Name = "ScriptexerLoaderUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.AnchorPoint = Vector2.new(1, 0)
frame.Position = UDim2.new(1, -18, 0, 18)
frame.Size = UDim2.new(0, 260, 0, 96)
frame.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
frame.BackgroundTransparency = 0.06
frame.BorderSizePixel = 0
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 14)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 255, 255)
stroke.Transparency = 0.88
stroke.Thickness = 1
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 14, 0, 10)
title.Size = UDim2.new(1, -28, 0, 18)
title.Font = Enum.Font.GothamBold
title.Text = "⚡ SCRIPTEXER"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local status = Instance.new("TextLabel")
status.Name = "Status"
status.BackgroundTransparency = 1
status.Position = UDim2.new(0, 14, 0, 30)
status.Size = UDim2.new(1, -28, 0, 32)
status.Font = Enum.Font.Gotham
status.Text = "Detecting game..."
status.TextColor3 = Color3.fromRGB(190, 190, 190)
status.TextSize = 12
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Parent = frame

local switchBtn = Instance.new("TextButton")
switchBtn.Name = "SwitchButton"
switchBtn.Position = UDim2.new(0, 14, 1, -34)
switchBtn.Size = UDim2.new(1, -28, 0, 24)
switchBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
switchBtn.AutoButtonColor = false
switchBtn.Font = Enum.Font.GothamBold
switchBtn.Text = "Switch Script"
switchBtn.TextColor3 = Color3.fromRGB(0, 0, 0)
switchBtn.TextSize = 12
switchBtn.Visible = false
switchBtn.Parent = frame

local switchCorner = Instance.new("UICorner")
switchCorner.CornerRadius = UDim.new(1, 0)
switchCorner.Parent = switchBtn

switchBtn.MouseEnter:Connect(function()
	switchBtn.BackgroundColor3 = Color3.fromRGB(210, 210, 210)
end)
switchBtn.MouseLeave:Connect(function()
	switchBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
end)

-- Drag support
do
	local dragging, dragStart, startPos = false, nil, nil
	title.Size = UDim2.new(1, -28, 0, 18)
	frame.Active = true
	frame.InputBegan:Connect(function(input)
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

local function setStatus(text)
	status.Text = text
end

--========================================================
-- Script catalog + execution
--========================================================
local matchedGame = nil
local scripts = {}
local currentIndex = 0
local currentThread = nil

-- Stops the currently running script before switching. This closes the
-- coroutine it's running in, which halts it the next time it yields
-- (e.g. on wait()/task.wait()) — the best generic "unload" available
-- for arbitrary injected scripts without their cooperation.
local function stopCurrent()
	if currentThread and coroutine.status(currentThread) ~= "dead" then
		pcall(coroutine.close, currentThread)
	end
	currentThread = nil
end

local function runScriptAt(index)
	stopCurrent()
	local s = scripts[index]
	if not s then return end
	currentIndex = index
	setStatus("Running: " .. s.title)

	currentThread = coroutine.create(function()
		local ok, err = pcall(function()
			loadstring(s.loadstring)()
		end)
		if not ok then
			setStatus("Failed: " .. s.title .. " — " .. tostring(err))
		end
	end)
	coroutine.resume(currentThread)
end

local function switchScript()
	if #scripts <= 1 then return end
	local nextIndex = currentIndex + 1
	if nextIndex > #scripts then nextIndex = 1 end
	runScriptAt(nextIndex)
end

switchBtn.MouseButton1Click:Connect(switchScript)

--========================================================
-- Boot — fetch game + its scripts live from Supabase
--========================================================
setStatus("Detecting game (PlaceId " .. tostring(placeId) .. ")...")

local gamesUrl = string.format(
	"%s/rest/v1/games?place_id=eq.%d&select=id,name&apikey=%s",
	SUPABASE_URL, placeId, ANON_KEY
)
local gamesBody = httpGet(gamesUrl)
if not gamesBody then
	setStatus("Couldn't reach the script database. Check your internet connection.")
	return
end

local okGames, games = pcall(function() return HttpService:JSONDecode(gamesBody) end)
if not okGames or #games == 0 then
	setStatus("No scripts registered for this game yet.")
	return
end

matchedGame = games[1]
setStatus("Script for " .. matchedGame.name .. " launching...")

local scriptsUrl = string.format(
	"%s/rest/v1/scripts?game_id=eq.%s&select=title,loadstring,verified,downloads&apikey=%s",
	SUPABASE_URL, HttpService:UrlEncode(matchedGame.id), ANON_KEY
)
local scriptsBody = httpGet(scriptsUrl)
if not scriptsBody then
	setStatus("Failed to fetch scripts for " .. matchedGame.name)
	return
end

local okScripts, fetchedScripts = pcall(function() return HttpService:JSONDecode(scriptsBody) end)
if not okScripts or #fetchedScripts == 0 then
	setStatus(matchedGame.name .. " has no scripts uploaded yet.")
	return
end

-- Prefer verified scripts, then the highest download count.
table.sort(fetchedScripts, function(a, b)
	if a.verified ~= b.verified then
		return a.verified
	end
	return parseDownloads(a.downloads) > parseDownloads(b.downloads)
end)
scripts = fetchedScripts

switchBtn.Visible = #scripts > 1
runScriptAt(1)
