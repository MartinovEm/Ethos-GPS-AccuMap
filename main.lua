local VERSION = "2.0.4"
local bitmapsPath = "/bitmaps/GPS"
local metadataDir = "/documents/user"

-- Localize non-lcd globals at load time
local floor = math.floor
local mlog = math.log
local mtan = math.tan
local msin = math.sin
local mcos = math.cos
local msqrt = math.sqrt
local masin = math.asin
local mabs = math.abs
local sformat = string.format
local matan2 = math.atan2 or math.atan
local mdeg = math.deg
local pi = math.pi
local DEG_TO_RAD = pi / 180
local EARTH_R = 6371000

-- LCD locals (initialized on first paint, lcd not available at load time)
local lcdReady = false
local lcdGetWindowSize
local lcdDrawBitmap
local lcdDrawText
local lcdDrawFilledCircle
local lcdDrawFilledRectangle
local lcdDrawRectangle
local lcdDrawLine
local lcdColor
local lcdFont
local lcdInvalidate
local colorOrange
local colorWhite
local colorRed
local colorBlack
local lcdIsVisible

-- Bitmap state
local loadedBitmap = nil
local rotateIcon = nil
local loadedFile = ""
local pendingGCBeforeLoad = false
local bmpW = 0
local bmpH = 0
local homeIcon = nil
local arrowIcon = nil
local arrowRedIcon = nil

-- Scaled overlay text (recomputed each paint from widget size)
local overlayFont = nil
local overlayBotY = 0

-- Cached layout values (recomputed only on bitmap or size change)
local cachedW = 0
local cachedH = 0
local offX = 0
local offY = 0

-- Cached GPS scaling (recomputed only on metadata load)
local topMercY = 0
local mercYRange = 0
local lonRange = 0
local leftLon = 0

-- Pre-allocated GPS lookup tables (avoids per-frame allocation)
local gpsLatQuery = {name="GPS", options=nil}
local gpsLonQuery = {name="GPS", options=nil}
local gpsQueriesReady = false
local prevGpsSensorName = ""

-- Cached GPS source objects (Ethos guide: cache, re-resolve only when nil or sensor changes)
local gpsSrcLat = nil
local gpsSrcLon = nil

-- Pre-allocated sensor resolve tables (avoids per-frame table creation)
local gpsSensorQuery = {name=""}
local altSensorQuery = {name=""}

-- Cached dot position (recomputed only when lat/lon change)
local dotX = nil
local dotY = nil
local prevLat = nil
local prevLon = nil

-- GPS staleness detection via source:age() (ms since last telemetry update)
local gpsStale = false

-- GPS glitch filter: last accepted fix, plus a candidate position after an implausible jump
local fixLat = nil
local fixLon = nil
local fixClock = 0
local jumpLat = nil
local jumpLon = nil
local jumpClock = 0
local jumpSince = 0
local GPS_MAX_SPEED_MS = 150
local GPS_JUMP_SLACK_M = 50
local GPS_JUMP_CONFIRM_SEC = 3

-- Home position (set once GPS stabilizes)
local homeLat = nil
local homeLon = nil
local homeAlt = nil
local homeX = nil
local homeY = nil
local homeStableLat = nil
local homeStableLon = nil
local homeStableFrames = 0
local HOME_STABLE_FRAMES = 100
local HOME_STABLE_DEG = 0.001



-- Cached ground distance from home (meters)
local prevGroundDist = nil
local lastGroundDistText = nil
local lastGroundDist2DText = nil
local lastGroundDistShort = nil
local lastGroundDist2DShort = nil
local DIST_JITTER_M = 5

-- Altitude display cache
local altValue = nil
local prevAltValue = nil
local altText = nil
local altTextShort = nil

-- Overlay text color (resolved in paint from widget.overlayTextColor index)
local overlayColor = nil

-- Flight statistics tracking (runtime only, reset with Reset Home)
local stats = {
    altMin = nil, altMax = nil, altSum = 0, altCount = 0,
    spdMin = nil, spdMax = nil, spdSum = 0, spdCount = 0,
    distMax = 0,
    user = {{}, {}, {}},
    flightTime = 0,
    flightLastTick = nil,
}
local flightInProgress = false
local flightSpdThreshold = 10
local flightAltThreshold = 5
local cachedAltUnit = "m"
local cachedSpdUnit = "km/h"
local cachedUserUnit = {"", "", ""}
local flightThresholdsSet = false

-- Speed display cache
local speedValue = nil
local prevSpeedValue = nil
local speedTextVal = nil
local speedTextShort = nil
local speedSensorQuery = {name=""}

-- User sensor display cache (3 slots)
local userSensorQuery = {{name=""}, {name=""}, {name=""}}
local userText = {nil, nil, nil}
local userTextShort = {nil, nil, nil}
local userLabel = {nil, nil, nil}
local userVal = {nil, nil, nil}
local prevUserValue = {nil, nil, nil}

-- Heading tracking (bearing from consecutive positions)
local lastHeading = 0
local prevHeadingLat = nil
local prevHeadingLon = nil

-- Cached rotated arrow icons (recomputed only when heading or map angle changes)
local cachedArrowBmp = nil
local cachedArrowRedBmp = nil
local cachedArrowHeading = -999
local cachedArrowMapAngle = -999

-- Last known coordinates text (shown when signal lost)
local lastCoordsText = nil

-- Cached stale timeout in ms (recomputed only when signalTimeout changes)
local staleMs = 2000
local prevSignalTimeout = 2

-- Rotation slider state
local sliderVisible = false
local sliderShowTime = 0
local SLIDER_HIDE_SEC = 3
local rotPendingOpen = false
local rotConsumeNextEnd = false

-- Map rotation cache
local rotatedBitmap = nil
local rotatedAngle = -1
local rotDrawX = 0
local rotDrawY = 0
local rotDrawW = 0
local rotDrawH = 0

-- Rotation coordinate transform state
local rotActive = false
local rotCosA = 1
local rotSinA = 0
local rotScale = 1
local bmpCX = 0
local bmpCY = 0
local scrCX = 0
local scrCY = 0

local function haversine(lat1, lon1, lat2, lon2)
    local dLat = (lat2 - lat1) * DEG_TO_RAD
    local dLon = (lon2 - lon1) * DEG_TO_RAD
    local r1 = lat1 * DEG_TO_RAD
    local r2 = lat2 * DEG_TO_RAD
    local sdLat = msin(dLat * 0.5)
    local sdLon = msin(dLon * 0.5)
    local a = sdLat * sdLat + mcos(r1) * mcos(r2) * sdLon * sdLon
    return EARTH_R * 2 * masin(msqrt(a))
end

-- Rejects impossible GPS readings: 0 or out of range, or a jump faster than GPS_MAX_SPEED_MS.
-- A real jump is accepted once the new position has stayed consistent for GPS_JUMP_CONFIRM_SEC.
local function acceptFix(la, lo, now)
    if la == 0 or lo == 0 or mabs(la) > 90 or mabs(lo) > 180 then return false end
    if fixLat and haversine(fixLat, fixLon, la, lo) > GPS_MAX_SPEED_MS * (now - fixClock) + GPS_JUMP_SLACK_M then
        if not jumpLat or haversine(jumpLat, jumpLon, la, lo) > GPS_MAX_SPEED_MS * (now - jumpClock) + GPS_JUMP_SLACK_M then
            jumpSince = now
        end
        jumpLat, jumpLon, jumpClock = la, lo, now
        if now - jumpSince < GPS_JUMP_CONFIRM_SEC then return false end
    end
    fixLat, fixLon, fixClock = la, lo, now
    jumpLat = nil
    return true
end

local function mercatorY(lat)
    local latRad = lat * DEG_TO_RAD
    return mlog(mtan(pi / 4 + latRad * 0.5))
end

local function mapToScreen(x, y)
    if not rotActive then return x, y end
    local dx = x - bmpCX
    local dy = y - bmpCY
    return floor(scrCX + (dx * rotCosA - dy * rotSinA) * rotScale + 0.5),
           floor(scrCY + (dx * rotSinA + dy * rotCosA) * rotScale + 0.5)
end

local function extractNum(content, key)
    if not content or not key then return 0 end
    local val = content:match('"' .. key .. '"%s*:%s*([%-]?%d+%.?%d*)')
    return tonumber(val) or 0
end

