--[[
    表情赠送脚本  GiftEmote.lua
    ------------------------------------------------------------
    基于已验证的购买脚本改造，核心差异只有一个参数：

      购买自己： Receiver = LP.UserId
      赠送他人： Receiver = 目标玩家.UserId

    赠送通道（TSB 原生支持）：
      Communicate:FireServer({
          Goal = "Gift Gamepass",
          GiftData = { Receiver = <目标UserId>, Gamepass = <通行证ID> }
      })

    ── 重要前提 ─────────────────────────────────────────────
    · 赠送通道走的是官方 "Gift Gamepass" 流程，会真实扣你的 Robux
    · Roblox 官方赠送通常要求双方是好友（部分游戏不走此限制）
    · 目标玩家必须在同一服务器内
    · 游戏可能限制每天赠送次数
--]]

--!nocheck

local Players        = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService    = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local LP   = Players.LocalPlayer
local GENV = getgenv and getgenv() or _G

-- ============================================================
-- 配置
-- ============================================================
local CFG = {
    -- 赠送前二次确认（防误触）
    confirmBeforeSend = true,
    -- 每日赠送上限（本地计数，非服务端）
    dailyLimit        = 20,
}

local COL = {
    bg     = Color3.fromRGB(16, 16, 22),
    panel  = Color3.fromRGB(28, 28, 36),
    text   = Color3.fromRGB(232, 232, 240),
    sub    = Color3.fromRGB(150, 150, 162),
    good   = Color3.fromRGB(90, 220, 130),
    mid    = Color3.fromRGB(240, 200, 90),
    bad    = Color3.fromRGB(240, 85, 85),
    accent = Color3.fromRGB(120, 90, 255),
}

-- ============================================================
-- 状态
-- ============================================================
local S = {
    catalog   = {},    -- name -> {gamepassId, price}
    owned     = {},    -- name -> true
    sentToday = 0,
    lastSent  = 0,
    logLabel  = nil,
}

local function log(msg)
    print("[赠送] " .. tostring(msg))
    if S.logLabel then
        S.logLabel.Text = tostring(msg)
    end
end

local function getCommunicate()
    local char = LP.Character or LP.CharacterAdded:Wait()
    local comm = char:FindFirstChild("Communicate")
    if not comm then
        comm = char:WaitForChild("Communicate", 8)
    end
    return comm
end

-- ============================================================
-- 读取表情目录
-- ============================================================
local function loadLimitedMap()
    local info = ReplicatedStorage:FindFirstChild("Info")
    if not info then return nil, "找不到 ReplicatedStorage.Info" end

    local ok, mod = pcall(require, info)
    if not ok or type(mod) ~= "table" then
        return nil, "require(Info) 失败"
    end

    local limited = mod.Limited
    if type(limited) ~= "table" then
        return nil, "Info.Limited 不是表"
    end

    local map = {}
    for _, v in ipairs(limited) do
        if type(v) == "table" and v.Name and v.ID then
            map[v.Name] = v.ID
        end
    end

    local n = 0
    for _ in pairs(map) do n = n + 1 end
    if n == 0 then return nil, "Info.Limited 为空" end

    return map
end

