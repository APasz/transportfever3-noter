local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local react = ug_require "::/gui/main/react.lua" as React
local globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local app_util = ug_require "::/scripts/app_util.tl" as AppUtil
local lang_util = ug_require "::/scripts/lang_util.tl" as LangUtil
local model = ug_require "apasz_noter::/noter/model.tl" as NoterModel
local logger = ug_require "apasz_noter::/noter/logger.tl" as ModLogging.Logger
local MOD_ID = getOwningModId()
local WINDOW_ID = "noter.notebook"
local WINDOW_POSITION_TOLERANCE_PIXELS = 1
local TOGGLE_OFF_INDEX = 1
local TOGGLE_ON_INDEX = 2
local JOIN_SCOPE = "Noter"
local POINT_PICKER_TOOL = "NoterPointPicker"
local LEFT_MOUSE_BUTTON = 0
local RIGHT_MOUSE_BUTTON = 2
local CHECKBOX_UNCHECKED = 0
local CHECKBOX_CHECKED = 1
local CHECKBOX_PARTIAL = -1
local SUBITEM_INDENT_PIXELS = 24
local NOTE_ICON = "::/gui/menu/icons/list.tga"
local LOCATION_ICON = "::/gui/builtin/window/icons/symbol_locate.tga"
local EDIT_ICON = "::/gui/builtin/window/icons/symbol_pencil.tga"
local ADD_ICON = "::/gui/line_vehicle_mgmt/icons/add.tga"
local ACCEPT_ICON = "::/gui/menu/icons/symbol_check.tga"
local CANCEL_ICON = "::/gui/builtin/window/icons/cross_thin.tga"
local DELETE_ICON = "::/gui/menu/icons/trash.tga"
local UNLINK_ICON = "::/gui/line_vehicle_mgmt/icons/minus.tga"
local POINT_FEEDBACK_SECONDS = 3
local REORDER_ICONS <total> : {NoterModel.MoveDirection : string} = {
	Up = "::/gui/builtin/spinbox/arrow_up.tga",
	Down = "::/gui/builtin/spinbox/arrow_down.tga",
}
local nextPickerId = 0

local record ModParams
	apasz_noter_opaque_window : integer | nil
	apasz_noter_remember : integer | nil
	apasz_noter_subitems : integer | nil
end

local enum ToggleParameter
	"apasz_noter_opaque_window"
	"apasz_noter_subitems"
end

local REMEMBER_MODES : {integer : NoterModel.RememberMode} = {
	[1] = "Ephemeral", [2] = "Remembered",
}

local function readRememberMode() : NoterModel.RememberMode
	local raw = api.engine.config.getModParams()[MOD_ID]
	if raw == nil then return "Remembered" end
	local index = (raw as ModParams).apasz_noter_remember
	if index == nil then return "Remembered" end
	local mode = REMEMBER_MODES[index]
	if mode == nil then return logger.fail("Invalid remember parameter: " .. tostring(index)) end
	return mode
end

local function readToggleParameter(key : ToggleParameter, defaultEnabled : boolean) : boolean
	local raw = api.engine.config.getModParams()[MOD_ID]
	if raw == nil then return defaultEnabled end
	-- GUI configuration returns one-based option indices, not the mod.json numbers.
	local value = (raw as ModParams)[key]
	if value == nil then return defaultEnabled end
	if value == TOGGLE_OFF_INDEX then return false end
	if value == TOGGLE_ON_INDEX then return true end
	return logger.fail("Invalid " .. key .. " parameter: " .. tostring(value))
end

local enum RowMode
	"View"
	"Edit"
	"ConfirmDelete"
	"AddItem"
end

local record TaskInteraction
	id : integer
	mode : RowMode
	itemId : integer | nil
end

local function label(text : string, class? : string) : TreeNodeId
	return builtin.TextView{meta = {class = "font-scale-body, " .. (class or "")}, text = text}
end

local function horizontal(children : {TreeNodeId}, fill? : boolean) : TreeNodeId
	return builtin.BoxLayout{
		meta = {class = fill and "noter-line, noter-fill-width" or "noter-line"},
		orientation = builtin.type.Orientation.Horizontal, children = children,
	}
end

local subitemSpacerStyle : StyleSheet | nil = nil

