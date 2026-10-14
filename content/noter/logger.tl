local debugLoggingEnabled = ug_require "apasz_noter::/noter/logging_config.tl" as boolean
local logging = ug_require "apasz_noter::/noter/logging.lua" as ModLogging.Module

return logging.new("Noter", debugLoggingEnabled)
