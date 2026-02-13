-- goomihealthstonereminder.lua - Healthstone reminder module for GoomiUI
-- Version 2.1 - Uses LibCustomGlow from GoomiUI

if not GoomiUI then
    print("Error: GoomiHealthStoneReminder requires GoomiUI to be installed!")
    return
end

local HealthstoneReminder = {
    name = "Healthstone Reminder",
    version = "2.1",
}

-- SavedVariables (will be loaded by WoW before addon code runs)
GoomiHealthStoneReminderDB = GoomiHealthStoneReminderDB or {}

-- Event frame to ensure SavedVariables are loaded
local addonLoadFrame = CreateFrame("Frame")
addonLoadFrame:RegisterEvent("ADDON_LOADED")
addonLoadFrame:SetScript("OnEvent", function(self, event, addonName)
    if addonName == "GoomiHealthStoneReminder" then
        -- Ensure DB exists
        GoomiHealthStoneReminderDB = GoomiHealthStoneReminderDB or {}
        print("GoomiHealthStoneReminder: SavedVariables loaded")
        print("Current settings:", "size=" .. (GoomiHealthStoneReminderDB.iconSize or "nil"), 
              "opacity=" .. (GoomiHealthStoneReminderDB.opacity or "nil"),
              "glow=" .. (GoomiHealthStoneReminderDB.glowStyle or "nil"))
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

local defaults = {
    enabled = true,
    iconSize = 28,
    posX = 0,
    posY = 20,
    opacity = 0.7,
    glowStyle = "pixel",  -- pixel, autocast, button, proc, none
    
    -- Glow color (shared by all glow types)
    glowR = 1,
    glowG = 0,
    glowB = 0,
    glowA = 1,
    
    -- Pixel glow thickness (only exposed setting)
    pixelThick = 2,       -- Particle thickness (1-10)
}

local function Clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

local function InitDB()
    local db = GoomiHealthStoneReminderDB
    for k, v in pairs(defaults) do
        if db[k] == nil then db[k] = v end
    end
    
    db.iconSize = Clamp(tonumber(db.iconSize) or defaults.iconSize, 20, 100)
    db.posX = Clamp(tonumber(db.posX) or defaults.posX, -1000, 1000)
    db.posY = Clamp(tonumber(db.posY) or defaults.posY, -1000, 1000)
    db.opacity = Clamp(tonumber(db.opacity) or defaults.opacity, 0.1, 1.0)
end

-- Module variables
local iconFrame, anchorFrame
local eventFrame
local ticker
local soulwellActive = false
local soulwellExpireTime = 0
local inGroup = false
local eventsRegistered = false

-- Try to get LibCustomGlow from GoomiUI
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)

-- ======================
-- Icon Frame
-- ======================
local function CreateIconFrame()
    if iconFrame then return iconFrame end
    
    local db = GoomiHealthStoneReminderDB
    
    iconFrame = CreateFrame("Frame", "GoomiHealthStoneReminderIcon", UIParent)
    iconFrame:SetSize(db.iconSize, db.iconSize)
    iconFrame:SetPoint("BOTTOM", UIParent, "CENTER", db.posX, db.posY)
    iconFrame:SetFrameStrata("MEDIUM")
    iconFrame:SetAlpha(db.opacity)
    iconFrame:Hide()
    
    -- Main icon
    iconFrame.icon = iconFrame:CreateTexture(nil, "BACKGROUND")
    iconFrame.icon:SetAllPoints()
    iconFrame.icon:SetTexture(538745)  -- Healthstone icon
    
    -- Healthstone count
    iconFrame.charges = iconFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    iconFrame.charges:SetPoint("CENTER")
    iconFrame.charges:SetTextColor(1, 1, 1, 1)
    
    return iconFrame
end

-- Apply the selected glow style
local function ApplyGlowStyle(frame, show)
    if not frame then 
        print("WARNING: ApplyGlowStyle called with nil frame!")
        return 
    end
    
    local db = GoomiHealthStoneReminderDB
    local style = db.glowStyle or "pixel"
    
    -- Hide all glow types first
    if LCG then
        LCG.PixelGlow_Stop(frame)
        LCG.AutoCastGlow_Stop(frame)
        LCG.ButtonGlow_Stop(frame)
        LCG.ProcGlow_Stop(frame)
    end
    
    if not show then return end
    
    -- Get glow color
    local color = {
        db.glowR or 1,
        db.glowG or 0,
        db.glowB or 0,
        db.glowA or 1
    }
    
    -- Apply selected style
    if style == "pixel" then
        if LCG then
            -- Use library defaults for N, freq, length; only thickness is customizable
            LCG.PixelGlow_Start(
                frame,
                color,
                8,                          -- N (lines) - library default
                0.25,                       -- frequency - library default
                8,                          -- length - library default
                db.pixelThick or 2          -- thickness - user customizable
            )
        else
            print("WARNING: LibCustomGlow not found! Add it to GoomiUI/Libs/")
        end
    elseif style == "autocast" then
        if LCG then
            -- Use all library defaults, just color is customizable
            LCG.AutoCastGlow_Start(frame, color)
        else
            print("WARNING: LibCustomGlow not found!")
        end
    elseif style == "button" then
        if LCG then
            -- Use all library defaults, just color is customizable
            LCG.ButtonGlow_Start(frame, color)
        else
            print("WARNING: LibCustomGlow not found!")
        end
    elseif style == "proc" then
        if LCG then
            LCG.ProcGlow_Start(frame, color)
        else
            print("WARNING: LibCustomGlow not found!")
        end
    end
    -- "none" = no glow
