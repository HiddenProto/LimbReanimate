--[[
	LimbReanimate -- evergreen loader.

	Always fetches the newest src/LimbReanimate.lua from the default branch.
	The query string defeats the raw.githubusercontent CDN cache, so an update
	pushed to the repo is live on the next execute rather than up to five
	minutes later.

	https://github.com/HiddenProto/LimbReanimate
]]

local REPO   = "HiddenProto/LimbReanimate"
local BRANCH = "main"
local FILE   = "src/LimbReanimate.lua"

local url = string.format(
	"https://raw.githubusercontent.com/%s/%s/%s?nocache=%d",
	REPO, BRANCH, FILE, math.floor(os.clock() * 1000) + math.random(1, 1000000)
)

local function fetch(u)
	if game.HttpGet then
		local ok, res = pcall(function() return game:HttpGet(u, true) end)
		if ok and type(res) == "string" and #res > 0 then return res end
	end
	local req = rawget(getgenv and getgenv() or getfenv(), "request")
		or rawget(getgenv and getgenv() or getfenv(), "http_request")
		or (syn and syn.request)
		or (http and http.request)
	if req then
		local ok, res = pcall(req, { Url = u, Method = "GET" })
		if ok and type(res) == "table" and type(res.Body) == "string" and #res.Body > 0 then
			return res.Body
		end
	end
	return nil
end

local source = fetch(url)
if not source then
	error("[LimbReanimate] could not download " .. url, 0)
end

local chunk, err = loadstring(source, "=LimbReanimate")
if not chunk then
	error("[LimbReanimate] downloaded source failed to compile: " .. tostring(err), 0)
end

return chunk()
