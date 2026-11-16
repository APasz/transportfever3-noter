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

expect(model.characterCount("") == 0, "Empty editor text contains zero characters")
local mixedText = ""
for _, codepoint in ipairs({0, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF}) do
	local character = utf8.char(codepoint)
	expect(model.characterCount(character) == utf8.len(character),
		"Character counting supports the boundaries of every UTF-8 encoding width")
	mixedText = mixedText .. character
end
expect(model.characterCount(mixedText) == utf8.len(mixedText),
	"Mixed Unicode text is counted correctly without a runtime utf8 global")
for _, malformed in ipairs({"\128", "\255", "\194", "\194A", "\224\160", "\240\144\128",
	"\192\128", "\224\128\128", "\237\160\128", "\240\128\128\128", "\244\144\128\128", "\245\128\128\128"}) do
	expect(model.characterCount(malformed) == nil, "Reject malformed UTF-8 rather than counting invalid bytes")
end

local notebook = model.readNotebook({})
expect(#notebook.tasks == 0 and notebook.nextId == 1, "Fresh notebook")
local defaultLayout = model.getWindowLayout(notebook)
expect(defaultLayout.x == 0.04 and defaultLayout.y == 0.1 and not defaultLayout.expanded,
	"Fresh saves use the default window position and normal size")
expect(model.setWindowLayout(notebook, defaultLayout) == notebook,
	"An unchanged default window does not create saved preferences")
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
expect(hidden.tasks == reordered.tasks, "Preference updates reuse the unchanged task list")
local point = {x = 25.5, y = -80, z = 4}
local linked = model.setPoint(hidden, 1, point)
point.x = 99
expect(linked.tasks[3].point.x == 25.5, "Copy location coordinates")
expect(model.setPoint(linked, 1, {x = 25.5, y = -80, z = 4}) == linked,
	"Identical coordinates preserve the existing notebook")
local edited = model.editTask(linked, 1, "Extend both platforms")
expect(edited.tasks[3].point.x == 25.5 and linked.tasks[3].text == "Extend the railway",
	"Editing keeps the map point and previous text")
local requestedLayout = {x = 0.2, y = 0.3, expanded = true}
local positioned = model.setWindowLayout(edited, requestedLayout)
requestedLayout.x = 0.8
expect(model.getWindowLayout(positioned).x == 0.2 and edited.windowLayout == nil,
	"Window updates copy their input and preserve the previous notebook")
expect(positioned.tasks == edited.tasks, "Window layout updates reuse the unchanged task list")
expect(model.setWindowLayout(positioned, {x = 0.2, y = 0.3, expanded = true}) == positioned,
	"An unchanged saved layout is a no-op")
for _, updated in ipairs({
	model.addTask(positioned, "Another task"), model.editTask(positioned, 1, "Changed note"),
	model.setCompleted(positioned, 1, true), model.setPoint(positioned, 1, nil),
	model.moveTask(positioned, 1, "Up"), model.removeTask(positioned, 1),
}) do
	local layout = model.getWindowLayout(updated)
	expect(layout.x == 0.2 and layout.y == 0.3 and layout.expanded,
		"Notebook changes preserve the saved window layout")
	expect(updated.tasks ~= positioned.tasks and #positioned.tasks == 3
		and positioned.tasks[3].text == "Extend both platforms" and positioned.tasks[3].point ~= nil
		and not positioned.tasks[3].completed, "Task updates preserve the list shared by earlier notebook states")
end
expect(model.setPreferences(positioned, false, false).windowLayout == positioned.windowLayout,
	"Preference updates preserve the saved window layout")
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

local restored = model.readNotebook(assert(load("return " .. serialize(positioned)))())
expect(restored.tasks[3].text == "Extend both platforms" and restored.tasks[3].point.y == -80
	and restored.hideCompleted and restored.pinned, "Serializable save round-trip")
local restoredLayout = model.getWindowLayout(restored)
expect(restoredLayout.x == 0.2 and restoredLayout.y == 0.3 and restoredLayout.expanded,
	"Window layout survives a save round-trip")
expect(model.getWindowLayout(model.readNotebook(edited)).x == defaultLayout.x
	and model.readNotebook(edited).windowLayout == nil,
	"Older notebooks without layout data remain readable and use defaults")
local outsideLayout = {x = -0.15, y = 1.05, expanded = true}
local legacyOutside = model.setWindowLayout(edited, outsideLayout)
local restoredOutside = model.readNotebook(assert(load("return " .. serialize(legacyOutside)))())
expect(model.getWindowLayout(restoredOutside).x == -0.15
	and model.getWindowLayout(restoredOutside).y == 1.05,
	"Saved off-screen positions from the removed mode remain readable")
local expandedLayout = model.getWindowLayout(legacyOutside, "Remembered")
expect(expandedLayout.x == 0.5 and expandedLayout.y == 0.5 and expandedLayout.expanded
	and legacyOutside.windowLayout.x == -0.15,
	"Remembered opens expanded windows at the screen centre without changing the saved normal anchor")
local normalOutside = model.setWindowLayout(legacyOutside, {x = -0.15, y = 1.05, expanded = false})
local boundedLayout = model.getWindowLayout(normalOutside, "Remembered")
expect(boundedLayout.x == 0 and boundedLayout.y == 1 and not boundedLayout.expanded,
	"Remembered restores a bounded position for normal windows")
local ephemeralLayout = model.getWindowLayout(legacyOutside, "Ephemeral")
expect(ephemeralLayout.x == defaultLayout.x and ephemeralLayout.y == defaultLayout.y and not ephemeralLayout.expanded,
	"Ephemeral ignores any saved window position and size")
expect(model.setWindowLayout(legacyOutside, defaultLayout, "Ephemeral") == legacyOutside,
	"Ephemeral never changes saved layout data")
local bounded = model.setWindowLayout(edited, outsideLayout, "Remembered")
expect(bounded.windowLayout.x == 0 and bounded.windowLayout.y == 1 and bounded.windowLayout.expanded,
	"Remembered clamps captured anchors to screen fractions")
rejects(function() model.getWindowLayout(legacyOutside, "Unknown") end,
	"Invalid remember modes cannot silently use unbounded coordinates")
rejects(function() model.setWindowLayout(edited, outsideLayout, "Unknown") end,
	"Invalid remember modes cannot silently save unbounded coordinates")
for _, layout in ipairs({false, {}, {x = 0.2, y = 0.3}, {x = 0.2, y = 0.3, expanded = "true"},
	{x = 0/0, y = 0.3, expanded = false}, {x = 0.2, y = math.huge, expanded = false}}) do
	rejects(function() model.setWindowLayout(notebook, layout) end, "Reject invalid window layout updates")
	local invalidLayoutSave = model.newNotebook()
	invalidLayoutSave.windowLayout = layout
	rejects(function() model.readNotebook(invalidLayoutSave) end, "Reject invalid saved window layouts")
end
for _, text in ipairs({"", "  ", "a\nb", "a\rb", "a\0b"}) do
	expect(not model.canSubmitText(text), "Reject blank or multiline task input")
	rejects(function() model.addTask(notebook, text) end, "Reject invalid task text")
end
for _, character in ipairs({"x", "🚂", "界"}) do
	local atLimit = string.rep(character, model.MAX_TEXT_LENGTH)
	local overLimit = atLimit .. character
	expect(model.canSubmitText(atLimit) and model.canSubmitText("  " .. atLimit .. "  "),
		"The character limit counts normalized Unicode characters rather than UTF-8 bytes")
	expect(model.addTask(notebook, atLimit).tasks[1].text == atLimit,
		"A task exactly at the character limit is accepted intact")
	expect(not model.canSubmitText(overLimit), "Reject text beyond the character limit")
	rejects(function() model.addTask(notebook, overLimit) end, "Cannot add over-limit text")
	rejects(function() model.editTask(third, 1, overLimit) end, "Cannot edit to over-limit text")
end
expect(third.tasks[1].text == "Extend the railway", "Rejected edits preserve the previous text")
local legacy = model.newNotebook()
legacy.version = 1
local legacyText = string.rep("🚂", model.MAX_TEXT_LENGTH + 100)
legacy.nextId = 2
legacy.tasks = {{id = 1, text = legacyText, completed = false}}
local loadedLegacy = model.readNotebook(assert(load("return " .. serialize(legacy)))())
expect(loadedLegacy.tasks[1].text == legacyText, "Saved notes beyond the new limit remain readable and intact")
local completedLegacy = model.setCompleted(loadedLegacy, 1, true)
expect(model.readNotebook(completedLegacy).tasks[1].text == legacyText,
	"Unrelated updates keep over-limit saved text intact")
rejects(function() model.editTask(loadedLegacy, 1, legacyText) end,
	"Editing an older long note requires reducing it to the new limit")
expect(model.editTask(loadedLegacy, 1, "Shortened note").tasks[1].text == "Shortened note",
	"Older notes can be edited down to fit the limit")
expect(not model.canSubmitText("\255"), "Invalid UTF-8 is rejected before counting characters")
rejects(function() model.addTask(notebook, "\255") end, "Cannot save invalid UTF-8")
rejects(function() model.editTask(notebook, 99, "Test") end, "Reject missing task")
rejects(function() model.moveTask(third, 1, "Sideways") end, "Reject unknown direction")
for _, pointValue in ipairs({{x = 0, y = 0}, {y = 0, z = 0}, {x = 0, z = 0},
	{x = 0/0, y = 0, z = 0}, {x = math.huge, y = 0, z = 0}, {x = 0, y = "invalid", z = 0}}) do
	rejects(function() model.setPoint(third, 1, pointValue) end, "Reject invalid coordinate")
end
local invalid = model.newNotebook()
invalid.version = model.newNotebook().version + 1
rejects(function() model.readNotebook(invalid) end, "Reject unknown save version")
invalid = model.newNotebook()
invalid.nextId = 3
invalid.tasks = {{id = 1, text = "A", completed = false, items = {}}, {id = 1, text = "B", completed = false, items = {}}}
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

local oldSave = {
	version = 1, nextId = 4, hideCompleted = true, pinned = true,
	windowLayout = {x = 0.2, y = 0.3, expanded = true},
	tasks = {
		{id = 1, text = "Existing active note", completed = false, point = {x = 10, y = 20, z = 3}},
		{id = 3, text = "Existing completed note", completed = true},
	},
}
local migrated = model.readNotebook(oldSave)
expect(migrated.version == model.newNotebook().version and #migrated.tasks[1].items == 0
	and migrated.tasks[1].point.x == 10 and migrated.tasks[2].completed and migrated.nextId == 4
	and migrated.hideCompleted and migrated.pinned and migrated.windowLayout.expanded,
	"Version-one notes migrate without losing completion, IDs, map points or preferences")
expect(oldSave.version == 1 and oldSave.tasks[1].items == nil and migrated.tasks[1] ~= oldSave.tasks[1],
	"Migration does not modify game-owned save data")
expect(model.readNotebook(migrated) == migrated, "Current save data does not need another migration")
local checklist = model.addItem(positioned, 1, "  Extend the first platform 🚉  ")
local parent = checklist.tasks[3]
local firstItemId = parent.items[1].id
expect(#parent.items == 1 and parent.items[1].text == "Extend the first platform 🚉"
	and firstItemId == positioned.nextId and checklist.nextId == firstItemId + 1,
	"Checklist items share the notebook's stable ID sequence and normalize Unicode text")
expect(#positioned.tasks[3].items == 0 and checklist.tasks[1] == positioned.tasks[1]
	and parent.point == positioned.tasks[3].point and checklist.windowLayout == positioned.windowLayout,
	"Adding an item preserves earlier states, unrelated tasks, map points and preferences")
local twoItems = model.addItem(checklist, 1, "Extend the second platform")
local secondItemId = twoItems.tasks[3].items[2].id
local partial = model.setItemCompleted(twoItems, 1, firstItemId, true)
expect(not partial.tasks[3].completed and model.completedItemCount(partial.tasks[3]) == 1
	and not twoItems.tasks[3].items[1].completed and partial.tasks[3].items[2] == twoItems.tasks[3].items[2],
	"Checking one item leaves the parent incomplete and only replaces the changed item")
expect(model.setItemCompleted(partial, 1, firstItemId, true) == partial
	and model.editItem(partial, 1, firstItemId, "  Extend the first platform 🚉  ") == partial,
	"Unchanged item edits and completion events do not dirty the notebook")
local allItems = model.setItemCompleted(partial, 1, secondItemId, true)
expect(allItems.tasks[3].completed and model.remainingTaskCount(allItems) == model.remainingTaskCount(partial) - 1
	and #model.visibleTasks(allItems) == #model.visibleTasks(partial) - 1,
	"The last tick completes the parent and hides its whole group when Hide completed is enabled")
expect(model.setCompleted(allItems, 1, true) == allItems, "Checking an already complete checklist is a no-op")
local reopened = model.setItemCompleted(allItems, 1, firstItemId, false)
expect(not reopened.tasks[3].completed and #model.visibleTasks(reopened) == #model.visibleTasks(partial),
	"Unchecking any item reopens its parent")
local clearedItems = model.setCompleted(allItems, 1, false)
expect(model.completedItemCount(clearedItems.tasks[3]) == 0 and not clearedItems.tasks[3].completed
	and model.completedItemCount(allItems.tasks[3]) == 2,
	"Unchecking the parent clears all children without changing previous states")
local bulkChecked = model.setCompleted(partial, 1, true)
expect(bulkChecked.tasks[3].completed and model.completedItemCount(bulkChecked.tasks[3]) == 2
	and bulkChecked.tasks[3].items[1] == partial.tasks[3].items[1],
	"Checking a partial parent completes its checklist and reuses already checked items")
local withNewItem = model.addItem(allItems, 1, "Buy a train")
expect(not withNewItem.tasks[3].completed and model.completedItemCount(withNewItem.tasks[3]) == 2,
	"Adding an unchecked item reopens a completed parent")
local editedItem = model.editItem(partial, 1, firstItemId, "Changed platform")
expect(editedItem.tasks[3].items[1].text == "Changed platform" and editedItem.tasks[3].items[1].completed
	and editedItem.tasks[3].point ~= nil and partial.tasks[3].items[1].text ~= "Changed platform",
	"Editing an item preserves completion, map points and previous text")
expect(model.editTask(partial, 1, "Changed parent").tasks[3].items == partial.tasks[3].items
	and model.setPoint(partial, 1, nil).tasks[3].items == partial.tasks[3].items,
	"Parent edits and map changes retain the checklist")
do
	local countItems = model.completedItemCount
	local completionScans = 0
	model.completedItemCount = function(task)
		completionScans = completionScans + 1
		return countItems(task)
	end
	local renamed = model.editTask(partial, 1, "Renamed parent")
	local relocated = model.setPoint(renamed, 1, {x = 1, y = 2, z = 3})
	expect(completionScans == 0 and not relocated.tasks[3].completed
		and relocated.tasks[3].items == partial.tasks[3].items,
		"Parent text and location updates do not rescan an unchanged checklist")
	local finished = model.setItemCompleted(relocated, 1, secondItemId, true)
	expect(completionScans == 1 and finished.tasks[3].completed,
		"Changing checklist completion still updates the parent")
	model.completedItemCount = countItems
end
local movedItem = model.moveItem(partial, 1, secondItemId, "Up")
expect(movedItem.tasks[3].items[1].id == secondItemId and not movedItem.tasks[3].items[1].completed
	and movedItem.tasks[3].items[2].id == firstItemId and not movedItem.tasks[3].completed,
	"Item ordering stays within the checklist and does not split checked and unchecked items")
expect(model.moveItem(movedItem, 1, secondItemId, "Up") == movedItem,
	"Moving a checklist item past its boundary is a no-op")
local removedIncomplete = model.removeItem(partial, 1, secondItemId)
expect(removedIncomplete.tasks[3].completed and #removedIncomplete.tasks[3].items == 1,
	"Removing the last unchecked item completes the remaining checklist")
local withoutItems = model.removeItem(removedIncomplete, 1, firstItemId)
expect(#withoutItems.tasks[3].items == 0 and withoutItems.tasks[3].completed,
	"Removing the final item retains the parent's current completion")
expect(not model.setCompleted(withoutItems, 1, false).tasks[3].completed,
	"A note without checklist items returns to manual completion")
local replacement = model.addItem(withoutItems, 1, "Replacement")
expect(replacement.tasks[3].items[1].id > secondItemId and not replacement.tasks[3].completed,
	"Deleted checklist IDs are never reused")
expect(#model.removeTask(partial, 1).tasks == #partial.tasks - 1 and #partial.tasks[3].items == 2,
	"Deleting a parent removes its checklist without mutating previous states")
local checklistRestored = model.readNotebook(assert(load("return " .. serialize(partial)))())
expect(checklistRestored.tasks[3].items[1].completed and not checklistRestored.tasks[3].items[2].completed
	and checklistRestored.tasks[3].items[2].id == secondItemId and not checklistRestored.tasks[3].completed,
	"Checklist text, IDs, ordering and partial completion survive serialization")
for _, action in ipairs({
	function() model.addItem(partial, 99, "Missing parent") end,
	function() model.editItem(partial, 1, 99, "Missing item") end,
	function() model.setItemCompleted(partial, 1, 99, true) end,
	function() model.removeItem(partial, 1, 99) end,
	function() model.moveItem(partial, 1, 99, "Up") end,
	function() model.moveItem(partial, 1, firstItemId, "Sideways") end,
	function() model.addItem(partial, 1, "line\nbreak") end,
	function() model.editItem(partial, 1, firstItemId, string.rep("🚂", model.MAX_TEXT_LENGTH + 1)) end,
	function() model.addItem(exhausted, 1, "No ID space") end,
}) do rejects(action, "Invalid checklist mutations fail explicitly") end
local function invalidChecklist(change)
	local value = assert(load("return " .. serialize(partial)))()
	change(value.tasks[3], value)
	rejects(function() model.readNotebook(value) end, "Reject malformed checklist save data")
end
for _, value in ipairs({false, 3, "items"}) do
	invalidChecklist(function(task) task.items = value end)
end
invalidChecklist(function(task) task.items = nil end)
invalidChecklist(function(task) task.items[1] = nil end)
invalidChecklist(function(task) task.items.bad = task.items[1] end)
invalidChecklist(function(task) task.items[2].id = task.items[1].id end)
invalidChecklist(function(task) task.items[2].id = task.id end)
invalidChecklist(function(task, value) task.items[2].id = value.nextId end)
invalidChecklist(function(task) task.items[1].text = "" end)
invalidChecklist(function(task) task.items[1].completed = "true" end)
invalidChecklist(function(task) task.items[1].items = {} end)
invalidChecklist(function(task) task.items[1].point = {x = 0, y = 0, z = 0} end)
invalidChecklist(function(task) task.completed = true end)
print(string.format("Notebook behavior: %d checks passed", checks))
