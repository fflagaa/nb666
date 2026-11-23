--[[
    Limited Emote Helper  (standalone)
    ------------------------------------------------------------
    原理（与 Revenant 的 Bypass Limited Emotes Timer 相同）：
      1. 从 ReplicatedStorage.Info.Limited 取出全部限定表情的
         [表情名] = GamepassId 映射
      2. 用 MarketplaceService 查真实价格 / ProductId / 图标
      3. 把「全部限定表情」重建成一段 JSON 写进 workspace.Limited，
         并固定 info.currentWeek 使客户端不再按周轮换做时间判断
      4. 购买走游戏官方的 Communicate 远程：
         FireServer({Goal="Gift Gamepass", GiftData={Receiver=自己, Gamepass=id}})
         —— 这会真实扣 Robux，不是白嫖
    ------------------------------------------------------------
    这个脚本不替代 GUI 库，全部用原生 Instance 手搓，直接粘贴即可跑。
--]]

--!nocheck

local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService        = game:GetService("HttpService")
local UserInputService   = game:GetService("UserInputService")
local RunService         = game:GetService("RunService")

local LP = Players.LocalPlayer
local GENV = getgenv and getgenv() or _G

-- ============================================================
-- 状态
-- ============================================================
local S = {
    savedOriginal = nil,
    savedFlag     = false,
    emotesConn    = nil,
    catalog       = {},   -- name -> {gamepassId=, price=, productId=, icon=}
    owned         = {},   -- name -> true
}

-- ============================================================
-- 工具
-- ============================================================
local function log(msg)
    print("[LimitedHelper] " .. tostring(msg))
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

-- 读取本地已拥有表情
local function refreshOwned()
    S.owned = {}
    local raw = LP:GetAttribute("Emotes")
    if type(raw) ~= "string" then return end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(raw)
    end)
    if not ok or type(data) ~= "table" then return end
    for _, v in ipairs(data) do
        S.owned[tostring(v)] = true
    end
end

-- ============================================================
-- 1. 读取限定表情映射表
-- ============================================================
local function loadLimitedMap()
    local info = ReplicatedStorage:FindFirstChild("Info")
    if not info then
        return nil, "找不到 ReplicatedStorage.Info"
    end

    local ok, mod = pcall(require, info)
    if not ok or type(mod) ~= "table" then
        return nil, "require(Info) 失败: " .. tostring(mod)
    end

    local limited = mod.Limited
    if type(limited) ~= "table" then
        return nil, "Info.Limited 不是表（游戏可能改名了）"
    end

    local map = {}
    for _, v in ipairs(limited) do
        if type(v) == "table" and v.Name and v.ID then
            map[v.Name] = v.ID
        end
    end

    local n = 0
    for _ in pairs(map) do n = n + 1 end
    if n == 0 then
        return nil, "Info.Limited 解析出 0 条记录"
    end

    return map
end

-- ============================================================
-- 2. 查询单个通行证信息
-- ============================================================
local function queryGamepass(id)
    local num = tonumber(id)
    if not num then
        return nil, "ID 必须是纯数字"
    end

    local ok, info = pcall(function()
        return MarketplaceService:GetProductInfo(num, Enum.InfoType.GamePass)
    end)

    if not ok or type(info) ~= "table" or not info.Name then
        return nil, "查询失败：ID 无效或被限流"
    end

    return {
        id      = num,
        name    = info.Name,
        price   = info.PriceInRobux,
        icon    = info.IconImageAssetId,
        forSale = info.IsForSale,
        desc    = info.Description,
        creator = (type(info.Creator) == "table" and info.Creator.Name) or "?",
    }
end

-- ============================================================
-- 3. 建立完整目录（含价格）
-- ============================================================
local function buildCatalog()
    local map, err = loadLimitedMap()
    if not map then
        return nil, err
    end

    local catalog = {}
    for name, gid in pairs(map) do
        catalog[name] = { gamepassId = gid, price = nil, icon = 0, productId = 0 }
    end

    -- 用开发者商品列表补全价格 / ProductId / 图标（和原脚本同源）
    local ok, pages = pcall(function()
        return MarketplaceService:GetDeveloperProductsAsync()
    end)

    if ok and pages then
        local pageOk, items = pcall(function()
            return pages:GetCurrentPage()
        end)

        if pageOk and type(items) == "table" then
            for _, it in ipairs(items) do
                local entry = catalog[it.Name]
                if entry then
                    entry.price     = it.PriceInRobux or 0
                    entry.icon      = it.IconImageAssetId or 0
                    entry.productId = it.ProductId or 0
                end
            end
        end
    end

    S.catalog = catalog

    local list = {}
    for name, e in pairs(catalog) do
        list[#list + 1] = {
            name = name,
            gamepassId = e.gamepassId,
            price = e.price,
        }
    end
    table.sort(list, function(a, b)
        return (a.price or 999999) < (b.price or 999999)
    end)

    return list
end

