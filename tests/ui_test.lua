local runtime, uiCode, modRoot = ...
local reorderChecks = 0
local visibilityScans = 0
local model = setmetatable({canMoveTask = function(...)
	reorderChecks = reorderChecks + 1
	return runtime.model.canMoveTask(...)
end, visibleTasks = function(...)
	visibilityScans = visibilityScans + 1
	return runtime.model.visibleTasks(...)
end}, {__index = runtime.model})
local checks = 0
local function expect(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = copy(child) end
	return result
end

local palette = {BaseDarkMedium = {0.12, 0.16, 0.2, 0.4},
	NeutralMedium = {0.4, 0.5, 0.6, 1}, NeutralLightest = {0.9, 0.8, 0.7, 1},
	AccentMedium = {0.1, 0.3, 0.5, 1}}
local rules = {}
local styleEnv = {
	require = function(path)
		if path == "::/gui/main/stylesheetutil.lua" then
			return {makeAdder = function()
				return function(selectors, style)
					for selector in selectors:gmatch("[^,]+") do
						selector = selector:match("^%s*(.-)%s*$")
						local properties = rules[selector] or {}
						for key, value in pairs(style) do properties[key] = value end
						rules[selector] = properties
					end
				end
			end}
		elseif path == "::/gui/main/color_util.tl" then
			return {withTransparencyRaw = function(color, alpha) return {color[1], color[2], color[3], alpha} end}
		end
		error("Unexpected stylesheet dependency: " .. path)
	end,
	api = {gui = {genericRep = {
		find = function(path) assert(path == "::/gui/main/default_colors.gres"); return 1 end,
		get = function() return {data = palette} end,
	}}},
}
assert(loadfile(modRoot .. "/content/noter/noter.css.lua", "t", styleEnv))()
styleEnv.data()

local instances, context, joins = {}, nil, {}
local builtinKinds = {}
local layoutKinds = {BoxLayout = true, FlowLayout = true, FloatingLayout = true, TableLayout = true, AbsoluteLayout = true}
local window, tool, toolbar
local windowKey
local toolStack = {}
local saveId = "first"
local saves = {first = {}, second = {}}
local modParams = {}
local writeCount = 0
local terrainAvailable = true
local terrainPoint = {x = 120, y = -30, z = 8}
local located
local flashes = {}
local focusCount = 0
local taskButtonWidth = 1600
local viewportSize = {x = 2560, y = 1440}
local windowPosition = {x = 0, y = 0}
local movedWindowPosition
local forcedOpeningPosition
local windowLaidOut = true
local windowReferenceAvailable = true
local windowReferenceExpired = false
local restrictedApi = false
local geometryReads = 0
local assignedStyleSizes = {}
local styleAssignments = 0
local windowApiAvailable = true
local toolStackAvailable = true
local language = "en"
local gamepadInput = false

local langUtil = {
	formatInt = tostring,
	format = function(template, values)
		return (template:gsub("{([%w_]+)}", function(key) return assert(values[key], "Missing placeholder: " .. key) end))
	end,
}

local function hook(initializer)
	context.cursor = context.cursor + 1
	local slot = context.slots[context.cursor]
	if slot == nil then slot = initializer(); context.slots[context.cursor] = slot end
	return slot
end

local function state(value)
	return {
		value = value,
		old = function(self) return self.value end,
		get = function(self) return self.value end,
		set = function(self, nextValue) self.value = nextValue end,
		transform = function(self, fn) self:set(fn(self:get())) end,
	}
end

local function recipe(name, fn, wrappedKind)
	local registered = {name = name, fn = fn, wrappedKind = wrappedKind}
	return setmetatable(registered, {__call = function(self, params)
		return {kind = "recipe", recipe = self, params = params or {}}
	end})
end

local react = {
	RegisterRecipe = recipe,
	RegisterPluginRecipe = function(_, name, fn) return recipe(name, fn) end,
	RegisterWrapperRecipe = function(name, wrapped, fn)
		return recipe(name, fn, assert(builtinKinds[wrapped], "Wrapper needs a native recipe"))
	end,
	RegisterTool = function(definition) return definition end,
	useState = function(value) return hook(function() return state(value) end) end,
	useStateLazy = function(fn) return hook(function() return state(fn()) end) end,
	useRef = function(value) return hook(function() return state(value) end) end,
	useMirrorRef = function(source)
		local ref = hook(function() return state(source:old()) end)
		ref:set(source:old())
		return ref
	end,
	useNodeRef = function(nativeRecipe)
		return hook(function()
			return {
				nativeKind = builtinKinds[nativeRecipe],
				get = function()
					if builtinKinds[nativeRecipe] == "Window" and not windowReferenceAvailable then return nil end
					return {
						focus = function() focusCount = focusCount + 1 end,
						getPosition = function(_, gravityX, gravityY)
							assert(not restrictedApi, "API is currently restricted: getPosition")
							geometryReads = geometryReads + 1
							assert(builtinKinds[nativeRecipe] == "Window", "Position tracking must read the native window bounds")
							if not windowLaidOut then return {x = 0, y = 0} end
							return {x = windowPosition.x + gravityX * 640 / viewportSize.x,
								y = windowPosition.y + gravityY * 280 / viewportSize.y}
						end,
					}
				end,
				hasExpired = function() return builtinKinds[nativeRecipe] == "Window" and windowReferenceExpired end,
			}
		end)
	end,
	ref = function(ref) return {nodeRef = ref} end,
	onMount = function(fn) context.mount[#context.mount + 1] = fn end,
	onStep = function(fn) context.step[#context.step + 1] = fn end,
	onStepTimer = function() error("Window position capture must not use a polling timer") end,
	onMouseEvent = function(fn) context.mouseEvents[#context.mouseEvents + 1] = fn end,
	setStyleClasses = function(...) context.styleClasses = table.concat({...}, ",") end,
	onUnmount = function(fn) context.unmount[#context.unmount + 1] = fn end,
	enqueueJoin = function(fn) joins[#joins + 1] = fn end,
	iaHandler = function(fn) return fn end,
	useInputAction = function(name, fn)
		assert(context.wrappedKind ~= "ActionDescriptor",
			"ActionDescriptor wrappers cannot bind component input actions; use onBack")
		context.inputActions[name] = fn
	end,
}

local function flush()
	local count = 0
	while #joins > 0 do
		local pending = joins
		joins = {}
		for _, fn in ipairs(pending) do fn() end
		count = count + 1
		assert(count < 50, "Deferred UI operations did not settle")
	end
end

local function pressEscape(input)
	expect(input.params.popFocusOnStopEditing == false,
		"Cancellable native inputs retain focus when Escape ends editing")
	input.params.meta.onFocusChange(true)
	input.params.onCancel()
	flush()
end

local builtins = {type = {Orientation = {Horizontal = "Horizontal", Vertical = "Vertical"},
	ScrollBarPolicy = {AlwaysOff = "AlwaysOff", AsNeeded = "AsNeeded"}}}
for _, name in ipairs({"TextView", "ImageView", "Button", "BoxLayout", "Component", "TextInputField", "ToggleButton", "CheckBox", "Selector", "ActionDescriptor", "ScrollArea", "Window"}) do
	builtins[name] = function(first, second)
		return {kind = name, params = second or first, nodeRef = second and first.nodeRef or nil}
	end
	builtinKinds[builtins[name]] = name
end
-- Tool callbacks run inside the native ActionFn lifecycle context.
builtins.ActionFn = recipe("ActionFn", function(params) return params.fn() end, "ActionDescriptor")

local windows = {
	addWindow = function(windowRecipe, key, params)
		assert(windowRecipe.wrappedKind == "Window", "Window container needs a native window wrapper")
		assert(type(key) == "string", "Window instances need explicit keys")
		windowKey = key
		window = windowRecipe(params)
		windowPosition = movedWindowPosition or {x = params.initialX, y = params.initialY}
	end,
	removeAllWindows = function() movedWindowPosition = copy(windowPosition); window = nil end,
}

local function popTool(index)
	index = index or #toolStack
	if index == 0 then return end
	local previous = table.remove(toolStack, index)
	local wasTop = previous == tool
	tool = toolStack[#toolStack]
	previous.definition.pop(previous.context, previous.params)
	if wasTop and tool and tool.definition.shelve then tool.definition.shelve(tool.context, tool.params, false) end
end

local tools
tools = {
	pop = function(definition, key)
		for index, entry in ipairs(toolStack) do
			if entry.definition == definition and entry.key == key then popTool(index); return end
		end
	end,
	push = function(definition, key, params, allowStacking)
		if not allowStacking then while tool do popTool() end end
		local current = {definition = definition, key = key, params = params}
		current.context = {
			setActionFn = function(fn) current.action = fn end,
			-- Native popSelf uses definition and key, rather than checking entry identity.
			popSelf = function() tools.pop(definition, key) end,
		}
		if tool and tool.definition.shelve then tool.definition.shelve(tool.context, tool.params, true) end
		toolStack[#toolStack + 1] = current
		tool = current
		definition.push(current.context, params)
	end,
}

local globals = {getDefaultWindowApi = function() return windowApiAvailable and windows or nil end,
	getDefaultToolStackApi = function() return toolStackAvailable and tools or nil end}
local environment = setmetatable({
	_ = function(key) return assert(runtime.translations[language][key], "Missing translation: " .. language .. ":" .. key) end,
	getOwningModId = function() return "apasz_noter" end,
	ug_require = function(path)
		local dependencies = {
			["::/gui/main/builtin.lua"] = builtins,
			["::/gui/main/react.lua"] = react,
			["::/gui/main/game_react_globals.tl"] = globals,
			["::/gui/main/engine_react_util.tl"] = {useStepState = function(getValue)
				local value = react.useStateLazy(getValue)
				react.onStep(function()
					local updated = getValue()
					if updated ~= value:old() then value:set(updated) end
				end)
				return value
			end},
			["::/scripts/app_util.tl"] = {isGamepadInputMode = function() return gamepadInput end},
			["apasz_noter::/noter/model.tl"] = model,
			["apasz_noter::/noter/logger.tl"] = runtime.logger,
			["::/scripts/lang_util.tl"] = langUtil,
			["::/gui/main/main_mod_button_area.tl"] = {MainModButtonAreaExtension = {}},
		}
		assert(dependencies[path] ~= nil, "Unexpected UI dependency: " .. path)
		return dependencies[path]
	end,
	api = {
		engine = {config = {getModParams = function() return modParams end}},
		gui = {
			spawnEphemeralHudImage = function(icon, entity, color, position, duration, fadeIn, fadeOut)
				flashes[#flashes + 1] = {icon = icon, entity = entity, color = color, position = position,
					duration = duration, fadeIn = fadeIn, fadeOut = fadeOut}
			end,
			game = {
				getGuiSaveData = function(modId) return copy(saves[saveId][modId] or {}) end,
				setGuiSaveData = function(modId, value)
					assert(not restrictedApi, "Save data writes require the main thread")
					saves[saveId][modId] = copy(value)
					writeCount = writeCount + 1
				end,
			},
			byId = {
				setVisible = function() end,
				resetMovedWindowPosition = function(id)
					assert(id == "noter.notebook" and window, "Reset position after the window mounts")
					windowPosition = copy(forcedOpeningPosition or {x = window.params.initialX, y = window.params.initialY})
					movedWindowPosition = nil
				end,
				getSize = function(id)
					assert(id:match("^noter%.notebook%.task%.%d+$"), "Only task buttons need width measurements")
					return {x = taskButtonWidth / viewportSize.x, y = 24 / viewportSize.y}
				end,
			},
			StyleSheet = {new = function()
				return setmetatable({}, {
					__index = function(_, key)
						if key == "size" then error("Native StyleSheet.size cannot be read back") end
					end,
					__newindex = function(style, key, value)
						assert(key == "size", "Unexpected inline style property: " .. key)
						assignedStyleSizes[style] = value
						styleAssignments = styleAssignments + 1
					end,
				})
			end},
			mouse = {hasTerrainPosition = function() return terrainAvailable end,
				getTerrainPosition = function() return terrainPoint end,
				Event = {Type = {Clicked = "Clicked", DoubleClicked = "DoubleClicked"}}},
			camera = {getSize = function()
				assert(not restrictedApi, "API is currently restricted: camera.getSize")
				return viewportSize
			end,
				getCameraData = function() return {z = 700} end,
				setManualCamera = function(center, distance) located = {center = center, distance = distance} end},
		},
		type = {
			Vec2f = {new = function(x, y) return {x = x, y = y} end},
			Vec3f = {new = function(x, y, z) return {x = x, y = y, z = z} end},
		},
		cmd = {sendCommand = function() error("Notebook edits must not need simulation commands") end},
	},
}, {__index = runtime.environment})

local exports = assert(load(uiCode, "@ui.script.tl", "t", environment))()
toolbar = exports.NoterButton()

local function resolve(node, path, visited, hasActionDescriptor)
	if node.kind == "recipe" then
		local key = path .. "/" .. node.recipe.name .. "/" .. (node.params.meta and node.params.meta.localKey or "")
		local isNew = instances[key] == nil
		local instance = instances[key] or {slots = {}}
		instance.wrappedKind = node.recipe.wrappedKind
		instances[key] = instance
		visited[key] = true
		instance.cursor, instance.unmount, instance.inputActions, instance.mount, instance.mouseEvents = 0, {}, {}, {}, {}
		instance.step, instance.styleClasses = {}, nil
		local previousContext = context
		context = instance
		local result = node.recipe.fn(node.params)
		context = previousContext
		if node.recipe.wrappedKind then
			assert(result.kind == node.recipe.wrappedKind, "Wrapper returned the wrong native control")
		else
			assert(layoutKinds[result.kind], "Recipe child must be a layout: " .. node.recipe.name)
		end
		local resolved = resolve(result, key, visited, hasActionDescriptor)
		resolved.mouseEvents = instance.mouseEvents
		resolved.styleClasses = instance.styleClasses
		if isNew then for _, fn in ipairs(instance.mount) do fn() end end
		return resolved
	end
	if node.kind == "Selector" then
		assert(hasActionDescriptor, "Selector requires an enclosing ActionDescriptor")
	end
	local insideActionDescriptor = hasActionDescriptor or node.kind == "ActionDescriptor"
	local result = {kind = node.kind, params = {}, nodeRef = node.nodeRef}
	if result.nodeRef then assert(result.nodeRef.nativeKind == result.kind, "Node reference needs its declared native control") end
	if result.kind == "Window" then assert(result.nodeRef, "Position capture needs a reference attached to the native window") end
	for key, value in pairs(node.params) do
		if type(value) == "table" and value.kind then
			result.params[key] = resolve(value, path .. "/" .. key, visited, insideActionDescriptor)
		elseif key == "children" then
			result.params.children = {}
			for index, child in ipairs(value) do
				local identity = child.params.meta and child.params.meta.localKey or tostring(index)
				result.params.children[index] = resolve(child, path .. "/children/" .. identity, visited, insideActionDescriptor)
			end
		else result.params[key] = value end
	end
	if result.kind == "ScrollArea" then
		assert(result.params.content and not layoutKinds[result.params.content.kind],
			"ScrollArea does not accept a Layout as content")
	elseif result.kind == "Component" and result.params.layout then
		assert(layoutKinds[result.params.layout.kind], "Component layout must be a layout")
	end
	return result
end

local function find(node, predicate)
	if not node then return nil end
	if predicate(node) then return node end
	for key, value in pairs(node.params) do
		if type(value) == "table" and value.kind then
			local found = find(value, predicate)
			if found then return found end
		elseif key == "children" then
			for _, child in ipairs(value) do
				local found = find(child, predicate)
				if found then return found end
			end
		end
	end
end

local function render()
	reorderChecks = 0
	local visited = {}
	local root = resolve(toolbar, "toolbar", visited)
	local notebookWindow = window and resolve(window, "window/" .. windowKey, visited)
	local action = tool and resolve(builtins.ActionFn{fn = tool.action}, "tool/" .. tool.key, visited)
	if action then assert(action.kind == "ActionDescriptor", "Tool actions must return an action descriptor") end
	local selector = find(action, function(node) return node.kind == "Selector" end)
	local removed = {}
	for key, instance in pairs(instances) do
		if not visited[key] then removed[#removed + 1] = key; for _, fn in ipairs(instance.unmount) do fn() end end
	end
	for _, key in ipairs(removed) do instances[key] = nil end
	for _, instance in pairs(instances) do for _, fn in ipairs(instance.step) do fn() end end
	flush()
	return root, notebookWindow, selector, action
end

local function renderInputMode(enabled)
	gamepadInput = enabled
	render()
	return render()
end

local function notifyWindowMoved(view)
	local previous = restrictedApi
	restrictedApi = true
	local ok, failure = pcall(assert(view.params.onMovedChange, "Window must handle native movement notifications"))
	restrictedApi = previous
	if not ok then error(failure, 0) end
end

local function captureWindowMove(view)
	notifyWindowMoved(view)
	flush()
end

local function getButton(root, text)
	return find(root, function(node)
		return node.kind == "Button" and (node.params.meta.tooltip == text or find(node.params.content, function(child)
			return child.kind == "TextView" and child.params.text == text
		end) ~= nil)
	end)
end

local function findButton(root, text)
	return assert(getButton(root, text), "Missing button: " .. text)
end

local function tooltipButton(root, tooltip)
	return assert(find(root, function(node)
		return node.kind == "Button" and node.params.meta.tooltip == tooltip
	end), "Missing icon button: " .. tooltip)
end

local function expectIconButton(root, tooltip, expectedPath)
	local control = tooltipButton(root, tooltip)
	expect(control.params.meta.class == "noter-icon-button" and control.params.content.kind == "ImageView"
		and control.params.content.params.path == expectedPath,
		"Icon actions use native artwork with a translated tooltip: " .. tooltip)
	return control
end

local function taskRow(root, id)
	return assert(find(root, function(node)
		local meta = node.params.meta
		return meta and meta.localKey == tostring(id) and meta.class and meta.class:find("noter-row", 1, true)
	end), "Missing task row: " .. id)
end

local function noteGroup(root, id)
	return assert(find(root, function(node)
		return node.params.meta and node.params.meta.localKey == "note." .. tostring(id)
	end), "Missing note group: " .. id)
end

local function taskActions(root, id)
	return find(root, function(node)
		return node.params.meta and node.params.meta.localKey == "actions." .. tostring(id)
	end)
end

local function taskButton(root, id)
	local row = taskRow(root, id)
	return assert(find(row, function(node)
		return node.kind == "Button" and node.params.meta.class == "noter-task-button"
	end), "Task text must be a native focusable button")
end

local function clickTask(root, id, eventType)
	local button = taskButton(root, id)
	if eventType == "DoubleClicked" then button.params.onDoubleClick()
	else button.params.onClick() end
	return true
end

local function notebook()
	return model.readNotebook(saves[saveId].apasz_noter or {})
end

local function toolbarButton(root)
	return assert(find(root, function(node) return node.kind == "ToggleButton" end), "Missing toolbar toggle")
end

local function windowIsExpanded(view)
	return view.params.expanded == true
end

local invalidRecipe = recipe("InvalidControlRoot", function() return builtins.ToggleButton{} end)
local valid, failure = pcall(resolve, invalidRecipe(), "regression", {})
expect(not valid and tostring(failure):find("Recipe child must be a layout", 1, true),
	"Ordinary recipes must reject a control root, matching the native startup failure")
valid, failure = pcall(resolve, builtins.ScrollArea{content = builtins.BoxLayout{children = {}}}, "regression", {})
expect(not valid and tostring(failure):find("ScrollArea does not accept a Layout as content", 1, true),
	"Scroll areas must reject layout content, matching the native window failure")
valid, failure = pcall(resolve, builtins.Selector{}, "regression", {})
expect(not valid and tostring(failure):find("Selector requires an enclosing ActionDescriptor", 1, true),
	"A bare selector must be rejected, matching the native descriptorNodeId crash")

local root = render()
expect(window == nil, "Notebook starts closed")
toolbarButton(root).params.onValueChange(1)
flush()
local _, view = render()
expect(view.kind == "Window" and view.params.pinnable, "Toolbar opens a pinnable native window")
expect(view.params.initialX == 0.04 and view.params.initialY == 0.1,
	"Notebook initially opens 4% from the left and 10% from the top, matching UIT")
expect(view.params.title == "Noter · 0 remaining" and focusCount == 1,
	"Opening focuses the composer and shows the remaining count")
expect(not windowIsExpanded(view), "Notebook opens at normal size")
local readsBeforeMoveEvent = geometryReads
local writesBeforeMoveEvent = writeCount
notifyWindowMoved(view)
expect(geometryReads == readsBeforeMoveEvent and writeCount == writesBeforeMoveEvent,
	"Movement callbacks queue capture without reading GUI geometry or writing save data")
flush()
expect(geometryReads > readsBeforeMoveEvent, "Queued movement capture reads geometry on the main thread")
local readsBeforeIdle = geometryReads
for _ = 1, 10 do _, view = render() end
expect(geometryReads == readsBeforeIdle and writeCount == writesBeforeMoveEvent,
	"Idle windows perform no position reads or writes")
expect(view.params.meta.class == nil, "Missing mod parameters preserve the native window transparency")
local writesBeforeNoop = writeCount
view.params.onPinned(false)
local hide = assert(find(view, function(node) return node.kind == "CheckBox" and node.params.label == "Hide completed" end))
hide.params.onValueChange(0)
expect(writeCount == writesBeforeNoop, "Unchanged native preference events do not dirty the save")
captureWindowMove(view)
expect(writeCount == writesBeforeNoop and notebook().windowLayout == nil,
	"An unchanged default window does not create save data")
windowPosition = {x = 0.12, y = 0.18}
windowLaidOut = false
captureWindowMove(view)
expect(writeCount == writesBeforeNoop, "Empty window bounds are ignored before layout")
windowLaidOut = true
local readsBeforeRepeatedEvents = geometryReads
for _ = 1, 3 do notifyWindowMoved(view) end
flush()
expect(geometryReads == readsBeforeRepeatedEvents + 2 and writeCount == writesBeforeNoop + 1
	and math.abs(model.getWindowLayout(notebook()).x - 0.12) < 0.000001,
	"Repeated move notifications coalesce into one position capture and save-data write")
windowPosition = {x = 0.16, y = 0.22}
captureWindowMove(view)
local rememberedLayout = model.getWindowLayout(notebook())
expect(math.abs(rememberedLayout.x - 0.16) < 0.000001 and math.abs(rememberedLayout.y - 0.22) < 0.000001,
	"A second drag updates the saved anchor while the window remains open")
local writesAfterMove = writeCount
captureWindowMove(view)
windowPosition.x = windowPosition.x + 0.25 / viewportSize.x
captureWindowMove(view)
expect(writeCount == writesAfterMove, "Stationary windows and subpixel noise do not rewrite save data")
windowPosition = {x = rememberedLayout.x, y = rememberedLayout.y}
local input = assert(find(view, function(node) return node.kind == "TextInputField" end))
expect(input.params.maxLength == model.MAX_TEXT_LENGTH, "The composer uses the shared character limit")
local writesBeforeInvalidInput = writeCount
input.params.onTyping(string.rep("x", model.MAX_TEXT_LENGTH + 1))
_, view = render()
expect(not findButton(view, "Add").params.meta.enabled, "Over-limit drafts disable Add")
input = assert(find(view, function(node) return node.kind == "TextInputField" end))
input.params.onValueChange(string.rep("x", model.MAX_TEXT_LENGTH + 1))
expect(writeCount == writesBeforeInvalidInput, "Over-limit submissions cannot bypass the input control")
local writesBeforeResize = writeCount
input.params.onTyping("Draft while resizing")
local resizeButton = tooltipButton(view.params.header, "Expand window")
expect(resizeButton.kind == "Button" and resizeButton.params.content.kind == "ImageView",
	"The native window header contains the expand icon button")
local headerChildren = view.params.header.params.children
expect(headerChildren[1].kind == "TextView" and headerChildren[1].params.text == view.params.title
	and headerChildren[2] == resizeButton,
	"The header places the title before the resize control")
resizeButton.params.onClick()
_, view = render()
input = assert(find(view, function(node) return node.kind == "TextInputField" end))
expect(windowIsExpanded(view) and input.params.value == "Draft while resizing" and focusCount == 1,
	"Expanding preserves the composer draft without requesting focus")
tooltipButton(view.params.header, "Restore normal size").params.onClick()
_, view = render()
input = assert(find(view, function(node) return node.kind == "TextInputField" end))
expect(not windowIsExpanded(view) and input.params.value == "Draft while resizing" and writeCount == writesBeforeResize + 2
	and not model.getWindowLayout(notebook()).expanded,
	"Changing size preserves the draft and saves each accepted size choice")
local longTaskText = string.rep("A long task with many words to wrap ", 12) .. "end."
input.params.onTyping(longTaskText)
findButton(view, "Add").params.onClick()
expect(#notebook().tasks == 1, "Add uses latest typed text before rerender")
_, view = render()
expect(view.params.title == "Noter · 1 remaining", "Adding updates the title count")
expect(focusCount == 1, "Updating the open notebook does not request text focus again")
local writesBeforePreview = writeCount
clickTask(view, 1)
_, view = render()
expect(not taskRow(view, 1).params.meta.class:find("noter-selected", 1, true)
	and not getButton(taskActions(view, 1), "Edit"), "Clicking a selected note collapses its preview and actions")
clickTask(view, 1)
_, view = render()
expect(taskRow(view, 1).params.meta.class:find("noter-selected", 1, true)
	and getButton(taskActions(view, 1), "Edit") and taskButton(view, 1).params.content.params.text == longTaskText
	and notebook().tasks[1].text == longTaskText and writeCount == writesBeforePreview and focusCount == 1,
	"Selecting a note enables its preview without changing the text, save data or focus")
expect(taskRow(view, 1).styleClasses:find("noter-selected", 1, true)
	and taskButton(view, 1).params.content.params.meta.class:find("noter-preview", 1, true),
	"Selection reaches the native wrapper and wrapping is applied directly to the selected text")
tooltipButton(view, "Expand window").params.onClick()
for _, allocatedWidth in ipairs({1600, 2200, 900}) do
	taskButtonWidth = allocatedWidth
	render()
	_, view = render()
	local text = taskButton(view, 1).params.content
	local size = assert(assignedStyleSizes[text.params.meta.styleSheet])
	expect(size.x == allocatedWidth and size.y == -1 and text.params.text == longTaskText,
		"Expanded previews use the allocated row width as the wrap boundary without changing the text")
	expect(text.params.meta.class:find("noter-expanded-text", 1, true)
		and text.params.meta.class:find("noter-preview", 1, true),
		"Expanded previews carry both width and wrapping states on the native TextView")
end
for _, viewportWidth in ipairs({1280, 3840}) do
	viewportSize.x = viewportWidth
	taskButtonWidth = 0.75 * viewportWidth
	render()
	_, view = render()
	local textStyle = taskButton(view, 1).params.content.params.meta.styleSheet
	expect(assignedStyleSizes[textStyle].x == taskButtonWidth,
		"A fractional component width is converted to pixels at the current viewport resolution")
end
local settledStyle = taskButton(view, 1).params.content.params.meta.styleSheet
local assignmentsBeforeStableWidth = styleAssignments
_, view = render()
expect(taskButton(view, 1).params.content.params.meta.styleSheet == settledStyle
	and styleAssignments == assignmentsBeforeStableWidth,
	"Stable widths reuse the cached style without accessing native style getters")
clickTask(view, 1)
taskButtonWidth = 1200
render()
_, view = render()
local collapsedExpandedText = taskButton(view, 1).params.content
expect(assignedStyleSizes[collapsedExpandedText.params.meta.styleSheet].x == taskButtonWidth
	and not getButton(taskActions(view, 1), "Edit"),
	"Collapsed notes also use the current expanded width while keeping their actions hidden")
clickTask(view, 1)
_, view = render()
local scansBeforeResize = visibilityScans
tooltipButton(view, "Restore normal size").params.onClick()
expect(visibilityScans == scansBeforeResize, "Window layout changes do not rescan unchanged task visibility")
_, view = render()
expect(taskButton(view, 1).params.content.params.meta.styleSheet == nil and getButton(taskActions(view, 1), "Edit")
	and writeCount == writesBeforePreview + 2 and focusCount == 1,
	"Restoring normal size removes the expanded width while preserving selection, notes and focus")
input = assert(find(view, function(node) return node.kind == "TextInputField" end))
expect(input.params.value == "", "Composer clears after adding")
input.params.onValueChange("Buy a train")
_, view = render()
expect(not getButton(taskActions(view, 1), "Edit") and getButton(taskActions(view, 2), "Edit"),
	"Only the selected task shows its actions")
expect(reorderChecks == 2, "Only the selected task checks its two reorder directions")
expect(tooltipButton(taskActions(view, 2), "Move up").params.content.kind == "ImageView"
	and not tooltipButton(taskActions(view, 2), "Move down").params.meta.enabled,
	"Reordering uses arrow icons, tooltips, and boundary disabling")
local complete = assert(find(view, function(node)
	return node.kind == "CheckBox" and node.params.meta and node.params.meta.tooltip == "Mark complete"
end))
complete.params.onValueChange(1)
local scansBeforePin = visibilityScans
view.params.onPinned(true)
expect(notebook().tasks[1].completed and notebook().pinned, "Same-frame writes do not overwrite one another")
expect(visibilityScans == scansBeforePin, "Pin changes do not rescan unchanged task visibility")
local writesBeforeRepeatedCompletion = writeCount
complete.params.onValueChange(1)
expect(writeCount == writesBeforeRepeatedCompletion, "Repeated completion events do not rewrite GUI save data")
_, view = render()
expect(view.params.title == "Noter · 1 remaining", "Completion updates the title count")
expect(not find(view, function(node) return node.kind == "TextView" and node.params.text == "Completed" end),
	"Completing a note does not insert a heading into the list")
hide = assert(find(view, function(node) return node.kind == "CheckBox" and node.params.label == "Hide completed" end))
hide.params.onValueChange(1)
_, view = render()
expect(notebook().hideCompleted and not find(view, function(node)
	return node.kind == "TextView" and node.params.text == longTaskText
end), "Hide completed removes finished tasks from the window")
hide = assert(find(view, function(node) return node.kind == "CheckBox" and node.params.label == "Hide completed" end))
hide.params.onValueChange(0)
_, view = render()
local setPointContent = findButton(view, "Set point").params.content
expect(setPointContent.kind == "ImageView"
	and setPointContent.params.path == "::/gui/builtin/window/icons/symbol_locate.tga"
	and findButton(view, "Set point").params.meta.tooltip == "Set point",
	"Set point uses the native map marker with a translated tooltip")
toolStackAvailable = false
findButton(view, "Set point").params.onClick()
local pickerOk, pickerFailure = pcall(flush)
expect(not pickerOk and tostring(pickerFailure):find("[Noter] ERROR: Map picker needs an active game tool stack", 1, true)
	and tool == nil and notebook().tasks[2].point == nil,
	"Missing tool stack fails through the shared logger without changing the task")
toolStackAvailable = true
findButton(view, "Set point").params.onClick()
flush()
local selector, action
_, view, selector, action = render()
expect(tool ~= nil and selector.kind == "Selector", "Set point activates a map selector")
expect(action.kind == "ActionDescriptor" and action.params.tool == tool.definition.name,
	"Picker selector belongs to the active tool's action descriptor")
terrainAvailable = false
expect(not selector.params.onProcessMouseEvent({type = "Clicked", button = 0}), "Invalid terrain is ignored")
terrainAvailable = true
expect(not selector.params.onProcessMouseEvent({type = "Clicked", button = 0, handled = true}),
	"Clicks consumed by the UI are ignored")
expect(selector.params.onProcessMouseEvent({type = "Clicked", button = 0}), "Valid map click is consumed")
flush()
expect(tool == nil and notebook().tasks[2].point.x == 120, "Point is saved and picker stops")
expect(#flashes == 1 and flashes[1].position.x == 120 and flashes[1].position.z == 8
	and flashes[1].entity == nil and flashes[1].duration == 3 and flashes[1].fadeOut,
	"Setting a point flashes a temporary world icon")
_, view = render()
expect(not getButton(view, "Go"), "Linked rows omit the redundant Go text button")
local changePointContent = findButton(view, "Change point").params.content
expect(changePointContent.params.path == setPointContent.params.path
	and findButton(view, "Change point").params.meta.tooltip == "Change point",
	"Change point keeps the same map icon with its own translated tooltip")
local linkedRow = taskRow(view, 2)
local linkedLine = linkedRow.params.layout.params.children[1].params.children
expect(linkedLine[1].kind == "CheckBox" and linkedLine[2].params.meta.class == "noter-pin-slot"
	and tooltipButton(linkedLine[2], "Go to map point")
	and linkedLine[3].params.meta.class == "noter-task-button",
	"The pin column is directly after the checkbox and before the task text")
local unlinkedLine = taskRow(view, 1).params.layout.params.children[1].params.children
expect(unlinkedLine[2].params.meta.class == linkedLine[2].params.meta.class
	and unlinkedLine[2].params.layout == nil,
	"Unlinked tasks keep an empty pin column to align the text")
local writesBeforeGo = writeCount
expectIconButton(linkedRow, "Unlink", "::/gui/line_vehicle_mgmt/icons/minus.tga")
tooltipButton(linkedRow, "Go to map point").params.onClick()
expect(located.center.x == 120 and located.center.y == -30 and located.distance == 700,
	"The pin navigates to the point at the current zoom")
expect(#flashes == 2 and writeCount == writesBeforeGo, "The pin highlights the point without changing saved data")
_, view = render()
expect(getButton(taskActions(view, 2), "Edit"), "Using the pin does not toggle the row's actions")
local writesBeforeSelection = writeCount
clickTask(view, 2)
_, view = render()
expect(not getButton(taskActions(view, 2), "Edit"), "Clicking the selected task collapses its actions")
expect(reorderChecks == 0, "Compact task lists perform no reorder scans")
-- Native Button activation uses the same onClick callback for controller Select.
local buttonBeforeController = taskButton(view, 2).nodeRef
local focusBeforeController = focusCount
_, view = renderInputMode(true)
expect(taskButton(view, 2).params.meta.tooltip == runtime.translations.en.APASZ_NOTER_TASK_ACTIONS_CONTROLLER_TOOLTIP
	and taskButton(view, 2).nodeRef == buttonBeforeController
	and writeCount == writesBeforeSelection and focusCount == focusBeforeController,
	"Switching to controller updates the tooltip without replacing the button, changing focus or saving")
taskButton(view, 2).params.onClick()
_, view = render()
expect(getButton(taskActions(view, 2), "Edit") and writeCount == writesBeforeSelection,
	"Controller Select can expand task actions without changing saved data")
taskButton(view, 2).params.onClick()
_, view = render()
expect(not getButton(taskActions(view, 2), "Edit"), "Controller Select toggles task actions closed again")
_, view = renderInputMode(false)
expect(taskButton(view, 2).params.meta.tooltip == runtime.translations.en.APASZ_NOTER_TASK_ACTIONS_TOOLTIP
	and taskButton(view, 2).nodeRef == buttonBeforeController
	and writeCount == writesBeforeSelection and focusCount == focusBeforeController,
	"Switching back to mouse restores double-click guidance without changing selection or focus")
expect(clickTask(view, 1), "Clicking a task selects it")
_, view = render()
expect(getButton(taskActions(view, 1), "Edit") and not getButton(taskActions(view, 2), "Edit"),
	"Changing selection collapses the previous row")
findButton(view, "Set point").params.onClick()
flush()
_, view, selector = render()
expect(selector.params.onProcessMouseEvent({type = "Clicked", button = 2}), "An active picker consumes right-click cancellation")
expect(not selector.params.onSelect(1, {}, {}), "Canceled picker ignores further selection in the same frame")
expect(not selector.params.onProcessMouseEvent({type = "Clicked", button = 2}),
	"A canceled picker leaves subsequent right-clicks available to the restored tool")
flush()
expect(tool == nil and notebook().tasks[1].point == nil, "Right-click cancels without attaching a point")
expect(#flashes == 2, "Canceling does not flash a point")
_, view = render()
findButton(view, "Set point").params.onClick()
flush()
_, view, selector = render()
local collapsedSelector = selector
clickTask(view, 1)
_, view = render()
expect(tool == nil and not getButton(taskActions(view, 1), "Edit"),
	"Collapsing a task cancels its active map picker")
local writesBeforeLateSelection = writeCount
expect(not collapsedSelector.params.onSelect(1, {}, {}) and writeCount == writesBeforeLateSelection
	and notebook().tasks[1].point == nil,
	"A late selection from a collapsed task's picker cannot change saved data")
-- Collapse before the queued push executes, then start a new request before rendering.
clickTask(view, 1)
_, view = render()
findButton(view, "Set point").params.onClick()
clickTask(view, 1)
flush()
expect(tool == nil, "A picker request canceled before its deferred push never starts")
_, view = render()
clickTask(view, 1)
_, view = render()
findButton(view, "Set point").params.onClick()
flush()
_, view = render()
clickTask(view, 2)
_, view = render()
expect(tool == nil and notebook().tasks[1].point == nil, "Selecting another row cancels an active map picker")
clickTask(view, 1)
_, view = render()
findButton(view, "Set point").params.onClick()
flush()
_, view, selector, action = render()
local writesBeforeEscape = writeCount
assert(action.params.onBack, "Picker must handle native Escape/back")()
action.params.onBack()
expect(not selector.params.onSelect(1, {}, {}) and writeCount == writesBeforeEscape,
	"Native back immediately rejects late input and repeated cancellation without saving")
flush()
expect(tool == nil and notebook().tasks[1].point == nil, "Escape cancels without changing a task")
_, view = render()
findButton(view, "Set point").params.onClick()
flush()
_, view, selector = render()
tool.definition.shelve(tool.context, tool.params, true)
expect(not selector.params.onSelect(1, {}, {}), "A shelved picker stops accepting input immediately")
flush()
expect(tool == nil, "Switching to another tool cancels point selection")
_, view = render()
local writesBeforeDelete = writeCount
findButton(view, "Delete").params.onClick()
expect(writeCount == writesBeforeDelete, "First delete click requests confirmation")
_, view = render()
expect(getButton(view, "Yes") and getButton(view, "No"), "Delete confirmation uses Yes and No choices")
expect(reorderChecks == 0, "Delete confirmation performs no reorder scans")
findButton(view, "No").params.onClick()
_, view = render()
expect(#notebook().tasks == 2 and writeCount == writesBeforeDelete and getButton(view, "Delete")
	and not getButton(view, "Yes"), "No cancels deletion and restores the task actions without saving")
findButton(view, "Delete").params.onClick()
_, view = render()
clickTask(view, 2)
_, view = render()
expect(not getButton(view, "Yes") and #notebook().tasks == 2,
	"Changing rows clears the delete confirmation without deleting")
clickTask(view, 1)
_, view = render()
findButton(view, "Delete").params.onClick()
_, view = render()
findButton(view, "Yes").params.onClick()
expect(#notebook().tasks == 1, "Confirmed delete removes the task")
_, view = render()
expect(not getButton(view, "Edit"), "Deleting the selected task clears selection")
local focusBeforeEdit = focusCount
local compactButton = taskButton(view, 2)
expect(#taskRow(view, 2).mouseEvents == 0,
	"Task rows delegate mouse press and release handling to native buttons instead of window-bubbling hooks")
expect(clickTask(view, 2, "DoubleClicked"), "Double-click starts editing")
compactButton.params.onClick()
_, view = render()
expect(focusCount == focusBeforeEdit + 1 and getButton(view, "Save"),
	"Direct editing focuses the field and ignores a late single-click callback")
expect(reorderChecks == 0, "Text editing performs no reorder scans")
local editor = assert(findButton(view, "Save"))
expectIconButton(view, "Save", "::/gui/menu/icons/symbol_check.tga")
expectIconButton(view, "Cancel", "::/gui/builtin/window/icons/cross_thin.tga")
local row = taskRow(view, 2)
local editInput = assert(find(row, function(node) return node.kind == "TextInputField" end))
expect(editInput.params.maxLength == model.MAX_TEXT_LENGTH, "Editing uses the same character limit as Add")
expect(tooltipButton(row.params.layout.params.children[1].params.children[2], "Go to map point")
	and #row.mouseEvents == 0,
	"Editing preserves the pin column and leaves mouse handling to native editor controls")
editInput.params.onTyping("Upgrade the railway")
local focusBeforeResize = focusCount
local editorBeforeInputChange = editInput.nodeRef
local writesBeforeInputChange = writeCount
_, view = renderInputMode(true)
editInput = assert(find(taskRow(view, 2), function(node) return node.kind == "TextInputField" end))
expect(editInput.nodeRef == editorBeforeInputChange and editInput.params.value == "Upgrade the railway"
	and focusCount == focusBeforeResize and writeCount == writesBeforeInputChange,
	"An input-mode change preserves the native editor, draft, focus and saved notebook")
_, view = renderInputMode(false)
tooltipButton(view, "Expand window").params.onClick()
_, view = render()
editInput = assert(find(taskRow(view, 2), function(node) return node.kind == "TextInputField" end))
expect(windowIsExpanded(view) and editInput.params.value == "Upgrade the railway" and focusCount == focusBeforeResize,
	"Expanding during an edit preserves the selected row, draft and focus")
editor = findButton(view, "Save")
editInput.params.onCancel()
editInput.params.meta.onFocusChange(false)
flush()
_, view = render()
expect(findButton(view, "Save") and notebook().tasks[1].text ~= "Upgrade the railway",
	"Focus loss leaves an edited note open without saving before the Save click")
editor = findButton(view, "Save")
editor.params.onClick()
expect(notebook().tasks[1].text == "Upgrade the railway", "Save commits the edited text")
_, view = render()
findButton(taskActions(view, 2), "Edit").params.onClick()
_, view = render()
row = taskRow(view, 2)
editInput = assert(find(row, function(node) return node.kind == "TextInputField" end))
local writesBeforeCancel = writeCount
editInput.params.onTyping("Discard this change")
expect(not find(row, function(node)
	return node.kind == "Button" and node.params.meta.class == "noter-task-button"
end), "The editing row has no selection button that could discard its draft")
pressEscape(editInput)
editInput.params.onValueChange("Late text before the cancelled editor unmounts")
_, view = render()
expect(notebook().tasks[1].text == "Upgrade the railway" and writeCount == writesBeforeCancel
	and not getButton(view, "Save"), "Escape cancels an edit without saving")
local writesAfterEditorCancel = writeCount
editInput.params.onValueChange("Late text from the cancelled editor")
_, view = render()
expect(notebook().tasks[1].text == "Upgrade the railway" and writeCount == writesAfterEditorCancel,
	"An unmounted editor ignores a late native acceptance callback")
clickTask(view, 2, "DoubleClicked")
_, view = render()
editInput = assert(find(taskRow(view, 2), function(node) return node.kind == "TextInputField" end))
editInput.params.onValueChange("Upgrade both platforms")
editInput.params.onValueChange("Duplicate acceptance after saving")
_, view = render()
expect(notebook().tasks[1].text == "Upgrade both platforms" and not getButton(view, "Save"),
	"Enter accepts the edit and returns to the task view")

findButton(view, "Change point").params.onClick()
flush()
_, view, selector = render()
findButton(view, "Unlink").params.onClick()
flush()
_, view = render()
local writesAfterUnlink = writeCount
expect(tool == nil and notebook().tasks[1].point == nil
	and not selector.params.onSelect(1, {}, {}) and writeCount == writesAfterUnlink,
	"Unlink cancels the pending point change and rejects late input that could reattach it")
findButton(view, "Set point").params.onClick()
flush()
_, view, selector = render()
selector.params.onProcessMouseEvent({type = "Clicked", button = 0})
flush()
_, view = render()

local previousToolShelved, previousToolRestored = false, false
local previousTool = {
	name = "another-mod-tool",
	push = function(toolContext)
		toolContext.setActionFn(function() return builtins.ActionDescriptor{tool = "another-mod-tool", children = {}} end)
	end,
	pop = function() error("Noter must preserve the previous tool") end,
	shelve = function(_, _, shelved)
		if shelved then previousToolShelved = true else previousToolRestored = true end
	end,
}
tools.push(previousTool, "another-mod-key", {}, true)
findButton(view, "Change point").params.onClick()
flush()
_, view, selector = render()
expect(#toolStack == 2 and previousToolShelved, "Point picking shelves the existing game/mod tool without clearing it")
selector.params.onProcessMouseEvent({type = "Clicked", button = 2})
flush()
_, view = render()
expect(tool.definition == previousTool and #toolStack == 1 and previousToolRestored,
	"Canceling point picking restores the previous game/mod tool")
previousTool.pop = function() end
popTool()

-- An old completion is queued while the next picker request starts.
findButton(view, "Change point").params.onClick()
flush()
_, view, selector = render()
local oldPickerKey = tool.key
local oldPickerContext = tool.context
selector.params.onProcessMouseEvent({type = "Clicked", button = 0})
findButton(view, "Change point").params.onClick()
flush()
_, view, selector = render()
oldPickerContext.popSelf()
flush()
expect(tool ~= nil and tool.key ~= oldPickerKey and findButton(view, "Cancel"),
	"An old picker's deferred completion cannot pop or hide the newer request")
selector.params.onProcessMouseEvent({type = "Clicked", button = 2})
flush()
_, view = render()

findButton(view, "Change point").params.onClick()
view.params.onClose()
flush()
expect(tool == nil and window == nil, "Closing before a queued picker starts prevents it from starting")
root = render()
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
clickTask(view, 2)
_, view = render()
tooltipButton(view, "Restore normal size").params.onClick()
_, view = render()
windowPosition = {x = 0.28, y = 0.24}
view.params.onClose()
flush()
root = render()
expect(window == nil and toolbarButton(root).params.value == 0, "Close updates the toolbar toggle")
local focusBeforeReopen = focusCount
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
expect(focusCount == focusBeforeReopen + 1, "Reopening the notebook requests text focus once")
expect(not windowIsExpanded(view) and not model.getWindowLayout(notebook()).expanded,
	"Reopening restores the saved normal size")
expect(math.abs(view.params.initialX - 0.28) < 0.000001 and math.abs(view.params.initialY - 0.24) < 0.000001,
	"Closing captures the latest position even without a movement notification")
expect(notebook().tasks[1].text == "Upgrade both platforms" and view.params.pinned,
	"Close/reopen restores notebook and pin preference")
expect(not getButton(view, "Edit"), "Reopening begins with compact, unselected rows")
clickTask(view, 2)
_, view = render()
findButton(view, "Change point").params.onClick()
flush()
_, view, selector = render()
local writesBeforeClose = writeCount
view.params.onClose()
expect(not selector.params.onSelect(1, {}, {}) and writeCount == writesBeforeClose,
	"Closing the window immediately rejects late map input before deferred cleanup")
flush()
render()
expect(tool == nil, "Closing cancels the map picker")
root = render()
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
windowPosition = {x = 0.36, y = 0.32}
notifyWindowMoved(view)
toolbarButton(root).params.onValueChange(0)
flush()
root = render()
expect(math.abs(model.getWindowLayout(notebook()).x - 0.36) < 0.000001,
	"Closing through the toolbar also captures the latest position")
-- Recreate all hook state, as on a UI reload or a new game session.
instances = {}
toolbar = exports.NoterButton()
root = render()
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
expect(not windowIsExpanded(view) and math.abs(view.params.initialX - 0.36) < 0.000001
	and math.abs(view.params.initialY - 0.32) < 0.000001,
	"Saved window layout survives recreation of the entire UI runtime")
local lateLayoutMove = assert(view.params.onMovedChange)
view.params.onClose()
flush()
root = render()
saveId = "second"
root = render()
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
expect(#notebook().tasks == 0 and #saves.first.apasz_noter.tasks == 1, "Saves have independent notebooks")
expect(not windowIsExpanded(view) and view.params.initialX == 0.04 and view.params.initialY == 0.1
	and windowPosition.x == 0.04 and windowPosition.y == 0.1 and notebook().windowLayout == nil,
	"A fresh save starts at the default size and position despite the previous save's moved window")
local writesBeforeLateLayoutMove = writeCount
lateLayoutMove()
flush()
expect(writeCount == writesBeforeLateLayoutMove and notebook().windowLayout == nil,
	"Late layout callbacks from an old window cannot write into the newly loaded save")
view.params.onClose()
flush()
root = render()
saveId = "first"
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
expect(not windowIsExpanded(view) and math.abs(view.params.initialX - 0.36) < 0.000001
	and math.abs(view.params.initialY - 0.32) < 0.000001,
	"Returning to an existing save restores its own layout")
view.params.onClose()
flush()
root = render()
saveId = "second"
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()

if runtime.debugLoggingEnabled then
	local messages = {}
	for _, entry in ipairs(runtime.entries) do
		expect(entry.level == "verbose" and entry.message:find("[Noter] ", 1, true) == 1,
			"Debug output uses the shared logger")
		messages[entry.message] = true
	end
	expect(messages["[Noter] Opened notebook"] and messages["[Noter] Closed notebook"]
		and messages["[Noter] Started map point picker for task 2"]
		and messages["[Noter] Selected map point: x=120.00, y=-30.00, z=8.00"]
		and messages["[Noter] Canceled map point selection"]
		and messages["[Noter] Window movement callback"]
		and messages["[Noter] Captured window position: x=0.1600, y=0.2200"]
		and messages["[Noter] Updated notebook GUI save data: 2 tasks, 1 remaining"],
		"Enabled debug logging covers window movement, captured positions, save data and map-picker activity")
else
	expect(#runtime.entries == 0, "Normal notebook activity emits no messages with production defaults")
end
view.params.onClose()
flush()
root = render()
windowApiAvailable = false
local warningsBefore = #runtime.entries
for _ = 1, 2 do
	toolbarButton(root).params.onValueChange(1)
	flush()
	root = render()
end
local warning = runtime.entries[warningsBefore + 1]
expect(#runtime.entries == warningsBefore + 1 and warning.level == "warning"
	and warning.message == "[Noter] Cannot open notebook: game window API is unavailable"
	and window == nil, "An unavailable window API emits one warning through the shared logger")

local resourceEnv = {resolve = function(path) return "apasz_noter::/noter/" .. path end}
assert(loadfile(modRoot .. "/content/noter/menu.res.lua", "t", resourceEnv))()
local resource = resourceEnv.data()
expect(resource.type == "react-plugin ::MainModButtonAreaExtension"
	and resource.data.filePath == "apasz_noter::/noter/ui.script@NoterButton", "Plugin resource resolves its export")

expect(rules["!noter-child-content"].borderWidth[4] > 0
	and rules["!noter-group"].padding[3] > rules["!noter-no-padding"].padding[3],
	"Checklists have a vertical guide and more space between parent groups than child rows")
expect(rules["!noter-no-padding"].padding[4] == 0 and rules["!noter-no-padding"].padding[2] == 0,
	"Shared zero padding keeps child rows and the add row aligned")
local opaqueColor = rules["Window#noter.notebook!noter-opaque"].backgroundColor1
expect(opaqueColor[1] == palette.BaseDarkMedium[1] and opaqueColor[2] == palette.BaseDarkMedium[2]
	and opaqueColor[3] == palette.BaseDarkMedium[3] and opaqueColor[4] == 1,
	"Opaque windows use the current theme's background colour at full opacity")
expect(rules["Window#noter.notebook"].backgroundColor1 == nil,
	"The default window keeps the native theme's transparency")
expect(rules["!noter-selected"].backgroundColor1[2] == palette.AccentMedium[2],
	"Selection uses the active theme's accent colour")
expect(rules["!noter-selected:hover"].backgroundColor1[4] == rules["!noter-selected"].backgroundColor1[4]
	and rules["!noter-destructive"].padding[4] > 0,
	"Selection remains visible on hover and destructive actions have a separate gap")
local pinSlotStyle = rules["!" .. linkedLine[2].params.meta.class]
local iconWidth = rules["!noter-icon"].size[1]
local iconPadding = rules["!noter-icon-button"].padding
local pinButtonWidth = rules["!noter-icon-button"].size[1]
expect(pinSlotStyle.minSize[1] == pinButtonWidth and pinSlotStyle.maxSize[1] == pinButtonWidth,
	"Pin columns fit the pin button exactly without taking extra task-text width")
expect(pinButtonWidth >= iconWidth + iconPadding[2] + iconPadding[4]
	and rules["!noter-icon-button"].minSize[1] == rules["!noter-icon-button"].maxSize[1],
	"Icon controls share a fixed size with padding around the native artwork")
local completedColor = rules["!noter-text!noter-completed-text"].color
expect(completedColor[1] == palette.NeutralLightest[1] and completedColor[4] < palette.NeutralLightest[4],
	"Completed text is dimmed using the active theme")
local collapsedTextStyle = rules["!noter-text"]
local previewTextStyle = rules["!noter-text!noter-preview"]
expect(collapsedTextStyle.textAutoWrap == false and collapsedTextStyle.size[1] > 0
	and collapsedTextStyle.minSize[1] == collapsedTextStyle.size[1]
	and collapsedTextStyle.maxSize[1] == collapsedTextStyle.size[1],
	"Collapsed notes have a finite single-line text column")
expect(previewTextStyle.textAutoWrap and collapsedTextStyle.maxSize[2] > 0,
	"Selected notes wrap in the same text column with a bounded preview height")
local checklistTextStyle = rules["!noter-text!noter-checklist-text"]
expect(checklistTextStyle.maxSize[1] == checklistTextStyle.size[1]
	and checklistTextStyle.maxSize[2] == collapsedTextStyle.maxSize[2],
	"Checklist notes reserve progress width while sharing the preview height cap")
expect(collapsedTextStyle.gravity[1] == 0 and rules["!noter-task-button"].gravity[1] == -1,
	"Note text stays left-aligned while its button fills space before the progress count")
local expandedWindowStyle = rules["Window#noter.notebook!window-expanded"]
expect(expandedWindowStyle.size[1] == "75vw" and expandedWindowStyle.size[2] == "80vh",
	"Expanded windows use the larger window dimensions")
expect(expandedWindowStyle.anchorPoint[1] == 0.5 and expandedWindowStyle.anchorPoint[2] == 0.5
	and expandedWindowStyle.gravity[1] == 0.5 and expandedWindowStyle.gravity[2] == 0.5,
	"Expanded placement aligns the window centre with the screen centre")
local normalWindowStyle = rules["Window#noter.notebook"]
expect(normalWindowStyle.anchorPoint[1] == 0 and normalWindowStyle.anchorPoint[2] == 0,
	"Normal placement continues to use the top-left anchor")
local expandedTextStyle = rules["!noter-text!noter-expanded-text"]
expect(rules["!noter-task-button"].gravity[1] == -1
	and expandedTextStyle.gravity[1] == -1 and expandedTextStyle.minSize[1] == 0
	and expandedTextStyle.maxSize[1] == -1,
	"Expanded note buttons fill the row and text can grow beyond the normal width")
expect(expandedTextStyle.maxSize[2] == collapsedTextStyle.maxSize[2],
	"Expanded previews keep the height cap while allowing the entire row width")

windowApiAvailable = true
local writesBeforeAppearance = writeCount
for _, case in ipairs({
	{name = "Missing parameter", parameters = {}, opaque = false},
	{name = "Off (option 1)", parameters = {apasz_noter_opaque_window = 1}, opaque = false},
	{name = "On (option 2)", parameters = {apasz_noter_opaque_window = 2}, opaque = true},
}) do
	modParams = {apasz_noter = case.parameters}
	toolbarButton(root).params.onValueChange(1)
	flush()
	_, view = render()
	local writesBeforeOpaqueRender = writeCount
	expect(view.params.meta.class == (case.opaque and "noter-opaque" or nil) and not windowIsExpanded(view),
		case.name .. ": normal window uses the requested appearance")
	tooltipButton(view, "Expand window").params.onClick()
	_, view = render()
	expect(windowIsExpanded(view) and view.params.meta.class == (case.opaque and "noter-opaque" or nil),
		case.name .. ": expanded window uses the requested appearance")
	tooltipButton(view, "Restore normal size").params.onClick()
	_, view = render()
	expect(writeCount == writesBeforeOpaqueRender + 2, "Only size changes are saved when checking window appearance")
	view.params.onClose()
	flush()
	root = render()
end
expect(writeCount == writesBeforeAppearance + 6, "Window appearance changes do not add writes beyond the six size choices")
for _, case in ipairs({
	{name = "Ephemeral", index = 1, x = 0.04, y = 0.1, expanded = false},
	{name = "Remembered", index = 2, x = 0, y = 1, expanded = false},
}) do
	saveId = "remember-" .. tostring(case.index)
	saves[saveId] = {apasz_noter = model.setWindowLayout(model.newNotebook(), {x = -0.12, y = 1.03, expanded = false})}
	modParams = {apasz_noter = {apasz_noter_remember = case.index}}
	local readsBeforeOpen = geometryReads
	local writesBeforeOpen = writeCount
	toolbarButton(root).params.onValueChange(1)
	flush()
	_, view = render()
	expect(view.params.initialX == case.x and view.params.initialY == case.y and windowIsExpanded(view) == case.expanded,
		case.name .. ": reopening applies the mode to an existing saved layout")
	expect(geometryReads == readsBeforeOpen and writeCount == writesBeforeOpen,
		case.name .. ": opening requires no position calibration and does not rewrite saved data")
	windowPosition = {x = -0.06, y = 0.96}
	captureWindowMove(view)
	tooltipButton(view, case.expanded and "Restore normal size" or "Expand window").params.onClick()
	_, view = render()
	expect(windowIsExpanded(view) ~= case.expanded, case.name .. ": resizing updates the open window")
	local movedLayout = model.getWindowLayout(notebook())
	if case.index == 1 then
		expect(writeCount == writesBeforeOpen and geometryReads == readsBeforeOpen
			and movedLayout.x == -0.12 and movedLayout.y == 1.03 and not movedLayout.expanded,
			"Ephemeral moves and size changes neither measure geometry nor change existing saved layout data")
		local composer = assert(find(view, function(node) return node.kind == "TextInputField" end))
		composer.params.onValueChange("Notes remain saved in Ephemeral mode")
		view.params.onPinned(true)
		expect(#notebook().tasks == 1 and notebook().pinned and notebook().windowLayout.x == -0.12,
			"Ephemeral still saves notes and pin preferences without overwriting a remembered layout")
	else
		expect(movedLayout.x == 0 and math.abs(movedLayout.y - 0.96) < 0.000001
			and movedLayout.expanded, case.name .. ": movement and resizing use the selected bounds policy")
		local writesBeforeRepeatedOutside = writeCount
		local readsBeforeRepeatedOutside = geometryReads
		captureWindowMove(view)
		expect(writeCount == writesBeforeRepeatedOutside
			and geometryReads == readsBeforeRepeatedOutside,
			"Remembered ignores expanded window movement without measuring geometry or rewriting the normal anchor")
	end
	view.params.onClose()
	flush()
	root = render()
	toolbarButton(root).params.onValueChange(1)
	flush()
	_, view = render()
	if case.index == 1 then
		expect(view.params.initialX == 0.04 and view.params.initialY == 0.1 and not windowIsExpanded(view),
			"Closing Ephemeral restores the default size and position despite the native moved-window cache")
	else
		expect(view.params.initialX == 0.5 and view.params.initialY == 0.5 and windowIsExpanded(view)
			and notebook().windowLayout.x == movedLayout.x and notebook().windowLayout.y == movedLayout.y,
			case.name .. ": expanded reopenings use centred placement and retain the normal anchor")
	end
	view.params.onClose()
	flush()
	root = render()
end
saveId = "normal-native-reposition"
saves[saveId] = {apasz_noter = model.setWindowLayout(model.newNotebook(), {x = 0.8, y = 0.8, expanded = false})}
modParams = {apasz_noter = {apasz_noter_remember = 2}}
forcedOpeningPosition = {x = 0.6, y = 0.55}
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
forcedOpeningPosition = nil
windowPosition = {x = 0.52, y = 0.42}
captureWindowMove(view)
expect(math.abs(notebook().windowLayout.x - 0.52) < 0.000001
	and math.abs(notebook().windowLayout.y - 0.42) < 0.000001,
	"Dragging after native placement saves the actual normal position without an opening-offset bias")
local writesBeforeResolution = writeCount
local originalViewport = viewportSize
viewportSize = {x = 3200, y = 1800}
captureWindowMove(view)
windowPosition = {x = 0.52 + 0.25 / viewportSize.x, y = 0.42 + 0.25 / viewportSize.y}
captureWindowMove(view)
expect(writeCount == writesBeforeResolution,
	"Resolution changes preserve stationary coordinates and subpixel noise does not dirty saved data")
windowPosition = {x = 0.33, y = 0.27}
captureWindowMove(view)
expect(math.abs(notebook().windowLayout.x - 0.33) < 0.000001
	and math.abs(notebook().windowLayout.y - 0.27) < 0.000001,
	"Both coordinates are captured at the current resolution")
local writesBeforeInvalidGeometry, readsBeforeInvalidReference = writeCount, geometryReads
windowReferenceAvailable = false
captureWindowMove(view)
windowReferenceAvailable = true
windowReferenceExpired = true
captureWindowMove(view)
windowReferenceExpired = false
expect(geometryReads == readsBeforeInvalidReference and writeCount == writesBeforeInvalidGeometry,
	"Missing and expired window references are ignored before accessing geometry")
viewportSize = {x = 0, y = 0}
captureWindowMove(view)
expect(writeCount == writesBeforeInvalidGeometry, "An unavailable viewport cannot overwrite the saved normal position")
viewportSize = originalViewport
windowPosition = {x = 0.48, y = 0.38}
view.params.onClose()
flush()
root = render()
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
expect(math.abs(windowPosition.x - 0.48) < 0.000001 and math.abs(windowPosition.y - 0.38) < 0.000001,
	"Closing without a move notification captures the actual position after native placement")
view.params.onClose()
flush()
root = render()
saveId = "expanded-position"
local normalPosition = {x = 0.24, y = 0.25, expanded = false}
saves[saveId] = {apasz_noter = model.setWindowLayout(model.newNotebook(), normalPosition)}
modParams = {apasz_noter = {apasz_noter_remember = 2}}
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
tooltipButton(view, "Expand window").params.onClick()
_, view = render()
local expandedPosition = {x = 0.04, y = 0.115}
windowPosition = copy(expandedPosition)
local readsBeforeExpandedMove, writesBeforeExpandedMove = geometryReads, writeCount
captureWindowMove(view)
expect(geometryReads == readsBeforeExpandedMove and writeCount == writesBeforeExpandedMove,
	"Moving an expanded window leaves its saved normal position unchanged")
for _, useToolbar in ipairs({false, true, false}) do
	local writesBeforeReopen = writeCount
	if useToolbar then toolbarButton(root).params.onValueChange(0)
	else view.params.onClose() end
	flush()
	root = render()
	toolbarButton(root).params.onValueChange(1)
	flush()
	_, view = render()
	expect(windowIsExpanded(view) and windowPosition.x == 0.5 and windowPosition.y == 0.5
		and notebook().windowLayout.x == normalPosition.x and notebook().windowLayout.y == normalPosition.y
		and geometryReads == readsBeforeExpandedMove and writeCount == writesBeforeReopen,
		"Both close controls reopen expanded windows centred and preserve the saved normal position")
end
-- Expanded state also survives a fresh UI runtime.
view.params.onClose()
flush()
root = render()
instances = {}
toolbar = exports.NoterButton()
root = render()
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
expect(windowIsExpanded(view) and windowPosition.x == 0.5 and windowPosition.y == 0.5,
	"Expanded state survives recreation of the UI runtime with centred placement")
tooltipButton(view, "Restore normal size").params.onClick()
-- Native restoration can place the normal window away from its expanded opening anchor.
windowPosition = {x = normalPosition.x, y = normalPosition.y}
_, view = render()
windowPosition = {x = 0.32, y = 0.28}
captureWindowMove(view)
view.params.onClose()
flush()
root = render()
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
expect(not windowIsExpanded(view) and math.abs(windowPosition.x - 0.32) < 0.000001
	and math.abs(windowPosition.y - 0.28) < 0.000001,
	"Returning to normal size resumes position tracking and remembers normal state on close")
view.params.onClose()
flush()
root = render()
for _, index in ipairs({1, 2}) do
	saveId = "rapid-reopen-" .. tostring(index)
	saves[saveId] = {}
	modParams = {apasz_noter = {apasz_noter_remember = index}}
	toolbarButton(root).params.onValueChange(1)
	flush()
	_, view = render()
	if index == 1 then tooltipButton(view, "Expand window").params.onClick() end
	local composer = assert(find(view, function(node) return node.kind == "TextInputField" end))
	composer.params.onTyping("Discard this draft when closing")
	_, view = render()
	windowPosition = {x = 0.3, y = 0.4}
	notifyWindowMoved(view)
	local staleClose = view.params.onClose
	view.params.onClose()
	local readsAfterClose, writesAfterClose = geometryReads, writeCount
	toolbarButton(root).params.onValueChange(1)
	flush()
	expect(geometryReads == readsAfterClose and writeCount == writesAfterClose,
		"Reopening invalidates queued movement capture before the old window unmounts")
	_, view = render()
	composer = assert(find(view, function(node) return node.kind == "TextInputField" end))
	local expectedX, expectedY = index == 1 and 0.04 or 0.3, index == 1 and 0.1 or 0.4
	expect(not windowIsExpanded(view) and math.abs(windowPosition.x - expectedX) < 0.000001
		and math.abs(windowPosition.y - expectedY) < 0.000001 and composer.params.value == "",
		"Rapid close and reopen creates fresh window state while applying the selected Remember mode")
	staleClose()
	flush()
	_, view = render()
	expect(view ~= nil, "A late close callback cannot close a newer window instance")
	composer = assert(find(view, function(node) return node.kind == "TextInputField" end))
	composer.params.onTyping("Keep this draft while already open")
	toolbarButton(root).params.onValueChange(1)
	flush()
	_, view = render()
	composer = assert(find(view, function(node) return node.kind == "TextInputField" end))
	expect(composer.params.value == "Keep this draft while already open",
		"Repeated open notifications leave the current window and its draft intact")
	view.params.onClose()
	flush()
	root = render()
end
saveId = "remember-1"
for _, index in ipairs({1, 2}) do
	modParams = {apasz_noter = {apasz_noter_remember = index}}
	toolbarButton(root).params.onValueChange(1)
	flush()
	_, view = render()
	local expectedX = index == 1 and 0.04 or 0
	expect(math.abs(view.params.initialX - expectedX) < 0.000001
		and math.abs(notebook().windowLayout.x + 0.12) < 0.000001,
		"Switching Remember modes applies the new policy without discarding saved layout data")
	view.params.onClose()
	flush()
	root = render()
end
modParams = {}
saveId = "legacy"
local legacyText = string.rep("🚂", model.MAX_TEXT_LENGTH + 100)
local legacyNotebook = model.newNotebook()
legacyNotebook.version = 1
legacyNotebook.nextId = 2
legacyNotebook.tasks = {{id = 1, text = legacyText, completed = false}}
saves[saveId] = {apasz_noter = legacyNotebook}
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
expect(taskButton(view, 1).params.content.params.text == legacyText,
	"The preview retains all of an older note's text")
clickTask(view, 1, "DoubleClicked")
_, view = render()
editInput = assert(find(taskRow(view, 1), function(node) return node.kind == "TextInputField" end))
expect(editInput.params.value == legacyText and editInput.params.maxLength >= utf8.len(legacyText)
	and not findButton(view, "Save").params.meta.enabled,
	"An older long note opens intact for editing and cannot be saved above the new limit")
local writesBeforeLegacyCancel = writeCount
editInput.params.onValueChange(legacyText)
pressEscape(editInput)
_, view = render()
expect(notebook().tasks[1].text == legacyText and writeCount == writesBeforeLegacyCancel,
	"Rejected submissions and Cancel preserve an older long note")
findButton(view, "Edit").params.onClick()
_, view = render()
editInput = assert(find(taskRow(view, 1), function(node) return node.kind == "TextInputField" end))
local shortenedText = string.rep("界", model.MAX_TEXT_LENGTH)
editInput.params.onTyping(shortenedText)
_, view = render()
expect(findButton(view, "Save").params.meta.enabled, "Shortening an older note to the limit enables Save")
findButton(view, "Save").params.onClick()
expect(notebook().tasks[1].text == shortenedText, "Saving a shortened older note preserves its Unicode text")
_, view = render()
view.params.onClose()
flush()
root = render()
do
	saveId = "checklist"
	saves[saveId] = {}
	toolbarButton(root).params.onValueChange(1)
	flush()
	_, view = render()
	local function inputWithPlaceholder(placeholder)
		return assert(find(view, function(node)
			return node.kind == "TextInputField" and node.params.placeholderText == placeholder
		end), "Missing input: " .. placeholder)
	end
	local function checkbox(id)
		return assert(find(taskRow(view, id), function(node) return node.kind == "CheckBox" end))
	end
	local function progress(text)
		return find(taskRow(view, 1), function(node)
			return node.kind == "TextView" and node.params.meta.class:find("noter-progress", 1, true)
				and node.params.text == text
		end)
	end
	local function hasRow(id)
		return find(view, function(node)
			return node.params.meta and node.params.meta.id == "noter.notebook.task." .. id
		end) ~= nil
	end
	inputWithPlaceholder("Enter a task").params.onValueChange("Upgrade Central station")
	_, view = render()
	local writesBeforeComposer, focusBeforeComposer = writeCount, focusCount
	findButton(view, "Add subitem").params.onClick()
	_, view = render()
	expect(focusCount == focusBeforeComposer + 1 and writeCount == writesBeforeComposer,
		"Opening a subitem composer focuses it without changing saved notes")
	local itemInput = inputWithPlaceholder("Enter a subitem")
	expect(itemInput.params.resetValueOnCancel == false,
		"A native focus-loss cancellation preserves the text until Add or Cancel resolves the composer")
	itemInput.params.onValueChange("bad\nitem")
	expect(writeCount == writesBeforeComposer, "The subitem composer rejects multiline text before saving")
	pressEscape(itemInput)
	flush()
	_, view = render()
	expect(writeCount == writesBeforeComposer and getButton(view, "Add subitem"),
		"Cancel closes an empty checklist composer without changing the notebook")
	findButton(view, "Add subitem").params.onClick()
	_, view = render()
	itemInput = inputWithPlaceholder("Enter a subitem")
	itemInput.params.onValueChange("First platform 🚉")
	_, view = render()
	expect(#notebook().tasks[1].items == 1 and progress("0/1")
		and inputWithPlaceholder("Enter a subitem").params.value == ""
		and inputWithPlaceholder("Enter a subitem").nodeRef ~= itemInput.nodeRef,
		"Adding a subitem opens a fresh native input ready for another item")
	local writesAfterFirstItem = writeCount
	itemInput.params.onCancel()
	itemInput.params.onValueChange("Duplicate from the old field")
	_, view = render()
	expect(writeCount == writesAfterFirstItem and inputWithPlaceholder("Enter a subitem"),
		"Late cancellation and acceptance from a submitted field cannot close or duplicate the next composer")
	itemInput = inputWithPlaceholder("Enter a subitem")
	pressEscape(itemInput)
	flush()
	_, view = render()
	findButton(view, "Add subitem").params.onClick()
	itemInput.params.onCancel()
	flush()
	_, view = render()
	expect(inputWithPlaceholder("Enter a subitem").nodeRef ~= itemInput.nodeRef,
		"Reopening a subitem composer replaces native editing state and ignores the old cancel callback")
	local focusAfterFirstItem = focusCount
	inputWithPlaceholder("Enter a subitem").params.onTyping("Second platform")
	_, view = render()
	-- Native focus loss and its deferred work finish before the mouse release delivers Add.
	inputWithPlaceholder("Enter a subitem").params.onCancel()
	inputWithPlaceholder("Enter a subitem").params.meta.onFocusChange(false)
	flush()
	_, view = render()
	expect(inputWithPlaceholder("Enter a subitem").params.value == "Second platform",
		"Focus loss preserves the composer and its draft until the later Add click")
	findButton(find(view, function(node)
		return node.kind == "BoxLayout" and find(node, function(child)
			return child.kind == "TextInputField" and child.params.placeholderText == "Enter a subitem"
		end) ~= nil and node.params.meta and node.params.meta.class == "noter-line, noter-fill-width"
	end), "Add").params.onClick()
	flush()
	_, view = render()
	expect(#notebook().tasks[1].items == 2 and focusCount == focusAfterFirstItem + 1
		and taskRow(view, 2).params.meta.class:find("noter-subitem", 1, true) and progress("0/2"),
		"A reopened composer accepts Add after input cancellation, then focuses its next field")
	expect(taskRow(view, 2).kind == "Component" and taskRow(view, 2).params.layout.kind == "BoxLayout",
		"Subitem rows preserve native Component identity around their layout")
	expect(taskRow(view, 2).params.meta.class:find("noter-no-padding", 1, true)
		and taskRow(view, 2).styleClasses:find("noter-no-padding", 1, true),
		"Subitems apply the shared zero-padding class to both native row components")
	local childLayout = taskRow(view, 2).params.layout
	local spacer = childLayout.params.children[1]
	local spacerSize = assignedStyleSizes[spacer.params.meta.styleSheet]
	expect(childLayout.params.orientation == "Horizontal" and spacer.kind == "Component"
		and spacerSize and spacerSize.x > 0 and spacerSize.y == 0
		and childLayout.params.children[2].params.layout.params.orientation == "Vertical",
		"A native spacer reserves horizontal space before the entire subitem row and its actions")
	expect(taskRow(view, 1).params.layout.params.orientation == "Vertical",
		"Parent notes retain their existing layout without a subitem spacer")
	expect(not find(taskRow(view, 2), function(node)
		return node.params.meta and node.params.meta.class == "noter-pin-slot"
	end), "Subitems omit the unused map-marker column so labels stay beside their checkboxes")
	local groupRows = noteGroup(view, 1).params.layout.params.children
	local composer = groupRows[#groupRows]
	local composerSpacer = composer.params.children[1]
	expect(composerSpacer.kind == "Component"
		and composerSpacer.params.meta.styleSheet == spacer.params.meta.styleSheet
		and taskRow(view, 3).params.layout.params.children[1].params.meta.styleSheet == spacer.params.meta.styleSheet,
		"Subitem rows and their composer reuse one native spacer style")
	expect(groupRows[1] == taskRow(view, 1) and groupRows[2] == taskRow(view, 2) and find(composer, function(node)
		return node.kind == "TextInputField" and node.params.placeholderText == "Enter a subitem"
	end), "Each note groups its children together with the composer after the last child")
	expect(taskButton(view, 2).params.content.params.meta.class:find("font-scale-annotation", 1, true)
		and taskButton(view, 1).params.content.params.meta.class:find("font-scale-body", 1, true),
		"Subitems use the game's smaller annotation font while parent notes retain body text")
	inputWithPlaceholder("Enter a subitem").params.onValueChange("Third platform")
	_, view = render()
	expect(#notebook().tasks[1].items == 3 and progress("0/3"),
		"Successive native Enter submissions continue adding items after the second")
	pressEscape(inputWithPlaceholder("Enter a subitem"))
	flush()
	_, view = render()
	local addItemRow = assert(find(noteGroup(view, 1), function(node)
		return node.params.meta and node.params.meta.localKey == "add-item.action.1"
	end))
	expect(not getButton(taskRow(view, 1), "Add subitem")
		and addItemRow.params.meta.class:find("noter-no-padding", 1, true)
		and addItemRow.params.layout.params.children[1].params.meta.styleSheet == spacer.params.meta.styleSheet
		and getButton(addItemRow, "Add subitem"),
		"The checklist plus uses child indentation beneath the list rather than the parent action row")
	clickTask(view, 4)
	_, view = render()
	findButton(taskActions(view, 4), "Delete").params.onClick()
	_, view = render()
	findButton(taskActions(view, 4), "Yes").params.onClick()
	_, view = render()
	checkbox(2).params.onValueChange(1)
	_, view = render()
	expect(checkbox(1).params.value == -1 and progress("1/2") and not notebook().tasks[1].completed
		and view.params.title == "Noter · 1 remaining",
		"Partial progress uses the game's indeterminate checkbox and counts only parent notes")
	checkbox(1).params.onValueChange(0)
	_, view = render()
	expect(checkbox(1).params.value == 1 and checkbox(2).params.value == 1 and checkbox(3).params.value == 1
		and progress("2/2") and view.params.title == "Noter · 0 remaining",
		"The native partial-to-unchecked event checks all children as the parent's bulk action")
	checkbox(1).params.onValueChange(0)
	_, view = render()
	expect(checkbox(2).params.value == 0 and checkbox(3).params.value == 0 and progress("0/2"),
		"Clearing the parent clears every subitem")
	local textButtons, textClasses = {}, {}
	for id = 1, 3 do
		textButtons[id] = taskButton(view, id).nodeRef
		textClasses[id] = taskButton(view, id).params.content.params.meta.class
	end
	local writesBeforeTargeting = writeCount
	local function expectStationaryChecklist(targetId)
		local rows = noteGroup(view, 1).params.layout.params.children
		local actions = assert(taskActions(view, targetId))
		expect(rows[1] == taskRow(view, 1) and rows[2] == taskRow(view, 2) and rows[3] == taskRow(view, 3)
			and rows[4] == actions and actions.params.layout.params.orientation == "Horizontal",
			"Switching targets keeps every checklist row before one consistently indented action bar")
		for id = 1, 3 do
			local textButton = taskButton(view, id)
			expect(textButton.nodeRef == textButtons[id]
				and textButton.params.content.params.meta.class == textClasses[id]
				and not find(taskRow(view, id), function(node)
					return node.params.meta and node.params.meta.class == "noter-actions"
				end), "Target changes preserve native text buttons and wrapping without inserting controls between rows")
		end
		expect(taskRow(view, targetId).params.meta.class:find("noter-selected", 1, true)
			and writeCount == writesBeforeTargeting,
			"Selection stays on the requested checklist entry without changing saved data")
	end
	expectStationaryChecklist(1)
	for _, id in ipairs({2, 2, 3, 2}) do
		clickTask(view, id)
		_, view = render()
		expectStationaryChecklist(id)
	end
	local unselectedItemButton = taskButton(view, 3)
	unselectedItemButton.params.onClick()
	_, view = render()
	expectStationaryChecklist(3)
	local secondItemClick = taskButton(view, 3)
	secondItemClick.params.onClick()
	_, view = render()
	expectStationaryChecklist(3)
	secondItemClick.params.onDoubleClick()
	unselectedItemButton.params.onClick()
	_, view = render()
	itemInput = assert(find(taskRow(view, 3), function(node) return node.kind == "TextInputField" end))
	expect(itemInput.params.value == "Second platform" and not getButton(taskActions(view, 1), "Edit")
		and writeCount == writesBeforeTargeting,
		"Double-clicking an untargeted subitem survives intervening redraws and late single-click callbacks")
	pressEscape(itemInput)
	_, view = render()
	clickTask(view, 2)
	_, view = render()
	expect(getButton(taskActions(view, 2), "Edit") and not getButton(taskRow(view, 2), "Add subitem")
		and not getButton(taskActions(view, 2), "Set point") and not getButton(taskActions(view, 1), "Edit"),
		"Subitems share normal row actions without allowing nested checklists or map points")
	local selectedItemButton = taskButton(view, 2)
	selectedItemButton.params.onClick()
	_, view = render()
	expectStationaryChecklist(2)
	selectedItemButton.params.onDoubleClick()
	selectedItemButton.params.onClick()
	_, view = render()
	itemInput = assert(find(taskRow(view, 2), function(node) return node.kind == "TextInputField" end))
	expect(itemInput.params.value == "First platform 🚉" and writeCount == writesBeforeTargeting,
		"Double-clicking the selected subitem edits that subitem instead of selecting the parent")
	local staleCancel = findButton(taskRow(view, 2), "Cancel")
	clickTask(view, 3)
	itemInput.params.onValueChange("Late save from the previous subitem target")
	staleCancel.params.onClick()
	_, view = render()
	expectStationaryChecklist(3)
	expect(notebook().tasks[1].items[1].text == "First platform 🚉",
		"Late Save and Cancel events cannot change an old subitem or replace the new target before redraw")
	clickTask(view, 2, "DoubleClicked")
	_, view = render()
	itemInput = assert(find(taskRow(view, 2), function(node) return node.kind == "TextInputField" end))
	itemInput.params.onTyping("Extended first platform")
	tooltipButton(view, "Expand window").params.onClick()
	_, view = render()
	itemInput = assert(find(taskRow(view, 2), function(node) return node.kind == "TextInputField" end))
	expect(itemInput.params.value == "Extended first platform" and itemInput.params.placeholderText == "Enter a subitem",
		"Expanding the notebook preserves a subitem edit draft and its native editor")
	findButton(taskRow(view, 2), "Save").params.onClick()
	_, view = render()
	expect(notebook().tasks[1].items[1].text == "Extended first platform"
		and notebook().tasks[1].text == "Upgrade Central station",
		"Saving a child edit changes only its own text")
	tooltipButton(taskActions(view, 2), "Move down").params.onClick()
	_, view = render()
	expect(notebook().tasks[1].items[1].id == 3 and notebook().tasks[1].items[2].id == 2
		and getButton(taskActions(view, 2), "Edit") and not tooltipButton(taskActions(view, 2), "Move down").params.meta.enabled,
		"Reordering retains the selected child and disables its boundary arrow")
	findButton(taskActions(view, 2), "Delete").params.onClick()
	_, view = render()
	expect(find(taskActions(view, 2), function(node)
		return node.kind == "TextView" and node.params.text == "Delete this subitem?"
	end), "Child deletion names the subitem in its confirmation")
	findButton(taskActions(view, 2), "No").params.onClick()
	_, view = render()
	expect(#notebook().tasks[1].items == 2, "Cancelling child deletion preserves the checklist")
	clickTask(view, 1)
	_, view = render()
	findButton(taskActions(view, 1), "Set point").params.onClick()
	flush()
	_, view = render()
	expect(tool ~= nil, "The checklist parent retains its native map picker")
	findButton(noteGroup(view, 1), "Add subitem").params.onClick()
	flush()
	_, view = render()
	expect(tool == nil, "Opening the checklist composer cancels a pending map picker")
	pressEscape(inputWithPlaceholder("Enter a subitem"))
	flush()
	_, view = render()
	checkbox(2).params.onValueChange(1)
	_, view = render()
	view.params.onClose()
	flush()
	root = render()
	toolbarButton(root).params.onValueChange(1)
	flush()
	_, view = render()
	expect(progress("1/2") and checkbox(1).params.value == -1 and not hasRow(2) and not hasRow(3),
		"Reopening restores partial progress while keeping the checklist collapsed")
	clickTask(view, 1)
	_, view = render()
	expect(checkbox(2).params.value == 1 and checkbox(3).params.value == 0
		and notebook().tasks[1].items[1].id == 3,
		"Expanding restores the saved child ordering, text and completion")
	local filter = assert(find(view, function(node) return node.kind == "CheckBox" and node.params.label == "Hide completed" end))
	filter.params.onValueChange(1)
	_, view = render()
	checkbox(3).params.onValueChange(1)
	_, view = render()
	expect(not hasRow(1) and not hasRow(2) and not hasRow(3) and view.params.title == "Noter · 0 remaining",
		"The last tick hides the whole group and clears child selection")
	filter = assert(find(view, function(node) return node.kind == "CheckBox" and node.params.label == "Hide completed" end))
	filter.params.onValueChange(0)
	_, view = render()
	expect(hasRow(1) and not hasRow(2) and progress("2/2"),
		"Showing completed notes restores the parent without resurrecting its temporary selection")
	clickTask(view, 1)
	_, view = render()
	findButton(taskActions(view, 1), "Delete").params.onClick()
	_, view = render()
	expect(find(taskActions(view, 1), function(node)
		return node.kind == "TextView" and node.params.text == "Delete this task and its checklist?"
	end), "Parent deletion explicitly includes its checklist")
	findButton(taskActions(view, 1), "No").params.onClick()
	_, view = render()
	checkbox(3).params.onValueChange(0)
	_, view = render()
	clickTask(view, 3)
	_, view = render()
	findButton(taskActions(view, 3), "Delete").params.onClick()
	_, view = render()
	findButton(taskActions(view, 3), "Yes").params.onClick()
	_, view = render()
	expect(#notebook().tasks[1].items == 1 and notebook().tasks[1].completed
		and getButton(taskActions(view, 1), "Edit") and not hasRow(3),
		"Deleting the selected unchecked child completes the parent and returns selection to it")
	clickTask(view, 2)
	_, view = render()
	findButton(taskActions(view, 2), "Delete").params.onClick()
	_, view = render()
	findButton(taskActions(view, 2), "Yes").params.onClick()
	_, view = render()
	expect(#notebook().tasks[1].items == 0 and notebook().tasks[1].completed and checkbox(1).params.value == 1,
		"Removing the final child leaves a completed ordinary note")
	checkbox(1).params.onValueChange(0)
	_, view = render()
	expect(not notebook().tasks[1].completed, "The ordinary note can be unchecked manually again")
	view.params.onClose()
	flush()
	root = render()
end
do
	local saved = model.addTask(model.newNotebook(), "Checklist note")
	saved = model.addItem(saved, 1, "First subitem")
	saved = model.addItem(saved, 1, "Second subitem")
	saved = model.setItemCompleted(saved, 1, 2, true)
	saved = model.setPoint(saved, 1, terrainPoint)
	saved = model.addTask(saved, "Ordinary note")
	local function openNotebook(parameters)
		modParams = {apasz_noter = parameters}
		toolbarButton(root).params.onValueChange(1)
		flush()
		_, view = render()
		clickTask(view, 1)
		_, view = render()
	end
	local function closeNotebook()
		view.params.onClose()
		flush()
		root = render()
	end
	for _, case in ipairs({
		{name = "Missing subitems parameter", parameters = {}, enabled = true},
		{name = "Subitems on", parameters = {apasz_noter_subitems = 2}, enabled = true},
		{name = "Subitems off", parameters = {apasz_noter_subitems = 1}, enabled = false},
	}) do
		saveId = case.name
		saves[saveId] = {apasz_noter = copy(saved)}
		local writesBeforeOpen = writeCount
		openNotebook(case.parameters)
		local hasSubitems = find(view, function(node)
			return node.kind == "TextView" and node.params.text == "First subitem"
		end) ~= nil
		local hasProgress = find(taskRow(view, 1), function(node)
			return node.kind == "TextView" and node.params.text == "1/2"
		end) ~= nil
		expect(hasSubitems == case.enabled and hasProgress == case.enabled
			and (getButton(view, "Add subitem") ~= nil) == case.enabled,
			case.name .. ": subitems, progress and creation controls follow the setting")
		local restored = notebook()
		expect(writeCount == writesBeforeOpen and restored.nextId == saved.nextId
			and restored.tasks[1].items[1].completed and not restored.tasks[1].items[2].completed,
			case.name .. ": opening and selecting preserve saved subitems and partial completion")
		if not case.enabled then
			findButton(taskActions(view, 1), "Edit").params.onClick()
			_, view = render()
			local parentInput = assert(find(taskRow(view, 1), function(node) return node.kind == "TextInputField" end))
			parentInput.params.onValueChange("Renamed checklist note")
			_, view = render()
			expect(notebook().tasks[1].text == "Renamed checklist note"
				and notebook().tasks[1].items[1].text == "First subitem"
				and notebook().tasks[1].items[2].text == "Second subitem"
				and notebook().tasks[1].items[1].id == 2 and notebook().tasks[1].items[2].id == 3
				and notebook().tasks[1].point.x == terrainPoint.x,
				"Editing a parent while subitems are disabled preserves its checklist and map point")
			local parentCheckbox = assert(find(taskRow(view, 1), function(node) return node.kind == "CheckBox" end))
			expect(parentCheckbox.params.value == -1 and parentCheckbox.params.meta.tooltip == "Check all subitems",
				"A hidden partial checklist retains its parent checkbox state and bulk-action tooltip")
			parentCheckbox.params.onValueChange(0)
			_, view = render()
			expect(notebook().tasks[1].completed and notebook().tasks[1].items[1].completed
				and notebook().tasks[1].items[2].completed,
				"The partial parent checkbox still completes every hidden subitem")
			parentCheckbox = assert(find(taskRow(view, 1), function(node) return node.kind == "CheckBox" end))
			parentCheckbox.params.onValueChange(0)
			_, view = render()
			expect(not notebook().tasks[1].completed and not notebook().tasks[1].items[1].completed
				and not notebook().tasks[1].items[2].completed,
				"The completed parent checkbox still clears every hidden subitem")
			findButton(taskActions(view, 1), "Delete").params.onClick()
			_, view = render()
			expect(find(taskActions(view, 1), function(node)
				return node.kind == "TextView" and node.params.text == "Delete this task and its checklist?"
			end), "Deleting a parent still warns about its hidden checklist")
			findButton(taskActions(view, 1), "No").params.onClick()
			_, view = render()
			local ordinaryCheckbox = assert(find(taskRow(view, 4), function(node) return node.kind == "CheckBox" end))
			ordinaryCheckbox.params.onValueChange(1)
			_, view = render()
			expect(notebook().tasks[2].completed and #notebook().tasks[1].items == 2
				and not getButton(view, "Add subitem"),
				"Ordinary note completion works with subitems disabled and keeps the hidden checklist")
			closeNotebook()
			local writesBeforeEnable = writeCount
			openNotebook({apasz_noter_subitems = 2})
			expect(writeCount == writesBeforeEnable and getButton(view, "Add subitem")
				and taskButton(view, 2).params.content.params.text == "First subitem"
				and taskButton(view, 3).params.content.params.text == "Second subitem"
				and notebook().tasks[1].text == "Renamed checklist note"
				and not notebook().tasks[1].items[1].completed and not notebook().tasks[1].items[2].completed,
				"Re-enabling restores access to the same saved subitems with the updated completion state")
		end
		closeNotebook()
	end
	modParams = {}
end
for locale, texts in pairs(runtime.translations) do
	language = locale
	saveId = "locale_" .. locale
	saves[saveId] = {}
	toolbarButton(root).params.onValueChange(1)
	flush()
	_, view = render()
	expect(view.params.title == langUtil.format(texts.APASZ_NOTER_TITLE_REMAINING, {count = "0"}),
		locale .. ": the title uses the catalogue and formats zero remaining")
	input = assert(find(view, function(node) return node.kind == "TextInputField" end))
	expect(input.params.placeholderText == texts.APASZ_NOTER_ENTER_TASK,
		locale .. ": the task placeholder is translated")
	expect(input.params.meta.tooltip == langUtil.format(texts.APASZ_NOTER_TEXT_LIMIT,
		{count = tostring(model.MAX_TEXT_LENGTH)}), locale .. ": the character limit tooltip is translated")
	tooltipButton(view, texts.APASZ_NOTER_EXPAND).params.onClick()
	_, view = render()
	expect(windowIsExpanded(view), locale .. ": the translated expand control expands the window")
	tooltipButton(view, texts.APASZ_NOTER_NORMAL_SIZE).params.onClick()
	_, view = render()
	expect(not windowIsExpanded(view), locale .. ": the translated restore control returns to normal size")
	input = assert(find(view, function(node) return node.kind == "TextInputField" end))
	local literalNote = "User note · APASZ_NOTER_ADD"
	input.params.onValueChange(literalNote)
	_, view = render()
	expect(view.params.title == langUtil.format(texts.APASZ_NOTER_TITLE_REMAINING, {count = "1"})
		and notebook().tasks[1].text == literalNote,
		locale .. ": the title formats one remaining while user notes stay literal")
	for _, action in ipairs({
		{texts.APASZ_NOTER_ADD, "::/gui/line_vehicle_mgmt/icons/add.tga"},
		{texts.APASZ_NOTER_ADD_ITEM, "::/gui/line_vehicle_mgmt/icons/add.tga"},
		{texts.APASZ_NOTER_EDIT, "::/gui/builtin/window/icons/symbol_pencil.tga"},
		{texts.APASZ_NOTER_MOVE_UP, "::/gui/builtin/spinbox/arrow_up.tga"},
		{texts.APASZ_NOTER_MOVE_DOWN, "::/gui/builtin/spinbox/arrow_down.tga"},
		{texts.APASZ_NOTER_SET_POINT, "::/gui/builtin/window/icons/symbol_locate.tga"},
		{texts.APASZ_NOTER_DELETE, "::/gui/menu/icons/trash.tga"},
	}) do
		expectIconButton(view, action[1], action[2])
	end
	findButton(view, texts.APASZ_NOTER_SET_POINT).params.onClick()
	flush()
	_, view, selector = render()
	expect(find(view, function(node)
		return node.kind == "TextView" and node.params.text == texts.APASZ_NOTER_PICK_POINT_PROMPT
	end), locale .. ": the map-picker prompt is translated")
	expectIconButton(view, texts.APASZ_NOTER_CANCEL, "::/gui/builtin/window/icons/cross_thin.tga")
	findButton(view, texts.APASZ_NOTER_CANCEL).params.onClick()
	flush()
	_, view = render()
	findButton(view, texts.APASZ_NOTER_DELETE).params.onClick()
	_, view = render()
	expect(getButton(view, texts.APASZ_NOTER_YES) and getButton(view, texts.APASZ_NOTER_NO)
		and find(view, function(node)
			return node.kind == "TextView" and node.params.text == texts.APASZ_NOTER_DELETE_CONFIRM
		end), locale .. ": delete confirmation and choices are translated")
	findButton(view, texts.APASZ_NOTER_NO).params.onClick()
	_, view = render()
	input = assert(find(view, function(node) return node.kind == "TextInputField" end))
	input.params.onValueChange("Second literal task")
	_, view = render()
	expect(view.params.title == langUtil.format(texts.APASZ_NOTER_TITLE_REMAINING, {count = "2"}),
		locale .. ": the title formats multiple remaining")
	findButton(noteGroup(view, 2), texts.APASZ_NOTER_ADD_ITEM).params.onClick()
	_, view = render()
	local itemInput = assert(find(view, function(node)
		return node.kind == "TextInputField" and node.params.placeholderText == texts.APASZ_NOTER_ENTER_ITEM
	end))
	itemInput.params.onValueChange("Literal checklist item · APASZ_NOTER_ADD_ITEM")
	_, view = render()
	findButton(view, texts.APASZ_NOTER_CANCEL).params.onClick()
	_, view = render()
	expect(notebook().tasks[2].items[1].text == "Literal checklist item · APASZ_NOTER_ADD_ITEM",
		locale .. ": checklist user text stays literal while its composer is translated")
	expect(taskButton(view, 2).params.meta.tooltip == texts.APASZ_NOTER_TASK_ACTIONS_TOOLTIP
		and taskButton(view, 3).params.meta.tooltip == texts.APASZ_NOTER_TASK_ACTIONS_TOOLTIP,
		locale .. ": notes and subitems initially show translated mouse guidance")
	_, view = renderInputMode(true)
	expect(taskButton(view, 2).params.meta.tooltip == texts.APASZ_NOTER_TASK_ACTIONS_CONTROLLER_TOOLTIP
		and taskButton(view, 3).params.meta.tooltip == texts.APASZ_NOTER_TASK_ACTIONS_CONTROLLER_TOOLTIP,
		locale .. ": notes and subitems switch to translated controller guidance while open")
	_, view = renderInputMode(false)
	expect(taskButton(view, 2).params.meta.tooltip == texts.APASZ_NOTER_TASK_ACTIONS_TOOLTIP
		and taskButton(view, 3).params.meta.tooltip == texts.APASZ_NOTER_TASK_ACTIONS_TOOLTIP,
		locale .. ": notes and subitems restore translated mouse guidance while open")
	clickTask(view, 3)
	_, view = render()
	findButton(taskActions(view, 3), texts.APASZ_NOTER_DELETE).params.onClick()
	_, view = render()
	expect(find(taskActions(view, 3), function(node)
		return node.kind == "TextView" and node.params.text == texts.APASZ_NOTER_DELETE_ITEM_CONFIRM
	end), locale .. ": subitem deletion confirmation is translated")
	findButton(taskActions(view, 3), texts.APASZ_NOTER_NO).params.onClick()
	_, view = render()
	clickTask(view, 2)
	_, view = render()
	findButton(taskActions(view, 2), texts.APASZ_NOTER_DELETE).params.onClick()
	_, view = render()
	expect(find(taskActions(view, 2), function(node)
		return node.kind == "TextView" and node.params.text == texts.APASZ_NOTER_DELETE_CHECKLIST_CONFIRM
	end), locale .. ": deleting a parent names its checklist in the translated confirmation")
	findButton(taskActions(view, 2), texts.APASZ_NOTER_NO).params.onClick()
	_, view = render()
	local parentCheckbox = assert(find(taskRow(view, 2), function(node) return node.kind == "CheckBox" end))
	expect(parentCheckbox.params.meta.tooltip == texts.APASZ_NOTER_CHECK_ALL,
		locale .. ": the incomplete checklist's bulk action is translated")
	parentCheckbox.params.onValueChange(1)
	_, view = render()
	parentCheckbox = assert(find(taskRow(view, 2), function(node) return node.kind == "CheckBox" end))
	expect(parentCheckbox.params.meta.tooltip == texts.APASZ_NOTER_UNCHECK_ALL
		and find(taskRow(view, 2), function(node)
			return node.kind == "TextView" and node.params.text == langUtil.format(texts.APASZ_NOTER_CHECKLIST_PROGRESS,
				{completed = "1", total = "1"})
		end), locale .. ": completed checklist progress and the clear-all action use the catalogue")
	view.params.onClose()
	flush()
	root = render()
end
for _, invalidValue in ipairs({0, 3, -1, 0.5, "1", true}) do
	modParams = {apasz_noter = {apasz_noter_subitems = invalidValue}}
	toolbarButton(root).params.onValueChange(1)
	flush()
	local ok, invalidParameter = pcall(render)
	expect(not ok and tostring(invalidParameter):find("[Noter] ERROR: Invalid apasz_noter_subitems parameter:", 1, true),
		"Invalid subitems parameters fail explicitly instead of hiding or showing saved subitems")
	toolbarButton(root).params.onValueChange(0)
	flush()
	root = render()
end
for _, invalidValue in ipairs({0, 3, -1, 0.5, "1", true}) do
	modParams = {apasz_noter = {apasz_noter_opaque_window = invalidValue}}
	toolbarButton(root).params.onValueChange(1)
	flush()
	local ok, invalidParameter = pcall(render)
	expect(not ok and tostring(invalidParameter):find("[Noter] ERROR: Invalid apasz_noter_opaque_window parameter:", 1, true),
		"Invalid opacity parameters fail explicitly instead of choosing an appearance")
	toolbarButton(root).params.onValueChange(0)
	flush()
	root = render()
end
for _, invalidValue in ipairs({0, 3, -1, 1.5, "2", false, math.huge}) do
	modParams = {apasz_noter = {apasz_noter_remember = invalidValue}}
	toolbarButton(root).params.onValueChange(1)
	local ok, invalidParameter = pcall(flush)
	expect(not ok and tostring(invalidParameter):find("[Noter] ERROR: Invalid remember parameter:", 1, true),
		"Invalid Remember parameters fail explicitly instead of silently selecting a mode")
	toolbarButton(root).params.onValueChange(0)
	flush()
	root = render()
end
print(string.format("Notebook UI interactions (debug %s): %d checks passed",
	runtime.debugLoggingEnabled and "enabled" or "disabled", checks))
