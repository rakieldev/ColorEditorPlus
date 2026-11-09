-- Color Editor - Palette grid and controls.
local util = require('external.mods.colorEditor.-colorEditor-util')
local t = {}

-------------------------------------------------------------
-- Helpers
-------------------------------------------------------------
local function binding(keys)
	local names = {U = 'Up', D = 'Down', B = 'Left', F = 'Right', s = 'Start'}
	if type(keys) ~= 'table' then
		keys = {keys}
	end

	local result = {}
	for _, key in ipairs(keys) do
		result[#result + 1] = names[key] or tostring(key):upper()
	end
	return table.concat(result, '/')
end

local function tweenStep(value, target, factor)
	local nextValue = value + (target - value) * math.min(factor, 1)
	if math.abs(nextValue - target) < 1 then
		return target
	end
	return nextValue
end

-- Text labels
local function label(section)
	local sprite = util.loadMotifFont(section)
	local result = {value = nil, offset = section.offset}
	textImgSetLayerno(sprite, 2)
	local wrap = tostring(section.textwrap) == 'w' or tostring(section.textwrap) == '1'
	textImgSetTextWrap(sprite, wrap)
	function result:set(value)
		value = tostring(value or '')
		if self.value == value then
			return
		end
		self.value = value
		textImgSetText(sprite, value)
	end
	function result:draw(value, offset)
		self:set(value)
		if offset and (self.x ~= offset[1] or self.y ~= offset[2]) then
			textImgSetPos(sprite, offset[1], offset[2])
			self.x, self.y = offset[1], offset[2]
		end
		textImgDraw(sprite, 2)
	end
	return result
end

-------------------------------------------------------------
-- Editor interface
-------------------------------------------------------------
function t.new(m, cols, rows)
	local ui = {rects = {}, labels = {}}
	local multi = m.multicolor and (m.multicolor.enabled == true or tonumber(m.multicolor.enabled) == 1)
	local actionNames = {'copy', 'paste', 'reset'}
	if multi then
		actionNames[4], actionNames[5] = 'adjust', 'clear'
		ui.labels.multicolor = label(m.multicolor.text)
		for _, name in ipairs({'hue', 'saturation', 'value'}) do
			ui.labels[name] = label(m.slider[name].text)
		end
	end
	for _, name in ipairs({
		'title',
		'character',
		'format',
		'index',
		'save',
		'help',
		'warning',
		'restore',
		'yes',
		'yes.active',
		'no',
		'no.active',
		'before',
		'after',
	}) do
		local section
		if name == 'yes.active' then
			section = m.yes.active.text
		elseif name == 'no.active' then
			section = m.no.active.text
		else
			section = m[name].text
		end
		ui.labels[name] = label(section)
	end
	for _, name in ipairs({'r', 'g', 'b', 'a'}) do
		ui.labels[name] = label(m.slider[name].text)
	end
	ui.labels['actions.title'] = label(m.actions.title.text)
	for i, name in ipairs(actionNames) do
		for _, style in ipairs({'normal', 'active', 'disabled'}) do
			local section = {}
			for key, value in pairs(m.actions.item.text) do
				section[key] = value
			end
			if style ~= 'normal' then
				for key, value in pairs(m.actions.item[style].text) do
					section[key] = value
				end
			end
			section.offset = {
				section.offset[1] + (i - 1) * m.actions.item.spacing[1],
				section.offset[2] + (i - 1) * m.actions.item.spacing[2],
			}
			ui.labels['actions.' .. name .. '.' .. style] = label(section)
		end
	end

	local function optionalAnim(section)
		local spr = section.spr
		local group = type(spr) == 'table' and spr[1] or spr
		if (tonumber(section.anim) or -1) >= 0 or (tonumber(group) or -1) >= 0 then
			local anim, hasData = util.loadMotifAnim(section)
			if hasData == false then
				return
			end
			animSetLayerno(anim, 2)
			return anim
		end
	end

	local customCursor = optionalAnim(m.cell.cursor)
	local cursorX, cursorY
	local tween = m.cell.cursor.tween or {}
	local factors = tween.factor or {0, 0}
	if type(factors) ~= 'table' then
		factors = {factors, factors}
	end

	local factorX = tonumber(factors[1]) or 0
	local factorY = tonumber(factors[2]) or factorX
	local wrapSnap = tween.wrap and (tween.wrap.snap == true or tonumber(tween.wrap.snap) == 1)
	local customMarker
	if multi then
		customMarker = optionalAnim(m.multicolor.marker)
	end

	local function rect(id, x, y, w, h, color, alpha)
		if w <= 0 or h <= 0 then
			return
		end

		local r = ui.rects[id]
		if not r then
			r = util.rectNew()
			rectSetLayerno(r, 2)
			ui.rects[id] = r
		end
		rectSetWindow(r, x, y, x + w, y + h)
		rectSetColor(r, color[1], color[2], color[3])
		rectSetAlpha(r, alpha or 255, 255 - (alpha or 255))
		rectUpdate(r)
		rectDraw(r, 2)
	end

	local function border(id, x, y, w, h, color, thickness)
		local n = thickness or 1
		rect(id .. 't', x - n, y - n, w + 2 * n, n, color)
		rect(id .. 'b', x - n, y + h, w + 2 * n, n, color)
		rect(id .. 'l', x - n, y, n, h, color)
		rect(id .. 'r', x + w, y, n, h, color)
	end

	local function panel(name)
		local p = m.panel[name]
		rect(name, p.offset[1], p.offset[2], p.size[1], p.size[2], p.col, p.alpha)
		border(name, p.offset[1], p.offset[2], p.size[1], p.size[2], m.panel.border.col)
	end

	local function swatch(id, x, y, w, h, color)
		if color[4] < 255 then
			rect(id .. 'base', x, y, w, h, m.cell.checker.dark)
			rect(id .. 'check1', x, y, w / 2, h / 2, m.cell.checker.light)
			rect(id .. 'check2', x + w / 2, y + h / 2, w / 2, h / 2, m.cell.checker.light)
		end
		rect(id, x, y, w, h, color, color[4])
	end
	function ui:drawPreview()
		panel('preview')
	end
	function ui:draw(state)
		panel('palette')
		local sx, sy = m.cell.size[1], m.cell.size[2]
		local gap = m.cell.spacing
		local gx, gy = m.pos[1] + m.cell.offset[1], m.pos[2] + m.cell.offset[2]
		for y = 1, rows do
			for x = 1, cols do
				local index = (y - 1) * cols + x
				local color = state.colors[index]
				if color then
					local cx, cy = gx + (x - 1) * (sx + gap[1]), gy + (y - 1) * (sy + gap[2])
					swatch('cell' .. index, cx, cy, sx, sy, color)
					if multi and not customMarker and state.marked and state.marked[index] then
						border('marked' .. index, cx + 2, cy + 2, sx - 4, sy - 4, m.multicolor.marker.col, m.multicolor.marker.width)
					end
				end
			end
		end
		if customMarker and state.marked then
			local updated = false
			for index, marked in pairs(state.marked) do
				if marked and state.colors[index] then
					-- Advance once per frame to synchronize all markers.
					if not updated then
						animUpdate(customMarker)
						updated = true
					end

					local cx = gx + ((index - 1) % cols) * (sx + gap[1])
					local cy = gy + math.floor((index - 1) / cols) * (sy + gap[2])
					animSetPos(customMarker, cx + m.multicolor.marker.offset[1], cy + m.multicolor.marker.offset[2])
					animDraw(customMarker, 2)
				end
			end
		end

		local x = gx + (state.column - 1) * (sx + gap[1])
		local y = gy + (state.row - 1) * (sy + gap[2])
		if cursorX == nil or state.mode ~= 1 or (wrapSnap and state.cursorWrapped) or factorX <= 0 or factorY <= 0 then
			cursorX, cursorY = x, y
		else
			cursorX = tweenStep(cursorX, x, factorX)
			cursorY = tweenStep(cursorY, y, factorY)
		end
		x, y = cursorX, cursorY
		if customCursor then
			animSetPos(customCursor, x + m.cell.cursor.offset[1], y + m.cell.cursor.offset[2])
			animUpdate(customCursor)
			animDraw(customCursor, 2)
		else
			border('cursor.shadow', x - 1, y - 1, sx + 2, sy + 2, m.cell.cursor.shadow.col, m.cell.cursor.width + 1)
			border(
				'cursor',
				x,
				y,
				sx,
				sy,
				(state.mode == 2 or state.mode == 5) and m.cell.cursor.edit.col or m.cell.cursor.col,
				m.cell.cursor.width
			)
		end
		self.labels.index:draw(string.format(m.index.text.text, state.index - 1, #state.colors - 1))
		if multi and (state.markedCount or 0) > 0 then
			self.labels.multicolor:draw(string.format(m.multicolor.text.text, state.markedCount))
		end
		for _, name in ipairs({'before', 'after'}) do
			local s = m[name]
			local color = name == 'before' and state.saved[state.index] or state.colors[state.index]
			swatch(name, s.swatch.offset[1], s.swatch.offset[2], s.swatch.size[1], s.swatch.size[2], color)
			self.labels[name]:draw(s.text.text)
		end

		local sliders = state.mode == 5 and {'hue', 'saturation', 'value'} or {'r', 'g', 'b', 'a'}
		for i, name in ipairs(sliders) do
			if state.mode == 5 or i <= state.channels then
				local s = m.slider[name]
				local value = state.mode == 5 and state.adjustment[i] or state.colors[state.index][i]
				local limit = i == 1 and 180 or 100
				local fraction = state.mode == 5 and (value + limit) / (2 * limit) or value / 255
				local xPos, yPos = m.pos[1] + s.offset[1], m.pos[2] + s.offset[2]
				rect(name .. 'track', xPos, yPos, s.size[1], s.size[2], m.slider.track.col)
				rect(name .. 'fill', xPos, yPos, s.size[1] * fraction, s.size[2], s.col)
				if (state.mode == 5 or state.mode == 2) and i == state.channel then
					border('slider.cursor', xPos, yPos, s.size[1], s.size[2], m.cell.cursor.edit.col, 2)
				end

				local indicator = m.slider.indicator
				local valuePos = xPos + s.size[1] * fraction
				rect(
					name .. 'indicator',
					valuePos - indicator.size[1] / 2,
					yPos + (s.size[2] - indicator.size[2]) / 2,
					indicator.size[1],
					indicator.size[2],
					indicator.col
				)
				self.labels[name]:draw(string.format(s.text.text, value))
			end
		end
		self.labels.title:draw(m.title.text.text)
		self.labels.character:draw(string.format(m.character.text.text, state.name, state.pal))
		self.labels.format:draw(state.format)
		panel('status')
		self.labels.save:draw(state.feedback or (state.changed and m.save.pending.text or m.save.idle.text))
		local help
		if state.mode == 4 then
			help = string.format(
				m.help.actions.text,
				binding(m.actions.up.key) .. '/' .. binding(m.actions.down.key),
				binding(m.actions.confirm.key),
				binding(m.actions.cancel.key)
			)
		elseif state.mode == 5 then
			help = string.format(
				m.help.multicolor.edit.text,
				binding(m.slider.prev.key) .. '/' .. binding(m.slider.next.key),
				binding(m.slider.decrease.key) .. '/' .. binding(m.slider.increase.key),
				binding(m.cell.confirm.key),
				binding(m.cell.cancel.key)
			)
		elseif state.adjusting then
			help = string.format(
				m.help.preview.text,
				binding(m.preview.adjust.key),
				binding(m.preview.move.up.key)
					.. '/'
					.. binding(m.preview.move.down.key)
					.. '/'
					.. binding(m.preview.move.back.key)
					.. '/'
					.. binding(m.preview.move.fwd.key),
				binding(m.preview.zoom.decrease.key) .. '/' .. binding(m.preview.zoom.increase.key),
				binding(m.preview.reset.key)
			)
		elseif state.browsing then
			help = string.format(
				m.help.animation.text,
				binding(m.preview.browse.key),
				binding(m.preview.prev.key) .. '/' .. binding(m.preview.next.key)
			)
		elseif state.mode == 0 or state.mode == 0.75 then
			help = string.format(m.help.confirm.text, binding(m.warning.switch.key), binding(m.warning.confirm.key))
		elseif state.mode == 2 then
			help = string.format(
				m.help.edit.text,
				binding(m.slider.prev.key) .. '/' .. binding(m.slider.next.key),
				binding(m.slider.decrease.key) .. '/' .. binding(m.slider.increase.key),
				binding(m.cell.confirm.key),
				binding(m.cell.cancel.key)
			)
		else
			local mark = multi and string.format(m.help.multicolor.text, binding(m.multicolor.key)) or ''
			help = string.format(
				m.help.select.text,
				binding(m.cell.select.key),
				binding(m.actions.key),
				binding(m.preview.adjust.key),
				binding(m.preview.browse.key),
				mark,
				binding(m.restore.key),
				binding(m.save.key)
			)
		end
		if state.mode == 0 or state.mode == 0.75 or state.mode == 4 then
			local p = m.panel.darken
			rect('darken', p.offset[1], p.offset[2], p.size[1], p.size[2], p.col, p.alpha)
			panel('dialog')
			if state.mode == 4 then
				self.labels['actions.title']:draw(m.actions.title.text.text)
				for i, name in ipairs(actionNames) do
					if i <= 3 or (state.markedCount or 0) > 0 then
						local active = state.action == i
						local disabled = (i == 2 and not state.canPaste) or ((i == 3 or i == 4) and not state.editable)
						local style = disabled and 'disabled' or active and 'active' or 'normal'
						local text = m.actions[name].text.text
						if active then
							text = string.format(m.actions.item.active.text.text, text)
						end

						local spacing = (state.markedCount or 0) > 0 and m.actions.multicolor.item.spacing or m.actions.item.spacing
						local item = self.labels['actions.' .. name .. '.' .. style]
						local offset = item.offset
						item:draw(
							text,
							{
								offset[1] + (i - 1) * (spacing[1] - m.actions.item.spacing[1]),
								offset[2] + (i - 1) * (spacing[2] - m.actions.item.spacing[2]),
							}
						)
					end
				end
			else
				local prompt = state.mode == 0 and 'warning' or 'restore'
				self.labels[prompt]:draw(m[prompt].text.text)
				for i, name in ipairs({'yes', 'no'}) do
					local active = state.choice == i
					local key = name .. (active and '.active' or '')
					self.labels[key]:draw(active and m[name].active.text.text or m[name].text.text)
				end
			end
		end
		self.labels.help:draw(help)
	end
	return ui
end

return t