local function loadMetadata(bmpFile)
    if not bmpFile or bmpFile == "" then return end
    local baseName = bmpFile:match("([^/]+)$")
    if baseName then
        baseName = baseName:match("^(.+)%.[^.]+$") or baseName
    end
    if not baseName or baseName == "" then return end
    local f = io.open(metadataDir .. "/" .. baseName .. ".json", "r")
    if f then
        local content = f:read(4096)
        f:close()
        if content then
            local tLat = extractNum(content, "topLat")
            local bLat = extractNum(content, "bottomLat")
            leftLon = extractNum(content, "leftLon")
            local rLon = extractNum(content, "rightLon")
            topMercY = mercatorY(tLat)
            mercYRange = topMercY - mercatorY(bLat)
            lonRange = rLon - leftLon
        end
    end
end

local function updateOffsets(w, h)
    cachedW = w
    cachedH = h
    offX = floor((w - bmpW) / 2)
    offY = floor((h - bmpH) / 2)
end

local function drawIndicator(w, h, isRed, indicatorType)
    if not dotX then return end
    local dx, dy = mapToScreen(dotX, dotY)
    if dx < 6 then dx = 6 elseif dx > w - 6 then dx = w - 6 end
    if dy < 6 then dy = 6 elseif dy > h - 6 then dy = h - 6 end
    local icon = isRed and arrowRedIcon or arrowIcon
    if indicatorType == 1 and icon and icon.rotate then
        -- Compensate heading for map rotation; cache rotated arrow
        local mapAng = rotActive and rotatedAngle or 0
        local visualHeading = lastHeading - mapAng
        if visualHeading ~= cachedArrowHeading or mapAng ~= cachedArrowMapAngle then
            cachedArrowBmp = arrowIcon and arrowIcon.rotate and arrowIcon:rotate(visualHeading) or nil
            cachedArrowRedBmp = arrowRedIcon and arrowRedIcon.rotate and arrowRedIcon:rotate(visualHeading) or nil
            cachedArrowHeading = visualHeading
            cachedArrowMapAngle = mapAng
        end
        local rotated = isRed and cachedArrowRedBmp or cachedArrowBmp
        if rotated then
            local rw, rh = 0, 0
            if rotated.width then rw = rotated:width() end
            if rotated.height then rh = rotated:height() end
            lcdDrawBitmap(dx - floor(rw / 2), dy - floor(rh / 2), rotated)
        else
            lcdColor(isRed and colorRed or colorOrange)
            lcdDrawFilledCircle(dx, dy, 6)
        end
    else
        lcdColor(isRed and colorRed or colorOrange)
        lcdDrawFilledCircle(dx, dy, 6)
    end
end

local function drawShadowText(x, y, text, align, color)
    lcdColor(colorBlack)
    lcdDrawText(x - 1, y - 1, text, align)
    lcdDrawText(x + 1, y - 1, text, align)
    lcdDrawText(x - 1, y + 1, text, align)
    lcdDrawText(x + 1, y + 1, text, align)
    lcdColor(color or colorWhite)
    lcdDrawText(x, y, text, align)
end

local function drawLastDotRed(w, h, indicatorType, staleColor)
    drawIndicator(w, h, true, indicatorType)
    lcdFont(overlayFont)
    if lastGroundDist2DText then
        local txt = w < 400 and lastGroundDist2DShort or lastGroundDist2DText
        drawShadowText(4, overlayBotY, txt, nil, staleColor)
    end
    if lastCoordsText then
        drawShadowText(w - 4, overlayBotY, lastCoordsText, RIGHT, staleColor)
    end
end

local function drawRotationUI(widget, w, h)
    -- Draw rotation icon (top-left) when rotation is enabled
    if widget.czRotEnabled then
        local iconSz = floor(w * 0.05)
        if iconSz < 16 then iconSz = 16 end
        local iconY = w < 400 and 30 or 4
        if rotateIcon then
            lcdDrawBitmap(4, iconY, rotateIcon, iconSz, iconSz)
        else
            lcdFont(FONT_BOLD)
            lcdColor(colorBlack)
            lcdDrawText(5, iconY + 1, "R")
            lcdColor(colorWhite)
            lcdDrawText(4, iconY, "R")
        end
    end

    -- Draw rotation angle grid (bottom area) when visible
    if sliderVisible and widget.czRotEnabled and lcdDrawFilledRectangle then
        -- 10 angles that fill the viewport at 1:1 (90°/270° excluded — bitmap narrower than display)
        local angles = {0, 30, 60, 120, 150, 180, 210, 240, 300, 330}
        local cols = 5
        local gapX = 2
        local gapY = 2
        local cellW = floor(w / 7)
        local cellH = floor(h / 14)
        if cellH < 20 then cellH = 20 end
        local gridW = cols * cellW + (cols - 1) * gapX
        local gridH = 2 * cellH + gapY
        local gridX = floor((w - gridW) / 2)
        local gridY = h - gridH - 6

        -- Background panel
        lcdColor(lcd.RGB(0, 0, 0, 0.65))
        lcdDrawFilledRectangle(gridX - 4, gridY - 4, gridW + 8, gridH + 8)

        local currentAngle = widget.czRotAngle or 0
        local textOff = h > 300 and 8 or 6
        lcdFont(h > 300 and FONT_S or FONT_XS)

        for i = 1, 10 do
            local angle = angles[i]
            local idx = i - 1
            local col = idx % cols
            local row = floor(idx / cols)
            local cx = gridX + col * (cellW + gapX)
            local cy = gridY + row * (cellH + gapY)

            if angle == currentAngle then
                -- Selected cell: white background, black text
                lcdColor(lcd.RGB(255, 255, 255, 0.85))
                lcdDrawFilledRectangle(cx, cy, cellW, cellH)
                lcdColor(colorBlack)
                lcdDrawText(cx + floor(cellW / 2), cy + floor(cellH / 2) - textOff, sformat("%d\xC2\xB0", angle), CENTERED)
            else
                -- Normal cell: dark background, white border and text
                lcdColor(lcd.RGB(80, 80, 80, 0.5))
                lcdDrawFilledRectangle(cx, cy, cellW, cellH)
                lcdColor(lcd.RGB(200, 200, 200, 0.6))
                lcdDrawRectangle(cx, cy, cellW, cellH)
                drawShadowText(cx + floor(cellW / 2), cy + floor(cellH / 2) - textOff, sformat("%d\xC2\xB0", angle), CENTERED)
            end
        end
    end
end

local function create()
    return {bitmapFile = "", gpsSensor = nil, gpsSensorName = "", altSensorName = "", altSrc = nil, speedSensorName = "", speedSrc = nil, userSensorName = {"", "", ""}, userSrc = {nil, nil, nil}, indicatorType = 0, signalTimeout = 2, staleTextColor = 0, overlayTextColor = 0, distEnabled = false, czRotEnabled = false, czRotAngle = 0}
end

local buildMainForm, buildDiagForm, buildStatsForm

buildDiagForm = function(widget)
    form.clear()

    -- GPS Source check
    local gpsStatus = "Not configured"
    local sensorName = widget.gpsSensorName or ""
    if sensorName ~= "" then
        local testQuery = {name = sensorName}
        if OPTION_LATITUDE then testQuery.options = OPTION_LATITUDE end
        local src = system.getSource(testQuery)
        if src then
            local lat = src:value()
            if lat then
                gpsStatus = "OK (" .. sensorName .. ")"
            else
                gpsStatus = "Found, no fix (" .. sensorName .. ")"
            end
        else
            gpsStatus = "NOT FOUND (" .. sensorName .. ")"
        end
    end
    local lineGps = form.addLine("GPS Source")
    form.addStaticText(lineGps, nil, gpsStatus)

    -- GPS Coordinates
    local coordsStatus = "—"
    if sensorName ~= "" and OPTION_LATITUDE and OPTION_LONGITUDE then
        local sLat = system.getSource({name = sensorName, options = OPTION_LATITUDE})
        local sLon = system.getSource({name = sensorName, options = OPTION_LONGITUDE})
        if sLat and sLon then
            local lat = sLat:value()
            local lon = sLon:value()
            if lat and lon then
                coordsStatus = sformat("%.5f, %.5f", lat, lon)
            end
        end
    end
    local lineCoords = form.addLine("GPS Lat, Lon")
    form.addStaticText(lineCoords, nil, coordsStatus)

    -- JSON metadata check
    local jsonStatus = "No map selected"
    local bmpFile = widget.bitmapFile or ""
    if bmpFile ~= "" then
        local baseName = bmpFile:match("([^/]+)$")
        if baseName then
            baseName = baseName:match("^(.+)%.[^.]+$") or baseName
        end
        if baseName and baseName ~= "" then
            local jsonPath = metadataDir .. "/" .. baseName .. ".json"
            local f = io.open(jsonPath, "r")
            if f then
                f:close()
                jsonStatus = "OK (" .. baseName .. ".json)"
            else
                jsonStatus = "NOT FOUND (" .. baseName .. ".json)"
            end
        end
    end
    local lineJson = form.addLine("JSON Metadata")
    form.addStaticText(lineJson, nil, jsonStatus)

    -- Map bitmap check
    local mapStatus = "No map selected"
    if bmpFile ~= "" then
        if loadedBitmap then
            mapStatus = "OK (" .. bmpFile .. ")"
        else
            mapStatus = "Selected: " .. bmpFile
        end
    end
    local lineMap = form.addLine("Map Bitmap")
    form.addStaticText(lineMap, nil, mapStatus)

    -- Back button
    form.addLine("")
    local lineBack = form.addLine("")
    form.addTextButton(lineBack, nil, "Back", function()
        buildMainForm(widget)
    end)
