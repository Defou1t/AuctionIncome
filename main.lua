local api = require("api")

local addon = {
    name = "Auction Income",
    author = "Ako/Defou1t",
    desc = "Counts auction income and purchase spending only for the items you choose.",
    version = "1.5.0"
}

-- Kept at the Addon root, outside the addon folder, so replacing the addon
-- folder on an update never wipes the statistics.
local DATA_FILE = "auction_income_data.lua"
local DEBUG_FILE = "auction_income_debug.lua"

-- Numeric settings live in one table: Lua 5.1 allows only 200 locals per chunk.
local C = {}
C.WIN_W = 620
C.WIN_H = 735
C.DBG_W = 600
C.DBG_H = 650
-- Each list starts with DEFAULT_SLOTS slots; "+"/"-" change it per list.
C.MAX_SLOTS = 24
C.SLOTS_PER_ROW = 8
C.DEFAULT_SLOTS = 8
C.ITEM_PAGE_ROWS = 8
C.RECORD_ROWS = 6
C.BAG_ROWS = 10
C.LOG_ROWS = 8
C.MAX_RECORDS = 3000
C.MAX_OTHER = 200
C.MAX_DEBUG = 300
C.MAX_ARGS = 12
-- Lowest share of the sale price we still accept as "this mail paid that
-- sale" (the auction house keeps a commission).
C.MIN_NET_RATIO = 0.80
-- The sale mail also refunds the listing deposit (seen: price 34g 01s 78c,
-- +34s 01c deposit, -5% trade fee = 32g 65s 70c), so a cheap lot can pay a
-- little more than its price.
C.MAX_NET_RATIO = 1.05
-- A sale whose price is unknown (seen only in chat) is matched against the
-- item's last known net price per unit, within this range.
C.UNIT_MIN = 0.6
C.UNIT_MAX = 1.5
-- A wallet change waits this long before it is matched, so a mail event that
-- arrives right after PLAYER_MONEY still counts as its context.
C.MATCH_DELAY_MS = 3000
C.MAIL_WINDOW_MS = 15000
C.DEDUP_MS = 10000
-- A purchase is money leaving the wallet and a tracked item entering the bag
-- within this time of each other.
C.BUY_PAIR_MS = 3000
-- How long a spend waits for a chat/auction notice to claim it.
C.SPEND_KEEP_MS = 60000
C.SPEND_CLAIM_MS = 5000
-- An auction purchase: PLAYER_MONEY goes down and the purchase mail shows up
-- (MAIL_INBOX_UPDATE) right after. The item arrives later, when the mail is
-- taken: ADDED_ITEM with this item task.
C.AUCTION_MAIL_AFTER_MS = 2000
C.AUCTION_MAIL_BEFORE_MS = 300
C.MAIL_ITEM_TASK = 46
C.MAIL_ITEM_WINDOW_MS = 2000
-- Auction mails expire, so a purchase not taken by then is forgotten.
C.AUCTION_SPEND_DAYS = 30
C.MAX_AUCTION_SPENDS = 100
-- Listing an item: REMOVED_ITEM(link, count, "destroy", 45) right after the
-- deposit leaves the wallet. The deposit is 1% of the price (7499 for
-- 749994), which tells several lots of one item apart when one of them sells.
-- An unsold lot comes back by mail and its deposit is lost.
local LISTING = {task = 45, rate = 0.01, days = 30, max = 200}

-- When the item already has an average price, a waiting auction purchase is
-- only assigned to it if its price per unit is within this range of it.
C.AUCTION_UNIT_MIN = 0.25
C.AUCTION_UNIT_MAX = 4

-- Words that mark a system message as a notice that someone bought our item,
-- and words that mean the player bought, or sold to an NPC. Checked in lower case.
local SALE_WORDS = {"sold", "bought by", "purchased by"}
local NOT_SALE_WORDS = {"you bought", "you purchased", "you have bought", "you have purchased", "merchant", "vendor"}
-- Words that mark a system message as the player's own purchase.
local BUY_WORDS = {"you bought", "you purchased", "you have bought", "you have purchased", "purchase complete", "purchased"}
local NOT_BUY_WORDS = {"bought by", "purchased by"}
-- System messages containing these are written to the debug log, to learn
-- the exact wording of the client's notices.
local DEBUG_WORDS = {"auction", "sold", "bought", "purchas", "mail"}

-- api.File:Write stores numbers with 6 significant digits (1234567 becomes
-- 1.23457e+006), so every money amount and timestamp is kept as a string.
local state = {
    items = {},
    sales = {},
    other = {},
    buyItems = {},
    buys = {},
    -- Auction purchases whose mail has not been taken yet.
    auctionSpends = {},
    -- Lots on the auction now, and deposits lost on lots that did not sell.
    listings = {},
    fees = {},
    mode = "sell",
    slotCount = {sell = C.DEFAULT_SLOTS, buy = C.DEFAULT_SLOTS},
    feeRatio = "",
    mailEventsSeen = false,
    debug = false,
    buttonX = 40,
    buttonY = 320,
}

-- Widgets live in one table: Lua 5.1 allows only 200 locals per chunk.
local ui = {itemSlots = {}, itemRows = {}, recordRows = {}, gridCells = {}, dbgBagRows = {}, dbgLogRows = {}}
local dbgPicked
local bagList, bagPage = {}, 1
local probeSummary = "not checked"
local debugLog = {}
local debugDirty = false
local lastDebugFlushMs = 0
local lastDebugKey
local pendingDeltas = {}
local recentSpends = {}
local pendingArrivals = {}
local lastMailMs = -1000000
local lastSentMailMs = -1000000
local lastMoney
local lastSaleKey, lastSaleMs = nil, -1000000
local lastRecorded, lastOther, lastBuy
-- Raw icon paths seen this session, by item ID. Stored paths use "/" because
-- the raw "Game\ui\icon\..." form does not survive File:Write.
local iconCache = {}

-- ============================================================
-- Basics
-- ============================================================

local function log(message)
    pcall(function() api.Log:Info("[Auction Income] " .. tostring(message)) end)
end

local function nowMs()
    local ok, value = pcall(function() return api.Time:GetUiMsec() end)
    return ok and tonumber(value) or 0
end

local function fmt(value)
    return string.format("%.0f", tonumber(value) or 0)
end

-- File:Write's serializer is not known to escape quotes, so anything that
-- comes from the game (item names, event arguments) is stripped of them.
local function clean(text)
    local result = tostring(text or ""):gsub('[%c"\\]', "'")
    return result
end

local function safePath(path)
    local result = tostring(path or ""):gsub("\\", "/"):gsub("'", "/")
    return result
end

local function trim(text)
    local result = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return result
end

local function formatCopper(value)
    local raw = tonumber(value) or 0
    local sign = raw < 0 and "-" or ""
    local copper = math.floor(math.abs(raw) + 0.5)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    return sign .. string.format("%.0fg %02ds %02dc", gold, silver, copper % 100)
end

local function isLeap(year)
    return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function toEpoch(year, month, day, hour, minute, second)
    local monthDays = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    local days = 0
    for value = 1970, year - 1 do days = days + (isLeap(value) and 366 or 365) end
    for value = 1, month - 1 do
        days = days + monthDays[value]
        if value == 2 and isLeap(year) then days = days + 1 end
    end
    return (days + day - 1) * 86400 + hour * 3600 + minute * 60 + second
end

