-- Stracker Delta: lap delta against a reference lap from a stracker server
--
-- Windows:
--   drive - time/speed delta and the reference lap time
--   laps  - stracker lap list and reference selection
--
-- Networking: modules/web.lua, site knowledge: modules/stracker.lua,
-- configured addresses: modules/addresses.lua, HTML parsing: modules/html.lua,
-- lap model: modules/lap.lua.
--
-- IMPORTANT: Assetto Corsa only loads the file whose name matches the app
-- folder name (StrackerDelta/StrackerDelta.lua). Renaming either of them
-- breaks the app silently: AC creates empty windows and draws nothing.

local DEBUG_FILE = 'apps/lua/StrackerDelta/debug.log'
local debugBuffer = nil

--- Writes to ac.log and to debug.log next to the app (readable after a session).
local function debugLog(text)
  pcall(function()
    if debugBuffer == nil then
      local existing = io.load(DEBUG_FILE)
      debugBuffer = (existing and (existing .. '\n') or '')
    end
    debugBuffer = debugBuffer .. os.date('%H:%M:%S') .. ' ' .. text .. '\n'
    local lines = 0
    for _ in debugBuffer:gmatch('[^\n]*') do lines = lines + 1 end
    if lines > 300 then debugBuffer = '(older lines dropped)\n' .. debugBuffer end
    io.save(DEBUG_FILE, debugBuffer)
  end)
  pcall(ac.log, '[Stracker Delta] ' .. text)
end

debugLog('file loaded, require done')

local stracker = require('modules.stracker')
local lap = require('modules.lap')
local addresses = require('modules.addresses')

local config = ac.storage{
  serverAddresses = '',      -- stracker addresses, comma separated, as typed
  serverBindings = '',       -- which address belongs to which AC server
  listServer = '',         -- '' = detect from AC
  listScope = 'session',   -- session | track | track_car
  autoRefresh = false,
  refreshSeconds = 60,
  detailsOpen = false,     -- diagnostics block in the list window
  alwaysFastest = false,   -- always take the fastest lap of the list
  hints = false,         -- field hints on hover, off until asked for
  textSizePx = 25,           -- delta text size in pixels (vector font)
  lastLapId = 0,           -- reference lap restored on the next start
}

-- At start the app always loads "Session - auto" and then picks a reference lap.
config.listScope = 'session'
config.listServer = ''

-- Note: ac.storage raises an error when reading a key that is not in the layout,
-- so only the keys above may be touched.

local state = {
  laps = {},
  status = '',
  busy = false,
  refreshQueued = false,
  addressRefusals = {},   -- addresses that just refused, and when

  page = 0,             -- kept for the future: the list is always fetched whole
  pages = 1,            -- how many pages the server has (diagnostics only)
  listToken = 0,        -- request counter: stale chains are dropped
  listVersion = 0,      -- grows with every new list, triggers the grid recalculation
  gridVersion = -1,     -- list version the column grid was computed for
  gridWidth = nil,      -- window width the grid was computed for
  grid = nil,           -- { offsets, width, widths }
  filter = '',          -- local search over the loaded list

  reference = nil,       -- { positions, speeds, times, meta }
  pendingLapid = nil,    -- lap that is currently being loaded
  address = nil,         -- stracker address in use
  addressReason = nil,   -- why that one was chosen
  addressText = nil,     -- what the user types in Details
  server = nil,          -- stracker server id in use
  serverReason = nil,    -- how it was detected
  track = nil,           -- track id in stracker terms
  lastPath = nil,        -- last requested address
  updatedAt = nil,       -- time of the last successful list load
  lastRequestRaw = false, -- lastPath is a url of a failed request, not a summary
  acServerName = nil,

  clock = 0,             -- seconds since app start
  lapStart = nil,
  lapActive = false,
  lapSource = '?',
  lastPosition = nil,

  lastRequest = 0,
}

-- The address field is edited in place, so the app keeps a live copy of it and
-- writes it back to the settings as soon as it changes.
state.addressText = config.serverAddresses or ''

-- ---------------------------------------------------------------------------
-- Colors and helpers
-- ---------------------------------------------------------------------------

local WHITE = rgbm.colors.white
local FAST = rgbm.colors.lime
local SLOW = rgbm.colors.red
local YELLOW = rgbm.colors.yellow
local DIM = rgbm.colors.silver
-- dimmed column text: DIM is already used by the table headers
local SUBTLE = rgbm(0.60, 0.60, 0.60, 1)
-- The stripes tell where one row ends and the next begins. They only started
-- showing up once the rectangles were drawn in the right coordinate system, and
-- at the alpha they were written with they fought the white text: the number
-- that reads the table is the text, so the stripes stay as a hint and no more.
local ZEBRA = rgbm(1, 1, 1, 0.04)
local HOVER = rgbm(1, 1, 1, 0.07)
local TARGET_BG = rgbm(0.20, 0.30, 0.42, 0.55)
local TARGET_BAR = rgbm(0.40, 0.72, 1.00, 1)
local ROW_ALPHA = 0.55

-- status dot colour: YELLOW for anything in progress or worth noticing,
-- SLOW for errors only, and nowhere else
local PHASE_COLOR = {
  loading = YELLOW,
  error = SLOW,
  empty = YELLOW,
  ready = DIM,
}

-- The status marker itself: U+2022 BULLET written as utf-8 bytes, because the
-- Lua in Assetto Corsa is 5.1 and has no \u escapes.
local STATUS_MARK = '\226\128\162'

-- auto refresh intervals: the ones on screen are the ones we use
local INTERVALS = { 30, 60, 120, 300 }
local INTERVALS_LABEL = { '30s', '60s', '2m', '5m' }

-- How long an address that has just refused us is left alone. The timer stops
-- asking for a while; the Refresh button asks at once, because that is a person
-- saying "try again", and editing the list forgets the refusal altogether.
local ADDRESS_RETRY_AFTER = 120

-- ---------------------------------------------------------------------------
-- Cache of the last reference lap
-- ---------------------------------------------------------------------------

local CACHE_INDEX = 'apps/lua/StrackerDelta/cache_index.txt'
local CACHE_LAP = 'apps/lua/StrackerDelta/cache_lap.csv'
local CACHE_FIELDS = { 'lapid', 'lapTimeText', 'driver', 'car', 'track', 'server', 'date' }

-- currentCar is declared further down but used here: without a prototype
-- Lua turns the call into a global read and it hits nil
local currentCar

--- Key of the list the cache is valid for: same address, scope, server, track
--- and car. The list always comes from the network (all pages at once),
--- the cache only decides what to show while the profile is downloading.
local function listCacheKey()
  return table.concat({
    state.address or '', config.listScope or 'session', config.listServer or '',
    state.track or '', currentCar() or '',
  }, '|')
end

local function clean(value)
  return (tostring(value or ''):gsub('[\t\r\n]', ' '))
end

--- Text that is safe to draw and to put in the log.
--- A game side error arrives in the system code page, and its bytes turn into
--- question marks or nonsense on screen. Anything not printable ascii becomes ?.
local function plain(value)
  local text = clean(value):gsub('[^\32-\126]', '?'):gsub('%?{3,}', '??')
  if #text > 150 then text = text:sub(1, 150) .. '...' end
  return text
end

