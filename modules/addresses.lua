-- Stracker Delta: the stracker addresses the user configured and which one
-- belongs to which AC server.
--
-- Pure functions only, no game and no network, so every decision here can be
-- tested offline. The UI keeps a single comma separated field; this module
-- decides what that text means.

local M = {}

-- how many AC servers we remember an address for
M.MAX_BINDINGS = 30

local function trimmed(text)
  return (tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- ---------------------------------------------------------------------------
-- Addresses
-- ---------------------------------------------------------------------------

--- One address as the app will use it: scheme added, trailing slashes cut.
--- Returns nil plus the reason when the text cannot be used as an address.
function M.normalise(url)
  local text = trimmed(url)
  if text == '' then return nil, 'empty' end
  if not text:find('://') then text = 'https://' .. text end

  local scheme, host = text:match('^(https?)://([^/]+)')
  if not scheme then return nil, 'only http and https' end

  host = trimmed(host)
  -- a host without spaces and with either a dot or a port is as far as we go:
  -- anything else is a sentence the user forgot to delete
  if host == '' then return nil, 'no host' end
  if host:find('%s') then return nil, 'no spaces in an address' end
  if not host:find('[%.:]') and host ~= 'localhost' then return nil, 'no host' end

  return (text:gsub('/+$', ''))
end

--- What the user typed into the field: the addresses in it, plus one line per
--- piece that did not make it, so the UI can say what was skipped.
--- Duplicates are dropped, the order the user typed is kept: the first entry is
--- the fallback when nothing matches the AC server.
function M.parseList(text)
  local list, problems, seen = {}, {}, {}

  for piece in tostring(text or ''):gmatch('[^,]+') do
    local address, reason = M.normalise(piece)
    if address then
      if not seen[address] then
        seen[address] = true
        list[#list + 1] = address
      end
    else
      problems[#problems + 1] = trimmed(piece) .. ' (' .. reason .. ')'
    end
  end

  return list, problems
end

--- Back to the text of the field, so what is stored is what was on screen.
function M.serializeList(list)
  return table.concat(list or {}, ', ')
end

-- ---------------------------------------------------------------------------
-- Which address belongs to which AC server
-- ---------------------------------------------------------------------------

-- AC server names carry slashes, spaces and anything the server owner typed, so
-- they are percent encoded before being used as a key: that keeps the
-- separator of the stored form out of the data.
local function encodeName(name)
  if string.urlEncode then return string.urlEncode(name) end
  return (tostring(name or ''):gsub('[^%w%-%._~]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

M.encodeName = encodeName

--- Stored form: entries of <encoded name>=<address> separated by semicolons.
--- Semicolons appear in neither URLs nor percent encoded names, and a newline
--- would break the value inside the .ini of ac.storage.
function M.parseBindings(text)
  local list = {}

  for entry in tostring(text or ''):gmatch('[^;]+') do
    local name, address = entry:match('^(.-)=(%S+)$')
    if name and address and name ~= '' then
      list[#list + 1] = { name = name, address = address }
    end
  end

  return list
end

function M.serializeBindings(bindings)
  local parts = {}
  for _, binding in ipairs(bindings or {}) do
    parts[#parts + 1] = binding.name .. '=' .. binding.address
  end
  return table.concat(parts, ';')
end

--- The address remembered for this AC server, or nil when nothing is known.
function M.lookup(bindings, acServerName)
  local wanted = encodeName(acServerName)
  for _, binding in ipairs(bindings or {}) do
    if binding.name == wanted then return binding.address end
  end
  return nil
end

--- Remembers the address for this AC server. An existing entry moves to the end
--- so the oldest ones fall off once there are more than MAX_BINDINGS.
function M.bind(bindings, acServerName, address)
  local list, wanted = {}, encodeName(acServerName)

  for _, binding in ipairs(bindings or {}) do
    if binding.name == wanted then
      wanted = nil                       -- drop the old entry, it is added back at the end
    else
      list[#list + 1] = binding
    end
  end

  if address and address ~= '' then list[#list + 1] = { name = encodeName(acServerName), address = address } end

  while #list > M.MAX_BINDINGS do table.remove(list, 1) end
  return list
end

--- Drops the bindings whose address is no longer in the configured list, so an
--- address the user deleted does not come back on the next start.
function M.forgetRemoved(bindings, configured)
  local keep = {}
  for _, address in ipairs(configured or {}) do keep[address] = true end

  local kept = {}
  for _, binding in ipairs(bindings or {}) do
    if keep[binding.address] then kept[#kept + 1] = binding end
  end
  return kept
end

return M
