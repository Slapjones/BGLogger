BGLoggerDB = BGLoggerDB or {}
BGLoggerSession = BGLoggerSession or {}
BGLoggerAccountChars = BGLoggerAccountChars or {}
BGLoggerCharStats = BGLoggerCharStats or {}

---------------------------------------------------------------------
-- globals
---------------------------------------------------------------------
local WINDOW, DetailLines, ListButtons = nil, {}, {}
local selectedLogs = {}
local RefreshWindow
local RequestRefreshWindow
local RefreshSeasonDropdown, RefreshCharacterDropdown, RefreshBgTypeDropdown, RefreshMapDropdown
local IsEpicBattleground

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

    local state = BGLoggerSession.activeMatch
    
    -- Only reject if data is very stale (15+ minutes old)
    local now = GetServerTime()
    if state.timestamp and (now - state.timestamp) > 900 then
        ClearSessionState("snapshot too old")
        return false
    end
    
    -- Check if the saved state has an initial player list worth restoring
    if not state.playerTracker or not state.playerTracker.initialPlayerList then
        return false
    end
    
    local initialCount = 0
    for _ in pairs(state.playerTracker.initialPlayerList) do
        initialCount = initialCount + 1
    end
    if initialCount == 0 then
        return false
    end

    -- Restore the state - trust the saved data
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
-- Account-wide stat aggregation (personal performance)
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
-- Simple Player List Tracking
---------------------------------------------------------------------
local playerTracker = {
    initialPlayerList = {},
    finalPlayerList = {},
    initialListCaptured = false,
    battleHasBegun = false,
}