end

buildStatsForm = function(widget)
    form.clear()

    if not widget.distEnabled then
        local lineOff = form.addLine("")
        form.addStaticText(lineOff, nil, "Turn ON Sensors & Overlay first")
    else
        -- Flight duration
        local lineDur = form.addLine("Flight Duration")
        if widget.speedSensorName == "" or widget.altSensorName == "" then
            form.addStaticText(lineDur, nil, "Set Speed + Altitude sensors")
        else
            local t = floor(stats.flightTime)
            local mm = floor(t / 60)
            local ss = t % 60
            local durText = sformat("%02d:%02d", mm, ss)
            if mm >= 60 then
                local hh = floor(mm / 60)
                mm = mm % 60
                durText = sformat("%d:%02d:%02d", hh, mm, ss)
            end
            form.addStaticText(lineDur, nil, durText)
        end

        -- Hint when no flight recorded yet
        if stats.flightTime == 0 then
            local lineHint = form.addLine("")
            form.addStaticText(lineHint, nil, "Fly to record statistics")
        end

        -- Max distance
        form.addLine("")
        local lineDMax = form.addLine("Max Distance")
        if stats.distMax > 0 then
            local dText
            if stats.distMax >= 1000 then
                dText = sformat("%.1f km", stats.distMax / 1000)
            else
                dText = sformat("%.0f m", stats.distMax)
            end
            form.addStaticText(lineDMax, nil, dText)
        else
            form.addStaticText(lineDMax, nil, "")
        end

        -- Helper: format min / avg / max as one string
        local function fmtMinAvgMax(vMin, vMax, vSum, vCount, decimals)
            local avg = vSum / vCount
            if decimals and decimals > 0 then
                local f = "%." .. decimals .. "f / %." .. decimals .. "f / %." .. decimals .. "f"
                return sformat(f, vMin, avg, vMax)
            else
                return sformat("%d / %d / %d", floor(vMin + 0.5), floor(avg + 0.5), floor(vMax + 0.5))
            end
        end

        -- Column header (always if any sensor configured)
        local anySensor = widget.altSensorName ~= "" or widget.speedSensorName ~= ""
        for ui = 1, 3 do
            if widget.userSensorName[ui] and widget.userSensorName[ui] ~= "" then anySensor = true end
        end
        if anySensor then
            local lineHdr = form.addLine("")
            form.addStaticText(lineHdr, nil, "Min / Avg / Max")
        end

        -- Altitude
        if widget.altSensorName ~= "" then
            local label = sformat("Altitude (%s)", cachedAltUnit)
            local lineA = form.addLine(label)
            if stats.altCount > 0 then
                form.addStaticText(lineA, nil, fmtMinAvgMax(stats.altMin, stats.altMax, stats.altSum, stats.altCount, 0))
            else
                form.addStaticText(lineA, nil, "")
            end
        end

        -- Speed
        if widget.speedSensorName ~= "" then
            local label = sformat("Speed (%s)", cachedSpdUnit)
            local lineS = form.addLine(label)
            if stats.spdCount > 0 then
                form.addStaticText(lineS, nil, fmtMinAvgMax(stats.spdMin, stats.spdMax, stats.spdSum, stats.spdCount, 0))
            else
                form.addStaticText(lineS, nil, "")
            end
        end

        -- User sensors
        for ui = 1, 3 do
            local uName = widget.userSensorName[ui] or ""
            if uName ~= "" then
                local unitStr = cachedUserUnit[ui] or ""
                local label = uName
                if unitStr ~= "" then
                    label = sformat("%s (%s)", uName, unitStr:match("^%s*(.+)") or unitStr)
                end
                local lineU = form.addLine(label)
                local u = stats.user[ui]
                if u and u.count and u.count > 0 then
                    form.addStaticText(lineU, nil, fmtMinAvgMax(u.min, u.max, u.sum, u.count, 1))
                else
                    form.addStaticText(lineU, nil, "")
                end
            end
        end
    end

    -- Back button
    form.addLine("")
    local lineBack = form.addLine("")
    form.addTextButton(lineBack, nil, "Back", function()
        buildMainForm(widget)
    end)
end

