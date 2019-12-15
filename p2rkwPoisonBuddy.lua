local addonName = "p2rkwPoisonBuddy"

local PSBD = CreateFrame("Frame")
PSBD:RegisterEvent("ADDON_LOADED")
PSBD:RegisterEvent("UNIT_INVENTORY_CHANGED")
PSBD:RegisterEvent("BAG_UPDATE")

PSBD.ConfigFrame = nil
PSBD.Parser = CreateFrame("GameTooltip", addonName.."ParserTooltip", nil, "GameTooltipTemplate")
PSBD.Tooltip = GameTooltip

--fubar/mapicon
local mapiconEnabled = true
if mapiconEnabled then
    PSBD.ACE = AceLibrary("AceAddon-2.0"):new("FuBarPlugin-2.0")
    PSBD.ACE.name = addonName
    PSBD.ACE.hasIcon = "Interface\\Icons\\Ability_Rogue_DualWeild"
    PSBD.ACE.defaultMinimapPosition = 200
    PSBD.ACE.cannotDetachTooltip = true
    function PSBD.ACE:OpenMenu() -- override open menu functionality from ace fubar
        PSBDToggleLock()
    end

    function PSBD.ACE:OnClick(button)
        if button == "LeftButton" then
            PoisonBuddyToggleVisibility()
        end
    end
end

-- local functions
PSBD.GetWeaponEnchantInfo = GetWeaponEnchantInfo
PSBD.GetInventorySlotInfo = GetInventorySlotInfo
PSBD.GetContainerItemLink = GetContainerItemLink
PSBD.GetContainerItemInfo = GetContainerItemInfo
PSBD.GetContainerNumSlots = GetContainerNumSlots

local floor = math.floor

local function modulo(a, b) return a - floor(a / b) * b end

local function roundToNearest(number, multiple) return floor(number / multiple) * multiple end

local function mergeTables(t1, t2)
    local function tableMergeHelper(t1, t2)
        for k, v in pairs(t2) do
            if type(v) == "table" then
                if type(t1[k] or false) == "table" then
                    tableMergeHelper(t1[k] or {}, t2[k] or {})
                else
                    t1[k] = v
                end
            else
                t1[k] = v
            end
        end
        return t1
    end

    local result = {}
    tableMergeHelper(result, t1 or {})
    tableMergeHelper(result, t2 or {})
    return result
end

local function serializeTable(val, name, skipnewlines, depth)
    skipnewlines = skipnewlines or false
    depth = depth or 0

    local tmp = string.rep(" ", depth)

    if name then tmp = tmp .. name .. " = " end

    if type(val) == "table" then
        tmp = tmp .. "{" .. (not skipnewlines and "\n" or "")

        for k, v in pairs(val) do
            tmp = tmp .. serializeTable(v, k, skipnewlines, depth + 1) .. "," .. (not skipnewlines and "\n" or "")
        end

        tmp = tmp .. string.rep(" ", depth) .. "}"
    elseif type(val) == "number" then
        tmp = tmp .. tostring(val)
    elseif type(val) == "string" then
        tmp = tmp .. string.format("%q", val)
    elseif type(val) == "boolean" then
        tmp = tmp .. (val and "true" or "false")
    else
        tmp = tmp .. "\"[inserializeable datatype:" .. type(val) .. "]\""
    end

    return tmp
end

local function debugMsg2(...)

    for i, v in ipairs(arg) do
        local s = serializeTable(v)
        for line in string.gmatch(s, "([^\n]*)\n?") do
            DEFAULT_CHAT_FRAME:AddMessage(line)
        end
    end
end

local function getNameFromLinkString(link)
    return gsub(link, "^.*%[(.*)%].*$", "%1")
end

local Iters = {}

function Iters.merchantLinks()
    local numItems = GetMerchantNumItems()
    local function myiter(numItems, itemidx)
        if itemidx >= numItems then
            return nil
        end
        itemidx = itemidx + 1
        link = GetMerchantItemLink(itemidx)
        return itemidx, link
    end

    return myiter, numItems, 0