local function CountTableEntries(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function ResetPlayerTracker()
    if not insideBG or matchSaved then
        playerTracker.initialPlayerList = {}
        playerTracker.finalPlayerList = {}
        playerTracker.initialListCaptured = false
        playerTracker.initialCaptureRetried = false
        playerTracker.firstAttemptStats = nil
        playerTracker.battleHasBegun = false
        playerTracker.detectedAFKers = {}
        playerTracker.joinedInProgress = false
        playerTracker.playerJoinedInProgress = false
        FlagStateDirty()
        PersistMatchState("reset")
        
    end
end

local function GetPlayerKey(name, realm)
    return (name or "Unknown") .. "-" .. (realm or "Unknown")
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

local function CountFactionsInTable(playerTable)
    local allianceCount, hordeCount = 0, 0
    for _, p in pairs(playerTable or {}) do
        if p and p.faction == "Alliance" then allianceCount = allianceCount + 1
        elseif p and p.faction == "Horde" then hordeCount = hordeCount + 1 end
    end
    return allianceCount, hordeCount
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

local function GetObjectiveColumns(battlegroundName, playerDataList)
    local bgName = (battlegroundName or ""):lower()
    local availableObjectives = {}
    
    for _, player in ipairs(playerDataList or {}) do
        if player.objectiveBreakdown then
            for objType, value in pairs(player.objectiveBreakdown) do
                if value > 0 then
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
    for _, colDef in ipairs(columnDefinitions) do
        if availableObjectives[colDef.key] then
            table.insert(activeColumns, colDef)
        end
    end
    
    if #activeColumns == 0 then
        table.insert(activeColumns, {key = "objectives", name = "Obj", tooltip = "Total Objectives"})
    end
    
    
    return activeColumns
end

local initialPlayerCount = 0

local function IsMatchStarted()
    local rows = GetNumBattlefieldScores()
    if rows == 0 then 
		return false
    end
    
    if not playerTracker.battleHasBegun then
        return false
    end
    
    local apiDuration = 0
    if C_PvP and C_PvP.GetActiveMatchDuration then
        apiDuration = C_PvP.GetActiveMatchDuration() or 0
        
        if apiDuration > 5 then
            return true
        elseif apiDuration == 0 then
            return false
        end
    end
    
    local allianceCount, hordeCount = 0, 0
    
    for i = 1, math.min(rows, 20) do
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        if success and s and s.name then
            local faction = nil
            
            if s.faction == 0 then
                faction = "Horde"
            elseif s.faction == 1 then
                faction = "Alliance"
            elseif s.side == "Alliance" or s.side == "Horde" then
                faction = s.side
            elseif s.side == 0 then
                faction = "Horde"
            elseif s.side == 1 then
                faction = "Alliance"
            end
            
            if faction == "Alliance" then
                allianceCount = allianceCount + 1
            elseif faction == "Horde" then
                hordeCount = hordeCount + 1
            end
        end
    end
    
    local bothFactionsVisible = (allianceCount > 0 and hordeCount > 0)
    local hasMinimumPlayers = (rows >= (IsEpicBattleground() and 10 or 15))
    
    local timeSinceEntered = GetTime() - bgStartTime
    local minimumWaitTime = IsEpicBattleground() and 20 or 45
    
    
    local matchStarted = playerTracker.battleHasBegun and 
                        apiDuration > 0 and 
                        bothFactionsVisible and 
                        hasMinimumPlayers and
                        timeSinceEntered >= minimumWaitTime
    
    
    return matchStarted
end

local function CaptureInitialPlayerList(skipMatchStartCheck)
    
    if playerTracker.initialListCaptured then 
        return 
    end
    
    if not skipMatchStartCheck and not IsMatchStarted() then
        return
    end
    
    
    local rows = GetNumBattlefieldScores()
    
    if rows == 0 then 
        return 
    end
    
    
    playerTracker.initialPlayerList = {}
    
    local playerRealm = GetRealmName() or "Unknown-Realm"
    if GetNormalizedRealmName and GetNormalizedRealmName() ~= "" then
        playerRealm = GetNormalizedRealmName()
    end
    
    local processedCount = 0
    local skippedCount = 0
    local keyCollisions = {}
    
    for i = 1, rows do
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        if success and s then
            
            if not s.name or s.name == "" then
                skippedCount = skippedCount + 1
            else
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
            
            local playerKey = GetPlayerKey(playerName, realmName)
            
            if playerTracker.initialPlayerList[playerKey] then
                keyCollisions[playerKey] = (keyCollisions[playerKey] or 0) + 1
                
                local uniqueKey = playerKey .. "_" .. i
                playerKey = uniqueKey
            end
            
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
                factionName = (s.faction == 0) and "Horde" or "Alliance"
            end
            
            playerTracker.initialPlayerList[playerKey] = {
                name = playerName,
                realm = realmName,
                class = className,
                spec = specName,
                faction = factionName,
                rawFaction = s.faction,
                rawSide = s.side,
                rawRace = s.race
            }
            processedCount = processedCount + 1
            
            end
        else
            skippedCount = skippedCount + 1
        end
    end
    
    local initialCount = CountTableEntries(playerTracker.initialPlayerList)
    
    
    if next(keyCollisions) then
        for key, count in pairs(keyCollisions) do
        end
    end
    
    local completenessRatio = rows > 0 and (processedCount / rows) or 0
    local isLargeDisparity = skippedCount > 15 and completenessRatio < 0.7
    
    local isEpicMap = IsEpicBattleground()
    local currentMap = C_Map.GetBestMapForUnit("player") or 0
    local mapInfo = C_Map.GetMapInfo(currentMap)
    local mapName = (mapInfo and mapInfo.name) or "Unknown"
    
    if isEpicMap then
    end
    
    if isLargeDisparity and not playerTracker.initialCaptureRetried then
        local retryDelay = isEpicMap and 25 or 12
        
        playerTracker.firstAttemptStats = {
            rows = rows,
            processed = processedCount,
            skipped = skippedCount,
            stored = initialCount
        }
        
        playerTracker.initialCaptureRetried = true
        playerTracker.initialListCaptured = false
        
        C_Timer.After(retryDelay, function()
            if insideBG and not playerTracker.initialListCaptured then
                RequestBattlefieldScoreData()
                C_Timer.After(1.0, function()
            if insideBG and not playerTracker.initialListCaptured then
                CaptureInitialPlayerList(true)
                    end
                end)
            end
        end)
        
        return
    end
    
    if playerTracker.firstAttemptStats then
        local firstAttempt = playerTracker.firstAttemptStats
        local improvement = initialCount - firstAttempt.stored
        local newCompleteness = math.floor((processedCount / rows) * 100)
        local oldCompleteness = math.floor((firstAttempt.processed / firstAttempt.rows) * 100)
        
        
        playerTracker.firstAttemptStats = nil
    end
    
    if IsEpicBattleground() then
        local aCount, hCount = CountFactionsInTable(playerTracker.initialPlayerList)
        if (aCount == 0 or hCount == 0) and not playerTracker.initialCaptureRetried then
            playerTracker.initialCaptureRetried = true
            RequestBattlefieldScoreData()
            C_Timer.After(1.5, function()
                if insideBG then
                    local beforeCount = CountTableEntries(playerTracker.initialPlayerList)
                    local rows2 = GetNumBattlefieldScores()
                    for i = 1, rows2 do
                        local ok, s2 = pcall(C_PvP.GetScoreInfo, i)
                        if ok and s2 and s2.name and s2.name ~= "" then
                            local pn, rn = s2.name, ""
                            if s2.name:find("-") then pn, rn = s2.name:match("^(.+)-(.+)$") end
                            if (not rn or rn == "") and s2.realm then rn = s2.realm end
                            if (not rn or rn == "") and s2.guid then
                                local _, _, _, _, _, _, _, rFrom = GetPlayerInfoByGUID(s2.guid)
                                if rFrom and rFrom ~= "" then rn = rFrom end
                            end
                            if not rn or rn == "" then rn = GetRealmName() or "Unknown-Realm" end
                            rn = rn:gsub("%s+", ""):gsub("'", "")
                            local key = GetPlayerKey(pn, rn)
                            if not playerTracker.initialPlayerList[key] then
                                local factionName = (s2.faction == 1) and "Alliance" or ((s2.faction == 0) and "Horde" or (s2.side == 1 and "Alliance" or (s2.side == 0 and "Horde" or "")))
                                playerTracker.initialPlayerList[key] = { name = pn, realm = rn, faction = factionName }
                            end
                        end
                    end
                    local afterCount = CountTableEntries(playerTracker.initialPlayerList)
                end
                playerTracker.initialListCaptured = true
                FlagStateDirty()
                PersistMatchState("initial_capture_epic_refresh")
            end)
            return
        end
    end

    playerTracker.initialListCaptured = true
    
    local count = 0
    for playerKey, playerInfo in pairs(playerTracker.initialPlayerList) do
        if count < 3 then
            count = count + 1
        end
    end
    FlagStateDirty()
    PersistMatchState("initial_capture")
end

local function CaptureFinalPlayerList(playerStats)
    
    local currentPlayerName = UnitName("player")
    local currentPlayerRealm = GetRealmName() or "Unknown-Realm"
    local currentPlayerKey = GetPlayerKey(currentPlayerName, currentPlayerRealm)
    
    
    local foundCurrentPlayer = false
    
    playerTracker.finalPlayerList = {}
    
    for i, player in ipairs(playerStats) do
        
        local playerKey = GetPlayerKey(player.name, player.realm)
        
        if player.name == currentPlayerName then
            foundCurrentPlayer = true
        end
        
        if playerKey == currentPlayerKey then
            foundCurrentPlayer = true
        end
        
        playerTracker.finalPlayerList[playerKey] = {
            name = player.name,
            realm = player.realm,
            playerData = player
        }
    end
    
    
    
    local finalCount = CountTableEntries(playerTracker.finalPlayerList)
    
    local count = 0
    for playerKey, playerInfo in pairs(playerTracker.finalPlayerList) do
        if count < 3 then
            count = count + 1
        end
    end
    FlagStateDirty()
    PersistMatchState("final_capture")
end

local function AnalyzePlayerLists()
    
    local afkers = {}
    local backfills = {}
    local normal = {}
    
    local initialCount = CountTableEntries(playerTracker.initialPlayerList)
    local finalCount = CountTableEntries(playerTracker.finalPlayerList)
    
    
    if initialCount == 0 then
    end
    
    if finalCount == 0 then
        return afkers, backfills, normal
    end
    
    if playerTracker.joinedInProgress then
        
        for playerKey, playerInfo in pairs(playerTracker.finalPlayerList) do
            local playerData = playerInfo.playerData
            playerData.participationUnknown = true
            table.insert(normal, playerData)
        end
        
        
    else
        
        for playerKey, playerInfo in pairs(playerTracker.initialPlayerList) do
            if not playerTracker.finalPlayerList[playerKey] then
                table.insert(afkers, playerInfo)
            end
        end
        
        for playerKey, playerInfo in pairs(playerTracker.finalPlayerList) do
            local playerData = playerInfo.playerData
            
            if playerTracker.initialPlayerList[playerKey] then
                table.insert(normal, playerData)
            else
                table.insert(backfills, playerData)
            end
        end
        
    end
    
    local playerName = UnitName("player")
    local playerRealm = GetRealmName() or "Unknown-Realm"
    local yourKey = GetPlayerKey(playerName, playerRealm)
    
    
    local yourStatus = "UNKNOWN"
    if playerTracker.joinedInProgress then
        yourStatus = "JOINED IN-PROGRESS (participation status unknown)"
    elseif playerTracker.finalPlayerList[yourKey] then
        if playerTracker.initialPlayerList[yourKey] then
            yourStatus = "NORMAL (in initial, on final)"
        else
            yourStatus = "BACKFILL (NOT in initial, on final)"
        end
    else
        if playerTracker.initialPlayerList[yourKey] then
            yourStatus = "AFKer (in initial, NOT on final)"
        else
            yourStatus = "ERROR: Not in either list!"
        end
    end
    
    
    return afkers, backfills, normal
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
    local currentPlayerRealm = GetRealmName() or "Unknown-Realm"
    currentPlayerRealm = currentPlayerRealm:gsub("%s+", ""):gsub("'", "")
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
                factionName = (s.faction == 0) and "Horde" or "Alliance"
            end
            
            if playerName == currentPlayerName then
                foundCurrentPlayer = true
            end
            
            local rawDamage = s.damageDone or s.damage or 0
            local rawHealing = s.healingDone or s.healing or 0
            
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
                objectives = objectives,
                objectiveBreakdown = objectiveBreakdown or {},
                isBackfill = false,
                isAfker = false
            }
            
            t[#t+1] = playerData
        else
            failedReads = failedReads + 1
        end
    end
     
    
    local afkers = {}
    if not playerTracker.joinedInProgress then
        for playerKey, playerInfo in pairs(playerTracker.initialPlayerList) do
            local foundInFinal = false
            for _, finalPlayer in ipairs(t) do
                local finalPlayerKey = GetPlayerKey(finalPlayer.name, finalPlayer.realm)
                if finalPlayerKey == playerKey then
                    foundInFinal = true
                    break
                end
            end
            
            if not foundInFinal then
                local afkerData = {
                    name = playerInfo.name,
                    realm = playerInfo.realm,
                    class = playerInfo.class or "Unknown",
                    spec = playerInfo.spec or "",
                    faction = playerInfo.faction or "Unknown"
                }
                table.insert(afkers, afkerData)
            end
        end
    end
    
    for _, player in ipairs(t) do
        local playerKey = GetPlayerKey(player.name, player.realm)
        
        if playerTracker.joinedInProgress then
            local isCurrent = (player.name == currentPlayerName and player.realm == currentPlayerRealm)
            player.isBackfill = isCurrent
            player.participationUnknown = not isCurrent
        else
            if not playerTracker.initialPlayerList[playerKey] then
                player.isBackfill = true
            else
                player.isBackfill = false
            end
            player.participationUnknown = false
        end
    end
    
    playerTracker.detectedAFKers = afkers
    FlagStateDirty()
    PersistMatchState("afk_analysis")
    
    
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
                objectives = p.objectives or 0,
                objectiveBreakdown = p.objectiveBreakdown or {},
                isBackfill = p.isBackfill or false
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
            afkers = playerTracker.detectedAFKers or {},
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
            
            battlegroundName = mapName,
            duration = duration,
            durationSource = durationSource,
            winner = winner,
            type = bgType,
			season = CURRENT_SEASON,
            startTime = bgStartTime,
            endTime = currentTime,
            dateISO = date("!%Y-%m-%dT%H:%M:%SZ"),
            
            afkerList = playerTracker.detectedAFKers or {},
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
                version = "BGLogger_v2.0",
                realm = GetRealmName() or "Unknown"
            }
        }
        
        -- Append to persistent character stats
        local selfKey = GetPlayerKey(selfName, selfRealm)
        local selfEntry = FindSelfPlayerEntry(BGLoggerDB[key], selfName, selfRealm)
        if selfEntry then
            local didWin = nil
            if winner ~= "" then
                didWin = (winner == selfFaction)
            end
            -- Compute bgCategory using same logic as GetBattlegroundCategory
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

