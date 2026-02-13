BGLoggerDB = BGLoggerDB or {}
BGLoggerSession = BGLoggerSession or {}
BGLoggerAccountChars = BGLoggerAccountChars or {}
BGLoggerCharStats = BGLoggerCharStats or {}

---------------------------------------------------------------------
-- globals
---------------------------------------------------------------------
local IsEpicBattleground

local function GetAddonVersion()
	-- Prefer modern API, fall back to legacy.
	if C_AddOns and type(C_AddOns.GetAddOnMetadata) == "function" then
		return C_AddOns.GetAddOnMetadata("BGLogger", "Version")
	end
	if type(GetAddOnMetadata) == "function" then
		return GetAddOnMetadata("BGLogger", "Version")
	end
	return nil
end

local ADDON_VERSION = tostring(GetAddonVersion() or "Unknown")
_G.BGLOGGER_ADDON_VERSION = ADDON_VERSION

local WINDOW, DetailLines, ListButtons = nil, {}, {}
local selectedLogs = {}
local RefreshWindow
local RequestRefreshWindow
local RefreshSeasonDropdown, RefreshCharacterDropdown, RefreshBgTypeDropdown, RefreshMapDropdown

local LINE_HEIGHT            = 20
local BUTTON_HEIGHT          = LINE_HEIGHT * 2 + 4
local ROW_PADDING_Y          = 2
local WIN_W, WIN_H           = 1380, 820
local insideBG, matchSaved   = false, false
local bgStartTime            = 0
local MIN_BG_TIME            = 30
local saveInProgress         = false
local pendingRefresh         = false

local CURRENT_SEASON         = "mntpp"
local UNKNOWN_SEASON         = "Unspecified"

local filterState = {
	seasons = { [CURRENT_SEASON] = true },
	characters = {},
	bgCategories = {},
	maps = {},
}

local function IsFilterEmpty(filterSet)
	if not filterSet then return true end
	return next(filterSet) == nil
end

local function CountFilterSelections(filterSet)
	if not filterSet then return 0 end
	local count = 0
	for _ in pairs(filterSet) do
		count = count + 1
	end
	return count
end

local function ValueMatchesFilter(value, filterSet)
	if IsFilterEmpty(filterSet) then return true end
	return filterSet[value] == true
end

local function ToggleFilterValue(filterSet, value)
	if filterSet[value] then
		filterSet[value] = nil
	else
		filterSet[value] = true
	end
end

local function ResetFilters()
	wipe(filterState.seasons)
	filterState.seasons[CURRENT_SEASON] = true
	wipe(filterState.characters)
	wipe(filterState.bgCategories)
	wipe(filterState.maps)
	if BGLoggerSession then
		BGLoggerSession.filterState = nil
	end
end

local function SaveFilterState()
	BGLoggerSession = BGLoggerSession or {}
	BGLoggerSession.filterState = {
		seasons = {},
		characters = {},
		bgCategories = {},
		maps = {},
	}
	for k, v in pairs(filterState.seasons) do
		BGLoggerSession.filterState.seasons[k] = v
	end
	for k, v in pairs(filterState.characters) do
		BGLoggerSession.filterState.characters[k] = v
	end
	for k, v in pairs(filterState.bgCategories) do
		BGLoggerSession.filterState.bgCategories[k] = v
	end
	for k, v in pairs(filterState.maps) do
		BGLoggerSession.filterState.maps[k] = v
	end
end

local function RestoreFilterState()
	if not BGLoggerSession or not BGLoggerSession.filterState then return end
	local saved = BGLoggerSession.filterState
	
	wipe(filterState.seasons)
	wipe(filterState.characters)
	wipe(filterState.bgCategories)
	wipe(filterState.maps)
	
	if saved.seasons and next(saved.seasons) then
		for k, v in pairs(saved.seasons) do
			filterState.seasons[k] = v
		end
	else
		filterState.seasons[CURRENT_SEASON] = true
	end
	if saved.characters then
		for k, v in pairs(saved.characters) do
			filterState.characters[k] = v
		end
	end
	if saved.bgCategories then
		for k, v in pairs(saved.bgCategories) do
			filterState.bgCategories[k] = v
		end
	end
	if saved.maps then
		for k, v in pairs(saved.maps) do
			filterState.maps[k] = v
		end
	end
end

local function HasActiveFilters()
	local seasonCount = CountFilterSelections(filterState.seasons)
	local seasonDiffersFromDefault = (seasonCount ~= 1) or (not filterState.seasons[CURRENT_SEASON])
	
	return seasonDiffersFromDefault
		or not IsFilterEmpty(filterState.characters)
		or not IsFilterEmpty(filterState.bgCategories)
		or not IsFilterEmpty(filterState.maps)
end

local BG_CATEGORY_LABELS = {
	random = "Random BGs",
	epic = "Epic BGs",
	rated = "Rated BGs",
	blitz = "Rated Blitz",
}

----------------------------------------------------------------------
-- Session Persistence Helpers
----------------------------------------------------------------------
local statePersistTimer = nil
local stateDirty = false

local function NormalizeRealmName(realm)
	realm = realm or "Unknown-Realm"
	return realm:gsub("%s+", ""):gsub("'", "")
end

local function FormatStatNumber(value)
	value = tonumber(value) or 0
	if value >= 1000000000 then
		return string.format("%.1fB", value / 1000000000)
	elseif value >= 1000000 then
		return string.format("%.1fM", value / 1000000)
	elseif value >= 1000 then
		return string.format("%.0fK", value / 1000)
	end
	return tostring(math.floor(value + 0.5))
end

local function DeepCopyTable(orig, copies)
    copies = copies or {}
    if type(orig) ~= "table" then return orig end
    if copies[orig] then return copies[orig] end
    local copy = {}
    copies[orig] = copy
    for k, v in pairs(orig) do
        copy[DeepCopyTable(k, copies)] = DeepCopyTable(v, copies)
    end
    return copy
end

local function GetCurrentMatchDuration()
    local duration = 0
    if C_PvP and C_PvP.GetActiveMatchDuration then
        duration = C_PvP.GetActiveMatchDuration() or 0
    end
    if (not duration or duration == 0) and GetBattlefieldInstanceRunTime then
        duration = math.floor((GetBattlefieldInstanceRunTime() or 0) / 1000)
    end
    return duration or 0
end

local function ClearSessionState(reason)
    if BGLoggerSession then
        BGLoggerSession.activeMatch = nil
    end
    stateDirty = false
end

local function FlagStateDirty()
    if insideBG then
        stateDirty = true
    end
end

local function PersistMatchState(reason)
    if not insideBG then
        ClearSessionState(reason or "not in BG")
        return
    end

    if not BGLoggerSession then
        return
    end

    local snapshot = {
        timestamp = GetServerTime(),
        mapID = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player") or 0,
        matchDuration = GetCurrentMatchDuration(),
        playerTracker = DeepCopyTable(playerTracker),
        matchSaved = matchSaved,
        saveInProgress = saveInProgress,
        bgStartTime = bgStartTime
    }

    BGLoggerSession.activeMatch = snapshot
    stateDirty = false
end

local function StartStatePersistence()
    if statePersistTimer then return end
    statePersistTimer = C_Timer.NewTicker(5, function()
        if stateDirty then
            PersistMatchState("ticker")
        end
    end)
end

local function StopStatePersistence()
    if statePersistTimer then
        statePersistTimer:Cancel()
        statePersistTimer = nil
    end
end

local function TryRestoreMatchState()
    if not BGLoggerSession or not BGLoggerSession.activeMatch then
        return false
    end
    if not insideBG then
        return false
    end

    local state = BGLoggerSession.activeMatch
    local now = GetServerTime()
    if state.timestamp and (now - state.timestamp) > 900 then
        ClearSessionState("snapshot too old")
        return false
    end

    local currentMap = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player") or 0
    if state.mapID and state.mapID > 0 and currentMap and currentMap > 0 and currentMap ~= state.mapID then
        ClearSessionState("map mismatch on restore")
        return false
    end

    local currentDuration = GetCurrentMatchDuration()
    if state.matchDuration and state.matchDuration > 0 and currentDuration > 0 then
        local diff = math.abs(currentDuration - state.matchDuration)
        if diff > 900 then
            ClearSessionState("duration mismatch on restore")
            return false
        end
    end

    playerTracker = DeepCopyTable(state.playerTracker) or playerTracker
    matchSaved = state.matchSaved or false
    saveInProgress = state.saveInProgress or false
    bgStartTime = state.bgStartTime or bgStartTime

    FlagStateDirty()

    return true
end

---------------------------------------------------------------------
-- List Selection Helpers
---------------------------------------------------------------------
local function IsLogSelected(key)
	return key and selectedLogs[key] == true
end

local function SetLogSelected(key, isSelected)
	if not key then return end
	if isSelected then
		selectedLogs[key] = true
	else
		selectedLogs[key] = nil
	end
end

local function ClearAllSelections()
	wipe(selectedLogs)
end

local function GetSelectedCount()
	local count = 0
	for _ in pairs(selectedLogs) do
		count = count + 1
	end
	return count
end

---------------------------------------------------------------------
-- Account-wide stat aggregation (personal performance only)
---------------------------------------------------------------------
local function GetCurrentPlayerIdentity()
	local name = UnitName("player")
	local realm = NormalizeRealmName(GetRealmName() or "Unknown-Realm")
	return name, realm
end

local function RegisterCurrentCharacter()
	local name, realm = GetCurrentPlayerIdentity()
	if not name or name == "" or name == "Unknown" then return end
	
	local key = string.format("%s-%s", name, realm)
	BGLoggerAccountChars = BGLoggerAccountChars or {}
	
	if not BGLoggerAccountChars[key] then
		BGLoggerAccountChars[key] = {
			name = name,
			realm = realm,
			firstSeen = GetServerTime()
		}
	end
	
	BGLoggerAccountChars[key].lastSeen = GetServerTime()
end

local function IsKnownAccountCharacter(playerKey)
	return BGLoggerAccountChars and BGLoggerAccountChars[playerKey] ~= nil
end

local function FindKnownAccountCharacterInLog(data)
	if not data or not data.stats or not BGLoggerAccountChars then return nil, nil end
	
	for _, player in ipairs(data.stats) do
		if player.name and player.realm then
			local key = string.format("%s-%s", player.name, NormalizeRealmName(player.realm))
			if BGLoggerAccountChars[key] then
				return player.name, NormalizeRealmName(player.realm)
			end
		end
	end
	
	for _, player in ipairs(data.stats) do
		if player.name then
			for accountKey, charInfo in pairs(BGLoggerAccountChars) do
				if charInfo.name == player.name then
					return charInfo.name, charInfo.realm
				end
			end
		end
	end
	
	return nil, nil
end

local function FindSelfPlayerEntry(data, fallbackName, fallbackRealm)
	if not data or type(data.stats) ~= "table" then return nil end

	local targetName = fallbackName
	local targetRealm = fallbackRealm

	if data.selfPlayer then
		targetName = data.selfPlayer.name or targetName
		targetRealm = NormalizeRealmName(data.selfPlayer.realm or targetRealm)
	elseif data.selfPlayerKey and type(data.selfPlayerKey) == "string" then
		local n, r = data.selfPlayerKey:match("^(.-)%-(.+)$")
		if n and r then
			targetName = n
			targetRealm = NormalizeRealmName(r)
		end
	end

	for _, p in ipairs(data.stats) do
		local realm = NormalizeRealmName(p.realm or "")
		if p.name == targetName and realm == targetRealm then
			return p
		end
	end

	local nameOnlyMatches = {}
	for _, p in ipairs(data.stats) do
		if p.name == targetName then
			table.insert(nameOnlyMatches, p)
		end
	end
	if #nameOnlyMatches == 1 then
		return nameOnlyMatches[1]
	end

	return nil
end

local function GetSelfIdentityFromData(data)
	if not data then return nil, nil end
	
	if data.selfPlayer then
		return data.selfPlayer.name, NormalizeRealmName(data.selfPlayer.realm or "")
	end
	if data.selfPlayerKey and type(data.selfPlayerKey) == "string" then
		local n, r = data.selfPlayerKey:match("^(.-)%-(.+)$")
		if n and r then
			return n, NormalizeRealmName(r)
		end
	end
	
	if data.recorder then
		return data.recorder.name, NormalizeRealmName(data.recorder.realm or "")
	end
	if data.recorderKey and type(data.recorderKey) == "string" then
		local n, r = data.recorderKey:match("^(.-)%-(.+)$")
		if n and r then
			return n, NormalizeRealmName(r)
		end
	end
	
	local foundName, foundRealm = FindKnownAccountCharacterInLog(data)
	if foundName and foundRealm then
		return foundName, foundRealm
	end
	
	return nil, nil
end

local function NormalizeSeason(season)
	if season == nil or season == "" or season == UNKNOWN_SEASON then
		return CURRENT_SEASON
	end
	
	local legacyMapping = {
		["Season 1"] = "tww-s3",
		["season 1"] = "tww-s3",
		["S1"] = "tww-s3",
		["MNTPP"] = "mntpp",
		["Midnight Prepatch"] = "mntpp",
		["midnight prepatch"] = "mntpp",
	}
	
	local normalized = legacyMapping[season]
	if normalized then
		return normalized
	end
	
	return tostring(season)
end

local function GetLogSeason(data)
	if not data then return CURRENT_SEASON end
	return NormalizeSeason(data.season)
end

local function IsEpicBattlegroundByName(mapName)
	if not mapName or mapName == "" then return false end
	local name = mapName:lower()
	return name:find("alterac")
		or name:find("isle of conquest")
		or name:find("wintergrasp")
		or name:find("ashran")
		or name:find("slayer")
		or false
end

local function GetBattlegroundCategory(data)
	if not data then return "random" end

	local bgType = data.type or ""
	
	if bgType == "rated-blitz" then
		return "blitz"
	end
	
	if bgType == "rated" then
		return "rated"
	end

	local mapName = data.battlegroundName or ""
	if IsEpicBattlegroundByName(mapName) then
		return "epic"
	end

	return "random"
end

local function GetRecorderKey(data)
	local name, realm = GetSelfIdentityFromData(data)
	if name and realm then
		return string.format("%s-%s", name, realm)
	end
	return nil
end

local function ParsePlayerKey(key)
	if not key or type(key) ~= "string" then return nil, nil end
	local n, r = key:match("^(.-)%-(.+)$")
	if n and r then
		return n, NormalizeRealmName(r)
	end
	return nil, nil
end

local function NormalizeKey(key)
	local n, r = ParsePlayerKey(key)
	if n and r then
		return string.format("%s-%s", n, r)
	end
	return key
end

local function GetRecorderKeys(data)
	if not data then return {} end
	local keys = {}
	local function add(key)
		if key and type(key) == "string" then
			table.insert(keys, NormalizeKey(key))
		end
	end
	add(data.selfPlayerKey)
	add(data.recorderKey)
	add(GetRecorderKey(data))
	return keys
end

local function FindPlayerEntryByKey(data, key)
	if not data or not data.stats or not key then return nil end
	local targetName, targetRealm = ParsePlayerKey(key)
	if not targetName or not targetRealm then return nil end
	for _, p in ipairs(data.stats) do
		if p.name == targetName and NormalizeRealmName(p.realm or "") == targetRealm then
			return p
		end
	end
	local matches = {}
	for _, p in ipairs(data.stats) do
		if p.name == targetName then
			table.insert(matches, p)
		end
	end
	if #matches == 1 then
		return matches[1]
	end
	return nil
end

local function GetLogMapName(data)
	if not data then return nil end
	if data.battlegroundName then
		return data.battlegroundName
	end
	if data.mapID then
		local mapInfo = C_Map.GetMapInfo(data.mapID)
		return mapInfo and mapInfo.name
	end
	return nil
end

local function LogMatchesFilters(data)
	if not data or type(data) ~= "table" or not data.mapID or not data.stats then
		return false
	end

	local season = GetLogSeason(data)
	if not ValueMatchesFilter(season, filterState.seasons) then
		return false
	end

	local category = GetBattlegroundCategory(data)
	if not ValueMatchesFilter(category, filterState.bgCategories) then
		return false
	end

	local logMapName = GetLogMapName(data)
	if not ValueMatchesFilter(logMapName, filterState.maps) then
		return false
	end

	if not IsFilterEmpty(filterState.characters) then
		local candidates = GetRecorderKeys(data)
		local matched = false
		for _, candidateKey in ipairs(candidates) do
			if filterState.characters[candidateKey] then
				matched = true
				break
			end
		end
		if not matched then
			return false
		end
	end

	return true
end

local function ExtractSeasonNumber(seasonStr)
	if not seasonStr then return nil end
	local num = seasonStr:match("(%d+)")
	return num and tonumber(num) or nil
end

local function CollectSeasonNames()
	local seasons = {}
	local seen = {}
	seen[CURRENT_SEASON] = true

	-- Collect from logs
	for _, data in pairs(BGLoggerDB) do
		if type(data) == "table" and data.mapID and data.stats then
			local season = GetLogSeason(data)
			if season and not seen[season] then
				seen[season] = true
			end
		end
	end
	
	-- Also collect from persistent stats
	for _, entry in pairs(BGLoggerCharStats) do
		if entry.season and not seen[entry.season] then
			seen[entry.season] = true
		end
	end

	for season in pairs(seen) do
		table.insert(seasons, season)
	end

	table.sort(seasons, function(a, b)
		if a == CURRENT_SEASON then return true end
		if b == CURRENT_SEASON then return false end
		if a == UNKNOWN_SEASON then return false end
		if b == UNKNOWN_SEASON then return true end
		local numA = ExtractSeasonNumber(a)
		local numB = ExtractSeasonNumber(b)
		if numA and numB then
			return numA > numB
		end
		return a > b
	end)

	return seasons
end

local function CollectCharacterOptions()
	local characters = {}
	
	-- Collect from logs
	for _, data in pairs(BGLoggerDB) do
		if type(data) == "table" and data.mapID and data.stats then
			local logSeason = GetLogSeason(data)
			local seasonMatches = ValueMatchesFilter(logSeason, filterState.seasons)
			
			local bgCategory = GetBattlegroundCategory(data)
			local bgTypeMatches = ValueMatchesFilter(bgCategory, filterState.bgCategories)
			
			local logMapName = GetLogMapName(data)
			local mapMatches = ValueMatchesFilter(logMapName, filterState.maps)
			
			if seasonMatches and bgTypeMatches and mapMatches then
				local name, realm = GetSelfIdentityFromData(data)
				if name and realm then
					local key = string.format("%s-%s", name, realm)
					characters[key] = { name = name, realm = realm }
				end
			end
		end
	end
	
	-- Also collect from persistent stats (for characters with stats but no logs)
	for _, entry in pairs(BGLoggerCharStats) do
		if entry.charKey then
			local seasonMatches = ValueMatchesFilter(entry.season, filterState.seasons)
			local bgTypeMatches = ValueMatchesFilter(entry.bgCategory, filterState.bgCategories)
			local mapMatches = ValueMatchesFilter(entry.mapName, filterState.maps)
			
			if seasonMatches and bgTypeMatches and mapMatches then
				if not characters[entry.charKey] then
					local name, realm = ParsePlayerKey(entry.charKey)
					if name and realm then
						characters[entry.charKey] = { name = name, realm = realm }
					end
				end
			end
		end
	end

	local list = {}
	for key, info in pairs(characters) do
		table.insert(list, { value = key, text = string.format("%s-%s", info.name, info.realm) })
	end

	table.sort(list, function(a, b)
		return a.text < b.text
	end)

	return list
