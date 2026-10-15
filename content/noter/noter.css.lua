local stylesheet = require "::/gui/main/stylesheetutil.lua"
local colorUtil = require "::/gui/main/color_util.tl"

function data()
	local result = {}
	local add = stylesheet.makeAdder(result)
	local scope = "Window#noter.notebook "
	local width = 640
	local contentPadding = 12
	local contentWidth = width - 2 * contentPadding
	local colors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data
	add("Window#noter.notebook", {minSize = {width, -1}, maxSize = {width, -1}})
	add(scope .. "!noter-content", {
		padding = {contentPadding, contentPadding, contentPadding, contentPadding}, innerSpacing = {8, 8},
	})
	add(scope .. "!noter-list", {minSize = {contentWidth, 180}, maxSize = {contentWidth, 450}})
	add(scope .. "!noter-rows", {innerSpacing = {0, 0}})
	add(scope .. "!noter-row", {
		padding = {6, 6, 6, 6}, innerSpacing = {4, 4},
		borderWidth = {0, 0, 0, 1}, borderColor = colorUtil.withTransparencyRaw(colors.NeutralMedium, 0.25),
	})
	add(scope .. "!noter-row:hover", {backgroundColor1 = colorUtil.withTransparencyRaw(colors.NeutralLightest, 0.04)})
	add(scope .. "!noter-selected", {backgroundColor1 = colorUtil.withTransparencyRaw(colors.AccentMedium, 0.12)})
	add(scope .. "!noter-completed TextView!noter-text", {color = colorUtil.withTransparencyRaw(colors.NeutralLightest, 0.55)})
	add(scope .. "!noter-line", {innerSpacing = {6, 6}})
	add(scope .. "!noter-text", {minSize = {500, -1}, maxSize = {500, -1}})
	add(scope .. "!noter-task-button", {padding = {0, 0, 0, 0}, margin = {0, 0, 0, 0}})
	add(scope .. "!noter-input", {minSize = {440, -1}, maxSize = {440, -1}})
	add(scope .. "!noter-edit-input", {minSize = {320, -1}, maxSize = {320, -1}})
	add(scope .. "!noter-icon", {size = {18, 18}})
	add(scope .. "!noter-icon-button", {padding = {3, 3, 3, 3}})
	add(scope .. "!noter-hint", {
		size = {contentWidth, -1}, textAlignment = {0.5, 0.5}, textAutoWrap = true,
		color = colorUtil.withTransparencyRaw(colors.NeutralLightest, 0.65),
	})
	add("R::NoterButton ToggleButton!noter-toolbar", {
		size = {32, 32}, padding = {4, 4, 4, 4}, margin = {1, 1, 1, 1},
	})
	return result
end
