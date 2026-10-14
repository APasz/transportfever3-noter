local debugLoggingEnabled = ug_require "/noter/logging_config.tl" as boolean
local logging = ug_require "/noter/logging.lua" as ModLogging.Module

return logging.new("Noter", debugLoggingEnabled)
