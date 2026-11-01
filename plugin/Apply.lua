--!strict
-- Applying a plan from RoGit (a merge, a pull, a revert, a restore or a discard) to this place.

local CollectionService = game:GetService("CollectionService")
local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")
local SerializationService = game:GetService("SerializationService")

local Core = require(script.Parent.Core)
local Place = require(script.Parent.Place)

local playtest, PAUSED, TAG, SERVICES = Core.playtest, Core.PAUSED, Core.TAG, Core.SERVICES
local OP_TAG, REF_TAG, MERGES_TAG = Core.OP_TAG, Core.REF_TAG, Core.MERGES_TAG
local findObject = Place.findObject

local function recordMerge(branch: string, id: string)
	local ok, record = pcall(HttpService.JSONDecode, HttpService, workspace:GetAttribute(MERGES_TAG) or "{}")
	if not ok or typeof(record) ~= "table" then
		record = {}
	end
	record[branch] = id
	workspace:SetAttribute(MERGES_TAG, HttpService:JSONEncode(record))
end

-- Properties a plugin can't set directly. They change through the mesh or union APIs instead.
local MESH_DATA = {
	MeshId = true, MeshContent = true, MeshData = true, InitialSize = true, PhysicalConfigData = true, PhysicsData = true,
	CollisionFidelity = true, RenderFidelity = true, HasJointOffset = true, HasSkinnedMesh = true, JointOffset = true,
	DoubleSided = true,
}
local UNION_DATA = {
	AssetId = true, ChildData = true, MeshData = true, PhysicsData = true, PhysicalConfigData = true, InitialSize = true,
	CollisionFidelity = true, RenderFidelity = true, SmoothingAngle = true,
}

-- Saved property names that scripts know by another name.
local SCRIPT_NAMES = { WorldPivotData = "WorldPivot" }

local function decodeValue(encoded: any): any
	local t, v = encoded.t, encoded.v
	if t == "Color3" then
		return Color3.new(v[1], v[2], v[3])
	elseif t == "Vector3" then
		return Vector3.new(v[1], v[2], v[3])
	elseif t == "Vector2" then
		return Vector2.new(v[1], v[2])
	elseif t == "NumberRange" then
		return NumberRange.new(v[1], v[2])
	end
	return v
end

local function copyAttributes(from: Instance, to: Instance)
	for key in to:GetAttributes() do
		if key ~= TAG and string.sub(key, 1, 4) ~= "RBX_" and from:GetAttribute(key) == nil then
			to:SetAttribute(key, nil)
		end
	end
	for key, value in from:GetAttributes() do
		if key ~= TAG and key ~= OP_TAG and key ~= REF_TAG and string.sub(key, 1, 4) ~= "RBX_" then
			to:SetAttribute(key, value)
		end
	end
end

local function copyTags(from: Instance, to: Instance)
	for _, tagName in CollectionService:GetTags(to) do
		if not from:HasTag(tagName) then
			to:RemoveTag(tagName)
		end
	end
	for _, tagName in CollectionService:GetTags(from) do
		to:AddTag(tagName)
	end
end

-- Every tagged object in this place, by RoGit ID.
local function idMap(): { [string]: Instance }
	local ids = {}
	for _, name in SERVICES do
		local ok, service = pcall(game.GetService, game, name)
		if ok and service then
			for _, object in service:GetDescendants() do
				local id = object:GetAttribute(TAG)
				if type(id) == "string" then
					ids[id] = object
				end
			end
		end
	end
	return ids
end

