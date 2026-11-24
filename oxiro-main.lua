--!nocheck
-- CT SYSTEM v3.0 FORK — PART 1/3
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local Stats = game:GetService("Stats")
local player = Players.LocalPlayer

local mode = "idle"
local attackTarget = nil
local destroyTarget = nil
local FLOAT_HEIGHT = 2
local HITBOX_SIZE = 100
local HITBOX_ENABLED = true
local BLOCK_ENABLED = true
local PREDICT_ENABLED = false
local PREDICT_FACTOR = 0.18
local NOCLIP_ENABLED = true
local SILENT_AIM_ENABLED = false
local AUTO_EQUIP_KATANA = true
local UNLIMITED_M1_ENABLED = true
local NCD_ENABLED = false

local ORBIT_MODE = "atomic"
local DESTROY_RADIUS = 7
local DESTROY_SPEED = 800
local DESTROY_MOVE_STEP = 65
local SPIRAL_GROWTH = 1.4
local SPIRAL_MAX_R = 22
local MAX_SAFE_GLIDE_SPEED = 5000
local orbitPhase = 0
local spiralR = DESTROY_RADIUS
local savedAutoRotate = nil
local isVoidResetting = false
local followConnection = nil
local panicMode = false

local RBBypass = { enabled = true, legalAccel = 12000, maxDeltaFactor = 4.0 }
local _lastHRP = nil
local _lastPos = nil

local function claimOwnership(hrp)
    if not RBBypass.enabled then return end
    pcall(function()
        if hrp:GetNetworkOwner() ~= player then hrp:SetNetworkOwner(player) end
    end)
end

local function envelopeVelocity(hrp, desiredPos, dt)
    if not _lastPos or not _lastHRP or _lastHRP ~= hrp then
        _lastPos = hrp.Position; _lastHRP = hrp
        return (desiredPos - hrp.Position) / math.max(dt, 0.001)
    end
    local rawVel = (desiredPos - _lastPos) / math.max(dt, 0.001)
    local mag = rawVel.Magnitude
    local cap = RBBypass.legalAccel * math.max(dt, 0.001)
    if mag > cap and mag > 0 then rawVel = rawVel.Unit * cap end
    return rawVel
end

local function safeSetCFrame(hrp, cf, dt)
    if not hrp then return end
    local vel = envelopeVelocity(hrp, cf.Position, dt)
    pcall(function()
        hrp.AssemblyLinearVelocity = vel
        hrp.AssemblyAngularVelocity = Vector3.zero
        hrp.CFrame = cf
    end)
    _lastPos = hrp.Position
end

local function getHRP(plr)
    local p = plr or player
    return p.Character and p.Character:FindFirstChild("HumanoidRootPart")
end
local function getHumanoid(plr)
    local p = plr or player
    return p.Character and p.Character:FindFirstChildOfClass("Humanoid")
end
local function getPredictedPosition(hrp)
    if not PREDICT_ENABLED then return hrp.Position end
    return hrp.Position + hrp.Velocity * PREDICT_FACTOR
end

local function restoreAutoRotate()
    local hum = getHumanoid(player)
    if hum and savedAutoRotate ~= nil then hum.AutoRotate = savedAutoRotate end
    savedAutoRotate = nil
end

local function lockAutoRotateForAim()
    local hum = getHumanoid(player)
    if not hum then return end
    if savedAutoRotate == nil then savedAutoRotate = hum.AutoRotate end
    hum.PlatformStand = false
    hum.AutoRotate = false
end

local function equipKatana()
    if not AUTO_EQUIP_KATANA then return end
    task.spawn(function()
        pcall(function()
            local r = ReplicatedStorage:WaitForChild("EquippingRemote", 5)
            if r then r:FireServer("Katana") end
        end)
    end)
end
-- CT SYSTEM v3.0 FORK — PART 2/3
local ATOM_SHELL_TILTS = {
    CFrame.Angles(math.rad(60), 0, math.rad(25)),
    CFrame.Angles(math.rad(-60), math.rad(60), math.rad(-25)),
    CFrame.Angles(math.rad(15), math.rad(-60), math.rad(75)),
}

local function evalAtomicOffset(t, radius)
    local n = #ATOM_SHELL_TILTS
    local idx = (math.floor(t / (math.pi * 2)) % n) + 1
    local rx, rz = radius, radius * 0.42
    local lp = Vector3.new(math.cos(t) * rx, 0, math.sin(t) * rz)
    return ATOM_SHELL_TILTS[idx]:VectorToWorldSpace(lp)
end

local function evalSpiralOffset(t, dt)
    spiralR = spiralR + SPIRAL_GROWTH * dt
    if spiralR > SPIRAL_MAX_R then spiralR = DESTROY_RADIUS end
    local r = spiralR
    local y = math.sin(t * 2.2) * (r * 0.16)
    return Vector3.new(math.cos(t) * r, y, math.sin(t) * r)
