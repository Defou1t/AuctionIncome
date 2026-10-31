local api = require("api")

-- Regrade panel (Auction Income 1.11.0): next to the client's Enchant window,
-- while its regrade tab is open, shows what the item in the slot, the scroll
-- and the charm cost at the auction, their total and the cost of one try,
-- and a table of the tries made since the window opened; the table is
-- cleared when the window closes.
--
-- Read from the client (its own regrade tab uses the same calls):
--   api.ItemEnchant:GetTargetItemInfo()   item: itemType, itemGrade,
--                                         grade_enchant_cost (gold per try)
--   api.ItemEnchant:GetEnchantItemInfo()  scroll: itemType, total (in the bag)
--   api.ItemEnchant:GetSupportItemInfo()  charm: itemType, total
--   GRADE_ENCHANT_RESULT(resultCode, itemLink, oldGrade, newGrade, ...)
--     codes of X2ItemEnchant: 0 break, 1 downgrade, 2 disabled, 3 fail,
--     4 success, 5 great success, 7 restored
-- The window is looked at 4 times a second; prices are worked out only when
-- a slot changes, and a label is touched only when its text changes.
local R = {}

local POLL_MS, ROWS, W, ROW_Y = 250, 12, 380, 300
local H = ROW_Y + ROWS * 20 + 10
-- Grade numbers of the client: 0 Basic, 1 Crude, then Grand and up.
local GRADES = {[0] = "Basic", "Crude", "Grand", "Rare", "Arcane", "Heroic", "Unique",
    "Celestial", "Divine", "Epic", "Legendary", "Mythic"}
local RESULTS = {[0] = "Break", [1] = "Downgrade", [2] = "Disabled", [3] = "Fail",
    [4] = "Success", [5] = "Great success", [7] = "Restored"}
-- Order of the counts in the summary line.
local SUMMARY_ORDER = {4, 5, 3, 1, 0, 2, 7}
local COLORS = {[0] = {0.75, 0.1, 0.1}, [1] = {0.7, 0.35, 0}, [4] = {0.1, 0.5, 0.1}, [5] = {0, 0.45, 0.65}}
local TEXT_COLOR = {0.08, 0.035, 0.01}
local SLOTS = {
    {key = "target", title = "Item", getter = "GetTargetItemInfo"},
    {key = "scroll", title = "Scroll", getter = "GetEnchantItemInfo"},
    {key = "charm", title = "Charm", getter = "GetSupportItemInfo"},
}
local MAX_TRIES = 500

local ctx
local texts, colors = {}, {}

local function setText(label, text)
    if texts[label] == text then return end
    texts[label] = text
    label:SetText(text)
end

local function setColor(label, color)
    if colors[label] == color then return end
    colors[label] = color
    if label.style then label.style:SetColor(color[1], color[2], color[3], 1) end
end

local function show(visible)
    if R.visible == visible then return end
    R.visible = visible
    R.win:Show(visible)
end

local function gradeName(grade)
    grade = tonumber(grade)
    if not grade then return "?" end
    return GRADES[grade] or ("grade " .. grade)
end

local function resultName(code)
    return RESULTS[code] or ("code " .. tostring(code))
end

local function money(copper)
    if not copper then return "?" end
    return ctx.formatCopper(copper)
end

-- The client's Enchant window if it is open, and whether its regrade tab
-- (the first one, enchant_window.lua) is selected. A tab that cannot be
-- read counts as the regrade tab.
local function enchantWindow()
    local ok, frame = pcall(function() return ADDON:GetContent(UIC.ENCHANT_WINDOW) end)
    if not (ok and frame) then return nil end
    local okShown, shown = pcall(function() return frame:IsVisible() end)
    if not (okShown and shown) then return nil end
    local okTab, tab = pcall(function() return frame.tab:GetSelectedTab() end)
    return frame, not (okTab and tonumber(tab)) or tonumber(tab) == 1
end

-- To the right of the window, or to its left when the screen ends there.
local function place(frame)
    local side = "right"
    pcall(function()
        local x = tonumber((frame:GetEffectiveOffset()))
        local width = tonumber((frame:GetExtent()))
        local screenW = tonumber(api.Interface:GetScreenWidth()) or 1920
        if x and width and x + width + W + 8 > screenW then side = "left" end
    end)
    if R.frame == frame and R.side == side then return end
    R.frame, R.side = frame, side
    R.win:RemoveAllAnchors()
    if side == "right" then
        R.win:AddAnchor("TOPLEFT", frame, "TOPRIGHT", 6, 0)
    else
        R.win:AddAnchor("TOPRIGHT", frame, "TOPLEFT", -6, 0)
    end
end

local function readSlot(slot)
    local ok, info = pcall(function() return api.ItemEnchant[slot.getter](api.ItemEnchant) end)
    if not (ok and type(info) == "table") then return nil end
    local id = tonumber(info.itemType)
    if not id or id <= 0 then return nil end
    local name = info.name
    if type(name) ~= "string" or name == "" then name = ctx.itemName(id) end
    return {id = id, name = name, grade = tonumber(info.itemGrade), count = tonumber(info.total),
        fee = tonumber(info.grade_enchant_cost), info = info}
