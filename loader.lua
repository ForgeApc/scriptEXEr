--[[
  SCRIPTEXER — Universal Loader
  Detects the Roblox game you're currently in (via game.PlaceId) and
  automatically runs the best matching script from the SCRIPTEXER
  catalog (the verified script with the most downloads for that game).

  Usage: paste this whole script into your executor and run it.
--]]

local SUPABASE_URL = "https://fscazttvhgwaqxkdphsp.supabase.co"
local ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZzY2F6dHR2aGd3YXF4a2RwaHNwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU1MzI0NTYsImV4cCI6MjEwMTEwODQ1Nn0.WWKLNM6ZQZKF2DVne0diOaT3ZB7apbbbuk1lTH-b4L8"

local HttpService = game:GetService("HttpService")
local placeId = game.PlaceId

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

warn("[SCRIPTEXER] Detecting game (PlaceId: " .. tostring(placeId) .. ")...")

local gamesUrl = string.format(
	"%s/rest/v1/games?place_id=eq.%d&select=id,name&apikey=%s",
	SUPABASE_URL, placeId, ANON_KEY
)
local gamesBody = httpGet(gamesUrl)
if not gamesBody then
	warn("[SCRIPTEXER] Couldn't reach the script database. Check your internet connection.")
	return
end

local okGames, games = pcall(function() return HttpService:JSONDecode(gamesBody) end)
if not okGames or #games == 0 then
	warn("[SCRIPTEXER] No scripts registered for this game yet (PlaceId: " .. tostring(placeId) .. ").")
	warn("[SCRIPTEXER] Browse scripts manually at your SCRIPTEXER site.")
	return
end

local matchedGame = games[1]
warn("[SCRIPTEXER] Game detected: " .. matchedGame.name)

local scriptsUrl = string.format(
	"%s/rest/v1/scripts?game_id=eq.%s&select=title,loadstring,verified,downloads&apikey=%s",
	SUPABASE_URL, HttpService:UrlEncode(matchedGame.id), ANON_KEY
)
local scriptsBody = httpGet(scriptsUrl)
if not scriptsBody then
	warn("[SCRIPTEXER] Failed to fetch scripts for " .. matchedGame.name)
	return
end

local okScripts, scripts = pcall(function() return HttpService:JSONDecode(scriptsBody) end)
if not okScripts or #scripts == 0 then
	warn("[SCRIPTEXER] " .. matchedGame.name .. " has no scripts uploaded yet.")
	return
end

-- Prefer verified scripts, then the highest download count.
table.sort(scripts, function(a, b)
	if a.verified ~= b.verified then
		return a.verified
	end
	return parseDownloads(a.downloads) > parseDownloads(b.downloads)
end)

local chosen = scripts[1]
warn("[SCRIPTEXER] Running: " .. chosen.title)

local ok, err = pcall(function()
	loadstring(chosen.loadstring)()
end)
if not ok then
	warn("[SCRIPTEXER] Script failed to run: " .. tostring(err))
end
