-- AutoAim + Head ESP + Keycard-in-BodyBag ESP (LocalScript for StarterPlayerScripts)
-- Optimized: cached lists, scan interval, cheap per-frame aiming/ESP
-- WARNING: run in Local context (StarterPlayerScripts) and test in Play mode

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = workspace.CurrentCamera

-- ====== CONFIG ======
local SCAN_INTERVAL      = 0.20   -- seconds between scans for nearest target
local AIM_SPEED          = 0.22   -- lerp factor for camera aim (0..1)
local NPC_LOCK_RANGE     = 280    -- studs to consider NPC lock (tweak)
local NPC_ESP_RANGE      = 180
local PLAYER_ESP_RANGE   = 300
local KEYCARD_RANGE      = 150    -- requested 150 studs for keycards
local HOLD_TIME          = 2.5    -- how long to stay on same target before auto-switch
local SHOW_STATUS        = true

local AlwaysIgnore = { Merchant=true, Broker=true, ["Vulture Merchant"]=true }

local KEYCARD_COLORS = {
    ["Orange Keycard"] = Color3.fromRGB(255,165,0),
    ["Green Keycard"]  = Color3.fromRGB(0,255,0),
    ["Red Keycard"]    = Color3.fromRGB(255,0,0),
}
-- ======================

-- State
local autoAimEnabled   = false
local extraToggle      = false -- placeholder (does nothing currently)
local currentTarget    = nil   -- BasePart (head)
local targetAcquiredAt = 0
local lastScanTime     = 0

-- Caches
local npcHeads = {}            -- array of BasePart (heads)
local modelToHead = {}         -- model -> head
local playerToHead = {}        -- player -> head
local playerHeads = {}         -- array of player head parts

local espCache = {}            -- part -> BillboardGui for heads
local keycardCache = {}        -- keyPart -> BillboardGui
local bodyBagCache = {}        -- keyPart -> bagModel

-- ---------- Utilities ----------
local function isIgnoredModel(model)
    if not model or not model:IsA("Model") then return true end
    if model == LocalPlayer.Character then return true end
    if AlwaysIgnore[model.Name] then return true end
    if string.find(model.Name:lower(), "rebel", 1, true) then return true end
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hum then return true end
    if Players:GetPlayerFromCharacter(model) then return true end
    return false
end

-- ---------- NPC cache management ----------
local function addNPCModel(model)
    if not model or not model:IsA("Model") then return end
    if isIgnoredModel(model) then return end
    if modelToHead[model] then return end
    local head = model:FindFirstChild("Head")
    if head and head:IsA("BasePart") then
        modelToHead[model] = head
        table.insert(npcHeads, head)
    end
end

local function removeNPCModel(model)
    local head = modelToHead[model]
    if head then
        modelToHead[model] = nil
        -- remove from array
        for i = #npcHeads, 1, -1 do
            if npcHeads[i] == head then table.remove(npcHeads, i); break end
        end
        -- cleanup esp
        if espCache[head] then espCache[head]:Destroy(); espCache[head] = nil end
    end
end

-- ---------- Player head tracking ----------
local function registerPlayerCharacter(plr, char)
    local head = (char and char:FindFirstChild("Head"))
    playerToHead[plr] = head
    -- refresh playerHeads array
    for i = #playerHeads, 1, -1 do
        local h = playerHeads[i]
        if not h or not h.Parent or Players:GetPlayerFromCharacter(h.Parent) == plr then
            table.remove(playerHeads, i)
        end
    end
    if head and head:IsA("BasePart") then
        table.insert(playerHeads, head)
    end
end

local function onPlayerAdded(plr)
    if plr.Character then registerPlayerCharacter(plr, plr.Character) end
    plr.CharacterAdded:Connect(function(c) registerPlayerCharacter(plr, c) end)
    plr.CharacterRemoving:Connect(function() registerPlayerCharacter(plr, nil) end)
end

for _,plr in ipairs(Players:GetPlayers()) do onPlayerAdded(plr) end
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(plr)
    playerToHead[plr] = nil
    -- remove any esp for that player's head (cleanup happens in updateESP)
end)

-- ---------- BodyBag/keycard tracking ----------
local function addKeycardPartToCache(part, bagModel)
    if not part or not part:IsA("BasePart") then return end
    if not KEYCARD_COLORS[part.Name] then return end
    bodyBagCache[part] = bagModel
end

local function removeKeycardPart(part)
    if keycardCache[part] then keycardCache[part]:Destroy(); keycardCache[part] = nil end
    bodyBagCache[part] = nil
end

