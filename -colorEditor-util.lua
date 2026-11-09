local t = {}
local function nativeSff()
	return require('external.mods.colorEditor.-colorEditor-sffv2')
end

-------------------------------------------------------------
-- General helpers
-------------------------------------------------------------
function t.clamp(lo, val, hi)
	if val < lo then
		return lo
	end
	if val > hi then
		return hi
	end
	return val
end

function t.backwards(_t)
	return function(t2, i)
		i = i - 1
		if i ~= 0 then
			return i, t2[i]
		end
	end, _t, #_t + 1
end

function t.normpath(path)
	path = path:gsub('\\', '/')
	local prefix = path:match('^%a:/') or path:match('^//') or path:match('^/') or ''
	local components = {}
	for comp in path:sub(#prefix + 1):gmatch('[^/]+') do
		if comp == '..' then
			if #components > 0 and components[#components] ~= '..' then
				table.remove(components)
			elseif prefix == '' then
				table.insert(components, comp)
			end
		elseif comp ~= '.' then
			table.insert(components, comp)
		end
	end
	return prefix .. table.concat(components, '/')
end

-------------------------------------------------------------
-- File handling
-------------------------------------------------------------
function t.readBytes(file, b)
	local bytes = file:read(b)
	local j = 0

	for i = b, 1, -1 do
		j = j * 256 + bytes:byte(i)
	end

	return j
end

local function readFile(path)
	local file, err = io.open(path, 'rb')
	if not file then
		return nil, 'Cannot open ' .. path .. ': ' .. tostring(err)
	end

	local data, readErr = file:read('*a')
	local closed, closeErr = file:close()
	if not data or not closed then
		return nil, 'Cannot read ' .. path .. ': ' .. tostring(readErr or closeErr)
	end
	return data
end

local function fileExists(path)
	-- Keep unreadable backups distinguishable from missing files.
	return _G.fileExists(path)
end

-- Close the temporary file before replacing the destination.
local function writeFile(path, data, preserveExisting)
	if preserveExisting and fileExists(path) then
		return nil, 'Backup already exists: ' .. path
	end

	local temporary = path .. '.coloreditor.tmp'
	if fileExists(temporary) then
		return nil, 'Temporary file already exists: ' .. temporary
	end

	local file, err = io.open(temporary, 'wb')
	if not file then
		return nil, 'Cannot open ' .. temporary .. ': ' .. tostring(err)
	end

	local written, writeErr = file:write(data)
	local closed, closeErr = file:close()
	if not written or not closed then
		os.remove(temporary)
		return nil, 'Cannot write ' .. path .. ': ' .. tostring(writeErr or closeErr)
	end
	if preserveExisting and fileExists(path) then
		os.remove(temporary)
		return nil, 'Backup appeared during saving: ' .. path
	end

	local renamed, renameErr = os.rename(temporary, path)
	if not renamed then
		os.remove(temporary)
		return nil, 'Cannot replace ' .. path .. ': ' .. tostring(renameErr)
	end
	return true
end

-------------------------------------------------------------
-- DEF parsing
-------------------------------------------------------------
local function trim(value)
	return value:match('^%s*(.-)%s*$')
end

local function stripComment(line)
	local quoted = false
	for i = 1, #line do
		local char = line:sub(i, i)
		if char == '"' then
			quoted = not quoted
		elseif char == ';' and not quoted then
			return line:sub(1, i - 1), line:sub(i)
		end
	end
	return line, ''
end

local function defHeader(line)
	return trim(stripComment(line):gsub('^\239\187\191', '')):match('^%[(.-)%]$')
end

local function defEntry(line)
	local content, comment = stripComment(line)
	local key, value = content:match('^%s*([^=]-)%s*=%s*(.-)%s*$')
	if not key then
		return nil
	end
	return trim(key):lower(), trim(value), comment
end

local function prepareDefEntry(def, section, key, value)
	local data, err = readFile(def)
	if not data then
		return nil, err
	end

	local newline = data:find('\r\n', 1, true) and '\r\n' or '\n'
	local lines, inSection, foundSection, keyWritten = {}, false, false, false
	local function appendEntry()
		if #lines > 0 and not lines[#lines]:match('\n$') then
			lines[#lines] = lines[#lines] .. newline
		end
		lines[#lines + 1] = key .. ' = ' .. value .. newline
	end

	local offset = 1
	while offset <= #data do
		local stop = data:find('\n', offset, true)
		local raw = data:sub(offset, stop or #data)
		offset = (stop or #data) + 1
		local line = raw:gsub('[\r\n]+$', '')
		local header = defHeader(line)
		if header then
			if inSection and not keyWritten then
				appendEntry()
				keyWritten = true
			end
			inSection = trim(header):lower() == section:lower()
			foundSection = foundSection or inSection
		elseif inSection then
			local entry, _, comment = defEntry(line)
			if entry == key:lower() then
				local ending = raw:match('\r?\n$') or ''
				raw = (line:match('^%s*') or '') .. key .. ' = ' .. value .. (comment ~= '' and ' ' .. comment or '') .. ending
				keyWritten = true
			end
		end
		lines[#lines + 1] = raw
	end
	if inSection and not keyWritten then
		appendEntry()
	elseif not foundSection then
		if #lines > 0 and not lines[#lines]:match('\n$') then
			lines[#lines] = lines[#lines] .. newline
		end
		lines[#lines + 1] = '[' .. section .. ']' .. newline
		appendEntry()
	end
	return table.concat(lines)
end

function t.writeDefEntry(def, section, key, value)
	local data, err = prepareDefEntry(def, section, key, value)
	if not data then
		return nil, err
	end
	return writeFile(def, data)
end

-------------------------------------------------------------
-- ACT palettes
-------------------------------------------------------------
function t.createBackupFile(path)
	if fileExists(path .. '.bak') then
		return true
	end

	local data, err = readFile(path)
	if not data then
		return nil, err
	end
	return writeFile(path .. '.bak', data, true)
end

function t.saveActFile(act, tbl, depth, preserveExisting)
	if type(depth) ~= 'number' or depth < 1 or depth % 1 ~= 0 then
		return nil, 'Invalid palette size'
	end

	local colors = {}
	for i = depth, 1, -1 do
		local color = tbl[i]
		for channel = 1, 3 do
			local value = type(color) == 'table' and color[channel] or nil
			if type(value) ~= 'number' or value < 0 or value > 255 or value % 1 ~= 0 then
				return nil, 'Invalid RGB value at palette index ' .. i
			end
		end
		colors[#colors + 1] = string.char(color[1], color[2], color[3])
	end
	return writeFile(act, table.concat(colors), preserveExisting)
end

function t.saveSffFile(sff, pal, tbl)
	local info, err = nativeSff().inspect(sff, pal)
	if not info then
		return nil, err
	end

	local raw
	raw, err = nativeSff().encode(info, tbl)
	if not raw then
		return nil, err
	end
	return nativeSff().write(info, raw)
end

function t.sffVersion(sff)
	return nativeSff().version(sff)
end

function t.resolveDefPath(def, path)
	path = path:gsub('\\', '/')
	if path:match('^/') or path:match('^%a:/') then
		return t.normpath(path)
	end

	local directory = def:gsub('\\', '/'):match('^(.*)/') or '.'
	return t.normpath(directory .. '/' .. path)
end

function t.getDefPath(def, filetype)
	local data, err = readFile(def)
	if not data then
		return nil, err
	end

	local inFiles = false
	for line in (data .. '\n'):gmatch('(.-)\n') do
		local header = defHeader(line)
		if header then
			inFiles = trim(header):lower() == 'files'
		elseif inFiles then
			local key, path = defEntry(line)
			if key == filetype:lower() then
				if path:sub(1, 1) == '"' and path:sub(-1) == '"' then
					path = path:sub(2, -2)
				end
				if path == '' then
					return nil
				end
				return t.resolveDefPath(def, path)
			end
		end
	end
end

-- Commit the ACT before its DEF entry and roll back if the DEF update fails.
function t.savePalette(def, pal, colors, originalColors, backupEnabled)
	local key = 'pal' .. tostring(pal)
	local act, err = t.getDefPath(def, key)
	if err then
		return nil, err
	end

	local needsEntry = act == nil
	local filename = 'color' .. tostring(pal) .. '.act'
	act = act or t.resolveDefPath(def, filename)
	local defData, previousAct
	local existed = fileExists(act)
	if needsEntry then
		defData, err = prepareDefEntry(def, 'Files', key, filename)
		if not defData then
			return nil, err
		end
		if existed then
			previousAct, err = readFile(act)
			if not previousAct then
				return nil, err
			end
		end
	end
	if (backupEnabled == true or tonumber(backupEnabled) == 1) and not fileExists(act .. '.bak') then
		local backedUp
		if existed then
			backedUp, err = t.createBackupFile(act)
		else
			backedUp, err = t.saveActFile(act .. '.bak', originalColors, #originalColors, true)
		end
		if not backedUp then
			return nil, err
		end
	end

	local saved
	saved, err = t.saveActFile(act, colors, #colors)
	if not saved then
		return nil, err
	end
	if needsEntry then
		saved, err = writeFile(def, defData)
		if not saved then
			local restored, restoreErr
			if existed then
				restored, restoreErr = writeFile(act, previousAct)
			else
				restored, restoreErr = os.remove(act)
			end
			if not restored then
				err = err .. '; ACT rollback failed: ' .. tostring(restoreErr)
			end
			return nil, err
		end
	end
	return act
end

-------------------------------------------------------------
-- Palette sources
-------------------------------------------------------------
function t.getPaletteSource(def, pal)
	local sff, err = t.getDefPath(def, 'sprite')
	if not sff then
		return nil, err or 'Character has no sprite file'
	end

	local version
	version, err = t.sffVersion(sff)
	if not version then
		return nil, err
	end

	local act
	act, err = t.getDefPath(def, 'pal' .. tostring(pal))
	if err then
		return nil, err
	end

	local source = {def = def, pal = pal, sff = sff, version = version, editable = true}
	if act or version[1] == 1 then
		source.kind, source.alpha = 'act', false
		source.path = act or t.resolveDefPath(def, 'color' .. tostring(pal) .. '.act')
		source.backup = source.path .. '.bak'
	elseif version[1] == 2 then
		local info
		info, err = nativeSff().inspect(sff, pal)
		if not info then
			return nil, err
		end
		source.kind, source.alpha, source.info = 'sff', version.alpha, info
		source.path = sff
		source.backup = sff .. '.colorEditor-pal' .. tostring(pal) .. '.bak'
		source.colors, source.editable, source.reason = info.colors, info.writable, info.reason
		-- Preserve the original palette snapshot.
		source.originalBackup = nativeSff().backup(info)
		if fileExists(source.backup) then
			local data, backupErr = readFile(source.backup)
			if data then
				local valid
				valid, backupErr = nativeSff().readBackup(info, data)
				if valid then
					source.originalBackup = data
				end
			end
			source.backupError = backupErr
		end
	else
		return nil, 'Unsupported SFF version'
	end
	return source
end

-------------------------------------------------------------
-- Preview palettes
-------------------------------------------------------------
function t.loadPreviewSff(source)
	-- Use an equivalent path to keep the preview SFF private.
	local path = source.sff:gsub('\\', '/'):gsub('([^/]+)$', './%1')
	return sffNew(path, true)
end

function t.newPalettePreview(sff, action, source, ref)
	local anim = animNew(sff, action)
	if source.kind ~= 'sff' then
		animLoadPalettes(anim, ref)
		anim = animPrepare(anim, ref)
		if not source.version or source.version[1] ~= 2 then
			anim = animSetColorPalette(anim, source.pal)
		end
	end
	-- Preserve native palette indices and apply preview colors to palette 1,1.
	animUpdate(anim)
	return anim
end

function t.updatePreviewPalette(anim, source, colors)
	local pal = source.pal
	local sffv2 = source.kind == 'sff' or source.version and source.version[1] == 2
	if sffv2 then
		-- ACTs also use the actual SFFv2 base palette for previewing.
		pal = 1
		local count = #animPaletteGet(anim, pal)
		local visible = {}
		for index, color in pairs(colors) do
			if index <= count then
				visible[index] = color
			end
		end
		colors = visible
	end
	animPaletteSet(anim, pal, colors)
	if not sffv2 then
		-- Restore the selected palette after writing.
		animSetColorPalette(anim, source.pal)
	end
end

-------------------------------------------------------------
-- Color highlight
-------------------------------------------------------------
function t.newPreviewHighlight(source, section)
	section = section or {}
	local enabled = section.enabled == true or tonumber(section.enabled) == 1
	local time = math.max(1, math.floor(tonumber(section.time) or 24))
	local fadeTime = math.max(0, math.floor(tonumber(section.fade and section.fade.time) or 0))
	local first = section.col or {255, 255, 255}
	local second = section.alt and section.alt.col or {0, 0, 0}
	local currentAnim, currentIndex, currentMarks
	local visible = {}
	local frame = 0
	local function differs(a, b)
		return a[1] ~= b[1] or a[2] ~= b[2] or a[3] ~= b[3] or a[4] ~= b[4]
	end

	local highlight = {}
	function highlight:clear(colors)
		if not currentAnim then
			return
		end

		local changes = {}
		for index, tint in pairs(visible) do
			if colors[index] and differs(tint, colors[index]) then
				changes[index] = colors[index]
			end
		end
		if next(changes) then
			t.updatePreviewPalette(currentAnim, source, changes)
		end
		currentAnim, currentIndex, currentMarks, visible, frame = nil, nil, nil, {}, 0
	end
	function highlight:update(anim, index, colors, active, marked)
		if not enabled or not active then
			self:clear(colors)
			return
		end

		local desired, hasMarks = {}, false
		for i, selected in pairs(marked or {}) do
			if selected and colors[i] and colors[i][4] ~= 0 then
				desired[i], hasMarks = true, true
			end
		end
		if colors[index] and colors[index][4] ~= 0 then
			desired[index] = true
		end
		if not next(desired) then
			self:clear(colors)
			return
		end
		if currentAnim ~= anim then
			self:clear(colors)
		elseif currentIndex ~= index and not currentMarks and not hasMarks then
			frame = 0
		end
		currentAnim, currentIndex, currentMarks = anim, index, hasMarks
		local duration = time + fadeTime
		local phase = math.floor(frame / duration)
		local elapsed = frame % duration
		local from, to = first, second
		if phase == 1 then
			from, to = second, first
		end

		local blend = fadeTime > 0 and math.max(0, elapsed - time + 1) / fadeTime or 0
		local tint = {}
		for channel = 1, 3 do
			tint[channel] = math.floor(from[channel] + (to[channel] - from[channel]) * blend + 0.5)
		end
		-- Upload one synchronized phase for all marked indices.
		local changes = {}
		for i, previous in pairs(visible) do
			if not desired[i] then
				if colors[i] and differs(previous, colors[i]) then
					changes[i] = colors[i]
				end
				visible[i] = nil
			end
		end
		for i in pairs(desired) do
			local color = {tint[1], tint[2], tint[3], colors[i][4]}
			if differs(visible[i] or colors[i], color) then
				changes[i] = color
			end
			visible[i] = color
		end
		if next(changes) then
			t.updatePreviewPalette(anim, source, changes)
		end
		frame = (frame + 1) % (duration * 2)
	end
	return highlight
end

-------------------------------------------------------------
-- Saving and restoration
-------------------------------------------------------------
function t.hasPaletteBackup(source)
	return fileExists(source.backup)
end

local function currentSff(source)
	local info, err = nativeSff().inspect(source.path, source.pal)
	if not info then
		return nil, err
	end
	if info.identity ~= source.info.identity or info.raw ~= source.info.raw then
		return nil, 'SFF changed outside the editor; reopen it before saving or restoring'
	end
	if not info.writable then
		return nil, info.reason
	end
	return info
end

function t.savePaletteSource(source, colors, originalColors, backupEnabled)
	if source.kind == 'act' then
		local act, err = t.savePalette(source.def, source.pal, colors, originalColors, backupEnabled)
		if not act then
			return nil, err
		end
		source.path, source.backup = act, act .. '.bak'
		return true
	end

	local info, err = currentSff(source)
	if not info then
		return nil, err
	end

	local raw
	raw, err = nativeSff().encode(info, colors)
	if not raw then
		return nil, err
	end
	if backupEnabled == true or tonumber(backupEnabled) == 1 then
		if fileExists(source.backup) then
			local data
			data, err = readFile(source.backup)
			if not data then
				return nil, err
			end

			local valid
			valid, err = nativeSff().readBackup(info, data)
			if not valid then
				return nil, err
			end
			source.originalBackup, source.backupError = data, nil
		else
			if source.backupError then
				return nil, source.backupError
			end

			local original = source.originalBackup
			local valid
			valid, err = nativeSff().readBackup(info, original)
			if not valid then
				return nil, err
			end

			local backedUp
			backedUp, err = writeFile(source.backup, original, true)
			if not backedUp then
				return nil, err
			end
		end
	end

	local saved
	saved, err = nativeSff().write(info, raw)
	if not saved then
		return nil, err
	end
	info.raw, info.colors = raw, nativeSff().decode(raw, source.alpha)
	source.info, source.colors = info, info.colors
	return true
end

local function decodeAct(data)
	local colors = {}
	for i = 1, 256 do
		colors[i] = {0, 0, 0, 0}
	end
	for i = 1, math.min(256, math.floor(#data / 3)) do
		local r, g, b = data:byte((i - 1) * 3 + 1, i * 3)
		colors[257 - i] = {r, g, b, i == 256 and 0 or 255}
	end
	return colors
end

local function finishRestore(source, colors, deleteBackup)
	if deleteBackup == true or tonumber(deleteBackup) == 1 then
		local removed, err = os.remove(source.backup)
		if not removed then
			return colors, 'Colors restored; cannot remove backup: ' .. tostring(err)
		end
	end
	return colors
end

function t.restorePaletteSource(source, deleteBackup)
	local data, err = readFile(source.backup)
	if not data then
		return nil, err
	end
	if source.kind == 'act' then
		if not (#data == 772 or (#data >= 3 and #data <= 768 and #data % 3 == 0)) then
			return nil, 'Invalid ACT palette backup'
		end
		-- Restore the saved ACT bytes before optionally removing the backup.
		local restored
		restored, err = writeFile(source.path, data)
		if not restored then
			return nil, err
		end
		return finishRestore(source, decodeAct(data), deleteBackup)
	end

	local info
	info, err = currentSff(source)
	if not info then
		return nil, err
	end

	local raw
	raw, err = nativeSff().readBackup(info, data)
	if not raw then
		return nil, err
	end

	local restored
	restored, err = nativeSff().write(info, raw)
	if not restored then
		return nil, err
	end
	info.raw, info.colors = raw, nativeSff().decode(raw, source.alpha)
	source.info, source.colors = info, info.colors
	return finishRestore(source, info.colors, deleteBackup)
end

-------------------------------------------------------------
-- Editor configuration
-------------------------------------------------------------

local editorMotif
local warned = {}

local function warn(message)
	if warned[message] then
		return
	end
	warned[message] = true
	local output = 'Color Editor: ' .. message
	if type(printConsole) == 'function' then
		printConsole(output)
	else
		print(output)
	end
end

local function copyConfig(value, seen)
	if type(value) ~= 'table' then
		return value
	end
	seen = seen or {}
	if seen[value] then
		return seen[value]
	end

	local result = {}
	seen[value] = result
	for key, entry in pairs(value) do
		result[key] = copyConfig(entry, seen)
	end
	return result
end

local function mergeConfig(base, overlay)
	for key, value in pairs(overlay or {}) do
		-- Replace lists and merge named sections.
		if type(value) == 'table' and type(base[key]) == 'table' and value[1] == nil and base[key][1] == nil then
			mergeConfig(base[key], value)
		else
			base[key] = copyConfig(value)
		end
	end
	return base
end

local function coords(section)
	local pair = section and section.localcoord
	if type(pair) == 'table' and tonumber(pair[1]) and tonumber(pair[2]) and tonumber(pair[1]) > 0 and tonumber(pair[2]) > 0 then
		return {tonumber(pair[1]), tonumber(pair[2])}
	end
	return editorMotif and editorMotif.info.localcoord or motif.info.localcoord
end

local function selectionTitle(section)
	local title = section and section.title
	if not title then
		return nil
	end
	if type(title.coloreditor) == 'table' then
		return title.coloreditor.text
	end
	if type(title.text) == 'table' then
		return title.text.coloreditor
	end
end

local function hasBackground(data)
	for key in pairs(data) do
		if key:match('^coloreditorbg_') or key:match('^coloreditorbgctrl') then
			return true
		end
	end
	return false
end

local function resourcePath(path, def)
	for _, candidate in ipairs({t.resolveDefPath(def, path), t.normpath(path), t.normpath('data/' .. path)}) do
		if fileExists(candidate) then
			return candidate
		end
	end
	return nil
end

function t.loadMotifExtensions(default, path)
	warned = {}
	default, path = t.normpath(default), t.normpath(path)
	local base = loadIni(default)
	local result = {info = copyConfig(base.info or {}), coloreditor_info = {}, coloreditorbgdef = {}}
	local language = tostring(gameOption('Config.Language')):lower()
	local bgPath, bgSprPath = path, path
	local function apply(data, def)
		for _, prefix in ipairs({'', language .. '.'}) do
			for _, key in ipairs({'coloreditor_info', 'coloreditorbgdef'}) do
				local section = data[prefix .. key]
				if section then
					mergeConfig(result[key], section)
					if key == 'coloreditorbgdef' and section.spr then
						bgSprPath = def
					end
				end
			end

			local text = selectionTitle(data[prefix .. 'select_info'])
			if text then
				result.select_title = text
			end
		end
		if hasBackground(data) then
			bgPath = def
		end
	end
	apply(base, default)
	if path ~= default then
		local extension = loadIni(path)
		mergeConfig(result.info, extension.info or {})
		apply(extension, path)
	end

	local systemDef = motif.def or motif.Def
	if type(systemDef) == 'string' and systemDef ~= '' then
		apply(loadIni(systemDef), systemDef)
	end
	-- Copy runtime overrides into the editor configuration.
	apply(motif, systemDef or path)
	local pair = result.coloreditor_info.localcoord or result.info.localcoord or {1280, 720}
	if type(pair) ~= 'table' or not tonumber(pair[1]) or not tonumber(pair[2]) or tonumber(pair[1]) <= 0 or tonumber(pair[2]) <= 0 then
		warn('Invalid editor localcoord; using 1280,720')
		pair = {1280, 720}
	end
	result.info.localcoord = {tonumber(pair[1]), tonumber(pair[2])}
	result.Sff, result.Fnt = motif.Sff, motif.Fnt
	result.AnimTable = {}
	if type(systemDef) == 'string' and systemDef ~= '' then
		local ok, actions = pcall(loadAnimTable, systemDef, result.Sff)
		if ok and type(actions) == 'table' then
			result.AnimTable = actions
		else
			warn('Cannot load screenpack animations: ' .. tostring(actions))
		end
	else
		warn('Screenpack DEF path is unavailable; system animations cannot be loaded')
	end

	local bg = result.coloreditorbgdef
	bg.Sff = motif.Sff
	if type(bg.spr) == 'string' and bg.spr ~= '' then
		local sprite = resourcePath(bg.spr, bgSprPath)
		if sprite then
			bg.Sff = sffNew(sprite)
		else
			warn('Background SFF not found: ' .. bg.spr .. '; using system SFF')
		end
	end
	bg.BGDef = bgNew(bg.Sff, bgPath, 'coloreditorbg', nil)
	result.select_title = result.select_title or result.coloreditor_info.title.text.text
	editorMotif = result
	return result
end

-------------------------------------------------------------
-- Graphics resources
-------------------------------------------------------------
function t.loadMotifAnim(section)
	local data = '-1,0, 0,0, -1'
	local anim
	local hasData = false

	if section.spr then
		local spr = type(section.spr) == 'table' and section.spr or {section.spr}
		local group, item = spr[1], spr[2]
		group = group or -1
		item = item or 0
		data = string.format('%s,%s, 0,0, -1', group, item)
		hasData = (tonumber(group) or -1) >= 0
	end
	if section.anim then
		local action = tonumber(section.anim)
		if action and action >= 0 then
			local actions = editorMotif and editorMotif.AnimTable or {}
			if actions[action] then
				data, hasData = actions[action], true
			else
				warn('Screenpack action ' .. action .. ' not found; using configured sprite or empty animation')
			end
		end
	end

	anim = animNew(editorMotif and editorMotif.Sff or motif.Sff, data)
	t.updateMotifAnim(anim, section)
	return anim, hasData
end

function t.updateMotifAnim(anim, section)
	local pair
	pair = section.scale or {1.0, 1.0}
	animSetScale(anim, pair[1], pair[2])
	local localcoord = coords(section)
	animSetLocalcoord(anim, localcoord[1], localcoord[2])
	animSetFacing(anim, section.facing or 1)
	animSetAngle(anim, section.angle or 0)
	animSetXAngle(anim, section.xangle or 0)
	animSetYAngle(anim, section.yangle or 0)
	animSetLayerno(anim, section.layerno or 0)
	pair = section.window or {0, 0, localcoord[1], localcoord[2]}
	animSetWindow(anim, pair[1], pair[2], pair[3], pair[4])
	animSetFocalLength(anim, section.focallength or 2048)
	animSetProjection(anim, section.projection or 'orthographic')
	return anim
end

-- Apply localcoord, portrait scale and CNS scale.
function t.previewScale(section, charData)
	local localcoord = tonumber(charData.localcoord) or 320
	if localcoord <= 0 then
		localcoord = 320
	end

	local cns = charData.cns_scale or {1, 1}
	local ratio = coords(section)[1] / localcoord * (tonumber(charData.portraitscale) or 1)
	return section.scale[1] * ratio * (tonumber(cns[1]) or 1), section.scale[2] * ratio * (tonumber(cns[2]) or 1)
end

-- Apply HSV adjustments to the entry snapshot to avoid rounding drift.
-- Preserve alpha and neutral grays.
function t.adjustHSV(color, degrees, saturation, value)
	saturation, value = saturation or 0, value or 0
	local r, g, b = color[1] / 255, color[2] / 255, color[3] / 255
	local high, low = math.max(r, g, b), math.min(r, g, b)
	local chroma = high - low
	if degrees % 360 == 0 and saturation == 0 and value == 0 then
		return {color[1], color[2], color[3], color[4]}
	end

	local hue = 0
	if chroma > 0 then
		if high == r then
			hue = (g - b) / chroma
		elseif high == g then
			hue = (b - r) / chroma + 2
		else
			hue = (r - g) / chroma + 4
		end
	end
	hue = (hue + degrees / 60) % 6
	local sat = high > 0 and chroma / high or 0
	sat = t.clamp(0, sat * (1 + saturation / 100), 1)
	high = t.clamp(0, high * (1 + value / 100), 1)
	chroma, low = high * sat, high * (1 - sat)
	local x = chroma * (1 - math.abs(hue % 2 - 1))
	if hue < 1 then
		r, g, b = chroma, x, 0
	elseif hue < 2 then
		r, g, b = x, chroma, 0
	elseif hue < 3 then
		r, g, b = 0, chroma, x
	elseif hue < 4 then
		r, g, b = 0, x, chroma
	elseif hue < 5 then
		r, g, b = x, 0, chroma
	else
		r, g, b = chroma, 0, x
	end
	-- Stabilize half-byte rounding after the floating-point HSV conversion.
	local rounding = 0.5 + 1e-9
	return {
		math.floor((r + low) * 255 + rounding),
		math.floor((g + low) * 255 + rounding),
		math.floor((b + low) * 255 + rounding),
		color[4],
	}
end

function t.textWindow(section)
	local localcoord = coords(section)
	return section.window or {0, 0, localcoord[1], localcoord[2]}
end

function t.loadMotifFont(section)
	local text = textImgNew()
	t.updateMotifFont(text, section)
	return text
end

function t.updateMotifFont(text, section)
	local pair
	local font
	pair = section.font or {-1, 0, 0, 255, 255, 255, -1}
	if type(pair) ~= 'table' then
		pair = {pair}
	end
	font = pair[1] or -1
	local fonts = editorMotif and editorMotif.Fnt or motif.Fnt
	local requested = tonumber(font) or -1
	font = fonts[requested]
	if not font and requested >= 0 then
		warn('Screenpack font ' .. requested .. ' not found; using font 1 when available')
		font = fonts[1]
	end
	if font then
		textImgSetFont(text, font)
	end
	textImgSetBank(text, pair[2] or 0)
	textImgSetAlign(text, pair[3] or 0)
	textImgSetColor(text, pair[4] or 255, pair[5] or 255, pair[6] or 255)
	local concat = section.text
	if type(concat) == 'table' then
		concat = table.concat(concat, ', ')
	end
	textImgSetText(text, concat or '')
	local localcoord = coords(section)
	textImgSetLocalcoord(text, localcoord[1], localcoord[2])
	textImgSetLayerno(text, section.layerno or 0)
	pair = section.offset or {0, 0}
	textImgSetPos(text, pair[1] or 0, pair[2] or 0)
	pair = section.scale or {1, 1}
	textImgSetScale(text, pair[1] or 1, pair[2] or 1)
	pair = section.textspacing or {0, 0}
	textImgSetTextSpacing(text, pair[1] or 0, pair[2] or 0)
	textImgSetAngle(text, section.angle or 0)
	textImgSetXShear(text, section.xshear or 0)
	textImgSetProjection(text, section.projection or 'orthographic')
	textImgSetFocalLength(text, section.focallength or 2048)
	pair = t.textWindow(section)
	textImgSetWindow(text, pair[1] or 0, pair[2] or 0, pair[3] or localcoord[1], pair[4] or localcoord[2])
	return text
end

function t.rectNew()
	local rect = rectNew()
	local localcoord = coords()
	rectSetLocalcoord(rect, localcoord[1], localcoord[2])
	return rect
end

return t
