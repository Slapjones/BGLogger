-- BGLogger: Battleground Statistics Tracker
local addonName = "BGLogger"
BGLoggerDB = BGLoggerDB or {}

---------------------------------------------------------------------
-- Config / globals
---------------------------------------------------------------------
local WINDOW, DetailLines, ListButtons = nil, {}, {}
local LINE_HEIGHT            = 20
local ROW_PADDING_Y          = 2
local WIN_W, WIN_H           = 1380, 820
local insideBG, matchSaved   = false, false
local bgStartTime            = 0
local MIN_BG_TIME            = 30  -- Minimum seconds in BG before saving
local GetWinner              = _G.GetBattlefieldWinner -- may be nil on some clients
-- Debug mode: false for production releases, can be toggled by users
local DEBUG_MODE             = false -- Set to false for production, true for development
local saveInProgress         = false
local ALLOW_TEST_EXPORTS     = DEBUG_MODE
-- 32-bit overflow detection constants
local UINT32_LIMIT           = 4294967295  -- 32-bit unsigned integer limit
local OVERFLOW_DETECTION_THRESHOLD = UINT32_LIMIT * 0.8  -- Detect when approaching overflow
local UINT32_RANGE           = UINT32_LIMIT + 1  -- 2^32 wrap amount to add per overflow
-- Removed unused timing detection variables since we now use C_PvP.GetActiveMatchDuration()

-- Overflow tracking timer
local overflowTrackingTimer = nil

-- Persisted per-battleground mapping of PVPStatID -> objective type
BGLoggerDB.__ObjectiveIdMap = BGLoggerDB.__ObjectiveIdMap or {}
local ObjectiveIdMap = BGLoggerDB.__ObjectiveIdMap

---------------------------------------------------------------------
-- Simple Player List Tracking
---------------------------------------------------------------------
local playerTracker = {
    initialPlayerList = {}, -- Players present at match start
    finalPlayerList = {},   -- Players present at match end (when we save)
    initialListCaptured = false,
    battleHasBegun = false,  -- Flag to track if we've seen the "battle has begun" message
    -- Overflow detection tracking
    damageHealing = {},     -- Track damage/healing values over time
    lastCheck = {},         -- Last recorded values for each player
    overflowDetected = {}   -- Track detected overflows
}

---------------------------------------------------------------------
-- Debug Functions
---------------------------------------------------------------------
local function Debug(msg)
    if DEBUG_MODE then
        print("|cff00ffffBGLogger:|r " .. tostring(msg))
    end
end

-- Expose debug printer for split modules
_G.BGLogger_Debug = Debug

-- Toggle debug mode for users
local function ToggleDebugMode()
    DEBUG_MODE = not DEBUG_MODE
    BGLoggerDB.debugMode = DEBUG_MODE -- Save to saved variables
    
    if DEBUG_MODE then
        print("|cff00ffffBGLogger:|r Debug mode |cff00ff00ENABLED|r")
        print("|cff00ffffBGLogger:|r You will now see detailed debug information")
        print("|cff00ffffBGLogger:|r Use '/bglogger debug' again to disable")
    else
        print("|cff00ffffBGLogger:|r Debug mode |cffff0000DISABLED|r")
        print("|cff00ffffBGLogger:|r Debug output is now hidden")
    end
end

-- Initialize debug mode from saved variables
local function InitializeDebugMode()
    if BGLoggerDB.debugMode ~= nil then
        DEBUG_MODE = BGLoggerDB.debugMode
    end
    -- Update dependent variables
    ALLOW_TEST_EXPORTS = DEBUG_MODE
end

---------------------------------------------------------------------
-- Simple Player List Tracking Functions
---------------------------------------------------------------------