local COLUMN_ORDER = {
    "name",
    "realm",
    "class",
    "spec",
    "faction",
    "damage",
    "healing",
    "kills",
    "deaths",
    "objectives",
    "hk",
    "status"
}

local COLUMN_HEADERS = {
    name = "Player",
    realm = "Realm",
    class = "Class",
    spec = "Spec",
    faction = "Faction",
    damage = "Damage",
    healing = "Healing",
    kills = "Kills",
    deaths = "Deaths",
    objectives = "Objectives",
    hk = "HK",
    status = "Status"
}

local COLUMN_ALIGNMENT = {
    name = "LEFT",
    realm = "LEFT",
    class = "CENTER",
    spec = "CENTER",
    faction = "CENTER",
    damage = "RIGHT",
    healing = "RIGHT",
    kills = "CENTER",
    deaths = "CENTER",
    objectives = "CENTER",
    hk = "CENTER",
    status = "LEFT"
}

local COLUMN_WIDTHS = {
    name = 170,
    realm = 120,
    class = 90,
    spec = 110,
    faction = 80,
    damage = 100,
    healing = 100,
    kills = 50,
    deaths = 50,
    objectives = 80,
    hk = 70,
    status = 100
}

local COLUMN_GAP = 8
local DETAIL_LEFT_PADDING = 12
local COLUMN_POSITIONS = {}
local DETAIL_CONTENT_WIDTH = 0

