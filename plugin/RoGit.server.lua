--!strict
-- RoGit Studio plugin. Talks to RoGit (`rogit serve`), which runs in the background on this computer and keeps every
-- game's branches. Each part of the plugin is a ModuleScript inside this Script.

local RunService = game:GetService("RunService")

if not RunService:IsEdit() then
	return
end

local App = require(script.App)
App.plugin = plugin

-- Loading the actions loads everything they use: the panel, the window of changes and the 3D preview.
require(script.Actions)
require(script.Watch).start()