buildMainForm = function(widget)
    form.clear()

    local line1 = form.addLine("Map")
    form.addBitmapField(line1, nil, bitmapsPath,
        function() return widget.bitmapFile end,
        function(value)
            widget.bitmapFile = value
            if loadedBitmap then
                loadedBitmap = nil
                pendingGCBeforeLoad = true
            end
            loadedFile = ""
        end)

    local line2 = form.addLine("GPS Source")
    form.addSensorField(line2, nil,
        function() return widget.gpsSensor end,
        function(value)
            widget.gpsSensor = value
            if value then
                local ok, name = pcall(function() return value:name() end)
                if ok and name and name ~= "" and name ~= "---" then
                    widget.gpsSensorName = name
                else
                    widget.gpsSensorName = ""
                end
            else
                widget.gpsSensorName = ""
            end
        end)

    local line2a = form.addLine("Heading Indicator")
    form.addChoiceField(line2a, nil, {{"Dot", 0}, {"Arrow", 1}},
        function() return widget.indicatorType end,
        function(value) widget.indicatorType = value end)

    local line2b = form.addLine("Signal Timeout (s)")
    form.addNumberField(line2b, nil, 2, 30,
        function() return widget.signalTimeout end,
        function(value) widget.signalTimeout = value end)

    local line2c = form.addLine("Signal Lost Text")
    form.addChoiceField(line2c, nil, {{"White", 0}, {"Red", 1}},
        function() return widget.staleTextColor end,
        function(value) widget.staleTextColor = value end)

    local line2d = form.addLine("Map Overlay Text")
    form.addChoiceField(line2d, nil, {{"White", 0}, {"Red", 1}, {"Green", 2}, {"Blue", 3}, {"Yellow", 4}, {"Orange", 5}, {"Cyan", 6}},
        function() return widget.overlayTextColor end,
        function(value) widget.overlayTextColor = value end)

    local altSrcField, speedSrcField, userSrcFields

    local lineDA = form.addLine("Sensors & Overlay")
    form.addBooleanField(lineDA, nil,
        function() return widget.distEnabled end,
        function(value)
            widget.distEnabled = value
            altSrcField:enable(value)
            speedSrcField:enable(value)
            for ui = 1, 3 do
                if userSrcFields and userSrcFields[ui] then userSrcFields[ui]:enable(value) end
            end
        end)

    local lineAlt = form.addLine("  Altitude Source")
    altSrcField = form.addSensorField(lineAlt, nil,
        function()
            if not widget.altSrc and widget.altSensorName ~= "" then
                widget.altSrc = system.getSource({name = widget.altSensorName})
            end
            return widget.altSrc
        end,
        function(value)
            if value then
                widget.altSrc = value
                local ok, name = pcall(function() return value:name() end)
                if ok and name and name ~= "" and name ~= "---" then
                    widget.altSensorName = name
                else
                    widget.altSensorName = ""
                    widget.altSrc = nil
                end
            else
                widget.altSensorName = ""
                widget.altSrc = nil
            end
        end)
    altSrcField:enable(widget.distEnabled)

    local lineSpd = form.addLine("  Speed Source")
    speedSrcField = form.addSensorField(lineSpd, nil,
        function()
            if not widget.speedSrc and widget.speedSensorName ~= "" then
                widget.speedSrc = system.getSource({name = widget.speedSensorName})
            end
            return widget.speedSrc
        end,
        function(value)
            if value then
                widget.speedSrc = value
                local ok, name = pcall(function() return value:name() end)
                if ok and name and name ~= "" and name ~= "---" then
                    widget.speedSensorName = name
                else
                    widget.speedSensorName = ""
                    widget.speedSrc = nil
                end
            else
                widget.speedSensorName = ""
                widget.speedSrc = nil
            end
        end)
    speedSrcField:enable(widget.distEnabled)

    userSrcFields = {}
    for idx = 1, 3 do
        local lineU = form.addLine("  User Sensor " .. idx)
        local usf = form.addSensorField(lineU, nil,
            function()
                if not widget.userSrc[idx] and widget.userSensorName[idx] ~= "" then
                    widget.userSrc[idx] = system.getSource({name = widget.userSensorName[idx]})
                end
                return widget.userSrc[idx]
            end,
            function(value)
                if value then
                    widget.userSrc[idx] = value
                    local ok, name = pcall(function() return value:name() end)
                    if ok and name and name ~= "" and name ~= "---" then
                        widget.userSensorName[idx] = name
                    else
                        widget.userSensorName[idx] = ""
                        widget.userSrc[idx] = nil
                    end
                else
                    widget.userSensorName[idx] = ""
                    widget.userSrc[idx] = nil
                    userText[idx] = nil
                    userLabel[idx] = nil
                    userVal[idx] = nil
                    prevUserValue[idx] = nil
                end
            end)
        usf:enable(widget.distEnabled)
        userSrcFields[idx] = usf
    end

    local czRotAngleField

    local lineRot = form.addLine("Map Rotation")
    form.addBooleanField(lineRot, nil,
        function() return widget.czRotEnabled end,
        function(value)
            widget.czRotEnabled = value
            czRotAngleField:enable(value)
            if not value then
                sliderVisible = false
            end
        end)

    local lineRotA = form.addLine("  Rotation Angle (\xC2\xB0)")
    czRotAngleField = form.addNumberField(lineRotA, nil, 0, 359,
        function() return widget.czRotAngle end,
        function(value)
            -- Skip 90 and 270 (bitmap narrower than viewport at those angles)
            -- Detect scroll direction from current stored value
            if value == 90 then
                value = (widget.czRotAngle == 91) and 89 or 91
            elseif value == 270 then
                value = (widget.czRotAngle == 271) and 269 or 271
            end
            widget.czRotAngle = value
        end)
    czRotAngleField:enable(widget.czRotEnabled)

    local lineStats = form.addLine("Flight Statistics")
    form.addTextButton(lineStats, nil, "View", function()
        buildStatsForm(widget)
    end)

    local line4 = form.addLine("Reset Home")
    form.addTextButton(line4, nil, "Reset",
        function()
            homeLat = nil
            homeLon = nil
            homeAlt = nil
            homeX = nil
            homeY = nil
            homeStableLat = nil
            homeStableLon = nil
            homeStableFrames = 0
            prevGroundDist = nil
            lastGroundDistText = nil
            lastGroundDist2DText = nil
            lastGroundDistShort = nil
            lastGroundDist2DShort = nil
            altValue = nil
            prevAltValue = nil
            altText = nil
            altTextShort = nil
            speedValue = nil
            prevSpeedValue = nil
            speedTextVal = nil
            speedTextShort = nil
            for ui = 1, 3 do
                userText[ui] = nil
                userTextShort[ui] = nil
                userLabel[ui] = nil
                userVal[ui] = nil
                prevUserValue[ui] = nil
            end
            stats.altMin = nil
            stats.altMax = nil
            stats.altSum = 0
            stats.altCount = 0
            stats.spdMin = nil
            stats.spdMax = nil
            stats.spdSum = 0
            stats.spdCount = 0
            stats.distMax = 0
            for ui = 1, 3 do stats.user[ui] = {} end
            stats.flightTime = 0
            stats.flightLastTick = nil
            flightInProgress = false
        end)

    local lineDiag = form.addLine("Diagnostics")
    form.addTextButton(lineDiag, nil, "Run", function()
        buildDiagForm(widget)
    end)

    local line5 = form.addLine("Version")
    form.addStaticText(line5, nil, VERSION)
end

local function configure(widget)
    buildMainForm(widget)
end

