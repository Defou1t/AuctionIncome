local api = require("api")

-- Fish Tracker: the fish's action and Strength Contest buffs with timers
-- under the targeted fish (and under the watch / track target), countdowns
-- for dead marked fish and for the Owner's Mark on your boat.
-- From Raid & Fish Tools 1.3.2 (Norrina-Hub by Norrina, based on Fish Track
-- Reborn v2.2 by Wagasez, inspired by Usb), moved here in Auction Income 1.10.0.
--
-- Work per frame is kept to the minimum, the game client being 32-bit:
--   every frame  only the screen position of a shown overlay, re-anchored
--                only when its pixel position changed
--   10 per sec   buffs and timers of the target / watch target
--   2 per sec    overhead markers
-- Unit info is asked for only when the unit id changes, and every widget is
-- touched only when its visibility, text or texture really changes.
local T = {}

local DATA_MS, MARKER_MS = 100, 500
local DEAD_TIME_MS, OWNERS_MARK_ID = 150000, 4867
local DEAD_ICON, WAITING_ICON, CONTEST_ICON = 4832, 3710, 5715
local CONTEST_BUFF = 5715
local ACTION_BUFFS = {[5264] = true, [5265] = true, [5266] = true, [5267] = true, [5508] = true}
local FISH_NAMES = {
    ["Marlin"] = true, ["Blue Marlin"] = true, ["Tuna"] = true, ["Blue Tuna"] = true,
    ["Bluefin Tuna"] = true, ["Sunfish"] = true, ["Sailfish"] = true, ["Sturgeon"] = true,
    ["Pink Pufferfish"] = true, ["Carp"] = true, ["Arowana"] = true, ["Pufferfish"] = true,
    ["Eel"] = true, ["Pink Marlin"] = true, ["Treasure Mimic"] = true,
    ["철갑상어"] = true, ["청새치"] = true, ["참다랑어"] = true, ["돛새치"] = true, ["개복치"] = true,
    ["鲟鱼"] = true, ["枪鱼"] = true, ["蓝鳍金枪鱼"] = true, ["旗鱼"] = true, ["翻车鱼"] = true
}

local unit = api.Unit
local shown, texts, textures, buffIcons = {}, {}, {}, {}

local function show(widget, visible)
    if shown[widget] == visible then return end
    shown[widget] = visible
    widget:Show(visible)
end

local function setText(label, text)
    if texts[label] == text then return end
    texts[label] = text
    label:SetText(text)
end

-- Seconds with one decimal, formatted only when the tenth changed.
local function setTenths(label, ms)
    local tenths = math.floor((tonumber(ms) or 0) / 100)
    if texts[label] == tenths then return end
    texts[label] = tenths
    label:SetText(string.format("%.1fs", tenths / 10))
end

local function setSeconds(label, ms)
    local seconds = math.floor(ms / 1000 + 0.5)
    if texts[label] == seconds then return end
    texts[label] = seconds
    label:SetText(seconds .. "s")
end

local function setIcon(icon, buffId, path)
    local iconPath = path or buffIcons[buffId]
    if not iconPath then
        local ok, tooltip = pcall(api.Ability.GetBuffTooltip, api.Ability, buffId, 1)
        iconPath = ok and type(tooltip) == "table" and tooltip.path or false
        buffIcons[buffId] = iconPath
    end
    if not iconPath or textures[icon] == iconPath then return end
    textures[icon] = iconPath
    pcall(F_SLOT.SetIconBackGround, icon, iconPath)
end

local function makeIcon(parent, id)
    local icon = CreateItemIconButton(id, parent)
    icon:Show(true)
    F_SLOT.ApplySlotSkin(icon, icon.back, SLOT_STYLE.DEFAULT)
    return icon
end

local function makeLabel(parent, id, text, x, y, r, g, b)
    local label = parent:CreateChildWidget("label", id, 0, true)
    label:SetExtent(38, 20)
    label:RemoveAllAnchors()
    label:AddAnchor("TOPLEFT", parent, x, y)
    label:SetText(text)
    texts[label] = text
    if label.style then
        label.style:SetAlign(ALIGN.CENTER)
        label.style:SetFontSize(FONT_SIZE.MIDDLE or 16)
        label.style:SetColor(r or 0.08, g or 0.035, b or 0.01, 1)
    end
    label:Show(true)
    return label
end

local function makeWindow(id)
    local window = api.Interface:CreateEmptyWindow(id)
    window:Show(false)
    shown[window] = false
    return window
end

