--!strict
-- What RoGit does when asked: finding and polling RoGit, Init, making, opening, merging and archiving branches,
-- commits, pulls, reverts, restoring unsaved work, and applying the window of changes.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")

local App = require(script.Parent.App)
local Apply = require(script.Parent.Apply)
local Core = require(script.Parent.Core)
local Look = require(script.Parent.Look)
local Panel = require(script.Parent.Panel)
local Place = require(script.Parent.Place)
local Preview = require(script.Parent.Preview)
local Review = require(script.Parent.Review)

type Branch = Core.Branch
type Game = Core.Game

local state, playtest, PAUSED, PORTS, SESSION, UPDATE_TAG = Core.state, Core.playtest, Core.PAUSED, Core.PORTS, Core.SESSION, Core.UPDATE_TAG
local request, withGame, versionRank, newId = Core.request, Core.withGame, Core.versionRank, Core.newId
local tagObjects, copyPlace, findObject = Place.tagObjects, Place.copyPlace, Place.findObject
local clock, formatTime = Look.clock, Look.formatTime
local render, uncommitted, KIND_TEXT = Panel.render, Panel.uncommitted, Panel.KIND_TEXT
local initButton, nameBox, createButton, commitBox = Panel.initButton, Panel.nameBox, Panel.createButton, Panel.commitBox
local commitButton, pullButton, restoreButton, dismissButton = Panel.commitButton, Panel.pullButton, Panel.restoreButton, Panel.dismissButton
local SINCE, KINDS, reviewWidget, showView = Review.SINCE, Review.KINDS, Review.widget, Review.showView
local closeButton, applyButton = Review.closeButton, Review.applyButton
local runPlan, recordMerge = Apply.runPlan, Apply.recordMerge

local openBranch: (string) -> ()
local startMerge: (string) -> ()
local setPinned: (string, boolean) -> ()
local confirmArchive: (string) -> ()
local openHistory: (any) -> ()
local viewCommit: (any, string) -> ()
local startRevert: (any) -> ()
local selectObject: (string) -> ()
local discard: ({ string }) -> ()
local setStaged: ({ string }) -> ()

local dropView: () -> ()
reviewWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
	-- Closing the window with its X is the same as Cancel or Close.
	if not reviewWidget.Enabled and state.view then
		dropView()
	end
	render()
end)

local recordingStart = false

local function run(first: string, action: () -> ())
	if not playtest.isEditing() then
		return
	end
	if state.busy then
		return
	end
	state.busy, state.problem, state.notice, state.offer = first, nil, nil, nil
	render()
	local ok, failure = pcall(action)
	state.busy = nil
	if not ok then
		state.problem = tostring(failure)
	end
	render()
end

-- Good news shows for a few seconds, then clears.
local function flash(textValue: string)
	state.notice = textValue
	task.delay(5, function()
		if state.notice == textValue then
			state.notice = nil
			render()
		end
	end)
end

local function step(textValue: string)
	state.busy = textValue
	render()
end

local function call(method: string, path: string, body: any?): any
	local ok, reply = request(method, path, body)
	if not ok then
		error(reply or "Lost the connection to RoGit.", 0)
	end
	return reply
end

-- Copies this place to RoGit and returns the capture ID and manifest.
local function copy(): (string, any)
	local capture = newId(16)
	return capture, copyPlace(capture)
end

openBranch = function(name: string)
	local ok, reply = request("POST", "/api/branches/open", { name = name })
	state.problem = if ok then nil else (reply or "Couldn't reach RoGit.")
	state.notice = if ok then "Opening " .. name .. "…" else nil
	render()
end

-- The open local file's name. Rojo renames the place to its project's name when it syncs; a branch file still says
-- which branch it is on its Workspace.
local function fileName(): string
	if string.sub(game.Name, -5) == ".rbxl" then
		return game.Name
	end
	local tag = workspace:GetAttribute("RoGitBranch")
	local branch = if type(tag) == "string" then string.match(tag, "^%d+:(.+)$") else nil
	return if branch then branch .. ".rbxl" else game.Name
end

local function statusPath(): string
	local file = if game.PlaceId == 0 then "&file=" .. HttpService:UrlEncode(fileName()) else ""
	return "/api/rogit?place=" .. string.format("%d", game.PlaceId) .. file .. "&session=" .. SESSION
end

