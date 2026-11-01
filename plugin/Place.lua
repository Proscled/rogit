--!strict
-- The place itself: RoGit IDs on its objects, copying it to RoGit, and finding objects again.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local EncodingService = game:GetService("EncodingService")
local ReflectionService = game:GetService("ReflectionService")
local SerializationService = game:GetService("SerializationService")

local Core = require(script.Parent.Core)

local playtest, request, newId = Core.playtest, Core.request, Core.newId
local TAG, SERVICES, PART_CHARS = Core.TAG, Core.SERVICES, Core.PART_CHARS

-- Collects the objects RoGit tracks: everything saved in the place except scripts (with anything inside them) and
-- code Folders, which hold scripts and nothing but Folders besides. A Folder of models or UI with a stray script in
-- it is tracked; only its scripts are left out.
local function trackedObjects(): ({ Instance }, number)
	local epoch = playtest.generation
	playtest.check(epoch)
	local list: { Instance } = {}
	local visited = 0

	-- Returns whether `parent` holds scripts, and whether it holds anything else besides Folders.
	local function visit(parent: Instance): (boolean, boolean)
		local scripts, things = false, false
		for _, child in parent:GetChildren() do
			visited += 1
			if visited % 10000 == 0 then
				task.wait()
				playtest.check(epoch)
			end
			if child:IsA("LuaSourceContainer") then
				scripts = true
			elseif child.Archivable and not child:IsA("Camera") then
				local mark = #list
				table.insert(list, child)
				local innerScripts, innerThings = visit(child)
				scripts = scripts or innerScripts
				if not child:IsA("Folder") then
					things = true
				elseif innerScripts and not innerThings then
					for i = #list, mark + 1, -1 do
						list[i] = nil
					end
				else
					things = things or innerThings
				end
			end
		end
		return scripts, things
	end

	for _, name in SERVICES do
		local ok, service = pcall(game.GetService, game, name)
		if ok and service then
			visit(service)
		end
	end
	return list, visited
end

-- Gives every tracked object without an ID a short hidden one. Copies made with Ctrl+D share an ID, so
-- repeats get a new one. Records a single undo step, and only when something changes.
local function tagObjects(): { tagged: number, added: number, skipped: number, seconds: number }
	local started = os.clock()
	local objects, visited = trackedObjects()
	local seen: { [string]: boolean } = {}
	local missing: { Instance } = {}
	for _, object in objects do
		local id = object:GetAttribute(TAG)
		if type(id) == "string" and id ~= "" and not seen[id] then
			seen[id] = true
		else
			table.insert(missing, object)
		end
	end
	local added = 0
	if #missing > 0 then
		local recording = ChangeHistoryService:TryBeginRecording("RoGitTags", "RoGit IDs")
		for _, object in missing do
			local id = newId(10)
			if pcall(object.SetAttribute, object, TAG, id) then
				added += 1
				if Core.idOwners then
					Core.idOwners[id] = object
				end
			end
		end
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
	end
	local tagged = #objects - #missing + added
	return { tagged = tagged, added = added, skipped = visited - tagged, seconds = os.clock() - started }
end

-- Copying a place ----------------------------------------------------------------------------------

local function encode(value: any): any
	local t = typeof(value)
	if t == "boolean" or t == "number" or t == "string" then
		return { t = t, v = value }
	elseif t == "Color3" then
		return { t = t, v = { value.R, value.G, value.B } }
	elseif t == "Vector3" then
		return { t = t, v = { value.X, value.Y, value.Z } }
	elseif t == "Vector2" then
		return { t = t, v = { value.X, value.Y } }
	elseif t == "CFrame" then
		return { t = t, v = { value:GetComponents() } }
	elseif t == "EnumItem" then
		return { t = t, v = value.Value }
	elseif t == "UDim" then
		return { t = t, v = { value.Scale, value.Offset } }
	elseif t == "NumberRange" then
		return { t = t, v = { value.Min, value.Max } }
	elseif t == "BrickColor" then
		return { t = t, v = value.Number }
	end
	return nil
end

