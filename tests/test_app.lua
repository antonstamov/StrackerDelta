-- Offline run of the Stracker Delta application with ac/ui/web stubbed out.
-- Scenario: clock -> Refresh -> list -> scope change -> lap pick -> TARGET -> delta -> network error.
-- Started from run_tests.py: chunk(appPath, fixtures)

local appPath, fixtures = ...

local checks, failures = 0, 0
local function check(name, actual, expected)
  checks = checks + 1
  local ok
  if expected == nil then
    ok = actual ~= nil
  elseif type(expected) == 'number' and type(actual) == 'number' then
    ok = math.abs(actual - expected) < 1e-6
  else
    ok = actual == expected
  end
  if ok then
    print(string.format('  ok   %-38s %s', name, tostring(actual)))
  else
    failures = failures + 1
    print(string.format('  FAIL %-38s got=%s expected=%s', name, tostring(actual), tostring(expected)))
  end
end

local function checkNil(name, actual)
  checks = checks + 1
  if actual == nil then
    print(string.format('  ok   %-38s nil', name))
  else
    failures = failures + 1
    print(string.format('  FAIL %-38s got=%s expected=nil', name, tostring(actual)))
  end
end

local fileCache = {}
local function readFile(path)
  if fileCache[path] then return fileCache[path] end
  local handle = io.open(path, 'rb')
  if not handle then error('cannot open ' .. path) end
  local content = handle:read('*a')
  handle:close()
  fileCache[path] = content
  return content
end

-- ---------------------------------------------------------------------------
-- AC environment stubs
-- ---------------------------------------------------------------------------

local env = {
  carPosition = 0.10,
  lapTimeMs = 0,
  carSpeed = 180.0,
  serverName = 'SRV1',
  requests = {},
  windowOps = {},
  savedFiles = {},
  clicks = {},
  comboChoice = {},
  comboSeen = {},
  itemWidths = {},
  selectableAt = nil,
  selectableCalls = 0,
  rowClicks = {},
  clickOnButton = false,
  windowWidth = 320,
  rowHovered = false,
  drawn = {},
  texts = {},
  callbackErrors = {},
  events = {},
  fonts = {},
  lastChildHeight = nil,
  failNext = false,
  lapCallback = nil,
}

local colorMetatable = { __tostring = function() return 'color' end }
local colorNames = { 'transparent', 'black', 'silver', 'gray', 'white', 'maroon', 'red',
                     'purple', 'fuchsia', 'green', 'lime', 'olive', 'yellow', 'orange',
                     'navy', 'blue', 'teal', 'cyan', 'aqua' }
local colors = {}
for _, name in ipairs(colorNames) do colors[name] = setmetatable({}, colorMetatable) end

-- rgbm(r, g, b, a) and vec2(x, y) are callable types with arithmetic in the game
local vecMeta = {}
vecMeta.__index = vecMeta
vecMeta.__add = function(a, b) return vecMeta.make(a.x + b.x, a.y + b.y) end
vecMeta.__sub = function(a, b) return vecMeta.make(a.x - b.x, a.y - b.y) end
vecMeta.__mul = function(a, b)
  if type(b) == 'number' then return vecMeta.make(a.x * b, a.y * b) end
  return vecMeta.make(a.x * b.x, a.y * b.y)
end
vecMeta.__div = function(a, b) return vecMeta.make(a.x / b, a.y / b) end
vecMeta.__unm = function(a) return vecMeta.make(-a.x, -a.y) end
vecMeta.__tostring = function(v) return '(' .. v.x .. ', ' .. v.y .. ')' end
function vecMeta.make(x, y)
  return setmetatable({ x = x, y = y }, vecMeta)
end

_G.rgbm = setmetatable({ colors = colors }, {
  __call = function(_, r, g, b, a) return setmetatable({ r = r, g = g, b = b, a = a }, colorMetatable) end,
})
_G.vec2 = vecMeta.make
_G.script = {}

-- ac.storage raises on unknown keys in the real game - make the stub behave the same
local storageKeys = { serverAddresses = '', serverBindings = '',
                      listServer = '', listScope = 'session',
                      autoRefresh = false, refreshSeconds = 60,
                      detailsOpen = false, alwaysFastest = false,
                      textSizePx = 25, lastLapId = 0 }
env.storage = storageKeys

