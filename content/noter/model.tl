local logger = ug_require "apasz_noter::/noter/logger.tl" as ModLogging.Logger
local model : NoterModel = {MAX_TEXT_LENGTH = 500}
local FORMAT_VERSION = 1
local DEFAULT_WINDOW_LAYOUT : NoterModel.WindowLayout = {x = 0.04, y = 0.1, expanded = false}
local EXPANDED_WINDOW_LAYOUT : NoterModel.WindowLayout = {x = 0.5, y = 0.5, expanded = true}

local function requireValid(condition : boolean, message : string)
	if not condition then logger.fail(message) end
end

function model.newNotebook() : NoterModel.Notebook
	return {version = FORMAT_VERSION, nextId = 1, tasks = {}, hideCompleted = false, pinned = false}
end

function model.normalizeText(text : string) : string
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The game omits Lua's utf8 library. Count code points and reject malformed UTF-8.
function model.characterCount(text : string) : integer | nil
	local count, index = 0, 1
	while index <= #text do
		local first = text:byte(index)
		local width = 1
		local secondMin, secondMax = 0x80, 0xBF
		if first <= 0x7F then
			width = 1
		elseif first >= 0xC2 and first <= 0xDF then
			width = 2
		elseif first >= 0xE0 and first <= 0xEF then
			width = 3
			if first == 0xE0 then secondMin = 0xA0 end
			if first == 0xED then secondMax = 0x9F end
		elseif first >= 0xF0 and first <= 0xF4 then
			width = 4
			if first == 0xF0 then secondMin = 0x90 end
			if first == 0xF4 then secondMax = 0x8F end
		else
			return nil
		end
		if index + width - 1 > #text then return nil end
		for offset = 1, width - 1 do
			local byte = text:byte(index + offset)
			local minimum = offset == 1 and secondMin or 0x80
			local maximum = offset == 1 and secondMax or 0xBF
			if byte < minimum or byte > maximum then return nil end
		end
		count, index = count + 1, index + width
	end
	return count
end

local function taskTextLength(text : string) : integer | nil
	local normalized = model.normalizeText(text)
	if normalized == "" or text:find("[%z\1-\31\127]") then return nil end
	return model.characterCount(normalized)
end

function model.canSubmitText(text : string) : boolean
	local length = taskTextLength(text)
	return length ~= nil and length <= model.MAX_TEXT_LENGTH
end

local function requireText(text : string) : string
	local length = taskTextLength(text)
	requireValid(length ~= nil, "Tasks must contain non-blank, single-line UTF-8 text")
	requireValid((length as integer) <= model.MAX_TEXT_LENGTH,
		"Tasks must not exceed " .. tostring(model.MAX_TEXT_LENGTH) .. " characters")
	return model.normalizeText(text)
end

local function isFiniteNumber(value : any) : boolean
	if type(value) ~= "number" then return false end
	local numberValue = value as number
	return numberValue == numberValue and math.abs(numberValue) < math.huge
end

local function isInteger(value : any) : boolean
	return isFiniteNumber(value) and (value as number) == math.floor(value as number)
end

local function requirePoint(point : NoterModel.Point)
	requireValid(type(point) == "table", "Map point must be a table")
	requireValid(point.x ~= nil and point.y ~= nil and point.z ~= nil, "Map point is missing coordinates")
	requireValid(isFiniteNumber(point.x) and isFiniteNumber(point.y) and isFiniteNumber(point.z),
		"Map point must contain finite coordinates")
end

local function samePoint(left : NoterModel.Point | nil, right : NoterModel.Point | nil) : boolean
	if left == right then return true end
	if left == nil or right == nil then return false end
	local first, second = left as NoterModel.Point, right as NoterModel.Point
	return first.x == second.x and first.y == second.y and first.z == second.z
end

local function requireWindowLayout(layout : NoterModel.WindowLayout)
	requireValid(type(layout) == "table", "Window layout must be a table")
	requireValid(isFiniteNumber(layout.x) and isFiniteNumber(layout.y), "Window position must contain finite coordinates")
	requireValid(type(layout.expanded) == "boolean", "Window expanded state must be a boolean")
end

