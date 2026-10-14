local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local react = ug_require "::/gui/main/react.lua" as React
local globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local lang_util = ug_require "::/scripts/lang_util.tl" as LangUtil
local model = ug_require "/noter/model.tl" as NoterModel
local logger = ug_require "/noter/logger.tl" as ModLogging.Logger

local MOD_ID = getOwningModId()
local WINDOW_ID = "noter.notebook"
local WINDOW_INITIAL_X = 0.04
local WINDOW_INITIAL_Y = 0.1
local JOIN_SCOPE = "Noter"
local POINT_PICKER_TOOL = "NoterPointPicker"
local LEFT_MOUSE_BUTTON = 0
local RIGHT_MOUSE_BUTTON = 2
local NOTE_ICON = "::/gui/menu/icons/list.tga"
local LOCATION_ICON = "::/gui/builtin/window/icons/symbol_pin_18.tga"
local POINT_FEEDBACK_SECONDS = 3
local REORDER_ICONS <total> : {NoterModel.MoveDirection : string} = {
	Up = "::/gui/component/table_arrow_up.tga",
	Down = "::/gui/component/table_arrow_down.tga",
}
local nextPickerId = 0

local enum RowMode
	"View"
	"Edit"
	"ConfirmDelete"
end

local record TaskInteraction
	id : integer
	mode : RowMode
end

local function label(text : string, class? : string) : TreeNodeId
	return builtin.TextView{meta = {class = "font-scale-body, " .. (class or "")}, text = text}
end

local function horizontal(children : {TreeNodeId}) : TreeNodeId
	return builtin.BoxLayout{
		meta = {class = "noter-line"}, orientation = builtin.type.Orientation.Horizontal, children = children,
	}
end

local function button(text : string, onClick : function(), enabled? : boolean, iconPath? : string, showIconLabel? : boolean) : TreeNodeId
	local content : TreeNodeId
	if iconPath then
		local icon = builtin.ImageView{meta = {class = "noter-icon"}, path = iconPath}
		content = showIconLabel and horizontal{icon, label(text)} or icon
	else
		content = label(text)
	end
	return builtin.Button{
		meta = {
			enabled = enabled == nil or enabled,
			class = iconPath and not showIconLabel and "noter-icon-button" or nil,
			tooltip = iconPath and not showIconLabel and text or nil,
		},
		content = content,
		onClick = onClick,
	}
end

local function flashPoint(point : NoterModel.Point)
	api.gui.spawnEphemeralHudImage(LOCATION_ICON, nil, nil,
		api.type.Vec3f.new(point.x, point.y, point.z), POINT_FEEDBACK_SECONDS, true, true)
end

local function goToPoint(point : NoterModel.Point)
	local camera = api.gui.camera.getCameraData()
	api.gui.camera.setManualCamera(api.type.Vec2f.new(point.x, point.y), camera.z)
	flashPoint(point)
end

local record EditorParams
	initialText : string
	submitLabel : string
	clearAfterSubmit : boolean
	onSubmit : function(string)
	onCancel : function() | nil
end

