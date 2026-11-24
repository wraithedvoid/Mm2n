--[[
    NOVEX HUB | Murder Mystery 2 (place 142823291)
    UI: WindUI (Footagesus) 1.6.x  -- there is no "WindUI 2" release, 1.6.x is current
    Target: Delta / any executor with hookmetamethod, getnamecallmethod, checkcaller,
            firetouchinterest, readfile/isfile (fallbacks wrapped in pcall)
    Plain Luau syntax only (no +=, no continue) so it parses everywhere.

    EMOTE / ANIMATION TAB
      Put your emote script (the 7yd7 one you pasted) at:  <executor workspace>/NovexHub/Emote.lua
      The hub rebrands it at load time (7yd7 -> Novex Hub) and prints "Novex Hub Emote loaded".
      Or set getgenv().NovexEmoteURL = "https://raw...." before running this script.
]]

if getgenv().NovexHubLoaded then
    pcall(function() getgenv().NovexHubUnload() end)
    task.wait(0.8)
end
getgenv().NovexHubLoaded = true

-- ===================== services =====================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local VirtualUser = game:GetService("VirtualUser")
local TweenService = game:GetService("TweenService")

local LP = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- ===================== state =====================
local Novex = {
    Connections = {},
    Cleanups = {},
    Roles = {},            -- [Player] = "Murderer" | "Sheriff" | "Hero" | "Innocent"
    Murderer = nil,
    Sheriff = nil,
    Flags = {
        GunAim = false,
        GunAimArmed = true,
        KnifeAim = false,
        KnifeAimArmed = true,
        Prediction = 0.12,
        ESP = false,
        GunESP = false,
        TargetMurderer = false,
        TargetSheriff = false,
        CoinFarm = false,
        FarmSpeed = 28,
        FarmMode = "Tween",
        FarmResetFull = true,
        BagFull = false,
        AutoGun = false,
        KillAura = false,
        KillAuraRange = 12,
        Noclip = false,
        InfJump = false,
        Fly = false,
        FlySpeed = 60,
        WalkSpeed = 16,
        WalkSpeedOn = false,
        JumpPower = 50,
        JumpPowerOn = false,
        AntiFling = false,
        AntiAFK = true,
        Spectate = false,
        NotifyRoles = true,
    },
}
getgenv().Novex = Novex

local function track(conn)
    table.insert(Novex.Connections, conn)
    return conn
end

local function cleanup(fn)
    table.insert(Novex.Cleanups, fn)
end

getgenv().NovexHubUnload = function()
    for _, c in ipairs(Novex.Connections) do
        pcall(function() c:Disconnect() end)
    end
    for _, f in ipairs(Novex.Cleanups) do
        pcall(f)
    end
    Novex.Connections = {}
    Novex.Cleanups = {}
    Novex.Flags.CoinFarm = false
    Novex.Flags.Fly = false
    Novex.Flags.GunAim = false
    Novex.Flags.KnifeAim = false
    pcall(function()
        if getgenv().NovexWindow then getgenv().NovexWindow:Destroy() end
    end)
    getgenv().NovexWindow = nil
    getgenv().NovexHubLoaded = false
end

-- ===================== helpers =====================
local function char(p)
    p = p or LP
    return p and p.Character
end

local function hrp(p)
    local c = char(p)
    return c and (c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart)
end

local function hum(p)
    local c = char(p)
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function alive(p)
    local h = hum(p)
    return h ~= nil and h.Health > 0 and hrp(p) ~= nil
end

local function dist(a, b)
    return (a - b).Magnitude
end

local function notify(title, content, dur)
    pcall(function()
        if Novex.WindUI then
            Novex.WindUI:Notify({
                Title = title or "Novex Hub",
                Content = content or "",
                Duration = dur or 3,
                Icon = "bell",
            })
        end
    end)
end

local function findTool(p, name)
    local c = char(p)
    local t = c and c:FindFirstChild(name)
    if t and t:IsA("Tool") then return t end
    local bp = p and p:FindFirstChildOfClass("Backpack")
    t = bp and bp:FindFirstChild(name)
    if t and t:IsA("Tool") then return t end
    return nil
end

local function equip(name)
    local h = hum(LP)
    if not h then return nil end
    local c = char(LP)
    local t = c and c:FindFirstChild(name)
    if t and t:IsA("Tool") then return t end
    local bp = LP:FindFirstChildOfClass("Backpack")
    t = bp and bp:FindFirstChild(name)
    if t and t:IsA("Tool") then
        h:EquipTool(t)
        task.wait(0.12)
        return t
    end
    return nil
end

local function myRole()
    return Novex.Roles[LP] or "Innocent"
end

-- ===================== role tracking =====================
-- GetPlayerData:InvokeServer() returns { [playerName] = { Role = "Murderer"|"Sheriff"|"Hero"|"Innocent"|... } }
-- (resolved by name so it survives the remote moving between folders)
local function refreshRoles()
    local ok, data = pcall(function()
        local rf = ReplicatedStorage:FindFirstChild("GetPlayerData", true)
        if rf and rf:IsA("RemoteFunction") then
            return rf:InvokeServer()
        end
        return nil
    end)
    local seenM, seenS = nil, nil
    if ok and type(data) == "table" then
        for _, p in ipairs(Players:GetPlayers()) do
            local info = data[p.Name]
            local role = "Innocent"
            if type(info) == "table" and info.Role then
                role = tostring(info.Role)
            end
            Novex.Roles[p] = role
            if role == "Murderer" then seenM = p end
            if role == "Sheriff" or role == "Hero" then seenS = p end
        end
    end
    -- tool based fallback (equipped tools replicate on other characters)
    for _, p in ipairs(Players:GetPlayers()) do
        local c = char(p)
        if c then
            if c:FindFirstChild("Knife") then
                Novex.Roles[p] = "Murderer"
                seenM = p
            elseif c:FindFirstChild("Gun") then
                if Novex.Roles[p] ~= "Hero" then Novex.Roles[p] = "Sheriff" end
                seenS = p
            end
        end
    end
    -- own backpack is always readable
    if findTool(LP, "Knife") then Novex.Roles[LP] = "Murderer"; seenM = LP end
    if findTool(LP, "Gun") then
        if Novex.Roles[LP] ~= "Hero" then Novex.Roles[LP] = "Sheriff" end
        seenS = LP
    end
    -- drop dead players from role slots
    if seenM and not alive(seenM) then seenM = nil end
    if seenS and not alive(seenS) then seenS = nil end
    Novex.Murderer = seenM
    Novex.Sheriff = seenS
end