end

-- iterator over every text line of parser tooltip
function Iters.leftTexts(parser)

    local initial = 1
    local numLines = parser:NumLines()
    local leftName = parser:GetName() .. "TextLeft"

    local function myiter(state, prev)
        local next = prev
        while next <= numLines do
            next = next + 1
            local textN = getglobal(leftName .. next):GetText()
            if textN then
                return next, textN
            end
        end
    end

    return myiter, self, initial
end

function Iters.bagSlotPairs()
    local initState = {
        bag = 0,
        slot = 0,
        numSlots = {
            [0] = PSBD.GetContainerNumSlots(0),
            [1] = PSBD.GetContainerNumSlots(1),
            [2] = PSBD.GetContainerNumSlots(2),
            [3] = PSBD.GetContainerNumSlots(3),
            [4] = PSBD.GetContainerNumSlots(4),
        }
    }
    local function myiter(state)
        if state.slot < state.numSlots[state.bag] then
            state.slot = state.slot + 1
            return state.bag, state.slot
        elseif state.bag < 4 then
            state.bag = state.bag + 1
            state.slot = 1
            return state.bag, state.slot
        end
    end

    return myiter, initState, 0
end

function PSBD:logDebug(msg)
    DEFAULT_CHAT_FRAME:AddMessage("[debug] "..addonName..": " .. msg)
end

function PSBD:getLocalMedia(file)
    return [[Interface\AddOns\]]..addonName..[[\Media\]] .. file
end

function PSBD:getDefaultConfig()
    return {
        posX = 200,
        posY = -200,
        scale = 1,
        button = {
            --texCoords = { .08, .92, .08, .92 },
            texCoords = { 0.0, 1.0, 0.0, 1.0 },
            spacing = { x = 2, y = 2 },
            font = {
                file = [[Fonts\Homespun.ttf]],
                size = 10,
                outline = "MONOCROMEOUTLINE"
            },
            size = 34,
        },
        isLocked = false,
    }
end

PsbdConfig = PSBD:getDefaultConfig()

-- pre-allocate work variables
PSBD.PoisonDB = {
    name = {
        [1] = "Instant Poison",
        [2] = "Deadly Poison",
        [3] = "Crippling Poison",
        [4] = "Mind-numbing Poison",
        [5] = "Wound Poison",
        [6] = "Flash Powder",
        [7] = "Blinding Powder",
    },
    id = {
        [1] = { 6947, 6949, 6950, 8926, 8927, 8928 },
        [2] = { 2892, 2893, 8984, 8985, 20844 },
        [3] = { 3775, 3776 },
        [4] = { 5237, 6951, 9186 },
        [5] = { 10918, 10920, 10921, 10922 },
        [6] = { 5140 },
        [7] = { 5530 },
    },
    icon = {
        [1] = "Interface\\Icons\\Ability_Poisons",
        [2] = "Interface\\Icons\\Ability_Rogue_DualWeild",
        [3] = "Interface\\Icons\\INV_Potion_19",
        [4] = "Interface\\Icons\\Spell_Nature_NullifyDisease",
        [5] = "Interface\\Icons\\Ability_PoisonSting",
        [6] = "Interface\\Icons\\Ability_Vanish",
        [7] = "Interface\\Icons\\Spell_Shadow_Mindsteal",
    },
    mats = {
        [1] = {
            [1] = { 1, "Dust of Decay", 1/5, "Empty Vial" },
            [2] = { 3, "Dust of Decay", 1/5, "Leaded Vial" },
            [3] = { 1, "Dust of Deterioration", 1/5, "Leaded Vial" },
            [4] = { 2, "Dust of Deterioration", 1/5, "Leaded Vial" },
            [5] = { 3, "Dust of Deterioration", 1/5, "Crystal Vial" },
            [6] = { 4, "Dust of Deterioration", 1/5, "Crystal Vial" }
        },
        [2] = {
            [1] = { 1, "Deathweed", 1/5, "Leaded Vial"},
            [2] = {	2, "Deathweed", 1/5, "Leaded Vial"},
            [3] = {	3, "Deathweed", 1/5, "Crystal Vial"},
            [4] = {	5, "Deathweed", 1/5, "Crystal Vial"},
            [5] = {	7, "Deathweed", 1/5, "Crystal Vial"},
        },
        [3] = {
            [1] = {1, "Essence of Pain", 1/5, "Empty Vial" },
            [2] = {3, "Essence of Agony", 1/5, "Crystal Vial"},
        },
        [4] = {
            [1] = {1, "Dust of Decay", 1, "Essence of Pain", 1/5, "Empty Vial"},
            [2] = {4, "Dust of Decay", 4, "Essence of Pain", 1/5, "Leaded Vial"},
            [3] = {2, "Dust of Deterioration", 2, "Essence of Agony", 1/5, "Crystal Vial"},
        },
        [5] = {
            [1] = {1, "Essence of Pain", 1, "Deathweed", 1/5, "Leaded Vial"},
            [2] = {1, "Essence of Pain", 2, "Deathweed", 1/5, "Leaded Vial"},
            [3] = {1, "Essence of Agony", 2, "Deathweed", 1/5, "Crystal Vial"},
            [4] = {2, "Essence of Agony", 2, "Deathweed", 1/5, "Crystal Vial"},
        },
        [6] = {
            [1] = {1, "Flash Powder"}
        },
        [7] = {
            [1] = {1/3, "Fadeleaf"}
        }
    },
    _rankStrings = { "", " II", " III", " IV", " V", " VI", },
}

