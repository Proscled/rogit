--!strict
-- The 3D preview. While a merge (or a pull, revert or restore) waits in its window, the 3D view shows what it would
-- do: new objects in green, changed ones in orange where they'll end up, removed ones in red. The previews are
-- copies under this window's camera, which RoGit doesn't track and Studio doesn't save, and they go when the window
-- closes. Changes with nothing to see (ReplicatedStorage, Lighting settings, a Folder's attributes) are only in the
-- list. Roblox draws at most 31 Highlights at once, so each color is one Highlight over a Model of copies.

local EncodingService = game:GetService("EncodingService")
local SerializationService = game:GetService("SerializationService")
local TweenService = game:GetService("TweenService")

local App = require(script.Parent.App)
local Apply = require(script.Parent.Apply)
local Core = require(script.Parent.Core)
local Look = require(script.Parent.Look)
local Place = require(script.Parent.Place)

local TAG, OP_TAG, REF_TAG = Core.TAG, Core.OP_TAG, Core.REF_TAG
local GREEN, AMBER, RED, new = Look.GREEN, Look.AMBER, Look.RED, Look.new
local findObject, idMap = Place.findObject, Apply.idMap
local MESH_DATA, UNION_DATA, SCRIPT_NAMES = Apply.MESH_DATA, Apply.UNION_DATA, Apply.SCRIPT_NAMES

local Preview = {}

local MAX_PREVIEW_PARTS = 20000
local PREVIEWED = { merge = true, update = true, revert = true, restore = true }
local COLORS = { added = GREEN, changed = AMBER, removed = RED }
-- Removed objects get a stronger fill: their copy sits exactly over the real thing.
local FILL = { added = 0.75, changed = 0.7, removed = 0.55 }
-- Copies mustn't hold on to the real place: joints and constraints pointing out of a copy could pull real parts.
local JOINTS = { "JointInstance", "WeldConstraint", "NoCollisionConstraint", "Constraint" }

type Shown = { ghost: Instance, group: string }
type Copies = {
	view: any,
	root: Model,
	groups: { [string]: Model },
	-- Each operation's copies, so a conflict choice shows or hides them without building them again.
	byOp: { [number]: { Shown } },
	-- Copies by review key (added rows) and by the live object they show (changed and removed ones).
	byKey: { [string]: Instance },
	byObject: { [Instance]: Instance },
	templates: { [number]: Instance },
}
local current: Copies? = nil

local function inWorld(object: Instance?, camera: Camera): boolean
	return object ~= nil
		and (object == workspace or object:IsDescendantOf(workspace))
		and not object:IsDescendantOf(camera)
		and not object:IsA("Terrain")
end

local function hasParts(object: Instance): boolean
	return object:IsA("BasePart") or object:FindFirstChildWhichIsA("BasePart", true) ~= nil
end

-- Makes a copy inert: no IDs (RoGit finds objects by them), no scripts or joints, and parts that can't be clicked,
-- touched or hit. Returns how many parts it has.
local function prepare(ghost: Instance): number
	local parts = 0
	local objects = ghost:GetDescendants()
	table.insert(objects, ghost)
	for _, object in objects do
		if object.Parent == nil and object ~= ghost then
			continue -- Inside something already destroyed.
		end
		local inert = object:IsA("LuaSourceContainer")
		for _, class in JOINTS do
			inert = inert or object:IsA(class)
		end
		if inert and object ~= ghost then
			object:Destroy()
			continue
		end
		for _, name in { TAG, OP_TAG, REF_TAG } do
			if object:GetAttribute(name) ~= nil then
				object:SetAttribute(name, nil)
			end
		end
		if object:IsA("BasePart") then
			parts += 1
			object.Locked = true
			object.Anchored = true
			object.CanCollide = false
			object.CanTouch = false
			object.CanQuery = false
			object.CastShadow = false
		end
	end
	ghost.Archivable = false
	return parts
end

-- A changed part as it will be: a copy of the live part with the incoming values. New mesh or union geometry
-- only comes with the incoming copy itself, which has nothing inside it.
local function changedPart(p: Copies, op: any, target: BasePart): Instance?
	local template = if op.template then p.templates[op.template] else nil
	if template then
		for _, property in op.properties do
			if MESH_DATA[property] or UNION_DATA[property] then
				p.templates[op.template] = nil
				return template
			end
		end
	end
	local ghost = target:Clone()
	if not ghost then
		return nil
	end
	-- Parts inside a part have previews of their own if they changed.
	for _, child in ghost:GetDescendants() do
		if child.Parent and (child:IsA("BasePart") or child:IsA("Model")) then
			child:Destroy()
		end
	end
	if op.kind == "set" and template then
		for _, property in op.properties do
			if property ~= "Attributes" and property ~= "Tags" then
				local name = SCRIPT_NAMES[property] or property
				pcall(function()
					(ghost :: any)[name] = (template :: any)[name]
				end)
			end
		end
	end
	-- A hair bigger, so a part that only changed color doesn't flicker against the original.
	ghost.Size += Vector3.new(0.02, 0.02, 0.02)
	return ghost
end

-- Shows the copies of operations that would apply with the choices so far. An open conflict shows the incoming
-- side, since that's what's being decided.
local function showChoices(p: Copies)
	local wanted: { [Instance]: Instance } = {}
	for index, shown in p.byOp do
		local op = p.view.data.operations[index]
		if not (op.conflict and p.view.choices[op.conflict] == "keep") then
			for _, entry in shown do
				wanted[entry.ghost] = p.groups[entry.group]
			end
		end
	end
	for _, shown in p.byOp do
		for _, entry in shown do
			local parent = wanted[entry.ghost]
			if entry.ghost.Parent ~= parent then
				entry.ghost.Parent = parent
			end
		end
	end
end

local function build(p: Copies, camera: Camera)
	local plan = p.view.data
	if plan.bundle ~= "" then
		local data = EncodingService:Base64Decode(buffer.fromstring(plan.bundle))
		local decoded = SerializationService:DeserializeInstancesAsync(data)
		for _, object in decoded do
			local index = tonumber(object:GetAttribute(OP_TAG))
			if index and current == p then
				p.templates[index] = object
			else
				object:Destroy()
			end
		end
		if current ~= p then
			return
		end
	end
	local ids = idMap()
	local parts = 0
	-- Live objects with a copy, and everything around them, so a changed Model or light only gets a copy of its
	-- own when nothing in it has one already.
	local covered: { [Instance]: boolean } = {}
	local function cover(object: Instance)
		local at: Instance? = object
		while at and at ~= workspace and not covered[at] do
			covered[at] = true
			at = at.Parent
		end
	end
	local function show(index: number, ghost: Instance?, group: string, source: Instance?, key: string?)
		if not ghost then
			return
		end
		parts += prepare(ghost)
		p.byOp[index] = p.byOp[index] or {}
		table.insert(p.byOp[index], { ghost = ghost, group = group })
		if source then
			p.byObject[source] = ghost
			cover(source)
		end
		if key then
			p.byKey[key] = ghost
		end
	end
	local later: { { index: number, target: Instance } } = {}
	for index, op in plan.operations do
		if parts >= MAX_PREVIEW_PARTS then
			break
		end
		if index % 200 == 0 then
			task.wait()
			if current ~= p then
				return
			end
		end
		if op.kind == "add" then
			local template = p.templates[op.template]
			if template and hasParts(template) and inWorld(findObject(op.parent, ids), camera) then
				p.templates[op.template] = nil
				show(index, template, "added", nil, op.key)
			end
		elseif op.kind == "remove" then
			local target = findObject(op.target, ids)
			if target and inWorld(target, camera) and hasParts(target) then
				show(index, target:Clone(), "removed", target)
			end
		elseif op.kind == "set" or op.kind == "rename" or op.kind == "move" then
			local target = findObject(op.target, ids)
			if target and inWorld(target, camera) then
				if target:IsA("BasePart") then
					show(index, changedPart(p, op, target), "changed", target)
				else
					table.insert(later, { index = index, target = target })
				end
			end
		end
	end
	-- A changed Model shows as a whole, and a change inside a part (a light, a decal) shows on the part.
	for _, entry in later do
		if parts >= MAX_PREVIEW_PARTS then
			break
		end
		local index, target = entry.index, entry.target
		if not inWorld(target, camera) then
			continue
		end
		local anchor = if target:IsA("Model")
			then target
			else target:FindFirstAncestorWhichIsA("BasePart") or target:FindFirstAncestorWhichIsA("Model")
		if anchor and anchor ~= workspace and not covered[anchor] and hasParts(anchor) then
			local ghost = anchor:Clone()
			if ghost and anchor:IsA("BasePart") then
				for _, child in ghost:GetDescendants() do
					if child.Parent and (child:IsA("BasePart") or child:IsA("Model")) then
						child:Destroy()
					end
				end
			end
			show(index, ghost, "changed", anchor)
		end
	end
	for _, template in p.templates do
		template:Destroy()
	end
	table.clear(p.templates)
	if current == p then
		showChoices(p)
	end
end

Preview.show = function(view: any)
	Preview.clear()
	local camera = workspace.CurrentCamera
	if not camera or not PREVIEWED[view.kind] or not view.data.operations or #view.data.operations == 0 then
		return
	end
	local root = new("Model", { Name = "RoGit preview", Archivable = false, Parent = camera })
	local p: Copies = { view = view, root = root, groups = {}, byOp = {}, byKey = {}, byObject = {}, templates = {} }
	for name, color in COLORS do
		local group = new("Model", { Name = name, Parent = root })
		new("Highlight", {
			FillColor = color, OutlineColor = color, FillTransparency = FILL[name], OutlineTransparency = 0,
			DepthMode = Enum.HighlightDepthMode.AlwaysOnTop, Parent = group,
		})
		p.groups[name] = group
	end
	current = p
	task.spawn(function()
		local ok, err = pcall(build, p, camera)
		if not ok and current == p then
			warn("RoGit couldn't show this in 3D: " .. tostring(err))
			Preview.clear()
		end
	end)
end

Preview.update = function()
	if current then
		showChoices(current)
	end
end

Preview.clear = function()
	local p = current
	if not p then
		return
	end
	current = nil
	for _, shown in p.byOp do
		for _, entry in shown do
			entry.ghost:Destroy()
		end
	end
	for _, template in p.templates do
		template:Destroy()
	end
	p.root:Destroy()
end

-- Points the camera at a row's object: where it is now and, if it's changing, where it will be.
Preview.focus = function(row: any, object: Instance?)
	local p = current
	local camera = workspace.CurrentCamera
	if not p or not camera then
		return
	end
	local low, high = Vector3.one * math.huge, -Vector3.one * math.huge
	local function extend(frame: CFrame, size: Vector3)
		local half = size / 2
		local x, y, z = frame.XVector, frame.YVector, frame.ZVector
		local reach = Vector3.new(
			math.abs(x.X) * half.X + math.abs(y.X) * half.Y + math.abs(z.X) * half.Z,
			math.abs(x.Y) * half.X + math.abs(y.Y) * half.Y + math.abs(z.Y) * half.Z,
			math.abs(x.Z) * half.X + math.abs(y.Z) * half.Y + math.abs(z.Z) * half.Z
		)
		low, high = low:Min(frame.Position - reach), high:Max(frame.Position + reach)
	end
	local function include(target: Instance)
		if target:IsA("BasePart") then
			extend(target.CFrame, target.Size)
		elseif target:IsA("Model") then
			local ok, frame, size = pcall(target.GetBoundingBox, target)
			if ok and size.Magnitude > 0 then
				extend(frame, size)
			end
		else
			local counted = 0
			for _, part in target:GetDescendants() do
				if part:IsA("BasePart") then
					extend(part.CFrame, part.Size)
					counted += 1
					if counted >= 2000 then
						break
					end
				end
			end
		end
	end
	local ghost = p.byKey[row.key]
	if ghost and ghost.Parent then
		include(ghost)
	end
	if object and inWorld(object, camera) and object ~= workspace then
		include(object)
		for source, copy in p.byObject do
			if copy.Parent and (source == object or source:IsDescendantOf(object)) then
				include(copy)
			end
		end
	end
	if low.X > high.X then
		return -- Nothing to see in 3D.
	end
	local center = (low + high) / 2
	local radius = math.max((high - low).Magnitude / 2, 2)
	-- Far enough back to see what's around it too.
	local distance = 1.75 * radius / math.sin(math.rad(camera.FieldOfView) / 2)
	local goal = CFrame.lookAt(center - camera.CFrame.LookVector * distance, center)
	local tween = TweenService:Create(camera, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = goal, Focus = CFrame.new(center),
	})
	tween:Play()
end

App.plugin.Unloading:Connect(function()
	Preview.clear()
end)

return Preview