end

local function slotText(slot, item)
    if not item then return slot.title .. ": -" end
    local text = slot.title .. ": " .. tostring(item.name)
    if slot.key == "target" then
        if item.grade then text = text .. " (" .. gradeName(item.grade) .. ")" end
    elseif item.count then
        text = text .. " x" .. item.count
    end
    return text
end

-- Prices of the slots now, the total of one of each and the cost of a try.
local function drawPrices()
    local total, try, totalKnown, tryKnown = 0, 0, true, true
    for _, slot in ipairs(SLOTS) do
        local item, row = R.slots[slot.key], R.rows[slot.key]
        setText(row.name, slotText(slot, item))
        if item then
            setText(row.source, item.price and item.source or "no price")
            if item.price then total = total + item.price else totalKnown = false end
            if slot.key ~= "target" then
                if item.price then try = try + item.price else tryKnown = false end
            end
        else
            setText(row.source, "")
        end
    end
    local target = R.slots.target
    local fee = target and target.fee
    if target then
        if fee then try = try + fee else tryKnown = false end
    end
    setText(R.fee, "Gold per try: " .. (target and money(fee) or "-"))
    setText(R.total, "Item + scroll + charm: " .. money(total) .. (totalKnown and "" or " + unpriced"))
    setText(R.perTry, "One try (scroll + charm + gold): " .. money(try) .. (tryKnown and "" or " + unpriced"))
    setText(R.market, R.note or ctx.marketNote())
end

local function fillEdit(slot)
    local item, row = R.slots[slot.key], R.rows[slot.key]
    local text = item and item.price and ctx.goldText(item.price) or ""
    R.shown[slot.key] = text
    row.edit:SetText(text)
end

-- Reads the three slots; a slot that changed gets its price again and its
-- edit box refilled.
local function readSlots()
    local changed = false
    for _, slot in ipairs(SLOTS) do
        local item = readSlot(slot)
        local sig = item and table.concat({item.id, item.grade or "", item.count or "", item.fee or ""}, "/") or ""
        local old = R.slots[slot.key]
        if item and old and old.id == item.id then
            item.price, item.source = old.price, old.source
        elseif item then
            item.price, item.source = ctx.price(item.id)
        end
        R.slots[slot.key] = item
        if sig ~= R.sig[slot.key] then
            R.sig[slot.key] = sig
            changed = true
            if not (item and old and old.id == item.id) then fillEdit(slot) end
            if item and ctx.state.debug then ctx.note("REGRADE", slot.key .. " " .. ctx.dump(item.info)) end
        end
    end
    if changed then
        R.note = nil
        if ctx.state.debug then
            local ok, ratio = pcall(function() return api.ItemEnchant:GetRatioInfos() end)
            ctx.note("REGRADE", "ratio " .. (ok and ctx.dump(ratio) or ("error " .. tostring(ratio))))
        end
        drawPrices()
    end
end

