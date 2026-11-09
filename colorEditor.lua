-- Color Editor: In-game character palette editor.
-- Version: 1.0.0
-- Date: 06/11/2026
-- Author: Rakíel
-- Compatible with: Ikemen GO 1.0 and nightly
-- Description: Edit character palettes with RGB(A) and HSV controls, live previews, backups and restoration.

local util = require('external.mods.colorEditor.-colorEditor-util')
local interface = require('external.mods.colorEditor.-colorEditor-ui')

local editor = util.loadMotifExtensions('external/mods/colorEditor/colorEditor.def', 'external/mods/colorEditor/colorEditor.def')
local m = editor.coloreditor_info
local background = editor.coloreditorbgdef

local function loadFade(section)
	local anim
	if (tonumber(section.anim) or -1) >= 0 then
		anim = util.loadMotifAnim(section)
	end
	return fadeNew({
		time = tonumber(section.time),
		color = section.col,
		anim = anim,
		sound = section.snd,
	})
end
m.fadein.FadeData = loadFade(m.fadein)
m.fadeout.FadeData = loadFade(m.fadeout)

m.anim.exclude = type(m.anim.exclude) == 'table' and m.anim.exclude or {m.anim.exclude}
for k, v in pairs(m.anim.exclude) do
	m.anim.exclude[k] = tonumber(v)
end
local function isExcluded(anim)
	if anim < tonumber(m.anim.range[1]) then
		return true
	end
	if anim > tonumber(m.anim.range[2]) then
		return true
	end
	for _, v in pairs(m.anim.exclude) do
		if v == anim then
			return true
		end
	end
	return false
end

-------------------------------------------------------------
-- Menu entry
-------------------------------------------------------------
main.t_itemname.coloreditor = function()
	return start.f_colorEditor
end

-------------------------------------------------------------
-- Selection previews
-------------------------------------------------------------
local editedPalettes = {}
local paletteRevision = {}
local editedBasePalettes = {}
local appliedCellPalettes = setmetatable({}, {__mode = 'k'})
local appliedPalettes = setmetatable({}, {__mode = 'k'})
local portraitRefs = setmetatable({}, {__mode = 'k'})
local loadPalettesKey = type(start.f_loadPalettes) == 'function' and 'f_loadPalettes' or 'loadPalettes'
local engineLoadPalettes = start[loadPalettesKey]
local engineAnimGet = start.f_animGet
local engineDrawPortraits = start.f_drawPortraits
local engineMaterializeCharCell = main.f_materializeCharCell

local function refreshCellPalette(charData)
	local base = editedBasePalettes[charData.char_ref]
	local anim = charData.cell_data
	if not base or not anim then
		return
	end

	local stamp = appliedCellPalettes[anim]
	if stamp and stamp.ref == charData.char_ref and stamp.revision == base.revision then
		return
	end
	-- Copy the preloaded base while preserving unique palettes.
	anim = animCopy(anim)
	animPaletteSet(anim, 1, base.colors)
	animSetColorPalette(anim, 1)
	animUpdate(anim)
	charData.cell_data = anim
	appliedCellPalettes[anim] = {ref = charData.char_ref, revision = base.revision}
	start.needUpdateDrawList = true
end

local function refreshPalettes(anim, ref, selectedPal)
	local colors = editedPalettes[ref]
	if not anim or not colors then
		return anim
	end

	local stamp = appliedPalettes[anim]
	if stamp and stamp.ref == ref and stamp.revision == paletteRevision[ref] then
		return anim
	end
	-- Load edited slots before native palette cycling.
	for pal, palette in pairs(colors) do
		animPaletteSet(anim, pal, palette)
	end
	-- Restore selection after palette writes reset the mapping.
	animSetColorPalette(anim, selectedPal)
	appliedPalettes[anim] = {ref = ref, revision = paletteRevision[ref]}
	return anim
end

-------------------------------------------------------------
-- Editor helpers
-------------------------------------------------------------
local function copyColors(colors)
	local copy = {}
	for i, color in ipairs(colors) do
		copy[i] = {color[1], color[2], color[3], color[4]}
	end
	return copy
end

