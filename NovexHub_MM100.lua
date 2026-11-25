--[[
    NOVEX HUB  |  Murder Mystery 2  |  PlaceId 142823291
    UI: WindUI (latest dist)   Executor: Delta (mobile + pc)

    gun aimbot   -> hooks the gun's "Shoot" remote   (arg2 = CFrame target)
    knife aimbot -> hooks the knife's "KnifeThrown"  (arg2 = CFrame target)
    stab         -> Knife.Events.HandleTouched:FireServer(targetRoot)
    roles        -> ReplicatedStorage.Remotes.Extras.GetPlayerData (+ Weapon_Knife / Weapon_Gun tags as fallback)
    coins        -> CollectionService tag "ServerCoinPart", CoinCollected for bag-full
    gun drop     -> CollectionService tag "GunDrop"

    emotes: the emote/animation module is NOT bundled. it's fetched when you tap the button
    (original by 7yd7) and rebranded to Novex Hub at load time.

    remotes get renamed in MM2 patches now and then. everything here resolves by name at runtime,
    so if something dies after an update it's one of the names above.
]]

if getgenv and getgenv().NovexHubUnload then
    pcall(getgenv().NovexHubUnload)
end

if not game:IsLoaded() then game.Loaded:Wait() end

----------------------------------------------------------------------
-- config you can edit
----------------------------------------------------------------------
local HUB_NAME       = "Novex Hub"
local DISCORD_INVITE = ""   -- put your own invite here; if empty the emote module keeps its original one
local EMOTE_SRC      = "https://raw.githubusercontent.com/7yd7/Hub/refs/heads/Branch/GUIS/Emotes.lua"
local WINDUI_URLS = {
    "https://raw.githubusercontent.com/Footagesus/WindUI/refs/heads/main/dist/main.lua",
    "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua",
}