local function drawTries()
    local counts, spent, unpriced = {}, 0, false
    for _, try in ipairs(R.tries) do
        counts[try.code] = (counts[try.code] or 0) + 1
        spent = spent + try.cost
        if try.unpriced then unpriced = true end
    end
    if #R.tries == 0 then
        setText(R.summary, "No tries since the window opened.")
        setText(R.spent, "")
    else
        local parts = {}
        for _, code in ipairs(SUMMARY_ORDER) do
            if counts[code] then parts[#parts + 1] = counts[code] .. " " .. resultName(code):lower() end
        end
        setText(R.summary, #R.tries .. (#R.tries == 1 and " try: " or " tries: ") .. table.concat(parts, ", "))
        setText(R.spent, "Spent since the window opened: " .. money(spent) .. (unpriced and " + unpriced" or ""))
    end
    for row = 1, ROWS do
        local try, line = R.tries[row], R.lines[row]
        if try then
            setText(line.num, "#" .. (#R.tries - row + 1))
            local grades = gradeName(try.old)
            if try.code == 0 then
                grades = grades .. " -> broken"
            elseif try.new and try.new ~= try.old then
                grades = grades .. " -> " .. gradeName(try.new)
            end
            setText(line.grade, grades)
            setText(line.result, resultName(try.code))
            setColor(line.result, COLORS[try.code] or TEXT_COLOR)
            setText(line.cost, money(try.cost) .. (try.unpriced and "+?" or ""))
        else
            setText(line.num, "")
            setText(line.grade, "")
            setText(line.result, "")
            setText(line.cost, "")
        end
    end
end

local function reset()
    R.slots, R.sig, R.shown, R.tries, R.note = {}, {}, {}, {}, nil
    for _, slot in ipairs(SLOTS) do R.rows[slot.key].edit:SetText("") end
    drawTries()
end

-- Prices typed into the edit boxes become the items' own prices (the labor
-- calculator uses them too); an emptied box goes back to the market price.
function R.savePrices()
    local saved, bad = 0, nil
    for _, slot in ipairs(SLOTS) do
        local item, row = R.slots[slot.key], R.rows[slot.key]
        local text = item and ctx.trim(row.edit:GetText())
        if item and text ~= R.shown[slot.key] then
            local key = tostring(item.id)
            local copper = ctx.money(text)
            if text == "" then
                ctx.state.prices[key] = nil
                saved = saved + 1
            elseif copper and copper >= 0 then
                ctx.state.prices[key] = string.format("%.0f", copper)
                saved = saved + 1
            else
                bad = text
            end
            item.price, item.source = ctx.price(item.id)
            fillEdit(slot)
        end
    end
    if saved > 0 then ctx.save() end
    if bad then
        R.note = "Not a price: " .. bad .. " (e.g. 35.5 or 35g 50s)"
    else
        R.note = saved > 0 and ("Saved " .. saved .. (saved == 1 and " price." or " prices.")) or "Nothing changed."
    end
    drawPrices()
end

-- A try, priced with the slots as they were while it was cast.
function R.onResult(args)
    if not R.enabled or not R.open then return end
    local cost, unpriced = 0, false
    local function add(copper)
        if copper then cost = cost + copper else unpriced = true end
    end
    local target, scroll, charm = R.slots.target, R.slots.scroll, R.slots.charm
    if scroll then add(scroll.price) else unpriced = true end
    if charm then add(charm.price) end
    add(target and target.fee)
    table.insert(R.tries, 1, {code = tonumber(args[1]), old = tonumber(args[3]), new = tonumber(args[4]),
        cost = cost, unpriced = unpriced})
    while #R.tries > MAX_TRIES do table.remove(R.tries) end
    drawTries()
end

function R.init(context, suffix, enabled)
    ctx, texts, colors = context, {}, {}
    R.enabled = enabled ~= false
    R.pollMs, R.open, R.visible, R.frame, R.side = -100000, false, nil, nil, nil
    R.win = api.Interface:CreateEmptyWindow("ai_regrade" .. suffix)
    R.win:SetExtent(W, H)
    local paper = R.win:CreateColorDrawable(0.93, 0.86, 0.69, 0.98, "background")
    paper:AddAnchor("TOPLEFT", R.win, 0, 0)
    paper:AddAnchor("BOTTOMRIGHT", R.win, 0, 0)
    show(false)
    local label, button, edit = ctx.makeLabel, ctx.makeButton, ctx.makeEdit
    label(R.win, "ai_rg_title", "Regrade costs", 12, 8, W - 24, 24, FONT_SIZE.LARGE or 20, ALIGN.CENTER)
    R.rows = {}
    for index, slot in ipairs(SLOTS) do
        local y = 38 + (index - 1) * 30
        R.rows[slot.key] = {
            name = label(R.win, "ai_rg_name_" .. slot.key, "", 12, y + 4, 206, 20, 13),
            edit = edit(R.win, "ai_rg_edit_" .. slot.key, 222, y, 90, 26),
            source = label(R.win, "ai_rg_src_" .. slot.key, "", 316, y + 4, 56, 20, 12),
        }
    end
    R.fee = label(R.win, "ai_rg_fee", "", 12, 134, W - 24, 20, 13)
    R.total = label(R.win, "ai_rg_total", "", 12, 156, W - 24, 20, 13)
    R.perTry = label(R.win, "ai_rg_try", "", 12, 178, W - 24, 20, 13)
    button(R.win, "ai_rg_save", "Save prices", 12, 204, 110, 26, R.savePrices)
    R.market = label(R.win, "ai_rg_market", "", 130, 208, W - 142, 20, 12)
    R.summary = label(R.win, "ai_rg_summary", "", 12, 244, W - 24, 20, 13)
    R.spent = label(R.win, "ai_rg_spent", "", 12, 266, W - 24, 20, 13)
    R.lines = {}
    for row = 1, ROWS do
        local y = ROW_Y + (row - 1) * 20
        R.lines[row] = {
            num = label(R.win, "ai_rg_num_" .. row, "", 12, y, 30, 20, 13),
            grade = label(R.win, "ai_rg_grade_" .. row, "", 42, y, 138, 20, 13),
            result = label(R.win, "ai_rg_result_" .. row, "", 180, y, 92, 20, 13),
            cost = label(R.win, "ai_rg_cost_" .. row, "", 272, y, 96, 20, 13, ALIGN.RIGHT),
        }
    end
    reset()
    drawPrices()
end

function R.hide()
    if R.win then show(false) end
end

function R.setEnabled(enabled)
    R.enabled = enabled
    if not enabled and R.win then
        show(false)
        R.open = false
        reset()
    end
end

-- Called every frame.
function R.update(ms)
    if not R.enabled or not R.win or ms - R.pollMs < POLL_MS then return end
    R.pollMs = ms
    local frame, regradeTab = enchantWindow()
    if not frame then
        if R.open then
            R.open = false
            show(false)
            reset()
        end
        return
    end
    if not R.open then
        R.open = true
        drawPrices()
    end
    if not regradeTab then
        show(false)
        return
    end
    place(frame)
    readSlots()
    show(true)
end

return R