local function paint(widget)
    -- Initialize lcd locals on first paint (lcd not available at load time)
    if not lcdReady then
        lcdGetWindowSize = lcd.getWindowSize
        lcdDrawBitmap = lcd.drawBitmap
        lcdDrawText = lcd.drawText
        lcdDrawFilledCircle = lcd.drawFilledCircle
        lcdColor = lcd.color
        lcdFont = lcd.font
        lcdInvalidate = lcd.invalidate
        colorOrange = lcd.RGB(255, 165, 0)
        colorWhite = lcd.RGB(255, 255, 255)
        colorRed = lcd.RGB(255, 0, 0)
        colorBlack = lcd.RGB(0, 0, 0)
        lcdIsVisible = lcd.isVisible
        if lcd.drawFilledRectangle then lcdDrawFilledRectangle = lcd.drawFilledRectangle end
        if lcd.drawRectangle then lcdDrawRectangle = lcd.drawRectangle end
        if lcd.drawLine then lcdDrawLine = lcd.drawLine end
        lcdReady = true
    end

    if not homeIcon then
        local ok, img = pcall(lcd.loadBitmap, "icons/home.png")
        if ok and img then homeIcon = img end
    end
    if not arrowIcon then
        local ok, img = pcall(lcd.loadBitmap, "icons/arrow.png")
        if ok and img then arrowIcon = img end
    end
    if not arrowRedIcon then
        local ok, img = pcall(lcd.loadBitmap, "icons/arrow_red.png")
        if ok and img then arrowRedIcon = img end
    end
    if not rotateIcon then
        local ok, img = pcall(lcd.loadBitmap, "icons/rotate.png")
        if ok and img then rotateIcon = img end
    end

    local w, h = lcdGetWindowSize()

    -- Scale overlay font and bottom text offset to widget size
    local minDim = h < w and h or w
    if minDim >= 300 then
        overlayFont = FONT_L
        overlayBotY = h - 28
    elseif minDim >= 150 then
        overlayFont = FONT_M
        overlayBotY = h - 22
    else
        overlayFont = FONT_S
        overlayBotY = h - 16
    end

    local bmpFile = widget.bitmapFile or ""

    -- Load bitmap only when selection changes
    if bmpFile ~= "" and (bmpFile ~= loadedFile or not loadedBitmap) then
        if loadedBitmap then
            loadedBitmap = nil
            pendingGCBeforeLoad = true
        end
        -- Flush dead bitmap userdata before allocating new one
        if pendingGCBeforeLoad then
            collectgarbage()
            collectgarbage()
            pendingGCBeforeLoad = false
        end
        local ok, result = pcall(lcd.loadBitmap, bitmapsPath .. "/" .. bmpFile)
        if ok and result then
            loadedBitmap = result
            local ok2, bw, bh = pcall(result.width, result)
            if ok2 and bw then
                local ok3, bh2 = pcall(result.height, result)
                bmpW = bw
                bmpH = (ok3 and bh2) or h
            else
                bmpW = w
                bmpH = h
            end
        else
            loadedBitmap = nil
        end
        loadedFile = bmpFile
        loadMetadata(bmpFile)
        updateOffsets(w, h)
        dotX = nil
        homeX = nil
    elseif bmpFile == "" and loadedBitmap then
        loadedBitmap = nil
        loadedFile = ""
        dotX = nil
        homeX = nil
    elseif w ~= cachedW or h ~= cachedH then
        updateOffsets(w, h)
        dotX = nil
        homeX = nil
    end

    if loadedBitmap or rotatedBitmap then
        local mapAngle = widget.czRotAngle or 0
        if mapAngle > 0 and (loadedBitmap and loadedBitmap.rotate or rotatedBitmap) then
            -- Rotate to exact angle (slider gives 30° coarse steps, settings allow fine-tuning)
            if mapAngle ~= rotatedAngle or not rotatedBitmap then
                -- Free rotated bitmap FIRST to make room for original reload
                if rotatedBitmap then rotatedBitmap = nil end
                collectgarbage()
                collectgarbage()
                -- Reload original if nil'd
                if not loadedBitmap then
                    local bmpFile = widget.bitmapFile or ""
                    if bmpFile ~= "" then
                        local ok2, result = pcall(lcd.loadBitmap, bitmapsPath .. "/" .. bmpFile)
                        if ok2 and result then loadedBitmap = result end
                    end
                end
                if loadedBitmap and loadedBitmap.rotate then
                    local ok, rb = pcall(loadedBitmap.rotate, loadedBitmap, mapAngle)
                    -- Release original immediately — only rotated bitmap stays in RAM
                    loadedBitmap = nil
                    collectgarbage()
                    collectgarbage()
                    if ok and rb then
                        local wOk, rbW = pcall(rb.width, rb)
                        local hOk, rbH = pcall(rb.height, rb)
                        if wOk and hOk and rbW and rbH and rbW > 0 and rbH > 0 then
                            rotatedBitmap = rb
                            rotatedAngle = mapAngle
                            -- Zoom-to-fill: scale so rotated map covers viewport (no black corners)
                            local eff = mapAngle % 180
                            if eff > 90 then eff = 180 - eff end
                            local rad = eff * DEG_TO_RAD
                            local cosA = mcos(rad)
                            local sinA = msin(rad)
                            local s1 = (w * cosA + h * sinA) / bmpW
                            local s2 = (w * sinA + h * cosA) / bmpH
                            local scale = (s1 > s2) and s1 or s2
                            if scale < 1 then scale = 1 end
                            rotDrawW = floor(rbW * scale + 0.5)
                            rotDrawH = floor(rbH * scale + 0.5)
                            rotDrawX = floor((w - rotDrawW) / 2)
                            rotDrawY = floor((h - rotDrawH) / 2)
                            -- Set coordinate transform for overlays
                            rotActive = true
                            local rotRad = mapAngle * DEG_TO_RAD
                            rotCosA = mcos(rotRad)
                            rotSinA = msin(rotRad)
                            rotScale = scale
                            bmpCX = offX + bmpW / 2
                            bmpCY = offY + bmpH / 2
                            scrCX = w / 2
                            scrCY = h / 2
                        else
                            rotatedBitmap = nil
                            rotatedAngle = -1
                        end
                    else
                        rotatedBitmap = nil
                        rotatedAngle = -1
                    end
                end
            end
            if rotatedBitmap then
                -- Scaled draw (safe: 90°/270° excluded from grid)
                local drawOk = pcall(lcdDrawBitmap, rotDrawX, rotDrawY, rotatedBitmap, rotDrawW, rotDrawH)
                if not drawOk then
                    lcdDrawBitmap(floor((w - rotatedBitmap:width()) / 2), floor((h - rotatedBitmap:height()) / 2), rotatedBitmap)
                end
            end
        else
            -- No rotation: release rotated bitmap, reload original if needed
            rotActive = false
            if rotatedBitmap then
                rotatedBitmap = nil
                rotatedAngle = -1
                collectgarbage()
                collectgarbage()
                collectgarbage()
            end
            if not loadedBitmap then
                local bmpFile = widget.bitmapFile or ""
                if bmpFile ~= "" then
                    local ok2, result = pcall(lcd.loadBitmap, bitmapsPath .. "/" .. bmpFile)
                    if ok2 and result then loadedBitmap = result end
                end
            end
            if loadedBitmap then
                lcdDrawBitmap(offX, offY, loadedBitmap)
            end
        end
    else
        lcdColor(colorWhite)
        lcdDrawText(floor(w / 2) - 55, floor(h / 2) - 8, "No map selected")
        return
    end

    -- Set OPTION constants once (may not be available at load time)
    if not gpsQueriesReady then
        if not OPTION_LATITUDE then return end
        gpsLatQuery.options = OPTION_LATITUDE
        gpsLonQuery.options = OPTION_LONGITUDE
        gpsQueriesReady = true
    end

    -- Update GPS query name when sensor name changes
    local wName = widget.gpsSensorName or ""
    if wName ~= "" and wName ~= prevGpsSensorName then
        gpsLatQuery.name = wName
        gpsLonQuery.name = wName
        prevGpsSensorName = wName
        -- Sensor changed: drop cached handles so they re-resolve for the new sensor
        gpsSrcLat = nil
        gpsSrcLon = nil
    end

    -- Reuse cached GPS sources; resolve only when missing (Ethos guide: cache, re-resolve when nil)
    if not gpsSrcLat then gpsSrcLat = system.getSource(gpsLatQuery) end
    if not gpsSrcLon then gpsSrcLon = system.getSource(gpsLonQuery) end
    local srcLat = gpsSrcLat
    local srcLon = gpsSrcLon

    -- Localize hot widget fields (avoid repeated SDRAM hash lookups)
    local indType = widget.indicatorType or 0

    local staleColor = widget.staleTextColor == 1 and colorRed or nil

    -- Resolve overlay text color (0=White default)
    local otc = widget.overlayTextColor or 0
    if otc == 1 then overlayColor = colorRed
    elseif otc == 2 then overlayColor = lcd.RGB(0, 255, 0)
    elseif otc == 3 then overlayColor = lcd.RGB(80, 140, 255)
    elseif otc == 4 then overlayColor = lcd.RGB(255, 255, 0)
    elseif otc == 5 then overlayColor = colorOrange
    elseif otc == 6 then overlayColor = lcd.RGB(0, 255, 255)
    else overlayColor = nil
    end

    if not srcLat or not srcLon then
        drawLastDotRed(w, h, indType, staleColor)
        drawRotationUI(widget, w, h)
        return
    end

    -- Last fix accepted by the glitch filter in wakeup
    local lat = fixLat
    local lon = fixLon
    if not lat or not lon then
        drawLastDotRed(w, h, indType, staleColor)
        drawRotationUI(widget, w, h)
        return
    end
    if mercYRange == 0 or lonRange == 0 then
        drawRotationUI(widget, w, h)
        return
    end

    -- Recompute dot only when position changes
    if lat ~= prevLat or lon ~= prevLon or dotX == nil then
        prevLat = lat
        prevLon = lon
        dotX = floor(((lon - leftLon) / lonRange) * bmpW + 0.5) + offX
        dotY = floor(((topMercY - mercatorY(lat)) / mercYRange) * bmpH + 0.5) + offY
        lastCoordsText = sformat("%.5f, %.5f", lat, lon)
    end

    -- Set home after GPS position stabilizes
    if homeLat and not homeX then
        homeX = floor(((homeLon - leftLon) / lonRange) * bmpW + 0.5) + offX
        homeY = floor(((topMercY - mercatorY(homeLat)) / mercYRange) * bmpH + 0.5) + offY
    end

    -- Draw home marker
    local sHomeX, sHomeY
    if homeX then sHomeX, sHomeY = mapToScreen(homeX, homeY) end
    if sHomeX then
        if homeIcon then
            lcdDrawBitmap(sHomeX - 8, sHomeY - 10, homeIcon)
        else
            lcdFont(FONT_BOLD)
            lcdColor(colorWhite)
            lcdDrawText(sHomeX - 8, sHomeY - 12, "H")
        end
    end

    drawIndicator(w, h, gpsStale, indType)

    -- Bottom text: stale vs normal display
    local narrow = w < 400
    if gpsStale then
        lcdFont(overlayFont)
        if lastGroundDist2DText then
            drawShadowText(4, overlayBotY, narrow and lastGroundDist2DShort or lastGroundDist2DText, nil, staleColor)
        end
        if lastCoordsText then
            drawShadowText(w - 4, overlayBotY, lastCoordsText, RIGHT, staleColor)
        end
    elseif widget.distEnabled and homeLat then
        lcdFont(overlayFont)
        if lastGroundDistText then
            drawShadowText(4, overlayBotY, narrow and lastGroundDistShort or lastGroundDistText, nil, overlayColor)
        end
        if speedTextVal then
            if narrow then
                local cx = floor(w / 2)
                drawShadowText(cx, overlayBotY, speedTextShort, CENTERED, overlayColor)
            else
                local cx = floor(w / 2)
                drawShadowText(cx, overlayBotY, "Spd:", RIGHT, overlayColor)
                drawShadowText(cx + 2, overlayBotY, speedTextVal, nil, overlayColor)
            end
        end
        if altText then
            drawShadowText(w - 4, overlayBotY, narrow and altTextShort or altText, RIGHT, overlayColor)
        end
    end

    -- User sensors along top edge
    do
        local uCount = 0
        local uFull = {}
        local uShort = {}
        local uLabels = {}
        local uVals = {}
        for ui = 1, 3 do
            if userText[ui] then
                uCount = uCount + 1
                uFull[uCount] = userText[ui]
                uShort[uCount] = userTextShort[ui]
                uLabels[uCount] = userLabel[ui]
                uVals[uCount] = userVal[ui]
            end
        end
        if uCount > 0 then
            lcdFont(overlayFont)
            -- Reserve margins when rotation icon / compass are active
            local hasCompass = rotActive and (widget.czRotAngle or 0) > 0 and w >= 400
            local hasRotIcon = widget.czRotEnabled and w >= 400
            local iconSzM = floor(w * 0.05)
            if iconSzM < 16 then iconSzM = 16 end
            local leftMargin = hasRotIcon and (4 + iconSzM + 10) or 4
            local rightMargin = hasCompass and 50 or 4
            if uCount == 1 then
                drawShadowText(leftMargin, 2, narrow and uShort[1] or uFull[1], nil, overlayColor)
            elseif uCount == 2 then
                drawShadowText(leftMargin, 2, narrow and uShort[1] or uFull[1], nil, overlayColor)
                drawShadowText(w - rightMargin, 2, narrow and uShort[2] or uFull[2], RIGHT, overlayColor)
            else
                drawShadowText(leftMargin, 2, narrow and uShort[1] or uFull[1], nil, overlayColor)
                if narrow then
                    local cx = floor(w / 2)
                    drawShadowText(cx, 2, uShort[2], CENTERED, overlayColor)
                else
                    local cx = floor(w / 2)
                    drawShadowText(cx, 2, uLabels[2], RIGHT, overlayColor)
                    drawShadowText(cx + 2, 2, uVals[2], nil, overlayColor)
                end
                drawShadowText(w - rightMargin, 2, narrow and uShort[3] or uFull[3], RIGHT, overlayColor)
            end
        end
    end

    -- Compass indicator (top-right) when map is rotated
    if rotActive and (widget.czRotAngle or 0) > 0 then
        local cx = w - 24
        -- On narrow screens, drop compass below sensor text row
        local cy = 24
        if w < 400 then cy = 50 end
        local r = 12
        local hw = 4
        local northRad = widget.czRotAngle * DEG_TO_RAD
        local sinA = msin(northRad)
        local cosA = mcos(northRad)
        -- North direction in screen coords (y-down); matches the map rotation transform
        local nX, nY = sinA, -cosA
        -- Perpendicular (east on the rotated map)
        local pX, pY = cosA, sinA
        -- Diamond vertices
        local ntX = cx + floor(r * nX + 0.5)
        local ntY = cy + floor(r * nY + 0.5)
        local stX = cx - floor(r * nX + 0.5)
        local stY = cy - floor(r * nY + 0.5)
        local rpX = cx + floor(hw * pX + 0.5)
        local rpY = cy + floor(hw * pY + 0.5)
        local lpX = cx - floor(hw * pX + 0.5)
        local lpY = cy - floor(hw * pY + 0.5)
        -- Background circle
        lcdColor(lcd.RGB(0, 0, 0, 0.5))
        lcdDrawFilledCircle(cx, cy, r + 3)
        if lcdDrawLine then
            -- Fill north needle (red)
            lcdColor(colorRed)
            for t = 0, r do
                local f = t / r
                local x1 = ntX + f * (lpX - ntX)
                local y1 = ntY + f * (lpY - ntY)
                local x2 = ntX + f * (rpX - ntX)
                local y2 = ntY + f * (rpY - ntY)
                lcdDrawLine(floor(x1 + 0.5), floor(y1 + 0.5), floor(x2 + 0.5), floor(y2 + 0.5))
            end
            -- Fill south needle (white)
            lcdColor(colorWhite)
            for t = 0, r do
                local f = t / r
                local x1 = stX + f * (lpX - stX)
                local y1 = stY + f * (lpY - stY)
                local x2 = stX + f * (rpX - stX)
                local y2 = stY + f * (rpY - stY)
                lcdDrawLine(floor(x1 + 0.5), floor(y1 + 0.5), floor(x2 + 0.5), floor(y2 + 0.5))
            end
        else
            -- Fallback: just draw colored dots at tips
            lcdColor(colorRed)
            lcdDrawFilledCircle(ntX, ntY, 3)
            lcdColor(colorWhite)
            lcdDrawFilledCircle(stX, stY, 3)
        end
        -- Center pivot dot
        lcdColor(colorBlack)
        lcdDrawFilledCircle(cx, cy, 2)
        -- "N" label near north tip (clamped to screen)
        lcdFont(FONT_S)
        local nlX = cx + floor((r + 10) * nX + 0.5)
        local nlY = cy + floor((r + 10) * nY + 0.5) - 6
        if nlX < 10 then nlX = 10 end
        if nlX > w - 10 then nlX = w - 10 end
        if nlY < 0 then nlY = 0 end
        if nlY > h - 14 then nlY = h - 14 end
        drawShadowText(nlX, nlY, "N", CENTERED)
    end

    drawRotationUI(widget, w, h)