_G.ac = {
  storage = function()
    return setmetatable({}, {
      __index = function(_, key)
        if storageKeys[key] == nil then error('Unknown key: ' .. tostring(key)) end
        return storageKeys[key]
      end,
      __newindex = function(_, key, value) storageKeys[key] = value end,
    })
  end,
  log = function() end,
  error = function() end,
  warn = function() end,
  getCar = function()
    return { position = { 0, 0, 0 }, normalizedSplinePosition = env.carPosition,
             lapTimeMs = env.lapTimeMs }
  end,
  getCarSpeedKmh = function() return env.carSpeed end,
  getTrackID = function() return 'rmi_nelson_ledges' end,
  getTrackFullID = function() return 'rmi_nelson_ledges' end,
  getTrackLayout = function() return '' end,
  getCarID = function() return 'ac_legends_gtc_corvette_63' end,
  getServerName = function() return env.serverName end,
  worldCoordinateToTrackProgress = function() return env.carPosition end,
  onTrackPointCrossed = function(_, _, callback) env.lapCallback = callback end,
  setWindowOpen = function(id, opened)
    env.windowOps[#env.windowOps + 1] = id .. '=' .. tostring(opened)
    if id == 'laps' then env.lapsOpen = opened end
  end,
  isWindowOpen = function() return env.lapsOpen == true end,
}

_G.ui = {
  ComboFlags = { None = 0 },
  text = function(text)
    env.events[#env.events + 1] = 'text:' .. tostring(text)
  end,
  inputText = function(_, text)
    env.inputText = text
    -- one shot, like a person typing into one field: only the first text field
    -- of this frame gets the new value
    if env.inputTextResult ~= nil then
      local typed = env.inputTextResult
      env.inputTextResult = nil
      return typed, false, false
    end
    return text, false, false
  end,
  textColored = function(text, color)
    env.texts[#env.texts + 1] = { text = text, color = color }
    env.events[#env.events + 1] = 'text:' .. tostring(text)
  end,
  sameLine = function() end,
  newLine = function() end,
  separator = function() end,
  button = function(label)
    env.events[#env.events + 1] = 'button:' .. label
    if env.clicks[label] then env.clicks[label] = nil return true end
    return false
  end,
  combo = function(label, index)
    env.comboSeen[label] = index
    local choice = env.comboChoice[label]
    if choice then env.comboChoice[label] = nil return choice, true end
    return index, false
  end,
  beginChild = function(_, size) env.lastChildHeight = size.y end,
  pushFont = function(font) env.fonts[#env.fonts + 1] = font end,
  popFont = function() end,
  setNextItemWidth = function(width)
    env.itemWidths[#env.itemWidths + 1] = width
  end,
  endChild = function() end,
  columns = function() end,
  nextColumn = function() end,
  columnSortingHeader = function() end,
  pushStyleVarAlpha = function() end,
  popStyleVar = function() end,
  dummy = function() end,
  beginScale = function() end,
  endPivotScale = function() end,
  endScale = function() end,
  getCursorX = function() return 0 end,
  setCursorX = function() end,
  getCursorY = function() return 0 end,
  fontSize = function() return 18 end,
  measureText = function(text)
    local width = 7 * #tostring(text)
    return { x = width, y = 14 }
  end,
  textAligned = function() end,
  Alignment = { Start = 0, Center = 1, End = 2 },
  SelectableFlags = { None = 0, AllowDoubleClick = 1, DontClosePopups = 2, SpanAllColumns = 4 },
  pushFont = function() end,
  popFont = function() end,
  setNextTextBold = function() end,
  pushStyleVar = function() end,
  pushStyleColor = function() end,
  popStyleColor = function() end,
  Font = { Small = 1, Tiny = 2, Monospace = 3, Main = 4, Italic = 5, Title = 6, Huge = 7, SmallItalic = 8 },
  StyleVar = { WindowPadding = 1, ItemSpacing = 2 },
  StyleColor = { Text = 0, TextDisabled = 1, FrameBg = 2, Button = 3, Separator = 4 },
  setCursorY = function() end,
  invisibleButton = function(label)
    env.events[#env.events + 1] = 'row:' .. label
    if env.rowClicks[label] then env.rowClicks[label] = nil return true end
    return false
  end,
  itemHovered = function() return env.rowHovered == true end,
  drawRectFilled = function(p1, p2)
    -- a rule is a filled rect of less than two pixels: the separators
    if p2.y - p1.y < 2 then env.events[#env.events + 1] = 'rule' end
    env.lastRect = { x1 = p1.x, y1 = p1.y, x2 = p2.x, y2 = p2.y }
  end,
  drawLine = function() end,
  drawText = function(_, pos) return pos.x + 40 end,
  pushDWriteFont = function() end,
  popDWriteFont = function() end,
  mouseLocalPos = function()
    if env.clickOnButton and env.lastRect then
      return vecMeta.make((env.lastRect.x1 + env.lastRect.x2) / 2,
                          (env.lastRect.y1 + env.lastRect.y2) / 2)
    end
    return vecMeta.make(-1, -1)
  end,
  icon24 = function() end,
  Icons = { Stopwatch = 1, List = 2 },
  MouseButton = { Left = 0 },
  isMouseDragging = function() return false end,
  mouseReleased = function() return false end,
  mouseDragDelta = function() return vecMeta.make(0, 0) end,
  setNextWindowPosition = function() end,
  accessAppWindow = function() return nil end,
  getAppWindows = function() return {} end,
  tooltip = function(_, content) if content then content() end end,
  mouseClicked = function()
    if env.clickOnButton then env.clickOnButton = false return true end
    return false
  end,
  dwriteDrawText = function(text, _, _, color)
    env.drawn[#env.drawn + 1] = { text = text, color = color }
  end,
  measureDWriteText = function() return { x = 40, y = 14 } end,
  cursorScreenPos = function() return vecMeta.make(0, 0) end,
  setCursorScreenPos = function() end,
  pushClipRect = function() end,
  popClipRect = function() end,
  windowSize = function() return vecMeta.make(env.windowWidth or 320, 100) end,
  windowPos = function() return vecMeta.make(0, 0) end,
  slider = function(_, value) return value, false end,
  checkbox = function(label)
    if env.clicks[label] then env.clicks[label] = nil return true end
    return false
  end,
  selectable = function(label)
    env.selectableCalls = env.selectableCalls + 1
    env.events[#env.events + 1] = 'selectable:' .. label
    return env.selectableAt == env.selectableCalls
  end,
}

local realIo = io
_G.io = {
  save = function(path, data) env.savedFiles[path] = data return true end,
  load = function(path) return env.savedFiles[path] end,
  open = realIo.open,
}

-- the stracker the app is pointed at during the run
env.address = 'https://stracker.test'
env.storage.serverAddresses = env.address

-- a page with the header row and nothing under it: what a track with no laps looks
-- like, and what the statistics page of a track the site never filled in looks like
local EMPTY_LAPSTAT = '<table><thead><tr><th>Pos</th><th>Driver</th><th>Car</th>' ..
  '<th>Best lap</th><th>Gap to 1st</th><th>S1</th><th>S2</th><th>S3</th>' ..
  '<th>Valid</th><th>Laps</th><th>Date</th><th>Grip</th><th>Amb./Track</th>' ..
  '<th>vMax</th></tr></thead><tbody></tbody></table>'
local EMPTY_STATISTICS = '<table><thead><tr><th>Track</th><th>Cars</th>' ..
  '<th>Date</th></tr></thead><tbody></tbody></table>'

--- Puts the page count the test wants into a lapstat body: the fixtures ship
--- with one page. env.pageRepeats leaves the pages identical, which is the case
--- the app has to survive, because the site shifts its order between requests.
local function withPages(body, url)
  local pages = env.pageCount or 1
  if pages <= 1 then return body end

  local page = tonumber(url:match('[&?]page=(%d+)')) or 0
  if page > pages - 1 then page = pages - 1 end

  local pager = '<ul class="pagination pagination-sm">' ..
    '<li class="active"><a href="/lapstat?page=' .. page .. '">' .. (page + 1) .. '</a></li>' ..
    '<li><a href="/lapstat?page=' .. (pages - 1) ..
    '"><span class="glyphicon glyphicon-fast-forward"></span></a></li></ul>'
  if body:find('<ul class="pagination') then
    body = body:gsub('<ul class="pagination.-</ul>', pager, 1)
  else
    body = body .. pager
  end

  -- every page of a real query holds different laps
  if not env.pageRepeats and page > 0 then
    local shift = page * 1000
    body = body:gsub('lapdetails%?lapid=(%d+)', function(id)
      return 'lapdetails?lapid=' .. tostring(tonumber(id) + shift)
    end)
  end
  return body
end

local function bodyFor(url)
  if url:find('lapdetails') then
    return readFile(fixtures .. '/lapdetails_468323.html')
  end
  if url:find('statistics') then
    if env.emptyStatistics then return EMPTY_STATISTICS end
    return readFile(fixtures .. '/statistics_track.html')
  end
  if url:find('cars=') then
    if env.emptyWithCars then return EMPTY_LAPSTAT end
    return withPages(readFile(fixtures .. '/lapstat_track_car.html'), url)
  end

  local body = readFile(fixtures .. '/lapstat_session.html')
  -- an address can answer with a server list that does not know this AC server:
  -- that is what the probing has to notice
  if url:find('nomatch') then body = body:gsub('SRV1', 'XSRV1') end

  -- a track query without a car filter is the probe that finds the car list:
  -- the fixture ships with hundreds of options, so a known short list goes in,
  -- long enough to be split into parts
  if url:find('track=') and not url:find('cars=') then
    local options = '<option value="ac_car_alpha"></option><option value="ac_car_beta"></option>'
    for n = 3, 62 do options = options .. '<option value="ac_car_' .. n .. '"></option>' end
    body = body:gsub('(<select[^>]-name="cars"[^>]-)[%s]*', '%1' .. options, 1)
    if env.noCarsInForm then body = body:gsub('<select[^>]-name="cars".-</select>', '', 1) end
    if env.emptyWithoutCars then body = EMPTY_LAPSTAT end
    return body
  end

  return withPages(body, url)
end

_G.web = {
  timeouts = function() end,
  get = function(url, callback)
    env.requests[#env.requests + 1] = url
    if env.failNext then
      env.failNext = false
      callback('connection refused', nil)
      return
    end
    -- a client that refuses the long car list once, the way a game does, and takes
    -- the shorter ones that follow
    if env.failCarsRequest and url:find('cars=') then
      env.failCarsRequest = nil
      callback('url too long', nil)
      return
    end
    -- car groups that do not go through: one of them, or all of them. The text the
    -- game hands over comes in a system code page, not in utf-8
    if url:find('cars=') and (env.failAllCarGroups or
       (env.failCarsStartingWith and url:find(env.failCarsStartingWith, 1, true))) then
      callback('\232\235\230\244\236\238 (code: 122)', nil)
      return
    end
    -- a client that takes fewer cars per query than the app asks for
    if env.maxCarsPerQuery and url:find('cars=') then
      local list = url:match('cars=([^&]*)') or ''
      -- the separators arrive encoded, that is what the app puts in the url
      local encoded = select(2, list:gsub('%%2C', ''))
      local plain = select(2, list:gsub(',', ''))
      if 1 + encoded + plain > env.maxCarsPerQuery then
        env.refusedCarQueries = (env.refusedCarQueries or 0) + 1
        callback('url too long', nil)
        return
      end
    end
    local ok, err = pcall(callback, nil, { status = 200, body = bodyFor(url) })
    -- stracker.get swallows callback errors through pcall: they are caught here,
    -- otherwise they look like a network error and cannot be found at all
    if not ok then env.callbackErrors[#env.callbackErrors + 1] = tostring(err) end
  end,
}

-- ---------------------------------------------------------------------------
-- Application run
-- ---------------------------------------------------------------------------

assert(loadfile(appPath))()
local app = _G.DeltaLuaTest
local appScript = _G.script
local s = app.state

print('')
print('== application: scenario ==')

-- the windows draw even without data
appScript.windowDrive()
check('drive window draws without data', true, true)
checkNil('TARGET is empty', s.reference)

-- 1) app start: it loads Session - auto by itself and picks the fastest lap
appScript.update(0.016)
for _, message in ipairs(env.callbackErrors) do print('  CALLBACK ERROR: ' .. message) end
check('startup request for the server list', env.requests[1], env.address .. '/lapstat')
check('startup request for the list', env.requests[2], env.address .. '/lapstat?currservers=SRV1')
check('startup request for the lap', env.requests[3]:find('lapdetails') ~= nil, true)
check('laps in the session', #s.laps, 2)
check('reference loaded automatically', s.reference and s.reference.meta.lapTimeText or nil, '01:18.149')
check('reference lapid stored', env.storage.lastLapId, 469675)   -- fastest lap of the list
check('CSV stored', env.savedFiles['apps/lua/StrackerDelta/last_lap.csv'] ~= nil, true)
local strayWrites = 0; for path in pairs(env.savedFiles) do if path:find('^apps/lua/StrackerDelta/') == nil then strayWrites = strayWrites + 1 end end
check('no writes outside the app folder', strayWrites, 0)
appScript.windowDrive()
check('drive window draws without data', true, true)

-- 1b) second start: if the lap from last time is in the list, load it
env.storage.lastLapId = 469663
s.autoLoaded = false
s.reference = nil
s.laps = {}
env.clicks['Refresh'] = true
appScript.windowLaps()
check('lap from last time restored', env.storage.lastLapId, 469663)

appScript.windowLaps()
check('laps window draws', true, true)
check('server detected', s.server, 'SRV1')

-- 2) single list: "Track + car - auto"
env.comboChoice['##list'] = 3
appScript.windowLaps()
check('list scope', app.config.listScope, 'track_car')
check('track+car request (no server)', env.requests[#env.requests],
      env.address .. '/lapstat?track=rmi_nelson_ledges&cars=ac_legends_gtc_corvette_63')
check('laps in track+car mode', #s.laps, 21)

-- 3) "This track": the lapstat page itself carries the whole car list, so the
-- statistics page is not needed and the query goes out with every car of it
env.requests = {}
env.comboChoice['##list'] = 2
appScript.windowLaps()
check('laps in track mode', #s.laps, 21)
check('last request is lapstat', env.requests[#env.requests]:find('lapstat') ~= nil, true)

local probedPlain, askedWithEveryCar, askedStatistics = false, false, false
for _, url in ipairs(env.requests) do
  if url:find('/statistics') then askedStatistics = true end
  if url:find('/lapstat%?track=') and not url:find('cars=') then probedPlain = true end
  if url:find('cars=ac_car_alpha') and url:find('ac_car_beta') then askedWithEveryCar = true end
end
check('the plain track query came first', probedPlain, true)
check('asked with the whole car list', askedWithEveryCar, true)
check('statistics not needed', askedStatistics, false)

-- 4) picking a lap from the list (click on a row; the row id is the lapid now)
env.selectableCalls = 0
env.rowClicks['##lap' .. tostring(s.laps[1].lapid)] = true
appScript.windowLaps()
check('TARGET loaded', s.reference and s.reference.meta.lapTimeText or nil, '01:18.149')
check('TARGET driver', s.reference and s.reference.meta.driver or nil, 'Dana Whitfield')
check('TARGET track', s.reference and s.reference.meta.track or nil, 'rmi_nelson_ledges')
check('points in the profile', s.reference and #s.reference.positions or 0, 72)
check('laps window stayed open', env.windowOps[#env.windowOps] ~= 'laps=false', true)
check('status has no TARGET', s.status:find('TARGET') == nil, true)

-- 4a) another click on Lap list closes the window, the next one opens it
env.clickOnButton = true
appScript.windowDrive()
check('list opened by click', env.lapsOpen, true)
env.clickOnButton = true
appScript.windowDrive()
check('another click closes it', env.lapsOpen, false)
env.clickOnButton = true
appScript.windowDrive()
check('click opens it again', env.lapsOpen, true)

-- 4b) the list button does not go past the right edge even in a window narrower than the content
env.windowWidth = 120
env.lastRect = nil
appScript.windowDrive()
check('button stays inside a narrow window',
      env.lastRect ~= nil and env.lastRect.x2 <= env.windowWidth and env.lastRect.x1 >= 0, true)
env.windowWidth = 320
env.lastRect = nil
appScript.windowDrive()
check('button at the right edge at normal width',
      env.lastRect ~= nil and math.abs(env.lastRect.x2 - (env.windowWidth - 10)) < 0.001, true)

-- 4c) the target time is drawn in the same colour as the rest of the line
env.drawn = {}
appScript.windowDrive()
local labelColor, targetColor
for _, item in ipairs(env.drawn) do
  if item.text == 'SPEED' then labelColor = item.color end
  if item.text == '01:18.149' then targetColor = item.color end
end
check('target time is not colour highlighted',
      targetColor ~= nil and targetColor == labelColor, true)

-- 5) delta: the lap time comes from ac.StateCar.lapTimeMs (no waiting for the line)
env.lapTimeMs = 12500
appScript.update(0.016)
check('lap time from lapTimeMs', s.reference ~= nil, true)
env.lapCallback()
appScript.update(0.016)
check('fallback counter works too', s.lapActive, true)
check('the clock runs', s.clock > 0, true)
appScript.windowDrive()
check('drive window with delta draws', true, true)

-- 5b) when lapTimeMs is not available (0) the fallback counter works
env.lapTimeMs = 0
env.lapCallback()
appScript.update(0.016)
check('fallback on the line crossing', s.lapActive, true)
env.lapTimeMs = 12500

-- 7) unknown server in auto mode -> quietly switch to This track
app.config.listScope = 'session'
app.config.listServer = ''
env.serverName = 'Some Unknown Server'
s.laps = {}
env.clicks['Refresh'] = true
appScript.windowLaps()
check('server not recognised -> track scope', app.config.listScope, 'track')
check('track list loaded', #s.laps, 21)
check('request without a server', s.lastPath:find('track=') ~= nil, true)
check('no currservers in the request', s.lastPath:find('currservers') == nil, true)
env.comboChoice['##list'] = 4       -- "Session - SRV1"
appScript.windowLaps()
check('manual server pick', app.config.listServer, 'SRV1')
check('scope stayed session', app.config.listScope, 'session')
check('laps after the manual pick', #s.laps, 2)

-- 8) a network error does not take the app down
env.failNext = true
env.clicks['Refresh'] = true
appScript.windowLaps()
check('network error shown', s.status:find('error') ~= nil, true)
appScript.windowDrive()
check('window still draws after the error', true, true)

-- 9) recovery after the error
env.clicks['Refresh'] = true
appScript.windowLaps()
check('recovered after the error', #s.laps, 2)

-- 10) list window: diagnostics collapsed, the error is visible and opens Details
env.texts = {}
appScript.windowLaps()
local shown = {}
for _, item in ipairs(env.texts) do shown[item.text] = item.color end
check('AC server is not in the main area', shown['AC: ' .. env.serverName] == nil, true)
check('request is not in the main area', shown['/' .. s.lastPath] == nil, true)
check('the List caption is gone', shown['List'] == nil, true)
check('there is a status line', shown[s.status] ~= nil, true)

env.failNext = true
env.clicks['Refresh'] = true
env.texts = {}
appScript.windowLaps()
local errorColor
for _, item in ipairs(env.texts) do
  if item.text == s.status then errorColor = item.color end
end
check('the error is not drawn in grey', errorColor ~= nil and errorColor ~= rgbm.colors.silver, true)
check('Details opened on error', app.config.detailsOpen, true)
check('Details has the reason', env.texts[1] ~= nil, true)

local foundReason = false
for _, item in ipairs(env.texts) do
  if tostring(item.text):find('connection refused', 1, true) then foundReason = true end
end
check('the error text is visible in Details', foundReason, true)

-- Details collapses again on a click on the toggle
env.selectableAt = env.selectableCalls + 1
appScript.windowLaps()
check('Details collapses on click', app.config.detailsOpen, false)

-- 11) clicking an already loaded lap does not request it again
-- (the lapdetails stub returns a fixed lapid, so meta is aligned by hand)
s.reference.meta.lapid = s.laps[1].lapid
local requestsBefore = #env.requests
env.rowClicks['##lap' .. tostring(s.laps[1].lapid)] = true
appScript.windowLaps()
check('the same lap is not loaded again', #env.requests, requestsBefore)

-- 12) another lap loads
env.rowClicks['##lap' .. tostring(s.laps[2].lapid)] = true
appScript.windowLaps()
check('another lap loads', #env.requests > requestsBefore, true)

-- 13) window layout: no Retry, Details visible without scrolling, one font
app.config.detailsOpen = true
env.events = {}
env.fonts = {}
appScript.windowLaps()

local sawRetry, detailsAt, firstRowAt, detailAt, selectedAt = false, nil, nil, nil, nil
for i, event in ipairs(env.events) do
  if event == 'button:Retry' then sawRetry = true end
  if event:find('^selectable:.') and event:find('Details') and not detailsAt then detailsAt = i end
  if event == 'text:delta text size' and not detailAt then detailAt = i end
  if event:sub(1, 13) == 'text:Selected' and not selectedAt then selectedAt = i end
  if event:sub(1, 4) == 'row:' and not firstRowAt then firstRowAt = i end
end
check('no Retry button', sawRetry, false)
check('Details drawn before the table', detailsAt ~= nil and firstRowAt ~= nil and
                                   detailsAt < firstRowAt, true)
check('Details content right under the button',
      detailAt ~= nil and detailsAt < detailAt and detailAt < selectedAt, true)
-- the list takes the remaining window height: the window size sets the table size
check('list fills the remaining height', env.lastChildHeight, -10)
check('one font in the table', #env.fonts, 0)

-- 14) cell colours: only the time and the name in white, the rest grey
env.texts = {}
appScript.windowLaps()
local cellColor = {}
for _, item in ipairs(env.texts) do cellColor[item.text] = item.color end
local white = rgbm.colors.white
check('time is white', cellColor['00:56.597'], white)
check('name is white', cellColor['Riley Vance'], white)
check('Gap in the same grey as Car', cellColor['+00.000'] == cellColor['wsc_legends_330p4'], true)
check('Gap is not white', cellColor['+00.000'] ~= white, true)
check('Date in the same grey', cellColor['2026-10-13 02:41'] == cellColor['+00.000'], true)

-- 15) the grip / temperature / vMax columns are present and filled
env.texts = {}
appScript.windowLaps()
local headers = {}
for _, item in ipairs(env.texts) do headers[item.text] = true end
check('Grip column', headers['Grip'], true)
check('Amb/Track column', headers['Amb/Track'], true)
check('vMax column', headers['vMax'], true)
local cellsByText = {}
for _, item in ipairs(env.texts) do cellsByText[item.text] = item.color end
local subtleColor = cellColor['+00.000']          -- colour of every secondary column
check('grip in the same grey', cellsByText['97.0%'], subtleColor)
check('max speed in the same grey', cellsByText['258 km/h'], subtleColor)
local tempsDrawn = false
for text, color in pairs(cellsByText) do
  if type(text) == 'string' and text:find('/', 1, true) and color == subtleColor then
    tempsDrawn = true
  end
end
check('temperatures drawn', tempsDrawn, true)

-- 16) the column grid is measured from the content and fitted to the window
env.windowWidth = 1200
appScript.windowLaps()
local wide = s.grid
local ordered, noOverlap = true, true
for i = 2, #wide.offsets do
  if wide.offsets[i] <= wide.offsets[i - 1] then ordered = false end
  if wide.offsets[i] < wide.offsets[i - 1] + wide.widths[i - 1] then noOverlap = false end
end
check('columns increase', ordered, true)
check('columns do not overlap', noOverlap, true)
check('everything fits in a wide window', wide.width <= 1200 - 30 - 6, true)

env.windowWidth = 420
appScript.windowLaps()
local narrow = s.grid
check('a narrow window shrinks the columns', narrow.width < wide.width, true)
check('the name and the car are the ones that shrink', narrow.widths[4] < wide.widths[4], true)
env.windowWidth = 320

-- 15) pagination: the list is fetched whole, there is no page switch in the UI
app.config.listScope = 'session'
app.config.listServer = 'SRV1'
env.pageCount = 3             -- the fixture has one page, so our own pager goes in
env.requests = {}
env.clicks['Refresh'] = true
appScript.windowLaps()

local paged = 0
for _, url in ipairs(env.requests) do
  if url:find('page=') then paged = paged + 1 end
end
check('first page without the parameter', env.requests[1]:find('page=') == nil, true)
check('the other pages were requested', paged, 2)
check('list merged from all pages', #s.laps, 6)
check('pages reported in the diagnostics', s.pages, 3)

env.pageCount = 1
env.clicks['Refresh'] = true
appScript.windowLaps()
check('one page again after the reset', #s.laps, 2)

-- 16) local search: every word has to be found in the driver or the car
local function drawnDrivers()
  local names = {}
  for _, item in ipairs(env.texts) do
    if item.text == 'Frost' or item.text == 'Riley Vance' then names[item.text] = true end
  end
  return names
end

local function shownStatusText()
  for _, item in ipairs(env.texts) do
    local text = tostring(item.text)
    if text:find(' match$') or text:find('^no matches') then return text end
  end
  return ''
end

env.texts = {}
s.filter = 'frost gt40'
appScript.windowLaps()
check('Frost found', drawnDrivers()['Frost'], true)
check('the other driver filtered out', drawnDrivers()['Riley Vance'] == nil, true)
check('match counter', shownStatusText(), '1 of 2 match')

env.texts = {}
s.filter = 'gt40'
appScript.windowLaps()
check('the same one found by car', drawnDrivers()['Frost'], true)

env.texts = {}
s.filter = 'frost gt330'
appScript.windowLaps()
check('no matches - a clear hint', shownStatusText():find('no matches') ~= nil, true)

env.texts = {}
s.filter = ''
appScript.windowLaps()
check('clearing the filter shows everything', drawnDrivers()['Riley Vance'], true)

-- 17) the "always fastest" checkbox: the list takes the first row and reloads the lap
app.config.alwaysFastest = true
s.page = 0
env.requests = {}
env.clicks['Refresh'] = true
appScript.windowLaps()
check('the fastest lap was requested', env.requests[#env.requests]:find('lapid=469675') ~= nil, true)
check('the checkbox is on', app.config.alwaysFastest, true)

env.rowClicks['##lap' .. tostring(s.laps[2].lapid)] = true
appScript.windowLaps()
check('a manual pick clears the checkbox', app.config.alwaysFastest, false)
app.config.alwaysFastest = false

-- 18) cache: the profile from disk survives a network error on the lap
env.savedFiles = {}
s.autoLoaded = false
s.reference = nil
env.clicks['Refresh'] = true
appScript.windowLaps()
check('profile cache written', env.savedFiles['apps/lua/StrackerDelta/cache_lap.csv'] ~= nil, true)
check('list key written', env.savedFiles['apps/lua/StrackerDelta/cache_index.txt'] ~= nil, true)

s.autoLoaded = false
s.reference = nil
env.failLap = true
env.clicks['Refresh'] = true
appScript.windowLaps()
check('profile taken from disk on a network error',
      s.reference ~= nil and s.reference.meta.driver ~= nil, true)
env.failLap = false

-- a lap from the cache has to stay "one of ours" for the list: otherwise the Selected row
-- complains that there is no reference and the highlight is not drawn
check('lapid from the cache is a number', type(s.reference.meta.lapid), 'number')
check('lapid from the cache is in the list',
      s.reference.meta.lapid == s.laps[1].lapid or
      s.reference.meta.lapid == s.laps[2].lapid, true)

env.texts = {}
appScript.windowLaps()
local selectedLine
for _, item in ipairs(env.texts) do
  if tostring(item.text):sub(1, 8) == 'Selected' then selectedLine = item.text end
end
check('Selected does not complain about being missing from the list',
      selectedLine ~= nil and selectedLine:find('not in the current list') == nil, true)

-- ---------------------------------------------------------------------------
-- 19) addresses: configured by the user, remembered per AC server
-- ---------------------------------------------------------------------------
env.pageCount = nil
env.failLap = nil
-- section 7 left an AC server that no fixture knows; the address tests need one
-- that is in the server list, so the probing has something to find
env.serverName = 'SRV1'
app.config.listScope = 'session'
app.config.listServer = ''

local function setAddresses(text)
  env.storage.serverAddresses = text
  s.addressText = text
end

local function requestsTo(host)
  local found = 0
  for _, url in ipairs(env.requests) do
    if url:find('^' .. host:gsub('(%W)', '%%%1')) then found = found + 1 end
  end
  return found
end

local function refreshNow()
  env.requests = {}
  env.clicks['Refresh'] = true
  appScript.windowLaps()
end

-- 19a) nothing configured: the app must say where to type it and not hammer the network
setAddresses('')
s.address = nil
app.config.serverBindings = ''
refreshNow()
check('no address: nothing was requested', #env.requests, 0)
check('no address: status points at Details', s.status:find('no stracker address') ~= nil, true)
check('no address: Details opened itself', app.config.detailsOpen, true)

-- 19b) one address: used straight away, no guessing needed
setAddresses('https://solo.test')
s.address = nil
refreshNow()
check('single address used', s.address, 'https://solo.test')
check('single address reason', s.addressReason, 'the only one configured')
check('single address stored back', app.config.serverAddresses, 'https://solo.test')
check('single address went into the bindings', app.config.serverBindings:find('solo%.test') ~= nil, true)
check('single address got the list', requestsTo('https://solo.test') > 0, true)

-- 19c) two addresses now, but this AC server is known: the remembered one wins
setAddresses('https://solo.test, https://other.test')
s.address = nil
refreshNow()
check('remembered address wins', s.address, 'https://solo.test')
check('remembered address reason', s.addressReason, 'remembered')
check('the other address was not asked', requestsTo('https://other.test'), 0)

-- 19d) the remembered one is gone: ask the list, take the one that knows the server
setAddresses('https://nomatch.test, https://good.test')
s.address = nil
refreshNow()
check('the first address was probed', requestsTo('https://nomatch.test') > 0, true)
check('the second one too', requestsTo('https://good.test') > 0, true)
check('the address that knows the server won', s.address, 'https://good.test')
check('probe reason says so', s.addressReason:find('matches SRV1') ~= nil, true)
check('the probe result was remembered', app.config.serverBindings:find('good%.test') ~= nil, true)

-- 19e) nothing knows this AC server: the first address of the list is used and kept
setAddresses('https://nomatch.test, https://nomatch2.test')
s.address = nil
app.config.serverBindings = ''
refreshNow()
check('fallback is the first address', s.address, 'https://nomatch.test')
check('fallback reason says so', s.addressReason, 'no match, first in the list')
check('fallback was remembered', app.config.serverBindings:find('nomatch%.test') ~= nil, true)

-- 19f) the field is the list: typing into it is enough, no button
app.config.detailsOpen = true
env.inputTextResult = 'https://typed1.test, https://typed2.test, oops'
env.texts = {}
appScript.windowLaps()
check('typed list is stored normalised', app.config.serverAddresses,
      'https://typed1.test, https://typed2.test')
check('the bad piece is reported', #s.addressText > 0 and true or false, true)
local reported = false
for _, item in ipairs(env.texts) do
  if tostring(item.text):find('skipped: oops') then reported = true end
end
check('the bad piece is shown in the UI', reported, true)

-- 19g) the manual choice: picking an entry binds it for this AC server and takes it
-- into use, with no button to press
env.comboChoice['##addressPick'] = 2
refreshNow()
check('manual pick wins', s.address, 'https://typed2.test')
check('manual pick reason', s.addressReason, 'by hand')
check('manual pick remembered', app.config.serverBindings:find('typed2%.test') ~= nil, true)
checkNil('the first address is not bound', app.config.serverBindings:find('typed1%.test'))

-- the choice has to survive the next frame: a combo that is rebuilt from the address
-- in use must show the one that was just picked, not fall back to the old one
env.comboSeen = {}
appScript.windowLaps()
check('the list kept the picked address', env.comboSeen['##addressPick'], 2)

-- 19h) removing an address from the field removes its bindings too
env.inputTextResult = 'https://typed1.test'
env.clicks['Refresh'] = true
appScript.windowLaps()
checkNil('the removed address is not bound any more', app.config.serverBindings:find('typed2%.test'))
check('the field kept only what is left', app.config.serverAddresses, 'https://typed1.test')
s.address = nil
refreshNow()
check('the only address left is used', s.address, 'https://typed1.test')
check('and remembered again', app.config.serverBindings:find('typed1%.test') ~= nil, true)

-- ---------------------------------------------------------------------------
-- 20) This track: the lapstat page carries the whole car list, so the query goes
-- out with every car of it; the statistics page is the fallback for a page that
-- does not, and the plain result is kept whenever the long one does not work
-- ---------------------------------------------------------------------------
setAddresses(env.address)
s.address = env.address
app.config.listScope = 'track'
app.config.listServer = ''
app.config.alwaysFastest = false
s.autoLoaded = true          -- the reference lap is the business of other sections