local lastAnnounce = ""
task.spawn(function()
    while getgenv().NovexHubLoaded do
        pcall(refreshRoles)
        if Novex.Flags.NotifyRoles then
            local key = tostring(Novex.Murderer) .. "|" .. tostring(Novex.Sheriff)
            if key ~= lastAnnounce and (Novex.Murderer or Novex.Sheriff) then
                lastAnnounce = key
                notify("Roles", "Murderer: " .. (Novex.Murderer and Novex.Murderer.Name or "?") ..
                    "  |  Sheriff: " .. (Novex.Sheriff and Novex.Sheriff.Name or "?"), 4)
            end
        end
        task.wait(1.5)
    end
end)

-- round reset hooks (resolved by name)
local function bindRemoteByName(name, fn)
    local r = ReplicatedStorage:FindFirstChild(name, true)
    if r and r:IsA("RemoteEvent") then
        track(r.OnClientEvent:Connect(fn))
        return true
    end
    return false
end

bindRemoteByName("RoundEndFade", function()
    Novex.Roles = {}
    Novex.Murderer, Novex.Sheriff = nil, nil
    Novex.Flags.BagFull = false
    lastAnnounce = ""
end)
bindRemoteByName("CoinsStarted", function()
    Novex.Flags.BagFull = false
end)
bindRemoteByName("CoinCollected", function(coinType, current, max)
    if type(current) == "number" and type(max) == "number" and current >= max then
        Novex.Flags.BagFull = true
    end
end)

-- ===================== target selection =====================
local function targetPlayer(role)
    if role == "Murderer" then return Novex.Murderer end
    if role == "Sheriff" then return Novex.Sheriff end
    return nil
end

local function predictedPos(p)
    local r = hrp(p)
    if not r then return nil end
    local v = r.AssemblyLinearVelocity
    return r.Position + Vector3.new(v.X, 0, v.Z) * Novex.Flags.Prediction
end

-- ===================== silent aim hook =====================
-- gun   : RemoteFunction "ShootGun" -> InvokeServer(..., aimPosition, ...)   args[2] is the aim position
-- knife : RemoteEvent    "Throw"    -> FireServer(..., aimPosition)          args[2] is the aim position
-- hooked by NAME so a rename of parent tools doesn't matter. Only the game's own calls are rewritten
-- (checkcaller() is true for calls this script makes itself).
local oldNamecall

-- returns a new args table (with n) when this call should be rewritten, else nil
local function computeRewrite(self, method, args, n)
    if typeof(self) ~= "Instance" then return nil end
    local nm = self.Name
    if nm == "ShootGun" and method == "InvokeServer" then
        if Novex.Flags.GunAim and Novex.Flags.GunAimArmed then
            local tp = Novex.Murderer
            if tp and tp ~= LP and alive(tp) then
                local pos = predictedPos(tp)
                if pos then
                    args[2] = pos
                    return args
                end
            end
        end
    elseif nm == "Throw" and method == "FireServer" then
        if Novex.Flags.KnifeAim and Novex.Flags.KnifeAimArmed then
            local best, bestD = nil, math.huge
            local me = hrp(LP)
            if me then
                for _, p in ipairs(Players:GetPlayers()) do
                    if p ~= LP and alive(p) then
                        local d = dist(hrp(p).Position, me.Position)
                        if p == Novex.Sheriff then d = d * 0.6 end
                        if d < bestD then bestD = d; best = p end
                    end
                end
            end
            if best then
                local pos = predictedPos(best)
                if pos then
                    args[2] = pos
                    return args
                end
            end
        end
    end
    return nil
end

local hookOk = pcall(function()
    assert(hookmetamethod and getnamecallmethod and checkcaller, "missing executor functions")
    local wrap = newcclosure or function(f) return f end
    oldNamecall = hookmetamethod(game, "__namecall", wrap(function(self, ...)
        local method = getnamecallmethod()
        if method == "InvokeServer" or method == "FireServer" then
            local n = select("#", ...)
            local newArgs = nil
            if not checkcaller() then
                local args = { ... }
                local ok, res = pcall(computeRewrite, self, method, args, n)
                if ok and res then newArgs = res end
            end
            -- inner namecalls above can clobber the namecall state, so restore it
            if setnamecallmethod then setnamecallmethod(method) end
            if newArgs then
                return oldNamecall(self, unpack(newArgs, 1, math.max(n, 2)))
            end
            return oldNamecall(self, ...)
        end
        return oldNamecall(self, ...)
    end))
end)
if not hookOk then
    warn("[Novex] hookmetamethod unavailable, silent aim disabled (direct fire buttons still work)")
end

-- ===================== highlights / ESP =====================
local ESPFolder = Instance.new("Folder")
ESPFolder.Name = "NovexESP"
local espOk = pcall(function() ESPFolder.Parent = CoreGui end)
if not espOk or not ESPFolder.Parent then
    ESPFolder.Parent = LP:WaitForChild("PlayerGui")
end
cleanup(function() ESPFolder:Destroy() end)

local ROLE_COLORS = {
    Murderer = Color3.fromRGB(255, 60, 60),
    Sheriff = Color3.fromRGB(70, 130, 255),
    Hero = Color3.fromRGB(255, 220, 60),
    Innocent = Color3.fromRGB(90, 255, 140),
}

local espObjects = {} -- [Player] = { hl = Highlight, bb = BillboardGui, label = TextLabel }

local function makeESP(p)
    local o = {}
    local hl = Instance.new("Highlight")
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.FillTransparency = 0.55
    hl.OutlineTransparency = 0
    hl.Parent = ESPFolder
    o.hl = hl
    local bb = Instance.new("BillboardGui")
    bb.Size = UDim2.fromOffset(160, 36)
    bb.StudsOffset = Vector3.new(0, 3.2, 0)
    bb.AlwaysOnTop = true
    bb.Parent = ESPFolder
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.fromScale(1, 1)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 13
    lbl.TextStrokeTransparency = 0.4
    lbl.TextColor3 = Color3.new(1, 1, 1)
    lbl.Parent = bb
    o.bb = bb
    o.label = lbl
    espObjects[p] = o
    return o
end

local function clearESP(p)
    local o = espObjects[p]
    if o then
        pcall(function() o.hl:Destroy() end)
        pcall(function() o.bb:Destroy() end)
        espObjects[p] = nil
    end
end

track(Players.PlayerRemoving:Connect(clearESP))

-- target visuals (beam + marker) for Target Murderer / Target Sheriff
local targetMarks = {} -- [role] = { hl, bb, beam, a0, a1 }

local function clearTargetMark(role)
    local m = targetMarks[role]
    if m then
        for _, k in pairs(m) do pcall(function() k:Destroy() end) end
        targetMarks[role] = nil
    end
end

