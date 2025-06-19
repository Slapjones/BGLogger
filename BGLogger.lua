-- BGLogger: Battleground Statistics Tracker
local addonName = "BGLogger"
BGLoggerDB = BGLoggerDB or {}

---------------------------------------------------------------------
-- Config / globals
---------------------------------------------------------------------
local WINDOW, DetailLines, ListButtons = nil, {}, {}
local LINE_HEIGHT            = 14
local WIN_W, WIN_H           = 900, 750
local insideBG, matchSaved   = false, false
local bgStartTime            = 0
local MIN_BG_TIME            = 30  -- Minimum seconds in BG before saving
local GetWinner              = _G.GetBattlefieldWinner -- may be nil on some clients
local DEBUG_MODE             = true -- Set to true for easier troubleshooting
local saveInProgress         = false
local ALLOW_TEST_EXPORTS     = DEBUG_MODE
-- Removed unused timing detection variables since we now use C_PvP.GetActiveMatchDuration()

---------------------------------------------------------------------
-- Simple Player List Tracking
---------------------------------------------------------------------
local playerTracker = {
    initialPlayerList = {}, -- Players present at match start
    finalPlayerList = {},   -- Players present at match end (when we save)
    initialListCaptured = false,
    battleHasBegun = false  -- Flag to track if we've seen the "battle has begun" message
}

---------------------------------------------------------------------
-- Debug Functions
---------------------------------------------------------------------
local function Debug(msg)
    if DEBUG_MODE then
        print("|cff00ffffBGLogger:|r " .. tostring(msg))
    end
end

---------------------------------------------------------------------
-- Simple Player List Tracking Functions
---------------------------------------------------------------------

-- Helper function to count table entries
local function tCount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- Reset tracker for new battleground
local function ResetPlayerTracker()
    -- Only reset if we're not in the middle of a match
    if not insideBG or matchSaved then
        playerTracker.initialPlayerList = {}
        playerTracker.finalPlayerList = {}
        playerTracker.initialListCaptured = false
        playerTracker.battleHasBegun = false
        playerTracker.detectedAFKers = {}
        Debug("Player tracker reset for new battleground")
    else
        Debug("Skipping tracker reset - still in active battleground")
    end
end

-- Generate unique player key
local function GetPlayerKey(name, realm)
    return (name or "Unknown") .. "-" .. (realm or "Unknown")
end

-- Track initial player count to detect when enemy team becomes visible
local initialPlayerCount = 0

-- CONSERVATIVE match start detection - requires multiple confirmations
local function IsMatchStarted()
    print("*** IsMatchStarted() called ***")
    local rows = GetNumBattlefieldScores()
    if rows == 0 then 
        print("IsMatchStarted: No battlefield scores available")
        return false 
    end
    
    -- REQUIREMENT 1: Must have "battle has begun" message
    if not playerTracker.battleHasBegun then
        print("IsMatchStarted: Battle has not begun yet (no battle start message)")
        return false
    end
    
    -- REQUIREMENT 2: Check API duration (most reliable indicator)
    local apiDuration = 0
    if C_PvP and C_PvP.GetActiveMatchDuration then
        apiDuration = C_PvP.GetActiveMatchDuration() or 0
        print("IsMatchStarted: API duration = " .. apiDuration .. " seconds")
        
        -- If API shows active duration > 5 seconds, match has definitely started
        if apiDuration > 5 then
            print("IsMatchStarted: CONFIRMED via API duration > 5 seconds")
            return true
        elseif apiDuration == 0 then
            print("IsMatchStarted: API shows 0 duration - match not started")
            return false
        end
    else
        print("IsMatchStarted: API duration not available")
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
    local hasMinimumPlayers = (rows >= 15)
    
    -- REQUIREMENT 4: Minimum time since entering BG (prevent instant capture)
    local timeSinceEntered = GetTime() - bgStartTime
    local minimumWaitTime = 45 -- Wait at least 45 seconds after entering BG
    
    print("Match start requirements check:")
    print("  Battle begun message: " .. tostring(playerTracker.battleHasBegun))
    print("  API duration: " .. apiDuration .. " seconds")
    print("  Both factions visible: " .. tostring(bothFactionsVisible) .. " (A=" .. allianceCount .. ", H=" .. hordeCount .. ")")
    print("  Minimum players: " .. tostring(hasMinimumPlayers) .. " (" .. rows .. " total)")
    print("  Time since entered: " .. math.floor(timeSinceEntered) .. "s (min: " .. minimumWaitTime .. "s)")
    
    -- ALL requirements must be met
    local matchStarted = playerTracker.battleHasBegun and 
                        apiDuration > 0 and 
                        bothFactionsVisible and 
                        hasMinimumPlayers and
                        timeSinceEntered >= minimumWaitTime
    
    print("  FINAL RESULT: " .. tostring(matchStarted))
    
    return matchStarted
end