end

-- ======================
-- Anchor Frame
-- ======================
local function CreateAnchor()
    if anchorFrame then return anchorFrame end
    
    local db = GoomiHealthStoneReminderDB
    
    anchorFrame = CreateFrame("Frame", nil, UIParent)
    anchorFrame:SetSize(db.iconSize, db.iconSize)
    anchorFrame:SetFrameStrata("DIALOG")
    anchorFrame:SetMovable(true)
    anchorFrame:EnableMouse(false)
    anchorFrame:RegisterForDrag("LeftButton")
    anchorFrame:Hide()
    
    -- Main icon
    anchorFrame.icon = anchorFrame:CreateTexture(nil, "BACKGROUND")
    anchorFrame.icon:SetAllPoints()
    anchorFrame.icon:SetTexture(538745)
    
    anchorFrame.text = anchorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    anchorFrame.text:SetPoint("CENTER")
    anchorFrame.text:SetText("DRAG")
    anchorFrame.text:SetTextColor(1, 1, 1, 1)
    
    anchorFrame:SetScript("OnDragStart", anchorFrame.StartMoving)
    anchorFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x, y = self:GetCenter()
        local px, py = UIParent:GetCenter()
        
        GoomiHealthStoneReminderDB.posX = x - px
        GoomiHealthStoneReminderDB.posY = y - py
        
        UpdateIconAppearance()
        
        self:ClearAllPoints()
        self:SetPoint("BOTTOM", UIParent, "CENTER", GoomiHealthStoneReminderDB.posX, GoomiHealthStoneReminderDB.posY)
    end)
    
    -- Show glow on anchor when visible
    anchorFrame:SetScript("OnShow", function(self)
        ApplyGlowStyle(self, true)
    end)
    
    anchorFrame:SetScript("OnHide", function(self)
        ApplyGlowStyle(self, false)
    end)
    
    return anchorFrame
end

local function UpdateIconAppearance()
    if not iconFrame then return end
    
    local db = GoomiHealthStoneReminderDB
    iconFrame:SetSize(db.iconSize, db.iconSize)
    iconFrame:SetAlpha(db.opacity)
    iconFrame:ClearAllPoints()
    iconFrame:SetPoint("BOTTOM", UIParent, "CENTER", db.posX, db.posY)
end

local function UpdateAnchorPosition()
    if not anchorFrame then return end
    
    local db = GoomiHealthStoneReminderDB
    anchorFrame:SetSize(db.iconSize, db.iconSize)
    anchorFrame:ClearAllPoints()
    anchorFrame:SetPoint("BOTTOM", UIParent, "CENTER", db.posX, db.posY)
end

-- ======================
-- Healthstone Detection
-- ======================
local function GetHealthstoneCount()
    local count1 = C_Item.GetItemCount(5512, false, true) or 0
    local count2 = C_Item.GetItemCount(224464, false, true) or 0
    return count1 + count2
end

local function UpdateIcon()
    local db = GoomiHealthStoneReminderDB
    if not db.enabled then
        if iconFrame then 
            iconFrame:Hide()
            ApplyGlowStyle(iconFrame, false)
        end
        return
    end
    
    if not iconFrame then CreateIconFrame() end
    
    local count = GetHealthstoneCount()
    if soulwellActive and count <= 1 then
        iconFrame.charges:SetText(count)
        iconFrame:Show()
        ApplyGlowStyle(iconFrame, true)
    else
        iconFrame:Hide()
        ApplyGlowStyle(iconFrame, false)
    end
end

-- ======================
-- Event Handlers
-- ======================
local function OnUnitSpellcastSucceeded(unit, castGUID, spellID)
    -- Verify we're in a group
    if not (IsInGroup() or IsInRaid()) then return end
    
    -- Only care about spells cast by the player (for testing) or party/raid members
    if unit ~= "player" and not UnitInParty(unit) and not UnitInRaid(unit) then
        return
    end
    
    -- Normalize spell ID (handles secret spell IDs from Patch 11.0)
    spellID = tonumber(tostring(spellID))
    
    -- Check for Create Soulwell (spell ID 29893)
    if spellID == 29893 then
        -- Verify the caster is in our party/raid
        if UnitInParty(unit) or UnitInRaid(unit) or unit == "player" then
            print("DEBUG: Soulwell detected from", UnitName(unit))
            soulwellActive = true
            soulwellExpireTime = GetTime() + 120  -- Soulwell lasts 2 minutes
            UpdateIcon()
        end
    end
