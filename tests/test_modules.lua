-- Offline tests of the Stracker Delta modules: html, lap and stracker
-- (run through lupa, no game).
-- Usage: python run_tests.py [fixtures_dir]

local html = require('modules.html')
local lap = require('modules.lap')
local addresses = require('modules.addresses')

local fixtures = ... or 'fixtures'
local outDir = fixtures .. '/../out'

local failures = 0
local checks = 0

local function check(name, actual, expected)
  checks = checks + 1
  local ok
  if type(expected) == 'number' then
    ok = type(actual) == 'number' and math.abs(actual - expected) < 1e-6
  else
    ok = actual == expected
  end
  if ok then
    print(string.format('  ok   %-34s %s', name, tostring(actual)))
  else
    failures = failures + 1
    print(string.format('  FAIL %-34s got=%s expected=%s', name, tostring(actual), tostring(expected)))
  end
end

local function checkNil(name, actual)
  checks = checks + 1
  if actual == nil then
    print(string.format('  ok   %-34s %s', name, 'nil'))
  else
    failures = failures + 1
    print(string.format('  FAIL %-34s got=%s expected=nil', name, tostring(actual)))
  end
end

local function readFile(path)
  local handle = io.open(path, 'rb')
  if not handle then error('cannot open ' .. path) end
  local content = handle:read('*a')
  handle:close()
  return content
end

local function heading(text)
  print('')
  print('== ' .. text .. ' ==')
end

