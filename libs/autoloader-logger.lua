-- SPDX-License-Identifier: BSD-3-Clause
-- Copyright (c) 2025 NeatMachine

require("Modes")

_G.logger = _G.logger or {}
local logger = _G.logger

logger.VERBOSITY = { OFF = "off", ERROR = "error", INFO = "info", DEBUG = "debug" }
local _verbosity_level = {
  [logger.VERBOSITY .OFF] = 0,
  [logger.VERBOSITY .ERROR] = 1,
  [logger.VERBOSITY .INFO] = 2,
  [logger.VERBOSITY .DEBUG] = 3
}
local _verbosity_display = {
  [logger.VERBOSITY .OFF] = "Off",
  [logger.VERBOSITY .ERROR] = "ERROR",
  [logger.VERBOSITY .INFO] = "",
  [logger.VERBOSITY .DEBUG] = "Debug",
}

logger.options = {
  prefix = "[AutoLoader]",
  verbosity = logger.VERBOSITY.INFO,
  color = 207,
  max_chars_per_line = 80,
}
logger.mode = M { ["description"] = "Log", logger.VERBOSITY .OFF, logger.VERBOSITY .ERROR, logger.VERBOSITY .INFO, logger.VERBOSITY .DEBUG }
logger.mode:set(logger.options.verbosity)

local function sticky_chat_color(s, color_index)
  if not s or s == '' then return '' end
  local cc = string.char(0x1F, color_index or logger.options.color)
  -- Reapply color after common wrap points (space, comma, semicolon, colon)
  return cc .. s:gsub('([ ,;:])', '%1' .. cc)
end

local function format_message(tag, msg, color)
  if windower and windower.add_to_chat then
    if type(msg) ~= "string" then
      msg = tostring(msg)
    end
    local sanitized = msg
        :gsub("[\r\n\t]", " ")    -- normalize line breaks/tabs to space
        :gsub("\194\160", " ")    -- non-breaking space (UTF-8) -> space (optional but handy)
        :gsub("[%z\1-\31\127]", "") -- strip control chars

    local prefix = ("%s%s "):format(logger.options.prefix, (tag and tag ~= "" and "(" .. tag .. ")") or "")
    windower.add_to_chat(color, sticky_chat_color(prefix .. sanitized, color))
  else
    print("AutoLoader Error: Couldn't find windower.add_to_chat.")
  end
end

function logger.info(msg, force)
  if force or _verbosity_level[logger.mode.current] >= _verbosity_level[logger.VERBOSITY .INFO] then
    format_message((force and "") or _verbosity_display[logger.VERBOSITY .INFO], msg, logger.options.color)
  end
end

local function _callsite(skip)
  local info = debug.getinfo(2 + (skip or 0), "nSl")
  if not info then return "<unknown>", "?:0", "?", "?" end
  local name = info.name or "<anon>"
  local where = ("%s:%d"):format(info.short_src or "?", info.currentline or 0)
  return name, where, info.namewhat or "?", info.what or "?"
end
function logger.debug(msg)
  if _verbosity_level[logger.mode.current] >= _verbosity_level[logger.VERBOSITY .DEBUG] then
    local name, where = _callsite(1)
    format_message(_verbosity_display[logger.VERBOSITY .DEBUG], name .. ": ".. msg, 161)
  end
end

function logger.error(msg)
  if _verbosity_level[logger.mode.current] >= _verbosity_level[logger.VERBOSITY .ERROR] then
    local ok, err = format_message(_verbosity_display[logger.VERBOSITY .ERROR], msg, 39)
    if not ok then
      print(err)
    end
  end
end

function logger.dump(obj, opts, _seen, _depth)
  opts   = opts or {}
  local max_depth = opts.depth or 4       -- nesting limit
  local str_max   = opts.str_max or 200   -- truncate long strings
  local max_items = opts.max_items        -- cap items per table (nil = no cap)

  _seen  = _seen or {}
  _depth = _depth or 0

  local function prettify(v, seen, depth)
    local tv = type(v)
    if tv ~= "table" then
      if tv == "string" then
        local s = tostring(v)
        if #s > str_max then s = s:sub(1, str_max) .. "…" end
        return string.format("%q", s)
      end
      return tostring(v)
    end
    if seen[v] then return "<cycle>" end
    if depth >= max_depth then return "{…}" end
    seen[v] = true

    -- stable key order
    local keys, n = {}, 0
    for k in pairs(v) do n = n + 1; keys[n] = k end
    table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)

    local parts, count = {"{"}, 0
    for _, k in ipairs(keys) do
      count = count + 1
      if not max_items or count <= max_items then
        local kv = ("[%s]=%s"):format(tostring(k), prettify(v[k], seen, depth + 1))
        parts[#parts+1] = kv .. ","
      else
        parts[#parts+1] = "…"
        break
      end
    end
    parts[#parts+1] = "}"
    seen[v] = nil
    -- top level: multiline; nested: compact
    return table.concat(parts, depth == 0 and "\n" or " ")
  end

  local out = prettify(obj, _seen, _depth)
  for line in out:gmatch("[^\n]+") do
    logger.debug(line)
  end
end

return logger
