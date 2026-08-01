-- SCRIPTEXER diagnostic — run this by itself, paste back everything it prints.

print("[DIAG] getgc exists: " .. tostring(getgc ~= nil))
print("[DIAG] debug.getupvalue exists: " .. tostring(debug ~= nil and debug.getupvalue ~= nil))
print("[DIAG] debug.info exists: " .. tostring(debug ~= nil and debug.info ~= nil))

if not getgc then
	print("[DIAG] getgc is missing entirely — that's the whole problem, stop here.")
	return
end

local ok, list = pcall(getgc)
if not ok then
	print("[DIAG] calling getgc() errored: " .. tostring(list))
	return
end

local totalFunctions = 0
local matchedSources = {}

for _, v in pairs(list) do
	if type(v) == "function" then
		totalFunctions += 1
		local ok2, src = pcall(debug.info, v, "s")
		if ok2 and src and src:match("RestockStoreController") then
			local ok3, line = pcall(debug.info, v, "l")
			table.insert(matchedSources, tostring(src) .. " @ line " .. tostring(ok3 and line or "?"))
		end
	end
end

print("[DIAG] total live functions from getgc(): " .. totalFunctions)
print("[DIAG] functions matching 'RestockStoreController': " .. #matchedSources)
for _, s in ipairs(matchedSources) do
	print("[DIAG]   -> " .. s)
end

if #matchedSources == 0 then
	print("[DIAG] No match at all. Either RestockStoreController isn't the right")
	print("[DIAG] script name in this game/version, or getgc() isn't seeing it")
	print("[DIAG] (e.g. it hasn't loaded yet, or your executor's getgc is limited).")
end