local function buildCatalog()
    local map, err = loadLimitedMap()
    if not map then return nil, err end

    local catalog = {}
    for name, gid in pairs(map) do
        catalog[name] = { gamepassId = gid, price = nil }
    end

    -- 补价格
    local ok, pages = pcall(function()
        return MarketplaceService:GetDeveloperProductsAsync()
    end)
    if ok and pages then
        local ok2, items = pcall(function() return pages:GetCurrentPage() end)
        if ok2 and type(items) == "table" then
            for _, it in ipairs(items) do
                local e = catalog[it.Name]
                if e then e.price = it.PriceInRobux or 0 end
            end
        end
    end

    S.catalog = catalog

    local list = {}
    for name, e in pairs(catalog) do
        list[#list + 1] = { name = name, id = e.gamepassId, price = e.price }
    end
    table.sort(list, function(a, b)
        return (a.price or 999999) < (b.price or 999999)
    end)

    return list
end

local function refreshOwned()
    S.owned = {}
    local raw = LP:GetAttribute("Emotes")
    if type(raw) ~= "string" then return end
    local ok, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if ok and type(data) == "table" then
        for _, v in ipairs(data) do S.owned[tostring(v)] = true end
    end
end

-- ============================================================
-- 核心：赠送
-- ============================================================
local function giftEmote(gamepassId, targetUserId, targetName)
    -- 计数检查
    if S.sentToday >= CFG.dailyLimit then
        return false, "已达本地每日上限 " .. CFG.dailyLimit
    end

    -- 冷却（防止连点）
    if os.clock() - S.lastSent < 1.5 then
        return false, "操作太快，请稍等"
    end

    local comm = getCommunicate()
    if not comm then
        return false, "找不到 Communicate（角色未加载完）"
    end

    local uid = tonumber(targetUserId)
    if not uid then
        return false, "目标 UserId 无效"
    end

    if uid == LP.UserId then
        return false, "目标是自己，请用「购买」功能"
    end

    local ok, err = pcall(function()
        comm:FireServer({
            Goal = "Gift Gamepass",
            GiftData = {
                Receiver = uid,
                Gamepass = gamepassId,
            },
        })
    end)

    if not ok then
        return false, "发送失败: " .. tostring(err)
    end

    S.sentToday = S.sentToday + 1
    S.lastSent = os.clock()

    return true, string.format("已发送 → %s (#%d)", tostring(targetName), uid)
end

-- ============================================================
-- GUI
-- ============================================================
local function new(cls, props, parent)
    local o = Instance.new(cls)
    for k, v in pairs(props or {}) do pcall(function() o[k] = v end) end
    if parent then o.Parent = parent end
    return o
end

local old = GENV.__GiftEmoteGui
if old then pcall(function() old:Destroy() end) end

local gui = new("ScreenGui", {
    Name = "GiftEmote",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, LP:WaitForChild("PlayerGui"))
GENV.__GiftEmoteGui = gui

local main = new("Frame", {
    Size = UDim2.fromOffset(380, 460),
    Position = UDim2.new(0, 50, 0, 100),
    BackgroundColor3 = COL.bg,
    BorderSizePixel = 0,
    Active = true,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, main)
new("UIStroke", { Color = COL.accent, Thickness = 1, Transparency = 0.5 }, main)

local title = new("TextLabel", {
    Size = UDim2.new(1, 0, 0, 34),
    BackgroundColor3 = COL.panel,
    BorderSizePixel = 0,
    Text = "  表情赠送",
    TextColor3 = COL.text,
    TextSize = 14,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Left,
}, main)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, title)

-- 拖动
do
    local dragging, dragStart, startPos
    main.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, main.Position
        end
    end)
    main.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            local d = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

-- ============================================================
-- 第一步：选目标玩家
-- ============================================================
local lblStep1 = new("TextLabel", {
    Size = UDim2.new(1, -20, 0, 20),
    Position = UDim2.fromOffset(10, 42),
    BackgroundTransparency = 1,
    Text = "  ① 选择接收者",
    TextColor3 = COL.sub,
    TextSize = 11,
    Font = Enum.Font.GothamMedium,
    TextXAlignment = Enum.TextXAlignment.Left,
}, main)

local playerList = new("ScrollingFrame", {
    Size = UDim2.new(1, -20, 0, 96),
    Position = UDim2.fromOffset(10, 64),
    BackgroundColor3 = COL.panel,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, main)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, playerList)
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, playerList)
new("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3) }, playerList)

local selected = { userId = nil, name = nil }
local playerRows = {}

local function refreshPlayers()
    for _, r in ipairs(playerRows) do
        if r and r.Parent then r:Destroy() end
    end
    playerRows = {}

    local rowN = 0
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            rowN = rowN + 1
            local row = new("TextButton", {
                Size = UDim2.new(1, -6, 0, 24),
                BackgroundColor3 = COL.bg,
                BorderSizePixel = 0,
                Text = string.format("  %s  (%d)", p.Name, p.UserId),
                TextColor3 = COL.text,
                TextSize = 11,
                Font = Enum.Font.Code,
                TextXAlignment = Enum.TextXAlignment.Left,
                LayoutOrder = rowN,
            }, playerList)
            new("UICorner", { CornerRadius = UDim.new(0, 4) }, row)

            local isSelected = (selected.userId == p.UserId)
            row.BackgroundColor3 = isSelected and COL.accent or COL.bg

            row.MouseButton1Click:Connect(function()
                selected.userId = p.UserId
                selected.name = p.Name
                refreshPlayers()
                log("已选择接收者: " .. p.Name)
            end)

            table.insert(playerRows, row)
        end
    end

    if rowN == 0 then
        new("TextLabel", {
            Size = UDim2.new(1, -6, 0, 24),
            BackgroundTransparency = 1,
            Text = "    房间里没有其他玩家",
            TextColor3 = COL.sub,
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, playerList)
    end
end

-- ============================================================
-- 第二步：选表情
-- ============================================================
new("TextLabel", {
    Size = UDim2.new(1, -20, 0, 20),
    Position = UDim2.fromOffset(10, 166),
    BackgroundTransparency = 1,
    Text = "  ② 选择表情",
    TextColor3 = COL.sub,
    TextSize = 11,
    Font = Enum.Font.GothamMedium,
    TextXAlignment = Enum.TextXAlignment.Left,
}, main)

local emoteList = new("ScrollingFrame", {
    Size = UDim2.new(1, -20, 0, 150),
    Position = UDim2.fromOffset(10, 188),
    BackgroundColor3 = COL.panel,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, main)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, emoteList)
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, emoteList)
new("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3) }, emoteList)

local selectedEmote = { name = nil, id = nil }
local emoteRows = {}

local function clearEmotes()
    for _, r in ipairs(emoteRows) do
        if r and r.Parent then r:Destroy() end
    end
    emoteRows = {}
end

local function refreshEmotes()
    clearEmotes()
    refreshOwned()

    local list = {}
    for name, e in pairs(S.catalog) do
        list[#list + 1] = { name = name, id = e.gamepassId, price = e.price }
    end
    table.sort(list, function(a, b)
        return (a.price or 999999) < (b.price or 999999)
    end)

    for i, e in ipairs(list) do
        local ownTag = S.owned[e.name] and " [已有]" or ""
        local row = new("TextButton", {
            Size = UDim2.new(1, -6, 0, 24),
            BackgroundColor3 = (selectedEmote.id == e.id) and COL.accent or COL.bg,
            BorderSizePixel = 0,
            Text = string.format("  %s  %s R$%s", e.name,
                e.price and tostring(e.price) or "?", ownTag),
            TextColor3 = S.owned[e.name] and COL.sub or COL.text,
            TextSize = 11,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            LayoutOrder = i,
        }, emoteList)
        new("UICorner", { CornerRadius = UDim.new(0, 4) }, row)

        row.MouseButton1Click:Connect(function()
            selectedEmote.name = e.name
            selectedEmote.id = e.id
            refreshEmotes()
            log(string.format("已选表情: %s (#%d)", e.name, e.id))
        end)

        table.insert(emoteRows, row)
    end
end

-- ============================================================
-- 第三步：赠送
-- ============================================================
local lblInfo = new("TextLabel", {
    Size = UDim2.new(1, -20, 0, 44),
    Position = UDim2.fromOffset(10, 346),
    BackgroundColor3 = COL.panel,
    BorderSizePixel = 0,
    Text = "  请选择接收者和表情",
    TextColor3 = COL.sub,
    TextSize = 11,
    Font = Enum.Font.Code,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextWrapped = true,
}, main)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, lblInfo)
new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingTop = UDim.new(0, 4) }, lblInfo)
S.logLabel = lblInfo