end

local function event(widget, category, value, x, y)
    if not widget.czRotEnabled then return end
    if not EVT_TOUCH or category ~= EVT_TOUCH then return end

    local w, h = lcdGetWindowSize()

    local iconSz = floor(w * 0.05)
    if iconSz < 16 then iconSz = 16 end
    local iconY = w < 400 and 30 or 4
    local hitSz = iconSz + 8
    local hitTop = iconY - 4
    local hitBot = iconY + iconSz + 4

    -- Grid layout (must match paint)
    local angles = {0, 30, 60, 120, 150, 180, 210, 240, 300, 330}
    local cols = 5
    local gapX = 2
    local gapY = 2
    local cellW = floor(w / 7)
    local cellH = floor(h / 14)
    if cellH < 20 then cellH = 20 end
    local gridW = cols * cellW + (cols - 1) * gapX
    local gridH = 2 * cellH + gapY
    local gridX = floor((w - gridW) / 2)
    local gridY = h - gridH - 6

    -- TOUCH_FIRST (16640): finger just touched screen
    if value == 16640 then
        if sliderVisible then
            -- Finger down on grid area
            if x >= gridX - 4 and x <= gridX + gridW + 4 and y >= gridY - 4 then
                rotPendingOpen = false
                return false
            end
            -- Finger down on icon: pending close
            if x <= hitSz and y >= hitTop and y <= hitBot then
                rotPendingOpen = false
                return false
            end
            -- Finger down elsewhere: close grid
            sliderVisible = false
            rotConsumeNextEnd = true
            if lcdIsVisible() then lcdInvalidate() end
            if system and system.killEvents then system.killEvents(value) end
            return true
        end
        -- Grid not visible: finger on icon → pending open
        if x and y and x <= hitSz and y >= hitTop and y <= hitBot then
            rotPendingOpen = true
            return false
        end
        return
    end

    -- TOUCH_SLIDE (16642): finger moving — open grid if pending
    if value == 16642 then
        if rotPendingOpen then
            rotPendingOpen = false
            sliderVisible = true
            sliderShowTime = os.clock()
            if lcdIsVisible() then lcdInvalidate() end
            if system and system.killEvents then system.killEvents(value) end
            return true
        end
        return
    end

    -- TOUCH_END (16641): finger lifted
    if value == 16641 then
        if rotConsumeNextEnd then
            rotConsumeNextEnd = false
            return true
        end
        if rotPendingOpen then
            -- Was pending from icon tap, no slide happened → toggle grid
            rotPendingOpen = false
            sliderVisible = not sliderVisible
            sliderShowTime = os.clock()
            if lcdIsVisible() then lcdInvalidate() end
            return true
        end
        if sliderVisible then
            -- Finger lifted on icon → close grid
            if x <= hitSz and y >= hitTop and y <= hitBot then
                sliderVisible = false
                if lcdIsVisible() then lcdInvalidate() end
                return true
            end
            -- Finger lifted on grid cell → set angle
            if x >= gridX and x < gridX + gridW and y >= gridY and y < gridY + gridH then
                local col = floor((x - gridX) / (cellW + gapX))
                local row = floor((y - gridY) / (cellH + gapY))
                if col >= 0 and col < cols and row >= 0 and row < 2 then
                    local idx = row * cols + col + 1
                    if idx >= 1 and idx <= 10 then
                        widget.czRotAngle = angles[idx]
                    end
                end
            end
            sliderShowTime = os.clock()
            if lcdIsVisible() then lcdInvalidate() end
            return true
        end
        return
    end

    return
end

