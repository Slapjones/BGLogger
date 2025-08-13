---------------------------------------------------------------------
-- BGLogger Hash Module (simple_v1)
-- Contains ONLY hash-related code moved from BGLogger.lua
-- NOTE: Do not change logic without updating website and HASH_SPEC.md
---------------------------------------------------------------------

-- Safe debug logger (avoids dependency on Debug local in main file)
local function D(msg)
	if _G and _G.BGLogger_Debug then
		_G.BGLogger_Debug(msg)
	end
end

-- Simple hash function using built-in string.byte and math operations
local function SimpleStringHash(str)
	local hash = 5381
	for i = 1, #str do
		local byte = string.byte(str, i)
		hash = ((hash * 33) + byte) % 2147483647
	end
	return string.format("%08X", hash)
end

-- Generate hash from battleground data
function GenerateDataHash(battlegroundMetadata, playerList)
	D("GenerateDataHash called with " .. #playerList .. " players")
	
	-- Normalize string function to handle special characters
	local function normalizeString(str)
		if not str then return "" end
		str = tostring(str)
		
		-- Replace all non-ASCII characters with underscore for consistency
		local result = ""
		for i = 1, #str do
			local byte = string.byte(str, i)
			if byte <= 127 then
				-- Keep ASCII characters as-is
				result = result .. string.char(byte)
			else
				-- Replace any non-ASCII character with underscore
				result = result .. "_"
			end
		end
		
		return result
	end
	
	-- Create simple string from key data
	local parts = {}
	
	-- Add battleground info (normalize battleground name)
	table.insert(parts, normalizeString(battlegroundMetadata.battleground or ""))
	table.insert(parts, tostring(battlegroundMetadata.duration or 0))
	table.insert(parts, normalizeString(battlegroundMetadata.winner or ""))
	
	-- Sort players by name for consistency
	local sortedPlayers = {}
	for _, player in ipairs(playerList) do
		table.insert(sortedPlayers, player)
	end
	
	table.sort(sortedPlayers, function(a, b)
		local nameA = normalizeString(a.name or "")
		local nameB = normalizeString(b.name or "")
		return nameA < nameB
	end)
	
	-- Add player data
	for _, player in ipairs(sortedPlayers) do
		local playerStr = normalizeString(player.name or "") .. "|" .. 
					 normalizeString(player.realm or "") .. "|" .. 
					 tostring(player.damage or 0) .. "|" .. 
					 tostring(player.healing or 0)
		table.insert(parts, playerStr)
	end
	
	-- Generate hash
	local dataString = table.concat(parts, "||")
	local hash = SimpleStringHash(dataString)
	
	-- Simple metadata
	local metadata = {
		playerCount = #playerList,
		algorithm = "simple_v1"
	}
	
	D("Generated hash: " .. hash)
	return hash, metadata
end

-- Verify a hash against stored data (for debugging/validation)
function VerifyDataHash(storedHash, battlegroundMetadata, playerList)
	local regeneratedHash, metadata = GenerateDataHash(battlegroundMetadata, playerList)
	local isValid = (storedHash == regeneratedHash)
	
	D("Hash verification: " .. (isValid and "VALID" or "INVALID"))
	D("Stored: " .. tostring(storedHash))
	D("Regenerated: " .. tostring(regeneratedHash))
	
	return isValid, regeneratedHash, metadata
end

-- Extract battleground metadata from saved data for hash verification
function ExtractBattlegroundMetadata(data)
	return {
		battleground = data.battlegroundName or "Unknown Battleground",
		duration = data.duration or 0,
		winner = data.winner or "",
		type = data.type or "non-rated",
		date = data.dateISO or date("!%Y-%m-%dT%H:%M:%SZ")
	}
end