local function ensureTargetMark(role, p)
    local m = targetMarks[role]
    if m and m.hl and m.hl.Adornee == char(p) then return m end
    clearTargetMark(role)
    local c = char(p)
    local me = hrp(LP)
    local tr = hrp(p)
    if not (c and me and tr) then return nil end
    m = {}
    local col = role == "Murderer" and Color3.fromRGB(255, 0, 80) or Color3.fromRGB(0, 170, 255)
    local hl = Instance.new("Highlight")
    hl.Adornee = c
    hl.FillColor = col
    hl.OutlineColor = Color3.new(1, 1, 1)
    hl.FillTransparency = 0.3
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = ESPFolder
    m.hl = hl
    local bb = Instance.new("BillboardGui")
    bb.Adornee = tr
    bb.Size = UDim2.fromOffset(200, 40)
    bb.StudsOffset = Vector3.new(0, 4.6, 0)
    bb.AlwaysOnTop = true
    bb.Parent = ESPFolder
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.fromScale(1, 1)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamBlack
    lbl.TextSize = 15
    lbl.TextColor3 = col
    lbl.TextStrokeTransparency = 0
    lbl.Text = "TARGET: " .. string.upper(role)
    lbl.Parent = bb
    m.bb = bb
    local a0 = Instance.new("Attachment")
    a0.Parent = me
    local a1 = Instance.new("Attachment")
    a1.Parent = tr
    local beam = Instance.new("Beam")
    beam.Attachment0 = a0
    beam.Attachment1 = a1
    beam.Width0 = 0.15
    beam.Width1 = 0.15
    beam.FaceCamera = true
    beam.Color = ColorSequence.new(col)
    beam.LightEmission = 1
    beam.Parent = me
    m.a0, m.a1, m.beam = a0, a1, beam
    targetMarks[role] = m
    return m
end

cleanup(function()
    for role, _ in pairs(targetMarks) do clearTargetMark(role) end
end)

-- gun drop ESP
local gunMark = nil
local lastGunSeen = false
local function clearGunMark()
    if gunMark then
        for _, k in pairs(gunMark) do pcall(function() k:Destroy() end) end
        gunMark = nil
    end
end
cleanup(clearGunMark)

local function findGunDrop()
    return Workspace:FindFirstChild("GunDrop")
end

-- main ESP / target / gun drop loop (cheap, 6 Hz)
task.spawn(function()
    while getgenv().NovexHubLoaded do
        -- player ESP
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then
                if Novex.Flags.ESP and alive(p) then
                    local o = espObjects[p] or makeESP(p)
                    local role = Novex.Roles[p] or "Innocent"
                    local col = ROLE_COLORS[role] or ROLE_COLORS.Innocent
                    o.hl.Adornee = char(p)
                    o.hl.FillColor = col
                    o.hl.OutlineColor = col
                    o.bb.Adornee = hrp(p)
                    local me = hrp(LP)
                    local d = me and math.floor(dist(me.Position, hrp(p).Position)) or 0
                    o.label.Text = p.DisplayName .. " [" .. role .. "] " .. d .. "m"
                    o.label.TextColor3 = col
                else
                    clearESP(p)
                end
            end
        end
        -- targets
        for _, role in ipairs({ "Murderer", "Sheriff" }) do
            local on = (role == "Murderer" and Novex.Flags.TargetMurderer) or (role == "Sheriff" and Novex.Flags.TargetSheriff)
            local tp = targetPlayer(role)
            if on and tp and tp ~= LP and alive(tp) then
                ensureTargetMark(role, tp)
            else
                clearTargetMark(role)
            end
        end
        -- dropped gun
        local gd = findGunDrop()
        if gd and Novex.Flags.GunESP then
            if not gunMark or gunMark.hl.Adornee ~= gd then
                clearGunMark()
                gunMark = {}
                local hl = Instance.new("Highlight")
                hl.Adornee = gd
                hl.FillColor = Color3.fromRGB(255, 230, 0)
                hl.OutlineColor = Color3.new(1, 1, 1)
                hl.FillTransparency = 0.2
                hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                hl.Parent = ESPFolder
                gunMark.hl = hl
                local bb = Instance.new("BillboardGui")
                bb.Adornee = gd
                bb.Size = UDim2.fromOffset(150, 32)
                bb.StudsOffset = Vector3.new(0, 3, 0)
                bb.AlwaysOnTop = true
                bb.Parent = ESPFolder
                local lbl = Instance.new("TextLabel")
                lbl.Size = UDim2.fromScale(1, 1)
                lbl.BackgroundTransparency = 1
                lbl.Font = Enum.Font.GothamBlack
                lbl.TextSize = 15
                lbl.TextColor3 = Color3.fromRGB(255, 230, 0)
                lbl.TextStrokeTransparency = 0
                lbl.Text = "GUN DROPPED"
                lbl.Parent = bb
                gunMark.bb = bb
            end
        else
            clearGunMark()
        end
        if gd and not lastGunSeen then
            notify("Gun", "Sheriff died - gun dropped!", 4)
        end
        lastGunSeen = gd ~= nil
        task.wait(0.16)
    end
end)

-- ===================== movement helpers =====================
local function tpTo(cf)
    local r = hrp(LP)
    if r then
        r.CFrame = cf
        r.AssemblyLinearVelocity = Vector3.zero
    end
end

local function tpBehind(p, back, up)
    local tr = hrp(p)
    if not tr then return false end
    tpTo(tr.CFrame * CFrame.new(0, up or 0, back or 3))
    return true
end

local function tpToRole(role)
    local p = targetPlayer(role)
    if not p or p == LP or not alive(p) then
        notify("TP", role .. " not found right now", 2)
        return
    end
    tpBehind(p, 3, 0)
end

local function tpToGun()
    local gd = findGunDrop()
    if not gd then
        notify("Gun", "no dropped gun right now", 2)
        return false
    end
    local pos = gd:IsA("BasePart") and gd.CFrame or (gd:IsA("Model") and gd:GetPivot()) or nil
    if not pos then return false end
    tpTo(pos + Vector3.new(0, 2, 0))
    return true
end

-- noclip
track(RunService.Stepped:Connect(function()
    local farming = Novex.Flags.CoinFarm
    if Novex.Flags.Noclip or farming or Novex.Flags.Fly then
        local c = char(LP)
        if c then
            for _, part in ipairs(c:GetDescendants()) do
                if part:IsA("BasePart") and part.CanCollide then
                    part.CanCollide = false
                end
            end
        end
    end
end))

-- walk speed / jump power / infinite jump
track(RunService.Heartbeat:Connect(function()
    local h = hum(LP)
    if h then
        if Novex.Flags.WalkSpeedOn then h.WalkSpeed = Novex.Flags.WalkSpeed end
        if Novex.Flags.JumpPowerOn then
            h.UseJumpPower = true
            h.JumpPower = Novex.Flags.JumpPower
        end
    end
end))

