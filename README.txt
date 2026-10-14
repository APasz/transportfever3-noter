Noter
=====

A per-save to-do notebook for Transport Fever 3.

Enable Noter for a game and click the paper-and-list icon in the mod button area.
The new-task field receives focus when the window opens. Type a task and
press Enter or Add. Click a task's text to toggle its actions; double-click
its text or use Edit to change it. Enter or Save accepts the edit;
Escape or Cancel discards it. Tasks use one plain-text line.
With a controller, focus the task text and press Select to toggle its
actions, then navigate to Edit or another action button.

The checkbox marks a task complete. Completed tasks appear below active
tasks; Hide completed removes them from view. The arrow buttons reorder
tasks within their completion group. The title shows how many remain.
Only the selected task shows its actions. Completed text is dimmed.
Delete asks "Delete this task?": Yes removes it; No cancels.
Selecting another task clears the pending confirmation.

Set point starts a map picker. Click the map to attach that position;
Escape, right-click, Cancel, or switching tools cancels. The pin beside
the checkbox returns to the linked point using the current camera zoom.
Change point replaces it; Unlink removes it. A pin briefly flashes when a
point is set or visited. Closing Noter, collapsing a task or selecting
another task cancels an active picker.
Set point and Change point show a pin icon alongside their translated labels.
Point picking temporarily shelves the current game/mod tool and restores it
when finished; Unlink also cancels a pending point change.

The window opens 4% from the left and 10% from the top, matching UI Tweaks.
It is movable and pinnable. The pin and Hide completed preferences
are stored with the notebook. The window starts closed when loading a game.

Added tasks, accepted edits, completion, ordering and map points go directly
to the mod's GUI save data. Save the game to keep them across sessions.
Unsubmitted text is a draft. Each save has its own notebook; loading an older
save restores that save's notes. Removing the mod may discard its data.

Development
-----------

Run: python tools/check.py
For another installation: python tools/check.py --game-dir /path/to/game

Checks use the game's bundled Teal compiler, validate against the installed
API definitions, and run notebook and UI interaction tests under Lua 5.3.
Python and lua5.3 are required; no additional packages are needed.

strings.json translates all UI text for the 13 bundled game languages.
Keys are prefixed APASZ_NOTER_ to avoid collisions with other mods. The title
uses {count} and the game's locale-aware integer formatter. User notes stay
as entered. Mod-list metadata is translated in _metadata/modinfo.json;
description.html is a shared English description and overrides that text.
Restart the game after changing translation catalogues. Checks validate all
keys, placeholders and metadata, and exercise the UI in every language.

Logging uses the shared _logging package through relative symlinks, as in
the other mods in _modding. logger.tl provides one shared [Noter] logger.
Debug logging is disabled by default. Set DEBUG_LOGGING_ENABLED to true in
content/noter/logging_config.tl and reload UI to trace window, GUI save-data
and map-picker activity. Warnings remain visible and invalid states throw
with the Noter prefix. Checks exercise the real logger with debug off and on.
When packaging the mod, include the targets of the shared logging symlinks.

In-game verification still required:
- Open Noter, edit a task while paused, save, quit, and reload.
- Confirm notebooks remain separate between two saves.
- Pick a map point over empty ground and over a construction; try the pin.
- Cancel picking with Escape, right-click, window close and another tool.
- Check that point picking restores an existing construction or mod tool.
- Check window layout, pin behavior and scrolling at your usual UI scale.
- Check repeated row selection toggles its actions, including with a controller.
- Double-click to edit; check the window stays still, and titlebar dragging works.
- Check controller navigation to each action, editing, focus and point feedback.