-- One overlay (action + Strength Contest icons with timers) under a unit.
local function makeOverlay(id, suffix, tag)
    local o = {token = nil}
    o.win = makeWindow(id .. suffix)
    o.icon = makeIcon(o.win, id .. "_action" .. suffix)
    o.icon:AddAnchor("TOPLEFT", o.win, "TOPLEFT", 0, 0)
    o.actionTime = makeLabel(o.win, id .. "_action_time" .. suffix, "", 0, 38, 0, 1, 0)
    o.strengthIcon = makeIcon(o.win, id .. "_strength" .. suffix)
    o.strengthIcon:AddAnchor("LEFT", o.icon, "RIGHT", 5, 0)
    o.strengthIcon:Show(false)
    shown[o.strengthIcon] = false
    o.strengthTime = makeLabel(o.win, id .. "_strength_time" .. suffix, "", 43, 38, 1, 1, 0)
    if tag then makeLabel(o.win, id .. "_tag" .. suffix, tag, 21, -22, 0.4, 0.8, 1) end
    return o
end

-- A countdown window in the row above the screen centre (dead fish, boat).
local function makeCountdown(id, suffix, number, r, g, b)
    local c = {}
    c.window = makeWindow(id .. suffix)
    c.icon = makeIcon(c.window, id .. "_icon" .. suffix)
    c.icon:AddAnchor("TOPLEFT", c.window, "TOPLEFT", 0, 0)
    if number then makeLabel(c.window, id .. "_num" .. suffix, number, 0, -22) end
    c.time = makeLabel(c.window, id .. "_time" .. suffix, "", 0, 38, r, g, b)
    return c
end

local function placeCountdown(c, slot)
    if c.slot == slot then return end
    c.slot = slot
    c.window:RemoveAllAnchors()
    c.window:AddAnchor("TOP", "UIParent", "CENTER", slot * 50 - 125, 200)
end

-- Keeps overlay o under its fish; called every frame while it is shown.
local function place(o)
    local ok, x, y = pcall(unit.GetUnitScreenPosition, unit, o.token)
    if not (ok and x and y) then x, y = o.fallbackX, o.fallbackY end
    x, y = tonumber(x), tonumber(y)
    if not (x and y) then return end
    x, y = math.floor(x - 42), math.floor(y + 5)
    if x == o.x and y == o.y then return end
    o.x, o.y = x, y
    o.win:RemoveAllAnchors()
    o.win:AddAnchor("TOP", "UIParent", "TOPLEFT", x, y)
end

-- Unit info, asked for only when the unit behind a token changes.
local function fishInfo(o, id)
    if id ~= o.unitId then
        o.unitId = id
        local ok, info = pcall(unit.GetUnitInfoById, unit, id)
        o.info = ok and type(info) == "table" and FISH_NAMES[info.name] and info or nil
    end
    return o.info
end

-- Fills overlay o for the unit behind token. Returns the fish's unit id and
-- info, whether it is dead and its Owner's Mark buff, or nil for no fish.
local function updateOverlay(o, token, fallbackX, fallbackY)
    local id = token and unit:GetUnitId(token)
    local info = id and fishInfo(o, id)
    if not info then
        o.unitId = id
        show(o.win, false)
        return nil
    end
    o.token, o.fallbackX, o.fallbackY = token, fallbackX, fallbackY
    place(o)
    local health = unit:UnitHealth(token)
    if health and health <= 0 then
        show(o.strengthIcon, false); setText(o.strengthTime, "")
        setIcon(o.icon, DEAD_ICON); setText(o.actionTime, "")
        show(o.win, true)
        return id, info, true
    end
    local action, contest, owner
    for index = 1, unit:UnitBuffCount(token) or 0 do
        local buff = unit:UnitBuff(token, index)
        if buff then
            local buffId = buff.buff_id
            if buffId == OWNERS_MARK_ID then owner = buff
            elseif ACTION_BUFFS[buffId] then action = buff
            elseif buffId == CONTEST_BUFF then contest = buff end
        end
    end
    if action then
        setIcon(o.icon, action.buff_id, action.path)
        setTenths(o.actionTime, action.timeLeft)
    else
        setIcon(o.icon, WAITING_ICON)
        setText(o.actionTime, "Waiting")
    end
    if contest then
        setIcon(o.strengthIcon, CONTEST_ICON)
        setTenths(o.strengthTime, contest.timeLeft)
        show(o.strengthIcon, true)
    else
        show(o.strengthIcon, false); setText(o.strengthTime, "")
    end
    show(o.win, true)
    return id, info, false, owner
end

-- The client's watch / track target frame keeps the token of its unit in
-- frame.target; asked at most every 5 s until found.
local function watchToken(ms)
    if T.watchToken then return T.watchToken end
    if T.watchAskedMs and ms - T.watchAskedMs < 5000 then return nil end
    T.watchAskedMs = ms
    local ok, token = pcall(function()
        local frame = ADDON:GetContent(UIC.WATCH_TARGET_FRAME)
        return frame and frame.target
    end)
    if ok and type(token) == "string" and token ~= "" and token ~= "target" then
        T.watchToken = token
        return token
    end
    return nil