end

local function CollectMapNames()
	local maps = {}
	local seen = {}

	-- Collect from logs
	for _, data in pairs(BGLoggerDB) do
		if type(data) == "table" and data.mapID and data.stats then
			local season = GetLogSeason(data)
			local seasonMatches = ValueMatchesFilter(season, filterState.seasons)
			
			local bgCategory = GetBattlegroundCategory(data)
			local bgTypeMatches = ValueMatchesFilter(bgCategory, filterState.bgCategories)
			
			local charMatches = true
			if not IsFilterEmpty(filterState.characters) then
				local candidates = GetRecorderKeys(data)
				charMatches = false
				for _, candidateKey in ipairs(candidates) do
					if filterState.characters[candidateKey] then
						charMatches = true
						break
					end
				end
			end
			
			if seasonMatches and bgTypeMatches and charMatches then
				local mapName = GetLogMapName(data)
				if mapName and not seen[mapName] then
					seen[mapName] = true
					table.insert(maps, mapName)
				end
			end
		end
	end
	
	-- Also collect from persistent stats
	for _, entry in pairs(BGLoggerCharStats) do
		if entry.mapName and not seen[entry.mapName] then
			local seasonMatches = ValueMatchesFilter(entry.season, filterState.seasons)
			local bgTypeMatches = ValueMatchesFilter(entry.bgCategory, filterState.bgCategories)
			local charMatches = IsFilterEmpty(filterState.characters) or filterState.characters[entry.charKey]
			
			if seasonMatches and bgTypeMatches and charMatches then
				seen[entry.mapName] = true
				table.insert(maps, entry.mapName)
			end
		end
	end

	table.sort(maps)
	return maps
end

---------------------------------------------------------------------
-- Persistent Character Stats Helpers
---------------------------------------------------------------------
local function GetCharStatsKey(charKey, season, bgCategory, mapName)
	return charKey .. "|" .. (season or CURRENT_SEASON) .. "|" .. (bgCategory or "random") .. "|" .. (mapName or "Unknown")
end

local function EnsureCharStatsEntry(charKey, season, bgCategory, mapName)
	local statsKey = GetCharStatsKey(charKey, season, bgCategory, mapName)
	if not BGLoggerCharStats[statsKey] then
		BGLoggerCharStats[statsKey] = {
			charKey = charKey,
			season = season or CURRENT_SEASON,
			bgCategory = bgCategory or "random",
			mapName = mapName or "Unknown",
			games = 0,
			wins = 0,
			losses = 0,
			damage = 0,
			healing = 0,
			kills = 0,
			deaths = 0,
			honorableKills = 0,
			objectives = 0,
		}
	end
	return BGLoggerCharStats[statsKey]
end

local function AppendCharStats(charKey, season, bgCategory, mapName, playerEntry, didWin)
	local entry = EnsureCharStatsEntry(charKey, season, bgCategory, mapName)
	entry.games = entry.games + 1
	if didWin == true then
		entry.wins = entry.wins + 1
	elseif didWin == false then
		entry.losses = entry.losses + 1
	end
	entry.damage = entry.damage + (tonumber(playerEntry.damage) or tonumber(playerEntry.dmg) or 0)
	entry.healing = entry.healing + (tonumber(playerEntry.healing) or tonumber(playerEntry.heal) or 0)
	entry.kills = entry.kills + (playerEntry.kills or playerEntry.killingBlows or playerEntry.kb or 0)
	entry.deaths = entry.deaths + (playerEntry.deaths or 0)
	entry.honorableKills = entry.honorableKills + (playerEntry.honorableKills or 0)
	entry.objectives = entry.objectives + (playerEntry.objectives or 0)
end

local function ComputeAccountStats()
	local totals = {
		games = 0,
		wins = 0,
		losses = 0,
		damage = 0,
		healing = 0,
		kills = 0,
	}

	for statsKey, entry in pairs(BGLoggerCharStats) do
		local charKey = entry.charKey
		local season = entry.season
		local bgCategory = entry.bgCategory
		local mapName = entry.mapName

		local seasonMatches = ValueMatchesFilter(season, filterState.seasons)
		local charMatches = IsFilterEmpty(filterState.characters) or filterState.characters[charKey]
		local bgTypeMatches = ValueMatchesFilter(bgCategory, filterState.bgCategories)
		local mapMatches = ValueMatchesFilter(mapName, filterState.maps)

		if seasonMatches and charMatches and bgTypeMatches and mapMatches then
			totals.games = totals.games + entry.games
			totals.wins = totals.wins + entry.wins
			totals.losses = totals.losses + entry.losses
			totals.damage = totals.damage + entry.damage
			totals.healing = totals.healing + entry.healing
			totals.kills = totals.kills + entry.kills
		end
	end

	totals.avgDamage = totals.games > 0 and (totals.damage / totals.games) or 0
	totals.avgHealing = totals.games > 0 and (totals.healing / totals.games) or 0
	totals.avgKills = totals.games > 0 and (totals.kills / totals.games) or 0

	return totals
end


local function BuildPersonalSummaryLine(data)
	if not data then return "" end
	local meName, meRealm = GetCurrentPlayerIdentity()
	local identityName, identityRealm = GetSelfIdentityFromData(data)

	local targetName = identityName or meName or "Unknown"
	local targetRealm = identityRealm or meRealm or "Unknown"

	local playerEntry = FindSelfPlayerEntry(data, targetName, targetRealm)
	if not playerEntry then
		return string.format("You: %s-%s  (personal stats not found)", targetName, targetRealm)
	end

	targetName = playerEntry.name or targetName
	targetRealm = NormalizeRealmName(playerEntry.realm or targetRealm)

	local duration = tonumber(data.duration) or 0
	local damage = playerEntry.damage or playerEntry.dmg or 0
	local healing = playerEntry.healing or playerEntry.heal or 0
	local kills = playerEntry.kills or playerEntry.killingBlows or playerEntry.kb or 0
	local deaths = playerEntry.deaths or 0

	local dpsText = (duration and duration > 0) and FormatStatNumber(damage / duration) or "-"
	local hpsText = (duration and duration > 0) and FormatStatNumber(healing / duration) or "-"

	return string.format(
		"%s-%s | K/D %d/%d | Dmg %s (DPS %s) | Heal %s (HPS %s)",
		targetName,
		targetRealm,
		kills,
		deaths,
		FormatStatNumber(damage),
		dpsText,
		FormatStatNumber(healing),
		hpsText
	)
end

local function UpdateStatBar()
	if not WINDOW or not WINDOW.statBarText then return end
	local stats = ComputeAccountStats()

	local filterPrefix = ""
	if HasActiveFilters() then
		filterPrefix = "|cffFFD100[Filtered]|r "
	end

	if stats.games == 0 then
		WINDOW.statBarText:SetText(filterPrefix .. "No matching entries for current filters.")
		return
	end

	local text = string.format(
		"%sGames: %d  W-L: %d-%d (%.0f%%)  Kills: %s  Damage: %s (avg %s)  Healing: %s (avg %s)",
		filterPrefix,
		stats.games,
		stats.wins,
		stats.losses,
		stats.games > 0 and (stats.wins / stats.games * 100) or 0,
		FormatStatNumber(stats.kills),
		FormatStatNumber(stats.damage),
		FormatStatNumber(stats.avgDamage),
		FormatStatNumber(stats.healing),
		FormatStatNumber(stats.avgHealing)
	)

	WINDOW.statBarText:SetText(text)
end


local SEASON_DISPLAY_NAMES = {
	["mntpp"] = "Midnight Prepatch",
	["MNTPP"] = "Midnight Prepatch",
	["Midnight Prepatch"] = "Midnight Prepatch",
	["tww-s3"] = "TWW Season 3",
	["Season 1"] = "TWW Season 3",
	["Unspecified"] = "TWW Season 3",
}

local function GetSeasonDisplayName(seasonId)
	if not seasonId then return "Unknown" end
	return SEASON_DISPLAY_NAMES[seasonId] or seasonId
end

local function GetSeasonDisplayLabel()
	local count = CountFilterSelections(filterState.seasons)
	if count == 0 then
		return "All Seasons"
	elseif count == 1 then
		for season in pairs(filterState.seasons) do
			return GetSeasonDisplayName(season)
		end
	else
		return string.format("%d Seasons", count)
	end
end

local function GetCharacterDisplayLabel()
	local count = CountFilterSelections(filterState.characters)
	if count == 0 then
		return "All Characters"
	elseif count == 1 then
		for char in pairs(filterState.characters) do
			return char
		end
	else
		return string.format("%d Characters", count)
	end
end

local function GetBgTypeDisplayLabel()
	local count = CountFilterSelections(filterState.bgCategories)
	if count == 0 then
		return "All BG Types"
	elseif count == 1 then
		for category in pairs(filterState.bgCategories) do
			return BG_CATEGORY_LABELS[category] or category
		end
	else
		return string.format("%d Types", count)
	end
end

local function GetMapDisplayLabel()
	local count = CountFilterSelections(filterState.maps)
	if count == 0 then
		return "All Maps"
	elseif count == 1 then
		for mapName in pairs(filterState.maps) do
			return mapName
		end
	else
		return string.format("%d Maps", count)
	end
end

RefreshSeasonDropdown = function()
	if not WINDOW or not WINDOW.seasonDropdown then return end

	local seasons = CollectSeasonNames()

	UIDropDownMenu_Initialize(WINDOW.seasonDropdown, function(frame, level)
		local info = UIDropDownMenu_CreateInfo()
		info.text = "|cffFFD100All Seasons|r"
		info.notCheckable = true
		info.func = function()
			wipe(filterState.seasons)
			UIDropDownMenu_SetText(WINDOW.seasonDropdown, GetSeasonDisplayLabel())
			WINDOW.currentView = "list"
			ClearAllSelections()
			RefreshMapDropdown()
			RefreshCharacterDropdown()
			CloseDropDownMenus()
			RequestRefreshWindow()
		end
		UIDropDownMenu_AddButton(info, level)

		info = UIDropDownMenu_CreateInfo()
		info.text = "|cff00FF00Current Season Only|r"
		info.notCheckable = true
		info.func = function()
			wipe(filterState.seasons)
			filterState.seasons[CURRENT_SEASON] = true
			UIDropDownMenu_SetText(WINDOW.seasonDropdown, GetSeasonDisplayLabel())
			WINDOW.currentView = "list"
			ClearAllSelections()
			RefreshMapDropdown()
			RefreshCharacterDropdown()
			CloseDropDownMenus()
			RequestRefreshWindow()
		end
		UIDropDownMenu_AddButton(info, level)

		info = UIDropDownMenu_CreateInfo()
		info.disabled = true
		info.notCheckable = true
		UIDropDownMenu_AddButton(info, level)

		for _, season in ipairs(seasons) do
			info = UIDropDownMenu_CreateInfo()
			info.text = GetSeasonDisplayName(season)
			info.value = season
			info.isNotRadio = true
			info.keepShownOnClick = true
			info.checked = filterState.seasons[season] == true
			info.func = function(self)
				ToggleFilterValue(filterState.seasons, self.value)
				UIDropDownMenu_SetText(WINDOW.seasonDropdown, GetSeasonDisplayLabel())
				WINDOW.currentView = "list"
				ClearAllSelections()
				RefreshMapDropdown()
				RefreshCharacterDropdown()
				RequestRefreshWindow()
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end)

	UIDropDownMenu_SetWidth(WINDOW.seasonDropdown, 150)
	UIDropDownMenu_SetText(WINDOW.seasonDropdown, GetSeasonDisplayLabel())
end

RefreshCharacterDropdown = function()
	if not WINDOW or not WINDOW.characterDropdown then return end

	local options = CollectCharacterOptions()

	UIDropDownMenu_Initialize(WINDOW.characterDropdown, function(frame, level)
		local info = UIDropDownMenu_CreateInfo()
		info.text = "|cffFFD100Clear Selection|r"
		info.notCheckable = true
		info.func = function()
			wipe(filterState.characters)
			UIDropDownMenu_SetText(WINDOW.characterDropdown, GetCharacterDisplayLabel())
			WINDOW.currentView = "list"
			ClearAllSelections()
			CloseDropDownMenus()
			RequestRefreshWindow()
		end
		UIDropDownMenu_AddButton(info, level)

		info = UIDropDownMenu_CreateInfo()
		info.disabled = true
		info.notCheckable = true
		UIDropDownMenu_AddButton(info, level)

		for _, opt in ipairs(options) do
			info = UIDropDownMenu_CreateInfo()
			info.text = opt.text
			info.value = opt.value
			info.isNotRadio = true
			info.keepShownOnClick = true
			info.checked = filterState.characters[opt.value] == true
			info.func = function(self)
				ToggleFilterValue(filterState.characters, self.value)
				UIDropDownMenu_SetText(WINDOW.characterDropdown, GetCharacterDisplayLabel())
				WINDOW.currentView = "list"
				ClearAllSelections()
				RequestRefreshWindow()
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end)

	UIDropDownMenu_SetWidth(WINDOW.characterDropdown, 180)
	UIDropDownMenu_SetText(WINDOW.characterDropdown, GetCharacterDisplayLabel())
end

RefreshBgTypeDropdown = function()
	if not WINDOW or not WINDOW.bgTypeDropdown then return end

	UIDropDownMenu_Initialize(WINDOW.bgTypeDropdown, function(frame, level)
		local info = UIDropDownMenu_CreateInfo()
		info.text = "|cffFFD100Clear Selection|r"
		info.notCheckable = true
		info.func = function()
			wipe(filterState.bgCategories)
			UIDropDownMenu_SetText(WINDOW.bgTypeDropdown, GetBgTypeDisplayLabel())
			WINDOW.currentView = "list"
			ClearAllSelections()
			CloseDropDownMenus()
			RequestRefreshWindow()
		end
		UIDropDownMenu_AddButton(info, level)

		info = UIDropDownMenu_CreateInfo()
		info.disabled = true
		info.notCheckable = true
		UIDropDownMenu_AddButton(info, level)

		local bgOptions = {
			{ value = "random", text = BG_CATEGORY_LABELS.random },
			{ value = "epic", text = BG_CATEGORY_LABELS.epic },
			{ value = "rated", text = BG_CATEGORY_LABELS.rated },
			{ value = "blitz", text = BG_CATEGORY_LABELS.blitz },
		}

		for _, opt in ipairs(bgOptions) do
			info = UIDropDownMenu_CreateInfo()
			info.text = opt.text
			info.value = opt.value
			info.isNotRadio = true
			info.keepShownOnClick = true
			info.checked = filterState.bgCategories[opt.value] == true
			info.func = function(self)
				ToggleFilterValue(filterState.bgCategories, self.value)
				UIDropDownMenu_SetText(WINDOW.bgTypeDropdown, GetBgTypeDisplayLabel())
				WINDOW.currentView = "list"
				ClearAllSelections()
				RefreshCharacterDropdown()
				RefreshMapDropdown()
				RequestRefreshWindow()
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end)

	UIDropDownMenu_SetWidth(WINDOW.bgTypeDropdown, 140)
	UIDropDownMenu_SetText(WINDOW.bgTypeDropdown, GetBgTypeDisplayLabel())
end

RefreshMapDropdown = function()
	if not WINDOW or not WINDOW.mapDropdown then return end

	local maps = CollectMapNames()

	UIDropDownMenu_Initialize(WINDOW.mapDropdown, function(frame, level)
		local info = UIDropDownMenu_CreateInfo()
		info.text = "|cffFFD100Clear Selection|r"
		info.notCheckable = true
		info.func = function()
			wipe(filterState.maps)
			UIDropDownMenu_SetText(WINDOW.mapDropdown, GetMapDisplayLabel())
			WINDOW.currentView = "list"
			ClearAllSelections()
			CloseDropDownMenus()
			RequestRefreshWindow()
		end
		UIDropDownMenu_AddButton(info, level)

		info = UIDropDownMenu_CreateInfo()
		info.disabled = true
		info.notCheckable = true
		UIDropDownMenu_AddButton(info, level)

		for _, mapName in ipairs(maps) do
			info = UIDropDownMenu_CreateInfo()
			info.text = mapName
			info.value = mapName
			info.isNotRadio = true
			info.keepShownOnClick = true
			info.checked = filterState.maps[mapName] == true
			info.func = function(self)
				ToggleFilterValue(filterState.maps, self.value)
				UIDropDownMenu_SetText(WINDOW.mapDropdown, GetMapDisplayLabel())
				WINDOW.currentView = "list"
				ClearAllSelections()
				RequestRefreshWindow()
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end)

	UIDropDownMenu_SetWidth(WINDOW.mapDropdown, 160)
	UIDropDownMenu_SetText(WINDOW.mapDropdown, GetMapDisplayLabel())
end

local function RefreshFilterDropdowns()
	RefreshSeasonDropdown()
	RefreshBgTypeDropdown()
	RefreshMapDropdown()
	RefreshCharacterDropdown()
end

local function PruneInvalidSelections(entries)
	if not entries then return end
	local valid = {}
	for _, entry in ipairs(entries) do
		valid[entry.key] = true
	end
	for key in pairs(selectedLogs) do
		if not valid[key] then
			selectedLogs[key] = nil
		end
	end
end

local function AreAllEntriesSelected(entries)
	if not entries or #entries == 0 then return false end
	for _, entry in ipairs(entries) do
		if not selectedLogs[entry.key] then
			return false
		end
	end
	return true
end

local function RefreshListSelectionVisuals()
	for _, btn in ipairs(ListButtons) do
		if btn:IsShown() and btn.bgKey then
			local isSelected = IsLogSelected(btn.bgKey)
			if btn.checkbox then
				btn.checkbox:SetChecked(isSelected)
			end
			if btn.bg then
				if isSelected then
					btn.bg:SetColorTexture(0.13, 0.35, 0.18, 0.85)
				else
					btn.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
				end
			end
		end
	end
end

local function GetSelectedKeysInOrder()
	local ordered = {}
	if WINDOW and WINDOW.currentEntries then
		for _, entry in ipairs(WINDOW.currentEntries) do
			if selectedLogs[entry.key] then
				table.insert(ordered, entry.key)
			end
		end
	else
		for key in pairs(selectedLogs) do
			table.insert(ordered, key)
		end
		table.sort(ordered)
	end
	return ordered
end