local function registerBodyBag(bagModel)
    if not bagModel or not bagModel:IsA("Model") then return end
    -- scan existing children
    for _,desc in ipairs(bagModel:GetDescendants()) do
        if desc:IsA("BasePart") and KEYCARD_COLORS[desc.Name] then
            addKeycardPartToCache(desc, bagModel)
        end
    end
    -- monitor new/removed parts inside this bag
    local addedConn = bagModel.DescendantAdded:Connect(function(desc)
        if desc:IsA("BasePart") and KEYCARD_COLORS[desc.Name] then
            addKeycardPartToCache(desc, bagModel)
        end
    end)
    local removedConn = bagModel.DescendantRemoving:Connect(function(desc)
        if desc:IsA("BasePart") and KEYCARD_COLORS[desc.Name] then
            removeKeycardPart(desc)
        end
    end)
    -- store connections on the model for later cleanup
    bagModel:SetAttribute("__bodybag_conn", true) -- marker (optional)
end

local function unregisterBodyBag(bagModel)
    if not bagModel then return end
    -- remove any keycard parts that referenced this bag
    for part, bag in pairs(bodyBagCache) do
        if bag == bagModel then
            removeKeycardPart(part)
        end
    end
end

-- ---------- initial workspace scan (deferred to avoid blocking) ----------
task.spawn(function()
    for _,inst in ipairs(workspace:GetDescendants()) do
        if inst:IsA("Model") then
            addNPCModel(inst)
            if inst.Name == "BodyBag" then registerBodyBag(inst) end
        elseif inst:IsA("BasePart") and KEYCARD_COLORS[inst.Name] then
            -- keycard that is not necessarily inside a BodyBag
            addKeycardPartToCache(inst, inst.Parent)
        end
    end
end)

-- listen to workspace changes
workspace.DescendantAdded:Connect(function(inst)
    -- find top-level model if descendant
    if inst:IsA("Model") then
        addNPCModel(inst)
        if inst.Name == "BodyBag" then registerBodyBag(inst) end
    else
        -- if a keycard part appears anywhere
        if inst:IsA("BasePart") and KEYCARD_COLORS[inst.Name] then
            addKeycardPartToCache(inst, inst.Parent)
        end
        -- catch models created as descendants
        local model = inst
        while model and not model:IsA("Model") do model = model.Parent end
        if model then addNPCModel(model) end
    end
end)

workspace.DescendantRemoving:Connect(function(inst)
    if inst:IsA("Model") then
        removeNPCModel(inst)
        if inst.Name == "BodyBag" then unregisterBodyBag(inst) end
    elseif inst:IsA("BasePart") and KEYCARD_COLORS[inst.Name] then
        removeKeycardPart(inst)
    end
end)

-- ---------- ESP creation helpers ----------
local function makeBillboard(part, size, color)
    if not part or not part:IsA("BasePart") then return nil end
    local bg = Instance.new("BillboardGui")
    bg.Adornee = part
    bg.Size = size
    bg.AlwaysOnTop = true
    bg.ResetOnSpawn = false
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1,0,1,0)
    f.BackgroundColor3 = color
    f.BorderSizePixel = 0
    f.Parent = bg
    bg.Parent = part
    return bg
end

local function ensureHeadESP(part, color)
    if espCache[part] then return espCache[part] end
    local b = makeBillboard(part, UDim2.new(0,6,0,6), color)
    espCache[part] = b
    return b
end

local function ensureKeycardESP(part, color)
    if keycardCache[part] then return keycardCache[part] end
    local b = makeBillboard(part, UDim2.new(0,10,0,10), color)
    keycardCache[part] = b
    return b
end

-- ---------- target helpers ----------
local function cleanStaleHeads(list)
    for i = #list,1,-1 do
        local h = list[i]
        if not h or not h.Parent or not h:IsA("BasePart") then table.remove(list, i) end
    end
end

local function getNearestFromList(list, maxRange)
    local root = LocalPlayer.Character and (LocalPlayer.Character:FindFirstChild("HumanoidRootPart") or LocalPlayer.Character:FindFirstChild("Head"))
    if not root then return nil, math.huge end
    local best, bestDist = nil, math.huge
    local rp = root.Position
    for _, head in ipairs(list) do
        if head and head.Parent and head:IsA("BasePart") then
            local model = head.Parent
            local hum = model:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                local d = (head.Position - rp).Magnitude
                if d <= maxRange and d < bestDist then
                    best, bestDist = head, d
                end
            end
        end
    end
    return best, bestDist
end

local function getNearestNPCHead()
    cleanStaleHeads(npcHeads)
    return getNearestFromList(npcHeads, NPC_LOCK_RANGE)
end