function PSBD.PoisonDB:getHighestRank(poisonIndex)
    if not poisonIndex then
        return getn(self._rankStrings)
    end
    return getn(self.id[poisonIndex])
end

function PSBD.PoisonDB:getPoisonName(poisonIndex, rank)
    rank = rank or self:getHighestRank(poisonIndex)
    if self.id[poisonIndex][rank] then
        return self.name[poisonIndex] .. self._rankStrings[rank]
    end
end

function PSBD.PoisonDB:generateAllPoisons()
    local result = {}
    -- iterate from higher to lower rank of every poison
    for rank = getn(self._rankStrings), 1, -1 do
        for poisonIndex, v in pairs(self.name) do
            local pn = self:getPoisonName(poisonIndex, rank)
            if pn then
                table.insert(result, { poisonIndex, pn })
            end
        end
    end
    return result
end

local existingPoisons = PSBD.PoisonDB:generateAllPoisons()

PSBD._work = {
    Time = 0,
    iSCasting = nil,
    buttons = {
        ["MainHandSlot"] = {},
        ["SecondaryHandSlot"] = {},
    },
    active = {
        ["MainHandSlot"] = nil,
        ["SecondaryHandSlot"] = nil,
    },
}

function PSBD:OnEvent()
    if event == "BAG_UPDATE" then
        if arg1 == 0 or arg1 == 1 or arg1 == 2 or arg1 == 3 or arg1 == 4 then
            PSBD:updatePoisonCounters()
        end

    elseif event == "ADDON_LOADED" and arg1 == addonName then
        PsbdConfig = mergeTables(PSBD:getDefaultConfig(), PsbdConfig)

        PSBD.ConfigFrame = PSBD.configureUI()
        PSBDToggleLock(); PSBDToggleLock();

        -- workarround for the fact that temp. enchants are not loaded at the addon start
        function addonStart()
            PSBD._work.Time = PSBD._work.Time + arg1
            if PSBD._work.Time >= 2 then
                PSBD._work.Time = 0
                PSBD.ConfigFrame:SetScript("OnUpdate", nil)
                PSBD:highlightActivePoisonButton()
            end
        end

        PSBD.ConfigFrame:SetScript("OnUpdate", addonStart)

    elseif event == "SPELLCAST_START" then
        PSBD._work.iSCasting = 1

    elseif event == "SPELLCAST_STOP" or event == "SPELLCAST_INTERRUPTED" or event == "SPELLCAST_FAILED" then
        PSBD:UnregisterEvent("SPELLCAST_STOP")
        PSBD:UnregisterEvent("SPELLCAST_START")
        PSBD:UnregisterEvent("SPELLCAST_INTERRUPTED")
        PSBD:UnregisterEvent("SPELLCAST_FAILED")
        PSBD._work.iSCasting = nil
        PSBD:highlightActivePoisonButton()

    elseif event == "UNIT_INVENTORY_CHANGED" then
        PSBD:highlightActivePoisonButton()
    end
