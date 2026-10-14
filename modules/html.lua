-- Stracker Delta: the three pages a stracker server serves as plain Lua tables.
-- /lapstat (lap list and pager), /statistics (cars per track) and /lapdetails
-- (one lap: metadata and chart points).
-- No external dependencies, string patterns of plain Lua only.

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local ENTITIES = {
  ['&nbsp;'] = ' ',
  ['&amp;'] = '&',
  ['&lt;'] = '<',
  ['&gt;'] = '>',
  ['&quot;'] = '"',
  ['&apos;'] = "'",
  ['&#39;'] = "'",
  ['&deg;'] = ' deg',
  ['&times;'] = 'x',
  ['&plusmn;'] = '+/-',
  ['&euro;'] = 'EUR',
}

--- Strips tags, entities and extra spaces. nil for nil.
function M.text(fragment)
  if fragment == nil then return nil end
  local s = fragment:gsub('<[^>]*>', ' ')
  for entity, replacement in pairs(ENTITIES) do
    s = s:gsub(entity, replacement)
  end
  s = s:gsub('&#(%d+);', function(code)
    local n = tonumber(code)
    if utf8 then return utf8.char(n) end
    return '?'
  end)
  s = s:gsub('%s+', ' ')
  s = s:gsub('^%s+', '')
  s = s:gsub('%s+$', '')
  if s == '' then return nil end
  return s
end

--- "01:18.149" -> 78.149
function M.parseTime(text)
  if not text then return nil end
  local minutes, seconds = text:match('(%d+):(%d+%.?%d*)')
  if not minutes then return nil end
  return tonumber(minutes) * 60 + tonumber(seconds)
end

--- Value of the cell that follows a label: ">Lap time<" ... "<td>01:18.149</td>"
function M.labelValue(html, label)
  local i = html:find('>' .. label .. '<', 1, true)
  if not i then return nil end
  local value = html:match('<td[^>]*>(.-)</td>', i)
  if not value then return nil end
  return M.text(value)
end

--- Walks the body of every table on the page: fn(bodyHtml)
function M.eachTable(html, fn)
  local pos = 1
  while true do
    local ts = html:find('<table', pos, true)
    if not ts then break end
    local te = html:find('>', ts, true)
    if not te then break end
    local close = html:find('</table>', te, true)
    if not close then break end
    fn(html:sub(te + 1, close - 1))
    pos = close + 8
  end
end

