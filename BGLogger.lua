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

---------------------------------------------------------------------
-- Debug Functions
---------------------------------------------------------------------
local function Debug(msg)
    if DEBUG_MODE then
        print("|cff00ffffBGLogger:|r " .. tostring(msg))
    end
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
    
    -- Create simple string from key data
    local parts = {}
    
    -- Add battleground info
    table.insert(parts, battlegroundMetadata.battleground or "")
    table.insert(parts, tostring(battlegroundMetadata.duration or 0))
    table.insert(parts, battlegroundMetadata.winner or "")
    
    -- Sort players by name for consistency
    local sortedPlayers = {}
    for _, player in ipairs(playerList) do
        table.insert(sortedPlayers, player)
    end
    
    table.sort(sortedPlayers, function(a, b)
        return (a.name or "") < (b.name or "")
    end)
    
    -- Add player data
    for _, player in ipairs(sortedPlayers) do
        local playerStr = (player.name or "") .. "|" .. 
                         (player.realm or "") .. "|" .. 
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
            
            -- SIMPLIFIED: Create player data without objectives
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
    return t
end

local function DetectAvailableAPIs()
    local apis = {
        GetWinner = _G.GetBattlefieldWinner,
        IsRatedBattleground = _G.IsRatedBattleground,
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
        
        -- Get battleground duration
        local duration = math.floor(GetTime() - bgStartTime)
        
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
        
        -- Try to determine battleground type
        local bgType = "non-rated"
        if IsRatedBattleground and IsRatedBattleground() then
            bgType = "rated"
        end
        
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
            duration = duration,
            winner = winner,
            type = bgType,
            startTime = bgStartTime,
            endTime = GetTime(),
            dateISO = date("!%Y-%m-%dT%H:%M:%SZ"),
            
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
        Debug("Duration: " .. duration .. " seconds")
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
    
    local mapName = data.battlegroundName or "Unknown Battleground"
    local normalizedMapName = NormalizeBattlegroundName(mapName)
    
    -- Process players (same as before)
    local exportPlayers = {}
    for _, player in ipairs(data.stats or {}) do
        table.insert(exportPlayers, {
            name = player.name,
            realm = player.realm,
            faction = player.faction or player.side,
            class = player.class,
            spec = player.spec,
            damage = player.damage or player.dmg or 0,
            healing = player.healing or player.heal or 0,
            kills = player.kills or player.killingBlows or player.kb or 0,
            deaths = player.deaths or 0,
            honorableKills = player.honorableKills or 0,
            objectives = 0
        })
    end
    
    -- Convert to website-compatible JSON format
    local exportData = {
        battleground = normalizedMapName,
        date = data.dateISO or date("!%Y-%m-%dT%H:%M:%SZ"),
        type = data.type or "non-rated",
        duration = data.duration or 0,
        winner = data.winner or "",
        players = exportPlayers,
        
        -- USE PRE-GENERATED INTEGRITY DATA
        integrity = data.integrity
    }
    
    Debug("Export using pre-generated hash: " .. (data.integrity.hash or "missing"))
    
    -- Generate JSON string
    local success, jsonString = pcall(TableToJSON, exportData)
    
    if not success then
        print("|cff00ffffBGLogger:|r Error generating JSON: " .. tostring(jsonString))
        return
    end
    
    Debug("JSON generated successfully with pre-generated integrity hash, length: " .. #jsonString)
    
    -- Create filename
    local filename = string.format("BGLogger_%s_%s.json", 
        normalizedMapName:gsub("%s+", "_"):gsub("[^%w_]", ""),
        date("!%Y%m%d_%H%M%S")
    )
    
    SaveJSONToFile(jsonString, filename)
    
    print("|cff00ffffBGLogger:|r Exported " .. normalizedMapName .. " with verified integrity hash")
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

-- Save JSON to file
function SaveJSONToFile(jsonString, filename)
    -- WoW doesn't allow direct file writing, so we'll display it for copy/paste
    ShowJSONExportFrame(jsonString, filename)
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
    
    -- Clear existing detail lines
    for _, line in ipairs(DetailLines) do
        line:SetText("")
        line:Hide()
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
    
    -- UPDATED: Column headers without objectives, separate K and D
    local header = DetailLines[3] or MakeDetailLine(WINDOW.detailContent, 3)
    header:SetText("Player Name            Realm          Class       Spec         Faction   Damage    Healing   Kills Deaths HK")
    header:Show()
    
    -- Add separator line
    local separator2 = DetailLines[4] or MakeDetailLine(WINDOW.detailContent, 4)
    separator2:SetText(string.rep("-", 105))
    separator2:Show()
    
    -- Build detail lines
    local rows = data.stats or {}
    for i, row in ipairs(rows) do
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
        
        -- Truncate long names/realms to fit
        local displayName = string.sub(row.name or "Unknown", 1, 18)
        local displayRealm = string.sub(realm, 1, 12)
        local displayClass = string.sub(class, 1, 9)
        local displaySpec = string.sub(spec, 1, 10)
        local displayFaction = string.sub(faction, 1, 8)
        
        -- UPDATED: Show kills and deaths separately
        fs:SetFormattedText("%-18s %-12s %-9s %-10s %-8s %8s %8s %5d %6d %3d",
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
            honorableKills)
        fs:Show()
    end
    
    -- Add summary footer
    local summaryLine = DetailLines[#rows+6] or MakeDetailLine(WINDOW.detailContent, #rows+6)
    summaryLine:SetText(string.rep("-", 105))
    summaryLine:Show()
    
    local totalLine = DetailLines[#rows+7] or MakeDetailLine(WINDOW.detailContent, #rows+7)
    local totalDamage, totalHealing, totalKills, totalDeaths = 0, 0, 0, 0
    for _, row in ipairs(rows) do
        totalDamage = totalDamage + (row.damage or row.dmg or 0)
        totalHealing = totalHealing + (row.healing or row.heal or 0)
        totalKills = totalKills + (row.kills or row.killingBlows or row.kb or 0)
        totalDeaths = totalDeaths + (row.deaths or 0)
    end
    
    -- UPDATED: Show separate totals for kills and deaths
    totalLine:SetFormattedText("TOTALS (%d players)%46s %8s %8s %5d %6d",
        #rows,
        "",
        totalDamage >= 1000000 and string.format("%.1fM", totalDamage/1000000) or 
        totalDamage >= 1000 and string.format("%.0fK", totalDamage/1000) or tostring(totalDamage),
        totalHealing >= 1000000 and string.format("%.1fM", totalHealing/1000000) or 
        totalHealing >= 1000 and string.format("%.0fK", totalHealing/1000) or tostring(totalHealing),
        totalKills,
        totalDeaths)
    totalLine:Show()
    
    -- Update content height
    WINDOW.detailContent:SetHeight(math.max((#rows+7)*LINE_HEIGHT, 10))
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
            MIN_BG_TIME = MIN_BG_TIME
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

-- Try to register additional events that might exist
local additionalEvents = {
    "PVP_MATCH_COMPLETE",
    "BATTLEGROUND_POINTS_UPDATE",
    "BATTLEFIELDS_CLOSED"
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
            bgStartTime = GetTime()
            matchSaved = false
            saveInProgress = false -- Also reset save lock
            Debug("BG start time set to " .. bgStartTime .. ", flags reset")
        elseif not insideBG and wasInBG then
            -- Just left a BG
            Debug("Left battleground, resetting timer and flags")
            bgStartTime = 0
            matchSaved = false
            saveInProgress = false
        elseif not insideBG then
            -- ADDED: Reset timer on login if not in BG
            Debug("Player entering world outside BG, resetting timer")
            bgStartTime = 0
            matchSaved = false
            saveInProgress = false
        end
    
    elseif e == "UPDATE_BATTLEFIELD_SCORE" then
        -- Update BG status each time
        insideBG = newBGStatus
        
        if insideBG and not matchSaved then
            local timeSinceStart = GetTime() - bgStartTime
            
            -- ADDED: Safety check for invalid start time
            if bgStartTime == 0 or timeSinceStart < 0 or timeSinceStart > 7200 then -- More than 2 hours is invalid
                Debug("Invalid BG start time detected, resetting to now")
                bgStartTime = GetTime()
                timeSinceStart = 0
            end
            
            if timeSinceStart > MIN_BG_TIME then
                local winner = GetWinner and GetWinner() or nil
                Debug("UPDATE_BATTLEFIELD_SCORE: Time=" .. timeSinceStart .. "s, Winner=" .. tostring(winner))
                
                if winner and winner ~= 0 and timeSinceStart > 120 then
                    Debug("Winner confirmed (" .. winner .. ") after " .. timeSinceStart .. " seconds - attempting save")
                    RequestBattlefieldScoreData()
                    C_Timer.After(1, function()
                        AttemptSaveWithRetry("UPDATE_BATTLEFIELD_SCORE")
                    end)
                elseif winner then
                    Debug("Winner detected but ignoring - only " .. timeSinceStart .. " seconds elapsed")
                end
            end
        elseif matchSaved then
            Debug("UPDATE_BATTLEFIELD_SCORE: Match already saved, ignoring")
        end
        
    elseif e == "PVP_MATCH_COMPLETE" and insideBG and not matchSaved then
        Debug("PVP_MATCH_COMPLETE event detected!")
        local timeSinceStart = GetTime() - bgStartTime
        
        -- ADDED: Safety check here too
        if bgStartTime == 0 or timeSinceStart < 0 or timeSinceStart > 7200 then
            Debug("Invalid BG start time on match complete, using minimum duration")
            bgStartTime = GetTime() - 300 -- Assume 5 minute minimum
            timeSinceStart = 300
        end
        
        if timeSinceStart > MIN_BG_TIME then
            Debug("PVP_MATCH_COMPLETE: Attempting save after " .. timeSinceStart .. " seconds")
            RequestBattlefieldScoreData()
            C_Timer.After(1.5, function()
                AttemptSaveWithRetry("PVP_MATCH_COMPLETE")
            end)
        else
            Debug("PVP_MATCH_COMPLETE: Ignoring - only been in BG for " .. timeSinceStart .. " seconds")
        end
        
    elseif e == "CHAT_MSG_BG_SYSTEM_NEUTRAL" and insideBG and not matchSaved then
        local message = ...
        local timeSinceStart = GetTime() - bgStartTime
        
        -- ADDED: Safety check here too
        if bgStartTime == 0 or timeSinceStart < 0 or timeSinceStart > 7200 then
            Debug("Invalid BG start time on system message, using minimum duration")
            bgStartTime = GetTime() - 300
            timeSinceStart = 300
        end
        
        Debug("BG System message after " .. timeSinceStart .. "s: " .. tostring(message))
        
        local isEndMessage = false
        if message and timeSinceStart > 60 then
            local lowerMsg = message:lower()
            if lowerMsg:find("wins!") or 
               lowerMsg:find("claimed victory") or
               lowerMsg:find("won the battle") or
               lowerMsg:find("has won") or
               lowerMsg:find("alliance wins") or
               lowerMsg:find("horde wins") then
                isEndMessage = true
            end
        end
        
        if isEndMessage and timeSinceStart > MIN_BG_TIME then
            Debug("End of BG confirmed through specific message after " .. timeSinceStart .. " seconds: " .. message)
            RequestBattlefieldScoreData()
            C_Timer.After(2, function()
                AttemptSaveWithRetry("CHAT_MSG_BG_SYSTEM_NEUTRAL")
            end)
        elseif isEndMessage then
            Debug("End message detected but ignoring - only been in BG for " .. timeSinceStart .. " seconds")
        end
    
    elseif (e == "PLAYER_LEAVING_WORLD" or e == "ZONE_CHANGED_NEW_AREA") and insideBG then
        Debug("Leaving battleground event: " .. e)
        -- UPDATED: Always reset timer when leaving BG
        insideBG = false
        bgStartTime = 0
        matchSaved = false
        saveInProgress = false
        Debug("BG exit: All flags and timer reset")
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

-- Enhanced polling function
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
            Debug("Max poll attempts reached, saving final data")
            SaveExitingBattleground()
        end
    end)
end

-- Print loaded message
print("|cff00ffffBGLogger|r addon loaded. Use |cffffffff/bgstats|r to open the window.")
if DEBUG_MODE then
    print("|cff00ffffBGLogger|r debug mode active. Use |cffffffff/bgdebug|r for debug commands.")
    print("|cff00ffffBGLogger|r tip: Use |cffffffff/bgdebug forcesave|r to manually save current BG data.")
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