-- Helper function to count table entries
local function tCount(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

-- Reset tracker for new battleground
local function ResetPlayerTracker()
    -- Only reset if we're not in the middle of a match
    if not insideBG or matchSaved then
        playerTracker.initialPlayerList = {}
        playerTracker.finalPlayerList = {}
        playerTracker.initialListCaptured = false
        playerTracker.initialCaptureRetried = false  -- Reset retry flag
        playerTracker.firstAttemptStats = nil  -- Reset retry stats
        playerTracker.battleHasBegun = false
        playerTracker.detectedAFKers = {}
        playerTracker.damageHealing = {}
        playerTracker.lastCheck = {}
        playerTracker.overflowDetected = {}
        -- In-progress BG tracking flags
        playerTracker.joinedInProgress = false
        playerTracker.playerJoinedInProgress = false
        Debug("Player tracker reset for new battleground")
    else
        Debug("Skipping tracker reset - still in active battleground")
    end
end

-- Generate unique player key
local function GetPlayerKey(name, realm)
    return (name or "Unknown") .. "-" .. (realm or "Unknown")
end

-- Determine if current battleground is an Epic BG where enemy team may be far away
local function IsEpicBattleground()
    local mapId = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player") or 0
    local info = mapId and C_Map.GetMapInfo and C_Map.GetMapInfo(mapId) or nil
    local name = (info and info.name or ""):lower()
    if name == "" then return false end
    return name:find("alterac") or name:find("isle of conquest") or name:find("wintergrasp") or name:find("ashran") or false
end

-- Count factions within a keyed player table { key -> { faction = "Alliance"|"Horde" } }
local function CountFactionsInTable(playerTable)
    local allianceCount, hordeCount = 0, 0
    for _, p in pairs(playerTable or {}) do
        if p and p.faction == "Alliance" then allianceCount = allianceCount + 1
        elseif p and p.faction == "Horde" then hordeCount = hordeCount + 1 end
    end
    return allianceCount, hordeCount
end

-- Format text to fit exactly in a fixed width, centered
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

-- Format text to fit exactly in a fixed width, left-aligned
local function FixedWidthLeft(text, width)
    text = tostring(text or "")
    if #text > width then
        text = string.sub(text, 1, width)
    end
    return text .. string.rep(" ", width - #text)
end

-- Format text to fit exactly in a fixed width, right-aligned  
local function FixedWidthRight(text, width)
    text = tostring(text or "")
    if #text > width then
        text = string.sub(text, 1, width)
    end
    return string.rep(" ", width - #text) .. text
end

---------------------------------------------------------------------
-- Overflow Detection Functions
---------------------------------------------------------------------

-- Track and detect 32-bit integer overflow for damage/healing
local function TrackPlayerStats()
    if not insideBG then return end
    
    local rows = GetNumBattlefieldScores()
    if rows == 0 then return end
    
    Debug("Tracking stats for overflow detection: " .. rows .. " players")
    
    for i = 1, rows do
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        if success and s and s.name then
            local playerName, realmName = s.name, ""
            
            -- Normalize realm like CollectScoreData to keep keys consistent
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
                realmName = GetRealmName() or "Unknown-Realm"
            end

            realmName = realmName:gsub("%s+", ""):gsub("'", "")
            
            local playerKey = GetPlayerKey(playerName, realmName)
            local currentDamage = s.damageDone or s.damage or 0
            local currentHealing = s.healingDone or s.healing or 0
            
            -- Initialize tracking for new players
            if not playerTracker.lastCheck[playerKey] then
                playerTracker.lastCheck[playerKey] = {
                    damage = currentDamage,
                    healing = currentHealing,
                    timestamp = GetTime()
                }
                playerTracker.overflowDetected[playerKey] = {
                    damageOverflows = 0,
                    healingOverflows = 0
                }
            else
                local lastData = playerTracker.lastCheck[playerKey]
                local overflowData = playerTracker.overflowDetected[playerKey]
                
                -- Check for damage overflow (current value significantly lower than previous)
                if currentDamage < lastData.damage and lastData.damage > OVERFLOW_DETECTION_THRESHOLD then
                    Debug("OVERFLOW DETECTED: " .. playerKey .. " damage dropped from " .. lastData.damage .. " to " .. currentDamage)
                    overflowData.damageOverflows = overflowData.damageOverflows + 1
                end
                
                -- Check for healing overflow
                if currentHealing < lastData.healing and lastData.healing > OVERFLOW_DETECTION_THRESHOLD then
                    Debug("OVERFLOW DETECTED: " .. playerKey .. " healing dropped from " .. lastData.healing .. " to " .. currentHealing)
                    overflowData.healingOverflows = overflowData.healingOverflows + 1
                end
                
                -- Update tracking data
                lastData.damage = currentDamage
                lastData.healing = currentHealing
                lastData.timestamp = GetTime()
            end
        end
    end
end

-- Get corrected damage/healing values accounting for overflow
local function GetCorrectedStats(playerKey, rawDamage, rawHealing)
    local overflowData = playerTracker.overflowDetected[playerKey]
    if not overflowData then
        return rawDamage, rawHealing
    end
    
    local correctedDamage = rawDamage + (overflowData.damageOverflows * UINT32_RANGE)
    local correctedHealing = rawHealing + (overflowData.healingOverflows * UINT32_RANGE)
    
    if overflowData.damageOverflows > 0 or overflowData.healingOverflows > 0 then
        Debug("CORRECTED STATS for " .. playerKey .. ":")
        Debug("  Raw damage: " .. rawDamage .. " -> Corrected: " .. correctedDamage .. " (" .. overflowData.damageOverflows .. " overflows)")
        Debug("  Raw healing: " .. rawHealing .. " -> Corrected: " .. correctedHealing .. " (" .. overflowData.healingOverflows .. " overflows)")
    end
    
    return correctedDamage, correctedHealing
end

---------------------------------------------------------------------
-- Objective Data Collection Functions
---------------------------------------------------------------------



-- NEW: Extract detailed objective data using the stats table (PVPStatInfo[])
local function ExtractObjectiveDataFromStats(scoreData)
    if not scoreData or not scoreData.stats then 
        Debug("No stats table available, falling back to legacy method")
        return nil  -- Will trigger fallback to legacy method
    end
    
    local objectiveBreakdown = {}
    local totalObjectives = 0
    local foundStats = {}
    
    Debug("Extracting objectives from stats table with " .. #scoreData.stats .. " entries")
    
    -- Scan through all PVP stats looking for objective-related ones
    for _, stat in ipairs(scoreData.stats) do
        local statName = (stat.name or ""):lower()
        local statValue = stat.pvpStatValue or 0
        local statID = stat.pvpStatID
        local originalName = stat.name or ""
        
        -- Check if this stat represents an objective based on name patterns
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
        
        -- Learn from historical mapping if available for this statID
        local learnedType = ObjectiveIdMap[statID]
        if learnedType and statValue > 0 then
            totalObjectives = totalObjectives + statValue
            objectiveBreakdown[learnedType] = (objectiveBreakdown[learnedType] or 0) + statValue
            table.insert(foundStats, { name = originalName, value = statValue, id = statID, type = learnedType })
            Debug("Found objective via learned mapping: ID " .. tostring(statID) .. " -> " .. learnedType .. " = " .. statValue)
        elseif isObjectiveStat and statValue > 0 then
            totalObjectives = totalObjectives + statValue
            
            -- Categorize the objective type based on name
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
                objectiveType = "objectives"  -- Generic catch-all
            end
            
            -- Add to breakdown (sum if multiple stats map to same type)
            objectiveBreakdown[objectiveType] = (objectiveBreakdown[objectiveType] or 0) + statValue
            
            table.insert(foundStats, {
                name = originalName,
                value = statValue,
                id = statID,
                type = objectiveType
            })
            Debug("Found objective stat: " .. originalName .. " = " .. statValue .. " -> " .. objectiveType .. " (ID: " .. tostring(statID) .. ")")
            -- Store learned mapping for future clarity
            ObjectiveIdMap[statID] = objectiveType
        end
    end
    
    if #foundStats > 0 then
        Debug("Stats-based extraction found " .. totalObjectives .. " total objectives from " .. #foundStats .. " stat types")
        Debug("Objective breakdown: " .. table.concat(
            (function()
                local parts = {}
                for k, v in pairs(objectiveBreakdown) do
                    table.insert(parts, k .. "=" .. v)
                end
                return parts
            end)(), ", "
        ))
        return totalObjectives, objectiveBreakdown
    else
        Debug("No objective stats found in stats table")
        return 0, {}
    end
end

-- LEGACY: Extract detailed objective data from scoreboard based on battleground type (fallback)
local function ExtractObjectiveDataLegacy(scoreData, battlegroundName)
    if not scoreData then return 0, {} end
    
    -- Normalize battleground name for comparison
    local bgName = (battlegroundName or ""):lower()
    local objectiveBreakdown = {}
    
    Debug("Using LEGACY ExtractObjectiveData for BG: " .. bgName)
    
    -- Battleground-specific objective extraction
    if bgName:find("warsong") or bgName:find("twin peaks") then
        -- Capture the Flag maps: focus on flag captures and returns
        local flagsCaptured = scoreData.flagsCaptured or 0
        local flagsReturned = scoreData.flagsReturned or 0
        local objectives = flagsCaptured + flagsReturned
        
        if flagsCaptured > 0 then objectiveBreakdown.flagsCaptured = flagsCaptured end
        if flagsReturned > 0 then objectiveBreakdown.flagsReturned = flagsReturned end
        
        Debug("CTF BG - Flags captured: " .. flagsCaptured .. ", returned: " .. flagsReturned .. ", total: " .. objectives)
        return objectives, objectiveBreakdown
        
    elseif bgName:find("temple of kotmogu") then
        -- Temple of Kotmogu: orb control points (can be very high numbers)
        -- Try multiple possible field names for orb score
        local orbScore = scoreData.orbScore or scoreData.objectives or scoreData.objectiveValue or 
                        scoreData.objectiveBG1 or scoreData.score or 0
        
        if orbScore > 0 then objectiveBreakdown.orbScore = orbScore end
        
        Debug("Temple of Kotmogu - Orb score: " .. orbScore)
        return orbScore, objectiveBreakdown
        
    elseif bgName:find("arathi basin") or bgName:find("battle for gilneas") or bgName:find("eye of the storm") then
        -- Resource-based battlegrounds: bases captured/defended
        local basesAssaulted = scoreData.basesAssaulted or 0
        local basesDefended = scoreData.basesDefended or 0
        local objectives = basesAssaulted + basesDefended
        
        if basesAssaulted > 0 then objectiveBreakdown.basesAssaulted = basesAssaulted end
        if basesDefended > 0 then objectiveBreakdown.basesDefended = basesDefended end
        
        Debug("Resource BG - Bases assaulted: " .. basesAssaulted .. ", defended: " .. basesDefended .. ", total: " .. objectives)
        return objectives, objectiveBreakdown
        
    elseif bgName:find("alterac valley") or bgName:find("isle of conquest") then
        -- Large battlegrounds: multiple objective types
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
        
        Debug("Large BG - Towers: " .. (towersAssaulted + towersDefended) .. ", GYs: " .. (graveyardsAssaulted + graveyardsDefended) .. ", Bases: " .. (basesAssaulted + basesDefended) .. ", total: " .. objectives)
        return objectives, objectiveBreakdown
        
    elseif bgName:find("strand") then
        -- Strand of the Ancients: gates destroyed/defended
        local gatesDestroyed = scoreData.gatesDestroyed or scoreData.objectiveBG1 or 0
        local gatesDefended = scoreData.gatesDefended or scoreData.objectiveBG2 or 0
        local objectives = gatesDestroyed + gatesDefended
        
        if gatesDestroyed > 0 then objectiveBreakdown.gatesDestroyed = gatesDestroyed end
        if gatesDefended > 0 then objectiveBreakdown.gatesDefended = gatesDefended end
        
        Debug("Strand - Gates destroyed: " .. gatesDestroyed .. ", defended: " .. gatesDefended .. ", total: " .. objectives)
        return objectives, objectiveBreakdown
        
    elseif bgName:find("silvershard") then
        -- Silvershard Mines: carts controlled/captured
        local cartsControlled = scoreData.cartsControlled or scoreData.objectiveBG1 or 0
        
        if cartsControlled > 0 then objectiveBreakdown.cartsControlled = cartsControlled end
        
        Debug("Silvershard - Carts controlled: " .. cartsControlled)
        return cartsControlled, objectiveBreakdown
        
    elseif bgName:find("deepwind") then
        -- Deepwind Gorge: capture points and flag captures
        local flagsCaptured = scoreData.flagsCaptured or 0
        local basesAssaulted = scoreData.basesAssaulted or 0
        local objectives = flagsCaptured + basesAssaulted
        
        if flagsCaptured > 0 then objectiveBreakdown.flagsCaptured = flagsCaptured end
        if basesAssaulted > 0 then objectiveBreakdown.basesAssaulted = basesAssaulted end
        
        Debug("Deepwind - Flags: " .. flagsCaptured .. ", bases: " .. basesAssaulted .. ", total: " .. objectives)
        return objectives, objectiveBreakdown
        
    elseif bgName:find("seething shore") then
        -- Seething Shore: azerite collected
        local azeriteCollected = scoreData.azeriteCollected or scoreData.objectives or scoreData.objectiveBG1 or 0
        
        if azeriteCollected > 0 then objectiveBreakdown.azeriteCollected = azeriteCollected end
        
        Debug("Seething Shore - Azerite collected: " .. azeriteCollected)
        return azeriteCollected, objectiveBreakdown
        
    elseif bgName:find("deephaul") then
        -- Deephaul Ravine: carts controlled/escorted
        local cartsEscorted = scoreData.cartsEscorted or scoreData.cartsControlled or scoreData.objectiveBG1 or 0
        
        if cartsEscorted > 0 then objectiveBreakdown.cartsControlled = cartsEscorted end
        
        Debug("Deephaul - Carts escorted: " .. cartsEscorted)
        return cartsEscorted, objectiveBreakdown
        
    elseif bgName:find("wintergrasp") or bgName:find("tol barad") then
        -- Wintergrasp/Tol Barad: structures destroyed/defended
        local structuresDestroyed = scoreData.structuresDestroyed or scoreData.objectiveBG1 or 0
        local structuresDefended = scoreData.structuresDefended or scoreData.objectiveBG2 or 0
        local objectives = structuresDestroyed + structuresDefended
        
        if structuresDestroyed > 0 then objectiveBreakdown.structuresDestroyed = structuresDestroyed end
        if structuresDefended > 0 then objectiveBreakdown.structuresDefended = structuresDefended end
        
        Debug("Epic BG - Structures destroyed: " .. structuresDestroyed .. ", defended: " .. structuresDefended .. ", total: " .. objectives)
        return objectives, objectiveBreakdown
        
    else
        -- Generic/unknown battleground: try all common objective fields
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
            cartsEscorted = "cartsControlled",  -- Map escorted to controlled
            orbScore = "orbScore",
            azeriteCollected = "azeriteCollected",
            structuresDestroyed = "structuresDestroyed",
            structuresDefended = "structuresDefended",
            demolishersDestroyed = "vehiclesDestroyed",
            vehiclesDestroyed = "vehiclesDestroyed",
            nodesAssaulted = "basesAssaulted",  -- Map nodes to bases
            nodesDefended = "basesDefended"
        }
        
        -- Generic fields to try
        local genericFields = {
            "objectives", "objectiveValue", "score",
            "objectiveBG1", "objectiveBG2", "objectiveBG3", "objectiveBG4"
        }
        
        -- Check mapped fields first
        for fieldName, breakdownKey in pairs(fieldMapping) do
            local value = scoreData[fieldName] or 0
            if value > 0 then
                objectives = objectives + value
                objectiveBreakdown[breakdownKey] = (objectiveBreakdown[breakdownKey] or 0) + value
                Debug("Generic BG - Found " .. fieldName .. ": " .. value .. " -> " .. breakdownKey)
            end
        end
        
        -- Check generic fields if no specific ones found
        if objectives == 0 then
            for _, field in ipairs(genericFields) do
                local value = scoreData[field] or 0
                if value > 0 then
                    objectives = objectives + value
                    objectiveBreakdown.objectives = (objectiveBreakdown.objectives or 0) + value
                    Debug("Generic BG - Found " .. field .. ": " .. value)
                end
            end
        end
        
        Debug("Generic/Unknown BG (" .. bgName .. ") - Total objectives: " .. objectives)
        return objectives, objectiveBreakdown
    end
end

-- MAIN: Extract objective data with stats-first approach and legacy fallback
local function ExtractObjectiveData(scoreData, battlegroundName)
    if not scoreData then return 0, {} end
    
    -- Method 1: Try the new stats-based extraction first
    local statsResult, statsBreakdown = ExtractObjectiveDataFromStats(scoreData)
    if statsResult ~= nil then
        Debug("Using stats-based objective extraction: " .. statsResult)
        return statsResult, statsBreakdown or {}
    end
    
    -- Method 2: Fall back to legacy field-based extraction
    Debug("Stats-based extraction failed, using legacy method")
    return ExtractObjectiveDataLegacy(scoreData, battlegroundName)
end

-- Determine what objective columns should be displayed for this battleground
local function GetObjectiveColumns(battlegroundName, playerDataList)
    local bgName = (battlegroundName or ""):lower()
    local availableObjectives = {}
    
    -- Scan all players to see what objective types actually have data
    for _, player in ipairs(playerDataList or {}) do
        if player.objectiveBreakdown then
            for objType, value in pairs(player.objectiveBreakdown) do
                if value > 0 then
                    availableObjectives[objType] = true
                end
            end
        end
    end
    
    -- Define column order and display names based on battleground type
    local columnDefinitions = {}
    
    -- Battleground-specific column layouts
    if bgName:find("warsong") or bgName:find("twin peaks") then
        -- Capture the Flag maps
        columnDefinitions = {
            {key = "flagsCaptured", name = "FC", tooltip = "Flags Captured"},
            {key = "flagsReturned", name = "FR", tooltip = "Flags Returned"}
        }
    elseif bgName:find("temple of kotmogu") then
        -- Temple of Kotmogu
        columnDefinitions = {
            {key = "orbScore", name = "Orb", tooltip = "Orb Score"}
        }
    elseif bgName:find("arathi") or bgName:find("battle for gilneas") or bgName:find("eye of the storm") then
        -- Resource-based battlegrounds
        columnDefinitions = {
            {key = "basesAssaulted", name = "BA", tooltip = "Bases Assaulted"},
            {key = "basesDefended", name = "BD", tooltip = "Bases Defended"}
        }
    elseif bgName:find("alterac valley") or bgName:find("isle of conquest") then
        -- Large battlegrounds with multiple objective types
        columnDefinitions = {
            {key = "towersAssaulted", name = "TA", tooltip = "Towers Assaulted"},
            {key = "towersDefended", name = "TD", tooltip = "Towers Defended"},
            {key = "graveyardsAssaulted", name = "GA", tooltip = "Graveyards Assaulted"},
            {key = "graveyardsDefended", name = "GD", tooltip = "Graveyards Defended"},
            {key = "basesAssaulted", name = "BA", tooltip = "Bases Assaulted"},
            {key = "basesDefended", name = "BD", tooltip = "Bases Defended"}
        }
    elseif bgName:find("strand") then
        -- Strand of the Ancients
        columnDefinitions = {
            {key = "gatesDestroyed", name = "GDest", tooltip = "Gates Destroyed"},
            {key = "gatesDefended", name = "GDef", tooltip = "Gates Defended"}
        }
    elseif bgName:find("silvershard") or bgName:find("deephaul") then
        -- Cart-based battlegrounds
        columnDefinitions = {
            {key = "cartsControlled", name = "Carts", tooltip = "Carts Controlled"}
        }
    elseif bgName:find("seething shore") then
        -- Seething Shore
        columnDefinitions = {
            {key = "azeriteCollected", name = "Azer", tooltip = "Azerite Collected"}
        }
    elseif bgName:find("deepwind") then
        -- Deepwind Gorge (mixed objectives)
        columnDefinitions = {
            {key = "flagsCaptured", name = "FC", tooltip = "Flags Captured"},
            {key = "basesAssaulted", name = "BA", tooltip = "Bases Assaulted"}
        }
    elseif bgName:find("wintergrasp") or bgName:find("tol barad") then
        -- Epic battlegrounds
        columnDefinitions = {
            {key = "structuresDestroyed", name = "SDest", tooltip = "Structures Destroyed"},
            {key = "structuresDefended", name = "SDef", tooltip = "Structures Defended"}
        }
    else
        -- Generic/unknown battleground - show all available objectives
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
    
    -- Filter columns to only show those that have data
    local activeColumns = {}
    for _, colDef in ipairs(columnDefinitions) do
        if availableObjectives[colDef.key] then
            table.insert(activeColumns, colDef)
        end
    end
    
    -- If no specific objectives found, fall back to the generic "objectives" column
    if #activeColumns == 0 then
        table.insert(activeColumns, {key = "objectives", name = "Obj", tooltip = "Total Objectives"})
    end
    
    Debug("Objective columns for " .. bgName .. ": " .. #activeColumns .. " active columns")
    for _, col in ipairs(activeColumns) do
        Debug("  " .. col.key .. " -> " .. col.name .. " (" .. col.tooltip .. ")")
    end
    
    return activeColumns
end

-- Start periodic overflow tracking
local function StartOverflowTracking()
    if overflowTrackingTimer then
        Debug("Overflow tracking already running")
        return
    end
    
    Debug("Starting overflow tracking")
    overflowTrackingTimer = C_Timer.NewTicker(5, function() -- Check every 5 seconds
        TrackPlayerStats()
    end)
end

-- Stop overflow tracking
local function StopOverflowTracking()
    if overflowTrackingTimer then
        overflowTrackingTimer:Cancel()
        overflowTrackingTimer = nil
        Debug("Stopped overflow tracking")
    end
end

-- Track initial player count to detect when enemy team becomes visible
local initialPlayerCount = 0

-- CONSERVATIVE match start detection - requires multiple confirmations
local function IsMatchStarted()
    Debug("*** IsMatchStarted() called ***")
    local rows = GetNumBattlefieldScores()
    if rows == 0 then 
        Debug("IsMatchStarted: No battlefield scores available")
        return false 
    end
    
    -- REQUIREMENT 1: Must have "battle has begun" message
    if not playerTracker.battleHasBegun then
        Debug("IsMatchStarted: Battle has not begun yet (no battle start message)")
        return false
    end
    
    -- REQUIREMENT 2: Check API duration (most reliable indicator)
    local apiDuration = 0
    if C_PvP and C_PvP.GetActiveMatchDuration then
        apiDuration = C_PvP.GetActiveMatchDuration() or 0
        Debug("IsMatchStarted: API duration = " .. apiDuration .. " seconds")
        
        -- If API shows active duration > 5 seconds, match has definitely started
        if apiDuration > 5 then
            Debug("IsMatchStarted: CONFIRMED via API duration > 5 seconds")
            return true
        elseif apiDuration == 0 then
            Debug("IsMatchStarted: API shows 0 duration - match not started")
            return false
        end
    else
        Debug("IsMatchStarted: API duration not available")
    end
    
    -- REQUIREMENT 3: Both factions must be visible (fallback check)
    local allianceCount, hordeCount = 0, 0
    
    for i = 1, math.min(rows, 20) do -- Only check first 20 players for performance
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        if success and s and s.name then
            local faction = nil
            
            -- Simplified faction detection
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
            
            -- Count by faction
            if faction == "Alliance" then
                allianceCount = allianceCount + 1
            elseif faction == "Horde" then
                hordeCount = hordeCount + 1
            end
        end
    end
    
    local bothFactionsVisible = (allianceCount > 0 and hordeCount > 0)
    local hasMinimumPlayers = (rows >= (IsEpicBattleground() and 10 or 15))
    
    -- REQUIREMENT 4: Minimum time since entering BG (prevent instant capture)
    local timeSinceEntered = GetTime() - bgStartTime
    local minimumWaitTime = IsEpicBattleground() and 20 or 45 -- Shorter for epics; enemy team is far but duration confirms start
    
    Debug("Match start requirements check:")
    Debug("  Battle begun message: " .. tostring(playerTracker.battleHasBegun))
    Debug("  API duration: " .. apiDuration .. " seconds")
    Debug("  Both factions visible: " .. tostring(bothFactionsVisible) .. " (A=" .. allianceCount .. ", H=" .. hordeCount .. ")")
    Debug("  Minimum players: " .. tostring(hasMinimumPlayers) .. " (" .. rows .. " total)")
    Debug("  Time since entered: " .. math.floor(timeSinceEntered) .. "s (min: " .. minimumWaitTime .. "s)")
    
    -- ALL requirements must be met
    local matchStarted = playerTracker.battleHasBegun and 
                        apiDuration > 0 and 
                        bothFactionsVisible and 
                        hasMinimumPlayers and
                        timeSinceEntered >= minimumWaitTime
    
    Debug("  FINAL RESULT: " .. tostring(matchStarted))
    
    return matchStarted
end

-- Capture initial player list (call this after match starts, when both teams are visible)
local function CaptureInitialPlayerList(skipMatchStartCheck)
    Debug("*** CaptureInitialPlayerList called (skipMatchStartCheck=" .. tostring(skipMatchStartCheck) .. ") ***")
    Debug("Already captured: " .. tostring(playerTracker.initialListCaptured))
    
    if playerTracker.initialListCaptured then 
        Debug("Initial player list already captured, skipping")
        return 
    end
    
    -- Critical: Only capture if match has actually started (both teams visible)
    -- Skip this check if called from a reliable source like PVP_MATCH_STATE_CHANGED
    if not skipMatchStartCheck and not IsMatchStarted() then
        Debug("Match hasn't started yet (enemy team not visible), skipping initial capture")
        return
    end
    
    if skipMatchStartCheck then
        Debug("*** SKIPPING MATCH START VALIDATION - called from reliable event source ***")
        Debug("Proceeding directly to capture logic")
    else
        Debug("Using match start validation (called from fallback/debug)")
    end
    
    local rows = GetNumBattlefieldScores()
    Debug("Battlefield scores available: " .. rows)
    
    if rows == 0 then 
        Debug("No battlefield scores available yet, skipping initial capture")
        return 
    end
    
    Debug("*** MATCH HAS STARTED - Starting initial capture with " .. rows .. " players ***")
    
    -- Clear any existing data
    playerTracker.initialPlayerList = {}
    
    -- Get the best realm name once for this capture session
    local playerRealm = GetRealmName() or "Unknown-Realm"
    if GetNormalizedRealmName and GetNormalizedRealmName() ~= "" then
        playerRealm = GetNormalizedRealmName()
    end
    Debug("Using player realm: '" .. playerRealm .. "'")
    
    local processedCount = 0
    local skippedCount = 0
    local keyCollisions = {}
    
    for i = 1, rows do
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        if success and s then
            Debug("Processing player " .. i .. ": " .. tostring(s.name or "NO_NAME"))
            
            -- Check for incomplete data (common in AV with distant players)
            if not s.name or s.name == "" then
                Debug("  SKIPPED: Player has no name (distant player in AV?)")
                skippedCount = skippedCount + 1
            else
                local playerName, realmName = s.name, ""
            
            if s.name:find("-") then
                playerName, realmName = s.name:match("^(.+)-(.+)$")
                Debug("  Split name: '" .. playerName .. "' realm: '" .. realmName .. "'")
            else
                Debug("  No realm in name, using fallback methods")
            end
            
            if (not realmName or realmName == "") and s.realm then
                realmName = s.realm
                Debug("  Using s.realm: '" .. realmName .. "'")
            end
            
            if (not realmName or realmName == "") and s.guid then
                local _, _, _, _, _, _, _, realmFromGUID = GetPlayerInfoByGUID(s.guid)
                if realmFromGUID and realmFromGUID ~= "" then
                    realmName = realmFromGUID
                    Debug("  Using GUID realm: '" .. realmName .. "'")
                end
            end
            
            if not realmName or realmName == "" then
                realmName = playerRealm
                Debug("  Using fallback playerRealm: '" .. realmName .. "'")
            end
            
            -- CRITICAL: Normalize realm name exactly like CollectScoreData does
            realmName = realmName:gsub("%s+", ""):gsub("'", "")
            Debug("  Normalized realm: '" .. realmName .. "'")
            
            local playerKey = GetPlayerKey(playerName, realmName)
            Debug("  Generated key: '" .. playerKey .. "'")
            
            -- Check for key collisions (happens with empty names in AV)
            if playerTracker.initialPlayerList[playerKey] then
                Debug("  KEY COLLISION: Key '" .. playerKey .. "' already exists!")
                Debug("    Existing: " .. (playerTracker.initialPlayerList[playerKey].name or "nil"))
                Debug("    New: " .. (playerName or "nil"))
                keyCollisions[playerKey] = (keyCollisions[playerKey] or 0) + 1
                
                -- Generate unique key for collision
                local uniqueKey = playerKey .. "_" .. i
                playerKey = uniqueKey
                Debug("    Using unique key: '" .. playerKey .. "'")
            end
            
            -- Enhanced class detection (same logic as CollectScoreData)
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
            
            -- Enhanced faction detection (same logic as CollectScoreData)
            local factionName = ""
            if s.faction == 0 then
                factionName = "Horde"
            elseif s.faction == 1 then
                factionName = "Alliance"
            else
                factionName = (s.faction == 0) and "Horde" or "Alliance"
            end
            
            -- Store complete player information
            playerTracker.initialPlayerList[playerKey] = {
                name = playerName,
                realm = realmName,
                class = className,
                spec = specName,
                faction = factionName,
                -- Store raw API data for debugging
                rawFaction = s.faction,
                rawSide = s.side,
                rawRace = s.race
            }
            Debug("  Added to initial list: " .. className .. " " .. factionName)
            processedCount = processedCount + 1
            
            -- Special check for current player
            if playerName == UnitName("player") then
                Debug("  THIS IS THE CURRENT PLAYER")
            end
            end
        else
            Debug("Failed to get score info for player " .. i)
            skippedCount = skippedCount + 1
        end
    end
    
    local initialCount = tCount(playerTracker.initialPlayerList)
    
    Debug("*** Initial capture COMPLETE ***")
    Debug("  Total API entries: " .. rows)
    Debug("  Successfully processed: " .. processedCount)
    Debug("  Skipped (no name): " .. skippedCount)
    Debug("  Final stored players: " .. initialCount)
    
    -- Show key collision information
    if next(keyCollisions) then
        Debug("  Key collisions detected:")
        for key, count in pairs(keyCollisions) do
            Debug("    '" .. key .. "': " .. count .. " collisions")
        end
    end
    
    -- Calculate data completeness ratio
    local completenessRatio = rows > 0 and (processedCount / rows) or 0
    local isLargeDisparity = skippedCount > 15 and completenessRatio < 0.7  -- More than 15 skipped AND less than 70% success rate
    
    -- Analysis for AV and retry logic
    local isEpicMap = IsEpicBattleground()
    local currentMap = C_Map.GetBestMapForUnit("player") or 0
    local mapInfo = C_Map.GetMapInfo(currentMap)
    local mapName = (mapInfo and mapInfo.name) or "Unknown"
    
    if isEpicMap then
        Debug("  EPIC BG DETECTED - Distance-based data limitations expected (" .. mapName .. ")")
        if skippedCount > 10 then
            Debug("    High skip count (" .. skippedCount .. ") is common due to player distance across the large map")
        end
    end
    
    -- Smart retry logic for large disparities
    if isLargeDisparity and not playerTracker.initialCaptureRetried then
        Debug("  LARGE DISPARITY DETECTED (" .. math.floor(completenessRatio * 100) .. "% success rate)")
        local retryDelay = isEpicMap and 25 or 12
        Debug("    Scheduling retry in " .. retryDelay .. " seconds to allow players to move closer (epic=" .. tostring(isEpicMap) .. ")...")
        
        -- Store first attempt stats for comparison
        playerTracker.firstAttemptStats = {
            rows = rows,
            processed = processedCount,
            skipped = skippedCount,
            stored = initialCount
        }
        
        playerTracker.initialCaptureRetried = true  -- Prevent infinite retries
        playerTracker.initialListCaptured = false   -- Allow retry
        
        C_Timer.After(retryDelay, function()
            if insideBG and not playerTracker.initialListCaptured then
                -- Force a fresh scoreboard update before retrying
                RequestBattlefieldScoreData()
                C_Timer.After(1.0, function()
            if insideBG and not playerTracker.initialListCaptured then
                Debug("RETRYING INITIAL CAPTURE (players should be closer now)")
                CaptureInitialPlayerList(true)  -- Skip match start check since we know it's started
                    else
                        Debug("Retry cancelled after refresh - no longer in BG or already captured")
                    end
                end)
            else
                Debug("Retry cancelled - no longer in BG or already captured")
            end
        end)
        
        return  -- Exit early, don't mark as captured yet
    end
    
    -- Show retry improvement stats if this was a retry
    if playerTracker.firstAttemptStats then
        local firstAttempt = playerTracker.firstAttemptStats
        local improvement = initialCount - firstAttempt.stored
        local newCompleteness = math.floor((processedCount / rows) * 100)
        local oldCompleteness = math.floor((firstAttempt.processed / firstAttempt.rows) * 100)
        
        Debug("  RETRY IMPROVEMENT:")
        Debug("    First attempt: " .. firstAttempt.stored .. " players (" .. oldCompleteness .. "% success)")
        Debug("    After retry: " .. initialCount .. " players (" .. newCompleteness .. "% success)")
        Debug("    Improvement: +" .. improvement .. " players")
        
        playerTracker.firstAttemptStats = nil  -- Clear stats
    end
    
    -- If on epic battlegrounds and both factions are not represented, do one immediate refresh attempt
    if IsEpicBattleground() then
        local aCount, hCount = CountFactionsInTable(playerTracker.initialPlayerList)
        if (aCount == 0 or hCount == 0) and not playerTracker.initialCaptureRetried then
            Debug("  Epic BG initial capture missing a faction (A=" .. aCount .. ", H=" .. hCount .. ") - forcing one more refresh")
            playerTracker.initialCaptureRetried = true
            RequestBattlefieldScoreData()
            C_Timer.After(1.5, function()
                if insideBG then
                    -- Do not clear previous entries; augment with any new visible players
                    local beforeCount = tCount(playerTracker.initialPlayerList)
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
                    local afterCount = tCount(playerTracker.initialPlayerList)
                    Debug("  After augmentation: " .. afterCount .. " players (added " .. (afterCount - beforeCount) .. ")")
                end
                playerTracker.initialListCaptured = true
            end)
            return
        end
    end

    playerTracker.initialListCaptured = true
    
    -- Show first few players as verification with complete info
    local count = 0
    for playerKey, playerInfo in pairs(playerTracker.initialPlayerList) do
        if count < 3 then
            Debug("  Sample: " .. playerKey .. " (" .. (playerInfo.class or "Unknown") .. " " .. (playerInfo.faction or "Unknown") .. ")")
            count = count + 1
        end
    end
end

-- Capture final player list (call this when saving match data)
local function CaptureFinalPlayerList(playerStats)
    Debug("*** CaptureFinalPlayerList called ***")
    Debug("Player stats provided: " .. #playerStats)
    
    -- Critical debug: Check if current player is in the provided data
    local currentPlayerName = UnitName("player")
    local currentPlayerRealm = GetRealmName() or "Unknown-Realm"
    local currentPlayerKey = GetPlayerKey(currentPlayerName, currentPlayerRealm)
    
    Debug("*** SEARCHING FOR CURRENT PLAYER ***")
    Debug("Current player name: '" .. currentPlayerName .. "'")
    Debug("Current player realm: '" .. currentPlayerRealm .. "'")
    Debug("Current player key: '" .. currentPlayerKey .. "'")
    
    local foundCurrentPlayer = false
    
    playerTracker.finalPlayerList = {}
    
    for i, player in ipairs(playerStats) do
        Debug("Processing final player " .. i .. ": " .. player.name .. "-" .. player.realm)
        
        local playerKey = GetPlayerKey(player.name, player.realm)
        Debug("  Generated key: '" .. playerKey .. "'")
        
        -- Check if this matches current player
        if player.name == currentPlayerName then
            Debug("  NAME MATCH - current player")
            foundCurrentPlayer = true
        end
        
        if playerKey == currentPlayerKey then
            Debug("  KEY MATCH - current player")
            foundCurrentPlayer = true
        end
        
        playerTracker.finalPlayerList[playerKey] = {
            name = player.name,
            realm = player.realm,
            playerData = player -- Keep reference to full player data
        }
        Debug("  Added to final list")
    end
    
    Debug("*** CURRENT PLAYER SEARCH RESULT ***")
    Debug("Found current player in final data: " .. tostring(foundCurrentPlayer))
    
    if not foundCurrentPlayer then
        Debug("*** ERROR: Current player NOT found in final player data! ***")
        Debug("This may trigger AFKer detection due to missing current player")
    end
    
    local finalCount = tCount(playerTracker.finalPlayerList)
    Debug("*** Final capture COMPLETE: " .. finalCount .. " players stored ***")
    
    -- Show first few players as verification
    local count = 0
    for playerKey, playerInfo in pairs(playerTracker.finalPlayerList) do
        if count < 3 then
            Debug("  Sample: " .. playerKey)
            count = count + 1
        end
    end
end

-- Simple comparison to determine AFKers and Backfills
local function AnalyzePlayerLists()
    Debug("*** AnalyzePlayerLists called ***")
    
    local afkers = {}
    local backfills = {}
    local normal = {}
    
    local initialCount = tCount(playerTracker.initialPlayerList)
    local finalCount = tCount(playerTracker.finalPlayerList)
    
    Debug("Initial list size: " .. initialCount)
    Debug("Final list size: " .. finalCount)
    Debug("Joined in progress: " .. tostring(playerTracker.joinedInProgress or false))
    
    if initialCount == 0 then
        if playerTracker.joinedInProgress then
            Debug("INFO: Initial list is EMPTY because player joined in-progress BG")
            Debug("All players will be marked as 'unknown' participation status")
        else
            Debug("WARNING: Initial list is EMPTY! Everyone will be marked as backfill!")
        end
    end
    
    if finalCount == 0 then
        Debug("WARNING: Final list is EMPTY! This shouldn't happen!")
        return afkers, backfills, normal
    end
    
    -- Handle in-progress BG joins differently
    if playerTracker.joinedInProgress then
        Debug("IN-PROGRESS BG ANALYSIS")
        Debug("Rule: Cannot reliably determine AFKers/Backfills - player joined mid-match")
        Debug("All players will be marked as 'unknown' participation status")
        
        -- Everyone on final scoreboard is treated as normal (can't determine backfill status)
        for playerKey, playerInfo in pairs(playerTracker.finalPlayerList) do
            local playerData = playerInfo.playerData
            -- Mark as unknown participation since we joined mid-match
            playerData.participationUnknown = true
            table.insert(normal, playerData)
            Debug("  Unknown participation: " .. playerKey .. " (joined mid-match)")
        end
        
        Debug("IN-PROGRESS ANALYSIS COMPLETE")
        Debug("Normal/Unknown players: " .. #normal)
        Debug("Backfills: 0 (cannot determine)")
        Debug("AFKers: 0 (cannot determine)")
        
    else
        Debug("STANDARD ANALYSIS")
        Debug("Rule 1: Anyone on final scoreboard = NOT an AFKer (they're still here)")
        Debug("Rule 2: Anyone on initial list = NOT a backfill (they were here from start)")
        
        Debug("Step 1: Finding AFKers (in initial but NOT on final scoreboard)")
        for playerKey, playerInfo in pairs(playerTracker.initialPlayerList) do
            if not playerTracker.finalPlayerList[playerKey] then
                table.insert(afkers, playerInfo)
                Debug("  AFKer: " .. playerKey .. " (was in initial, not on final scoreboard)")
            end
        end
        Debug("Found " .. #afkers .. " AFKers")
        
        Debug("Step 2: Processing final scoreboard - everyone here is NOT an AFKer")
        for playerKey, playerInfo in pairs(playerTracker.finalPlayerList) do
            local playerData = playerInfo.playerData
            
            if playerTracker.initialPlayerList[playerKey] then
                -- Was in initial list = normal player (not backfill, not AFKer)
                table.insert(normal, playerData)
                Debug("  Normal: " .. playerKey .. " (in initial list, on final scoreboard)")
            else
                -- Was NOT in initial list = backfill (not AFKer since they're on final scoreboard)
                table.insert(backfills, playerData)
                Debug("  Backfill: " .. playerKey .. " (NOT in initial list, on final scoreboard)")
            end
        end
        
        Debug("STANDARD ANALYSIS COMPLETE")
        Debug("Normal players: " .. #normal .. " (in initial, on final)")
        Debug("Backfills: " .. #backfills .. " (NOT in initial, on final)")
        Debug("AFKers: " .. #afkers .. " (in initial, NOT on final)")
    end
    
    -- Special check for current player
    local playerName = UnitName("player")
    local playerRealm = GetRealmName() or "Unknown-Realm"
    local yourKey = GetPlayerKey(playerName, playerRealm)
    
    Debug("YOUR STATUS CHECK")
    Debug("Your key: " .. yourKey)
    Debug("In initial: " .. (playerTracker.initialPlayerList[yourKey] and "YES" or "NO"))
    Debug("In final: " .. (playerTracker.finalPlayerList[yourKey] and "YES" or "NO"))
    Debug("Joined in progress: " .. tostring(playerTracker.playerJoinedInProgress or false))
    
    -- Determine your status using the appropriate rules
    local yourStatus = "UNKNOWN"
    if playerTracker.joinedInProgress then
        yourStatus = "JOINED IN-PROGRESS (participation status unknown)"
    elseif playerTracker.finalPlayerList[yourKey] then
        -- You're on final scoreboard = NOT AFKer
        if playerTracker.initialPlayerList[yourKey] then
            yourStatus = "NORMAL (in initial, on final)"
        else
            yourStatus = "BACKFILL (NOT in initial, on final)"
        end
    else
        -- You're NOT on final scoreboard
        if playerTracker.initialPlayerList[yourKey] then
            yourStatus = "AFKer (in initial, NOT on final)"
        else
            yourStatus = "ERROR: Not in either list!"
        end
    end
    
    Debug("Your status: " .. yourStatus)
    
    return afkers, backfills, normal
end

-- Debug function to show current tracking status
function DebugPlayerTracking()
    if not insideBG then
        print("=== Simple Player Tracking Debug ===")
        print("Not currently in a battleground")
        print("===================================")
        return
    end
    
    print("=== Simple Player Tracking Debug ===")
    print("Initial list captured: " .. tostring(playerTracker.initialListCaptured))
    
    -- Count initial players
    local initialCount = tCount(playerTracker.initialPlayerList)
    print("Initial players: " .. initialCount)
    
    -- Show some initial players
    if initialCount > 0 then
        print("Sample initial players:")
        local count = 0
        for playerKey, playerInfo in pairs(playerTracker.initialPlayerList) do
            if count < 5 then
                print("  " .. playerKey)
                count = count + 1
            else
                break
            end
        end
    end
    
    -- Count current players on scoreboard
    local currentPlayers = GetNumBattlefieldScores()
    print("Current scoreboard players: " .. currentPlayers)
    
    -- Show current player names for comparison
    if currentPlayers > 0 then
        print("Sample current players:")
        for i = 1, math.min(5, currentPlayers) do
            local success, s = pcall(C_PvP.GetScoreInfo, i)
            if success and s and s.name then
                local playerName, realmName = s.name, ""
                if s.name:find("-") then
                    playerName, realmName = s.name:match("^(.+)-(.+)$")
                end
                if (not realmName or realmName == "") and s.realm then
                    realmName = s.realm
                end
                if not realmName or realmName == "" then
                    realmName = GetRealmName() or "Unknown-Realm"
                end
                local playerKey = GetPlayerKey(playerName, realmName)
                local inInitial = playerTracker.initialPlayerList[playerKey] and "YES" or "NO"
                print("  " .. playerKey .. " (in initial: " .. inInitial .. ")")
            end
        end
    end
    
    print("===================================")
end

-- Simple participation system summary function
function GetParticipationSummary()
    print("=== Simple Participation Tracking System ===")
    print("How it works:")
    print("  1. Capture initial player list when match starts")
    print("     - ALL players present (6-80+ depending on BG type)")
    print("     - 10v10 BGs = ~20 players, Epic BGs = ~80 players")
    print("     - Can capture partial rosters if match starts early")
    print("  2. Capture final player list when match ends")
    print("  3. Compare the two lists:")
    print("")
    print("Backfill Detection:")
    print("  - Players in FINAL list but NOT in initial list")
    print("  - Flagged as 'BF' in player list (yellow text)")
    print("")
    print("AFKer Detection:")
    print("  - Players in initial list but NOT in final list")
    print("  - Listed separately at bottom (red text)")
    print("  - Not included in main statistics")
    print("")
    print("Status Codes in UI:")
    print("  OK - Normal participation (was there start to finish)")
    print("  BF - Backfill (joined during the match)")
    print("")
    print("AFKers are shown separately as: PlayerName-Realm (left before match ended)")
    print("==============================================")
end

-- Debug function to test the simple AFKer detection
function DebugAFKerDetection()
    print("=== COMPREHENSIVE AFKer Detection Debug ===")
    
    if not insideBG then
        print("Not currently in a battleground")
        print("==========================================")
        return
    end
    
    print("STEP 1: Current State")
    print("Initial list captured: " .. tostring(playerTracker.initialListCaptured))
    print("Initial list size: " .. tCount(playerTracker.initialPlayerList))
    print("Final list size: " .. tCount(playerTracker.finalPlayerList))
    print("")
    
    -- Show first 5 initial players
    if tCount(playerTracker.initialPlayerList) > 0 then
        print("First 5 initial players:")
        local count = 0
        for playerKey, playerInfo in pairs(playerTracker.initialPlayerList) do
            if count < 5 then
                print("  " .. playerKey)
                count = count + 1
            else
                break
            end
        end
    else
        print("*** WARNING: Initial list is EMPTY! ***")
    end
    print("")
    
    print("STEP 2: Current Scoreboard")
    local rows = GetNumBattlefieldScores()
    print("Current scoreboard players: " .. rows)
    
    -- Show current player keys and check against initial list
    if rows > 0 then
        print("Current players and initial list status:")
        for i = 1, math.min(10, rows) do
            local success, s = pcall(C_PvP.GetScoreInfo, i)
            if success and s and s.name then
                local playerName, realmName = s.name, ""
                if s.name:find("-") then
                    playerName, realmName = s.name:match("^(.+)-(.+)$")
                end
                if (not realmName or realmName == "") and s.realm then
                    realmName = s.realm
                end
                if not realmName or realmName == "" then
                    realmName = GetRealmName() or "Unknown-Realm"
                end
                local playerKey = GetPlayerKey(playerName, realmName)
                local inInitial = playerTracker.initialPlayerList[playerKey] and "YES" or "NO"
                print("  " .. playerKey .. " -> in initial: " .. inInitial)
                
                -- Check if this is the current player
                if playerName == UnitName("player") then
                    print("    *** THIS IS YOU ***")
                end
            end
        end
    end
    print("")
    
    print("STEP 3: Simulating Detection Process")
    
    -- Simulate what happens during save
    local testData = CollectScoreData()
    print("CollectScoreData returned " .. #testData .. " players")
    print("AFKers detected: " .. #(playerTracker.detectedAFKers or {}))
    
    -- Show what YOU are being detected as
    local playerName = UnitName("player")
    local playerRealm = GetRealmName() or "Unknown-Realm"
    local yourKey = GetPlayerKey(playerName, playerRealm)
    
    print("")
    print("STEP 4: YOUR STATUS")
    print("Your key: " .. yourKey)
    print("In initial list: " .. (playerTracker.initialPlayerList[yourKey] and "YES" or "NO"))
    print("In final list: " .. (playerTracker.finalPlayerList[yourKey] and "YES" or "NO"))
    
    -- Check if you're in the test data
    local youInTestData = false
    local youMarkedAsBackfill = false
    for _, player in ipairs(testData) do
        local testKey = GetPlayerKey(player.name, player.realm)
        if testKey == yourKey then
            youInTestData = true
            youMarkedAsBackfill = player.isBackfill
            break
        end
    end
    
    print("In test data: " .. (youInTestData and "YES" or "NO"))
    print("Marked as backfill: " .. (youMarkedAsBackfill and "YES" or "NO"))
    
    -- Check if you're in AFKer list
    local youInAFKList = false
    for _, afker in ipairs(playerTracker.detectedAFKers or {}) do
        if GetPlayerKey(afker.name, afker.realm) == yourKey then
            youInAFKList = true
            break
        end
    end
    print("In AFKer list: " .. (youInAFKList and "YES" or "NO"))
    
    print("==========================================")
end

-- Force capture initial list (for testing)
function ForceCaptureInitialList()
    if not insideBG then
        print("Not in a battleground")
        return
    end
    
    print("Forcing initial list capture...")
    print("Match started check: " .. tostring(IsMatchStarted()))
    
    if not IsMatchStarted() then
        print("WARNING: Match hasn't started yet - enemy team may not be visible!")
        print("This may result in incorrect backfill detection.")
        print("Proceeding anyway for testing purposes...")
    end
    
    playerTracker.initialListCaptured = false -- Reset flag
    CaptureInitialPlayerList(false) -- Use validation for manual force capture
end

-- Force capture bypassing all checks (emergency testing)
function ForceCaptureBypassed()
    if not insideBG then
        print("Not in a battleground")
        return
    end
    
    print("*** EMERGENCY BYPASS CAPTURE ***")
    print("Bypassing all match start checks...")
    
    local rows = GetNumBattlefieldScores()
    print("Scoreboard players: " .. rows)
    
    if rows == 0 then
        print("No players on scoreboard!")
        return
    end
    
    -- Reset and capture directly
    playerTracker.initialPlayerList = {}
    playerTracker.initialListCaptured = false
    
    for i = 1, rows do
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        if success and s and s.name then
            local playerName, realmName = s.name, ""
            
            if s.name:find("-") then
                playerName, realmName = s.name:match("^(.+)-(.+)$")
            end
            
            if not realmName or realmName == "" then
                realmName = GetRealmName() or "Unknown-Realm"
            end
            
            local playerKey = GetPlayerKey(playerName, realmName)
            playerTracker.initialPlayerList[playerKey] = {
                name = playerName,
                realm = realmName
            }
            print("  Added: " .. playerKey)
        end
    end
    
    playerTracker.initialListCaptured = true
    local count = tCount(playerTracker.initialPlayerList)
    print("*** BYPASS CAPTURE COMPLETE: " .. count .. " players ***")
end

-- Complete reset of tracking data (for debugging)
function ResetPlayerTracking()
    print("BGLogger: RESETTING all player tracking data")
    
    playerTracker = {
        initialPlayerList = {},
        finalPlayerList = {},
        initialListCaptured = false,
        detectedAFKers = {}
    }
    
    print("BGLogger: Player tracking reset complete")
    print("Initial list captured: " .. tostring(playerTracker.initialListCaptured))
    print("Initial list size: " .. tCount(playerTracker.initialPlayerList))
end

-- Debug function to show raw scoreboard data
function DebugScoreboardData()
    if not insideBG then
        print("=== Scoreboard Data Debug ===")
        print("Not currently in a battleground")
        print("=============================")
        return
    end
    
    print("=== RAW SCOREBOARD DATA DEBUG ===")
    
    local rows = GetNumBattlefieldScores()
    print("Total players: " .. rows)
    
    if rows == 0 then
        print("No scoreboard data available")
        print("=================================")
        return
    end
    
    -- Show raw data for first few players
    for i = 1, math.min(5, rows) do
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        if success and s and s.name then
            print("Player " .. i .. ": " .. s.name)
            print("  Raw data available:")
            for key, value in pairs(s) do
                print("    " .. key .. " = " .. tostring(value) .. " (type: " .. type(value) .. ")")
            end
            print("")
        else
            print("Player " .. i .. ": Failed to get data")
        end
    end
    
    print("=================================")
end

-- Debug function to test match start detection
function DebugMatchStart()
    if not insideBG then
        print("=== Match Start Detection Debug ===")
        print("Not currently in a battleground")
        print("==================================")
        return
    end
    
    print("=== Match Start Detection Debug ===")
    
    local rows = GetNumBattlefieldScores()
    print("Total players on scoreboard: " .. rows)
    
    if rows == 0 then
        print("No players visible - still loading or not in BG")
        print("==================================")
        return
    end
    
    -- First, let's see what data we actually have
    print("Raw data sample (first player):")
    local success, firstPlayer = pcall(C_PvP.GetScoreInfo, 1)
    if success and firstPlayer then
        for key, value in pairs(firstPlayer) do
            print("  " .. key .. " = " .. tostring(value))
        end
    end
    print("")
    
    local allianceCount, hordeCount = 0, 0
    local unknownCount = 0
    
    print("Player faction analysis:")
    
    for i = 1, math.min(10, rows) do -- Show first 10 players
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        if success and s and s.name then
            local faction = "Unknown"
            local detectionMethod = "none"
            
            -- Try to determine faction using multiple methods
            if s.faction then
                faction = s.faction
                detectionMethod = "s.faction"
            elseif s.side ~= nil then
                if s.side == "Alliance" or s.side == "Horde" then
                    faction = s.side
                    detectionMethod = "s.side (string)"
                elseif s.side == 0 then
                    faction = "Horde"
                    detectionMethod = "s.side == 0"
                elseif s.side == 1 then
                    faction = "Alliance"
                    detectionMethod = "s.side == 1"
                else
                    detectionMethod = "s.side unknown value: " .. tostring(s.side)
                end
            end
            
            -- Race-based detection as fallback
            if faction == "Unknown" and s.race then
                local allianceRaces = {
                    ["Human"] = true, ["Dwarf"] = true, ["Night Elf"] = true, ["Gnome"] = true,
                    ["Draenei"] = true, ["Worgen"] = true, ["Void Elf"] = true, ["Lightforged Draenei"] = true,
                    ["Dark Iron Dwarf"] = true, ["Kul Tiran"] = true, ["Mechagnome"] = true, ["Pandaren"] = true
                }
                
                if allianceRaces[s.race] then
                    faction = "Alliance"
                    detectionMethod = "race-based (Alliance)"
                else
                    faction = "Horde"
                    detectionMethod = "race-based (Horde)"
                end
            end
            
            print("  " .. s.name .. " -> " .. faction .. " [" .. detectionMethod .. "]")
            print("    race: " .. tostring(s.race) .. ", side: " .. tostring(s.side) .. ", faction: " .. tostring(s.faction))
            
            if faction == "Alliance" then
                allianceCount = allianceCount + 1
            elseif faction == "Horde" then
                hordeCount = hordeCount + 1
            else
                unknownCount = unknownCount + 1
            end
        end
    end
    
    if rows > 10 then
        print("  ... (showing first 10 of " .. rows .. " players)")
        
        -- Count remaining players for totals
        for i = 11, rows do
            local success, s = pcall(C_PvP.GetScoreInfo, i)
            if success and s and s.name then
                local faction = "Unknown"
                
                if s.faction then
                    faction = s.faction
                elseif s.side ~= nil then
                    if s.side == "Alliance" or s.side == "Horde" then
                        faction = s.side
                    elseif s.side == 0 then
                        faction = "Horde"
                    elseif s.side == 1 then
                        faction = "Alliance"
                    end
                elseif s.race then
                    local allianceRaces = {
                        ["Human"] = true, ["Dwarf"] = true, ["Night Elf"] = true, ["Gnome"] = true,
                        ["Draenei"] = true, ["Worgen"] = true, ["Void Elf"] = true, ["Lightforged Draenei"] = true,
                        ["Dark Iron Dwarf"] = true, ["Kul Tiran"] = true, ["Mechagnome"] = true, ["Pandaren"] = true
                    }
                    
                    if allianceRaces[s.race] then
                        faction = "Alliance"
                    else
                        faction = "Horde"
                    end
                end
                
                if faction == "Alliance" then
                    allianceCount = allianceCount + 1
                elseif faction == "Horde" then
                    hordeCount = hordeCount + 1
                else
                    unknownCount = unknownCount + 1
                end
            end
        end
    end
    
    print("")
    print("TOTALS:")
    print("Alliance players: " .. allianceCount)
    print("Horde players: " .. hordeCount)
    print("Unknown faction: " .. unknownCount)
    print("")
    
    local matchStarted = IsMatchStarted()
    print("MATCH STARTED: " .. tostring(matchStarted))
    
    if not matchStarted then
        if allianceCount > 0 and hordeCount == 0 then
            print("Reason: Only Alliance players visible (preparation phase)")
        elseif hordeCount > 0 and allianceCount == 0 then
            print("Reason: Only Horde players visible (preparation phase)")
        elseif allianceCount == 0 and hordeCount == 0 then
            print("Reason: No players detected with valid factions")
        else
            print("Reason: Unknown (both factions detected but IsMatchStarted returned false)")
        end
    else
        print("Both factions are visible - match has started!")
    end
    
    print("==================================")
end

-- Debug function to test CollectScoreData directly
function DebugCollectScoreData()
    if not insideBG then
        print("=== CollectScoreData Debug ===")
        print("Not currently in a battleground")
        print("=============================")
        return
    end
    
    print("=== CollectScoreData Debug ===")
    print("Testing CollectScoreData function directly...")
    
    local data = CollectScoreData(999) -- Use high attempt number to identify debug run
    
    print("CollectScoreData returned " .. #data .. " players")
    
    local currentPlayerName = UnitName("player")
    local foundInData = false
    
    for i, player in ipairs(data) do
        if player.name == currentPlayerName then
            foundInData = true
            print("Current player found in data at position " .. i)
            print("  Name: " .. player.name)
            print("  Realm: " .. player.realm)
            print("  Faction: " .. player.faction)
            print("  Class: " .. player.class)
            break
        end
    end
    
    if not foundInData then
        print("*** Current player NOT found in CollectScoreData result! ***")
    end
    
    print("=============================")
end

-- Debug function to test the NEW conservative match start detection
function DebugConservativeMatchStart()
    if not insideBG then
        print("=== Conservative Match Start Debug ===")
        print("Not currently in a battleground")
        print("=====================================")
        return
    end
    
    print("=== Conservative Match Start Debug ===")
    print("Testing new conservative IsMatchStarted() logic...")
    
    -- Show current status
    print("Current tracking status:")
    print("  Inside BG: " .. tostring(insideBG))
    print("  Initial list captured: " .. tostring(playerTracker.initialListCaptured))
    print("  Battle begun flag: " .. tostring(playerTracker.battleHasBegun))
    print("  BG start time: " .. bgStartTime)
    print("  Time since entered: " .. math.floor(GetTime() - bgStartTime) .. " seconds")
    
    -- Test API duration
    if C_PvP and C_PvP.GetActiveMatchDuration then
        local apiDuration = C_PvP.GetActiveMatchDuration() or 0
        print("  API match duration: " .. apiDuration .. " seconds")
    else
        print("  API match duration: Not available")
    end
    
    -- Test the conservative match start detection
    print("\nTesting conservative match start detection:")
    local result = IsMatchStarted()
    print("IsMatchStarted() result: " .. tostring(result))
    
    if result then
        print("*** CONSERVATIVE VALIDATION PASSED - Match has started ***")
    else
        print("*** CONSERVATIVE VALIDATION FAILED - Match not started ***")
        print("This is the expected behavior if you're still in preparation phase")
    end
    
    print("=====================================")
end

-- Simple function to check tracking status
function CheckTrackingStatus()
    print("=== TRACKING STATUS ===")
    print("Inside BG: " .. tostring(insideBG))
    print("Initial list captured: " .. tostring(playerTracker.initialListCaptured))
    print("Initial list size: " .. tCount(playerTracker.initialPlayerList))
    print("Final list size: " .. tCount(playerTracker.finalPlayerList))
    
    if tCount(playerTracker.initialPlayerList) > 0 then
        print("Sample initial players:")
        local count = 0
        for playerKey, _ in pairs(playerTracker.initialPlayerList) do
            if count < 3 then
                print("  " .. playerKey)
                count = count + 1
            end
        end
    else
        print("*** INITIAL LIST IS EMPTY! ***")
    end
    
    print("Match started check: " .. tostring(IsMatchStarted()))
    print("======================")
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
    
    -- Try connected realms
    local connectedRealms = GetAutoCompleteRealms()
    if connectedRealms and #connectedRealms > 0 then
        return connectedRealms[1]
    end
    
    return "Unknown-Realm"
end

---------------------------------------------------------------------
-- Hash Generation Functions for BGLogger
---------------------------------------------------------------------
-- Moved to BGLogger_Hash.lua

-- Enhanced battleground detection function
local function UpdateBattlegroundStatus()
    local _, instanceType = IsInInstance()
    local inBG = false
    
    -- Multiple methods to detect if we're in a battleground
    if instanceType == "pvp" then
        inBG = true
        Debug("BG detected via instanceType")
    elseif C_PvP and C_PvP.IsBattleground and C_PvP.IsBattleground() then
        inBG = true
        Debug("BG detected via C_PvP.IsBattleground")
    elseif GetNumBattlefieldScores() > 0 then
        inBG = true
        Debug("BG detected via battlefield scores")
    elseif UnitInBattleground("player") then
        inBG = true
        Debug("BG detected via UnitInBattleground")
    end
    
    return inBG
end

-- Normalize battleground names to match website expectations
local function NormalizeBattlegroundName(mapName)
    local nameMap = {
        ["Ashran"] = "Ashran",
        ["Wintergrasp"] = "Battle for Wintergrasp", 
        ["Tol Barad"] = "Tol Barad",
        ["The Battle for Gilneas"] = "Battle for Gilneas",
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
        ["Twin Peaks"] = "Twin Peaks"
    }
    
    return nameMap[mapName] or mapName
end

local function CollectScoreData(attemptNumber)
    attemptNumber = attemptNumber or 1
    local t, rows = {}, GetNumBattlefieldScores()
    Debug("CollectScoreData attempt #" .. attemptNumber .. ": Found " .. rows .. " battlefield score rows")
    
    -- Safety check
    if rows == 0 then
        Debug("WARNING: No battlefield scores available on attempt " .. attemptNumber)
        return {}
    end
    
    -- Debug: Track current player
    local currentPlayerName = UnitName("player")
    local currentPlayerRealm = GetRealmName() or "Unknown-Realm"
    -- Normalize current player's realm the same way as scoreboard entries
    currentPlayerRealm = currentPlayerRealm:gsub("%s+", ""):gsub("'", "")
    Debug("*** CollectScoreData: Looking for current player ***")
    Debug("Current player: " .. currentPlayerName .. "-" .. currentPlayerRealm)
    local foundCurrentPlayer = false
    
    local playerRealm = GetBestRealmName()
    local successfulReads = 0
    local failedReads = 0
    
    -- Process all players
    for i = 1, rows do
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        
        if success and s and s.name then
            successfulReads = successfulReads + 1
            
            -- Enhanced realm detection (keep your existing code)
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
            
            -- Enhanced class detection (keep your existing code)
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
            
            -- Faction detection
            local factionName = ""
            if s.faction == 0 then
                factionName = "Horde"
            elseif s.faction == 1 then
                factionName = "Alliance"
            else
                factionName = (s.faction == 0) and "Horde" or "Alliance"
            end
            
            -- Debug: Check if this is current player
            if playerName == currentPlayerName then
                Debug("*** FOUND CURRENT PLAYER in CollectScoreData ***")
                Debug("  Name: " .. playerName .. " (matches: " .. currentPlayerName .. ")")
                Debug("  Realm: " .. realmName .. " (current: " .. currentPlayerRealm .. ")")
                foundCurrentPlayer = true
            end
            
            -- Get raw damage/healing values
            local rawDamage = s.damageDone or s.damage or 0
            local rawHealing = s.healingDone or s.healing or 0
            
            -- Apply overflow correction
            local playerKey = GetPlayerKey(playerName, realmName)
            local correctedDamage, correctedHealing = GetCorrectedStats(playerKey, rawDamage, rawHealing)
            
            -- Extract objective data
            local map = C_Map.GetBestMapForUnit("player") or 0
            local mapInfo = C_Map.GetMapInfo(map)
            local battlegroundName = (mapInfo and mapInfo.name) or "Unknown"
            local objectives, objectiveBreakdown = ExtractObjectiveData(s, battlegroundName)
            
            -- Create player data (participation will be determined later)
            local playerData = {
                name = playerName,
                realm = realmName,
                faction = factionName,
                class = className,
                spec = specName,
                damage = correctedDamage,
                healing = correctedHealing,
                kills = s.killingBlows or s.kills or 0,
                deaths = s.deaths or 0,
                honorableKills = s.honorableKills or s.honorKills or 0,
                objectives = objectives,
                objectiveBreakdown = objectiveBreakdown or {},
                -- Overflow tracking data
                rawDamage = rawDamage,
                rawHealing = rawHealing,
                damageOverflows = playerTracker.overflowDetected[playerKey] and playerTracker.overflowDetected[playerKey].damageOverflows or 0,
                healingOverflows = playerTracker.overflowDetected[playerKey] and playerTracker.overflowDetected[playerKey].healingOverflows or 0,
                -- Will be set later by the simple list comparison
                isBackfill = false,
                isAfker = false
            }
            
            t[#t+1] = playerData
        else
            failedReads = failedReads + 1
            if i <= 5 then -- Only debug first few failures to avoid spam
                Debug("Failed to read player " .. i .. ": " .. tostring(s and s.name or "nil"))
            end
        end
    end
    
    Debug("CollectScoreData completed: " .. successfulReads .. " successful, " .. failedReads .. " failed")
    
    Debug("*** CollectScoreData RESULT ***")
    Debug("Found current player: " .. tostring(foundCurrentPlayer))
    if not foundCurrentPlayer then
        Debug("*** ERROR: Current player NOT found in scoreboard data! ***")
        Debug("This will cause AFKer detection!")
    end
    
    -- Simple AFKer/Backfill analysis using the data we just collected
    Debug("*** Performing AFKer/Backfill analysis ***")
    Debug("Final data has " .. #t .. " players")
    Debug("Initial list has " .. tCount(playerTracker.initialPlayerList) .. " players")
    
    -- Create AFKer list unless we joined in-progress (in which case AFK/backfill analysis isn't valid)
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
                -- Use complete player information from initial capture
                local afkerData = {
                    name = playerInfo.name,
                    realm = playerInfo.realm,
                    class = playerInfo.class or "Unknown",
                    spec = playerInfo.spec or "",
                    faction = playerInfo.faction or "Unknown"
                }
                table.insert(afkers, afkerData)
                Debug("AFKer: " .. playerKey .. " (" .. afkerData.class .. " " .. afkerData.faction .. " - in initial, not in final)")
            end
        end
    else
        Debug("Joined in-progress: suppressing AFKer detection for this log")
    end
    
    -- Set participation flags for each player in final data
    for _, player in ipairs(t) do
        local playerKey = GetPlayerKey(player.name, player.realm)
        
        if playerTracker.joinedInProgress then
            -- In-progress join: only uploader (current player) counts as backfill, others unaffected
            local isCurrent = (player.name == currentPlayerName and player.realm == currentPlayerRealm)
            player.isBackfill = isCurrent
            player.participationUnknown = not isCurrent
            if isCurrent then
                Debug("Backfill (self): " .. playerKey .. " (joined mid-match)")
            else
                Debug("Unknown participation: " .. playerKey .. " (joined mid-match)")
            end
        else
            -- Normal join: use standard logic
            if not playerTracker.initialPlayerList[playerKey] then
                player.isBackfill = true
                Debug("Backfill: " .. playerKey .. " (not in initial)")
            else
                player.isBackfill = false
                Debug("Normal: " .. playerKey .. " (in initial)")
            end
            player.participationUnknown = false
        end
    end
    
    -- Store AFKer list for later use in exports
    playerTracker.detectedAFKers = afkers
    
    Debug("Analysis complete: " .. #afkers .. " AFKers, " .. #t .. " final players")
    
    return t
end

local function DetectAvailableAPIs()
    local apis = {
        GetWinner = _G.GetBattlefieldWinner,
        IsRatedBattleground = _G.IsRatedBattleground,
        IsInBrawl = C_PvP and C_PvP.IsInBrawl,
        IsSoloRBG = C_PvP and C_PvP.IsSoloRBG,
        IsBattleground = C_PvP and C_PvP.IsBattleground,
        GetActiveMatchDuration = C_PvP and C_PvP.GetActiveMatchDuration,
        GetPlayerInfoByGUID = _G.GetPlayerInfoByGUID,
        GetClassInfo = _G.GetClassInfo,
        GetRealmName = _G.GetRealmName,
    }
    
    Debug("Available APIs:")
    for name, func in pairs(apis) do
        Debug("  " .. name .. ": " .. (func and "Available" or "Not Available"))
    end
    
    return apis
end

local function CommitMatch(list)
    Debug("CommitMatch called, matchSaved=" .. tostring(matchSaved) .. ", list size=" .. #list)
    
    if matchSaved then
        Debug("Match already saved, not saving again")
        return
    end
    
    if #list == 0 then
        Debug("Empty player list, cannot save")
        return
    end

    local success, result = pcall(function()
        local map = C_Map.GetBestMapForUnit("player") or 0
        Debug("Map ID: " .. map)
        
        local currentTime = GetTime()
        Debug("Saving match at time: " .. currentTime)
        
        -- SIMPLIFIED: Use C_PvP.GetActiveMatchDuration() API for accurate duration
        local duration = 0
        local trueDuration = 0
        local durationSource = "unknown"
        
        -- Method 1: Try to get match duration from API (most accurate)
        if C_PvP and C_PvP.GetActiveMatchDuration then
            local apiDuration = C_PvP.GetActiveMatchDuration()
            if apiDuration and apiDuration > 0 and apiDuration < 7200 then -- Reasonable duration (less than 2 hours)
                duration = math.floor(apiDuration)
                trueDuration = duration
                durationSource = "C_PvP.GetActiveMatchDuration"
                Debug("Duration from API: " .. duration .. " seconds")
            else
                Debug("API returned invalid duration: " .. tostring(apiDuration))
            end
        else
            Debug("C_PvP.GetActiveMatchDuration not available")
        end
        
        -- Method 2: Fallback to estimated duration if API failed
        if duration == 0 then
            -- Calculate time since BG started as fallback
            local timeSinceBGStart = math.floor(currentTime - bgStartTime)
            
            -- Safety check for fallback duration
            if timeSinceBGStart > 0 and timeSinceBGStart < 7200 then -- Reasonable duration
                trueDuration = timeSinceBGStart
                durationSource = "calculated_fallback"
                Debug("Using fallback duration from bgStartTime: " .. trueDuration .. " seconds")
            else
                -- Last resort: default duration
                trueDuration = 900 -- 15 minutes default
                durationSource = "default_estimate"
                Debug("Using default duration estimate: " .. trueDuration .. " seconds")
            end
            
            duration = trueDuration
            if playerTracker.joinedInProgress then
                -- User joined late: mark duration as unreliable unless API provided it
                Debug("Joined in-progress: duration is a fallback estimate")
            end
        end
        
        Debug("Final duration: " .. duration .. " seconds (source: " .. durationSource .. ")")
        
        -- Determine winner
        local winner = ""
        if GetWinner then
            local winnerFaction = GetWinner()
            if winnerFaction == 0 then
                winner = "Horde"
            elseif winnerFaction == 1 then
                winner = "Alliance"
            end
        end
        
                -- SIMPLIFIED: Use reliable API calls for battleground type detection
        local bgType = "non-rated"

        -- Method 1: Brawl detection (highest priority - overrides everything else)
        if C_PvP and C_PvP.IsInBrawl and C_PvP.IsInBrawl() then
            bgType = "brawl"
            Debug("Detected BRAWL via C_PvP.IsInBrawl()")
        
        -- Method 2: Blitz detection using the specific API
        elseif C_PvP and C_PvP.IsSoloRBG and C_PvP.IsSoloRBG() then
            bgType = "rated-blitz"
            Debug("Detected RATED BLITZ via C_PvP.IsSoloRBG()")
        
        -- Method 3: Standard rated BG detection (10v10 rated BGs)
        elseif IsRatedBattleground and IsRatedBattleground() then
            bgType = "rated"
            Debug("Detected RATED BG via IsRatedBattleground()")
        
        -- Method 4: Check if it's a regular unrated battleground
        elseif C_PvP and C_PvP.IsBattleground and C_PvP.IsBattleground() then
            bgType = "non-rated"
            Debug("Detected NON-RATED BG via C_PvP.IsBattleground()")
        
        -- Method 5: Fallback detection (should rarely be needed now)
        else
            -- If none of the APIs work, try to determine based on context
            Debug("API detection failed, using fallback logic")
            
            -- Check for rated BG bracket as fallback
            if C_PvP and C_PvP.GetActiveMatchBracket then
                local bracket = C_PvP.GetActiveMatchBracket()
                if bracket and bracket > 0 then
                    bgType = "rated-blitz"
                    Debug("Fallback: Detected Blitz via GetActiveMatchBracket: " .. bracket)
                end
            end
            
            -- If still unknown, default to non-rated
            if bgType == "non-rated" then
                Debug("Fallback: Defaulting to non-rated battleground")
            end
        end

        Debug("Final BG type determined: " .. bgType)
        
        -- Get map name
        local mapInfo = C_Map.GetMapInfo(map)
        local mapName = (mapInfo and mapInfo.name) or "Unknown Battleground"
        
        -- GENERATE HASH IMMEDIATELY (v2 deep hash over export-shaped payload)
        -- Build export-like players table (use strings for certain numeric fields to match export)
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
        Debug("Generated v2 hash at save time: " .. dataHash)
        
        local key = map.."_"..date("!%Y%m%d_%H%M%S")
        Debug("Saving match with key: " .. key)
        
        -- Enhanced battleground data structure WITH HASH
        BGLoggerDB[key] = {
            -- Original fields
            mapID = map,
            ended = date("%c"),
            stats = list,
            
            -- Enhanced fields
            battlegroundName = mapName,
            duration = duration, -- Primary duration field (from API or calculated)
            durationSource = durationSource, -- How duration was determined
            winner = winner,
            type = bgType,
            startTime = bgStartTime, -- Keep for compatibility
            endTime = currentTime,
            dateISO = date("!%Y-%m-%dT%H:%M:%SZ"),
            
            -- Enhanced participation tracking
            afkerList = playerTracker.detectedAFKers or {},
            joinedInProgress = playerTracker.joinedInProgress or false,
            playerJoinedInProgress = playerTracker.playerJoinedInProgress or false,
            validForStats = not (playerTracker.joinedInProgress or false),
            
            -- INTEGRITY DATA - v2 generated at save time
            integrity = {
                hash = dataHash,
                metadata = { algorithm = "deep_v2", playerCount = #list },
                generatedAt = GetServerTime(),
                serverTime = GetServerTime(),
                version = "BGLogger_v2.0",
                realm = GetRealmName() or "Unknown"
            }
        }
        
        Debug("Match saved successfully with " .. #list .. " players")
        Debug("Duration: " .. duration .. " seconds (source: " .. durationSource .. ")")
        Debug("Winner: " .. (winner ~= "" and winner or "Unknown"))
        Debug("Type: " .. bgType)
        Debug("Map: " .. mapName)
        Debug("Integrity hash: " .. dataHash)
        
        matchSaved = true
        
        -- Verify the save actually worked
        if BGLoggerDB[key] then
            Debug("Save verification successful - entry exists in database with integrity hash")
        else
            Debug("ERROR: Save verification failed - entry not found in database!")
            return false
        end
        
        return true
    end)
    
    if not success then
        Debug("ERROR in CommitMatch: " .. tostring(result))
        return false
    end
    
    -- If the window is open, refresh it
    if WINDOW and WINDOW:IsShown() then
        C_Timer.After(0.1, RefreshWindow)
    end
    
    return result
end

local function PollUntilWinner(retries)
    retries = retries or 0
    Debug("Polling for winner, attempt " .. retries)
    
    -- Request score data
    RequestBattlefieldScoreData()
    
    C_Timer.After(0.7, function()
        local win = GetWinner and GetWinner() or nil
        
        if win then
            Debug("Winner found on poll attempt " .. retries)
            CommitMatch(CollectScoreData())
        elseif retries < 5 then
            -- Keep trying a few times
            PollUntilWinner(retries + 1)
        else
            -- Last attempt - save anyway
            Debug("Max poll attempts reached, saving regardless")
            CommitMatch(CollectScoreData())
        end
    end)
end

-- Helper function to count table entries
local function tCount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- Attempt to retry save on fails
function AttemptSaveWithRetry(source, retryCount)
    retryCount = retryCount or 0
    Debug("AttemptSaveWithRetry called from " .. source .. ", attempt " .. (retryCount + 1))
    
    if matchSaved then
        Debug("Match already saved, aborting")
        return
    end
    
    if saveInProgress then
        Debug("Save already in progress, aborting duplicate save from " .. source)
        return
    end
    
    saveInProgress = true -- Set lock
    
    -- Request fresh score data
    RequestBattlefieldScoreData()
    
    local delay = 2 + (retryCount * 0.5)
    Debug("Waiting " .. delay .. " seconds for score data to populate...")
    
    C_Timer.After(delay, function()
        local success, result = pcall(function()
            local data = CollectScoreData()
            Debug("Collected " .. #data .. " player records")
            
            if #data == 0 then
                Debug("No player data collected")
                return false
            end
            
            local minExpectedPlayers = 10
            if #data < minExpectedPlayers then
                Debug("Too few players (" .. #data .. "), expected at least " .. minExpectedPlayers)
                return false
            end
            
            local validPlayers = 0
            for i, player in ipairs(data) do
                if player.name and player.name ~= "" and 
                   (player.damage > 0 or player.healing > 0 or player.kills > 0) then
                    validPlayers = validPlayers + 1
                end
            end
            
            Debug("Found " .. validPlayers .. " valid players with stats out of " .. #data)
            
            if validPlayers < minExpectedPlayers then
                Debug("Too few valid players with stats")
                return false
            end
            
            Debug("Attempting to commit match data...")
            local saveSuccess = CommitMatch(data)
            
            if matchSaved then
                Debug("Match successfully saved!")
                saveInProgress = false -- Clear lock on success
                return true
            else
                Debug("CommitMatch returned but matchSaved is still false")
                return false
            end
        end)
        
        if success and result then
            Debug("Save successful from " .. source)
            saveInProgress = false -- Clear lock
        elseif success and not result then
            Debug("Save failed (insufficient data) from " .. source)
            
            if retryCount < 3 then
                Debug("Retrying save in 3 seconds...")
                C_Timer.After(3, function()
                    saveInProgress = false -- Clear lock before retry
                    AttemptSaveWithRetry(source, retryCount + 1)
                end)
            else
                Debug("Max retries reached, giving up on save from " .. source)
                saveInProgress = false -- Clear lock
            end
        else
            Debug("Save failed with error from " .. source .. ": " .. tostring(result))
            saveInProgress = false -- Clear lock on error
        end
    end)
end

---------------------------------------------------------------------
-- Export Functions
---------------------------------------------------------------------

-- ExportBattleground moved to BGLogger_Export.lua

-- Convert Lua table to JSON string
-- TableToJSON moved to BGLogger_Export.lua
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
    
    -- Check if array
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

-- Show JSON export frame with read-only text
-- ShowJSONExportFrame moved to BGLogger_Export.lua
if not ShowJSONExportFrame then
function ShowJSONExportFrame(jsonString, filename)
    Debug("ShowJSONExportFrame called with " .. #jsonString .. " characters")
    
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
        
        -- Close button
        local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", -6, -6)
        
        -- Title
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -16)
        title:SetText("Export Battleground Data")

        -- Instructions
        local instructions = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        instructions:SetPoint("TOP", title, "BOTTOM", 0, -10)
        instructions:SetText("Select all text (Ctrl+A) and copy (Ctrl+C) - Text is read-only:")
        
        -- Create scroll frame
        local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 20, -80)
        scrollFrame:SetPoint("BOTTOMRIGHT", -40, 60)
        
        -- Create the edit box inside scroll frame - MADE READ-ONLY
        local editBox = CreateFrame("EditBox", nil, scrollFrame)
        editBox:SetSize(scrollFrame:GetWidth() - 20, 1)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(false)
        editBox:SetFontObject(ChatFontNormal)
        
        -- MAKE READ-ONLY: Disable editing but allow selection/copying
        editBox:SetScript("OnChar", function() end) -- Block character input
        editBox:SetScript("OnKeyDown", function(self, key)
            -- Allow copy commands and navigation, block everything else
            if key == "LCTRL" or key == "RCTRL" or
               key == "C" or key == "A" or  -- Ctrl+C, Ctrl+A
               key == "LEFT" or key == "RIGHT" or key == "UP" or key == "DOWN" or
               key == "HOME" or key == "END" or key == "PAGEUP" or key == "PAGEDOWN" then
                -- Allow these keys
                return
            else
                -- Block all other keys
                return
            end
        end)
        
        -- Allow selection but prevent modification
        editBox:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                -- If user tries to modify, restore original text
                self:SetText(f.originalText or "")
                self:SetCursorPosition(0)
            end
        end)
        
        editBox:SetScript("OnEscapePressed", function(self) 
            self:ClearFocus() 
        end)
        
        editBox:SetScript("OnEditFocusGained", function(self)
            -- Auto-select all when focused
            C_Timer.After(0.05, function()
                if self:HasFocus() then
                    self:HighlightText()
                end
            end)
        end)
        
        -- Visual indication that it's read-only
        editBox:SetTextColor(0.9, 0.9, 0.9) -- Slightly dimmed text
        
        -- Set up scrolling
        scrollFrame:SetScrollChild(editBox)
        
        -- Store references
        f.scrollFrame = scrollFrame
        f.editBox = editBox
        
        -- Select All button
        local selectBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        selectBtn:SetSize(100, 22)
        selectBtn:SetPoint("BOTTOMLEFT", 20, 20)
        selectBtn:SetText("Select All")
        selectBtn:SetScript("OnClick", function()
            f.editBox:SetFocus()
            f.editBox:HighlightText()
        end)
        
        -- Copy Instructions
        local copyInstructions = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        copyInstructions:SetPoint("LEFT", selectBtn, "RIGHT", 20, 0)
        copyInstructions:SetText("Read-only: Ctrl+A to select, Ctrl+C to copy")
        copyInstructions:SetTextColor(1, 1, 0) -- Yellow text to indicate read-only
        
        -- Filename display
        local filenameText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        filenameText:SetPoint("BOTTOMRIGHT", -20, 20)
        f.filenameText = filenameText
        
        f:Hide()
        BGLoggerExportFrame = f
    end
    
    -- Store original text for restoration if modified
    BGLoggerExportFrame.originalText = jsonString
    
    -- Set the JSON text
    BGLoggerExportFrame.editBox:SetText(jsonString)
    BGLoggerExportFrame.editBox:SetCursorPosition(0)
    
    -- Update filename
    BGLoggerExportFrame.filenameText:SetText("Save as: " .. filename)
    
    -- Adjust editbox height based on content
    local fontHeight = 12
    local numLines = 1
    for _ in jsonString:gmatch('\n') do
        numLines = numLines + 1
    end
    BGLoggerExportFrame.editBox:SetHeight(math.max(numLines * fontHeight + 50, 100))
    
    -- Show the frame
    BGLoggerExportFrame:Show()
    
    Debug("JSON export frame shown with read-only " .. #jsonString .. " characters")
end
end

-- Show export menu (uses Export* functions from BGLogger_Export.lua)
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
    b:SetHeight(LINE_HEIGHT*2)  -- Make buttons bigger for easier clicking
    b:SetPoint("TOPLEFT", 0, -(i-1)*(LINE_HEIGHT*2 + 2))  -- Add spacing between buttons
    b:SetPoint("RIGHT", parent, "RIGHT", -30, 0)  -- More padding for wider window
    b:SetText("Loading...")  -- Default text
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)  -- Dark semi-transparent background
    
    -- Add highlight texture
    b:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight", "ADD")
    
    ListButtons[i] = b
    return b
end

---------------------------------------------------------------------
-- Renderers - completely rebuilt
---------------------------------------------------------------------
local function RefreshWindow()
    if not WINDOW or not WINDOW:IsShown() then return end
    
    -- Determine which view to show
    if WINDOW.currentView == "detail" and WINDOW.currentKey then
        ShowDetail(WINDOW.currentKey)
    else
        ShowList()
    end
end

-- Redesigned list view with proper chronological sorting and data filtering
function ShowList()
    Debug("ShowList called, DB has " .. tCount(BGLoggerDB) .. " entries")
    
    -- Set current view
    WINDOW.currentView = "list"
    WINDOW.currentKey = nil
    
    -- Hide detail view, show list view
    WINDOW.detailScroll:Hide()
    WINDOW.backBtn:Hide()
    WINDOW.listScroll:Show()
    if WINDOW.exportBtn then WINDOW.exportBtn:Hide() end
    
    -- Clear existing buttons first
    for _, btn in ipairs(ListButtons) do
        btn:Hide()
        btn:SetScript("OnClick", nil)
    end
    
    -- Build sorted list of entries - FILTER OUT NON-BATTLEGROUND DATA
    local entries = {}
    for k, v in pairs(BGLoggerDB) do
        -- Only include entries that look like battleground data
        if type(v) == "table" and v.mapID and v.stats then
            table.insert(entries, {key = k, data = v})
        else
            Debug("Skipping non-battleground entry: " .. k .. " (type: " .. type(v) .. ")")
        end
    end
    
    -- Sort by actual date/time, newest first
    table.sort(entries, function(a, b)
        -- First try to use the ISO date if available (most accurate)
        if a.data.dateISO and b.data.dateISO then
            return a.data.dateISO > b.data.dateISO
        end
        
        -- Fallback to endTime if available
        if a.data.endTime and b.data.endTime then
            return a.data.endTime > b.data.endTime
        end
        
        -- Final fallback to key comparison (which includes timestamp)
        return a.key > b.key
    end)
    
    Debug("Sorted " .. #entries .. " battleground entries chronologically")
    
    -- Create buttons for each entry
    for i, entry in ipairs(entries) do
        local btn = ListButtons[i] or MakeListButton(WINDOW.listContent, i)
        local k, data = entry.key, entry.data
        
        local mapInfo = C_Map.GetMapInfo(data.mapID or 0)
        local mapName = (mapInfo and mapInfo.name) or "Unknown Map"
        
        -- Better date/time display
        local dateDisplay = ""
        if data.dateISO then
            -- Convert ISO date to readable format
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
        
        -- Include duration and winner info
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
        
        -- Set enhanced button text
        btn:SetText(string.format("%s%s%s\n%s", mapName, durationText, winnerText, dateDisplay))
        btn.bgKey = k  -- Store the key on the button
        
        -- Set click handler
        btn:SetScript("OnClick", function(self) 
            Debug("Clicked button for " .. self.bgKey)
            ShowDetail(self.bgKey) 
        end)
        
        btn:Show()
    end
    
    -- Hide unused buttons
    for i = #entries + 1, #ListButtons do
        ListButtons[i]:Hide()
    end
    
    -- Update content height
    local contentHeight = #entries * (LINE_HEIGHT*2 + 2)
    WINDOW.listContent:SetHeight(math.max(contentHeight, 10))
    Debug("List view rendered with " .. #entries .. " buttons in chronological order")
end

-- Redesigned detail view
function ShowDetail(key)
    Debug("ShowDetail called for key: " .. tostring(key))
    
    -- Store current view state
    WINDOW.currentView = "detail"
    WINDOW.currentKey = key
    
    -- Hide list view, show detail view
    WINDOW.listScroll:Hide()
    WINDOW.detailScroll:Show()
    WINDOW.backBtn:Show()
    if WINDOW.exportBtn then WINDOW.exportBtn:Show() end
    
    -- Clear existing detail lines completely
    for i = 1, #DetailLines do
        if DetailLines[i] then
            if DetailLines[i].columns then
                -- New column-based lines
                for _, column in pairs(DetailLines[i].columns) do
                    column:SetText("")
                end
            else
                -- Old single-text lines (fallback)
                DetailLines[i]:SetText("")
            end
            DetailLines[i]:Hide()
        end
    end

    -- Also clear any lines beyond our current data
    local maxLinesToClear = math.max(50, #DetailLines) -- Clear at least 50 lines
    for i = 1, maxLinesToClear do
        if DetailLines[i] then
            if DetailLines[i].columns then
                -- New column-based lines
                for _, column in pairs(DetailLines[i].columns) do
                    column:SetText("")
                end
            else
                -- Old single-text lines (fallback)
                DetailLines[i]:SetText("")
            end
            DetailLines[i]:Hide()
        end
    end
    
    -- Check if data exists
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
    
    -- Add battleground info header
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
    
    -- Add in-progress join indicator if applicable
    if data.joinedInProgress then
        bgInfo = bgInfo .. " | ⚠️ JOINED IN-PROGRESS"
    end
    
    -- Use first column for header info, span across multiple columns if needed
    headerInfo.columns.name:SetText(bgInfo)
    for columnName, column in pairs(headerInfo.columns) do
        if columnName ~= "name" then
            column:SetText("")
        end
    end
    headerInfo:Show()
    
    -- Add separator
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
    
    -- Column headers with perfect positioning
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
    
    -- Add separator line under headers
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
    
    -- Get regular players (all players in stats since AFKers aren't in the final stats)
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
    
    -- Get AFKers from stored list
    local afkers = data.afkerList or {}
    
    -- Build detail lines for regular players only
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
        
        -- Check for both new and legacy data format
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
        
        -- Enhanced participation data
        local textColor = DETAIL_TEXT_COLORS.default
        if participationUnknown then
            textColor = DETAIL_TEXT_COLORS.unknown
        elseif isBackfill then
            textColor = DETAIL_TEXT_COLORS.backfill
        end
        
        -- Create status string
        local status = ""
        if participationUnknown then
            status = "??"   -- Unknown participation (joined in-progress BG)
        elseif isBackfill then
            status = "BF"   -- Backfill
        else
            status = "OK"   -- Normal participation
        end
        
        -- Format damage and healing for display
        local damageText = damage >= 1000000 and string.format("%.1fM", damage/1000000) or 
                          damage >= 1000 and string.format("%.0fK", damage/1000) or tostring(damage)
        local healingText = healing >= 1000000 and string.format("%.1fM", healing/1000000) or 
                           healing >= 1000 and string.format("%.0fK", healing/1000) or tostring(healing)
        
        -- Set each column individually - perfect alignment guaranteed!
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
            
        -- Color code the text based on status
        StyleDetailLine(line, { style = styleKey, textColor = participationUnknown and "unknown" or (isBackfill and "backfill" or "default") })
        line:Show()
    end
    
    -- Add summary footer for regular players
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
    
    -- Calculate totals for regular players only
    for _, row in ipairs(regularPlayers) do
        totalDamage = totalDamage + (row.damage or row.dmg or 0)
        totalHealing = totalHealing + (row.healing or row.heal or 0)
        totalKills = totalKills + (row.kills or row.killingBlows or row.kb or 0)
        totalDeaths = totalDeaths + (row.deaths or 0)
        
        -- Count backfills among regular players
        if row.isBackfill then backfillCount = backfillCount + 1 end
    end
    
    -- Show totals with perfect column alignment
    local totalDamageText = totalDamage >= 1000000 and string.format("%.1fM", totalDamage/1000000) or 
                           totalDamage >= 1000 and string.format("%.0fK", totalDamage/1000) or tostring(totalDamage)
    local totalHealingText = totalHealing >= 1000000 and string.format("%.1fM", totalHealing/1000000) or 
                            totalHealing >= 1000 and string.format("%.0fK", totalHealing/1000) or tostring(totalHealing)
    
    totalLine.columns.name:SetText("TOTALS (" .. #regularPlayers .. " players)")
    totalLine.columns.realm:SetText("")  -- Empty
    totalLine.columns.class:SetText("")  -- Empty
    totalLine.columns.spec:SetText("")   -- Empty
    totalLine.columns.faction:SetText("") -- Empty
    totalLine.columns.damage:SetText(totalDamageText)
    totalLine.columns.healing:SetText(totalHealingText)
    totalLine.columns.kills:SetText(tostring(totalKills))
    totalLine.columns.deaths:SetText(tostring(totalDeaths))
    totalLine.columns.objectives:SetText("") -- Empty
    totalLine.columns.hk:SetText("") -- Empty
    totalLine.columns.status:SetText("") -- Empty
    
    -- Make totals bold/colored
    StyleDetailLine(totalLine, { style = "totals", textColor = "totals" })
    totalLine:Show()
    
    local currentLineIndex = #regularPlayers + 8
    
    -- Add backfill summary for regular players
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
    
    -- Add AFKer section if there are any
    if #afkers > 0 then
        -- Add separator before AFKer section
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
        
        -- AFKer section header
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
        
        -- List each AFKer with enhanced information
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
    
    -- Hide unused detail lines
    for i = currentLineIndex, #DetailLines do
        if DetailLines[i] then
            DetailLines[i]:Hide()
        end
    end

    -- Update content height based on actual lines used
    WINDOW.detailContent:SetHeight(math.max((currentLineIndex-1)*LINE_HEIGHT, 10))
    Debug("Detail view rendered with " .. #rows .. " players, showing enhanced stats")
end

---------------------------------------------------------------------
-- Window - completely rebuilt
---------------------------------------------------------------------
local function CreateWindow()
    Debug("Creating window...")
    
    -- Create main frame
    local f = CreateFrame("Frame", "BGLoggerWindow", UIParent, "BackdropTemplate")
    f:SetSize(WIN_W, WIN_H)
    f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = {left = 8, right = 8, top = 8, bottom = 8}
    })
    
    -- Make it movable
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    
    -- Enable escape key to close window
    f:SetPropagateKeyboardInput(true)
    f:EnableKeyboard(true)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
            -- Stop the key from propagating further
            self:SetPropagateKeyboardInput(false)
        else
            -- Let other keys propagate normally
            self:SetPropagateKeyboardInput(true)
        end
    end)
    
    -- Ensure keyboard input is enabled when window is shown
    f:SetScript("OnShow", function(self)
        self:EnableKeyboard(true)
    end)
    
    -- Disable keyboard input when window is hidden
    f:SetScript("OnHide", function(self)
        self:EnableKeyboard(false)
    end)
    
    -- Add close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    
    -- Add title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Battleground Statistics")
    
    -- Add clear button with confirmation
    StaticPopupDialogs["BGLOGGER_CLEAR"] = {
        text = "Clear all saved logs?",
        button1 = YES,
        button2 = NO,
        OnAccept = function() 
            wipe(BGLoggerDB)
            RefreshWindow()
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
    
    -- Add back button
    local backBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    backBtn:SetSize(60, 22)
    backBtn:SetPoint("TOPLEFT", 20, -40)
    backBtn:SetText("<- Back")
    backBtn:SetScript("OnClick", ShowList)
    backBtn:Hide()
    f.backBtn = backBtn
    
    -- Add refresh button
    local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refreshBtn:SetSize(80, 22)
    refreshBtn:SetPoint("TOPRIGHT", clearBtn, "TOPLEFT", -10, 0)
    refreshBtn:SetText("Refresh")
    refreshBtn:SetScript("OnClick", RefreshWindow)

    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetSize(80, 22)
    exportBtn:SetPoint("TOPRIGHT", refreshBtn, "TOPLEFT", -10, 0)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", function()
        if WINDOW.currentView == "detail" and WINDOW.currentKey then
            ExportBattleground(WINDOW.currentKey)
        else
            -- No action in list view
        end
    end)
    exportBtn:Hide() -- Hidden by default (list view)
    f.exportBtn = exportBtn
    
    -- Create list scroll frame
    local listScroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 20, -80)
    listScroll:SetPoint("BOTTOMRIGHT", -30, 20)
    
    -- Create list content frame
    local listContent = CreateFrame("Frame", nil, listScroll)
    listContent:SetSize(listScroll:GetWidth() - 16, 10)  -- Initial small height
    listScroll:SetScrollChild(listContent)
    
    -- Create detail scroll frame
    local detailScroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    detailScroll:SetPoint("TOPLEFT", 20, -80)
    detailScroll:SetPoint("BOTTOMRIGHT", -30, 20)
    detailScroll:Hide()
    
    -- Create detail content frame
    local detailContent = CreateFrame("Frame", nil, detailScroll)
    detailContent:SetSize(detailScroll:GetWidth() - 16, 10)  -- Initial small height
    detailScroll:SetScrollChild(detailContent)
    
    -- Store references
    f.listScroll = listScroll
    f.listContent = listContent
    f.detailScroll = detailScroll
    f.detailContent = detailContent
    f.currentView = "list"  -- Default view
    
    f:Hide()
    return f
end

---------------------------------------------------------------------
-- Minimap Button
---------------------------------------------------------------------
local MinimapButton = {}

-- Create the minimap button
local function CreateMinimapButton()
    local button = CreateFrame("Button", "BGLoggerMinimapButton", Minimap)
    button:SetFrameStrata("MEDIUM")
    button:SetSize(32, 32)
    button:SetFrameLevel(8)
    button:RegisterForClicks("anyUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture(136477)
    
    -- UPDATED: Faction-based icon selection
    local playerFaction = UnitFactionGroup("player")
    local iconTexture = ""
    
    if playerFaction == "Alliance" then
        iconTexture = "Interface\\Icons\\PVPCurrency-Honor-Alliance"
    elseif playerFaction == "Horde" then
        iconTexture = "Interface\\Icons\\PVPCurrency-Honor-Horde"
    else
        -- Fallback in case faction detection fails
        iconTexture = "Interface\\Icons\\Achievement-pvp-legion03"
    end
    
    Debug("Minimap button using " .. playerFaction .. " icon: " .. iconTexture)
    
    -- Set the button texture
    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(iconTexture)
    button.icon = icon
    
    -- UPDATED: Better border for outside positioning
    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetPoint("TOPLEFT", 0, 0)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    
    -- Position on minimap
    local function UpdatePosition()
        local angle = BGLoggerDB.minimapPos or 45
        local radius = 105
        local x = math.cos(math.rad(angle)) * radius
        local y = math.sin(math.rad(angle)) * radius
        button:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end
    
    -- Click handler
    button:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "LeftButton" then
            -- Left click: Toggle main window
            if not WINDOW then
                WINDOW = CreateWindow()
            end
            
            if WINDOW:IsShown() then
                WINDOW:Hide()
            else
                WINDOW:Show()
                C_Timer.After(0.1, RefreshWindow)
            end
        end
    end)
    
    -- Drag functionality for repositioning
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
    
    -- Tooltip
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
    
    -- Store reference and update position
    MinimapButton.button = button
    UpdatePosition()
    
    Debug("Minimap button created")
    return button
end

-- Show/Hide minimap button
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

function DebugExportVsHash(key)
    if not BGLoggerDB[key] then
        print("No data found for key: " .. tostring(key))
        return
    end
    
    local data = BGLoggerDB[key]
    print("=== DEBUGGING HASH MISMATCH ===")
    
    -- Show stored hash
    if data.integrity and data.integrity.hash then
        print("Stored hash: " .. data.integrity.hash)
    else
        print("No stored hash found!")
        return
    end
    
    -- Recreate the exact hash generation process
    local battlegroundMetadata = {
        battleground = data.battlegroundName or "Unknown Battleground",
        duration = data.duration or 0,
        winner = data.winner or "",
        type = data.type or "non-rated",
        date = data.dateISO or date("!%Y-%m-%dT%H:%M:%SZ")
    }
    
    print("BG Metadata:")
    print("  battleground: '" .. battlegroundMetadata.battleground .. "'")
    print("  duration: " .. battlegroundMetadata.duration)
    print("  winner: '" .. battlegroundMetadata.winner .. "'")
    
    -- Show what the export will send vs what hash used
    print("\nPlayer data comparison (first 3 players):")
    for i = 1, math.min(3, #(data.stats or {})) do
        local player = data.stats[i]
        print("Player " .. i .. ":")
        print("  name: '" .. (player.name or "") .. "'")
        print("  realm: '" .. (player.realm or "") .. "'")
        print("  damage field: " .. (player.damage or "nil"))
        print("  dmg field: " .. (player.dmg or "nil"))
        print("  healing field: " .. (player.healing or "nil"))
        print("  heal field: " .. (player.heal or "nil"))
        
        -- Show what export will use
        local exportDamage = player.damage or player.dmg or 0
        local exportHealing = player.healing or player.heal or 0
        print("  export damage: " .. tostring(exportDamage))
        print("  export healing: " .. tostring(exportHealing))
        
        -- Show what hash used (assuming it only checks player.damage/healing)
        print("  hash damage: " .. tostring(player.damage or 0))
        print("  hash healing: " .. tostring(player.healing or 0))
        
        if exportDamage ~= (player.damage or 0) or exportHealing ~= (player.healing or 0) then
            print("  *** MISMATCH DETECTED! ***")
        end
    end
    
    -- Regenerate hash with current data
    local newHash, newMetadata = GenerateDataHash(battlegroundMetadata, data.stats or {})
    print("\nHash comparison:")
    print("  Original: " .. data.integrity.hash)
    print("  Regenerated: " .. newHash)
    print("  Match: " .. tostring(data.integrity.hash == newHash))
end

---------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------
SLASH_BGLOGGER1 = "/bgstats"
SLASH_BGLOGGER2 = "/bglogger"
SlashCmdList.BGLOGGER = function(msg)
    local command = msg and msg:lower() or ""
    
    if command == "debug" then
        ToggleDebugMode()
        return
    elseif command == "testbreakdown" then
        if not insideBG then
            print("|cff00ffffBGLogger:|r Not in a battleground")
            return
        end
        TestObjectiveBreakdownSystem()
        return
    elseif command == "testretry" then
        if not insideBG then
            print("|cff00ffffBGLogger:|r Not in a battleground")
            return
        end
        -- Force a retry scenario for testing
        print("|cff00ffffBGLogger:|r Simulating large disparity to test retry logic...")
        playerTracker.initialListCaptured = false
        playerTracker.initialCaptureRetried = false
        
        -- Simulate the retry logic
        print("🔄 SIMULATED LARGE DISPARITY - Scheduling retry in 3 seconds for testing...")
        playerTracker.initialCaptureRetried = true
        
        C_Timer.After(3, function()
            if insideBG and not playerTracker.initialListCaptured then
                print("🔄 *** TEST RETRY TRIGGERED ***")
                CaptureInitialPlayerList(true)
            else
                print("🔄 Test retry cancelled")
            end
        end)
        return
    elseif command == "help" then
        print("|cff00ffffBGLogger Commands:|r")
        print("|cffffffff/bgstats|r or |cffffffff/bglogger|r - Open/close BGLogger window")
        print("|cffffffff/bglogger debug|r - Toggle debug mode on/off")
        print("|cffffffff/bglogger testbreakdown|r - Test new objective breakdown system (in BG only)")
        print("|cffffffff/bglogger testretry|r - Test initial capture retry logic (in BG only)")
        print("|cffffffff/bglogger help|r - Show this help")
        return
    end
    
    Debug("Slash command executed")
    
    -- Create window if it doesn't exist
    if not WINDOW then
        Debug("Creating window")
        WINDOW = CreateWindow()
    end
    
    -- Toggle visibility
    if WINDOW:IsShown() then
        Debug("Hiding window")
        WINDOW:Hide()
    else
        Debug("Showing window")
        WINDOW:Show()
        
        -- Refresh after a small delay to ensure frame is ready
        C_Timer.After(0.1, RefreshWindow)
    end
end

---------------------------------------------------------------------
-- Initialize Debug Module (if available)
---------------------------------------------------------------------

-- Initialize debug mode from saved variables
C_Timer.After(0.5, function()
    InitializeDebugMode()
end)

-- Try to initialize debug module
C_Timer.After(1, function()
    if _G.BGLoggerDebug then
        _G.BGLoggerDebug.Initialize({
            BGLoggerDB = BGLoggerDB,
            DEBUG_MODE = DEBUG_MODE,
            WINDOW = WINDOW,
            Debug = Debug,
            RefreshWindow = RefreshWindow,
            CommitMatch = CommitMatch,
            CollectScoreData = CollectScoreData,
            AttemptSaveWithRetry = AttemptSaveWithRetry,
            TableToJSON = TableToJSON,
            ExportBattleground = ExportBattleground,
            GetBestRealmName = GetBestRealmName,
            tCount = tCount,
            -- Add references to variables the debug module needs
            insideBG = insideBG,
            matchSaved = matchSaved,
            bgStartTime = bgStartTime,
            MIN_BG_TIME = MIN_BG_TIME,
                    -- Simple player tracking references
        playerTracker = playerTracker,
        DebugPlayerTracking = DebugPlayerTracking,
        ResetPlayerTracker = ResetPlayerTracker,
        ResetPlayerTracking = ResetPlayerTracking,
        CaptureInitialPlayerList = CaptureInitialPlayerList,
        CaptureFinalPlayerList = CaptureFinalPlayerList,
        AnalyzePlayerLists = AnalyzePlayerLists,
        DebugAFKerDetection = DebugAFKerDetection,
        GetParticipationSummary = GetParticipationSummary,
        ForceCaptureInitialList = ForceCaptureInitialList,
        DebugMatchStart = DebugMatchStart,
        DebugScoreboardData = DebugScoreboardData,
        DebugCollectScoreData = DebugCollectScoreData,
        CheckTrackingStatus = CheckTrackingStatus,
        ForceCaptureBypassed = ForceCaptureBypassed,
        IsMatchStarted = IsMatchStarted,
        DebugOverflowTracking = function()
            if not insideBG then
                print("Not in a battleground")
                return
            end
            
            print("=== Overflow Tracking Debug ===")
            print("Total tracked players: " .. tCount(playerTracker.lastCheck))
            
            for playerKey, data in pairs(playerTracker.lastCheck) do
                local overflows = playerTracker.overflowDetected[playerKey]
                if overflows and (overflows.damageOverflows > 0 or overflows.healingOverflows > 0) then
                    print("OVERFLOW DETECTED: " .. playerKey)
                    print("  Damage overflows: " .. overflows.damageOverflows)
                    print("  Healing overflows: " .. overflows.healingOverflows)
                    print("  Current damage: " .. data.damage)
                    print("  Current healing: " .. data.healing)
                end
            end
            print("===============================")
        end,
        DebugObjectiveData = DebugObjectiveData,
        TestObjectiveCollection = TestObjectiveCollection,
        DebugInProgressDetection = DebugInProgressDetection,
        DebugColumnAlignment = function()
            print("=== Column Alignment Test ===")
            print("Testing fixed-width functions:")
            print("'" .. FixedWidthLeft("Test", 10) .. "' (should be 10 chars)")
            print("'" .. FixedWidthCenter("Test", 10) .. "' (should be 10 chars)")  
            print("'" .. FixedWidthRight("Test", 10) .. "' (should be 10 chars)")
            print("'" .. FixedWidthLeft("VeryLongTextThatShouldBeTruncated", 10) .. "' (should be 10 chars)")
            
            -- Test full header line
            local testHeader = 
                FixedWidthCenter("Player Name", 14) .. "|" ..
                FixedWidthCenter("Realm", 22) .. "|" ..
                FixedWidthCenter("Class", 14) .. "|" ..
                FixedWidthCenter("Spec", 14) .. "|" ..
                FixedWidthCenter("Faction", 10) .. "|" ..
                FixedWidthCenter("Damage", 12) .. "|" ..
                FixedWidthCenter("Healing", 12) .. "|" ..
                FixedWidthCenter("K", 3) .. "|" ..
                FixedWidthCenter("D", 3) .. "|" ..
                FixedWidthCenter("Obj", 3) .. "|" ..
                FixedWidthCenter("HK", 5) .. "|" ..
                FixedWidthCenter("Status", 8)
            print("Test header (with | separators):")
            print("'" .. testHeader .. "'")
            print("Header length: " .. #testHeader .. " characters")
            print("============================")
        end
        })
    end
end)

---------------------------------------------------------------------
-- Event driver
---------------------------------------------------------------------

local Driver = CreateFrame("Frame")

-- Register all relevant events
Driver:RegisterEvent("PLAYER_ENTERING_WORLD")
Driver:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
Driver:RegisterEvent("PLAYER_LEAVING_WORLD")
Driver:RegisterEvent("ZONE_CHANGED_NEW_AREA")
Driver:RegisterEvent("CHAT_MSG_BG_SYSTEM_NEUTRAL")

-- Register additional events for BG detection
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
    if success then
        Debug("Registered event: " .. eventName)
    else
        Debug("Failed to register event: " .. eventName .. " (not available)")
    end
end

Driver:SetScript("OnEvent", function(_, e, ...)
    -- Update BG status on relevant events
    local newBGStatus = UpdateBattlegroundStatus()
    local statusChanged = (newBGStatus ~= insideBG)
    
    if DEBUG_MODE then
        Debug("Event: " .. e .. " (insideBG=" .. tostring(newBGStatus) .. ", matchSaved=" .. tostring(matchSaved) .. ")")
        if statusChanged then
            Debug("BG Status changed: " .. tostring(insideBG) .. " -> " .. tostring(newBGStatus))
        end
    end
    
    if e == "PLAYER_ENTERING_WORLD" then
    local wasInBG = insideBG
    insideBG = newBGStatus
    
        if insideBG and not wasInBG then
            -- Just entered a BG
            Debug("Entered battleground")
            bgStartTime = GetTime() -- For fallback duration calculation
            matchSaved = false
            saveInProgress = false
            ResetPlayerTracker() -- Initialize player tracking
            initialPlayerCount = 0 -- Reset player count tracking
            StartOverflowTracking() -- Start monitoring for overflow
            
            -- CRITICAL: Check if this is an in-progress BG with multiple robust retries
            local function CheckInProgress(attempt)
                attempt = attempt or 1
                if not insideBG then return end
                -- Do not run in-progress detection once the match has started or the initial list is captured
                if (playerTracker and (playerTracker.battleHasBegun or playerTracker.initialListCaptured)) then
                    Debug("CheckInProgress aborted: match started or initial list captured (attempt " .. tostring(attempt) .. ")")
                    return
                end
                    local isInProgressBG = false
                    local detectionMethod = "none"

                -- Try to force the scoreboard to refresh for more reliable reads
                RequestBattlefieldScoreData()

                C_Timer.After(0.6, function()
                    if not insideBG then return end
                    -- Re-check in case match started or initial list captured while waiting
                    if playerTracker and (playerTracker.battleHasBegun or playerTracker.initialListCaptured) then
                        Debug("CheckInProgress inner aborted: match started or initial list captured")
                        return
                    end
                    
                    -- Method 1: Check API duration (most reliable)
                    if C_PvP and C_PvP.GetActiveMatchDuration then
                        local apiDuration = C_PvP.GetActiveMatchDuration() or 0
                        local timeInside = GetTime() - (bgStartTime or GetTime())
                        local durationDelta = apiDuration - timeInside
                        Debug(string.format("In-progress API check: apiDuration=%.1fs, timeInside=%.1fs, delta=%.1fs", apiDuration, timeInside, durationDelta))

                        -- Require the duration to significantly exceed the time we've been inside
                        if apiDuration > 5 and durationDelta >= 10 then
                            isInProgressBG = true
                            detectionMethod = string.format("API_duration_%ss_delta_%s", tostring(apiDuration), tostring(math.floor(durationDelta)))
                            Debug("IN-PROGRESS BG detected via API duration delta (attempt " .. attempt .. ")")
                        end
                    end
                    
                    -- Method 2: Check if both teams are immediately visible (fallback)
                    -- Restrict this heuristic to epic BGs only to avoid false positives on regular maps
                    if not isInProgressBG and IsEpicBattleground() then
                        local rows = GetNumBattlefieldScores()
                        if rows > 0 then
                            local allianceCount, hordeCount = 0, 0
                            local myFaction = UnitFactionGroup("player")
                            local allowedThreshold = (myFaction == "Alliance") and 10 or 6
                            local visibleEnemy = 0

                            for i = 1, math.min(rows, 30) do
                                local success, s = pcall(C_PvP.GetScoreInfo, i)
                                if success and s and s.name then
                                    local factionId = s.faction or s.side
                                    if factionId == 0 then
                                        hordeCount = hordeCount + 1
                                    elseif factionId == 1 then
                                        allianceCount = allianceCount + 1
                                    end

                                    if myFaction == "Alliance" and factionId == 1 then
                                        visibleEnemy = visibleEnemy + 1
                                    elseif myFaction == "Horde" and factionId == 0 then
                                        visibleEnemy = visibleEnemy + 1
                                    end
                                end
                            end

                            if visibleEnemy >= allowedThreshold then
                                isInProgressBG = true
                                detectionMethod = string.format("enemy_visible_%d_players", visibleEnemy)
                                Debug("IN-PROGRESS BG detected via enemy visibility threshold (attempt " .. attempt .. ")")
                            end
                        end
                    end
                    
                    if isInProgressBG then
                        Debug("*** IN-PROGRESS BATTLEGROUND DETECTED ***")
                        Debug("Detection method: " .. detectionMethod)
                        Debug("Player joined an ongoing match - adjusting tracking behavior")
                        
                        -- Set flags to indicate this is an in-progress join
                        playerTracker.joinedInProgress = true
                        playerTracker.battleHasBegun = true -- Match has obviously started
                        
                        -- Capture current state as "initial" list (best we can do)
                        Debug("*** Capturing current player state as baseline (in-progress join) ***")
                        CaptureInitialPlayerList(true) -- Skip match start validation
                        
                        -- Mark the player themselves as a backfill candidate
                        playerTracker.playerJoinedInProgress = true
                        return
                    end

                    -- Retry additional times in case APIs/scoreboard are slow to populate (especially on epic maps)
                    local epic = IsEpicBattleground()
                    local maxAttempts = epic and 6 or 4
                    local delays = epic and { 2, 6, 12, 20, 30, 45 } or { 2, 5, 10, 15 }
                    if attempt < maxAttempts then
                        local nextDelay = delays[attempt + 1] or 10
                        C_Timer.After(nextDelay, function() 
                            -- Skip retries if battle has begun or initial list was captured in the meantime
                            if playerTracker and (playerTracker.battleHasBegun or playerTracker.initialListCaptured) then
                                Debug("CheckInProgress retries cancelled: match started or initial list captured")
                                return
                            end
                            CheckInProgress(attempt + 1) 
                        end)
                    else
                        Debug("Normal BG join detected - waiting for match to start")
                        Debug("Waiting for match to start before capturing initial player list")
                end
            end)
            end
            C_Timer.After(2, function() 
                if playerTracker and (playerTracker.battleHasBegun or playerTracker.initialListCaptured) then
                    Debug("Initial CheckInProgress skipped: match already started or initial list captured")
                    return
                end
                CheckInProgress(1) 
            end)
            
            -- Fallback: Set battleHasBegun flag after reasonable delay if no chat message comes
            C_Timer.After(90, function() -- 1.5 minutes after entering BG
                if insideBG and not playerTracker.battleHasBegun then
                    Debug("*** FALLBACK: Setting battleHasBegun flag (no start message received) ***")
                    playerTracker.battleHasBegun = true
                    Debug("Battle begun flag set via fallback timer")
                end
            end)
            
            -- CONSERVATIVE fallback: Check periodically if match has started (in case events are missed)
            local checkCount = 0
            local function CheckMatchStart()
                checkCount = checkCount + 1
                if insideBG and not playerTracker.initialListCaptured and checkCount <= 15 then -- Check for up to 2.5 minutes
                    if IsMatchStarted() then
                        Debug("MATCH START DETECTED via periodic check (attempt " .. checkCount .. ")")
                        CaptureInitialPlayerList(false) -- Use match start validation for fallback
                    else
                        C_Timer.After(10, CheckMatchStart) -- Check every 10 seconds (less frequent)
                    end
                end
            end
            
            -- Start checking after 30 seconds (longer delay for preparation phase)
            C_Timer.After(25, CheckMatchStart)
            
        elseif not insideBG and wasInBG then
            -- Just left a BG
            Debug("Left battleground, resetting flags")
            bgStartTime = 0
            matchSaved = false
            saveInProgress = false
        elseif not insideBG then
            -- Reset everything when not in BG
            Debug("Player entering world outside BG, resetting flags")
            bgStartTime = 0
            matchSaved = false
            saveInProgress = false
        end

        -- Handle BG system messages for match start and end detection
    elseif (e == "CHAT_MSG_BG_SYSTEM_NEUTRAL" or e == "CHAT_MSG_BG_SYSTEM_ALLIANCE" or e == "CHAT_MSG_BG_SYSTEM_HORDE") and insideBG then
        local message = ...
        Debug("BG System message: " .. tostring(message))
        
        -- Check for battle start messages to set the "battle begun" flag
        if message and not playerTracker.battleHasBegun then
            local lowerMsg = message:lower()
            -- Be MORE SPECIFIC about battle start messages to avoid false positives
            local isBattleStartMessage = (lowerMsg:find("battle has begun") or 
                                         lowerMsg:find("let the battle begin") or
                                         lowerMsg:find("the battle begins") or
                                         lowerMsg:find("gates are open") or
                                         lowerMsg:find("the battle for .* has begun") or
                                         lowerMsg:find("begin!") or
                                         -- Common specific BG start messages
                                         (lowerMsg:find("go") and lowerMsg:find("go") and lowerMsg:find("go"))) -- "Go! Go! Go!"
            
            -- EXCLUDE preparation phase messages that contain "start" but aren't actual start
            local isPreparationMessage = (lowerMsg:find("prepare") or 
                                         lowerMsg:find("will begin in") or
                                         lowerMsg:find("starting in") or
                                         lowerMsg:find("seconds") or
                                         lowerMsg:find("minute"))
            
            if isBattleStartMessage and not isPreparationMessage then
                playerTracker.battleHasBegun = true
                Debug("*** BATTLE HAS BEGUN detected via chat message: " .. message .. " ***")
                Debug("Battle begun flag set to true")
            elseif isPreparationMessage then
                Debug("*** PREPARATION MESSAGE detected (ignoring): " .. message .. " ***")
            end
        end
        
        -- Check for end messages to trigger save
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
                Debug("End of BG detected via chat message: " .. message)
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
        Debug("PVP_MATCH_STATE_CHANGED: " .. tostring(matchState))
        Debug("*** BGLogger: PVP_MATCH_STATE_CHANGED event received ***")
        Debug("Match state parameter: '" .. tostring(matchState) .. "'")
        Debug("Inside BG: " .. tostring(insideBG))
        Debug("Initial list captured: " .. tostring(playerTracker.initialListCaptured))
        
        -- Resolve actual match state early
        local actualMatchState = matchState
        if not actualMatchState and C_PvP and C_PvP.GetActiveMatchState then
            actualMatchState = C_PvP.GetActiveMatchState()
            Debug("Got match state from API: '" .. tostring(actualMatchState) .. "'")
        end
        
        -- If this update indicates the match is ending/ended, prioritize save and exit
        if actualMatchState == "complete" or actualMatchState == "finished" or actualMatchState == "ended" or 
           actualMatchState == "concluded" or actualMatchState == "done" then
            if not matchSaved then
                local timeSinceStart = GetTime() - bgStartTime
                if timeSinceStart > MIN_BG_TIME then
                    Debug("BG END DETECTED via PVP_MATCH_STATE_CHANGED")
                    RequestBattlefieldScoreData()
                    C_Timer.After(1, function()
                        AttemptSaveWithRetry("PVP_MATCH_STATE_CHANGED")
                    end)
                end
            end
            return -- Do not attempt initial capture on end-state transitions
        end

        -- Only attempt initial capture during the early phase of a match
        if not playerTracker.initialListCaptured then
            Debug("*** PVP_MATCH_STATE_CHANGED detected, checking if match has truly started ***")
            
            C_Timer.After(8, function()
                Debug("*** PVP_MATCH_STATE_CHANGED timer callback - checking match status ***")
                Debug("Current insideBG: " .. tostring(insideBG))
                Debug("Current initialListCaptured: " .. tostring(playerTracker.initialListCaptured))

                -- Guard against very late captures near the end of a match
                local timeSinceStart = GetTime() - bgStartTime
                if timeSinceStart >= 240 then
                    Debug("*** SKIPPING initial capture: more than 240s since start ***")
                    return
                end
                
                if insideBG and not playerTracker.initialListCaptured then
                    -- Check API duration first (most reliable)
                    local apiDuration = 0
                    if C_PvP and C_PvP.GetActiveMatchDuration then
                        apiDuration = C_PvP.GetActiveMatchDuration() or 0
                        Debug("API match duration: " .. apiDuration .. " seconds")
                        if apiDuration > 0 then
                            Debug("*** BATTLE HAS BEGUN detected via API duration: " .. apiDuration .. "s ***")
                            playerTracker.battleHasBegun = true
                            Debug("Battle begun flag set via API detection")
                        end
                    end
                    
                    -- Use conservative match start check (for epics, relax minimum players requirement via override)
                    local matchHasStarted = IsMatchStarted()
                    Debug("Conservative match started validation: " .. tostring(matchHasStarted))
                    
                    local numPlayers = GetNumBattlefieldScores()
                    Debug("Current player count: " .. numPlayers)
                    
                    if matchHasStarted then
                        Debug("*** MATCH CONFIRMED STARTED - Calling CaptureInitialPlayerList ***")
                        Debug("MATCH START CONFIRMED via conservative PVP_MATCH_STATE_CHANGED validation")
                        -- On epic BGs, allow initial capture with validation bypass once scoreboard shows both factions even if players < threshold
                        CaptureInitialPlayerList(IsEpicBattleground())
                    else
                        Debug("*** MATCH NOT YET STARTED - Conservative validation failed ***")
                        Debug("  - Conservative IsMatchStarted() returned false")
                    end
                else
                    Debug("*** CONDITIONS NOT MET ***")
                    if not insideBG then Debug("  - Not in BG anymore") end
                    if playerTracker.initialListCaptured then Debug("  - Initial list already captured") end
                end
            end)
        else
            Debug("*** Initial list already captured, ignoring this PVP_MATCH_STATE_CHANGED event ***")
        end


    elseif e == "UPDATE_BATTLEFIELD_SCORE" then
        -- Update BG status each time
        insideBG = newBGStatus
        
        -- Don't capture initial list here - wait for match start events
        
        if insideBG and not matchSaved then
            local timeSinceStart = GetTime() - bgStartTime
            
            -- Safety check for invalid start time
            if bgStartTime == 0 or timeSinceStart < 0 or timeSinceStart > 7200 then
                Debug("Invalid BG start time detected, resetting to now")
                bgStartTime = GetTime()
                timeSinceStart = 0
            end
            
            -- Check for winner to trigger save
            if timeSinceStart > MIN_BG_TIME then
                local winner = GetWinner and GetWinner() or nil
                
                if winner and winner ~= 0 and timeSinceStart > 120 then
                    Debug("Winner detected (" .. winner .. ") after " .. timeSinceStart .. " seconds")
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
        Debug("PVP_MATCH_COMPLETE event detected")
        local timeSinceStart = GetTime() - bgStartTime
        
        if timeSinceStart > MIN_BG_TIME then
            RequestBattlefieldScoreData()
            C_Timer.After(2, function()
                if not matchSaved then
                    AttemptSaveWithRetry("PVP_MATCH_COMPLETE")
                end
            end)
        end
        
    
    elseif (e == "PLAYER_LEAVING_WORLD" or e == "ZONE_CHANGED_NEW_AREA") and insideBG then
        Debug("Leaving battleground event: " .. e)
        insideBG = false
        bgStartTime = 0
        matchSaved = false
        saveInProgress = false
        StopOverflowTracking() -- Stop monitoring overflow
        -- Reset player tracker on BG exit
        playerTracker.initialPlayerList = {}
        playerTracker.finalPlayerList = {}
        playerTracker.initialListCaptured = false
        playerTracker.battleHasBegun = false
        playerTracker.detectedAFKers = {}
        playerTracker.damageHealing = {}
        playerTracker.lastCheck = {}
        playerTracker.overflowDetected = {}
        Debug("BG exit: All flags reset, player tracker cleared")
    end
end)

-- Special function to save BG data when exiting
function SaveExitingBattleground()
    if matchSaved then return end
    
    Debug("SaveExitingBattleground called")
    
    -- Request battlefield score data
    RequestBattlefieldScoreData()
    
    C_Timer.After(1, function()
        -- Get scores
        local data = CollectScoreData()
        
        -- Only save if we have data
        if #data > 0 then
            Debug("Got " .. #data .. " player records on exit, saving")
            CommitMatch(data)
        else
            Debug("No player data on exit, trying one more time")
            
            -- One last try
            RequestBattlefieldScoreData()
            C_Timer.After(1, function()
                local finalData = CollectScoreData()
                if #finalData > 0 then
                    Debug("Final attempt: got " .. #finalData .. " player records")
                    CommitMatch(finalData)
                else
                    Debug("Still no player data, giving up")
                end
            end)
        end
    end)
end

-- Removed duplicate PollUntilWinner function

-- Debug function to check BG type detection in real-time
function DebugBGTypeDetection()
    if not insideBG then
        print("=== BG Type Detection Debug ===")
        print("Not currently in a battleground")
        print("==============================")
        return
    end
    
    print("=== BG Type Detection Debug ===")
    
    -- Check API availability
    print("API Availability:")
    print("  C_PvP.IsInBrawl: " .. (C_PvP and C_PvP.IsInBrawl and "Available" or "Not Available"))
    print("  C_PvP.IsSoloRBG: " .. (C_PvP and C_PvP.IsSoloRBG and "Available" or "Not Available"))
    print("  C_PvP.IsBattleground: " .. (C_PvP and C_PvP.IsBattleground and "Available" or "Not Available"))
    print("  C_PvP.GetActiveMatchDuration: " .. (C_PvP and C_PvP.GetActiveMatchDuration and "Available" or "Not Available"))
    print("  IsRatedBattleground: " .. (IsRatedBattleground and "Available" or "Not Available"))
    print("  C_PvP.GetActiveMatchBracket: " .. (C_PvP and C_PvP.GetActiveMatchBracket and "Available" or "Not Available"))
    
    -- Test each detection method
    if C_PvP and C_PvP.IsInBrawl then
        local isBrawl = C_PvP.IsInBrawl()
        print("C_PvP.IsInBrawl(): " .. tostring(isBrawl))
    end
    
    if C_PvP and C_PvP.IsSoloRBG then
        local isSoloRBG = C_PvP.IsSoloRBG()
        print("C_PvP.IsSoloRBG(): " .. tostring(isSoloRBG))
    end
    
    if C_PvP and C_PvP.IsBattleground then
        local isBG = C_PvP.IsBattleground()
        print("C_PvP.IsBattleground(): " .. tostring(isBG))
    end
    
    if C_PvP and C_PvP.GetActiveMatchDuration then
        local duration = C_PvP.GetActiveMatchDuration()
        print("C_PvP.GetActiveMatchDuration(): " .. tostring(duration) .. " seconds")
    end
    
    if IsRatedBattleground then
        local isRated = IsRatedBattleground()
        print("IsRatedBattleground(): " .. tostring(isRated))
    end
    
    if C_PvP and C_PvP.GetActiveMatchBracket then
        local bracket = C_PvP.GetActiveMatchBracket()
        print("GetActiveMatchBracket(): " .. tostring(bracket))
    end
    
    if C_PvP and C_PvP.GetRatedBGInfo then
        local info = C_PvP.GetRatedBGInfo()
        print("GetRatedBGInfo(): " .. (info and "table" or tostring(info)))
        if info then
            for k, v in pairs(info) do
                print("  " .. k .. ": " .. tostring(v))
            end
        end
    end
    
    -- Check current player data
    local numPlayers = GetNumBattlefieldScores()
    print("Current battlefield players: " .. numPlayers)
    
    if numPlayers > 0 then
        RequestBattlefieldScoreData()
        C_Timer.After(0.2, function()
            local data = CollectScoreData(1)
            print("Collected player data: " .. #data .. " players")
            
            local allianceCount, hordeCount = 0, 0
            for _, player in ipairs(data) do
                if player.faction == "Alliance" then
                    allianceCount = allianceCount + 1
                elseif player.faction == "Horde" then
                    hordeCount = hordeCount + 1
                end
            end
            
            print("Team distribution: Alliance=" .. allianceCount .. ", Horde=" .. hordeCount)
            
            local map = C_Map.GetBestMapForUnit("player") or 0
            local mapInfo = C_Map.GetMapInfo(map)
            local mapName = (mapInfo and mapInfo.name) or "Unknown"
            print("Map: " .. mapName .. " (ID: " .. map .. ")")
            
            -- Simulate the detection logic
            local detectedType = "non-rated"
            
            if C_PvP and C_PvP.IsInBrawl and C_PvP.IsInBrawl() then
                detectedType = "brawl"
                print("DETECTION: Brawl")
            elseif C_PvP and C_PvP.IsSoloRBG and C_PvP.IsSoloRBG() then
                detectedType = "rated-blitz"
                print("DETECTION: Rated Blitz")
            elseif IsRatedBattleground and IsRatedBattleground() then
                detectedType = "rated"
                print("DETECTION: Standard rated BG")
            elseif C_PvP and C_PvP.IsBattleground and C_PvP.IsBattleground() then
                detectedType = "non-rated"
                print("DETECTION: Non-rated BG")
            elseif C_PvP and C_PvP.GetActiveMatchBracket then
                local bracket = C_PvP.GetActiveMatchBracket()
                if bracket and bracket > 0 then
                    detectedType = "rated-blitz"
                    print("DETECTION: Blitz via bracket")
                end
            end
            
            if detectedType == "non-rated" and #data == 16 and allianceCount == 8 and hordeCount == 8 then
                print("DETECTION: Possible Blitz via player count + team split")
                detectedType = "rated-blitz"
            end
            
            print("FINAL DETECTED TYPE: " .. detectedType)
            print("==============================")
        end)
    else
        print("No battlefield score data available")
        print("==============================")
    end
end

-- Debug function to check timing status in real-time
function DebugTimingStatus()
    local currentTime = GetTime()
    print("=== BGLogger Timing Status ===")
    print("Inside BG: " .. tostring(insideBG))
    print("Match Saved: " .. tostring(matchSaved))
    print("Current Time: " .. currentTime)
    
    -- Show API duration if available (primary source)
    if insideBG and C_PvP and C_PvP.GetActiveMatchDuration then
        local apiDuration = C_PvP.GetActiveMatchDuration()
        print("API Match Duration: " .. tostring(apiDuration) .. " seconds (PRIMARY SOURCE)")
    else
        print("API Match Duration: Not available or not in BG")
    end
    
    -- Show fallback timing
    print("BG Start Time (fallback): " .. bgStartTime .. " (" .. (bgStartTime > 0 and (currentTime - bgStartTime) .. "s ago" or "not set") .. ")")
    
    if bgStartTime > 0 then
        print("Fallback duration: " .. math.floor(currentTime - bgStartTime) .. " seconds")
    end
    
    -- Show current battlefield data if available
    if insideBG then
        local numPlayers = GetNumBattlefieldScores()
        print("Battlefield score players: " .. numPlayers)
    end
    print("=============================")
end

-- Print loaded message
print("|cff00ffffBGLogger|r loaded successfully! Use |cffffffff/bgstats|r to open the statistics window.")
print("|cff00ffffBGLogger|r Use |cffffffff/bglogger help|r for additional commands.")

-- Debug mode startup messages
if DEBUG_MODE then
    print("|cff00ffffBGLogger|r |cffff8800Debug mode is ACTIVE|r")
    print("|cff00ffffBGLogger|r Use |cffffffff/bglogger debug|r to toggle debug mode")
    print("|cff00ffffBGLogger|r Development functions are available in console")
end

-- Initialize minimap button after addon loads
C_Timer.After(1, function()
    -- Show minimap button by default (can be toggled off)
    if BGLoggerDB.minimapButton ~= false then -- Default to true unless explicitly disabled
        SetMinimapButtonShown(true)
        Debug("Minimap button initialized and shown")
    else
        Debug("Minimap button disabled in settings")
    end
end)

C_Timer.After(2, DetectAvailableAPIs) -- Delay to ensure APIs are loaded

-- Debug function to examine raw scoreboard data for objectives
function DebugObjectiveData()
    if not insideBG then
        print("=== Objective Data Debug ===")
        print("Not currently in a battleground")
        print("============================")
        return
    end
    
    print("=== RAW OBJECTIVE DATA DEBUG ===")
    
    local rows = GetNumBattlefieldScores()
    print("Total players: " .. rows)
    
    if rows == 0 then
        print("No scoreboard data available")
        print("=================================")
        return
    end
    
    -- Get map info for battleground-specific logic
    local map = C_Map.GetBestMapForUnit("player") or 0
    local mapInfo = C_Map.GetMapInfo(map)
    local mapName = (mapInfo and mapInfo.name) or "Unknown"
    print("Current Battleground: " .. mapName .. " (ID: " .. map .. ")")
    print("")
    
    -- Analyze first few players for objective data
    for i = 1, math.min(5, rows) do
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        if success and s and s.name then
            print("Player " .. i .. ": " .. s.name)
            print("  All available fields:")
            
            -- Sort fields for better readability
            local fields = {}
            for key, value in pairs(s) do
                table.insert(fields, {key = key, value = value})
            end
            table.sort(fields, function(a, b) return a.key < b.key end)
            
            -- Show all fields with their values
            for _, field in ipairs(fields) do
                local valueStr = tostring(field.value)
                if type(field.value) == "number" and field.value > 0 then
                    print("    " .. field.key .. " = " .. valueStr .. " *** NON-ZERO ***")
                else
                    print("    " .. field.key .. " = " .. valueStr)
                end
            end
            
            -- Test the current ExtractObjectiveData function
            local extractedObjectives, extractedBreakdown = ExtractObjectiveData(s, mapName)
            print("  ExtractObjectiveData result: " .. extractedObjectives)
            if extractedBreakdown and next(extractedBreakdown) then
                print("  Objective breakdown:")
                for objType, value in pairs(extractedBreakdown) do
                    print("    " .. objType .. ": " .. value)
                end
            end
            print("")
        else
            print("Player " .. i .. ": Failed to get data")
        end
    end
    
    print("=================================")
end

-- Quick debug function to see ALL fields from a single player
function DebugSinglePlayerAPI()
    if not insideBG then
        print("Not in a battleground")
        return
    end
    
    local rows = GetNumBattlefieldScores()
    if rows == 0 then
        print("No battlefield score data available")
        return
    end
    
    print("=== COMPLETE API DUMP (First Player) ===")
    local success, s = pcall(C_PvP.GetScoreInfo, 1)
    if success and s then
        print("Player: " .. (s.name or "Unknown"))
        print("Raw table contents:")
        
        -- Show everything in alphabetical order
        local sortedKeys = {}
        for key in pairs(s) do
            table.insert(sortedKeys, key)
        end
        table.sort(sortedKeys)
        
        for _, key in ipairs(sortedKeys) do
            local value = s[key]
            local typeStr = type(value)
            local valueStr = tostring(value)
            
            if typeStr == "number" then
                if value > 0 then
                    print(string.format("  %-25s = %s (%s) *** NON-ZERO ***", key, valueStr, typeStr))
                else
                    print(string.format("  %-25s = %s (%s)", key, valueStr, typeStr))
                end
            else
                print(string.format("  %-25s = %s (%s)", key, valueStr, typeStr))
            end
        end
    else
        print("Failed to get player data")
    end
    print("=====================================")
end

-- Debug function to test in-progress BG detection
function DebugInProgressDetection()
    if not insideBG then
        print("=== In-Progress BG Detection Debug ===")
        print("Not currently in a battleground")
        print("=====================================")
        return
    end
    
    print("=== IN-PROGRESS BG DETECTION DEBUG ===")
    
    -- Check API duration
    local apiDuration = 0
    if C_PvP and C_PvP.GetActiveMatchDuration then
        apiDuration = C_PvP.GetActiveMatchDuration() or 0
        print("API Match Duration: " .. apiDuration .. " seconds")
        
        if apiDuration > 30 then
            print("  RESULT: IN-PROGRESS (duration > 30s)")
        else
            print("  RESULT: Not in-progress or just started")
        end
    else
        print("API Match Duration: Not available")
    end
    
    -- Check team visibility
    local rows = GetNumBattlefieldScores()
    print("Battlefield score players: " .. rows)
    
    if rows > 0 then
        local allianceCount, hordeCount = 0, 0
        for i = 1, math.min(rows, 10) do
            local success, s = pcall(C_PvP.GetScoreInfo, i)
            if success and s and s.name then
                if s.faction == 0 then
                    hordeCount = hordeCount + 1
                elseif s.faction == 1 then
                    allianceCount = allianceCount + 1
                end
            end
        end
        
        print("Team visibility: Alliance=" .. allianceCount .. ", Horde=" .. hordeCount)
        
        if allianceCount > 0 and hordeCount > 0 and rows > 15 then
            print("  RESULT: IN-PROGRESS (both teams visible with " .. rows .. " players)")
        else
            print("  RESULT: Not in-progress (preparation phase or insufficient data)")
        end
    end
    
    -- Show current tracking status
    print("")
    print("Current tracking status:")
    print("  Joined in progress: " .. tostring(playerTracker.joinedInProgress or false))
    print("  Player joined in progress: " .. tostring(playerTracker.playerJoinedInProgress or false))
    print("  Battle has begun: " .. tostring(playerTracker.battleHasBegun or false))
    print("  Initial list captured: " .. tostring(playerTracker.initialListCaptured or false))
    print("  Initial list size: " .. tCount(playerTracker.initialPlayerList))
    
    print("=====================================")
end

-- Debug function to check overflow tracking status
function DebugOverflowStatus()
    print("=== OVERFLOW TRACKING DEBUG ===")
    print("Inside BG: " .. tostring(insideBG))
    print("Overflow timer running: " .. tostring(overflowTrackingTimer ~= nil))
    
    if not insideBG then
        print("Not in battleground - overflow tracking should be stopped")
        print("===============================")
        return
    end
    
    local trackedPlayers = tCount(playerTracker.lastCheck)
    print("Players being tracked: " .. trackedPlayers)
    
    if trackedPlayers == 0 then
        print("*** WARNING: No players being tracked for overflow! ***")
        print("This could indicate TrackPlayerStats() isn't running properly")
    end
    
    -- Show current player's tracking data
    local playerName = UnitName("player")
    local playerRealm = GetRealmName() or "Unknown-Realm"
    local playerKey = GetPlayerKey(playerName, playerRealm)
    
    print("")
    print("YOUR TRACKING DATA:")
    print("Player key: " .. playerKey)
    
    local yourLastCheck = playerTracker.lastCheck[playerKey]
    local yourOverflows = playerTracker.overflowDetected[playerKey]
    
    if yourLastCheck then
        print("Last recorded damage: " .. yourLastCheck.damage)
        print("Last recorded healing: " .. yourLastCheck.healing)
        print("Last check timestamp: " .. yourLastCheck.timestamp .. " (current: " .. GetTime() .. ")")
        print("Time since last check: " .. math.floor(GetTime() - yourLastCheck.timestamp) .. " seconds")
    else
        print("*** NO TRACKING DATA FOR YOU! ***")
        print("This means TrackPlayerStats() hasn't seen you yet")
    end
    
    if yourOverflows then
        print("Detected damage overflows: " .. yourOverflows.damageOverflows)
        print("Detected healing overflows: " .. yourOverflows.healingOverflows)
        
        if yourOverflows.healingOverflows > 0 then
            print("*** HEALING OVERFLOW DETECTED! ***")
        end
    else
        print("No overflow data initialized for you")
    end
    
    -- Get current scoreboard data to compare
    local rows = GetNumBattlefieldScores()
    if rows > 0 then
        for i = 1, rows do
            local success, s = pcall(C_PvP.GetScoreInfo, i)
            if success and s and s.name then
                local name, realm = s.name, ""
                if s.name:find("-") then
                    name, realm = s.name:match("^(.+)-(.+)$")
                else
                    realm = GetRealmName() or "Unknown-Realm"
                end
                
                local key = GetPlayerKey(name, realm)
                if key == playerKey then
                    local currentDamage = s.damageDone or s.damage or 0
                    local currentHealing = s.healingDone or s.healing or 0
                    
                    print("")
                    print("CURRENT SCOREBOARD VALUES:")
                    print("Current damage: " .. currentDamage)
                    print("Current healing: " .. currentHealing)
                    
                    if yourLastCheck then
                        print("Change since last check:")
                        print("  Damage: " .. (currentDamage - yourLastCheck.damage))
                        print("  Healing: " .. (currentHealing - yourLastCheck.healing))
                        
                        -- Check if this looks like an overflow
                        if currentHealing < yourLastCheck.healing and yourLastCheck.healing > OVERFLOW_DETECTION_THRESHOLD then
                            print("*** POTENTIAL OVERFLOW DETECTED NOW! ***")
                            print("Previous healing (" .. yourLastCheck.healing .. ") was above threshold")
                            print("Current healing (" .. currentHealing .. ") is lower")
                        end
                    end
                    break
                end
            end
        end
    end
    
    print("===============================")
end

-- Function to manually run overflow detection right now
function ForceOverflowCheck()
    if not insideBG then
        print("Not in a battleground")
        return
    end
    
    print("=== FORCING OVERFLOW CHECK ===")
    print("Running TrackPlayerStats() manually...")
    
    TrackPlayerStats()
    
    print("Check complete. Run DebugOverflowStatus() to see results.")
    print("==============================")
end

-- Enhanced overflow tracking with more frequent checks and better logging
function StartEnhancedOverflowTracking()
    if overflowTrackingTimer then
        overflowTrackingTimer:Cancel()
        Debug("Stopped existing overflow tracking")
    end
    
    Debug("Starting ENHANCED overflow tracking (every 5 seconds)")
    overflowTrackingTimer = C_Timer.NewTicker(5, function() -- Check every 5 seconds instead of 15
        if insideBG then
            TrackPlayerStats()
        else
            -- Auto-stop if we leave BG
            StopOverflowTracking()
        end
    end)
end

-- Test objective data collection on saved battlegrounds
function TestObjectiveCollection()
    print("=== Testing Objective Collection on Saved Data ===")
    
    local totalBGs = 0
    local bgsWithObjectives = 0
    local bgsByType = {}
    
    for key, data in pairs(BGLoggerDB) do
        if type(data) == "table" and data.stats and data.battlegroundName then
            totalBGs = totalBGs + 1
            local bgName = data.battlegroundName:lower()
            
            -- Count by BG type
            bgsByType[data.battlegroundName] = (bgsByType[data.battlegroundName] or 0) + 1
            
            -- Check if any players have objectives > 0
            local hasObjectives = false
            local maxObjectives = 0
            local totalObjectives = 0
            local playersWithObjectives = 0
            
            for _, player in ipairs(data.stats) do
                local objectives = player.objectives or 0
                if objectives > 0 then
                    hasObjectives = true
                    playersWithObjectives = playersWithObjectives + 1
                    totalObjectives = totalObjectives + objectives
                    maxObjectives = math.max(maxObjectives, objectives)
                end
            end
            
            if hasObjectives then
                bgsWithObjectives = bgsWithObjectives + 1
                print(data.battlegroundName .. " (" .. key .. "):")
                print("  Players with objectives: " .. playersWithObjectives .. "/" .. #data.stats)
                print("  Total objectives: " .. totalObjectives)
                print("  Max objectives: " .. maxObjectives)
                print("  Average per player: " .. math.floor(totalObjectives / #data.stats * 100) / 100)
            else
                print(data.battlegroundName .. " (" .. key .. "): NO OBJECTIVES RECORDED")
            end
        end
    end
    
    print("")
    print("Summary:")
    print("  Total BGs: " .. totalBGs)
    print("  BGs with objectives: " .. bgsWithObjectives)
    print("  BGs without objectives: " .. (totalBGs - bgsWithObjectives))
    
    print("")
    print("BGs by type:")
    for bgName, count in pairs(bgsByType) do
        print("  " .. bgName .. ": " .. count .. " matches")
    end
    
    print("================================================")
end

-- Debug function to check overflow tracking status
function DebugOverflowStatus()
    print("=== OVERFLOW TRACKING DEBUG ===")
    print("Inside BG: " .. tostring(insideBG))
    print("Overflow timer running: " .. tostring(overflowTrackingTimer ~= nil))
    
    if not insideBG then
        print("Not in battleground - overflow tracking should be stopped")
        print("===============================")
        return
    end
    
    local trackedPlayers = tCount(playerTracker.lastCheck)
    print("Players being tracked: " .. trackedPlayers)
    
    if trackedPlayers == 0 then
        print("*** WARNING: No players being tracked for overflow! ***")
        print("This could indicate TrackPlayerStats() isn't running properly")
    end
    
    -- Show current player's tracking data
    local playerName = UnitName("player")
    local playerRealm = GetRealmName() or "Unknown-Realm"
    local playerKey = GetPlayerKey(playerName, playerRealm)
    
    print("")
    print("YOUR TRACKING DATA:")
    print("Player key: " .. playerKey)
    
    local yourLastCheck = playerTracker.lastCheck[playerKey]
    local yourOverflows = playerTracker.overflowDetected[playerKey]
    
    if yourLastCheck then
        print("Last recorded damage: " .. yourLastCheck.damage)
        print("Last recorded healing: " .. yourLastCheck.healing)
        print("Last check timestamp: " .. yourLastCheck.timestamp .. " (current: " .. GetTime() .. ")")
        print("Time since last check: " .. math.floor(GetTime() - yourLastCheck.timestamp) .. " seconds")
    else
        print("*** NO TRACKING DATA FOR YOU! ***")
        print("This means TrackPlayerStats() hasn't seen you yet")
    end
    
    if yourOverflows then
        print("Detected damage overflows: " .. yourOverflows.damageOverflows)
        print("Detected healing overflows: " .. yourOverflows.healingOverflows)
        
        if yourOverflows.healingOverflows > 0 then
            print("*** HEALING OVERFLOW DETECTED! ***")
        end
    else
        print("No overflow data initialized for you")
    end
    
    -- Get current scoreboard data to compare
    local rows = GetNumBattlefieldScores()
    if rows > 0 then
        for i = 1, rows do
            local success, s = pcall(C_PvP.GetScoreInfo, i)
            if success and s and s.name then
                local name, realm = s.name, ""
                if s.name:find("-") then
                    name, realm = s.name:match("^(.+)-(.+)$")
                else
                    realm = GetRealmName() or "Unknown-Realm"
                end
                
                local key = GetPlayerKey(name, realm)
                if key == playerKey then
                    local currentDamage = s.damageDone or s.damage or 0
                    local currentHealing = s.healingDone or s.healing or 0
                    
                    print("")
                    print("CURRENT SCOREBOARD VALUES:")
                    print("Current damage: " .. currentDamage)
                    print("Current healing: " .. currentHealing)
                    
                    if yourLastCheck then
                        print("Change since last check:")
                        print("  Damage: " .. (currentDamage - yourLastCheck.damage))
                        print("  Healing: " .. (currentHealing - yourLastCheck.healing))
                        
                        -- Check if this looks like an overflow
                        if currentHealing < yourLastCheck.healing and yourLastCheck.healing > OVERFLOW_DETECTION_THRESHOLD then
                            print("*** POTENTIAL OVERFLOW DETECTED NOW! ***")
                            print("Previous healing (" .. yourLastCheck.healing .. ") was above threshold")
                            print("Current healing (" .. currentHealing .. ") is lower")
                        end
                    end
                    break
                end
            end
        end
    end
    
    print("===============================")
end

-- Function to manually run overflow detection right now
function ForceOverflowCheck()
    if not insideBG then
        print("Not in a battleground")
        return
    end
    
    print("=== FORCING OVERFLOW CHECK ===")
    print("Running TrackPlayerStats() manually...")
    
    TrackPlayerStats()
    
    print("Check complete. Run DebugOverflowStatus() to see results.")
    print("==============================")
end

-- Enhanced overflow tracking with more frequent checks and better logging
function StartEnhancedOverflowTracking()
    if overflowTrackingTimer then
        overflowTrackingTimer:Cancel()
        Debug("Stopped existing overflow tracking")
    end
    
    Debug("Starting ENHANCED overflow tracking (every 5 seconds)")
    overflowTrackingTimer = C_Timer.NewTicker(5, function() -- Check every 5 seconds instead of 15
        if insideBG then
            TrackPlayerStats()
        else
            -- Auto-stop if we leave BG
            StopOverflowTracking()
        end
    end)
end

-- Debug function to examine the stats table from GetScoreInfo
function DebugPVPStatInfo()
    if not insideBG then
        print("Not in a battleground")
        return
    end
    
    local rows = GetNumBattlefieldScores()
    if rows == 0 then
        print("No battlefield score data available")
        return
    end
    
    print("=== PVP STAT INFO DEBUG ===")
    
    -- Get map info for context
    local map = C_Map.GetBestMapForUnit("player") or 0
    local mapInfo = C_Map.GetMapInfo(map)
    local mapName = (mapInfo and mapInfo.name) or "Unknown"
    print("Current Battleground: " .. mapName .. " (ID: " .. map .. ")")
    print("")
    
    -- Examine first few players
    for i = 1, math.min(3, rows) do
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        if success and s and s.name then
            print("Player " .. i .. ": " .. s.name)
            
            if s.stats then
                print("  stats table found with " .. #s.stats .. " entries:")
                
                -- Sort by orderIndex for logical display
                local sortedStats = {}
                for j, stat in ipairs(s.stats) do
                    table.insert(sortedStats, stat)
                end
                table.sort(sortedStats, function(a, b) 
                    return (a.orderIndex or 999) < (b.orderIndex or 999) 
                end)
                
                for j, stat in ipairs(sortedStats) do
                    local statID = stat.pvpStatID or "nil"
                    local statValue = stat.pvpStatValue or 0
                    local orderIndex = stat.orderIndex or "nil"
                    local name = stat.name or "nil"
                    local tooltip = stat.tooltip or "nil"
                    local iconName = stat.iconName or "nil"
                    
                    print(string.format("    [%d] ID:%s Value:%s Order:%s", 
                        j, tostring(statID), tostring(statValue), tostring(orderIndex)))
                    print(string.format("        Name: '%s'", name))
                    print(string.format("        Tooltip: '%s'", tooltip))
                    print(string.format("        Icon: '%s'", iconName))
                    
                    -- Highlight non-zero values
                    if statValue > 0 then
                        print("        *** NON-ZERO VALUE: " .. statValue .. " ***")
                    end
                    print("")
                end
            else
                print("  *** NO STATS TABLE FOUND! ***")
                print("  This might indicate the API doesn't return stats for this player/BG")
            end
            print("  ────────────────────────────────────")
        else
            print("Player " .. i .. ": Failed to get data")
        end
    end
    
    print("===========================")
end

-- Function to map common objective stat IDs to their meanings
function DebugStatIDMappings()
    print("=== STAT ID RESEARCH ===")
    print("This function helps identify what different pvpStatID values mean")
    print("Run DebugPVPStatInfo() first to see the actual IDs in your current BG")
    print("")
    print("Common patterns to look for:")
    print("  - Flags captured/returned (CTF maps)")
    print("  - Bases assaulted/defended (resource maps)")
    print("  - Orb time/score (Temple of Kotmogu)")
    print("  - Gates destroyed (Strand)")
    print("  - Carts controlled (mines)")
    print("  - Any stat with name containing 'objective' or 'goal'")
    print("")
    print("Look for stats where:")
    print("  1. The 'name' field mentions objectives/flags/bases/etc")
    print("  2. The 'pvpStatValue' is > 0 for players who did objectives")
    print("  3. The 'tooltip' explains what the stat tracks")
    print("======================")
end

-- Test the enhanced objective system with breakdown support
function TestObjectiveBreakdownSystem()
    if not insideBG then
        print("Not in a battleground")
        return
    end
    
    local rows = GetNumBattlefieldScores()
    if rows == 0 then
        print("No battlefield score data available")
        return
    end
    
    print("=== TESTING OBJECTIVE BREAKDOWN SYSTEM ===")
    
    local map = C_Map.GetBestMapForUnit("player") or 0
    local mapInfo = C_Map.GetMapInfo(map)
    local mapName = (mapInfo and mapInfo.name) or "Unknown"
    print("Battleground: " .. mapName)
    print("")
    
    -- Collect sample data to test column determination
    local samplePlayers = {}
    for i = 1, math.min(5, rows) do
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        if success and s and s.name then
            local objectives, objectiveBreakdown = ExtractObjectiveData(s, mapName)
            
            local playerData = {
                name = s.name,
                objectives = objectives,
                objectiveBreakdown = objectiveBreakdown or {}
            }
            table.insert(samplePlayers, playerData)
            
            print("Player: " .. s.name)
            print("  Total objectives: " .. objectives)
            if objectiveBreakdown and next(objectiveBreakdown) then
                print("  Breakdown:")
                for objType, value in pairs(objectiveBreakdown) do
                    print("    " .. objType .. ": " .. value)
                end
            else
                print("  No breakdown data")
            end
            print("")
        end
    end
    
    -- Test column determination
    local recommendedColumns = GetObjectiveColumns(mapName, samplePlayers)
    print("RECOMMENDED COLUMNS FOR UI:")
    for i, col in ipairs(recommendedColumns) do
        print("  " .. i .. ". " .. col.name .. " (" .. col.key .. ") - " .. col.tooltip)
    end
    print("")
    
    -- Test export format
    print("SAMPLE EXPORT FORMAT:")
    if #samplePlayers > 0 then
        local testPlayer = samplePlayers[1]
        local exportObjectiveData = {
            total = testPlayer.objectives,
            breakdown = testPlayer.objectiveBreakdown
        }
        print("  Player: " .. testPlayer.name)
        print("  Objectives field for export:")
        print("    total: " .. exportObjectiveData.total)
        print("    breakdown: {")
        for objType, value in pairs(exportObjectiveData.breakdown) do
            print("      " .. objType .. ": " .. value .. ",")
        end
        print("    }")
    end
    
    print("=========================================")
end

-- Test the new stats-based objective extraction
function TestNewObjectiveExtraction()
    if not insideBG then
        print("Not in a battleground")
        return
    end
    
    local rows = GetNumBattlefieldScores()
    if rows == 0 then
        print("No battlefield score data available")
        return
    end
    
    print("=== TESTING NEW OBJECTIVE EXTRACTION ===")
    
    local map = C_Map.GetBestMapForUnit("player") or 0
    local mapInfo = C_Map.GetMapInfo(map)
    local mapName = (mapInfo and mapInfo.name) or "Unknown"
    print("Battleground: " .. mapName)
    print("")
    
    -- Test a few players
    for i = 1, math.min(5, rows) do
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        if success and s and s.name then
            print("Player: " .. s.name)
            
            -- Old method result
            local oldObjectives, oldBreakdown = ExtractObjectiveData(s, mapName)
            print("  Old extraction method: " .. oldObjectives)
            if oldBreakdown and next(oldBreakdown) then
                print("    Breakdown:")
                for objType, value in pairs(oldBreakdown) do
                    print("      " .. objType .. ": " .. value)
                end
            end
            
            -- New method: scan stats table
            local newObjectives = 0
            local objectiveStats = {}
            
            if s.stats then
                for _, stat in ipairs(s.stats) do
                    local name = (stat.name or ""):lower()
                    local value = stat.pvpStatValue or 0
                    
                    -- Look for objective-related stats based on common names
                    if value > 0 and (
                        name:find("flag") or name:find("capture") or name:find("return") or
                        name:find("base") or name:find("assault") or name:find("defend") or
                        name:find("orb") or name:find("gate") or name:find("cart") or
                        name:find("objective") or name:find("goal") or
                        name:find("tower") or name:find("graveyard") or name:find("mine")
                    ) then
                        newObjectives = newObjectives + value
                        table.insert(objectiveStats, {
                            name = stat.name,
                            value = value,
                            id = stat.pvpStatID
                        })
                    end
                end
            end
            
            print("  New extraction method: " .. newObjectives)
            if #objectiveStats > 0 then
                print("    Found objective stats:")
                for _, objStat in ipairs(objectiveStats) do
                    print("      - " .. objStat.name .. ": " .. objStat.value .. " (ID: " .. (objStat.id or "nil") .. ")")
                end
            end
            
            -- Compare results
            if oldObjectives ~= newObjectives then
                print("  *** METHODS DISAGREE! Old: " .. oldObjectives .. " vs New: " .. newObjectives .. " ***")
            else
                print("  Methods agree: " .. oldObjectives)
            end
            print("")
        end
    end
    
    print("=========================================")
end