local function sawCarFilter()
  for _, url in ipairs(env.requests) do
    if url:find('cars=') then return true end
  end
  return false
end

local function sawStatistics()
  for _, url in ipairs(env.requests) do
    if url:find('/statistics') then return true end
  end
  return false
end

-- 20a) the page has no car list at all: fall back to what the statistics know
env.noCarsInForm = true
refreshNow()
check('no car list: the statistics page is asked', sawStatistics(), true)
check('no car list: asked with the cars it knows', sawCarFilter(), true)
check('no car list: rows arrived anyway', #s.laps > 0, true)

-- 20b) the whole car list does not fit into one url: ask in parts and merge
env.noCarsInForm = nil
env.failCarsRequest = true
refreshNow()
local partQueries = 0
for _, url in ipairs(env.requests) do
  if url:find('cars=ac_car') then partQueries = partQueries + 1 end
end
check('refused long url: the list was split', partQueries > 1, true)
check('refused long url: rows arrived anyway', #s.laps > 0, true)
check('refused long url: the report shows a car query', s.lastPath:find('cars=') ~= nil, true)
env.failCarsRequest = nil

-- 20c) pages of one query can repeat a lap, the site shifts its order between
-- requests: the same lap must not turn into two rows
env.pageCount = 1
refreshNow()
local onePage = #s.laps

