---------------------------------------------------------------------
-- BGLogger Hash Module (simple_v1)
-- Contains ONLY hash-related code moved from BGLogger.lua
-- NOTE: Do not change logic without updating website and the reference in backend/utils/hash.js
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


---------------------------------------------------------------------
-- Deep hash v2: canonicalize the ENTIRE export payload (minus integrity)
-- This must exactly match backend/utils/hash.js V2 implementation
---------------------------------------------------------------------

-- Normalize string bytes (non-ASCII -> '_') to match web implementation
local function NormalizeStringBytes(str)
    if str == nil then return "" end
    str = tostring(str)
    local out = {}
    for i = 1, #str do
        local byte = string.byte(str, i)
        if byte and byte <= 127 then
            out[#out+1] = string.char(byte)
        else
            out[#out+1] = "_"
        end
    end
    return table.concat(out)
end

-- Determine if a Lua table should be treated as an array (1..n sequence)
local function IsArrayTable(t)
    if type(t) ~= "table" then return false end
    local maxIndex = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" then
            return false
        end
        if k > maxIndex then maxIndex = k end
    end
    return maxIndex > 0
end

-- Canonicalize any Lua value into a deterministic string
local function CanonicalizeValueV2(value)
    local vt = type(value)
    if value == nil then
        return "Z|"
    elseif vt == "string" then
        return "S|" .. NormalizeStringBytes(value)
    elseif vt == "number" then
        local n = value
        if n ~= n or n == math.huge or n == -math.huge then n = 0 end
        return "N|" .. tostring(n)
    elseif vt == "boolean" then
        return "B|" .. (value and "1" or "0")
    elseif vt == "table" then
        if IsArrayTable(value) then
            local elems = {}
            -- Serialize present indices 1..max, ignoring gaps, then sort for order-insensitivity
            local maxIndex = 0
            for k in pairs(value) do if type(k) == "number" and k > maxIndex then maxIndex = k end end
            for i = 1, maxIndex do
                if value[i] ~= nil then
                    elems[#elems+1] = CanonicalizeValueV2(value[i])
                end
            end
            table.sort(elems)
            return "A|" .. table.concat(elems, "|")
        else
            -- Object: sort keys lexicographically, exclude 'integrity' anywhere in the tree
            local keys = {}
            for k in pairs(value) do
                if tostring(k) ~= "integrity" then
                    keys[#keys+1] = tostring(k)
                end
            end
            table.sort(keys)
            local parts = {}
            for _, k in ipairs(keys) do
                local v = value[k]
                parts[#parts+1] = "K|" .. NormalizeStringBytes(k) .. "|" .. CanonicalizeValueV2(v)
            end
            return "O|" .. table.concat(parts, "|")
        end
    else
        return "Z|"
    end
end

-- Public: compute v2 hash from an export-like Lua table (without integrity)
function GenerateDataHashV2FromExport(exportObject)
    local dataString = CanonicalizeValueV2(exportObject)
    local hash = SimpleStringHash(dataString)
    local metadata = { algorithm = "deep_v2" }
    return hash, metadata
end

-- (Removed debug helper prior to release)


