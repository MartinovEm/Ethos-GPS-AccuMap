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
local lcdColor
local lcdFont
local lcdInvalidate
local colorOrange
local colorWhite
local colorRed
local lcdIsVisible

-- Bitmap state
local loadedBitmap = nil
local loadedFile = ""
local bmpW = 0
local bmpH = 0
local homeIcon = nil
local arrowIcon = nil
local arrowRedIcon = nil

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

-- Home position (set once GPS stabilizes)
local homeLat = nil
local homeLon = nil
local homeX = nil
local homeY = nil
local homeStableLat = nil
local homeStableLon = nil
local homeStableFrames = 0
local HOME_STABLE_FRAMES = 100
local HOME_STABLE_DEG = 0.001



-- Cached distance from home (meters)
local distFromHome = nil
local prevDistFromHome = nil
local distText = nil
local DIST_JITTER_M = 5

-- Heading tracking (bearing from consecutive positions)
local lastHeading = 0
local prevHeadingLat = nil
local prevHeadingLon = nil

-- Last known coordinates text (shown when signal lost)
local lastCoordsText = nil
local lastGroundDistText = nil

local prevGroundDist = nil

-- Cached stale timeout in ms (recomputed only when signalTimeout changes)
local staleMs = 2000
local prevSignalTimeout = 2



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

local function mercatorY(lat)
    local latRad = lat * DEG_TO_RAD
    return mlog(mtan(pi / 4 + latRad * 0.5))
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
    local dx = dotX
    local dy = dotY
    if dx < 6 then dx = 6 elseif dx > w - 6 then dx = w - 6 end
    if dy < 6 then dy = 6 elseif dy > h - 6 then dy = h - 6 end
    local icon = isRed and arrowRedIcon or arrowIcon
    if indicatorType == 1 and icon and icon.rotate then
        local rotated = icon:rotate(lastHeading)
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

local function drawLastDotRed(w, h, indicatorType)
    drawIndicator(w, h, true, indicatorType)
    lcdFont(FONT_L)
    lcdColor(colorWhite)
    if lastCoordsText then
        lcdDrawText(w - 4, h - 28, lastCoordsText, RIGHT)
    end
    if lastGroundDistText then
        lcdDrawText(4, h - 28, lastGroundDistText)
    end
end

local function create()
    return {bitmapFile = "", gpsSensor = nil, gpsSensorName = "", distEnabled = false, altSensorName = "", altSrc = nil, indicatorType = 0, signalTimeout = 2}
end