--- Walks every <tr>: fn(cells, attrs), cells being the cleaned <td> list
function M.eachRow(html, fn)
  local pos = 1
  while true do
    local ts, te, attrs = html:find('<tr([^>]*)>', pos)
    if not ts then break end
    local close = html:find('</tr>', te, true)
    if not close then break end
    local cells = {}
    for _, cell in html:sub(te + 1, close - 1):gmatch('(<td[^>]*>)(.-)</td>') do
      cells[#cells + 1] = M.text(cell)
    end
    fn(cells, attrs)
    pos = close + 5
  end
end

-- ---------------------------------------------------------------------------
-- /lapstat - lap list
-- ---------------------------------------------------------------------------

--- Column names from <thead>. The column set depends on the scope
--- (S1/S2/S3 are not always there), so positions come from the header
--- instead of fixed indexes. Returns name -> number, counting from 1.
function M.parseColumns(tableHtml)
  local columns = {}
  local head = tableHtml:match('(<thead.-</thead>)')
  if not head then return columns end
  local index = 0
  for name in head:gmatch('<th[^>]*>(.-)</th>') do
    index = index + 1
    local title = M.text(name)
    if title then columns[title:lower()] = index end
  end
  return columns
end

--- Cell by column name; falls back to the known index when there is no name.
local function cell(cells, columns, name, fallbackIndex)
  local index = columns[name]
  if not index or index == 0 then index = fallbackIndex end
  return cells[index or 0]
end

--- Column layout used when the table has no header: the one with S1/S2/S3.
local function fallbackColumns()
  return {
    ['pos'] = 1, ['driver'] = 2, ['car'] = 3, ['best lap'] = 4, ['gap to 1st'] = 5,
    ['s1'] = 6, ['s2'] = 7, ['s3'] = 8, ['valid'] = 9, ['laps'] = 10,
    ['date'] = 11, ['grip'] = 12, ['amb./track'] = 13, ['vmax'] = 14,
  }
end

--- Parses a /lapstat page.
--- Returns rows: { lapid, pos, driver, car, timeText, time, gap, s1, s2, s3,
---                      valid, laps, date, grip, temps, vmax }
function M.parseLapstat(html)
  local rows = {}
  M.eachTable(html, function(tableHtml)
    local columns = M.parseColumns(tableHtml)
    if next(columns) == nil then columns = fallbackColumns() end

    M.eachRow(tableHtml, function(cells, attrs)
      local lapid = attrs:match('href%s*=%s*"lapdetails%?lapid=(%d+)')
      if lapid then
        local timeText = cell(cells, columns, 'best lap', 4)
        rows[#rows + 1] = {
          lapid = tonumber(lapid),
          pos = tonumber((cell(cells, columns, 'pos', 1) or ''):match('(%d+)')),
          driver = cell(cells, columns, 'driver', 2),
          car = cell(cells, columns, 'car', 3),
          timeText = timeText,
          time = M.parseTime(timeText),
          gap = cell(cells, columns, 'gap to 1st', 5),
          s1 = cell(cells, columns, 's1', 6),
          s2 = cell(cells, columns, 's2', 7),
          s3 = cell(cells, columns, 's3', 8),
          valid = cell(cells, columns, 'valid', 9),
          laps = tonumber((cell(cells, columns, 'laps', 10) or ''):match('(%d+)')),
          date = cell(cells, columns, 'date', 11),
          grip = cell(cells, columns, 'grip', 12),
          temps = cell(cells, columns, 'amb./track', 13),
          vmax = cell(cells, columns, 'vmax', 14),
        }
      end
    end)
  end)
  return rows
end

--- /lapstat pagination. In HTML it is a bootstrap list where
--- "jump to last" points at page=<last page> and numbering starts at 1.
--- Returns { page = zero based index, pages = total }.
function M.parsePager(html)
  local pager = { page = 0, pages = 1 }
  local i = html:find('<ul class="pagination')
  if not i then return pager end
  local close = html:find('</ul>', i, true)
  if not close then return pager end
  local block = html:sub(i, close)

  -- the "jump to last" link: the numbered list may be truncated
  local last = block:match('page=(%-?%d+)"[^>]*>%s*<span class="glyphicon glyphicon%-fast%-forward')
  if last then
    pager.pages = tonumber(last) + 1
  else
    local known = 0
    for index in block:gmatch('<li[^>]*>%s*<a[^>]-page=(%d+)"') do
      local page = tonumber(index)
      if page and page + 1 > known then known = page + 1 end
    end
    pager.pages = known
  end

  local active = block:match('class="active"[^>]*>%s*<a[^>]-page=(%-?%d+)')
  if active then pager.page = tonumber(active) or 0 end
  if pager.pages < 1 then pager.pages = 1 end
  if pager.page < 0 then pager.page = 0 end
  if pager.page > pager.pages - 1 then pager.page = pager.pages - 1 end
  return pager
end

--- Track list from <select id="trackname">
function M.parseTracks(html)
  local list = {}
  local i = html:find('id="trackname"')
  if not i then return list end
  local close = html:find('</select>', i, true)
  if not close then return list end
  for value in html:sub(i, close):gmatch('<option[^>]-value="([^"]*)"') do
    if value ~= '' then list[#list + 1] = value end
  end
  return list
end

--- Every car the site offers in the <select name="cars"> of a lapstat page.
--- It is the complete list, not the nine that come marked: asked with all of
--- them, a track filtered lapstat answers with every car that drove it.
function M.parseCars(html)
  local list = {}
  local i = html:find('name="cars"') or html:find('id="cars"')
  if not i then return list end
  local close = html:find('</select>', i, true)
  if not close then return list end
  for value in html:sub(i, close):gmatch('<option[^>]-value="([^"]*)"') do
    if value ~= '' then list[#list + 1] = value end
  end
  return list
end

--- Server list from <select id="servers">
function M.parseServers(html)
  local list = {}
  local i = html:find('id="servers"')
  if not i then return list end
  local close = html:find('</select>', i, true)
  if not close then return list end
  local block = html:sub(i, close)
  for _, value, text in block:gmatch('<option([^>]-)value="([^"]*)"[^>]*>(.-)</option>') do
    local name = M.text(text)
    if name then list[#list + 1] = { id = value, name = name } end
  end
  return list
end

-- ---------------------------------------------------------------------------
-- /statistics - which cars have driven the track
-- ---------------------------------------------------------------------------

--- Returns trackId -> { cars = { carId, ... } }
function M.parseTrackCars(html)
  local result = {}
  M.eachTable(html, function(body)
    if not body:find('<th>Cars</th>', 1, true) then return end
    M.eachRow(body, function(cells)
      local track = cells[1]
      local carsCell = cells[2]
      if not track or not carsCell then return end
      local entry = result[track]
      if not entry then
        entry = { cars = {}, seen = {} }
        result[track] = entry
      end
      for car in carsCell:gmatch('[%w%-%._]+') do
        if not entry.seen[car] then
          entry.seen[car] = true
          entry.cars[#entry.cars + 1] = car
        end
      end
    end)
  end)
  return result
end

-- ---------------------------------------------------------------------------
-- /lapdetails - data of a single lap
-- ---------------------------------------------------------------------------

--- Parses a /lapdetails page.
--- Returns { lapid, driver, track, car, date, server, lapTimeText, lapTime,
---               points = { {position, speed}, ... } }
function M.parseLapDetails(html)
  local info = {
    driver = M.labelValue(html, 'Name'),
    track = M.labelValue(html, 'Track'),
    car = M.labelValue(html, 'Car'),
    lapTimeText = M.labelValue(html, 'Lap time'),
    date = M.labelValue(html, 'Achieved on'),
    server = M.labelValue(html, 'Server name'),
    valid = M.labelValue(html, 'Valid'),
  }
  info.lapTime = M.parseTime(info.lapTimeText)

  local points = {}
  for attrs, value in html:gmatch('<desc([^>]*)>(.-)</desc>') do
    if attrs:match('class%s*=%s*"value"') then
      local position, speed = value:match('^%s*([%d%.]+)%s*:%s*([%d%.]+)')
      if position and speed then
        points[#points + 1] = { tonumber(position), tonumber(speed) }
      end
    end
  end
  info.points = points
  return info
end

return M