-- ---------- ESP update (called each frame; cheap-ish) ----------
local function updateESP()
    local rootObj = LocalPlayer.Character and (LocalPlayer.Character:FindFirstChild("HumanoidRootPart") or LocalPlayer.Character:FindFirstChild("Head"))
    if not rootObj then return end
    local rootPos = rootObj.Position

    -- NPC heads ESP
    for i = #npcHeads,1,-1 do
        local head = npcHeads[i]
        if not head or not head.Parent then
            if head and espCache[head] then espCache[head]:Destroy(); espCache[head] = nil end
            table.remove(npcHeads, i)
        else
            local model = head.Parent
            if isIgnoredModel(model) then
                if espCache[head] then espCache[head].Enabled = false end
            else
                local hum = model:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then
                    local d = (head.Position - rootPos).Magnitude
                    if d <= NPC_ESP_RANGE then
                        local g = ensureHeadESP(head, Color3.fromRGB(0,255,0))
                        if g then g.Enabled = true end
                    else
                        if espCache[head] then espCache[head].Enabled = false end
                    end
                else
                    if espCache[head] then espCache[head].Enabled = false end
                end
            end
        end
    end

    -- Player heads ESP
    for plr, head in pairs(playerToHead) do
        if plr ~= LocalPlayer and head and head.Parent then
            local hum = head.Parent:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                local d = (head.Position - rootPos).Magnitude
                if d <= PLAYER_ESP_RANGE then
                    local g = ensureHeadESP(head, Color3.fromRGB(255,0,0))
                    if g then g.Enabled = true end
                else
                    if espCache[head] then espCache[head].Enabled = false end
                end
            else
                if espCache[head] then espCache[head].Enabled = false end
            end
        end
    end

    -- Keycards in BodyBags
    for part, bag in pairs(bodyBagCache) do
        if part and part.Parent then
            local d = (part.Position - rootPos).Magnitude
            if d <= KEYCARD_RANGE then
                local g = ensureKeycardESP(part, KEYCARD_COLORS[part.Name] or Color3.fromRGB(255,255,255))
                if g then g.Enabled = true end
            else
                if keycardCache[part] then keycardCache[part].Enabled = false end
            end
        else
            if keycardCache[part] then keycardCache[part]:Destroy(); keycardCache[part] = nil end
            bodyBagCache[part] = nil
        end
    end
end

-- ---------- small draggable UI (stacked vertically) ----------
local gui = Instance.new("ScreenGui")
gui.Name = "AutoAim_GUI"
gui.ResetOnSpawn = false
gui.Parent = PlayerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0,130,0,92) -- smaller stacked vertical
frame.Position = UDim2.new(0.78,0,0.06,0)
frame.BackgroundColor3 = Color3.fromRGB(30,30,30)
frame.BorderSizePixel = 0
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0,8)

local function makeDraggable(f)
    local dragging, dragStart, startPos
    f.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = f.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            f.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end
makeDraggable(frame)

local function makeBtn(text, y)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1,-10,0,30)
    b.Position = UDim2.new(0,5,0,y)
    b.BackgroundColor3 = Color3.fromRGB(50,50,50)
    b.TextColor3 = Color3.fromRGB(255,255,255)
    b.TextScaled = true
    b.Text = text
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,6)
    b.Parent = frame
    return b
end

local aimBtn = makeBtn("AutoAim: OFF", 6)
local extraBtn = makeBtn("Extra: OFF", 42)
local statusLbl
if SHOW_STATUS then
    statusLbl = Instance.new("TextLabel")
    statusLbl.Size = UDim2.new(1,-10,0,12)
    statusLbl.Position = UDim2.new(0,5,0,74)
    statusLbl.BackgroundTransparency = 1
    statusLbl.TextColor3 = Color3.fromRGB(220,220,220)
    statusLbl.TextScaled = true
    statusLbl.Text = "Target: None"
    statusLbl.Parent = frame
end

aimBtn.MouseButton1Click:Connect(function()
    autoAimEnabled = not autoAimEnabled
    aimBtn.Text = "AutoAim: " .. (autoAimEnabled and "ON" or "OFF")
    aimBtn.BackgroundColor3 = autoAimEnabled and Color3.fromRGB(40,160,40) or Color3.fromRGB(50,50,50)
    if not autoAimEnabled then
        currentTarget = nil
        if statusLbl then statusLbl.Text = "Target: None" end
    end
end)

extraBtn.MouseButton1Click:Connect(function()
    extraToggle = not extraToggle
    extraBtn.Text = "Extra: " .. (extraToggle and "ON" or "OFF")
    extraBtn.BackgroundColor3 = extraToggle and Color3.fromRGB(40,120,200) or Color3.fromRGB(50,50,50)
end)

-- ---------- Main loop: scans (interval) and aim+ESP (per frame light) ----------
local scanTimer = 0
local holdTimer = 0