local function configure(widget)
    local line1 = form.addLine("Map")
    form.addBitmapField(line1, nil, bitmapsPath,
        function() return widget.bitmapFile end,
        function(value)
            widget.bitmapFile = value
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

    local line3 = form.addLine("Distance")
    form.addBooleanField(line3, nil,
        function() return widget.distEnabled end,
        function(value)
            widget.distEnabled = value
        end)

    local line3a = form.addLine("  Altitude Source")
    form.addSensorField(line3a, nil,
        function()
            if not widget.distEnabled then return nil end
            if not widget.altSrc and widget.altSensorName ~= "" then
                widget.altSrc = system.getSource({name = widget.altSensorName})
            end
            return widget.altSrc
        end,
        function(value)
            if not widget.distEnabled then return end
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

    local line4 = form.addLine("Reset Home")
    form.addTextButton(line4, nil, "Reset",
        function()
            homeLat = nil
            homeLon = nil
            homeX = nil
            homeY = nil
            homeStableLat = nil
            homeStableLon = nil
            homeStableFrames = 0
            distFromHome = nil
            lastGroundDistText = nil
        end)
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
        lcdIsVisible = lcd.isVisible
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

    local w, h = lcdGetWindowSize()
    local bmpFile = widget.bitmapFile or ""

    -- Load bitmap only when selection changes
    if bmpFile ~= "" and (bmpFile ~= loadedFile or not loadedBitmap) then
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

    if loadedBitmap then
        lcdDrawBitmap(offX, offY, loadedBitmap)
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

    -- Resolve GPS sources each frame (source objects may not survive across frames)
    local srcLat = system.getSource(gpsLatQuery)
    local srcLon = system.getSource(gpsLonQuery)

    -- Localize hot widget fields (avoid repeated SDRAM hash lookups)
    local indType = widget.indicatorType or 0
    local wDistEnabled = widget.distEnabled

    if not srcLat or not srcLon then
        drawLastDotRed(w, h, indType)
        return
    end

    local lat = srcLat:value()
    local lon = srcLon:value()
    if not lat or not lon then
        drawLastDotRed(w, h, indType)
        return
    end
    if mercYRange == 0 or lonRange == 0 then return end

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
    if homeX then
        if homeIcon then
            lcdDrawBitmap(homeX - 8, homeY - 10, homeIcon)
        else
            lcdFont(FONT_BOLD)
            lcdColor(colorWhite)
            lcdDrawText(homeX - 8, homeY - 12, "H")
        end
    end

    drawIndicator(w, h, gpsStale, indType)

    -- Draw last known coordinates and distance when signal is stale
    if gpsStale then
        lcdFont(FONT_L)
        lcdColor(colorWhite)
        if lastCoordsText then
            lcdDrawText(w - 4, h - 28, lastCoordsText, RIGHT)
        end
        if lastGroundDistText then
            lcdDrawText(4, h - 28, lastGroundDistText)
        end
    end

    -- Draw distance from home in bottom-left corner
    if wDistEnabled and homeLat and distFromHome and distText then
        lcdFont(FONT_L)
        lcdColor(colorWhite)
        lcdDrawText(4, h - 28, distText)
    end
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

    -- Cache stale timeout only when setting changes
    local wTimeout = widget.signalTimeout or 2
    if wTimeout ~= prevSignalTimeout then
        prevSignalTimeout = wTimeout
        staleMs = wTimeout * 1000
    end

    -- Localize hot widget fields (avoid repeated SDRAM hash lookups)
    local wDistEnabled = widget.distEnabled
    local wGpsSensorName = widget.gpsSensorName
    local wAltSensorName = widget.altSensorName

    -- Detect telemetry loss via source:age() (ms since last update)
    local srcLat = system.getSource(gpsLatQuery)
    local wasStale = gpsStale
    local needsInvalidate = false
    if srcLat then
        local age = srcLat:age()
        gpsStale = age and age > staleMs
    end
    if gpsStale ~= wasStale then
        needsInvalidate = true
    end

    -- Resolve lon source once for shared use below
    local srcLon = (not gpsStale and srcLat) and system.getSource(gpsLonQuery) or nil
    local la, lo
    if srcLat and srcLon then
        la = srcLat:value()
        lo = srcLon:value()
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

    -- Calculate 2D ground distance for telemetry-loss display (always, regardless of toggle)
    local distLa = la or prevLat
    local distLo = lo or prevLon
    local lastGd = nil
    if homeLat and distLa and distLo then
        local gd = haversine(homeLat, homeLon, distLa, distLo)
        lastGd = gd
        if gd < DIST_JITTER_M then gd = 0 end
        if gd ~= prevGroundDist then
            prevGroundDist = gd
            if gd >= 1000 then
                lastGroundDistText = sformat("Distance: %.1f km", gd / 1000)
            else
                lastGroundDistText = sformat("Distance: %.0f m", gd)
            end
            needsInvalidate = true
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
    if wDistEnabled and widget.altSrc and homeLat and not gpsStale and la and lo then
        local alt = widget.altSrc:value()
        if alt and type(alt) == "number" then
            local groundDist = lastGd or haversine(homeLat, homeLon, la, lo)
            if groundDist < DIST_JITTER_M then
                distFromHome = 0
            else
                distFromHome = msqrt(groundDist * groundDist + alt * alt)
            end
        else
            distFromHome = nil
        end
    else
        distFromHome = nil
    end

    -- Update cached distance text only when value changes
    if distFromHome ~= prevDistFromHome then
        prevDistFromHome = distFromHome
        if distFromHome and distFromHome >= 1000 then
            distText = sformat("Distance: %.1f km", distFromHome / 1000)
        elseif distFromHome then
            distText = sformat("Distance: %.0f m", distFromHome)
        else
            distText = nil
        end
        needsInvalidate = true
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
end

local function write(widget)
    local s = (widget.bitmapFile or "") .. CFG_SEP
             .. (widget.gpsSensorName or "") .. CFG_SEP
             .. (widget.distEnabled and "1" or "0") .. CFG_SEP
             .. (widget.altSensorName or "") .. CFG_SEP
             .. (widget.indicatorType == 1 and "1" or "0") .. CFG_SEP
             .. tostring(widget.signalTimeout or 2)
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
        read = read,
        write = write
    })
end

return {init = init}