local function UpdateSelectionToolbar()
	if not WINDOW then return end
	local count = GetSelectedCount()
	if WINDOW.exportSelectedBtn then
		if WINDOW.currentView == "list" then
			WINDOW.exportSelectedBtn:Show()
			WINDOW.exportSelectedBtn:SetEnabled(count > 0)
		else
			WINDOW.exportSelectedBtn:Hide()
		end
	end
	if WINDOW.deleteSelectedBtn then
		if WINDOW.currentView == "list" then
			WINDOW.deleteSelectedBtn:Show()
			WINDOW.deleteSelectedBtn:SetEnabled(count > 0)
		else
			WINDOW.deleteSelectedBtn:Hide()
		end
	end
	if WINDOW.selectAllBtn then
		if WINDOW.currentView == "list" then
			WINDOW.selectAllBtn:Show()
			local showClear = WINDOW.currentEntries and AreAllEntriesSelected(WINDOW.currentEntries) and #WINDOW.currentEntries > 0
			WINDOW.selectAllBtn:SetText(showClear and "Clear All" or "Select All")
		else
			WINDOW.selectAllBtn:Hide()
		end
	end
	if WINDOW.selectionStatusText then
		if WINDOW.currentView == "list" then
			WINDOW.selectionStatusText:Show()
			WINDOW.selectionStatusText:SetText("Selected: " .. count)
		else
			WINDOW.selectionStatusText:Hide()
		end
	end
end

local function ToggleSelectAllEntries()
	if not WINDOW or WINDOW.currentView ~= "list" then return end
	local entries = WINDOW.currentEntries or {}
	if #entries == 0 then return end
	local shouldSelectAll = not AreAllEntriesSelected(entries)
	for _, entry in ipairs(entries) do
		SetLogSelected(entry.key, shouldSelectAll)
	end
	RefreshListSelectionVisuals()
	UpdateSelectionToolbar()
end

local function ExportSelectedFromList()
	if WINDOW and WINDOW.currentView ~= "list" then
		print("|cff00ffffBGLogger:|r Please return to the list view to export multiple logs.")
		return
	end
	local keys = GetSelectedKeysInOrder()
	if #keys == 0 then
		print("|cff00ffffBGLogger:|r Select at least one battleground from the list first.")
		return
	end
	if ExportSelectedBattlegrounds then
		ExportSelectedBattlegrounds(keys)
	else
		print("|cff00ffffBGLogger:|r ExportSelectedBattlegrounds is not available.")
	end
end

local pendingDeleteKeys = nil
local function DeleteSelectedFromList()
	if WINDOW and WINDOW.currentView ~= "list" then
		print("|cff00ffffBGLogger:|r Please return to the list view to delete multiple logs.")
		return
	end
	local keys = GetSelectedKeysInOrder()
	if #keys == 0 then
		print("|cff00ffffBGLogger:|r Select at least one battleground from the list first.")
		return
	end

	pendingDeleteKeys = keys
	StaticPopup_Show("BGLOGGER_DELETE_SELECTED")
end
local GetWinner              = _G.GetBattlefieldWinner

local GetNumBattlefieldScores = _G.GetNumBattlefieldScores
local RequestBattlefieldScoreData = _G.RequestBattlefieldScoreData
if not GetNumBattlefieldScores then
	local function _probeScoreRowCount()
		local count = 0
		if C_PvP and C_PvP.GetScoreInfo then
			for i = 1, 80 do
				local ok, s = pcall(C_PvP.GetScoreInfo, i)
				if ok and s then
					count = i
				else
					break
				end
			end
		end
		return count
	end
	GetNumBattlefieldScores = _probeScoreRowCount
end
if not RequestBattlefieldScoreData then
	RequestBattlefieldScoreData = function() end
end

BGLoggerDB.__ObjectiveIdMap = BGLoggerDB.__ObjectiveIdMap or {}
local ObjectiveIdMap = BGLoggerDB.__ObjectiveIdMap

---------------------------------------------------------------------
-- Match Participation Tracking
---------------------------------------------------------------------
local playerTracker = {
    battleHasBegun = false,
    joinedInProgress = false,
    playerJoinedInProgress = false,
    sawPrematchState = false,
}

local function ResetPlayerTracker()
    if not insideBG or matchSaved then
        playerTracker.battleHasBegun = false
        playerTracker.joinedInProgress = false
        playerTracker.playerJoinedInProgress = false
        playerTracker.sawPrematchState = false
        FlagStateDirty()
        PersistMatchState("reset")
        
    end
end

local function GetPlayerKey(name, realm)
    local n = tostring(name or "Unknown")
    local r = tostring(realm or "Unknown")
    if NormalizeRealmName then
        r = NormalizeRealmName(r)
    end
    r = r:gsub("%s+", ""):gsub("'", "")
    return n .. "-" .. r
end

IsEpicBattleground = function()
    local mapId = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player") or 0
    local info = mapId and C_Map.GetMapInfo and C_Map.GetMapInfo(mapId) or nil
    local name = (info and info.name or ""):lower()
    if name == "" then return false end
	return name:find("alterac") 
		or name:find("isle of conquest") 
		or name:find("wintergrasp") 
		or name:find("ashran")
		or name:find("slayer's rise")
		or false
end

local function FixedWidthCenter(text, width)
    text = tostring(text or "")
    if #text > width then
        text = string.sub(text, 1, width)
    end
    local padding = width - #text
    local leftPad = math.floor(padding / 2)
    local rightPad = padding - leftPad
    return string.rep(" ", leftPad) .. text .. string.rep(" ", rightPad)
end