end

PSBD:SetScript("OnEvent", PSBD.OnEvent)

function PSBD.createPoisonButton(parent, poisonIndex, hand)
    local button = CreateFrame("Button", "p2rkwPoisonBuddy_Button_" .. hand .. poisonIndex, parent)
    local bsize = PsbdConfig.button.size

    button:SetWidth(bsize)
    button:SetHeight(bsize)

    local handInfo = {
        ["MainHandSlot"] =      {PoisonBuddyBuyMats, "Main Hand", "Buys reagents at vendor"},
        ["SecondaryHandSlot"] = {PoisonBuddyCraftPoison, "Off Hand", "Crafts a stack"},
        ["Vanish"] =            {PoisonBuddyBuyMats, "Main Hand", "Buys reagents at vendor"},
        ["Blind"] =             {PoisonBuddyCraftPoison, "Off Hand", "Crafts a stack"},
    }; handInfo = handInfo[hand]

    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnClick", function()
        if arg1 == "LeftButton" then
            PoisonBuddyApplyPoison(hand, poisonIndex)
        end
        if arg1 == "RightButton" then
            handInfo[1](poisonIndex, 20)
        end
    end)

    local bag, slot, pName, pLink = PSBD:getPoisonInvetoryInfo(poisonIndex)

    button:SetScript("OnEnter", function()
        button.Highlight:SetVertexColor(1, 1, 1, 0.5)

        local tt = PSBD.Tooltip
        tt:SetOwner(button, "ANCHOR_PRESERVE")
        tt:AddLine(pName, 1,1,1)
        --tt:AddDoubleLine("Left click:","apply to "..handInfo[2], 1,1,1,1,1,1)
        --tt:AddDoubleLine("Right click:", handInfo[3], 1,1,1,1,1,1)
        tt:AddLine("Left click: applies poison to "..handInfo[2], nil, nil, nil, true)
        tt:AddLine("Right click: "..handInfo[3], nil, nil, nil, true)

        tt:Show()
    end)

    button:SetScript("OnLeave", function()
        button.Highlight:SetVertexColor(1, 1, 1, 0)

        PSBD.Tooltip:Hide()
    end)

    --button:SetNormalTexture(PSBD.PoisonDB.icon[poisonIndex])
    local texture = button:CreateTexture(nil, "ARTWORK")
    texture:SetTexture(PSBD.PoisonDB.icon[poisonIndex])
    texture:SetTexCoord(unpack(PsbdConfig.button.texCoords))
    texture:SetAllPoints()
    button:SetNormalTexture(texture)

    button.NormalTexture = texture

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetPoint("CENTER", button, "CENTER", 0, 0)
    highlight:SetWidth(bsize)
    highlight:SetHeight(bsize)
    highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
    highlight:SetVertexColor(1, 1, 1, 0)
    highlight:SetBlendMode("ADD")

    button.Highlight = highlight

    local fntCfg = PsbdConfig.button.font
    local font = button:CreateFontString(nil, "OVERLAY")
    font:SetPoint("BOTTOMRIGHT", -3, 3)
    font:SetFont(PSBD:getLocalMedia(fntCfg.file), fntCfg.size, fntCfg.outline)
    font:SetTextColor(0.9, 0.9, 0.9)
    button.CounterFont = font

    local font = button:CreateFontString(nil, "OVERLAY")
    font:SetPoint("TOPLEFT", 3, -3)
    font:SetFont(PSBD:getLocalMedia(fntCfg.file), fntCfg.size, fntCfg.outline)
    font:SetTextColor(0.9, 0.9, 0.9)
    button.TimerFont = font

    return button