-- Capture initial player list (call this after match starts, when both teams are visible)
local function CaptureInitialPlayerList(skipMatchStartCheck)
    print("*** CaptureInitialPlayerList called (skipMatchStartCheck=" .. tostring(skipMatchStartCheck) .. ") ***")
    print("Already captured: " .. tostring(playerTracker.initialListCaptured))
    
    if playerTracker.initialListCaptured then 
        print("Initial player list already captured, skipping")
        return 
    end
    
    -- Critical: Only capture if match has actually started (both teams visible)
    -- Skip this check if called from a reliable source like PVP_MATCH_STATE_CHANGED
    if not skipMatchStartCheck and not IsMatchStarted() then
        print("Match hasn't started yet (enemy team not visible), skipping initial capture")
        return
    end
    
    if skipMatchStartCheck then
        print("*** SKIPPING MATCH START VALIDATION - called from reliable event source ***")
        print("Proceeding directly to capture logic")
    else
        print("Using match start validation (called from fallback/debug)")
    end
    
    local rows = GetNumBattlefieldScores()
    print("Battlefield scores available: " .. rows)
    
    if rows == 0 then 
        print("No battlefield scores available yet, skipping initial capture")
        return 
    end
    
    print("*** MATCH HAS STARTED - Starting initial capture with " .. rows .. " players ***")
    
    -- Clear any existing data
    playerTracker.initialPlayerList = {}
    
    -- Get the best realm name once for this capture session
    local playerRealm = GetRealmName() or "Unknown-Realm"
    if GetNormalizedRealmName and GetNormalizedRealmName() ~= "" then
        playerRealm = GetNormalizedRealmName()
    end
    print("Using player realm: '" .. playerRealm .. "'")
    
    for i = 1, rows do
        local success, s = pcall(C_PvP.GetScoreInfo, i)
        if success and s and s.name then
            local playerName, realmName = s.name, ""
            
            print("Processing player " .. i .. ": " .. s.name)
            
            if s.name:find("-") then
                playerName, realmName = s.name:match("^(.+)-(.+)$")
                print("  Split name: '" .. playerName .. "' realm: '" .. realmName .. "'")
            else
                print("  No realm in name, using fallback methods")
            end
            
            if (not realmName or realmName == "") and s.realm then
                realmName = s.realm
                print("  Using s.realm: '" .. realmName .. "'")
            end
            
            if (not realmName or realmName == "") and s.guid then
                local _, _, _, _, _, _, _, realmFromGUID = GetPlayerInfoByGUID(s.guid)
                if realmFromGUID and realmFromGUID ~= "" then
                    realmName = realmFromGUID
                    print("  Using GUID realm: '" .. realmName .. "'")
                end
            end
            
            if not realmName or realmName == "" then
                realmName = playerRealm
                print("  Using fallback playerRealm: '" .. realmName .. "'")
            end
            
            -- CRITICAL: Normalize realm name exactly like CollectScoreData does
            realmName = realmName:gsub("%s+", ""):gsub("'", "")
            print("  Normalized realm: '" .. realmName .. "'")
            
            local playerKey = GetPlayerKey(playerName, realmName)
            print("  Generated key: '" .. playerKey .. "'")
            
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
            print("  ✓ Added to initial list: " .. className .. " " .. factionName)
            
            -- Special check for current player
            if playerName == UnitName("player") then
                print("  *** THIS IS THE CURRENT PLAYER ***")
            end
        else
            print("Failed to get score info for player " .. i)
        end
    end
    
    playerTracker.initialListCaptured = true
    local initialCount = tCount(playerTracker.initialPlayerList)
    print("*** Initial capture COMPLETE: " .. initialCount .. " players stored ***")
    
    -- Show first few players as verification with complete info
    local count = 0
    for playerKey, playerInfo in pairs(playerTracker.initialPlayerList) do
        if count < 3 then
            print("  Sample: " .. playerKey .. " (" .. (playerInfo.class or "Unknown") .. " " .. (playerInfo.faction or "Unknown") .. ")")
            count = count + 1
        end
    end
end