local function FixedWidthLeft(text, width)
    text = tostring(text or "")
    if #text > width then
        text = string.sub(text, 1, width)
    end
    return text .. string.rep(" ", width - #text)
end

local function FixedWidthRight(text, width)
    text = tostring(text or "")
    if #text > width then
        text = string.sub(text, 1, width)
    end
    return string.rep(" ", width - #text) .. text
end

---------------------------------------------------------------------
-- Objective Data Collection 
---------------------------------------------------------------------

local function ExtractObjectiveDataFromStats(scoreData)
    if not scoreData or not scoreData.stats then 
        
        return nil
    end
    
    local objectiveBreakdown = {}
    local totalObjectives = 0
    local foundStats = {}
    
    
    for _, stat in ipairs(scoreData.stats) do
        local statName = (stat.name or ""):lower()
        local statValue = stat.pvpStatValue or 0
        local statID = stat.pvpStatID
        local originalName = stat.name or ""
        
        local isObjectiveStat = (
            statName:find("flag") or statName:find("capture") or statName:find("return") or
            statName:find("base") or statName:find("assault") or statName:find("defend") or
            statName:find("orb") or statName:find("gate") or statName:find("cart") or
            statName:find("tower") or statName:find("graveyard") or 
            statName:find("mine") or statName:find("node") or 
            statName:find("azerite") or statName:find("structure") or
            statName:find("demolisher") or statName:find("vehicle") or
            statName:find("goal") or statName:find("objective") or
            statName:find("crystal") or statName:find("shard") or statName:find("deposit")
        )
        
        local learnedType = ObjectiveIdMap[statID]
        if learnedType and statValue > 0 then
            totalObjectives = totalObjectives + statValue
            objectiveBreakdown[learnedType] = (objectiveBreakdown[learnedType] or 0) + statValue
            table.insert(foundStats, { name = originalName, value = statValue, id = statID, type = learnedType })
            
        elseif isObjectiveStat and statValue > 0 then
            totalObjectives = totalObjectives + statValue
            
            local objectiveType = "other"
            if statName:find("flag") and statName:find("capture") then
                objectiveType = "flagsCaptured"
            elseif statName:find("flag") and statName:find("return") then
                objectiveType = "flagsReturned"
            elseif statName:find("base") and statName:find("assault") then
                objectiveType = "basesAssaulted"
            elseif statName:find("base") and statName:find("defend") then
                objectiveType = "basesDefended"
            elseif statName:find("tower") and statName:find("assault") then
                objectiveType = "towersAssaulted"
            elseif statName:find("tower") and statName:find("defend") then
                objectiveType = "towersDefended"
            elseif statName:find("graveyard") and statName:find("assault") then
                objectiveType = "graveyardsAssaulted"
            elseif statName:find("graveyard") and statName:find("defend") then
                objectiveType = "graveyardsDefended"
            elseif statName:find("gate") and statName:find("destroy") then
                objectiveType = "gatesDestroyed"
            elseif statName:find("gate") and statName:find("defend") then
                objectiveType = "gatesDefended"
            elseif statName:find("cart") then
                objectiveType = "cartsControlled"
            elseif statName:find("crystal") or statName:find("shard") or statName:find("deposit") then
                objectiveType = "crystalsCaptured"
            elseif statName:find("orb") then
                objectiveType = "orbScore"
            elseif statName:find("azerite") then
                objectiveType = "azeriteCollected"
            elseif statName:find("structure") and statName:find("destroy") then
                objectiveType = "structuresDestroyed"
            elseif statName:find("structure") and statName:find("defend") then
                objectiveType = "structuresDefended"
            elseif statName:find("demolisher") or statName:find("vehicle") then
                objectiveType = "vehiclesDestroyed"
            else
                objectiveType = "objectives"
            end
            
            objectiveBreakdown[objectiveType] = (objectiveBreakdown[objectiveType] or 0) + statValue
            
            table.insert(foundStats, {
                name = originalName,
                value = statValue,
                id = statID,
                type = objectiveType
            })
            
            ObjectiveIdMap[statID] = objectiveType
        end
    end
    
    if #foundStats > 0 then
        
        return totalObjectives, objectiveBreakdown
    else
        
        return 0, {}
    end
end

local function ExtractObjectiveDataLegacy(scoreData, battlegroundName)
    if not scoreData then return 0, {} end
    
    local bgName = (battlegroundName or ""):lower()
    local objectiveBreakdown = {}
    
    
    if bgName:find("warsong") or bgName:find("twin peaks") then
        local flagsCaptured = scoreData.flagsCaptured or 0
        local flagsReturned = scoreData.flagsReturned or 0
        local objectives = flagsCaptured + flagsReturned
        
        if flagsCaptured > 0 then objectiveBreakdown.flagsCaptured = flagsCaptured end
        if flagsReturned > 0 then objectiveBreakdown.flagsReturned = flagsReturned end
        
        return objectives, objectiveBreakdown
        
    elseif bgName:find("temple of kotmogu") then
        local orbScore = scoreData.orbScore or scoreData.objectives or scoreData.objectiveValue or 
                        scoreData.objectiveBG1 or scoreData.score or 0
        
        if orbScore > 0 then objectiveBreakdown.orbScore = orbScore end
        
        return orbScore, objectiveBreakdown
        
    elseif bgName:find("arathi basin") or bgName:find("battle for gilneas") or bgName:find("eye of the storm") then
        local basesAssaulted = scoreData.basesAssaulted or 0
        local basesDefended = scoreData.basesDefended or 0
        local objectives = basesAssaulted + basesDefended
        
        if basesAssaulted > 0 then objectiveBreakdown.basesAssaulted = basesAssaulted end
        if basesDefended > 0 then objectiveBreakdown.basesDefended = basesDefended end
        
        return objectives, objectiveBreakdown
        
    elseif bgName:find("alterac valley") or bgName:find("isle of conquest") then
        local towersAssaulted = scoreData.towersAssaulted or 0
        local towersDefended = scoreData.towersDefended or 0
        local graveyardsAssaulted = scoreData.graveyardsAssaulted or 0
        local graveyardsDefended = scoreData.graveyardsDefended or 0
        local basesAssaulted = scoreData.basesAssaulted or 0
        local basesDefended = scoreData.basesDefended or 0
        local objectives = towersAssaulted + towersDefended + graveyardsAssaulted + graveyardsDefended + basesAssaulted + basesDefended
        
        if towersAssaulted > 0 then objectiveBreakdown.towersAssaulted = towersAssaulted end
        if towersDefended > 0 then objectiveBreakdown.towersDefended = towersDefended end
        if graveyardsAssaulted > 0 then objectiveBreakdown.graveyardsAssaulted = graveyardsAssaulted end
        if graveyardsDefended > 0 then objectiveBreakdown.graveyardsDefended = graveyardsDefended end
        if basesAssaulted > 0 then objectiveBreakdown.basesAssaulted = basesAssaulted end
        if basesDefended > 0 then objectiveBreakdown.basesDefended = basesDefended end
        
        return objectives, objectiveBreakdown
        
    elseif bgName:find("strand") then
        local gatesDestroyed = scoreData.gatesDestroyed or scoreData.objectiveBG1 or 0
        local gatesDefended = scoreData.gatesDefended or scoreData.objectiveBG2 or 0
        local objectives = gatesDestroyed + gatesDefended
        
        if gatesDestroyed > 0 then objectiveBreakdown.gatesDestroyed = gatesDestroyed end
        if gatesDefended > 0 then objectiveBreakdown.gatesDefended = gatesDefended end
        
        return objectives, objectiveBreakdown
        
    elseif bgName:find("silvershard") then
        local cartsControlled = scoreData.cartsControlled or scoreData.objectiveBG1 or 0
        
        if cartsControlled > 0 then objectiveBreakdown.cartsControlled = cartsControlled end
        
        return cartsControlled, objectiveBreakdown
        
    elseif bgName:find("deepwind") then
        local flagsCaptured = scoreData.flagsCaptured or 0
        local basesAssaulted = scoreData.basesAssaulted or 0
        local objectives = flagsCaptured + basesAssaulted
        
        if flagsCaptured > 0 then objectiveBreakdown.flagsCaptured = flagsCaptured end
        if basesAssaulted > 0 then objectiveBreakdown.basesAssaulted = basesAssaulted end
        
        return objectives, objectiveBreakdown
        
    elseif bgName:find("seething shore") then
        local azeriteCollected = scoreData.azeriteCollected or scoreData.objectives or scoreData.objectiveBG1 or 0
        
        if azeriteCollected > 0 then objectiveBreakdown.azeriteCollected = azeriteCollected end
        
        return azeriteCollected, objectiveBreakdown
        
    elseif bgName:find("deephaul") then
        local cartsEscorted = scoreData.cartsEscorted or scoreData.cartsControlled or scoreData.objectiveBG1 or 0
        
        if cartsEscorted > 0 then objectiveBreakdown.cartsControlled = cartsEscorted end
        
        return cartsEscorted, objectiveBreakdown
        
    elseif bgName:find("wintergrasp") or bgName:find("tol barad") then
        local structuresDestroyed = scoreData.structuresDestroyed or scoreData.objectiveBG1 or 0
        local structuresDefended = scoreData.structuresDefended or scoreData.objectiveBG2 or 0
        local objectives = structuresDestroyed + structuresDefended
        
        if structuresDestroyed > 0 then objectiveBreakdown.structuresDestroyed = structuresDestroyed end
        if structuresDefended > 0 then objectiveBreakdown.structuresDefended = structuresDefended end
        
        return objectives, objectiveBreakdown
        
    else
        local objectives = 0
        local fieldMapping = {
            flagsCaptured = "flagsCaptured",
            flagsReturned = "flagsReturned",
            basesAssaulted = "basesAssaulted",
            basesDefended = "basesDefended",
            towersAssaulted = "towersAssaulted",
            towersDefended = "towersDefended",
            graveyardsAssaulted = "graveyardsAssaulted",
            graveyardsDefended = "graveyardsDefended",
            gatesDestroyed = "gatesDestroyed",
            gatesDefended = "gatesDefended",
            cartsControlled = "cartsControlled",
            cartsEscorted = "cartsControlled",
            orbScore = "orbScore",
            azeriteCollected = "azeriteCollected",
            structuresDestroyed = "structuresDestroyed",
            structuresDefended = "structuresDefended",
            demolishersDestroyed = "vehiclesDestroyed",
            vehiclesDestroyed = "vehiclesDestroyed",
            nodesAssaulted = "basesAssaulted",
            nodesDefended = "basesDefended"
        }
        
        local genericFields = {
            "objectives", "objectiveValue", "score",
            "objectiveBG1", "objectiveBG2", "objectiveBG3", "objectiveBG4"
        }
        
        for fieldName, breakdownKey in pairs(fieldMapping) do
            local value = scoreData[fieldName] or 0
            if value > 0 then
                objectives = objectives + value
                objectiveBreakdown[breakdownKey] = (objectiveBreakdown[breakdownKey] or 0) + value
            end
        end
        
        if objectives == 0 then
            for _, field in ipairs(genericFields) do
                local value = scoreData[field] or 0
                if value > 0 then
                    objectives = objectives + value
                    objectiveBreakdown.objectives = (objectiveBreakdown.objectives or 0) + value
                end
            end
        end
        
        return objectives, objectiveBreakdown
    end
end

local function ExtractObjectiveData(scoreData, battlegroundName)
    if not scoreData then return 0, {} end
    
    local statsResult, statsBreakdown = ExtractObjectiveDataFromStats(scoreData)
    if statsResult ~= nil then
        return statsResult, statsBreakdown or {}
    end
    
    return ExtractObjectiveDataLegacy(scoreData, battlegroundName)
end

local function HumanizeObjectiveKey(key)
    local text = tostring(key or "objectives")
    text = text:gsub("_", " ")
    text = text:gsub("([a-z])([A-Z])", "%1 %2")
    text = text:gsub("^%l", string.upper)
    return text
end

local function GetObjectiveColumns(battlegroundName, playerDataList)
    local bgName = (battlegroundName or ""):lower()
    local availableObjectives = {}
    
    for _, player in ipairs(playerDataList or {}) do
        if player.objectiveBreakdown then
            for objType, value in pairs(player.objectiveBreakdown) do
                if (tonumber(value) or 0) > 0 then
                    availableObjectives[objType] = true
                end
            end
        end
    end
    
    local columnDefinitions = {}
    
    if bgName:find("warsong") or bgName:find("twin peaks") then
        columnDefinitions = {
            {key = "flagsCaptured", name = "FC", tooltip = "Flags Captured"},
            {key = "flagsReturned", name = "FR", tooltip = "Flags Returned"}
        }
    elseif bgName:find("temple of kotmogu") then
        columnDefinitions = {
            {key = "orbScore", name = "Orb", tooltip = "Orb Score"}
        }
    elseif bgName:find("arathi") or bgName:find("battle for gilneas") or bgName:find("eye of the storm") then
        columnDefinitions = {
            {key = "basesAssaulted", name = "BA", tooltip = "Bases Assaulted"},
            {key = "basesDefended", name = "BD", tooltip = "Bases Defended"}
        }
    elseif bgName:find("alterac valley") or bgName:find("isle of conquest") then
        columnDefinitions = {
            {key = "towersAssaulted", name = "TA", tooltip = "Towers Assaulted"},
            {key = "towersDefended", name = "TD", tooltip = "Towers Defended"},
            {key = "graveyardsAssaulted", name = "GA", tooltip = "Graveyards Assaulted"},
            {key = "graveyardsDefended", name = "GD", tooltip = "Graveyards Defended"},
            {key = "basesAssaulted", name = "BA", tooltip = "Bases Assaulted"},
            {key = "basesDefended", name = "BD", tooltip = "Bases Defended"}
        }
    elseif bgName:find("strand") then
        columnDefinitions = {
            {key = "gatesDestroyed", name = "GDest", tooltip = "Gates Destroyed"},
            {key = "gatesDefended", name = "GDef", tooltip = "Gates Defended"}
        }
    elseif bgName:find("silvershard") or bgName:find("deephaul") then
        columnDefinitions = {
            {key = "cartsControlled", name = "Carts", tooltip = "Carts Controlled"}
        }
    elseif bgName:find("seething shore") then
        columnDefinitions = {
            {key = "azeriteCollected", name = "Azer", tooltip = "Azerite Collected"}
        }
    elseif bgName:find("deepwind") then
        columnDefinitions = {
            {key = "flagsCaptured", name = "FC", tooltip = "Flags Captured"},
            {key = "basesAssaulted", name = "BA", tooltip = "Bases Assaulted"}
        }
    elseif bgName:find("wintergrasp") or bgName:find("tol barad") then
        columnDefinitions = {
            {key = "structuresDestroyed", name = "SDest", tooltip = "Structures Destroyed"},
            {key = "structuresDefended", name = "SDef", tooltip = "Structures Defended"}
        }
    else
        local commonObjectives = {
            {key = "flagsCaptured", name = "FC", tooltip = "Flags Captured"},
            {key = "flagsReturned", name = "FR", tooltip = "Flags Returned"},
            {key = "basesAssaulted", name = "BA", tooltip = "Bases Assaulted"},
            {key = "basesDefended", name = "BD", tooltip = "Bases Defended"},
            {key = "towersAssaulted", name = "TA", tooltip = "Towers Assaulted"},
            {key = "towersDefended", name = "TD", tooltip = "Towers Defended"},
            {key = "graveyardsAssaulted", name = "GA", tooltip = "Graveyards Assaulted"},
            {key = "graveyardsDefended", name = "GD", tooltip = "Graveyards Defended"},
            {key = "gatesDestroyed", name = "GDest", tooltip = "Gates Destroyed"},
            {key = "gatesDefended", name = "GDef", tooltip = "Gates Defended"},
            {key = "cartsControlled", name = "Carts", tooltip = "Carts Controlled"},
            {key = "orbScore", name = "Orb", tooltip = "Orb Score"},
            {key = "azeriteCollected", name = "Azer", tooltip = "Azerite Collected"},
            {key = "structuresDestroyed", name = "SDest", tooltip = "Structures Destroyed"},
            {key = "structuresDefended", name = "SDef", tooltip = "Structures Defended"},
            {key = "vehiclesDestroyed", name = "Vehi", tooltip = "Vehicles Destroyed"},
            {key = "objectives", name = "Obj", tooltip = "Other Objectives"}
        }
        columnDefinitions = commonObjectives
    end
    
    local activeColumns = {}
    local seenKeys = {}
    for _, colDef in ipairs(columnDefinitions) do
        if availableObjectives[colDef.key] then
            seenKeys[colDef.key] = true
            table.insert(activeColumns, colDef)
        end
    end

    local unknownObjectiveKeys = {}
    for objectiveKey in pairs(availableObjectives) do
        if not seenKeys[objectiveKey] then
            table.insert(unknownObjectiveKeys, objectiveKey)
        end
    end
    table.sort(unknownObjectiveKeys)
    for _, objectiveKey in ipairs(unknownObjectiveKeys) do
        table.insert(activeColumns, {
            key = objectiveKey,
            name = HumanizeObjectiveKey(objectiveKey),
            tooltip = HumanizeObjectiveKey(objectiveKey)
        })
    end

    if #activeColumns == 0 then
        local hasAnyTotalObjectives = false
        for _, player in ipairs(playerDataList or {}) do
            if player and (tonumber(player.objectives) or 0) > 0 then
                hasAnyTotalObjectives = true
                break
            end
        end
        if hasAnyTotalObjectives then
            table.insert(activeColumns, {
                key = "objectives",
                name = "Objectives",
                tooltip = "Objectives"
            })
        end
    end

    return activeColumns
end

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function GetBestRealmName()
    local realm = GetRealmName()
    if realm and realm ~= "" then
        return realm
    end
    
    realm = GetNormalizedRealmName()
    if realm and realm ~= "" then
        return realm
    end
    
    local connectedRealms = GetAutoCompleteRealms()
    if connectedRealms and #connectedRealms > 0 then
        return connectedRealms[1]
    end
    
    return "Unknown-Realm"
end

local function UpdateBattlegroundStatus()
    local _, instanceType = IsInInstance()
    local inBG = false
    
    if instanceType == "pvp" then
        inBG = true
    elseif C_PvP and C_PvP.IsBattleground and C_PvP.IsBattleground() then
        inBG = true
    elseif GetNumBattlefieldScores() > 0 then
        inBG = true
    elseif UnitInBattleground("player") then
        inBG = true
    end
    
    return inBG
end

local function NormalizeBattlegroundName(mapName)
    local nameMap = {
        ["Ashran"] = "Ashran",
        ["Wintergrasp"] = "Battle for Wintergrasp", 
        ["Tol Barad"] = "Tol Barad",
	["The Battle for Gilneas"] = "The Battle for Gilneas",
	["Battle for Gilneas"] = "The Battle for Gilneas",
        ["Silvershard Mines"] = "Silvershard Mines",
        ["Temple of Kotmogu"] = "Temple of Kotmogu",
        ["Deepwind Gorge"] = "Deepwind Gorge",
        ["Seething Shore"] = "Seething Shore",
        ["Deephaul Ravine"] = "Deephaul Ravine",
        ["Arathi Basin"] = "Arathi Basin",
        ["Warsong Gulch"] = "Warsong Gulch",
        ["Alterac Valley"] = "Alterac Valley",
        ["Eye of the Storm"] = "Eye of the Storm",
        ["Strand of the Ancients"] = "Strand of the Ancients",
        ["Isle of Conquest"] = "Isle of Conquest",
		["Twin Peaks"] = "Twin Peaks",
		["Slayer's Rise"] = "Slayer's Rise"
    }
    
    return nameMap[mapName] or mapName
end

local function CollectScoreData(attemptNumber)
    attemptNumber = attemptNumber or 1
    local t, rows = {}, GetNumBattlefieldScores()
    
    if rows == 0 then
        return {}
    end
    
    local currentPlayerName = UnitName("player")
    local currentKey = GetPlayerKey(currentPlayerName, GetBestRealmName())
    local foundCurrentPlayer = false
    
    local playerRealm = GetBestRealmName()
    local successfulReads = 0
    local failedReads = 0
    
    for i = 1, rows do
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        
        if success and s and s.name then
            successfulReads = successfulReads + 1
            
            local playerName, realmName = s.name, ""
            
            if s.name:find("-") then
                playerName, realmName = s.name:match("^(.+)-(.+)$")
            end
            
            if (not realmName or realmName == "") and s.realm then
                realmName = s.realm
            end
            
            if (not realmName or realmName == "") and s.guid then
                local _, _, _, _, _, _, _, realmFromGUID = GetPlayerInfoByGUID(s.guid)
                if realmFromGUID and realmFromGUID ~= "" then
                    realmName = realmFromGUID
                end
            end
            
            if not realmName or realmName == "" then
                realmName = playerRealm
            end
            
            realmName = realmName:gsub("%s+", ""):gsub("'", "")
            
            local className = ""
            local specName = s.talentSpec or s.specName or ""
            
            if s.className then
                className = s.className
            elseif s.class then
                className = s.class
            elseif s.guid then
                local _, _, _, _, _, _, classFileName = GetPlayerInfoByGUID(s.guid)
                if classFileName then
                    local classNames = {
                        ["WARRIOR"] = "Warrior", ["PALADIN"] = "Paladin", ["HUNTER"] = "Hunter",
                        ["ROGUE"] = "Rogue", ["PRIEST"] = "Priest", ["DEATHKNIGHT"] = "Death Knight",
                        ["SHAMAN"] = "Shaman", ["MAGE"] = "Mage", ["WARLOCK"] = "Warlock",
                        ["MONK"] = "Monk", ["DRUID"] = "Druid", ["DEMONHUNTER"] = "Demon Hunter",
                        ["EVOKER"] = "Evoker"
                    }
                    className = classNames[classFileName] or classFileName
                end
            end
            
            if className == "" then
                className = "Unknown"
            end
            
            local factionName = ""
            if s.faction == 0 then
                factionName = "Horde"
            elseif s.faction == 1 then
                factionName = "Alliance"
            else
                if s.side == "Alliance" or s.side == "Horde" then
                    factionName = s.side
                elseif s.side == 0 then
                    factionName = "Horde"
                elseif s.side == 1 then
                    factionName = "Alliance"
                else
                    factionName = "Unknown"
                end
            end
            
            if playerName == currentPlayerName then
                foundCurrentPlayer = true
            end
            
            local rawDamage = s.damageDone or s.damage or 0
            local rawHealing = s.healingDone or s.healing or 0
            local rating = s.rating or 0
            local ratingChange = s.ratingChange or 0
            local preMatchMMR = s.preMatchMMR or 0
            local postMatchMMR = s.postMatchMMR or 0
            
            local map = C_Map.GetBestMapForUnit("player") or 0
            local mapInfo = C_Map.GetMapInfo(map)
            local battlegroundName = (mapInfo and mapInfo.name) or "Unknown"
            local objectives, objectiveBreakdown = ExtractObjectiveData(s, battlegroundName)
            
            local playerData = {
                name = playerName,
                realm = realmName,
                faction = factionName,
                class = className,
                spec = specName,
				damage = rawDamage,
				healing = rawHealing,
                kills = s.killingBlows or s.kills or 0,
                deaths = s.deaths or 0,
                honorableKills = s.honorableKills or s.honorKills or 0,
                rating = rating,
                ratingChange = ratingChange,
                preMatchMMR = preMatchMMR,
                postMatchMMR = postMatchMMR,
                objectives = objectives,
                objectiveBreakdown = objectiveBreakdown or {}
            }
            
            t[#t+1] = playerData
        else
            failedReads = failedReads + 1
        end
    end
     
    for _, player in ipairs(t) do
        if playerTracker.joinedInProgress then
            player.participationUnknown = true
        else
            player.participationUnknown = false
        end
    end

    return t
end

local function DetectAvailableAPIs()
    local apis = {
        GetWinner = _G.GetBattlefieldWinner,
        IsRatedBattleground = _G.IsRatedBattleground,
		IsWargame = _G.IsWargame,
        IsInBrawl = C_PvP and C_PvP.IsInBrawl,
        IsSoloRBG = C_PvP and C_PvP.IsSoloRBG,
        IsBattleground = C_PvP and C_PvP.IsBattleground,
        GetActiveMatchDuration = C_PvP and C_PvP.GetActiveMatchDuration,
        GetPlayerInfoByGUID = _G.GetPlayerInfoByGUID,
        GetClassInfo = _G.GetClassInfo,
        GetRealmName = _G.GetRealmName,
    }
    
    for name, func in pairs(apis) do
    end
    
    return apis
end

local function CommitMatch(list)
    
    if matchSaved then
        return
    end
    
    if #list == 0 then
        return
    end

    local success, result = pcall(function()
        local map = C_Map.GetBestMapForUnit("player") or 0
        
        local currentTime = GetTime()
        
        local duration = 0
        local trueDuration = 0
        local durationSource = "unknown"
        
        if C_PvP and C_PvP.GetActiveMatchDuration then
            local apiDuration = C_PvP.GetActiveMatchDuration()
            if apiDuration and apiDuration > 0 and apiDuration < 7200 then
                duration = math.floor(apiDuration)
                trueDuration = duration
                durationSource = "C_PvP.GetActiveMatchDuration"
            end
        end
        
        if duration == 0 then
            local timeSinceBGStart = math.floor(currentTime - bgStartTime)
            
            if timeSinceBGStart > 0 and timeSinceBGStart < 7200 then
                trueDuration = timeSinceBGStart
                durationSource = "calculated_fallback"
            else
                trueDuration = 900
                durationSource = "default_estimate"
            end
            
            duration = trueDuration
        end
        
        
        local winner = ""
        if GetWinner then
            local winnerFaction = GetWinner()
            if winnerFaction == 0 then
                winner = "Horde"
            elseif winnerFaction == 1 then
                winner = "Alliance"
            end
        end
        
        local bgType = "non-rated"

		if IsWargame and IsWargame() then
			bgType = "wargames"
		
		elseif C_PvP and C_PvP.IsInBrawl and C_PvP.IsInBrawl() then
            bgType = "brawl"
        
        elseif C_PvP and C_PvP.IsSoloRBG and C_PvP.IsSoloRBG() then
            bgType = "rated-blitz"
        
        elseif IsRatedBattleground and IsRatedBattleground() then
            bgType = "rated"
        
        elseif C_PvP and C_PvP.IsBattleground and C_PvP.IsBattleground() then
            bgType = "non-rated"
        
        else
            
            if C_PvP and C_PvP.GetActiveMatchBracket then
                local bracket = C_PvP.GetActiveMatchBracket()
                if bracket and bracket > 0 then
                    bgType = "rated-blitz"
                end
            end
            
        end

        
        local mapInfo = C_Map.GetMapInfo(map)
        local mapName = (mapInfo and mapInfo.name) or "Unknown Battleground"
        
        local exportPlayers = {}
        for _, p in ipairs(list) do
            table.insert(exportPlayers, {
                name = p.name,
                realm = p.realm,
                faction = p.faction,
                class = p.class,
                spec = p.spec,
                damage = tostring(p.damage or p.dmg or 0),
                healing = tostring(p.healing or p.heal or 0),
                kills = p.kills or p.killingBlows or p.kb or 0,
                deaths = p.deaths or 0,
                honorableKills = p.honorableKills or 0,
                rating = p.rating or 0,
                ratingChange = p.ratingChange or 0,
                preMatchMMR = p.preMatchMMR or 0,
                postMatchMMR = p.postMatchMMR or 0,
                objectives = p.objectives or 0,
                objectiveBreakdown = p.objectiveBreakdown or {}
            })
        end
        
        local forHashV2 = {
            battleground = mapName,
            date = date("!%Y-%m-%dT%H:%M:%SZ"),
            type = bgType,
            duration = tostring(duration or 0),
            trueDuration = tostring(trueDuration or duration or 0),
            winner = winner,
            players = exportPlayers,
            joinedInProgress = playerTracker.joinedInProgress or false,
            validForStats = not (playerTracker.joinedInProgress or false)
        }
        local dataHash, hashMetadata = GenerateDataHashV2FromExport(forHashV2)
        
        local key = map.."_"..date("!%Y%m%d_%H%M%S")
		local selfName = UnitName("player")
		local selfRealm = NormalizeRealmName(GetRealmName() or "Unknown-Realm")
		local selfFaction = UnitFactionGroup("player") or ""
        
        BGLoggerDB[key] = {
            mapID = map,
            ended = date("%c"),
            stats = list,
            addonVersion = ADDON_VERSION,
            
            battlegroundName = mapName,
            duration = duration,
            durationSource = durationSource,
            winner = winner,
            type = bgType,
			season = CURRENT_SEASON,
            startTime = bgStartTime,
            endTime = currentTime,
            dateISO = date("!%Y-%m-%dT%H:%M:%SZ"),
            
            joinedInProgress = playerTracker.joinedInProgress or false,
            playerJoinedInProgress = playerTracker.playerJoinedInProgress or false,
            validForStats = not (playerTracker.joinedInProgress or false),
			selfPlayer = { name = selfName, realm = selfRealm, faction = selfFaction },
			selfPlayerKey = GetPlayerKey(selfName, selfRealm),
			recorder = { name = selfName, realm = selfRealm, faction = selfFaction },
			recorderKey = GetPlayerKey(selfName, selfRealm),
            
            integrity = {
                hash = dataHash,
                metadata = { algorithm = "deep_v2", playerCount = #list },
                generatedAt = GetServerTime(),
                serverTime = GetServerTime(),
                version = ADDON_VERSION,
                realm = GetRealmName() or "Unknown"
            }
        }
        
        -- Append to persistent character stats
        local selfKey = GetPlayerKey(selfName, selfRealm)
        local selfEntry = FindSelfPlayerEntry(BGLoggerDB[key], selfName, selfRealm)
        if selfEntry then
            local didWin = nil
            if winner ~= "" then
                local matchFaction = selfEntry.faction or selfFaction
                didWin = (winner == matchFaction)
            end
    
            local bgCategory
            if bgType == "rated-blitz" then
                bgCategory = "blitz"
            elseif bgType == "rated" then
                bgCategory = "rated"
            elseif IsEpicBattlegroundByName(mapName) then
                bgCategory = "epic"
            else
                bgCategory = "random"
            end
            AppendCharStats(selfKey, CURRENT_SEASON, bgCategory, mapName, selfEntry, didWin)
        end
        
        matchSaved = true
        ClearSessionState("match saved")
        StopStatePersistence()
        
        if BGLoggerDB[key] then
        else
            return false
        end
        
        return true
    end)
    
    if not success then
        return false
    end
    
    if WINDOW and WINDOW:IsShown() then
        C_Timer.After(0.1, RequestRefreshWindow)
    end
    
    return result
end

local function PollUntilWinner(retries)
    retries = retries or 0
    
    RequestBattlefieldScoreData()
    
    C_Timer.After(0.7, function()
        local win = GetWinner and GetWinner() or nil
        
        if win then
            CommitMatch(CollectScoreData())
        elseif retries < 5 then
            PollUntilWinner(retries + 1)
        else
            CommitMatch(CollectScoreData())
        end
    end)
end

function AttemptSaveWithRetry(source, retryCount)
    retryCount = retryCount or 0
    
    if matchSaved then
        return
    end
    
    if saveInProgress then
        return
    end
    
    saveInProgress = true
    
    RequestBattlefieldScoreData()
    
    local delay = 2 + (retryCount * 0.5)
    
    C_Timer.After(delay, function()
        local success, result = pcall(function()
            local data = CollectScoreData()
            
            if #data == 0 then
                return false
            end
            
            local minExpectedPlayers = 10
            if #data < minExpectedPlayers then
                return false
            end
            
            local validPlayers = 0
            for i, player in ipairs(data) do
                if player.name and player.name ~= "" and 
                   (player.damage > 0 or player.healing > 0 or player.kills > 0) then
                    validPlayers = validPlayers + 1
                end
            end
            
            
            if validPlayers < minExpectedPlayers then
                return false
            end
            
            local saveSuccess = CommitMatch(data)
            
            if matchSaved then
                saveInProgress = false
                return true
            else
                return false
            end
        end)
        
        if success and result then
            saveInProgress = false
        elseif success and not result then
            
            if retryCount < 3 then
                C_Timer.After(3, function()
                    saveInProgress = false
                    AttemptSaveWithRetry(source, retryCount + 1)
                end)
            else
                saveInProgress = false
            end
        else
            saveInProgress = false
        end
    end)
end

---------------------------------------------------------------------
-- Export Functions
---------------------------------------------------------------------


if not TableToJSON then
function TableToJSON(tbl, indent)
    indent = indent or 0
    local spacing = string.rep("  ", indent)
    
    if type(tbl) == "string" then
        return '"' .. tbl:gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r') .. '"'
    elseif type(tbl) == "number" then
        return tostring(tbl)
    elseif type(tbl) == "boolean" then
        return tbl and "true" or "false"
    elseif tbl == nil then
        return "null"
    elseif type(tbl) ~= "table" then
        return "null"
    end
    
    local isArray = true
    local arraySize = 0
    for k, v in pairs(tbl) do
        if type(k) ~= "number" then
            isArray = false
            break
        end
        arraySize = math.max(arraySize, k)
    end
    
    if isArray then
        local parts = {}
        table.insert(parts, "[\n")
        for i = 1, arraySize do
            if tbl[i] ~= nil then
                table.insert(parts, spacing .. "  " .. TableToJSON(tbl[i], indent + 1))
                if i < arraySize and tbl[i+1] ~= nil then
                    table.insert(parts, ",")
                end
                table.insert(parts, "\n")
            end
        end
        table.insert(parts, spacing .. "]")
        return table.concat(parts)
    else
        local parts = {}
        table.insert(parts, "{\n")
        
        local keys = {}
        for k in pairs(tbl) do
            table.insert(keys, k)
        end
        table.sort(keys)
        
        for i, k in ipairs(keys) do
            local v = tbl[k]
            table.insert(parts, spacing .. '  "' .. tostring(k) .. '": ' .. TableToJSON(v, indent + 1))
            if i < #keys then
                table.insert(parts, ",")
            end
            table.insert(parts, "\n")
        end
        
        table.insert(parts, spacing .. "}")
        return table.concat(parts)
    end
    end
end

if not ShowJSONExportFrame then
function ShowJSONExportFrame(jsonString, filename)
    
    if not BGLoggerExportFrame then
        local f = CreateFrame("Frame", "BGLoggerExportFrame", UIParent, "BackdropTemplate")
        f:SetSize(700, 500)
        f:SetPoint("CENTER")
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = {left = 8, right = 8, top = 8, bottom = 8}
        })
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")
        
        local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", -6, -6)
        
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -16)
        title:SetText("Export Battleground Data")

        local instructions = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        instructions:SetPoint("TOP", title, "BOTTOM", 0, -10)
        instructions:SetText("Select all text (Ctrl+A) and copy (Ctrl+C) - Text is read-only:")
        
        local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 20, -80)
        scrollFrame:SetPoint("BOTTOMRIGHT", -40, 60)
        
        local editBox = CreateFrame("EditBox", nil, scrollFrame)
        editBox:SetSize(scrollFrame:GetWidth() - 20, 1)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(false)
        editBox:SetFontObject(ChatFontNormal)
        
        editBox:SetScript("OnChar", function() end)
        editBox:SetScript("OnKeyDown", function(self, key)
            if key == "C" and IsControlKeyDown() then
                C_Timer.After(0.1, function()
                    if BGLoggerExportFrame then
                        BGLoggerExportFrame:Hide()
                    end
                end)
            end
        end)
        
        editBox:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                self:SetText(f.originalText or "")
                self:SetCursorPosition(0)
            end
        end)
        
        editBox:SetScript("OnEscapePressed", function(self) 
            self:ClearFocus() 
        end)
        
        editBox:SetScript("OnEditFocusGained", function(self)
            C_Timer.After(0.05, function()
                if self:HasFocus() then
                    self:HighlightText()
                end
            end)
        end)
        
        editBox:SetTextColor(0.9, 0.9, 0.9)
        
        scrollFrame:SetScrollChild(editBox)
        
        f.scrollFrame = scrollFrame
        f.editBox = editBox
        
        local selectBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        selectBtn:SetSize(100, 22)
        selectBtn:SetPoint("BOTTOMLEFT", 20, 20)
        selectBtn:SetText("Select All")
        selectBtn:SetScript("OnClick", function()
            f.editBox:SetFocus()
            f.editBox:HighlightText()
        end)
        
        local copyInstructions = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        copyInstructions:SetPoint("LEFT", selectBtn, "RIGHT", 20, 0)
        copyInstructions:SetText("Read-only: Ctrl+A to select, Ctrl+C to copy")
        copyInstructions:SetTextColor(1, 1, 0)
        
        local filenameText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        filenameText:SetPoint("BOTTOMRIGHT", -20, 20)
        f.filenameText = filenameText
        
        f:Hide()
        BGLoggerExportFrame = f
    end
    
    BGLoggerExportFrame.originalText = jsonString
    
    BGLoggerExportFrame.editBox:SetText(jsonString)
    BGLoggerExportFrame.editBox:SetCursorPosition(0)
    
    BGLoggerExportFrame.filenameText:SetText("Save as: " .. filename)
    
    local fontHeight = 12
    local numLines = 1
    for _ in jsonString:gmatch('\n') do
        numLines = numLines + 1
    end
    BGLoggerExportFrame.editBox:SetHeight(math.max(numLines * fontHeight + 50, 100))
    
    BGLoggerExportFrame:Show()
    