local function mkBtn(text, x, y, w, color)
    local b = new("TextButton", {
        Size = UDim2.fromOffset(w, 32),
        Position = UDim2.fromOffset(x, y),
        BackgroundColor3 = color or COL.panel,
        BorderSizePixel = 0,
        Text = text,
        TextColor3 = COL.text,
        TextSize = 12,
        Font = Enum.Font.GothamMedium,
        AutoButtonColor = true,
    }, main)
    new("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
    return b
end

local pendingConfirm = false
local confirmUntil = 0

local btnGift = mkBtn("赠送", 10, 396, 110, COL.good)
local btnRefresh = mkBtn("刷新列表", 128, 396, 120)
local btnReset = mkBtn("重置计数", 256, 396, 114)

local function doGift()
    if not selected.userId then
        log("✗ 请先选择接收者")
        return
    end
    if not selectedEmote.id then
        log("✗ 请先选择表情")
        return
    end

    local ok, msg = giftEmote(selectedEmote.id, selected.userId, selected.name)
    if ok then
        log("✓ " .. msg)
        lblInfo.Text = string.format("  ✓ %s\n  今日已赠送 %d 次", msg, S.sentToday)
        lblInfo.TextColor3 = COL.good
    else
        log("✗ " .. msg)
        lblInfo.TextColor3 = COL.bad
    end
end

btnGift.MouseButton1Click:Connect(function()
    if not selected.userId or not selectedEmote.id then
        log("✗ 请先选择接收者和表情")
        return
    end

    -- 二次确认
    if CFG.confirmBeforeSend then
        local now = os.clock()
        if pendingConfirm and now < confirmUntil then
            pendingConfirm = false
            doGift()
        else
            pendingConfirm = true
            confirmUntil = now + 5
            lblInfo.Text = string.format(
                "  确认赠送「%s」给 %s？\n  5 秒内再点一次确认（会扣 Robux）",
                selectedEmote.name, selected.name)
            lblInfo.TextColor3 = COL.mid
        end
    else
        doGift()
    end
end)

btnRefresh.MouseButton1Click:Connect(function()
    refreshPlayers()
    refreshEmotes()
    log(string.format("已刷新：%d 名玩家，%d 个表情",
        #Players:GetPlayers() - 1,
        (function() local n = 0 for _ in pairs(S.catalog) do n = n + 1 end return n end)()))
end)

btnReset.MouseButton1Click:Connect(function()
    S.sentToday = 0
    log("计数已重置")
end)

-- ============================================================
-- 启动
-- ============================================================
task.spawn(function()
    local list, err = buildCatalog()
    if list then
        refreshPlayers()
        refreshEmotes()
        log(string.format("就绪：%d 个表情可用", #list))
    else
        log("初始化失败: " .. tostring(err))
    end
end)

Players.PlayerAdded:Connect(function() task.defer(refreshPlayers) end)
Players.PlayerRemoving:Connect(function(p)
    if selected.userId == p.UserId then
        selected.userId, selected.name = nil, nil
    end
    task.defer(refreshPlayers)
end)
LP.CharacterAdded:Connect(function() task.defer(refreshPlayers) end)

-- ============================================================
-- 对外接口
-- ============================================================
GENV.GIFTEMOTE = {
    gui = gui,
    config = CFG,
    state = S,
    catalog = S.catalog,

    -- 直接赠送（不经过 GUI）
    gift = function(gamepassId, targetUserId)
        return giftEmote(gamepassId, targetUserId, "玩家" .. tostring(targetUserId))
    end,

    -- 按名字赠送
    giftByName = function(emoteName, targetUserId)
        local e = S.catalog[emoteName]
        if not e then return false, "表情不存在: " .. tostring(emoteName) end
        return giftEmote(e.gamepassId, targetUserId, "玩家" .. tostring(targetUserId))
    end,

    -- 按玩家名赠送
    giftTo = function(emoteName, playerName)
        local target
        for _, p in ipairs(Players:GetPlayers()) do
            if p.Name:lower() == tostring(playerName):lower() then
                target = p
                break
            end
        end
        if not target then return false, "找不到玩家: " .. tostring(playerName) end
        local e = S.catalog[emoteName]
        if not e then return false, "表情不存在: " .. tostring(emoteName) end
        return giftEmote(e.gamepassId, target.UserId, target.Name)
    end,

    getSentCount = function() return S.sentToday end,
    destroy = function() pcall(function() gui:Destroy() end) end,
}

log("脚本已加载")