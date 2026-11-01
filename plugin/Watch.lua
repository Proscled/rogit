--!strict
-- Following a branch as you work: what changed (and RoGit IDs for new objects) goes to RoGit within seconds, which
-- keeps its changes current and is the branch's autosave. Also polls RoGit, in main as well.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local EncodingService = game:GetService("EncodingService")
local ReflectionService = game:GetService("ReflectionService")
local Selection = game:GetService("Selection")
local SerializationService = game:GetService("SerializationService")

local Actions = require(script.Parent.Actions)
local App = require(script.Parent.App)
local Core = require(script.Parent.Core)
local Panel = require(script.Parent.Panel)
local Place = require(script.Parent.Place)

type Branch = Core.Branch

local state, playtest, PAUSED, TAG, SERVICES, POLL_SECONDS = Core.state, Core.playtest, Core.PAUSED, Core.TAG, Core.SERVICES, Core.POLL_SECONDS
local newId, SESSION = Core.newId, Core.SESSION
local encode, serviceSettings, sendParts, walkIds, copyPlace = Place.encode, Place.serviceSettings, Place.sendParts, Place.walkIds, Place.copyPlace
local refresh, call, applyChanges = Actions.refresh, Actions.call, Actions.applyChanges
local render = Panel.render

local function startWatching()
	-- A branch's changes stay current. RoGit copies the whole branch once, then sends only the objects that change
	-- (Studio's session IDs say which is which), so this stays quick in big places. rogit serve's copy is also the
	-- autosave.
	local watch = { dirty = true, first = 0, last = 0, seconds = 0.5, sending = false, lastFull = 0 }
	local pending = {
		-- rogit serve has no copy yet (or lost track): send a full one.
		full = true,
		-- Changed or added objects.
		objects = {} :: { [Instance]: boolean },
		-- Removed objects, with their IDs.
		removed = {} :: { [Instance]: string },
		-- Services whose own settings changed.
		services = {} :: { [Instance]: boolean },
	}
	local tracked: { Instance } = {}
	local trackedSet: { [Instance]: boolean } = {}
	for _, name in SERVICES do
		local ok, service = pcall(game.GetService, game, name)
		if ok and service then
			table.insert(tracked, service)
			trackedSet[service] = true
		end
	end

	-- Whether an object is a saved service or in one, remembered per object (dragging a model fires a lot).
	local relevance: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	local function relevant(object: Instance): boolean
		local known = relevance[object]
		if known == nil then
			known = trackedSet[object] == true
			-- Nothing under a camera is saved with the place (a merge's 3D preview lives there).
			if not known and object:FindFirstAncestorWhichIsA("Camera") then
				relevance[object] = false
				return false
			end
			for _, service in tracked do
				if known or object:IsDescendantOf(service) then
					known = true
					break
				end
			end
			relevance[object] = known
		end
		return known
	end

	local function noteEdit()
		if not watch.dirty then
			watch.dirty, watch.first = true, os.clock()
		end
		watch.last = os.clock()
	end

	-- Only edits to the place count: Studio changes plenty of its own things (outlines, panels) all the time. RoGit
	-- leaves scripts alone, so their edits don't count, but adding or removing a script changes its parent (it can
	-- turn a Folder into a code Folder, which isn't tracked, or back).
	local function touched(object: Instance)
		if not playtest.isEditing() then
			return
		end
		if object.ClassName == "Camera" or object:IsA("LuaSourceContainer") or not relevant(object) then
			return
		end
		if trackedSet[object] then
			pending.services[object] = true
		else
			pending.objects[object] = true
		end
		noteEdit()
	end
	-- Whether a new object is one Init would give an ID: saved, not a camera, and not inside something that isn't saved.
	local function trackable(object: Instance): boolean
		if object:IsA("Camera") then
			return false
		end
		local current = object
		while not trackedSet[current] do
			if not current.Archivable or current.Parent == nil then
				return false
			end
			current = current.Parent :: Instance
		end
		return true
	end

	-- A newly added object keeps its RoGit ID unless another object has it (a Ctrl+D copy, a paste); then it gets its
	-- own. Something new gets one too, so RoGit can follow it if it's renamed or moved before it's merged. This runs
	-- while Studio is still adding the object, so it's part of the same undo step.
	local function claimId(object: Instance)
		if not Core.idOwners then
			return
		end
		local id = object:GetAttribute(TAG)
		if type(id) ~= "string" then
			if trackable(object) then
				local fresh = newId(10)
				if pcall(object.SetAttribute, object, TAG, fresh) then
					Core.idOwners[fresh] = object
				end
			end
			return
		end
		local owner = Core.idOwners[id]
		if owner and owner ~= object and owner:IsDescendantOf(game) then
			local fresh = newId(10)
			object:SetAttribute(TAG, fresh)
			Core.idOwners[fresh] = object
		else
			Core.idOwners[id] = object
		end
	end

	local function added(object: Instance)
		if not playtest.isEditing() then
			return
		end
		if object:IsA("LuaSourceContainer") then
			if object.Parent then
				touched(object.Parent)
			end
			return
		end
		if relevant(object) then
			claimId(object)
		end
		touched(object)
	end

	-- Makes the list of IDs, and gives copies that share one (Ctrl+D copies from before) their own, in one undo step.
	local function claimAllIds()
		local owners: { [string]: Instance } = {}
		local copies = {}
		for _, service in tracked do
			for _, object in service:GetDescendants() do
				local id = object:GetAttribute(TAG)
				if type(id) == "string" then
					if owners[id] then
						table.insert(copies, object)
					else
						owners[id] = object
					end
				end
			end
		end
		if #copies > 0 then
			local recording = ChangeHistoryService:TryBeginRecording("RoGitTags", "RoGit IDs")
			for _, object in copies do
				local id = newId(10)
				if pcall(object.SetAttribute, object, TAG, id) then
					owners[id] = object
				end
			end
			if recording then
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			end
		end
		Core.idOwners = owners
	end
	local function removing(object: Instance)
		if not playtest.isEditing() then
			return
		end
		if object:IsA("LuaSourceContainer") then
			if object.Parent then
				touched(object.Parent)
			end
			return
		end
		if object.ClassName == "Camera" or trackedSet[object] or not relevant(object) then
			return
		end
		pending.removed[object] = object:GetDebugId(0)
		pending.objects[object] = nil
		relevance[object] = nil
		-- Cut and paste keeps an object's ID: once it's out of the place, its ID is free again.
		local id = object:GetAttribute(TAG)
		if Core.idOwners and type(id) == "string" and Core.idOwners[id] == object then
			Core.idOwners[id] = nil
		end
		noteEdit()
	end
	-- RoGit doesn't listen from Play to Stop.
	local observerConnections: { RBXScriptConnection } = {}
	local selectionConnections: { RBXScriptConnection } = {}
	local hearsEverything = false
	local function watchSelection()
		for _, connection in selectionConnections do
			connection:Disconnect()
		end
		table.clear(selectionConnections)
		if not playtest.isEditing() then
			return
		end
		for _, object in Selection:Get() do
			local objects = object:GetDescendants()
			table.insert(objects, object)
			for _, watched in objects do
				if #selectionConnections >= 5000 then
					return
				end
				table.insert(selectionConnections, watched.Changed:Connect(function()
					touched(watched)
				end))
			end
		end
	end
	local function changedByUndo()
		if not playtest.isEditing() then
			return
		end
		if not hearsEverything then
			pending.full = true
		end
		noteEdit()
	end
	local function disconnectObservers()
		for _, connection in observerConnections do
			connection:Disconnect()
		end
		for _, connection in selectionConnections do
			connection:Disconnect()
		end
		table.clear(observerConnections)
		table.clear(selectionConnections)
	end
	local function connectObservers()
		if not playtest.isEditing() or #observerConnections > 0 then
			return
		end
		table.insert(observerConnections, game.DescendantAdded:Connect(added))
		table.insert(observerConnections, game.DescendantRemoving:Connect(removing))
		-- Studio may not let plugins hear every property change. Then RoGit listens to what's selected, which is where
		-- nearly every edit happens (moving, scaling, the Properties panel), and copies the whole place now and then.
		hearsEverything = pcall(function()
			table.insert(observerConnections, game.ItemChanged:Connect(touched))
		end)
		if not hearsEverything then
			table.insert(observerConnections, Selection.SelectionChanged:Connect(watchSelection))
			watchSelection()
		end
		table.insert(observerConnections, ChangeHistoryService.OnUndo:Connect(changedByUndo))
		table.insert(observerConnections, ChangeHistoryService.OnRedo:Connect(changedByUndo))
	end

	-- Attributes and tags don't fire change events. They're edited on the selection (Properties, Tag Editor), so RoGit
	-- looks at the selected objects a few times a second.
	local marks: { [Instance]: string } = {}
	local function markOf(object: Instance): string
		local parts = {}
		for key, value in object:GetAttributes() do
			table.insert(parts, key .. "=" .. tostring(value))
		end
		table.sort(parts)
		local tags = object:GetTags()
		table.sort(tags)
		return table.concat(parts, ";") .. "|" .. table.concat(tags, ",")
	end
	local function checkSelection()
		local seen = {}
		for i, object in Selection:Get() do
			if i > 200 then
				break
			end
			local mark = markOf(object)
			if marks[object] and marks[object] ~= mark then
				touched(object)
			end
			seen[object] = mark
		end
		marks = seen
	end

	-- Terrain voxels don't fire change events either; the number of filled cells is cheap to check.
	local terrainCells = if playtest.isEditing() then workspace.Terrain:CountCells() else 0
	local function checkTerrain()
		local cells = workspace.Terrain:CountCells()
		if cells ~= terrainCells then
			terrainCells = cells
			touched(workspace.Terrain)
		end
	end

	-- Whether an object is in the copies: in a saved service, and saved itself (copies skip what isn't Archivable).
	local function inPlace(object: Instance): boolean
		local current: Instance? = object
		while current and not trackedSet[current] do
			if not current.Archivable then
				return false
			end
			current = current.Parent
		end
		return current ~= nil and current ~= object
	end

	-- Reference properties. A copy of just one object loses its references to others; RoGit sends them along.
	local REF_NAMES = {
		PrimaryPart = true, Part0 = true, Part1 = true, Attachment0 = true, Attachment1 = true, Value = true, Adornee = true,
		SoundGroup = true, CameraSubject = true,
	}
	local refNames: { [string]: { string } } = {}
	local function refsOf(class: string): { string }
		local known = refNames[class]
		if not known then
			known = {}
			local ok, infos = pcall(ReflectionService.GetPropertiesOfClass, ReflectionService, class)
			if ok then
				for _, info in infos do
					if REF_NAMES[info.Name] then
						table.insert(known, info.Name)
					end
				end
			end
			refNames[class] = known
		end
		return known
	end

	local function serviceOf(object: Instance): Instance
		local current = object
		while current.Parent and current.Parent ~= game do
			current = current.Parent
		end
		return current
	end

	-- Sends what changed since last time: a full copy when rogit serve has none, otherwise just the changed objects.
	-- Returns whether rogit serve's copy is current afterwards.
	local function sendChanges(): boolean
		local epoch = playtest.generation
		playtest.check(epoch)
		local branch = state.branch :: Branch
		if pending.full then
			pending.full = false
			table.clear(pending.objects)
			table.clear(pending.removed)
			table.clear(pending.services)
			local capture = newId(16)
			local manifest = copyPlace(capture, true)
			playtest.check(epoch)
			local reply = call("POST", "/api/branches/changes", { name = branch.name, capture = capture, manifest = manifest, session = SESSION })
			watch.lastFull = os.clock()
			-- If the IDs don't line up with the copy, every refresh stays a full copy.
			pending.full = not reply.live
			applyChanges(reply)
			return not pending.full
		end
		local objects, removed, services = pending.objects, pending.removed, pending.services
		pending.objects, pending.removed, pending.services = {}, {}, {}
		-- The changed objects that aren't inside another changed one (that one brings them along).
		local tops = {}
		for object in objects do
			if inPlace(object) then
				local covered = false
				local ancestor = object.Parent
				while ancestor and not trackedSet[ancestor] do
					if objects[ancestor] then
						covered = true
						break
					end
					ancestor = ancestor.Parent
				end
				if not covered then
					table.insert(tops, object)
				end
			end
		end
		local upserts, refs = {}, {}
		for _, top in tops do
			local ids = {}
			walkIds(top, ids)
			local parent = top.Parent :: Instance
			table.insert(upserts, {
				id = top:GetDebugId(0), parent = if trackedSet[parent] then "service:" .. parent.Name else parent:GetDebugId(0), ids = ids,
			})
			local service = serviceOf(top)
			local inside = top:GetDescendants()
			table.insert(inside, top)
			for _, object in inside do
				for _, property in refsOf(object.ClassName) do
					local ok, target = pcall(function()
						return (object :: any)[property]
					end)
					if ok and typeof(target) == "Instance" and target ~= top and not target:IsDescendantOf(top) and target:IsDescendantOf(service) then
						table.insert(refs, { id = object:GetDebugId(0), property = property, target = target:GetDebugId(0) })
					end
				end
			end
		end
		local removes = {}
		for object, id in removed do
			if not object:IsDescendantOf(game) then
				table.insert(removes, id)
			end
		end
		local settings = {}
		for service in services do
			local attributes = {}
			for key, value in service:GetAttributes() do
				attributes[key] = encode(value)
			end
			table.insert(settings, { name = service.Name, className = service.ClassName, settings = serviceSettings(service), attributes = attributes })
		end
		if #upserts == 0 and #removes == 0 and #settings == 0 then
			return true
		end
		local capture = nil
		if #upserts > 0 then
			capture = newId(16)
			local data = SerializationService:SerializeInstancesAsync(tops)
			playtest.check(epoch)
			local uploads: { pending: number, failure: string? } = { pending = 0, failure = nil }
			sendParts(capture, "Patch", buffer.tostring(EncodingService:Base64Encode(data)), uploads, epoch)
			while uploads.pending > 0 do
				task.wait()
				playtest.check(epoch)
			end
			if uploads.failure then
				error(uploads.failure, 0)
			end
		end
		playtest.check(epoch)
		local reply = call("POST", "/api/branches/patch", {
			name = branch.name, capture = capture, upserts = upserts, removes = removes, services = settings, refs = refs,
		})
		if reply.full then
			pending.full = true
			return false
		end
		applyChanges(reply)
		return true
	end

	-- Sends anything not sent yet, and the terrain (which can change unseen), so rogit serve's copy is exact. Returns
	-- whether it is; if not, the caller sends a full copy.
	App.flushChanges = function(): boolean
		local epoch = playtest.generation
		playtest.check(epoch)
		while watch.sending do
			task.wait()
			playtest.check(epoch)
		end
		if pending.full or state.branch == nil then
			return false
		end
		pending.objects[workspace.Terrain] = true
		watch.sending = true
		local ok, current = pcall(sendChanges)
		watch.sending = false
		if not ok or not playtest.isCurrent(epoch) then
			-- The changes it was sending are gone from the queue: the next refresh sends a full copy instead.
			pending.full = true
			watch.dirty = true
			playtest.check(epoch)
			return false
		end
		watch.dirty = false
		return current
	end

	local function updatePlaytestState()
		disconnectObservers()
		if playtest.isEditing() then
			-- Back from a playtest (or just loaded). RoGit wasn't listening, so the next refresh sends a full copy.
			pending.full = true
			Core.idOwners = nil
			table.clear(relevance)
			connectObservers()
			noteEdit()
			if state.problem == PAUSED then
				state.problem = nil
			end
		end
		render()
	end
	local modeConnection = playtest.service:GetPropertyChangedSignal("EditModeActive"):Connect(updatePlaytestState)
	App.plugin.Unloading:Connect(function()
		disconnectObservers()
		modeConnection:Disconnect()
	end)
	updatePlaytestState()
	task.spawn(function()
		while playtest.alive do
			if playtest.isEditing() and not state.busy then
				refresh()
			end
			task.wait(POLL_SECONDS)
		end
	end)
	task.spawn(function()
		local ticks = 0
		while playtest.alive do
			task.wait(0.1)
			if not playtest.isEditing() then
				continue
			end
			ticks += 1
			local branch = state.branch
			local inBranch = branch ~= nil and branch.has_starting_point and not state.archived and state.connected
			if not inBranch then
				pending.full = true
				continue
			end
			if ticks % 4 == 0 then
				checkSelection()
				checkTerrain()
			end
			if Core.idOwners == nil and not state.busy then
				claimAllIds()
			end
			-- Every 10 minutes, when nobody's editing, a full copy makes sure nothing was missed.
			if os.clock() - watch.lastFull > 600 and os.clock() - watch.last > 30 then
				pending.full = true
				noteEdit()
			end
			-- Bigger places take longer to send, so wait a little longer for edits to settle.
			local settle = math.clamp(watch.seconds / 2, 0.1, 3)
			local due = watch.dirty and (os.clock() - watch.last >= settle or os.clock() - watch.first >= 30)
			-- Without hearing every change, copy the whole place every so often too.
			if not hearsEverything and os.clock() - watch.lastFull >= math.max(15, watch.seconds * 20) then
				pending.full = true
				due = true
			end
			if due and not state.busy and not watch.sending then
				watch.dirty, watch.sending = false, true
				local started = os.clock()
				local epoch = playtest.generation
				local ok, failure = pcall(sendChanges)
				watch.sending = false
				watch.seconds = os.clock() - started
				if ok then
					render()
				else
					pending.full = true
					watch.dirty = true
					if playtest.isCurrent(epoch) then
						warn("RoGit couldn't refresh the changes: " .. tostring(failure))
					end
				end
			end
		end
	end)
end

return { start = startWatching }
