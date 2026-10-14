-- Stracker Delta: asynchronous HTTP on top of the web.get of Assetto Corsa.
-- The only module that touches the network: everything that needs bytes
-- from somewhere goes through here.

local M = {}

--- Async GET of a full URL. callback(result), result = { ok, body, error }
---
--- web.get calls back more than once now and then (redirects, retries after a
--- timeout), so the first answer wins and the rest is dropped. Any error inside
--- the call is caught and reported like a network error, so a caller never has
--- to wrap this in pcall.
function M.get(url, callback)
  local finished = false
  local function finish(result)
    if finished then return end
    finished = true
    -- the url travels with the failure: a client that refuses a long one has to
    -- be told which request it was
    if not result.ok then result.url = url end
    callback(result)
  end

  local ok, err = pcall(function()
    web.timeouts(4000, 8000, 15000, 20000, 2)
    web.get(url, function(requestError, response)
      if requestError or not response then
        finish({ ok = false, error = requestError or 'no response' })
      elseif response.status >= 400 then
        finish({ ok = false, error = 'HTTP ' .. tostring(response.status) })
      else
        finish({ ok = true, body = response.body or '' })
      end
    end)
  end)

  if not ok then finish({ ok = false, error = tostring(err) }) end
end

return M