end

function PSBD:getButton(poisonIndex, hand) return self._work.buttons[hand][poisonIndex] end

function PSBD:setButton(poisonIndex, hand, button) self._work.buttons[hand][poisonIndex] = button end

function PSBD.getHandWeaponEnchantInfo(hand)
    local hasMainHandEnchant, mainHandExpiration, mainHandCharges,
    hasOffHandEnchant, offHandExpiration, offHandCharges = GetWeaponEnchantInfo()
    if hand == "MainHandSlot" then
        return hasMainHandEnchant, mainHandExpiration, mainHandCharges
    elseif hand == "SecondaryHandSlot" then
        return hasOffHandEnchant, offHandExpiration, offHandCharges
    end
end

function PSBD.configureUI()
    local cframe = CreateFrame("Frame", nil, UIParent) -- self.ConfigFrame
    local bsize = PsbdConfig.button.size
    local scale = PsbdConfig.scale
    local spacing = PsbdConfig.button.spacing

    --local fubarButtonFrame = PSBD.ACE:GetFrame()

    cframe:SetScale(scale)
    local backdrop = {
        bgFile = "Interface\\TutorialFrame\\TutorialFrameBackground", -- path to the background texture
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 3, right = 5, top = 3, bottom = 5 }
    }
    cframe.hiddenBackdrop = backdrop

    cframe:SetWidth(2 * (bsize + 8))
    cframe:SetHeight(30)
    cframe:SetPoint("TOPLEFT", PsbdConfig.posX, PsbdConfig.posY)
    --cframe:SetPoint("BOTTOM", fubarButtonFrame, 0, 0)

    for poisonIndex, name in pairs(PSBD.PoisonDB.name) do
        local mh = PSBD.createPoisonButton(cframe, poisonIndex, "MainHandSlot")
        local oh = PSBD.createPoisonButton(cframe, poisonIndex, "SecondaryHandSlot")

        PSBD:setButton(poisonIndex, "MainHandSlot", mh)
        PSBD:setButton(poisonIndex, "SecondaryHandSlot", oh)

        mh:SetPoint("TOPLEFT", 7, -20 + (poisonIndex - 1) * -(bsize + spacing.y))
        oh:SetPoint("TOPLEFT", 7 + bsize + spacing.x, -20 + (poisonIndex - 1) * -(bsize + spacing.y))
    end

    if not PsbdConfig.isVisible then
        cframe:Hide()
    end
    return cframe
end

function PSBD:findCurrentPoison(hand)
    local hasEnchant, expiration, charges = PSBD.getHandWeaponEnchantInfo(hand);

    if not hasEnchant then return end

    PSBD.Parser:ClearLines()
    PSBD.Parser:SetOwner(UIParent, "ANCHOR_NONE")
    PSBD.Parser:SetInventoryItem("player", PSBD.GetInventorySlotInfo(hand))

    for i, tooltipText in Iters.leftTexts(PSBD.Parser) do
        --debugMsg2(string.lower(tooltipText))
        for k, v in pairs(existingPoisons) do
            local poisonIndex, fullName = unpack(v)
            if string.find(string.lower(tooltipText), string.lower(fullName)) then
                --debugMsg2(string.lower(tooltipText))
                return {
                    poisonIndex = poisonIndex,
                    fullName = fullName,
                    expirationSeconds = expiration / 1000,
                    charges = charges
                }
            end
        end
    end
end

