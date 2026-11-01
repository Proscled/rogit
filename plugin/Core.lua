--!strict
-- What every part of the plugin shares: the playtest pause, RoGit's settings, the panel's state, talking to RoGit and
-- RoGit IDs.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local App = require(script.Parent.App)

local Core = {
	-- Where RoGit is; see findServer.
	serverBase = "http://127.0.0.1:34875",
	-- Every RoGit ID in this place and its object, once the project is set up. A copy made with Ctrl+D or pasted
	-- carries its original's ID; with this, it gets its own right away.
	idOwners = nil :: { [string]: Instance }?,
}

-- RoGit pauses while a playtest runs: this window's place stays open underneath it, and nothing should be copied from
-- it or changed in it until Stop. RunService:IsEdit() stays true meanwhile; EditModeActive is false from Play to Stop,
-- paused or not.
local PAUSED = "RoGit is paused while you playtest. Stop the playtest to carry on."
local playtest = {
	service = game:GetService("StudioTestService"),
	-- Goes up at every Play and Stop (and when the plugin unloads), so work started before one is dropped after it.
	generation = 0,
	alive = true,
}
function playtest.isEditing(): boolean
	return playtest.alive and RunService:IsEdit() and playtest.service.EditModeActive
end
function playtest.isCurrent(generation: number): boolean
	return playtest.isEditing() and generation == playtest.generation
end
function playtest.check(generation: number?)
	assert(playtest.isCurrent(generation or playtest.generation), PAUSED)
end
-- Counting Play and Stop, not just reading EditModeActive, also catches a copy that waited through a whole playtest.
local generationConnection = playtest.service:GetPropertyChangedSignal("EditModeActive"):Connect(function()
	playtest.generation += 1
end)
App.plugin.Unloading:Connect(function()
	playtest.alive = false
	playtest.generation += 1
	generationConnection:Disconnect()
end)

-- This plugin's version; `rogit plugin install` (and so the installer) fills it in.
local VERSION = "__ROGIT_VERSION__"
-- RoGit takes the first free one of these ports.
local PORTS = { 34875, 34876, 34877, 34878, 34879 }
local TAG = "RoGitId"
local POLL_SECONDS = 2
-- rogit serve stores each part at part * 3 MiB, so parts must be exactly 4 MiB of base64.
local PART_CHARS = 4 * 1024 * 1024
-- Services whose contents are saved in place files. RoGit only looks inside these.
local SERVICES = {
	"Workspace", "Lighting", "MaterialService", "ReplicatedFirst", "ReplicatedStorage", "ServerScriptService",
	"ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "Teams", "SoundService", "TextChatService",
	"Chat", "LocalizationService", "TestService", "SocialService", "VoiceChatService",
}

-- Bundle attributes (set by rogit): which operation an object belongs to, and which ones need a reference fixed.
local OP_TAG = "RoGitOp"
local REF_TAG = "RoGitRef"
-- Workspace attribute in main: the last merge of each branch, so the next merge only brings what changed after it.
local MERGES_TAG = "RoGitMerges"
-- Workspace attribute in a branch: the last update from main, so the next one only brings what changed after it.
local UPDATE_TAG = "RoGitUpdate"

export type Game = { name: string, universe_id: number, main_place_id: number }
export type Branch = { name: string, created: number, has_starting_point: boolean, merged: number?, updated: number?, pinned: boolean? }
export type State = {
	connected: boolean,
	-- The running RoGit's version, and the newest release it knows of.
	version: string?,
	latest: string?,
	game: Game?,
	-- The game of a branch file made before branch files said which game they're from, as RoGit found it.
	branchGame: number?,
	branches: { Branch },
	branch: Branch?,
	isMain: boolean?,
	experience: string?,
	busy: string?,
	notice: string?,
	problem: string?,
	-- The open window of changes: a review, merge, update, revert, restore, commit or history entry.
	view: any?,
	-- A message with buttons, for example "Archive this branch?".
	offer: any?,
	-- The branch whose extra actions (pin, archive) are showing.
	menu: string?,
	commits: { any },
	-- Everything that happened, newest first, for the graph.
	graph: { any },
	-- A branch's changes since its last commit, which of them are staged, and what they're measured from.
	changes: any?,
	staged: { [string]: boolean },
	since: any?,
	-- When unsaved work was found for this branch.
	unsaved: number?,
	-- The branch this window shows, if it was archived.
	archived: string?,
	autosaved: number?,
}