local function now()
    local ok, t = pcall(function() return api.Time:TimeToDate(api.Time:GetLocalTime()) end)
    if ok and type(t) == "table" then
        local year = tonumber(t.year)
        local month = tonumber(t.month or t.mon)
        local day = tonumber(t.day)
        local hour = tonumber(t.hour) or 0
        local minute = tonumber(t.minute or t.min) or 0
        local second = tonumber(t.second or t.sec) or 0
        if year and month and day and month >= 1 and month <= 12 then
            return {
                text = string.format("%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second),
                day = string.format("%04d-%02d-%02d", year, month, day),
                epoch = fmt(toEpoch(year, month, day, hour, minute, second)),
            }
        end
    end
    return {text = "?", day = "?", epoch = "0"}
end

-- Item ID from a client item link: "|i28305,0,0,..." (seen in ADDED_ITEM).
local function linkId(text)
    return tonumber(tostring(text or ""):match("|i(%d+)") or tostring(text or ""):match("%[(%d+),"))
end

local function currentMoney()
    local ok, value = pcall(api.Bag.GetCurrency, api.Bag)
    if ok then return tonumber(value) end
    return nil
end

local function itemInfo(id)
    local ok, info = pcall(api.Item.GetItemInfoByType, api.Item, tonumber(id))
    if ok and type(info) == "table" then return info end
    return nil
end

local function bagCount(id)
    local ok, count = pcall(api.Bag.CountBagItemByItemType, api.Bag, tonumber(id))
    return ok and tonumber(count) or 0
end

local function bagCapacity()
    local ok, cap = pcall(api.Bag.Capacity, api.Bag)
    return ok and tonumber(cap) or 150
end

-- The bag item that is currently held on the cursor, as Dawnsdrop Check reads
-- it. The index is 0 when nothing is held.
local function pickedBagItem()
    local ok, slot = pcall(api.Cursor.GetCursorPickedBagItemIndex, api.Cursor)
    slot = ok and tonumber(slot)
    if not slot or slot == 0 then return nil end
    local okInfo, info = pcall(api.Bag.GetBagItemInfo, api.Bag, 1, slot)
    if okInfo and type(info) == "table" and tonumber(info.itemType) and tonumber(info.itemType) > 0 then
        return info
    end
    return nil
end

-- ============================================================
-- Storage
-- ============================================================

-- Reloading an addon from the Addons window leaves the previous copy
-- running: its windows and event handler survive until the client restarts
-- (seen: one sale logged three times). Each copy therefore marks the data
-- file as its own, and a copy that finds another owner retires for good.
local instanceId, alive, lastOwnerCheckMs, idSuffix, retire = "", true, -100000, "", nil

local function ownedByOther()
    local ok, onDisk = pcall(api.File.Read, api.File, DATA_FILE)
    return ok and type(onDisk) == "table" and onDisk.owner ~= nil and tostring(onDisk.owner) ~= instanceId
end

local function save()
    if not alive then return end
    if ownedByOther() then
        if retire then retire() end
        return
    end
    state.owner = instanceId
    local ok, err = pcall(api.File.Write, api.File, DATA_FILE, state)
    if not ok then log("Save failed: " .. tostring(err)) end
end

local function stillActive()
    if not alive then return false end
    local ms = nowMs()
    if ms - lastOwnerCheckMs >= 2000 then
        lastOwnerCheckMs = ms
        if ownedByOther() then
            if retire then retire() end
            return false
        end
    end
    return true
end

local function load()
    local ok, loaded = pcall(api.File.Read, api.File, DATA_FILE)
    if not ok or type(loaded) ~= "table" then return end
    for _, key in ipairs({"items", "sales", "other", "buyItems", "buys", "auctionSpends", "listings", "fees"}) do
        if type(loaded[key]) == "table" then state[key] = loaded[key] end
    end
    -- v1.1.0 stored icon paths with backslashes turned into quotes.
    for _, item in ipairs(state.items) do item.path = safePath(item.path) end
    if loaded.mode == "buy" then state.mode = "buy" end
    if type(loaded.slotCount) == "table" then
        for _, mode in ipairs({"sell", "buy"}) do
            local count = tonumber(loaded.slotCount[mode])
            if count then state.slotCount[mode] = math.min(math.max(math.floor(count), 1), C.MAX_SLOTS) end
        end
    end
    if loaded.feeRatio ~= nil then state.feeRatio = tostring(loaded.feeRatio) end
    if loaded.listingRate ~= nil then state.listingRate = tostring(loaded.listingRate) end
    if type(loaded.mailEventsSeen) == "boolean" then state.mailEventsSeen = loaded.mailEventsSeen end
    if type(loaded.debug) == "boolean" then state.debug = loaded.debug end
    for _, key in ipairs({"buttonX", "buttonY", "winX", "winY", "dbgX", "dbgY"}) do
        if tonumber(loaded[key]) then state[key] = tonumber(loaded[key]) end
    end
end

local refreshDebug

local function debugNote(kind, text)
    if not state.debug then return end
    -- MAIL_INBOX_UPDATE repeats the same arguments many times a second.
    local key = kind .. " " .. tostring(text)
    if key == lastDebugKey then return end
    lastDebugKey = key
    table.insert(debugLog, clean(now().text .. " " .. key))
    while #debugLog > C.MAX_DEBUG do table.remove(debugLog, 1) end
    debugDirty = true
    if ui.debugWin and ui.debugWin:IsVisible() then refreshDebug() end
end

local function flushDebug()
    if not debugDirty or not alive then return end
    debugDirty = false
    pcall(api.File.Write, api.File, DEBUG_FILE, {lines = debugLog})
end

local function dump(value, depth)
    depth = depth or 0
    if type(value) == "table" then
        if depth > 2 then return "{...}" end
        local parts = {}
        for key, nested in pairs(value) do
            parts[#parts + 1] = tostring(key) .. "=" .. dump(nested, depth + 1)
            if #parts >= 30 then break end
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    if type(value) == "string" then return "'" .. value .. "'" end
    return tostring(value)
end

local function packArgs(...)
    local packed = {...}
    local args = {}
    for index = 1, C.MAX_ARGS do args[index] = packed[index] end
    return args
end

local function dumpArgs(args)
    local parts = {}
    for index = 1, C.MAX_ARGS do
        if args[index] ~= nil then parts[#parts + 1] = index .. ":" .. dump(args[index]) end
    end
    return table.concat(parts, " | ")
end

-- ============================================================
-- Tracked items
-- ============================================================

-- "sell" items are counted as income from auction sales, "buy" items as
-- spending on purchases. Both lists and both histories are separate.
local function itemsOf(mode)
    if mode == "buy" then return state.buyItems end
    return state.items
end

local function recordsOf(mode)
    if mode == "buy" then return state.buys end
    return state.sales
end

-- Never fewer slots than items, so no tracked item is ever hidden.
local function slotCount(mode)
    local count = tonumber(state.slotCount[mode]) or C.DEFAULT_SLOTS
    return math.min(math.max(count, #itemsOf(mode), 1), C.MAX_SLOTS)
end

local function sameName(a, b)
    return tostring(a or ""):lower() == tostring(b or ""):lower()
end

local function trackedById(list, id)
    id = tonumber(id)
    if not id then return nil end
    for _, item in ipairs(list) do
        if tonumber(item.id) == id then return item end
    end
    return nil
end

-- The longest matching name wins, so "Regrade Scroll" does not swallow a
-- sale of "Superior Regrade Scroll".
local function trackedByText(list, text)
    local low = tostring(text or ""):lower()
    if low == "" then return nil end
    local best, bestLen
    for _, item in ipairs(list) do
        local name = tostring(item.name or ""):lower()
        if name ~= "" and low:find(name, 1, true) and (not bestLen or #name > bestLen) then
            best, bestLen = item, #name
        end
    end
    return best
end

local function recordBelongsTo(record, item)
    if tostring(item.id or "") ~= "" and tostring(record.itemId or "") ~= "" then
        return tonumber(item.id) == tonumber(record.itemId)
    end
    return sameName(item.name, record.item)
end

local function itemForRecord(list, record)
    for _, item in ipairs(list) do
        if recordBelongsTo(record, item) then return item end
    end
    return nil
end

-- ============================================================
-- Statistics
-- ============================================================

local function feeRatio()
    local ratio = tonumber(state.feeRatio)
    if ratio and ratio > 0 and ratio <= C.MAX_NET_RATIO then return ratio end
    return nil
end

local function saleGot(sale) return tonumber(sale.net) end

local function saleWaiting(sale)
    if saleGot(sale) then return 0 end
    local gross = tonumber(sale.gross)
    if gross then return math.floor(gross * (feeRatio() or 1) + 0.5) end
    local item = itemForRecord(state.items, sale)
    local unit = item and tonumber(item.unitNet)
    if unit then return math.floor(unit * (tonumber(sale.count) or 1) + 0.5) end
    return 0
end

-- The client's Lua uses single-precision numbers: past 16,777,216 copper
-- (about 1677g) a sum drops copper, and a timestamp drops up to two minutes.
-- Totals are therefore kept as whole gold plus a copper remainder.
local function newMoney() return {g = 0, c = 0} end

local function moneyAdd(m, amount)
    local text = fmt(amount)
    local negative = text:sub(1, 1) == "-"
    if negative then text = text:sub(2) end
    local gold = tonumber(text:sub(1, -5)) or 0
    local copper = tonumber(text:sub(-4)) or 0
    if negative then gold, copper = -gold, -copper end
    m.g = m.g + gold
    m.c = m.c + copper
    local carry = math.floor(m.c / 10000)
    m.g = m.g + carry
    m.c = m.c - carry * 10000
    return m
end

local function moneySub(a, b)
    local result = {g = a.g - b.g, c = a.c - b.c}
    local carry = math.floor(result.c / 10000)
    result.g = result.g + carry
    result.c = result.c - carry * 10000
    return result
end

local function moneyValue(m) return m.g * 10000 + m.c end

local function formatMoney(m)
    local gold, copper = m.g, m.c
    local sign = ""
    if gold < 0 then
        sign = "-"
        if copper > 0 then gold, copper = gold + 1, 10000 - copper end
        gold = -gold
    end
    return sign .. string.format("%.0fg %02ds %02dc", gold, math.floor(copper / 100), copper % 100)
end

local function computeTotals()
    local t = now()
    local nowEpoch = tonumber(t.epoch) or 0
    local buckets = {}
    for _, key in ipairs({"today", "week", "month", "all"}) do
        buckets[key] = {got = newMoney(), wait = newMoney(), spent = newMoney(), fees = newMoney()}
    end
    local function add(day, epoch, field, amount)
        if amount == 0 then return end
        moneyAdd(buckets.all[field], amount)
        if day == t.day then moneyAdd(buckets.today[field], amount) end
        if epoch > 0 and nowEpoch - epoch < 7 * 86400 then moneyAdd(buckets.week[field], amount) end
        if epoch > 0 and nowEpoch - epoch < 30 * 86400 then moneyAdd(buckets.month[field], amount) end
    end
    for _, sale in ipairs(state.sales) do
        local got = saleGot(sale)
        if got then
            -- Collected money belongs to the day it reached the wallet.
            add(sale.collectedDay, tonumber(sale.collectedEpoch) or 0, "got", got)
        else
            add(sale.soldDay, tonumber(sale.soldEpoch) or 0, "wait", saleWaiting(sale))
        end
    end
    for _, buy in ipairs(state.buys) do
        add(buy.day, tonumber(buy.epoch) or 0, "spent", tonumber(buy.cost) or 0)
    end
    for _, lost in ipairs(state.fees) do
        add(lost.day, tonumber(lost.epoch) or 0, "fees", tonumber(lost.fee) or 0)
    end
    return buckets
end

local function sellStats(item)
    local sold, got, wait, lost = 0, newMoney(), newMoney(), newMoney()
    for _, sale in ipairs(state.sales) do
        if recordBelongsTo(sale, item) then
            sold = sold + (tonumber(sale.count) or 1)
            moneyAdd(got, saleGot(sale) or 0)
            moneyAdd(wait, saleWaiting(sale))
        end
    end
    for _, fee in ipairs(state.fees) do
        if recordBelongsTo(fee, item) then moneyAdd(lost, tonumber(fee.fee) or 0) end
    end
    return sold, got, wait, lost
end

local function buyStats(item)
    local bought, spent, pricedCount = 0, newMoney(), 0
    for _, buy in ipairs(state.buys) do
        if recordBelongsTo(buy, item) then
            local count = tonumber(buy.count) or 1
            bought = bought + count
            if tonumber(buy.cost) then
                moneyAdd(spent, tonumber(buy.cost))
                pricedCount = pricedCount + count
            end
        end
    end
    return bought, spent, pricedCount > 0 and math.floor(moneyValue(spent) / pricedCount + 0.5) or nil
end

-- ============================================================
-- UI helpers
-- ============================================================

local refresh

local function setStatus(text)
    if ui.statusLabel then ui.statusLabel:SetText(tostring(text or "")) end
end

local function makeLabel(parent, id, text, x, y, width, height, size, align)
    local label = parent:CreateChildWidget("label", id, 0, true)
    label:SetExtent(width, height)
    label:RemoveAllAnchors()
    label:AddAnchor("TOPLEFT", parent, x, y)
    label:SetText(text or "")
    if label.style then
        label.style:SetAlign(align or ALIGN.LEFT)
        label.style:SetFontSize(size or 14)
        label.style:SetColor(0.08, 0.035, 0.01, 1)
    end
    label:Show(true)
    return label
end

local function makeButton(parent, id, text, x, y, width, height, callback)
    local button = parent:CreateChildWidget("button", id, 0, true)
    if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(button, BUTTON_BASIC.DEFAULT) end
    button:SetExtent(width, height)
    button:RemoveAllAnchors()
    button:AddAnchor("TOPLEFT", parent, x, y)
    button:SetText(text)
    function button:OnClick()
        if not alive then return end
        local ok, err = pcall(callback)
        if not ok then log("Error: " .. tostring(err)) end
    end
    button:SetHandler("OnClick", button.OnClick)
    button:Show(true)
    return button
end

local function makeEdit(parent, id, x, y, width, height)
    local edit
    if W_CTRL and W_CTRL.CreateEdit then
        edit = W_CTRL.CreateEdit(id, parent)
    else
        edit = parent:CreateChildWidget("edit", id, 0, true)
    end
    edit:SetExtent(width, height)
    edit:RemoveAllAnchors()
    edit:AddAnchor("TOPLEFT", parent, x, y)
    edit:SetText("")
    edit:Show(true)
    return edit
end

-- An item slot like the ones in Dawnsdrop Check's "Alert Items" window:
-- drag a bag item onto it (or click it while holding one), right-click to
-- clear it.
local function makeItemSlot(parent, id, x, y, onDrop, onRightClick)
    local slot = CreateItemIconButton(id, parent)
    pcall(function() F_SLOT.ApplySlotSkin(slot, slot.back, SLOT_STYLE.BAG_DEFAULT) end)
    slot:RemoveAllAnchors()
    slot:AddAnchor("TOPLEFT", parent, x, y)
    slot:SetHandler("OnClick", function(self, button)
        local ok, err = pcall(function()
            if button == "RightButton" then onRightClick() else onDrop() end
        end)
        if not ok then log("Error: " .. tostring(err)) end
    end)
    slot:SetHandler("OnDragReceive", function()
        local ok, err = pcall(onDrop)
        if not ok then log("Error: " .. tostring(err)) end
    end)
    slot:Show(true)
    return slot
end

local function setSlotIcon(slot, path)
    if not slot then return end
    pcall(function() F_SLOT.SetIconBackGround(slot, path) end)
end

local function rememberIcon(id, path)
    id = tonumber(id)
    if id and type(path) == "string" and path ~= "" then iconCache[id] = path end
end

-- The game's own path is preferred; the stored "/" copy is the last resort.
local function iconFor(item)
    local id = tonumber(item.id)
    if id and iconCache[id] then return iconCache[id] end
    if id then
        local info = itemInfo(id)
        if info and type(info.path) == "string" and info.path ~= "" then
            iconCache[id] = info.path
            return info.path
        end
        for slot = 1, bagCapacity() do
            local ok, bagInfo = pcall(api.Bag.GetBagItemInfo, api.Bag, 1, slot)
            if ok and type(bagInfo) == "table" and tonumber(bagInfo.itemType) == id and bagInfo.path then
                rememberIcon(id, bagInfo.path)
                return bagInfo.path
            end
        end
    end
    if item.path and item.path ~= "" then return item.path end
    return nil
end

local function makeDraggable(window, width, xKey, yKey)
    local handle = window:CreateChildWidget("emptywidget", window:GetId() .. "_drag", 0, true)
    handle:SetExtent(width - 45, 38)
    handle:AddAnchor("TOPLEFT", window, 0, 0)
    function handle:OnDragStart()
        window:StartMoving()
        api.Cursor:ClearCursor()
        api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
    end
    handle:SetHandler("OnDragStart", handle.OnDragStart)
    function handle:OnDragStop()
        window:StopMovingOrSizing()
        api.Cursor:ClearCursor()
        state[xKey], state[yKey] = window:GetEffectiveOffset()
        save()
    end
    handle:SetHandler("OnDragStop", handle.OnDragStop)
    handle:EnableDrag(true)
    handle:Show(true)
end

local function makePaperWindow(id, title, width, height, xKey, yKey)
    local window = api.Interface:CreateEmptyWindow(id)
    window:SetExtent(width, height)
    local paper = window:CreateColorDrawable(0.93, 0.86, 0.69, 0.98, "background")
    paper:AddAnchor("TOPLEFT", window, 0, 0)
    paper:AddAnchor("BOTTOMRIGHT", window, 0, 0)
    window:RemoveAllAnchors()
    if state[xKey] and state[yKey] then
        window:AddAnchor("TOPLEFT", "UIParent", state[xKey], state[yKey])
    else
        local screenW = tonumber(api.Interface:GetScreenWidth()) or 1920
        local screenH = tonumber(api.Interface:GetScreenHeight()) or 1080
        window:AddAnchor("TOPLEFT", "UIParent", math.floor((screenW - width) / 2), math.floor((screenH - height) / 2))
    end
    makeLabel(window, id .. "_heading", title, 12, 10, width - 24, 28, FONT_SIZE.LARGE or 20, ALIGN.CENTER)
    makeButton(window, id .. "_close", "X", width - 34, 7, 27, 27, function() window:Show(false) end)
    makeDraggable(window, width, xKey, yKey)
    return window
end

-- ============================================================
-- Item list editing
-- ============================================================

local function findTracked(list, id, name)
    for index, item in ipairs(list) do
        if (id and tonumber(item.id) == tonumber(id)) or (name ~= "" and sameName(item.name, name)) then
            return index, item
        end
    end
    return nil
end


-- Puts an item into slot `index` of the current list (replacing what was
-- there) or, with no index, into the first free slot. Recorded history stays.
local function setItem(index, id, name, path)
    local list = itemsOf(state.mode)
    name = clean(trim(name))
    if name == "" and id then
        local info = itemInfo(id)
        name = clean(info and info.name or ("Item " .. fmt(id)))
        path = path or (info and info.path)
    end
    if name == "" then setStatus("Nothing to add.") return end
    local existing = findTracked(list, id, name)
    if existing and existing ~= index then
        setStatus("Already in slot " .. existing .. ": " .. name)
        return
    end
    rememberIcon(id, path)
    local entry = {id = id and fmt(id) or "", name = name, path = safePath(path)}
    local old = index and list[index]
    if old then
        if tonumber(old.id) == tonumber(id) then entry.unitNet = old.unitNet end
        list[index] = entry
    else
        local slots = slotCount(state.mode)
        if #list >= slots then
            -- A full list grows by one slot instead of refusing the item.
            if slots >= C.MAX_SLOTS then setStatus("All " .. C.MAX_SLOTS .. " slots are taken.") return end
            state.slotCount[state.mode] = slots + 1
        end
        table.insert(list, entry)
    end
    save()
    setStatus((state.mode == "buy" and "Tracking purchases of: " or "Tracking sales of: ") .. name
        .. (entry.id ~= "" and (" (ID " .. entry.id .. ")") or ""))
    refresh()
end

local function removeItem(index)
    local list = itemsOf(state.mode)
    local item = list[index]
    if not item then return end
    table.remove(list, index)
    save()
    setStatus("Stopped tracking: " .. tostring(item.name) .. " (its history stays)")
    refresh()
end

local function dropOnSlot(index)
    local list = itemsOf(state.mode)
    local info = pickedBagItem()
    if not info then
        local item = list[index]
        if item then
            setStatus(tostring(item.name) .. "  ID " .. (item.id ~= "" and item.id or "?") .. "  (right-click to remove)")
        else
            setStatus("Drag an item from your bag onto this slot.")
        end
        return
    end
    pcall(api.Cursor.ClearCursor, api.Cursor)
    setItem(list[index] and index or nil, tonumber(info.itemType), info.name, info.path)
end

local function bagIdByName(name)
    for slot = 1, bagCapacity() do
        local ok, info = pcall(api.Bag.GetBagItemInfo, api.Bag, 1, slot)
        if ok and type(info) == "table" and sameName(info.name, name) and tonumber(info.itemType) then
            return tonumber(info.itemType), info.name, info.path
        end
    end
    return nil
end

local function addFromText()
    local text = trim(ui.itemEdit:GetText())
    if text == "" then setStatus("Type an item ID or exact name first.") return end
    local id = tonumber(text)
    if id then
        local info = itemInfo(id)
        if not info then setStatus("Unknown item ID " .. text) return end
        setItem(nil, id, info.name, info.path)
    else
        -- An item that is in the bag right now gives us its ID as well, which
        -- is more reliable than matching by name.
        local bagId, bagName, bagPath = bagIdByName(text)
        setItem(nil, bagId, bagName or text, bagPath)
    end
    ui.itemEdit:SetText("")
end

-- ============================================================
-- Recording sales and purchases
-- ============================================================

-- One sale can be reported both by AUCTION_BOUGHT_BY_SOMEONE and by a chat
-- notice; the second report only fills in what the first was missing.
local function recordSale(item, count, price, src)
    local ms = nowMs()
    if lastRecorded and lastRecorded.src ~= src and ms - lastRecorded.ms < C.DEDUP_MS
        and lastRecorded.sale.item == item.name then
        local sale = lastRecorded.sale
        if tostring(sale.gross) == "" and price then sale.gross = fmt(price) end
        if (tonumber(sale.count) or 1) < (count or 1) then sale.count = fmt(count) end
        lastRecorded = nil
        save()
        refresh()
        return
    end
    local t = now()
    local sale = {
        item = item.name, itemId = tostring(item.id or ""),
        count = fmt(count or 1),
        gross = price and fmt(price) or "", net = "",
        soldAt = t.text, soldDay = t.day, soldEpoch = t.epoch,
        collectedAt = "", collectedDay = "", collectedEpoch = "",
        src = src,
    }
    table.insert(state.sales, sale)
    while #state.sales > C.MAX_RECORDS do table.remove(state.sales, 1) end
    lastRecorded = {sale = sale, ms = ms, src = src}
    log("Sold " .. item.name .. " x" .. fmt(count or 1) .. (price and (" for " .. formatCopper(price)) or "") .. " (" .. src .. ")")
    save()
    refresh()
end

-- Same merging rule as sales: a chat notice and the bag/wallet change of one
-- purchase leave one record.
local function recordBuy(item, count, cost, src, when)
    local ms = nowMs()
    if lastBuy and lastBuy.src ~= src and ms - lastBuy.ms < C.DEDUP_MS and lastBuy.buy.item == item.name then
        local buy = lastBuy.buy
        if tostring(buy.cost) == "" and cost then buy.cost = fmt(cost) end
        if (tonumber(buy.count) or 1) < (count or 1) then buy.count = fmt(count) end
        lastBuy = nil
        save()
        refresh()
        return true
    end
    -- An auction purchase is dated when it was bought, not when its mail
    -- was taken.
    local t = when or now()
    local buy = {
        item = item.name, itemId = tostring(item.id or ""),
        count = fmt(count or 1), cost = cost and fmt(cost) or "",
        at = t.text, day = t.day, epoch = t.epoch, src = src,
    }
    table.insert(state.buys, buy)
    while #state.buys > C.MAX_RECORDS do table.remove(state.buys, 1) end
    lastBuy = {buy = buy, ms = ms, src = src}
    log("Bought " .. item.name .. " x" .. fmt(count or 1) .. (cost and (" for " .. formatCopper(cost)) or "") .. " (" .. src .. ")")
    save()
    refresh()
    return true
end

-- Takes the unclaimed spend closest in time to `ms` within `window`.
local function claimSpend(ms, window)
    local best, bestGap
    for _, spend in ipairs(recentSpends) do
        local gap = math.abs(spend.ms - ms)
        if not spend.used and gap <= window and (not bestGap or gap < bestGap) then
            best, bestGap = spend, gap
        end
    end
    if best then
        best.used = true
        return best.amount
    end
    return nil
end

local function auctionSpendTotal()
    local total = newMoney()
    for _, spend in ipairs(state.auctionSpends) do moneyAdd(total, tonumber(spend.amount) or 0) end
    return total
end

-- Picks the waiting auction purchase that fits this item best: the one
-- closest to its average price per unit, or the oldest for a new item.
local function takeAuctionSpend(item, count)
    local _, _, avg = buyStats(item)
    local bestIndex, bestDiff
    for index, spend in ipairs(state.auctionSpends) do
        local unit = (tonumber(spend.amount) or 0) / math.max(count, 1)
        if not avg then
            bestIndex = bestIndex or index
        elseif unit >= avg * C.AUCTION_UNIT_MIN and unit <= avg * C.AUCTION_UNIT_MAX then
            local diff = math.abs(unit - avg)
            if not bestDiff or diff < bestDiff then bestIndex, bestDiff = index, diff end
        end
    end
    if not bestIndex then return nil end
    return table.remove(state.auctionSpends, bestIndex)
end

-- The purchase mail appeared: the spend just before it was an auction buy.
local function onInboxUpdate()
    local ms = nowMs()
    if ms - lastSentMailMs <= C.BUY_PAIR_MS then return end
    for _, spend in ipairs(recentSpends) do
        local gap = ms - spend.ms
        if not spend.used and gap <= C.AUCTION_MAIL_AFTER_MS and gap >= -C.AUCTION_MAIL_BEFORE_MS then
            spend.used = true
            local t = spend.when
            table.insert(state.auctionSpends, {amount = fmt(spend.amount), at = t.text, day = t.day, epoch = t.epoch})
            while #state.auctionSpends > C.MAX_AUCTION_SPENDS do table.remove(state.auctionSpends, 1) end
            debugNote("AH-BUY", "-" .. fmt(spend.amount) .. " waiting in mail")
            save()
            refresh()
        end
    end
end

local lastListing

local function listingRate()
    local rate = tonumber(state.listingRate)
    if rate and rate > 0.001 and rate < 0.2 then return rate end
    return LISTING.rate
end

-- REMOVED_ITEM(link, count, removeState, itemTaskType, ...) - seen in the
-- client: ('|i28298,3,0,...', 2, 'destroy', 45, '') for a lot of 2.
local function onItemRemoved(args)
    if tonumber(args[4]) ~= LISTING.task then return end
    local item = trackedById(state.items, linkId(args[1]))
    if not item then return end
    local count = math.max(math.floor(tonumber(args[2]) or 1), 1)
    local fee = claimSpend(nowMs(), C.BUY_PAIR_MS)
    local t = now()
    local listing = {
        item = item.name, itemId = tostring(item.id or ""), count = fmt(count),
        fee = fee and fmt(fee) or "", at = t.text, day = t.day, epoch = t.epoch,
    }
    table.insert(state.listings, listing)
    while #state.listings > LISTING.max do table.remove(state.listings, 1) end
    -- The deposit may leave the wallet a moment later; onSpend looks here.
    if not fee then lastListing = {listing = listing, ms = nowMs()} end
    log("Listed " .. item.name .. " x" .. count .. (fee and (", deposit " .. formatCopper(fee)) or ""))
    save()
    refresh()
end

-- The lot that sold: the open lot of this item whose deposit fits the price
-- best (deposit = 1% of the price), else the oldest one.
local function takeListing(item, price)
    local rate = listingRate()
    local bestIndex, bestScore
    for index, listing in ipairs(state.listings) do
        if recordBelongsTo(listing, item) then
            local fee = tonumber(listing.fee)
            local score = (fee and price) and math.abs(fee - price * rate) or 1000000000
            if not bestScore or score < bestScore then bestIndex, bestScore = index, score end
        end
    end
    if not bestIndex then return nil end
    local listing = table.remove(state.listings, bestIndex)
    local fee = tonumber(listing.fee)
    if fee and price and price > 0 and fee / price > 0.001 and fee / price < 0.2 then
        state.listingRate = string.format("%.5f", fee / price)
    end
    return listing
end

-- A lot of a selling item came back by mail: it did not sell (or was
-- cancelled), and its deposit is lost.
local function onListingReturned(item, count)
    for index, listing in ipairs(state.listings) do
        if recordBelongsTo(listing, item) and tonumber(listing.count) == count then
            table.remove(state.listings, index)
            local fee = tonumber(listing.fee)
            if fee and fee > 0 then
                local t = now()
                table.insert(state.fees, {
                    item = listing.item, itemId = listing.itemId, count = listing.count, fee = fmt(fee),
                    listedAt = listing.at, at = t.text, day = t.day, epoch = t.epoch,
                })
                while #state.fees > C.MAX_RECORDS do table.remove(state.fees, 1) end
            end
            log("Unsold lot came back: " .. tostring(listing.item) .. " x" .. tostring(listing.count)
                .. (fee and (", deposit lost " .. formatCopper(fee)) or ""))
            save()
            refresh()
            return
        end
    end
end

-- ADDED_ITEM(link, count, itemTaskType, ...) - seen in the client:
-- ('|i28305,0,0,...', 10, 46, '') when a mail attachment is taken.
local function onItemAdded(args)
    local link = type(args[1]) == "string" and args[1] or ""
    local id = linkId(link)
    local count = math.max(math.floor(tonumber(args[2]) or 1), 1)
    local task = tonumber(args[3])
    local item = trackedById(state.buyItems, id)
    if not item then
        local sellItem = trackedById(state.items, id)
        if sellItem and task == C.MAIL_ITEM_TASK then onListingReturned(sellItem, count) end
        return
    end
    local ms = nowMs()
    local cost = claimSpend(ms, C.BUY_PAIR_MS)
    if cost then
        recordBuy(item, count, cost, "shop")
        return
    end
    if task == C.MAIL_ITEM_TASK or ms - lastMailMs <= C.MAIL_ITEM_WINDOW_MS then
        local spend = takeAuctionSpend(item, count)
        if spend then
            recordBuy(item, count, tonumber(spend.amount), "auction",
                {text = spend.at, day = spend.day, epoch = spend.epoch})
        else
            debugNote("BAG", "+" .. count .. " " .. tostring(item.name) .. " from mail, no auction purchase waiting")
        end
        return
    end
    -- The money may change a moment later; onSpend looks here.
    table.insert(pendingArrivals, {item = item, count = count, ms = ms})
end

local function onSpend(amount)
    local ms = nowMs()
    if lastListing and ms - lastListing.ms <= C.BUY_PAIR_MS then
        lastListing.listing.fee = fmt(amount)
        lastListing = nil
        save()
        return
    end
    for index, arrival in ipairs(pendingArrivals) do
        if ms - arrival.ms <= C.BUY_PAIR_MS then
            table.remove(pendingArrivals, index)
            recordBuy(arrival.item, arrival.count, amount, "shop")
            return
        end
    end
    table.insert(recentSpends, {amount = amount, ms = ms, when = now()})
end

local function expireBuyState(ms)
    local index = 1
    while index <= #pendingArrivals do
        local arrival = pendingArrivals[index]
        if ms - arrival.ms > C.BUY_PAIR_MS then
            table.remove(pendingArrivals, index)
            debugNote("BAG", "+" .. arrival.count .. " " .. tostring(arrival.item.name) .. " with no money spent")
        else
            index = index + 1
        end
    end
    index = 1
    while index <= #recentSpends do
        local spend = recentSpends[index]
        if ms - spend.ms > C.SPEND_KEEP_MS then
            table.remove(recentSpends, index)
            if not spend.used then debugNote("SPEND", "-" .. fmt(spend.amount) .. " not linked to a tracked purchase") end
        else
            index = index + 1
        end
    end
    local nowEpoch = tonumber(now().epoch) or 0
    index = 1
    while index <= #state.listings do
        local epoch = tonumber(state.listings[index].epoch) or 0
        if nowEpoch > 0 and epoch > 0 and nowEpoch - epoch > LISTING.days * 86400 then
            table.remove(state.listings, index)
            save()
        else
            index = index + 1
        end
    end
    index = 1
    while index <= #state.auctionSpends do
        local epoch = tonumber(state.auctionSpends[index].epoch) or 0
        if nowEpoch > 0 and epoch > 0 and nowEpoch - epoch > C.AUCTION_SPEND_DAYS * 86400 then
            table.remove(state.auctionSpends, index)
            save()
        else
            index = index + 1
        end
    end
end

local function addManual()
    local list = itemsOf(state.mode)
    local text = trim(ui.manualItemEdit:GetText())
    local count = math.max(math.floor(tonumber(ui.manualCountEdit:GetText()) or 1), 1)
    local gold = tonumber((trim(ui.manualGoldEdit:GetText()):gsub(",", ".")))
    if not gold or gold <= 0 then setStatus("Enter the amount in gold, e.g. 12.5") return end
    local item = list[tonumber(text) or 0] or trackedById(list, text) or trackedByText(list, text)
    if not item and text ~= "" then
        -- A part of the name is enough, e.g. "superior".
        for _, candidate in ipairs(list) do
            if not item and tostring(candidate.name):lower():find(text:lower(), 1, true) then item = candidate end
        end
    end
    if not item then setStatus("Item: slot number, ID or name of an item in the list above.") return end
    local copper = fmt(gold * 10000)
    if state.mode == "buy" then
        local t = now()
        table.insert(state.buys, {
            item = item.name, itemId = tostring(item.id or ""), count = fmt(count), cost = copper,
            at = t.text, day = t.day, epoch = t.epoch, src = "manual",
        })
        while #state.buys > C.MAX_RECORDS do table.remove(state.buys, 1) end
        setStatus("Manual purchase added: " .. item.name .. " x" .. count .. " = " .. formatCopper(copper))
    else
        local t = now()
        table.insert(state.sales, {
            item = item.name, itemId = tostring(item.id or ""), count = fmt(count),
            gross = copper, net = copper,
            soldAt = t.text, soldDay = t.day, soldEpoch = t.epoch,
            collectedAt = t.text, collectedDay = t.day, collectedEpoch = t.epoch,
            src = "manual",
        })
        while #state.sales > C.MAX_RECORDS do table.remove(state.sales, 1) end
        item.unitNet = fmt(gold * 10000 / count)
        setStatus("Manual sale added: " .. item.name .. " x" .. count .. " = " .. formatCopper(copper))
    end
    save()
    ui.manualGoldEdit:SetText("")
    refresh()
end

-- ============================================================
-- Main window
-- ============================================================

local function shortTime(text)
    text = tostring(text or "")
    if #text >= 16 then return text:sub(6, 16) end
    return text
end

local PERIODS = {{"today", "Today"}, {"week", "7 days"}, {"month", "30 days"}, {"all", "All time"}}
local GRID_ROWS = {"Received", "In mail", "Spent", "Lost fees", "Net"}

-- Fixed part of the window above the slots, and the height of everything
-- below them (the lower panel moves down as slot rows are added).
local SLOTS_Y = 221
local SLOT_STEP = 50
local LOWER_H = 512

local itemPage = {sell = 1, buy = 1}

local function refreshGrid()
    local totals = computeTotals()
    for column, period in ipairs(PERIODS) do
        local bucket = totals[period[1]]
        ui.gridCells[1][column]:SetText(formatMoney(bucket.got))
        ui.gridCells[2][column]:SetText(moneyValue(bucket.wait) > 0 and ("~" .. formatMoney(bucket.wait)) or "-")
        ui.gridCells[3][column]:SetText(formatMoney(bucket.spent))
        ui.gridCells[4][column]:SetText(moneyValue(bucket.fees) > 0 and formatMoney(bucket.fees) or "-")
        ui.gridCells[5][column]:SetText(formatMoney(moneySub(moneySub(bucket.got, bucket.spent), bucket.fees)))
    end
end

local function sellRowText(index, item)
    local sold, got, wait, lost = sellStats(item)
    local text = index .. ". " .. tostring(item.name) .. "   sold " .. sold .. "   got " .. formatMoney(got)
    if moneyValue(wait) > 0 then text = text .. "   mail ~" .. formatMoney(wait) end
    if moneyValue(lost) > 0 then text = text .. "   lost fees " .. formatMoney(lost) end
    return text
end

local function buyRowText(index, item)
    local bought, spent, avg = buyStats(item)
    local text = index .. ". " .. tostring(item.name) .. "   bought " .. bought .. "   spent " .. formatMoney(spent)
    if avg then text = text .. "   avg " .. formatCopper(avg) .. "/pc" end
    return text
end

local function saleRecordText(sale)
    local amount
    if saleGot(sale) then
        amount = formatCopper(sale.net) .. "  got " .. shortTime(sale.collectedAt)
    elseif saleWaiting(sale) > 0 then
        amount = "~" .. formatCopper(saleWaiting(sale)) .. "  in mail"
    else
        amount = "price unknown, in mail"
    end
    return shortTime(sale.soldAt) .. "  " .. tostring(sale.item) .. " x" .. tostring(sale.count or 1) .. "  " .. amount
end

local function buyRecordText(buy)
    local cost = tonumber(buy.cost) and ("-" .. formatCopper(buy.cost)) or "cost unknown"
    return shortTime(buy.at) .. "  " .. tostring(buy.item) .. " x" .. tostring(buy.count or 1) .. "  " .. cost .. "  (" .. tostring(buy.src) .. ")"
end

-- Moves the lower panel under the last row of slots and fits the window.
local function layoutMain(slots)
    local rows = math.max(math.ceil(slots / C.SLOTS_PER_ROW), 1)
    if rows == ui.shownSlotRows then return end
    ui.shownSlotRows = rows
    local lowerY = SLOTS_Y + rows * SLOT_STEP + 2
    ui.lowerPanel:RemoveAllAnchors()
    ui.lowerPanel:AddAnchor("TOPLEFT", ui.mainWin, 0, lowerY)
    ui.mainWin:SetExtent(C.WIN_W, lowerY + LOWER_H)
end

refresh = function()
    if not ui.mainWin then return end
    refreshGrid()
    local buying = state.mode == "buy"
    local list = itemsOf(state.mode)
    local slots = slotCount(state.mode)
    ui.sellModeBtn:SetText(buying and "Selling" or "> Selling <")
    ui.buyModeBtn:SetText(buying and "> Buying <" or "Buying")
    ui.itemsHeader:SetText(buying and "Items you BUY (drag from the bag; right-click a slot removes)"
        or "Items you SELL (drag from the bag; right-click a slot removes)")
    ui.slotCountLabel:SetText(#list .. " / " .. slots)
    local waiting = #state.auctionSpends
    ui.recordsHeader:SetText(buying and ("Recent purchases" .. (waiting > 0 and ("   (auction buys still in mail: "
        .. waiting .. ", " .. formatMoney(auctionSpendTotal()) .. ")") or ""))
        or ("Recent sales" .. (#state.listings > 0 and ("   (lots on the auction: " .. #state.listings .. ")") or "")))
    ui.manualHeader:SetText(buying and "Manual purchase (slot#, ID or name / count / gold spent):"
        or "Manual sale (slot#, ID or name / count / gold received):")
    ui.manualAddBtn:SetText(buying and "Add purchase" or "Add sale")

    layoutMain(slots)
    for index = 1, C.MAX_SLOTS do
        local slot = ui.itemSlots[index]
        if slot then
            local item = list[index]
            setSlotIcon(slot, item and iconFor(item) or nil)
            slot:Show(index <= slots)
        end
    end

    local pages = math.max(math.ceil(#list / C.ITEM_PAGE_ROWS), 1)
    local page = math.min(math.max(itemPage[state.mode] or 1, 1), pages)
    itemPage[state.mode] = page
    for row = 1, C.ITEM_PAGE_ROWS do
        local index = (page - 1) * C.ITEM_PAGE_ROWS + row
        local item = list[index]
        local widgets = ui.itemRows[row]
        widgets.index = index
        if item then
            widgets.label:SetText(buying and buyRowText(index, item) or sellRowText(index, item))
            widgets.label:Show(true)
            widgets.remove:Show(true)
        else
            widgets.label:SetText("")
            widgets.label:Show(false)
            widgets.remove:Show(false)
        end
    end
    local paged = pages > 1
    ui.pageLabel:SetText(paged and ("Page " .. page .. " / " .. pages) or "")
    ui.pagePrev:Show(paged)
    ui.pageNext:Show(paged)

    local records = recordsOf(state.mode)
    for index = 1, C.RECORD_ROWS do
        local record = records[#records - index + 1]
        if record then
            ui.recordRows[index]:SetText(buying and buyRecordText(record) or saleRecordText(record))
        else
            ui.recordRows[index]:SetText(index == 1 and (buying and "No purchases recorded yet." or "No sales recorded yet.") or "")
        end
    end

    if ui.debugBtn then ui.debugBtn:SetText(state.debug and "Debug: On" or "Debug: Off") end
end

local toggleDebugWin

local function setMode(mode)
    state.mode = mode
    save()
    setStatus("")
    refresh()
    if refreshDebug then refreshDebug() end
end

-- "+" adds an empty slot; "-" removes the last slot, only while it is empty.
local function changeSlots(delta)
    local list = itemsOf(state.mode)
    local slots = slotCount(state.mode)
    if delta > 0 then
        if slots >= C.MAX_SLOTS then setStatus("At most " .. C.MAX_SLOTS .. " slots.") return end
        slots = slots + 1
    else
        if slots <= #list then
            setStatus("The last slot holds " .. tostring(list[slots].name) .. ". Right-click it to clear it first.")
            return
        end
        if slots <= 1 then return end
        slots = slots - 1
    end
    state.slotCount[state.mode] = slots
    save()
    setStatus("")
    refresh()
end

local function changePage(delta)
    itemPage[state.mode] = (itemPage[state.mode] or 1) + delta
    refresh()
end

local function createMainWindow()
    ui.mainWin = makePaperWindow("auction_income_main" .. idSuffix, "Auction Income", C.WIN_W, C.WIN_H, "winX", "winY")

    ui.sellModeBtn = makeButton(ui.mainWin, "ai_mode_sell", "Selling", 16, 42, 130, 26, function() setMode("sell") end)
    ui.buyModeBtn = makeButton(ui.mainWin, "ai_mode_buy", "Buying", 152, 42, 130, 26, function() setMode("buy") end)

    local gridY, colX, colW = 76, 100, 128
    for column, period in ipairs(PERIODS) do
        makeLabel(ui.mainWin, "ai_grid_h" .. column, period[2], colX + (column - 1) * colW, gridY, colW, 18, 13, ALIGN.CENTER)
    end
    for row, title in ipairs(GRID_ROWS) do
        local y = gridY + row * 19
        makeLabel(ui.mainWin, "ai_grid_r" .. row, title, 16, y, 84, 18, 13)
        ui.gridCells[row] = {}
        for column = 1, #PERIODS do
            ui.gridCells[row][column] = makeLabel(ui.mainWin, "ai_grid_" .. row .. "_" .. column, "",
                colX + (column - 1) * colW, y, colW, 18, 13, ALIGN.CENTER)
        end
    end

    ui.itemsHeader = makeLabel(ui.mainWin, "ai_items_h", "", 16, SLOTS_Y - 24, C.WIN_W - 190, 22, 14)
    makeLabel(ui.mainWin, "ai_slots_t", "Slots:", C.WIN_W - 172, SLOTS_Y - 24, 44, 22, 13)
    ui.slotCountLabel = makeLabel(ui.mainWin, "ai_slots_n", "", C.WIN_W - 128, SLOTS_Y - 24, 48, 22, 13, ALIGN.CENTER)
    makeButton(ui.mainWin, "ai_slot_minus", "-", C.WIN_W - 78, SLOTS_Y - 27, 28, 24, function() changeSlots(-1) end)
    makeButton(ui.mainWin, "ai_slot_plus", "+", C.WIN_W - 46, SLOTS_Y - 27, 28, 24, function() changeSlots(1) end)
    local ok, err = pcall(function()
        for index = 1, C.MAX_SLOTS do
            local column = (index - 1) % C.SLOTS_PER_ROW
            local row = math.floor((index - 1) / C.SLOTS_PER_ROW)
            ui.itemSlots[index] = makeItemSlot(ui.mainWin, "ai_slot_" .. index, 16 + column * SLOT_STEP, SLOTS_Y + row * SLOT_STEP,
                function() dropOnSlot(index) end,
                function() removeItem(index) end)
        end
    end)
    if not ok then log("Item slots unavailable, use ID/name instead: " .. tostring(err)) end

    -- Everything below the slots lives in one panel, so adding a row of
    -- slots only has to move this panel.
    ui.lowerPanel = ui.mainWin:CreateChildWidget("emptywidget", "ai_lower", 0, true)
    ui.lowerPanel:SetExtent(C.WIN_W, LOWER_H)
    ui.lowerPanel:Show(true)

    for row = 1, C.ITEM_PAGE_ROWS do
        local y = 2 + (row - 1) * 22
        local widgets = {index = row}
        widgets.label = makeLabel(ui.lowerPanel, "ai_item_" .. row, "", 16, y, C.WIN_W - 70, 20, 13)
        widgets.remove = makeButton(ui.lowerPanel, "ai_item_rm_" .. row, "X", C.WIN_W - 46, y - 1, 26, 20,
            function() removeItem(widgets.index) end)
        ui.itemRows[row] = widgets
    end
    local pageY = 2 + C.ITEM_PAGE_ROWS * 22
    ui.pagePrev = makeButton(ui.lowerPanel, "ai_page_prev", "<", 16, pageY, 36, 24, function() changePage(-1) end)
    ui.pageNext = makeButton(ui.lowerPanel, "ai_page_next", ">", 56, pageY, 36, 24, function() changePage(1) end)
    ui.pageLabel = makeLabel(ui.lowerPanel, "ai_page", "", 100, pageY + 2, 200, 20, 13)

    local addY = pageY + 32
    ui.itemEdit = makeEdit(ui.lowerPanel, "ai_item_edit", 16, addY, 250, 28)
    makeButton(ui.lowerPanel, "ai_add", "Add ID/name", 272, addY, 130, 28, addFromText)
    makeButton(ui.lowerPanel, "ai_ids", "Item IDs / Debug", 408, addY, 160, 28, function() toggleDebugWin() end)

    local recordsY = addY + 40
    ui.recordsHeader = makeLabel(ui.lowerPanel, "ai_records_h", "", 16, recordsY, C.WIN_W - 32, 22, FONT_SIZE.MIDDLE or 16)
    for index = 1, C.RECORD_ROWS do
        ui.recordRows[index] = makeLabel(ui.lowerPanel, "ai_record_" .. index, "", 16, recordsY + 24 + (index - 1) * 22, C.WIN_W - 32, 20, 13)
    end

    local manualY = recordsY + 24 + C.RECORD_ROWS * 22 + 8
    ui.manualHeader = makeLabel(ui.lowerPanel, "ai_manual_h", "", 16, manualY, C.WIN_W - 32, 20, 13)
    ui.manualItemEdit = makeEdit(ui.lowerPanel, "ai_m_item", 16, manualY + 22, 220, 28)
    ui.manualCountEdit = makeEdit(ui.lowerPanel, "ai_m_count", 242, manualY + 22, 60, 28)
    ui.manualCountEdit:SetText("1")
    ui.manualGoldEdit = makeEdit(ui.lowerPanel, "ai_m_gold", 308, manualY + 22, 110, 28)
    ui.manualAddBtn = makeButton(ui.lowerPanel, "ai_m_add", "Add sale", 424, manualY + 22, 130, 28, addManual)

    local bottomY = manualY + 60
    ui.debugBtn = makeButton(ui.lowerPanel, "ai_debug", "Debug: Off", 16, bottomY, 120, 26, function()
        state.debug = not state.debug
        save()
        setStatus(state.debug and ("Debug log: Addon/" .. DEBUG_FILE) or "Debug log off")
        refresh()
        refreshDebug()
    end)
    ui.statusLabel = makeLabel(ui.lowerPanel, "ai_status", "", 146, bottomY + 3, C.WIN_W - 160, 22, 13)

    ui.mainWin:Show(false)
end

-- ============================================================
-- Debug window: item IDs and recent events
-- ============================================================

local function scanBag()
    bagList = {}
    local seen = {}
    for slot = 1, bagCapacity() do
        local ok, info = pcall(api.Bag.GetBagItemInfo, api.Bag, 1, slot)
        local id = ok and type(info) == "table" and tonumber(info.itemType)
        if id and id > 0 and not seen[id] then
            seen[id] = true
            bagList[#bagList + 1] = {id = id, name = tostring(info.name or "?"), path = info.path}
        end
    end
    bagPage = 1
    refreshDebug()
end

local function describeItem(id, name)
    return tostring(name) .. "   ID " .. fmt(id) .. "   in bag: " .. bagCount(id)
end

local function inspectDrop()
    local info = pickedBagItem()
    if not info then
        if ui.dbgInfoLabel then ui.dbgInfoLabel:SetText("Drag an item from your bag onto the slot.") end
        return
    end
    pcall(api.Cursor.ClearCursor, api.Cursor)
    dbgPicked = {id = tonumber(info.itemType), name = info.name, path = info.path}
    setSlotIcon(ui.dbgSlot, info.path)
    local text = describeItem(dbgPicked.id, dbgPicked.name)
    ui.dbgInfoLabel:SetText(text)
    log(text)
    debugNote("ITEM", dump(info))
end

refreshDebug = function()
    if not ui.debugWin then return end
    local list = itemsOf(state.mode)
    local pages = math.max(math.ceil(#bagList / C.BAG_ROWS), 1)
    if bagPage > pages then bagPage = pages end
    for index = 1, C.BAG_ROWS do
        local entry = bagList[(bagPage - 1) * C.BAG_ROWS + index]
        local row = ui.dbgBagRows[index]
        if entry then
            local tracked = trackedById(list, entry.id) and "  (tracked)" or ""
            row.label:SetText(fmt(entry.id) .. "   " .. entry.name .. "   x" .. bagCount(entry.id) .. tracked)
            row.add:Show(tracked == "")
        else
            row.label:SetText(index == 1 and #bagList == 0 and "Press 'Scan bag' to list the IDs of everything in your bag." or "")
            row.add:Show(false)
        end
    end
    ui.dbgPageLabel:SetText(#bagList > 0 and ("Page " .. bagPage .. " / " .. pages .. "   (" .. #bagList .. " kinds)") or "")
    for index = 1, C.LOG_ROWS do
        local line = debugLog[#debugLog - C.LOG_ROWS + index]
        line = line and tostring(line) or ""
        if #line > 110 then line = line:sub(1, 107) .. "..." end
        ui.dbgLogRows[index]:SetText(line)
    end
    ui.dbgProbeLabel:SetText("Mail API for addons: " .. probeSummary .. (state.debug and "" or "   (debug log is off)"))
end

local function createDebugWindow()
    ui.debugWin = makePaperWindow("auction_income_debug" .. idSuffix, "Item IDs / Debug", C.DBG_W, C.DBG_H, "dbgX", "dbgY")

    makeLabel(ui.debugWin, "aid_drop_h", "Drag any item here to see its ID ('Track it' adds it to the open list):", 16, 44, C.DBG_W - 32, 20, 14)
    local ok = pcall(function()
        ui.dbgSlot = makeItemSlot(ui.debugWin, "aid_slot", 16, 68, inspectDrop, function()
            dbgPicked = nil
            setSlotIcon(ui.dbgSlot, nil)
            ui.dbgInfoLabel:SetText("")
        end)
    end)
    if not ok then ui.dbgSlot = nil end
    ui.dbgInfoLabel = makeLabel(ui.debugWin, "aid_info", "", 70, 72, C.DBG_W - 210, 22, 14)
    makeButton(ui.debugWin, "aid_track", "Track it", C.DBG_W - 130, 70, 110, 28, function()
        if dbgPicked then setItem(nil, dbgPicked.id, dbgPicked.name, dbgPicked.path); refreshDebug() end
    end)

    makeLabel(ui.debugWin, "aid_bag_h", "Items in your bag (ID, name, count):", 16, 122, 330, 20, 14)
    makeButton(ui.debugWin, "aid_scan", "Scan bag", C.DBG_W - 130, 118, 110, 26, scanBag)
    for index = 1, C.BAG_ROWS do
        local y = 148 + (index - 1) * 24
        local row = {}
        row.label = makeLabel(ui.debugWin, "aid_bag_" .. index, "", 16, y + 2, C.DBG_W - 80, 20, 13)
        row.add = makeButton(ui.debugWin, "aid_bag_add_" .. index, "+", C.DBG_W - 50, y, 30, 22, function()
            local entry = bagList[(bagPage - 1) * C.BAG_ROWS + index]
            if entry then setItem(nil, entry.id, entry.name, entry.path); refreshDebug() end
        end)
        row.add:Show(false)
        ui.dbgBagRows[index] = row
    end
    local pageY = 148 + C.BAG_ROWS * 24 + 4
    makeButton(ui.debugWin, "aid_prev", "<", 16, pageY, 40, 26, function()
        if bagPage > 1 then bagPage = bagPage - 1; refreshDebug() end
    end)
    makeButton(ui.debugWin, "aid_next", ">", 62, pageY, 40, 26, function()
        if bagPage * C.BAG_ROWS < #bagList then bagPage = bagPage + 1; refreshDebug() end
    end)
    ui.dbgPageLabel = makeLabel(ui.debugWin, "aid_page", "", 112, pageY + 3, 300, 20, 13)

    local logY = pageY + 38
    makeLabel(ui.debugWin, "aid_log_h", "Recent events (full log: Addon/" .. DEBUG_FILE .. ")", 16, logY, C.DBG_W - 32, 20, 14)
    for index = 1, C.LOG_ROWS do
        ui.dbgLogRows[index] = makeLabel(ui.debugWin, "aid_log_" .. index, "", 16, logY + 22 + (index - 1) * 19, C.DBG_W - 32, 18, 11)
    end
    ui.dbgProbeLabel = makeLabel(ui.debugWin, "aid_probe", "", 16, logY + 26 + C.LOG_ROWS * 19, C.DBG_W - 32, 20, 12)

    ui.debugWin:Show(false)
end

toggleDebugWin = function()
    if not ui.debugWin then return end
    local show = not ui.debugWin:IsVisible()
    if show then refreshDebug() end
    ui.debugWin:Show(show)
end

local function toggleMain()
    if not ui.mainWin then return end
    local show = not ui.mainWin:IsVisible()
    if show then refresh() end
    ui.mainWin:Show(show)
end

-- Position of the button inside the mailbox: right after the three buttons
-- at its bottom left (delete, read, take all), as in the client's layout.
local MAIL_BTN_X, MAIL_BTN_Y, MAIL_BTN_W, MAIL_BTN_H = 218, -20, 100, 30

-- The addon sandbox exposes only some client windows through UIC. Any whose
-- name says MAIL (but not the marketplace goods mail) is tried.
local function findMailFrame()
    if type(UIC) ~= "table" then return nil end
    for key, id in pairs(UIC) do
        local name = tostring(key):upper()
        if name:find("MAIL", 1, true) and not name:find("COMMERCIAL", 1, true) and not name:find("GOODS", 1, true) then
            local ok, frame = pcall(function() return ADDON:GetContent(id) end)
            if ok and frame then return frame, tostring(key) end
        end
    end
    return nil
end

-- Client widgets outlive an addon reload, so the button is kept on the frame
-- and only its click handler is replaced (as Dawnsdrop Check does).
local function attachMailButton()
    if ui.mailBtn then return true end
    local frame, key = findMailFrame()
    if not frame then return false end
    local button = frame.auctionIncomeBtn
    if type(button) ~= "table" and type(button) ~= "userdata" then
        button = frame:CreateChildWidget("button", "auction_income_mail_btn", 0, true)
        frame.auctionIncomeBtn = button
    end
    if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(button, BUTTON_BASIC.DEFAULT) end
    button:SetExtent(MAIL_BTN_W, MAIL_BTN_H)
    button:RemoveAllAnchors()
    button:AddAnchor("BOTTOMLEFT", frame, MAIL_BTN_X, MAIL_BTN_Y)
    button:SetText("Auction $")
    button:SetHandler("OnClick", function() toggleMain() end)
    button:Show(true)
    ui.mailBtn = button
    debugNote("PROBE", "mailbox button attached to UIC." .. key)
    return true
end

local function createFloatingButton()
    ui.floatingBtn = api.Interface:CreateEmptyWindow("auction_income_floating" .. idSuffix, "UIParent")
    ui.floatingBtn:SetExtent(130, 40)
    ui.floatingBtn:RemoveAllAnchors()
    ui.floatingBtn:AddAnchor("TOPLEFT", "UIParent", state.buttonX, state.buttonY)
    local background = ui.floatingBtn:CreateNinePartDrawable(TEXTURE_PATH.HUD, "background")
    background:SetTextureInfo("bg_quest")
    background:SetColor(0, 0, 0, 0.6)
    background:AddAnchor("TOPLEFT", ui.floatingBtn, 0, 0)
    background:AddAnchor("BOTTOMRIGHT", ui.floatingBtn, 0, 0)
    local button = api.Interface:CreateWidget("button", "auction_income_button" .. idSuffix, ui.floatingBtn)
    api.Interface:ApplyButtonSkin(button, BUTTON_BASIC.DEFAULT)
    button:SetExtent(120, 28)
    button:AddAnchor("TOPLEFT", ui.floatingBtn, 5, 6)
    button:SetText("Auction $")
    button:SetHandler("OnClick", function() toggleMain() end)
    button:Show(true)
    function ui.floatingBtn:OnDragStart()
        if api.Input:IsShiftKeyDown() then
            ui.floatingBtn:StartMoving()
            api.Cursor:ClearCursor()
            api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
        end
    end
    ui.floatingBtn:SetHandler("OnDragStart", ui.floatingBtn.OnDragStart)
    function ui.floatingBtn:OnDragStop()
        local x, y = ui.floatingBtn:GetEffectiveOffset()
        state.buttonX, state.buttonY = x, y
        ui.floatingBtn:StopMovingOrSizing()
        api.Cursor:ClearCursor()
        save()
    end
    ui.floatingBtn:SetHandler("OnDragStop", ui.floatingBtn.OnDragStop)
    ui.floatingBtn:EnableDrag(true)
    ui.floatingBtn:Show(true)
end

-- ============================================================
-- Sale and purchase detection
-- ============================================================

local function rememberOther(price, count)
    -- Untracked sales are remembered only so their mail money is not mistaken
    -- for a tracked sale of a similar price. The event and the chat notice of
    -- the same sale must not leave two entries.
    local ms = nowMs()
    if lastOther and lastOther.gross == fmt(price) and ms - lastOther.ms < C.DEDUP_MS then return end
    lastOther = {gross = fmt(price), ms = ms}
    table.insert(state.other, {gross = fmt(price), count = fmt(count or 1), at = now().epoch})
    while #state.other > C.MAX_OTHER do table.remove(state.other, 1) end
    save()
end

local ID_KEYS = {"itemType", "itemId", "item_type", "templateId", "type"}
local NAME_KEYS = {"name", "itemName", "item_name"}
local PRICE_KEYS = {"price", "money", "directPrice", "buyoutPrice", "bidPrice", "salePrice", "amount", "copper"}
local COUNT_KEYS = {"stackCount", "stack_count", "itemCount", "count", "stack", "quantity"}


-- The argument layout of the auction events is not documented for AAC, so
-- this accepts tables with named fields, item links, numeric strings and
-- plain numbers. The raw arguments go to the debug log for checking.
local function parseAuctionArgs(args, list)
    local sale = {}
    local nums, texts = {}, {}
    local function scanTable(t)
        for _, key in ipairs(ID_KEYS) do
            if not sale.id and tonumber(t[key]) then sale.id = tonumber(t[key]) end
        end
        for _, key in ipairs(NAME_KEYS) do
            if not sale.name and type(t[key]) == "string" then sale.name = t[key] end
        end
        for _, key in ipairs(PRICE_KEYS) do
            if not sale.price and tonumber(t[key]) then sale.price = tonumber(t[key]) end
        end
        for _, key in ipairs(COUNT_KEYS) do
            if not sale.count and tonumber(t[key]) then sale.count = tonumber(t[key]) end
        end
    end
    for index = 1, C.MAX_ARGS do
        local value = args[index]
        if type(value) == "table" then
            scanTable(value)
        elseif type(value) == "number" then
            nums[#nums + 1] = value
        elseif type(value) == "string" and value ~= "" then
            local id = linkId(value)
            if id then
                sale.id = sale.id or id
                texts[#texts + 1] = value
            elseif tonumber(value) then
                nums[#nums + 1] = tonumber(value)
            else
                texts[#texts + 1] = value
            end
        end
    end
    for index, value in ipairs(nums) do
        if (sale.id and value == sale.id) or (not sale.id and trackedById(list, value)) then
            sale.id = value
            table.remove(nums, index)
            break
        end
    end
    if not sale.price then
        for _, value in ipairs(nums) do
            if value > 0 and (not sale.price or value > sale.price) then sale.price = value end
        end
    end
    if not sale.count then
        local candidates = {}
        for _, value in ipairs(nums) do
            if value > 0 and value ~= sale.price and value <= 10000 and math.floor(value) == value then
                candidates[#candidates + 1] = value
            end
        end
        sale.count = #candidates == 1 and candidates[1] or 1
    end
    sale.text = table.concat(texts, " ")
    sale.item = trackedById(list, sale.id) or trackedByText(list, sale.name) or trackedByText(list, sale.text)
    return sale
end

local function onAuctionSold(args)
    local key = dumpArgs(args)
    local ms = nowMs()
    if key == lastSaleKey and ms - lastSaleMs < 3000 then return end
    lastSaleKey, lastSaleMs = key, ms

    local sale = parseAuctionArgs(args, state.items)
    if sale.item then
        -- Learn the ID of an item that was added by name only.
        if tostring(sale.item.id or "") == "" and sale.id then sale.item.id = fmt(sale.id) end
        -- The sold event carries no stack size; the lot it came from does.
        local listing = takeListing(sale.item, sale.price)
        recordSale(sale.item, listing and tonumber(listing.count) or sale.count, sale.price, "auction")
    elseif sale.price then
        rememberOther(sale.price, sale.count)
    end
end

-- AUCTION_BIDDEN may be the client's notice of our own bid or buyout. Only
-- items in the Buying list are taken from it.
local function onAuctionBid(args)
    local bid = parseAuctionArgs(args, state.buyItems)
    if bid.item then
        recordBuy(bid.item, bid.count, bid.price or claimSpend(nowMs(), C.SPEND_CLAIM_MS), "auction")
    end
end

-- Money written in a chat line: the client's money tag "|m12345;" (copper) or
-- plain "12g 34s 56c" / "12 gold".
local function moneyFromText(text)
    local tagged = tonumber(text:match("|m(%d+)"))
    if tagged then return tagged end
    local plain = text:gsub("|i.-|h", " ")
    local function amount(letter, word)
        return tonumber(plain:match("(%d+)%s*" .. letter .. "[^%a]") or plain:match("(%d+)%s*" .. letter .. "$")
            or plain:match("(%d+)%s+" .. word))
    end
    local gold = amount("[gG]", "[gG]old")
    local silver = amount("[sS]", "[sS]ilver")
    local copper = amount("[cC]", "[cC]opper")
    if gold or silver or copper then
        return (gold or 0) * 10000 + (silver or 0) * 100 + (copper or 0)
    end
    return nil
end

local function countFromText(text)
    return tonumber(text:match("[xX]%s?(%d+)") or text:match("(%d+)%s*[xX]%s") or text:match("%((%d+)%)"))
end

local function containsAny(text, words)
    local low = text:lower()
    for _, word in ipairs(words) do
        if low:find(word, 1, true) then return true end
    end
    return false
end

-- A system line (no speaker) about a tracked item. Player chat is never
-- parsed, so "WTS Regrade Scroll" in trade chat is safe.
local function onSystemText(source, text)
    text = tostring(text or "")
    if text == "" then return end
    if containsAny(text, BUY_WORDS) and not containsAny(text, NOT_BUY_WORDS) then
        local item = trackedById(state.buyItems, linkId(text)) or trackedByText(state.buyItems, text)
        if item then
            local cost = moneyFromText(text) or claimSpend(nowMs(), C.SPEND_CLAIM_MS)
            debugNote("BUY?", source .. " item=" .. tostring(item.name) .. " cost=" .. tostring(cost))
            recordBuy(item, countFromText(text), cost, "chat")
        end
        return
    end
    if not (containsAny(text, SALE_WORDS) and not containsAny(text, NOT_SALE_WORDS)) then return end
    local item = trackedById(state.items, linkId(text)) or trackedByText(state.items, text)
    local price = moneyFromText(text)
    local count = countFromText(text)
    debugNote("SALE?", source .. " item=" .. tostring(item and item.name) .. " price=" .. tostring(price) .. " count=" .. tostring(count))
    if item then
        recordSale(item, count, price, "chat")
    elseif price then
        rememberOther(price, count)
    end
end

local function onChat(channel, unit, isHostile, name, message)
    local text = tostring(message or "")
    local speaker = trim(name)
    if state.debug and speaker == "" and (containsAny(text, DEBUG_WORDS)
        or trackedByText(state.items, text) or trackedByText(state.buyItems, text)) then
        debugNote("CHAT", "ch=" .. tostring(channel) .. " name=" .. tostring(name) .. " msg=" .. text)
    end
    if speaker == "" then onSystemText("chat ch=" .. tostring(channel), text) end
end

local function totalsFor(record)
    local gross = tonumber(record.gross)
    if not gross or gross <= 0 then return {} end
    local count = tonumber(record.count) or 1
    -- The event price may be per unit or for the whole lot; accept both.
    if count > 1 then return {gross, gross * count} end
    return {gross}
end

local function matchScore(delta, total)
    if delta > total * C.MAX_NET_RATIO or delta < total * C.MIN_NET_RATIO then return nil end
    local ratio = feeRatio()
    if ratio then return math.abs(delta - total * ratio) end
    return math.abs(total - delta)
end

local function processDelta(entry)
    local delta = entry.delta
    local fromMail = math.abs(entry.at - lastMailMs) <= C.MAIL_WINDOW_MS
    if state.mailEventsSeen and not fromMail then
        debugNote("MONEY", "+" .. fmt(delta) .. " not near a mail event, ignored")
        return
    end
    local best, bestTotal, bestScore, bestIsOther, bestIndex
    local function consider(record, isOther, index)
        for _, total in ipairs(totalsFor(record)) do
            local score = matchScore(delta, total)
            if score and (not bestScore or score < bestScore) then
                best, bestTotal, bestScore, bestIsOther, bestIndex = record, total, score, isOther, index
            end
        end
    end
    for index, sale in ipairs(state.sales) do
        if not saleGot(sale) then consider(sale, false, index) end
    end
    for index, other in ipairs(state.other) do consider(other, true, index) end

    -- Sales seen only in chat have no price: fall back to the item's last
    -- known net price per unit.
    if not best then
        local bestDiff
        for _, sale in ipairs(state.sales) do
            local item = not saleGot(sale) and not tonumber(sale.gross) and itemForRecord(state.items, sale)
            local unit = item and tonumber(item.unitNet)
            if unit then
                local expected = unit * (tonumber(sale.count) or 1)
                local diff = math.abs(delta - expected)
                if delta >= expected * C.UNIT_MIN and delta <= expected * C.UNIT_MAX and (not bestDiff or diff < bestDiff) then
                    best, bestDiff = sale, diff
                end
            end
        end
    end

    if not best then
        debugNote("MONEY", "+" .. fmt(delta) .. " matched no pending sale")
        return
    end
    if bestIsOther then
        table.remove(state.other, bestIndex)
        debugNote("MONEY", "+" .. fmt(delta) .. " = untracked sale")
    else
        local t = entry.when or now()
        if bestTotal then
            best.gross = fmt(bestTotal)
            state.feeRatio = string.format("%.4f", delta / bestTotal)
        end
        best.net = fmt(delta)
        best.collectedAt, best.collectedDay, best.collectedEpoch = t.text, t.day, t.epoch
        local item = itemForRecord(state.items, best)
        if item then item.unitNet = fmt(delta / math.max(tonumber(best.count) or 1, 1)) end
        log("Collected " .. formatCopper(delta) .. " for " .. tostring(best.item) .. " x" .. tostring(best.count))
    end
    save()
    refresh()
end

local function onMoney(args)
    local argNum
    for index = 1, C.MAX_ARGS do
        local value = tonumber(args[index])
        if value then argNum = value break end
    end
    local money = currentMoney()
    local diff = (money and lastMoney) and (money - lastMoney) or nil
    if money then lastMoney = money end
    -- PLAYER_MONEY passes the change in copper (as Norrina-Hub relies on);
    -- fall back to the wallet difference if it ever passes the new total.
    local change = argNum
    if not change or (money and change == money and diff ~= change) then change = diff end
    change = tonumber(change)
    if not change or change == 0 then return end
    if change < 0 then
        onSpend(-change)
        return
    end
    table.insert(pendingDeltas, {delta = change, at = nowMs(), when = now()})
end

local MAIL_EVENTS = {
    MAIL_INBOX_UPDATE = false,
    MAIL_INBOX_MONEY_TAKEN = true,
    MAIL_INBOX_ATTACHMENT_TAKEN_ALL = true,
    MAIL_INBOX_ITEM_TAKEN = false,
    MAIL_INBOX_TAX_PAID = false,
    MAIL_RETURNED = false,
    GOODS_MAIL_INBOX_UPDATE = false,
}

-- System notices that are not CHAT_MESSAGE; any text they carry is checked
-- for a sale or purchase of a tracked item.
local NOTICE_EVENTS = {
    NOTICE_MESSAGE = true,
    CHAT_MSG_ALARM = true,
    SET_UI_MESSAGE = true,
}

local EVENTS = {"PLAYER_MONEY", "AUCTION_BOUGHT_BY_SOMEONE", "AUCTION_BIDDEN", "ADDED_ITEM",
    "MAIL_SENT_SUCCESS", "MAIL_SENTBOX_UPDATE", "REMOVED_ITEM"}
for name in pairs(MAIL_EVENTS) do EVENTS[#EVENTS + 1] = name end
for name in pairs(NOTICE_EVENTS) do EVENTS[#EVENTS + 1] = name end

retire = function()
    if not alive then return end
    alive = false
    for _, key in ipairs({"mainWin", "debugWin", "floatingBtn"}) do
        local widget = ui[key]
        if widget then pcall(function() widget:Show(false) end) end
    end
    if ui.listener then
        pcall(function() ui.listener:ReleaseHandler("OnEvent") end)
        for _, name in ipairs(EVENTS) do pcall(function() ui.listener:UnregisterEvent(name) end) end
        pcall(function() ui.listener:Show(false) end)
    end
end

local function onEvent(event, ...)
    if not stillActive() then return end
    local args = packArgs(...)
    debugNote(event, dumpArgs(args))
    if event == "PLAYER_MONEY" then
        onMoney(args)
    elseif event == "AUCTION_BOUGHT_BY_SOMEONE" then
        onAuctionSold(args)
    elseif event == "AUCTION_BIDDEN" then
        onAuctionBid(args)
    elseif event == "ADDED_ITEM" then
        onItemAdded(args)
    elseif event == "REMOVED_ITEM" then
        onItemRemoved(args)
    elseif event == "MAIL_SENT_SUCCESS" or event == "MAIL_SENTBOX_UPDATE" then
        -- Postage is not an auction purchase.
        lastSentMailMs = nowMs()
    elseif MAIL_EVENTS[event] ~= nil then
        lastMailMs = nowMs()
        if event == "MAIL_INBOX_UPDATE" then
            onInboxUpdate()
            -- The mailbox frame may only exist once it has been opened.
            if not ui.mailBtn then pcall(attachMailButton) end
        end
        if MAIL_EVENTS[event] and not state.mailEventsSeen then
            state.mailEventsSeen = true
            save()
        end
    elseif NOTICE_EVENTS[event] then
        local texts = {}
        for index = 1, C.MAX_ARGS do
            if type(args[index]) == "string" then texts[#texts + 1] = args[index] end
        end
        onSystemText(event, table.concat(texts, " "))
    end
end

local function createListener()
    ui.listener = api.Interface:CreateEmptyWindow("auction_income_listener" .. idSuffix)
    function ui.listener:OnEvent(event, ...)
        local ok, err = pcall(onEvent, event, ...)
        if not ok then log("Event " .. tostring(event) .. " failed: " .. tostring(err)) end
    end
    ui.listener:SetHandler("OnEvent", ui.listener.OnEvent)
    ui.listener:Show(true)
    for _, name in ipairs(EVENTS) do
        local ok = pcall(function() ui.listener:RegisterEvent(name) end)
        if not ok then debugNote("PROBE", "cannot register " .. name) end
    end
end

-- Records which client mail/auction tables the sandbox exposes, to see
-- whether sale mails could be read directly.
local function probeGlobals()
    local probes = {
        X2Mail = function() return X2Mail end,
        X2GoodsMail = function() return X2GoodsMail end,
        X2Auction = function() return X2Auction end,
    }
    local found = {}
    for name, getter in pairs(probes) do
        local ok, value = pcall(getter)
        local text = ok and type(value) or ("error " .. tostring(value))
        if ok and value ~= nil then found[#found + 1] = name end
        if ok and type(value) == "table" then
            local keys = {}
            pcall(function()
                for key in pairs(value) do
                    keys[#keys + 1] = tostring(key)
                    if #keys >= 60 then break end
                end
            end)
            text = text .. " keys: " .. table.concat(keys, ",")
        end
        debugNote("PROBE", name .. " = " .. text)
    end
    probeSummary = #found > 0 and ("available: " .. table.concat(found, ", ")) or "not available, sales are read from chat"
    -- Which client windows an addon can reach (ADDON:GetContent).
    local keys = {}
    if type(UIC) == "table" then
        for key in pairs(UIC) do keys[#keys + 1] = tostring(key) end
    end
    debugNote("PROBE", "UIC = " .. table.concat(keys, ","))
end

-- ============================================================
-- Lifecycle
-- ============================================================

local function OnUpdate()
    if not alive then return end
    local ms = nowMs()
    if #pendingDeltas > 0 then
        local index = 1
        while index <= #pendingDeltas do
            local entry = pendingDeltas[index]
            if ms - entry.at >= C.MATCH_DELAY_MS then
                table.remove(pendingDeltas, index)
                local ok, err = pcall(processDelta, entry)
                if not ok then log("Match failed: " .. tostring(err)) end
            else
                index = index + 1
            end
        end
    end
    local ok, err = pcall(expireBuyState, ms)
    if not ok then log("Purchase check failed: " .. tostring(err)) end
    if debugDirty and ms - lastDebugFlushMs >= 3000 then
        lastDebugFlushMs = ms
        flushDebug()
    end
end

local function OnLoad()
    local okRandom, random = pcall(function() return math.floor(math.random() * 1000000) end)
    idSuffix = "_" .. fmt(nowMs())
    instanceId = fmt(nowMs()) .. "-" .. (okRandom and fmt(random) or "0")
    local ok, err = pcall(load)
    if not ok then log("Data load failed: " .. tostring(err)) end
    -- Claim the data file at once, so an older copy still running stops.
    state.owner = instanceId
    pcall(api.File.Write, api.File, DATA_FILE, state)
    local okDebug, existing = pcall(api.File.Read, api.File, DEBUG_FILE)
    if okDebug and type(existing) == "table" and type(existing.lines) == "table" then debugLog = existing.lines end
    lastMoney = currentMoney()

    pcall(probeGlobals)
    pcall(attachMailButton)

    ok, err = pcall(createListener)
    if not ok then log("Event listener failed: " .. tostring(err)) end
    ok, err = pcall(createMainWindow)
    if not ok then log("Window failed: " .. tostring(err)) end
    ok, err = pcall(createDebugWindow)
    if not ok then log("Debug window failed: " .. tostring(err)) end
    api:DoIn(200, function()
        local success, buttonErr = pcall(createFloatingButton)
        if not success then log("Button failed: " .. tostring(buttonErr)) end
    end)
    api.On("CHAT_MESSAGE", onChat)
    api.On("UPDATE", OnUpdate)
    log("Loaded. Click 'Auction $' to open, Shift-drag it to move.")
end

local function OnUnload()
    api.On("UPDATE", function() end)
    api.On("CHAT_MESSAGE", function() end)
    if ui.mainWin then ui.mainWin:Show(false) end
    if ui.debugWin then ui.debugWin:Show(false) end
    if ui.floatingBtn then ui.floatingBtn:Show(false) end
    if ui.mailBtn then
        ui.mailBtn:Show(false)
        ui.mailBtn = nil
    end
    save()
    flushDebug()
    if retire then retire() end
end

addon.OnLoad = OnLoad
addon.OnUnload = OnUnload

return addon