-- Looks through the ports for RoGit (the newest, if an older one is still running). Returns its reply.
local lastSearch = 0
local function findServer(): (boolean, any)
	local epoch = playtest.generation
	if not playtest.isCurrent(epoch) then
		return false, PAUSED
	end
	lastSearch = os.clock()
	local found: { [number]: any } = {}
	local waiting = #PORTS
	for i, port in PORTS do
		task.spawn(function()
			if not playtest.isCurrent(epoch) then
				waiting -= 1
				return
			end
			local base = "http://127.0.0.1:" .. port
			local ok, response = pcall(HttpService.RequestAsync, HttpService, { Url = base .. withGame(statusPath()), Method = "GET" })
			if playtest.isCurrent(epoch) and ok and response.Success then
				local decoded, reply = pcall(HttpService.JSONDecode, HttpService, response.Body)
				if decoded and reply.server == "rogit" then
					found[i] = { base = base, reply = reply }
				end
			end
			waiting -= 1
		end)
	end
	while waiting > 0 do
		task.wait()
		if not playtest.isCurrent(epoch) then
			return false, PAUSED
		end
	end
	if not playtest.isCurrent(epoch) then
		return false, PAUSED
	end
	local best = nil
	for i = 1, #PORTS do
		local candidate = found[i]
		if candidate and (best == nil or versionRank(candidate.reply.version) > versionRank(best.reply.version)) then
			best = candidate
		end
	end
	if best then
		Core.serverBase = best.base
		return true, best.reply
	end
	return false, nil
end

local function refresh()
	local epoch = playtest.generation
	if not playtest.isCurrent(epoch) then
		return
	end
	local ok, reply = request("GET", statusPath())
	if not playtest.isCurrent(epoch) then
		return
	end
	-- RoGit isn't where it was (or never was): look through the ports now and then.
	if not ok and os.clock() - lastSearch > 5 then
		ok, reply = findServer()
	end
	if not playtest.isCurrent(epoch) then
		return
	end
	if ok and not state.connected then
		-- RoGit (re)started: check this place again.
		state.isMain, state.problem = nil, nil
	end
	state.connected = ok
	if ok then
		state.version, state.latest = reply.version, reply.latest
		state.game = reply.project and reply.project.game
		if type(reply.game) == "number" and reply.game ~= 0 then
			state.branchGame = reply.game
		end
		state.branches = reply.branches or {}
		state.branch = reply.branch
		state.commits = reply.commits or {}
		state.unsaved = reply.unsaved
		state.graph = reply.graph or {}
		state.archived = reply.archived
		if not state.game and state.isMain == nil and game.PlaceId ~= 0 and game.GameId ~= 0 then
			local found, place = request("GET", string.format("/api/place?game=%d&place=%d", game.GameId, game.PlaceId))
			if not playtest.isCurrent(epoch) then
				return
			end
			if found then
				state.isMain, state.experience, state.problem = place.isMain, place.experience, nil
			elseif place then
				state.problem = place
			end
		end
	end
	render()
	-- A branch that just opened for the first time: copy it once as its starting point.
	local branch = state.branch
	if branch and not branch.has_starting_point and not recordingStart then
		recordingStart = true
		run("Getting the branch ready…", function()
			local capture, manifest = copy()
			call("POST", "/api/branches/start", { name = branch.name, capture = capture, manifest = manifest })
		end)
		recordingStart = false
	end
	-- A branch is waiting to be updated from main: send it a copy of main.
	local wanted = ok and reply.copy
	if wanted and not state.busy then
		run("Sending main to " .. wanted.branch .. "…", function()
			local sent, failure = pcall(function()
				tagObjects()
				local manifest = copyPlace(wanted.capture)
				call("POST", "/api/main/copy", { capture = wanted.capture, manifest = manifest })
			end)
			if not sent then
				request("POST", "/api/main/copy", { capture = wanted.capture, failed = tostring(failure) })
				error(failure, 0)
			end
			flash("Sent main to " .. wanted.branch .. ".")
		end)
	end
end

initButton.Activated:Connect(function()
	run("Checking with RoGit…", function()
		call("POST", "/api/init", { game = game.GameId, place = game.PlaceId })
		step("Giving every object an ID…")
		local report = tagObjects()
		request("POST", "/api/init/done", report)
		state.notice = string.format("Done: %d objects have an ID. Save main to keep them.", report.tagged)
	end)
	refresh()
end)