end
end

function ShowExportMenu()
    local menu = {
        {
            text = "Export Current Battleground",
            func = function()
                if WINDOW.currentView == "detail" and WINDOW.currentKey then
                    ExportBattleground(WINDOW.currentKey)
                else
                    print("|cff00ffffBGLogger:|r Please open a battleground detail view first")
                end
            end,
            disabled = not (WINDOW.currentView == "detail" and WINDOW.currentKey)
        },
        {
            text = "Export All Battlegrounds",
            func = function()
                if ExportAllBattlegrounds then
                    ExportAllBattlegrounds()
                else
                    print("|cff00ffffBGLogger:|r ExportAllBattlegrounds not available")
                end
            end
        },
        {
            text = "Cancel",
            func = function() end
        }
    }
    
    EasyMenu(menu, CreateFrame("Frame", "BGLoggerExportMenu", UIParent, "UIDropDownMenuTemplate"), "cursor", 0, 0, "MENU")
end

---------------------------------------------------------------------
-- UI factory - completely rebuilt with proper column positioning
---------------------------------------------------------------------

local BASE_NON_OBJECTIVE_ORDER = {
    "name",
    "spec",
    "faction",
    "kills",
    "hk",
    "deaths",
    "damage",
    "healing",
}

local BASE_COLUMN_HEADERS = {
    name = "Player",
    spec = "Spec",
    faction = "Faction",
    kills = "Killing Blows",
    hk = "Honorable Kills",
    deaths = "Deaths",
    damage = "Damage",
    healing = "Healing",
}

local BASE_COLUMN_ALIGNMENT = {
    name = "LEFT",
    spec = "CENTER",
    faction = "CENTER",
    kills = "CENTER",
    hk = "CENTER",
    deaths = "CENTER",
    damage = "CENTER",
    healing = "CENTER",
}

local BASE_COLUMN_WIDTHS = {
    name = 360,
    spec = 110,
    faction = 80,
    kills = 58,
    hk = 74,
    deaths = 58,
    damage = 125,
    healing = 125,
}

local COLUMN_ORDER = {}
local COLUMN_HEADERS = {}
local COLUMN_ALIGNMENT = {}
local COLUMN_WIDTHS = {}
local SORTABLE_FIELDS = {}
local DETAIL_OBJECTIVE_COLUMNS = {}
local DETAIL_OBJECTIVE_KEY_BY_FIELD = {}
local DETAIL_OBJECTIVE_TOOLTIP_BY_FIELD = {}

local COLUMN_GAP = 6
local DETAIL_LEFT_PADDING = 12
local COLUMN_POSITIONS = {}
local DETAIL_CONTENT_WIDTH = 0
local OBJECTIVE_COLUMN_WIDTH_TARGET = 74
local OBJECTIVE_COLUMN_WIDTH_MIN = 48

local function CopyShallowTable(source)
    local copy = {}
    for k, v in pairs(source or {}) do
        copy[k] = v
    end
    return copy
end

local function RebuildDetailColumnGeometry()
    wipe(COLUMN_POSITIONS)
    local x = DETAIL_LEFT_PADDING
    for _, key in ipairs(COLUMN_ORDER) do
        COLUMN_POSITIONS[key] = x
        x = x + COLUMN_WIDTHS[key] + COLUMN_GAP
    end
    DETAIL_CONTENT_WIDTH = x - COLUMN_GAP + DETAIL_LEFT_PADDING
end

local SORTABLE_FIELDS_BASE = {
    name = {
        label = "Player",
        sortType = "string",
        accessor = function(row)
            return row.name or ""
        end
    },
    spec = {
        label = "Spec",
        sortType = "string",
        accessor = function(row)
            return row.spec or ""
        end
    },
    damage = {
        label = "Damage",
        sortType = "number",
        accessor = function(row)
            return row.damage or row.dmg or 0
        end
    },
    healing = {
        label = "Healing",
        sortType = "number",
        accessor = function(row)
            return row.healing or row.heal or 0
        end
    },
    kills = {
        label = "Killing Blows",
        sortType = "number",
        accessor = function(row)
            return row.kills or row.killingBlows or row.kb or 0
        end
    },
    deaths = {
        label = "Deaths",
        sortType = "number",
        accessor = function(row)
            return row.deaths or 0
        end
    },
    hk = {
        label = "Honorable Kills",
        sortType = "number",
        accessor = function(row)
            return row.honorableKills or row.honorKills or row.hk or 0
        end
    }
}

local function ResetSortableFields()
    wipe(SORTABLE_FIELDS)
    for key, def in pairs(SORTABLE_FIELDS_BASE) do
        SORTABLE_FIELDS[key] = def
    end
end

local function BuildObjectiveHeaderText(label, objectiveCount)
    local text = tostring(label or "Objective")
    if objectiveCount >= 3 and not text:find("\n", 1, true) then
        local left, right = text:match("^(%S+)%s+(.+)$")
        if left and right then
            return left .. "\n" .. right
        end
    end
    return text
end

local function ConfigureDetailColumnsForLog(data, battlegroundName)
    local rows = (data and data.stats) or {}
    local objectiveDefinitions = GetObjectiveColumns(battlegroundName or "", rows) or {}
    local objectiveCount = #objectiveDefinitions

    local widths = CopyShallowTable(BASE_COLUMN_WIDTHS)
    if objectiveCount >= 3 then
        widths.name = 330
        widths.spec = 98
        widths.damage = 112
        widths.healing = 112
    end
    if objectiveCount >= 5 then
        widths.name = 280
        widths.spec = 90
        widths.faction = 68
        widths.damage = 96
        widths.healing = 96
        widths.kills = 52
        widths.deaths = 52
        widths.hk = 62
    end

    local availableWidth = WIN_W - 90
    if WINDOW and WINDOW.detailScroll and type(WINDOW.detailScroll.GetWidth) == "function" then
        local scrollWidth = WINDOW.detailScroll:GetWidth() or 0
        if scrollWidth > 0 then
            availableWidth = scrollWidth - 18
        end
    end
    local usableWidth = math.max(980, availableWidth - DETAIL_LEFT_PADDING * 2)

    local objectiveWidth = 0
    if objectiveCount > 0 then
        local fixedWidth = 0
        for _, key in ipairs(BASE_NON_OBJECTIVE_ORDER) do
            fixedWidth = fixedWidth + (widths[key] or 0)
        end
        local projectedColumns = #BASE_NON_OBJECTIVE_ORDER + objectiveCount
        local projectedGaps = math.max(projectedColumns - 1, 0) * COLUMN_GAP
        local remainingForObjectives = usableWidth - fixedWidth - projectedGaps
        objectiveWidth = math.floor(remainingForObjectives / objectiveCount)
        objectiveWidth = math.max(OBJECTIVE_COLUMN_WIDTH_MIN, math.min(OBJECTIVE_COLUMN_WIDTH_TARGET, objectiveWidth))
    end

    local newOrder = {
        "name",
        "spec",
        "faction",
        "kills",
        "hk",
        "deaths",
        "damage",
        "healing",
    }
    local newHeaders = CopyShallowTable(BASE_COLUMN_HEADERS)
    local newAlignment = CopyShallowTable(BASE_COLUMN_ALIGNMENT)
    local newWidths = CopyShallowTable(widths)

    wipe(DETAIL_OBJECTIVE_COLUMNS)
    wipe(DETAIL_OBJECTIVE_KEY_BY_FIELD)
    wipe(DETAIL_OBJECTIVE_TOOLTIP_BY_FIELD)

    for i, objectiveDef in ipairs(objectiveDefinitions) do
        local field = "obj_" .. tostring(i)
        local objectiveKey = objectiveDef.key
        local objectiveLabel = objectiveDef.name or HumanizeObjectiveKey(objectiveKey)
        local objectiveTooltip = objectiveDef.tooltip or HumanizeObjectiveKey(objectiveKey)

        table.insert(newOrder, field)
        newHeaders[field] = BuildObjectiveHeaderText(objectiveLabel, objectiveCount)
        newAlignment[field] = "CENTER"
        newWidths[field] = objectiveWidth

        table.insert(DETAIL_OBJECTIVE_COLUMNS, {
            field = field,
            key = objectiveKey,
            label = objectiveLabel,
        })
        DETAIL_OBJECTIVE_KEY_BY_FIELD[field] = objectiveKey
        DETAIL_OBJECTIVE_TOOLTIP_BY_FIELD[field] = objectiveTooltip
    end

    -- Keep objective columns slim, but avoid a large empty field on the right by
    -- distributing any remaining width across core columns.
    local projectedWidth = 0
    for _, columnKey in ipairs(newOrder) do
        projectedWidth = projectedWidth + (newWidths[columnKey] or 0)
    end
    local projectedGaps = math.max(#newOrder - 1, 0) * COLUMN_GAP
    projectedWidth = projectedWidth + projectedGaps

    local extraWidth = math.floor(usableWidth - projectedWidth)
    if extraWidth > 0 then
        local growthColumns = { "name", "spec", "damage", "healing", "faction" }
        local growthCount = #growthColumns
        if growthCount > 0 then
            local perColumn = math.floor(extraWidth / growthCount)
            local remainder = extraWidth % growthCount
            for i, columnKey in ipairs(growthColumns) do
                if newWidths[columnKey] then
                    newWidths[columnKey] = newWidths[columnKey] + perColumn + ((i <= remainder) and 1 or 0)
                end
            end
        end
    end

    COLUMN_ORDER = newOrder
    COLUMN_HEADERS = newHeaders
    COLUMN_ALIGNMENT = newAlignment
    COLUMN_WIDTHS = newWidths

    ResetSortableFields()
    for _, objectiveColumn in ipairs(DETAIL_OBJECTIVE_COLUMNS) do
        local fieldName = objectiveColumn.field
        local objectiveKey = objectiveColumn.key
        SORTABLE_FIELDS[fieldName] = {
            label = objectiveColumn.label or HumanizeObjectiveKey(objectiveKey),
            sortType = "number",
            accessor = function(row)
                if not row then return 0 end
                if type(row.objectiveBreakdown) == "table" then
                    local value = row.objectiveBreakdown[objectiveKey]
                    if value then
                        return tonumber(value) or 0
                    end
                end
                if objectiveKey == "objectives" then
                    return tonumber(row.objectives) or 0
                end
                return 0
            end,
        }
    end

    RebuildDetailColumnGeometry()

    if WINDOW then
        local signatureParts = {}
        for _, objectiveColumn in ipairs(DETAIL_OBJECTIVE_COLUMNS) do
            table.insert(signatureParts, tostring(objectiveColumn.key))
        end
        local layoutSignature = table.concat(signatureParts, "|")
        if WINDOW.detailLayoutSignature ~= layoutSignature then
            for _, line in ipairs(DetailLines) do
                if line then
                    line:Hide()
                end
            end
            wipe(DetailLines)
            WINDOW.detailLayoutSignature = layoutSignature
            if WINDOW.detailSortField and not SORTABLE_FIELDS[WINDOW.detailSortField] then
                WINDOW.detailSortField = "damage"
                WINDOW.detailSortDirection = "desc"
            end
        end
        if WINDOW.detailContent and WINDOW.detailScroll and type(WINDOW.detailScroll.GetWidth) == "function" then
            local scrollWidth = WINDOW.detailScroll:GetWidth() or 0
            if scrollWidth > 0 then
                WINDOW.detailContent:SetWidth(math.max(scrollWidth - 16, DETAIL_CONTENT_WIDTH))
            end
        end
    end
end

COLUMN_ORDER = CopyShallowTable(BASE_NON_OBJECTIVE_ORDER)
COLUMN_HEADERS = CopyShallowTable(BASE_COLUMN_HEADERS)
COLUMN_ALIGNMENT = CopyShallowTable(BASE_COLUMN_ALIGNMENT)
COLUMN_WIDTHS = CopyShallowTable(BASE_COLUMN_WIDTHS)
ResetSortableFields()
RebuildDetailColumnGeometry()

local DETAIL_ROW_COLORS = {
    even = {0.06, 0.06, 0.09, 0.86},
    odd = {0.06, 0.06, 0.09, 0.86},
    allianceEven = {0.04, 0.09, 0.18, 0.90},
    allianceOdd = {0.04, 0.09, 0.18, 0.90},
    hordeEven = {0.20, 0.02, 0.07, 0.90},
    hordeOdd = {0.20, 0.02, 0.07, 0.90},
    unknown = {0.11, 0.11, 0.11, 0.86},
    totals = {0.26, 0.20, 0.07, 0.92},
    summary = {0.17, 0.13, 0.06, 0.88},
    header = {0.16, 0.13, 0.05, 0.95},
    section = {0.12, 0.10, 0.06, 0.84}
}

local DETAIL_TEXT_COLORS = {
    default = {0.94, 0.94, 0.94},
    header = {1.0, 0.93, 0.62},
    totals = {1.0, 0.94, 0.70},
    section = {0.86, 0.84, 0.75},
    unknown = {0.78, 0.78, 0.78},
    alliance = {0.0, 0.64, 0.85},
    horde = {0.95, 0.20, 0.24},
    self = {0.98, 0.98, 1.0}
}

local DIVIDER_COLOR_DEFAULT = {0.33, 0.28, 0.16, 0.58}
local DIVIDER_COLOR_HEADER = {0.56, 0.45, 0.18, 0.74}
local DETAIL_NAME_ICON_SIZE = 16
local DETAIL_NAME_ICON_TEXT_GAP = 5
local DETAIL_NAME_ICON_TEXCOORD = {0.07, 0.93, 0.07, 0.93}
local SPEC_ICON_FALLBACK = "Interface\\Icons\\INV_Misc_QuestionMark"
local CLASS_ICONS_TEXTURE = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"

local specIconCacheBuilt = false
local classTokenByKey = {}
local specIconByClassToken = {}

local ENGLISH_CLASS_TOKEN_BY_KEY = {
    WARRIOR = "WARRIOR",
    PALADIN = "PALADIN",
    HUNTER = "HUNTER",
    ROGUE = "ROGUE",
    PRIEST = "PRIEST",
    DEATHKNIGHT = "DEATHKNIGHT",
    SHAMAN = "SHAMAN",
    MAGE = "MAGE",
    WARLOCK = "WARLOCK",
    MONK = "MONK",
    DRUID = "DRUID",
    DEMONHUNTER = "DEMONHUNTER",
    EVOKER = "EVOKER",
}

local function NormalizeLookupKey(value)
    return tostring(value or ""):upper():gsub("[%s%p_]", "")
end

local function BuildSpecIconCache()
    if specIconCacheBuilt then
        return
    end
    specIconCacheBuilt = true

    if type(GetNumClasses) ~= "function" or type(GetClassInfo) ~= "function" then
        return
    end

    local classCount = GetNumClasses() or 0
    for classIndex = 1, classCount do
        local className, classToken, classID = GetClassInfo(classIndex)
        local classIdentifier = classID or classIndex
        if classToken and classToken ~= "" then
            classTokenByKey[NormalizeLookupKey(classToken)] = classToken
            classTokenByKey[NormalizeLookupKey(className)] = classToken

            if LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classToken] then
                classTokenByKey[NormalizeLookupKey(LOCALIZED_CLASS_NAMES_MALE[classToken])] = classToken
            end
            if LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[classToken] then
                classTokenByKey[NormalizeLookupKey(LOCALIZED_CLASS_NAMES_FEMALE[classToken])] = classToken
            end

            specIconByClassToken[classToken] = specIconByClassToken[classToken] or {}
            if classIdentifier
                and type(GetNumSpecializationsForClassID) == "function"
                and type(GetSpecializationInfoForClassID) == "function"
            then
                local specCount = GetNumSpecializationsForClassID(classIdentifier) or 0
                for specIndex = 1, specCount do
                    local _, specName, _, iconTexture = GetSpecializationInfoForClassID(classIdentifier, specIndex)
                    if specName and specName ~= "" and iconTexture then
                        specIconByClassToken[classToken][NormalizeLookupKey(specName)] = iconTexture
                    end
                end
            end
        end
    end