-- Shared RGB and HSV hold acceleration.
local function sliderInput()
	local increase = getInputTime(-1, m.slider.increase.key)
	local decrease = getInputTime(-1, m.slider.decrease.key)
	local activeTime = math.max(increase, decrease)
	local speed = util.clamp(1, math.ceil((activeTime ^ 2) * 0.001), 20)
	local function step(held)
		if held == 1 then
			return 1
		end
		if held > 10 and held % 2 == 0 then
			return speed
		end
		return 0
	end
	return step(increase), step(decrease)
end

-------------------------------------------------------------
-- Palette editor
-------------------------------------------------------------
local function editPalette()
	bgReset(background.BGDef)

	-- Palette and character preview
	local ref = start.p[1].t_selected[1].ref
	local pal = start.p[1].t_selected[1].pal
	local charData = start.f_getCharData(ref)
	local def = charData.def
	local air = util.getDefPath(def, 'anim')
	local source, sourceErr = util.getPaletteSource(def, pal)
	if not source then
		print('Color Editor: ' .. tostring(sourceErr))
		return
	end

	local channelCount = source.alpha and 4 or 3
	local formatText = string.format(
		m.format.text.text,
		source.version.label,
		source.kind == 'act' and m.format.act.text or m.format.sff.text,
		source.alpha and 'RGBA' or 'RGB'
	)
	if not source.editable then
		formatText = formatText .. m.format.readonly.text
	end

	local selectMode = 1
	local selectModeCooldown = 0
	local selectColorData = {}
	local changed = false
	local paletteWritten = false
	local sprite = util.loadPreviewSff(source)
	local animtable = loadAnimTable(air, sprite)

	local actionNumbers, anims, idle = {}, {}, 1
	for number in pairs(animtable) do
		if type(number) == 'number' and not isExcluded(number) then
			table.insert(actionNumbers, number)
		end
	end
	table.sort(actionNumbers)
	for i, number in ipairs(actionNumbers) do
		anims[i] = animtable[number]
		if number == 0 then
			idle = i
		end
	end
	if #anims == 0 then
		printConsole('Color Editor: No character animations match anim.range/anim.exclude: ' .. tostring(air))
		return
	end

	local locator
	local locatorConfig = m.preview.locator
	if locatorConfig and (locatorConfig.enabled == true or tonumber(locatorConfig.enabled) == 1) and type(animPaletteCopy) == 'function' then
		local ok, result, err = pcall(function()
			return require('external.mods.colorEditor.-colorEditor-locator').new(source, sprite, ref, locatorConfig, charData)
		end)
		if ok then
			locator = result
		end
		if not locator then
			printConsole('Color Editor: Locator unavailable: ' .. tostring(ok and err or result))
		end
	end

	local preview = {}
	for key, value in pairs(m.preview) do
		preview[key] = value
	end
	if locator then
		preview.offset, preview.window = locatorConfig.main.offset, locatorConfig.main.window
	end

	-- Cursor state (row, column + 1, channel, animation and dialog choices).
	local cursorPos = {1, 2, 1, idle, 2, 2}
	local actionChoice = 1
	local clipboard
	local multiConfig = m.multicolor
	local multiEnabled = multiConfig and (multiConfig.enabled == true or tonumber(multiConfig.enabled) == 1)
	local markedColors, markedCount = {}, 0
	local groupColors, groupValues, groupChannel = {}, {0, 0, 0}, 1
	local actionNames = {'copy', 'paste', 'reset', 'adjust', 'clear'}
	local viewX, viewY, viewZoom = 0, 0, 1
	local wasAdjusting, browseBlocked = false, false
	local scaleX, scaleY = util.previewScale(preview, charData)

	local function loadAnim(k, locator)
		local anim = util.newPalettePreview(sprite, anims[k], source, ref)
		if locator then
			local ok, result, err = pcall(locator.setAction, locator, anims[k])
			if not ok or not result then
				printConsole('Color Editor: Locator unavailable: ' .. tostring(ok and err or result))
				locator = nil
				preview.offset, preview.window = m.preview.offset, m.preview.window
			end
		end
		util.updateMotifAnim(anim, preview)
		animSetLayerno(anim, 2)
		return anim, locator
	end

	local function copyPalData(anim, tbl)
		util.updatePreviewPalette(anim, source, tbl)
	end

	local anim
	anim, locator = loadAnim(cursorPos[4], locator)

	animUpdate(anim)

	local colorTable = source.colors and copyColors(source.colors) or animPaletteGet(anim, pal)
	if #colorTable == 0 then
		printConsole('Color Editor: Selected palette has no colors: ' .. tostring(def))
		return
	end
	copyPalData(anim, colorTable)
	local highlight = util.newPreviewHighlight(source, m.preview.highlight)
	local function updateColor(index, color)
		colorTable[index] = {color[1], color[2], color[3], color[4]}
		copyPalData(anim, {[index] = colorTable[index]})
	end

	local cols = math.floor(tonumber(m.cell.columns) or 16)
	if cols < 1 then
		cols = 16
	end
	cols = math.min(cols, #colorTable)
	local rows = math.ceil(#colorTable / cols)
	local function rowColumns(row)
		return math.min(cols, #colorTable - (row - 1) * cols)
	end

	local ui = interface.new(m, cols, rows)

	local originalColorTable = copyColors(colorTable)
	local savedColorTable = copyColors(colorTable)
	local function updateChanged()
		changed = false
		for i, color in ipairs(colorTable) do
			for channel = 1, channelCount do
				if color[channel] ~= savedColorTable[i][channel] then
					changed = true
					return
				end
			end
		end
	end

	local function applyGroup()
		local changes = {}
		for index, color in pairs(groupColors) do
			colorTable[index] = util.adjustHSV(color, groupValues[1], groupValues[2], groupValues[3])
			changes[index] = colorTable[index]
		end
		copyPalData(anim, changes)
		updateChanged()
	end

	local saveTextTimer = 0
	local saveMessage = m.save.text.text
	local function feedback(message, err, failed)
		saveMessage = message
		saveTextTimer = m.save.time
		if err then
			print('Color Editor: ' .. tostring(err))
		end

		local sound = (err or failed) and m.cancel.snd or m.done.snd
		sndPlay(motif.Snd, sound[1], sound[2])
	end

	local function rememberPalette()
		paletteWritten = true
		editedPalettes[ref] = editedPalettes[ref] or {}
		editedPalettes[ref][pal] = copyColors(colorTable)
		paletteRevision[ref] = (paletteRevision[ref] or 0) + 1
		-- Refresh cell portraits from native palette 1,1.
		if source.kind == 'sff' and pal == 1 then
			editedBasePalettes[ref] = {colors = copyColors(colorTable), revision = paletteRevision[ref]}
			for _, data in ipairs(main.t_selChars) do
				if data.char_ref == ref then
					refreshCellPalette(data)
				end
			end
		end
	end
	-- Start music after preview loading.
	playBgm({
		bgm = m.bgm.path,
		loop = tonumber(m.bgm.loop),
		volume = tonumber(m.bgm.volume),
		loopstart = tonumber(m.bgm.loopstart),
		loopend = tonumber(m.bgm.loopend),
		startposition = tonumber(m.bgm.startposition),
		freqmul = tonumber(m.bgm.freqmul),
		loopcount = tonumber(m.bgm.loopcount),
	})
	fadeInInit(m.fadein.FadeData)

	-- Editor loop
	while true do
		local idx = (((cursorPos[1] - 1) * cols) + cursorPos[2]) - 1
		local inputMode = selectMode
		local cursorWrapped = false
		local fading = fadeActive()
		local adjusting = selectMode == 1 and getInputTime(-1, m.preview.adjust.key) > 0
		local browseHeld = getInputTime(-1, m.preview.browse.key) > 0
		if not browseHeld then
			browseBlocked = false
		elseif wasAdjusting and not adjusting then
			browseBlocked = true
		end

		local browsing = selectMode == 1 and not adjusting and not browseBlocked and browseHeld
		wasAdjusting = adjusting
		if main.close and not fading then
			highlight:clear(colorTable)
			break
		elseif main.close or fading then
			-- Wait for the fade.
			esc(false)
		elseif selectMode == 1 and (getInput(-1, {'m'}) or esc()) then
			esc(false)
			if changed == true then
				sndPlay(motif.Snd, m.done.snd[1], m.done.snd[2])
				selectMode = 0
				cursorPos[5] = 2
			else
				selectMode = 3
				sndPlay(motif.Snd, m.cancel.snd[1], m.cancel.snd[2])
				fadeOutInit(m.fadeout.FadeData)
				main.close = true
			end
		elseif selectMode == 2 and (getInput(-1, m.cell.cancel.key) or esc()) then
			esc(false)
			updateColor(idx, selectColorData)
			updateChanged()
			selectMode, selectModeCooldown = 1, 15
			sndPlay(motif.Snd, m.cancel.snd[1], m.cancel.snd[2])
		elseif selectMode == 5 then
			if esc() or getInput(-1, m.cell.cancel.key) then
				esc(false)
				groupValues = {0, 0, 0}
				applyGroup()
				groupColors = {}
				selectMode, selectModeCooldown = 1, 15
				sndPlay(motif.Snd, m.cancel.snd[1], m.cancel.snd[2])
			elseif getInput(-1, m.cell.confirm.key) then
				groupColors = {}
				selectMode, selectModeCooldown = 1, 15
				sndPlay(motif.Snd, m.done.snd[1], m.done.snd[2])
			else
				local increase, decrease = sliderInput()
				local channel = groupChannel
				local limit = channel == 1 and 180 or 100
				local value = util.clamp(-limit, groupValues[channel] + increase - decrease, limit)
				if value ~= groupValues[channel] then
					groupValues[channel] = value
					applyGroup()
				end
				if getInput(-1, m.slider.next.key) then
					groupChannel = groupChannel % 3 + 1
					sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
				elseif getInput(-1, m.slider.prev.key) then
					groupChannel = (groupChannel - 2) % 3 + 1
					sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
				end
			end
		elseif adjusting then
			local move = m.preview.move
			if getInput(-1, move.up.key) then
				viewY = viewY - move.step[2]
			end
			if getInput(-1, move.down.key) then
				viewY = viewY + move.step[2]
			end
			if getInput(-1, move.back.key) then
				viewX = viewX - move.step[1]
			end
			if getInput(-1, move.fwd.key) then
				viewX = viewX + move.step[1]
			end

			local zoom = m.preview.zoom
			if getInput(-1, zoom.decrease.key) then
				viewZoom = util.clamp(zoom.min, viewZoom - zoom.step, zoom.max)
			end
			if getInput(-1, zoom.increase.key) then
				viewZoom = util.clamp(zoom.min, viewZoom + zoom.step, zoom.max)
			end
			if getInput(-1, m.preview.reset.key) then
				viewX, viewY, viewZoom = 0, 0, 1
			end
		elseif browsing then
			local step = 0
			if getInput(-1, m.preview.prev.key) then
				step = -1
			elseif getInput(-1, m.preview.next.key) then
				step = 1
			end
			if step ~= 0 then
				cursorPos[4] = (cursorPos[4] - 1 + step) % #anims + 1
				sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
				anim, locator = loadAnim(cursorPos[4], locator)
				copyPalData(anim, colorTable)
			end
		elseif selectMode == 1 and getInput(-1, m.actions.key) then
			selectMode, actionChoice = 4, 1
			sndPlay(motif.Snd, m.done.snd[1], m.done.snd[2])
		elseif selectMode == 1 and multiEnabled and getInput(-1, multiConfig.key) then
			markedColors[idx] = not markedColors[idx] or nil
			markedCount = markedCount + (markedColors[idx] and 1 or -1)
			sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
		elseif selectMode == 4 then
			if esc() or getInput(-1, m.actions.cancel.key) then
				esc(false)
				selectMode = 1
				sndPlay(motif.Snd, m.cancel.snd[1], m.cancel.snd[2])
			elseif getInput(-1, m.actions.up.key) then
				actionChoice = actionChoice == 1 and (markedCount > 0 and 5 or 3) or actionChoice - 1
				sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
			elseif getInput(-1, m.actions.down.key) then
				actionChoice = actionChoice == (markedCount > 0 and 5 or 3) and 1 or actionChoice + 1
				sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
			elseif getInput(-1, m.actions.confirm.key) then
				if actionChoice > 1 and actionChoice < 5 and not source.editable then
					feedback(m.save.readonly.text, nil, true)
				elseif actionChoice == 2 and not clipboard then
					feedback(m.actions.empty.text, nil, true)
				elseif actionChoice == 4 then
					groupColors, groupValues, groupChannel = {}, {0, 0, 0}, 1
					for index in pairs(markedColors) do
						groupColors[index] = copyColors({colorTable[index]})[1]
					end
					selectMode = 5
					sndPlay(motif.Snd, m.done.snd[1], m.done.snd[2])
				elseif actionChoice == 5 then
					markedColors, markedCount, selectMode = {}, 0, 1
					sndPlay(motif.Snd, m.done.snd[1], m.done.snd[2])
				else
					local action = actionNames[actionChoice]
					if actionChoice == 1 then
						clipboard = copyColors({colorTable[idx]})[1]
					else
						local color = copyColors({colorTable[idx]})[1]
						local from = actionChoice == 2 and clipboard or savedColorTable[idx]
						for channel = 1, channelCount do
							color[channel] = from[channel]
						end
						updateColor(idx, color)
						updateChanged()
					end
					selectMode = 1
					feedback(m.actions[action].done.text)
				end
			end
		elseif selectMode == 0 then
			if esc() then
				esc(false)
				selectMode = 1
			elseif getInput(-1, m.warning.confirm.key) then
				if cursorPos[5] == 1 then
					sndPlay(motif.Snd, m.cancel.snd[1], m.cancel.snd[2])
					fadeOutInit(m.fadeout.FadeData)
					main.close = true
					selectMode = 3
				else
					sndPlay(motif.Snd, m.cancel.snd[1], m.cancel.snd[2])
					selectMode = 1
				end
			elseif getInput(-1, m.warning.switch.key) then
				sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
				cursorPos[5] = (cursorPos[5] == 1) and 2 or 1
			end
		else
			-- Palette navigation and commands
			if selectMode == 1 then
				if getInput(-1, m.cell.cursor.down.key) then
					cursorWrapped = cursorWrapped or cursorPos[1] == rows
					sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
					cursorPos[1] = (cursorPos[1] == rows) and 1 or (cursorPos[1] + 1)
					cursorPos[2] = math.min(cursorPos[2], rowColumns(cursorPos[1]) + 1)
				end
				if getInput(-1, m.cell.cursor.up.key) then
					cursorWrapped = cursorWrapped or cursorPos[1] == 1
					sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
					cursorPos[1] = (cursorPos[1] == 1) and rows or (cursorPos[1] - 1)
					cursorPos[2] = math.min(cursorPos[2], rowColumns(cursorPos[1]) + 1)
				end
				if getInput(-1, m.cell.cursor.fwd.key) then
					cursorWrapped = cursorWrapped or cursorPos[2] == rowColumns(cursorPos[1]) + 1
					sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
					cursorPos[2] = (cursorPos[2] == rowColumns(cursorPos[1]) + 1) and 2 or (cursorPos[2] + 1)
				end
				if getInput(-1, m.cell.cursor.back.key) then
					cursorWrapped = cursorWrapped or cursorPos[2] == 2
					sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
					cursorPos[2] = (cursorPos[2] == 2) and (rowColumns(cursorPos[1]) + 1) or (cursorPos[2] - 1)
				end
				idx = (((cursorPos[1] - 1) * cols) + cursorPos[2]) - 1
				if getInput(-1, m.save.key) then
					local saved, err = util.savePaletteSource(source, colorTable, originalColorTable, m.backupfiles)
					if saved then
						rememberPalette()
						savedColorTable = copyColors(colorTable)
						changed = false
						feedback(m.save.text.text)
					else
						feedback(m.save.error.text, err)
					end
				elseif getInput(-1, m.restore.key) then
					if util.hasPaletteBackup(source) then
						saveTextTimer, selectMode, cursorPos[6] = 0, 0.75, 2
						sndPlay(motif.Snd, m.done.snd[1], m.done.snd[2])
					else
						feedback(m.restore.missing.text, 'No original palette backup: ' .. source.backup)
					end
				end
			-- Channel editing
			elseif selectMode == 2 then
				local rgba = {colorTable[idx][1], colorTable[idx][2], colorTable[idx][3], colorTable[idx][4]}

				local increase, decrease = sliderInput()

				local function applyColor()
					updateColor(idx, rgba)
					updateChanged()
				end

				if decrease > 0 and colorTable[idx][cursorPos[3]] > 0 then
					rgba[cursorPos[3]] = math.max(0, rgba[cursorPos[3]] - decrease)
					applyColor()
				end

				if increase > 0 and colorTable[idx][cursorPos[3]] < 255 then
					rgba[cursorPos[3]] = math.min(255, rgba[cursorPos[3]] + increase)
					applyColor()
				end

				if getInput(-1, m.slider.next.key) then
					sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
					cursorPos[3] = (cursorPos[3] == channelCount) and 1 or (cursorPos[3] + 1)
				elseif getInput(-1, m.slider.prev.key) then
					sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
					cursorPos[3] = (cursorPos[3] == 1) and channelCount or (cursorPos[3] - 1)
				end
			elseif selectMode == 0.75 then
				if esc() then
					esc(false)
					selectMode = 1
					sndPlay(motif.Snd, m.cancel.snd[1], m.cancel.snd[2])
				elseif getInput(-1, m.warning.confirm.key) then
					if cursorPos[6] == 1 then
						local colors, err = util.restorePaletteSource(source, m.restore.deletebackup)
						if colors then
							colorTable = copyColors(colors)
							copyPalData(anim, colorTable)
							rememberPalette()
							originalColorTable = copyColors(colorTable)
							savedColorTable = copyColors(colorTable)
							changed = false
							feedback(err and m.restore.cleanup.error.text or m.restore.done.text, err)
						else
							feedback(m.restore.error.text, err)
						end
					else
						sndPlay(motif.Snd, m.cancel.snd[1], m.cancel.snd[2])
					end
					selectMode = 1
				elseif getInput(-1, m.warning.switch.key) then
					cursorPos[6] = cursorPos[6] == 1 and 2 or 1
					sndPlay(motif.Snd, m.move.snd[1], m.move.snd[2])
				end
			end
		end

		-- Enter or confirm a color edit
		if
			not main.close
			and not fading
			and not adjusting
			and not browsing
			and selectMode == inputMode
			and selectModeCooldown == 0
			and (selectMode == 1 or selectMode == 2)
		then
			if selectMode == 1 and getInput(-1, m.cell.select.key) then
				if source.editable then
					-- Preserve the entry color for cancellation.
					selectColorData = {
						colorTable[idx][1],
						colorTable[idx][2],
						colorTable[idx][3],
						colorTable[idx][4],
					}
					selectMode = 2
					selectModeCooldown = 15
					sndPlay(motif.Snd, m.done.snd[1], m.done.snd[2])
				else
					feedback(m.save.readonly.text, source.reason)
				end
			elseif selectMode == 2 and getInput(-1, m.cell.confirm.key) then
				selectMode = 1
				selectModeCooldown = 15
				sndPlay(motif.Snd, m.done.snd[1], m.done.snd[2])
			end
		end

		if selectModeCooldown > 0 then
			selectModeCooldown = selectModeCooldown - 1
		end

		if saveTextTimer > 0 then
			saveTextTimer = saveTextTimer - 1
		end
		highlight:update(anim, idx, colorTable, not locator and selectMode == 1 and not fading and not main.close, markedColors)

		-- Draw the editor above the background.
		clearColor(background.bgclearcolor[1], background.bgclearcolor[2], background.bgclearcolor[3])
		bgDraw(background.BGDef, 0)
		bgDraw(background.BGDef, 1)
		ui:drawPreview()
		animSetPos(anim, m.pos[1] + preview.offset[1] + viewX, m.pos[2] + preview.offset[2] + viewY)
		animSetScale(anim, scaleX * viewZoom, scaleY * viewZoom)
		animUpdate(anim)
		animDraw(anim, 2)
		if locator then
			locator:draw(
				idx,
				colorTable,
				(selectMode == 1 or selectMode == 2 or selectMode == 4 or selectMode == 5) and not fading and not main.close,
				markedColors
			)
		end
		ui:draw({
			colors = colorTable,
			saved = savedColorTable,
			index = idx,
			row = cursorPos[1],
			column = cursorPos[2] - 1,
			channel = selectMode == 5 and groupChannel or cursorPos[3],
			cursorWrapped = cursorWrapped,
			channels = channelCount,
			mode = selectMode,
			changed = changed,
			action = actionChoice,
			canPaste = clipboard ~= nil and source.editable,
			marked = markedColors,
			markedCount = markedCount,
			adjustment = groupValues,
			editable = source.editable,
			adjusting = adjusting and selectMode == 1,
			browsing = browsing and selectMode == 1,
			choice = selectMode == 0 and cursorPos[5] or cursorPos[6],
			name = charData.name or def,
			pal = pal,
			format = formatText,
			feedback = saveTextTimer > 0 and string.format(saveMessage, pal) or nil,
		})

		refresh()
	end
	return paletteWritten
end

-------------------------------------------------------------
-- Character selection
-------------------------------------------------------------
function start.f_colorEditor()
	start.f_selectReset(true)
	main.f_default()
	remapInput(1, getLastInputController())
	remapInput(getLastInputController(), 1)
	main.teamMenu[1].single = true
	main.close = false
	local menuGroup = motif[main.group]
	local menuBackground = motif[main.background]
	while true do
		textImgSetText(motif.select_info.title.TextSpriteData, editor.select_title)
		local selected = start.f_selectScreen()
		-- Present the selection's terminal fade frame before loading or returning.
		refresh()
		if not selected then
			esc(false)
			bgReset(menuBackground.BGDef)
			fadeInInit(menuGroup.fadein.FadeData)
			playBgm({source = 'motif.title', interrupt = true})
			main.close = false
			return
		end
		local paletteWritten = editPalette()
		-- Finish the editor fade before resetting the selection state.
		refresh()
		if paletteWritten then
			-- Discard resident fight assets so the next match reads the saved palettes.
			loadCancel()
		end
		main.close = false
		start.f_selectReset(false)
	end
end

-------------------------------------------------------------
-- Engine integration
-------------------------------------------------------------
if engineMaterializeCharCell then
	function main.f_materializeCharCell(row)
		local ready = engineMaterializeCharCell(row)
		local data = main.t_selChars[row]
		if ready and data then
			refreshCellPalette(data)
		end
		return ready
	end
end

start[loadPalettesKey] = function(a, ref, pal, bypass)
	a = engineLoadPalettes(a, ref, pal, bypass)
	if a then
		portraitRefs[a] = ref
	end
	return refreshPalettes(a, ref, pal)
end

function start.f_animGet(ref, side, member, params, ...)
	local anim = engineAnimGet(ref, side, member, params, ...)
	local stamp = anim and appliedPalettes[anim]
	if anim and editedPalettes[ref] and params.applypal and not (stamp and stamp.ref == ref and stamp.revision == paletteRevision[ref]) then
		-- Confirmed portraits are already prepared by f_animGet.
		-- Rebuild unconfirmed portraits with palette 1 when cancelling.
		anim = start[loadPalettesKey](anim, ref, 1)
	end
	if anim then
		portraitRefs[anim] = ref
	end
	return anim
end

function start.f_drawPortraits(portraits, side, params, subname, ...)
	for member, portrait in ipairs(portraits) do
		if editedPalettes[portrait.ref] then
			-- Match the engine's p3/p4 -> p1/p2 parameter fallback.
			local config
			if type(params) == 'table' then
				config = params['p' .. (2 * (member - 1) + side)] or params['p' .. side]
			end
			if config then
				local pal = 1
				if portrait.slotConfirmed ~= false then
					pal = (portrait.validPals and portrait.validPals[portrait.currentIdx]) or portrait.pal or pal
				end

				local face = subname and subname ~= '' and config[subname] or config
				if face and face.applypal and portraitRefs[portrait.face_data] == portrait.ref then
					refreshPalettes(portrait.face_data, portrait.ref, pal)
				end
				if config.face2 and config.face2.applypal and portraitRefs[portrait.face2_data] == portrait.ref then
					refreshPalettes(portrait.face2_data, portrait.ref, pal)
				end
			end
		end
	end
	return engineDrawPortraits(portraits, side, params, subname, ...)
end