-- The game hands its error text over in the system code page, where a Russian
-- Windows says "не удалось подключиться" in bytes that cannot be drawn: on screen
-- it was a row of question marks. The number behind "code:" is worth more than
-- those words: it is the Windows web error, and it means the same thing in every
-- language, so the message is built from it instead.
local WEB_ERRORS = {
  [122]   = 'the query was too long for the game',
  [10060] = 'timed out',
  [10061] = 'connection refused',
  [12002] = 'timed out',
  [12007] = 'connection reset',
  [12029] = 'could not connect',
  [12130] = 'connection refused',
  [12152] = 'invalid server response',
  [12156] = 'connection aborted',
}

--- What to tell about a failure, in words that can be drawn.
local function reasonText(result)
  local message = tostring((result and result.error) or 'no data')
  local code = message:match('code:%s*(%d+)')

  if code then
    local known = WEB_ERRORS[tonumber(code)]
    return plain(known or ('game web error ' .. code)) .. ' (code ' .. code .. ')'
  end
  -- no code: the game message is worth showing only when it is already ascii,
  -- like the HTTP status this app writes itself
  if message:find('^[\32-\126]+$') then return plain(message) end
  return 'the game could not reach the server'
end

--- What to tell when an address does not answer as a stracker site. The site
--- serves its own main page for any path it does not know, so the answer is the
--- only thing that can say whether an address is the site: "HTTP 500" on its own
--- says nothing to a person who only typed a wrong link. The address itself is not
--- repeated here, it is right above in the field.
local function siteError(result)
  return 'that address does not answer as a stracker site (' .. reasonText(result) .. ')'
end

