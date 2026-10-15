local stylesheet = require "::/gui/main/stylesheetutil.lua"
local colorUtil = require "::/gui/main/color_util.tl"

function data()
	local result = {}
	local add = stylesheet.makeAdder(result)
	local windowSelector = "Window#noter.notebook"
	local scope = windowSelector .. " "
	local expandedSelector = windowSelector .. "!window-expanded"
	local width = 640
	local contentPadding = 12
	local iconSize = 18
	local iconButtonPadding = 3
	local pinColumnWidth = iconSize + 2 * iconButtonPadding
	local textWidth = 500
	local previewHeight = 80
	local colors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data
	add(windowSelector, {size = {width, -1}, minSize = {width, -1}, maxSize = {width, -1}})
	add(windowSelector .. "!noter-opaque", {backgroundColor1 = colorUtil.withTransparencyRaw(colors.BaseDarkMedium, 1)})
	add(expandedSelector, {size = {"75vw", "80vh"}, maxSize = {"90vw", "85vh"}})
	add(expandedSelector .. " Window::Content", {gravity = {-1, -1}})
	-- The native header precedes the title; our full-width header places resize beside the native controls.
	add(scope .. "Window::Title, " .. scope .. "Window::TitleLayout > !title-scroll", {visibility = "none"})
	add(scope .. "!noter-header", {gravity = {-1, 0}, innerSpacing = {4, 4}})
	add(scope .. "!noter-title", {
		gravity = {-1, 0}, minSize = {0, -1}, margin = {4, 4, 4, 4}, padding = {4, 4, 4, 4},
		textAlignment = {0, 0.5},
	})
	add(scope .. "!noter-content", {
		padding = {contentPadding, contentPadding, contentPadding, contentPadding}, innerSpacing = {8, 8},
		gravity = {-1, -1},
	})
	add(scope .. "!noter-list", {minSize = {0, 180}, maxSize = {-1, 450}, gravity = {-1, -1}})
	add(expandedSelector .. " !noter-list", {maxSize = {-1, -1}})
	add(scope .. "!noter-rows", {innerSpacing = {0, 0}, gravity = {-1, 0}})
	add(scope .. "!noter-row", {
		padding = {6, 6, 6, 6}, innerSpacing = {4, 4},
		borderWidth = {0, 0, 0, 1}, borderColor = colorUtil.withTransparencyRaw(colors.NeutralMedium, 0.25),
		gravity = {-1, 0},
	})
	add(scope .. "!noter-row:hover", {backgroundColor1 = colorUtil.withTransparencyRaw(colors.NeutralLightest, 0.04)})
	add(scope .. "!noter-selected", {backgroundColor1 = colorUtil.withTransparencyRaw(colors.AccentMedium, 0.12)})
	add(scope .. "!noter-completed TextView!noter-text", {color = colorUtil.withTransparencyRaw(colors.NeutralLightest, 0.55)})
	add(scope .. "!noter-line", {innerSpacing = {6, 6}})
	add(scope .. "!noter-fill-width", {gravity = {-1, 0}})
	add(scope .. "!noter-text", {
		size = {textWidth, -1}, minSize = {textWidth, -1}, maxSize = {textWidth, -1},
		gravity = {0, 0.5}, textAlignment = {0, 0.5}, textAutoWrap = false,
	})
	add(scope .. "!noter-selected TextView!noter-text", {
		textAutoWrap = true, maxSize = {textWidth, previewHeight},
	})
	add(scope .. "!noter-task-button", {
		padding = {0, 0, 0, 0}, margin = {0, 0, 0, 0}, minSize = {0, -1}, gravity = {0, 0.5},
	})
	add(scope .. "!noter-input, " .. expandedSelector .. " !noter-task-button", {
		minSize = {0, -1}, gravity = {-1, 0.5},
	})
	add(expandedSelector .. " TextView!noter-text", {
		minSize = {0, -1}, maxSize = {-1, -1}, gravity = {-1, 0.5},
	})
	add(expandedSelector .. " !noter-selected TextView!noter-text", {maxSize = {-1, previewHeight}})
	add(scope .. "!noter-pin-slot", {
		size = {pinColumnWidth, -1}, minSize = {pinColumnWidth, -1}, maxSize = {pinColumnWidth, -1},
		gravity = {0, 0.5},
	})
	add(scope .. "!noter-icon", {size = {iconSize, iconSize}})
	add(scope .. "!noter-icon-button", {
		padding = {iconButtonPadding, iconButtonPadding, iconButtonPadding, iconButtonPadding},
	})
	add(scope .. "!noter-hint", {
		minSize = {0, -1}, gravity = {-1, 0.5}, textAlignment = {0.5, 0.5}, textAutoWrap = true,
		color = colorUtil.withTransparencyRaw(colors.NeutralLightest, 0.65),
	})
	add("R::NoterButton ToggleButton!noter-toolbar", {
		size = {32, 32}, padding = {4, 4, 4, 4}, margin = {1, 1, 1, 1},
	})
	return result
end