env.pageCount = 2
env.pageRepeats = true
refreshNow()
local withRepeats = #s.laps

env.pageRepeats = nil
refreshNow()
local withDistinct = #s.laps

check('a lap repeated on two pages is one row', withRepeats, onePage)
check('two pages of different laps are both there', withDistinct, onePage * 2)
env.pageCount = nil

-- 20d) one car group fails and the rest still arrive: a group is not the whole list
env.failCarsStartingWith = 'ac_car_51'   -- the second group of the split list
refreshNow()
check('a failing car group does not empty the list', #s.laps > 0, true)
check('the failing group is not in the list', s.status:find('error') == nil, true)

-- 20e) a client that takes even less than a group: the group has to be asked in
-- halves until the answers come, not written off as too long
env.failCarsStartingWith = nil
env.maxCarsPerQuery = 6
env.refusedCarQueries = 0
env.requests = {}
refreshNow()
local askedWithHalves = 0
for _, url in ipairs(env.requests) do
  if url:find('cars=') then askedWithHalves = askedWithHalves + 1 end
end
check('the client refused a group', env.refusedCarQueries > 0, true)
check('the list was asked in many small queries', askedWithHalves > 10, true)
check('halving still delivers rows', #s.laps > 0, true)
check('halving lost no group, so no group is reported lost', s.status:find('failed'), nil)
env.maxCarsPerQuery = nil

-- 20f) every group fails: the error text the game hands over is not utf-8, and it
-- has to reach the screen as readable text that names the query that died
env.failAllCarGroups = true
refreshNow()
check('all groups failing is an error', s.status:find('error') ~= nil, true)
check('the status stays printable ascii', s.status:find('[^%32-\126]'), nil)
check('the failing query is shown in Details', s.lastPath:find('lapstat', 1, true) ~= nil, true)
env.failAllCarGroups = nil