end

local function evalOrbitOffset(t, dt, radius)
    if ORBIT_MODE == "spiral" then return evalSpiralOffset(t, dt) end
    return evalAtomicOffset(t, radius)
end

local function destroyTargetPlayer(dt)
    if not destroyTarget then return end
    local char = player.Character
    local hrp = getHRP(player)
    if not char or not hrp then return end
    local tChar = destroyTarget.Character
    if not tChar or not tChar:FindFirstChild("HumanoidRootPart") then return end
    lockAutoRotateForAim()
    local tHRP = tChar.HumanoidRootPart
    local center = getPredictedPosition(tHRP) + Vector3.new(0, FLOAT_HEIGHT, 0)
    local radius = math.max(DESTROY_RADIUS, 1)
    local speed = math.clamp(DESTROY_SPEED, 1, MAX_SAFE_GLIDE_SPEED)
    local stepF = math.clamp(DESTROY_MOVE_STEP / 65, 0.05, 4)
    local sdt = math.clamp(dt, 0.001, 0.05)
    local ang = (speed / radius) * 1.35 * stepF
    orbitPhase = (orbitPhase + ang * sdt) % (math.pi * 600)
    local offset = evalOrbitOffset(orbitPhase, sdt, radius)
    local desired = center + offset
    claimOwnership(hrp)
    safeSetCFrame(hrp, CFrame.lookAt(desired, center), sdt)
    pcall(function()
        if BLOCK_ENABLED then ReplicatedStorage.CombatRemote:FireServer("Block") end
    end)
end

local function stopFollowing()
    if followConnection then followConnection:Disconnect(); followConnection = nil end
    mode = "idle"; attackTarget = nil; destroyTarget = nil
    _lastHRP, _lastPos = nil, nil
    restoreAutoRotate()
end

local function startFollowing()
    if followConnection then followConnection:Disconnect() end
    followConnection = RunService.Heartbeat:Connect(function(dt)
        if panicMode or isVoidResetting then return end
        local char = player.Character
        local hrp = getHRP(player)
        if not char or not hrp then return end
        claimOwnership(hrp)
        if mode == "destroy" and destroyTarget then destroyTargetPlayer(dt); return end
        if mode == "attack" and attackTarget then
            local tChar = attackTarget.Character
            if tChar and tChar:FindFirstChild("HumanoidRootPart") then
                lockAutoRotateForAim()
                local tHRP = tChar.HumanoidRootPart
                local pPos = getPredictedPosition(tHRP)
                local rot = CFrame.new(pPos) * tHRP.CFrame.Rotation
                local behind = rot * CFrame.new(0, FLOAT_HEIGHT, 2.5)
                safeSetCFrame(hrp, CFrame.lookAt(behind.Position, pPos), dt)
                pcall(function()
                    if BLOCK_ENABLED then ReplicatedStorage.CombatRemote:FireServer("Block") end
                end)
            end
            return
        end
        if mode == "idle" and not SILENT_AIM_ENABLED then restoreAutoRotate() end
    end)
end

local function getVoidCFrame()
    local y = workspace.FallenPartsDestroyHeight
    local tY = (typeof(y) == "number" and y > -45000 and y < 0) and (y - 120) or -10000
    return CFrame.new(0, tY, 0)
end

local function performVoidReset(waitForRespawn)
    if isVoidResetting then
        if waitForRespawn then
            local c = player.CharacterAdded:Wait()
            c:WaitForChild("HumanoidRootPart", 6)
            return c
        end
        return nil
    end
    isVoidResetting = true
    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function()
            hum:ChangeState(Enum.HumanoidStateType.Physics)
            hum.PlatformStand = false
        end)
    end
    local vcf = getVoidCFrame()
    if char then
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") then
                pcall(function()
                    p.Anchored = false
                    p.AssemblyLinearVelocity = Vector3.new(0, -2500, 0)
                    p.AssemblyAngularVelocity = Vector3.zero
                    p.CFrame = vcf
                end)
            end
        end
    end
    task.spawn(function()
        local t = 0
        while isVoidResetting and t < 0.45 and player.Character == char do
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then
                pcall(function()
                    hrp.AssemblyLinearVelocity = Vector3.new(0, -2500, 0)
                    hrp.CFrame = vcf
                end)
            end
            t = t + RunService.Heartbeat:Wait()
        end
        if isVoidResetting and player.Character == char then
            local h = char and char:FindFirstChildOfClass("Humanoid")
            if h and h.Health > 0 then pcall(function() h.Health = 0 end) end
        end
    end)
    local spawned = nil
    if waitForRespawn then
        spawned = player.CharacterAdded:Wait()
        spawned:WaitForChild("HumanoidRootPart", 6)
    end
    task.delay(0.15, function() isVoidResetting = false end)
    return spawned