track(UserInputService.JumpRequest:Connect(function()
    if Novex.Flags.InfJump then
        local h = hum(LP)
        if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end))

-- anti afk
track(LP.Idled:Connect(function()
    if Novex.Flags.AntiAFK then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new(0, 0))
        end)
    end
end))

-- anti fling (zero crazy velocities on own character)
track(RunService.Heartbeat:Connect(function()
    if Novex.Flags.AntiFling and not Novex.Flinging then
        local r = hrp(LP)
        if r then
            local v = r.AssemblyLinearVelocity
            if v.Magnitude > 250 then
                r.AssemblyLinearVelocity = Vector3.zero
                r.AssemblyAngularVelocity = Vector3.zero
            end
        end
    end
end))

-- fly (mobile friendly: joystick = MoveDirection, camera look = vertical)
local flyBV, flyBG
local function stopFly()
    Novex.Flags.Fly = false
    if flyBV then flyBV:Destroy(); flyBV = nil end
    if flyBG then flyBG:Destroy(); flyBG = nil end
    local h = hum(LP)
    if h then h.PlatformStand = false end
end
cleanup(stopFly)

local function startFly()
    local r = hrp(LP)
    local h = hum(LP)
    if not r or not h then return end
    stopFly()
    Novex.Flags.Fly = true
    flyBV = Instance.new("BodyVelocity")
    flyBV.MaxForce = Vector3.new(1e9, 1e9, 1e9)
    flyBV.Velocity = Vector3.zero
    flyBV.Parent = r
    flyBG = Instance.new("BodyGyro")
    flyBG.MaxTorque = Vector3.new(1e9, 1e9, 1e9)
    flyBG.P = 9e4
    flyBG.CFrame = r.CFrame
    flyBG.Parent = r
    h.PlatformStand = true
end

track(RunService.RenderStepped:Connect(function()
    if Novex.Flags.Fly and flyBV and flyBG then
        local h = hum(LP)
        local r = hrp(LP)
        if not h or not r then return end
        local cam = Workspace.CurrentCamera
        local md = h.MoveDirection
        local look = cam.CFrame.LookVector
        local right = cam.CFrame.RightVector
        local dir = Vector3.zero
        local flatLook = Vector3.new(look.X, 0, look.Z)
        local flatRight = Vector3.new(right.X, 0, right.Z)
        if md.Magnitude > 0 and flatLook.Magnitude > 0.001 and flatRight.Magnitude > 0.001 then
            -- project joystick onto the camera so pushing "forward" flies where you look (incl. up/down)
            local fwd = md:Dot(flatLook.Unit)
            local side = md:Dot(flatRight.Unit)
            dir = look * fwd + right * side
        end
        flyBV.Velocity = dir * Novex.Flags.FlySpeed
        flyBG.CFrame = cam.CFrame
    end
end))

-- ===================== fling =====================
Novex.Flinging = false
local function flingPlayer(p, duration)
    if Novex.Flinging then return end
    if not p or p == LP or not alive(p) or not alive(LP) then
        notify("Fling", "target not available", 2)
        return
    end
    Novex.Flinging = true
    local r = hrp(LP)
    local origin = r.CFrame
    local t0 = tick()
    duration = duration or 3
    local conn
    conn = RunService.Heartbeat:Connect(function()
        local tr = hrp(p)
        r = hrp(LP)
        if not tr or not r or tick() - t0 > duration or not alive(p) then
            conn:Disconnect()
            return
        end
        local v = tr.AssemblyLinearVelocity
        r.CFrame = tr.CFrame * CFrame.new(0, 0, 0) + v * 0.05
        r.AssemblyLinearVelocity = Vector3.new(9e5, 9e5, 9e5)
        r.AssemblyAngularVelocity = Vector3.new(9e5, 9e5, 9e5)
    end)
    while conn.Connected and Novex.Flinging do
        task.wait(0.05)
    end
    pcall(function()
        local rr = hrp(LP)
        if rr then
            rr.AssemblyLinearVelocity = Vector3.zero
            rr.AssemblyAngularVelocity = Vector3.zero
            rr.CFrame = origin
        end
    end)
    Novex.Flinging = false
    notify("Fling", "done on " .. p.Name, 2)
end

-- ===================== coin farm =====================
local cachedCC, cachedCCTime = nil, 0
local function findCoinContainer()
    if cachedCC and cachedCC.Parent then return cachedCC end
    if tick() - cachedCCTime < 1 then return nil end
    cachedCCTime = tick()
    cachedCC = Workspace:FindFirstChild("CoinContainer", true)
    return cachedCC
end

local function coinCollectable(c)
    return c and c.Parent and c.Name == "Coin_Server" and c:FindFirstChildOfClass("TouchTransmitter") ~= nil
end

local function nearestCoin(blacklist)
    local cc = findCoinContainer()
    local me = hrp(LP)
    if not cc or not me then return nil end
    local best, bestD = nil, math.huge
    for _, c in ipairs(cc:GetChildren()) do
        if c.Name == "Coin_Server" and c:IsA("BasePart") and not blacklist[c] and coinCollectable(c) then
            local d = dist(c.Position, me.Position)
            if d < bestD then bestD = d; best = c end
        end
    end
    return best
end

local function moveToCoin(coin)
    local r = hrp(LP)
    if not r then return end
    local target = coin.CFrame
    if Novex.Flags.FarmMode == "Instant" then
        r.CFrame = target
        r.AssemblyLinearVelocity = Vector3.zero
        return
    end
    local d = dist(r.Position, coin.Position)
    local speed = math.max(Novex.Flags.FarmSpeed, 5)
    local tm = d / speed
    if tm <= 0.05 then
        r.CFrame = target
        return
    end
    local tw = TweenService:Create(r, TweenInfo.new(tm, Enum.EasingStyle.Linear), { CFrame = target })
    tw:Play()
    local t0 = tick()
    while tick() - t0 < tm + 0.1 and Novex.Flags.CoinFarm and coinCollectable(coin) do
        r.AssemblyLinearVelocity = Vector3.zero
        task.wait()
    end
    pcall(function() tw:Cancel() end)
end