function PSBD:highlightActivePoisonButton(hand)
    if not hand then
        PSBD:highlightActivePoisonButton("MainHandSlot")
        PSBD:highlightActivePoisonButton("SecondaryHandSlot")
        return
    end

    local r = PSBD:findCurrentPoison(hand)

    for poisonIndex, button in pairs(PSBD._work.buttons[hand]) do
        if not r or poisonIndex ~= r.poisonIndex then
            button:SetAlpha(0.8)
        else
            button:SetAlpha(1.0)
            PSBD:getButton(poisonIndex, hand).TimerFont:SetText(floor(r.expirationSeconds / 60))
            PSBD._work.active[hand] = poisonIndex
        end
    end
end

local function searchAllBags(predicate, ...)
    for bag, slot in Iters.bagSlotPairs() do
        if PSBD.GetContainerItemInfo(bag, slot) then
            local foundSomething = {predicate(bag, slot, unpack(arg))}
            if getn(foundSomething) > 0 then
                return unpack(foundSomething)
            end
        end
    end
end

function PSBD.countItems(item)
    local sumCount = 0
    for bag, slot in Iters.bagSlotPairs() do
        local texture, itemCount, locked, quality, readable, lootable, link = PSBD.GetContainerItemInfo(bag, slot)
        -- debugMsg2(texture, itemCount, locked, quality, readable, lootable, link)
        if texture then
            local link = PSBD.GetContainerItemLink(bag,slot)
            if string.find(link, item, nil, true) then
                sumCount = sumCount + itemCount
            end
        end
    end
    return sumCount
end

function PSBD:updatePoisonCounters(poisonIndex)
    if not poisonIndex then
        for poisonIndex, v in pairs(PSBD.PoisonDB.name) do
            local count = PSBD:updatePoisonCounters(poisonIndex)
            PSBD:getButton(poisonIndex, "MainHandSlot").CounterFont:SetText(count)
            PSBD:getButton(poisonIndex, "SecondaryHandSlot").CounterFont:SetText(count)
            -- should both of buttons get the counter set?
        end
        return
    end

    local countPoison = 0
    local bag, slot, name, link = PSBD:getPoisonInvetoryInfo(poisonIndex)
    if name then
        return PSBD.countItems(name)
    end
end

-- Search for poison with highest rank available
function PSBD:getPoisonInvetoryInfo(poisonIndex)

    local function poisonPredicate(i, j, poisonName)
        local link = PSBD.GetContainerItemLink(i, j)
        local cleanLink = getNameFromLinkString(link)
        --PSBD:logDebug(GetContainerItemLink(i, j))
        if cleanLink == poisonName then
            return i, j, cleanLink, link
        end
        return nil
    end

    for rank = PSBD.PoisonDB:getHighestRank(poisonIndex), 1, -1 do
        local lookingPoison = PSBD.PoisonDB:getPoisonName(poisonIndex, rank)
        --debugMsg2(lookingPoison)
        local bag, slot, name, link = searchAllBags(poisonPredicate, lookingPoison)
        if bag then
            return bag, slot, name, link
        end
    end
end

function PoisonBuddyApplyPoison(hand, poisonIndex)
    poisonIndex = poisonIndex or PSBD._work.active[hand]
    if not poisonIndex then
        return
    end

    PSBD:highlightActivePoisonButton()
    if not hand or PSBD._work.iSCasting then
        return
    end

    local bag, slot = PSBD:getPoisonInvetoryInfo(poisonIndex)
    if bag then
        PSBD:RegisterEvent("SPELLCAST_START")
        PSBD:RegisterEvent("SPELLCAST_STOP")
        PSBD:RegisterEvent("SPELLCAST_INTERRUPTED")
        PSBD:RegisterEvent("SPELLCAST_FAILED")

        UseContainerItem(bag, slot)
        PickupInventoryItem(GetInventorySlotInfo(hand))

        ReplaceEnchant()
        ClearCursor()
    else
        DEFAULT_CHAT_FRAME:AddMessage("PoisonBuddy: " .. "|cFFCC9900" .. PSBD.PoisonDB.name[poisonIndex] .. "|r" .. "|cFFFFFFFF" .. " not found." .. "|r", 0.4, 0.8, 0.4)
    end