do
    local x = DETAIL_LEFT_PADDING
    for _, key in ipairs(COLUMN_ORDER) do
        COLUMN_POSITIONS[key] = x
        x = x + COLUMN_WIDTHS[key] + COLUMN_GAP
    end
    DETAIL_CONTENT_WIDTH = x - COLUMN_GAP + DETAIL_LEFT_PADDING
end

local SORTABLE_FIELDS = {
    damage = {
        label = "Damage",
        accessor = function(row)
            return row.damage or row.dmg or 0
        end
    },
    healing = {
        label = "Healing",
        accessor = function(row)
            return row.healing or row.heal or 0
        end
    },
    kills = {
        label = "Kills",
        accessor = function(row)
            return row.kills or row.killingBlows or row.kb or 0
        end
    },
    deaths = {
        label = "Deaths",
        accessor = function(row)
            return row.deaths or 0
        end
    },
    objectives = {
        label = "Objectives",
        accessor = function(row)
            return row.objectives or 0
        end
    },
    hk = {
        label = "HK",
        accessor = function(row)
            return row.honorableKills or row.honorKills or row.hk or 0
        end
    }
}

local DETAIL_ROW_COLORS = {
    even = {0.08, 0.08, 0.10, 0.78},
    odd = {0.10, 0.10, 0.12, 0.78},
    backfill = {0.17, 0.14, 0.04, 0.85},
    unknown = {0.12, 0.12, 0.12, 0.80},
    totals = {0.14, 0.14, 0.18, 0.92},
    summary = {0.11, 0.11, 0.16, 0.88},
    header = {0.14, 0.14, 0.18, 0.95},
    section = {0.11, 0.11, 0.15, 0.80},
    afkHeader = {0.28, 0.12, 0.12, 0.92},
    afkRow = {0.22, 0.09, 0.09, 0.85}
}

local DETAIL_TEXT_COLORS = {
    default = {0.90, 0.92, 0.96},
    header = {1.0, 1.0, 0.72},
    totals = {1.0, 1.0, 0.85},
    section = {0.78, 0.78, 0.82},
    backfill = {1.0, 0.94, 0.55},
    unknown = {0.82, 0.82, 0.82},
    afk = {1.0, 0.80, 0.80}
}

local DIVIDER_COLOR_DEFAULT = {0.25, 0.25, 0.32, 0.55}
local DIVIDER_COLOR_HEADER = {0.30, 0.30, 0.38, 0.70}

local function GetSortableValue(row, field)
    if not row or not SORTABLE_FIELDS[field] then
        return 0
    end
    local ok, value = pcall(SORTABLE_FIELDS[field].accessor, row)
    if not ok then
        return 0
    end
    return tonumber(value) or 0
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
        WINDOW.detailSortDirection = "desc"
    end
    if WINDOW.currentView == "detail" and WINDOW.currentKey then
        ShowDetail(WINDOW.currentKey)
    end
end