-- A service's own settings. Studio doesn't let plugins read some of them; those keep Roblox's defaults.
local function serviceSettings(service: Instance): { [string]: any }
	local settingsOut = {}
	for _, info in ReflectionService:GetPropertiesOfClass(service.ClassName) do
		if info.Serialized and info.Name ~= "Name" then
			local ok, value = pcall(function()
				return (service :: any)[info.Name]
			end)
			if ok then
				settingsOut[info.Name] = encode(value)
			end
		end
	end
	return settingsOut
end

-- Starts sending one service's copy in 4 MiB parts. `uploads` tracks the parts still on their way, across services.
local function sendParts(capture: string, service: string, text: string, uploads: { pending: number, failure: string? }, epoch: number)
	for i = 1, math.max(1, math.ceil(#text / PART_CHARS)) do
		uploads.pending += 1
		local part = string.sub(text, (i - 1) * PART_CHARS + 1, i * PART_CHARS)
		task.spawn(function()
			local ok, reply = request("POST", string.format("/api/upload?capture=%s&file=%s&part=%d", capture, service, i - 1), nil, part, epoch)
			if not ok then
				uploads.failure = reply or "Lost the connection to RoGit."
			end
			uploads.pending -= 1
		end)
	end
end

-- Lists an object and everything inside it as "id|Class", in the order copies keep them (depth first), using
-- Studio's session ID for each object. rogit serve uses these to tell later changes apart.
local function walkIds(object: Instance, out: { string })
	table.insert(out, object:GetDebugId(0) .. "|" .. object.ClassName)
	for _, child in object:GetChildren() do
		if child.Archivable then
			walkIds(child, out)
		end
	end
end

-- Copies every saved service (its children in Roblox's binary format, plus its settings) to rogit serve, with every
-- object's ID when `withIds` is set.
local function copyPlace(capture: string, withIds: boolean?): any
	local epoch = playtest.generation
	playtest.check(epoch)
	local services = {}
	local uploads: { pending: number, failure: string? } = { pending = 0, failure = nil }
	for _, name in SERVICES do
		playtest.check(epoch)
		local ok, service = pcall(game.GetService, game, name)
		if not (ok and service) then
			continue
		end
		local children = {}
		for _, child in service:GetChildren() do
			if child.Archivable then
				table.insert(children, child)
			end
		end
		if #children > 0 then
			local serialized, data = pcall(SerializationService.SerializeInstancesAsync, SerializationService, children)
			playtest.check(epoch)
			if not serialized then
				error(string.format("Studio couldn't copy %s: %s", name, tostring(data)), 0)
			end
			sendParts(capture, name, buffer.tostring(EncodingService:Base64Encode(data)), uploads, epoch)
		end
		local attributes = {}
		for key, value in service:GetAttributes() do
			attributes[key] = encode(value)
		end
		local entry: any = { name = service.Name, className = service.ClassName, settings = serviceSettings(service), attributes = attributes }
		if withIds then
			entry.ids = {}
			for _, child in children do
				walkIds(child, entry.ids)
			end
		end
		table.insert(services, entry)
	end
	while uploads.pending > 0 do
		task.wait()
		playtest.check(epoch)
	end
	playtest.check(epoch)
	if uploads.failure then
		error(uploads.failure, 0)
	end
	return { services = services }
end

-- Finds a live object by review key: RoGit ID, service, or path for untagged objects. `ids` is an optional
-- RoGitId -> object map, so repeated lookups don't scan the place each time.
local function findObject(key: string, ids: { [string]: Instance }?): Instance?
	if key == "" then
		return nil
	end
	local service = string.match(key, "^service:(.+)$")
	if service then
		local ok, found = pcall(game.GetService, game, service)
		return if ok then found else nil
	end
	local path = string.match(key, "^path:(.+)#%d+$")
	if path then
		local current: Instance? = game
		for name in string.gmatch(path, "[^/]+") do
			current = current and current:FindFirstChild(name)
		end
		return current
	end
	if ids then
		return ids[key]
	end
	for _, name in SERVICES do
		local ok, service = pcall(game.GetService, game, name)
		if ok and service then
			for _, object in service:GetDescendants() do
				if object:GetAttribute(TAG) == key then
					return object
				end
			end
		end
	end
	return nil
end

return {
	trackedObjects = trackedObjects, tagObjects = tagObjects, encode = encode, serviceSettings = serviceSettings,
	sendParts = sendParts, walkIds = walkIds, copyPlace = copyPlace, findObject = findObject,
}