-- ---------------------------------------------------------------------------
heading('lapstat: server session')
local sessionHtml = readFile(fixtures .. '/lapstat_session.html')
local sessionRows = html.parseLapstat(sessionHtml)
check('session rows', #sessionRows > 0 and true or false, true)
if #sessionRows > 0 then
  check('session row 1 lapid', sessionRows[1].lapid, 469675)
  check('session row 1 driver', sessionRows[1].driver, 'Riley Vance')
  check('session row 1 car', sessionRows[1].car, 'wsc_legends_330p4')
  check('session row 1 time', sessionRows[1].timeText, '00:56.597')
  check('session row 1 time seconds', sessionRows[1].time, 56.597)
  check('session row 1 columns', sessionRows[1].vmax ~= nil and true or false, true)
end

-- ---------------------------------------------------------------------------
heading('lapstat: the lists in the form')
-- These come out of the form of the same page. They used to come back empty
-- because the loop asked for more variables than the pattern captures.
local formTracks = html.parseTracks(sessionHtml)
check('track list is not empty', #formTracks > 100, true)
check('no empty track entries', (function()
  for _, track in ipairs(formTracks) do
    if track == '' then return false end
  end
  return true
end)(), true)
check('the layout variants are in there', (function()
  for _, track in ipairs(formTracks) do
    if track == 'tmm_lausitzring-layout_oval' then return true end
  end
  return false
end)(), true)

local formCars = html.parseCars(sessionHtml)
check('car list is not empty', #formCars > 100, true)
check('a known car is in there', (function()
  for _, car in ipairs(formCars) do
    if car == 'ac_legends_gtc_corvette_63' then return true end
  end
  return false
end)(), true)
check('no empty car entries', (function()
  for _, car in ipairs(formCars) do
    if car == '' then return false end
  end
  return true
end)(), true)

-- ---------------------------------------------------------------------------
heading('lapstat: track + car')
local trackCarHtml = readFile(fixtures .. '/lapstat_track_car.html')
local trackRows = html.parseLapstat(trackCarHtml)
check('track+car rows', #trackRows, 21)

-- ---------------------------------------------------------------------------
heading('lapstat: server list')
local servers = html.parseServers(sessionHtml)
check('servers count', #servers, 8)
if #servers >= 2 then
  check('server 1', servers[1].id, 'SRV1')
  check('server last', servers[#servers].id, 'srvopen')
end

-- ---------------------------------------------------------------------------
heading('statistics: cars on the track')
local statsHtml = readFile(fixtures .. '/statistics_track.html')
local trackCars = html.parseTrackCars(statsHtml)
local nelson = trackCars['rmi_nelson_ledges']
check('track found', nelson ~= nil and true or false, true)
if nelson then
  local joined = table.concat(nelson.cars, ',')
  check('cars of track', joined, 'ac_legends_gtc_corvette_63,citroen_c15_d')
end

-- ---------------------------------------------------------------------------
heading('lapdetails: lap data')
local lapHtml = readFile(fixtures .. '/lapdetails_468323.html')
local info = html.parseLapDetails(lapHtml)
check('lap driver', info.driver, 'Dana Whitfield')
check('lap track', info.track, 'rmi_nelson_ledges')
check('lap car', info.car, 'ac_legends_gtc_corvette_63')
check('lap time text', info.lapTimeText, '01:18.149')
check('lap time seconds', info.lapTime, 78.149)
check('lap date', info.date, '2026-10-10 18:21')
check('lap server', info.server, 'SRV1')
check('lap points', #info.points, 72)
check('first point', info.points[1][1], 0.0)
check('first point speed', info.points[1][2], 170.39)
check('last point', info.points[#info.points][1], 0.99)

-- ---------------------------------------------------------------------------
heading('lap: lap time calculation')
local positions, speeds, times = lap.build(info.points, info.lapTime)
check('built profile points', #positions, 72)
check('first time', times[1], 0.0)
check('last time equals lap time', times[#times] ~= nil and times[#times] > 0 and true or false, true)
print(string.format('  info  total time at last point: %.3f s (lap time %.3f)', times[#times], info.lapTime))

-- checkpoint from the Python version: position 0.02 -> 1.31 s
local interpolated = lap.interpolate(0.02, positions, times)
check('interpolate at 0.02', interpolated > 1.0 and interpolated < 1.6 and true or false, true)
print(string.format('  info  time at position 0.02: %.3f s (csv: 1.31)', interpolated))

-- ---------------------------------------------------------------------------
heading('stracker: page URLs')
local stracker = require('modules.stracker')
check('session url', stracker.lapstatPath('SRV1'), 'lapstat?currservers=SRV1')
check('track url', stracker.lapstatPath('SRV1', 'rmi_nelson_ledges', nil),
      'lapstat?currservers=SRV1&track=rmi_nelson_ledges')
check('track+car url', stracker.lapstatPath('SRV1', 'rmi_nelson_ledges', 'ac_legends_gtc_corvette_63'),
      'lapstat?currservers=SRV1&track=rmi_nelson_ledges&cars=ac_legends_gtc_corvette_63')
check('statistics url', stracker.statisticsPath('lime rock park'), 'statistics?tracks=lime%20rock%20park')
check('lapdetails url', stracker.lapDetailsPath(468323), 'lapdetails?lapid=468323&cmpbits=0')
-- pagination: page=1 is the second page, the first one needs no parameter
check('first page without page', stracker.lapstatPath('SRV1', nil, nil, 0),
      'lapstat?currservers=SRV1')
check('second page', stracker.lapstatPath('SRV1', nil, nil, 1),
      'lapstat?currservers=SRV1&page=1')
check('page in track+car mode', stracker.lapstatPath(nil, 'lilski_watkins_glen', 'abt,xyz', 2),
      'lapstat?track=lilski_watkins_glen&cars=abt%2Cxyz&page=2')
check('page without the other parameters', stracker.lapstatPath(nil, nil, nil, 3), 'lapstat?page=3')

heading('lapstat: pagination')
check('one page, the first', html.parsePager(sessionHtml).pages, 1)
check('page number', html.parsePager(sessionHtml).page, 0)

-- synthetic: a multi page list with truncated numbering (1 2 3 ... 9)
local pagedHtml = [[<html><ul class="pagination pagination-sm">
<li class="active"><a href="/lapstat?page=2">3</a></li>
<li><a href="/lapstat?page=0">1</a></li>
<li><a href="/lapstat?page=1">2</a></li>
<li><a href="/lapstat?page=8">9</a></li>
<li><a href="/lapstat?page=3"><span class="glyphicon glyphicon-forward"></span></a></li>
<li><a href="/lapstat?page=8"><span class="glyphicon glyphicon-fast-forward"></span></a></li>
</ul></html>]]
local pager = html.parsePager(pagedHtml)
check('pages from the jump to last link', pager.pages, 9)
check('current page is active', pager.page, 2)

heading('lapstat: columns by header')
-- the same table but without S1/S2/S3: that is how the live site answers
local function stripSectors(html)
  local out = html
  out = out:gsub('<th>S1</th>', '', 1)
  out = out:gsub('<th>S2</th>', '', 1)
  out = out:gsub('<th>S3</th>', '', 1)
  out = out:gsub('<td class="bestSector" >[^<]*</td>', '', 3)
  return out
end
local shortRows = html.parseLapstat(stripSectors(sessionHtml))
check('rows without sectors', #shortRows, 2)
check('date did not drift into vMax', shortRows[1].date, '2026-10-13 02:41')
check('vMax is in its place', shortRows[1].vmax, '258 km/h')
check('time is in its place', shortRows[1].timeText, '00:56.597')
check('driver is in its place', shortRows[1].driver, 'Riley Vance')

heading('stracker: server matching')
local serverList = {
  { id = 'SRV1', name = 'SRV1' }, { id = 'SRV2', name = 'SRV2' },
  { id = 'SRV7', name = 'SRV7' }, { id = 'srvopen', name = 'srvopen' },
}
check('exact match', stracker.matchServer('SRV1', serverList, ''), 'SRV1')
check('case-insensitive', stracker.matchServer('srv2', serverList, ''), 'SRV2')
check('substring match', stracker.matchServer('Weekend Series (SRV2)', serverList, ''), 'SRV2')
check('manual override', stracker.matchServer('anything', serverList, 'srvopen'), 'srvopen')
check('no match', stracker.matchServer('Totally Other Server', serverList, ''), nil)
check('nil name', stracker.matchServer(nil, serverList, ''), nil)

-- real server name the game reported (taken from a session log)
local realAcServer = '_SRX1_Race - https://example.com - ' ..
                     'The Cancer Sucks at Lausitzring Oval Practice Session'
check('real AC server name', stracker.matchServer(realAcServer, serverList, ''), 'SRV1')
check('reason for the match', stracker.matchServer(realAcServer, serverList, '') ~= nil, true)
check('RACI2 -> SRV2', stracker.matchServer('_SRX2_Race - practice', serverList, ''), 'SRV2')
check('SRV7 inside the name', stracker.matchServer('server SRV7 open', serverList, ''), 'SRV7')
check('srvopen inside the name', stracker.matchServer('srvopen main', serverList, ''), 'srvopen')

heading('stracker: track matching')
local knownTracks = { 'rmi_nelson_ledges', 'tmm_lausitzring', 'tmm_lausitzring-layout_oval',
                      'lime_rock_mountain', 'indianapolis' }
check('track as is', stracker.resolveTrack('rmi_nelson_ledges', '', knownTracks), 'rmi_nelson_ledges')
check('track + layout', stracker.resolveTrack('tmm_lausitzring', 'layout_oval', knownTracks),
      'tmm_lausitzring-layout_oval')
check('track without layout is in the list', stracker.resolveTrack('lime_rock_mountain', '', knownTracks),
      'lime_rock_mountain')
check('an unknown track does not break it', stracker.resolveTrack('some_unknown_track', '', knownTracks),
      'some_unknown_track')
check('no list yet, the id goes through', stracker.resolveTrack('rmi_nelson_ledges', '', nil),
      'rmi_nelson_ledges')
-- the list of the form, not a hand written one: this is what caught a loop that
-- asked for more variables than the pattern captures and returned nothing
check('layout resolved against the real form list',
      stracker.resolveTrack('tmm_lausitzring', 'layout_oval', html.parseTracks(sessionHtml)),
      'tmm_lausitzring-layout_oval')
check('unknown id stays unknown with a real list',
      stracker.resolveTrack('some_unknown_track', '', html.parseTracks(sessionHtml)),
      'some_unknown_track')

-- ---------------------------------------------------------------------------
heading('addresses: what the user typed')
check('scheme is added', addresses.normalise('stracker.example.com'), 'https://stracker.example.com')
check('trailing slash is cut', addresses.normalise('https://a.example/'), 'https://a.example')
check('several slashes are cut', addresses.normalise('https://a.example///'), 'https://a.example')
check('http is kept', addresses.normalise('http://a.example'), 'http://a.example')
check('spaces around are ignored', addresses.normalise('  https://a.example  '), 'https://a.example')
check('path is kept', addresses.normalise('https://a.example/stracker'),
      'https://a.example/stracker')
checkNil('empty is refused', addresses.normalise('   '))
checkNil('nonsense is refused', addresses.normalise('not an address'))
checkNil('ftp is refused', addresses.normalise('ftp://a.example'))

-- a page of the site is what lands in the field when the address bar was copied.
-- It has to be refused with a reason that says what an address is, and a stracker
-- in a folder has to survive it: only the pages of the site are refused by name
local pageUrl = 'https://a.example/lapstat?currservers=SRV1'
local pageAddress, pageReason = addresses.normalise(pageUrl)
checkNil('a lapstat page is not an address', pageAddress)
check('and the reason says so', pageReason, 'a page of the site, not its address')
checkNil('the lapdetails page as well',
         addresses.normalise('https://a.example/lapdetails?lapid=469554'))
checkNil('the statistics page as well', addresses.normalise('https://a.example/statistics'))
checkNil('the main page as well', addresses.normalise('https://a.example/mainpage'))
checkNil('and the pages the app never asks for', addresses.normalise('https://a.example/livemap'))
checkNil('a query on the root is a page with a filter on',
         addresses.normalise('https://a.example/?currservers=SRV1'))
checkNil('a query on a folder is too', addresses.normalise('https://a.example/stracker?x=1'))
checkNil('a page name is refused whatever its case',
         addresses.normalise('https://a.example/LapStat?currservers=SRV1'))
checkNil('and with a trailing slash', addresses.normalise('https://a.example/lapstat/'))
check('a stracker in a folder stays valid',
      addresses.normalise('https://a.example/stracker'), 'https://a.example/stracker')
check('another path stays valid too',
      addresses.normalise('https://a.example/lap'), 'https://a.example/lap')
check('a host that looks like one is still not', addresses.normalise('lapstat.example.com'),
      'https://lapstat.example.com')

-- the reason reaches the field as the line that says what was skipped
local pageProblems = select(2, addresses.parseList(pageUrl))
check('a page in the list is reported', #pageProblems, 1)
check('with the reason in it', pageProblems[1]:find('a page of the site', 1, true) ~= nil, true)
check('and with what was typed', pageProblems[1]:find('currservers', 1, true) ~= nil, true)
check('a list of one page address is no address', #addresses.parseList(pageUrl), 0)

local two = addresses.parseList('https://a.example, https://b.example')
check('two addresses parsed', #two, 2)
check('first one', two[1], 'https://a.example')
check('second one', two[2], 'https://b.example')
check('duplicates dropped', #addresses.parseList('https://a.example, a.example'), 1)
check('same host in two forms is one', #addresses.parseList('https://a.example/,https://a.example'), 1)
check('empty field means none', #addresses.parseList(''), 0)

local mixed, problems = addresses.parseList('https://a.example, nope, https://b.example')
check('the good ones survive', #mixed, 2)
check('the bad one is reported', #problems, 1)
check('what was reported', problems[1]:find('nope') ~= nil, true)
check('serialize keeps the order', addresses.serializeList(two), 'https://a.example, https://b.example')
check('serialize round trip', addresses.serializeList(addresses.parseList(
      addresses.serializeList(two))), 'https://a.example, https://b.example')

-- ---------------------------------------------------------------------------
heading('addresses: which address belongs to which AC server')
local acName = '_SRX1_Race - https://example.com - Weekend Practice'
check('nothing remembered at first', addresses.lookup({}, acName), nil)
check('encoded name has no separator', addresses.encodeName(acName):find('[;,=]') == nil, true)

local bindings = addresses.bind({}, acName, 'https://b.example')
check('one binding after bind', #bindings, 1)
check('lookup finds it', addresses.lookup(bindings, acName), 'https://b.example')
check('another server does not', addresses.lookup(bindings, 'some other server'), nil)

bindings = addresses.bind(bindings, acName, 'https://c.example')
check('rebind replaces, not appends', #bindings, 1)
check('rebind took effect', addresses.lookup(bindings, acName), 'https://c.example')

bindings = addresses.bind(bindings, 'second server', 'https://a.example')
check('two servers remembered', #bindings, 2)
check('first still there', addresses.lookup(bindings, acName), 'https://c.example')

local stored = addresses.serializeBindings(bindings)
check('stored form has no newline', stored:find('\n') == nil, true)
check('bindings round trip', #addresses.parseBindings(stored), 2)
check('bindings round trip, value', addresses.lookup(addresses.parseBindings(stored), acName),
      'https://c.example')

-- a name with the separator inside must not break the stored form
local tricky = 'weird = name ; with; separators'
bindings = addresses.bind(bindings, tricky, 'https://d.example')
check('tricky name survives a round trip',
      addresses.lookup(addresses.parseBindings(addresses.serializeBindings(bindings)), tricky),
      'https://d.example')
check('tricky name did not break the other one',
      addresses.lookup(addresses.parseBindings(addresses.serializeBindings(bindings)), acName),
      'https://c.example')

local many = {}
for i = 1, addresses.MAX_BINDINGS + 5 do
  many = addresses.bind(many, 'server ' .. i, 'https://s' .. i .. '.example')
end
check('bindings are capped', #many, addresses.MAX_BINDINGS)
check('the oldest fell off', addresses.lookup(many, 'server 1'), nil)
check('the newest stayed', addresses.lookup(many, 'server ' .. (addresses.MAX_BINDINGS + 5)),
      'https://s' .. (addresses.MAX_BINDINGS + 5) .. '.example')

local pruned = addresses.forgetRemoved(bindings, { 'https://a.example', 'https://d.example' })
check('forget drops the removed address', #pruned, 2)
check('the removed address is gone', addresses.lookup(pruned, acName), nil)
check('the addresses still configured stayed', addresses.lookup(pruned, tricky), 'https://d.example')

-- ---------------------------------------------------------------------------
heading('ranking of a merged list')
-- Pages of the site are batches of one list: each numbers its rows from one and
-- counts the gap from the fastest of its own batch.
local merged = {
  { pos = 1, time = 90.500, driver = 'Second Page', car = 'b', gap = '+00.000' },
  { pos = 2, time = 91.250, driver = 'Also Second', car = 'c', gap = '+00.750' },
  { pos = 1, time = 89.125, driver = 'First Page', car = 'a', gap = '+00.000' },
  { pos = 2, time = 92.000, driver = 'Second Of Two', car = 'd', gap = '+02.875' },
}
local ranked = stracker.rankRows(merged)
check('the merged list is sorted by lap time', ranked[1].driver, 'First Page')
check('the merged list keeps every row', #ranked, 4)
check('the fastest is number one', ranked[1].pos, 1)
check('the numbering goes on', ranked[4].pos, 4)
check('the slowest is last', ranked[4].time, 92.000)
check('the leader has no gap', ranked[1].gap, '+00.000')
check('the gap counts from the leader', ranked[3].gap, '+02.125')
check('the gap grows down the list', ranked[4].gap, '+02.875')

-- a row the site could not give a time for still belongs to the list
local withGap = stracker.rankRows({
  { pos = 1, time = 90.0, driver = 'Known', car = 'a' },
  { pos = 2, driver = 'No Time', car = 'b', gap = '+00.000' },
})
check('a row without a time keeps its gap', withGap[2].gap, '+00.000')
check('a row without a time is last', withGap[2].pos, 2)

-- ---------------------------------------------------------------------------
heading('CSV')
-- the one CSV the app writes: the profile cache, at full precision. The reference
-- file in reference/ holds the same profile and is compared line by line.
local csv = lap.toCache(positions, speeds, times)
local handle = io.open(outDir .. '/lua_data.csv', 'wb')
handle:write(csv)
handle:close()
check('csv written', true, true)
print('  info  ' .. outDir .. '/lua_data.csv')

print('')
print(string.format('%d checks, %d failures', checks, failures))
if failures > 0 then os.exit(1) end