end

local function snapToActiveTarget(charModel)
    local hrp = charModel and charModel:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end
    local active, isOrbit
    if mode == "destroy" and destroyTarget and destroyTarget.Parent == Players then
        active, isOrbit = destroyTarget, true
    elseif mode == "attack" and attackTarget and attackTarget.Parent == Players then
        active, isOrbit = attackTarget, false
    end
    if not active then return false end
    local tHRP = getHRP(active); if not tHRP then return false end
    local hum = charModel:FindFirstChildOfClass("Humanoid")
    if hum then
        if savedAutoRotate == nil then savedAutoRotate = hum.AutoRotate end
        hum.PlatformStand = false; hum.AutoRotate = false
    end
    local center = getPredictedPosition(tHRP)
    if isOrbit then
        local r = math.max(DESTROY_RADIUS, 1)
        local oc = center + Vector3.new(0, FLOAT_HEIGHT, 0)
        local sp = oc + evalOrbitOffset(orbitPhase, 0.016, r)
        safeSetCFrame(hrp, CFrame.lookAt(sp, oc), 0.016)
    else
        local behind = tHRP.CFrame * CFrame.new(0, FLOAT_HEIGHT, 3.5)
        safeSetCFrame(hrp, CFrame.lookAt(behind.Position, center), 0.016)
    end
    return true
end

local function runCommand(cmd)
    if cmd.type == "idle" then
        stopFollowing(); startFollowing()
    elseif cmd.type == "attack" and cmd.target then
        mode, attackTarget, destroyTarget = "attack", cmd.target, nil
        task.spawn(function()
            performVoidReset(true)
            snapToActiveTarget(player.Character)
            startFollowing()
        end)
    elseif cmd.type == "hate" and cmd.target then
        mode, destroyTarget, attackTarget = "destroy", cmd.target, nil
        orbitPhase = math.random() * math.pi * 2
        spiralR = DESTROY_RADIUS
        snapToActiveTarget(player.Character)
        startFollowing()
    elseif cmd.type == "orbit_mode" and cmd.mode then
        ORBIT_MODE = (cmd.mode == "spiral") and "spiral" or "atomic"
        spiralR = DESTROY_RADIUS
    elseif cmd.type == "spiral_growth" and cmd.val then
        SPIRAL_GROWTH = math.clamp(cmd.val, 0.1, 20)
    elseif cmd.type == "spiral_max" and cmd.val then
        SPIRAL_MAX_R = math.clamp(cmd.val, DESTROY_RADIUS + 1, 120)
    elseif cmd.type == "radius" and cmd.val then
        DESTROY_RADIUS = math.clamp(cmd.val, 1, 50); spiralR = DESTROY_RADIUS
    elseif cmd.type == "speed" and cmd.val then
        DESTROY_SPEED = math.clamp(cmd.val, 1, MAX_SAFE_GLIDE_SPEED)
    elseif cmd.type == "step" and cmd.val then
        DESTROY_MOVE_STEP = math.clamp(cmd.val, 1, 250)
    elseif cmd.type == "rb_toggle" then
        RBBypass.enabled = cmd.val
    elseif cmd.type == "rb_accel" and cmd.val then
        RBBypass.legalAccel = math.clamp(cmd.val, 500, 100000)
    elseif cmd.type == "height" and cmd.val then
        FLOAT_HEIGHT = math.clamp(cmd.val, -50, 100)
    end
end

local function findPlayerByFuzzy(str)
    if not str or str == "" then return nil end
    local s = str:lower()
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.DisplayName:lower():find(s) or plr.Name:lower():find(s) then
            return plr
        end
    end
    return nil
end
-- CT SYSTEM v3.0 FORK — PART 3/3
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "ctSystemForkGui_v3"
ScreenGui.ResetOnSpawn = false
pcall(function()
    if gethui then ScreenGui.Parent = gethui()
    else ScreenGui.Parent = CoreGui end
end)
if not ScreenGui.Parent then ScreenGui.Parent = player:WaitForChild("PlayerGui") end

local Btn = Instance.new("TextButton")
Btn.Parent = ScreenGui
Btn.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
Btn.Position = UDim2.new(0.02, 0, 0.35, 0)
Btn.Size = UDim2.new(0, 92, 0, 34)
Btn.Font = Enum.Font.SourceSansBold
Btn.Text = "CT v3 FORK"
Btn.TextColor3 = Color3.fromRGB(245, 245, 245)
Btn.TextSize = 13
Btn.Draggable = true
Instance.new("UICorner", Btn).CornerRadius = UDim.new(0, 7)

