---------------------------------------------------------------------
-- BGLogger Hash Module (simple_v1)
-- Contains ONLY hash-related code moved from BGLogger.lua
-- NOTE: Do not change logic without updating website and the reference in backend/utils/hash.js
---------------------------------------------------------------------

local function SimpleStringHash(str)
	local hash = 5381
	for i = 1, #str do
		local byte = string.byte(str, i)
		hash = ((hash * 33) + byte) % 2147483647
	end
	return string.format("%08X", hash)
end

function GenerateDataHash(battlegroundMetadata, playerList)
	
	local function normalizeString(str)
		if not str then return "" end
		str = tostring(str)
		
		local result = ""
		for i = 1, #str do
			local byte = string.byte(str, i)
			if byte <= 127 then
				result = result .. string.char(byte)
			else
				result = result .. "_"
			end
		end
		
		return result
	end
	
	local parts = {}
	
	table.insert(parts, normalizeString(battlegroundMetadata.battleground or ""))
	table.insert(parts, tostring(battlegroundMetadata.duration or 0))
	table.insert(parts, normalizeString(battlegroundMetadata.winner or ""))
	
	local sortedPlayers = {}
	for _, player in ipairs(playerList) do
		table.insert(sortedPlayers, player)
	end
	
	table.sort(sortedPlayers, function(a, b)
		local nameA = normalizeString(a.name or "")
		local nameB = normalizeString(b.name or "")
		return nameA < nameB
	end)
	
	for _, player in ipairs(sortedPlayers) do
		local playerStr = normalizeString(player.name or "") .. "|" .. 
					 normalizeString(player.realm or "") .. "|" .. 
					 tostring(player.damage or 0) .. "|" .. 
					 tostring(player.healing or 0)
		table.insert(parts, playerStr)
	end
	
	local dataString = table.concat(parts, "||")
	local hash = SimpleStringHash(dataString)
	
	local metadata = {
		playerCount = #playerList,
		algorithm = "simple_v1"
	}
	
	return hash, metadata
end

function VerifyDataHash(storedHash, battlegroundMetadata, playerList)
	local regeneratedHash, metadata = GenerateDataHash(battlegroundMetadata, playerList)
	local isValid = (storedHash == regeneratedHash)
	
	
	return isValid, regeneratedHash, metadata
end

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

local function IsArrayTable(t)
    if type(t) ~= "table" then return false end
    local nField = rawget(t, 'n')
    if type(nField) == "number" then
        return true
    end
    local maxIndex = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" then
            return false
        end
        if k > maxIndex then maxIndex = k end
    end
    return maxIndex > 0
end

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

local function ToStringSafeLua(v)
    if v == nil then return "" end
    return tostring(v)
end

local function ToNumberSafeLua(v)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return 0 end
    return n
end

local function ToBooleanSafeLua(v)
    return not not v
end

local function NormalizeObjectiveBreakdown(ob)
    if type(ob) ~= "table" then return {} end
    for _ in pairs(ob) do
        return ob
    end
    return {}
end

function BuildHashPayloadV2_FromExport(json)
    local players = type(json.players) == "table" and json.players or {}
    local afkers = type(json.afkers) == "table" and json.afkers or {}

    local normPlayers = {}
    for i = 1, #players do
        local p = players[i]
        if type(p) == "table" then
            normPlayers[#normPlayers+1] = {
                name = ToStringSafeLua(p.name),
                realm = ToStringSafeLua(p.realm),
                faction = ToStringSafeLua(p.faction),
                class = ToStringSafeLua(p.class),
                spec = ToStringSafeLua(p.spec),
                damage = ToStringSafeLua(p.damage),
                healing = ToStringSafeLua(p.healing),
                kills = ToNumberSafeLua(p.kills),
                deaths = ToNumberSafeLua(p.deaths),
                honorableKills = ToNumberSafeLua(p.honorableKills),
                objectives = ToNumberSafeLua(p.objectives),
                objectiveBreakdown = NormalizeObjectiveBreakdown(p.objectiveBreakdown),
                isBackfill = ToBooleanSafeLua(p.isBackfill)
            }
        end
    end
    normPlayers.n = #normPlayers

    local normAfkers = {}
    for i = 1, #afkers do
        local a = afkers[i]
        if type(a) == "table" then
            normAfkers[#normAfkers+1] = {
                name = ToStringSafeLua(a.name),
                realm = ToStringSafeLua(a.realm),
                faction = ToStringSafeLua(a.faction),
                class = ToStringSafeLua(a.class)
            }
        end
    end
    normAfkers.n = #normAfkers

    return {
        battleground = ToStringSafeLua(json.battleground),
        date = ToStringSafeLua(json.date),
        type = ToStringSafeLua(json.type),
        duration = ToStringSafeLua(json.duration),
        trueDuration = ToStringSafeLua(json.trueDuration),
        winner = ToStringSafeLua(json.winner),
        players = normPlayers,
        afkers = normAfkers,
        joinedInProgress = ToBooleanSafeLua(json.joinedInProgress),
        validForStats = ToBooleanSafeLua(json.validForStats)
    }
end

function GenerateDataHashV2FromExport(exportObject)
    local normalized = BuildHashPayloadV2_FromExport(exportObject)
    local dataString = CanonicalizeValueV2(normalized)
    local hash = SimpleStringHash(dataString)
    local metadata = { algorithm = "deep_v2" }
    return hash, metadata
end