local TextEditor = react.RegisterRecipe("NoterTextEditor", function(params : EditorParams) : TreeNodeId
	local draft : ReactStateT<string> = react.useState(params.initialText)
	local draftRef = react.useMirrorRef(draft)
	local input = react.useNodeRef(builtin.TextInputField)
	react.onMount(function() input:get():focus() end)
	local function submit(text : string)
		if not model.canSubmitText(text) then return end
		params.onSubmit(text)
		if params.clearAfterSubmit then
			draftRef:set("")
			draft:set("")
		end
	end
	local children = {
		builtin.TextInputField(react.ref(input), {
			meta = {class = "font-scale-body, " .. (params.clearAfterSubmit and "noter-input" or "noter-edit-input")},
			value = draft:old(), placeholderText = _("APASZ_NOTER_ENTER_TASK"),
			onTyping = function(text : string)
				draftRef:set(text)
				draft:set(text)
			end,
			onValueChange = submit,
			acceptOnFocusLoss = false,
			popFocusOnStopEditing = not params.clearAfterSubmit,
			onCancel = params.onCancel,
		}),
		button(params.submitLabel, function() submit(draftRef:get()) end, model.canSubmitText(draft:old())),
	}
	if params.onCancel then children[#children + 1] = button(_("APASZ_NOTER_CANCEL"), params.onCancel) end
	return horizontal(children)
end)

local record PickerRequest
	key : string | nil
	active : boolean
end

local record PickerParams
	request : PickerRequest
	onPoint : function(NoterModel.Point)
	onFinish : function()
end

local record PickerActionParams
	request : PickerRequest
	onPoint : function(NoterModel.Point)
	onCancel : function()
end

local PickerAction = react.RegisterWrapperRecipe("NoterPointPickerAction", builtin.ActionDescriptor, function(params : PickerActionParams) : TreeNodeId
	react.onUnmount(function() params.request.active = false end)
	local function pick() : boolean
		if not params.request.active or not api.gui.mouse.hasTerrainPosition() then return false end
		local point = api.gui.mouse.getTerrainPosition()
		params.request.active = false
		logger.debug(string.format("Selected map point: x=%.2f, y=%.2f, z=%.2f", point.x, point.y, point.z))
		params.onPoint({x = point.x, y = point.y, z = point.z})
		return true
	end
	local function cancel()
		if not params.request.active then return end
		params.request.active = false
		logger.debug("Canceled map point selection")
		params.onCancel()
	end
	react.useInputAction("IA_MENU_BACK", react.iaHandler(cancel))
	local selector = builtin.Selector{
		stopOnMenuBack = false,
		onSelect = function(_entity : Engine.Entity, _indices : {integer}, _details : Gui.SelectionDetails) : boolean
			return pick()
		end,
		onProcessMouseEvent = function(event : Gui.Mouse.Event) : boolean
			if event.handled or event.type ~= api.gui.mouse.Event.Type.Clicked then return false end
			if event.button == RIGHT_MOUSE_BUTTON then
				cancel()
				return true
			elseif event.button == LEFT_MOUSE_BUTTON then
				return pick()
			end
			return false
		end,
	}
	return builtin.ActionDescriptor{
		tool = POINT_PICKER_TOOL,
		terrainCirclePolicy = "Never",
		onBack = cancel,
		children = {selector},
	}
end)

local PointPicker = react.RegisterTool({
	name = POINT_PICKER_TOOL,
	push = function(context : Builtin.ToolStackContext<PickerParams>, params : PickerParams)
		local function finish()
			react.enqueueJoin(function() context.popSelf() end, JOIN_SCOPE)
		end
		context.setActionFn(function() : TreeNodeId
			return PickerAction{
				request = params.request,
				onPoint = function(point : NoterModel.Point)
					params.onPoint(point)
					finish()
				end,
				onCancel = finish,
			}
		end)
	end,
	pop = function(_context : Builtin.ToolStackContext<PickerParams>, params : PickerParams)
		params.request.active = false
		params.onFinish()
	end,
	shelve = function(context : Builtin.ToolStackContext<PickerParams>, params : PickerParams, shelved : boolean)
		if shelved then
			params.request.active = false
			react.enqueueJoin(function() context.popSelf() end, JOIN_SCOPE)
		end
	end,
})

local record TaskRowParams
	task : NoterModel.Task
	selected : boolean
	mode : RowMode
	canMoveUp : boolean
	canMoveDown : boolean
	onToggle : function()
	onMode : function(RowMode)
	onText : function(string)
	onCompleted : function(boolean)
	onMove : function(NoterModel.MoveDirection)
	onRemove : function()
	onPickPoint : function()
	onClearPoint : function()
end

local TaskRow = react.RegisterRecipe("NoterTaskRow", function(params : TaskRowParams) : TreeNodeId
	local task = params.task
	local pointButton : TreeNodeId | nil = nil
	if task.point then
		local point = task.point as NoterModel.Point
		pointButton = button(_("APASZ_NOTER_GO_TO_POINT"), function() goToPoint(point) end, true, LOCATION_ICON)
	end
	local line = {
		builtin.CheckBox{
			meta = {tooltip = task.completed and _("APASZ_NOTER_MARK_INCOMPLETE") or _("APASZ_NOTER_MARK_COMPLETE")},
			value = task.completed and 1 or 0,
			onValueChange = function(value : integer) params.onCompleted(value == 1) end,
		},
		builtin.Component{
			meta = {class = "noter-point-column"}, layout = pointButton and horizontal{pointButton} or nil,
		},
	}
	if params.mode == "Edit" then
		line[#line + 1] = TextEditor{
			initialText = task.text, submitLabel = _("APASZ_NOTER_SAVE"), clearAfterSubmit = false,
			onSubmit = function(text : string) params.onText(text); params.onMode("View") end,
			onCancel = function() params.onMode("View") end,
		}
	else
		line[#line + 1] = builtin.Button{
			meta = {class = "noter-task-button", tooltip = _("APASZ_NOTER_TASK_ACTIONS_TOOLTIP")},
			content = builtin.TextView{
				meta = {class = "font-scale-body, noter-text"}, text = task.text, tooltipWhenClipped = task.text,
			},
			onClick = params.onToggle,
			onDoubleClick = function() params.onMode("Edit") end,
		}
	end
	local children = {horizontal(line)}
	if params.selected and params.mode ~= "Edit" then
		local actions : {TreeNodeId}
		if params.mode == "ConfirmDelete" then
			actions = {
				label(_("APASZ_NOTER_DELETE_CONFIRM")), button(_("APASZ_NOTER_YES"), params.onRemove),
				button(_("APASZ_NOTER_NO"), function() params.onMode("View") end),
			}
		else
			actions = {
				button(_("APASZ_NOTER_EDIT"), function() params.onMode("Edit") end),
				button(_("APASZ_NOTER_MOVE_UP"), function() params.onMove("Up") end, params.canMoveUp, REORDER_ICONS.Up),
				button(_("APASZ_NOTER_MOVE_DOWN"), function() params.onMove("Down") end, params.canMoveDown, REORDER_ICONS.Down),
				button(task.point and _("APASZ_NOTER_CHANGE_POINT") or _("APASZ_NOTER_SET_POINT"), params.onPickPoint, true, LOCATION_ICON, true),
			}
			if task.point then actions[#actions + 1] = button(_("APASZ_NOTER_UNLINK"), params.onClearPoint) end
			actions[#actions + 1] = button(_("APASZ_NOTER_DELETE"), function() params.onMode("ConfirmDelete") end)
		end
		children[#children + 1] = horizontal(actions)
	end
	local classes = "noter-row"
	if params.selected then classes = classes .. ", noter-selected" end
	if task.completed then classes = classes .. ", noter-completed" end
	return builtin.BoxLayout{
		meta = {localKey = tostring(task.id), class = classes},
		orientation = builtin.type.Orientation.Vertical, children = children,
	}
end)

local record WindowParams
	onClose : function()
	isOpen : function() : boolean
end

local NotebookWindow = react.RegisterWrapperRecipe("NoterNotebookWindow", builtin.Window, function(params : WindowParams) : TreeNodeId
	local notebook = react.useStateLazy(function() : NoterModel.Notebook
		return model.readNotebook(api.gui.game.getGuiSaveData(MOD_ID))
	end)
	local current = react.useMirrorRef(notebook)
	local interaction : ReactStateT<TaskInteraction | nil> = react.useState(nil)
	local latestInteraction = react.useMirrorRef(interaction)
	local picking : ReactStateT<boolean> = react.useState(false)
	local picker : ReactRefT<PickerRequest | nil> = react.useRef(nil)
	local alive = react.useRef(true)
	local function changeInteraction(value : TaskInteraction | nil)
		latestInteraction:set(value)
		interaction:set(value)
	end
	local function cancelPicker()
		local pending = picker:get()
		if pending == nil then return end
		local request = pending as PickerRequest
		request.active = false
		picker:set(nil)
		if alive:get() then picking:set(false) end
		local key = request.key
		if key == nil then return end
		react.enqueueJoin(function()
			local stack = globals.getDefaultToolStackApi()
			if stack then stack.pop(PointPicker, key as string) end
		end, JOIN_SCOPE)
	end
	local function selectTask(id : integer, mode : RowMode)
		local previous = latestInteraction:get()
		if previous == nil or (previous as TaskInteraction).id ~= id or mode ~= "View" then cancelPicker() end
		changeInteraction({id = id, mode = mode})
	end
	local function toggleTask(id : integer)
		local previous = latestInteraction:get()
		if previous ~= nil and (previous as TaskInteraction).id == id then
			-- A native double-click can also deliver the single-click callback before rerendering.
			if (previous as TaskInteraction).mode == "Edit" then return end
			changeInteraction(nil)
			cancelPicker()
		else
			selectTask(id, "View")
		end
	end
	local function commit(value : NoterModel.Notebook)
		if not alive:get() or not params.isOpen() or value == current:get() then return end
		api.gui.game.setGuiSaveData(MOD_ID, value as table)
		current:set(value)
		notebook:set(value)
		logger.debug(string.format("Updated notebook GUI save data: %d tasks, %d remaining",
			#value.tasks, model.remainingTaskCount(value)))
		local selected = latestInteraction:get()
		if selected ~= nil then
			local visible = false
			for _, task in ipairs(model.visibleTasks(value)) do
				if task.id == (selected as TaskInteraction).id then visible = true; break end
			end
			if not visible then
				changeInteraction(nil)
				cancelPicker()
			end
		end
	end
	react.onUnmount(function()
		alive:set(false)
		cancelPicker()
	end)
	local rows : {TreeNodeId} = {}
	local completedHeading = false
	local selection = interaction:old()
	for _index, task in ipairs(model.visibleTasks(notebook:old())) do
		local selected = selection ~= nil and (selection as TaskInteraction).id == task.id
		local rowMode : RowMode = selected and (selection as TaskInteraction).mode or "View"
		local showActions = selected and rowMode == "View"
		if task.completed and not completedHeading then
			rows[#rows + 1] = label(_("APASZ_NOTER_COMPLETED"))
			completedHeading = true
		end
		rows[#rows + 1] = TaskRow{
			meta = {localKey = tostring(task.id)}, task = task, selected = selected,
			mode = rowMode,
			onToggle = function() toggleTask(task.id) end,
			onMode = function(mode : RowMode) selectTask(task.id, mode) end,
			canMoveUp = showActions and model.canMoveTask(notebook:old(), task.id, "Up"),
			canMoveDown = showActions and model.canMoveTask(notebook:old(), task.id, "Down"),
			onText = function(text : string) commit(model.editTask(current:get(), task.id, text)) end,
			onCompleted = function(completed : boolean) commit(model.setCompleted(current:get(), task.id, completed)) end,
			onMove = function(direction : NoterModel.MoveDirection) commit(model.moveTask(current:get(), task.id, direction)) end,
			onRemove = function() cancelPicker(); commit(model.removeTask(current:get(), task.id)) end,
			onClearPoint = function() cancelPicker(); commit(model.setPoint(current:get(), task.id, nil)) end,
			onPickPoint = function()
				cancelPicker()
				local request : PickerRequest = {active = true}
				picker:set(request)
				react.enqueueJoin(function()
					if not request.active or picker:get() ~= request then return end
					if not alive:get() or not params.isOpen() then cancelPicker(); return end
					local stack = globals.getDefaultToolStackApi()
					if not stack then
						cancelPicker()
						logger.fail("Map picker needs an active game tool stack")
						return
					end
					-- Native popSelf identifies tools by key, so each request needs its own key.
					nextPickerId = nextPickerId + 1
					request.key = WINDOW_ID .. ".point." .. tostring(nextPickerId)
					stack.push(PointPicker, request.key, {
						request = request,
						onPoint = function(point : NoterModel.Point)
							if not alive:get() or not params.isOpen() or picker:get() ~= request then return end
							commit(model.setPoint(current:get(), task.id, point))
							flashPoint(point)
						end,
						onFinish = function()
							if picker:get() ~= request then return end
							picker:set(nil)
							if alive:get() then picking:set(false) end
						end,
					}, true)
					picking:set(true)
					logger.debug("Started map point picker for task " .. tostring(task.id))
				end, JOIN_SCOPE)
			end,
		}
	end
	if #rows == 0 then rows[1] = label(_("APASZ_NOTER_EMPTY")) end
	local children = {
		TextEditor{
			initialText = "", submitLabel = _("APASZ_NOTER_ADD"), clearAfterSubmit = true,
			onSubmit = function(text : string)
				local added = model.addTask(current:get(), text)
				commit(added)
				selectTask(added.nextId - 1, "View")
			end,
		},
		builtin.CheckBox{
			label = _("APASZ_NOTER_HIDE_COMPLETED"),
			value = notebook:old().hideCompleted and 1 or 0,
			onValueChange = function(value : integer)
				commit(model.setPreferences(current:get(), value == 1, current:get().pinned))
			end,
		},
	}
	if picking:old() then
		children[#children + 1] = horizontal{
			label(_("APASZ_NOTER_PICK_POINT_PROMPT")), button(_("APASZ_NOTER_CANCEL"), cancelPicker),
		}
	end
	children[#children + 1] = builtin.ScrollArea{
		meta = {class = "noter-list"},
		horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
		verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
		content = builtin.Component{
			layout = builtin.BoxLayout{
				meta = {class = "noter-rows"}, orientation = builtin.type.Orientation.Vertical, children = rows,
			},
		},
	}
	children[#children + 1] = label(_("APASZ_NOTER_SAVE_HINT"), "noter-hint")
	return builtin.Window{
		id = WINDOW_ID,
		title = lang_util.format(_("APASZ_NOTER_TITLE_REMAINING"), {count = lang_util.formatInt(model.remainingTaskCount(notebook:old()))}),
		closable = true, movable = true, pinnable = true,
		pinned = notebook:old().pinned, initialX = WINDOW_INITIAL_X, initialY = WINDOW_INITIAL_Y,
		onClose = function() cancelPicker(); params.onClose() end,
		onPinned = function(pinned : boolean)
			commit(model.setPreferences(current:get(), current:get().hideCompleted, pinned))
		end,
		content = builtin.BoxLayout{
			meta = {class = "noter-content"}, orientation = builtin.type.Orientation.Vertical, children = children,
		},
	}
end)

local modButtons = ug_require "::/gui/main/main_mod_button_area.tl" as MainModButtonArea
local NoterButton = react.RegisterPluginRecipe(modButtons.MainModButtonAreaExtension, "NoterButton", function() : TreeNodeId
	local opened : ReactStateT<boolean> = react.useState(false)
	local requestedOpen = react.useRef(false)
	local alive = react.useRef(true)
	react.onUnmount(function() alive:set(false) end)
	local setOpen : function(boolean)
	setOpen = function(open : boolean)
		requestedOpen:set(open)
		react.enqueueJoin(function()
			if not alive:get() or requestedOpen:get() ~= open then return end
			local windows = globals.getDefaultWindowApi()
			if not windows then
				if open then logger.warnOnce("window-api-unavailable", "Cannot open notebook: game window API is unavailable") end
				return
			end
			if open then
				windows.addSingletonWindow(NotebookWindow, {
					onClose = function() setOpen(false) end,
					isOpen = function() : boolean return alive:get() and requestedOpen:get() end,
				})
				api.gui.byId.setVisible(WINDOW_ID, true)
				windows.moveSingletonWindowToFront(NotebookWindow)
				logger.debug("Opened notebook")
			else
				windows.removeAllWindows(NotebookWindow)
				logger.debug("Closed notebook")
			end
			opened:set(open)
		end, JOIN_SCOPE)
	end
	return horizontal{
		builtin.ToggleButton{
			meta = {class = "extra, noter-toolbar", tooltip = _("APASZ_NOTER_TOOLBAR_TOOLTIP")},
			content = builtin.ImageView{meta = {class = "noter-toolbar-icon"}, path = NOTE_ICON},
			value = opened:old() and 1 or 0,
			onValueChange = function(value : integer) setOpen(value == 1) end,
		},
	}
end)

return {NoterButton = NoterButton}