-- 20g) nothing anywhere: the status has to say why instead of guessing
env.emptyWithCars = true
env.emptyWithoutCars = true
refreshNow()
check('nothing anywhere: the list is empty', #s.laps, 0)
check('nothing anywhere: the reason is shown', s.status, 'no laps recorded on this track')

env.emptyStatistics = nil
env.emptyWithCars = nil
env.emptyWithoutCars = nil

-- 21) the Details block: what can be changed comes first, what it produced below,
-- and what it says about the query is in words rather than in a url
app.config.detailsOpen = true
refreshNow()

local function drawOrder()
  env.texts, env.events = {}, {}
  appScript.windowLaps()
  local at = {}
  for index, item in ipairs(env.texts) do
    if at[tostring(item.text)] == nil then at[tostring(item.text)] = index end
  end
  return at, env.texts
end

local function drawnTexts()
  local texts = {}
  for _, item in ipairs(env.texts) do texts[tostring(item.text)] = true end
  return texts
end

local at = drawOrder()
check('the text size comes first', at['delta text size'] ~= nil, true)
check('the address list is an input and comes before the output',
      at['addresses'] ~= nil and at['ac server'] ~= nil and
      at['addresses'] < at['ac server'], true)
check('the address choice comes before the output too',
      at['this server uses'] ~= nil and at['this server uses'] < at['ac server'], true)