RunService.RenderStepped:Connect(function(dt)
    -- update ESP every frame (cheap operations only)
    updateESP()

    -- scanning logic (low frequency)
    scanTimer = scanTimer + dt
    if scanTimer >= SCAN_INTERVAL then
        scanTimer = 0

        -- if no current target, try to find one
        if not currentTarget or not currentTarget.Parent then
            local best, d = getNearestFromList and getNearestFromList(npcHeads, NPC_LOCK_RANGE) or nil, math.huge
            -- fallback: compute nearest quickly
            if not best then
                -- iterate cached npcHeads
                for _,h in ipairs(npcHeads) do
                    if h and h.Parent then
                        local m = h.Parent
                        if not isIgnoredModel(m) then
                            local hum = m:FindFirstChildOfClass("Humanoid")
                            if hum and hum.Health > 0 then
                                local root = LocalPlayer.Character and (LocalPlayer.Character:FindFirstChild("HumanoidRootPart") or LocalPlayer.Character:FindFirstChild("Head"))
                                if root then
                                    local dist = (h.Position - root.Position).Magnitude
                                    if dist <= NPC_LOCK_RANGE and dist < d then
                                        best = h; d = dist
                                    end
                                end
                            end
                        end
                    end
                end
            end
            currentTarget = best
            if currentTarget then
                targetAcquiredAt = tick()
            end
        else
            -- validate current target
            local model = currentTarget.Parent
            local valid = false
            if currentTarget and currentTarget.Parent and currentTarget:IsA("BasePart") and model and not isIgnoredModel(model) then
                local hum = model:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then
                    local root = LocalPlayer.Character and (LocalPlayer.Character:FindFirstChild("HumanoidRootPart") or LocalPlayer.Character:FindFirstChild("Head"))
                    if root then
                        local d = (currentTarget.Position - root.Position).Magnitude
                        if d <= NPC_LOCK_RANGE then valid = true end
                    end
                end
            end

            if not valid then
                currentTarget = nil
            else
                -- hold time check: if held long enough, switch to another nearest
                if tick() - targetAcquiredAt >= HOLD_TIME then
                    -- find next nearest excluding current
                    local bestNext, dnext = nil, math.huge
                    for _,h in ipairs(npcHeads) do
                        if h ~= currentTarget and h and h.Parent and not isIgnoredModel(h.Parent) then
                            local hum = h.Parent:FindFirstChildOfClass("Humanoid")
                            if hum and hum.Health > 0 then
                                local root = LocalPlayer.Character and (LocalPlayer.Character:FindFirstChild("HumanoidRootPart") or LocalPlayer.Character:FindFirstChild("Head"))
                                if root then
                                    local dist = (h.Position - root.Position).Magnitude
                                    if dist <= NPC_LOCK_RANGE and dist < dnext then
                                        bestNext = h; dnext = dist
                                    end
                                end
                            end
                        end
                    end
                    if bestNext then
                        currentTarget = bestNext
                        targetAcquiredAt = tick()
                    else
                        -- reset timer so we don't constantly search
                        targetAcquiredAt = tick()
                    end
                end
            end
        end
    end

    -- AIM each frame (smooth)
    if autoAimEnabled and currentTarget and currentTarget.Parent then
        local camPos = Camera.CFrame.Position
        local tgtPos = currentTarget.Position + Vector3.new(0, 0.08, 0)
        local goal = CFrame.new(camPos, tgtPos)
        pcall(function()
            Camera.CFrame = Camera.CFrame:Lerp(goal, AIM_SPEED)
        end)
        if statusLbl and currentTarget.Parent then
            local root = LocalPlayer.Character and (LocalPlayer.Character:FindFirstChild("HumanoidRootPart") or LocalPlayer.Character:FindFirstChild("Head"))
            local dist = root and (currentTarget.Position - root.Position).Magnitude or 0
            statusLbl.Text = string.format("%s (%.1fm)", tostring(currentTarget.Parent.Name or "NPC"), math.floor(dist*10)/10)
        end
    end
end)

-- Provide a simple safe helper fallback (local function) used above when available
-- If earlier code had getNearestFromList defined, we keep its reference; otherwise we define it now:
if not getNearestFromList then
    function getNearestFromList(list, maxRange)
        local root = LocalPlayer.Character and (LocalPlayer.Character:FindFirstChild("HumanoidRootPart") or LocalPlayer.Character:FindFirstChild("Head"))
        if not root then return nil, math.huge end
        local best, bestDist = nil, math.huge
        local rp = root.Position
        for _,h in ipairs(list) do
            if h and h.Parent and h:IsA("BasePart") then
                local model = h.Parent
                local hum = model:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then
                    local d = (h.Position - rp).Magnitude
                    if d <= maxRange and d < bestDist then
                        best, bestDist = h, d
                    end
                end
            end
        end
        return best, bestDist
    end
end

-- Done.
