# Noter

A per-save to-do notebook for Transport Fever 3.

Enable Noter for a game and click the paper-and-list icon in the mod button area.
The new-task field receives automatic focus only when the notebook opens.
It releases focus when editing stops. Type a task and press Enter or the plus button.
Click a task's text to toggle its actions; double-click
its text or use the pencil to change it. Enter or the tick accepts the edit;
Escape or the cross discards it. Tasks are entered on one plain-text line,
with a limit of 500 Unicode characters for new and edited notes.
Collapsed notes show one clipped line; selecting a note opens a wrapped preview
of a few lines. Edit gives access to the full text. Older notes above the limit
remain intact; shorten them to 500 characters before saving an edit.
With a controller, focus the task text and press Select to toggle its
actions, then navigate to the pencil or another action button.
Note and subitem tooltips follow the game's current input mode while the window
is open: mouse guidance mentions double-click, and controller guidance points
to the pencil button for editing.

Action buttons use the game's own icons and show translated tooltips. They share
the same button size, padding and native hover/disabled states. The trash button
is separated from the editing, ordering and location controls. Deletion prompts,
the completed filter and map-picking instructions retain translated text.

The checkbox marks a task complete. Completed tasks appear below active
tasks without a separate heading; Hide completed removes them from view. The arrow buttons reorder
tasks within their completion group. The title shows how many remain.
Only the selected task shows its actions. Completed text is dimmed.
Delete asks "Delete this task?": Yes removes it; No cancels.
Selecting another task clears the pending confirmation.

Select a note and use the indented plus beneath it to give it a checklist. Enter
or the plus saves each subitem; the cross or Escape closes the composer. Subitems use
the same text limit, editing and delete confirmation as notes. They have one
level, with no map points or further subitems. Select a subitem to edit, delete
or reorder it within its checklist; checked subitems stay in their chosen order.
Clicking an already selected subitem keeps it selected; double-click edits it.
Checklist controls appear below the last subitem and apply to the selected entry.
The parent and visible subitems keep their wrapped previews while selection moves,
so changing targets does not move the text under the pointer.
Subitems are indented, use the game's smaller annotation text and have a faint
vertical guide. Their labels sit directly beside their checkboxes. Each note and
its children form a group, with more space between groups than between subitems.
The indented plus and composer sit after the last subitem. Each accepted subitem
opens a fresh, focused input ready for the next one.
Selecting another note collapses the checklist, keeping its progress count visible.

Checking every subitem completes its parent note. A dash in the parent checkbox
means some subitems are complete. Clicking an unchecked or partial parent checks
all subitems; clicking a checked parent clears all of them. Adding an unchecked
subitem or unchecking an existing one reopens the parent. Hide completed applies
to the whole note, including its checklist; individual checked subitems remain
visible while their parent is open. The title counts notes, not subitems.
Deleting a note also deletes its checklist. Removing the last subitem leaves the
note's current completion unchanged and returns it to manual completion.
The **Subitems** mod parameter is on by default. Turning it off hides subitems,
progress counts and subitem controls while retaining the saved checklist.
Parent checkboxes still check or clear the entire checklist, including hidden
subitems. Re-enable the setting to access them again. Deleting a parent note
still deletes its checklist after confirmation.
Older notebooks upgrade automatically, preserving notes, IDs, completion, map
points and preferences. Checklist saves use format version 2 and require this
version of Noter or newer.

Set point starts a map picker. Click the map to attach that position;
Escape, right-click, the cross, or switching tools cancels. The map marker beside
the checkbox returns to the linked point using the current camera zoom.
Change point replaces it; the minus removes the link. A map marker briefly flashes when a
point is set or visited. Closing Noter, collapsing a task or selecting
another task cancels an active picker.
Set point and Change point use a map marker with translated tooltips.
Point picking temporarily shelves the current game/mod tool and restores it
when finished; Unlink also cancels a pending point change.

On a fresh save, the window opens at normal size, 4% from the left and 10%
from the top, matching UI Tweaks. It is movable and pinnable. Pin and Hide
completed preferences are stored with the notebook. The **Remember** mod
parameter controls position and normal/expanded size:

- **Ephemeral** resets both when the window closes. Notes and other preferences
  are still saved.
- **Remembered** (default) saves the normal/expanded choice and the position
  while normal, keeping that anchor within screen coordinates. Expanded windows
  reopen centred on screen; their position is not saved.

Save the game to keep remembered layouts across sessions; a fresh save starts
with the defaults. Ephemeral ignores existing layout data without erasing it,
so switching back to Remembered can restore it. The window starts closed
when loading a game.
The expand icon in the title bar switches between normal and expanded
sizes, giving the scrolling list more room. Expanded notes use the available
row width; selected previews keep their height cap. Switching sizes preserves
drafts and task selection.

In Noter's mod parameters, enable **Opaque window** for a solid window
background. It is off by default, keeping the current transparency.
Choose the setting when creating a game or loading a save through the mod list.

Added tasks, accepted edits, completion, ordering and map points go directly
to the mod's GUI save data. Save the game to keep them across sessions.
Unsubmitted text is a draft. Each save has its own notebook; loading an older
save restores that save's notes. Removing the mod may discard its data.

## Development

```sh
./tools/validate.sh
./tools/validate.sh /path/to/game
```

The validator also accepts `TF3_GAME_DIR`, as in Vehicle Readout.
`TPF3_INSTALL_DIR` and `python tools/check.py --game-dir /path/to/game`
remain available.

Typed Teal sources live in `content/`, as in Vehicle Readout, and run
directly in the game. `tlconfig.lua` configures optional generated output
under `build/`.

Checks use the game's bundled Teal compiler, validate against the installed
API definitions, and run notebook and UI interaction tests under Lua 5.3.
Picker contract tests use the bundled React implementation to check both load
orders with an ActionDescriptor wrapper like Better Bus Overlay's.
The mod runs in these tests without the `utf8` global, matching the game.
Python and lua5.3 are required; no additional packages are needed.

Rows wrap native components. A fixed-width native component provides the indent
for subitem rows and their composer. Visual styles target Noter's own row and
control classes; native window-ID selectors retain the normal/expanded geometry.
Row state classes are set on the native recipe, and preview, width and completion
states are applied directly to each text view. Icon validation checks the game's
registered resource manifest, since unused artwork can remain on disk.
Native text fields cancel editing on focus loss as well as Escape. Cancellable
editors retain focus when editing stops, then resolve cancellation after focus
events: Escape closes the editor while mouse focus loss preserves the draft for
Add or Save. Editors check their lifetime and current selection before accepting
text or cancellation, including before unmounting. Tests cover focus loss and a
render before Add, repeated submissions, native row identity, target changes and
late callbacks after Save or Cancel.

Window-position polling previously raised `API is currently restricted` from
`getPosition`: React runs `onStepTimer` callbacks as deferred steps with restricted
API access. Queue geometry reads and GUI save-data writes through `enqueueJoin`
so they run on the main thread. UI tests enforce this restriction and check that
callbacks from a closed window cannot write into a newly loaded save.
Each open request uses a distinct window key, so closing and reopening before
the next render still resets temporary state. Deferred work and close callbacks
check the request identity before acting on a window.

Position capture uses the native `Window.onMovedChange` callback used in
`gui/music_player/music_player.tl` and `gui/entity_window/view_manager.tl` in the
game's `gui.zip`. The wiki and bundled Teal definitions omit this field. Movement
notifications queue a capture through `enqueueJoin`; notifications before the
join are coalesced. There is no polling timer. Debug traces distinguish
`Window movement callback` from `Captured window position: x=..., y=...`.
Tests cover repeated notifications and idle windows. Movement notifications were
verified in-game, including after a full game restart.
Normal position capture reads the native window's top-left bounds directly.
Calibrating a title offset from the requested opening position introduced a bias
when native placement adjusted that position. No startup calibration or frame
callback is needed. Tests cover native repositioning, resolution changes and the
first normal drag after reopening expanded.
Transport Fever 3 repositions the native window when it reopens outside the
viewport. Its documented window API does not expose an overflow control.
Expanded windows also shifted vertically on their first reopening, including
when sized through a custom CSS class instead of `Window.expanded`. Remembered
therefore persists the normal/expanded flag, captures position only while normal,
and centres expanded windows when reopening. Expanded movement and close
events leave the saved normal anchor intact and do not read geometry. Tests cover
both close controls, pending callbacks, size changes and a fresh UI runtime.