checkNil('the old track / car row is gone', drawnTexts()['track / car'])

-- the stracker server is not part of a track query at all, so it is not shown
local inTrack = drawnTexts()
checkNil('the stracker server is hidden in a track scope', inTrack['stracker server'])
check('asking for names the track and every car',
      inTrack['every car on ' .. tostring(s.track)] ~= nil, true)

-- the query is described, not printed: the raw path is in the log
local shownRequest
for _, item in ipairs(env.texts) do
  if tostring(item.text):find('^lapstat') then shownRequest = tostring(item.text) end
end
check('the request is a description, not a url',
      shownRequest ~= nil and shownRequest:find('^lapstat  ·  track ') ~= nil, true)
check('the request does not print the long query',
      shownRequest ~= nil and shownRequest:find('cars=ac_car') == nil, true)

-- a list that had to be asked for in groups says how many queries it took
env.failCarsRequest = true
refreshNow()
shownRequest = nil
for _, item in ipairs(env.texts) do
  if tostring(item.text):find('^lapstat') then shownRequest = tostring(item.text) end
end
check('a split list says how many car queries it took',
      shownRequest ~= nil and shownRequest:find('car queries') ~= nil, true)
env.failCarsRequest = nil

-- the session scope is the one that filters by server, so the row is there
app.config.listScope = 'session'
app.config.listServer = 'SRV1'
refreshNow()
local inSession = drawOrder()
check('the stracker server is shown in the session scope',
      inSession['stracker server'] ~= nil, true)