local function wakeup(widget)
    -- Set OPTION constants if needed
    if not gpsQueriesReady then
        if OPTION_LATITUDE then
            gpsLatQuery.options = OPTION_LATITUDE
            gpsLonQuery.options = OPTION_LONGITUDE
            gpsQueriesReady = true
        else
            return
        end
    end

    -- Update GPS query name when sensor name changes
    local wName = widget.gpsSensorName or ""
    if wName ~= "" and wName ~= prevGpsSensorName then
        gpsLatQuery.name = wName
        gpsLonQuery.name = wName
        prevGpsSensorName = wName
        -- Sensor changed: drop cached handles so they re-resolve for the new sensor
        gpsSrcLat = nil
        gpsSrcLon = nil
    end

    -- Cache stale timeout only when setting changes
    local wTimeout = widget.signalTimeout or 2
    if wTimeout ~= prevSignalTimeout then
        prevSignalTimeout = wTimeout
        staleMs = wTimeout * 1000
    end

    -- Auto-hide rotation slider after 3 seconds
    if sliderVisible then
        if os.clock() - sliderShowTime > SLIDER_HIDE_SEC then
            sliderVisible = false
            if (lcdIsVisible or lcd.isVisible)() then
                (lcdInvalidate or lcd.invalidate)()
            end
        end
    end

    local wGpsSensorName = widget.gpsSensorName
    local wAltSensorName = widget.altSensorName

    -- Detect telemetry loss via source:age() (ms since last update)
    if not gpsSrcLat then gpsSrcLat = system.getSource(gpsLatQuery) end
    local srcLat = gpsSrcLat
    local wasStale = gpsStale
    local needsInvalidate = false
    if srcLat then
        local age = srcLat:age()
        gpsStale = age and age > staleMs
    end
    if gpsStale ~= wasStale then
        needsInvalidate = true
    end

    -- Resolve lon source once for shared use below (reuse cached handle)
    if not gpsSrcLon then gpsSrcLon = system.getSource(gpsLonQuery) end
    local srcLon = (not gpsStale and srcLat) and gpsSrcLon or nil
    local la, lo
    if srcLat and srcLon then
        la = srcLat:value()
        lo = srcLon:value()
        if la and lo and not acceptFix(la, lo, os.clock()) then
            la, lo = nil, nil
        end
    end

    -- Update heading from consecutive positions
    if la and lo and prevHeadingLat and prevHeadingLon then
        local dlat = la - prevHeadingLat
        local dlon = lo - prevHeadingLon
        if mabs(dlat) > 0.00001 or mabs(dlon) > 0.00001 then
            local y = msin(dlon * DEG_TO_RAD) * mcos(la * DEG_TO_RAD)
            local x = mcos(prevHeadingLat * DEG_TO_RAD) * msin(la * DEG_TO_RAD)
                    - msin(prevHeadingLat * DEG_TO_RAD) * mcos(la * DEG_TO_RAD) * mcos(dlon * DEG_TO_RAD)
            lastHeading = (mdeg(matan2(y, x)) + 360) % 360
            prevHeadingLat = la
            prevHeadingLon = lo
            needsInvalidate = true
        end
    elseif la and lo then
        prevHeadingLat = la
        prevHeadingLon = lo
    end

    -- Home stabilization: count frames where position stays within tolerance
    if not homeLat and not gpsStale and la and lo and la ~= 0 and lo ~= 0 then
        if not homeStableLat then
            homeStableLat = la
            homeStableLon = lo
            homeStableFrames = 1
        elseif mabs(la - homeStableLat) > HOME_STABLE_DEG
            or mabs(lo - homeStableLon) > HOME_STABLE_DEG then
            homeStableLat = la
            homeStableLon = lo
            homeStableFrames = 1
        else
            homeStableFrames = homeStableFrames + 1
            if homeStableFrames >= HOME_STABLE_FRAMES then
                homeLat = la
                homeLon = lo
                needsInvalidate = true
            end
        end
    end

    -- Lazy-resolve sensor objects by name if not yet available (reuse pre-allocated tables)
    if not widget.gpsSensor and wGpsSensorName ~= "" then
        gpsSensorQuery.name = wGpsSensorName
        widget.gpsSensor = system.getSource(gpsSensorQuery)
    end
    if not widget.altSrc and wAltSensorName ~= "" then
        altSensorQuery.name = wAltSensorName
        widget.altSrc = system.getSource(altSensorQuery)
    end

    -- Read altitude from sensor (only when Distance and Altitude is ON)
    if widget.distEnabled and widget.altSrc and not gpsStale then
        local rawAlt = widget.altSrc:value()
        if rawAlt and type(rawAlt) == "number" then
            local newAlt = floor(rawAlt + 0.5)
            if newAlt ~= prevAltValue then
                prevAltValue = newAlt
                altValue = newAlt
                local altUnit = "m"
                local uOk, uStr = pcall(function() return widget.altSrc:stringUnit() end)
                if uOk and uStr and uStr ~= "" then altUnit = uStr end
                cachedAltUnit = altUnit
                altText = sformat("Alt: %d %s", newAlt, altUnit)
                altTextShort = sformat("%d %s", newAlt, altUnit)
                needsInvalidate = true
            end
            -- Accumulate altitude stats (only while airborne)
            if altValue and flightInProgress then
                if not stats.altMin or altValue < stats.altMin then stats.altMin = altValue end
                if not stats.altMax or altValue > stats.altMax then stats.altMax = altValue end
                stats.altSum = stats.altSum + altValue
                stats.altCount = stats.altCount + 1
            end
        elseif altValue ~= nil then
            altValue = nil
            prevAltValue = nil
            altText = nil
            altTextShort = nil
            needsInvalidate = true
        end
    elseif altValue ~= nil and (not widget.distEnabled or not widget.altSrc or gpsStale) then
        altValue = nil
        prevAltValue = nil
        altText = nil
        altTextShort = nil
        needsInvalidate = true
    end

    -- Altitude at home: 3D distance and flight detection use height above home, so a sensor
    -- that reports altitude above sea level (e.g. ELRS GPS altitude) does not inflate them
    if homeLat and not homeAlt and altValue then homeAlt = altValue end

    -- Lazy-resolve speed sensor
    if not widget.speedSrc and (widget.speedSensorName or "") ~= "" then
        speedSensorQuery.name = widget.speedSensorName
        widget.speedSrc = system.getSource(speedSensorQuery)
    end

    -- Read speed from sensor (only when Distance and Altitude is ON)
    if widget.distEnabled and widget.speedSrc and not gpsStale then
        local rawSpd = widget.speedSrc:value()
        if rawSpd and type(rawSpd) == "number" then
            local newSpd = floor(rawSpd + 0.5)
            if newSpd ~= prevSpeedValue then
                prevSpeedValue = newSpd
                speedValue = newSpd
                local spdUnit = "km/h"
                local uOk, uStr = pcall(function() return widget.speedSrc:stringUnit() end)
                if uOk and uStr and uStr ~= "" then spdUnit = uStr end
                cachedSpdUnit = spdUnit
                speedTextVal = sformat(" %d %s", newSpd, spdUnit)
                speedTextShort = sformat("%d %s", newSpd, spdUnit)
                needsInvalidate = true
            end
            -- Accumulate speed stats (only while airborne)
            if speedValue and flightInProgress then
                if not stats.spdMin or speedValue < stats.spdMin then stats.spdMin = speedValue end
                if not stats.spdMax or speedValue > stats.spdMax then stats.spdMax = speedValue end
                stats.spdSum = stats.spdSum + speedValue
                stats.spdCount = stats.spdCount + 1
            end
        elseif speedValue ~= nil then
            speedValue = nil
            prevSpeedValue = nil
            speedTextVal = nil
            speedTextShort = nil
            needsInvalidate = true
        end
    elseif speedValue ~= nil and (not widget.distEnabled or not widget.speedSrc or gpsStale) then
        speedValue = nil
        prevSpeedValue = nil
        speedTextVal = nil
        speedTextShort = nil
        needsInvalidate = true
    end

    -- Read user sensors (only when Distance and Altitude is ON and not stale)
    for ui = 1, 3 do
        local uName = widget.userSensorName[ui] or ""
        if widget.distEnabled and uName ~= "" and not gpsStale then
            if not widget.userSrc[ui] then
                userSensorQuery[ui].name = uName
                widget.userSrc[ui] = system.getSource(userSensorQuery[ui])
            end
            if widget.userSrc[ui] then
                local rawVal = widget.userSrc[ui]:value()
                if rawVal and type(rawVal) == "number" then
                    local newVal = floor(rawVal * 10 + 0.5) / 10
                    if newVal ~= prevUserValue[ui] then
                        prevUserValue[ui] = newVal
                        local uUnit = ""
                        local uOk, uStr = pcall(function() return widget.userSrc[ui]:stringUnit() end)
                        if uOk and uStr and uStr ~= "" then uUnit = " " .. uStr end
                        if newVal == floor(newVal) then
                            userText[ui] = sformat("%s: %d%s", uName, newVal, uUnit)
                            userTextShort[ui] = sformat("%d%s", newVal, uUnit)
                            userLabel[ui] = uName .. ":"
                            userVal[ui] = sformat(" %d%s", newVal, uUnit)
                        else
                            userText[ui] = sformat("%s: %.1f%s", uName, newVal, uUnit)
                            userTextShort[ui] = sformat("%.1f%s", newVal, uUnit)
                            userLabel[ui] = uName .. ":"
                            userVal[ui] = sformat(" %.1f%s", newVal, uUnit)
                        end
                        -- Cache user unit
                        cachedUserUnit[ui] = uUnit
                        needsInvalidate = true
                    end
                    -- Accumulate user sensor stats (only while airborne)
                    if flightInProgress then
                        local u = stats.user[ui]
                        if not u.min or newVal < u.min then u.min = newVal end
                        if not u.max or newVal > u.max then u.max = newVal end
                        u.sum = (u.sum or 0) + newVal
                        u.count = (u.count or 0) + 1
                    end
                elseif userText[ui] then
                    userText[ui] = nil
                    userTextShort[ui] = nil
                    userLabel[ui] = nil
                    userVal[ui] = nil
                    prevUserValue[ui] = nil
                    needsInvalidate = true
                end
            end
        elseif userText[ui] then
            userText[ui] = nil
            userTextShort[ui] = nil
            userLabel[ui] = nil
            userVal[ui] = nil
            prevUserValue[ui] = nil
            needsInvalidate = true
        end
    end

    -- Calculate distance: 3D (sqrt(ground² + height above home²)) when altitude available, else 2D ground
    -- Always cache 2D text separately for signal-lost display
    local distLa = la or fixLat
    local distLo = lo or fixLon
    if homeLat and distLa and distLo then
        local gd = haversine(homeLat, homeLon, distLa, distLo)
        if gd < DIST_JITTER_M then gd = 0 end
        local dist = gd
        local hAbove = (altValue and homeAlt) and (altValue - homeAlt) or 0
        if cachedAltUnit == "ft" then hAbove = hAbove * 0.3048 end
        if hAbove ~= 0 then
            dist = msqrt(gd * gd + hAbove * hAbove)
        end
        if dist < DIST_JITTER_M then dist = 0 end
        -- Track max distance for stats (only while airborne)
        if flightInProgress and dist > stats.distMax then stats.distMax = dist end
        if dist ~= prevGroundDist then
            prevGroundDist = dist
            if dist >= 1000 then
                lastGroundDistText = sformat("Distance: %.1f km", dist / 1000)
                lastGroundDistShort = sformat("%.1f km", dist / 1000)
            else
                lastGroundDistText = sformat("Distance: %.0f m", dist)
                lastGroundDistShort = sformat("%.0f m", dist)
            end
            -- Cache 2D ground distance text for signal-lost display
            if gd ~= dist then
                if gd >= 1000 then
                    lastGroundDist2DText = sformat("Distance: %.1f km", gd / 1000)
                    lastGroundDist2DShort = sformat("%.1f km", gd / 1000)
                else
                    lastGroundDist2DText = sformat("Distance: %.0f m", gd)
                    lastGroundDist2DShort = sformat("%.0f m", gd)
                end
            else
                lastGroundDist2DText = lastGroundDistText
                lastGroundDist2DShort = lastGroundDistShort
            end
            needsInvalidate = true
        end
    end

    -- Detect imperial units once and set flight thresholds accordingly
    if not flightThresholdsSet then
        if widget.speedSrc then
            local uOk, uStr = pcall(function() return widget.speedSrc:stringUnit() end)
            if uOk and uStr then
                if uStr == "mph" or uStr == "kts" or uStr == "kt" then
                    flightSpdThreshold = 6
                end
                flightThresholdsSet = true
            end
        end
        if widget.altSrc then
            local uOk, uStr = pcall(function() return widget.altSrc:stringUnit() end)
            if uOk and uStr and uStr == "ft" then
                flightAltThreshold = 16
            end
        end
    end

    -- Flight duration timer (speed > threshold AND height above home > threshold)
    local flying = homeLat and not gpsStale
        and speedValue and speedValue > flightSpdThreshold
        and altValue and homeAlt and altValue - homeAlt > flightAltThreshold
    if flying then
        if not flightInProgress then
            -- New flight detected: reset timer
            stats.flightTime = 0
            flightInProgress = true
        end
        local now = os.clock()
        if stats.flightLastTick then
            local dt = now - stats.flightLastTick
            if dt > 0 and dt < 2 then
                stats.flightTime = stats.flightTime + dt
            end
        end
        stats.flightLastTick = now
    else
        stats.flightLastTick = nil
        if flightInProgress and (not speedValue or speedValue <= flightSpdThreshold) 
            and (not altValue or not homeAlt or altValue - homeAlt <= flightAltThreshold) then
            flightInProgress = false
        end
    end

    -- Only repaint when something actually changed
    if needsInvalidate or (la and la ~= prevLat) or (lo and lo ~= prevLon) then
        if (lcdIsVisible or lcd.isVisible)() then
            (lcdInvalidate or lcd.invalidate)()
        end
    end