-- ============================================================
-- 4. 重建 workspace.Limited（绕过周轮换时间判断）
-- ============================================================
local function rebuildLimited(currentWeek)
    local catalog = S.catalog
    if not catalog or next(catalog) == nil then
        local _, err = buildCatalog()
        if err then return false, err end
        catalog = S.catalog
    end

    local parts = {}
    local n = 1
    for name, e in pairs(catalog) do
        parts[#parts + 1] = string.format(
            '{"Number":%d,"Image":%d,"Name":"%s","Price":%d,"ID":%d}',
            n,
            e.icon or 0,
            name,
            e.price or 0,
            e.productId or 0
        )
        n = n + 1
    end

    if #parts == 0 then
        return false, "目录为空，无法重建"
    end

    if not S.savedFlag then
        S.savedFlag     = true
        S.savedOriginal = workspace:GetAttribute("Limited")
    end

    local json = '{"items":[' .. table.concat(parts, ",") .. '],'
             .. '"info":{"secondsInWeek":604800,'
             .. '"startOfYear":1735732800,'
             .. '"currentWeek":' .. tostring(currentWeek or 23) .. '}}'

    workspace:SetAttribute("Limited", json)
    return true, #parts
end

local function restoreLimited()
    if S.savedFlag then
        pcall(function()
            workspace:SetAttribute("Limited", S.savedOriginal)
        end)
        S.savedFlag     = false
        S.savedOriginal = nil
    end
end

-- ============================================================
-- 5. 购买（走官方 Communicate）
-- ============================================================
local function buyGamepass(gamepassId)
    local comm = getCommunicate()
    if not comm then
        return false, "找不到 Communicate 远程（角色没加载完？）"
    end

    local ok, err = pcall(function()
        comm:FireServer({
            Goal = "Gift Gamepass",
            GiftData = {
                Receiver = LP.UserId,
                Gamepass = gamepassId,
            },
        })
    end)

    if not ok then
        return false, "发送失败: " .. tostring(err)
    end

    return true
end

-- ============================================================
-- 6. 极简 GUI
-- ============================================================
local COL = {
    bg      = Color3.fromRGB(20, 20, 24),
    panel   = Color3.fromRGB(30, 30, 36),
    accent  = Color3.fromRGB(120, 90, 255),
    text    = Color3.fromRGB(235, 235, 240),
    sub     = Color3.fromRGB(150, 150, 160),
    ok      = Color3.fromRGB(90, 200, 130),
    bad     = Color3.fromRGB(230, 90, 90),
}

local function new(cls, props, parent)
    local o = Instance.new(cls)
    for k, v in pairs(props or {}) do
        o[k] = v
    end
    if parent then o.Parent = parent end
    return o
end

local old = GENV.__LimitedHelperGui
if old then pcall(function() old:Destroy() end) end

local gui = new("ScreenGui", {
    Name = "LimitedHelper",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, LP:WaitForChild("PlayerGui"))
GENV.__LimitedHelperGui = gui

local main = new("Frame", {
    Name = "Main",
    Size = UDim2.fromOffset(380, 400),
    Position = UDim2.new(0, 60, 0, 120),
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
    Text = "  Limited Emote Helper",
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
            dragging = true
            dragStart = input.Position
            startPos = main.Position
        end
    end)
    main.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y
            )
        end
    end)
end

-- 输入框
local box = new("TextBox", {
    Size = UDim2.new(1, -20, 0, 32),
    Position = UDim2.new(0, 10, 0, 42),
    BackgroundColor3 = COL.panel,
    BorderSizePixel = 0,
    Text = "",
    PlaceholderText = "输入 Gamepass ID（纯数字）",
    PlaceholderColor3 = COL.sub,
    TextColor3 = COL.text,
    TextSize = 13,
    Font = Enum.Font.Code,
    ClearTextOnFocus = false,
}, main)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, box)
new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, box)

local function mkButton(text, x, y, w, color)
    local b = new("TextButton", {
        Size = UDim2.fromOffset(w, 30),
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

local btnQuery = mkButton("查询",   10, 82, 76, COL.accent)
local btnBuy   = mkButton("购买",   94, 82, 76, COL.ok)
local btnList  = mkButton("列出限定",176, 82, 88)
local btnFix   = mkButton("解除时限",270, 82, 96)

-- 日志 / 输出区
S.logLabel = new("TextLabel", {
    Size = UDim2.new(1, -20, 0, 40),
    Position = UDim2.new(0, 10, 0, 120),
    BackgroundColor3 = COL.panel,
    BorderSizePixel = 0,
    Text = "就绪",
    TextColor3 = COL.sub,
    TextSize = 12,
    Font = Enum.Font.Code,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Center,
}, main)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, S.logLabel)
new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, S.logLabel)

-- 列表
local scroll = new("ScrollingFrame", {
    Size = UDim2.new(1, -20, 0, 220),
    Position = UDim2.new(0, 10, 0, 168),
    BackgroundColor3 = COL.panel,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, main)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, scroll)

local layout = new("UIListLayout", {
    Padding = UDim.new(0, 2),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, scroll)
new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }, scroll)