end

function PoisonBuddyReapplyPoisons()
    PoisonBuddyApplyPoison("MainHandSlot")
    PoisonBuddyApplyPoison("SecondaryHandSlot")
end


function PSBDToggleLock()
    local cframe = PSBD.ConfigFrame

    if not PsbdConfig.isLocked then
        PsbdConfig.isLocked = true

        cframe:SetBackdropColor(0, 0, 0, 0.0)
        cframe:SetBackdrop(nil)

        cframe:SetMovable(0)
        cframe:EnableMouse(0)

        cframe:SetScript("OnDragStart", nil)
        cframe:SetScript("OnDragStop", nil)
    else
        PsbdConfig.isLocked = false

        cframe:SetBackdrop(cframe.hiddenBackdrop)
        cframe:SetBackdropColor(0, 0, 0, 0.8)

        cframe:SetMovable(1)
        cframe:EnableMouse(1)

        cframe:RegisterForDrag("LeftButton")

        function cframe:OnDragStartImpl()
            cframe:SetBackdropColor(0, 0, 0, 0.4)
            cframe:StartMoving()
        end

        function cframe:OnDragStopImpl()
            cframe:StopMovingOrSizing()
            cframe:SetBackdropColor(0, 0, 0, 0.8)

            local a1, a2, a3, x, y = cframe:GetPoint()
            PsbdConfig.posX = roundToNearest(x, 4)
            PsbdConfig.posY = roundToNearest(y, 4)
            --cframe:SetPoint(a1,a2,a3, PsbdConfig.posX, PsbdConfig.posY)
            cframe:SetPoint("TOPLEFT", PsbdConfig.posX, PsbdConfig.posY)
        end

        cframe:SetScript("OnDragStart", cframe.OnDragStartImpl)
        cframe:SetScript("OnDragStop", cframe.OnDragStopImpl)
    end
end

function PoisonBuddyToggleVisibility()
    local cframe = PSBD.ConfigFrame

    if cframe:IsVisible() then
        cframe:Hide()
        PsbdConfig.isVisible = false
    else
        PSBD:highlightActivePoisonButton()
        cframe:Show()
        PsbdConfig.isVisible = true
    end
end

function PoisonBuddyCfg(key, value)
    if not key then return end

    if not value then
        debugMsg2(PsbdConfig[key])
        return PsbdConfig[key]
    else
        PsbdConfig[key] = value
        debugMsg2(PsbdConfig[key])
    end
end

function PoisonBuddyBuyMats(poisonIndex, count)
    count = count or 20
    local matArr = PSBD.PoisonDB.mats[poisonIndex]
    local rank = getn(matArr)

    local howManyNeeded
    for k, mat in ipairs(matArr[rank]) do
        if tonumber(mat) then
            howManyNeeded = tonumber(mat)
        else
            local needed = (howManyNeeded*count) --  substract carried items? (-PSBD.countItems(mat))
            if needed > 0 then
                for i, link in Iters.merchantLinks() do
                    if string.find(link, mat) then
                        BuyMerchantItem(i, needed)
                    end
                end
            end
        end
    end
end

function PoisonBuddyCraftPoison(poisonIndex, count)
    if CraftItem then
        CraftItem('Poisons', PSBD.PoisonDB:getPoisonName(poisonIndex), count)
    end
end

function PoisonBuddyMsg(...)
    debugMsg2(unpack(arg))
end

function PoisonBuddyPromt(command)
    RunScript("PoisonBuddy" .. command);
end

SlashCmdList['POISONBUDDY'] = PoisonBuddyPromt
SLASH_POISONBUDDY1 = '/poisonbuddy'
SLASH_POISONBUDDY2 = '/psbd'

-- binding list
BINDING_HEADER_HEAD = "p2rkwPoisonBuddy"