local function applyOperation(op: any, templates: { [number]: Instance }, ids: { [string]: Instance }, problems: { string })
	local epoch = playtest.generation
	playtest.check(epoch)
	local function find(key: string): Instance
		return findObject(key, ids) or error("Couldn't find " .. key .. " in this place.", 0)
	end
	if op.kind == "set" then
		local target, template = find(op.target), templates[op.template]
		local geometry = false
		for _, property in op.properties do
			playtest.check(epoch)
			if property == "Attributes" then
				copyAttributes(template, target)
			elseif property == "Tags" then
				copyTags(template, target)
			elseif (target:IsA("MeshPart") and MESH_DATA[property]) or (target:IsA("PartOperation") and UNION_DATA[property]) then
				geometry = true
			elseif target:IsA("Terrain") and property == "SmoothGrid" then
				-- Voxels can't be set directly: paste the incoming terrain over the whole thing.
				local terrain = target :: Terrain
				local source = template :: Terrain
				local region = source:CopyRegion(source.MaxExtents)
				terrain:Clear()
				local low = source.MaxExtents.Min
				terrain:PasteRegion(region, Vector3int16.new(low.X, low.Y, low.Z), true)
			elseif target:IsA("Terrain") and property == "MaterialColors" then
				for _, material in Enum.Material:GetEnumItems() do
					pcall(function()
						(target :: Terrain):SetMaterialColor(material, (template :: Terrain):GetMaterialColor(material))
					end)
				end
			else
				-- Some saved names differ from what scripts use.
				local name = SCRIPT_NAMES[property] or property
				local ok = pcall(function()
					(target :: any)[name] = (template :: any)[name]
				end)
				if not ok then
					table.insert(problems, target:GetFullName() .. "." .. property .. " couldn't be set")
				end
			end
		end
		playtest.check(epoch)
		for property, key in op.refs do
			(target :: any)[property] = if key == "" then nil else find(key)
		end
		if geometry then
			local ok, err = pcall(function()
				if target:IsA("MeshPart") then
					(target :: any):ApplyMesh(template)
				else
					(target :: any):SubstituteGeometry(template)
				end
			end)
			if not ok then
				table.insert(problems, target:GetFullName() .. " geometry: " .. tostring(err))
			end
		end
	elseif op.kind == "settings" then
		local service = game:GetService(op.service)
		for property, encoded in op.values do
			local ok = pcall(function()
				(service :: any)[property] = decodeValue(encoded)
			end)
			if not ok then
				table.insert(problems, op.service .. "." .. property .. " couldn't be set")
			end
		end
	elseif op.kind == "rename" then
		find(op.target).Name = op.name
	elseif op.kind == "move" then
		find(op.target).Parent = find(op.parent)
	elseif op.kind == "add" then
		local parent, object = find(op.parent), templates[op.template]
		local marked: { [string]: Instance } = {}
		for _, descendant in object:GetDescendants() do
			local marker = descendant:GetAttribute(REF_TAG)
			if marker then
				marked[marker] = descendant
				descendant:SetAttribute(REF_TAG, nil)
			end
		end
		local ownMarker = object:GetAttribute(REF_TAG)
		if ownMarker then
			marked[ownMarker] = object
			object:SetAttribute(REF_TAG, nil)
		end
		for _, fixup in op.fixups do
			local holder = marked[fixup.marker]
			if holder then
				(holder :: any)[fixup.property] = if fixup.target == "" then nil else ids[fixup.target] or findObject(fixup.target, ids)
			end
		end
		object.Parent = parent
	elseif op.kind == "remove" then
		find(op.target).Parent = nil
	end
end

-- Applies a plan's operations; conflicts apply only where `choices` says "use". Returns how many applied, how many
-- were skipped by choice, and what went wrong. The caller wraps this in one undo step.
local function runPlan(plan: any, choices: { [number]: string }): (number, number, { string })
	local epoch = playtest.generation
	playtest.check(epoch)
	local templates: { [number]: Instance } = {}
	if plan.bundle ~= "" then
		local data = EncodingService:Base64Decode(buffer.fromstring(plan.bundle))
		local decoded = SerializationService:DeserializeInstancesAsync(data)
		if not playtest.isCurrent(epoch) then
			for _, object in decoded do
				object:Destroy()
			end
			return 0, 0, { PAUSED }
		end
		for _, object in decoded do
			local index = tonumber(object:GetAttribute(OP_TAG))
			if index then
				object:SetAttribute(OP_TAG, nil)
				templates[index] = object
			end
		end
	end
	local ids = idMap()
	local problems: { string } = {}
	local applied, skipped = 0, 0
	-- Removals go last, so moves and additions can still find everything they need.
	local ordered = {}
	for _, op in plan.operations do
		if op.kind ~= "remove" then
			table.insert(ordered, op)
		end
	end
	for _, op in plan.operations do
		if op.kind == "remove" then
			table.insert(ordered, op)
		end
	end
	for _, op in ordered do
		if not playtest.isCurrent(epoch) then
			table.insert(problems, PAUSED)
			break
		end
		if op.conflict and choices[op.conflict] ~= "use" then
			skipped += 1
			continue
		end
		local ok, err = pcall(applyOperation, op, templates, ids, problems)
		if ok then
			applied += 1
		else
			table.insert(problems, tostring(err))
		end
	end
	return applied, skipped, problems
end

return {
	recordMerge = recordMerge, runPlan = runPlan, idMap = idMap, MESH_DATA = MESH_DATA, UNION_DATA = UNION_DATA,
	SCRIPT_NAMES = SCRIPT_NAMES,
}
