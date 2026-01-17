---------------------------------------------------------------------
-- BGLogger Export Module
-- Contains export JSON generation and export UI
---------------------------------------------------------------------

function TableToJSON(tbl, indent)
	indent = indent or 0
	local spacing = string.rep("  ", indent)

	if type(tbl) == "string" then
		local escaped = tbl:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
		return '"' .. escaped .. '"'
	elseif type(tbl) == "number" or type(tbl) == "boolean" then
		return tostring(tbl)
	elseif tbl == nil then
		return "null"
	elseif type(tbl) ~= "table" then
		return '"' .. tostring(tbl) .. '"'
	end

	local isArray = true
	local arraySize = 0
	for k, _ in pairs(tbl) do
		if type(k) ~= "number" then
			isArray = false
			break
		end
		if k > arraySize then arraySize = k end
	end

	local parts = {}
	if isArray then
		table.insert(parts, "[\n")
		local first = true
		for i = 1, arraySize do
			if tbl[i] ~= nil then
				if not first then table.insert(parts, ",\n") end
				first = false
				table.insert(parts, spacing .. "  " .. TableToJSON(tbl[i], indent + 1))
			end
		end
		table.insert(parts, "\n" .. spacing .. "]")
		return table.concat(parts)
	else
		table.insert(parts, "{\n")
		local keys = {}
		for k in pairs(tbl) do table.insert(keys, k) end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for idx, k in ipairs(keys) do
			if idx > 1 then table.insert(parts, ",\n") end
			local v = tbl[k]
			table.insert(parts, spacing .. '  "' .. tostring(k) .. '": ' .. TableToJSON(v, indent + 1))
		end
		table.insert(parts, "\n" .. spacing .. "}")
		return table.concat(parts)
	end
end

function ShowJSONExportFrame(jsonString, filename)
	
	if not BGLoggerExportFrame then
		local f = CreateFrame("Frame", "BGLoggerExportFrame", UIParent, "BackdropTemplate")
		f:SetSize(700, 500)
		f:SetPoint("CENTER")
		f:SetFrameStrata("DIALOG")
		
		f:SetBackdrop({
			bgFile = "Interface/Tooltips/UI-Tooltip-Background",
			edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
			edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 }
		})
		f:SetBackdropColor(0, 0, 0, 0.8)
		
		local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		title:SetPoint("TOP", 0, -16)
		title:SetText("Export Battleground Data")

		local inst = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		inst:SetPoint("TOPLEFT", 16, -46)
		inst:SetWidth(668)
		inst:SetJustifyH("LEFT")
		inst:SetText("Copy the JSON below and paste into the website upload page.")

		local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 16, -70)
		scroll:SetPoint("BOTTOMRIGHT", -36, 50)
		
		local editBox = CreateFrame("EditBox", nil, scroll)
		editBox:SetMultiLine(true)
		editBox:SetFontObject(ChatFontNormal)
		editBox:SetWidth(650)
		editBox:SetAutoFocus(false)
		editBox:EnableMouse(true)
		
		editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		editBox:SetScript("OnEditFocusGained", function(self)
			self:HighlightText()
		end)
		editBox:SetScript("OnMouseUp", function(self)
			self:HighlightText()
		end)
		
		scroll:SetScrollChild(editBox)
		f.editBox = editBox
		
		local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		closeBtn:SetSize(80, 22)
		closeBtn:SetPoint("BOTTOMRIGHT", -16, 16)
		closeBtn:SetText("Close")
		closeBtn:SetScript("OnClick", function() f:Hide() end)
		
		local copyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		copyBtn:SetSize(140, 22)
		copyBtn:SetPoint("RIGHT", closeBtn, "LEFT", -10, 0)
		copyBtn:SetText("Select All")
		copyBtn:SetScript("OnClick", function()
			f.editBox:SetFocus()
			f.editBox:HighlightText()
		end)

		local filenameText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		filenameText:SetPoint("BOTTOMLEFT", 16, 20)
		filenameText:SetWidth(500)
		filenameText:SetJustifyH("LEFT")
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