end

local CFG_SEP = "|"

local function read(widget)
    local raw = storage.read("cfg")
    if type(raw) ~= "string" or raw == "" then return end
    local parts = {}
    for part in (raw .. CFG_SEP):gmatch("(.-)" .. "%|") do
        parts[#parts + 1] = part
    end
    widget.bitmapFile = parts[1] or ""
    widget.gpsSensorName = parts[2] or ""
    if widget.gpsSensorName ~= "" then
        widget.gpsSensor = system.getSource({name = widget.gpsSensorName})
    end
    widget.distEnabled = (parts[3] == "1")
    widget.altSensorName = parts[4] or ""
    if widget.altSensorName ~= "" then
        widget.altSrc = system.getSource({name = widget.altSensorName})
    else
        widget.altSrc = nil
    end
    widget.indicatorType = (parts[5] == "1") and 1 or 0
    local st = tonumber(parts[6]) or 2
    if st < 2 then st = 2 elseif st > 30 then st = 30 end
    widget.signalTimeout = st
    widget.staleTextColor = (parts[7] == "1") and 1 or 0
    widget.overlayTextColor = tonumber(parts[14]) or 0
    widget.czRotEnabled = (parts[8] == "1")
    local ra = tonumber(parts[9]) or 0
    if ra < 0 then ra = 0 elseif ra > 359 then ra = 359 end
    widget.czRotAngle = ra
    widget.speedSensorName = parts[10] or ""
    if widget.speedSensorName ~= "" then
        widget.speedSrc = system.getSource({name = widget.speedSensorName})
    else
        widget.speedSrc = nil
    end
    widget.userSensorName = {"", "", ""}
    widget.userSrc = {nil, nil, nil}
    for ui = 1, 3 do
        widget.userSensorName[ui] = parts[10 + ui] or ""
        if widget.userSensorName[ui] ~= "" then
            widget.userSrc[ui] = system.getSource({name = widget.userSensorName[ui]})
        end
    end
end

local function write(widget)
    local s = (widget.bitmapFile or "") .. CFG_SEP
             .. (widget.gpsSensorName or "") .. CFG_SEP
             .. (widget.distEnabled and "1" or "0") .. CFG_SEP
             .. (widget.altSensorName or "") .. CFG_SEP
             .. (widget.indicatorType == 1 and "1" or "0") .. CFG_SEP
             .. tostring(widget.signalTimeout or 2) .. CFG_SEP
             .. (widget.staleTextColor == 1 and "1" or "0") .. CFG_SEP
             .. (widget.czRotEnabled and "1" or "0") .. CFG_SEP
             .. tostring(widget.czRotAngle or 0) .. CFG_SEP
             .. (widget.speedSensorName or "") .. CFG_SEP
             .. (widget.userSensorName[1] or "") .. CFG_SEP
             .. (widget.userSensorName[2] or "") .. CFG_SEP
             .. (widget.userSensorName[3] or "") .. CFG_SEP
             .. tostring(widget.overlayTextColor or 0)
    storage.write("cfg", s)
end

local function init()
    system.registerWidget({
        key = "accumap",
        name = "GPS AccuMap",
        title = false,
        create = create,
        configure = configure,
        paint = paint,
        wakeup = wakeup,
        event = event,
        read = read,
        write = write
    })
end

return {init = init}
