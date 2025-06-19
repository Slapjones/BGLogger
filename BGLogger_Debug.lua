---------------------------------------------------------------------
-- BGLogger Debug Module
-- Separate file for all debugging functionality
---------------------------------------------------------------------

local addonName = "BGLogger"
local BGLoggerDebug = {}

-- Reference to main addon globals (set by main addon)
local BGLoggerDB, DEBUG_MODE, WINDOW
local Debug, RefreshWindow, CommitMatch, CollectScoreData
local AttemptSaveWithRetry, TableToJSON, ExportBattleground
local GetBestRealmName, tCount

---------------------------------------------------------------------
-- Debug Hash Functions
---------------------------------------------------------------------

local function DebugHashComponents(key)
    if not BGLoggerDB[key] then
        Debug("No data found for key: " .. tostring(key))
        return
    end
    
    local data = BGLoggerDB[key]
    local metadata = {
        battleground = data.battlegroundName or "Unknown Battleground",
        duration = data.duration or 0,
        winner = data.winner or "",
        type = data.type or "non-rated",
        date = data.dateISO or date("!%Y-%m-%dT%H:%M:%SZ")
    }
    local players = data.stats or {}
    
    Debug("=== Hash Components Debug ===")
    Debug("Battleground: " .. metadata.battleground)
    Debug("Duration: " .. metadata.duration)
    Debug("Winner: " .. metadata.winner)
    Debug("Type: " .. metadata.type)
    Debug("Date: " .. metadata.date)
    Debug("Player count: " .. #players)
    
    -- Show first few players for verification
    for i = 1, math.min(3, #players) do
        local p = players[i]
        Debug("Player " .. i .. ": " .. (p.name or "?") .. "-" .. (p.realm or "?") .. 
              " (" .. (p.damage or 0) .. " dmg, " .. (p.healing or 0) .. " heal)")
    end
    
    if _G.GenerateDataHash then
        local hash, hashMeta = _G.GenerateDataHash(metadata, players)
        Debug("Generated hash: " .. hash)
        Debug("Hash metadata: " .. TableToJSON(hashMeta))
        
        if data.integrity and data.integrity.hash then
            Debug("Stored hash: " .. data.integrity.hash)
            Debug("Hashes match: " .. tostring(hash == data.integrity.hash))
        else
            Debug("No stored hash found")
        end
    else
        Debug("GenerateDataHash function not available")
    end
end

-- Debug function to show hash components
function DebugHashComponents(key)
    if not BGLoggerDB[key] then
        Debug("No data found for key: " .. tostring(key))
        return
    end
    
    local data = BGLoggerDB[key]
    local metadata = ExtractBattlegroundMetadata(data)
    local players = data.stats or {}
    
    Debug("=== Hash Components Debug ===")
    Debug("Battleground: " .. metadata.battleground)
    Debug("Duration: " .. metadata.duration)
    Debug("Winner: " .. metadata.winner)
    Debug("Type: " .. metadata.type)
    Debug("Date: " .. metadata.date)
    Debug("Player count: " .. #players)
    
    -- Show first few players for verification
    for i = 1, math.min(3, #players) do
        local p = players[i]
        Debug("Player " .. i .. ": " .. (p.name or "?") .. "-" .. (p.realm or "?") .. 
              " (" .. (p.damage or 0) .. " dmg, " .. (p.healing or 0) .. " heal)")
    end
    
    local hash, hashMeta = GenerateDataHash(metadata, players)
    Debug("Generated hash: " .. hash)
    Debug("Hash metadata: " .. TableToJSON(hashMeta))
    
    if data.integrity and data.integrity.hash then
        Debug("Stored hash: " .. data.integrity.hash)
        Debug("Hashes match: " .. tostring(hash == data.integrity.hash))
    else
        Debug("No stored hash found")
    end
end

function DebugJSONOutput(key)
    if not BGLoggerDB[key] then
        print("No data found for key: " .. tostring(key))
        return
    end
    
    local data = BGLoggerDB[key]
    local mapName = data.battlegroundName or "Unknown Battleground"
    
    -- Process players exactly like export does
    local exportPlayers = {}
    for _, player in ipairs(data.stats or {}) do
        table.insert(exportPlayers, {
            name = player.name,
            realm = player.realm,
            faction = player.faction or player.side,
            class = player.class,
            spec = player.spec,
            damage = tostring(player.damage or player.dmg or 0),
            healing = tostring(player.healing or player.heal or 0),
            kills = player.kills or player.killingBlows or player.kb or 0,
            deaths = player.deaths or 0,
            honorableKills = player.honorableKills or 0,
            objectives = 0
        })
    end
    
    -- Create export data exactly like export does (without normalization for now)
    local exportData = {
        battleground = mapName,  -- Use raw map name
        date = data.dateISO or date("!%Y-%m-%dT%H:%M:%SZ"),
        type = data.type or "non-rated",
        duration = tostring(data.duration or 0),
        winner = data.winner or "",
        players = exportPlayers,
        integrity = data.integrity
    }
    
    print("=== JSON DEBUG ===")
    print("Export data sample:")
    print("  battleground: '" .. exportData.battleground .. "' (type: " .. type(exportData.battleground) .. ")")
    print("  duration: '" .. exportData.duration .. "' (type: " .. type(exportData.duration) .. ")")
    print("  winner: '" .. exportData.winner .. "' (type: " .. type(exportData.winner) .. ")")
    
    if #exportPlayers > 0 then
        local p1 = exportPlayers[1]
        print("  player1.damage: '" .. p1.damage .. "' (type: " .. type(p1.damage) .. ")")
        print("  player1.healing: '" .. p1.healing .. "' (type: " .. type(p1.healing) .. ")")
        print("  player1.kills: " .. p1.kills .. " (type: " .. type(p1.kills) .. ")")
    end
    
    -- Generate JSON and check for issues
    local success, jsonString = pcall(TableToJSON, exportData)
    
    if success then
        print("JSON generation: SUCCESS")
        print("JSON length: " .. #jsonString)
        
        -- Show a small sample of the JSON around the first player's damage
        local damagePattern = '"damage":%s*"?([%d%.%-e+]*)"?'
        local firstDamage = jsonString:match(damagePattern)
        if firstDamage then
            print("First damage in JSON: '" .. firstDamage .. "'")
        end
        
        local healingPattern = '"healing":%s*"?([%d%.%-e+]*)"?'
        local firstHealing = jsonString:match(healingPattern)
        if firstHealing then
            print("First healing in JSON: '" .. firstHealing .. "'")
        end
        
        -- Check if integrity hash is included
        if jsonString:find('"integrity"') then
            print("Integrity hash included in JSON: YES")
        else
            print("Integrity hash included in JSON: NO - THIS IS THE PROBLEM!")
        end
        
    else
        print("JSON generation: FAILED - " .. tostring(jsonString))
    end
end

---------------------------------------------------------------------
-- Debug Command Handlers
---------------------------------------------------------------------

local function HandleDebugCommand(msg)
    local cmd, param = msg:match("^(%S*)%s*(.-)$")
    
    if cmd == "on" then
        _G.DEBUG_MODE = true
        print("BGLogger debug mode enabled")
        
    elseif cmd == "off" then
        _G.DEBUG_MODE = false
        print("BGLogger debug mode disabled")
        
    elseif cmd == "status" then
        print("BGLogger inside BG: " .. tostring(_G.insideBG))
        print("BGLogger match saved: " .. tostring(_G.matchSaved))
        print("BGLogger DB entries: " .. tCount(BGLoggerDB))
        print("BGLogger time in BG: " .. (_G.insideBG and math.floor(GetTime() - _G.bgStartTime) or 0) .. " seconds")
        
    elseif cmd == "dump" then
        print("BGLogger database dump:")
        local count = 0
        for k, v in pairs(BGLoggerDB) do
            if type(v) == "table" and v.mapID then
                count = count + 1
                print(count .. ". Entry: " .. k)
                print("  Map ID: " .. tostring(v.mapID))
                print("  Ended: " .. tostring(v.ended))
                print("  Players: " .. (v.stats and #v.stats or 0))
                print("  Has integrity: " .. tostring(v.integrity ~= nil))
                
                if v.stats and #v.stats > 0 then
                    local p = v.stats[1]
                    print("  Sample player: " .. (p.name or "unknown"))
                    print("    Damage: " .. (p.damage or p.dmg or 0))
                    print("    Healing: " .. (p.healing or p.heal or 0))
                    print("    Kills: " .. (p.kills or p.kb or 0))
                    print("    Deaths: " .. (p.deaths or 0))
                end
            else
                print("Non-BG entry: " .. k .. " (type: " .. type(v) .. ")")
            end
        end
        print("Total battleground entries: " .. count)
        
    elseif cmd == "repair" then
        print("Attempting to repair BGLogger database...")
        local fixed = 0
        for k, v in pairs(BGLoggerDB) do
            if v.stats then
                for i, player in ipairs(v.stats) do
                    if (player.dmg == 0 or player.dmg == nil) and player.damage then
                        player.dmg = player.damage
                        fixed = fixed + 1
                    end
                    if (player.heal == 0 or player.heal == nil) and player.healing then
                        player.heal = player.healing
                        fixed = fixed + 1
                    end
                    if (player.kb == 0 or player.kb == nil) and player.killingBlows then
                        player.kb = player.killingBlows
                        fixed = fixed + 1
                    end
                end
            end
        end
        print("BGLogger repair complete. Fixed " .. fixed .. " fields.")
        if WINDOW and WINDOW:IsShown() then
            RefreshWindow()
        end
        
    elseif cmd == "clearall" then
        print("Clearing all BGLogger data...")
        wipe(BGLoggerDB)
        print("BGLogger data cleared.")
        if WINDOW and WINDOW:IsShown() then
            RefreshWindow()
        end
        
    elseif cmd == "refresh" then
        if WINDOW and WINDOW:IsShown() then
            RefreshWindow()
            print("BGLogger window refreshed")
        else
            print("BGLogger window not open")
        end
        
    elseif cmd == "testbg" then
        local bgType = param or "wsg" -- Default to Warsong Gulch
        BGLoggerDebug.CreateTestBattleground(bgType)
        
    elseif cmd == "forcesave" then
        print("Forcing save of current battleground data...")
        if _G.insideBG then
            local timeSinceStart = GetTime() - _G.bgStartTime
            print("Time in BG: " .. timeSinceStart .. " seconds")
            print("Current matchSaved status: " .. tostring(_G.matchSaved))
            
            local originalSaved = _G.matchSaved
            _G.matchSaved = false
            
            if timeSinceStart < _G.MIN_BG_TIME then
                _G.bgStartTime = GetTime() - 120
                print("Faking longer BG time for testing")
            end
            
            RequestBattlefieldScoreData()
            C_Timer.After(0.5, function()
                AttemptSaveWithRetry("MANUAL_FORCE_SAVE_OVERRIDE")
            end)
        else
            print("Not in a battleground - can't force save")
        end
        
    elseif cmd == "testhash" then
        print("Testing hash generation with simple data...")
        local testMetadata = {
            battleground = "Warsong Gulch",
            duration = 180,
            winner = "Alliance",
            type = "non-rated",
            date = "2025-05-27T15:30:00Z"
        }
        
        local testPlayers = {
            {name="Alice", realm="Stormrage", faction="Alliance", class="Mage", spec="Fire", 
             damage=100000, healing=5000, kills=10, deaths=2, honorableKills=15},
            {name="Bob", realm="Area-52", faction="Horde", class="Warrior", spec="Arms", 
             damage=80000, healing=0, kills=8, deaths=3, honorableKills=12}
        }
        
        if _G.GenerateDataHash then
            local hash, metadata = _G.GenerateDataHash(testMetadata, testPlayers)
            print("Test hash: " .. hash)
            print("Metadata: " .. TableToJSON(metadata))
            
            local hash2 = _G.GenerateDataHash(testMetadata, testPlayers)
            print("Hash consistency: " .. (hash == hash2 and "PASS" or "FAIL"))
        else
            print("GenerateDataHash function not available")
        end
        
    elseif cmd == "checkhash" then
        local key = param
        if not key or key == "" then
            print("Usage: /bgdebug checkhash <battleground_key>")
            print("Use /bgdebug dump to see available keys")
            return
        end
        
        if not BGLoggerDB[key] then
            print("No data found for key: " .. key)
            return
        end
        
        local data = BGLoggerDB[key]
        if data.integrity and data.integrity.hash then
            print("Hash found for " .. key .. ": " .. data.integrity.hash)
            print("Generated at: " .. tostring(data.integrity.generatedAt))
            print("Version: " .. tostring(data.integrity.version))
        else
            print("No hash found for " .. key)
            print("This battleground was saved before hash implementation")
        end
        
    elseif cmd == "hashcomponents" then
        local key = param
        if key and key ~= "" then
            DebugHashComponents(key)
        else
            print("Usage: /bgdebug hashcomponents <battleground_key>")
            print("Available keys:")
            local count = 0
            for k, v in pairs(BGLoggerDB) do
                if type(v) == "table" and v.mapID then
                    count = count + 1
                    local mapInfo = C_Map.GetMapInfo(v.mapID or 0)
                    local mapName = (mapInfo and mapInfo.name) or "Unknown"
                    print("  " .. k .. " - " .. mapName)
                    if count >= 5 then
                        print("  ... (use /bgdebug dump for full list)")
                        break
                    end
                end
            end
        end
    elseif cmd == "debughash" then
    local key = param
    if not key or key == "" then
        print("Usage: /bgdebug debughash <battleground_key>")
        return
    end
    DebugExportVsHash(key)    
    elseif cmd == "debugjson" then
    local key = param
    if not key or key == "" then
        print("Usage: /bgdebug debugjson <battleground_key>")
        return
    end
    DebugJSONOutput(key)
    elseif cmd == "hashstring" then
    local key = param
    if not key or key == "" then
        print("Usage: /bgdebug hashstring <battleground_key>")
        return
    end
    
    if not BGLoggerDB[key] then
        print("No data found for key: " .. key)
        return
    end
    
    local data = BGLoggerDB[key]
    local metadata = {
        battleground = data.battlegroundName or "Unknown Battleground",
        duration = data.duration or 0,
        winner = data.winner or ""
    }
    
    -- Use the EXACT same normalization function as GenerateDataHash
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
    
    -- Recreate the exact hash string using the SAME logic as GenerateDataHash
    local parts = {}
    
    -- Add battleground info (normalize battleground name)
    table.insert(parts, normalizeString(metadata.battleground or ""))
    table.insert(parts, tostring(metadata.duration or 0))
    table.insert(parts, normalizeString(metadata.winner or ""))
    
    -- Sort players by name for consistency
    local sortedPlayers = {}
    for _, player in ipairs(data.stats or {}) do
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
    
    local hashString = table.concat(parts, "||")
    print("=== FULL HASH STRING (WITH NORMALIZATION) ===")
    print("Length: " .. #hashString)
    
    -- Output in 200-character chunks to avoid chat line limits
    local pos = 1
    local chunkNum = 1
    while pos <= #hashString do
        local chunk = hashString:sub(pos, pos + 199)
        print("Chunk " .. chunkNum .. ": " .. chunk)
        pos = pos + 200
        chunkNum = chunkNum + 1
    end
    print("=== END HASH STRING ===")
    elseif cmd == "hashparts" then
    local key = param
    if not key or key == "" then
        print("Usage: /bgdebug hashparts <battleground_key>")
        return
    end
    
    if not BGLoggerDB[key] then
        print("No data found for key: " .. key)
        return
    end
    
    local data = BGLoggerDB[key]
    local metadata = {
        battleground = data.battlegroundName or "Unknown Battleground",
        duration = data.duration or 0,
        winner = data.winner or ""
    }
    
    print("=== BATTLEGROUND METADATA ===")
    print("Battleground: '" .. metadata.battleground .. "' (length: " .. #metadata.battleground .. ")")
    print("Duration: '" .. tostring(metadata.duration) .. "' (length: " .. #tostring(metadata.duration) .. ")")
    print("Winner: '" .. metadata.winner .. "' (length: " .. #metadata.winner .. ")")
    
    local sortedPlayers = {}
    for _, player in ipairs(data.stats or {}) do
        table.insert(sortedPlayers, player)
    end
    
    table.sort(sortedPlayers, function(a, b)
        return (a.name or "") < (b.name or "")
    end)
    
    print("=== PLAYER COUNT ===")
    print("Total players: " .. #sortedPlayers)
    
    print("=== FIRST 3 PLAYERS ===")
    for i = 1, math.min(3, #sortedPlayers) do
        local player = sortedPlayers[i]
        local playerStr = (player.name or "") .. "|" .. 
                         (player.realm or "") .. "|" .. 
                         tostring(player.damage or 0) .. "|" .. 
                         tostring(player.healing or 0)
        print("Player " .. i .. ": '" .. playerStr .. "' (length: " .. #playerStr .. ")")
    end
    elseif cmd == "findchars" then
    local key = param
    if not key or key == "" then
        print("Usage: /bgdebug findchars <battleground_key>")
        return
    end
    
    if not BGLoggerDB[key] then
        print("No data found for key: " .. key)
        return
    end
    
    local data = BGLoggerDB[key]
    
    -- Function to show problematic characters
    local function analyzeString(str, label)
        if not str then return end
        str = tostring(str)
        
        local hasSpecial = false
        for i = 1, #str do
            local byte = string.byte(str, i)
            if byte > 127 then -- Non-ASCII character
                if not hasSpecial then
                    print("Special chars in " .. label .. ":")
                    hasSpecial = true
                end
                local char = string.sub(str, i, i)
                print("  Position " .. i .. ": '" .. char .. "' (byte: " .. byte .. ")")
            end
        end
        
        if hasSpecial then
            print("  Full string: '" .. str .. "' (length: " .. #str .. ")")
        end
    end
    
    -- Check battleground metadata
    analyzeString(data.battlegroundName, "battleground name")
    analyzeString(data.winner, "winner")
    
    -- Check first 10 players for special characters
    print("=== CHECKING PLAYER NAMES/REALMS ===")
    local count = 0
    for _, player in ipairs(data.stats or {}) do
        analyzeString(player.name, "player name")
        analyzeString(player.realm, "realm")
        count = count + 1
        if count >= 10 then break end
    end
    elseif cmd == "checkpipes" then
    local key = param
    if not key or key == "" then
        print("Usage: /bgdebug checkpipes <battleground_key>")
        return
    end
    
    if not BGLoggerDB[key] then
        print("No data found for key: " .. key)
        return
    end
    
    local data = BGLoggerDB[key]
    local metadata = {
        battleground = data.battlegroundName or "Unknown Battleground",
        duration = data.duration or 0,
        winner = data.winner or ""
    }
    
    -- Create parts exactly like hash generation
    local parts = {}
    table.insert(parts, metadata.battleground)
    table.insert(parts, tostring(metadata.duration))
    table.insert(parts, metadata.winner)
    
    -- Add just first player for testing
    if data.stats and #data.stats > 0 then
        local player = data.stats[1]
        local playerStr = (player.name or "") .. "|" .. 
                         (player.realm or "") .. "|" .. 
                         tostring(player.damage or 0) .. "|" .. 
                         tostring(player.healing or 0)
        table.insert(parts, playerStr)
    end
    
    print("=== PIPE SEPARATOR TEST ===")
    print("Parts count: " .. #parts)
    for i, part in ipairs(parts) do
        print("Part " .. i .. ": '" .. part .. "'")
    end
    
    local dataString = table.concat(parts, "||")
    print("Joined string length: " .. #dataString)
    print("Full string: '" .. dataString .. "'")
    
    -- Check for double pipes specifically
    local doublePipeCount = 0
    local singlePipeCount = 0
    local pos = 1
    while pos <= #dataString do
        if pos < #dataString and dataString:sub(pos, pos+1) == "||" then
            doublePipeCount = doublePipeCount + 1
            pos = pos + 2
        elseif dataString:sub(pos, pos) == "|" then
            singlePipeCount = singlePipeCount + 1
            pos = pos + 1
        else
            pos = pos + 1
        end
    end
    
    print("Double pipes (||): " .. doublePipeCount)
    print("Single pipes (|): " .. singlePipeCount)
    elseif cmd == "testnorm" then
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
    
    local testName = "Kìllah"
    local normalized = normalizeString(testName)
    print("Original: '" .. testName .. "' (length: " .. #testName .. ")")
    print("Normalized: '" .. normalized .. "' (length: " .. #normalized .. ")")
    elseif cmd == "realhash" then
    local key = param
    if not key or key == "" then
        print("Usage: /bgdebug realhash <battleground_key>")
        return
    end
    
    if not BGLoggerDB[key] then
        print("No data found for key: " .. key)
        return
    end
    
    local data = BGLoggerDB[key]
    local metadata = {
        battleground = data.battlegroundName or "Unknown Battleground",
        duration = data.duration or 0,
        winner = data.winner or "",
        type = data.type or "non-rated",
        date = data.dateISO or date("!%Y-%m-%dT%H:%M:%SZ")
    }
    
    print("=== REAL HASH GENERATION TEST ===")
    
    -- Call your actual GenerateDataHash function
    local hash, hashMeta = GenerateDataHash(metadata, data.stats or {})
    
    print("Generated hash: " .. hash)
    print("Stored hash: " .. (data.integrity and data.integrity.hash or "none"))
    print("Match: " .. tostring(hash == (data.integrity and data.integrity.hash or "")))
    
    -- Also test with just first player to see normalized output
    if data.stats and #data.stats > 0 then
        local testPlayer = data.stats[1]
        print("First player raw: " .. (testPlayer.name or ""))
        -- Show what normalization produces
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
        print("First player normalized: " .. normalizeString(testPlayer.name or ""))
    end
    elseif cmd == "timing" then
        if _G.DebugTimingStatus then
            _G.DebugTimingStatus()
        else
            print("DebugTimingStatus function not available")
        end
        
    elseif cmd == "bgtype" then
        if _G.DebugBGTypeDetection then
            _G.DebugBGTypeDetection()
        else
            print("DebugBGTypeDetection function not available")
        end
        
    elseif cmd == "tracking" then
        if _G.DebugPlayerTracking then
            _G.DebugPlayerTracking()
        else
            print("DebugPlayerTracking function not available")
        end
        
    elseif cmd == "afktest" then
        if _G.DebugAFKerDetection then
            _G.DebugAFKerDetection()
        else
            print("DebugAFKerDetection function not available")
        end
        
    elseif cmd == "resettracking" then
        if _G.ResetPlayerTracking then
            _G.ResetPlayerTracking()
        else
            print("ResetPlayerTracking function not available")
        end
        
    elseif cmd == "matchstart" then
        if _G.DebugMatchStart then
            _G.DebugMatchStart()
        else
            print("DebugMatchStart function not available")
        end
        
    elseif cmd == "scoredata" then
        if _G.DebugScoreboardData then
            _G.DebugScoreboardData()
        else
            print("DebugScoreboardData function not available")
        end
        
    elseif cmd == "collectdata" then
        if _G.DebugCollectScoreData then
            _G.DebugCollectScoreData()
        else
            print("DebugCollectScoreData function not available")
        end
        
    elseif cmd == "trackstatus" then
        if _G.CheckTrackingStatus then
            _G.CheckTrackingStatus()
        else
            print("CheckTrackingStatus function not available")
        end
        
    else
        print("BGLogger debug commands:")
        print("  on, off - toggle debug mode")
        print("  status - show current BG status") 
        print("  dump - show database contents")
        print("  testbg [type] - create test battleground (wsg, ab, av, eots, tp, bg, brawl)")
        print("  forcesave - force save current BG")
        print("  timing - show real-time timing status")
        print("  bgtype - debug BG type detection")
        print("  tracking - debug player participation tracking")
        print("  afktest - comprehensive AFKer detection test")
        print("  resettracking - reset all player tracking data")
        print("  matchstart - debug match start detection")
        print("  scoredata - show raw scoreboard data fields")
        print("  collectdata - test CollectScoreData function")
        print("  trackstatus - show current tracking state")
        print("  testhash - test hash generation")
        print("  checkhash [key] - check hash for entry")
        print("  hashcomponents [key] - debug hash components")
        print("  repair - fix database issues")
        print("  clearall - clear all data")
        print("  refresh - refresh window")
    end
end

---------------------------------------------------------------------
-- Debug Test Functions
---------------------------------------------------------------------

function BGLoggerDebug.CreateTestBattleground(bgType)
    bgType = bgType or "wsg" -- Default to Warsong Gulch
    
    print("Simulating battleground: " .. bgType)
    _G.insideBG = true
    _G.matchSaved = false
    _G.bgStartTime = GetTime() - 120
    
    local playerRealm = GetBestRealmName()
    
    -- Enhanced test player data with more variety
    local testPlayers = {
        {
            name="Shadowstep", realm=playerRealm, faction="Alliance", class="Rogue", spec="Assassination", 
            damage=1250000, healing=48000, kills=12, deaths=3, honorableKills=25,
            dmg=1250000, heal=48000, kb=12, side="Alliance"
        },
        {
            name="Holylight", realm="Stormrage", faction="Alliance", class="Priest", spec="Holy",
            damage=120000, healing=2800000, kills=1, deaths=4, honorableKills=15,
            dmg=120000, heal=2800000, kb=1, side="Alliance"
        },
        {
            name="Tankalot", realm="Area-52", faction="Alliance", class="Warrior", spec="Protection",
            damage=680000, healing=150000, kills=4, deaths=7, honorableKills=18,
            dmg=680000, heal=150000, kb=4, side="Alliance"
        },
        {
            name="Fireball", realm="Tichondrius", faction="Alliance", class="Mage", spec="Fire",
            damage=1800000, healing=85000, kills=15, deaths=6, honorableKills=28,
            dmg=1800000, heal=85000, kb=15, side="Alliance"
        },
        {
            name="Smasher", realm="Mal'Ganis", faction="Horde", class="Warrior", spec="Arms",
            damage=1400000, healing=60000, kills=14, deaths=5, honorableKills=32,
            dmg=1400000, heal=60000, kb=14, side="Horde"
        },
        {
            name="Bubbles", realm="Area-52", faction="Horde", class="Priest", spec="Discipline",
            damage=180000, healing=2500000, kills=2, deaths=2, honorableKills=12,
            dmg=180000, heal=2500000, kb=2, side="Horde"
        },
        {
            name="Bearform", realm=playerRealm, faction="Horde", class="Druid", spec="Guardian",
            damage=750000, healing=200000, kills=6, deaths=8, honorableKills=20,
            dmg=750000, heal=200000, kb=6, side="Horde"
        },
        {
            name="Arcaneshot", realm="Tichondrius", faction="Horde", class="Hunter", spec="Marksmanship",
            damage=1650000, healing=0, kills=18, deaths=4, honorableKills=35,
            dmg=1650000, heal=0, kb=18, side="Horde"
        }
    }
    
    -- Predefined battleground options with reliable data
    local battlegrounds = {
        wsg = { mapID = 1339, name = "Warsong Gulch" },
        ab = { mapID = 529, name = "Arathi Basin" },
        av = { mapID = 30, name = "Alterac Valley" },
        eots = { mapID = 566, name = "Eye of the Storm" },
        tp = { mapID = 726, name = "Twin Peaks" },
        bg = { mapID = 761, name = "Battle for Gilneas" },
        brawl = { mapID = 1339, name = "Warsong Gulch" } -- Brawl using WSG map
    }
    
    local selectedBG = battlegrounds[bgType] or battlegrounds.wsg
    local mapID = selectedBG.mapID
    local mapName = selectedBG.name
    local duration = math.floor(GetTime() - _G.bgStartTime)
    
    local key = mapID.."_"..date("!%Y%m%d_%H%M%S")
    
    -- Determine the BG type based on test type
    local testBGType = "non-rated"
    if bgType == "brawl" then
        testBGType = "brawl"
        mapName = mapName .. " Brawl" -- Add brawl suffix to make it clear
    end
    
    -- Create enhanced battleground data
    BGLoggerDB[key] = {
        mapID = mapID,
        ended = date("%c"),
        stats = testPlayers,
        battlegroundName = mapName,
        duration = duration,
        winner = "Alliance", -- Fixed winner for consistent testing
        type = testBGType,
        startTime = _G.bgStartTime,
        endTime = GetTime(),
        dateISO = date("!%Y-%m-%dT%H:%M:%SZ")
    }
    
    -- Generate hash if function is available
    if _G.GenerateDataHash then
        local battlegroundMetadata = {
            battleground = mapName,
            duration = duration,
            winner = "Alliance",
            type = testBGType,
            date = BGLoggerDB[key].dateISO
        }
        
        local dataHash, hashMetadata = _G.GenerateDataHash(battlegroundMetadata, testPlayers)
        BGLoggerDB[key].integrity = {
            hash = dataHash,
            metadata = hashMetadata,
            generatedAt = GetServerTime(),
            serverTime = GetServerTime(),
            version = "BGLogger_v1.0",
            realm = GetRealmName() or "Test-Realm"
        }
        print("Test battleground created: " .. mapName .. " with hash: " .. dataHash)
    else
        print("Test battleground created: " .. mapName .. " (no hash - function not available)")
    end
    
    print("Key: " .. key)
    print("Players: " .. #testPlayers)
    print("Duration: " .. duration .. " seconds")
    print("Winner: Alliance")
    
    _G.matchSaved = true
    
    if WINDOW and WINDOW:IsShown() then
        C_Timer.After(0.1, RefreshWindow)
    end
end

---------------------------------------------------------------------
-- Initialize Debug Module
---------------------------------------------------------------------

function BGLoggerDebug.Initialize(mainAddonGlobals)
    -- Store references to main addon functions and variables
    BGLoggerDB = mainAddonGlobals.BGLoggerDB
    DEBUG_MODE = mainAddonGlobals.DEBUG_MODE
    WINDOW = mainAddonGlobals.WINDOW
    Debug = mainAddonGlobals.Debug
    RefreshWindow = mainAddonGlobals.RefreshWindow
    CommitMatch = mainAddonGlobals.CommitMatch
    CollectScoreData = mainAddonGlobals.CollectScoreData
    AttemptSaveWithRetry = mainAddonGlobals.AttemptSaveWithRetry
    TableToJSON = mainAddonGlobals.TableToJSON
    ExportBattleground = mainAddonGlobals.ExportBattleground
    GetBestRealmName = mainAddonGlobals.GetBestRealmName
    tCount = mainAddonGlobals.tCount
    
    -- Register debug slash command
    SLASH_BGLOGGERDEBUG1 = "/bgdebug"
    SlashCmdList.BGLOGGERDEBUG = HandleDebugCommand
    
    print("|cff00ffffBGLogger Debug|r module loaded. Use |cffffffff/bgdebug|r for debug commands.")
end

-- Export the module
_G.BGLoggerDebug = BGLoggerDebug