function model.readNotebook(raw : table | nil) : NoterModel.Notebook
	if raw == nil then
		return model.newNotebook()
	end
	local data = raw as table
	requireValid(type(data) == "table", "Save data must be a table")
	if next(data) == nil then return model.newNotebook() end
	local notebook = data as NoterModel.Notebook
	requireValid(notebook.version == FORMAT_VERSION, "Unsupported save format: " .. tostring(notebook.version))
	requireValid(isInteger(notebook.nextId) and notebook.nextId > 0, "Invalid next task ID")
	requireValid(type(notebook.tasks) == "table", "Save is missing tasks")
	requireValid(type(notebook.hideCompleted) == "boolean" and type(notebook.pinned) == "boolean",
		"Save has invalid preferences")
	if notebook.windowLayout ~= nil then requireWindowLayout(notebook.windowLayout) end
	local seen : {integer : boolean} = {}
	local count = 0
	for key, rawTask in pairs(notebook.tasks as {any : any}) do
		requireValid(isInteger(key) and (key as integer) > 0, "Tasks must be an array")
		local value = rawTask as NoterModel.Task
		requireValid(type(value) == "table", "Invalid task")
		requireValid(isInteger(value.id) and value.id > 0 and value.id < notebook.nextId and not seen[value.id],
			"Invalid or duplicate task ID")
		requireValid(type(value.text) == "string" and taskTextLength(value.text) ~= nil, "Invalid task text")
		requireValid(type(value.completed) == "boolean", "Invalid task completion state")
		if value.point ~= nil then requirePoint(value.point) end
		seen[value.id] = true
		count = count + 1
	end
	for index = 1, count do
		requireValid(notebook.tasks[index] ~= nil, "Tasks must be a contiguous array")
	end
	return notebook
end

local function copyNotebook(notebook : NoterModel.Notebook) : NoterModel.Notebook
	return {
		version = notebook.version, nextId = notebook.nextId, tasks = notebook.tasks,
		hideCompleted = notebook.hideCompleted, pinned = notebook.pinned,
		windowLayout = notebook.windowLayout,
	}
end

local function copyNotebookWithTasks(notebook : NoterModel.Notebook) : NoterModel.Notebook
	local result = copyNotebook(notebook)
	result.tasks = {}
	for index, task in ipairs(notebook.tasks) do result.tasks[index] = task end
	return result
end

local function taskIndex(notebook : NoterModel.Notebook, id : integer) : integer
	for index, task in ipairs(notebook.tasks) do
		if task.id == id then return index end
	end
	return logger.fail("Unknown task ID: " .. tostring(id))
end

local function updateTask(notebook : NoterModel.Notebook, id : integer,
	update : function(NoterModel.Task)) : NoterModel.Notebook
	local index = taskIndex(notebook, id)
	local original = notebook.tasks[index]
	local task : NoterModel.Task = {
		id = original.id, text = original.text, completed = original.completed, point = original.point,
	}
	update(task)
	if task.text == original.text and task.completed == original.completed and samePoint(task.point, original.point) then
		return notebook
	end
	local result = copyNotebookWithTasks(notebook)
	result.tasks[index] = task
	return result
end

