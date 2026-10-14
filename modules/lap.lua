-- Stracker Delta: the lap model.
-- Builds a lap out of the chart points of /lapdetails: positions, speeds and
-- the time spent per point. Interpolates that profile at any position of the
-- track and formats lap times, deltas and the CSV export.

local M = {}

--- Interpolates a value at a position (binary search + linear interpolation).
function M.interpolate(position, positions, values)
  local n = #positions
  if n == 0 then return 0.0 end

  -- first index where positions[idx] >= position
  local lo, hi = 1, n
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if positions[mid] < position then lo = mid + 1 else hi = mid end
  end
  local idx = lo

  if idx == 1 then return values[1] end
  if idx > n then return values[n] end
  if positions[idx] == position then return values[idx] end

  local x0, x1 = positions[idx - 1], positions[idx]
  local y0, y1 = values[idx - 1], values[idx]
  if x1 == x0 then return y0 end
  return y0 + (y1 - y0) * (position - x0) / (x1 - x0)
end

--- Integrates the lap time over the segments.
--- points: sorted list of { {position, speedKmh}, ... }
local function integrate(points, trackLength, piecewise)
  local times = { 0.0 }
  for i = 1, #points - 1 do
    local position, speed = points[i][1], points[i][2]
    local nextPosition, nextSpeed = points[i + 1][1], points[i + 1][2]
    local deltaS = trackLength * (nextPosition - position)
    local deltaT = 0.0

    if piecewise and speed > 0 and nextSpeed > 0 and deltaS > 0 then
      local segments = 10
      local deltaSub = deltaS / segments
      local total = 0.0
      for j = 0, segments - 1 do
        local start = j * deltaSub
        local stop = (j + 1) * deltaSub
        local vStart = speed + (nextSpeed - speed) * (start / deltaS)
        local vStop = speed + (nextSpeed - speed) * (stop / deltaS)
        local averageMs = ((vStart + vStop) / 2) / 3.6
        if averageMs > 0 then total = total + deltaSub / averageMs end
      end
      deltaT = total
    else
      local averageMs = ((speed + nextSpeed) / 2) / 3.6
      if averageMs > 0 then deltaT = deltaS / averageMs end
    end

    times[#times + 1] = times[#times] + deltaT
  end
  return times
end

--- Builds a lap profile out of the chart points.
--- Returns positions, speeds and times (seconds since the lap started).
function M.build(points, lapTime)
  -- stable sort: points at the same position keep their original order
  local sorted = {}
  for i = 1, #points do
    sorted[i] = { points[i][1], points[i][2], i }
  end
  table.sort(sorted, function(a, b)
    if a[1] == b[1] then return a[3] < b[3] end
    return a[1] < b[1]
  end)

  local sum = 0.0
  for i = 1, #sorted do sum = sum + sorted[i][2] end
  local averageKmh = sum / #sorted
  local trackLength = lapTime * (averageKmh / 3.6)

  local times = integrate(sorted, trackLength, true)

  local total = times[#times]
  local lastPosition = sorted[#sorted][1]
  if lastPosition < 1.0 and #sorted >= 2 then
    local previousPosition = sorted[#sorted - 1][1]
    local previousTime = times[#times - 1]
    local lastTime = times[#times]
    if lastPosition > previousPosition then
      total = lastTime + (1.0 - lastPosition) * (lastTime - previousTime)
                              / (lastPosition - previousPosition)
    end
  end

  if total > 0 then
    local factor = lapTime / total
    for i = 1, #times do times[i] = times[i] * factor end
  end

  local positions, speeds = {}, {}
  for i = 1, #sorted do
    positions[i] = sorted[i][1]
    speeds[i] = sorted[i][2]
  end

  return positions, speeds, times
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

--- "0.0200000000" -> "0.02" (%.10f with the zeros cut off)
function M.formatPosition(value)
  local s = string.format('%.10f', value)
  s = s:gsub('0+$', '')
  s = s:gsub('%.$', '')
  if s == '-0' then s = '0' end
  return s
end

--- 179 -> "179.0", 187.04 -> "187.04" (shortest repr that keeps the number)
function M.formatSpeed(value)
  if value == math.floor(value) and math.abs(value) < 1e15 then
    return string.format('%.1f', value)
  end
  return (string.format('%.14g', value))
end

--- Seconds -> "01:18.149"
function M.formatLapTime(seconds)
  if not seconds then return '--:--.---' end
  local minutes = math.floor(seconds / 60)
  local rest = seconds - minutes * 60
  return string.format('%02d:%06.3f', minutes, rest)
end

--- Seconds -> "+0.35" / "-1.24", the classic delta format
function M.formatTimeDelta(delta)
  local absolute = math.abs(delta)
  local integerPart = math.floor(absolute)
  local digits = integerPart > 0 and #tostring(integerPart) or 1
  local sign = delta > 0 and '+' or ''
  if digits > 3 then
    return sign .. string.format('%.1fm', delta / 60.0)
  elseif digits == 3 then
    return sign .. string.format('%.1f', delta)
  end
  return sign .. string.format('%.2f', delta)
end

--- Speed delta -> "+12.4" / "-3.1"
function M.formatSpeedDelta(value)
  if value > 0 then return string.format('+%.1f', value) end
  return string.format('%.1f', value)
end

--- CSV of the format the tooling around this app has always used
function M.toCsv(positions, speeds, times)
  local lines = { 'Position,Speed,Time' }
  for i = 1, #positions do
    lines[#lines + 1] = table.concat({
      M.formatPosition(positions[i]),
      M.formatSpeed(speeds[i]),
      string.format('%.2f', times[i]),
    }, ',')
  end
  return table.concat(lines, '\n') .. '\n'
end

--- Profile cache: same CSV but more precise (0.1 ms per time sample),
--- so that the cached profile matches the one that came from the network.
function M.toCache(positions, speeds, times)
  local lines = { 'Position,Speed,Time' }
  for i = 1, #positions do
    lines[#lines + 1] = string.format('%.6f,%.3f,%.4f',
                                      positions[i] or 0, speeds[i] or 0, times[i] or 0)
  end
  return table.concat(lines, '\n') .. '\n'
end

--- Reads the cache back: nil when there is no data or it is broken.
function M.fromCache(text)
  if not text or text == '' then return nil end
  local positions, speeds, times = {}, {}, {}
  local header = true
  for line in text:gmatch('[^\r\n]+') do
    if header then
      header = false
    else
      local p, s, t = line:match('^%s*([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)%s*$')
      if p then
        positions[#positions + 1] = tonumber(p)
        speeds[#speeds + 1] = tonumber(s)
        times[#times + 1] = tonumber(t)
      end
    end
  end
  if #positions < 2 then return nil end
  return positions, speeds, times
end

return M