end

local function ResolveClassToken(className)
    BuildSpecIconCache()
    local key = NormalizeLookupKey(className)
    return classTokenByKey[key] or ENGLISH_CLASS_TOKEN_BY_KEY[key]
end

local function ResolveSpecOrClassIcon(className, specName)
    local classToken = ResolveClassToken(className)
    local specKey = NormalizeLookupKey(specName)

    if classToken and specKey ~= "" then
        local iconTexture = specIconByClassToken[classToken] and specIconByClassToken[classToken][specKey]
        if iconTexture then
            return iconTexture
        end
    end

    if classToken and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classToken] then
        local coords = CLASS_ICON_TCOORDS[classToken]
        return CLASS_ICONS_TEXTURE, coords[1], coords[2], coords[3], coords[4]
    end

    return SPEC_ICON_FALLBACK, unpack(DETAIL_NAME_ICON_TEXCOORD)
end

local function GetFactionStyleKey(faction)
    local normalized = tostring(faction or ""):lower()
    if normalized == "1" or normalized:find("alliance", 1, true) then
        return "alliance"
    elseif normalized == "0" or normalized:find("horde", 1, true) then
        return "horde"
    end
    return "neutral"
end

local function GetFactionDisplayColor(faction)
    local key = GetFactionStyleKey(faction)
    if key == "alliance" then
        return unpack(DETAIL_TEXT_COLORS.alliance)
    elseif key == "horde" then
        return unpack(DETAIL_TEXT_COLORS.horde)
    end
    return unpack(DETAIL_TEXT_COLORS.default)
end

local function GetDetailRowTextColor(faction, isSelfRow)
    if isSelfRow then
        return unpack(DETAIL_TEXT_COLORS.self)
    end
    return GetFactionDisplayColor(faction)
end

local function SetDetailRowRule(line, factionStyleKey, isSelfRow)
    if not line then return end
    if not line.rowRule then
        line.rowRule = line:CreateTexture(nil, "BORDER")
        line.rowRule:SetPoint("BOTTOMLEFT", DETAIL_LEFT_PADDING - 2, 0)
        line.rowRule:SetPoint("BOTTOMRIGHT", -DETAIL_LEFT_PADDING + 2, 0)
        line.rowRule:SetHeight(1)
    end

    if factionStyleKey == "alliance" then
        if isSelfRow then
            line.rowRule:SetColorTexture(0.86, 0.92, 1.0, 0.95)
        else
            line.rowRule:SetColorTexture(0.28, 0.52, 0.92, 0.72)
        end
    elseif factionStyleKey == "horde" then
        if isSelfRow then
            line.rowRule:SetColorTexture(1.0, 0.88, 0.88, 0.95)
        else
            line.rowRule:SetColorTexture(0.84, 0.22, 0.18, 0.72)
        end
    else
        line.rowRule:SetColorTexture(0.45, 0.38, 0.18, 0.55)
    end
    line.rowRule:Show()
end

local function ColorizeWinnerText(winner)
    local text = tostring(winner or "Unknown")
    local key = GetFactionStyleKey(text)
    if key == "alliance" then
        return "|cff74B9FF" .. text .. "|r"
    elseif key == "horde" then
        return "|cffFF7666" .. text .. "|r"
    end
    return "|cffE6E6E6" .. text .. "|r"
end

local function GetSortableValue(row, field)
    if not row or not SORTABLE_FIELDS[field] then
        return 0
    end
    local def = SORTABLE_FIELDS[field]
    local ok, value = pcall(def.accessor, row)
    if not ok then
        return def.sortType == "string" and "" or 0
    end
    if def.sortType == "string" then
        return tostring(value or ""):lower()
    end
    return tonumber(value) or 0
end

local function GetStableSortKey(row)
    local name = tostring(row and row.name or ""):lower()
    local realm = tostring(row and row.realm or ""):lower()
    return name, realm
end

local function SetDetailSort(field)
    if not field or not SORTABLE_FIELDS[field] then
        return
    end
    if not WINDOW then
        return
    end
    if WINDOW.detailSortField == field then
        WINDOW.detailSortDirection = (WINDOW.detailSortDirection == "asc") and "desc" or "asc"
    else
        WINDOW.detailSortField = field
        local def = SORTABLE_FIELDS[field]
        WINDOW.detailSortDirection = (def and def.sortType == "string") and "asc" or "desc"
    end
    if WINDOW.currentView == "detail" and WINDOW.currentKey then
        ShowDetail(WINDOW.currentKey)
    end
end

local function GetHeaderFieldAtCursor(header)
    if not header then return nil end

    local x, y = GetCursorPosition()
    local scale = header:GetEffectiveScale()
    x = x / scale
    y = y / scale

    for _, columnName in ipairs(COLUMN_ORDER) do
        if SORTABLE_FIELDS[columnName] then
            local columnFS = header.columns[columnName]
            local left = columnFS and columnFS:GetLeft()
            local right = columnFS and columnFS:GetRight()
            local top = columnFS and columnFS:GetTop()
            local bottom = columnFS and columnFS:GetBottom()
            if left and right and top and bottom and x >= left and x <= right and y >= bottom and y <= top then
                return columnName
            end
        end
    end
    return nil
end

