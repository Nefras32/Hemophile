local TRACKED = {
    { key = "bleed",  name = "Bleed indicator",  texture = "Interface\\Icons\\Spell_DeathKnight_BloodBoil" },
    { key = "poison", name = "Poison indicator", texture = "Interface\\Icons\\Ability_Creature_Poison_06" },
}
local KEYS = { bleed = true, poison = true }

-- Creature-type base guess
local IMMUNE_TYPES = {
    bleed  = { Mechanical = true, Elemental = true, Totem = true, Undead = true },
    poison = { Mechanical = true, Elemental = true, Totem = true },
}

-- Optional hardcoded exceptions by NPC ID: [npcID] = { bleed = true, poison = false }
local OVERRIDES = {
}

local PREFIX = "Hemophile"
local GAP = 3
local DEFAULT_SIZE, MIN_SIZE, MAX_SIZE = 26, 14, 64

HemophileStatic = {}

local unlocked = false -- icons are draggable while true (not saved between sessions)

---------------------------------------------------------------------
-- Options are stored per character in HemophileCharacterDB.options.
---------------------------------------------------------------------
local FALLBACK_OPTIONS = { size = DEFAULT_SIZE, hidden = {}, blockReceive = true }

local function Opt()
    if not HemophileCharacterDB then return FALLBACK_OPTIONS end
    local o = HemophileCharacterDB.options
    if not o then
        o = {}
        HemophileCharacterDB.options = o
    end
    if o.size == nil then o.size = DEFAULT_SIZE end
    if o.hidden == nil then o.hidden = {} end
    if o.blockReceive == nil then o.blockReceive = true end -- blocked by default
    if o.autoLearn == nil then o.autoLearn = true end       -- learn from Rupture/Garrote casts
    if o.minimapAngle == nil then o.minimapAngle = 200 end  -- minimap button position (degrees)
    return o
end

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function NpcIdFromGUID(guid)
    if not guid then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
end

-- Attackable NPCs only: no players, no pets, no friendly NPCs
local function IsHostileNpc(unit)
    return UnitExists(unit)
        and UnitCanAttack("player", unit)
        and not UnitPlayerControlled(unit)
        and NpcIdFromGUID(UnitGUID(unit)) ~= nil
end

local function Pretty(key)
    return key == "poison" and "Deadly Poison" or (key:sub(1, 1):upper() .. key:sub(2))
end

-- Text format: id;name;bleed;poison   (1 immune, 0 not immune, blank unknown)
local function ParseLines(text, target)
    local n = 0
    for line in text:gmatch("[^\r\n]+") do
        local id, name, b, p = line:match("^%s*(%d+);([^;]*);([01]?);([01]?)%s*$")
        if id then
            id = tonumber(id)
            local e = target[id] or {}
            if name ~= "" then e.name = name end
            if b ~= "" then e.bleed  = (b == "1") end
            if p ~= "" then e.poison = (p == "1") end
            target[id] = e
            n = n + 1
        end
    end
    return n
end

local function Flag(v)
    if v == nil then return "" end
    return v and "1" or "0"
end

-- Load shipped data
ParseLines(HemophileStaticText or "", HemophileStatic)

-- Returns immune (bool), source (string)
local function CheckImmunity(key, unit)
    local id = NpcIdFromGUID(UnitGUID(unit))
    local ctype = UnitCreatureType(unit)
    local baseline = ctype and IMMUNE_TYPES[key] and IMMUNE_TYPES[key][ctype]
        and ("; baseline: immune for " .. ctype .. " type") or ""
    if id then
        local entry = HemophileAuto and HemophileAuto[id]
        if entry and entry[key] ~= nil then
            return entry[key], (entry[key] and "Immune" or "Not immune") .. " (auto-detected)" .. baseline, "auto"
        end
        entry = HemophileDB and HemophileDB[id]
        if entry and entry[key] ~= nil then
            return entry[key], (entry[key] and "Immune" or "Not immune") .. " (marked by you)" .. baseline
        end
        entry = HemophileShared and HemophileShared[id]
        if entry and entry[key] ~= nil then
            return entry[key], (entry[key] and "Immune" or "Not immune") .. " (shared/imported)" .. baseline
        end
        entry = HemophileStatic[id]
        if entry and entry[key] ~= nil then
            return entry[key], (entry[key] and "Immune" or "Not immune") .. " (addon database)" .. baseline
        end
        entry = OVERRIDES[id]
        if entry and entry[key] ~= nil then
            return entry[key], (entry[key] and "Immune" or "Not immune") .. " (override)" .. baseline
        end
    end
    if ctype and IMMUNE_TYPES[key] and IMMUNE_TYPES[key][ctype] then
        return true, "Immune (" .. ctype .. " type guess, unconfirmed)"
    end
    return false, "Not known to be immune"
