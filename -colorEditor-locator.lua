-- Color Editor - Synchronized color locator.
local util = require('external.mods.colorEditor.-colorEditor-util')
local palettes = require('external.mods.colorEditor.-colorEditor-sffv2')
local t = {}

function t.new(source, sff, ref, section, charData)
	local sprites, err = palettes.previewSprites(source.sff)
	if not sprites then
		return nil, err
	end

	local scaleX, scaleY = util.previewScale(section, charData)
	local locator = {section = section}
	local anim, mask, baseColors, lastShared
	function locator:setAction(action)
		-- Reuse AIR timing and isolate palettes before applying the mask.
		anim = util.newPalettePreview(sff, action, source, ref)
		if not animPaletteCopy(anim) then
			return nil, 'Cannot isolate locator palettes'
		end
		util.updateMotifAnim(anim, section)
		animSetPos(anim, section.offset[1], section.offset[2])
		animSetScale(anim, scaleX, scaleY)
		animSetLayerno(anim, 2)
		baseColors = animPaletteGet(anim, source.kind == 'sff' and 1 or source.pal)
		mask, lastShared = {}, nil
		return true
	end
	function locator:draw(index, colors, active, marked)
		local desired = active and colors[index][4] ~= 0 and index or nil
		local changes = {}
		for i, baseColor in ipairs(baseColors) do
			local color = colors[i] or baseColor
			local col = section.col
			if i == desired then
				col = section.selected.col
			elseif active and marked and marked[i] and color[4] ~= 0 then
				col = section.marked.col
			end

			local old = mask[i]
			if not old or old[1] ~= col[1] or old[2] ~= col[2] or old[3] ~= col[3] or old[4] ~= color[4] then
				mask[i] = {col[1], col[2], col[3], color[4]}
				changes[i] = mask[i]
			end
		end
		if next(changes) then
			util.updatePreviewPalette(anim, source, changes)
		end
		animUpdate(anim)
		local info = animGetSpriteInfo(anim)
		local metadata = info and sprites[info.Group .. ',' .. info.Number]
		-- SFFv2 keeps physical palette indices when using ACTs.
		local shared = metadata and metadata.shared
			and (source.kind == 'sff' or source.version and source.version[1] == 2 or info.palidx == 0) or false
		if shared ~= lastShared then
			-- Darken unique palettes and truecolor sprites.
			animSetPalFX(
				anim,
				{time = -1, color = shared and 256 or 0, mul = shared and {256, 256, 256} or section.col, add = {0, 0, 0}}
			)
			lastShared = shared
		end
		animDraw(anim, 2)
	end
	return locator
end

return t
