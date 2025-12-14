-- SPDX-License-Identifier: BSD-3-Clause
-- Copyright (c) 2025 NeatMachine

require("lists")

_G.utils = _G.utils or {}
local utils = _G.utils

function utils.now()
  local socket = rawget(_G, "socket")
  if socket and type(socket.gettime) == "function" then
    return socket.gettime()
  end
  return os.clock()
end

function utils.call_hook(name, stub, ...)
  local fn = rawget(_G, name)
  if type(fn) == "function" and fn ~= stub then
    local ok, result = pcall(fn, ...)
    if not ok then
      return nil, result
    end
    return result
  end

  return nil
end

function utils.get_keys(map)
  local keys, i = L {}
  for k in pairs(map or {}) do
    keys:append(k)
  end
  return keys
end

function utils.pretty_time(ticks)
  local seconds = (tonumber(ticks) and tonumber(ticks) / 60) or 0
  if seconds < 0 then
    seconds = 0
  end

  seconds       = math.floor(seconds)

  local hours   = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local secs    = seconds % 60

  if hours > 0 then
    return string.format("%02d:%02d:%02d", hours, minutes, secs)
  else
    return string.format("%02d:%02d", minutes, secs)
  end
end

local _mode_display_names = {
  ["default"] = "Default",
  ["dt"] = "DT",
  ["mdt"] = "MDT",
  ["acc"] = "Accuracy",
  ["sb"] = "Subtle Blow",
  ["mb"] = "Magic Burst",
  ["on"] = "On",
  ["off"] = "Off",
}