check('the session asks for the session of that server',
      inSession['session of SRV1'] ~= nil, true)
check('the session query names the server',
      inSession['lapstat  ·  server SRV1'] ~= nil, true)

-- the field takes what is left of the window, so a second address is readable
local function widestField()
  local widest = 0
  for _, width in ipairs(env.itemWidths) do
    if width > widest then widest = width end
  end
  return widest
end

env.windowWidth, env.itemWidths = 320, {}
appScript.windowLaps()
local narrow = widestField()
env.windowWidth, env.itemWidths = 900, {}
appScript.windowLaps()
local wide = widestField()
check('a wider window gives the address field more room', wide > narrow, true)
check('the field follows the window, up to its minimum', narrow >= 240, true)
env.windowWidth = 320

-- the block ends before the filter: the filter belongs to the list, and the two
-- rows were touching without a rule between them
env.events = {}
appScript.windowLaps()
local referenceAt, filterAt, ruleBetween = nil, nil, false
for index, event in ipairs(env.events) do
  if event == 'text:reference lap' then referenceAt = index end
  if event == 'text:Filter' and filterAt == nil then filterAt = index end
  if event == 'rule' and referenceAt and filterAt == nil then ruleBetween = true end
end
check('the block ends with a rule before the filter',
      referenceAt ~= nil and filterAt ~= nil and ruleBetween, true)

-- a name the game does not report is said in words, not as a question mark
env.serverName = ''
refreshNow()
drawOrder()
check('an unreported server name is said in words',
      drawnTexts()['not reported by the game'] ~= nil, true)
env.serverName = 'SRV1'

print('')
print(string.format('%d checks, %d failures', checks, failures))
if failures > 0 then os.exit(1) end
