local runtime, uiCode, modRoot = ...
local reorderChecks = 0
local model = setmetatable({canMoveTask = function(...)
	reorderChecks = reorderChecks + 1
	return runtime.model.canMoveTask(...)
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

local instances, context, joins, recipes = {}, nil, {}, {}
local builtinKinds = {}
local layoutKinds = {BoxLayout = true, FlowLayout = true, FloatingLayout = true, TableLayout = true, AbsoluteLayout = true}
local window, tool, toolbar
local toolStack = {}
local saveId = "first"
local saves = {first = {}, second = {}}
local writeCount = 0
local terrainAvailable = true
local terrainPoint = {x = 120, y = -30, z = 8}
local located
local flashes = {}
local focusCount = 0
local windowApiAvailable = true
local toolStackAvailable = true
local language = "en"

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
	}
end

local function recipe(name, fn, wrappedKind)
	local registered = {name = name, fn = fn, wrappedKind = wrappedKind}
	recipes[name] = registered
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
	useNodeRef = function()
		return hook(function()
			return {get = function() return {focus = function() focusCount = focusCount + 1 end} end}
		end)
	end,
	ref = function(ref) return {nodeRef = ref} end,
	useSelfRef = function()
		return hook(function()
			return {get = function()
				return {containsPosition = function(_, position) return position.x >= 0 and position.y >= 0 end}
			end}
		end)
	end,
	onMount = function(fn) context.mount[#context.mount + 1] = fn end,
	onMouseEvent = function(fn) context.mouseEvents[#context.mouseEvents + 1] = fn end,
	onUnmount = function(fn) context.unmount[#context.unmount + 1] = fn end,
	enqueueJoin = function(fn) joins[#joins + 1] = fn end,
	iaHandler = function(fn) return fn end,
	useInputAction = function(name, fn) context.inputActions[name] = fn end,
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

local builtins = {type = {Orientation = {Horizontal = "Horizontal", Vertical = "Vertical"},
	ScrollBarPolicy = {AlwaysOff = "AlwaysOff", AsNeeded = "AsNeeded"}}}
for _, name in ipairs({"TextView", "ImageView", "Button", "BoxLayout", "Component", "TextInputField", "ToggleButton", "CheckBox", "Selector", "ActionDescriptor", "ScrollArea", "Window"}) do
	builtins[name] = function(first, second) return {kind = name, params = second or first} end
	builtinKinds[builtins[name]] = name
end

local windows = {
	addSingletonWindow = function(windowRecipe, params)
		assert(windowRecipe.wrappedKind == "Window", "Window container needs a native window wrapper")
		window = windowRecipe(params)
	end,
	removeAllWindows = function() window = nil end,
	moveSingletonWindowToFront = function() end,
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
			["/noter/model.tl"] = model,
			["/noter/logger.tl"] = runtime.logger,
			["::/scripts/lang_util.tl"] = langUtil,
			["::/gui/main/main_mod_button_area.tl"] = {MainModButtonAreaExtension = {}},
		}
		return assert(dependencies[path], "Unexpected UI dependency: " .. path)
	end,
	api = {
		gui = {
			spawnEphemeralHudImage = function(icon, entity, color, position, duration, fadeIn, fadeOut)
				flashes[#flashes + 1] = {icon = icon, entity = entity, color = color, position = position,
					duration = duration, fadeIn = fadeIn, fadeOut = fadeOut}
			end,
			game = {
				getGuiSaveData = function(modId) return copy(saves[saveId][modId] or {}) end,
				setGuiSaveData = function(modId, value)
					saves[saveId][modId] = copy(value)
					writeCount = writeCount + 1
				end,
			},
			byId = {setVisible = function() end},
			mouse = {hasTerrainPosition = function() return terrainAvailable end,
				getTerrainPosition = function() return terrainPoint end,
				Event = {Type = {Clicked = "Clicked", DoubleClicked = "DoubleClicked"}}},
			camera = {getCameraData = function() return {z = 700} end,
				setManualCamera = function(center, distance) located = {center = center, distance = distance} end},
		},
		type = {
			Vec2i = {new = function(x, y) return {x = x, y = y} end},
			Vec2f = {new = function(x, y) return {x = x, y = y} end},
			Vec3f = {new = function(x, y, z) return {x = x, y = y, z = z} end},
		},
		cmd = {sendCommand = function() error("Notebook edits must not need simulation commands") end},
	},
}, {__index = _G})

local exports = assert(load(uiCode, "@ui.script.tl", "t", environment))()
toolbar = exports.NoterButton()

local function resolve(node, path, visited, hasActionDescriptor)
	if node.kind == "recipe" then
		local key = path .. "/" .. node.recipe.name .. "/" .. (node.params.meta and node.params.meta.localKey or "")
		local isNew = instances[key] == nil
		local instance = instances[key] or {slots = {}}
		instances[key] = instance
		visited[key] = true
		instance.cursor, instance.unmount, instance.inputActions, instance.mount, instance.mouseEvents = 0, {}, {}, {}, {}
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
		if isNew then for _, fn in ipairs(instance.mount) do fn() end end
		return resolved
	end
	if node.kind == "Selector" then
		assert(hasActionDescriptor, "Selector requires an enclosing ActionDescriptor")
	end
	local insideActionDescriptor = hasActionDescriptor or node.kind == "ActionDescriptor"
	local result = {kind = node.kind, params = {}}
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
	local notebookWindow = window and resolve(window, "window", visited)
	local action = tool and resolve(tool.action(), "tool/" .. tool.key, visited)
	if action then assert(action.kind == "ActionDescriptor", "Tool actions must return an action descriptor") end
	local selector = find(action, function(node) return node.kind == "Selector" end)
	local removed = {}
	for key, instance in pairs(instances) do
		if not visited[key] then removed[#removed + 1] = key; for _, fn in ipairs(instance.unmount) do fn() end end
	end
	for _, key in ipairs(removed) do instances[key] = nil end
	flush()
	return root, notebookWindow, selector, action
end

local function getButton(root, text)
	return find(root, function(node)
		return node.kind == "Button" and find(node.params.content, function(child)
			return child.kind == "TextView" and child.params.text == text
		end) ~= nil
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

local function taskRow(root, id)
	return assert(find(root, function(node)
		local meta = node.params.meta
		return meta and meta.localKey == tostring(id) and meta.class and meta.class:find("noter-row", 1, true)
	end), "Missing task row: " .. id)
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
local writesBeforeNoop = writeCount
view.params.onPinned(false)
local hide = assert(find(view, function(node) return node.kind == "CheckBox" and node.params.label == "Hide completed" end))
hide.params.onValueChange(0)
expect(writeCount == writesBeforeNoop, "Unchanged native preference events do not dirty the save")
local input = assert(find(view, function(node) return node.kind == "TextInputField" end))
input.params.onTyping("Extend the railway")
findButton(view, "Add").params.onClick()
expect(#notebook().tasks == 1, "Add uses latest typed text before rerender")
_, view = render()
expect(view.params.title == "Noter · 1 remaining", "Adding updates the title count")
input = assert(find(view, function(node) return node.kind == "TextInputField" end))
expect(input.params.value == "", "Composer clears after adding")
input.params.onValueChange("Buy a train")
_, view = render()
expect(not getButton(taskRow(view, 1), "Edit") and getButton(taskRow(view, 2), "Edit"),
	"Only the selected task shows its actions")
expect(reorderChecks == 2, "Only the expanded task checks its two reorder directions")
expect(tooltipButton(taskRow(view, 2), "Move up").params.content.kind == "ImageView"
	and not tooltipButton(taskRow(view, 2), "Move down").params.meta.enabled,
	"Reordering uses arrow icons, tooltips, and boundary disabling")
local complete = assert(find(view, function(node)
	return node.kind == "CheckBox" and node.params.meta and node.params.meta.tooltip == "Mark complete"
end))
complete.params.onValueChange(1)
view.params.onPinned(true)
expect(notebook().tasks[1].completed and notebook().pinned, "Same-frame writes do not overwrite one another")
local writesBeforeRepeatedCompletion = writeCount
complete.params.onValueChange(1)
expect(writeCount == writesBeforeRepeatedCompletion, "Repeated completion events do not rewrite GUI save data")
_, view = render()
expect(view.params.title == "Noter · 1 remaining", "Completion updates the title count")
expect(find(view, function(node) return node.kind == "TextView" and node.params.text == "Completed" end),
	"Completed heading renders without shadowing localization")
hide = assert(find(view, function(node) return node.kind == "CheckBox" and node.params.label == "Hide completed" end))
hide.params.onValueChange(1)
_, view = render()
expect(notebook().hideCompleted and not find(view, function(node)
	return node.kind == "TextView" and node.params.text == "Extend the railway"
end), "Hide completed removes finished tasks from the window")
hide = assert(find(view, function(node) return node.kind == "CheckBox" and node.params.label == "Hide completed" end))
hide.params.onValueChange(0)
_, view = render()
local setPointContent = findButton(view, "Set point").params.content.params.children
expect(setPointContent[1].kind == "ImageView"
	and setPointContent[1].params.path == "::/gui/builtin/window/icons/symbol_pin_18.tga"
	and setPointContent[2].params.text == "Set point",
	"Set point shows the pin icon alongside its translated label")
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
local changePointContent = findButton(view, "Change point").params.content.params.children
expect(changePointContent[1].params.path == setPointContent[1].params.path
	and changePointContent[2].params.text == "Change point",
	"Change point keeps the same pin icon and its own translated label")
local linkedRow = taskRow(view, 2)
local linkedLine = linkedRow.params.children[1].params.children
expect(linkedLine[1].kind == "CheckBox" and linkedLine[2].params.meta.class == "noter-point-column"
	and tooltipButton(linkedLine[2], "Go to map point")
	and linkedLine[3].params.meta.class == "noter-task-button",
	"The pin column is directly after the checkbox and before the task text")
local unlinkedLine = taskRow(view, 1).params.children[1].params.children
expect(unlinkedLine[2].params.meta.class == "noter-point-column"
	and unlinkedLine[2].params.layout == nil,
	"Unlinked tasks keep an empty pin column to align the text")
local writesBeforeGo = writeCount
tooltipButton(linkedRow, "Go to map point").params.onClick()
expect(located.center.x == 120 and located.center.y == -30 and located.distance == 700,
	"The pin navigates to the point at the current zoom")
expect(#flashes == 2 and writeCount == writesBeforeGo, "The pin highlights the point without changing saved data")
_, view = render()
expect(getButton(taskRow(view, 2), "Edit"), "Using the pin does not toggle the row's actions")
local writesBeforeSelection = writeCount
clickTask(view, 2)
_, view = render()
expect(not getButton(taskRow(view, 2), "Edit"), "Clicking the selected task collapses its actions")
expect(reorderChecks == 0, "Compact task lists perform no reorder scans")
-- Native Button activation uses the same onClick callback for controller Select.
taskButton(view, 2).params.onClick()
_, view = render()
expect(getButton(taskRow(view, 2), "Edit") and writeCount == writesBeforeSelection,
	"Controller Select can expand task actions without changing saved data")
taskButton(view, 2).params.onClick()
_, view = render()
expect(not getButton(taskRow(view, 2), "Edit"), "Controller Select toggles task actions closed again")
expect(clickTask(view, 1), "Clicking a task selects it")
_, view = render()
expect(getButton(taskRow(view, 1), "Edit") and not getButton(taskRow(view, 2), "Edit"),
	"Changing selection collapses the previous row")
findButton(view, "Set point").params.onClick()
flush()
_, view, selector = render()
selector.params.onProcessMouseEvent({type = "Clicked", button = 2})
expect(not selector.params.onSelect(1, {}, {}), "Canceled picker ignores further selection in the same frame")
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
expect(tool == nil and not getButton(taskRow(view, 1), "Edit"),
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
_, view, selector = render()
local escape
for _, instance in pairs(instances) do escape = escape or instance.inputActions.IA_MENU_BACK end
assert(escape, "Picker must bind Escape/back")()
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
local row = taskRow(view, 2)
local editInput = assert(find(row, function(node) return node.kind == "TextInputField" end))
expect(tooltipButton(row.params.children[1].params.children[2], "Go to map point")
	and #row.mouseEvents == 0,
	"Editing preserves the pin column and leaves mouse handling to native editor controls")
editInput.params.onTyping("Upgrade the railway")
editor.params.onClick()
expect(notebook().tasks[1].text == "Upgrade the railway", "Save commits the edited text")
_, view = render()
findButton(taskRow(view, 2), "Edit").params.onClick()
_, view = render()
row = taskRow(view, 2)
editInput = assert(find(row, function(node) return node.kind == "TextInputField" end))
local writesBeforeCancel = writeCount
editInput.params.onTyping("Discard this change")
expect(not find(row, function(node)
	return node.kind == "Button" and node.params.meta.class == "noter-task-button"
end), "The editing row has no selection button that could discard its draft")
editInput.params.onCancel()
_, view = render()
expect(notebook().tasks[1].text == "Upgrade the railway" and writeCount == writesBeforeCancel
	and not getButton(view, "Save"), "Escape cancels an edit without saving")
clickTask(view, 2, "DoubleClicked")
_, view = render()
editInput = assert(find(taskRow(view, 2), function(node) return node.kind == "TextInputField" end))
editInput.params.onValueChange("Upgrade both platforms")
_, view = render()
expect(notebook().tasks[1].text == "Upgrade both platforms" and not getButton(view, "Save"),
	"Enter accepts the edit and returns to the compact row")

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
view.params.onClose()
flush()
root = render()
expect(window == nil and toolbarButton(root).params.value == 0, "Close updates the toolbar toggle")
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
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
saveId = "second"
root = render()
toolbarButton(root).params.onValueChange(1)
flush()
_, view = render()
expect(#notebook().tasks == 0 and #saves.first.apasz_noter.tasks == 1, "Saves have independent notebooks")

if runtime.debugLoggingEnabled then
	local messages = {}
	for _, entry in ipairs(runtime.entries) do
		expect(entry.level == "verbose" and entry.message:find("[Noter] ", 1, true) == 1,
			"Enabled debug messages use the native verbose API and the Noter prefix")
		messages[entry.message] = true
	end
	expect(messages["[Noter] Opened notebook"] and messages["[Noter] Closed notebook"]
		and messages["[Noter] Started map point picker for task 2"]
		and messages["[Noter] Selected map point: x=120.00, y=-30.00, z=8.00"]
		and messages["[Noter] Canceled map point selection"]
		and messages["[Noter] Updated notebook GUI save data: 2 tasks, 1 remaining"],
		"Enabled debug logging covers window, save-data and map-picker activity")
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

local palette = {NeutralMedium = {0.4, 0.5, 0.6, 1}, NeutralLightest = {0.9, 0.8, 0.7, 1},
	AccentMedium = {0.1, 0.3, 0.5, 1}}
local rules = {}
local styleEnv = {
	require = function(path)
		if path == "::/gui/main/stylesheetutil.lua" then
			return {makeAdder = function()
				return function(selector, style) rules[selector] = style end
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
local scope = "Window#noter.notebook "
expect(rules[scope .. "!noter-row"].borderWidth[4] > 0, "Task rows have a separator")
expect(rules[scope .. "!noter-selected"].backgroundColor1[2] == palette.AccentMedium[2],
	"Selection uses the active theme's accent colour")
expect(rules[scope .. "!noter-point-column"].size[1] == 24,
	"Linked and unlinked rows reserve the same fixed pin column width")
local completedColor = rules[scope .. "!noter-completed TextView!noter-text"].color
expect(completedColor[1] == palette.NeutralLightest[1] and completedColor[4] < palette.NeutralLightest[4],
	"Completed text is dimmed using the active theme")

windowApiAvailable = true
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
	local literalNote = "User note · APASZ_NOTER_ADD"
	input.params.onValueChange(literalNote)
	_, view = render()
	expect(view.params.title == langUtil.format(texts.APASZ_NOTER_TITLE_REMAINING, {count = "1"})
		and notebook().tasks[1].text == literalNote,
		locale .. ": the title formats one remaining while user notes stay literal")
	findButton(view, texts.APASZ_NOTER_SET_POINT).params.onClick()
	flush()
	_, view, selector = render()
	expect(find(view, function(node)
		return node.kind == "TextView" and node.params.text == texts.APASZ_NOTER_PICK_POINT_PROMPT
	end), locale .. ": the map-picker prompt is translated")
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
	view.params.onClose()
	flush()
	root = render()
end
print(string.format("Notebook UI interactions (debug %s): %d checks passed",
	runtime.debugLoggingEnabled and "enabled" or "disabled", checks))
