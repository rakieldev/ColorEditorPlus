-- Color Editor - SFFv2 palettes and preview metadata.
local t = {}
-- Backup format version 1. Preserve compatibility with existing backups.
local backupMagic = 'IKCEPAL\1'

-------------------------------------------------------------
-- Binary helpers
-------------------------------------------------------------
local function check(value, message)
	if not value then
		error(message, 0)
	end
	return value
end

local function read(file, size)
	local data = file:read(size)
	check(data and #data == size, 'Truncated SFF or palette backup')
	return data
end

local function uint(data, offset, size)
	local value = 0
	check(offset + size <= #data, 'Truncated integer')
	for i = offset + size, offset + 1, -1 do
		value = value * 256 + data:byte(i)
	end
	return value
end

local function pack(value, size)
	local bytes = {}
	for i = 1, size do
		bytes[i] = string.char(value % 256)
		value = math.floor(value / 256)
	end
	return table.concat(bytes)
end

-- Structural palette identity checksum.
local function checksum(data, value)
	value = value or 0
	for i = 1, #data do
		value = (value * 65599 + data:byte(i)) % 4294967296
	end
	return value
end

local function withFile(path, action)
	local file, err = io.open(path, 'rb')
	if not file then
		return nil, 'Cannot open ' .. path .. ': ' .. tostring(err)
	end

	local ok, result = pcall(action, file)
	local closed, closeErr = file:close()
	if not ok then
		return nil, tostring(result)
	end
	if not closed then
		return nil, tostring(closeErr)
	end
	return result
end

-------------------------------------------------------------
-- SFF metadata
-------------------------------------------------------------
local function version(header)
	check(header:sub(1, 12) == 'ElecbyteSpr\0', 'Invalid SFF signature')
	local v = {header:byte(16), header:byte(15), header:byte(14), header:byte(13)}
	v.raw = header:sub(13, 16)
	-- Display SFF 2.0.1.0 as 2.01.
	v.label = v[1] .. '.' .. v[2]
	if v[1] == 2 then
		v.label = v.label .. v[3]
	end
	v.alpha = v[1] == 2 and v[3] ~= 0
	return v
end

function t.version(path)
	return withFile(path, function(file)
		return version(read(file, 16))
	end)
end

-- Classify shared and unique palettes from sprite headers.
function t.previewSprites(path)
	return withFile(path, function(file)
		local header = read(file, 68)
		local v = version(header)
		check(v[1] == 1 or v[1] == 2, 'Unsupported SFF for locator')
		local size = check(file:seek('end'), 'Cannot determine SFF size')
		local roots, base = {}, nil
		if v[1] == 2 then
			local offset, count = uint(header, 44, 4), uint(header, 48, 4)
			check(offset >= 68 and offset + count * 16 <= size, 'Invalid SFF palette table')
			check(file:seek('set', offset), 'Cannot read SFF palettes')
			local entries = count > 0 and read(file, count * 16) or ''
			for i = 1, count do
				local entry = entries:sub((i - 1) * 16 + 1, i * 16)
				if uint(entry, 12, 4) == 0 then
					roots[i] = check(roots[uint(entry, 6, 2) + 1], 'Invalid SFF palette link')
				else
					roots[i] = i
				end
				if uint(entry, 0, 2) == 1 and uint(entry, 2, 2) == 1 and not base then
					base = roots[i]
				end
			end
		end

		local offset = uint(header, v[1] == 1 and 24 or 36, 4)
		local count = uint(header, v[1] == 1 and 20 or 40, 4)
		local length = v[1] == 1 and 32 or 28
		check(count <= size / length, 'Invalid SFF sprite count')
		local entries
		if v[1] == 2 then
			check(offset >= 68 and offset + count * length <= size, 'Invalid SFF sprite table')
			check(file:seek('set', offset), 'Cannot read SFF sprites')
			entries = count > 0 and read(file, count * length) or ''
		end

		local sprites, records, visited, previous = {}, {}, {}, nil
		for i = 1, count do
			-- String keys keep sparse SFFv1 offsets out of the Lua array.
			local offsetKey = tostring(offset)
			check(offset >= 68 and offset + length <= size and not visited[offsetKey], 'Invalid SFF sprite table')
			visited[offsetKey] = true
			local entry
			if entries then
				entry = entries:sub((i - 1) * length + 1, i * length)
			else
				check(file:seek('set', offset), 'Cannot read SFF sprite')
				entry = read(file, length)
			end

			local group = uint(entry, v[1] == 1 and 12 or 0, 2)
			local number = uint(entry, v[1] == 1 and 14 or 2, 2)
			local node = {depth = 8}
			if v[1] == 1 then
				if uint(entry, 4, 4) == 0 then
					local linked = check(records[uint(entry, 16, 2) + 1], 'Invalid SFF sprite link')
					node.root = linked.root
				else
					node.root = entry:byte(19) ~= 0 and previous or i
					previous = node.root
				end
				if group == 0 and number == 0 then
					base = node.root
				end
				offset = uint(entry, 0, 4)
			else
				node.depth = entry:byte(16)
				if uint(entry, 20, 4) == 0 then
					node.depth = check(records[uint(entry, 12, 2) + 1], 'Invalid SFF sprite link').depth
				end
				node.root = roots[uint(entry, 24, 2) + 1]
				offset = offset + length
			end
			records[i] = node
			local key = group .. ',' .. number
			if not sprites[key] then
				sprites[key] = node
			end
		end
		for _, node in pairs(sprites) do
			node.shared = base ~= nil and node.root == base and node.depth <= 8
		end
		return sprites
	end)
end

-------------------------------------------------------------
-- Palette data
-------------------------------------------------------------
function t.decode(raw, alpha)
	local colors = {}
	for i = 1, #raw / 4 do
		local r, g, b, a = raw:byte((i - 1) * 4 + 1, i * 4)
		if not alpha then
			a = i == 1 and 0 or 255
		end
		colors[i] = {r, g, b, a}
	end
	return colors
end

function t.inspect(path, pal)
	return withFile(path, function(file)
		local header = read(file, 68)
		local v = version(header)
		check(v[1] == 2, 'Native palette editing requires SFFv2')
		local size = check(file:seek('end'), 'Cannot determine SFF size')
		check(size <= 4294967295, 'SFF larger than supported 32-bit offsets')
		local spriteOffset, spriteCount = uint(header, 36, 4), uint(header, 40, 4)
		local paletteOffset, paletteCount = uint(header, 44, 4), uint(header, 48, 4)
		local ldata, lsize = uint(header, 52, 4), uint(header, 56, 4)
		check(spriteOffset >= 68 and spriteOffset + spriteCount * 28 <= size, 'Invalid SFF sprite table')
		check(paletteOffset >= 68 and paletteOffset + paletteCount * 16 <= size, 'Invalid SFF palette table')
		check(ldata >= 68 and ldata + lsize <= size, 'Invalid SFF local data block')
		check(file:seek('set', spriteOffset), 'Cannot read SFF sprite table')
		local sprites = spriteCount > 0 and read(file, spriteCount * 28) or ''
		check(file:seek('set', paletteOffset), 'Cannot read SFF palette table')
		local palettes = paletteCount > 0 and read(file, paletteCount * 16) or ''
		local nodes, target = {}, nil
		for i = 1, paletteCount do
			local offset = (i - 1) * 16
			local node = {
				group = uint(palettes, offset, 2),
				number = uint(palettes, offset + 2, 2),
				link = uint(palettes, offset + 6, 2) + 1,
				offset = uint(palettes, offset + 8, 4),
				size = uint(palettes, offset + 12, 4),
			}
			if node.size == 0 then
				check(node.link < i, 'Invalid or forward-linked SFF palette')
			else
				check(node.offset + node.size <= lsize, 'SFF palette outside local data block')
			end
			nodes[i] = node
			if node.group == 1 and node.number == pal then
				check(not target, 'Duplicate selectable SFF palette identifier')
				target = i
			end
		end
		check(target, 'SFF palette 1,' .. tostring(pal) .. ' not found')
		local function resolve(index)
			while nodes[index].size == 0 do
				index = nodes[index].link
			end
			return nodes[index]
		end

		local node = resolve(target)
		check(node.size >= 4 and node.size <= 1024 and node.size % 4 == 0, 'Unsupported SFF palette size')
		local offset = ldata + node.offset
		-- Check palette data against the headers and tables.
		local function overlaps(start, length)
			return length > 0 and offset < start + length and start < offset + node.size
		end
		check(
			not overlaps(0, 68) and not overlaps(spriteOffset, #sprites) and not overlaps(paletteOffset, #palettes),
			'SFF palette overlaps structural data'
		)
		local tdata = uint(header, 60, 4)
		for i = 0, spriteCount - 1 do
			local entry = i * 28
			local length = uint(sprites, entry + 20, 4)
			local base = uint(sprites, entry + 26, 2) % 2 == 1 and tdata or ldata
			local start = base + uint(sprites, entry + 16, 4)
			check(not overlaps(start, length), 'SFF palette overlaps sprite pixels')
		end
		check(file:seek('set', offset), 'Cannot read SFF palette')
		local raw = read(file, node.size)
		local info =
			{path = path, pal = pal, version = v, size = size, offset = offset, raw = raw, count = node.size / 4, writable = true}
		info.identity = checksum(palettes, checksum(sprites, checksum(header .. pack(size, 4))))
		if v[2] ~= 0 or v[3] > 1 or v[4] ~= 0 then
			info.writable, info.reason = false, 'Unsupported SFF revision for native writing'
		elseif nodes[target].size == 0 then
			info.writable, info.reason = false, 'Linked SFF palettes are not writable yet'
		else
			for i = 1, #nodes do
				if i ~= target then
					local other = resolve(i)
					if node.offset < other.offset + other.size and other.offset < node.offset + node.size then
						info.writable, info.reason = false, 'Shared SFF palettes are not writable yet'
						break
					end
				end
			end
		end
		info.colors = t.decode(raw, v.alpha)
		return info
	end)
end

function t.encode(info, colors)
	if not info.writable then
		return nil, info.reason
	end
	if type(colors) ~= 'table' or #colors ~= info.count then
		return nil, 'SFF palette color count changed'
	end

	local bytes = {}
	for i = 1, info.count do
		local color = colors[i]
		for channel = 1, (info.version.alpha and 4 or 3) do
			local value = type(color) == 'table' and color[channel] or nil
			if type(value) ~= 'number' or value < 0 or value > 255 or value % 1 ~= 0 then
				return nil, 'Invalid palette channel at index ' .. i
			end
		end
		-- Preserve the unused/reserved alpha byte in SFFv2.00.
		local alpha = info.version.alpha and color[4] or info.raw:byte(i * 4)
		bytes[i] = string.char(color[1], color[2], color[3], alpha)
	end
	return table.concat(bytes)
end

-------------------------------------------------------------
-- Palette backups
-------------------------------------------------------------
function t.backup(info)
	local data = backupMagic
		.. info.version.raw
		.. pack(info.identity, 4)
		.. pack(info.size, 4)
		.. pack(info.pal, 2)
		.. pack(info.count, 2)
		.. info.raw
	return data .. pack(checksum(data), 4)
end

function t.readBackup(info, data)
	if #data ~= 28 + info.count * 4 or data:sub(1, 8) ~= backupMagic then
		return nil, 'Invalid SFF palette backup format or color count'
	end
	if
		data:sub(9, 12) ~= info.version.raw
		or uint(data, 12, 4) ~= info.identity
		or uint(data, 16, 4) ~= info.size
		or uint(data, 20, 2) ~= info.pal
		or uint(data, 22, 2) ~= info.count
	then
		return nil, 'Palette backup belongs to a different SFF structure or palette'
	end
	if uint(data, #data - 4, 4) ~= checksum(data:sub(1, -5)) then
		return nil, 'Corrupted SFF palette backup'
	end
	return data:sub(25, -5)
end

-------------------------------------------------------------
-- Palette writing
-------------------------------------------------------------
function t.write(info, raw)
	if not info.writable then
		return nil, info.reason
	end
	if #raw ~= #info.raw then
		return nil, 'SFF palette byte count changed'
	end

	local fresh, err = t.inspect(info.path, info.pal)
	if not fresh then
		return nil, err
	end
	if fresh.identity ~= info.identity or fresh.raw ~= info.raw then
		return nil, 'SFF changed during palette editing; reopen the editor'
	end

	local temporary = info.path .. '.coloreditor.tmp'
	if fileExists(temporary) then
		return nil, 'Temporary file already exists: ' .. temporary
	end

	local source, openErr = io.open(info.path, 'rb')
	if not source then
		return nil, tostring(openErr)
	end

	local output, outErr = io.open(temporary, 'wb')
	if not output then
		source:close()
		return nil, tostring(outErr)
	end
	-- Stream the SFF through the temporary file.
	local writeErr
	local remaining = info.size
	while remaining > 0 do
		local size = math.min(remaining, 1048576)
		local chunk, readErr = source:read(size)
		if not chunk or #chunk ~= size then
			writeErr = readErr or 'SFF size changed during writing'
			break
		end

		local written, err = output:write(chunk)
		if not written then
			writeErr = err or 'Cannot write temporary SFF'
			break
		end
		remaining = remaining - #chunk
	end
	if not writeErr and source:read(1) then
		writeErr = 'SFF size changed during writing'
	end
	if not writeErr then
		local offset, seekErr = output:seek('set', info.offset)
		if not offset then
			writeErr = seekErr or 'Cannot seek to SFF palette'
		end
	end
	if not writeErr then
		local written, err = output:write(raw)
		if not written then
			writeErr = err or 'Cannot write SFF palette'
		end
	end

	local sourceClosed, sourceErr = source:close()
	local outputClosed, closeErr = output:close()
	if writeErr or not sourceClosed or not outputClosed then
		os.remove(temporary)
		return nil, tostring(writeErr or sourceErr or closeErr)
	end

	local verified, verifyErr = t.inspect(temporary, info.pal)
	if not verified or verified.identity ~= info.identity or verified.raw ~= raw then
		os.remove(temporary)
		return nil, verifyErr or 'Temporary SFF palette verification failed'
	end

	local renamed, renameErr = os.rename(temporary, info.path)
	if not renamed then
		os.remove(temporary)
		return nil, tostring(renameErr)
	end
	return true
end

return t