----------------------------------------------------------------------
-- services / helpers
----------------------------------------------------------------------
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local TweenService       = game:GetService("TweenService")
local CollectionService  = game:GetService("CollectionService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local Workspace          = game:GetService("Workspace")
local Lighting           = game:GetService("Lighting")
local TeleportService    = game:GetService("TeleportService")
local HttpService        = game:GetService("HttpService")
local CoreGui            = game:GetService("CoreGui")
local VirtualUser        = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer
local request     = (syn and syn.request) or (http and http.request) or http_request or request
local firetouch   = firetouchinterest
local wrapC       = newcclosure or function(f) return f end

local Alive = true
local Conns = {}

local function bind(signal, fn)
    local c = signal:Connect(fn)
    Conns[#Conns + 1] = c
    return c
end

local function safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then warn("[Novex] " .. tostring(err)) end
    return ok, err
end

local function guiParent()
    local ok, h = pcall(function() return gethui and gethui() end)
    if ok and h then return h end
    return CoreGui
end

local function httpGet(url)
    local ok, res = pcall(function() return game:HttpGet(url) end)
    if ok and type(res) == "string" and #res > 0 then return res end
    if request then
        local ok2, r2 = pcall(function() return request({Url = url, Method = "GET"}) end)
        if ok2 and r2 and r2.Body and #r2.Body > 0 then return r2.Body end
    end
    return nil
end

local function plainReplace(s, a, b)
    local out, i = {}, 1
    while true do
        local s1, e1 = string.find(s, a, i, true)
        if not s1 then
            out[#out + 1] = string.sub(s, i)
            break
        end
        out[#out + 1] = string.sub(s, i, s1 - 1)
        out[#out + 1] = b
        i = e1 + 1
    end
    return table.concat(out)
end

local function getChar() return LocalPlayer.Character end
local function getHum()
    local c = LocalPlayer.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function getRoot()
    local c = LocalPlayer.Character
    return c and (c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart)
end
local function rootOf(p)
    local c = p and p.Character
    return c and (c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart)
end

----------------------------------------------------------------------
-- load windui
----------------------------------------------------------------------
local WindUI
for _, url in ipairs(WINDUI_URLS) do
    local ok, lib = pcall(function() return loadstring(game:HttpGet(url))() end)
    if ok and type(lib) == "table" then
        WindUI = lib
        break
    end
end
if not WindUI then
    warn("[Novex Hub] WindUI failed to load (network / url). nothing started.")
    return
end

local function notify(title, content, dur)
    pcall(function()
        WindUI:Notify({Title = title, Content = content or "", Duration = dur or 4})
    end)
end

if game.PlaceId ~= 142823291 then
    notify(HUB_NAME, "this isn't MM2 (142823291), game features won't work", 6)
end

----------------------------------------------------------------------
-- state
----------------------------------------------------------------------
local S = {
    walkOn = false, walk = 32, jumpOn = false, jump = 60,
    infJump = false, noclip = false, antiFling = true,
    roleNotify = true,
    autoShoot = false, autoShootRange = 300,
    killAura = false, auraRange = 14,
    flingTime = 3,
    autoGrab = false,
}

local Aim = {
    gun   = {enabled = false, armed = true, button = true, mode = "Murderer", range = 300},
    knife = {enabled = false, armed = true, button = true, mode = "Nearest",  range = 300},
}

local Farm = {enabled = false, speed = 25, teleport = false, resetFull = true, bagFull = false, full = {}}
local Fling = {active = false}
local Fly = {on = false, speed = 60}

----------------------------------------------------------------------
-- roles
----------------------------------------------------------------------
local Roles = {map = {}, data = nil, busy = false}

local function weaponOwner(tool)
    local p = tool.Parent
    if not p then return nil end
    if p:IsA("Backpack") then return p.Parent end
    return Players:GetPlayerFromCharacter(p)
end

local function weaponHolders(tag)
    local out = {}
    for _, t in ipairs(CollectionService:GetTagged(tag)) do
        local o = weaponOwner(t)
        if o then out[o] = t end
    end
    return out
end

function Roles.refresh()
    if not Roles.busy then
        Roles.busy = true
        task.spawn(function()
            local ok, res = pcall(function()
                return ReplicatedStorage.Remotes.Extras.GetPlayerData:InvokeServer()
            end)
            if ok and type(res) == "table" then Roles.data = res end
            Roles.busy = false
        end)
    end
    local knives = weaponHolders("Weapon_Knife")
    local guns   = weaponHolders("Weapon_Gun")
    local map = {}
    for _, p in ipairs(Players:GetPlayers()) do
        local role, dead = "Innocent", false
        local d = Roles.data and Roles.data[p.Name]
        if type(d) == "table" then
            if d.Dead then dead = true end
            if type(d.Role) == "string" then role = d.Role end
        end
        if role == "Innocent" then
            if knives[p] then role = "Murderer"
            elseif guns[p] then role = "Sheriff" end
        end
        map[p] = {role = role, dead = dead}
    end
    Roles.map = map
end

function Roles.isAlive(p)
    local e = Roles.map[p]
    if e and e.dead then return false end
    local c = p.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    return h ~= nil and h.Health > 0
end

function Roles.roleOf(p)
    local e = Roles.map[p]
    return e and e.role or "Innocent"
end

function Roles.localRole()
    return Roles.roleOf(LocalPlayer)
end

-- nearest alive player holding a role (Sheriff also matches Hero)
function Roles.find(role, includeSelf)
    local best, bd
    local mr = getRoot()
    for _, p in ipairs(Players:GetPlayers()) do
        if (includeSelf or p ~= LocalPlayer) and Roles.isAlive(p) then
            local r = Roles.roleOf(p)
            if r == role or (role == "Sheriff" and r == "Hero") then
                local tr = rootOf(p)
                local d = (mr and tr) and (mr.Position - tr.Position).Magnitude or 0
                if not bd or d < bd then best, bd = p, d end
            end
        end
    end
    return best
end

----------------------------------------------------------------------
-- tools / targeting / prediction
----------------------------------------------------------------------
local function findTool(name)
    local c = LocalPlayer.Character
    local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
    local t = c and c:FindFirstChild(name)
    if t and t:IsA("Tool") then return t, true end
    t = bp and bp:FindFirstChild(name)
    if t and t:IsA("Tool") then return t, false end
    return nil
end

local function equip(name)
    local t, equipped = findTool(name)
    if not t then return nil end
    if not equipped then
        local h = getHum()
        if h then h:EquipTool(t) end
        task.wait(0.06)
    end
    return t
end

local function predict(root, kind)
    local v = root.AssemblyLinearVelocity
    local flat = Vector3.new(v.X, 0, v.Z)
    local p = root.Position + Vector3.new(0, 0.7, 0)
    if flat.Magnitude > 1.5 and flat.Magnitude < 120 then
        local k  = (kind == "knife") and 0.45 or 0.17
        local ky = (kind == "knife") and 0.028 or 0.03
        p = p + flat * k + Vector3.new(0, v.Y * ky, 0)
    end
    return p
end

local function pickTarget(mode, range)
    local mr = getRoot()
    if not mr then return nil end
    local best, bd
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and Roles.isAlive(p) then
            local r = Roles.roleOf(p)
            local ok = (mode == "Nearest")
                or (mode == "Murderer" and r == "Murderer")
                or (mode == "Sheriff" and (r == "Sheriff" or r == "Hero"))
            if ok then
                local tr = rootOf(p)
                if tr then
                    local d = (tr.Position - mr.Position).Magnitude
                    if d <= range and (not bd or d < bd) then best, bd = p, d end
                end
            end
        end
    end
    return best, bd
end

----------------------------------------------------------------------
-- namecall hook (silent aim for gun + knife)
-- the hook only reads A.pos, which a Heartbeat loop precomputes. no other
-- namecalls happen inside the hook so the stored namecall method stays valid.
----------------------------------------------------------------------
local oldNamecall
local hookOK = false
local checkC = checkcaller or function() return false end

local function hookFn(self, ...)
    local method = getnamecallmethod()
    if Alive and method == "FireServer" and typeof(self) == "Instance" and not checkC() then
        local nm = self.Name
        local A = (nm == "Shoot" and Aim.gun) or (nm == "KnifeThrown" and Aim.knife) or nil
        local pos = A and A.enabled and A.armed and A.pos
        if pos then
            local n = select("#", ...)
            local args = {...}
            args[2] = CFrame.new(pos)
            return oldNamecall(self, unpack(args, 1, math.max(n, 2)))
        end
    end
    return oldNamecall(self, ...)
end

do
    local ok = pcall(function()
        if not getnamecallmethod then error("no getnamecallmethod") end
        if hookmetamethod then
            oldNamecall = hookmetamethod(game, "__namecall", wrapC(hookFn))
        else
            local mt = getrawmetatable(game)
            oldNamecall = mt.__namecall
            if setreadonly then setreadonly(mt, false) elseif make_writeable then make_writeable(mt) end
            mt.__namecall = wrapC(hookFn)
            if setreadonly then setreadonly(mt, true) end
        end
    end)
    hookOK = ok and oldNamecall ~= nil
    if not hookOK then
        warn("[Novex Hub] namecall hook unsupported on this executor. aimbots off, direct-fire tools still work.")
    end
end

----------------------------------------------------------------------
-- aim ui: floating circle buttons + target marker
----------------------------------------------------------------------
local circleGui = Instance.new("ScreenGui")
circleGui.Name = "NovexCircles"
circleGui.ResetOnSpawn = false
circleGui.IgnoreGuiInset = true
circleGui.DisplayOrder = 1000
circleGui.Parent = guiParent()

local espFolder = Instance.new("Folder")
espFolder.Name = "NovexESP"
espFolder.Parent = guiParent()

local GRAY  = Color3.fromRGB(120, 120, 130)
local GREEN = Color3.fromRGB(60, 255, 130)
local RED   = Color3.fromRGB(255, 60, 60)

local function makeCircle(label, pos, onTap)
    local btn = Instance.new("TextButton")
    btn.Name = "Circle_" .. label
    btn.Size = UDim2.fromOffset(64, 64)
    btn.Position = pos
    btn.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
    btn.BackgroundTransparency = 0.2
    btn.AutoButtonColor = false
    btn.Text = label
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 13
    btn.Visible = false
    btn.Parent = circleGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = btn

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 3
    stroke.Color = GRAY
    stroke.Parent = btn

    local dragging, moved, startPt, startPos = false, false, Vector2.zero, btn.Position
    bind(btn.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, moved = true, false
            startPt = Vector2.new(input.Position.X, input.Position.Y)
            startPos = btn.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if not moved then safe(onTap) end
                end
            end)
        end
    end)
    bind(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = Vector2.new(input.Position.X, input.Position.Y) - startPt
            if d.Magnitude > 8 then moved = true end
            if moved then
                btn.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end
    end)
    return btn, stroke
end

local function makeMarker()
    local bb = Instance.new("BillboardGui")
    bb.Size = UDim2.fromOffset(70, 70)
    bb.AlwaysOnTop = true
    bb.Enabled = false
    bb.Parent = espFolder
    local f = Instance.new("Frame")
    f.Size = UDim2.fromScale(1, 1)
    f.BackgroundTransparency = 1
    f.Parent = bb
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(1, 0)
    c.Parent = f
    local s = Instance.new("UIStroke")
    s.Thickness = 3
    s.Color = RED
    s.Parent = f
    return bb
end

local AimUI = {}
do
    local gb, gs = makeCircle("GUN", UDim2.new(0.82, 0, 0.42, 0), function()
        Aim.gun.armed = not Aim.gun.armed
        notify("Gun Aimbot", Aim.gun.armed and "ARMED" or "paused", 2)
    end)
    local kb, ks = makeCircle("KNIFE", UDim2.new(0.82, 0, 0.58, 0), function()
        Aim.knife.armed = not Aim.knife.armed
        notify("Knife Aimbot", Aim.knife.armed and "ARMED" or "paused", 2)
    end)
    AimUI.gun   = {btn = gb, stroke = gs, marker = makeMarker()}
    AimUI.knife = {btn = kb, stroke = ks, marker = makeMarker()}
end

bind(RunService.Heartbeat, function()
    if not Alive then return end
    for _, kind in ipairs({"gun", "knife"}) do
        local A, ui = Aim[kind], AimUI[kind]
        local target
        if A.enabled then target = pickTarget(A.mode, A.range) end
        local tr = target and rootOf(target) or nil
        A.pos = (A.enabled and A.armed and tr) and predict(tr, kind) or nil
        ui.btn.Visible = A.enabled and A.button
        if not A.armed then
            ui.stroke.Color = GRAY
        else
            ui.stroke.Color = target and RED or GREEN
        end
        local mark = (A.enabled and A.armed) and tr or nil
        ui.marker.Adornee = mark
        ui.marker.Enabled = mark ~= nil
    end
end)

----------------------------------------------------------------------
-- combat actions
----------------------------------------------------------------------
local function shootAt(targetRoot)
    local gun = equip("Gun")
    if not gun then return false end
    local shoot = gun:FindFirstChild("Shoot")
    local handle = gun:FindFirstChild("Handle")
    if not (shoot and handle) then return false end
    local pos = predict(targetRoot, "gun")
    return (pcall(function() shoot:FireServer(handle.CFrame, CFrame.new(pos)) end))
end

local function stab(p)
    local knife = equip("Knife")
    if not knife then return false end
    local tr = rootOf(p)
    if not tr then return false end
    local ev = knife:FindFirstChild("Events")
    local ht = ev and ev:FindFirstChild("HandleTouched")
    if ht then pcall(function() ht:FireServer(tr) end) end
    local handle = knife:FindFirstChild("Handle")
    if firetouch and handle then
        pcall(firetouch, handle, tr, 0)
        pcall(firetouch, handle, tr, 1)
    end
    return true
end

local function throwKnifeAt(p)
    local knife = equip("Knife")
    if not knife then notify("Knife", "no knife (you're not murderer)", 3) return end
    local tr = rootOf(p)
    local handle = knife:FindFirstChild("Handle")
    local ev = knife:FindFirstChild("Events")
    local th = ev and ev:FindFirstChild("KnifeThrown")
    if not (tr and handle and th) then notify("Knife", "throw remote not found", 3) return end
    local pos = predict(tr, "knife")
    pcall(function() th:FireServer(handle.CFrame, CFrame.new(pos)) end)
end

local function killAll()
    if Roles.localRole() ~= "Murderer" then notify("Kill All", "you're not the murderer", 3) return end
    if not equip("Knife") then notify("Kill All", "no knife found", 3) return end
    local r = getRoot()
    local back = r and r.CFrame
    local n = 0
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and Roles.isAlive(p) then
            local tr = rootOf(p)
            r = getRoot()
            if tr and r then
                r.CFrame = tr.CFrame * CFrame.new(0, 0, 2.5)
                stab(p)
                n = n + 1
                task.wait(0.15)
            end
        end
    end
    r = getRoot()
    if r and back then r.CFrame = back end
    notify("Kill All", "swung on " .. n .. " players", 3)
end

-- auto shoot murderer (sheriff / hero)
task.spawn(function()
    local last = 0
    while Alive do
        task.wait(0.1)
        if S.autoShoot and os.clock() - last > 0.7 and Roles.localRole() ~= "Murderer" then
            local hasGun = findTool("Gun")
            local m = Roles.find("Murderer")
            local mr, tr = getRoot(), m and rootOf(m)
            if hasGun and mr and tr and (tr.Position - mr.Position).Magnitude <= S.autoShootRange then
                if shootAt(tr) then last = os.clock() end
            end
        end
    end
end)

-- kill aura (murderer)
task.spawn(function()
    local lastHit = {}
    while Alive do
        task.wait(0.08)
        if S.killAura and Roles.localRole() == "Murderer" and findTool("Knife") then
            local mr = getRoot()
            if mr then
                for _, p in ipairs(Players:GetPlayers()) do
                    if p ~= LocalPlayer and Roles.isAlive(p) then
                        local tr = rootOf(p)
                        if tr and (tr.Position - mr.Position).Magnitude <= S.auraRange and os.clock() - (lastHit[p] or 0) > 0.3 then
                            lastHit[p] = os.clock()
                            stab(p)
                        end
                    end
                end
            end
        end
    end
end)

----------------------------------------------------------------------
-- fling
----------------------------------------------------------------------
local function flingPlayer(p, duration)
    if Fling.active then notify("Fling", "already flinging", 2) return end
    local myRoot, myHum, tRoot = getRoot(), getHum(), rootOf(p)
    if not (myRoot and myHum and tRoot) then notify("Fling", "target or you not loaded", 3) return end
    Fling.active = true
    local origin = myRoot.CFrame
    local t0 = os.clock()
    notify("Fling", "flinging " .. p.DisplayName, 2)
    while Fling.active and Alive and os.clock() - t0 < duration do
        myRoot = getRoot()
        tRoot = rootOf(p)
        if not (myRoot and tRoot) then break end
        if not Roles.isAlive(p) then break end
        RunService.Heartbeat:Wait()
        myRoot.CFrame = tRoot.CFrame
        myRoot.AssemblyLinearVelocity = Vector3.new(9e6, 9e6, 9e6)
        myRoot.AssemblyAngularVelocity = Vector3.new(0, 9e6, 0)
        RunService.RenderStepped:Wait()
        myRoot.AssemblyLinearVelocity = Vector3.zero
        myRoot.AssemblyAngularVelocity = Vector3.zero
        if tRoot.AssemblyLinearVelocity.Magnitude > 400 then break end
    end
    Fling.active = false
    myRoot = getRoot()
    if myRoot then
        myRoot.AssemblyLinearVelocity = Vector3.zero
        myRoot.AssemblyAngularVelocity = Vector3.zero
        myRoot.CFrame = origin
    end
    local h = getHum()
    if h then h:ChangeState(Enum.HumanoidStateType.GettingUp) end
end

----------------------------------------------------------------------
-- teleports / gun drop
----------------------------------------------------------------------
local function tpTo(cf)
    local r = getRoot()
    if not r then return false end
    r.CFrame = cf
    r.AssemblyLinearVelocity = Vector3.zero
    return true
end

local function tpPlayer(p)
    local tr = rootOf(p)
    if not tr then return false end
    return tpTo(tr.CFrame * CFrame.new(0, 0, 3))
end

local gunCache, gunCacheT = nil, 0
local function findGunDrop()
    for _, g in ipairs(CollectionService:GetTagged("GunDrop")) do
        if g:IsA("BasePart") and g:IsDescendantOf(Workspace) then return g end
    end
    if os.clock() - gunCacheT > 2 then
        gunCacheT = os.clock()
        local g = Workspace:FindFirstChild("GunDrop", true)
        gunCache = (g and g:IsA("BasePart")) and g or nil
    end
    if gunCache and gunCache.Parent then return gunCache end
    return nil
end

local function currentMap()
    for _, m in ipairs(CollectionService:GetTagged("CurrentMap")) do
        return m
    end
    for _, c in ipairs(Workspace:GetChildren()) do
        if c:FindFirstChild("CoinContainer") then return c end
    end
    return nil
end

local function spawnPart(container)
    local sp = container and container:FindFirstChild("Spawns")
    return sp and sp:GetChildren()[1]
end

local grabbing = false
local function grabGun()
    if grabbing then return end
    local drop, r = findGunDrop(), getRoot()
    if not drop then notify("Gun", "no dropped gun right now", 3) return end
    if not r then return end
    grabbing = true
    local back = r.CFrame
    r.CFrame = drop.CFrame + Vector3.new(0, 2, 0)
    r.AssemblyLinearVelocity = Vector3.zero
    if firetouch then
        pcall(firetouch, r, drop, 0)
        task.wait(0.05)
        pcall(firetouch, r, drop, 1)
    end
    local t0 = os.clock()
    repeat task.wait(0.05) until findTool("Gun") or os.clock() - t0 > 1.2
    r = getRoot()
    if r then r.CFrame = back end
    grabbing = false
end

local safePart
local function tpSafeSpot()
    if not safePart or not safePart.Parent then
        safePart = Instance.new("Part")
        safePart.Name = "NovexSafe"
        safePart.Anchored = true
        safePart.Size = Vector3.new(60, 2, 60)
        safePart.Position = Vector3.new(0, 1500, 0)
        safePart.Transparency = 0.6
        safePart.Parent = Workspace
    end
    tpTo(safePart.CFrame + Vector3.new(0, 4, 0))
end

----------------------------------------------------------------------
-- coin farm
----------------------------------------------------------------------
local function getCoins()
    local list = {}
    for _, c in ipairs(CollectionService:GetTagged("ServerCoinPart")) do
        if c:IsA("BasePart") and c:IsDescendantOf(Workspace)
            and c:FindFirstChildOfClass("TouchTransmitter")
            and not (c:GetAttribute("Collected") or c:GetAttribute("Collected2") or c:GetAttribute("RoundEnd"))
            and not Farm.full[c:GetAttribute("CoinID")] then
            list[#list + 1] = c
        end
    end
    if #list == 0 then
        local m = currentMap()
        local cc = m and m:FindFirstChild("CoinContainer")
        if cc then
            for _, c in ipairs(cc:GetChildren()) do
                if c:IsA("BasePart") and not c:GetAttribute("Collected") then list[#list + 1] = c end
            end
        end
    end
    return list
end

task.spawn(function()
    while Alive do
        task.wait(0.05)
        if Farm.enabled and not Farm.bagFull then
            local r, h = getRoot(), getHum()
            if r and h and h.Health > 0 then
                local best, bd
                for _, c in ipairs(getCoins()) do
                    local d = (r.Position - c.Position).Magnitude
                    if not bd or d < bd then best, bd = c, d end
                end
                if best then
                    if Farm.teleport then
                        r.CFrame = CFrame.new(best.Position)
                    else
                        local dur = math.max(bd / Farm.speed, 0.05)
                        local tw = TweenService:Create(r, TweenInfo.new(dur, Enum.EasingStyle.Linear), {CFrame = CFrame.new(best.Position)})
                        local done = false
                        local cn = tw.Completed:Connect(function() done = true end)
                        tw:Play()
                        local t0 = os.clock()
                        repeat
                            task.wait()
                        until done or not Farm.enabled or not best.Parent or best:GetAttribute("Collected") or os.clock() - t0 > dur + 1
                        cn:Disconnect()
                        tw:Cancel()
                    end
                    if firetouch and best.Parent then
                        pcall(firetouch, r, best, 0)
                        pcall(firetouch, r, best, 1)
                    end
                    task.wait(0.12)
                else
                    task.wait(0.5)
                end
            end
        end
    end
end)

task.spawn(function()
    local rem = ReplicatedStorage:WaitForChild("Remotes", 10)
    local gp = rem and rem:WaitForChild("Gameplay", 10)
    if not gp then return end
    local cc = gp:FindFirstChild("CoinCollected")
    if cc then
        bind(cc.OnClientEvent, function(coinType, collected, limit)
            if collected and limit and collected >= limit then
                if coinType ~= nil then Farm.full[coinType] = true end
                Farm.bagFull = true
                if Farm.enabled and Farm.resetFull and Roles.localRole() ~= "Murderer" then
                    local h = getHum()
                    if h then h.Health = 0 end
                end
            end
        end)
    end
    local cs = gp:FindFirstChild("CoinsStarted")
    if cs then
        bind(cs.OnClientEvent, function()
            Farm.full = {}
            Farm.bagFull = false
        end)
    end
end)

----------------------------------------------------------------------
-- esp
----------------------------------------------------------------------
local ROLE_COLOR = {
    Murderer = Color3.fromRGB(255, 60, 60),
    Sheriff  = Color3.fromRGB(70, 120, 255),
    Hero     = Color3.fromRGB(255, 210, 60),
    Innocent = Color3.fromRGB(80, 255, 120),
}
local GUN_COLOR = Color3.fromRGB(190, 90, 255)

local ESP = {players = false, rolesOnly = false, gun = false, objs = {}, gunObj = nil, lastDrop = nil}

local function makeLabel(adornee, size, offset)
    local bb = Instance.new("BillboardGui")
    bb.Adornee = adornee
    bb.Size = size
    bb.StudsOffset = offset
    bb.AlwaysOnTop = true
    bb.Parent = espFolder
    local tl = Instance.new("TextLabel")
    tl.Size = UDim2.fromScale(1, 1)
    tl.BackgroundTransparency = 1
    tl.Font = Enum.Font.GothamBold
    tl.TextSize = 13
    tl.TextStrokeTransparency = 0.3
    tl.TextColor3 = Color3.new(1, 1, 1)
    tl.Text = ""
    tl.Parent = bb
    return bb, tl
end

local function makeHighlight(adornee, color)
    local hl = Instance.new("Highlight")
    hl.Adornee = adornee
    hl.FillColor = color
    hl.OutlineColor = color
    hl.FillTransparency = 0.6
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = espFolder
    return hl
end

local function destroyESP(p)
    local o = ESP.objs[p]
    if o then
        pcall(function() o.hl:Destroy() end)
        pcall(function() o.bb:Destroy() end)
        ESP.objs[p] = nil
    end
end

local function destroyGunESP()
    if ESP.gunObj then
        pcall(function() ESP.gunObj.hl:Destroy() end)
        pcall(function() ESP.gunObj.bb:Destroy() end)
        ESP.gunObj = nil
    end
end

local function espUpdate()
    for p in pairs(ESP.objs) do
        if not ESP.players or not p.Parent or not p.Character then destroyESP(p) end
    end
    if ESP.players then
        local mr = getRoot()
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then
                local char = p.Character
                local head = char and char:FindFirstChild("Head")
                local hrp = char and char:FindFirstChild("HumanoidRootPart")
                local role = Roles.roleOf(p)
                local show = head and hrp and Roles.isAlive(p) and (not ESP.rolesOnly or role ~= "Innocent")
                if show then
                    local o = ESP.objs[p]
                    if not o or o.char ~= char then
                        destroyESP(p)
                        local col = ROLE_COLOR.Innocent
                        local bb, tl = makeLabel(head, UDim2.fromOffset(200, 28), Vector3.new(0, 2.6, 0))
                        o = {char = char, hl = makeHighlight(char, col), bb = bb, tl = tl}
                        ESP.objs[p] = o
                    end
                    local col = ROLE_COLOR[role] or ROLE_COLOR.Innocent
                    o.hl.FillColor = col
                    o.hl.OutlineColor = col
                    o.tl.TextColor3 = col
                    local d = mr and math.floor((hrp.Position - mr.Position).Magnitude) or 0
                    o.tl.Text = string.format("%s [%s] %dm", p.DisplayName, role, d)
                else
                    destroyESP(p)
                end
            end
        end
    end

    local drop = findGunDrop()
    if ESP.gun and drop then
        if not ESP.gunObj or ESP.gunObj.part ~= drop then
            destroyGunESP()
            local bb, tl = makeLabel(drop, UDim2.fromOffset(120, 28), Vector3.new(0, 2, 0))
            ESP.gunObj = {part = drop, hl = makeHighlight(drop, GUN_COLOR), bb = bb, tl = tl}
            tl.TextColor3 = GUN_COLOR
            if ESP.lastDrop ~= drop then
                ESP.lastDrop = drop
                notify("Gun Dropped", "esp'd it, tp or auto grab", 4)
            end
        end
        local mr = getRoot()
        local d = mr and math.floor((drop.Position - mr.Position).Magnitude) or 0
        ESP.gunObj.tl.Text = "GUN " .. d .. "m"
    else
        destroyGunESP()
        if not drop then ESP.lastDrop = nil end
    end
end

task.spawn(function()
    while Alive do
        task.wait(0.25)
        safe(espUpdate)
        if S.autoGrab and Roles.localRole() ~= "Murderer" and not findTool("Gun") and findGunDrop() then
            safe(grabGun)
        end
    end
end)

----------------------------------------------------------------------
-- roles loop + notifier
----------------------------------------------------------------------
local statusPara
task.spawn(function()
    local lastSig, lastMine = "", ""
    while Alive do
        safe(Roles.refresh)
        local m, s = Roles.find("Murderer", true), Roles.find("Sheriff", true)
        local sig = (m and m.Name or "-") .. "|" .. (s and s.Name or "-")
        if sig ~= lastSig then
            lastSig = sig
            if S.roleNotify and (m or s) then
                notify("Roles", "Murderer: " .. (m and m.DisplayName or "?") .. "\nSheriff: " .. (s and s.DisplayName or "?"), 6)
            end
        end
        local mine = Roles.localRole()
        if mine ~= lastMine then
            lastMine = mine
            if S.roleNotify and mine ~= "Innocent" then notify("Your Role", "you are " .. mine, 4) end
        end
        if statusPara then
            local drop = findGunDrop()
            pcall(function()
                statusPara:SetDesc(string.format("You: %s\nMurderer: %s\nSheriff: %s\nGun drop: %s\nBag full: %s",
                    mine,
                    m and m.DisplayName or "-",
                    s and s.DisplayName or "-",
                    drop and "YES" or "no",
                    Farm.bagFull and "yes" or "no"))
            end)
        end
        task.wait(1)
    end
end)

----------------------------------------------------------------------
-- player mods
----------------------------------------------------------------------
local function flyStop()
    if Fly.bv then pcall(function() Fly.bv:Destroy() end) Fly.bv = nil end
    if Fly.bg then pcall(function() Fly.bg:Destroy() end) Fly.bg = nil end
    local h = getHum()
    if h then h.PlatformStand = false end
end

local function flyStart()
    local r, h = getRoot(), getHum()
    if not (r and h) then return end
    flyStop()
    Fly.bv = Instance.new("BodyVelocity")
    Fly.bv.MaxForce = Vector3.new(1e9, 1e9, 1e9)
    Fly.bv.Velocity = Vector3.zero
    Fly.bv.Parent = r
    Fly.bg = Instance.new("BodyGyro")
    Fly.bg.MaxTorque = Vector3.new(1e9, 1e9, 1e9)
    Fly.bg.P = 1e4
    Fly.bg.CFrame = r.CFrame
    Fly.bg.Parent = r
    h.PlatformStand = true
end

bind(RunService.RenderStepped, function()
    if Fly.on and Fly.bv and Fly.bv.Parent and Fly.bg then
        local h = getHum()
        local cam = Workspace.CurrentCamera
        if h and cam then
            local md = h.MoveDirection
            local v = Vector3.zero
            if md.Magnitude > 0 then
                local look = cam.CFrame.LookVector
                local flat = Vector3.new(look.X, 0, look.Z)
                local fwd = (flat.Magnitude > 0) and md:Dot(flat.Unit) or 0
                v = md * Fly.speed + Vector3.new(0, look.Y * Fly.speed * fwd, 0)
            end
            if UserInputService:IsKeyDown(Enum.KeyCode.Space) then v = v + Vector3.new(0, Fly.speed, 0) end
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then v = v - Vector3.new(0, Fly.speed, 0) end
            Fly.bv.Velocity = v
            Fly.bg.CFrame = cam.CFrame
        end
    end
end)

bind(RunService.Stepped, function()
    local c = LocalPlayer.Character
    if not c then return end
    if S.noclip or Farm.enabled or Fling.active then
        for _, part in ipairs(c:GetChildren()) do
            if part:IsA("BasePart") then part.CanCollide = false end
        end
    end
    local r = c:FindFirstChild("HumanoidRootPart")
    if r then
        if Farm.enabled then
            r.AssemblyLinearVelocity = Vector3.zero
        elseif S.antiFling and not Fling.active then
            if r.AssemblyLinearVelocity.Magnitude > 250 or r.AssemblyAngularVelocity.Magnitude > 250 then
                r.AssemblyLinearVelocity = Vector3.zero
                r.AssemblyAngularVelocity = Vector3.zero
            end
        end
    end
end)

bind(UserInputService.JumpRequest, function()
    if S.infJump then
        local h = getHum()
        if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end)

task.spawn(function()
    while Alive do
        task.wait(0.15)
        local h = getHum()
        if h then
            if S.walkOn then h.WalkSpeed = S.walk end
            if S.jumpOn then
                h.UseJumpPower = true
                h.JumpPower = S.jump
            end
        end
    end
end)

bind(LocalPlayer.CharacterAdded, function()
    Farm.bagFull = false
    if Fly.on then
        task.wait(1)
        flyStart()
    end
end)

bind(LocalPlayer.Idled, function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.zero)
end)

local lightOrig
local function setFullbright(on)
    if on then
        lightOrig = lightOrig or {
            Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime,
            FogEnd = Lighting.FogEnd, GlobalShadows = Lighting.GlobalShadows,
            Ambient = Lighting.Ambient,
        }
        Lighting.Brightness = 2
        Lighting.ClockTime = 14
        Lighting.FogEnd = 1e6
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(190, 190, 190)
    elseif lightOrig then
        for k, v in pairs(lightOrig) do Lighting[k] = v end
        lightOrig = nil
    end
end

local function spectate(p)
    local cam = Workspace.CurrentCamera
    local h = p and p.Character and p.Character:FindFirstChildOfClass("Humanoid")
    if cam and h then
        cam.CameraSubject = h
        notify("Spectate", "watching " .. p.DisplayName, 2)
    else
        notify("Spectate", "no target", 2)
    end
end

local function unspectate()
    local cam, h = Workspace.CurrentCamera, getHum()
    if cam and h then cam.CameraSubject = h end
end

local function rejoin()
    if #Players:GetPlayers() <= 1 then
        TeleportService:Teleport(game.PlaceId, LocalPlayer)
    else
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
    end
end

local function serverHop()
    if not request then notify("Server Hop", "executor has no request()", 4) return end
    notify("Server Hop", "looking for a server...", 3)
    local ok, res = pcall(function()
        return request({Url = string.format("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100", game.PlaceId)})
    end)
    local data
    if ok and res and res.Body then
        local ok2, dec = pcall(function() return HttpService:JSONDecode(res.Body) end)
        if ok2 then data = dec end
    end
    if not (data and data.data) then notify("Server Hop", "couldn't fetch servers", 4) return end
    local pool = {}
    for _, sv in ipairs(data.data) do
        if type(sv) == "table" and sv.id ~= game.JobId and tonumber(sv.playing) and tonumber(sv.maxPlayers)
            and sv.playing >= 3 and sv.playing < sv.maxPlayers - 1 then
            pool[#pool + 1] = sv.id
        end
    end
    if #pool == 0 then notify("Server Hop", "no good servers found", 4) return end
    TeleportService:TeleportToPlaceInstance(game.PlaceId, pool[math.random(1, #pool)], LocalPlayer)
end

----------------------------------------------------------------------
-- emote / animation module (loaded + rebranded at runtime)
----------------------------------------------------------------------
local rebrandConns = {}
local function rebrandText(o)
    if o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox") then
        local function fix()
            local t = o.Text
            if t and string.find(t, "7yd7", 1, true) then
                o.Text = plainReplace(t, "7yd7", HUB_NAME)
            end
        end
        fix()
        o:GetPropertyChangedSignal("Text"):Connect(fix)
    end
end

local function startRebrandSweep()
    if #rebrandConns > 0 then return end
    local roots = {CoreGui}
    local gp = guiParent()
    if gp ~= CoreGui then roots[#roots + 1] = gp end
    for _, root in ipairs(roots) do
        for _, d in ipairs(root:GetDescendants()) do pcall(rebrandText, d) end
        local c = root.DescendantAdded:Connect(function(d) pcall(rebrandText, d) end)
        rebrandConns[#rebrandConns + 1] = c
        Conns[#Conns + 1] = c
    end
end

local emoteLoading = false
local function loadEmotes()
    if emoteLoading then return end
    if _G.EmotesGUIRunning then
        notify(HUB_NAME .. " | Emote", "already loaded, open the emote wheel", 4)
        return
    end
    emoteLoading = true
    notify(HUB_NAME .. " | Emote", "loading animations & emotes...", 3)
    local src = httpGet(EMOTE_SRC)
    if not src then
        emoteLoading = false
        notify(HUB_NAME .. " | Emote", "download failed, check your connection", 5)
        return
    end
    -- display strings: "7yd7 | Emote" -> "Novex Hub | Emote"
    src = plainReplace(src, "7yd7 | ", HUB_NAME .. " | ")
    -- data folder: "7yd7/..." and "7yd7" -> NovexHub (quoted forms only, github urls are left alone)
    src = plainReplace(src, "\"7yd7/", "\"NovexHub/")
    src = plainReplace(src, "\"7yd7\"", "\"NovexHub\"")
    if DISCORD_INVITE ~= "" then
        src = plainReplace(src, "https://discord.gg/kRfzv2kV7X", DISCORD_INVITE)
    end
    local fn, err = loadstring(src)
    if not fn then
        emoteLoading = false
        notify(HUB_NAME .. " | Emote", "patch failed: " .. tostring(err), 6)
        return
    end
    startRebrandSweep()
    task.spawn(function()
        local ok, e = pcall(fn)
        emoteLoading = false
        if ok then
            notify(HUB_NAME .. " | Emote", "Novex Hub emote loaded ✅", 5)
        else
            warn("[Novex Hub] emote module error: " .. tostring(e))
            notify(HUB_NAME .. " | Emote", "module errored, see console", 5)
        end
    end)
end

----------------------------------------------------------------------
-- ui
----------------------------------------------------------------------
local Window = WindUI:CreateWindow({
    Title = HUB_NAME,
    Author = "Murder Mystery 2",
    Icon = "swords",
    Folder = "NovexHub",
    Size = UDim2.fromOffset(500, 360),
    Theme = "Dark",
    Transparent = true,
    SideBarWidth = 160,
})

pcall(function()
    Window:EditOpenButton({
        Title = HUB_NAME,
        Icon = "swords",
        CornerRadius = UDim.new(1, 0),
        StrokeThickness = 2,
        Color = ColorSequence.new(Color3.fromRGB(130, 80, 255), Color3.fromRGB(0, 200, 255)),
        Draggable = true,
    })
end)
pcall(function() Window:SetToggleKey(Enum.KeyCode.RightShift) end)

local function header(tab, text)
    pcall(function() tab:Section({Title = text}) end)
end
local function toggle(tab, title, desc, default, cb)
    return tab:Toggle({
        Title = title, Desc = desc,
        Value = default or false, Default = default or false,
        Callback = function(v) safe(cb, v) end,
    })
end
local function slider(tab, title, desc, min, max, default, step, cb)
    return tab:Slider({
        Title = title, Desc = desc, Step = step or 1,
        Value = {Min = min, Max = max, Default = default},
        Callback = function(v) safe(cb, tonumber(v) or default) end,
    })
end
local function button(tab, title, desc, cb)
    return tab:Button({
        Title = title, Desc = desc,
        Callback = function() task.spawn(safe, cb) end,
    })
end
local function dropdown(tab, title, values, default, cb)
    return tab:Dropdown({
        Title = title, Values = values, Value = default,
        Callback = function(sel)
            local v = sel
            if type(sel) == "table" then v = sel.Title or sel.Name or sel[1] end
            safe(cb, v)
        end,
    })
end

local TargetModes = {"Murderer", "Sheriff", "Nearest"}

-- info -----------------------------------------------------------------
local TInfo = Window:Tab({Title = "Info", Icon = "info"})
statusPara = TInfo:Paragraph({Title = "Round Status", Desc = "waiting for round data..."})
toggle(TInfo, "Role Notifier", "pop a notification with murderer + sheriff when roles are known", true, function(v) S.roleNotify = v end)
button(TInfo, "Show Roles Now", "murderer / sheriff / your role", function()
    local m, s = Roles.find("Murderer", true), Roles.find("Sheriff", true)
    notify("Roles", "You: " .. Roles.localRole() .. "\nMurderer: " .. (m and m.DisplayName or "?") .. "\nSheriff: " .. (s and s.DisplayName or "?"), 6)
end)
button(TInfo, "Rejoin", "same server", rejoin)
button(TInfo, "Server Hop", "jump to another public server", serverHop)

-- farm -----------------------------------------------------------------
local TFarm = Window:Tab({Title = "Farm", Icon = "coins"})
header(TFarm, "Coins")
toggle(TFarm, "Auto Farm Coins", "tweens to every coin, noclip on while farming", false, function(v)
    Farm.enabled = v
    if v then Farm.bagFull = false end
    notify("Farm", v and "ON" or "OFF", 2)
end)
slider(TFarm, "Farm Speed", "studs/sec. higher = faster but riskier", 16, 60, 25, 1, function(v) Farm.speed = v end)
toggle(TFarm, "Teleport Mode (risky)", "skip the tween and hop coin to coin", false, function(v) Farm.teleport = v end)
toggle(TFarm, "Reset When Bag Is Full", "dies when full so you skip the wait (not as murderer)", true, function(v) Farm.resetFull = v end)
button(TFarm, "Safe Spot (sky)", "parks you on a platform high above the map", tpSafeSpot)

-- combat ---------------------------------------------------------------
local TCombat = Window:Tab({Title = "Combat", Icon = "crosshair"})
header(TCombat, "Targeting")
button(TCombat, "Target Murderer", "both aimbots lock the murderer", function()
    Aim.gun.mode, Aim.knife.mode = "Murderer", "Murderer"
    notify("Target", "Murderer", 2)
end)
button(TCombat, "Target Sheriff", "both aimbots lock the sheriff", function()
    Aim.gun.mode, Aim.knife.mode = "Sheriff", "Sheriff"
    notify("Target", "Sheriff", 2)
end)

header(TCombat, "Gun Aimbot (sheriff / hero)")
toggle(TCombat, "Gun Aimbot", "shoot anywhere, the bullet goes to the target", false, function(v)
    Aim.gun.enabled = v
    if v then
        Aim.gun.armed = true
        if not hookOK then notify("Gun Aimbot", "hook unsupported on this executor", 5) end
    end
end)
toggle(TCombat, "Gun Circle Button", "floating circle: tap to arm / pause, drag to move. green = armed, red = target in range", true, function(v) Aim.gun.button = v; if not v then Aim.gun.armed = true end end)
dropdown(TCombat, "Gun Target", TargetModes, "Murderer", function(v) Aim.gun.mode = v end)
slider(TCombat, "Gun Range", "studs", 20, 1000, 300, 10, function(v) Aim.gun.range = v end)
toggle(TCombat, "Auto Shoot Murderer", "fires the second the murderer is in range", false, function(v) S.autoShoot = v end)
slider(TCombat, "Auto Shoot Range", "studs", 20, 1000, 300, 10, function(v) S.autoShootRange = v end)
button(TCombat, "Shoot Murderer Now", "equips gun and fires once", function()
    local m = Roles.find("Murderer")
    local tr = m and rootOf(m)
    if not tr then notify("Shoot", "no murderer found", 3) return end
    if not shootAt(tr) then notify("Shoot", "you have no gun", 3) end
end)
button(TCombat, "Equip Gun", "", function() if not equip("Gun") then notify("Gun", "you don't have one", 3) end end)

header(TCombat, "Knife Aimbot (murderer)")
toggle(TCombat, "Knife Aimbot", "throw anywhere, the knife goes to the target", false, function(v)
    Aim.knife.enabled = v
    if v then
        Aim.knife.armed = true
        if not hookOK then notify("Knife Aimbot", "hook unsupported on this executor", 5) end
    end
end)
toggle(TCombat, "Knife Circle Button", "floating circle: tap to arm / pause, drag to move", true, function(v) Aim.knife.button = v; if not v then Aim.knife.armed = true end end)
dropdown(TCombat, "Knife Target", TargetModes, "Nearest", function(v) Aim.knife.mode = v end)
slider(TCombat, "Knife Range", "studs", 20, 1000, 300, 10, function(v) Aim.knife.range = v end)
button(TCombat, "Throw Knife At Target", "uses the knife target setting", function()
    local p = pickTarget(Aim.knife.mode, Aim.knife.range)
    if not p then notify("Knife", "no target in range", 3) return end
    throwKnifeAt(p)
end)
toggle(TCombat, "Kill Aura", "auto stab anyone inside the range", false, function(v) S.killAura = v end)
slider(TCombat, "Aura Range", "studs", 6, 60, 14, 1, function(v) S.auraRange = v end)
button(TCombat, "Kill All", "murderer only, hops to each player and stabs", killAll)
button(TCombat, "Equip Knife", "", function() if not equip("Knife") then notify("Knife", "you don't have one", 3) end end)

-- troll ----------------------------------------------------------------
local TTroll = Window:Tab({Title = "Troll", Icon = "wind"})
slider(TTroll, "Fling Time", "seconds before it gives up", 1, 8, 3, 1, function(v) S.flingTime = v end)
button(TTroll, "Fling Murderer", "", function()
    local m = Roles.find("Murderer")
    if not m then notify("Fling", "no murderer", 3) return end
    flingPlayer(m, S.flingTime)
end)
button(TTroll, "Fling Sheriff", "", function()
    local s = Roles.find("Sheriff")
    if not s then notify("Fling", "no sheriff", 3) return end
    flingPlayer(s, S.flingTime)
end)
button(TTroll, "Fling Nearest", "", function()
    local p = pickTarget("Nearest", 1e6)
    if not p then notify("Fling", "nobody around", 3) return end
    flingPlayer(p, S.flingTime)
end)
button(TTroll, "Fling Everyone", "one by one", function()
    for _, p in ipairs(Players:GetPlayers()) do
        if not Alive then break end
        if p ~= LocalPlayer and Roles.isAlive(p) then flingPlayer(p, S.flingTime) task.wait(0.3) end
    end
end)
button(TTroll, "Stop Fling", "", function() Fling.active = false end)
toggle(TTroll, "Anti Fling (you)", "zeroes crazy velocity on your character", true, function(v) S.antiFling = v end)

-- esp ------------------------------------------------------------------
local TEsp = Window:Tab({Title = "ESP", Icon = "eye"})
toggle(TEsp, "Player ESP", "role colors: red murderer, blue sheriff, gold hero, green innocent", false, function(v) ESP.players = v end)
toggle(TEsp, "Only Murderer / Sheriff", "hide innocents", false, function(v) ESP.rolesOnly = v end)
toggle(TEsp, "Dropped Gun ESP", "lights up the gun when the sheriff dies", false, function(v) ESP.gun = v end)
toggle(TEsp, "Auto Grab Gun", "tp to a dropped gun, grab it, tp back", false, function(v) S.autoGrab = v end)
toggle(TEsp, "Fullbright", "", false, setFullbright)

-- teleport -------------------------------------------------------------
local TTp = Window:Tab({Title = "Teleport", Icon = "map-pin"})
button(TTp, "TP to Murderer", "", function()
    local m = Roles.find("Murderer")
    if not (m and tpPlayer(m)) then notify("TP", "no murderer found", 3) end
end)
button(TTp, "TP to Sheriff", "", function()
    local s = Roles.find("Sheriff")
    if not (s and tpPlayer(s)) then notify("TP", "no sheriff found", 3) end
end)
button(TTp, "TP to Gun", "dropped gun", function()
    local g = findGunDrop()
    if not (g and tpTo(g.CFrame + Vector3.new(0, 3, 0))) then notify("TP", "no dropped gun", 3) end
end)
button(TTp, "Grab Gun (tp, grab, back)", "", grabGun)
button(TTp, "TP to Map", "", function()
    local sp = spawnPart(currentMap())
    if not (sp and tpTo(sp.CFrame + Vector3.new(0, 4, 0))) then notify("TP", "no active map", 3) end
end)
button(TTp, "TP to Lobby", "", function()
    local sp = spawnPart(Workspace:FindFirstChild("Lobby"))
    if not (sp and tpTo(sp.CFrame + Vector3.new(0, 4, 0))) then notify("TP", "lobby spawn not found", 3) end
end)
button(TTp, "TP to Random Player", "", function()
    local list = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and Roles.isAlive(p) and rootOf(p) then list[#list + 1] = p end
    end
    if #list == 0 then notify("TP", "nobody alive", 3) return end
    tpPlayer(list[math.random(1, #list)])
end)
button(TTp, "Spectate Murderer", "", function() spectate(Roles.find("Murderer")) end)
button(TTp, "Spectate Sheriff", "", function() spectate(Roles.find("Sheriff")) end)
button(TTp, "Stop Spectating", "", unspectate)

-- player ---------------------------------------------------------------
local TPlayer = Window:Tab({Title = "Player", Icon = "user"})
toggle(TPlayer, "WalkSpeed", "", false, function(v)
    S.walkOn = v
    if not v then local h = getHum() if h then h.WalkSpeed = 16 end end
end)
slider(TPlayer, "WalkSpeed Value", "", 16, 120, 32, 1, function(v) S.walk = v end)
toggle(TPlayer, "JumpPower", "", false, function(v)
    S.jumpOn = v
    if not v then local h = getHum() if h then h.JumpPower = 50 end end
end)
slider(TPlayer, "JumpPower Value", "", 50, 200, 60, 1, function(v) S.jump = v end)
toggle(TPlayer, "Infinite Jump", "", false, function(v) S.infJump = v end)
toggle(TPlayer, "Noclip", "", false, function(v) S.noclip = v end)
toggle(TPlayer, "Fly", "joystick + camera aim to steer. pc: space up, ctrl down", false, function(v)
    Fly.on = v
    if v then flyStart() else flyStop() end
end)
slider(TPlayer, "Fly Speed", "", 20, 200, 60, 1, function(v) Fly.speed = v end)
slider(TPlayer, "Camera FOV", "", 50, 120, 70, 1, function(v)
    if Workspace.CurrentCamera then Workspace.CurrentCamera.FieldOfView = v end
end)

-- emotes ---------------------------------------------------------------
local TEmote = Window:Tab({Title = "Emotes", Icon = "smile"})
TEmote:Paragraph({
    Title = "Animations & Emotes",
    Desc = "Tap the button to load the full emote + animation pack. PC: press . to open the wheel. Mobile: an open button shows up.",
})
button(TEmote, "Animations & Emotes", "load the emote / animation menu", loadEmotes)

-- settings -------------------------------------------------------------
local TSet = Window:Tab({Title = "Settings", Icon = "settings"})
dropdown(TSet, "Theme", {"Dark", "Light", "Rose", "Plant", "Red", "Indigo", "Sky", "Violet", "Amber", "Emerald"}, "Dark", function(v)
    pcall(function() WindUI:SetTheme(v) end)
end)
TSet:Keybind({
    Title = "Toggle UI Key",
    Value = "RightShift",
    Callback = function(k)
        local kc = k
        if type(k) == "string" then kc = Enum.KeyCode[k] end
        if kc then pcall(function() Window:SetToggleKey(kc) end) end
    end,
})

local function Unload()
    Alive = false
    Farm.enabled = false
    Fling.active = false
    for _, c in ipairs(Conns) do pcall(function() c:Disconnect() end) end
    Conns = {}
    flyStop()
    setFullbright(false)
    for p in pairs(ESP.objs) do destroyESP(p) end
    destroyGunESP()
    if safePart then pcall(function() safePart:Destroy() end) end
    pcall(function() circleGui:Destroy() end)
    pcall(function() espFolder:Destroy() end)
    pcall(function() Window:Destroy() end)
    if getgenv then getgenv().NovexHubUnload = nil end
end
if getgenv then getgenv().NovexHubUnload = Unload end

button(TSet, "Unload Hub", "kills everything and removes the UI", Unload)

notify(HUB_NAME, "loaded ✅  gun/knife circles show up when the aimbot toggles are on", 6)
