--[[
	mm2 hub | luau | delta (mobile/pc) | place 142823291
	- role esp (GetPlayerData remote, tool-check fallback) + dropped gun esp
	- coin farm (CoinContainer/Coin_Server, tween + noclip, pauses on full bag)
	- r15 emotes via Animator on your own character -> replicates to everyone
	reexec safe. mm2 updates a lot: if a path breaks, the pcalls fail quiet.
]]

if game.PlaceId ~= 142823291 then
	warn("[mm2hub] not mm2")
	return
end

local genv = (getgenv and getgenv()) or _G
if genv.__MM2HUB then pcall(genv.__MM2HUB) end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UIS = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local CoreGui = game:GetService("CoreGui")

local lp = Players.LocalPlayer

-- state
local alive = true
local espOn = false
local farmOn = false
local currentTrack = nil
local conns = {}
local espObjs = {}
local FARM_SPEED = 22 -- studs/sec

local function bind(c)
	conns[#conns + 1] = c
	return c
end

local function new(class, props, parent)
	local i = Instance.new(class)
	for k, v in pairs(props) do
		i[k] = v
	end
	if parent then i.Parent = parent end
	return i
end

local function safeParent(inst)
	local ok = pcall(function()
		if gethui then
			inst.Parent = gethui()
		else
			inst.Parent = CoreGui
		end
	end)
	if not ok or not inst.Parent then
		inst.Parent = lp:WaitForChild("PlayerGui")
	end
end

local function getChar()
	local c = lp.Character
	if not c then return end
	return c, c:FindFirstChildOfClass("Humanoid"), c:FindFirstChild("HumanoidRootPart")
end

-- anti afk
bind(lp.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

------------------------------------------------------------------ ESP
local COLORS = {
	Murderer = Color3.fromRGB(255, 60, 60),
	Sheriff = Color3.fromRGB(70, 140, 255),
	Hero = Color3.fromRGB(70, 140, 255),
	Innocent = Color3.fromRGB(80, 255, 120),
	Gun = Color3.fromRGB(255, 220, 0),
}

local function fetchRoles()
	local ok, data = pcall(function()
		local r = RS:FindFirstChild("GetPlayerData", true)
		return r and r:InvokeServer()
	end)
	if ok and typeof(data) == "table" then
		local out = {}
		for name, d in pairs(data) do
			if typeof(d) == "table" and not d.Dead then
				out[name] = d.Role
			end
		end
		return out
	end
	return nil
end

local function toolRole(plr)
	local c = plr.Character
	local bp = plr:FindFirstChildOfClass("Backpack")
	local function has(n)
		return (c and c:FindFirstChild(n)) or (bp and bp:FindFirstChild(n))
	end
	if has("Knife") then return "Murderer" end
	if has("Gun") then return "Sheriff" end
	return nil
end

local function setHL(key, adornee, color)
	local h = espObjs[key]
	if not adornee or not adornee.Parent then
		if h then h:Destroy() espObjs[key] = nil end
		return false
	end
	if not h or not h.Parent then
		h = new("Highlight", {
			DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
			FillTransparency = 0.5,
			OutlineTransparency = 0,
		})
		safeParent(h)
		espObjs[key] = h
	end
	h.Adornee = adornee
	h.FillColor = color
	h.OutlineColor = color
	return true
end

local function clearESP()
	for k, h in pairs(espObjs) do
		h:Destroy()
		espObjs[k] = nil
	end
end

task.spawn(function()
	while alive do
		if espOn then
			local data = fetchRoles()
			local seen = {}
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr ~= lp then
					local role
					if data then role = data[plr.Name] else role = toolRole(plr) end
					local char = plr.Character
					if role and COLORS[role] and char and char:FindFirstChild("HumanoidRootPart") then
						if setHL(plr.Name, char, COLORS[role]) then
							seen[plr.Name] = true
						end
					end
				end
			end
			local gd = workspace:FindFirstChild("GunDrop", true)
			if setHL("__gun", gd, COLORS.Gun) then seen.__gun = true end
			for key, h in pairs(espObjs) do
				if not seen[key] then
					h:Destroy()
					espObjs[key] = nil
				end
			end
		end
		task.wait(1)
	end
end)

------------------------------------------------------------------ COIN FARM
local function bagFull()
	local ok, full = pcall(function()
		return lp.PlayerGui.MainGUI.Game.CashBag.Full.Visible
	end)
	return ok and full == true
end

local function findContainer()
	for _, d in ipairs(workspace:GetDescendants()) do
		if d.Name == "CoinContainer" then return d end
	end
end

local function nearestCoin(container, hrp, visited)
	local best, bd
	for _, c in ipairs(container:GetChildren()) do
		if c.Name == "Coin_Server" and c:IsA("BasePart") then
			local last = visited[c]
			if not last or os.clock() - last > 5 then
				local d = (c.Position - hrp.Position).Magnitude
				if not bd or d < bd then
					best, bd = c, d
				end
			end
		end
	end
	return best
end

local function goTo(hrp, pos)
	local dist = (hrp.Position - pos).Magnitude
	local t = math.max(dist / FARM_SPEED, 0.05)
	local tw = TweenService:Create(hrp, TweenInfo.new(t, Enum.EasingStyle.Linear), { CFrame = CFrame.new(pos) })
	local done = false
	local c = tw.Completed:Connect(function() done = true end)
	tw:Play()
	local t0 = os.clock()
	while not done and farmOn and alive and hrp.Parent and os.clock() - t0 < t + 1 do
		hrp.AssemblyLinearVelocity = Vector3.zero
		task.wait()
	end
	c:Disconnect()
	tw:Cancel()
end

bind(RunService.Stepped:Connect(function()
	if farmOn then
		local c = lp.Character
		if c then
			for _, p in ipairs(c:GetDescendants()) do
				if p:IsA("BasePart") then p.CanCollide = false end
			end
		end
	end
end))

task.spawn(function()
	local container, lastSearch = nil, 0
	local visited = {}
	while alive do
		if farmOn then
			local char, hum, hrp = getChar()
			if char and hum and hrp and hum.Health > 0 then
				if not (container and container.Parent) then
					container = nil
					if os.clock() - lastSearch > 2 then
						lastSearch = os.clock()
						container = findContainer()
						visited = {}
					end
				end
				if container and not bagFull() then
					local coin = nearestCoin(container, hrp, visited)
					if coin then
						visited[coin] = os.clock()
						goTo(hrp, coin.Position)
						if firetouchinterest and coin.Parent then
							pcall(function()
								firetouchinterest(hrp, coin, 0)
								firetouchinterest(hrp, coin, 1)
							end)
						end
						task.wait(0.15)
					else
						task.wait(0.3)
					end
				else
					task.wait(0.3)
				end
			else
				task.wait(0.5)
			end
		else
			task.wait(0.25)
		end
	end
end)

------------------------------------------------------------------ EMOTES
-- roblox-owned r15 animations. played on your own animator = replicates to all.
local EMOTES = {
	{ "wave", 507770239 },
	{ "point", 507770453 },
	{ "cheer", 507770677 },
	{ "laugh", 507770818 },
	{ "dance 1", 507771019 },
	{ "dance 2", 507776043 },
	{ "dance 3", 507777268 },
	{ "salute", 3360689775 },
	{ "stadium", 3360686498 },
	{ "tilt", 3360692915 },
	{ "shrug", 3576968026 },
	{ "floss", 10147821284 },
	{ "hips dont lie", 10214311282 },
	{ "dolphin", 5918726674 },
}

local function stopEmote()
	if currentTrack then
		pcall(function()
			currentTrack:Stop(0.2)
			currentTrack:Destroy()
		end)
		currentTrack = nil
	end
end

local function playEmote(id)
	local _, hum = getChar()
	if not hum or not id then return end
	if hum.RigType ~= Enum.HumanoidRigType.R15 then
		warn("[mm2hub] not r15")
		return
	end
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = new("Animator", {}, hum)
	end
	stopEmote()
	local anim = new("Animation", { AnimationId = "rbxassetid://" .. tostring(id) })
	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not ok or not track then return end
	track.Priority = Enum.AnimationPriority.Action4
	track.Looped = true
	track:Play(0.2)
	currentTrack = track
end

bind(RunService.Heartbeat:Connect(function()
	if currentTrack then
		local _, hum = getChar()
		if hum and hum.MoveDirection.Magnitude > 0.1 then
			stopEmote()
		end
	end
end))

------------------------------------------------------------------ GUI
local gui = new("ScreenGui", {
	Name = "MM2Hub",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 999,
})
safeParent(gui)

local main = new("Frame", {
	Size = UDim2.fromOffset(250, 330),
	Position = UDim2.new(0.5, -125, 0.15, 0),
	BackgroundColor3 = Color3.fromRGB(24, 24, 30),
	BorderSizePixel = 0,
	Active = true,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, main)

local bar = new("Frame", {
	Size = UDim2.new(1, 0, 0, 32),
	BackgroundColor3 = Color3.fromRGB(34, 34, 44),
	BorderSizePixel = 0,
}, main)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, bar)
new("TextLabel", {
	Size = UDim2.new(1, -70, 1, 0),
	Position = UDim2.fromOffset(10, 0),
	BackgroundTransparency = 1,
	Text = "mm2 hub",
	TextColor3 = Color3.new(1, 1, 1),
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
}, bar)

local function barBtn(txt, xoff)
	local b = new("TextButton", {
		Size = UDim2.fromOffset(26, 22),
		Position = UDim2.new(1, xoff, 0, 5),
		BackgroundColor3 = Color3.fromRGB(55, 55, 70),
		Text = txt,
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		BorderSizePixel = 0,
	}, bar)
	new("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
	return b
end
local minBtn = barBtn("-", -62)
local closeBtn = barBtn("x", -32)

local list = new("ScrollingFrame", {
	Size = UDim2.new(1, -12, 1, -40),
	Position = UDim2.fromOffset(6, 36),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, main)
new("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, list)

local order = 0
local function item(class, props)
	order += 1
	props.LayoutOrder = order
	local i = new(class, props, list)
	if class == "TextButton" or class == "TextBox" then
		new("UICorner", { CornerRadius = UDim.new(0, 6) }, i)
	end
	return i
end

local function label(text)
	return item("TextLabel", {
		Size = UDim2.new(1, -6, 0, 18),
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = Color3.fromRGB(150, 150, 170),
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
end

local function button(text, cb)
	local b = item("TextButton", {
		Size = UDim2.new(1, -6, 0, 30),
		BackgroundColor3 = Color3.fromRGB(45, 45, 58),
		Text = text,
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.Gotham,
		TextSize = 13,
		BorderSizePixel = 0,
	})
	bind(b.Activated:Connect(cb))
	return b
end

local function toggle(name, cb)
	local on = false
	local b
	b = button(name .. ": off", function()
		on = not on
		b.Text = name .. ": " .. (on and "on" or "off")
		b.BackgroundColor3 = on and Color3.fromRGB(40, 140, 80) or Color3.fromRGB(45, 45, 58)
		cb(on)
	end)
end

label("main")
toggle("role esp", function(v)
	espOn = v
	if not v then clearESP() end
end)
toggle("coin farm", function(v)
	farmOn = v
end)

label("emotes (r15, everyone sees)")
for _, e in ipairs(EMOTES) do
	button(e[1], function()
		playEmote(e[2])
	end)
end

local box = item("TextBox", {
	Size = UDim2.new(1, -6, 0, 30),
	BackgroundColor3 = Color3.fromRGB(34, 34, 44),
	PlaceholderText = "custom anim id",
	PlaceholderColor3 = Color3.fromRGB(120, 120, 140),
	Text = "",
	TextColor3 = Color3.new(1, 1, 1),
	Font = Enum.Font.Gotham,
	TextSize = 13,
	ClearTextOnFocus = false,
	BorderSizePixel = 0,
})
button("play custom id", function()
	playEmote(tonumber(box.Text:match("%d+")))
end)
button("stop emote", stopEmote)

-- drag
local dragging, dragStart, startPos = false, nil, nil
bind(bar.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = i.Position
		startPos = main.Position
	end
end))
bind(UIS.InputChanged:Connect(function(i)
	if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
		local d = i.Position - dragStart
		main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end))
bind(UIS.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end))

-- collapse / close
local collapsed = false
bind(minBtn.Activated:Connect(function()
	collapsed = not collapsed
	list.Visible = not collapsed
	main.Size = collapsed and UDim2.fromOffset(250, 32) or UDim2.fromOffset(250, 330)
end))

local function destroy()
	alive = false
	farmOn = false
	espOn = false
	for _, c in ipairs(conns) do
		pcall(function() c:Disconnect() end)
	end
	stopEmote()
	clearESP()
	pcall(function() gui:Destroy() end)
	genv.__MM2HUB = nil
end
genv.__MM2HUB = destroy
bind(closeBtn.Activated:Connect(destroy))