-- Capture final player list (call this when saving match data)
local function CaptureFinalPlayerList(playerStats)
    print("*** CaptureFinalPlayerList called ***")
    print("Player stats provided: " .. #playerStats)
    
    -- Critical debug: Check if current player is in the provided data
    local currentPlayerName = UnitName("player")
    local currentPlayerRealm = GetRealmName() or "Unknown-Realm"
    local currentPlayerKey = GetPlayerKey(currentPlayerName, currentPlayerRealm)
    
    print("*** SEARCHING FOR CURRENT PLAYER ***")
    print("Current player name: '" .. currentPlayerName .. "'")
    print("Current player realm: '" .. currentPlayerRealm .. "'")
    print("Current player key: '" .. currentPlayerKey .. "'")
    
    local foundCurrentPlayer = false
    
    playerTracker.finalPlayerList = {}
    
    for i, player in ipairs(playerStats) do
        print("Processing final player " .. i .. ": " .. player.name .. "-" .. player.realm)
        
        local playerKey = GetPlayerKey(player.name, player.realm)
        print("  Generated key: '" .. playerKey .. "'")
        
        -- Check if this matches current player
        if player.name == currentPlayerName then
            print("  *** NAME MATCH - THIS IS THE CURRENT PLAYER ***")
            foundCurrentPlayer = true
        end
        
        if playerKey == currentPlayerKey then
            print("  *** KEY MATCH - THIS IS THE CURRENT PLAYER ***")
            foundCurrentPlayer = true
        end
        
        playerTracker.finalPlayerList[playerKey] = {
            name = player.name,
            realm = player.realm,
            playerData = player -- Keep reference to full player data
        }
        print("  ✓ Added to final list")
    end
    
    print("*** CURRENT PLAYER SEARCH RESULT ***")
    print("Found current player in final data: " .. tostring(foundCurrentPlayer))
    
    if not foundCurrentPlayer then
        print("*** ERROR: Current player NOT found in final player data! ***")
        print("This will cause incorrect AFKer detection!")
        print("Possible causes:")
        print("  1. CollectScoreData() is not including current player")
        print("  2. Name/realm mismatch between initial and final capture")
        print("  3. Player left BG before final capture (but you're still here)")
    end
    
    local finalCount = tCount(playerTracker.finalPlayerList)
    print("*** Final capture COMPLETE: " .. finalCount .. " players stored ***")
    
    -- Show first few players as verification
    local count = 0
    for playerKey, playerInfo in pairs(playerTracker.finalPlayerList) do
        if count < 3 then
            print("  Sample: " .. playerKey)
            count = count + 1
        end
    end
end

-- Simple comparison to determine AFKers and Backfills
local function AnalyzePlayerLists()
    print("*** AnalyzePlayerLists called ***")
    
    local afkers = {}
    local backfills = {}
    local normal = {}
    
    local initialCount = tCount(playerTracker.initialPlayerList)
    local finalCount = tCount(playerTracker.finalPlayerList)
    
    print("Initial list size: " .. initialCount)
    print("Final list size: " .. finalCount)
    
    if initialCount == 0 then
        print("*** WARNING: Initial list is EMPTY! Everyone will be marked as backfill! ***")
    end
    
    if finalCount == 0 then
        print("*** WARNING: Final list is EMPTY! This shouldn't happen! ***")
        return afkers, backfills, normal
    end
    
    print("*** SIMPLIFIED LOGIC ***")
    print("Rule 1: Anyone on final scoreboard = NOT an AFKer (they're still here)")
    print("Rule 2: Anyone on initial list = NOT a backfill (they were here from start)")
    
    print("Step 1: Finding AFKers (in initial but NOT on final scoreboard)")
    for playerKey, playerInfo in pairs(playerTracker.initialPlayerList) do
        if not playerTracker.finalPlayerList[playerKey] then
            table.insert(afkers, playerInfo)
            print("  AFKer: " .. playerKey .. " (was in initial, not on final scoreboard)")
        end
    end
    print("Found " .. #afkers .. " AFKers")
    
    print("Step 2: Processing final scoreboard - everyone here is NOT an AFKer")
    for playerKey, playerInfo in pairs(playerTracker.finalPlayerList) do
        local playerData = playerInfo.playerData
        
        if playerTracker.initialPlayerList[playerKey] then
            -- Was in initial list = normal player (not backfill, not AFKer)
            table.insert(normal, playerData)
            print("  Normal: " .. playerKey .. " (in initial list, on final scoreboard)")
        else
            -- Was NOT in initial list = backfill (not AFKer since they're on final scoreboard)
            table.insert(backfills, playerData)
            print("  Backfill: " .. playerKey .. " (NOT in initial list, on final scoreboard)")
        end
    end
    
    print("*** Analysis COMPLETE ***")
    print("Normal players: " .. #normal .. " (in initial, on final)")
    print("Backfills: " .. #backfills .. " (NOT in initial, on final)")
    print("AFKers: " .. #afkers .. " (in initial, NOT on final)")
    
    -- Special check for current player
    local playerName = UnitName("player")
    local playerRealm = GetRealmName() or "Unknown-Realm"
    local yourKey = GetPlayerKey(playerName, playerRealm)
    
    print("*** YOUR STATUS CHECK ***")
    print("Your key: " .. yourKey)
    print("In initial: " .. (playerTracker.initialPlayerList[yourKey] and "YES" or "NO"))
    print("In final: " .. (playerTracker.finalPlayerList[yourKey] and "YES" or "NO"))
    
    -- Determine your status using the simple rules
    local yourStatus = "UNKNOWN"
    if playerTracker.finalPlayerList[yourKey] then
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
    
    print("Your status: " .. yourStatus)
    
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
    Debug("GenerateDataHash called with " .. #playerList .. " players")
    
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
    
    Debug("Generated hash: " .. hash)
    return hash, metadata
end

-- Verify a hash against stored data (for debugging/validation)
function VerifyDataHash(storedHash, battlegroundMetadata, playerList)
    local regeneratedHash, metadata = GenerateDataHash(battlegroundMetadata, playerList)
    local isValid = (storedHash == regeneratedHash)
    
    Debug("Hash verification: " .. (isValid and "VALID" or "INVALID"))
    Debug("Stored: " .. tostring(storedHash))
    Debug("Regenerated: " .. tostring(regeneratedHash))
    
    return isValid, regeneratedHash, metadata
end

-- Extract battleground metadata from saved data for hash verification
local function ExtractBattlegroundMetadata(data)
    return {
        battleground = data.battlegroundName or "Unknown Battleground",
        duration = data.duration or 0,
        winner = data.winner or "",
        type = data.type or "non-rated",
        date = data.dateISO or date("!%Y-%m-%dT%H:%M:%SZ")
    }
end

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
    print("*** CollectScoreData: Looking for current player ***")
    print("Current player: " .. currentPlayerName .. "-" .. currentPlayerRealm)
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
                print("*** FOUND CURRENT PLAYER in CollectScoreData ***")
                print("  Name: " .. playerName .. " (matches: " .. currentPlayerName .. ")")
                print("  Realm: " .. realmName .. " (current: " .. currentPlayerRealm .. ")")
                foundCurrentPlayer = true
            end
            
            -- Create player data (participation will be determined later)
            local playerData = {
                name = playerName,
                realm = realmName,
                faction = factionName,
                class = className,
                spec = specName,
                damage = s.damageDone or s.damage or 0,
                healing = s.healingDone or s.healing or 0,
                kills = s.killingBlows or s.kills or 0,
                deaths = s.deaths or 0,
                honorableKills = s.honorableKills or s.honorKills or 0,
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
    
    print("*** CollectScoreData RESULT ***")
    print("Found current player: " .. tostring(foundCurrentPlayer))
    if not foundCurrentPlayer then
        print("*** ERROR: Current player NOT found in scoreboard data! ***")
        print("This will cause AFKer detection!")
    end
    
    -- Simple AFKer/Backfill analysis using the data we just collected
    print("*** Performing AFKer/Backfill analysis ***")
    print("Final data has " .. #t .. " players")
    print("Initial list has " .. tCount(playerTracker.initialPlayerList) .. " players")
    
    -- Create AFKer list: people in initial list but NOT in final data
    local afkers = {}
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
            print("AFKer: " .. playerKey .. " (" .. afkerData.class .. " " .. afkerData.faction .. " - in initial, not in final)")
        end
    end
    
    -- Set isBackfill flag for each player in final data
    for _, player in ipairs(t) do
        local playerKey = GetPlayerKey(player.name, player.realm)
        
        -- If player was NOT in initial list = backfill
        if not playerTracker.initialPlayerList[playerKey] then
            player.isBackfill = true
            print("Backfill: " .. playerKey .. " (not in initial)")
        else
            player.isBackfill = false
            print("Normal: " .. playerKey .. " (in initial)")
        end
    end
    
    -- Store AFKer list for later use in exports
    playerTracker.detectedAFKers = afkers
    
    print("Analysis complete: " .. #afkers .. " AFKers, " .. #t .. " final players")
    
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
        
        -- GENERATE HASH IMMEDIATELY with current live data
        local battlegroundMetadata = {
            battleground = mapName,
            duration = duration,
            winner = winner,
            type = bgType,
            date = date("!%Y-%m-%dT%H:%M:%SZ")
        }
        
        local dataHash, hashMetadata = GenerateDataHash(battlegroundMetadata, list)
        Debug("Generated hash at save time: " .. dataHash)
        
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
            
            -- Simple AFKer tracking
            afkerList = playerTracker.detectedAFKers or {},
            
            -- INTEGRITY DATA - Generated at save time, not export time
            integrity = {
                hash = dataHash,
                metadata = hashMetadata,
                generatedAt = GetServerTime(),
                serverTime = GetServerTime(),
                version = "BGLogger_v1.0",
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

function ExportBattleground(key)
    Debug("ExportBattleground called for key: " .. tostring(key))
    
    -- Add safety check for nil key
    if not key or key == "" then
        print("|cff00ffffBGLogger:|r Error: No battleground key provided")
        return
    end
    
    if not BGLoggerDB[key] then
        print("|cff00ffffBGLogger:|r No data found for battleground " .. tostring(key))
        return
    end
    
    local data = BGLoggerDB[key]
    Debug("Found battleground data with " .. (#(data.stats or {})) .. " players")
    
    -- Check if integrity data exists (for backwards compatibility)
    if not data.integrity and not ALLOW_TEST_EXPORTS then
        print("|cff00ffffBGLogger:|r Warning: This battleground was saved without integrity data and cannot be exported safely.")
        print("|cff00ffffBGLogger:|r Only battlegrounds saved with the updated addon can be uploaded to prevent data tampering.")
        return
    end
    
    -- Check if this is a brawl and warn user
    if data.type == "brawl" then
        print("|cff00ffffBGLogger:|r Warning: This is a BRAWL record.")
        print("|cff00ffffBGLogger:|r Brawls use modified rules and should not be uploaded to the main battleground statistics website.")
        print("|cff00ffffBGLogger:|r The export will be generated for debugging/archival purposes only.")
        print("|cff00ffffBGLogger:|r Consider if you really want to export this brawl data.")
    end
    
    local mapName = data.battlegroundName or "Unknown Battleground"
    
    -- Process players and convert numbers to strings to preserve precision
    local exportPlayers = {}
    local afkersList = {}
    
    for _, player in ipairs(data.stats or {}) do
        -- Add to main player list
        table.insert(exportPlayers, {
            name = player.name,
            realm = player.realm,
            faction = player.faction or player.side,
            class = player.class,
            spec = player.spec,
            damage = tostring(player.damage or player.dmg or 0),  -- Convert to string
            healing = tostring(player.healing or player.heal or 0), -- Convert to string
            kills = player.kills or player.killingBlows or player.kb or 0,
            deaths = player.deaths or 0,
            honorableKills = player.honorableKills or 0,
            objectives = 0,
            -- Simple participation data
            isBackfill = player.isBackfill or false
        })
    end
    
    -- Get AFKer list from stored data (AFKers who left and aren't in final stats)
    if data.afkerList then
        for _, afker in ipairs(data.afkerList) do
            table.insert(afkersList, {
                name = afker.name,
                realm = afker.realm,
                faction = "Unknown", -- We don't have this data for AFKers
                class = "Unknown",   -- We don't have this data for AFKers
                isBackfill = false   -- Could theoretically be true, but we'll keep it simple
            })
        end
    end
    
    -- Convert to website-compatible JSON format
    local exportData = {
        battleground = mapName,
        date = data.dateISO or date("!%Y-%m-%dT%H:%M:%SZ"),
        type = data.type or "non-rated",
        duration = tostring(data.duration or 0), -- Legacy field
        trueDuration = tostring(data.trueDuration or data.duration or 0), -- Preferred field for website
        winner = data.winner or "",
        players = exportPlayers,
        afkers = afkersList, -- Separate AFKer list for website
        integrity = data.integrity
    }
    
    Debug("Export using pre-generated hash: " .. (data.integrity.hash or "missing"))
    Debug("Export includes " .. #exportPlayers .. " total players, " .. #afkersList .. " AFKers")
    
    -- Count backfills in export data for debug
    local backfillCount = 0
    for _, player in ipairs(exportPlayers) do
        if player.isBackfill then backfillCount = backfillCount + 1 end
    end
    Debug("Export includes " .. backfillCount .. " backfills")
    
    -- Generate JSON string
    local success, jsonString = pcall(TableToJSON, exportData)
    
    if not success then
        print("|cff00ffffBGLogger:|r Error generating JSON: " .. tostring(jsonString))
        return
    end
    
    Debug("JSON generated successfully with pre-generated integrity hash, length: " .. #jsonString)
    
    -- Create filename
    local filename = string.format("BGLogger_%s_%s.json", 
        mapName:gsub("%s+", "_"):gsub("[^%w_]", ""),
        date("!%Y%m%d_%H%M%S")
    )
    
    ShowJSONExportFrame(jsonString, filename)
    
    print("|cff00ffffBGLogger:|r Exported " .. mapName .. " with verified integrity hash")
end

-- Convert Lua table to JSON string
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

-- Show JSON export frame with read-only text
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

-- Show export menu
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
            func = ExportAllBattlegrounds
        },
        {
            text = "Cancel",
            func = function() end
        }
    }
    
    EasyMenu(menu, CreateFrame("Frame", "BGLoggerExportMenu", UIParent, "UIDropDownMenuTemplate"), "cursor", 0, 0, "MENU")
end

---------------------------------------------------------------------
-- UI factory - completely rebuilt
---------------------------------------------------------------------
local function MakeDetailLine(parent, i)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 0, -(i-1)*LINE_HEIGHT)
    fs:SetWidth(WIN_W-60)
    
    -- Use a monospace font for better column alignment
    fs:SetFont("Fonts\\ARIALN.TTF", 14, "OUTLINE")
    
    DetailLines[i] = fs
    return fs
end

local function MakeListButton(parent, i)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetHeight(LINE_HEIGHT*2)  -- Make buttons bigger for easier clicking
    b:SetPoint("TOPLEFT", 0, -(i-1)*(LINE_HEIGHT*2 + 2))  -- Add spacing between buttons
    b:SetPoint("RIGHT", parent, "RIGHT", -20, 0)  -- Don't extend all the way to the right
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
    
    -- Clear existing detail lines completely
    for i = 1, #DetailLines do
        if DetailLines[i] then
            DetailLines[i]:SetText("")
            DetailLines[i]:Hide()
        end
    end

    -- Also clear any lines beyond our current data
    local maxLinesToClear = math.max(50, #DetailLines) -- Clear at least 50 lines
    for i = 1, maxLinesToClear do
        if DetailLines[i] then
            DetailLines[i]:SetText("")
            DetailLines[i]:Hide()
        end
    end
    
    -- Check if data exists
    if not BGLoggerDB[key] then
        local fs = DetailLines[1] or MakeDetailLine(WINDOW.detailContent, 1)
        fs:SetText("No data found for this battleground")
        fs:Show()
        WINDOW.detailContent:SetHeight(LINE_HEIGHT)
        return
    end
    
    local data = BGLoggerDB[key]
    
    -- Add battleground info header
    local headerInfo = DetailLines[1] or MakeDetailLine(WINDOW.detailContent, 1)
    local mapInfo = C_Map.GetMapInfo(data.mapID or 0)
    local mapName = (mapInfo and mapInfo.name) or "Unknown Map"
    
    local bgInfo = string.format("Battleground: %s | Duration: %s | Winner: %s | Type: %s",
        mapName,
        data.duration and (math.floor(data.duration / 60) .. ":" .. string.format("%02d", data.duration % 60)) or "Unknown",
        data.winner or "Unknown",
        data.type or "Unknown"
    )
    headerInfo:SetText(bgInfo)
    headerInfo:Show()
    
    -- Add separator
    local separator1 = DetailLines[2] or MakeDetailLine(WINDOW.detailContent, 2)
    separator1:SetText(string.rep("=", 105))
    separator1:Show()
    
    -- UPDATED: Column headers with backfill status
    local header = DetailLines[3] or MakeDetailLine(WINDOW.detailContent, 3)
    header:SetText("Player Name            Realm          Class       Spec         Faction   Damage    Healing   Kills Deaths HK  Status")
    header:Show()
    
    -- Add separator line
    local separator2 = DetailLines[4] or MakeDetailLine(WINDOW.detailContent, 4)
    separator2:SetText(string.rep("-", 125))
    separator2:Show()
    
    -- Get regular players (all players in stats since AFKers aren't in the final stats)
    local rows = data.stats or {}
    local regularPlayers = rows
    
    -- Get AFKers from stored list
    local afkers = data.afkerList or {}
    
    -- Build detail lines for regular players only
    for i, row in ipairs(regularPlayers) do
        local fs = DetailLines[i+4] or MakeDetailLine(WINDOW.detailContent, i+4)
        
        -- Check for both new and legacy data format
        local damage = row.damage or row.dmg or 0
        local healing = row.healing or row.heal or 0
        local kills = row.kills or row.killingBlows or row.kb or 0
        local deaths = row.deaths or 0
        local honorableKills = row.honorableKills or row.honorKills or 0
        local realm = row.realm or "Unknown"
        local class = row.class or "Unknown"
        local spec = row.spec or "Unknown"
        local faction = row.faction or row.side or "Unknown"
        
        -- Simple participation data
        local isBackfill = row.isBackfill or false
        
        -- Create status string
        local status = ""
        if isBackfill then
            status = "BF"   -- Backfill
        else
            status = "OK"   -- Normal participation
        end
        
        -- Truncate long names/realms to fit
        local displayName = string.sub(row.name or "Unknown", 1, 18)
        local displayRealm = string.sub(realm, 1, 12)
        local displayClass = string.sub(class, 1, 9)
        local displaySpec = string.sub(spec, 1, 10)
        local displayFaction = string.sub(faction, 1, 8)
        
        -- UPDATED: Show kills, deaths, and backfill status
        fs:SetFormattedText("%-18s %-12s %-9s %-10s %-8s %8s %8s %5d %6d %3d %6s",
            displayName,
            displayRealm,
            displayClass,
            displaySpec,
            displayFaction,
            damage >= 1000000 and string.format("%.1fM", damage/1000000) or 
            damage >= 1000 and string.format("%.0fK", damage/1000) or tostring(damage),
            healing >= 1000000 and string.format("%.1fM", healing/1000000) or 
            healing >= 1000 and string.format("%.0fK", healing/1000) or tostring(healing),
            kills,
            deaths,
            honorableKills,
            status)
            
        -- Color code the text based on status
        if isBackfill then
            fs:SetTextColor(1, 1, 0.5) -- Light yellow for backfills
        else
            fs:SetTextColor(1, 1, 1) -- White for normal players
        end
        fs:Show()
    end
    
    -- Add summary footer for regular players
    local summaryLine = DetailLines[#regularPlayers+6] or MakeDetailLine(WINDOW.detailContent, #regularPlayers+6)
    summaryLine:SetText(string.rep("-", 125))
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
    
    -- Show totals for regular players
    totalLine:SetFormattedText("TOTALS (%d active players)%42s %8s %8s %5d %6d",
        #regularPlayers,
        "",
        totalDamage >= 1000000 and string.format("%.1fM", totalDamage/1000000) or 
        totalDamage >= 1000 and string.format("%.0fK", totalDamage/1000) or tostring(totalDamage),
        totalHealing >= 1000000 and string.format("%.1fM", totalHealing/1000000) or 
        totalHealing >= 1000 and string.format("%.0fK", totalHealing/1000) or tostring(totalHealing),
        totalKills,
        totalDeaths)
    totalLine:Show()
    
    local currentLineIndex = #regularPlayers + 8
    
    -- Add backfill summary for regular players
    if backfillCount > 0 then
        local backfillSummaryLine = DetailLines[currentLineIndex] or MakeDetailLine(WINDOW.detailContent, currentLineIndex)
        backfillSummaryLine:SetFormattedText("Backfills among active players: %d", backfillCount)
        backfillSummaryLine:SetTextColor(1, 1, 0) -- Yellow text
        backfillSummaryLine:Show()
        currentLineIndex = currentLineIndex + 1
    end
    
    -- Add AFKer section if there are any
    if #afkers > 0 then
        -- Add separator before AFKer section
        local afkerSeparator = DetailLines[currentLineIndex] or MakeDetailLine(WINDOW.detailContent, currentLineIndex)
        afkerSeparator:SetText("")
        afkerSeparator:Show()
        currentLineIndex = currentLineIndex + 1
        
        -- AFKer section header
        local afkerHeader = DetailLines[currentLineIndex] or MakeDetailLine(WINDOW.detailContent, currentLineIndex)
        afkerHeader:SetText("AFK/Early Leavers (" .. #afkers .. " players):")
        afkerHeader:SetTextColor(1, 0.5, 0.5) -- Red text
        afkerHeader:Show()
        currentLineIndex = currentLineIndex + 1
        
        -- List each AFKer with enhanced information
        for i, afker in ipairs(afkers) do
            local afkerLine = DetailLines[currentLineIndex] or MakeDetailLine(WINDOW.detailContent, currentLineIndex)
            local playerString = afker.name .. "-" .. afker.realm
            local classInfo = (afker.class and afker.class ~= "Unknown") and (" (" .. afker.class .. " " .. (afker.faction or "") .. ")") or ""
            
            afkerLine:SetText("  " .. playerString .. classInfo .. " (left before match ended)")
            afkerLine:SetTextColor(1, 0.7, 0.7) -- Light red text
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
            -- Export the currently viewed battleground
            ExportBattleground(WINDOW.currentKey)
        else
            -- Show export options menu
            ShowExportMenu()
        end
    end)
    
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
        elseif mouseButton == "RightButton" then
            -- Right click: Quick save (if in BG)
            if insideBG and not matchSaved then
                print("|cff00ffffBGLogger:|r Force saving current battleground...")
                local originalSaved = matchSaved
                matchSaved = false
                
                local timeSinceStart = GetTime() - bgStartTime
                if timeSinceStart < MIN_BG_TIME then
                    bgStartTime = GetTime() - 120
                end
                
                RequestBattlefieldScoreData()
                C_Timer.After(0.5, function()
                    AttemptSaveWithRetry("MINIMAP_FORCE_SAVE")
                end)
            else
                print("|cff00ffffBGLogger:|r Not in battleground or already saved")
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
        GameTooltip:AddLine("Right Click: Force Save (in BG)", 0.7, 0.7, 0.7)
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
-- Slash cmd
---------------------------------------------------------------------
SLASH_BGLOGGER1 = "/bgstats"
SlashCmdList.BGLOGGER = function()
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
        IsMatchStarted = IsMatchStarted
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
            
            -- Don't capture initial list immediately - wait for match to start
            Debug("Waiting for match to start before capturing initial player list")
            
            -- Fallback: Set battleHasBegun flag after reasonable delay if no chat message comes
            C_Timer.After(90, function() -- 1.5 minutes after entering BG
                if insideBG and not playerTracker.battleHasBegun then
                    print("*** FALLBACK: Setting battleHasBegun flag (no start message received) ***")
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
            C_Timer.After(30, CheckMatchStart)
            
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
                print("*** BATTLE HAS BEGUN detected via chat message: " .. message .. " ***")
                Debug("Battle begun flag set to true")
            elseif isPreparationMessage then
                print("*** PREPARATION MESSAGE detected (ignoring): " .. message .. " ***")
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
        print("*** BGLogger: PVP_MATCH_STATE_CHANGED event received ***")
        print("Match state parameter: '" .. tostring(matchState) .. "'")
        print("Inside BG: " .. tostring(insideBG))
        print("Initial list captured: " .. tostring(playerTracker.initialListCaptured))
        
        -- Try to get match state from API if parameter is nil
        local actualMatchState = matchState
        if not actualMatchState and C_PvP and C_PvP.GetActiveMatchState then
            actualMatchState = C_PvP.GetActiveMatchState()
            print("Got match state from API: '" .. tostring(actualMatchState) .. "'")
        end
        
        -- PVP_MATCH_STATE_CHANGED fires for multiple events (enter BG, preparation, match start, etc.)
        -- We need to be VERY selective about when to capture the initial list
        if not playerTracker.initialListCaptured then
            print("*** PVP_MATCH_STATE_CHANGED detected, checking if match has truly started ***")
            
            -- Add a longer delay to ensure we're not in preparation phase
            C_Timer.After(8, function() -- Increased from 3 to 8 seconds
                print("*** PVP_MATCH_STATE_CHANGED timer callback - checking match status ***")
                print("Current insideBG: " .. tostring(insideBG))
                print("Current initialListCaptured: " .. tostring(playerTracker.initialListCaptured))
                
                if insideBG and not playerTracker.initialListCaptured then
                    -- Check API duration first (most reliable)
                    local apiDuration = 0
                    if C_PvP and C_PvP.GetActiveMatchDuration then
                        apiDuration = C_PvP.GetActiveMatchDuration() or 0
                        print("API match duration: " .. apiDuration .. " seconds")
                        
                        -- If API shows duration > 0, battle has definitely begun
                        if apiDuration > 0 then
                            print("*** BATTLE HAS BEGUN detected via API duration: " .. apiDuration .. "s ***")
                            playerTracker.battleHasBegun = true
                            Debug("Battle begun flag set via API detection")
                        end
                    end
                    
                    -- Use conservative match start check
                    local matchHasStarted = IsMatchStarted()
                    print("Conservative match started validation: " .. tostring(matchHasStarted))
                    
                    local numPlayers = GetNumBattlefieldScores()
                    print("Current player count: " .. numPlayers)
                    
                    if matchHasStarted then -- Trust the conservative validation
                        print("*** MATCH CONFIRMED STARTED - Calling CaptureInitialPlayerList ***")
                        Debug("MATCH START CONFIRMED via conservative PVP_MATCH_STATE_CHANGED validation")
                        CaptureInitialPlayerList(false) -- Use validation since we want to be sure
                    else
                        print("*** MATCH NOT YET STARTED - Conservative validation failed ***")
                        print("  - Conservative IsMatchStarted() returned false")
                    end
                else
                    print("*** CONDITIONS NOT MET ***")
                    if not insideBG then
                        print("  - Not in BG anymore")
                    end
                    if playerTracker.initialListCaptured then
                        print("  - Initial list already captured")
                    end
                end
            end)
        else
            print("*** Initial list already captured, ignoring this PVP_MATCH_STATE_CHANGED event ***")
        end
        
        -- Also check for match end states if we have a valid state
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
        -- Reset player tracker on BG exit
        playerTracker.initialPlayerList = {}
        playerTracker.finalPlayerList = {}
        playerTracker.initialListCaptured = false
        playerTracker.battleHasBegun = false
        playerTracker.detectedAFKers = {}
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
print("|cff00ffffBGLogger|r addon loaded. Use |cffffffff/bgstats|r to open the window.")
if DEBUG_MODE then
    print("|cff00ffffBGLogger|r debug mode active. Use |cffffffff/bgdebug|r for debug commands.")
    print("|cff00ffffBGLogger|r tip: Use |cffffffff/bgdebug forcesave|r to manually save current BG data.")
    print("|cff00ffffBGLogger|r tip: Use |cffffffff/bgdebug timing|r to check real-time timing status.")
    print("|cff00ffffBGLogger|r tip: Use |cffffffff/bgdebug bgtype|r to debug BG type detection.")
    print("|cff00ffffBGLogger|r tip: Use |cffffffff/bgdebug tracking|r to debug player participation tracking.")
    print("|cff00ffffBGLogger|r tip: |cffffffffDebugPlayerTracking()|r can also be called directly.")
    print("|cff00ffffBGLogger|r tip: |cffffffffDebugAFKerDetection()|r analyzes AFKer detection in detail.")
    print("|cff00ffffBGLogger|r tip: |cffffffffForceCaptureInitialList()|r manually captures the initial list.")
    print("|cff00ffffBGLogger|r tip: |cffffffffResetPlayerTracking()|r resets all tracking data (debugging).")
    print("|cff00ffffBGLogger|r tip: |cffffffffDebugMatchStart()|r tests match start detection.")
    print("|cff00ffffBGLogger|r tip: |cffffffffDebugScoreboardData()|r shows raw scoreboard data.")
    print("|cff00ffffBGLogger|r tip: |cffffffffDebugCollectScoreData()|r tests final data collection.")
    print("|cff00ffffBGLogger|r tip: |cffffffffCheckTrackingStatus()|r shows current tracking state.")
    print("|cff00ffffBGLogger|r tip: |cffffffffForceCaptureBypassed()|r emergency capture bypassing all checks.")
    print("|cff00ffffBGLogger|r tip: |cffffffffGetParticipationSummary()|r explains the participation system.")
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