function model.addTask(notebook : NoterModel.Notebook, text : string) : NoterModel.Notebook
	local normalized = requireText(text)
	local nextId = notebook.nextId + 1
	requireValid(nextId > notebook.nextId, "Task ID sequence exhausted")
	local result = copyNotebookWithTasks(notebook)
	result.tasks[#result.tasks + 1] = {id = result.nextId, text = normalized, completed = false}
	result.nextId = nextId
	return result
end

function model.editTask(notebook : NoterModel.Notebook, id : integer, text : string) : NoterModel.Notebook
	local normalized = requireText(text)
	return updateTask(notebook, id, function(task : NoterModel.Task) task.text = normalized end)
end

function model.setCompleted(notebook : NoterModel.Notebook, id : integer, completed : boolean) : NoterModel.Notebook
	return updateTask(notebook, id, function(task : NoterModel.Task) task.completed = completed end)
end

function model.setPoint(notebook : NoterModel.Notebook, id : integer, point : NoterModel.Point | nil) : NoterModel.Notebook
	local copiedPoint : NoterModel.Point | nil = nil
	if point ~= nil then
		local location = point as NoterModel.Point
		requirePoint(location)
		copiedPoint = {x = location.x, y = location.y, z = location.z}
	end
	return updateTask(notebook, id, function(task : NoterModel.Task)
		task.point = copiedPoint
	end)
end

function model.removeTask(notebook : NoterModel.Notebook, id : integer) : NoterModel.Notebook
	local index = taskIndex(notebook, id)
	local result = copyNotebookWithTasks(notebook)
	table.remove(result.tasks, index)
	return result
end

local function moveTarget(notebook : NoterModel.Notebook, id : integer,
	direction : NoterModel.MoveDirection) : integer | nil
	requireValid(direction == "Up" or direction == "Down", "Invalid move direction")
	local index = taskIndex(notebook, id)
	local step = direction == "Up" and -1 or 1
	for target = index + step, (step == -1 and 1 or #notebook.tasks), step do
		if notebook.tasks[target].completed == notebook.tasks[index].completed then return target end
	end
	return nil
end

function model.canMoveTask(notebook : NoterModel.Notebook, id : integer,
	direction : NoterModel.MoveDirection) : boolean
	return moveTarget(notebook, id, direction) ~= nil
end

function model.moveTask(notebook : NoterModel.Notebook, id : integer,
	direction : NoterModel.MoveDirection) : NoterModel.Notebook
	local target = moveTarget(notebook, id, direction)
	if not target then return notebook end
	local targetIndex = target as integer
	local index = taskIndex(notebook, id)
	local result = copyNotebookWithTasks(notebook)
	result.tasks[index], result.tasks[targetIndex] = result.tasks[targetIndex], result.tasks[index]
	return result
end

function model.setPreferences(notebook : NoterModel.Notebook, hideCompleted : boolean,
	pinned : boolean) : NoterModel.Notebook
	if notebook.hideCompleted == hideCompleted and notebook.pinned == pinned then return notebook end
	local result = copyNotebook(notebook)
	result.hideCompleted, result.pinned = hideCompleted, pinned
	return result
end

local function windowLayoutForMode(layout : NoterModel.WindowLayout,
	mode : NoterModel.RememberMode | nil) : NoterModel.WindowLayout
	if mode == nil then return layout end
	if mode == "Ephemeral" then return DEFAULT_WINDOW_LAYOUT end
	if mode ~= "Remembered" then return logger.fail("Invalid remember mode: " .. tostring(mode)) end
	local x = math.max(0, math.min(1, layout.x))
	local y = math.max(0, math.min(1, layout.y))
	if x == layout.x and y == layout.y then return layout end
	return {x = x, y = y, expanded = layout.expanded}
end

-- With a mode, return the opening layout; without one, expose the stored normal anchor.
function model.getWindowLayout(notebook : NoterModel.Notebook,
	mode? : NoterModel.RememberMode) : NoterModel.WindowLayout
	local layout = windowLayoutForMode(notebook.windowLayout or DEFAULT_WINDOW_LAYOUT, mode)
	if mode == "Remembered" and layout.expanded then
		return EXPANDED_WINDOW_LAYOUT
	end
	return layout
end

function model.setWindowLayout(notebook : NoterModel.Notebook, layout : NoterModel.WindowLayout,
	mode? : NoterModel.RememberMode) : NoterModel.Notebook
	requireWindowLayout(layout)
	if mode == "Ephemeral" then return notebook end
	local constrained = windowLayoutForMode(layout, mode)
	local current = model.getWindowLayout(notebook)
	if current.x == constrained.x and current.y == constrained.y and current.expanded == constrained.expanded then return notebook end
	local result = copyNotebook(notebook)
	result.windowLayout = {x = constrained.x, y = constrained.y, expanded = constrained.expanded}
	return result
end

function model.visibleTasks(notebook : NoterModel.Notebook) : {NoterModel.Task}
	local result : {NoterModel.Task} = {}
	for _, task in ipairs(notebook.tasks) do
		if not task.completed then result[#result + 1] = task end
	end
	if not notebook.hideCompleted then
		for _, task in ipairs(notebook.tasks) do
			if task.completed then result[#result + 1] = task end
		end
	end
	return result
end

function model.remainingTaskCount(notebook : NoterModel.Notebook) : integer
	local count = 0
	for _, task in ipairs(notebook.tasks) do
		if not task.completed then count = count + 1 end
	end
	return count
end

return model