end

local function OnBagUpdate()
    if soulwellActive then
        UpdateIcon()
    end
end

-- ======================
-- Ticker-Based Group Detection
-- ======================
local function OnUpdate()
    local db = GoomiHealthStoneReminderDB
    if not db.enabled then
        -- Addon disabled - clean up
        if eventsRegistered and eventFrame then
            eventFrame:UnregisterAllEvents()
            eventsRegistered = false
        end
        if iconFrame then 
            iconFrame:Hide()
            ApplyGlowStyle(iconFrame, false)
        end
        return
    end
    
    local nowInGroup = IsInGroup() or IsInRaid()
    
    -- Group status changed
    if nowInGroup ~= inGroup then
        inGroup = nowInGroup
        
        if inGroup and not eventsRegistered then
            -- Just joined group - register events
            if eventFrame then
                eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", 
                    "player", "party1", "party2", "party3", "party4",
                    "raid1", "raid2", "raid3", "raid4", "raid5", "raid6", "raid7", "raid8", "raid9", "raid10",
                    "raid11", "raid12", "raid13", "raid14", "raid15", "raid16", "raid17", "raid18", "raid19", "raid20",
                    "raid21", "raid22", "raid23", "raid24", "raid25", "raid26", "raid27", "raid28", "raid29", "raid30",
                    "raid31", "raid32", "raid33", "raid34", "raid35", "raid36", "raid37", "raid38", "raid39", "raid40")
                eventFrame:RegisterEvent("BAG_UPDATE")
                eventsRegistered = true
            end
        elseif not inGroup and eventsRegistered then
            -- Left group - unregister events
            if eventFrame then
                eventFrame:UnregisterAllEvents()
                eventsRegistered = false
            end
            soulwellActive = false
            if iconFrame then 
                iconFrame:Hide()
                ApplyGlowStyle(iconFrame, false)
            end
        end
    end
    
    -- Check soulwell expiration
    if soulwellActive and GetTime() >= soulwellExpireTime then
        soulwellActive = false
        UpdateIcon()
    end
end

-- ======================
-- Module Lifecycle
-- ======================
function HealthstoneReminder:OnLoad()
    InitDB()
    CreateIconFrame()
    CreateAnchor()
    UpdateIconAppearance()
    UpdateAnchorPosition()
    
    -- Create event frame but don't register events yet
    eventFrame = CreateFrame("Frame")
    eventFrame:SetScript("OnEvent", function(self, event, ...)
        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            OnUnitSpellcastSucceeded(...)
        elseif event == "BAG_UPDATE" then
            OnBagUpdate()
        end
    end)
    
    -- Start ticker-based group detection
    ticker = C_Timer.NewTicker(1, OnUpdate)
end

function HealthstoneReminder:OnDisable()
    -- Clean up when module is disabled
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    if eventFrame then
        eventFrame:UnregisterAllEvents()
        eventsRegistered = false
    end
    if iconFrame then
        iconFrame:Hide()
        ApplyGlowStyle(iconFrame, false)
    end
end