local function indentLayout(layout : TreeNodeId) : TreeNodeId
	if subitemSpacerStyle == nil then
		subitemSpacerStyle = api.gui.StyleSheet.new()
		subitemSpacerStyle.size = api.type.Vec2f.new(SUBITEM_INDENT_PIXELS, 0)
	end
	return horizontal{
		builtin.Component{meta = {styleSheet = subitemSpacerStyle}},
		builtin.Component{meta = {class = "noter-child-content, noter-fill-width"}, layout = layout},
	}
end

local function button(text : string, onClick : function(), enabled? : boolean, iconPath? : string) : TreeNodeId
	local content : TreeNodeId
	if iconPath then
		content = builtin.ImageView{meta = {class = "noter-icon"}, path = iconPath}
	else
		content = label(text)
	end
	return builtin.Button{
		meta = {
			enabled = enabled == nil or enabled,
			class = iconPath and "noter-icon-button" or nil,
			tooltip = iconPath and text or nil,
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

local enum EditorAction
	"Add"
	"Save"
end

local record EditorParams
	initialText : string
	indented : boolean
	placeholderText : string | nil
	action : EditorAction
	isActive : function() : boolean
	onSubmit : function(string)
	onCancel : function() | nil
end

local TextEditor = react.RegisterRecipe("NoterTextEditor", function(params : EditorParams) : TreeNodeId
	local adding = params.action == "Add"
	local draft : ReactStateT<string> = react.useState(params.initialText)
	local draftRef = react.useMirrorRef(draft)
	local input = react.useNodeRef(builtin.TextInputField)
	local focused = react.useRef(false)
	local alive = react.useRef(true)
	react.onMount(function() input:get():focus() end)
	react.onUnmount(function() alive:set(false) end)
	local function isActive() : boolean
		return alive:get() and params.isActive()
	end
	local function cancel()
		if isActive() and params.onCancel then (params.onCancel as function())() end
	end
	local function submit(text : string)
		if not isActive() or not model.canSubmitText(text) then return end
		params.onSubmit(text)
		if adding then
			draftRef:set("")
			draft:set("")
		end
	end
	local children = {
		builtin.TextInputField(react.ref(input), {
			meta = {
				class = "font-scale-body, noter-input",
				tooltip = lang_util.format(_("APASZ_NOTER_TEXT_LIMIT"), {count = lang_util.formatInt(model.MAX_TEXT_LENGTH)}),
				onFocusChange = function(hasFocus : boolean)
					focused:set(hasFocus)
				end,
			},
			value = draft:old(), placeholderText = params.placeholderText or _("APASZ_NOTER_ENTER_TASK"),
			resetValueOnCancel = params.onCancel == nil,
			maxLength = math.max(model.MAX_TEXT_LENGTH, assert(model.characterCount(params.initialText))),
			onTyping = function(text : string)
				if not isActive() then return end
				draftRef:set(text)
				draft:set(text)
			end,
			onValueChange = submit,
			acceptOnFocusLoss = false,
			popFocusOnStopEditing = params.onCancel == nil,
			onCancel = params.onCancel and function()
				-- Native cancellation also occurs on mouse focus loss, before a later Add/Save click.
				react.enqueueJoin(function()
					logger.debug("Text editor cancellation: alive=" .. tostring(alive:get())
						.. ", focused=" .. tostring(focused:get()))
					if focused:get() then cancel() end
				end, JOIN_SCOPE)
			end or nil,
		}),
		button(adding and _("APASZ_NOTER_ADD") or _("APASZ_NOTER_SAVE"), function() submit(draftRef:get()) end,
			model.canSubmitText(draft:old()), adding and ADD_ICON or ACCEPT_ICON),
	}
	if params.onCancel then children[#children + 1] = button(_("APASZ_NOTER_CANCEL"), cancel, true, CANCEL_ICON) end
	local layout = horizontal(children, true)
	return params.indented and indentLayout(layout) or layout
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

local function makePickerAction(params : PickerActionParams) : TreeNodeId
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
	local selector = builtin.Selector{
		stopOnMenuBack = false,
		onSelect = function(_entity : Engine.Entity, _indices : {integer}, _details : Gui.SelectionDetails) : boolean
			return pick()
		end,
		onProcessMouseEvent = function(event : Gui.Mouse.Event) : boolean
			if not params.request.active or event.handled or event.type ~= api.gui.mouse.Event.Type.Clicked then return false end
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
		-- This 3D action has no UI component for useInputAction; native back handles Escape.
		onBack = cancel,
		children = {selector},
	}
end

local PointPicker = react.RegisterTool({
	name = POINT_PICKER_TOOL,
	push = function(context : Builtin.ToolStackContext<PickerParams>, params : PickerParams)
		local function finish()
			react.enqueueJoin(function() context.popSelf() end, JOIN_SCOPE)
		end
		context.setActionFn(function() : TreeNodeId
			return makePickerAction{
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

local record TaskRowParams is IRecipeParamWithMeta
	task : NoterModel.Entry
	point : NoterModel.Point | nil
	subitem : boolean
	subitemsEnabled : boolean
	itemCount : integer
	completedItems : integer
	deletePrompt : string
	windowExpanded : boolean
	gamepadInput : boolean
	selected : boolean
	preview : boolean
	deferActions : boolean
	isEditing : function() : boolean
	mode : RowMode
	canMoveUp : boolean
	canMoveDown : boolean
	onToggle : function()
	onMode : function(RowMode)
	onText : function(string)
	onCompleted : function(boolean)
	onMove : function(NoterModel.MoveDirection)
	onRemove : function()
	onPickPoint : function() | nil
	onClearPoint : function() | nil
end

local function taskActions(params : TaskRowParams) : TreeNodeId | nil
	if not params.selected or params.mode == "Edit" then return nil end
	local actions : {TreeNodeId}
	if params.mode == "ConfirmDelete" then
		actions = {
			label(params.deletePrompt), button(_("APASZ_NOTER_YES"), params.onRemove),
			button(_("APASZ_NOTER_NO"), function() params.onMode("View") end),
		}
	else
		actions = {
			button(_("APASZ_NOTER_EDIT"), function() params.onMode("Edit") end, true, EDIT_ICON),
			button(_("APASZ_NOTER_MOVE_UP"), function() params.onMove("Up") end, params.canMoveUp, REORDER_ICONS.Up),
			button(_("APASZ_NOTER_MOVE_DOWN"), function() params.onMove("Down") end, params.canMoveDown, REORDER_ICONS.Down),
		}
		if params.onPickPoint then
			actions[#actions + 1] = button(params.point and _("APASZ_NOTER_CHANGE_POINT") or _("APASZ_NOTER_SET_POINT"),
				params.onPickPoint as function(), true, LOCATION_ICON)
		end
		if params.point and params.onClearPoint then
			actions[#actions + 1] = button(_("APASZ_NOTER_UNLINK"), params.onClearPoint as function(), true, UNLINK_ICON)
		end
		actions[#actions + 1] = builtin.Component{
			meta = {class = "noter-destructive"},
			layout = horizontal{button(_("APASZ_NOTER_DELETE"), function() params.onMode("ConfirmDelete") end, true, DELETE_ICON)},
		}
	end
	local layout = horizontal(actions)
	return builtin.Component{
		meta = {localKey = "actions." .. tostring(params.task.id), class = "noter-actions"},
		layout = params.deferActions and indentLayout(layout) or layout,
	}
end

local record TaskTextLayout
	width : integer
	style : StyleSheet
end

local TaskRow = react.RegisterWrapperRecipe("NoterTaskRow", builtin.Component, function(params : TaskRowParams) : TreeNodeId
	local task = params.task
	local showChecklist = params.subitemsEnabled and params.itemCount > 0
	local textButtonId = WINDOW_ID .. ".task." .. tostring(task.id)
	local textButton = react.useNodeRef(builtin.Button)
	local textLayout : ReactStateT<TaskTextLayout | nil> = react.useState(nil)
	local latestLayout = react.useMirrorRef(textLayout)
	-- Measure the stretching button, so wrapped text does not determine its own width.
	react.onStep(function()
		if not params.windowExpanded or params.mode == "Edit" or textButton:hasExpired() then return end
		-- getSize returns viewport fractions; inline style dimensions use pixels.
		local viewportWidth = api.gui.camera.getSize().x
		local width = math.floor(api.gui.byId.getSize(textButtonId).x * viewportWidth + 0.5)
		local previous = latestLayout:get()
		if width <= 0 or (previous ~= nil and (previous as TaskTextLayout).width == width) then return end
		local style = api.gui.StyleSheet.new()
		style.size = api.type.Vec2f.new(width, -1)
		local layout : TaskTextLayout = {width = width, style = style}
		latestLayout:set(layout)
		textLayout:set(layout)
	end)
	local pointButton : TreeNodeId | nil = nil
	if params.point then
		local point = params.point as NoterModel.Point
		pointButton = button(_("APASZ_NOTER_GO_TO_POINT"), function() goToPoint(point) end, true, LOCATION_ICON)
	end
	local completionTooltip = task.completed and _("APASZ_NOTER_MARK_INCOMPLETE") or _("APASZ_NOTER_MARK_COMPLETE")
	if params.itemCount > 0 then
		completionTooltip = task.completed and _("APASZ_NOTER_UNCHECK_ALL") or _("APASZ_NOTER_CHECK_ALL")
	end
	local checkboxValue = task.completed and CHECKBOX_CHECKED or CHECKBOX_UNCHECKED
	if params.completedItems > 0 and not task.completed then checkboxValue = CHECKBOX_PARTIAL end
	local line = {
		builtin.CheckBox{
			meta = {tooltip = completionTooltip}, value = checkboxValue,
			-- A native indeterminate checkbox advances to unchecked; bulk actions follow the checklist instead.
			onValueChange = function(value : integer)
				params.onCompleted(checkboxValue == CHECKBOX_PARTIAL or value == CHECKBOX_CHECKED)
			end,
		},
	}
	if not params.subitem then
		line[#line + 1] = builtin.Component{
			meta = {class = "noter-pin-slot"}, layout = pointButton and horizontal{pointButton} or nil,
		}
	end
	if params.mode == "Edit" then
		line[#line + 1] = TextEditor{
			meta = {class = "noter-fill-width"},
			initialText = task.text, action = "Save",
			isActive = params.isEditing,
			placeholderText = params.subitem and _("APASZ_NOTER_ENTER_ITEM") or nil,
			onSubmit = function(text : string) params.onText(text); params.onMode("View") end,
			onCancel = function() params.onMode("View") end,
		}
	else
		local layout = textLayout:old()
		local textClasses = (params.subitem and "font-scale-annotation" or "font-scale-body") .. ", noter-text"
		if params.preview then textClasses = textClasses .. ", noter-preview" end
		if params.windowExpanded then textClasses = textClasses .. ", noter-expanded-text" end
		if showChecklist then textClasses = textClasses .. ", noter-checklist-text" end
		if task.completed then textClasses = textClasses .. ", noter-completed-text" end
		line[#line + 1] = builtin.Button(react.ref(textButton), {
			meta = {
				id = textButtonId, class = "noter-task-button",
				tooltip = params.gamepadInput and _("APASZ_NOTER_TASK_ACTIONS_CONTROLLER_TOOLTIP")
					or _("APASZ_NOTER_TASK_ACTIONS_TOOLTIP"),
			},
			content = builtin.TextView{
				meta = {
					class = textClasses,
					styleSheet = params.windowExpanded and layout ~= nil and (layout as TaskTextLayout).style or nil,
				}, text = task.text,
			},
			onClick = params.onToggle,
			onDoubleClick = function() params.onMode("Edit") end,
		})
	end
	if showChecklist and params.mode ~= "Edit" then
		line[#line + 1] = builtin.TextView{
			meta = {class = "font-scale-annotation, noter-progress"},
			text = lang_util.format(_("APASZ_NOTER_CHECKLIST_PROGRESS"), {
				completed = lang_util.formatInt(params.completedItems), total = lang_util.formatInt(params.itemCount),
			}),
		}
	end
	local children = {horizontal(line, true)}
	if not params.deferActions then
		local actions = taskActions(params)
		if actions then children[#children + 1] = actions end
	end
	local classes = "noter-row"
	if params.subitem then classes = classes .. ", noter-subitem, noter-no-padding" end
	if showChecklist then classes = classes .. ", noter-checklist" end
	if params.selected then classes = classes .. ", noter-selected" end
	if task.completed then classes = classes .. ", noter-completed" end
	if params.windowExpanded then classes = classes .. ", noter-expanded" end
	react.setStyleClasses(classes)
	local layout = builtin.BoxLayout{orientation = builtin.type.Orientation.Vertical, children = children}
	return builtin.Component{
		meta = {localKey = tostring(task.id), class = classes},
		layout = params.subitem and indentLayout(layout) or layout,
	}
end)

local record WindowParams
	onClose : function()
	isOpen : function() : boolean
	initialX : number
	initialY : number
	rememberMode : NoterModel.RememberMode
	captureLayout : ReactRefT<function() | nil>
end

local NotebookWindow = react.RegisterWrapperRecipe("NoterNotebookWindow", builtin.Window, function(params : WindowParams) : TreeNodeId
	local gamepadInput : ReactStateT<boolean> = engine_react_util.useStepState(app_util.isGamepadInputMode)
	local opaqueWindow : ReactStateT<boolean> = react.useStateLazy(function() : boolean
		return readToggleParameter("apasz_noter_opaque_window", false)
	end)
	local subitems : ReactStateT<boolean> = react.useStateLazy(function() : boolean
		return readToggleParameter("apasz_noter_subitems", true)
	end)
	local notebook = react.useStateLazy(function() : NoterModel.Notebook
		return model.readNotebook(api.gui.game.getGuiSaveData(MOD_ID))
	end)
	local current = react.useMirrorRef(notebook)
	local ephemeralExpanded : ReactStateT<boolean> = react.useState(false)
	local latestEphemeralExpanded = react.useMirrorRef(ephemeralExpanded)
	local windowRef = react.useNodeRef(builtin.Window)
	local layoutCaptureQueued = react.useRef(false)
	local interaction : ReactStateT<TaskInteraction | nil> = react.useState(nil)
	local latestInteraction = react.useMirrorRef(interaction)
	local composerGeneration : ReactRefT<integer> = react.useRef(0)
	local picking : ReactStateT<boolean> = react.useState(false)
	local picker : ReactRefT<PickerRequest | nil> = react.useRef(nil)
	local alive = react.useRef(true)
	local function isActive() : boolean
		return alive:get() and params.isOpen()
	end
	local function isCurrentInteraction(id : integer, mode : RowMode, itemId? : integer) : boolean
		if not isActive() then return false end
		local selected = latestInteraction:get()
		return selected ~= nil and (selected as TaskInteraction).id == id
			and (selected as TaskInteraction).mode == mode and (selected as TaskInteraction).itemId == itemId
	end
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
	local function selectTask(id : integer, mode : RowMode, itemId? : integer)
		local previous = latestInteraction:get()
		if previous == nil or (previous as TaskInteraction).id ~= id
			or (previous as TaskInteraction).itemId ~= itemId or mode ~= "View" then cancelPicker() end
		changeInteraction({id = id, mode = mode, itemId = itemId})
	end
	local function beginItemComposer(id : integer)
		composerGeneration:set(composerGeneration:get() + 1)
		logger.debug("Opened subitem composer for task " .. tostring(id))
		selectTask(id, "AddItem")
	end
	local function isCurrentComposer(id : integer, generation : integer) : boolean
		return isCurrentInteraction(id, "AddItem") and composerGeneration:get() == generation
	end
	local function toggleTask(id : integer, itemId? : integer)
		local previous = latestInteraction:get()
		if previous ~= nil and (previous as TaskInteraction).id == id and (previous as TaskInteraction).itemId == itemId then
			-- A native double-click can also deliver the single-click callback before rerendering.
			if (previous as TaskInteraction).mode == "Edit"
				or (itemId ~= nil and (previous as TaskInteraction).mode == "View") then return end
			changeInteraction(itemId ~= nil and {id = id, mode = "View", itemId = itemId} or nil)
			cancelPicker()
		else
			selectTask(id, "View", itemId)
		end
	end
	local function commit(value : NoterModel.Notebook)
		local previous = current:get()
		if not alive:get() or not params.isOpen() or value == previous then return end
		api.gui.game.setGuiSaveData(MOD_ID, value as table)
		current:set(value)
		notebook:set(value)
		logger.debug(string.format("Updated notebook GUI save data: %d tasks, %d remaining",
			#value.tasks, model.remainingTaskCount(value)))
		local selected = latestInteraction:get()
		if selected ~= nil and (value.tasks ~= previous.tasks or value.hideCompleted ~= previous.hideCompleted) then
			local visible = false
			for _, task in ipairs(value.tasks) do
				if task.id == (selected as TaskInteraction).id then
					visible = not (value.hideCompleted and task.completed)
					local itemId = (selected as TaskInteraction).itemId
					if itemId ~= nil then
						local found = false
						for _, item in ipairs(task.items) do
							if item.id == itemId then found = true; break end
						end
						if not found then changeInteraction({id = task.id, mode = "View"}) end
					end
					break
				end
			end
			if not visible then
				changeInteraction(nil)
				cancelPicker()
			end
		end
	end
	local function remembersWindowPosition() : boolean
		return params.rememberMode == "Remembered" and not model.getWindowLayout(current:get()).expanded
	end
	local function rememberWindowLayout()
		if not alive:get() or not params.isOpen() or not remembersWindowPosition() then return end
		if windowRef:hasExpired() then return end
		local window = windowRef:get()
		if window == nil then return end
		local position = window:getPosition(0, 0)
		local corner = window:getPosition(1, 1)
		if corner.x <= position.x or corner.y <= position.y then return end
		local viewport = api.gui.camera.getSize()
		if viewport.x <= 0 or viewport.y <= 0 then return end
		local x, y = position.x, position.y
		local layout = model.getWindowLayout(current:get())
		if math.abs(x - layout.x) * viewport.x < WINDOW_POSITION_TOLERANCE_PIXELS
			and math.abs(y - layout.y) * viewport.y < WINDOW_POSITION_TOLERANCE_PIXELS then return end
		local updated = model.setWindowLayout(current:get(), {x = x, y = y, expanded = layout.expanded}, params.rememberMode)
		if updated == current:get() then return end
		local saved = model.getWindowLayout(updated)
		logger.debug(string.format("Captured window position: x=%.4f, y=%.4f", saved.x, saved.y))
		commit(updated)
	end
	params.captureLayout:set(remembersWindowPosition() and rememberWindowLayout or nil)
	react.onMount(function() api.gui.byId.resetMovedWindowPosition(WINDOW_ID) end)
	react.onUnmount(function()
		if params.captureLayout:get() == rememberWindowLayout then params.captureLayout:set(nil) end
		alive:set(false)
		cancelPicker()
	end)
	local notebookValue = notebook:old()
	local gamepadMode = gamepadInput:old()
	local subitemsEnabled = subitems:old()
	local isExpanded = ephemeralExpanded:old()
	if params.rememberMode ~= "Ephemeral" then isExpanded = model.getWindowLayout(notebookValue).expanded end
	local rows : {TreeNodeId} = {}
	local selection = interaction:old()
	for _index, task in ipairs(model.visibleTasks(notebookValue)) do
		local expanded = selection ~= nil and (selection as TaskInteraction).id == task.id
		local selected = expanded and (selection as TaskInteraction).itemId == nil
		local rowMode : RowMode = selected and (selection as TaskInteraction).mode or "View"
		local showActions = selected and rowMode == "View"
		local taskRows : {TreeNodeId} = {}
		local parentParams : TaskRowParams = {
			meta = {localKey = tostring(task.id), class = "noter-fill-width"}, task = task, selected = selected,
			preview = expanded, deferActions = subitemsEnabled and #task.items > 0,
			isEditing = function() : boolean return isCurrentInteraction(task.id, "Edit") end,
			point = task.point, subitem = false, subitemsEnabled = subitemsEnabled,
			itemCount = #task.items, completedItems = model.completedItemCount(task),
			deletePrompt = #task.items > 0 and _("APASZ_NOTER_DELETE_CHECKLIST_CONFIRM") or _("APASZ_NOTER_DELETE_CONFIRM"),
			mode = rowMode, windowExpanded = isExpanded, gamepadInput = gamepadMode,
			onToggle = function() toggleTask(task.id) end,
			onMode = function(mode : RowMode) selectTask(task.id, mode) end,
			canMoveUp = showActions and model.canMoveTask(notebookValue, task.id, "Up"),
			canMoveDown = showActions and model.canMoveTask(notebookValue, task.id, "Down"),
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
		taskRows[#taskRows + 1] = TaskRow(parentParams)
		local checklistActions : TreeNodeId | nil = nil
		if parentParams.deferActions then checklistActions = taskActions(parentParams) end
		if expanded and subitemsEnabled then
			for index, item in ipairs(task.items) do
				local itemSelected = (selection as TaskInteraction).itemId == item.id
				local itemParams : TaskRowParams = {
					meta = {localKey = tostring(item.id), class = "noter-fill-width"}, task = item, selected = itemSelected,
					preview = true, deferActions = true,
					isEditing = function() : boolean return isCurrentInteraction(task.id, "Edit", item.id) end,
					subitem = true, subitemsEnabled = subitemsEnabled, itemCount = 0, completedItems = 0,
					deletePrompt = _("APASZ_NOTER_DELETE_ITEM_CONFIRM"),
					mode = itemSelected and (selection as TaskInteraction).mode or "View", windowExpanded = isExpanded,
					gamepadInput = gamepadMode,
					canMoveUp = index > 1, canMoveDown = index < #task.items,
					onToggle = function() toggleTask(task.id, item.id) end,
					onMode = function(mode : RowMode) selectTask(task.id, mode, item.id) end,
					onText = function(text : string) commit(model.editItem(current:get(), task.id, item.id, text)) end,
					onCompleted = function(completed : boolean)
						commit(model.setItemCompleted(current:get(), task.id, item.id, completed))
					end,
					onMove = function(direction : NoterModel.MoveDirection)
						commit(model.moveItem(current:get(), task.id, item.id, direction))
					end,
					onRemove = function() commit(model.removeItem(current:get(), task.id, item.id)) end,
				}
				taskRows[#taskRows + 1] = TaskRow(itemParams)
				if itemSelected then checklistActions = taskActions(itemParams) end
			end
			if checklistActions then taskRows[#taskRows + 1] = checklistActions end
			if rowMode == "AddItem" then
				local generation = composerGeneration:get()
				taskRows[#taskRows + 1] = TextEditor{
					meta = {
						localKey = "add-item." .. tostring(task.id) .. "." .. tostring(generation),
						class = "noter-subitem, noter-no-padding, noter-fill-width",
					},
					initialText = "", indented = true, placeholderText = _("APASZ_NOTER_ENTER_ITEM"),
					action = "Add",
					isActive = function() : boolean return isCurrentComposer(task.id, generation) end,
					onSubmit = function(text : string)
						local updated = model.addItem(current:get(), task.id, text)
						-- Native text inputs retain editing state; start a fresh field after each accepted item.
						beginItemComposer(task.id)
						commit(updated)
					end,
					onCancel = function()
						selectTask(task.id, "View")
					end,
				}
			elseif (selection as TaskInteraction).mode == "View" then
				taskRows[#taskRows + 1] = builtin.Component{
					meta = {localKey = "add-item.action." .. tostring(task.id), class = "noter-add-subitem, noter-no-padding"},
					layout = indentLayout(horizontal{button(_("APASZ_NOTER_ADD_ITEM"),
						function() beginItemComposer(task.id) end, true, ADD_ICON)}),
				}
			end
		end
		rows[#rows + 1] = builtin.Component{
			meta = {localKey = "note." .. tostring(task.id), class = "noter-group, noter-fill-width"},
			layout = builtin.BoxLayout{orientation = builtin.type.Orientation.Vertical, children = taskRows},
		}
	end
	if #rows == 0 then rows[1] = label(_("APASZ_NOTER_EMPTY")) end
	local title = lang_util.format(_("APASZ_NOTER_TITLE_REMAINING"), {
		count = lang_util.formatInt(model.remainingTaskCount(notebookValue)),
	})
	local children = {
		TextEditor{
			meta = {class = "noter-fill-width"},
			initialText = "", action = "Add",
			isActive = isActive,
			onSubmit = function(text : string)
				local added = model.addTask(current:get(), text)
				commit(added)
				selectTask(added.nextId - 1, "View")
			end,
		},
		builtin.CheckBox{
			label = _("APASZ_NOTER_HIDE_COMPLETED"),
			value = notebookValue.hideCompleted and 1 or 0,
			onValueChange = function(value : integer)
				commit(model.setPreferences(current:get(), value == 1, current:get().pinned))
			end,
		},
	}
	if picking:old() then
		children[#children + 1] = horizontal{
			label(_("APASZ_NOTER_PICK_POINT_PROMPT")), button(_("APASZ_NOTER_CANCEL"), cancelPicker, true, CANCEL_ICON),
		}
	end
	children[#children + 1] = builtin.ScrollArea{
		meta = {class = "noter-list"},
		horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
		verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
		content = builtin.Component{
			meta = {class = "noter-fill-width"},
			layout = builtin.BoxLayout{
				meta = {class = "noter-rows"}, orientation = builtin.type.Orientation.Vertical, children = rows,
			},
		},
	}
	children[#children + 1] = label(_("APASZ_NOTER_SAVE_HINT"), "noter-hint")
	return builtin.Window(react.ref(windowRef), {
		id = WINDOW_ID,
		meta = {class = opaqueWindow:old() and "noter-opaque" or nil},
		title = title,
		closable = true, movable = true, pinnable = true,
		expanded = isExpanded,
		pinned = notebookValue.pinned, initialX = params.initialX, initialY = params.initialY,
		onClose = function() cancelPicker(); params.onClose() end,
		-- Undocumented native callback, also used by vanilla music-player and entity windows.
		onMovedChange = function()
			if not alive:get() or not params.isOpen() or not remembersWindowPosition() then return end
			logger.debug("Window movement callback")
			if layoutCaptureQueued:get() then return end
			layoutCaptureQueued:set(true)
			react.enqueueJoin(function()
				if not alive:get() or not params.isOpen() then return end
				layoutCaptureQueued:set(false)
				rememberWindowLayout()
			end, JOIN_SCOPE)
		end,
		onPinned = function(pinned : boolean)
			commit(model.setPreferences(current:get(), current:get().hideCompleted, pinned))
		end,
		header = builtin.BoxLayout{
			meta = {class = "noter-header"}, orientation = builtin.type.Orientation.Horizontal,
			children = {
				builtin.TextView{
					meta = {class = "font-scale-title-3, noter-title"}, text = title, tooltipWhenClipped = title,
				},
				builtin.Button{
					meta = {tooltip = isExpanded and _("APASZ_NOTER_NORMAL_SIZE") or _("APASZ_NOTER_EXPAND")},
					content = builtin.ImageView{
						meta = {class = "noter-icon"},
						path = isExpanded and "::/gui/builtin/window/icons/symbol_minimize_18.tga"
							or "::/gui/builtin/window/icons/symbol_maximize_18.tga",
					},
					onClick = function()
						if params.rememberMode == "Ephemeral" then
							local value = not latestEphemeralExpanded:get()
							latestEphemeralExpanded:set(value)
							ephemeralExpanded:set(value)
							return
						end
						rememberWindowLayout()
						local layout = model.getWindowLayout(current:get())
						commit(model.setWindowLayout(current:get(), {x = layout.x, y = layout.y, expanded = not layout.expanded}, params.rememberMode))
					end,
				},
			},
		},
		content = builtin.BoxLayout{
			meta = {class = "noter-content"}, orientation = builtin.type.Orientation.Vertical, children = children,
		},
	})
end)

local modButtons = ug_require "::/gui/main/main_mod_button_area.tl" as MainModButtonArea
local NoterButton = react.RegisterPluginRecipe(modButtons.MainModButtonAreaExtension, "NoterButton", function() : TreeNodeId
	local opened : ReactStateT<boolean> = react.useState(false)
	local requestedOpen = react.useRef(false)
	local requestId = react.useRef(0)
	local alive = react.useRef(true)
	local captureLayout : ReactRefT<function() | nil> = react.useRef(nil)
	react.onUnmount(function() alive:set(false) end)
	local setOpen : function(boolean)
	setOpen = function(open : boolean)
		if not alive:get() or requestedOpen:get() == open then return end
		local capture = captureLayout:get()
		if not open and capture ~= nil then (capture as function())() end
		requestedOpen:set(open)
		local id = requestId:get() + 1
		requestId:set(id)
		react.enqueueJoin(function()
			if not alive:get() or requestId:get() ~= id then return end
			local windows = globals.getDefaultWindowApi()
			if not windows then
				if open then
					requestedOpen:set(false)
					logger.warnOnce("window-api-unavailable", "Cannot open notebook: game window API is unavailable")
				end
				return
			end
			if open then
				local mode = readRememberMode()
				local layout = model.getWindowLayout(model.readNotebook(api.gui.game.getGuiSaveData(MOD_ID)), mode)
				local key = WINDOW_ID .. "." .. tostring(id)
				local function isOpen() : boolean
					return alive:get() and requestedOpen:get() and requestId:get() == id
				end
				-- A new key resets hook state even when close and reopen share a render cycle.
				windows.removeAllWindows(NotebookWindow)
				windows.addWindow(NotebookWindow, key, {
					initialX = layout.x, initialY = layout.y, captureLayout = captureLayout,
					rememberMode = mode,
					onClose = function() if isOpen() then setOpen(false) end end,
					isOpen = isOpen,
				})
				api.gui.byId.setVisible(WINDOW_ID, true)
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
			content = builtin.ImageView{meta = {class = "iconlabelindicator-icon-size"}, path = NOTE_ICON},
			value = opened:old() and 1 or 0,
			onValueChange = function(value : integer) setOpen(value == 1) end,
		},
	}
end)

return {NoterButton = NoterButton}