local _unpack = table.unpack or unpack
function utils.insert_mode_option(mode, value, index, display)
  if not mode or type(mode.options) ~= "function" then
    return
  end
  if not value then
    return
  end

  index = tonumber(index) or (#mode + 1)
  if index < 1 then
    index = 1
  end

  local opts = {}
  for i = 1, #mode do
    opts[i] = mode[i]
  end

  if index > #opts + 1 then
    index = #opts + 1
  end

  table.insert(opts, index, value)
  mode:options(_unpack(opts))

  if display then
    _mode_display_names[value] = display
  end
end

function utils.get_keys_sorted(map)
  return utils.get_keys(map):sort()
end

function utils.echo(msg)
  windower.send_command("input /echo " .. msg)
end

function utils.capitalize_words(s)
  if type(s) ~= "string" then
    return s
  end
  s = s:lower()
  s = s:gsub("(%S)(%S*)", function(first, rest)
    return first:upper() .. rest
  end)

  return s
end

function utils.pretty_mode_value(value)
  return _mode_display_names[value] or value
end

function utils.split3_by_dot(s)
  local a, b, c = s:match("^([^%.]+)%.([^%.]+)%.(.+)$")
  if a then return a, b, c end
  a, b = s:match("^([^%.]+)%.(.+)$")
  if a then return a, b, nil end
  return s, nil, nil
end

function utils.split_args(cmd)
  return cmd:match("^%s*(%S+)%s*(.*)$")
end

function utils.escape_lua_pattern(s)
  return (tostring(s or ""):gsub("(%W)", "%%%1"))
end

function utils.join_paths(a, b)
  if a:sub(-1) == "/" then return a .. b end
  return a .. "/" .. b
end

function utils.slice_balanced_braces(s, open_pos)
  local i, n = open_pos, #s
  local depth = 0
  local in_s, in_d = false, false
  local esc = false
  local in_line_comment, in_block_comment = false, false

  while i <= n do
    local c  = s:sub(i, i)
    local c2 = (i < n) and s:sub(i, i + 1) or ""

    if in_line_comment then
      if c == "\n" then in_line_comment = false end
    elseif in_block_comment then
      if c2 == "]]" then
        in_block_comment = false; i = i + 1
      end
    elseif in_s then
      if esc then
        esc = false
      elseif c == "\\" then
        esc = true
      elseif c == "'" then
        in_s = false
      end
    elseif in_d then
      if esc then
        esc = false
      elseif c == "\\" then
        esc = true
      elseif c == '"' then
        in_d = false
      end
    else
      if c2 == "--" then
        local c4 = (i + 3 <= n) and s:sub(i + 2, i + 3) or ""
        if c4 == "[[" then
          in_block_comment = true
          i = i + 3
        else
          in_line_comment = true
          i = i + 1
        end
      elseif c == "'" then
        in_s = true
      elseif c == '"' then
        in_d = true
      elseif c == '{' then
        depth = depth + 1
        if depth == 1 then open_pos = i end
      elseif c == '}' then
        depth = depth - 1
        if depth == 0 then
          return s:sub(open_pos, i)
        end
      end
    end

    i = i + 1
  end

  return nil -- unbalanced
end

function utils.get_directory_name(path)
  return path:match("^(.*)/[^/]+$") or "."
end

function utils.normalize_path(p)
  p = tostring(p or ""):gsub("[\r\n\t]", "")
  p = p:gsub("\\", "/"):gsub("/+", "/")
  if p ~= "" and p:sub(-1) ~= "/" then p = p .. "/" end
  return p
end

function utils.ensure_parent_dir(path)
  path = tostring(path or '')
  local dir = utils.get_directory_name(path)
  if dir and dir ~= '' and dir ~= '.' then
    return utils.ensure_dir(dir)
  end
  return true
end

function utils.ensure_dir(path)
  path = tostring(path or ''):gsub('\\', '/'):gsub('/+$', '')
  if path == '' then return false, 'empty path' end

  local prefix = ''
  local drive = path:match('^([A-Za-z]:)/')
  if drive then
    prefix = drive .. '/'
    path   = path:sub(#prefix + 1)
  elseif path:sub(1, 1) == '/' then
    prefix = '/'
    path   = path:sub(2)
  end

  local cur = prefix
  for seg in path:gmatch('[^/]+') do
    cur = cur .. seg .. '/'
    if windower and windower.dir_exists then
      if not windower.dir_exists(cur) then
        local ok, err = windower.create_dir(cur)
        if not ok then return false, err or ('create_dir failed: ' .. cur) end
      end
    else
      -- fallback for unit tests outside Windower; idempotent on Windows
      os.execute(string.format('mkdir "%s"', cur))
    end
  end
  return true
end

function utils.remove_file(path)
  if not path or path == "" then return false end
  if windower and windower.file_exists then
    if windower.file_exists(path) then
      os.remove(path)
      return true
    end
    return false
  else
    local ok = os.remove(path)
    return ok and true or false
  end
end

function utils.move_file(src, dst)
  src = tostring(src or "")
  dst = tostring(dst or "")
  if src == "" or dst == "" then return false, "src/dst required" end
  if src == dst then return true, nil end

  -- Ensure destination directory exists
  local ok_dir, err_dir = utils.ensure_parent_dir and utils.ensure_parent_dir(dst) or true, nil
  if not ok_dir then return false, err_dir or "failed to ensure parent dir" end

  -- Fast path: same-volume rename
  if os.rename(src, dst) then
    return true, nil
  end

  -- If rename failed because dst exists (Windows), try removing dst then rename
  if windower and windower.file_exists and windower.file_exists(dst) then
    pcall(os.remove, dst)
    if os.rename(src, dst) then
      return true, nil
    end
  end

  -- Fallback: buffered copy (handles cross-volume moves)
  local in_f, ierr = io.open(src, "rb")
  if not in_f then return false, ("open src failed: %s"):format(tostring(ierr)) end

  local out_f, oerr = io.open(dst, "wb")
  if not out_f then
    in_f:close(); return false, ("open dst failed: %s"):format(tostring(oerr))
  end

  local ok = true
  local bufsize = 64 * 1024
  while true do
    local chunk = in_f:read(bufsize)
    if not chunk then break end
    if not out_f:write(chunk) then
      ok = false
      break
    end
  end

  -- Close handles before proceeding
  out_f:flush(); out_f:close()
  in_f:close()

  if not ok then
    -- Best-effort cleanup of partial dst
    pcall(os.remove, dst)
    return false, "write failed during copy"
  end

  -- Remove original only after successful copy
  local rmok, rerr = os.remove(src)
  if not rmok then
    -- We successfully copied but couldn't remove source; caller can decide what to do
    return false, ("remove src failed: %s"):format(tostring(rerr))
  end

  return true, nil
end

function utils.wait_for_file(path, timeout_s, poll_s, on_found, on_timeout)
  local deadline = utils.now() + math.max(tonumber(timeout_s) or 0, 1.0)
  local interval = math.max(tonumber(poll_s) or 0, 0.10)

  local function step()
    if windower and windower.file_exists and windower.file_exists(path) then
      if on_found then pcall(on_found, path) end
      return
    end
    if utils.now() >= deadline then
      if on_timeout then pcall(on_timeout, path) end
      return
    end
    if coroutine and coroutine.schedule then
      coroutine.schedule(step, interval)
    else
      -- Non-Windower (tests): avoid spinning the CPU
      if socket and socket.sleep then socket.sleep(math.min(interval, 0.25)) end
      step()
    end
  end

  step()
end

function utils.atomic_write(dst, bytes)
  dst = tostring(dst or "")
  if dst == "" then return false, "dst required" end
  bytes = tostring(bytes or "")

  -- Ensure destination directory exists
  local ok_dir, err_dir = utils.ensure_parent_dir and utils.ensure_parent_dir(dst) or true, nil
  if not ok_dir then return false, err_dir or "failed to ensure parent dir" end

  -- Derive directory and basename
  local dir = dst:gsub("[/\\][^/\\]+$", "") .. (dst:find("[/\\]") and "" or "")
  if dir == "" then dir = "./" end
  local base   = dst:match("([^/\\]+)$") or "file"

  -- Create a temp file path in the same directory to keep rename on the same volume
  local rnd    = ("%08x%08x"):format((math.floor(os.clock() * 1e6) % 0x100000000),
    (math.random(0, 0xFFFF) * 0x10000 + math.random(0, 0xFFFF)))
  local tmp    = (dir == "./" and "" or dir) .. "." .. base .. ".tmp." .. rnd

  local f, err = io.open(tmp, "wb")
  if not f then return false, ("open tmp failed: %s"):format(tostring(err)) end
  if not f:write(bytes) then
    f:close(); pcall(os.remove, tmp)
    return false, "write tmp failed"
  end
  f:flush(); f:close()

  -- Replace existing dst if present (Windows rename won’t overwrite)
  if windower and windower.file_exists and windower.file_exists(dst) then
    pcall(os.remove, dst)
  else
    -- If no windower, do a best-effort remove without checking
    pcall(os.remove, dst)
  end

  local rok, rerr = os.rename(tmp, dst)
  if not rok then
    pcall(os.remove, tmp)
    return false, ("rename failed: %s"):format(tostring(rerr))
  end

  return true, nil
end

do
  utils.__dir_cache = utils.__dir_cache or { map = {}, ttl = 0.25 }

  function utils.get_dir_cached(dir, ttl_s)
    dir = tostring(dir or "")
    if dir == "" then return {} end
    local now = os.clock()
    local ttl = tonumber(ttl_s) or utils.__dir_cache.ttl

    local ent = utils.__dir_cache.map[dir]
    if ent and (now - ent.t) <= ttl then
      return ent.list
    end

    local list = {}
    if windower and windower.get_dir then
      local ok, res = pcall(windower.get_dir, dir)
      if ok and type(res) == "table" then list = res end
    end

    utils.__dir_cache.map[dir] = { list = list, t = now }
    return list
  end

  function utils.clear_dir_cache()
    utils.__dir_cache.map = {}
  end

  function utils.set_dir_cache_ttl(ttl_s)
    utils.__dir_cache.ttl = tonumber(ttl_s) or 0.25
  end
end

function utils.starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

function utils.starts_with_any(s, prefixes)
  if prefixes == nil then return false end
  -- single string
  if type(prefixes) == "string" then
    return utils.starts_with(s, prefixes), prefixes
  end

  -- list/array: prefer numeric 1..n iteration so order is preserved
  local n = (type(prefixes) == "table" and (prefixes.n or #prefixes)) or 0
  for i = 1, n do
    local p = prefixes[i]
    if type(p) == "string" and utils.starts_with(s, p) then
      return true, p
    end
  end

  -- fallback for non-array tables (if someone passed a set-like table)
  for _, p in pairs(prefixes) do
    if type(p) == "string" and utils.starts_with(s, p) then
      return true, p
    end
  end

  return false
end

function utils.ends_with(s, suffix)
  return s:sub(- #suffix) == suffix
end

function utils.ensure_prefix(s, prefix)
  s = tostring(s or "")
  prefix = tostring(prefix or "")
  if prefix == "" then return s end

  if utils.starts_with(s, prefix) then return s end

  return prefix .. s
end

function utils.ensure_suffix(s, suffix)
  s = tostring(s or "")
  suffix = tostring(suffix or "")
  if suffix == "" then return s end

  if utils.ends_with(s, suffix) then return s end

  return s .. suffix
end

function utils.get_array_values(array)
  local values = L {}

  if type(array) ~= 'table' then return values end
  for i = 1, #array do values:append(array[i]) end

  return values
end

function utils.get_mode_options(mode)
  return utils.get_array_values(mode and (mode.options or mode))
end

function utils.ascii_only(s)
  s = tostring(s or ""):gsub("[\r\n]", " ")
  s = s:gsub("[%z\1-\8\11\12\14-\31]", "")
  return s
end

function utils.print_help_topic(topic)
  if not topic then return end

  print(topic.title .. " — " .. (topic.desc or ""))
  if topic.usage and #topic.usage > 0 then
    print("Usage:"); for i = 1, #topic.usage do print(topic.usage[i]) end
  end
  if topic.params and #topic.params > 0 then
    print("Params:"); for i = 1, #topic.params do print(topic.params[i]) end
  end
  if topic.examples and #topic.examples > 0 then
    print("Examples:"); for i = 1, #topic.examples do print(topic.examples[i]) end
  end
  if topic.dynamic then
    local ok, dyn = pcall(topic.dynamic); if ok and dyn and dyn ~= "" then print(dyn) end
  end
end

function utils.sanitize_spell_name(name)
  return (tostring(name or ""):gsub("%.", ""):gsub("'", ""):gsub("%s+", "_"):lower())
end

function utils.sanitize(name)
  return (tostring(name or ""):gsub("'", ""):gsub("%s+", "_"):lower())
end

local function get_sanitized_name_parts(name)
  return utils.split3_by_dot(utils.sanitize(name))
end
function utils.sanitize_set_name(name)
  if not name then return nil, "Name is required." end

  local p1, p2, p3 = get_sanitized_name_parts(name)
  if not p1 then return nil, "Invalid name: " .. name end

  return utils.sanitize(name), nil
end

return utils
