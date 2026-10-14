local model = ...
local checks = 0

local function expect(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local function rejects(action, message)
	local ok, failure = pcall(action)
	expect(not ok and tostring(failure):find("[Noter] ERROR: ", 1, true), message)
end

local notebook = model.readNotebook({})
expect(#notebook.tasks == 0 and notebook.nextId == 1, "Fresh notebook")
expect(#model.readNotebook(nil).tasks == 0, "Missing mod save data initializes an empty notebook")
rejects(function() model.readNotebook(false) end, "Non-table saved data is invalid")
local first = model.addTask(notebook, "  Extend the railway  ")
local second = model.addTask(first, "Buy a train 🚂")
local third = model.addTask(second, "Connect the sawmill")
expect(model.remainingTaskCount(third) == 3, "Count remaining tasks")
expect(#notebook.tasks == 0 and #first.tasks == 1, "Adding must preserve earlier states")
expect(first.tasks[1].text == "Extend the railway", "Trim task text")
expect(second.tasks[2].text == "Buy a train 🚂", "Preserve Unicode")
expect(model.editTask(third, 1, "  Extend the railway  ") == third,
	"Editing to the same normalized text preserves the existing notebook")
expect(model.setCompleted(third, 1, false) == third,
	"An unchanged completion state preserves the existing notebook")
expect(model.setPreferences(third, false, false) == third,
	"Unchanged preferences preserve the existing notebook")
expect(model.setPoint(third, 1, nil) == third, "Unlinking an unlinked task is a no-op")
local completed = model.setCompleted(third, 2, true)
expect(model.remainingTaskCount(completed) == 2, "Completion updates the remaining count")
expect(not third.tasks[2].completed and completed.tasks[2].completed, "Completion is immutable")
local visible = model.visibleTasks(completed)
expect(visible[1].id == 1 and visible[2].id == 3 and visible[3].id == 2, "Completed tasks go last")
local reordered = model.moveTask(completed, 3, "Up")
visible = model.visibleTasks(reordered)
expect(visible[1].id == 3 and visible[2].id == 1 and visible[3].id == 2,
	"Reorder active tasks across a completed task")
expect(not model.canMoveTask(reordered, 3, "Up"), "First active task cannot move up")
expect(not model.canMoveTask(reordered, 2, "Down"), "Only completed task cannot move down")
expect(model.moveTask(reordered, 3, "Up") == reordered, "Boundary move leaves state unchanged")
local hidden = model.setPreferences(reordered, true, true)
expect(model.remainingTaskCount(hidden) == 2, "Hiding completed tasks does not change the remaining count")
expect(#model.visibleTasks(hidden) == 2 and hidden.pinned, "Saved filter and pin preferences")
local point = {x = 25.5, y = -80, z = 4}
local linked = model.setPoint(hidden, 1, point)
point.x = 99
expect(linked.tasks[3].point.x == 25.5, "Copy location coordinates")
expect(model.setPoint(linked, 1, {x = 25.5, y = -80, z = 4}) == linked,
	"Identical coordinates preserve the existing notebook")
local edited = model.editTask(linked, 1, "Extend both platforms")
expect(edited.tasks[3].point.x == 25.5 and linked.tasks[3].text == "Extend the railway",
	"Editing keeps the map point and previous text")
local cleared = model.setPoint(edited, 1, nil)
expect(cleared.tasks[3].point == nil and edited.tasks[3].point ~= nil, "Clear map point")
local removed = model.removeTask(cleared, 1)
local added = model.addTask(removed, "Build the depot")
expect(added.tasks[#added.tasks].id == 4, "Deleted IDs must never be reused")

local function serialize(value)
	if type(value) ~= "table" then
		if type(value) == "string" then return string.format("%q", value) end
		return tostring(value)
	end
	local entries = {}
	for key, child in pairs(value) do
		entries[#entries + 1] = "[" .. serialize(key) .. "]=" .. serialize(child)
	end
	return "{" .. table.concat(entries, ",") .. "}"
end

local restored = model.readNotebook(assert(load("return " .. serialize(edited)))())
expect(restored.tasks[3].text == "Extend both platforms" and restored.tasks[3].point.y == -80
	and restored.hideCompleted and restored.pinned, "Serializable save round-trip")
for _, text in ipairs({"", "  ", "a\nb", "a\rb", "a\0b"}) do
	expect(not model.canSubmitText(text), "Reject blank or multiline task input")
	rejects(function() model.addTask(notebook, text) end, "Reject invalid task text")
end
rejects(function() model.editTask(notebook, 99, "Test") end, "Reject missing task")
rejects(function() model.moveTask(third, 1, "Sideways") end, "Reject unknown direction")
for _, pointValue in ipairs({{x = 0, y = 0}, {y = 0, z = 0}, {x = 0, z = 0},
	{x = 0/0, y = 0, z = 0}, {x = math.huge, y = 0, z = 0}, {x = 0, y = "invalid", z = 0}}) do
	rejects(function() model.setPoint(third, 1, pointValue) end, "Reject invalid coordinate")
end
local invalid = model.newNotebook()
invalid.version = 2
rejects(function() model.readNotebook(invalid) end, "Reject unknown save version")
invalid = model.newNotebook()
invalid.nextId = 3
invalid.tasks = {{id = 1, text = "A", completed = false}, {id = 1, text = "B", completed = false}}
rejects(function() model.readNotebook(invalid) end, "Reject duplicate IDs")
invalid.tasks[2].id = 2
invalid.tasks[1].point = false
rejects(function() model.readNotebook(invalid) end, "Reject invalid stored point")
invalid.tasks[1].point = nil
invalid.tasks[1] = nil
rejects(function() model.readNotebook(invalid) end, "Reject sparse task arrays")
local exhausted = model.newNotebook()
exhausted.nextId = math.maxinteger
rejects(function() model.addTask(exhausted, "No ID space left") end, "Reject task ID overflow")
expect(#exhausted.tasks == 0 and exhausted.nextId == math.maxinteger,
	"ID exhaustion leaves the original notebook untouched")
print(string.format("Notebook behavior: %d checks passed", checks))