local Frame = Instance.new("Frame")
Frame.Parent = ScreenGui
Frame.BackgroundColor3 = Color3.fromRGB(14, 14, 14)
Frame.Position = UDim2.new(0.05, 0, 0.19, 0)
Frame.Size = UDim2.new(0, 300, 0, 400)
Frame.Draggable = true
Frame.Visible = false
Instance.new("UICorner", Frame).CornerRadius = UDim.new(0, 9)

local Head = Instance.new("TextLabel")
Head.Parent = Frame
Head.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
Head.Size = UDim2.new(1, 0, 0, 34)
Head.Font = Enum.Font.SourceSansBold
Head.Text = "CT SYSTEM v3 · FORK"
Head.TextColor3 = Color3.fromRGB(245, 245, 245)
Head.TextSize = 14
Instance.new("UICorner", Head).CornerRadius = UDim.new(0, 9)

Btn.MouseButton1Click:Connect(function() Frame.Visible = not Frame.Visible end)

local List = Instance.new("UIListLayout")
List.Parent = Frame
List.Padding = UDim.new(0, 6)
List.SortOrder = Enum.SortOrder.LayoutOrder
local Pad = Instance.new("UIPadding")
Pad.PaddingTop = UDim.new(0, 42); Pad.PaddingLeft = UDim.new(0, 10)
Pad.PaddingRight = UDim.new(0, 10); Pad.PaddingBottom = UDim.new(0, 10)
Pad.Parent = Frame

local function mkButton(text, cb, order)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 30)
    b.BackgroundColor3 = Color3.fromRGB(26, 26, 26)
    b.Font = Enum.Font.SourceSansBold
    b.Text = text
    b.TextColor3 = Color3.fromRGB(242, 242, 242)
    b.TextSize = 12
    b.LayoutOrder = order
    b.Parent = Frame
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    b.MouseButton1Click:Connect(cb)
    return b
end

local function mkInput(label, placeholder, order, cb)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 30)
    row.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    row.LayoutOrder = order
    row.Parent = Frame
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Position = UDim2.new(0, 8, 0, 0)
    l.Size = UDim2.new(0.45, 0, 1, 0)
    l.Font = Enum.Font.SourceSansSemibold
    l.Text = label
    l.TextColor3 = Color3.fromRGB(210, 210, 210)
    l.TextSize = 11
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = row
    local box = Instance.new("TextBox")
    box.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
    box.Position = UDim2.new(0.45, 0, 0, 3)
    box.Size = UDim2.new(0.55, -6, 1, -6)
    box.Font = Enum.Font.SourceSans
    box.PlaceholderText = placeholder
    box.Text = ""
    box.TextColor3 = Color3.fromRGB(245, 245, 245)
    box.TextSize = 12
    box.Parent = row
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 5)
    box.FocusLost:Connect(function(enter)
        if enter and box.Text ~= "" then cb(box.Text) end
    end)
    return box
end

mkInput("Atom Target", "Player name", 1, function(name)
    local f = findPlayerByFuzzy(name)
    if f then runCommand({type = "hate", target = f}) end
end)

local orbitBtn = mkButton("Orbit: ATOMIC", function(self)
    if ORBIT_MODE == "atomic" then
        runCommand({type = "orbit_mode", mode = "spiral"})
        self.Text = "Orbit: SPIRAL"
    else
        runCommand({type = "orbit_mode", mode = "atomic"})
        self.Text = "Orbit: ATOMIC"
    end
end, 2)

mkInput("Radius", "7", 3, function(v)
    local n = tonumber(v); if n then runCommand({type = "radius", val = n}) end
end)

mkInput("Speed", "800", 4, function(v)
    local n = tonumber(v); if n then runCommand({type = "speed", val = n}) end
end)

mkInput("Spiral Growth", "1.4", 5, function(v)
    local n = tonumber(v); if n then runCommand({type = "spiral_growth", val = n}) end
end)

mkInput("Spiral Max R", "22", 6, function(v)
    local n = tonumber(v); if n then runCommand({type = "spiral_max", val = n}) end
end)

local rbBtn = mkButton("RB Bypass: ON", function(self)
    RBBypass.enabled = not RBBypass.enabled
    self.Text = RBBypass.enabled and "RB Bypass: ON" or "RB Bypass: OFF"
end, 7)

mkInput("RB Accel Cap", "12000", 8, function(v)
    local n = tonumber(v); if n then runCommand({type = "rb_accel", val = n}) end
end)

mkButton("Stop / Idle", function()
    runCommand({type = "idle"})
end, 9)

player.CharacterAdded:Connect(function()
    isVoidResetting = false
    _lastHRP, _lastPos = nil, nil
    equipKatana()
    task.wait(0.05)
    if mode == "destroy" or mode == "attack" then
        snapToActiveTarget(player.Character)
        startFollowing()
    end
end)

if player.Character then equipKatana() end
startFollowing()