local farmThread = nil
local function startCoinFarm()
    if farmThread then return end
    farmThread = task.spawn(function()
        local blacklist = {}
        local fails = 0
        local lastCoinTime = tick()
        while Novex.Flags.CoinFarm and getgenv().NovexHubLoaded do
            if not alive(LP) then
                blacklist = {}
                task.wait(1)
            elseif Novex.Flags.BagFull then
                if Novex.Flags.FarmResetFull then
                    local h = hum(LP)
                    if h then h.Health = 0 end
                    Novex.Flags.BagFull = false
                    task.wait(3)
                else
                    task.wait(1)
                end
            else
                local coin = nearestCoin(blacklist)
                if coin then
                    moveToCoin(coin)
                    -- wait for it to be consumed; otherwise skip it
                    local t0 = tick()
                    while Novex.Flags.CoinFarm and coinCollectable(coin) and tick() - t0 < 1.2 do
                        local r = hrp(LP)
                        if r then r.CFrame = coin.CFrame end
                        task.wait(0.05)
                    end
                    if coinCollectable(coin) then
                        blacklist[coin] = true
                        fails = fails + 1
                        if fails >= 3 then
                            -- coins stopped counting: bag is full
                            Novex.Flags.BagFull = true
                            fails = 0
                        end
                    else
                        fails = 0
                    end
                    lastCoinTime = tick()
                else
                    if not findCoinContainer() then
                        -- no round running: reset everything
                        Novex.Flags.BagFull = false
                        blacklist = {}
                        fails = 0
                    end
                    if tick() - lastCoinTime > 20 then blacklist = {} end
                    task.wait(0.4)
                end
            end
            task.wait()
        end
        farmThread = nil
    end)
end

-- ===================== knife / gun actions =====================
local function killAllAsMurderer()
    if myRole() ~= "Murderer" then
        notify("Kill All", "you're not the murderer this round", 3)
        return
    end
    local knife = equip("Knife")
    if not knife then
        notify("Kill All", "knife not found", 2)
        return
    end
    local origin = hrp(LP) and hrp(LP).CFrame
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and alive(p) and getgenv().NovexHubLoaded then
            for i = 1, 6 do
                if not alive(p) or not alive(LP) then break end
                tpBehind(p, 2, 0)
                pcall(function() knife:Activate() end)
                pcall(function()
                    local tr = hrp(p)
                    local handle = knife:FindFirstChild("Handle")
                    if tr and handle and firetouchinterest then
                        firetouchinterest(tr, handle, 1)
                        firetouchinterest(tr, handle, 0)
                    end
                end)
                local stab = knife:FindFirstChild("Stab")
                if stab and stab:IsA("RemoteEvent") then
                    pcall(function() stab:FireServer("Slash") end)
                end
                task.wait(0.12)
            end
        end
    end
    if origin then tpTo(origin) end
end

-- kill aura / reach (murderer)
track(RunService.Heartbeat:Connect(function()
    if not Novex.Flags.KillAura or myRole() ~= "Murderer" then return end
    local c = char(LP)
    local knife = c and c:FindFirstChild("Knife")
    local me = hrp(LP)
    if not (knife and me) then return end
    local handle = knife:FindFirstChild("Handle")
    if not handle or not firetouchinterest then return end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and alive(p) then
            local tr = hrp(p)
            if dist(tr.Position, me.Position) <= Novex.Flags.KillAuraRange then
                pcall(function()
                    firetouchinterest(tr, handle, 1)
                    firetouchinterest(tr, handle, 0)
                end)
            end
        end
    end
end))

-- direct shoot at the murderer (sheriff). equips gun and activates it; the namecall hook above
-- rewrites the aim position so we don't depend on the remote's argument layout.
local function shootMurderer()
    local m = Novex.Murderer
    if not m or m == LP or not alive(m) then
        notify("Gun", "murderer not found", 2)
        return
    end
    local gun = equip("Gun")
    if not gun then
        notify("Gun", "you don't have the gun", 2)
        return
    end
    local prev = Novex.Flags.GunAim
    local prevArm = Novex.Flags.GunAimArmed
    Novex.Flags.GunAim = true
    Novex.Flags.GunAimArmed = true
    -- face the target so the game's own mouse/camera aim is also close
    local me, tr = hrp(LP), hrp(m)
    if me and tr then
        me.CFrame = CFrame.new(me.Position, Vector3.new(tr.Position.X, me.Position.Y, tr.Position.Z))
    end
    pcall(function() gun:Activate() end)
    task.wait(0.35)
    Novex.Flags.GunAim = prev
    Novex.Flags.GunAimArmed = prevArm
end

-- direct knife throw at nearest/sheriff (murderer). Tries the hook path (tool:Activate is a stab,
-- so we fire the Throw remote ourselves with (CFrame, position)). Layout verified from public MM2
-- scripts: Throw:FireServer(<cf>, <Vector3 aim>).
local function throwKnifeAtTarget(p)
    if myRole() ~= "Murderer" then
        notify("Knife", "you're not the murderer", 2)
        return
    end
    local knife = equip("Knife")
    if not knife then notify("Knife", "knife not found", 2); return end
    if not p then p = Novex.Sheriff end
    if not p or not alive(p) then
        local best, bestD = nil, math.huge
        local me = hrp(LP)
        for _, q in ipairs(Players:GetPlayers()) do
            if q ~= LP and alive(q) and me then
                local d = dist(hrp(q).Position, me.Position)
                if d < bestD then bestD = d; best = q end
            end
        end
        p = best
    end
    if not p then notify("Knife", "no target", 2); return end
    local pos = predictedPos(p)
    local me = hrp(LP)
    local throw = knife:FindFirstChild("Throw", true)
    if throw and throw:IsA("RemoteEvent") and pos and me then
        pcall(function()
            throw:FireServer(CFrame.new(me.Position, pos), pos)
        end)
    else
        notify("Knife", "Throw remote not found (game updated?)", 3)
    end
end

-- ===================== on-screen circle buttons =====================
local ButtonGui = Instance.new("ScreenGui")
ButtonGui.Name = "NovexButtons"
ButtonGui.ResetOnSpawn = false
ButtonGui.IgnoreGuiInset = true
ButtonGui.DisplayOrder = 50
pcall(function()
    if gethui then ButtonGui.Parent = gethui() else ButtonGui.Parent = CoreGui end
end)
if not ButtonGui.Parent then ButtonGui.Parent = CoreGui end
cleanup(function() ButtonGui:Destroy() end)

local function makeCircle(name, text, pos, color, onTap)
    local b = Instance.new("TextButton")
    b.Name = name
    b.Size = UDim2.fromOffset(64, 64)
    b.Position = pos
    b.BackgroundColor3 = color
    b.BackgroundTransparency = 0.15
    b.AutoButtonColor = false
    b.Text = text
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBlack
    b.TextSize = 12
    b.TextWrapped = true
    b.Visible = false
    b.Parent = ButtonGui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = b
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 2.5
    stroke.Color = Color3.new(1, 1, 1)
    stroke.Parent = b

    -- drag + tap
    local dragging, dragStart, startPos, moved = false, nil, nil, false
    track(b.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            moved = false
            dragStart = input.Position
            startPos = b.Position
        end
    end))
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement) then
            local d = input.Position - dragStart
            if d.Magnitude > 8 then moved = true end
            if moved then
                b.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1) then
            dragging = false
            if not moved then onTap() end
        end
    end))
    return b