local function UpdateDetailHeaderTooltip(header)
    if not header then return end
    local hoveredField = GetHeaderFieldAtCursor(header)

    if hoveredField == header.activeTooltipField then
        return
    end

    if header.activeTooltipField then
        GameTooltip:Hide()
        header.activeTooltipField = nil
    end

    if hoveredField and DETAIL_OBJECTIVE_KEY_BY_FIELD[hoveredField] then
        local tooltipTitle = tostring(COLUMN_HEADERS[hoveredField] or "Objective")
        local tooltipBody = tostring(DETAIL_OBJECTIVE_TOOLTIP_BY_FIELD[hoveredField] or tooltipTitle)
        GameTooltip:SetOwner(header, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:SetText(tooltipTitle, 1, 0.93, 0.62)
        if tooltipBody ~= tooltipTitle then
            GameTooltip:AddLine(tooltipBody, 0.9, 0.9, 0.9, true)
        end
        GameTooltip:Show()
        header.activeTooltipField = hoveredField
    end
end

local function StyleDetailLine(line, options)
    options = options or {}

    local showDividers = options.showDividers
    if showDividers == nil then
        showDividers = false
    end

    local style = options.style
    if style and DETAIL_ROW_COLORS[style] then
        if not line.background then
            line.background = line:CreateTexture(nil, "BACKGROUND")
            line.background:SetAllPoints()
        end
        line.background:SetColorTexture(unpack(DETAIL_ROW_COLORS[style]))
        line.background:Show()
    elseif line.background then
        line.background:Hide()
    end
    local textColorKey = options.textColor or "default"
    local textColor = DETAIL_TEXT_COLORS[textColorKey] or DETAIL_TEXT_COLORS.default
    for _, columnName in ipairs(COLUMN_ORDER) do
        line.columns[columnName]:SetTextColor(unpack(textColor))
    end
    if line.specIcon then
        line.specIcon:Hide()
        line.specIcon:SetTexture(nil)
        line.specIcon:SetTexCoord(unpack(DETAIL_NAME_ICON_TEXCOORD))
    end
    if line.rowRule then
        line.rowRule:Hide()
    end

    if line.columnDividers then
        for _, divider in ipairs(line.columnDividers) do
            if showDividers then
                local dividerColor = options.dividerColor or DIVIDER_COLOR_DEFAULT
                divider:SetColorTexture(unpack(dividerColor))
                divider:Show()
            else
                divider:Hide()
            end
        end
    end
end

local function MakeDetailLine(parent, i)
    local lineFrame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    lineFrame:SetPoint("TOPLEFT", 0, -((i-1) * (LINE_HEIGHT + ROW_PADDING_Y)))
    lineFrame:SetSize(DETAIL_CONTENT_WIDTH, LINE_HEIGHT + ROW_PADDING_Y)
    
    if i == 1 then
        lineFrame.leftDivider = lineFrame:CreateTexture(nil, "BACKGROUND")
        lineFrame.leftDivider:SetColorTexture(unpack(DIVIDER_COLOR_HEADER))
        lineFrame.leftDivider:SetPoint("TOPLEFT", DETAIL_LEFT_PADDING - 6, ROW_PADDING_Y * 0.5)
        lineFrame.leftDivider:SetPoint("BOTTOMLEFT", DETAIL_LEFT_PADDING - 6, -ROW_PADDING_Y * 0.5)
        lineFrame.leftDivider:SetWidth(1)
    end

    local columns = {}
    lineFrame.columnDividers = {}

    for index, columnName in ipairs(COLUMN_ORDER) do
        local xPos = COLUMN_POSITIONS[columnName]
        local fontString = lineFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if columnName == "name" then
            local nameOffset = DETAIL_NAME_ICON_SIZE + DETAIL_NAME_ICON_TEXT_GAP
            fontString:SetPoint("TOPLEFT", xPos + nameOffset, -ROW_PADDING_Y * 0.5)
            fontString:SetSize(COLUMN_WIDTHS[columnName] - nameOffset, LINE_HEIGHT)
        else
            fontString:SetPoint("TOPLEFT", xPos, -ROW_PADDING_Y * 0.5)
            fontString:SetSize(COLUMN_WIDTHS[columnName], LINE_HEIGHT)
        end
        fontString:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        fontString:SetJustifyH(COLUMN_ALIGNMENT[columnName] or "CENTER")
        fontString:SetJustifyV("MIDDLE")
        fontString:SetWordWrap(false)
        fontString:SetTextColor(unpack(DETAIL_TEXT_COLORS.default))
        columns[columnName] = fontString

        if index < #COLUMN_ORDER then
            local divider = lineFrame:CreateTexture(nil, "BACKGROUND")
            divider:SetColorTexture(unpack(DIVIDER_COLOR_DEFAULT))
            divider:SetPoint("TOPLEFT", xPos + COLUMN_WIDTHS[columnName] + (COLUMN_GAP * 0.5), ROW_PADDING_Y * 0.35)
            divider:SetPoint("BOTTOMLEFT", xPos + COLUMN_WIDTHS[columnName] + (COLUMN_GAP * 0.5), -ROW_PADDING_Y * 0.35)
            divider:SetWidth(1)
            table.insert(lineFrame.columnDividers, divider)
        end
    end

    if lineFrame.leftDivider then
        table.insert(lineFrame.columnDividers, 1, lineFrame.leftDivider)
    end

    lineFrame.specIcon = lineFrame:CreateTexture(nil, "ARTWORK")
    lineFrame.specIcon:SetSize(DETAIL_NAME_ICON_SIZE, DETAIL_NAME_ICON_SIZE)
    lineFrame.specIcon:SetPoint(
        "CENTER",
        lineFrame,
        "TOPLEFT",
        COLUMN_POSITIONS.name + (DETAIL_NAME_ICON_SIZE * 0.5) + 1,
        -((LINE_HEIGHT + ROW_PADDING_Y) * 0.5)
    )
    lineFrame.specIcon:SetTexCoord(unpack(DETAIL_NAME_ICON_TEXCOORD))
    lineFrame.specIcon:Hide()

    lineFrame.columns = columns
    DetailLines[i] = lineFrame
    return lineFrame
end

local function MakeListButton(parent, i)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetHeight(BUTTON_HEIGHT)
	b:SetPoint("TOPLEFT", 0, -(i-1)*(BUTTON_HEIGHT + 2))
	b:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
	b:SetText("")
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
	
	b:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight", "ADD")

	local checkbox = CreateFrame("CheckButton", nil, b, "UICheckButtonTemplate")
	checkbox:SetPoint("LEFT", 6, 0)
	checkbox:SetSize(20, 20)
	checkbox:SetScript("OnClick", function(self)
		local key = self:GetParent().bgKey
		if key then
			SetLogSelected(key, self:GetChecked())
			RefreshListSelectionVisuals()
			UpdateSelectionToolbar()
		end
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	end)
	b.checkbox = checkbox

	local label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("TOPLEFT", 32, -4)
	label:SetPoint("BOTTOMRIGHT", -12, 4)
	label:SetJustifyH("CENTER")
	label:SetJustifyV("MIDDLE")
	label:SetWordWrap(true)
	label:SetMaxLines(2)
	label:SetTextColor(1, 1, 1)
	label:SetText("Loading...")
	b.label = label
	
	ListButtons[i] = b
	return b
end

---------------------------------------------------------------------
-- Renderers 
---------------------------------------------------------------------

RequestRefreshWindow = function()
	if not RefreshWindow then return end
	if InCombatLockdown and InCombatLockdown() then
		pendingRefresh = true
		return
	end
	pendingRefresh = false
	RefreshWindow()
end

RefreshWindow = function()
    if not WINDOW or not WINDOW:IsShown() then return end
	
	SaveFilterState()
	
	RefreshFilterDropdowns()
	UpdateStatBar()
    
    if WINDOW.currentView == "detail" and WINDOW.currentKey then
        ShowDetail(WINDOW.currentKey)
    else
        ShowList()
    end
end

function ShowList()
    
    WINDOW.currentView = "list"
    WINDOW.currentKey = nil
	UpdateStatBar()
    
    WINDOW.detailScroll:Hide()
    if WINDOW.detailBackdrop then
        WINDOW.detailBackdrop:Hide()
    end
    WINDOW.backBtn:Hide()
    WINDOW.listScroll:Show()
	WINDOW.currentEntries = nil
	if WINDOW.exportBtn then WINDOW.exportBtn:Hide() end
	UpdateSelectionToolbar()
    
    for _, btn in ipairs(ListButtons) do
        btn:Hide()
        btn:SetScript("OnClick", nil)
    end
    
    local entries = {}
    for k, v in pairs(BGLoggerDB) do
        if type(v) == "table" and v.mapID and v.stats then
			if LogMatchesFilters(v) then
				table.insert(entries, {key = k, data = v})
			end
        end
    end
    
	table.sort(entries, function(a, b)
        if a.data.dateISO and b.data.dateISO then
            return a.data.dateISO > b.data.dateISO
        end
        
        if a.data.endTime and b.data.endTime then
            return a.data.endTime > b.data.endTime
        end
        
        return a.key > b.key
    end)
    
	WINDOW.currentEntries = entries
	PruneInvalidSelections(entries)
    
    for i, entry in ipairs(entries) do
        local btn = ListButtons[i] or MakeListButton(WINDOW.listContent, i)
        local k, data = entry.key, entry.data
        
        local mapInfo = C_Map.GetMapInfo(data.mapID or 0)
        local mapName = (mapInfo and mapInfo.name) or "Unknown Map"
        
        local dateDisplay = ""
        if data.dateISO then
            local year, month, day, hour, min, sec = data.dateISO:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
            if year then
                dateDisplay = string.format("%s/%s/%s %s:%s", month, day, year:sub(3,4), hour, min)
            else
                dateDisplay = data.ended or "Unknown time"
            end
        elseif data.ended then
            dateDisplay = data.ended
        else
            dateDisplay = "Unknown time"
        end
        
        local durationText = ""
        if data.duration then
            local minutes = math.floor(data.duration / 60)
            local seconds = data.duration % 60
            durationText = string.format(" (%d:%02d)", minutes, seconds)
        end
        
        local winnerText = ""
        if data.winner and data.winner ~= "" then
            winnerText = " - " .. data.winner .. " Won"
        end
        
		local personalLine = BuildPersonalSummaryLine(data)

		local displayText = string.format("%s%s - %s\n%s", mapName, durationText, dateDisplay, personalLine)
		if btn.label then
			btn.label:SetText(displayText)
		else
			btn:SetText(displayText)
		end
        btn.bgKey = k
        
		btn:SetScript("OnClick", function(self, button) 
			if button == "LeftButton" and IsShiftKeyDown() and self.bgKey then
				SetLogSelected(self.bgKey, not IsLogSelected(self.bgKey))
				RefreshListSelectionVisuals()
				UpdateSelectionToolbar()
				return
			end
			ShowDetail(self.bgKey) 
        end)
		local isSelected = IsLogSelected(k)
		if btn.checkbox then
			btn.checkbox:SetChecked(isSelected)
		end
		if isSelected then
			btn.bg:SetColorTexture(0.13, 0.35, 0.18, 0.85)
		else
			btn.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
		end
        
        btn:Show()
    end
    
    for i = #entries + 1, #ListButtons do
        ListButtons[i]:Hide()
    end
    
    local contentHeight = #entries * (BUTTON_HEIGHT + 2)
    WINDOW.listContent:SetHeight(math.max(contentHeight, 10))
	RefreshListSelectionVisuals()
	UpdateSelectionToolbar()
end

function ShowDetail(key)
    
    WINDOW.currentView = "detail"
    WINDOW.currentKey = key
	UpdateSelectionToolbar()
    
    WINDOW.listScroll:Hide()
    WINDOW.detailScroll:Show()
    if WINDOW.detailBackdrop then
        WINDOW.detailBackdrop:Show()
    end
    WINDOW.backBtn:Show()
    if WINDOW.exportBtn then WINDOW.exportBtn:Show() end
    
    for i = 1, #DetailLines do
        if DetailLines[i] then
            if DetailLines[i].columns then
                for _, column in pairs(DetailLines[i].columns) do
                    column:SetText("")
                end
            else
                DetailLines[i]:SetText("")
            end
            if DetailLines[i].fullWidthText then
                DetailLines[i].fullWidthText:SetText("")
                DetailLines[i].fullWidthText:Hide()
            end
            if DetailLines[i].columnDividers then
                for _, divider in ipairs(DetailLines[i].columnDividers) do
                    divider:Show()
                end
            end
            DetailLines[i]:Hide()
        end
    end

    local maxLinesToClear = math.max(50, #DetailLines)
    for i = 1, maxLinesToClear do
        if DetailLines[i] then
            if DetailLines[i].columns then
                for _, column in pairs(DetailLines[i].columns) do
                    column:SetText("")
                end
            else
                DetailLines[i]:SetText("")
            end
            if DetailLines[i].fullWidthText then
                DetailLines[i].fullWidthText:SetText("")
                DetailLines[i].fullWidthText:Hide()
            end
            if DetailLines[i].columnDividers then
                for _, divider in ipairs(DetailLines[i].columnDividers) do
                    divider:Show()
                end
            end
            DetailLines[i]:Hide()
        end
    end
    
    if not BGLoggerDB[key] then
        local line = DetailLines[1] or MakeDetailLine(WINDOW.detailContent, 1)
        line.columns.name:SetText("No data found for this battleground")
        for columnName, column in pairs(line.columns) do
            if columnName ~= "name" then
                column:SetText("")
            end
        end
        if line.specIcon then
            line.specIcon:Hide()
        end
        line:Show()
        WINDOW.detailContent:SetHeight(LINE_HEIGHT + ROW_PADDING_Y)
        return
    end
    
    local data = BGLoggerDB[key]
    local recorderKeyLookup = {}
    for _, recorderKey in ipairs(GetRecorderKeys(data)) do
        recorderKeyLookup[NormalizeKey(recorderKey)] = true
    end
    local mapInfo = C_Map.GetMapInfo(data.mapID or 0)
    local mapName = data.battlegroundName or ((mapInfo and mapInfo.name) or "Unknown Map")

    ConfigureDetailColumnsForLog(data, mapName)
    
    local headerInfo = DetailLines[1] or MakeDetailLine(WINDOW.detailContent, 1)
    StyleDetailLine(headerInfo, { style = "header", textColor = "header", dividerColor = DIVIDER_COLOR_HEADER })
    
    local durationText = data.duration and (math.floor(data.duration / 60) .. ":" .. string.format("%02d", data.duration % 60)) or "Unknown"
    local winnerText = ColorizeWinnerText(data.winner or "Unknown")
    local bgType = tostring(data.type or "Unknown")
    local bgInfo = string.format(
        "Battleground: |cffE6D7AE%s|r   Duration: |cffF2F2F2%s|r   Winner: %s   Type: |cffE6D7AE%s|r",
        mapName,
        durationText,
        winnerText,
        bgType
    )
    
    if data.joinedInProgress then
        bgInfo = bgInfo .. "   |cffffb84fJOINED IN-PROGRESS|r"
    end
    
    if not headerInfo.fullWidthText then
        headerInfo.fullWidthText = headerInfo:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        headerInfo.fullWidthText:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
        headerInfo.fullWidthText:SetPoint("TOPLEFT", DETAIL_LEFT_PADDING, -ROW_PADDING_Y * 0.5)
        headerInfo.fullWidthText:SetPoint("TOPRIGHT", -DETAIL_LEFT_PADDING, -ROW_PADDING_Y * 0.5)
        headerInfo.fullWidthText:SetHeight(LINE_HEIGHT)
        headerInfo.fullWidthText:SetJustifyH("LEFT")
        headerInfo.fullWidthText:SetJustifyV("MIDDLE")
        headerInfo.fullWidthText:SetWordWrap(false)
    end
    headerInfo.fullWidthText:SetText(bgInfo)
    headerInfo.fullWidthText:SetTextColor(unpack(DETAIL_TEXT_COLORS.header))
    headerInfo.fullWidthText:Show()
    
    for columnName, column in pairs(headerInfo.columns) do
        column:SetText("")
    end
    if headerInfo.columnDividers then
        for _, divider in ipairs(headerInfo.columnDividers) do
            divider:Hide()
        end
    end
    headerInfo:Show()
    
    local separator1 = DetailLines[2] or MakeDetailLine(WINDOW.detailContent, 2)
    StyleDetailLine(separator1, { style = "section", showDividers = false })
    if not separator1.dividerTexture then
        separator1.dividerTexture = separator1:CreateTexture(nil, "BACKGROUND")
        separator1.dividerTexture:SetColorTexture(0.55, 0.43, 0.16, 0.75)
        separator1.dividerTexture:SetPoint("TOPLEFT", DETAIL_LEFT_PADDING - 4, -ROW_PADDING_Y)
        separator1.dividerTexture:SetPoint("BOTTOMRIGHT", -DETAIL_LEFT_PADDING + 4, ROW_PADDING_Y)
    end
    separator1.dividerTexture:Show()
    for _, column in pairs(separator1.columns) do
        column:SetText("")
    end
    separator1:Show()
    
    local header = DetailLines[3] or MakeDetailLine(WINDOW.detailContent, 3)
    StyleDetailLine(header, { style = "header", textColor = "header", dividerColor = DIVIDER_COLOR_HEADER })
    header:EnableMouse(true)

    for _, columnName in ipairs(COLUMN_ORDER) do
        local label = COLUMN_HEADERS[columnName] or ""
        local isObjectiveColumn = DETAIL_OBJECTIVE_KEY_BY_FIELD[columnName] ~= nil
        header.columns[columnName]:SetWordWrap(isObjectiveColumn)
        header.columns[columnName]:SetJustifyV("MIDDLE")
        header.columns[columnName]:SetFont("Fonts\\FRIZQT__.TTF", isObjectiveColumn and 10 or 11, "")
        if SORTABLE_FIELDS[columnName] then
            local arrow = ""
            if WINDOW.detailSortField == columnName then
                arrow = WINDOW.detailSortDirection == "asc" and " [^]" or " [v]"
            end
            header.columns[columnName]:SetText(label .. arrow)
            header.columns[columnName]:SetJustifyH("CENTER")
            header.columns[columnName]:SetTextColor(unpack(DETAIL_TEXT_COLORS.header))
            header:SetScript("OnMouseUp", nil)
        else
            header.columns[columnName]:SetText(label)
        end
    end

    header:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        local clickedField = GetHeaderFieldAtCursor(self)
        if clickedField then
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            SetDetailSort(clickedField)
        end
    end)
    header:SetScript("OnEnter", function(self)
        self:SetScript("OnUpdate", function(frame)
            UpdateDetailHeaderTooltip(frame)
        end)
        UpdateDetailHeaderTooltip(self)
    end)
    header:SetScript("OnLeave", function(self)
        self:SetScript("OnUpdate", nil)
        if self.activeTooltipField then
            GameTooltip:Hide()
            self.activeTooltipField = nil
        end
    end)
    header:SetScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
        if self.activeTooltipField then
            GameTooltip:Hide()
            self.activeTooltipField = nil
        end
    end)

    header:Show()
    
    local separator2 = DetailLines[4] or MakeDetailLine(WINDOW.detailContent, 4)
    StyleDetailLine(separator2, { style = "section", showDividers = false })
    if not separator2.dividerTexture then
        separator2.dividerTexture = separator2:CreateTexture(nil, "BACKGROUND")
        separator2.dividerTexture:SetColorTexture(0.42, 0.33, 0.12, 0.68)
        separator2.dividerTexture:SetPoint("TOPLEFT", DETAIL_LEFT_PADDING - 4, -ROW_PADDING_Y)
        separator2.dividerTexture:SetPoint("BOTTOMRIGHT", -DETAIL_LEFT_PADDING + 4, ROW_PADDING_Y)
    end
    separator2.dividerTexture:Show()
    for _, column in pairs(separator2.columns) do
        column:SetText("")
    end
    separator2:Show()
    
    local rows = data.stats or {}
    local regularPlayers = rows

    if WINDOW.detailSortField and SORTABLE_FIELDS[WINDOW.detailSortField] then
        table.sort(regularPlayers, function(a, b)
            local aValue = GetSortableValue(a, WINDOW.detailSortField)
            local bValue = GetSortableValue(b, WINDOW.detailSortField)
            local aName, aRealm = GetStableSortKey(a)
            local bName, bRealm = GetStableSortKey(b)
            if WINDOW.detailSortDirection == "asc" then
                if aValue == bValue then
                    if aName == bName then
                        return aRealm < bRealm
                    end
                    return aName < bName
                end
                return aValue < bValue
            else
                if aValue == bValue then
                    if aName == bName then
                        return aRealm < bRealm
                    end
                    return aName < bName
                end
                return aValue > bValue
            end
        end)
    end
    
    for i, row in ipairs(regularPlayers) do
        local line = DetailLines[i+4] or MakeDetailLine(WINDOW.detailContent, i+4)
        local participationUnknown = row.participationUnknown or false
        local factionStyleKey = GetFactionStyleKey(row.faction or row.side)
        local styleKey
        if factionStyleKey == "alliance" then
            styleKey = (i % 2 == 0) and "allianceEven" or "allianceOdd"
        elseif factionStyleKey == "horde" then
            styleKey = (i % 2 == 0) and "hordeEven" or "hordeOdd"
        elseif participationUnknown then
            styleKey = "unknown"
        else
            styleKey = (i % 2 == 0) and "even" or "odd"
        end
        
        local damage = row.damage or row.dmg or 0
        local healing = row.healing or row.heal or 0
        local kills = row.kills or row.killingBlows or row.kb or 0
        local deaths = row.deaths or 0
        local honorableKills = row.honorableKills or row.honorKills or 0
        local realm = row.realm or "Unknown"
        local class = row.class or "Unknown"
        local spec = row.spec or "Unknown"
        local faction = row.faction or row.side or "Unknown"
        local rowKey = GetPlayerKey(row.name or "Unknown", NormalizeRealmName(realm or ""))
        local isSelfRow = recorderKeyLookup[NormalizeKey(rowKey)] == true
        
        local damageText = damage >= 1000000 and string.format("%.1fM", damage/1000000) or 
                          damage >= 1000 and string.format("%.0fK", damage/1000) or tostring(damage)
        local healingText = healing >= 1000000 and string.format("%.1fM", healing/1000000) or 
                           healing >= 1000 and string.format("%.0fK", healing/1000) or tostring(healing)
        
        local displayName = row.name or "Unknown"
        if realm and realm ~= "" and realm ~= "Unknown" and realm ~= "Unknown-Realm" then
            displayName = string.format("%s-%s", displayName, realm)
        end
        line.columns.name:SetText(displayName)
        line.columns.spec:SetText(spec)
        line.columns.faction:SetText(faction)
        line.columns.damage:SetText(damageText)
        line.columns.healing:SetText(healingText)
        line.columns.kills:SetText(tostring(kills))
        line.columns.deaths:SetText(tostring(deaths))
        line.columns.hk:SetText(tostring(honorableKills))
        for _, objectiveColumn in ipairs(DETAIL_OBJECTIVE_COLUMNS) do
            local objectiveValue = 0
            if type(row.objectiveBreakdown) == "table" then
                objectiveValue = tonumber(row.objectiveBreakdown[objectiveColumn.key]) or 0
            end
            if objectiveColumn.key == "objectives" and objectiveValue == 0 then
                objectiveValue = tonumber(row.objectives) or 0
            end
            line.columns[objectiveColumn.field]:SetText(tostring(objectiveValue))
        end
            
        StyleDetailLine(line, { style = styleKey, textColor = participationUnknown and "unknown" or "default" })
        local textR, textG, textB
        if factionStyleKey == "neutral" and participationUnknown then
            textR, textG, textB = unpack(DETAIL_TEXT_COLORS.unknown)
        else
            textR, textG, textB = GetDetailRowTextColor(faction, isSelfRow)
        end
        for _, columnName in ipairs(COLUMN_ORDER) do
            line.columns[columnName]:SetTextColor(textR, textG, textB)
        end
        SetDetailRowRule(line, factionStyleKey, isSelfRow)

        local iconTexture, left, right, top, bottom = ResolveSpecOrClassIcon(class, spec)
        if line.specIcon then
            line.specIcon:SetTexture(iconTexture or SPEC_ICON_FALLBACK)
            if left and right and top and bottom then
                line.specIcon:SetTexCoord(left, right, top, bottom)
            else
                line.specIcon:SetTexCoord(unpack(DETAIL_NAME_ICON_TEXCOORD))
            end
            line.specIcon:Show()
        end

        line.columns.name:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        line:Show()
    end
    
    local summaryLine = DetailLines[#regularPlayers+5] or MakeDetailLine(WINDOW.detailContent, #regularPlayers+5)
    StyleDetailLine(summaryLine, { style = "summary", showDividers = false })
    if not summaryLine.dividerTexture then
        summaryLine.dividerTexture = summaryLine:CreateTexture(nil, "BACKGROUND")
        summaryLine.dividerTexture:SetColorTexture(0.40, 0.31, 0.12, 0.66)
        summaryLine.dividerTexture:SetPoint("TOPLEFT", DETAIL_LEFT_PADDING - 4, -ROW_PADDING_Y)
        summaryLine.dividerTexture:SetPoint("BOTTOMRIGHT", -DETAIL_LEFT_PADDING + 4, ROW_PADDING_Y)
    end
    summaryLine.dividerTexture:Show()
    for _, column in pairs(summaryLine.columns) do
        column:SetText("")
    end
    summaryLine:Show()

    local totalLine = DetailLines[#regularPlayers+6] or MakeDetailLine(WINDOW.detailContent, #regularPlayers+6)
    local totalDamage, totalHealing, totalKills, totalDeaths = 0, 0, 0, 0
    local objectiveTotals = {}
    
    for _, row in ipairs(regularPlayers) do
        totalDamage = totalDamage + (row.damage or row.dmg or 0)
        totalHealing = totalHealing + (row.healing or row.heal or 0)
        totalKills = totalKills + (row.kills or row.killingBlows or row.kb or 0)
        totalDeaths = totalDeaths + (row.deaths or 0)
        for _, objectiveColumn in ipairs(DETAIL_OBJECTIVE_COLUMNS) do
            local objectiveValue = 0
            if type(row.objectiveBreakdown) == "table" then
                objectiveValue = tonumber(row.objectiveBreakdown[objectiveColumn.key]) or 0
            end
            if objectiveColumn.key == "objectives" and objectiveValue == 0 then
                objectiveValue = tonumber(row.objectives) or 0
            end
            objectiveTotals[objectiveColumn.field] = (objectiveTotals[objectiveColumn.field] or 0) + objectiveValue
        end
    end
    
    local totalDamageText = totalDamage >= 1000000 and string.format("%.1fM", totalDamage/1000000) or 
                           totalDamage >= 1000 and string.format("%.0fK", totalDamage/1000) or tostring(totalDamage)
    local totalHealingText = totalHealing >= 1000000 and string.format("%.1fM", totalHealing/1000000) or 
                            totalHealing >= 1000 and string.format("%.0fK", totalHealing/1000) or tostring(totalHealing)
    
    totalLine.columns.name:SetText("TOTALS (" .. #regularPlayers .. " players)")
    totalLine.columns.spec:SetText("")
    totalLine.columns.faction:SetText("")
    totalLine.columns.damage:SetText(totalDamageText)
    totalLine.columns.healing:SetText(totalHealingText)
    totalLine.columns.kills:SetText(tostring(totalKills))
    totalLine.columns.deaths:SetText(tostring(totalDeaths))
    totalLine.columns.hk:SetText("")
    for _, objectiveColumn in ipairs(DETAIL_OBJECTIVE_COLUMNS) do
        local totalObjectiveValue = objectiveTotals[objectiveColumn.field] or 0
        totalLine.columns[objectiveColumn.field]:SetText(tostring(totalObjectiveValue))
    end
    
    StyleDetailLine(totalLine, { style = "totals", textColor = "totals" })
    totalLine:Show()
    
    local currentLineIndex = #regularPlayers + 7
    
    for i = currentLineIndex, #DetailLines do
        if DetailLines[i] then
            DetailLines[i]:Hide()
        end
    end

    WINDOW.detailContent:SetHeight(math.max((currentLineIndex-1)*(LINE_HEIGHT + ROW_PADDING_Y), 10))
end

---------------------------------------------------------------------
-- Window - completely rebuilt
---------------------------------------------------------------------
local function CreateWindow()
    
    local f = CreateFrame("Frame", "BGLoggerWindow", UIParent, "BackdropTemplate")
    f:SetSize(WIN_W, WIN_H)
    f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = {left = 8, right = 8, top = 8, bottom = 8}
    })
    
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    
    f:SetPropagateKeyboardInput(true)
    f:EnableKeyboard(true)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
        end
    end)
    
    f:SetScript("OnShow", function(self)
        self:EnableKeyboard(true)
    end)
    
    f:SetScript("OnHide", function(self)
        self:EnableKeyboard(false)
    end)
    
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Battleground Statistics")
    
    StaticPopupDialogs["BGLOGGER_DELETE_SELECTED"] = {
        text = "Delete selected logs? This cannot be undone.",
        button1 = YES,
        button2 = NO,
        OnAccept = function()
            if type(pendingDeleteKeys) ~= "table" or #pendingDeleteKeys == 0 then
                return
            end
            for _, key in ipairs(pendingDeleteKeys) do
                BGLoggerDB[key] = nil
            end
            pendingDeleteKeys = nil
            ClearAllSelections()
            RequestRefreshWindow()
        end,
        OnCancel = function()
            pendingDeleteKeys = nil
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true
    }
    
    local deleteSelectedBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    deleteSelectedBtn:SetSize(120, 22)
    deleteSelectedBtn:SetPoint("TOPRIGHT", -80, -40)
    deleteSelectedBtn:SetText("Delete Selected")
    deleteSelectedBtn:SetScript("OnClick", DeleteSelectedFromList)
    deleteSelectedBtn:Hide()
    f.deleteSelectedBtn = deleteSelectedBtn
    
    local backBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    backBtn:SetSize(60, 22)
    backBtn:SetPoint("TOPLEFT", 20, -40)
    backBtn:SetText("<- Back")
    backBtn:SetScript("OnClick", ShowList)
    backBtn:Hide()
    f.backBtn = backBtn

	local selectAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	selectAllBtn:SetSize(90, 22)
	selectAllBtn:SetPoint("LEFT", backBtn, "RIGHT", 10, 0)
	selectAllBtn:SetText("Select All")
	selectAllBtn:SetScript("OnClick", ToggleSelectAllEntries)
	selectAllBtn:Hide()
	f.selectAllBtn = selectAllBtn

	local selectionStatusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	selectionStatusText:SetPoint("LEFT", selectAllBtn, "RIGHT", 10, 0)
	selectionStatusText:SetText("Selected: 0")
	selectionStatusText:Hide()
	f.selectionStatusText = selectionStatusText
    
	local filterBar = CreateFrame("Frame", nil, f)
	filterBar:SetPoint("TOPLEFT", 20, -64)
	filterBar:SetPoint("TOPRIGHT", -20, -64)
	filterBar:SetHeight(26)

	local seasonLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	seasonLabel:SetPoint("LEFT", 0, 0)
	seasonLabel:SetText("Season:")
	local seasonDropdown = CreateFrame("Frame", "BGLoggerSeasonDropdown", filterBar, "UIDropDownMenuTemplate")
	seasonDropdown:SetPoint("LEFT", seasonLabel, "RIGHT", 4, -2)

	local characterLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	characterLabel:SetPoint("LEFT", seasonDropdown, "RIGHT", 12, 2)
	characterLabel:SetText("Character:")
	local characterDropdown = CreateFrame("Frame", "BGLoggerCharacterDropdown", filterBar, "UIDropDownMenuTemplate")
	characterDropdown:SetPoint("LEFT", characterLabel, "RIGHT", 4, -2)

	local bgTypeLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	bgTypeLabel:SetPoint("LEFT", characterDropdown, "RIGHT", 12, 2)
	bgTypeLabel:SetText("BG Type:")
	local bgTypeDropdown = CreateFrame("Frame", "BGLoggerBgTypeDropdown", filterBar, "UIDropDownMenuTemplate")
	bgTypeDropdown:SetPoint("LEFT", bgTypeLabel, "RIGHT", 4, -2)

	local mapLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	mapLabel:SetPoint("LEFT", bgTypeDropdown, "RIGHT", 12, 2)
	mapLabel:SetText("Map:")
	local mapDropdown = CreateFrame("Frame", "BGLoggerMapDropdown", filterBar, "UIDropDownMenuTemplate")
	mapDropdown:SetPoint("LEFT", mapLabel, "RIGHT", 4, -2)

	local resetFiltersBtn = CreateFrame("Button", nil, filterBar, "UIPanelButtonTemplate")
	resetFiltersBtn:SetSize(90, 20)
	resetFiltersBtn:SetPoint("LEFT", mapDropdown, "RIGHT", 20, 2)
	resetFiltersBtn:SetText("Reset Filters")
	resetFiltersBtn:SetScript("OnClick", function()
		ResetFilters()
		RequestRefreshWindow()
	end)

	f.filterBar = filterBar
	f.seasonDropdown = seasonDropdown
	f.characterDropdown = characterDropdown
	f.bgTypeDropdown = bgTypeDropdown
	f.mapDropdown = mapDropdown
	f.resetFiltersBtn = resetFiltersBtn
    
	local statBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
	statBar:SetPoint("TOPLEFT", filterBar, "BOTTOMLEFT", 0, -6)
	statBar:SetPoint("TOPRIGHT", filterBar, "BOTTOMRIGHT", 0, -6)
	statBar:SetHeight(26)
	statBar:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = false, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 }
	})
	statBar:SetBackdropColor(0, 0, 0, 0.3)
	statBar:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.8)

	local statText = statBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	statText:SetPoint("LEFT", 10, 0)
	statText:SetPoint("RIGHT", -10, 0)
	statText:SetJustifyH("LEFT")
	statText:SetText("Account stats: collecting...")

	f.statBar = statBar
	f.statBarText = statText
    
    local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refreshBtn:SetSize(80, 22)
    refreshBtn:SetPoint("TOPRIGHT", deleteSelectedBtn, "TOPLEFT", -10, 0)
    refreshBtn:SetText("Refresh")
    refreshBtn:SetScript("OnClick", RequestRefreshWindow)

    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetSize(80, 22)
    exportBtn:SetPoint("TOPRIGHT", refreshBtn, "TOPLEFT", -10, 0)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", function()
        if WINDOW.currentView == "detail" and WINDOW.currentKey then
            ExportBattleground(WINDOW.currentKey)
        end
    end)
    exportBtn:Hide()
    f.exportBtn = exportBtn

	local exportSelectedBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	exportSelectedBtn:SetSize(140, 22)
	exportSelectedBtn:SetPoint("TOPRIGHT", exportBtn, "TOPLEFT", -10, 0)
	exportSelectedBtn:SetText("Export Selected")
	exportSelectedBtn:SetScript("OnClick", ExportSelectedFromList)
	exportSelectedBtn:Hide()
	f.exportSelectedBtn = exportSelectedBtn
    
    local listScroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", statBar, "BOTTOMLEFT", 0, -10)
    listScroll:SetPoint("BOTTOMRIGHT", -30, 20)
    
    local listContent = CreateFrame("Frame", nil, listScroll)
    listContent:SetSize(listScroll:GetWidth() - 16, 10)
    listScroll:SetScrollChild(listContent)
    
    local detailScroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    detailScroll:SetPoint("TOPLEFT", statBar, "BOTTOMLEFT", 0, -10)
    detailScroll:SetPoint("BOTTOMRIGHT", -30, 20)
    detailScroll:Hide()
    local detailBackdrop = CreateFrame("Frame", nil, f, "BackdropTemplate")
    detailBackdrop:SetPoint("TOPLEFT", detailScroll, "TOPLEFT", -2, 2)
    detailBackdrop:SetPoint("BOTTOMRIGHT", detailScroll, "BOTTOMRIGHT", 2, -2)
    detailBackdrop:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    detailBackdrop:SetBackdropColor(0.02, 0.02, 0.04, 0.88)
    detailBackdrop:SetBackdropBorderColor(0.45, 0.35, 0.12, 0.88)
    detailBackdrop:SetFrameLevel(math.max(0, detailScroll:GetFrameLevel() - 1))
    detailBackdrop:Hide()
    
    local detailContent = CreateFrame("Frame", nil, detailScroll)
    detailContent:SetSize(detailScroll:GetWidth() - 16, 10)
    detailScroll:SetScrollChild(detailContent)
    
    f.listScroll = listScroll
    f.listContent = listContent
    f.detailScroll = detailScroll
    f.detailContent = detailContent
    f.detailBackdrop = detailBackdrop
    f.currentView = "list"
    
    f:Hide()
    return f
