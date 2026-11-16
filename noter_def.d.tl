global record NoterModel
	record Point
		x : number
		y : number
		z : number
	end

	interface Entry
		id : integer
		text : string
		completed : boolean
	end

	record ChecklistItem is Entry
	end

	record Task is Entry
		point : Point | nil
		items : {ChecklistItem}
	end

	record WindowLayout
		x : number
		y : number
		expanded : boolean
	end

	enum RememberMode
		"Ephemeral"
		"Remembered"
	end

	record Notebook
		version : integer
		nextId : integer
		tasks : {Task}
		hideCompleted : boolean
		pinned : boolean
		windowLayout : WindowLayout | nil
	end

	enum MoveDirection
		"Up"
		"Down"
	end

	MAX_TEXT_LENGTH : integer
	newNotebook : function() : Notebook
	readNotebook : function(table | nil) : Notebook
	normalizeText : function(string) : string
	characterCount : function(string) : integer | nil
	canSubmitText : function(string) : boolean
	addTask : function(Notebook, string) : Notebook
	editTask : function(Notebook, integer, string) : Notebook
	setCompleted : function(Notebook, integer, boolean) : Notebook
	completedItemCount : function(Task) : integer
	addItem : function(Notebook, integer, string) : Notebook
	editItem : function(Notebook, integer, integer, string) : Notebook
	setItemCompleted : function(Notebook, integer, integer, boolean) : Notebook
	removeItem : function(Notebook, integer, integer) : Notebook
	moveItem : function(Notebook, integer, integer, MoveDirection) : Notebook
	setPoint : function(Notebook, integer, Point | nil) : Notebook
	removeTask : function(Notebook, integer) : Notebook
	canMoveTask : function(Notebook, integer, MoveDirection) : boolean
	moveTask : function(Notebook, integer, MoveDirection) : Notebook
	setPreferences : function(Notebook, boolean, boolean) : Notebook
	getWindowLayout : function(Notebook, ?RememberMode) : WindowLayout
	setWindowLayout : function(Notebook, WindowLayout, ?RememberMode) : Notebook
	visibleTasks : function(Notebook) : {Task}
	remainingTaskCount : function(Notebook) : integer
end
