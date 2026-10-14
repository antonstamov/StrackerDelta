-- Stracker Delta: everything the app knows about a stracker server.
-- Page URLs, the paged lap list, and the mapping of AC server and track ids
-- onto the ones stracker uses. The transport itself is in modules/web.lua.
--
-- There is no built in address: the user configures them in the app, see
-- modules/addresses.lua. Everything here takes the address it should talk to.

local html = require('modules.html')
local web = require('modules.web')

local M = {}

M.MODES = { 'session', 'track', 'track_car' }

-- how many cars go into one query when the whole list does not fit into a url
M.CARS_PER_QUERY = 50

-- A group that is refused is asked again in halves until it is this small, and
-- until this many queries have gone out. Halving is how the limit of a client is
-- found out; the budget is what keeps a server that refuses everything from
-- turning one refresh into hundreds of requests.
M.MIN_CARS_PER_QUERY = 5
M.CARS_QUERY_BUDGET = 120

-- The server list and the track list belong to an address, not to the module:
-- two configured addresses know different servers, so the cache is per address.
local caches = {}

--- Cache entry of an address, created on first use.
function M.cacheFor(address)
  local key = address or ''
  if not caches[key] then caches[key] = { address = key } end
  return caches[key]
end

function M.serversAt(address)
  return M.cacheFor(address).servers
end

function M.tracksAt(address)
  return M.cacheFor(address).tracks
end

--- Forgets what an address told us, e.g. after the user edited the list.
function M.dropCache(address)
  caches[address or ''] = nil
end

--- Forgets every address, used when the configured list changes under us.
function M.dropAll()
  caches = {}
end

-- ---------------------------------------------------------------------------
-- Address building
-- ---------------------------------------------------------------------------