end

local gunCircle, knifeCircle

local function refreshCircles()
    if gunCircle then
        gunCircle.Visible = Novex.Flags.GunAim
        local armed = Novex.Flags.GunAimArmed
        gunCircle.BackgroundColor3 = armed and Color3.fromRGB(40, 120, 255) or Color3.fromRGB(70, 70, 80)
        gunCircle.Text = armed and "GUN\nAIM\nON" or "GUN\nAIM\nOFF"
    end
    if knifeCircle then
        knifeCircle.Visible = Novex.Flags.KnifeAim
        local armed = Novex.Flags.KnifeAimArmed
        knifeCircle.BackgroundColor3 = armed and Color3.fromRGB(255, 60, 80) or Color3.fromRGB(70, 70, 80)
        knifeCircle.Text = armed and "KNIFE\nAIM\nON" or "KNIFE\nAIM\nOFF"
    end
end

gunCircle = makeCircle("GunAimCircle", "GUN", UDim2.new(1, -90, 0.5, -90), Color3.fromRGB(40, 120, 255), function()
    Novex.Flags.GunAimArmed = not Novex.Flags.GunAimArmed
    refreshCircles()
end)
knifeCircle = makeCircle("KnifeAimCircle", "KNIFE", UDim2.new(1, -90, 0.5, -10), Color3.fromRGB(255, 60, 80), function()
    Novex.Flags.KnifeAimArmed = not Novex.Flags.KnifeAimArmed
    refreshCircles()
end)

-- circle label shows who it's locked on
track(RunService.Heartbeat:Connect(function()
    if gunCircle and gunCircle.Visible and Novex.Flags.GunAimArmed then
        local m = Novex.Murderer
        gunCircle.Text = "GUN\n" .. (m and string.sub(m.Name, 1, 8) or "no target")
    end
    if knifeCircle and knifeCircle.Visible and Novex.Flags.KnifeAimArmed then
        knifeCircle.Text = "KNIFE\nAIM ON"
    end
end))

-- ===================== misc world =====================
local origLighting = {
    Brightness = Lighting.Brightness,
    ClockTime = Lighting.ClockTime,
    FogEnd = Lighting.FogEnd,
    GlobalShadows = Lighting.GlobalShadows,
    Ambient = Lighting.Ambient,
}
local function setFullbright(on)
    if on then
        Lighting.Brightness = 2
        Lighting.ClockTime = 14
        Lighting.FogEnd = 1e6
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(180, 180, 180)
    else
        for k, v in pairs(origLighting) do pcall(function() Lighting[k] = v end) end
    end
end
cleanup(function() setFullbright(false) end)

local function spectate(on)
    local target = Novex.Murderer or Novex.Sheriff
    if on and target and alive(target) then
        Workspace.CurrentCamera.CameraSubject = hum(target)
    else
        local h = hum(LP)
        if h then Workspace.CurrentCamera.CameraSubject = h end
    end
end

-- ===================== emote loader =====================
local emoteLoaded = false
local function patchEmote(src)
    -- rebrand display strings, folders and identifiers, but NEVER touch URLs (those need the real 7yd7 host)
    src = src:gsub("7yd7 | ", "Novex Hub | ")
    src = src:gsub("7yd7_", "NovexHub_")
    src = src:gsub('"7yd7/', '"NovexHub/')
    src = src:gsub('"7yd7"', '"NovexHub"')
    src = src:gsub("Script loading%.%.%.", "Novex Hub Emote loading...")
    -- hide the original dev's discord button / promo (their invite, not yours)
    src = src:gsub("DiscordVisible = true", "DiscordVisible = false")
    src = src:gsub('"https://discord%.gg/kRfzv2kV7X"', 'tostring(getgenv().NovexDiscord or "")')
    src = src:gsub('(local DiscordPromo = SettingsLib%.AddItem%(ThemeTab, "WANT THEMES%?", "Join our Discord for themes!"%))',
        "%1\nDiscordPromo.Visible = false")
    return src
end

local function loadEmotes()
    if emoteLoaded then
        notify("Emote", "already loaded - open the emote wheel (period key / on-screen button)", 3)
        return
    end
    local src
    pcall(function()
        if isfile and isfile("NovexHub/Emote.lua") then
            src = readfile("NovexHub/Emote.lua")
        end
    end)
    if not src and getgenv().NovexEmoteURL then
        local ok, res = pcall(function() return game:HttpGet(getgenv().NovexEmoteURL) end)
        if ok then src = res end
    end
    if not src or src == "" then
        notify("Emote", "put your emote script at workspace/NovexHub/Emote.lua (or set getgenv().NovexEmoteURL)", 6)
        return
    end
    src = patchEmote(src)
    local fn, err = loadstring(src)
    if not fn then
        notify("Emote", "emote script failed to parse: " .. tostring(err), 6)
        return
    end
    emoteLoaded = true
    local ok, res = pcall(fn)
    if not ok then
        emoteLoaded = false
        notify("Emote", "emote script errored: " .. tostring(res), 6)
        return
    end
    notify("Novex Hub | Emote", "Novex Hub Emote loaded", 5)
end

-- ===================== WindUI =====================
local function loadWindUI()
    local urls = {
        "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua",
        "https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua",
    }
    for _, u in ipairs(urls) do
        local ok, lib = pcall(function() return loadstring(game:HttpGet(u))() end)
        if ok and lib then return lib end
    end
    return nil
end

local WindUI = loadWindUI()
if not WindUI then
    warn("[Novex] WindUI failed to load (check your connection / executor HttpGet)")
    return
end
Novex.WindUI = WindUI

local Window = WindUI:CreateWindow({
    Title = "Novex Hub",
    Author = "Murder Mystery 2",
    Folder = "NovexHub",
    Icon = "swords",
    Theme = "Dark",
    Size = UDim2.fromOffset(620, 460),
    Transparent = true,
    NewElements = true,
    ToggleKey = Enum.KeyCode.RightShift,
    OpenButton = {
        Title = "Novex Hub",
        Enabled = true,
        Draggable = true,
        CornerRadius = UDim.new(1, 0),
        StrokeThickness = 3,
        Color = ColorSequence.new(Color3.fromHex("#7b5cff"), Color3.fromHex("#00d4ff")),
    },
})