local function BuildExportObject(key)
	if not key or key == "" then
		return nil, nil, "No battleground selected for export"
	end

	local data = BGLoggerDB[key]
	if not data then
		return nil, nil, "Battleground data not found"
	end

	if not data.integrity then
		return nil, nil, "This battleground was saved without integrity data and cannot be exported safely."
	end

	local mapName = data.battlegroundName or "Unknown Battleground"

	local exportPlayers = {}
	local afkersList = {}
	for _, player in ipairs(data.stats or {}) do
		local objectiveData = {
			total = player.objectives or 0,
			breakdown = player.objectiveBreakdown or {}
		}
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
			objectives = objectiveData.total,
			objectiveBreakdown = objectiveData.breakdown,
			isBackfill = player.isBackfill or false
		})
	end

	if data.afkerList and type(data.afkerList) == "table" then
		for _, afker in ipairs(data.afkerList) do
			table.insert(afkersList, {
				name = afker.name,
				realm = afker.realm,
				faction = afker.faction or "Unknown",
				class = afker.class or "Unknown"
			})
		end
	end

	local exportData = {
		battleground = mapName,
		date = data.dateISO or date("!%Y-%m-%dT%H:%M:%SZ"),
		type = data.type or "non-rated",
		duration = tostring(data.duration or 0),
		trueDuration = tostring(data.trueDuration or data.duration or 0),
		winner = data.winner or "",
		season = data.season or "Unspecified",
		players = exportPlayers,
		afkers = afkersList,
		integrity = data.integrity,
		joinedInProgress = data.joinedInProgress or false,
		validForStats = data.validForStats or false,
		selfPlayer = data.selfPlayer,
		selfPlayerKey = data.selfPlayerKey,
		recorder = data.recorder,
		recorderKey = data.recorderKey
	}

	exportData.integrity = exportData.integrity or {}
	local forHashV2 = {
		battleground = exportData.battleground,
		date = exportData.date,
		type = exportData.type,
		duration = exportData.duration,
		trueDuration = exportData.trueDuration,
		winner = exportData.winner,
		players = exportData.players,
		afkers = exportData.afkers,
		joinedInProgress = exportData.joinedInProgress,
		validForStats = exportData.validForStats
	}
	local v2Hash, _ = GenerateDataHashV2FromExport(forHashV2)
	exportData.integrity.hash = v2Hash
	exportData.integrity.version = "BGLogger_v2.0"
	exportData.integrity.metadata = { algorithm = "deep_v2", playerCount = #exportPlayers }

	return exportData, mapName
end

function ExportBattleground(key)
	local exportData, mapName, err = BuildExportObject(key)
	if not exportData then
		if err then
			print("|cff00ffffBGLogger:|r " .. err)
		end
		return
	end

	local success, jsonString = pcall(TableToJSON, exportData)
	if not success then
		print("|cff00ffffBGLogger:|r Error generating JSON: " .. tostring(jsonString))
		return
	end

	local filename = string.format("BGLogger_%s_%s.json", 
		mapName:gsub("%s+", "_"):gsub("[^%w_]", ""),
		date("!%Y%m%d_%H%M%S")
	)

	ShowJSONExportFrame(jsonString, filename)
	print("|cff00ffffBGLogger:|r Exported " .. mapName .. " with verified integrity hash")
end

function ExportSelectedBattlegrounds(keys)
	if not keys or #keys == 0 then
		print("|cff00ffffBGLogger:|r Select at least one battleground from the main list first.")
		return
	end

	local exports = {}
	local successCount = 0
	for _, key in ipairs(keys) do
		local exportData, _, err = BuildExportObject(key)
		if exportData then
			table.insert(exports, exportData)
			successCount = successCount + 1
		elseif err then
			print("|cff00ffffBGLogger:|r Skipping " .. tostring(key) .. ": " .. err)
		end
	end

	if successCount == 0 then
		print("|cff00ffffBGLogger:|r No valid battlegrounds available for export.")
		return
	end

	local success, jsonString = pcall(TableToJSON, exports)
	if not success then
		print("|cff00ffffBGLogger:|r Error generating JSON: " .. tostring(jsonString))
		return
	end

	local filename = string.format("BGLogger_Selected_%s.json", date("!%Y%m%d_%H%M%S"))
	ShowJSONExportFrame(jsonString, filename)
	print("|cff00ffffBGLogger:|r Exported " .. successCount .. " battlegrounds in a single multi-log export.")
end

function ExportAllBattlegrounds()
	local keys = {}
	for k, v in pairs(BGLoggerDB) do
		if type(v) == "table" and v.mapID then table.insert(keys, k) end
	end
	table.sort(keys)

	local exports = {}
	for _, key in ipairs(keys) do
		local data = BGLoggerDB[key]
		if data then
			local success, json = pcall(function()
				local original = _G.TableToJSON
				local mapName = data.battlegroundName or "Unknown Battleground"
				local exportPlayers = {}
				for _, p in ipairs(data.stats or {}) do
					table.insert(exportPlayers, {
						name = p.name, realm = p.realm,
						damage = tostring(p.damage or p.dmg or 0),
						healing = tostring(p.healing or p.heal or 0)
					})
				end
				local obj = {
					battleground = mapName,
					date = data.dateISO or date("!%Y-%m-%dT%H:%M:%SZ"),
					type = data.type or "non-rated",
					duration = tostring(data.duration or 0),
					trueDuration = tostring(data.trueDuration or data.duration or 0),
					winner = data.winner or "",
					players = exportPlayers,
					integrity = data.integrity
				}
				return TableToJSON(obj)
			end)
			if success then table.insert(exports, json) end
		end
	end

	local jsonArray = "[\n  " .. table.concat(exports, ",\n  ") .. "\n]"
	local filename = string.format("BGLogger_All_%s.json", date("!%Y%m%d_%H%M%S"))
	ShowJSONExportFrame(jsonArray, filename)
	print("|cff00ffffBGLogger:|r Exported all battlegrounds (" .. tostring(#exports) .. ")")
end