local function encode(value)
  if string.urlEncode then return string.urlEncode(value) end
  return (tostring(value):gsub('[^%w%-%._~]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end
M.encode = encode

-- The address comes from the user, the transport does not.
local function get(address, path, callback)
  web.get(address .. '/' .. path, callback)
end

-- ---------------------------------------------------------------------------
-- Page URLs
-- ---------------------------------------------------------------------------

--- /lapstat URL. The server is sent only for the "session" scope:
--- the track and track+car scopes cover every server (offline hotlapping).
--- page is zero based, so &page=1 is the second page; the first page
--- does not need the parameter at all.
function M.lapstatPath(server, track, cars, page)
  local parts = {}
  if server and server ~= '' then parts[#parts + 1] = 'currservers=' .. encode(server) end
  if track and track ~= '' then parts[#parts + 1] = 'track=' .. encode(track) end
  if cars and cars ~= '' then parts[#parts + 1] = 'cars=' .. encode(cars) end
  if page and page > 0 then parts[#parts + 1] = 'page=' .. tostring(page) end
  if #parts == 0 then return 'lapstat' end
  return 'lapstat?' .. table.concat(parts, '&')
end

function M.statisticsPath(track)
  return 'statistics?tracks=' .. encode(track)
end

function M.lapDetailsPath(lapid)
  return 'lapdetails?lapid=' .. tostring(lapid) .. '&cmpbits=0'
end

-- ---------------------------------------------------------------------------
-- Ranking
-- ---------------------------------------------------------------------------

-- The site prints the gap as seconds with thousandths: +12.229
local function gapText(seconds)
  local ms = math.floor(seconds * 1000 + 0.5)
  return string.format('+%02d.%03d', math.floor(ms / 1000), ms % 1000)
end

--- Puts a merged list into one ranking.
---
--- Every page of the site is a batch of the same list and numbers its rows from
--- one again, and the gap it prints is the gap to the fastest of its own batch.
--- Asked with one car query or with fifty, the result is therefore numbered 1..50
--- over and over, with gaps that count from a different start every time. The
--- merged list is sorted by lap time and numbered once, so what the app shows is
--- one list from the fastest lap to the last.
local function rankRows(rows)
  table.sort(rows, function(a, b)
    local ta, tb = a.time or math.huge, b.time or math.huge
    if ta ~= tb then return ta < tb end
    if (a.driver or '') ~= (b.driver or '') then return (a.driver or '') < (b.driver or '') end
    return (a.car or '') < (b.car or '')
  end)

  local fastest = rows[1] and rows[1].time or nil
  for index, row in ipairs(rows) do
    row.pos = index
    if fastest and row.time then row.gap = gapText(row.time - fastest) end
  end
  return rows
end

M.rankRows = rankRows

-- ---------------------------------------------------------------------------
-- High level operations
-- ---------------------------------------------------------------------------

--- Lap list: pages are fetched one after another and merged, so the user
--- sees a single list.
--- options = { address, mode, server, track, car, onPage, isCancelled }
--- onPage(done, total) reports progress; isCancelled() tells the chain that it
--- has been superseded. callback(result) = { ok, rows, pager, error, note, path }
function M.listLaps(options, deliver)
  local mode = options.mode or 'session'
  local server = (mode == 'session') and options.server or nil
  local address = options.address
  local cache = M.cacheFor(address)

  -- Every path out of here hands over a list, and every one of them has to hand
  -- over the same kind of list: ranked once, numbered from one.
  local function callback(result)
    if result and result.rows and #result.rows > 0 then rankRows(result.rows) end
    return deliver(result)
  end

  if mode == 'session' and (not server or server == '') then
    return callback({ ok = false, error = 'server not determined' })
  end

  local function lapstatAll(trackFilter, cars, done)
    local rows = {}
    local seen = {}
    local path = nil
    local lastPager = nil

    local function step(page)
      if options.isCancelled and options.isCancelled() then
        return done({ ok = false, error = 'cancelled', silent = true })
      end

      path = M.lapstatPath(server, trackFilter, cars, page)
      get(address, path, function(response)
        if not response.ok then return done(response) end

        -- pages of one query overlap: the site shifts the order under us, so the
        -- same lap turns up twice. Counting it twice would show the driver two
        -- rows for one lap.
        for _, row in ipairs(html.parseLapstat(response.body)) do
          local id = row.lapid
          if id == nil or not seen[id] then
            if id ~= nil then seen[id] = true end
            rows[#rows + 1] = row
          end
        end
        lastPager = html.parsePager(response.body)

        local nextPage = lastPager.page + 1
        if nextPage < lastPager.pages then
          if options.onPage then options.onPage(nextPage + 1, lastPager.pages) end
          step(nextPage)
          return
        end

        cache.servers = cache.servers or html.parseServers(response.body)
        cache.tracks = cache.tracks or html.parseTracks(response.body)
        done({ ok = true, rows = rows, pager = lastPager, path = path })
      end)
    end

    step(0)
  end

  -- A track query with every car in it has a url of several kilobytes. A client
  -- that refuses a url that long gets the list in parts instead, and the rows of
  -- all of them are merged.
  local function chunk(list, size)
    local parts, current = {}, {}
    for _, item in ipairs(list) do
      current[#current + 1] = item
      if #current >= size then
        parts[#parts + 1] = current
        current = {}
      end
    end
    if #current > 0 then parts[#parts + 1] = current end
    return parts
  end

  local function slice(list, from, to)
    local out = {}
    for index = from, to do out[#out + 1] = list[index] end
    return out
  end

  -- Asks the groups of the queue one after the other and merges what comes back.
  --
  -- A group that does not go through is not the end of the list: it is asked again
  -- in halves, because how long a url a client takes is not known here and halving
  -- finds out. What is left of a group after the budget is used up is given up on
  -- and counted, so the app can say the list is not complete.
  local function lapstatInParts(track, queue, acc, done)
    local part = queue[1]
    if not part then
      if #acc.rows == 0 and acc.error then return done(acc.error) end
      local result = { ok = true, rows = acc.rows, path = acc.path, parts = acc.asked }
      if acc.failed > 0 then result.failedParts = acc.failed end
      if acc.refused > 0 then result.refusedParts = acc.refused end
      return done(result)
    end
    table.remove(queue, 1)

    acc.asked = acc.asked + 1
    if options.onPage then options.onPage(acc.asked, acc.asked + #queue) end

    lapstatAll(track, table.concat(part, ','), function(result)
      if not result.ok then
        acc.refused = acc.refused + 1
        acc.error = acc.error or result
        if #part > M.MIN_CARS_PER_QUERY and acc.asked < M.CARS_QUERY_BUDGET then
          local half = math.floor(#part / 2)
          table.insert(queue, 1, slice(part, half + 1, #part))
          table.insert(queue, 1, slice(part, 1, half))
        else
          -- nothing smaller left to try: this piece of the list is missing, and
          -- the app has to say the list is not the whole thing
          acc.failed = acc.failed + 1
        end
        return lapstatInParts(track, queue, acc, done)
      end

      for _, row in ipairs(result.rows) do
        if not acc.seen[row.lapid] then
          acc.seen[row.lapid] = true
          acc.rows[#acc.rows + 1] = row
        end
      end
      acc.path = result.path

      lapstatInParts(track, queue, acc, done)
    end)
  end

  if options.mode == 'track_car' then
    lapstatAll(options.track, options.car, callback)
  elseif options.mode == 'track' then
    -- "every car that drove this track".
    --
    -- A lapstat page filtered by track carries the complete car list in its form,
    -- and asked with all of it the site answers with every car that drove the track.
    -- So the first request is the plain one: it gives both the page to fall back on
    -- and the list to ask properly with. Only when that list is missing does the
    -- /statistics page come in, because it knows cars but is filled in for some
    -- tracks only. Whatever happens, the plain result is never thrown away for
    -- nothing: a server that refuses the long car list still leaves us the rows it
    -- returned on its own.
    local track = options.track

    get(address, M.lapstatPath(nil, track, nil, 0), function(response)
      if not response.ok then return callback(response) end

      local plain = {
        ok = true,
        rows = html.parseLapstat(response.body),
        pager = html.parsePager(response.body),
        path = M.lapstatPath(nil, track, nil, 0),
      }
      local function keepPlain(note)
        if #plain.rows == 0 and note then plain.note = note end
        callback(plain)
      end

      local cars = html.parseCars(response.body)

      if #cars == 0 then
        return get(address, M.statisticsPath(track), function(stats)
          local entry = stats.ok and html.parseTrackCars(stats.body)[track]
          if not entry or #entry.cars == 0 then
            return keepPlain('no laps recorded on this track')
          end
          lapstatAll(track, table.concat(entry.cars, ','), function(result)
            if result.ok and #result.rows == 0 then return keepPlain('no laps recorded on this track') end
            callback(result)
          end)
        end)
      end

      lapstatAll(track, table.concat(cars, ','), function(result)
        if not result.ok then
          -- the whole list did not fit into one url: ask in parts and merge
          return lapstatInParts(track, chunk(cars, M.CARS_PER_QUERY),
                                { rows = {}, seen = {}, failed = 0, refused = 0,
                                  asked = 0, error = nil, path = nil },
                                function(merged)
            if merged.ok and #merged.rows == 0 then
              return keepPlain('no laps recorded on this track')
            end
            callback(merged)
          end)
        end
        if #result.rows == 0 then return keepPlain('no laps recorded on this track') end
        callback(result)
      end)
    end)
  else
    lapstatAll(nil, nil, callback)
  end
end

--- Data of a single lap. callback(result) = { ok, info, error }
function M.fetchLap(address, lapid, callback)
  get(address, M.lapDetailsPath(lapid), function(response)
    if not response.ok then return callback(response) end
    local info = html.parseLapDetails(response.body)
    if not info.lapTime or #info.points < 2 then
      return callback({ ok = false, error = 'no chart data on the lap page' })
    end
    info.lapid = lapid
    callback({ ok = true, info = info })
  end)
end

--- Server list of an address (taken from the drop down on /lapstat).
--- Also the probe the app uses to find out which configured address belongs to
--- the AC server it is on: it returns that server list to compare against.
function M.fetchServers(address, callback)
  get(address, 'lapstat', function(response)
    if not response.ok then return callback(response) end
    local cache = M.cacheFor(address)
    cache.servers = html.parseServers(response.body)
    cache.tracks = html.parseTracks(response.body)
    callback({ ok = true, servers = cache.servers, tracks = cache.tracks })
  end)
end

-- ---------------------------------------------------------------------------
-- Server and track matching
-- ---------------------------------------------------------------------------

--- Signature of a name: SRX1 -> S1, SRV1 -> S1, for loose comparisons.
local function signature(text)
  local letters, digits = text:match('^(%a+)(%d+)$')
  if letters and digits then return letters:sub(1, 1):upper() .. digits end
  return nil
end

--- Finds the stracker server id for the name the game reported.
--- acName: ac.getServerName(); servers: list of { id, name }; saved: manual pick
--- Returns the id, nil and an optional explanation.
function M.matchServer(acName, servers, saved)
  if saved and saved ~= '' then return saved, 'by hand' end
  if not servers or #servers == 0 then return nil end

  local lowered = (acName or ''):lower()

  -- 1. exact match
  for _, server in ipairs(servers) do
    if server.id:lower() == lowered or server.name:lower() == lowered then
      return server.id, 'exact'
    end
  end

  -- 2. id contained in the name
  for _, server in ipairs(servers) do
    if lowered ~= '' and lowered:find(server.id:lower(), 1, true) then
      return server.id, 'by name'
    end
  end

  -- 3. loose match by signature: SRX1 ... -> SRV1
  for token in lowered:gmatch('%a+%d+') do
    local wanted = signature(token)
    if wanted then
      for _, server in ipairs(servers) do
        if signature(server.id:lower()) == wanted then
          return server.id, 'similar'
        end
      end
    end
  end

  return nil
end

--- Maps an AC track id to the one stracker knows.
--- ac.getTrackID() may return the id without the layout, stracker keeps it.
--- tracks: the track list of the address in use, nil when it is not known yet.
function M.resolveTrack(acTrackId, layout, tracks)
  if not acTrackId or acTrackId == '' then return nil end
  if not tracks or #tracks == 0 then return acTrackId end

  local function known(id)
    for _, track in ipairs(tracks) do
      if track == id then return true end
    end
    return false
  end

  -- layout first: stracker tells tmm_lausitzring and tmm_lausitzring-layout_oval apart
  if layout and layout ~= '' then
    local full = acTrackId .. '-' .. layout
    if known(full) then return full end
  end

  if known(acTrackId) then return acTrackId end

  for _, track in ipairs(tracks) do
    if track:sub(1, #acTrackId + 1) == acTrackId .. '-' then return track end
  end

  local base = acTrackId:match('^(.-)%-[^%-]+$')
  if base and known(base) then return base end

  return acTrackId
end

return M