Better Bus Overlay revision 9 replaces `builtin.ActionDescriptor` with an
unregistered Lua function. Registering a wrapper recipe around that function
loses the native descriptor metadata and can crash Set point with
`descriptorNodeId.has_value()`. Build the descriptor directly inside the tool's
native `ActionFn` context; the picker contract tests cover both mod load orders.

strings.json translates all UI text for the 13 bundled game languages.
Keys are prefixed APASZ_NOTER_ to avoid collisions with other mods. The title
uses {count} and the game's locale-aware integer formatter. User notes stay
as entered. Mod-list metadata is translated in _metadata/modinfo.json;
description.html contains the authored English description, translations from
that metadata, and the shared support footer; it overrides the metadata text.
Restart the game after changing translation catalogues. Checks validate all
keys, placeholders, mod parameter types and metadata, and exercise the UI
in every language.
When using a staging folder with individual symlinks, link strings.json at
its root alongside content, mod.json and _metadata so the game can load it.

Logging uses the shared _logging package through relative symlinks, as in
the other mods in _modding. logger.tl provides one shared [Noter] logger.
Debug logging is disabled by default. Set DEBUG_LOGGING_ENABLED to true in
content/noter/logging_config.tl and restart the game to trace window, GUI save-data
and map-picker activity. Warnings remain visible and invalid states throw
with the Noter prefix. Checks exercise the real logger with debug off and on.
When packaging the mod, include the targets of the shared logging symlinks.

Manual regression checks:
- Check icon tooltips, selection/completion colours, checklist guides and spacing
  at each font size, in normal and expanded views. Check that the indented plus
  and composer stay beneath the checklist and all action icons load.
- Add subitems, edit and reorder them, then tick the last one with Hide completed
  off and on. Check partial and bulk completion, reopening, and delete confirmation.
- Double-click both selected and unselected subitems, including after switching
  between siblings. Check that the rows stay in place and the correct editor opens.
- Save and reload a partial checklist; check old notes still retain their text,
  completion, points and layout. Test checklist controls with a controller and
  at both window sizes and your usual UI scale.
- Turn Subitems off through the mod list, save and reload, then re-enable it.
  Check that subitems and controls disappear and return with their saved data,
  and that parent checkboxes still check or clear the hidden checklist.
- Open Noter, edit a task while paused, save, quit, and reload.
- Confirm notebooks remain separate between two saves.
- Pick a map point over empty ground and over a construction; try the pin.
- Cancel picking with Escape, right-click, window close and another tool.
- Check that point picking restores an existing construction or mod tool.
- Check Set point, Change point and cancellation with Better Bus Overlay enabled.
- Check window layout, pin behavior and scrolling at your usual UI scale.
- Check both Remember modes through the mod list. Ephemeral must reset
  size and position on close; notes, pin and Hide completed must still persist.
- In Remembered, move the normal window and close it with the X and toolbar;
  reopening must restore its position and normal state. Save and reload to check
  persistence, and start a fresh save to check defaults.
- Expand, move and reopen through both close controls. It must remain expanded
  centred on screen; expanded movement must not overwrite the normal anchor.
  Restore normal size and verify that position tracking resumes.
- Drag twice, save with Noter still open, restart the game, and check the second
  position. Closing or resizing before saving would independently capture the
  position and mask missing movement notifications.
- Expand and restore with an empty list, a long list and a draft edit;
  check collapsed clipping, selected previews, scrolling and window placement
  at each UI scale.
- Load with Opaque window off and on; check the background in both window sizes.
- Check repeated row selection toggles its actions, including with a controller.
- Double-click to edit; check the window stays still, and titlebar dragging works.
- Check controller navigation to each action, editing, focus and point feedback.
- Switch between mouse and controller with Noter open; check that note and
  subitem tooltips update without losing selection, an edit draft or focus.
- Open a city or industry window while Noter is open, then close it with Escape
  or right-click; the new-task field should remain unfocused.