--- Which request a failure belongs to. The path is what tells one query from
--- another, the length is what tells a refused long url from a bad track name.
local function urlHint(url)
  if not url then return '' end
  local path = tostring(url):match('^[a-z]+://[^/]+(.*)$') or tostring(url)
  if #path > 90 then path = path:sub(1, 90) .. '...' end
  return ' [' .. tostring(#tostring(url)) .. ' B: ' .. plain(path) .. ']'
end

--- A failure in a form that is safe to show and safe to log.
local function errorText(result)
  return reasonText(result) .. urlHint(result and result.url)
end

local function saveLapCache(key, meta, positions, speeds, times)
  local header = { 'key=' .. clean(key) }
  for _, field in ipairs(CACHE_FIELDS) do
    header[#header + 1] = field .. '=' .. clean(meta[field])
  end
  pcall(io.save, CACHE_INDEX, table.concat(header, '\n') .. '\n')
  pcall(io.save, CACHE_LAP, lap.toCache(positions, speeds, times))
end

--- Profile from disk when it belongs to the same list and the same lap.
local function loadLapCache(key, lapid)
  local index = io.load(CACHE_INDEX)
  if not index then return nil end

  local cachedKey, cachedLapid
  for line in index:gmatch('[^\r\n]+') do
    local name, value = line:match('^([^=]+)=(.*)$')
    if name == 'key' then cachedKey = value
    elseif name == 'lapid' then cachedLapid = tonumber(value) end
  end

  if cachedKey ~= key or not cachedLapid or cachedLapid ~= lapid then return nil end

  -- file fields arrive as strings: lapid has to stay a number, otherwise it
  -- never matches the lapid of a row and the lap shows up as "not in list"
  local meta = { lapid = cachedLapid }
  for line in index:gmatch('[^\r\n]+') do
    local name, value = line:match('^([^=]+)=(.*)$')
    for _, field in ipairs(CACHE_FIELDS) do
      if name == field and value ~= '' then meta[field] = value end
    end
  end

  local positions, speeds, times = lap.fromCache(io.load(CACHE_LAP))
  if not positions then return nil end

  -- the second pass above overwrote the lapid with a string, back to a number
  meta.lapid = cachedLapid

  debugLog('cache hit: lap ' .. tostring(lapid) .. ' from disk')
  return { positions = positions, speeds = speeds, times = times, meta = meta }
end

local function log(...)
  local parts = {}
  for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  debugLog(table.concat(parts, ' '))
end

local function deltaColor(value)
  if not value then return DIM end
  if value < 0 then return FAST end
  if value > 0 then return SLOW end
  return WHITE
end

--- For speed the signs are inverted: more is better.
local function speedColor(value)
  if not value then return DIM end
  if value > 0 then return FAST end
  if value < 0 then return SLOW end
  return WHITE
end

local function safeNumber(fn, ...)
  local ok, value = pcall(fn, ...)
  if ok and type(value) == 'number' then return value end
  return nil
end

local function safeString(fn, ...)
  local ok, value = pcall(fn, ...)
  if ok and type(value) == 'string' and value ~= '' then return value end
  return nil
end

-- ---------------------------------------------------------------------------
-- Car state
-- ---------------------------------------------------------------------------

local function carPosition()
  local car = ac.getCar(0)
  if not car then return nil end
  local value = safeNumber(function() return car.normalizedSplinePosition end)
  if value then return value end
  value = safeNumber(function() return ac.worldCoordinateToTrackProgress(car.position) end)
  if value and value >= 0 then return value end
  return nil
end

local function carSpeed()
  local value = safeNumber(ac.getCarSpeedKmh, 0)
  if value then return value end
  local car = ac.getCar(0)
  if car then value = safeNumber(function() return car.speedKmh end) end
  return value
end

local function currentTrack()
  local full = safeString(function() return ac.getTrackFullID('-') end)
  if full then return full end
  return safeString(ac.getTrackID)
end

local function currentLayout()
  return safeString(ac.getTrackLayout) or ''
end

currentCar = function()
  return safeString(ac.getCarID, 0)
end

local function acServerName()
  return safeString(ac.getServerName) or '?'
end

--- Current lap time in seconds.
--- Primary source is ac.StateCar.lapTimeMs (exact time since the start/finish line).
local function currentLapTime()
  local car = ac.getCar(0)
  if car then
    local milliseconds = safeNumber(function() return car.lapTimeMs end)
    if milliseconds and milliseconds > 0 then return milliseconds / 1000 end
  end
  if state.lapActive and state.lapStart then return state.clock - state.lapStart end
  return nil
end

--- Fallback lap detection: a position rollback means the line was crossed.
local function trackLapFallback(position)
  if not position then return end
  local previous = state.lastPosition
  state.lastPosition = position
  if not previous then return end
  if previous > 0.5 and (previous - position) > 0.5 then
    state.lapStart = state.clock
    state.lapActive = true
  end
end

do
  local ok = pcall(function()
    ac.onTrackPointCrossed(0, 0, function()
      state.lapStart = state.clock
      state.lapActive = true
    end)
  end)
  state.lapSource = ok and 'line' or 'wrap'
  if not ok then debugLog('onTrackPointCrossed unavailable, using fallback') end
end

-- ---------------------------------------------------------------------------
-- Lap list source
-- ---------------------------------------------------------------------------

--- One dropdown: three scopes without a server + one entry per stracker server.
--- "Session - auto" is always available, otherwise there is no way back to it
--- once a server was picked by hand.
local function listChoices()
  local choices = {
    { label = 'Session - auto', scope = 'session', server = '' },
    { label = 'This track', scope = 'track', server = '' },
    { label = 'Track + car', scope = 'track_car', server = '' },
  }
  for _, entry in ipairs(stracker.serversAt(state.address) or {}) do
    choices[#choices + 1] = {
      label = 'Session - ' .. entry.id,
      scope = 'session',
      server = entry.id,
    }
  end
  return choices
end

local function selectedChoice(choices)
  for index, choice in ipairs(choices) do
    if choice.scope == config.listScope and choice.server == config.listServer then
      return index
    end
  end
  return 1
end

-- ---------------------------------------------------------------------------
-- stracker requests
-- ---------------------------------------------------------------------------

-- declared in advance: refresh() calls it from inside its own callback
local loadLap
local requestLaps

-- ---------------------------------------------------------------------------
-- Which address to talk to
-- ---------------------------------------------------------------------------

--- The address to use for this AC server, or nil when it has to be looked for.
--- A remembered address wins, a single configured address needs no guessing.
local function knownAddress(acName, configured)
  local remembered = addresses.lookup(addresses.parseBindings(config.serverBindings), acName)
  for _, address in ipairs(configured) do
    if address == remembered then return address, 'remembered' end
  end
  if #configured == 1 then return configured[1], 'the only one configured' end
  return nil
end

local function useAddress(acName, address, reason)
  config.serverBindings = addresses.serializeBindings(
    addresses.bind(addresses.parseBindings(config.serverBindings), acName, address))
  state.address = address
  state.addressReason = reason
  debugLog('address: ' .. tostring(address) .. ' (' .. tostring(reason) .. ')')
end

--- Asks every configured address for its server list and takes the first one
--- that knows the AC server. When none does, the first address of the list is
--- used, and remembered too, so the probing does not run again every session.
local function probeAddresses(acName, configured, index, done)
  local address = configured[index]

  if not address then
    local fallback = configured[1]
    debugLog('no address matched "' .. tostring(acName) .. '", using the first one')
    return done(fallback, 'no match, first in the list')
  end

  state.status = 'checking address ' .. index .. '/' .. #configured .. '...'
  stracker.fetchServers(address, function(result)
    local matched
    if result.ok and result.servers then matched = stracker.matchServer(acName, result.servers, nil) end
    if matched then
      return done(address, 'matches ' .. tostring(matched))
    end
    probeAddresses(acName, configured, index + 1, done)
  end)
end

-- ---------------------------------------------------------------------------

--- reasonOverride says why, when the automatic reason would be wrong: a pick by
--- hand goes through the same flow but has to keep its own explanation.
local function refresh(reasonOverride, manual)

  if state.busy then state.refreshQueued = true return end

  local configured = addresses.parseList(state.addressText)
  if #configured == 0 then
    state.status = 'no stracker address set - add one in Details'
    config.detailsOpen = true   -- there is no other way in, so show it
    return
  end

  local acName = acServerName()
  state.acServerName = acName
  state.busy = true

  local function proceed(address, reason)
    useAddress(acName, address, reasonOverride or reason)

    -- the server list of that address is needed for detection and for the dropdown
    local servers = stracker.serversAt(address)
    if not servers or #servers == 0 then
      -- An address that has just refused us is asked again by hand, but not by the
      -- timer: a list that cannot work would otherwise be asked for once a minute
      -- for the whole session, and the status would sit on "detecting" between
      -- the attempts instead of saying what is wrong.
      local refused = state.addressRefusals[address]
      if refused and not manual and state.clock - refused.at < ADDRESS_RETRY_AFTER then
        state.busy = false
        state.status = refused.status
        return
      end

      state.status = 'detecting servers...'
      stracker.fetchServers(address, function(result)
        state.busy = false
        if result.ok and result.servers and #result.servers > 0 then
          state.addressRefusals[address] = nil
          requestLaps(address)
        else
          local status = 'error: ' .. siteError(result)
          state.addressRefusals[address] = { status = status, at = state.clock }
          state.status = status
          debugLog('fetchServers failed: ' .. errorText(result))
        end
      end)
      return
    end

    state.busy = false
    requestLaps(address)
  end

  local known, reason = knownAddress(acName, configured)
  if known then return proceed(known, reason) end

  probeAddresses(acName, configured, 1, function(address, probeReason)
    state.busy = false
    proceed(address, probeReason)
  end)
end

--- Second half of a refresh: scope, server id, track, then the list itself.
requestLaps = function(address)

  local acName = acServerName()
  local servers = stracker.serversAt(address)

  local scope = config.listScope or 'session'
  local server = config.listServer
  local fellBack = false

  -- the server is only needed for the "session" scope: track scopes take everything
  if scope ~= 'session' then
    server = nil
    state.serverReason = 'not used in this scope'
  elseif server == '' then
    local matched, reason = stracker.matchServer(acName, servers, nil)
    if matched then
      server = matched
      state.serverReason = reason
      debugLog('server detected: ' .. matched .. ' (' .. tostring(reason) .. ') from "' .. acName .. '"')
    else
      -- offline hotlapping: there is no server and the only scope that works is
      -- the track list. Switch over without making a fuss.
      scope = 'track'
      config.listScope = 'track'
      fellBack = true
      state.serverReason = 'not recognised'
      debugLog('server not recognised: "' .. acName .. '" - switching to this track')
    end
  else
    state.serverReason = 'by hand'
  end

  local track = stracker.resolveTrack(currentTrack(), currentLayout(), stracker.tracksAt(address))

  state.server = server
  state.track = track
  state.busy = true
  state.lastRequest = state.clock
  state.status = 'loading laps...'
  -- mention the switch once: from then on it is just the current scope
  if fellBack and not state.fallbackNoted then
    state.fallbackNoted = true
    state.status = 'AC server not recognised - using This track'
  end

  state.listToken = state.listToken + 1
  local token = state.listToken

  stracker.listLaps({
    address = address,
    mode = scope,
    server = server,
    track = track,
    car = currentCar(),
    onPage = function(done, total)
      if token == state.listToken then
        state.status = 'loading page ' .. done .. '/' .. total .. '...'
      end
    end,
    isCancelled = function() return token ~= state.listToken end,
  }, function(result)
    if token ~= state.listToken then return end
    state.busy = false
    -- a failed request has no path of its own, but the url it died on is what
    -- tells one query from another in Details
    state.lastPath = result.path or result.url
    state.lastRequestRaw = not result.ok
    if result.silent then return end
    if not result.ok then
      state.status = 'error: ' .. reasonText(result)
      config.detailsOpen = true   -- on error the reason has to be visible right away
      debugLog('listLaps failed: ' .. errorText(result))
      if state.refreshQueued then
        state.refreshQueued = false
        refresh()
      end
      return
    end

    state.laps = result.rows
    state.listVersion = state.listVersion + 1
    state.pages = result.pager and result.pager.pages or 1
    local ok, stamp = pcall(os.date, '%H:%M:%S')
    state.updatedAt = ok and stamp or nil
    if #result.rows == 0 then
      -- result.note says why: no cars known, nothing recorded, and so on
      state.status = result.note or 'no laps for this combination - try another entry'
    else
      state.status = 'laps: ' .. #result.rows
    end
    debugLog('list: ' .. tostring(#result.rows) .. ' laps' ..
             (state.pages > 1 and (', ' .. tostring(state.pages) .. ' pages merged') or '') ..
             ', ' .. tostring(result.path))

    -- reference lap: the "always fastest" checkbox wins over the manual pick
    local target, force = nil, false
    if config.alwaysFastest then
      target = result.rows[1]
      force = true          -- the very same lap is reloaded as well
    elseif not state.autoLoaded then
      state.autoLoaded = true
      if config.lastLapId and config.lastLapId > 0 then
        for _, candidate in ipairs(result.rows) do
          if candidate.lapid == config.lastLapId then
            target = candidate
            debugLog('auto load: previous lap ' .. tostring(config.lastLapId))
            break
          end
        end
      end
      if not target then
        target = result.rows[1]
        debugLog('auto load: fastest lap ' .. tostring(target and target.lapid))
      end
    end

    if target then
      -- same list as before: show the profile from disk instead of waiting for network
      local cached = loadLapCache(listCacheKey(), target.lapid)
      if cached then
        state.reference = cached
        state.status = 'cached ' .. tostring(cached.meta.lapTimeText or '?') .. ' - ' ..
                       tostring(cached.meta.driver or '')
      end
      loadLap(target, force)
    end

    if state.refreshQueued then
      state.refreshQueued = false
      refresh()
    end
  end)
end

--- Loads a lap. force=true reloads it even when it is already loaded:
--- that is how the "always fastest" checkbox and the cache refresh work.
loadLap = function(row, force)
  if state.busy then return end
  -- an already loaded lap is not fetched again: a click on its own row would
  -- otherwise hit the network every time and blink the indicator
  local meta = state.reference and state.reference.meta
  if not force and meta and meta.lapid and meta.lapid == row.lapid then return end

  state.busy = true
  state.pendingLapid = row.lapid
  state.status = 'loading lap ' .. tostring(row.timeText) .. '...'

  stracker.fetchLap(state.address, row.lapid, function(result)
    state.busy = false
    state.pendingLapid = nil
    if not result.ok then
      state.status = 'error: ' .. reasonText(result)
      config.detailsOpen = true   -- on error the reason has to be visible right away
      log('fetchLap failed: ' .. errorText(result))
      return
    end

    local info = result.info
    local positions, speeds, times = lap.build(info.points, info.lapTime)
    state.reference = { positions = positions, speeds = speeds, times = times, meta = info }
    state.status = 'loaded ' .. tostring(info.lapTimeText) .. ' - ' .. tostring(info.driver)
    config.lastLapId = info.lapid or row.lapid or 0
    saveLapCache(listCacheKey(), info, positions, speeds, times)

    -- the whole profile is saved next to the app: it can be opened
    -- and compared with the reference by hand
    pcall(io.save, 'apps/lua/StrackerDelta/last_lap.csv', lap.toCsv(positions, speeds, times))

    log('lap loaded: ' .. tostring(info.lapid) .. ' ' .. tostring(info.lapTimeText) ..
        ' ' .. tostring(info.driver) .. ' ' .. tostring(info.track) ..
        ' points: ' .. #positions)
  end)
end

--- Tracks are compared by base name: tmm_lausitzring and tmm_lausitzring-layout_oval are the same track.
local function sameTrack(a, b)
  if not a or not b then return true end
  if a == b then return true end
  local function base(name)
    return (name:match('^(.-)%-[^%-]+$') or name)
  end
  return base(a) == base(b)
end

-- ---------------------------------------------------------------------------
-- Update loop
-- ---------------------------------------------------------------------------

function script.update(dt)
  local step = dt
  if step > 2 then step = step / 1000 end   -- in case dt arrives in milliseconds
  state.clock = state.clock + (step or 0)

  -- load "Session - auto" right after the app starts
  if not state.started then
    state.started = true
    debugLog('starting up, loading Session - auto')
    refresh()
  end

  if not state.updateSeen then
    state.updateSeen = true
    debugLog('script.update called, dt=' .. tostring(dt))
  end

  -- the fallback lap timer must run regardless of window visibility
  if state.lapSource == 'wrap' then trackLapFallback(carPosition()) end

  if config.autoRefresh and state.clock - state.lastRequest > config.refreshSeconds then
    refresh()
  end
end

--- Window wrapper: writes failures to debug.log instead of showing an empty window.
local function safeDraw(name, draw)
  if not state['drew_' .. name] then
    state['drew_' .. name] = true
    debugLog('window ' .. name .. ': first draw')
  end
  local ok, err = pcall(draw)
  if not ok then
    if not state['drawError_' .. name] then
      state['drawError_' .. name] = true
      debugLog('window ' .. name .. ': ERROR ' .. tostring(err))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Window: delta
-- ---------------------------------------------------------------------------

--- The delta window is drawn by hand, CMRT style: local window coordinates,
--- a vector font (DWrite) and an arbitrary text size in pixels.

local TITLE_BAR = 4         -- the title bar is hidden by NO_TITLE_BAR, the offset is only for the backdrop
local PAD = 10
local COLUMN = 130          -- column of the TIME/SPEED pair
local BUTTON = 24           -- square lap list button
local RESIZE_ZONE = 14      -- corner that drags the window size
local WINDOW_DRIVE = 'drive'

local DWRITE_FONT = 'DeltaUI:content/fonts/segoeuib.ttf'
local BTN_BG = rgbm(0.16, 0.16, 0.16, 0.85)
local BTN_BG_HOVER = rgbm(0.34, 0.34, 0.34, 0.95)

-- the field hints button when they are on: a painted frame reads as "active" in a
-- way a word next to it would not, and the toolbar does not need another word in it
local HINTS_ON_BG = rgbm(0.34, 0.09, 0.09, 0.95)
local HINTS_ON_BG_HOVER = rgbm(0.48, 0.13, 0.13, 1.00)
local HINTS_ON_FG = rgbm(1.00, 0.74, 0.74, 1.00)

local function paintText(str, color, size, x, y)
  ui.pushDWriteFont(DWRITE_FONT)
  ui.dwriteDrawText(str, size, vec2(x, y), color)
  ui.popDWriteFont()
end

local function textWidth(str, size)
  return ui.measureDWriteText(str, size).x
end

--- Icon in local window coordinates: ui.icon24() draws a widget at the cursor,
--- so window coordinates are converted to screen ones with ui.windowPos().
local function paintIcon(iconId, size, tint, x, y)
  ui.setCursorScreenPos(ui.windowPos() + vec2(x, y))
  ui.icon24(iconId, size, tint)
end

--- Square icon button with a tooltip. Returns true on click.
local function paintIconButton(iconId, x, y, size, tooltip)
  ui.drawRectFilled(vec2(x, y), vec2(x + size, y + size), BTN_BG)

  -- hit test after drawing
  local mouse = ui.mouseLocalPos()
  local inside = mouse.x >= x and mouse.x <= x + size and
                 mouse.y >= y and mouse.y <= y + size
  if inside then
    ui.drawRectFilled(vec2(x, y), vec2(x + size, y + size), BTN_BG_HOVER)
    ui.tooltip(vec2(12, 6), function()
      ui.textColored(tooltip, WHITE)
    end)
  end

  paintIcon(iconId, size - 10, WHITE, x + 5, y + 5)
  return inside and ui.mouseClicked(ui.MouseButton.Left)
end

local function drawDriveManual()
  local valueSize = config.textSizePx
  local labelSize = math.max(11, math.floor(valueSize * 0.5))
  local width = ui.windowSize().x

  local position = carPosition()
  local speed = carSpeed()
  local lapTime = currentLapTime()
  local reference = state.reference

  local deltaTime, deltaSpeed
  if reference and position and speed then
    local referenceSpeed = lap.interpolate(position, reference.positions, reference.speeds)
    local referenceTime = lap.interpolate(position, reference.positions, reference.times)
    deltaSpeed = speed - referenceSpeed
    if lapTime then deltaTime = lapTime - referenceTime end
  end

  local timeText = deltaTime and lap.formatTimeDelta(deltaTime) or '--'
  local speedText = deltaSpeed and lap.formatSpeedDelta(deltaSpeed) or '--'

  local timeLabel, targetColor
  if reference then
    local meta = reference.meta
    timeLabel = tostring(meta.lapTimeText)
    -- not highlighted by colour: the same grey as the rest of the line,
    -- it only turns red when the reference lap is from another track
    targetColor = sameTrack(meta.track, state.track or currentTrack()) and DIM or SLOW
  else
    timeLabel = '--:--.---'
    targetColor = DIM
  end

  -- lap list button: an icon instead of text, in the top right corner
  local buttonY = TITLE_BAR

  -- label row: TIME with the target time right after it, SPEED, button
  local labelY = buttonY + math.floor((BUTTON - labelSize) / 2)
  local x = PAD
  paintText('TIME', DIM, labelSize, x, labelY)
  x = x + textWidth('TIME', labelSize) + 14
  paintText(timeLabel, targetColor, labelSize, x, labelY)
  x = x + textWidth(timeLabel, labelSize)

  local speedX = PAD + COLUMN
  paintText('SPEED', DIM, labelSize, speedX, labelY)

  -- delta row
  local valueY = labelY + labelSize + 6
  paintText(timeText, deltaColor(deltaTime), valueSize, PAD, valueY)
  paintText(speedText, speedColor(deltaSpeed), valueSize, speedX, valueY)

  -- content width from the text: the window can be narrowed without the text moving
  local labelRight = PAD + textWidth('TIME', labelSize) + 14 + textWidth(timeLabel, labelSize)
  local valuesRight = PAD + COLUMN + math.max(textWidth(speedText, valueSize),
                                               textWidth(timeText, valueSize))
  local contentWidth = math.max(labelRight, valuesRight, PAD * 2 + BUTTON) + PAD + BUTTON + 12

  -- the button always stays inside the window: if it is narrower than the content,
  -- anchoring it to the content width pushes it off the right edge and clips it
  local buttonX = math.max(PAD, width - PAD - BUTTON)
  state.buttonRect = { x = buttonX, y = buttonY, w = BUTTON, h = BUTTON }
  local clicked = paintIconButton(ui.Icons.List, buttonX, buttonY, BUTTON, 'Lap times')
  if clicked then
    if ac.isWindowOpen('laps') then
      ac.setWindowOpen('laps', false)
    else
      ac.setWindowOpen('laps', true)
      if #state.laps == 0 and not state.busy then refresh() end
    end
  end

  local bottom = math.max(valueY + valueSize, buttonY + BUTTON)
  -- the height follows the content strictly: an empty band under invisible text
  -- looks like a hole in the HUD, and the status lives in the list window anyway
  return contentWidth, bottom + PAD
end

--- ac.accessAppWindow() expects the full window name IMGUI_LUA_<app>_<id>,
--- so the window is looked up by id in ac.getAppWindows(): the app name
--- is ours to change in the manifest, the window id is stable.
local driveAccessor = nil
local function driveWindow()
  if driveAccessor then
    if driveAccessor:valid() then return driveAccessor end
    driveAccessor = nil
  end

  local ok, windows = pcall(function() return ac.getAppWindows() end)
  if not ok or type(windows) ~= 'table' then return nil end

  for _, window in ipairs(windows) do
    local name = type(window) == 'table' and (window.id or window.name) or tostring(window)
    if type(name) == 'string' and name:sub(-6) == '_' .. WINDOW_DRIVE then
      local okA, accessor = pcall(function() return ac.accessAppWindow(name) end)
      if okA and accessor and accessor:valid() then
        driveAccessor = accessor
        debugLog('window accessor: ' .. name)
        return accessor
      end
    end
  end
  return nil
end

--- Without a title bar there is nothing to grab, so the window drags itself.
--- ui.setNextWindowPosition() does not work here: it applies to the next
--- window to open, which would move the lap list window instead.
local function handleWindowDrag()
  local mouse = ui.mouseLocalPos()
  local size = ui.windowSize()
  local inside = mouse.x >= 0 and mouse.y >= 0 and
                 mouse.x <= size.x and mouse.y <= size.y
  -- a click on the list button must not drag the window
  local button = state.buttonRect
  local onButton = button and
                   mouse.x >= button.x and mouse.x <= button.x + button.w and
                   mouse.y >= button.y and mouse.y <= button.y + button.h
  -- the resize corner is left to the system
  local onResizeCorner = inside and mouse.x >= size.x - RESIZE_ZONE and
                                      mouse.y >= size.y - RESIZE_ZONE

  if ui.mouseClicked(ui.MouseButton.Left) then
    state.dragArmed = inside and not onResizeCorner and not onButton
  end
  if not state.dragArmed then return end

  if not ui.isMouseDragging(ui.MouseButton.Left, true) then
    state.dragArmed = false
    return
  end

  local delta = ui.mouseDragDelta(ui.MouseButton.Left)
  if delta.x == 0 and delta.y == 0 then return end

  local accessor = driveWindow()
  if accessor then
    accessor:move(accessor:position() + delta)
  else
    state.dragArmed = false
    if not state.dragWarned then
      state.dragWarned = true
      debugLog('no app window accessor: window cannot be dragged by mouse')
    end
  end
end

local function drawDrive()
  local originX, originY = ui.getCursorX(), ui.getCursorY()
  local contentWidth, height = drawDriveManual()
  ui.setCursorX(originX)
  ui.setCursorY(originY)
  ui.dummy(vec2(contentWidth, height))
  -- after drawing: a click on the button has to stay a click, not the start of a drag
  handleWindowDrag()
end

function script.windowDrive()
  safeDraw('drive', drawDrive)
end

-- ---------------------------------------------------------------------------
-- Window: lap list
-- ---------------------------------------------------------------------------

--- Row of the loaded reference lap in the current list: returns the index and the row.
local function referenceRow()
  local meta = state.reference and state.reference.meta
  if not meta or not meta.lapid then return nil end
  for index, row in ipairs(state.laps) do
    if row.lapid == meta.lapid then return index, row end
  end
  return nil
end

--- Local search over the loaded list: every word of the query has to be
--- found in the driver name or in the car ("rowan gt40" -> Rowan Keene / ..._gt40_mk2).
local function filteredRows()
  local filter = (state.filter or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if filter == '' then return state.laps end

  local tokens = {}
  for token in filter:gmatch('%S+') do tokens[#tokens + 1] = token:lower() end

  local rows = {}
  for _, row in ipairs(state.laps) do
    local haystack = ((row.driver or '') .. ' ' .. (row.car or '')):lower()
    local matches = true
    for _, token in ipairs(tokens) do
      if not haystack:find(token, 1, true) then
        matches = false
        break
      end
    end
    if matches then rows[#rows + 1] = row end
  end
  return rows
end

--- Phase of the current operation: it decides the status dot colour.
local function listPhase()
  if state.busy then return 'loading' end
  if state.status:sub(1, 5) == 'error' then return 'error' end
  if #state.laps == 0 then return 'empty' end
  return 'ready'
end

--- One line instead of four: a dot and a message about the current state.
--- The toolbar already has its own Refresh button, repeating it here is pointless.
--- matchInfo describes the result of the local search.
local function drawStatus(matchInfo)
  local phase = listPhase()
  local text = state.status
  if matchInfo and #state.laps > 0 then
    if matchInfo.count == 0 then
      text = 'no matches for "' .. matchInfo.filter .. '"'
      phase = 'empty'
    elseif matchInfo.count ~= #state.laps then
      text = matchInfo.count .. ' of ' .. #state.laps .. ' match'
    end
  end
  local color = PHASE_COLOR[phase]

  -- The marker is a character in the text stream rather than a filled rectangle:
  -- ui.drawRectFilled() and ui.cursorScreenPos() do not agree with each other in
  -- this build, and the rectangle landed somewhere else on the screen as soon as
  -- the window was moved. Text and widgets always stay where the cursor is.
  local startX, startY = ui.getCursorX(), ui.getCursorY()
  ui.textColored(STATUS_MARK, color)

  ui.setCursorX(startX + 13)
  ui.setCursorY(startY)
  ui.textColored(text, color)
  ui.newLine()
end

-- The Details block has a fixed column for its labels, so the value of a field
-- starts there. Everything that has to fit next to the labels goes to
-- VALUE_COLUMN; a field that has to fill the window takes what is left of it.
local VALUE_COLUMN = 126
local VALUE_MARGIN = 14
local MIN_FIELD_WIDTH = 240

local function fieldWidth()
  local size = ui.windowSize()
  local width = (size and size.x or 640) - VALUE_COLUMN - VALUE_MARGIN
  return math.max(MIN_FIELD_WIDTH, width)
end

--- Line inside the Details block: label on the left, value on a fixed column.
--- tail is a short explanation, drawn after the value in a dimmer colour.
local function detailRow(label, value, color, tail)
  ui.newLine()
  ui.setCursorX(12)
  ui.textColored(label, DIM)
  ui.sameLine()
  ui.setCursorX(VALUE_COLUMN)
  local text = tostring(value or '-'):gsub('^%s+', '')
  ui.textColored(text, color or SUBTLE)
  if tail and tail ~= '' then
    ui.sameLine()
    ui.setCursorX(VALUE_COLUMN + ui.measureText(text).x + 10)
    ui.textColored(tail, DIM)
  end
end

--- A thin line between what can be changed and what it produced.
--- ui.separator() draws itself in the text stream, so it cannot drift away
--- from the rows it belongs to the way an absolute rectangle did.
local function drawDetailsSeparator()
  ui.newLine()
  ui.separator()
  ui.newLine()
end

--- What the app is asking the site for, in words.
--- The scope decides it, not the other way round: the list may well have been
--- switched to a track because no server was recognised, and then the track is
--- what is being asked for.
local function askingFor()
  local track = state.track or currentTrack() or '?'
  local scope = config.listScope or 'session'
  if scope == 'track' then return 'every car on ' .. track end
  if scope == 'track_car' then return track .. '  ·  ' .. tostring(currentCar() or '?') end
  return state.server and ('session of ' .. tostring(state.server)) or 'every session'
end

--- The last query in words: what was asked and how much of it.
--- The raw path is long, repeats itself for every page and says nothing at a
--- glance, so it stays in the log. A request that failed is the one case where
--- the query itself is the interesting part, and then it is shown as it went.
local function requestSummary()
  if not state.lastPath then return nil end
  if state.lastRequestRaw then return state.lastPath end

  local scope = config.listScope or 'session'
  local parts = { 'lapstat' }
  if scope == 'session' then
    parts[#parts + 1] = state.server and ('server ' .. tostring(state.server)) or 'all servers'
  else
    parts[#parts + 1] = 'track ' .. tostring(state.track or currentTrack() or '?')
    if scope == 'track_car' then
      parts[#parts + 1] = 'car ' .. tostring(currentCar() or '?')
    end
  end

  -- a list the site paginates says how many pages had to be walked
if state.pages > 1 then
    parts[#parts + 1] = tostring(state.pages) .. ' pages'
  end
  return table.concat(parts, '  ·  ')
end

--- Tooltip for the control that was just drawn.
--- The game shows it while the mouse is over that control. What goes in it is
--- what cannot be guessed from the label: what to type, what the switch changes,
--- which of several things a list is. One line or several.
--- Must be called right after the control, while it is still the last one drawn.
--- Hints are off until the user asks for them: useful once in a while, in the way
--- the rest of the time. always is for the control that turns them on, which
--- cannot explain itself otherwise.
local function tooltip(text, always)
  if not always and not config.hints then return end
  if not ui.itemHovered() then return end
  ui.tooltip(function()
    if type(text) == 'table' then
      for _, line in ipairs(text) do ui.text(line) end
    else
      ui.text(text)
    end
  end)
end

--- Field hints on and off, next to the diagnostics block.
---
--- The state is in the button itself: when the hints are on its frame is painted
--- red, which is the only thing about a button that says "this is on" without adding
--- a word next to it. The colour goes in through StyleColor.Button, which is what
--- the game draws a button frame from; FrameBg is not what it uses, and pushing
--- that one leaves the button looking the same either way.
local function drawHintsToggle()
  local on = config.hints and true or false

  if on then
    ui.pushStyleColor(ui.StyleColor.Button, HINTS_ON_BG)
    ui.pushStyleColor(ui.StyleColor.ButtonHovered, HINTS_ON_BG_HOVER)
    ui.pushStyleColor(ui.StyleColor.ButtonActive, HINTS_ON_BG_HOVER)
    ui.pushStyleColor(ui.StyleColor.Text, HINTS_ON_FG)
  end

  -- sized by the game, for the same reason as the Details button next to it
  if ui.button('?') then
    config.hints = not on
    debugLog('field hints: ' .. tostring(config.hints))
  end

  if on then
    ui.popStyleColor()
    ui.popStyleColor()
    ui.popStyleColor()
    ui.popStyleColor()
  end

  tooltip(on and 'Field hints are on: what a field is for. Click to hide them.'
                or 'Field hints are off. Click to show what a field is for.', true)
end

--- Diagnostics block button. A plain selectable with bare text blends into the
--- checkbox next to it, so this is a real button with a frame: it draws itself
--- where the cursor is and needs no coordinates of its own.
--- Diagnostics block button. A plain selectable with bare text blends into the
--- checkbox next to it, so this is a real button with a frame: it draws itself
--- where the cursor is and needs no coordinates of its own.
---
--- No size of its own: the game sizes a button with its own padding around the
--- text, and a height worked out here is always a couple of pixels short of that,
--- which shows as a frame cut off along the bottom edge.
local function drawDetailsToggle()
  -- no marker in front of the word: the block below is what says whether it is
  -- open, and the game does not draw one for us anyway
  if ui.button('Details') then
    config.detailsOpen = not config.detailsOpen
  end
  tooltip('What the app asked for, what the server sent back, and what it made of it.')
end

--- The address list and the manual choice.
--- One text field is the whole list: to add an address, type it after a comma.
--- The second line picks which of them this AC server should use, which is
--- remembered, so it survives the next start.
local function drawAddressEditor(configured)
  ui.newLine()
  ui.setCursorX(12)
  ui.textColored('addresses', DIM)
  ui.sameLine()
  ui.setCursorX(VALUE_COLUMN)
  -- the list has to be readable: it spans what is left of the window instead of
  -- a fixed width that cut the second address in half
  ui.setNextItemWidth(fieldWidth())
  local edited = ui.inputText('##addresses', state.addressText)
  tooltip({
    'Address of the stracker site, the root only:',
    'https://stracker.example.com',
    'A page of that site is not an address: drop everything from',
    '/lapstat, /statistics or /lapdetails on, and the ?... after it.',
    'Several sites: separate them with a comma.',
  })

  if edited ~= state.addressText then
    local list = addresses.parseList(edited)
    state.addressText = edited
    config.serverAddresses = addresses.serializeList(list)
    -- an address the user just deleted must not come back on the next start
    config.serverBindings = addresses.serializeBindings(
      addresses.forgetRemoved(addresses.parseBindings(config.serverBindings), list))
    stracker.dropAll()
    -- what the list used to say about an address says nothing about the new one
    state.addressRefusals = {}
  end

  local problems = select(2, addresses.parseList(state.addressText))
  if #problems > 0 then
    ui.newLine()
    ui.setCursorX(VALUE_COLUMN)
    ui.textColored('skipped: ' .. table.concat(problems, ', '), YELLOW)
  end

  if #configured == 0 then return end

  -- the list shows the address in use, so the choice below has to start there
  local active = 1
  for index, address in ipairs(configured) do
    if address == state.address then active = index end
  end

  ui.newLine()
  ui.setCursorX(12)
  ui.textColored('this server uses', DIM)
  ui.sameLine()
  ui.setCursorX(VALUE_COLUMN)
  ui.setNextItemWidth(330)
  -- picking an entry is the command: it binds that address for this AC server and
  -- takes it into use at once. There is no separate button, because a selection that
  -- only lives inside the widget would be back to the old value on the next frame.
  local picked = ui.combo('##addressPick', active, ui.ComboFlags.None, configured)
  tooltip({
    'Which of the addresses above this AC server uses.',
    'The choice is remembered, so the next session starts with it.',
  })
  if picked and picked ~= active and configured[picked] then
    useAddress(acServerName(), configured[picked], 'by hand')
    refresh('by hand')
  end

  -- why this address: the pick is what the user chose, the reason is what the app
  -- worked out on its own. The address row itself is gone, this is the only place
  -- where the address appears, and the reason belongs to it.
  if state.addressReason and state.addressReason ~= '' then
    ui.sameLine()
    ui.textColored(state.addressReason, DIM)
  end

  -- The pick is remembered for this AC server, but a refresh can be using another
  -- address for the moment. That is the one case where the two tell different
  -- stories, so it says which one is in use now.
  if state.address and state.address ~= configured[active] then
    ui.newLine()
    ui.setCursorX(VALUE_COLUMN)
    ui.textColored('in use now: ' .. state.address, DIM)
  end
end

--- Contents of Details: what can be changed on top, what it produced below.
--- The switch itself lives in the toolbar, otherwise it would be unreachable
--- without scrolling; the block reserves list height.
local function drawDetailsBody()
  if not config.detailsOpen then return end

  -- the size of the text in the delta window, which is the only one it changes
  ui.newLine()
  ui.setCursorX(12)
  ui.textColored('delta text size', DIM)
  ui.sameLine()
  ui.setCursorX(VALUE_COLUMN)
  if ui.button('-##sizeDown') then
    config.textSizePx = math.max(12, config.textSizePx - 1)
  end
  tooltip('Size of the delta text drawn on top of the game, in pixels.')
  ui.sameLine()
  ui.textColored(tostring(config.textSizePx) .. ' px', WHITE)
  ui.sameLine()
  if ui.button('+##sizeUp') then
    config.textSizePx = math.min(64, config.textSizePx + 1)
  end
  tooltip('Size of the delta text drawn on top of the game, in pixels.')

  drawAddressEditor(addresses.parseList(state.addressText))
  drawDetailsSeparator()

  -- what the app is talking to
  local acName = state.acServerName
  local unknownServer = (not acName) or acName == '?'
  detailRow('ac server', unknownServer and 'not reported by the game' or acName,
            unknownServer and DIM or nil)

  -- the stracker server is only part of the query in the session scope; in the
  -- track scopes it is not sent at all, and "asking for" below says so
  if (config.listScope or 'session') == 'session' then
    detailRow('stracker server', state.server or '-', nil, state.serverReason)
  end
  detailRow('asking for', askingFor())
  detailRow('request', requestSummary())
  detailRow('updated', state.updatedAt)

  local meta = state.reference and state.reference.meta
  local points = state.reference and #state.reference.positions or 0
  if meta then
    local note = ''
    if referenceRow() == nil then note = '  ·  not in this list' end
    detailRow('reference lap', 'lapid ' .. tostring(meta.lapid) .. '  ' ..
                               points .. ' points' .. note, SUBTLE)
  else
    detailRow('reference lap', 'not loaded', DIM)
  end
end

local COLUMNS = { '#', 'Time', 'Gap', 'Driver', 'Car', 'Grip', 'Amb/Track', 'vMax', 'Date' }
local COLUMN_GAP = 14        -- gap between columns
local FLEX_COLUMNS = { 4, 5 }  -- Driver and Car shrink first when nothing fits

--- Cells of a row in column order.
local function rowCells(row)
  return {
    tostring(row.pos or '-'), tostring(row.timeText or '-'), tostring(row.gap or '-'),
    tostring(row.driver or '-'), tostring(row.car or '-'), tostring(row.grip or '-'),
    tostring(row.temps or '-'), tostring(row.vmax or '-'), tostring(row.date or '-'),
  }
end

--- Column widths from the actual content. Measured once per list:
--- with 50 laps that is 450 measurements instead of 450 on every frame.
--- If it still does not fit, the driver name and the car shrink first, they are
--- longer than the rest and are usually the ones eating up the space.
local function buildGrid(available)
  local widths = {}
  for i, title in ipairs(COLUMNS) do widths[i] = ui.measureText(title).x end
  local minimums = {}
  for i = 1, #COLUMNS do minimums[i] = widths[i] end

  for _, row in ipairs(state.laps) do
    local cells = rowCells(row)
    for i, text in ipairs(cells) do
      local width = ui.measureText(text).x
      if width > widths[i] then widths[i] = width end
    end
  end

  local function layout()
    local offsets, x = {}, 0
    for i = 1, #COLUMNS do
      offsets[i] = math.floor(x + 0.5)
      x = x + widths[i] + COLUMN_GAP
    end
    return offsets, x
  end

  local offsets, total = layout()
  local overflow = total - available
  if overflow > 0 then
    local slack = 0
    for _, i in ipairs(FLEX_COLUMNS) do
      slack = slack + math.max(0, widths[i] - minimums[i])
    end
    if slack > 0 then
      local ratio = math.min(1, overflow / slack)
      for _, i in ipairs(FLEX_COLUMNS) do
        widths[i] = widths[i] - math.max(0, widths[i] - minimums[i]) * ratio
      end
      offsets, total = layout()
    end
  end

  return { offsets = offsets, width = total, widths = widths }
end

--- The row background and click area must not be narrower than the table.
local function drawLaps()
  local acName = acServerName()
  state.acServerName = acName

  local choices = listChoices()
  local labels = {}
  for i, choice in ipairs(choices) do labels[i] = choice.label end

  ui.setNextItemWidth(220)
  local current = selectedChoice(choices)
  local picked = ui.combo('##list', current, ui.ComboFlags.None, labels)
  tooltip({
    'What the list is loaded from:',
    'Session - the laps of the AC server you are on',
    'This track - every car on the track you are on',
    'Track + car - your car on this track',
  })
  if picked and picked ~= current then
    local choice = choices[picked]
    if choice then
      config.listScope = choice.scope
      config.listServer = choice.server
      state.filter = ''         -- the filter belongs to the previous list
      debugLog('list selection: ' .. choice.label)
      refresh()
    end
  end
  ui.sameLine()

  if ui.button('Refresh') then refresh(nil, true) end
  tooltip('Ask the server again, now.')
  ui.sameLine()
  if ui.checkbox('Auto', config.autoRefresh) then
    config.autoRefresh = not config.autoRefresh
    state.lastRequest = state.clock
    debugLog('auto refresh: ' .. tostring(config.autoRefresh))
  end
  tooltip('Reload the list on a timer, without asking for it.')
  ui.sameLine()

  local intervalIndex = 1
  for i, seconds in ipairs(INTERVALS) do
    if seconds == config.refreshSeconds then intervalIndex = i end
  end
  ui.setNextItemWidth(62)
  local pickedInterval = ui.combo('##interval', intervalIndex, ui.ComboFlags.None, INTERVALS_LABEL)
  tooltip('How often the list reloads itself while Auto is on.')
  if pickedInterval and pickedInterval ~= intervalIndex then
    config.refreshSeconds = INTERVALS[pickedInterval]
    state.lastRequest = state.clock
  end
  ui.sameLine()

  if ui.checkbox('Always fastest', config.alwaysFastest) then
    config.alwaysFastest = not config.alwaysFastest
    debugLog('always fastest: ' .. tostring(config.alwaysFastest))
    if config.alwaysFastest then refresh() end
  end
  tooltip({
    'Always take the fastest lap of the list as the reference.',
    'Off: the lap that is loaded stays the reference.',
  })
  ui.sameLine(0, 10)

  -- the diagnostics block is drawn as a button: plain text blends into the checkbox
  drawDetailsToggle()
  ui.sameLine()
  drawHintsToggle()
  ui.newLine()

  -- the block opens right below the button and pushes the rest down
  drawDetailsBody()
  -- and closes with a rule: the filter below belongs to the list, not to the
  -- block, and the two rows were touching without it
  if config.detailsOpen then drawDetailsSeparator() end

  -- local search over the loaded list (all pages are already in one table)
  ui.text('Filter')
  ui.sameLine()
  ui.setNextItemWidth(240)
  state.filter = ui.inputText('##filter', state.filter)
  tooltip('Show only the rows that match: a driver, a car, a time, anything in a row.')
  ui.newLine()

  local rows = filteredRows()
  drawStatus({ filter = state.filter, count = #rows })

  -- selected lap: a caption above the list and the row itself highlighted
  local targetIndex, targetRow = referenceRow()
  local meta = state.reference and state.reference.meta
  if not meta then
    ui.textColored('Selected: not loaded', DIM)
    ui.newLine()
  else
    local line = 'Selected: '
    if targetRow and targetRow.pos then line = line .. '#' .. tostring(targetRow.pos) .. '  ' end
    line = line .. tostring(meta.lapTimeText or '--:--.---')
    if meta.driver and meta.driver ~= '' then line = line .. '  ' .. tostring(meta.driver) end
    -- the reference is not among the loaded laps, but its delta is still computed
    if not targetRow then line = line .. '  · not in the current list' end
    ui.textColored(line, targetRow and WHITE or YELLOW)
    ui.newLine()
  end

  if #state.laps == 0 then
    return
  end

  local columns = COLUMNS
  local rowHeight = 19

  -- the width is taken before beginChild: inside a child ui.windowSize() is the child size
  local listWidth = ui.windowSize().x - 30

  if state.gridVersion ~= state.listVersion or state.gridWidth ~= listWidth then
    state.grid = buildGrid(listWidth - 6)
    state.gridVersion = state.listVersion
    state.gridWidth = listWidth
  end
  local offsets = state.grid.offsets

  -- zero padding keeps the header and the rows on the same grid
  ui.pushStyleVar(ui.StyleVar.WindowPadding, vec2(0, 0))
  ui.beginChild('laps-list', vec2(0, -10), true)
  local gridX, gridY = ui.getCursorX(), ui.getCursorY()

  for i, title in ipairs(columns) do
    ui.setCursorX(gridX + offsets[i])
    ui.setCursorY(gridY)
    ui.textColored(title, DIM)
  end
  gridY = gridY + 16
  ui.setCursorX(gridX)
  ui.setCursorY(gridY)
  ui.separator()
  gridY = gridY + 8

  for index, row in ipairs(rows) do
    local rowY = gridY + (index - 1) * rowHeight
    ui.setCursorX(gridX)
    ui.setCursorY(rowY)
    -- The tints are drawn with the coordinates of the row itself: in this build
    -- ui.cursorScreenPos() and ui.drawRectFilled() disagreed, and the rectangles
    -- showed up somewhere else on the screen once the window was moved.
    local top = vec2(gridX, rowY)

    -- the button first: only it gives an honest hover and click
    local clicked = ui.invisibleButton('##lap' .. tostring(row.lapid), vec2(listWidth, rowHeight))
    local hovered = ui.itemHovered()

    local isTarget = row.lapid == (meta and meta.lapid)
    local isPending = state.pendingLapid ~= nil and row.lapid == state.pendingLapid

    if isTarget then
      ui.drawRectFilled(top, top + vec2(listWidth, rowHeight), TARGET_BG)
    elseif index % 2 == 0 then
      ui.drawRectFilled(top, top + vec2(listWidth, rowHeight), ZEBRA)
    end
    if isTarget then
      ui.drawRectFilled(top, top + vec2(3, rowHeight), TARGET_BAR)
    end
    if hovered and not isTarget and not isPending then
      ui.drawRectFilled(top, top + vec2(listWidth, rowHeight), HOVER)
    end

    local cells = rowCells(row)
    -- only the time and the name in white: the rest is a background that must not compete
    local cellColors = { SUBTLE, WHITE, SUBTLE, WHITE, SUBTLE, SUBTLE, SUBTLE, SUBTLE, SUBTLE }
    if isTarget then
      cellColors = { WHITE, WHITE, SUBTLE, WHITE, SUBTLE, SUBTLE, SUBTLE, SUBTLE, SUBTLE }
    end
    -- A row that is downloading used to carry a yellow band. Next to the blue
    -- band of the selected row the two read as a flag, and the pairing said
    -- nothing: the loading lap is not the selected lap. The time in yellow says
    -- the same thing without a second stripe.
    if isPending then cellColors[2] = YELLOW end
    for i, text in ipairs(cells) do
      ui.setCursorX(gridX + offsets[i])
      ui.setCursorY(rowY)
      -- one font for the whole table: the second one left the rows at different heights
      ui.textColored(text, cellColors[i])
    end

    if clicked then
      -- a manual pick cancels the "always fastest" policy, otherwise in a minute
      -- the auto refresh would silently roll it back
      if config.alwaysFastest then
        config.alwaysFastest = false
        debugLog('always fastest off: lap picked by hand')
      end
      loadLap(row)
    end
  end

  -- reserve the space of all rows so the list scrolls
  ui.setCursorX(gridX)
  ui.setCursorY(gridY + #rows * rowHeight + 4)
  ui.dummy(vec2(listWidth, 1))
  ui.endChild()
  ui.popStyleVar(1)
end

function script.windowLaps()
  safeDraw('laps', drawLaps)
end

-- ---------------------------------------------------------------------------

debugLog('app initialised, lap source: ' .. state.lapSource)

-- Exposed for the offline tests; unused in game.
_G.DeltaLuaTest = { state = state, config = config }