end

local function playerName()
    if not T.player then
        local ok, name = pcall(function() return unit:GetUnitNameById(unit:GetUnitId("player")) end)
        T.player = ok and name or nil
    end
    return T.player
end

local function scanMarkers()
    for marker = 1, 9 do
        local id = unit:GetOverHeadMarkerUnitId(marker)
        local data = T.markers[marker]
        if not data or data.id ~= id then
            local isFish = false
            if id then
                local ok, info = pcall(unit.GetUnitInfoById, unit, id)
                isFish = ok and type(info) == "table" and FISH_NAMES[info.name] and true or false
            end
            -- A dead fish keeps its countdown even once its marker is gone.
            if not (data and data.deathAt and not id) then
                data = {id = id, fish = isFish}
                T.markers[marker] = data
            end
        end
    end
end

local function updateCountdowns(ms)
    local slot = 0
    for marker = 1, 9 do
        local data, c = T.markers[marker], T.markerUI[marker]
        local remaining = data and data.deathAt and DEAD_TIME_MS - (ms - data.deathAt)
        if remaining and remaining > 0 then
            placeCountdown(c, slot)
            setIcon(c.icon, DEAD_ICON)
            setSeconds(c.time, remaining)
            show(c.window, true)
            slot = slot + 1
        else
            if data and data.deathAt then data.deathAt = nil end
            show(c.window, false)
        end
    end
    local boat = T.boat
    local remaining = T.boatExpires and T.boatExpires - ms
    if remaining and remaining > 0 then
        placeCountdown(boat, slot)
        setIcon(boat.icon, OWNERS_MARK_ID)
        setSeconds(boat.time, remaining)
        show(boat.window, true)
    else
        T.boatExpires = nil
        show(boat.window, false)
    end
end

local function refresh(ms)
    if ms - T.markerMs >= MARKER_MS then
        T.markerMs = ms
        scanMarkers()
    end
    local id, _, dead, owner = updateOverlay(T.main, "target")
    local token = watchToken(ms)
    local watchId = token and unit:GetUnitId(token)
    if watchId and watchId ~= id then
        local screenW = tonumber(api.Interface:GetScreenWidth()) or 1920
        updateOverlay(T.watch, token, math.floor(screenW / 2) + 100, 150)
    else
        show(T.watch.win, false)
    end
    if id and dead then
        for marker = 1, 9 do
            local data = T.markers[marker]
            if data and data.fish and data.id == id and not data.deathAt then data.deathAt = ms end
        end
    elseif owner and ms - T.ownerMs >= 1000 then
        -- Fresh info (the owner is set once the fish is hooked), once a second.
        T.ownerMs = ms
        local ok, fresh = pcall(unit.GetUnitInfoById, unit, id)
        if ok and type(fresh) == "table" and fresh.owner_name and fresh.owner_name == playerName() then
            T.boatExpires = ms + (tonumber(owner.timeLeft) or 0)
        end
    end
    updateCountdowns(ms)
end

-- Creates the widgets; suffix keeps their names apart from a previous load.
function T.init(suffix, enabled)
    shown, texts, textures = {}, {}, {}
    T.enabled = enabled ~= false
    T.dataMs, T.markerMs, T.ownerMs = -100000, -100000, -100000
    T.markers, T.markerUI, T.boatExpires, T.watchToken, T.watchAskedMs = {}, {}, nil, nil, nil
    T.main = makeOverlay("ai_fish_target", suffix)
    T.watch = makeOverlay("ai_fish_watch", suffix, "W")
    for marker = 1, 9 do
        T.markerUI[marker] = makeCountdown("ai_fish_marker_" .. marker, suffix, tostring(marker), 1, 0.5, 0)
    end
    T.boat = makeCountdown("ai_fish_boat", suffix, nil, 0.3, 0.6, 1)
end

function T.hide()
    if not T.main then return end
    show(T.main.win, false)
    show(T.watch.win, false)
    for _, c in ipairs(T.markerUI) do show(c.window, false) end
    show(T.boat.window, false)
end

function T.setEnabled(enabled)
    T.enabled = enabled
    if not enabled then
        T.hide()
        T.markers, T.boatExpires = {}, nil
        T.main.unitId, T.watch.unitId = nil, nil
    end
end

-- Called every frame.
function T.update(ms)
    if not T.enabled or not T.main then return end
    if ms - T.dataMs >= DATA_MS then
        T.dataMs = ms
        refresh(ms)
        return
    end
    if shown[T.main.win] then place(T.main) end
    if shown[T.watch.win] then place(T.watch) end
end

return T