if not Window then
    warn("[Novex] CreateWindow returned nil (a WindUI window already exists?)")
    return
end
getgenv().NovexWindow = Window

Window:Tag({ Title = "MM2", Icon = "skull", Color = Color3.fromHex("#7b5cff") })

-- ---------- Main ----------
local Main = Window:Tab({ Title = "Main", Icon = "home" })

Main:Section({ Title = "Auto Farm" })
Main:Toggle({
    Title = "Farm Coins",
    Desc = "Collects coins; stops when your bag is full",
    Value = false,
    Callback = function(v)
        Novex.Flags.CoinFarm = v
        if v then startCoinFarm() end
    end,
})
Main:Dropdown({
    Title = "Farm Mode",
    Values = { "Tween", "Instant" },
    Value = "Tween",
    Callback = function(v) Novex.Flags.FarmMode = v end,
})
Main:Slider({
    Title = "Farm Speed (studs/s)",
    Step = 1,
    Value = { Min = 10, Max = 80, Default = 28 },
    Callback = function(v) Novex.Flags.FarmSpeed = v end,
})
Main:Toggle({
    Title = "Reset When Bag Full",
    Desc = "Respawn to skip the round once you're full",
    Value = true,
    Callback = function(v) Novex.Flags.FarmResetFull = v end,
})

Main:Section({ Title = "Roles" })
Main:Toggle({
    Title = "Announce Roles",
    Desc = "Pop a notification when murderer/sheriff are known",
    Value = true,
    Callback = function(v) Novex.Flags.NotifyRoles = v end,
})
Main:Button({
    Title = "Show Roles Now",
    Icon = "eye",
    Callback = function()
        refreshRoles()
        notify("Roles", "Murderer: " .. (Novex.Murderer and Novex.Murderer.Name or "?") ..
            "  |  Sheriff: " .. (Novex.Sheriff and Novex.Sheriff.Name or "?"), 5)
    end,
})
Main:Toggle({
    Title = "Auto Grab Gun",
    Desc = "Innocent only: grabs a dropped gun and comes back",
    Value = false,
    Callback = function(v) Novex.Flags.AutoGun = v end,
})

-- auto grab gun loop
local grabbing = false
task.spawn(function()
    while getgenv().NovexHubLoaded do
        if Novex.Flags.AutoGun and not grabbing and myRole() == "Innocent" and alive(LP) then
            local gd = findGunDrop()
            if gd then
                grabbing = true
                local back = hrp(LP) and hrp(LP).CFrame
                local t0 = tick()
                while Novex.Flags.AutoGun and findGunDrop() and tick() - t0 < 4 and alive(LP) do
                    tpToGun()
                    task.wait(0.1)
                end
                if back then tpTo(back) end
                grabbing = false
            end
        end
        task.wait(0.4)
    end
end)

-- ---------- Combat ----------
local Combat = Window:Tab({ Title = "Combat", Icon = "crosshair" })

Combat:Section({ Title = "Gun Aimbot (sheriff)" })
Combat:Toggle({
    Title = "Gun Aimbot",
    Desc = "Shows a circle button. While it's ON, any shot you take redirects to the murderer",
    Value = false,
    Callback = function(v)
        Novex.Flags.GunAim = v
        Novex.Flags.GunAimArmed = true
        refreshCircles()
        if v and not hookOk then
            notify("Gun Aimbot", "your executor has no hookmetamethod - use Shoot Murderer button", 5)
        end
    end,
})
Combat:Slider({
    Title = "Prediction",
    Desc = "Lead the target (seconds)",
    Step = 0.01,
    Value = { Min = 0, Max = 0.4, Default = 0.12 },
    Callback = function(v) Novex.Flags.Prediction = v end,
})
Combat:Button({
    Title = "Shoot Murderer",
    Icon = "target",
    Callback = shootMurderer,
})

Combat:Section({ Title = "Knife Aimbot (murderer)" })
Combat:Toggle({
    Title = "Knife Aimbot",
    Desc = "Shows a circle button. While it's ON, your throw goes to the nearest player (sheriff first)",
    Value = false,
    Callback = function(v)
        Novex.Flags.KnifeAim = v
        Novex.Flags.KnifeAimArmed = true
        refreshCircles()
    end,
})
Combat:Button({
    Title = "Throw Knife At Sheriff",
    Icon = "send",
    Callback = function() throwKnifeAtTarget(Novex.Sheriff) end,
})
Combat:Button({
    Title = "Throw Knife At Nearest",
    Icon = "send",
    Callback = function() throwKnifeAtTarget(nil) end,
})

Combat:Section({ Title = "Murderer Tools" })
Combat:Button({
    Title = "Kill All",
    Icon = "skull",
    Callback = function() task.spawn(killAllAsMurderer) end,
})
Combat:Toggle({
    Title = "Kill Aura (reach)",
    Value = false,
    Callback = function(v) Novex.Flags.KillAura = v end,
})
Combat:Slider({
    Title = "Kill Aura Range",
    Step = 1,
    Value = { Min = 5, Max = 40, Default = 12 },
    Callback = function(v) Novex.Flags.KillAuraRange = v end,
})

-- ---------- Target ----------
local TargetTab = Window:Tab({ Title = "Target", Icon = "locate" })

TargetTab:Section({ Title = "Lock On" })
TargetTab:Toggle({
    Title = "Target Murderer",
    Desc = "Highlight + beam + label on the murderer",
    Value = false,
    Callback = function(v) Novex.Flags.TargetMurderer = v end,
})
TargetTab:Toggle({
    Title = "Target Sheriff",
    Desc = "Highlight + beam + label on the sheriff",
    Value = false,
    Callback = function(v) Novex.Flags.TargetSheriff = v end,
})
TargetTab:Toggle({
    Title = "Spectate Murderer/Sheriff",
    Value = false,
    Callback = function(v)
        Novex.Flags.Spectate = v
        spectate(v)
    end,
})

TargetTab:Section({ Title = "Teleport" })
TargetTab:Button({ Title = "TP To Murderer", Icon = "navigation", Callback = function() tpToRole("Murderer") end })
TargetTab:Button({ Title = "TP To Sheriff", Icon = "navigation", Callback = function() tpToRole("Sheriff") end })
TargetTab:Button({
    Title = "TP To Gun",
    Icon = "navigation",
    Callback = function()
        local back = hrp(LP) and hrp(LP).CFrame
        if tpToGun() then
            task.wait(0.6)
            if back then tpTo(back) end
        end
    end,
})
TargetTab:Button({
    Title = "TP To Gun (stay)",
    Icon = "navigation",
    Callback = function() tpToGun() end,
})

