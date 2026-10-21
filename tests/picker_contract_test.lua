local uiCode, reactPath = ...

local function check(loadOrder)
	local framework = {recipes = {}, recipeMetas = {}, originalRecipeFn = {}, recipeReplace = {}, tools = {},
		builtin = {WithComponentParams = 0, ActionDescriptor = -1, Selector = -2, Window = -3, ActionFn = -4}}
	local nextRecipeId = 0
	local nativeParams = {}
	for name in pairs(framework.builtin) do nativeParams[name] = {new = function() return {} end} end
	local frameworkEnvironment = setmetatable({
		_react = framework,
		log = {verbose = function() end, error = function(message) error(message) end},
		require = function(path) assert(path == "/scripts/string_util.tl"); return {} end,
		ug_require = function(path) assert(path == "/scripts/util.tl"); return {} end,
		api = {gui = {react = {
			detail = {makeRecipeId = function() nextRecipeId = nextRecipeId + 1; return nextRecipeId end},
			params = {builtin = nativeParams}, fireEvent = function() end,
		}}},
	}, {__index = _G})
	local react = assert(loadfile(reactPath, "t", frameworkEnvironment))()
	local builtin = {}
	for name in pairs(framework.builtin) do
		if name == "ActionFn" then
			builtin[name] = react.DeclareBuiltinLayoutChildWithUserdata(name, function(params) return {params.fn()} end)
		else
			local children = name == "Window" and function(params) return {params.content} end
				or function(params) return params.children end
			builtin[name] = react.DeclareBuiltinWithUserdata(name, children)
		end
	end
	local descriptorId = react.GetRecipeId(builtin.ActionDescriptor)
	local wrappedCalls = 0
	local function installOverlay()
		local original = builtin.ActionDescriptor
		-- Better Bus Overlay revision 9 replaces the module function in doReplace. For Noter,
		-- its construction-menu filter leaves the descriptor untouched and forwards this call.
		builtin.ActionDescriptor = function(...)
			wrappedCalls = wrappedCalls + 1
			return original(...)
		end
	end
	if loadOrder == "OverlayFirst" then installOverlay() end
	local dependencies = {
		["::/gui/main/react.lua"] = react,
		["::/gui/main/builtin.lua"] = builtin,
		["::/gui/main/game_react_globals.tl"] = {},
		["::/scripts/lang_util.tl"] = {},
		["::/gui/main/main_mod_button_area.tl"] = {MainModButtonAreaExtension = {}},
		["apasz_noter::/noter/model.tl"] = {},
		["apasz_noter::/noter/logger.tl"] = {debug = function() end},
	}
	local environment = setmetatable({
		getOwningModId = function() return "apasz_noter" end,
		ug_require = function(path) return assert(dependencies[path], "Unexpected dependency: " .. path) end,
		api = {gui = {mouse = {Event = {Type = {Clicked = "Clicked"}}, hasTerrainPosition = function() return true end,
			getTerrainPosition = function() return {x = 120, y = -30, z = 8} end}}},
	}, {__index = _G})
	assert(load(uiCode, "@noter/ui.script.tl", "t", environment))()
	if loadOrder == "NoterFirst" then installOverlay() end
	local picker = assert(framework.tools.NoterPointPicker)
	for _, outcome in ipairs({"Pick", "Back", "Unmount"}) do
		local nodes, unmount = {}, {}
		local context = {
			makeNodeWithProps = function(_, recipeId, _, props)
				nodes[#nodes + 1] = {recipeId = recipeId, props = props}
				return #nodes
			end,
			checkRecipeMatch = function(_, nodeId, recipeId) return nodes[nodeId].recipeId == recipeId end,
			setResult = function(self, result) self.result = result end,
			onUnmount = function(_, fn) unmount[#unmount + 1] = fn end,
			useComponentInternals = function() error("3D picker must not request UI component internals") end,
		}
		local action, selected
		local popped, finished = 0, 0
		local request = {active = true}
		local params = {request = request, onPoint = function(point)
			assert(selected == nil, "A point must only be committed once")
			selected = point
		end, onFinish = function() finished = finished + 1 end}
		local toolContext = {setActionFn = function(fn) action = fn end,
			popSelf = function() popped = popped + 1; picker.pop(nil, params) end}
		picker.push(toolContext, params)
		-- The engine executes setActionFn callbacks inside its native ActionFn recipe.
		local actionFnId = react.GetRecipeId(builtin.ActionFn)
		framework.recipes[actionFnId](context, {props = {{fn = action}}})
		local nodeId = assert(context.result[1])
		while nodes[nodeId].recipeId ~= descriptorId do
			local node = nodes[nodeId]
			local metadata = framework.recipeMetas[node.recipeId]
			assert(metadata and metadata.innerRecipeId == descriptorId,
				loadOrder .. ": picker lost native ActionDescriptor identity (descriptorNodeId.has_value())")
			framework.recipes[node.recipeId](context, node.props)
			nodeId = assert(context.result[1])
		end
		local descriptor = nodes[nodeId].props.props[1]
		assert(descriptor.tool == picker.name and type(descriptor.onBack) == "function")
		local selectorNode = nodes[assert(descriptor.children[1])]
		assert(selectorNode.recipeId == react.GetRecipeId(builtin.Selector))
		local selector = selectorNode.props.props[1]
		if outcome == "Pick" then
			assert(selector.onSelect(42, {}, {}))
			assert(selected.x == 120 and selected.y == -30 and selected.z == 8)
		elseif outcome == "Back" then
			descriptor.onBack()
		else
			for _, fn in ipairs(unmount) do fn() end
		end
		assert(not request.active and not selector.onSelect(42, {}, {}), "Late selection must be ignored")
		assert(not selector.onProcessMouseEvent({type = "Clicked", button = 2}),
			"An inactive picker must not consume mouse input")
		descriptor.onBack()
		frameworkEnvironment._reactDoExecuteJoins()
		local expectedPops = outcome == "Unmount" and 0 or 1
		assert(popped == expectedPops and finished == expectedPops, "Picker finishes once")
		assert((selected ~= nil) == (outcome == "Pick"))
	end
	assert(wrappedCalls == (loadOrder == "Vanilla" and 0 or 3), "Overlay forwarding must remain active")
	print("Native picker contract (" .. loadOrder .. "): OK")
end

for _, loadOrder in ipairs({"Vanilla", "OverlayFirst", "NoterFirst"}) do check(loadOrder) end