end

---------------------------------------------------------------------
-- UI icons (parented to UIParent to avoid tainting TargetFrame)
---------------------------------------------------------------------
local container = CreateFrame("Frame", "HemophileFrame", UIParent)
container:SetSize((DEFAULT_SIZE + GAP) * #TRACKED, DEFAULT_SIZE)
container:SetPoint("BOTTOMLEFT", TargetFrame, "TOPLEFT", 8, -4)
container:SetFrameStrata("HIGH")
container:SetMovable(true)
container:SetClampedToScreen(true)
container:Hide()

-- Green tint shown while the icons are unlocked for dragging
container.bg = container:CreateTexture(nil, "BACKGROUND")
container.bg:SetPoint("TOPLEFT", -3, 3)
container.bg:SetPoint("BOTTOMRIGHT", 3, -3)
container.bg:SetColorTexture(0, 1, 0, 0.25)
container.bg:Hide()

local Refresh, Learn, ClearAutoLearnedPoison -- forward declarations
local latest

local function SavePosition()
    local left, bottom = container:GetLeft(), container:GetBottom()
    if left and bottom then Opt().pos = { x = left, y = bottom } end
end

local function ApplyPosition()
    local p = Opt().pos
    container:ClearAllPoints()
    if p then
        container:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", p.x, p.y)
    else
        container:SetPoint("BOTTOMLEFT", TargetFrame, "TOPLEFT", 8, -4)
    end
end

local function ShowTooltip(b)
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    GameTooltip:SetText(b.info.name)
    GameTooltip:AddLine(b.status or "", 1, 1, 1)
    if unlocked then
        GameTooltip:AddLine("Drag to move the icons", 0.6, 1, 0.6)
    elseif b.info.key == "poison" and b.origin == "auto" and b.status:match("^Not immune") then
        GameTooltip:AddLine("Click to clear this result and test poisonability again", 0.6, 0.6, 0.6)
    else
        GameTooltip:AddLine("Click to flip: mark immune / not immune", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

for i, info in ipairs(TRACKED) do
    local b = CreateFrame("Frame", nil, container)
    b:SetSize(DEFAULT_SIZE, DEFAULT_SIZE)
    b:SetPoint("LEFT", (i - 1) * (DEFAULT_SIZE + GAP), 0)
    b:EnableMouse(true)
    b:RegisterForDrag("LeftButton")

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    local iconTexture = info.texture
    if info.key == "poison" then
        local _, class = UnitClass("player")
        if class == "ROGUE" then
            iconTexture = "Interface\\Icons\\Ability_Rogue_DualWeild"
        end
    end
    b.icon:SetTexture(iconTexture)

    b.cross = b:CreateTexture(nil, "OVERLAY")
    b.cross:SetAllPoints()
    b.cross:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
    b.cross:Hide()

    b.info = info
    b:SetScript("OnEnter", ShowTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Dragging (only while unlocked)
    b:SetScript("OnDragStart", function()
        if unlocked then container:StartMoving() end
    end)
    b:SetScript("OnDragStop", function()
        container:StopMovingOrSizing()
        SavePosition()
    end)

    -- Click = flip the saved state for this ability on the current target
    b:SetScript("OnMouseUp", function(self, button)
        if unlocked or button ~= "LeftButton" then return end
        if not IsHostileNpc("target") then return end
        local guid = UnitGUID("target")
        local current, _, origin = CheckImmunity(self.info.key, "target")
        if self.info.key == "poison" and not current and origin == "auto" then
            ClearAutoLearnedPoison(NpcIdFromGUID(guid), guid, UnitName("target"))
        else
            Learn(guid, UnitName("target"), self.info.key, not current)
        end
        if GameTooltip:IsOwned(self) then ShowTooltip(self) end
    end)

    info.button = b
end

-- Applies icon size and which icons are shown
local function ApplyLayout()
    local o = Opt()
    local size = o.size    
    for i, info in ipairs(TRACKED) do
        local b = info.button
        b:SetSize(size, size)
        b:ClearAllPoints()
        b:SetPoint("LEFT", (i - 1) * (size + GAP), 0)
        if o.hidden[info.key] then
            b:Hide()
        else
            b:Show()
        end
    end
    container:SetSize(#TRACKED * (size + GAP) - GAP, size)
end

function Refresh()
    local hasTarget = IsHostileNpc("target") and not UnitIsDead("target")
    if not hasTarget and not unlocked then
        container:Hide()
        return
    end
    container:Show()
    for _, info in ipairs(TRACKED) do
        local b = info.button
        local immune, source, origin = CheckImmunity(info.key, "target")
        b.status = source
        b.origin = origin
        if immune then
            b.icon:SetDesaturated(true)
            b.icon:SetVertexColor(1, 0.3, 0.3)
            b.icon:SetAlpha(0.8)
            b.cross:Show()
        else
            b.icon:SetDesaturated(false)
            b.icon:SetVertexColor(1, 1, 1)
            b.icon:SetAlpha(1)
            b.cross:Hide()
        end
    end
end

local function SetUnlocked(value)
    unlocked = value and true or false
    container.bg:SetShown(unlocked)
    Refresh()
end


-- Live sharing (party / raid / guild)

local function Broadcast(id, key, immune, name)
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    local msg = ("%d;%s;%d;%s"):format(id, key, immune and 1 or 0, (name or ""):sub(1, 100))
    if IsInRaid() then
        C_ChatInfo.SendAddonMessage(PREFIX, msg, "RAID")
    elseif IsInGroup() then
        C_ChatInfo.SendAddonMessage(PREFIX, msg, "PARTY")
    end
    if IsInGuild() then
        C_ChatInfo.SendAddonMessage(PREFIX, msg, "GUILD")
    end
end

local function ReceiveShared(text, sender)
    if Opt().blockReceive then return end -- incoming sharing blocked
    if sender and sender:match("^[^-]+") == UnitName("player") then return end
    local id, key, val, name = text:match("^(%d+);(%a+);([01]);(.*)$")
    if not id or not KEYS[key] then return end
    id = tonumber(id)
    local e = HemophileShared[id] or {}
    if name ~= "" then e.name = name end
    e[key] = (val == "1")
    HemophileShared[id] = e
    Refresh()
end


-- Saving what you mark

function Learn(guid, mobName, key, immune, silent, automatic)
    local id = NpcIdFromGUID(guid)
    if not id then return end
    if not automatic then
        local autoEntry = HemophileAuto and HemophileAuto[id]
        if autoEntry then
            autoEntry[key] = nil
            if autoEntry.bleed == nil and autoEntry.poison == nil then
                HemophileAuto[id] = nil
            end
        end
    end
    local data = automatic and HemophileAuto or HemophileDB
    data[id] = data[id] or {}
    local entry = data[id]
    entry.name = mobName or entry.name
    if entry[key] == immune then Refresh() return end
    entry[key] = immune
    Broadcast(id, key, immune, entry.name)
    if not silent then
        print(("|cff00ff00Hemophile:|r %s: %s %s (saved)"):format(
            mobName or ("NPC " .. id), immune and "immune to" or "can be hit by", Pretty(key)))
    end
    if guid == UnitGUID("target") then Refresh() end
end

function ClearAutoLearnedPoison(id, guid, mobName)
    local entry = id and HemophileAuto and HemophileAuto[id]
    if not entry or entry.poison ~= false then return end

    entry.poison = nil
    if entry.bleed == nil then HemophileAuto[id] = nil end
    if latest and latest.guid == guid and latest.key == "poison" then latest = nil end

    print(("|cff00ff00Hemophile:|r cleared the auto-detected poisonability for %s; apply poison again to retest."):format(
        mobName or ("NPC " .. id)))
    Refresh()
end


-- Auto-learn immunity from casts that test bleed or poison effects.

local SPELL_KEYS = {}
local function TrackSpells(key, ids)
    for _, id in ipairs(ids) do
        SPELL_KEYS[id] = key
    end
end

-- Rogue bleeds
TrackSpells("bleed", {
    1943, 8639, 8640, 11273, 11274, 11275, -- Rupture
    703, 8631, 8632, 8633, 11289, 11290,  -- Garrote
})

-- Hunter stings count as evidence for the shared poison flag.
TrackSpells("poison", {
    2818, 2819, 11353, 11354, 25349, 26968, 27187, 57970, -- Deadly Poison ranks
    1978, 13549, 13550, 13551, 13552, 13553, 13554, 13555, 25295, -- Serpent Sting
    3034, 14279, 14280,                                          -- Viper Sting
    3043, 14275, 14276, 14277,                                   -- Scorpid Sting
})

-- Other class bleeds
TrackSpells("bleed", {
    772, 6546, 6547, 6548, 11572, 11573, 11574, -- Warrior Rend
    1079, 9492, 9493, 9752, 9894, 9896,         -- Druid Rip
    1822, 1823, 1824, 9904,                      -- Druid Rake
    33745, 48567, 48568,                         -- Druid Lacerate
})

local WINDOW = 0.5 -- seconds after a cast in which an IMMUNE result counts

-- Called when you successfully cast a spell
local function OnTrackedCast(spellID)
    if not Opt().autoLearn then return end
    local key = SPELL_KEYS[spellID]
    if not key then return end
    if not IsHostileNpc("target") then return end
    local guid = UnitGUID("target")

    local p = { key = key, guid = guid, name = UnitName("target"), time = GetTime() }
    latest = p

    C_Timer.After(WINDOW, function()
        if latest ~= p or p.immune then return end -- superseded or already learned as immune
        if UnitGUID("target") ~= guid then return end
        -- No IMMUNE result arrived, so the cast was not immune.
        Learn(guid, p.name, key, false, true, true)
    end)
end

-- Called for UNIT_COMBAT events on your target
local function OnTargetCombat(action)
    local p = latest
    if not p or p.immune then return end
    if GetTime() - p.time > WINDOW then return end
    if UnitGUID("target") ~= p.guid then return end
    if action == "IMMUNE" then
        p.immune = true
        -- Already shown as immune (type guess, database...)? Save it quietly, no message.
        Learn(p.guid, p.name, p.key, true, true, true)
    end
end
local debugCombat = false

---------------------------------------------------------------------
-- Export / import window
---------------------------------------------------------------------
local io
local function ShowIO(title, text, buttonLabel, onAccept)
    if not io then
        io = CreateFrame("Frame", "HemophileIO", UIParent, "BasicFrameTemplateWithInset")
        io:SetSize(460, 320)
        io:SetPoint("CENTER")
        io:SetFrameStrata("FULLSCREEN_DIALOG")
        io:SetMovable(true)
        io:EnableMouse(true)
        io:RegisterForDrag("LeftButton")
        io:SetScript("OnDragStart", io.StartMoving)
        io:SetScript("OnDragStop", io.StopMovingOrSizing)

        io.title = io:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        io.title:SetPoint("TOP", 0, -6)

        local sf = CreateFrame("ScrollFrame", "HemophileIOScroll", io, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 12, -30)
        sf:SetPoint("BOTTOMRIGHT", -32, 44)

        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(380)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function() io:Hide() end)
        sf:SetScrollChild(eb)
        io.edit = eb

        local btn = CreateFrame("Button", nil, io, "UIPanelButtonTemplate")
        btn:SetSize(100, 24)
        btn:SetPoint("BOTTOM", 0, 12)
        btn:SetScript("OnClick", function()
            if io.onAccept then io.onAccept(io.edit:GetText()) end
            io:Hide()
        end)
        io.button = btn
    end
    io.title:SetText(title)
    io.button:SetText(buttonLabel)
    io.onAccept = onAccept
    io.edit:SetText(text or "")
    io:Show()
    io.edit:SetFocus()
    if text and text ~= "" then io.edit:HighlightText() end
end

local function BuildExport()
    local merged = {}
    local function add(src)
        for id, e in pairs(src) do
            if type(id) == "number" then
                local m = merged[id] or {}
                m.name = e.name or m.name
                for k in pairs(KEYS) do
                    if e[k] ~= nil then m[k] = e[k] end
                end
                merged[id] = m
            end
        end
    end
    add(HemophileShared)
    add(HemophileDB)
    add(HemophileAuto) -- automatic observations take precedence
    local ids = {}
    for id in pairs(merged) do ids[#ids + 1] = id end
    table.sort(ids)
    local lines = {}
    for _, id in ipairs(ids) do
        local m = merged[id]
        local cleanName = ((m.name or ""):gsub(";", ""))
        lines[#lines + 1] = ("%d;%s;%s;%s"):format(id, cleanName,
            Flag(m.bleed), Flag(m.poison))
    end
    return table.concat(lines, "\n"), #ids
end

local function OpenExport()
    local text, n = BuildExport()
    print(("Hemophile: exporting %d mobs. Press Ctrl+C to copy."):format(n))
    ShowIO("Hemophile export", text, "Close")
end

local function OpenImport()
    ShowIO("Paste Hemophile data here", "", "Import", function(text)
        local n = ParseLines(text, HemophileShared)
        print(("Hemophile: imported %d mobs."):format(n))
        Refresh()
    end)
end

---------------------------------------------------------------------
-- Options window
---------------------------------------------------------------------
local optionsFrame
local UpdateMinimapButton -- forward declaration (defined below ShowOptions)

local function MakeCheckbox(parent, label, x, y, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetSize(26, 26)
    local text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    text:SetText(label)
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    cb.label = text
    return cb
end

local function BuildOptions()
    local f = CreateFrame("Frame", "HemophileOptions", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(300, 540)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "HemophileOptions") -- Escape closes it

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -6)
    title:SetText("Hemophile options")

    -- Icon size slider
    local sizeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sizeLabel:SetPoint("TOPLEFT", 18, -36)

    local slider = CreateFrame("Slider", "HemophileSizeSlider", f, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 22, -64)
    slider:SetWidth(250)
    slider:SetMinMaxValues(MIN_SIZE, MAX_SIZE)
    slider:SetValueStep(1)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    local low, high, txt = _G["HemophileSizeSliderLow"], _G["HemophileSizeSliderHigh"], _G["HemophileSizeSliderText"]
    if low then low:SetText(MIN_SIZE) end
    if high then high:SetText(MAX_SIZE) end
    if txt then txt:SetText("") end
    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        Opt().size = value
        sizeLabel:SetText("Icon size: " .. value)
        ApplyLayout()
    end)
    f.slider, f.sizeLabel = slider, sizeLabel

    -- Show/hide each icon
    local showLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    showLabel:SetPoint("TOPLEFT", 18, -104)
    showLabel:SetText("Show icons")

    f.iconChecks = {}
    for i, info in ipairs(TRACKED) do
        local cb = MakeCheckbox(f, info.name, 14, -104 - i * 26, function(checked)
            Opt().hidden[info.key] = (not checked) or nil
            ApplyLayout()
        end)
        f.iconChecks[info.key] = cb
    end

    -- Position
    local posLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    posLabel:SetPoint("TOPLEFT", 18, -214)
    posLabel:SetText("Position")

    f.unlockCheck = MakeCheckbox(f, "Unlock icons (drag to move)", 14, -230, function(checked)
        SetUnlocked(checked)
    end)

    local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    resetBtn:SetSize(170, 22)
    resetBtn:SetPoint("TOP", 0, -260)
    resetBtn:SetText("Reset to target frame")
    resetBtn:SetScript("OnClick", function()
        Opt().pos = nil
        ApplyPosition()
        print("Hemophile: icon position reset.")
    end)

    -- Automatic learning
    local learnLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    learnLabel:SetPoint("TOPLEFT", 18, -296)
    learnLabel:SetText("Learning")

    f.autoCheck = MakeCheckbox(f, "Auto-learn immunities", 14, -312, function(checked)
        Opt().autoLearn = checked
        print("Hemophile: auto-learning is " .. (checked and "ON" or "OFF"))
    end)

    -- Block incoming live sharing
    local shareLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    shareLabel:SetPoint("TOPLEFT", 18, -346)
    shareLabel:SetText("Live sharing")

    f.blockCheck = MakeCheckbox(f, "Block incoming shared data", 14, -362, function(checked)
        Opt().blockReceive = checked
        print("Hemophile: incoming live sharing is " .. (checked and "BLOCKED" or "allowed"))
    end)

    -- Minimap button
    local mmLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mmLabel:SetPoint("TOPLEFT", 18, -396)
    mmLabel:SetText("Minimap")

    f.minimapCheck = MakeCheckbox(f, "Show minimap button", 14, -412, function(checked)
        Opt().minimapHide = (not checked) or nil
        UpdateMinimapButton()
    end)

    -- Import / export
    local dataLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dataLabel:SetPoint("TOPLEFT", 18, -446)
    dataLabel:SetText("Data")

    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetSize(120, 22)
    exportBtn:SetPoint("TOPLEFT", 20, -464)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", OpenExport)

    local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    importBtn:SetSize(120, 22)
    importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 8, 0)
    importBtn:SetText("Import")
    importBtn:SetScript("OnClick", OpenImport)

    local wipeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    wipeBtn:SetSize(200, 24)
    wipeBtn:SetPoint("BOTTOM", 0, 14)
    wipeBtn:SetText("Clear shared/imported data")
    wipeBtn:SetScript("OnClick", function()
        wipe(HemophileShared)
        print("Hemophile: cleared all shared/imported data (your own marks are untouched).")
        Refresh()
    end)

    -- Locking again when the window closes keeps icons from being dragged by accident
    f:SetScript("OnHide", function()
        if unlocked then
            f.unlockCheck:SetChecked(false)
            SetUnlocked(false)
        end
    end)

    return f
end

local function ShowOptions()
    if not optionsFrame then optionsFrame = BuildOptions() end
    local o = Opt()
    optionsFrame.slider:SetValue(o.size)
    optionsFrame.sizeLabel:SetText("Icon size: " .. o.size)
    for _, info in ipairs(TRACKED) do
        optionsFrame.iconChecks[info.key]:SetChecked(not o.hidden[info.key])
    end
    optionsFrame.unlockCheck:SetChecked(unlocked)
    optionsFrame.autoCheck:SetChecked(o.autoLearn)
    optionsFrame.blockCheck:SetChecked(o.blockReceive)
    optionsFrame.minimapCheck:SetChecked(not o.minimapHide)
    optionsFrame:Show()
end

---------------------------------------------------------------------
-- Minimap button (Hemorrhage icon, opens the options window)
---------------------------------------------------------------------
local MINIMAP_ICON = "Interface\\Icons\\Spell_Shadow_LifeDrain" -- Hemorrhage
local minimapButton

local function PositionMinimapButton()
    if not minimapButton then return end
    local angle = math.rad(Opt().minimapAngle or 200)
    local cosA, sinA = math.cos(angle), math.sin(angle)
    local w = (Minimap:GetWidth() / 2) + 5
    local h = (Minimap:GetHeight() / 2) + 5
    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local x, y
    if shape == "ROUND" then
        x, y = cosA * w, sinA * h
    else -- square-ish minimap: slide along the edge
        local dw, dh = math.sqrt(2 * w * w), math.sqrt(2 * h * h)
        x = math.max(-w, math.min(cosA * dw, w))
        y = math.max(-h, math.min(sinA * dh, h))
    end
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function MinimapButton_OnUpdate(self)
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    local angle = math.deg((math.atan2 or math.atan)(cy - my, cx - mx))
    if angle < 0 then angle = angle + 360 end
    Opt().minimapAngle = angle
    PositionMinimapButton()
end

local function BuildMinimapButton()
    local b = CreateFrame("Button", "HemophileMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    b:SetClampedToScreen(true)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(MINIMAP_ICON)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)
    b.icon = icon

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    b:SetScript("OnClick", function()
        if optionsFrame and optionsFrame:IsShown() then
            optionsFrame:Hide()
        else
            ShowOptions()
        end
    end)

    b:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self.icon:SetTexCoord(0, 1, 0, 1)
        self:SetScript("OnUpdate", MinimapButton_OnUpdate)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self.icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    end)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Hemophile")
        GameTooltip:AddLine("Click to open the options", 1, 1, 1)
        GameTooltip:AddLine("Drag to move this button", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return b
end

function UpdateMinimapButton()
    if not minimapButton then minimapButton = BuildMinimapButton() end
    PositionMinimapButton()
    minimapButton:SetShown(not Opt().minimapHide)
end

---------------------------------------------------------------------
-- Events (no combat log, no aura reads: this client blocks both)
---------------------------------------------------------------------
container:RegisterEvent("ADDON_LOADED")
container:RegisterEvent("PLAYER_TARGET_CHANGED")
container:RegisterEvent("UNIT_CLASSIFICATION_CHANGED")
container:RegisterEvent("CHAT_MSG_ADDON")
container:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
container:RegisterUnitEvent("UNIT_COMBAT", "target")
container:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, a5)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- a1 unit, a2 castGUID, a3 spellID
        pcall(OnTrackedCast, a3)
    elseif event == "UNIT_COMBAT" then
        -- a1 unit, a2 action ("IMMUNE", "DODGE", "WOUND", ...), a3 flag, a4 amount, a5 school
        if debugCombat then
            print(("Hemophile debug: action=%s flag=%s amount=%s school=%s"):format(
                tostring(a2), tostring(a3), tostring(a4), tostring(a5)))
        end
        pcall(OnTargetCombat, a2)
    elseif event == "ADDON_LOADED" then
        if a1 == "Hemophile" then
            HemophileDB = HemophileDB or {}
            HemophileShared = HemophileShared or {}
            HemophileAuto = HemophileAuto or {}
            HemophileCharacterDB = HemophileCharacterDB or {}
            if not HemophileCharacterDB.options and HemophileDB.options then
                HemophileCharacterDB.options = HemophileDB.options
                HemophileDB.options = nil
            end
            if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
                C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
            end
            ApplyLayout()
            ApplyPosition()
            UpdateMinimapButton()
        end
    elseif event == "CHAT_MSG_ADDON" then
        -- a1 prefix, a2 text, a3 channel, a4 sender
        if a1 == PREFIX then ReceiveShared(a2, a4) end
    else
        Refresh()
    end
end)

---------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------
SLASH_HEMOPHILE1 = "/hemophile"
SLASH_HEMOPHILE2 = "/hemo"
SlashCmdList["HEMOPHILE"] = function(msg)
    local cmd, which = msg:lower():match("^(%S*)%s*(%S*)$")

    if cmd == "options" or cmd == "config" or cmd == "opt" then
        ShowOptions()
        return
    elseif cmd == "debug" then
        debugCombat = not debugCombat
        print("Hemophile: combat debug output is " .. (debugCombat and "ON" or "OFF"))
        return
    elseif cmd == "export" then
        OpenExport()
        return
    elseif cmd == "import" then
        OpenImport()
        return
    end

    local guid = UnitGUID("target")
    local id = NpcIdFromGUID(guid)
    if not id then
        print("Hemophile: /hemophile options | export | import | immune | hittable | forget (the last three need a mob targeted)")
        return
    end

    if cmd == "forget" then
        HemophileDB[id] = nil
        HemophileShared[id] = nil
        HemophileAuto[id] = nil
        print("Hemophile: cleared saved, shared, and auto-detected data for " .. (UnitName("target") or id))
        Refresh()
        return
    end

    if cmd ~= "immune" and cmd ~= "hittable" then
        print("Hemophile: /hemophile options, immune|hittable [bleed|poison|all], forget, export, import")
        return
    end

    local value = (cmd == "immune")
    for _, info in ipairs(TRACKED) do
        if which == "" or which == "all" or which == info.key then
            Learn(guid, UnitName("target"), info.key, value)
        end
    end
end