local function clearList()
    for _, c in ipairs(scroll:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
end

local function addRow(text, onClick, color)
    local b = new("TextButton", {
        Size = UDim2.new(1, -8, 0, 26),
        BackgroundColor3 = COL.bg,
        BorderSizePixel = 0,
        Text = "  " .. text,
        TextColor3 = color or COL.text,
        TextSize = 12,
        Font = Enum.Font.Code,
        TextXAlignment = Enum.TextXAlignment.Left,
        AutoButtonColor = true,
    }, scroll)
    new("UICorner", { CornerRadius = UDim.new(0, 4) }, b)
    b.MouseButton1Click:Connect(function()
        pcall(onClick)
    end)
    return b
end

-- ============================================================
-- 7. 按钮逻辑
-- ============================================================
btnQuery.MouseButton1Click:Connect(function()
    local info, err = queryGamepass(box.Text)
    if not info then
        log("✗ " .. err)
        return
    end

    log(string.format("✓ %s | %s R$ | 在售=%s",
        info.name,
        tostring(info.price or "?"),
        tostring(info.forSale)))

    clearList()
    addRow("名称: " .. info.name)
    addRow("价格: " .. tostring(info.price or "免费/不可售") .. " R$")
    addRow("在售: " .. tostring(info.forSale))
    addRow("作者: " .. tostring(info.creator))
    addRow("ID  : " .. info.id)
    addRow("→ 点此购买这张通行证", function()
        local ok, e = buyGamepass(info.id)
        log(ok and ("✓ 已发送购买请求 #" .. info.id) or ("✗ " .. e))
    end, COL.accent)
end)

btnBuy.MouseButton1Click:Connect(function()
    local id = tonumber(box.Text)
    if not id then
        log("✗ 请先输入数字 ID")
        return
    end
    local ok, e = buyGamepass(id)
    log(ok and ("✓ 已发送购买请求 #" .. id) or ("✗ " .. e))
end)

btnList.MouseButton1Click:Connect(function()
    local list, err = buildCatalog()
    if not list then
        log("✗ " .. err)
        return
    end

    refreshOwned()
    clearList()

    local shown, ownedN = 0, 0
    for _, e in ipairs(list) do
        local tag
        if S.owned[e.name] then
            tag = " [已拥有]"
            ownedN = ownedN + 1
        else
            tag = ""
        end

        addRow(string.format("%s  %s R$%s", e.name, tostring(e.price or "?"), tag), function()
            box.Text = tostring(e.gamepassId)
            local ok, er = buyGamepass(e.gamepassId)
            log(ok and ("✓ " .. e.name) or ("✗ " .. er))
        end, S.owned[e.name] and COL.sub or COL.text)

        -- 标记行对应的表情名，供 Emotes 变化时局部刷新
        do
            local row = scroll:GetChildren()[#scroll:GetChildren()]
            if row and row:IsA("TextButton") then
                row:SetAttribute("EmoteName", e.name)
                row:SetAttribute("Owned", S.owned[e.name] == true)
            end
        end

        shown = shown + 1
    end

    log(string.format("共 %d 个限定表情，已拥有 %d 个", shown, ownedN))

    -- 监听 Emotes 变化自动刷新（抽成函数，避免重复绑定）
    S.refreshList = function()
        refreshOwned()
        for _, row in ipairs(scroll:GetChildren()) do
            if row:IsA("TextButton") and row:GetAttribute("EmoteName") then
                local nm = row:GetAttribute("EmoteName")
                if S.owned[nm] and not row:GetAttribute("Owned") then
                    row:SetAttribute("Owned", true)
                    row.TextColor3 = COL.sub
                    local t = row.Text
                    if not t:find("%[已拥有%]") then
                        row.Text = t .. " [已拥有]"
                    end
                end
            end
        end
    end

    if S.emotesConn then
        pcall(function() S.emotesConn:Disconnect() end)
        S.emotesConn = nil
    end
    S.emotesConn = LP:GetAttributeChangedSignal("Emotes"):Connect(function()
        task.defer(function()
            pcall(S.refreshList)
        end)
    end)
end)

btnFix.MouseButton1Click:Connect(function()
    if S.savedFlag then
        restoreLimited()
        btnFix.Text = "解除时限"
        log("已还原 workspace.Limited")
        return
    end

    local ok, n = rebuildLimited(23)
    if not ok then
        log("✗ " .. tostring(n))
        return
    end
    btnFix.Text = "还原"
    log(string.format("✓ 已重建 Limited，共 %d 条，时限已解除", n))
end)

-- ============================================================
-- 8. 启动
-- ============================================================
task.spawn(function()
    local list, err = buildCatalog()
    if list then
        refreshOwned()
        local owned = 0
        for _ in pairs(S.owned) do owned = owned + 1 end
        log(string.format("就绪：%d 个限定表情，已拥有 %d 个", #list, owned))
    else
        log("初始化: " .. tostring(err))
    end
end)

LP.CharacterRemoving:Connect(function()
    if S.emotesConn then
        pcall(function() S.emotesConn:Disconnect() end)
        S.emotesConn = nil
    end
end)

log("脚本已加载")