-- ======================
-- Settings UI
-- ======================
function HealthstoneReminder:CreateSettings(parentFrame)
    local db = GoomiHealthStoneReminderDB
    
    -- Track anchor visibility
    local anchorEnabled = false
    local anchorBtn  -- Will be set later
    
    -- Auto-hide anchor when settings panel closes
    parentFrame:SetScript("OnHide", function()
        if anchorFrame and anchorFrame:IsShown() then
            anchorFrame:EnableMouse(false)
            anchorFrame:Hide()
            anchorEnabled = false
        end
    end)
    
    -- Reset button text when settings panel reopens
    parentFrame:SetScript("OnShow", function()
        if anchorBtn then
            if anchorFrame and anchorFrame:IsShown() then
                anchorBtn:SetText("Hide Anchor")
                anchorEnabled = true
            else
                anchorBtn:SetText("Show Anchor")
                anchorEnabled = false
            end
        end
    end)
    
    local function CreateBorder(parent, thickness, r, g, b, a)
        thickness, r, g, b, a = thickness or 1, r or 0, g or 0, b or 0, a or 1
        
        local top = parent:CreateTexture(nil, "OVERLAY")
        top:SetColorTexture(r, g, b, a)
        top:SetHeight(thickness)
        top:SetPoint("TOPLEFT")
        top:SetPoint("TOPRIGHT")
        
        local bottom = parent:CreateTexture(nil, "OVERLAY")
        bottom:SetColorTexture(r, g, b, a)
        bottom:SetHeight(thickness)
        bottom:SetPoint("BOTTOMLEFT")
        bottom:SetPoint("BOTTOMRIGHT")
        
        local left = parent:CreateTexture(nil, "OVERLAY")
        left:SetColorTexture(r, g, b, a)
        left:SetWidth(thickness)
        left:SetPoint("TOPLEFT")
        left:SetPoint("BOTTOMLEFT")
        
        local right = parent:CreateTexture(nil, "OVERLAY")
        right:SetColorTexture(r, g, b, a)
        right:SetWidth(thickness)
        right:SetPoint("TOPRIGHT")
        right:SetPoint("BOTTOMRIGHT")
    end
    
    -- Title
    local title = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText("HEALTHSTONE REMINDER")
    title:SetTextColor(1, 1, 1, 1)
    
    -- Show Anchor Button (top right)
    anchorBtn = CreateFrame("Button", nil, parentFrame, "UIPanelButtonTemplate")
    anchorBtn:SetSize(120, 30)
    anchorBtn:SetPoint("TOPRIGHT", 0, -2)
    anchorBtn:SetText("Show Anchor")
    
    anchorBtn:SetScript("OnClick", function(self)
        anchorEnabled = not anchorEnabled
        
        if anchorEnabled then
            self:SetText("Hide Anchor")
            if anchorFrame then
                anchorFrame:EnableMouse(true)
                anchorFrame:Show()
            end
        else
            self:SetText("Show Anchor")
            if anchorFrame then
                anchorFrame:EnableMouse(false)
                anchorFrame:Hide()
            end
        end
    end)
    
    -- Description
    local desc = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    desc:SetPoint("TOPLEFT", 0, -35)
    desc:SetWidth(550)
    desc:SetJustifyH("LEFT")
    desc:SetText("Shows a reminder icon when a soulwell is active and you have 1 or fewer healthstones. Only active when you're in a group or raid.")
    desc:SetTextColor(0.7, 0.7, 0.7, 1)
    
    local yOffset = 75
    
    -- Icon Size Control
    local sizeContainer = CreateFrame("Frame", nil, parentFrame)
    sizeContainer:SetSize(600, 40)
    sizeContainer:SetPoint("TOPLEFT", 0, -yOffset)
    
    sizeContainer.bg = sizeContainer:CreateTexture(nil, "BACKGROUND")
    sizeContainer.bg:SetAllPoints()
    sizeContainer.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
    CreateBorder(sizeContainer, 1, 0.2, 0.2, 0.2, 0.5)
    
    local sizeLabel = sizeContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sizeLabel:SetPoint("LEFT", 10, 0)
    sizeLabel:SetText("Size:")
    sizeLabel:SetTextColor(1, 1, 1, 1)
    
    local minus = CreateFrame("Button", nil, sizeContainer, "UIPanelButtonTemplate")
    minus:SetSize(30, 24)
    minus:SetPoint("LEFT", sizeLabel, "RIGHT", 10, 0)
    minus:SetText("-")
    
    local sizeBox = CreateFrame("EditBox", nil, sizeContainer, "InputBoxTemplate")
    sizeBox:SetSize(50, 24)
    sizeBox:SetPoint("LEFT", minus, "RIGHT", 5, 0)
    sizeBox:SetNumeric(true)
    sizeBox:SetAutoFocus(false)
    sizeBox:SetJustifyH("CENTER")
    sizeBox:SetText(tostring(db.iconSize))
    
    local plus = CreateFrame("Button", nil, sizeContainer, "UIPanelButtonTemplate")
    plus:SetSize(30, 24)
    plus:SetPoint("LEFT", sizeBox, "RIGHT", 5, 0)
    plus:SetText("+")
    
    local function SetSize(v)
        v = Clamp(tonumber(v) or defaults.iconSize, 20, 100)
        GoomiHealthStoneReminderDB.iconSize = v  -- Write directly to global
        sizeBox:SetText(tostring(v))
        UpdateIconAppearance()
        UpdateAnchorPosition()
    end
    
    minus:SetScript("OnClick", function() SetSize(db.iconSize - 1) end)
    plus:SetScript("OnClick", function() SetSize(db.iconSize + 1) end)
    
    -- Store original value when focused
    local originalValue
    sizeBox:SetScript("OnEditFocusGained", function(self)
        originalValue = db.iconSize
    end)
    
    sizeBox:SetScript("OnEnterPressed", function(self) 
        SetSize(self:GetText())
        self:ClearFocus()
    end)
    
    sizeBox:SetScript("OnEditFocusLost", function(self)
        -- Only update if we're not hitting escape
        if not self.escapingFocus then
            SetSize(self:GetText())
        end
        self.escapingFocus = nil
    end)
    
    sizeBox:SetScript("OnEscapePressed", function(self)
        self.escapingFocus = true
        db.iconSize = originalValue
        self:SetText(tostring(originalValue))
        self:ClearFocus()
        UpdateIconAppearance()
    end)
    
    yOffset = yOffset + 60
    
    -- Opacity Control
    local opacityContainer = CreateFrame("Frame", nil, parentFrame)
    opacityContainer:SetSize(600, 40)
    opacityContainer:SetPoint("TOPLEFT", 0, -yOffset)
    
    opacityContainer.bg = opacityContainer:CreateTexture(nil, "BACKGROUND")
    opacityContainer.bg:SetAllPoints()
    opacityContainer.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
    CreateBorder(opacityContainer, 1, 0.2, 0.2, 0.2, 0.5)
    
    local opacityLabel = opacityContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    opacityLabel:SetPoint("LEFT", 10, 0)
    opacityLabel:SetText("Opacity:")
    opacityLabel:SetTextColor(1, 1, 1, 1)
    
    local opacitySlider = CreateFrame("Slider", nil, opacityContainer, "OptionsSliderTemplate")
    opacitySlider:SetPoint("LEFT", opacityLabel, "RIGHT", 15, 0)
    opacitySlider:SetMinMaxValues(0.1, 1.0)
    opacitySlider:SetValue(db.opacity)
    opacitySlider:SetValueStep(0.05)
    opacitySlider:SetObeyStepOnDrag(true)
    opacitySlider:SetWidth(200)
    
    local opacityBox = CreateFrame("EditBox", nil, opacityContainer, "InputBoxTemplate")
    opacityBox:SetSize(50, 24)
    opacityBox:SetPoint("LEFT", opacitySlider, "RIGHT", 10, 0)
    opacityBox:SetAutoFocus(false)
    opacityBox:SetNumeric(false)
    opacityBox:SetText(string.format("%.0f", db.opacity * 100))
    
    local originalOpacity
    opacitySlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value * 100 + 0.5) / 100  -- Round to 2 decimals
        GoomiHealthStoneReminderDB.opacity = value
        opacityBox:SetText(string.format("%.0f", value * 100))
        UpdateIconAppearance()
    end)
    
    opacityBox:SetScript("OnEditFocusGained", function(self)
        originalOpacity = db.opacity
    end)
    
    opacityBox:SetScript("OnEnterPressed", function(self)
        local percent = tonumber(self:GetText()) or 70
        local value = Clamp(percent / 100, 0.1, 1.0)
        GoomiHealthStoneReminderDB.opacity = value
        opacitySlider:SetValue(value)
        UpdateIconAppearance()
        self:ClearFocus()
    end)
    
    opacityBox:SetScript("OnEditFocusLost", function(self)
        if not self.escapingFocus then
            local percent = tonumber(self:GetText()) or 70
            local value = Clamp(percent / 100, 0.1, 1.0)
            GoomiHealthStoneReminderDB.opacity = value
            opacitySlider:SetValue(value)
            UpdateIconAppearance()
        end
        self.escapingFocus = nil
    end)
    
    opacityBox:SetScript("OnEscapePressed", function(self)
        self.escapingFocus = true
        GoomiHealthStoneReminderDB.opacity = originalOpacity
        self:SetText(string.format("%.0f", originalOpacity * 100))
        opacitySlider:SetValue(originalOpacity)
        UpdateIconAppearance()
        self:ClearFocus()
    end)
    
    yOffset = yOffset + 60
    
    -- Glow Settings Section
    local glowHeader = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    glowHeader:SetPoint("TOPLEFT", 0, -yOffset)
    glowHeader:SetText("Glow Effect")
    glowHeader:SetTextColor(1, 1, 1, 1)
    
    yOffset = yOffset + 35
    
    -- Glow Style Dropdown
    local glowContainer = CreateFrame("Frame", nil, parentFrame)
    glowContainer:SetSize(600, 40)
    glowContainer:SetPoint("TOPLEFT", 0, -yOffset)
    
    glowContainer.bg = glowContainer:CreateTexture(nil, "BACKGROUND")
    glowContainer.bg:SetAllPoints()
    glowContainer.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
    CreateBorder(glowContainer, 1, 0.2, 0.2, 0.2, 0.5)
    
    local glowLabel = glowContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    glowLabel:SetPoint("LEFT", 10, 0)
    glowLabel:SetText("Glow Style:")
    glowLabel:SetTextColor(1, 1, 1, 1)
    
    local glowDropdown = CreateFrame("Frame", "GoomiHealthStoneGlowDropdown", glowContainer, "UIDropDownMenuTemplate")
    glowDropdown:SetPoint("LEFT", glowLabel, "RIGHT", 5, 0)
    UIDropDownMenu_SetWidth(glowDropdown, 150)
    
    local glowStyles = {
        { value = "pixel", name = "Pixel Glow" },
        { value = "autocast", name = "AutoCast Glow" },
        { value = "button", name = "Button Glow" },
        { value = "proc", name = "Proc Glow" },
        { value = "none", name = "None" }
    }
    
    -- Find current style name
    local currentStyleName = "Pixel Glow"
    for _, style in ipairs(glowStyles) do
        if style.value == (db.glowStyle or "pixel") then
            currentStyleName = style.name
            break
        end
    end
    UIDropDownMenu_SetText(glowDropdown, currentStyleName)
    
    -- Thickness slider container (will be shown/hidden based on glow type)
    local thickContainer = CreateFrame("Frame", nil, parentFrame)
    thickContainer:SetSize(600, 40)
    thickContainer:SetPoint("TOPLEFT", 0, -(yOffset + 45))
    
    thickContainer.bg = thickContainer:CreateTexture(nil, "BACKGROUND")
    thickContainer.bg:SetAllPoints()
    thickContainer.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
    CreateBorder(thickContainer, 1, 0.2, 0.2, 0.2, 0.5)
    
    local thickLabel = thickContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    thickLabel:SetPoint("LEFT", 10, 0)
    thickLabel:SetText("Thickness:")
    thickLabel:SetTextColor(1, 1, 1, 1)
    
    local thickSlider = CreateFrame("Slider", nil, thickContainer, "OptionsSliderTemplate")
    thickSlider:SetPoint("LEFT", thickLabel, "RIGHT", 15, 0)
    thickSlider:SetMinMaxValues(1, 10)
    thickSlider:SetValue(db.pixelThick or 2)
    thickSlider:SetValueStep(1)
    thickSlider:SetObeyStepOnDrag(true)
    thickSlider:SetWidth(200)
    
    local thickBox = CreateFrame("EditBox", nil, thickContainer, "InputBoxTemplate")
    thickBox:SetSize(50, 24)
    thickBox:SetPoint("LEFT", thickSlider, "RIGHT", 10, 0)
    thickBox:SetAutoFocus(false)
    thickBox:SetNumeric(true)
    thickBox:SetText(tostring(db.pixelThick or 2))
    
    local originalThick
    thickSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value)
        GoomiHealthStoneReminderDB.pixelThick = value
        thickBox:SetText(tostring(value))
        -- Update glow if showing
        if iconFrame and iconFrame:IsShown() then
            ApplyGlowStyle(iconFrame, true)
        end
        if anchorFrame and anchorFrame:IsShown() then
            ApplyGlowStyle(anchorFrame, true)
        end
    end)
    
    thickBox:SetScript("OnEditFocusGained", function(self)
        originalThick = db.pixelThick
    end)
    
    thickBox:SetScript("OnEnterPressed", function(self)
        local value = Clamp(tonumber(self:GetText()) or 2, 1, 10)
        GoomiHealthStoneReminderDB.pixelThick = value
        thickSlider:SetValue(value)
        -- Update glow if showing
        if iconFrame and iconFrame:IsShown() then
            ApplyGlowStyle(iconFrame, true)
        end
        if anchorFrame and anchorFrame:IsShown() then
            ApplyGlowStyle(anchorFrame, true)
        end
        self:ClearFocus()
    end)
    
    thickBox:SetScript("OnEditFocusLost", function(self)
        if not self.escapingFocus then
            local value = Clamp(tonumber(self:GetText()) or 2, 1, 10)
            GoomiHealthStoneReminderDB.pixelThick = value
            thickSlider:SetValue(value)
            if iconFrame and iconFrame:IsShown() then
                ApplyGlowStyle(iconFrame, true)
            end
            if anchorFrame and anchorFrame:IsShown() then
                ApplyGlowStyle(anchorFrame, true)
            end
        end
        self.escapingFocus = nil
    end)
    
    thickBox:SetScript("OnEscapePressed", function(self)
        self.escapingFocus = true
        GoomiHealthStoneReminderDB.pixelThick = originalThick
        self:SetText(tostring(originalThick))
        thickSlider:SetValue(originalThick)
        if iconFrame and iconFrame:IsShown() then
            ApplyGlowStyle(iconFrame, true)
        end
        if anchorFrame and anchorFrame:IsShown() then
            ApplyGlowStyle(anchorFrame, true)
        end
        self:ClearFocus()
    end)
    
    -- Function to update thickness visibility
    local function UpdateThicknessVisibility()
        if db.glowStyle == "pixel" then
            thickContainer:Show()
            yOffset = yOffset + 105  -- Account for both containers + spacing
        else
            thickContainer:Hide()
            yOffset = yOffset + 60  -- Just glow dropdown + spacing
        end
    end
    
    -- Initially set visibility
    UpdateThicknessVisibility()
    
    -- Dropdown initialization
    UIDropDownMenu_Initialize(glowDropdown, function(self, level)
        for _, style in ipairs(glowStyles) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = style.name
            info.checked = (GoomiHealthStoneReminderDB.glowStyle == style.value)
            info.func = function()
                GoomiHealthStoneReminderDB.glowStyle = style.value
                UIDropDownMenu_SetText(glowDropdown, style.name)
                
                -- Update thickness visibility
                if style.value == "pixel" then
                    thickContainer:Show()
                else
                    thickContainer:Hide()
                end
                
                -- Update glow on icon if it's showing
                if iconFrame and iconFrame:IsShown() then
                    ApplyGlowStyle(iconFrame, true)
                end
                -- Update anchor if it's showing
                if anchorFrame and anchorFrame:IsShown() then
                    ApplyGlowStyle(anchorFrame, true)
                end
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    
    -- Color Picker
    local colorContainer = CreateFrame("Frame", nil, parentFrame)
    colorContainer:SetSize(600, 60)
    colorContainer:SetPoint("TOPLEFT", 0, -yOffset)
    
    colorContainer.bg = colorContainer:CreateTexture(nil, "BACKGROUND")
    colorContainer.bg:SetAllPoints()
    colorContainer.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
    CreateBorder(colorContainer, 1, 0.2, 0.2, 0.2, 0.5)
    
    local colorBtn = CreateFrame("Button", nil, colorContainer, "UIPanelButtonTemplate")
    colorBtn:SetSize(120, 30)
    colorBtn:SetPoint("LEFT", 10, 0)
    colorBtn:SetText("Choose Color")
    
    -- Color Swatch
    local colorSwatch = CreateFrame("Frame", nil, colorContainer, "BackdropTemplate")
    colorSwatch:SetSize(30, 30)
    colorSwatch:SetPoint("LEFT", colorBtn, "RIGHT", 10, 0)
    colorSwatch:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    colorSwatch:SetBackdropColor(0, 0, 0, 1)
    colorSwatch:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    
    local colorSwatchTex = colorSwatch:CreateTexture(nil, "OVERLAY")
    colorSwatchTex:SetAllPoints(true)
    colorSwatchTex:SetColorTexture(db.glowR or 1, db.glowG or 0, db.glowB or 0, 1)
    
    -- Color Picker Button
    colorBtn:SetScript("OnClick", function()
        local prevR, prevG, prevB, prevA = db.glowR or 1, db.glowG or 0, db.glowB or 0, db.glowA or 1
        
        local info = {
            r = prevR,
            g = prevG,
            b = prevB,
            opacity = prevA,
            hasOpacity = true,
            
            swatchFunc = function()
                local r, g, b = ColorPickerFrame:GetColorRGB()
                GoomiHealthStoneReminderDB.glowR = r
                GoomiHealthStoneReminderDB.glowG = g
                GoomiHealthStoneReminderDB.glowB = b
                
                colorSwatchTex:SetColorTexture(r, g, b, 1)
                
                -- Update glow if showing
                if iconFrame and iconFrame:IsShown() then
                    ApplyGlowStyle(iconFrame, true)
                end
                if anchorFrame and anchorFrame:IsShown() then
                    ApplyGlowStyle(anchorFrame, true)
                end
            end,
            
            opacityFunc = function()
                local a = 1 - OpacitySliderFrame:GetValue()
                GoomiHealthStoneReminderDB.glowA = a
                
                -- Update glow if showing
                if iconFrame and iconFrame:IsShown() then
                    ApplyGlowStyle(iconFrame, true)
                end
                if anchorFrame and anchorFrame:IsShown() then
                    ApplyGlowStyle(anchorFrame, true)
                end
            end,
            
            cancelFunc = function()
                GoomiHealthStoneReminderDB.glowR = prevR
                GoomiHealthStoneReminderDB.glowG = prevG
                GoomiHealthStoneReminderDB.glowB = prevB
                GoomiHealthStoneReminderDB.glowA = prevA
                
                colorSwatchTex:SetColorTexture(prevR, prevG, prevB, 1)
                
                if iconFrame and iconFrame:IsShown() then
                    ApplyGlowStyle(iconFrame, true)
                end
                if anchorFrame and anchorFrame:IsShown() then
                    ApplyGlowStyle(anchorFrame, true)
                end
            end,
        }
        
        ColorPickerFrame:SetupColorPickerAndShow(info)
    end)
    
    yOffset = yOffset + 80
    
    -- Position Controls
    local posContainer = CreateFrame("Frame", nil, parentFrame)
    posContainer:SetSize(600, 90)
    posContainer:SetPoint("TOPLEFT", 0, -yOffset)
    
    posContainer.bg = posContainer:CreateTexture(nil, "BACKGROUND")
    posContainer.bg:SetAllPoints()
    posContainer.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
    CreateBorder(posContainer, 1, 0.2, 0.2, 0.2, 0.5)
    
    -- X Position
    local xLabel = posContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    xLabel:SetPoint("TOPLEFT", 10, -15)
    xLabel:SetText("X:")
    xLabel:SetTextColor(1, 1, 1, 1)
    
    local xSlider = CreateFrame("Slider", nil, posContainer, "OptionsSliderTemplate")
    xSlider:SetPoint("TOPLEFT", 30, -13)
    xSlider:SetMinMaxValues(-1000, 1000)
    xSlider:SetValue(db.posX)
    xSlider:SetValueStep(1)
    xSlider:SetObeyStepOnDrag(true)
    xSlider:SetWidth(200)
    
    local xBox = CreateFrame("EditBox", nil, posContainer, "InputBoxTemplate")
    xBox:SetSize(60, 20)
    xBox:SetPoint("LEFT", xSlider, "RIGHT", 10, 0)
    xBox:SetAutoFocus(false)
    xBox:SetNumeric(false)
    xBox:SetText(math.floor(db.posX))
    
    xSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value)
        GoomiHealthStoneReminderDB.posX = value  -- Write directly to global
        xBox:SetText(value)
        UpdateIconAppearance()
        UpdateAnchorPosition()
    end)
    
    xBox:SetScript("OnEnterPressed", function(self)
        local value = tonumber(self:GetText()) or 0
        GoomiHealthStoneReminderDB.posX = Clamp(value, -1000, 1000)  -- Write directly to global
        xSlider:SetValue(GoomiHealthStoneReminderDB.posX)
        UpdateIconAppearance()
        UpdateAnchorPosition()
        self:ClearFocus()
    end)
    
    xBox:SetScript("OnEscapePressed", function(self)
        self:SetText(math.floor(GoomiHealthStoneReminderDB.posX))
        self:ClearFocus()
    end)
    
    -- Y Position
    local yLabel = posContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    yLabel:SetPoint("TOPLEFT", 10, -55)
    yLabel:SetText("Y:")
    yLabel:SetTextColor(1, 1, 1, 1)
    
    local ySlider = CreateFrame("Slider", nil, posContainer, "OptionsSliderTemplate")
    ySlider:SetPoint("TOPLEFT", 30, -53)
    ySlider:SetMinMaxValues(-1000, 1000)
    ySlider:SetValue(db.posY)
    ySlider:SetValueStep(1)
    ySlider:SetObeyStepOnDrag(true)
    ySlider:SetWidth(200)
    
    local yBox = CreateFrame("EditBox", nil, posContainer, "InputBoxTemplate")
    yBox:SetSize(60, 20)
    yBox:SetPoint("LEFT", ySlider, "RIGHT", 10, 0)
    yBox:SetAutoFocus(false)
    yBox:SetNumeric(false)
    yBox:SetText(math.floor(db.posY))
    
    ySlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value)
        GoomiHealthStoneReminderDB.posY = value  -- Write directly to global
        yBox:SetText(value)
        UpdateIconAppearance()
        UpdateAnchorPosition()
    end)
    
    yBox:SetScript("OnEnterPressed", function(self)
        local value = tonumber(self:GetText()) or 0
        GoomiHealthStoneReminderDB.posY = Clamp(value, -1000, 1000)  -- Write directly to global
        ySlider:SetValue(GoomiHealthStoneReminderDB.posY)
        UpdateIconAppearance()
        UpdateAnchorPosition()
        self:ClearFocus()
    end)
    
    yBox:SetScript("OnEscapePressed", function(self)
        self:SetText(math.floor(GoomiHealthStoneReminderDB.posY))
        self:ClearFocus()
    end)
    
    -- Reset Button
    local resetBtn = CreateFrame("Button", nil, parentFrame, "UIPanelButtonTemplate")
    resetBtn:SetSize(120, 30)
    resetBtn:SetPoint("BOTTOMRIGHT", parentFrame:GetParent(), "BOTTOMRIGHT", -20, 20)
    resetBtn:SetText("Reset to Default")
    
    resetBtn:SetScript("OnClick", function()
        -- Reset to defaults
        for k, v in pairs(defaults) do
            GoomiHealthStoneReminderDB[k] = v
        end
        
        -- Update UI
        sizeBox:SetText(tostring(GoomiHealthStoneReminderDB.iconSize))
        opacitySlider:SetValue(GoomiHealthStoneReminderDB.opacity)
        opacityBox:SetText(string.format("%.0f", GoomiHealthStoneReminderDB.opacity * 100))
        UIDropDownMenu_SetText(glowDropdown, "Pixel Glow")
        thickSlider:SetValue(GoomiHealthStoneReminderDB.pixelThick)
        thickBox:SetText(tostring(GoomiHealthStoneReminderDB.pixelThick))
        thickContainer:Show()  -- Pixel glow is default
        colorSwatchTex:SetColorTexture(GoomiHealthStoneReminderDB.glowR, GoomiHealthStoneReminderDB.glowG, GoomiHealthStoneReminderDB.glowB, 1)
        xSlider:SetValue(GoomiHealthStoneReminderDB.posX)
        xBox:SetText(math.floor(GoomiHealthStoneReminderDB.posX))
        ySlider:SetValue(GoomiHealthStoneReminderDB.posY)
        yBox:SetText(math.floor(GoomiHealthStoneReminderDB.posY))
        
        UpdateIconAppearance()
        UpdateAnchorPosition()
        UpdateIcon()
        
        -- Update glow on visible frames
        if iconFrame and iconFrame:IsShown() then
            ApplyGlowStyle(iconFrame, true)
        end
        if anchorFrame and anchorFrame:IsShown() then
            ApplyGlowStyle(anchorFrame, true)
        end
    end)
end

-- Register module with GoomiUI
GoomiUI:RegisterModule("Healthstone Reminder", HealthstoneReminder)