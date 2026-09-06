-- Compile-check every source file with the real Luau compiler.
-- Compiles only; nothing is executed, so executor globals and Roblox APIs
-- being absent does not matter.
local luau = require("@lune/luau")
local fs = require("@lune/fs")
local process = require("@lune/process")

local files = {
	"src/LimbReanimate.lua",
	"loader.lua",
}

local failed = false

for _, path in ipairs(files) do
	local source = fs.readFile(path)
	local ok, err = pcall(luau.load, source, { debugName = path })

	if ok then
		local lines = 0
		for _ in string.gmatch(source, "\n") do
			lines += 1
		end
		print(string.format("OK    %s (%d lines)", path, lines + 1))
	else
		failed = true
		print(string.format("FAIL  %s\n      %s", path, tostring(err)))
	end
end

if failed then
	process.exit(1)
end

print("all files compile")
