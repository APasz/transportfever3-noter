local compilerPath, gameRoot, modRoot = assert(arg[1]), assert(arg[2]), assert(arg[3])
local translations = assert(loadfile(assert(arg[4])))()
local file = assert(io.open(compilerPath, "rb"))
local source = assert(file:read("*a"))
file:close()

local function patchOnce(original, replacement)
	local first, last = source:find(original, 1, true)
	assert(first and not source:find(original, last + 1, true), "Bundled compiler patch point changed")
	source = source:sub(1, first - 1) .. replacement .. source:sub(last + 1)
end

-- The game's compiler resolves modules through native APIs; use files for this standalone check.
patchOnce([[      -- local fd = io.open(tl_filename, "rb")
      -- if fd then
         -- return tl_filename, fd, tried
      -- end]], [[      local fd = io.open(tl_filename, "rb")
      if fd then
         return tl_filename, fd, tried
      end]])
patchOnce([[   if mod then
      return mod, env.module_filenames[module_name]
   else
      return a_type(w, "invalid", {}), false
   end]], [[   if mod then
      return mod, env.module_filenames[module_name]
   end]])

log = {error = function() end}
local teal = assert(load(source, "@" .. compilerPath, "t", _ENV))()
package.path = table.concat({
	gameRoot .. "/api/tealdef/?.lua", gameRoot .. "/base/tealdef/?.lua",
	modRoot .. "/?.lua", package.path,
}, ";")
local environment = teal.init_env(false)

local function check(path)
	local result = teal.process(modRoot .. "/" .. path, environment)
	for _, diagnostics in ipairs({result.syntax_errors, result.type_errors, result.warnings}) do
		for _, diagnostic in ipairs(diagnostics) do
			io.stderr:write(string.format("%s:%d:%d: %s\n",
				diagnostic.filename or path, diagnostic.y, diagnostic.x, diagnostic.msg))
		end
	end
	assert(#result.syntax_errors + #result.type_errors + #result.warnings == 0, path .. " failed checks")
	print(path .. ": OK")
	return assert(teal.pretty_print_ast(result.ast, "5.3"))
end

check("all_def.tl")
local moduleCode = {}
for _, name in ipairs({"logging_config", "logger", "model"}) do
	moduleCode["/noter/" .. name .. ".tl"] = check("content/noter/" .. name .. ".tl")
end
local uiCode = check("content/noter/ui.script.tl")

local function newRuntime(debugOverride)
	local entries = {}
	local function capture(level)
		return function(message, details)
			entries[#entries + 1] = {level = level, message = message, details = details}
		end
	end
	local runtimeEnvironment = setmetatable({log = {
		verbose = capture("verbose"), message = capture("message"),
		warning = capture("warning"), error = capture("error"),
	}}, {__index = _G})
	local modules = {}
	modules["/noter/logging.lua"] = assert(loadfile(modRoot .. "/content/noter/logging.lua", "t", runtimeEnvironment))()
	if debugOverride ~= nil then modules["/noter/logging_config.tl"] = debugOverride end
	runtimeEnvironment.ug_require = function(path)
		if modules[path] == nil then
			local code = assert(moduleCode[path], "Unexpected runtime dependency: " .. path)
			modules[path] = assert(load(code, "@" .. path, "t", runtimeEnvironment))()
		end
		return modules[path]
	end
	return {
		model = runtimeEnvironment.ug_require("/noter/model.tl"),
		logger = runtimeEnvironment.ug_require("/noter/logger.tl"),
		debugLoggingEnabled = runtimeEnvironment.ug_require("/noter/logging_config.tl"),
		entries = entries,
		translations = translations,
	}
end

local runtime = newRuntime()
assert(not runtime.debugLoggingEnabled, "Production debug logging must default to disabled")
assert(loadfile(modRoot .. "/tests/model_test.lua"))(runtime.model)
local testUi = assert(loadfile(modRoot .. "/tests/ui_test.lua"))
testUi(runtime, uiCode, modRoot)
testUi(newRuntime(true), uiCode, modRoot)

for _, path in ipairs({"content/noter/menu.res.lua", "content/noter/noter.css.lua", "tlconfig.lua"}) do
	assert(loadfile(modRoot .. "/" .. path))
end
print("Lua resource syntax: OK")