TargetTab:Section({ Title = "Fling" })
TargetTab:Button({
    Title = "Fling Murderer",
    Icon = "wind",
    Callback = function() task.spawn(flingPlayer, Novex.Murderer, 3) end,
})
TargetTab:Button({
    Title = "Fling Sheriff",
    Icon = "wind",
    Callback = function() task.spawn(flingPlayer, Novex.Sheriff, 3) end,
})

local selectedName = nil
local function playerNames()
    local t = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then table.insert(t, p.Name) end
    end
    if #t == 0 then t = { "(nobody)" } end
    return t
end
local playerDrop = TargetTab:Dropdown({
    Title = "Pick Player",
    Values = playerNames(),
    Value = playerNames()[1],
    Callback = function(v) selectedName = v end,
})
TargetTab:Button({
    Title = "Refresh Player List",
    Icon = "refresh-cw",
    Callback = function()
        pcall(function() playerDrop:Refresh(playerNames()) end)
    end,
})
TargetTab:Button({
    Title = "TP To Picked",
    Icon = "navigation",
    Callback = function()
        local p = selectedName and Players:FindFirstChild(selectedName)
        if p and alive(p) then tpBehind(p, 3, 0) end
    end,
})
TargetTab:Button({
    Title = "Fling Picked",
    Icon = "wind",
    Callback = function()
        local p = selectedName and Players:FindFirstChild(selectedName)
        if p then task.spawn(flingPlayer, p, 3) end
    end,
})

-- ---------- Visuals ----------
local Visuals = Window:Tab({ Title = "Visuals", Icon = "eye" })
Visuals:Toggle({
    Title = "Player ESP",
    Desc = "Red = murderer, blue = sheriff, yellow = hero, green = innocent",
    Value = false,
    Callback = function(v) Novex.Flags.ESP = v end,
})
Visuals:Toggle({
    Title = "ESP Dropped Gun",
    Desc = "Highlights the gun the moment the sheriff dies",
    Value = false,
    Callback = function(v) Novex.Flags.GunESP = v end,
})
Visuals:Toggle({
    Title = "Fullbright",
    Value = false,
    Callback = setFullbright,
})
Visuals:Slider({
    Title = "Field Of View",
    Step = 1,
    Value = { Min = 60, Max = 120, Default = 70 },
    Callback = function(v)
        pcall(function() Workspace.CurrentCamera.FieldOfView = v end)
    end,
})

-- ---------- Player ----------
local PlayerTab = Window:Tab({ Title = "Player", Icon = "user" })
PlayerTab:Toggle({
    Title = "Walk Speed",
    Value = false,
    Callback = function(v)
        Novex.Flags.WalkSpeedOn = v
        if not v then
            local h = hum(LP)
            if h then h.WalkSpeed = 16 end
        end
    end,
})
PlayerTab:Slider({
    Title = "Speed Value",
    Step = 1,
    Value = { Min = 16, Max = 120, Default = 30 },
    Callback = function(v) Novex.Flags.WalkSpeed = v end,
})
PlayerTab:Toggle({
    Title = "Jump Power",
    Value = false,
    Callback = function(v)
        Novex.Flags.JumpPowerOn = v
        if not v then
            local h = hum(LP)
            if h then h.JumpPower = 50 end
        end
    end,
})
PlayerTab:Slider({
    Title = "Jump Value",
    Step = 1,
    Value = { Min = 50, Max = 200, Default = 80 },
    Callback = function(v) Novex.Flags.JumpPower = v end,
})
PlayerTab:Toggle({ Title = "Infinite Jump", Value = false, Callback = function(v) Novex.Flags.InfJump = v end })
PlayerTab:Toggle({ Title = "Noclip", Value = false, Callback = function(v) Novex.Flags.Noclip = v end })
PlayerTab:Toggle({
    Title = "Fly",
    Desc = "Joystick moves, camera angle sets up/down",
    Value = false,
    Callback = function(v)
        if v then startFly() else stopFly() end
    end,
})
PlayerTab:Slider({
    Title = "Fly Speed",
    Step = 1,
    Value = { Min = 20, Max = 150, Default = 60 },
    Callback = function(v) Novex.Flags.FlySpeed = v end,
})
PlayerTab:Toggle({
    Title = "Anti Fling",
    Desc = "Zeroes your velocity if someone tries to launch you",
    Value = false,
    Callback = function(v) Novex.Flags.AntiFling = v end,
})
PlayerTab:Toggle({
    Title = "Anti AFK",
    Value = true,
    Callback = function(v) Novex.Flags.AntiAFK = v end,
})

-- ---------- Emotes ----------
local EmoteTab = Window:Tab({ Title = "Animations & Emotes", Icon = "smile" })
EmoteTab:Paragraph({
    Title = "Novex Hub Emote",
    Desc = "Tap the button to load the emote + animation pack. Then open the emote menu (period key on PC, the on-screen button on mobile).",
})
EmoteTab:Button({
    Title = "Load Animations & Emotes",
    Icon = "play",
    Callback = function() task.spawn(loadEmotes) end,
})

-- ---------- Misc ----------
local Misc = Window:Tab({ Title = "Misc", Icon = "settings" })
Misc:Button({
    Title = "Rejoin Server",
    Icon = "refresh-cw",
    Callback = function()
        pcall(function() TeleportService:Teleport(game.PlaceId, LP) end)
    end,
})
Misc:Button({
    Title = "Server Hop",
    Icon = "shuffle",
    Callback = function()
        pcall(function()
            local url = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"
            local data = HttpService:JSONDecode(game:HttpGet(url))
            for _, s in ipairs(data.data or {}) do
                if s.id ~= game.JobId and s.playing < s.maxPlayers then
                    TeleportService:TeleportToPlaceInstance(game.PlaceId, s.id, LP)
                    return
                end
            end
            notify("Hop", "no other server found", 3)
        end)
    end,
})
Misc:Button({
    Title = "Unload Novex Hub",
    Icon = "trash-2",
    Callback = function()
        pcall(function() getgenv().NovexHubUnload() end)
        pcall(function() Window:Destroy() end)
    end,
})

-- keep spectate pointed at a live target and refresh circles on respawn
track(LP.CharacterAdded:Connect(function()
    task.wait(0.5)
    refreshCircles()
    if Novex.Flags.Fly then startFly() end
end))
track(RunService.Heartbeat:Connect(function()
    if Novex.Flags.Spectate then
        local t = Novex.Murderer or Novex.Sheriff
        local cam = Workspace.CurrentCamera
        if t and alive(t) and cam.CameraSubject ~= hum(t) then
            cam.CameraSubject = hum(t)
        end
    end
end))

refreshCircles()
notify("Novex Hub", "loaded - right shift or the Novex button opens the menu", 5)