local function createBranch()
	local name = string.gsub(nameBox.Text, "^%s*(.-)%s*$", "%1")
	if name == "" then
		state.problem = "Type a name for the branch first."
		render()
		return
	end
	run("Copying main…", function()
		tagObjects()
		local capture, manifest = copy()
		step("Building " .. name .. "…")
		call("POST", "/api/branches", { name = name, capture = capture, manifest = manifest })
		nameBox.Text = ""
		flash("Created " .. name .. ". It's opening in Studio.")
	end)
	refresh()
end

createButton.Activated:Connect(createBranch)
nameBox.FocusLost:Connect(function(enter)
	if enter then
		createBranch()
	end
end)

-- Closes a window of changes that's waiting for a choice, telling rogit serve.
dropView = function()
	local view = state.view
	if view and KINDS[view.kind].apply then
		request("POST", "/api/branches/cancel", { name = view.branch, kind = view.kind })
	end
	Preview.clear()
	state.view = nil
	reviewWidget.Enabled = false
end

-- Takes a reply with a branch's changes (from a refresh or a commit).
local function applyChanges(reply: any)
	state.changes = reply.changes
	state.since = reply.since
	local staged = {}
	for _, key in reply.staged or {} do
		staged[key] = true
	end
	state.staged = staged
	if reply.time then
		state.autosaved = reply.time
	end
end