local state: State = { connected = false, branches = {}, commits = {}, graph = {}, staged = {} }

-- Talking to RoGit ---------------------------------------------------------------------------------

-- The game this window is about: the open place's game, or for a branch (a local file) the game it was made from.
local function gameId(): number
	if game.GameId ~= 0 then
		return game.GameId
	end
	local tag = workspace:GetAttribute("RoGitBranch")
	local id = if type(tag) == "string" then tonumber(string.match(tag, "^(%d+):")) else nil
	return id or state.branchGame or 0
end

-- A version ("1.2.3") as a number that sorts like the version.
local function versionRank(version: any): number
	local a, b, c = string.match(tostring(version), "^v?(%d+)%.(%d+)%.(%d+)")
	return (tonumber(a) or 0) * 1e6 + (tonumber(b) or 0) * 1e3 + (tonumber(c) or 0)
end

-- Every request says which game it's about; RoGit keeps each game's branches apart.
local function withGame(path: string): string
	return path .. (if string.find(path, "?", 1, true) then "&" else "?") .. string.format("game=%d", gameId())
end

local function request(method: string, path: string, body: any?, raw: string?, generation: number?): (boolean, any)
	local epoch = generation or playtest.generation
	if not playtest.isCurrent(epoch) then
		return false, PAUSED
	end
	local options: any = { Url = Core.serverBase .. withGame(path), Method = method }
	if raw ~= nil then
		options.Body = raw
		options.Headers = { ["Content-Type"] = "text/plain" }
	elseif body ~= nil then
		options.Body = HttpService:JSONEncode(body)
		options.Headers = { ["Content-Type"] = "application/json" }
	end
	local ok, response = pcall(HttpService.RequestAsync, HttpService, options)
	if not playtest.isCurrent(epoch) then
		return false, PAUSED
	end
	if not ok then
		return false, nil
	end
	local decoded, value = pcall(HttpService.JSONDecode, HttpService, response.Body)
	if not decoded then
		return false, "RoGit sent an unexpected reply."
	end
	if not response.Success then
		return false, value.error or ("RoGit answered HTTP " .. response.StatusCode .. ".")
	end
	return true, value
end

-- IDs ----------------------------------------------------------------------------------------------

local ID_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local random = Random.new()

local function newId(length: number): string
	local chars = table.create(length)
	for i = 1, length do
		local n = random:NextInteger(1, #ID_CHARS)
		chars[i] = string.sub(ID_CHARS, n, n)
	end
	return table.concat(chars)
end

-- This Studio window, so RoGit can tell work from before it opened.
local SESSION = newId(12)
-- Whether this window just opened its place (nothing to undo yet), rather than the plugin reloading in a window
-- that's been worked in. Only a window that just opened can be missing unsaved work.
local FRESH_WINDOW = not ChangeHistoryService:GetCanUndo()

Core.PAUSED, Core.playtest, Core.VERSION, Core.PORTS, Core.TAG, Core.POLL_SECONDS = PAUSED, playtest, VERSION, PORTS, TAG, POLL_SECONDS
Core.PART_CHARS, Core.SERVICES, Core.OP_TAG, Core.REF_TAG, Core.MERGES_TAG, Core.UPDATE_TAG = PART_CHARS, SERVICES, OP_TAG, REF_TAG, MERGES_TAG, UPDATE_TAG
Core.state, Core.gameId, Core.versionRank, Core.withGame, Core.request = state, gameId, versionRank, withGame, request
Core.newId, Core.SESSION, Core.FRESH_WINDOW = newId, SESSION, FRESH_WINDOW

return Core
