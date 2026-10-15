global record NoterModel
	record Point
		x : number
		y : number
		z : number
	end

	record Task
		id : integer
		text : string
		completed : boolean
		point : Point | nil
	end

	record Notebook
		version : integer
		nextId : integer
		tasks : {Task}
		hideCompleted : boolean
		pinned : boolean
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
	setPoint : function(Notebook, integer, Point | nil) : Notebook
	removeTask : function(Notebook, integer) : Notebook
	canMoveTask : function(Notebook, integer, MoveDirection) : boolean
	moveTask : function(Notebook, integer, MoveDirection) : Notebook
	setPreferences : function(Notebook, boolean, boolean) : Notebook
	visibleTasks : function(Notebook) : {Task}
	remainingTaskCount : function(Notebook) : integer
end