-- Commits everything in the branch as it is now, for a pull or a revert (like git's own commits for those).
-- Sends a request about the branch as it is in Studio: from rogit serve's copy (kept current, so this is quick), or
-- with a full copy when it has none.
local function callWithBranch(path: string, body: any): any
	if App.flushChanges() then
		body.live = true
		local reply = call("POST", path, body)
		if not reply.full then
			return reply
		end
		body.live = nil
	end
	body.capture, body.manifest = copy()
	return call("POST", path, body)
end

local function autoCommit(message: string)
	local branch = state.branch :: Branch
	local ok, reply = pcall(callWithBranch, "/api/branches/commit", { name = branch.name, message = message, auto = true })
	if ok then
		state.commits = reply.commits
		applyChanges(reply)
	end
end

-- Commits the staged changes (or all of them, when none are staged). Returns whether it worked.
local function commitBranch(): boolean
	local branch = state.branch
	if not branch then
		return false
	end
	local messageText = string.gsub(commitBox.Text, "^%s*(.-)%s*$", "%1")
	local done = false
	run("Committing…", function()
		local reply = callWithBranch("/api/branches/commit", { name = branch.name, message = messageText })
		state.commits = reply.commits
		applyChanges(reply)
		commitBox.Text = ""
		flash("Committed “" .. reply.commit.message .. "”.")
		done = true
	end)
	return done
end

-- In a branch: copy it, then wait for main (open in Studio) to send its copy, and show what the pull brings.
local function startUpdate()
	local branch = state.branch
	if not branch or state.busy then
		return
	end
	dropView()
	run("Copying the branch…", function()
		local epoch = playtest.generation
		tagObjects()
		local capture, manifest = copy()
		call("POST", "/api/branches/update", { name = branch.name, capture = capture, manifest = manifest })
		step("Waiting for main… Keep " .. (if state.game then (state.game :: Game).name else "main") .. " open in Studio.")
		local path = "/api/branches/update?name=" .. HttpService:UrlEncode(branch.name)
		while true do
			task.wait(0.5)
			playtest.check(epoch)
			local reply = call("GET", path)
			if not reply.waiting then
				showView({
					kind = "update", data = reply.plan, branch = branch.name, id = reply.update,
					title = "Pull main into " .. branch.name, subtitle = SINCE[reply.since] or SINCE.start,
				})
				break
			elseif reply.offered and state.busy ~= "Main is sending a copy…" then
				step("Main is sending a copy…")
			end
		end
	end)
	render()
end

-- Like git, pulling wants the branch's own work committed first.
local function startPull()
	if state.busy then
		return
	end
	if uncommitted() > 0 then
		state.notice, state.problem = nil, nil
		state.offer = {
			text = "Commit your changes before pulling from main.",
			actions = {
				{ label = "Commit and pull", kind = "primary", run = function()
					if commitBranch() then
						startUpdate()
					end
				end },
				{ label = "Cancel", kind = "quiet", run = function() end },
			},
		}
		render()
		return
	end
	startUpdate()
end

startMerge = function(name: string)
	if state.busy then
		return
	end
	dropView()
	run("Copying main…", function()
		tagObjects()
		local capture, manifest = copy()
		step("Comparing " .. name .. " with main…")
		local reply = call("POST", "/api/branches/merge", { name = name, capture = capture, manifest = manifest })
		local source = if reply.source == "commit"
			then "branch at “" .. (reply.commit or "") .. "”"
			else "branch as " .. reply.source .. " " .. clock(reply.sourceTime)
		local left = if reply.uncommitted and reply.uncommitted > 0
			then string.format(" · %d uncommitted change%s left out", reply.uncommitted, if reply.uncommitted == 1 then "" else "s")
			else ""
		showView({
			kind = "merge", data = reply.plan, branch = name, id = reply.merge, title = "Merge " .. name .. " into main",
			subtitle = (SINCE[reply.since] or SINCE.start) .. " · " .. source .. left,
		})
	end)
	render()
end

setPinned = function(name: string, pinned: boolean)
	state.menu = nil
	local ok, reply = request("POST", "/api/branches/pin", { name = name, pinned = pinned })
	if ok then
		state.branches = reply.branches
	else
		state.problem = reply
	end
	render()
end

local function archiveBranch(name: string)
	run("Archiving " .. name .. "…", function()
		local reply = call("POST", "/api/branches/archive", { name = name })
		state.branches = reply.branches
		flash("Archived " .. name .. ".")
	end)
	refresh()
end

confirmArchive = function(name: string)
	state.notice, state.problem = nil, nil
	state.offer = {
		text = "Archive " .. name .. "? This deletes its branch file and closes it in Studio.",
		actions = {
			{ label = "Archive", kind = "danger", run = function()
				archiveBranch(name)
			end },
			{ label = "Cancel", kind = "quiet", run = function() end },
		},
	}
	render()
end

openHistory = function(event: any)
	run("Opening…", function()
		local reply = call("GET", "/api/history/rows?id=" .. event.id)
		showView({
			kind = "history", branch = event.branch, data = { rows = reply.rows, truncated = reply.truncated, summary = event.summary or {} },
			title = string.format(KIND_TEXT[event.kind] or "%s", event.branch), subtitle = formatTime(event.time),
		})
	end)
end

viewCommit = function(commit: any, branchName: string)
	run("Opening…", function()
		local reply = call("POST", "/api/branches/commit/view", { name = branchName, id = commit.id })
		local here = state.branch ~= nil and (state.branch :: Branch).name == branchName
		showView({
			kind = "commit", data = reply.review, branch = branchName, commit = commit, canRevert = here,
			title = commit.message, subtitle = branchName .. " · " .. formatTime(commit.time),
		})
	end)
end

startRevert = function(commit: any)
	local branch = state.branch
	if not branch then
		return
	end
	dropView()
	local lost = uncommitted()
	run("Comparing with “" .. commit.message .. "”…", function()
		local reply = callWithBranch("/api/branches/revert", { name = branch.name, id = commit.id })
		showView({
			kind = "revert", data = reply.plan, branch = branch.name, record = reply.record, message = commit.message,
			title = "Revert to “" .. commit.message .. "”",
			subtitle = formatTime(commit.time)
				.. (if lost > 0 then string.format(" · %d uncommitted change%s will be undone too", lost, if lost == 1 then "" else "s") else ""),
		})
	end)
end

selectObject = function(key: string)
	local object = findObject(key)
	if object then
		Selection:Set({ object })
	end
end

setStaged = function(keys: { string })
	local staged = {}
	for _, key in keys do
		staged[key] = true
	end
	state.staged = staged
	render()
	local branch = state.branch
	if branch then
		request("POST", "/api/branches/stage", { name = branch.name, keys = keys })
	end
end

commitButton.Activated:Connect(commitBranch)
commitBox.FocusLost:Connect(function(enter)
	if enter then
		commitBranch()
	end
end)
pullButton.Activated:Connect(startPull)

restoreButton.Activated:Connect(function()
	local branch = state.branch
	if not branch then
		return
	end
	dropView()
	local from = state.unsaved
	run("Comparing…", function()
		local reply = callWithBranch("/api/branches/restore", { name = branch.name })
		showView({
			kind = "restore", data = reply.plan, branch = branch.name, record = reply.record, title = "Restore unsaved work",
			subtitle = if from then "From " .. formatTime(from) else nil,
		})
	end)
end)

dismissButton.Activated:Connect(function()
	local branch = state.branch
	if branch then
		request("POST", "/api/branches/unsaved/dismiss", { name = branch.name })
		state.unsaved = nil
		render()
	end
end)

local VERBS = {
	merge = { "Merge", "Merging…", "Merged" }, update = { "Pull", "Pulling…", "Pulled" },
	revert = { "Revert", "Reverting…", "Reverted" }, restore = { "Restore", "Restoring…", "Restored" },
}

-- Applies the open merge (in main), update, revert or restore (in a branch) as one undo step.
local function applyView()
	local view = state.view
	if not view or not view.ready then
		return
	end
	local kind = view.kind
	local verbs = VERBS[kind]
	-- The previews go first: they'd be in the way of finding objects by ID.
	Preview.clear()
	state.view = nil
	reviewWidget.Enabled = false
	run(verbs[2], function()
		local recording = ChangeHistoryService:TryBeginRecording("RoGit" .. verbs[1], "RoGit " .. string.lower(verbs[1]) .. " " .. view.branch)
		local applied, skipped, problems = runPlan(view.data, view.choices)
		-- Recorded in the same undo step, so undoing it (or not saving) forgets it too. If something couldn't be
		-- applied, the next merge or update starts from earlier and offers it again.
		local clean = #problems == 0
		if clean and kind == "merge" and view.id then
			recordMerge(view.branch, view.id)
		elseif clean and kind == "update" and view.id then
			workspace:SetAttribute(UPDATE_TAG, view.id)
		elseif clean and (kind == "revert" or kind == "restore") then
			workspace:SetAttribute(UPDATE_TAG, if view.record and view.record ~= "" then view.record else nil)
		end
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		local report: any = { name = view.branch, applied = applied, skipped = skipped, failed = problems }
		if kind == "merge" then
			report.merge = if clean then view.id else nil
			request("POST", "/api/branches/merged", report)
		elseif kind == "update" then
			report.update = if clean then view.id else nil
			request("POST", "/api/branches/updated", report)
		else
			report.kind = kind
			request("POST", "/api/branches/restored", report)
		end
		state.view = nil
		local done = string.format("%s: %d change%s.", verbs[3], applied, if applied == 1 then "" else "s")
		if not clean then
			done ..= string.format(" %d couldn't be applied.", #problems)
		end
		if kind == "merge" then
			-- The graph shows the merge; only problems need a message.
			if not clean then
				state.problem = done
			end
		else
			if kind == "update" then
				step("Committing the pull…")
				autoCommit("Pull from main")
			elseif kind == "revert" then
				step("Committing the revert…")
				autoCommit("Revert to “" .. (view.message or "commit") .. "”")
			end
			if clean then
				flash(done .. " Save with Ctrl+S.")
			else
				state.problem = done
			end
		end
	end)
	refresh()
end

-- Puts uncommitted changes (`keys`) back the way the last commit had them, like VS Code's Discard Changes.
discard = function(keys: { string })
	local branch = state.branch
	if not branch or #keys == 0 then
		return
	end
	run("Discarding…", function()
		local reply = callWithBranch("/api/branches/discard", { name = branch.name, keys = keys })
		local recording = ChangeHistoryService:TryBeginRecording("RoGitDiscard", "RoGit discard changes")
		local _, _, problems = runPlan(reply.plan, {})
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		if #problems > 0 then
			for _, problem in problems do
				warn("RoGit discard: " .. problem)
			end
			state.problem = string.format("%d couldn't be put back; see the Output window.", #problems)
		else
			flash(string.format("Discarded %d change%s. Ctrl+Z brings %s back.", #keys, if #keys == 1 then "" else "s", if #keys == 1 then "it" else "them"))
		end
	end)
end

applyButton.Activated:Connect(function()
	local view = state.view
	if not view then
		return
	elseif view.kind == "commit" then
		startRevert(view.commit)
	else
		applyView()
	end
end)
closeButton.Activated:Connect(function()
	dropView()
	render()
end)

App.openBranch, App.startMerge, App.setPinned, App.confirmArchive = openBranch, startMerge, setPinned, confirmArchive
App.openHistory, App.viewCommit, App.selectObject, App.setStaged, App.discard = openHistory, viewCommit, selectObject, setStaged, discard

return { refresh = refresh, call = call, applyChanges = applyChanges }