local function StyleDetailLine(line, options)
    options = options or {}

    local showDividers = options.showDividers
    if showDividers == nil then
        showDividers = true
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
    lineFrame:SetSize(DETAIL_CONTENT_WIDTH + DETAIL_LEFT_PADDING * 2, LINE_HEIGHT + ROW_PADDING_Y)
    
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
        fontString:SetPoint("TOPLEFT", xPos, -ROW_PADDING_Y * 0.5)
        fontString:SetSize(COLUMN_WIDTHS[columnName], LINE_HEIGHT)
        fontString:SetFont("Fonts\\ARIALN.TTF", 12, "")
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
-- List Selection Helpers
---------------------------------------------------------------------
---------------------------------------------------------------------
-- Renderers - completely rebuilt
---------------------------------------------------------------------
-- Assign to forward-declared variable (not local function) so callbacks can access it
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
        line:Show()
        WINDOW.detailContent:SetHeight(LINE_HEIGHT)
        return
    end
    
    local data = BGLoggerDB[key]
    
    local headerInfo = DetailLines[1] or MakeDetailLine(WINDOW.detailContent, 1)
    StyleDetailLine(headerInfo, { style = "header", textColor = "header", dividerColor = DIVIDER_COLOR_HEADER })
    local mapInfo = C_Map.GetMapInfo(data.mapID or 0)
    local mapName = (mapInfo and mapInfo.name) or "Unknown Map"
    
    local bgInfo = string.format("Battleground: %s | Duration: %s | Winner: %s | Type: %s",
        mapName,
        data.duration and (math.floor(data.duration / 60) .. ":" .. string.format("%02d", data.duration % 60)) or "Unknown",
        data.winner or "Unknown",
        data.type or "Unknown"
    )
    
    if data.joinedInProgress then
        bgInfo = bgInfo .. " | ⚠️ JOINED IN-PROGRESS"
    end
    
    if not headerInfo.fullWidthText then
        headerInfo.fullWidthText = headerInfo:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        headerInfo.fullWidthText:SetFont("Fonts\\ARIALN.TTF", 12, "")
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
    StyleDetailLine(separator1, { showDividers = false })
    if not separator1.dividerTexture then
        separator1.dividerTexture = separator1:CreateTexture(nil, "BACKGROUND")
        separator1.dividerTexture:SetColorTexture(0.35, 0.35, 0.45, 0.85)
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

    for _, columnName in ipairs(COLUMN_ORDER) do
        local label = COLUMN_HEADERS[columnName]
        if SORTABLE_FIELDS[columnName] then
            local arrow = ""
            if WINDOW.detailSortField == columnName then
                arrow = WINDOW.detailSortDirection == "asc" and " ▲" or " ▼"
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
        local x, y = GetCursorPosition()
        local scale = self:GetEffectiveScale()
        x = x / scale
        y = y / scale

        local clickedField = nil
        for _, columnName in ipairs(COLUMN_ORDER) do
            if SORTABLE_FIELDS[columnName] then
                local columnFS = header.columns[columnName]
                local left = columnFS:GetLeft()
                local right = columnFS:GetRight()
                local top = columnFS:GetTop()
                local bottom = columnFS:GetBottom()
                if x >= left and x <= right and y >= bottom and y <= top then
                    clickedField = columnName
                    break
                end
            end
        end

        if clickedField then
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            SetDetailSort(clickedField)
        end
    end)

    header:Show()
    
    local separator2 = DetailLines[4] or MakeDetailLine(WINDOW.detailContent, 4)
    StyleDetailLine(separator2, { showDividers = false })
    if not separator2.dividerTexture then
        separator2.dividerTexture = separator2:CreateTexture(nil, "BACKGROUND")
        separator2.dividerTexture:SetColorTexture(0.28, 0.28, 0.34, 0.75)
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
            if WINDOW.detailSortDirection == "asc" then
                if aValue == bValue then
                    return (a.name or "") < (b.name or "")
                end
                return aValue < bValue
            else
                if aValue == bValue then
                    return (a.name or "") < (b.name or "")
                end
                return aValue > bValue
            end
        end)
    end
    
    local afkers = data.afkerList or {}
    
    for i, row in ipairs(regularPlayers) do
        local line = DetailLines[i+4] or MakeDetailLine(WINDOW.detailContent, i+4)
        local participationUnknown = row.participationUnknown or false
        local isBackfill = row.isBackfill or false
        local styleKey
        if participationUnknown then
            styleKey = "unknown"
        elseif isBackfill then
            styleKey = "backfill"
        else
            styleKey = (i % 2 == 0) and "even" or "odd"
        end
        
        local damage = row.damage or row.dmg or 0
        local healing = row.healing or row.heal or 0
        local kills = row.kills or row.killingBlows or row.kb or 0
        local deaths = row.deaths or 0
        local honorableKills = row.honorableKills or row.honorKills or 0
        local objectives = row.objectives or 0
        local realm = row.realm or "Unknown"
        local class = row.class or "Unknown"
        local spec = row.spec or "Unknown"
        local faction = row.faction or row.side or "Unknown"
        
        local textColor = DETAIL_TEXT_COLORS.default
        if participationUnknown then
            textColor = DETAIL_TEXT_COLORS.unknown
        elseif isBackfill then
            textColor = DETAIL_TEXT_COLORS.backfill
        end
        
        local status = ""
        if participationUnknown then
            status = "??"
        elseif isBackfill then
            status = "BF"
        else
            status = "OK"
        end
        
        local damageText = damage >= 1000000 and string.format("%.1fM", damage/1000000) or 
                          damage >= 1000 and string.format("%.0fK", damage/1000) or tostring(damage)
        local healingText = healing >= 1000000 and string.format("%.1fM", healing/1000000) or 
                           healing >= 1000 and string.format("%.0fK", healing/1000) or tostring(healing)
        
        line.columns.name:SetText(row.name or "Unknown")
        line.columns.realm:SetText(realm)
        line.columns.class:SetText(class)
        line.columns.spec:SetText(spec)
        line.columns.faction:SetText(faction)
        line.columns.damage:SetText(damageText)
        line.columns.healing:SetText(healingText)
        line.columns.kills:SetText(tostring(kills))
        line.columns.deaths:SetText(tostring(deaths))
        line.columns.objectives:SetText(tostring(objectives))
        line.columns.hk:SetText(tostring(honorableKills))
        line.columns.status:SetText(status)
            
        StyleDetailLine(line, { style = styleKey, textColor = participationUnknown and "unknown" or (isBackfill and "backfill" or "default") })
        line:Show()
    end
    
    local summaryLine = DetailLines[#regularPlayers+6] or MakeDetailLine(WINDOW.detailContent, #regularPlayers+6)
    StyleDetailLine(summaryLine, { showDividers = false })
    if not summaryLine.dividerTexture then
        summaryLine.dividerTexture = summaryLine:CreateTexture(nil, "BACKGROUND")
        summaryLine.dividerTexture:SetColorTexture(0.24, 0.24, 0.30, 0.75)
        summaryLine.dividerTexture:SetPoint("TOPLEFT", DETAIL_LEFT_PADDING - 4, -ROW_PADDING_Y)
        summaryLine.dividerTexture:SetPoint("BOTTOMRIGHT", -DETAIL_LEFT_PADDING + 4, ROW_PADDING_Y)
    end
    summaryLine.dividerTexture:Show()
    for _, column in pairs(summaryLine.columns) do
        column:SetText("")
    end
    summaryLine:Show()

    local totalLine = DetailLines[#regularPlayers+7] or MakeDetailLine(WINDOW.detailContent, #regularPlayers+7)
    local totalDamage, totalHealing, totalKills, totalDeaths = 0, 0, 0, 0
    local backfillCount = 0
    
    for _, row in ipairs(regularPlayers) do
        totalDamage = totalDamage + (row.damage or row.dmg or 0)
        totalHealing = totalHealing + (row.healing or row.heal or 0)
        totalKills = totalKills + (row.kills or row.killingBlows or row.kb or 0)
        totalDeaths = totalDeaths + (row.deaths or 0)
        
        if row.isBackfill then backfillCount = backfillCount + 1 end
    end
    
    local totalDamageText = totalDamage >= 1000000 and string.format("%.1fM", totalDamage/1000000) or 
                           totalDamage >= 1000 and string.format("%.0fK", totalDamage/1000) or tostring(totalDamage)
    local totalHealingText = totalHealing >= 1000000 and string.format("%.1fM", totalHealing/1000000) or 
                            totalHealing >= 1000 and string.format("%.0fK", totalHealing/1000) or tostring(totalHealing)
    
    totalLine.columns.name:SetText("TOTALS (" .. #regularPlayers .. " players)")
    totalLine.columns.realm:SetText("")
    totalLine.columns.class:SetText("")
    totalLine.columns.spec:SetText("")
    totalLine.columns.faction:SetText("")
    totalLine.columns.damage:SetText(totalDamageText)
    totalLine.columns.healing:SetText(totalHealingText)
    totalLine.columns.kills:SetText(tostring(totalKills))
    totalLine.columns.deaths:SetText(tostring(totalDeaths))
    totalLine.columns.objectives:SetText("")
    totalLine.columns.hk:SetText("")
    totalLine.columns.status:SetText("")
    
    StyleDetailLine(totalLine, { style = "totals", textColor = "totals" })
    totalLine:Show()
    
    local currentLineIndex = #regularPlayers + 8
    
    if backfillCount > 0 then
        local backfillSummaryLine = DetailLines[currentLineIndex] or MakeDetailLine(WINDOW.detailContent, currentLineIndex)
        if not backfillSummaryLine.background then
            backfillSummaryLine.background = backfillSummaryLine:CreateTexture(nil, "BACKGROUND")
            backfillSummaryLine.background:SetAllPoints()
        end
        backfillSummaryLine.background:SetColorTexture(unpack(DETAIL_ROW_COLORS.summary))
        backfillSummaryLine.columns.name:SetText("Backfills among active players: " .. backfillCount)
        for columnName, column in pairs(backfillSummaryLine.columns) do
            if columnName == "name" then
                column:SetTextColor(unpack(DETAIL_TEXT_COLORS.section))
            else
                column:SetText("")
            end
        end
        backfillSummaryLine:Show()
        currentLineIndex = currentLineIndex + 1
    end
    
    if #afkers > 0 then
        local afkerSeparator = DetailLines[currentLineIndex] or MakeDetailLine(WINDOW.detailContent, currentLineIndex)
        StyleDetailLine(afkerSeparator, { showDividers = false })
        if not afkerSeparator.dividerTexture then
            afkerSeparator.dividerTexture = afkerSeparator:CreateTexture(nil, "BACKGROUND")
            afkerSeparator.dividerTexture:SetColorTexture(0.30, 0.24, 0.24, 0.80)
            afkerSeparator.dividerTexture:SetPoint("TOPLEFT", DETAIL_LEFT_PADDING - 4, -ROW_PADDING_Y)
            afkerSeparator.dividerTexture:SetPoint("BOTTOMRIGHT", -DETAIL_LEFT_PADDING + 4, ROW_PADDING_Y)
        end
        afkerSeparator.dividerTexture:Show()
        for _, column in pairs(afkerSeparator.columns) do
            column:SetText("")
        end
        afkerSeparator:Show()
        currentLineIndex = currentLineIndex + 1
        
        local afkerHeader = DetailLines[currentLineIndex] or MakeDetailLine(WINDOW.detailContent, currentLineIndex)
        StyleDetailLine(afkerHeader, { style = "afkHeader", textColor = "afk" })
        afkerHeader.columns.name:SetText("AFK/Early Leavers (" .. #afkers .. " players):")
        for columnName, column in pairs(afkerHeader.columns) do
            if columnName == "name" then
                column:SetTextColor(unpack(DETAIL_TEXT_COLORS.afk))
            else
                column:SetText("")
            end
        end
        afkerHeader:Show()
        currentLineIndex = currentLineIndex + 1
        
        for i, afker in ipairs(afkers) do
            local afkerLine = DetailLines[currentLineIndex] or MakeDetailLine(WINDOW.detailContent, currentLineIndex)
            StyleDetailLine(afkerLine, { style = "afkRow", textColor = "afk" })
            local playerString = afker.name .. "-" .. afker.realm
            local classInfo = (afker.class and afker.class ~= "Unknown") and (" (" .. afker.class .. " " .. (afker.faction or "") .. ")") or ""
            
            afkerLine.columns.name:SetText("  " .. playerString .. classInfo .. " (left before match ended)")
            for columnName, column in pairs(afkerLine.columns) do
                if columnName ~= "name" then
                    column:SetText("")
                end
            end
            afkerLine:Show()
            currentLineIndex = currentLineIndex + 1
        end
    end
    
    for i = currentLineIndex, #DetailLines do
        if DetailLines[i] then
            DetailLines[i]:Hide()
        end
    end

    WINDOW.detailContent:SetHeight(math.max((currentLineIndex-1)*LINE_HEIGHT, 10))
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
    
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
        end
    end)
    
    f:SetScript("OnShow", function(self)
        if not InCombatLockdown() then
            self:EnableKeyboard(true)
        end
    end)
    
    f:SetScript("OnHide", function(self)
        if not InCombatLockdown() then
            self:EnableKeyboard(false)
        end
    end)
    
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Battleground Statistics")
    
    StaticPopupDialogs["BGLOGGER_CLEAR"] = {
        text = "Clear all saved logs?",
        button1 = YES,
        button2 = NO,
        OnAccept = function() 
            wipe(BGLoggerDB)
			ClearAllSelections()
            RequestRefreshWindow()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true
    }
    
    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetSize(90, 22)
    clearBtn:SetPoint("TOPRIGHT", -80, -40)
    clearBtn:SetText("Clear All")
    clearBtn:SetScript("OnClick", function() 
        StaticPopup_Show("BGLOGGER_CLEAR")
    end)
    
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
    refreshBtn:SetPoint("TOPRIGHT", clearBtn, "TOPLEFT", -10, 0)
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
    
    local detailContent = CreateFrame("Frame", nil, detailScroll)
    detailContent:SetSize(detailScroll:GetWidth() - 16, 10)
    detailScroll:SetScrollChild(detailContent)
    
    f.listScroll = listScroll
    f.listContent = listContent
    f.detailScroll = detailScroll
    f.detailContent = detailContent
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
    
    if e == "PLAYER_ENTERING_WORLD" then
		RegisterCurrentCharacter()
		
    local wasInBG = insideBG
    insideBG = newBGStatus
    
        -- Step 1: Not in BG? Clear saved state and wait
        if not insideBG then
            ClearSessionState("not_in_bg")
            StopStatePersistence()
            return
        end
        
        -- Step 2: In BG - try to restore saved list data
        if insideBG and not wasInBG then
            local restoredState = TryRestoreMatchState()
            
            if restoredState then
                -- Have saved list data - use it, proceed normally
                StartStatePersistence()
            else
                -- Step 3: No saved list data - check if match has started
                bgStartTime = GetTime()
                matchSaved = false
                saveInProgress = false
                ResetPlayerTracker()
                initialPlayerCount = 0
                
                -- Check if match already started (backfill scenario)
                local apiDuration = 0
                if C_PvP and C_PvP.GetActiveMatchDuration then
                    apiDuration = C_PvP.GetActiveMatchDuration() or 0
                end
                
                if apiDuration > 10 then
                    -- Match has started, user is a backfill
                    playerTracker.joinedInProgress = true
                    playerTracker.joinedInProgressReason = "no_saved_data_match_started"
                end
                -- If match not started (apiDuration <= 10), normal flow continues below
                -- to capture initial list when battle begins
                
                StartStatePersistence()
            end
            
            if not playerTracker.initialListCaptured and not playerTracker.joinedInProgress then
            local function CheckInProgress(attempt)
                attempt = attempt or 1
                if not insideBG then return end
                if (playerTracker and (playerTracker.battleHasBegun or playerTracker.initialListCaptured)) then
                    return
                end
                    local isInProgressBG = false
                    local detectionMethod = "none"

                RequestBattlefieldScoreData()

                C_Timer.After(0.6, function()
                    if not insideBG then return end
                    if playerTracker and (playerTracker.battleHasBegun or playerTracker.initialListCaptured) then
                        return
                    end
                    
                    if C_PvP and C_PvP.GetActiveMatchDuration then
                        local apiDuration = C_PvP.GetActiveMatchDuration() or 0
                        local timeInside = GetTime() - (bgStartTime or GetTime())
                        local durationDelta = apiDuration - timeInside

                        if apiDuration > 5 and durationDelta >= 10 then
                            isInProgressBG = true
                            detectionMethod = string.format("API_duration_%ss_delta_%s", tostring(apiDuration), tostring(math.floor(durationDelta)))
                        end
                    end
                    
                    if not isInProgressBG and IsEpicBattleground() then
                        local rows = GetNumBattlefieldScores()
                        if rows > 0 then
                            local allianceCount, hordeCount = 0, 0
                            local myFaction = UnitFactionGroup("player")
                            local enemyFactionId = nil
                            if myFaction == "Alliance" then
                                enemyFactionId = 0
                            elseif myFaction == "Horde" then
                                enemyFactionId = 1
                            end

                            local allowedThreshold = (myFaction == "Alliance") and 10 or 6
                            local activeEnemyThreshold = 3
                            local visibleEnemy = 0
                            local activeEnemy = 0

                            for i = 1, math.min(rows, 30) do
                                local success, s = pcall(C_PvP.GetScoreInfo, i)
                                if success and s and s.name then
                                    local factionId = s.faction
                                    if factionId == nil then
                                        if type(s.side) == "number" then
                                            factionId = s.side
                                        elseif type(s.side) == "string" then
                                            if s.side == "Horde" then
                                                factionId = 0
                                            elseif s.side == "Alliance" then
                                                factionId = 1
                                            end
                                        end
                                    end

                                    if factionId == 0 then
                                        hordeCount = hordeCount + 1
                                    elseif factionId == 1 then
                                        allianceCount = allianceCount + 1
                                    end

                                    if enemyFactionId ~= nil and factionId == enemyFactionId then
                                        visibleEnemy = visibleEnemy + 1

                                        local damage = s.damageDone or s.damage or 0
                                        local healing = s.healingDone or s.healing or 0
                                        local killingBlows = s.killingBlows or s.kills or 0
                                        local honorableKills = s.honorableKills or s.honorKills or 0
                                        local deaths = s.deaths or 0
                                        local objectives = s.objectives or s.objectiveScore or 0

                                        if (damage > 0) or (healing > 0) or (killingBlows > 0) or (honorableKills > 0) or (deaths > 0) or (objectives > 0) then
                                            activeEnemy = activeEnemy + 1
                                        end
                                    end
                                end
                            end


                            if enemyFactionId ~= nil and visibleEnemy >= allowedThreshold and activeEnemy >= activeEnemyThreshold then
                                isInProgressBG = true
                                detectionMethod = string.format("enemy_visible_%d_players", visibleEnemy)
                            end
                        end
                    end
                    
                    if isInProgressBG then
                        
                        playerTracker.joinedInProgress = true
                        playerTracker.battleHasBegun = true
                        
                        CaptureInitialPlayerList(true)
                        
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
                            if playerTracker and (playerTracker.battleHasBegun or playerTracker.initialListCaptured) then
                                return
                            end
                            CheckInProgress(attempt + 1) 
                        end)
                end
            end)
            end
            C_Timer.After(2, function() 
                if playerTracker and (playerTracker.battleHasBegun or playerTracker.initialListCaptured) then
                    return
                end
                CheckInProgress(1) 
            end)
            
    C_Timer.After(90, function()
        if insideBG and not playerTracker.battleHasBegun then
            playerTracker.battleHasBegun = true
            FlagStateDirty()

            if playerTracker.joinedInProgress then
                return
            end
        end
    end)
            
            local checkCount = 0
            local function CheckMatchStart()
                checkCount = checkCount + 1
                if insideBG and not playerTracker.initialListCaptured and checkCount <= 15 then
                    if playerTracker.joinedInProgress then
                        return
                    end

                    if IsMatchStarted() then
                        CaptureInitialPlayerList(false)
                    else
                        C_Timer.After(10, CheckMatchStart)
                    end
                end
            end

            C_Timer.After(25, CheckMatchStart)
            end
            
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

    elseif e == "PVP_MATCH_STATE_CHANGED" and insideBG then
        local matchState = ...
        
        local actualMatchState = matchState
        if not actualMatchState and C_PvP and C_PvP.GetActiveMatchState then
            actualMatchState = C_PvP.GetActiveMatchState()
        end
        
        if actualMatchState == "complete" or actualMatchState == "finished" or actualMatchState == "ended" or 
           actualMatchState == "concluded" or actualMatchState == "done" then
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

        if not playerTracker.initialListCaptured then
            
            C_Timer.After(8, function()

                local timeSinceStart = GetTime() - bgStartTime
                if timeSinceStart >= 240 then
                    return
                end
                
                if insideBG and not playerTracker.initialListCaptured then
                    local apiDuration = 0
                    if C_PvP and C_PvP.GetActiveMatchDuration then
                        apiDuration = C_PvP.GetActiveMatchDuration() or 0
                        if apiDuration > 0 then
                            playerTracker.battleHasBegun = true
                            FlagStateDirty()
                        end
                    end
                    
                    local matchHasStarted = IsMatchStarted()
                    
                    local numPlayers = GetNumBattlefieldScores()
                    
                    if matchHasStarted then
                        CaptureInitialPlayerList(IsEpicBattleground())
                    end
                end
            end)
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