end

---------------------------------------------------------------------
-- Minimap Button
---------------------------------------------------------------------
local MinimapButton = {}

local function CreateMinimapButton()
    local button = CreateFrame("Button", "BGLoggerMinimapButton", Minimap)
    button:SetFrameStrata("MEDIUM")
    button:SetSize(32, 32)
    button:SetFrameLevel(8)
    button:RegisterForClicks("anyUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture(136477)
    
    local playerFaction = UnitFactionGroup("player")
    local iconTexture = ""
    
    if playerFaction == "Alliance" then
        iconTexture = "Interface\\Icons\\PVPCurrency-Honor-Alliance"
    elseif playerFaction == "Horde" then
        iconTexture = "Interface\\Icons\\PVPCurrency-Honor-Horde"
    else
        iconTexture = "Interface\\Icons\\Achievement-pvp-legion03"
    end
    
    
    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(iconTexture)
    button.icon = icon
    
    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetPoint("TOPLEFT", 0, 0)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    
    local function UpdatePosition()
        local angle = BGLoggerDB.minimapPos or 45
        local radius = 105
        local x = math.cos(math.rad(angle)) * radius
        local y = math.sin(math.rad(angle)) * radius
        button:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end
    
    button:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "LeftButton" then
            if not WINDOW then
                WINDOW = CreateWindow()
            end
            
            if WINDOW:IsShown() then
                WINDOW:Hide()
            else
                WINDOW:Show()
                C_Timer.After(0.1, RequestRefreshWindow)
            end
        end
    end)
    
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(self)
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px, py = px / scale, py / scale
            
            local angle = math.deg(math.atan2(py - my, px - mx))
            if angle < 0 then
                angle = angle + 360
            end
            
            BGLoggerDB.minimapPos = angle
            UpdatePosition()
        end)
    end)
    
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("BGLogger", 1, 1, 1)
        GameTooltip:AddLine("Left Click: Open/Close BGLogger", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Drag: Reposition button", 0.7, 0.7, 0.7)
        
        if insideBG then
            local timeSinceStart = GetTime() - bgStartTime
            GameTooltip:AddLine(" ", 1, 1, 1)
            GameTooltip:AddLine("In Battleground", 0, 1, 0)
            GameTooltip:AddLine("Time: " .. math.floor(timeSinceStart) .. "s", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Saved: " .. (matchSaved and "Yes" or "No"), 0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine(" ", 1, 1, 1)
            GameTooltip:AddLine("Not in Battleground", 0.7, 0.7, 0.7)
        end
        
        GameTooltip:Show()
    end)
    
    button:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
    
    MinimapButton.button = button
    UpdatePosition()
    
    return button
end

local function SetMinimapButtonShown(show)
    if show then
        if not MinimapButton.button then
            MinimapButton.button = CreateMinimapButton()
        end
        MinimapButton.button:Show()
        BGLoggerDB.minimapButton = true
    else
        if MinimapButton.button then
            MinimapButton.button:Hide()
        end
        BGLoggerDB.minimapButton = false
    end
end

---------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------
SLASH_BGLOGGER1 = "/bglogger"
SlashCmdList.BGLOGGER = function()
    
    if not WINDOW then
        WINDOW = CreateWindow()
    end
    
    if WINDOW:IsShown() then
        WINDOW:Hide()
    else
        WINDOW:Show()
        
        C_Timer.After(0.1, RequestRefreshWindow)
    end
end

C_Timer.After(0.5, function()
    RestoreFilterState()
end)

---------------------------------------------------------------------
-- Event driver
---------------------------------------------------------------------

local Driver = CreateFrame("Frame")

Driver:RegisterEvent("ADDON_LOADED")
Driver:RegisterEvent("PLAYER_ENTERING_WORLD")
Driver:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
Driver:RegisterEvent("PLAYER_LEAVING_WORLD")
Driver:RegisterEvent("ZONE_CHANGED_NEW_AREA")
Driver:RegisterEvent("CHAT_MSG_BG_SYSTEM_NEUTRAL")
Driver:RegisterEvent("PLAYER_REGEN_ENABLED")

local additionalEvents = {
    "PVP_MATCH_COMPLETE",
    "PVP_MATCH_STATE_CHANGED",
    "CHAT_MSG_BG_SYSTEM_ALLIANCE",
    "CHAT_MSG_BG_SYSTEM_HORDE",
    "UPDATE_BATTLEFIELD_STATUS"
}

for _, eventName in ipairs(additionalEvents) do
    local success, err = pcall(function()
        Driver:RegisterEvent(eventName)
    end)
end

Driver:SetScript("OnEvent", function(_, e, ...)
    local newBGStatus = UpdateBattlegroundStatus()
    local statusChanged = (newBGStatus ~= insideBG)
    
    if e == "PLAYER_REGEN_ENABLED" then
        if pendingRefresh then
            RequestRefreshWindow()
        end
        return
    end

	if e == "ADDON_LOADED" then
		local addonName = ...
		if addonName ~= "BGLogger" then return end

		-- Retire legacy initial-roster persistence data.
		BGLoggerActiveMatch = nil
		return
	end
    
    if e == "PLAYER_ENTERING_WORLD" then
		RegisterCurrentCharacter()
		
    local wasInBG = insideBG
    insideBG = newBGStatus
    
        if insideBG and (not wasInBG or bgStartTime == 0) then
            local restoredState = TryRestoreMatchState()
            if restoredState then
            else
                bgStartTime = GetTime()
                matchSaved = false
                saveInProgress = false
                ResetPlayerTracker()
            end

            StartStatePersistence()

            local function CheckInProgress(attempt)
                attempt = attempt or 1
                if not insideBG then return end
                if playerTracker and playerTracker.battleHasBegun then
                    return
                end
                    local isInProgressBG = false
                    local detectionMethod = "none"

                RequestBattlefieldScoreData()

                C_Timer.After(0.6, function()
                    if not insideBG then return end
                    if playerTracker and playerTracker.battleHasBegun then
                        return
                    end
                    
                    do
                        local apiDuration = GetCurrentMatchDuration() or 0
                        local timeInside = (bgStartTime and bgStartTime > 0) and (GetTime() - bgStartTime) or 0
                        local durationDelta = apiDuration - timeInside

                        if timeInside <= 15 and apiDuration >= 120 and durationDelta >= 60 then
                            isInProgressBG = true
                            detectionMethod = string.format("API_duration_%ss_delta_%s", tostring(apiDuration), tostring(math.floor(durationDelta)))
                        end
                    end
                    
                    
                    if isInProgressBG then
                        
                        playerTracker.joinedInProgress = true
                        playerTracker.battleHasBegun = true
                        playerTracker.playerJoinedInProgress = true
                        FlagStateDirty()
                        return
                    end

                    local epic = IsEpicBattleground()
                    local maxAttempts = epic and 6 or 4
                    local delays = epic and { 2, 6, 12, 20, 30, 45 } or { 2, 5, 10, 15 }
                    if attempt < maxAttempts then
                        local nextDelay = delays[attempt + 1] or 10
                        C_Timer.After(nextDelay, function() 
                            if playerTracker and playerTracker.battleHasBegun then
                                return
                            end
                            CheckInProgress(attempt + 1) 
                        end)
                end
            end)
            end
            C_Timer.After(2, function() 
                if playerTracker and playerTracker.battleHasBegun then
                    return
                end
                CheckInProgress(1) 
            end)
            
    C_Timer.After(90, function()
        if insideBG and not playerTracker.battleHasBegun then
            playerTracker.battleHasBegun = true
            FlagStateDirty()
        end
    end)
            
        elseif not insideBG and wasInBG then
            bgStartTime = 0
            matchSaved = false
            saveInProgress = false
            ResetPlayerTracker()
            StopStatePersistence()
            ClearSessionState("left battleground")
        elseif not insideBG then
            bgStartTime = 0
            matchSaved = false
            saveInProgress = false
            ResetPlayerTracker()
            StopStatePersistence()
            ClearSessionState("world load outside BG")
        end

    elseif (e == "CHAT_MSG_BG_SYSTEM_NEUTRAL" or e == "CHAT_MSG_BG_SYSTEM_ALLIANCE" or e == "CHAT_MSG_BG_SYSTEM_HORDE") and insideBG then
        local message = ...
        
        if message and not playerTracker.battleHasBegun then
            local lowerMsg = message:lower()
            local isBattleStartMessage = (lowerMsg:find("battle has begun") or 
                                         lowerMsg:find("let the battle begin") or
                                         lowerMsg:find("the battle begins") or
                                         lowerMsg:find("gates are open") or
                                         lowerMsg:find("the battle for .* has begun") or
                                         lowerMsg:find("begin!") or
                                         (lowerMsg:find("go") and lowerMsg:find("go") and lowerMsg:find("go")))
            
            local isPreparationMessage = (lowerMsg:find("prepare") or 
                                         lowerMsg:find("will begin in") or
                                         lowerMsg:find("starting in") or
                                         lowerMsg:find("seconds") or
                                         lowerMsg:find("minute"))
            
            if isBattleStartMessage and not isPreparationMessage then
                playerTracker.battleHasBegun = true
                FlagStateDirty()
            elseif isPreparationMessage then
            end
        end
        
        if message and not matchSaved then
            local timeSinceStart = GetTime() - bgStartTime
            local lowerMsg = message:lower()
            local isEndMessage = (lowerMsg:find("wins!") or 
                                 lowerMsg:find("claimed victory") or
                                 lowerMsg:find("won the battle") or
                                 lowerMsg:find("has won") or
                                 lowerMsg:find("alliance wins") or
                                 lowerMsg:find("horde wins"))
            
            if isEndMessage and timeSinceStart > MIN_BG_TIME then
                RequestBattlefieldScoreData()
                C_Timer.After(2, function()
                    if not matchSaved then
                        AttemptSaveWithRetry("CHAT_MSG_BG_SYSTEM_NEUTRAL")
                    end
                end)
            end
        end

    elseif e == "PVP_MATCH_STATE_CHANGED" then
        local rawState = nil
        if C_PvP and C_PvP.GetActiveMatchState then
            rawState = C_PvP.GetActiveMatchState()
        else
            rawState = ...
        end
        local actualMatchState = tostring(rawState or "")
        insideBG = newBGStatus
        if actualMatchState == "0" then
            return
        end

        if actualMatchState == "2" then
            if insideBG then
                playerTracker.sawPrematchState = true
            end
            return
        end

        if actualMatchState == "3" then
            playerTracker.battleHasBegun = true
            playerTracker.sawPrematchState = playerTracker.sawPrematchState or false
            FlagStateDirty()

            local enterTime = (bgStartTime and bgStartTime > 0) and bgStartTime or GetTime()
            local timeSinceEnter = GetTime() - enterTime
            local apiDuration = GetCurrentMatchDuration() or 0

            local likelyInProgress = (timeSinceEnter <= 15) and (apiDuration >= 120)
            if (not playerTracker.sawPrematchState) and likelyInProgress then
                playerTracker.joinedInProgress = true
                playerTracker.playerJoinedInProgress = true
                FlagStateDirty()
            end

            return
        end

        if actualMatchState == "5" then
            if not matchSaved then
                local timeSinceStart = GetTime() - bgStartTime
                if timeSinceStart > MIN_BG_TIME then
                    RequestBattlefieldScoreData()
                    C_Timer.After(1, function()
                        AttemptSaveWithRetry("PVP_MATCH_STATE_CHANGED")
                    end)
                end
            end
            return
        end


    elseif e == "UPDATE_BATTLEFIELD_SCORE" then
        insideBG = newBGStatus
        
        
        if insideBG and not matchSaved then
            local timeSinceStart = GetTime() - bgStartTime
            
            if bgStartTime == 0 or timeSinceStart < 0 or timeSinceStart > 7200 then
                bgStartTime = GetTime()
                timeSinceStart = 0
            end
            
            if timeSinceStart > MIN_BG_TIME then
                local winner = GetWinner and GetWinner() or nil
                
                if winner and winner ~= 0 and timeSinceStart > 120 then
                    RequestBattlefieldScoreData()
                    C_Timer.After(3, function()
                        if not matchSaved then
                            AttemptSaveWithRetry("UPDATE_BATTLEFIELD_SCORE")
                        end
                    end)
                end
            end
        end
        
    elseif e == "PVP_MATCH_COMPLETE" and insideBG and not matchSaved then
        local timeSinceStart = GetTime() - bgStartTime
        
        if timeSinceStart > MIN_BG_TIME then
            RequestBattlefieldScoreData()
            C_Timer.After(2, function()
                if not matchSaved then
                    AttemptSaveWithRetry("PVP_MATCH_COMPLETE")
                end
            end)
        end
        
    
    elseif (e == "PLAYER_LEAVING_WORLD" or e == "ZONE_CHANGED_NEW_AREA") then
        if insideBG then
            PersistMatchState("leaving_world_event")
            StopStatePersistence()
            insideBG = false
        end
    end
end)

function SaveExitingBattleground()
    if matchSaved then return end
    
    
    RequestBattlefieldScoreData()
    
    C_Timer.After(1, function()
        local data = CollectScoreData()
        
        if #data > 0 then
            CommitMatch(data)
        else
            
            RequestBattlefieldScoreData()
            C_Timer.After(1, function()
                local finalData = CollectScoreData()
                if #finalData > 0 then
                    CommitMatch(finalData)
                end
            end)
        end
    end)
end


print("|cff00ffffBGLogger|r loaded successfully! Use |cffffffff/bglogger|r to open and view recorded logs.")

C_Timer.After(1, function()
    if BGLoggerDB.minimapButton ~= false then
        SetMinimapButtonShown(true)
    end
end)

C_Timer.After(2, DetectAvailableAPIs)




