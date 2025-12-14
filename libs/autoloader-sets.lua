-- SPDX-License-Identifier: BSD-3-Clause
-- Copyright (c) 2025 NeatMachine

local log = require("autoloader-logger")
local utils = require("autoloader-utils")
local codex = require("autoloader-codex")
local ok_ext, extdata = pcall(require, "extdata")
local res = require("resources")

_G.sets = _G.sets or {}
local sets = _G.sets

local _root = sets._root or (windower and windower.addon_path) or "."

local _cache = {}

sets.naked = {
  head = empty,
  body = empty,
  hands = empty,
  legs = empty,
  feet = empty,
  back = empty,
  left_ring = empty,
  right_ring = empty,
  left_ear = empty,
  right_ear = empty,
  neck = empty,
  waist = empty
}

local function get_exported_file_prefix()
  if not windower or not windower.ffxi or not windower.ffxi.get_player then return nil end
  return windower.ffxi.get_player().name .. "_"
end

local function get_directory(dir)
  utils.ensure_dir(dir)
  -- Use cached listing with a short TTL to reduce IO/focus hiccups
  return utils.get_dir_cached(dir, 0.25)
end

local function list_files(dir)
  dir = utils.normalize_path(dir)
  local entries = get_directory(dir)
  log.debug("Listing files under " .. dir)

  local files = {}
  for _, name in ipairs(entries) do
    if name:sub(-1) ~= "/" then
      files[#files + 1] = name
    end
  end
  table.sort(files)
  return files
end

local function get_export_path()
  return utils.join_paths(_root, ("data/export"))
end

local function get_job_path()
  return utils.join_paths(_root, ("data/autoloader/jobs/%s"):format(player.main_job:lower()))
end

local function get_auto_path()
  return utils.join_paths(get_job_path(), ("auto"))
end

local function get_job_prefix()
  return player.main_job:lower() .. "."
end

local function get_exported_file_name(set_name)
  set_name = utils.ensure_prefix(set_name, get_job_prefix())
  return ("%s%s.lua"):format(get_exported_file_prefix(), set_name)
end

local function compile_table_expr(table_src, chunkname)
  local code = "return " .. table_src
  if _G.loadstring then
    local fn, err = loadstring(code, chunkname or "@AutoLoader:table")
    if not fn then return nil, err end
    if setfenv then setfenv(fn, {}) end
    return fn, nil
  else
    return load(code, chunkname or "@AutoLoader:table", "t", {})
  end
end

local function load_set(abs_filename)
  if not windower.file_exists(abs_filename) then
    log.debug("File: " .. abs_filename .. " does not exist.")
    return
  end

  local f, ferr = io.open(abs_filename, "rb")
  if not f then
    log.debug(("Couldn't open file %s: %s"):format(abs_filename, tostring(ferr)))
    return
  end

  local src = f:read("*a"); f:close()
  if not src or src == "" then
    log.debug("Empty file: " .. abs_filename)
    return
  end

  local normalized_content = src:lower()
  local anchor_pos, label

  anchor_pos = normalized_content:find("return%s*%{")
  if anchor_pos then
    label = "return"
  else
    anchor_pos = normalized_content:find("sets%s*%.%s*exported%s*=%s*%{")
    if anchor_pos then
      label = "sets.exported"
    else
      anchor_pos = normalized_content:find("sets%s*=%s*%{")
      if anchor_pos then
        label = "sets"
      end
    end
  end

  if not anchor_pos then
    log.debug(("Couldn't parse %s, no table anchor (return/sets.exported/sets) found"):format(abs_filename))
    return
  end

  local brace_pos = normalized_content:find("%{", anchor_pos)
  if not brace_pos then
    log.debug(("Couldn't parse %s, anchor without opening brace"):format(abs_filename))
    return
  end

  local table_src = utils.slice_balanced_braces(src, brace_pos)
  if not table_src then
    log.debug(("Couldn't parse %s, unbalanced braces"):format(abs_filename))
    return
  end

  local fn, cerr = compile_table_expr(table_src, "@AutoLoader:" .. (abs_filename or "set"))
  if not fn then
    log.debug(("%s compilation failed: %s"):format(abs_filename, tostring(cerr)))
    return
  end

  local ok, result = pcall(fn)
  if not ok then
    log.debug(("%s evaluation failed: %s"):format(abs_filename, tostring(result)))
    return
  end

  if result == nil then
    log.debug(("Loaded %s (%s) but it produced nil"):format(abs_filename, label or "?"))
  else
    log.debug(("Loaded %s (%s)"):format(abs_filename, (label or "?")))
    return result
  end
end

function sets.build_set(...)
  local args = { ... }

  if #args == 1 and type(args[1]) == "table" then
    args = args[1]
  end

  local combined, count = nil, 0
  for i, name in ipairs(args) do
    local n = utils.sanitize(name)
    local part = sets.get(n)

    if type(part) == "table" then
      combined = (combined == nil) and part or set_combine(combined or {}, part or {})
      count = count + 1
      log.debug(("Added %s"):format(n))
    else
      if part == nil then
        log.debug(("Set not found %s"):format(n))
      else
        log.debug(("%s returned %s; skipped"):format(n, type(part)))
      end
    end
  end

  if not combined then
    log.debug("No sets resolved")
    return nil
  end

  log.debug(("Combined %d set(s)"):format(count))
  return combined
end

function sets.get(name, use_auto_sets)
  if not name or type(name) ~= "string" then return nil end

  name = utils.sanitize(name)
  local filename = ("%s%s%s.lua"):format(get_exported_file_prefix(), get_job_prefix(), name)

  -- Return cached set
  if _cache and _cache[name] then
    return _cache[name]
  end

  -- Try to load set from current job path
  local job_file = utils.join_paths(get_job_path(), filename)
  local set = windower.file_exists(job_file) and load_set(job_file)
  if set then
    _cache[name] = set
    return _cache[name]
  end

  if not use_auto_sets or use_auto_sets == true then
    -- Try to load set from auto-generated folder
    local auto_file = utils.join_paths(get_auto_path(), filename)
    local auto_set = windower.file_exists(auto_file) and load_set(auto_file)
    if auto_set then
      _cache[name] = auto_set
      return _cache[name]
    end
  end
end

function sets.save(name)
  if not name then return false, "Name is required." end

  local sanitized_name, err = utils.sanitize(name)
  if not sanitized_name then return false, err end

  local exported_filename = get_exported_file_name(sanitized_name)
  local exported_file = utils.join_paths(get_export_path(), exported_filename)

  if windower.file_exists(exported_file) then
    utils.remove_file(exported_file)
    log.debug("Deleted existing file: " .. exported_file)
  end

  local gearswap_export_cmd = ("gs export filename %s%s"):format(get_job_prefix(), sanitized_name)
  log.debug(("Exporting via GearSwap: %s"):format(gearswap_export_cmd))
  windower.send_command(gearswap_export_cmd)

  utils.wait_for_file(
    exported_file,
    3, 0.25,
    function(_)
      local target_file = utils.join_paths(get_job_path(), exported_filename)
      local ok, err = utils.move_file(exported_file, target_file)
      if ok then
        log.info("Saved: " .. target_file)
      else
        log.error(("Failed to move file %s with error: %s"):format(target_file, err))
      end
    end,
    function(_)
      log.error(("Could not find GearSwap export, expected: %s"):format(exported_file))
    end
  )

  return nil, nil
end

function sets.delete(set_name)
  set_name = utils.sanitize(set_name)
  local dir, char_prefix, job_prefix = get_job_path(), get_exported_file_prefix(), get_job_prefix()
  local filename = ("%s/%s%s%s.lua"):format(dir, char_prefix, job_prefix, set_name)
  if windower.file_exists(filename) then
    utils.remove_file(filename)
    return true, nil
  else
    return false, "Could not find file: " .. filename
  end
end

-- Read a weapon display name from the top of the file, if present.
-- Expects the first line to look like: "-- name: Caladbolg"
local function read_weapon_display_name(abs_filename)
  local f, err = io.open(abs_filename, "rb")
  if not f then
    log.debug(("Couldn't open %s: %s"):format(abs_filename, tostring(err)))
    return nil
  end

  local first_line = f:read("*l") or ""
  f:close()

  local name = first_line:match("^%s*%-%-%s*name:%s*(.-)%s*$")
  if name and name ~= "" then
    return name
  end

  return nil
end

-- Write or update the name header at the top of the file.
local function write_weapon_display_name(abs_filename, display_name)
  display_name = tostring(display_name or ""):gsub("[\r\n]", " "):gsub("^%s+", ""):gsub("%s+$", "")

  local f, err = io.open(abs_filename, "rb")
  if not f then
    return false, ("Could not open %s for reading: %s"):format(abs_filename, tostring(err))
  end

  local src = f:read("*a") or ""
  f:close()

  if src == "" then
    return false, "File is empty: " .. abs_filename
  end

  local header = ("-- name: %s"):format(display_name)
  local first_line, rest = src:match("^([^\n]*)\n(.*)$")

  if first_line then
    if first_line:match("^%s*%-%-%s*name:") then
      -- Replace existing header
      src = header .. "\n" .. rest
    else
      -- Prepend new header
      src = header .. "\n" .. src
    end
  else
    -- Single-line file
    if src:match("^%s*%-%-%s*name:") then
      src = header
    else
      src = header .. "\n" .. src
    end
  end

  local out, werr = io.open(abs_filename, "wb")
  if not out then
    return false, ("Could not open %s for writing: %s"):format(abs_filename, tostring(werr))
  end

  out:write(src)
  out:close()
  return true, nil
end

local function get_weapon_id_from_filename(filename)
  -- Example filename: "Seloan_rdm.weapon3.lua"
  local char_prefix = get_exported_file_prefix() -- "Seloan_"
  local job_prefix  = get_job_prefix()           -- "rdm."
  local prefix      = char_prefix .. job_prefix  -- "Seloan_rdm."

  if not utils.starts_with(filename, prefix) then return nil end
  if filename:sub(-4) ~= ".lua" then return nil end

  -- Strip prefix + ".lua" to get the logical set name
  local set_name = filename:sub(#prefix + 1, -5) -- "weapon3"

  local id_str = set_name:match("^weapon(%d+)$")
  if not id_str then return nil end

  local id = tonumber(id_str)
  if not id then return nil end

  return id
end

function sets.get_weapons()
  local weapons = {}

  local dir = get_job_path()
  local files = list_files(dir)

  log.debug(("Scanning %d files for weapon sets under %s"):format(#files, dir))

  for _, filename in ipairs(files) do
    local id = get_weapon_id_from_filename(filename)
    if id then
      local abs_path = utils.join_paths(dir, filename)
      local set = load_set(abs_path)

      if set then
        local display_name = read_weapon_display_name(abs_path)

        -- Fallback: if no header yet, try to infer from main weapon
        if not display_name and type(set) == "table" then
          display_name = set.main or set.range or set.ranged or nil
        end

        local weapon = {
          id       = id,
          name     = display_name,
          set      = set,
          filename = abs_path,
        }

        weapons[id] = weapon
      else
        log.debug(("Skipping weapon file %s (failed to load)"):format(filename))
      end
    end
  end

  return weapons
end

function sets.get_weapon(id)
  id = tonumber(id)
  if not id then return nil end
  local weapons = sets.get_weapons() or {}
  return weapons[id]
end

function sets.save_weapon(id, name)
  -- ID is the integer slot/index for this weapon (e.g. 3)
  if not id then return false, "Weapon ID is required." end

  local numeric_id = tonumber(id)
  if not numeric_id then
    return false, "Weapon ID must be numeric. Got: " .. tostring(id)
  end

  -- Human-friendly display name for the weapon ("Caladbolg", etc.)
  local display_name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")

  local weapon_identifier = "weapon" .. tostring(numeric_id)

  local ok, err = sets.save(weapon_identifier)
  if ok == false then
    return false, err
  end

  -- Compute where save_async will move the file
  local filename   = ("%s%s%s.lua"):format(get_exported_file_prefix(), get_job_prefix(), weapon_identifier)
  local saved_file = utils.join_paths(get_job_path(), filename)

  utils.wait_for_file(
    saved_file,
    0.7, 0.1,
    function(path)
      local w_ok, w_err = write_weapon_display_name(path, display_name)
      if not w_ok then
        log.error(("Failed to write weapon metadata for %s: %s"):format(path, tostring(w_err)))
      else
        log.info(
          ("Saved weapon %d (%s) to %s"):format(numeric_id, display_name ~= "" and display_name or "", path)
        )
      end
    end,
    function(path)
      log.error(("Could not find saved weapon file, expected: %s"):format(saved_file))
    end
  )

  return true, nil
end

function sets.delete_weapon(id)
  if not id then return false, "Weapon ID is required." end

  local numeric_id = tonumber(id)
  if not numeric_id then
    return false, "Weapon ID must be numeric. Got: " .. tostring(id)
  end

  local weapon_identifier = "weapon" .. tostring(numeric_id)
  local ok, err = sets.delete(weapon_identifier)

  if ok then
    log.info(("Deleted weapon %d (%s)"):format(numeric_id, weapon_identifier))
  end

  return ok, err
end

function sets.list()
  return list_files(get_job_path())
end

function sets.clear_cache()
  _cache = {}
  log.debug("Cache cleared.")
end

local function sanitize_description(raw)
  raw = tostring(raw or "")

  -- Normalize punctuation, drop quotes, lower-case
  raw = raw
      :gsub("[\r\n\t]", " ")
      :gsub("’", "'"):gsub("‘", "'")
      :gsub("“", '"'):gsub("”", '"')
      :gsub("–", "-"):gsub("—", "-")
      :gsub("…", "...")
      :gsub("→", "->"):gsub("←", "<-"):gsub("↔", "<->")
      :gsub('"', "") -- drop quotes
      :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      :lower()

  -- Hard separators first (leave periods alone!)
  local chunks, lines = {}, {}

  for seg in string.gmatch(raw, "([^/|]+)") do
    seg = seg:gsub("^%s+", ""):gsub("%s+$", "")
    if seg ~= "" then chunks[#chunks + 1] = seg end
  end

  -- Then split on commas only
  for i = 1, #chunks do
    local s = chunks[i]
    for piece in string.gmatch(s, "([^,]+)") do
      piece = piece:gsub("^%s+", ""):gsub("%s+$", "")
      if piece ~= "" then lines[#lines + 1] = piece end
    end
  end

  -- Filter latent/event-only lines (simple substring match)
  local filtered = {}
  local skip_list = codex.LATENTS or {}
  for i = 1, #lines do
    local ln, skip = lines[i], false
    for j = 1, #skip_list do
      local needle = skip_list[j]
      if needle and needle ~= "" and ln:find(needle, 1, true) then
        skip = true
        break
      end
    end
    if not skip then filtered[#filtered + 1] = ln end
  end

  return filtered, raw
end

-- Parse a single item's description into canonical stats and enhancements.
-- - Longest-alias-first with word-frontier boundaries
-- - Consumes matched text from the line (prevents alias collisions/double count)
-- - PET: prefix handled; writes as pet_<stat>
-- - Lines with ranges '～' or '~' => enhancement (avoid false numeric)
-- - Invert negatives only for stats in codex.INVERTED_STATS (and only if < 0)
local function parse_description(item, ext)
  local function escape_lua_pattern(s)
    return (s:gsub("(%W)", "%%%1"))
  end

  -- Build ordered matchers from codex.STAT_ALIASES (lowercased, quotes removed)
  local function build_matchers()
    local out = {}
    local aliases = codex.STAT_ALIASES or {}
    for stat_key, alias_list in pairs(aliases) do
      for i = 1, #alias_list do
        local alias = tostring(alias_list[i] or ""):lower()
        if alias ~= "" then
          alias                = alias:gsub('"', '') -- mirror sanitize()
          local esc            = escape_lua_pattern(alias)

          -- Word-frontier boundaries when alias begins/ends with alnum
          local first_is_alnum = alias:match("^%w") ~= nil
          local last_is_alnum  = alias:match("%w$") ~= nil
          local left           = first_is_alnum and "%f[%w]" or ""
          local right          = last_is_alnum and "%f[%W]" or ""

          -- Allow optional : or = after the alias unless alias already ends with one
          local sep            = (alias:find("[:=]$") and "%s*") or "%s*[:=]?"

          -- Pattern: <alias><sep><num><%?>
          local pat            = left .. esc .. right .. sep .. "%s*([+-]?%d+%.?%d*)%s*(%%?)"

          out[#out + 1]        = { stat_key = stat_key, alias = alias, pattern = pat, alias_len = #alias }
        end
      end
    end
    table.sort(out, function(a, b) return a.alias_len > b.alias_len end)
    return out
  end

  local matchers     = build_matchers()
  local desc_text    = tostring(item.description or "")
  local desc_lines   = (function()
    local lines = {}
    local sanitized = sanitize_description(desc_text) -- returns (lines, raw); we only need lines here
    if type(sanitized) == "table" then
      lines = sanitized
    else
      -- if sanitize_description returns (lines, raw) tuple, handle that:
      local lns = { sanitize_description(desc_text) }
      lines = lns[1] or {}
    end
    return lines
  end)()

  local stats        = {}
  local enhancements = {} -- key -> { count, last_text }
  local enh_verbs    = codex.ENHANCEMENT_VERBS or
      { "enhances", "improves", "augments", "increases", "reduces", "adds", "occasionally" }
  local inverted     = codex.INVERTED_STATS or {}

  local function add_stat(stat_key, val)
    local n = tonumber(val)
    if not n then return end
    if n < 0 and inverted[stat_key] then n = -n end -- flip only when negative + inverted
    stats[stat_key] = (stats[stat_key] or 0) + n
  end

  local function add_enhancement(key, text)
    key = tostring(key or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if key == "" then return end
    local e           = enhancements[key] or { count = 0, last_text = "" }
    e.count           = e.count + 1
    e.last_text       = text or e.last_text
    enhancements[key] = e
  end

  local function has_range_token(ln)
    return (ln:find("～") or ln:find("~")) ~= nil
  end

  local function scan_aliases_into_stats(ln, is_pet)
    local matched_any = false

    -- Entire line carries a range => enhancement, not numeric parse
    if has_range_token(ln) then
      add_enhancement(is_pet and "pet range" or "range", ln)
      return true
    end

    -- Try every matcher (longest-first). Consume the matched text from ln to
    -- prevent smaller aliases from re-matching inside larger phrases.
    for m = 1, #matchers do
      local mt = matchers[m]
      local count_this_alias = 0
      ln = ln:gsub(mt.pattern, function(num, pct)
        count_this_alias = count_this_alias + 1
        if is_pet then
          add_stat("pet_" .. mt.stat_key, num)
        else
          add_stat(mt.stat_key, num)
        end
        return "" -- consume the matched region
      end)
      if count_this_alias > 0 then matched_any = true end
    end

    return matched_any
  end

  for i = 1, #desc_lines do
    local ln = desc_lines[i]

    -- PET: … lines
    local pet_rest = ln:match("^%s*pet%s*[:%-]?%s*(.+)$")
    if pet_rest and pet_rest ~= "" then
      local consumed = scan_aliases_into_stats(pet_rest, true)
      if not consumed then
        add_enhancement("pet", ln)
      end
    else
      -- Normal stat lines
      local consumed = scan_aliases_into_stats(ln, false)
      if not consumed then
        -- Enhancement-y lines: verb-led or unknown-name with trailing +/-N or ranges
        local verb_hit = false
        for _, v in ipairs(enh_verbs) do
          if ln:find(v, 1, true) then
            verb_hit = true
            break
          end
        end
        if verb_hit or ln:match("^[%a%p%s]+[%+%-]%d+") or has_range_token(ln) then
          local key = ln:match("^([%a%p%s]-)%s*[%+%-]?%d*%%?") or ln
          key = (key or ""):gsub("[%s%p]+$", ""):gsub("^%s+", "")
          if key == "" then key = ln end
          add_enhancement(key, ln)
        end
      end
    end
  end

  -- Known “silent” bonuses by item id (real stats)
  local known = (codex.KNOWN_ENHANCED_BY_ID or {})[item.id or -1]
  if known then
    for k, v in pairs(known) do add_stat(k, v) end
  end

  return {
    id              = item.id,
    name            = item.en or item.enl or item.name,
    -- Keep your logging choice: if you removed raw_desc from logs, you can omit it in the caller.
    raw_description = tostring(item.description or ""),
    description     = table.concat(desc_lines, " | "),
    stats           = stats,
    enhancements    = enhancements,
  }
end

local function get_augments_from_entry(entry)
  if not ok_ext or not entry or not entry.extdata then return nil end
  local ok, ex = pcall(extdata.decode, entry)
  if not ok or type(ex) ~= 'table' then return nil end
  local a = ex.augments
  if type(a) == 'table' and #a > 0 then
    local out = {}
    for _, v in ipairs(a) do if v and v ~= '' then out[#out + 1] = v end end
    if #out > 0 then return out end
  end
  return nil
end

local function get_available_items()
  local items = windower.ffxi.get_items() or {}
  local rows = {}

  local default_bags = { 'inventory', 'wardrobe', 'wardrobe2', 'wardrobe3', 'wardrobe4', 'wardrobe5', 'wardrobe6',
    'wardrobe7', 'wardrobe8' }
  local bag_keys = codex.BAG_KEYS or default_bags

  for _, bag_key in ipairs(bag_keys) do
    local bag = items[bag_key]
    if type(bag) == 'table' and type(bag.max) == 'number' then
      for slot = 1, bag.max do
        local entry = bag[slot]
        if type(entry) == 'table' and entry.id and entry.id > 0 then
          local it = res.items[entry.id]
          if it then
            -- stitch in description from resource table if available
            local desc_res = res.item_descriptions and res.item_descriptions[entry.id]
            local desc = (desc_res and (desc_res.en or desc_res.enl)) or it.description or ""
            rows[#rows + 1] = {
              bag       = bag_key,
              slot      = slot,
              entry     = entry,
              item      = it,
              id        = it.id,
              name      = it.en or it.enl or it.name,
              category  = (it.category or ""):lower(),
              desc_text = desc,
            }
          end
        end
      end
    end
  end

  return rows
end

local function player_can_equip(e)
  if not e or not e.category or e.category:lower() ~= "armor" then return false end

  -- Lvl req
  if not e.level or e.level > player.main_job_level then return false end

  -- Job req
  local jobs = e.jobs and e.jobs:map(function(v, k) return res.jobs[v] and res.jobs[v].ens end)
  if not jobs or not jobs[player.main_job] then return false end

  -- Race/Gender req
  local player_mob = windower.ffxi.get_mob_by_index(player.index)
  local race = player_mob and player_mob.race
  if not e.races or not e.races[race] then return false end

  -- Su check
  if e.superior_level and e.superior_level > player.superior_level then return false end

  return true
end

local function find_available_equipment()
  local entries = get_available_items()
  log.debug(("Scanned %d bag entries."):format(#entries))

  local out = {}
  for i = 1, #entries do
    local rec = entries[i]
    if player_can_equip(rec.item) then
      local ext        = get_augments_from_entry(rec.entry)
      local parse_item = {
        id          = rec.id,
        name        = rec.name,
        en          = rec.item.en,
        enl         = rec.item.enl,
        description = rec.desc_text,
      }
      local parsed     = parse_description(parse_item, ext)

      out[#out + 1]    = {
        id           = rec.id,
        name         = rec.name,
        slots        = rec.item.slots,
        parsed_stats = parsed.stats,
        enhancements = parsed.enhancements,
        description  = parsed.description,     -- normalized
        raw_desc     = parsed.raw_description, -- original text
        augments     = ext or nil,
      }
    end
  end

  table.sort(out, function(a, b)
    local an, bn = tostring(a.name or ""), tostring(b.name or "")
    if an == bn then return (a.id or 0) < (b.id or 0) end
    return an < bn
  end)

  log.debug(("%d equippable items."):format(#out))

  return out
end

local function calculate_auto_sets(level, threshold, beam_k)
  local thr = tonumber(threshold) or 0
  if thr > 1 then thr = thr / 100 end
  if thr < 0 then thr = 0 end

  beam_k = tonumber(beam_k) or 40
  if beam_k < 1 then beam_k = 1 end

  -- default: no pruning by dots unless level is a valid number
  local max_dots = tonumber(level)
  if not max_dots or max_dots < 0 then max_dots = math.huge end

  -- Build a filtered COPY so we don't mutate the codex tables in place
  local raw_map = codex.set_functions or codex.SET_FUNCTIONS or {}
  if type(raw_map) ~= "table" or next(raw_map) == nil then
    log.error("No codex.set_functions/SET_FUNCTIONS found; aborting.")
    return {}
  end
  local calc_map = {}
  for k, fn in pairs(raw_map) do
    if type(fn) == "function" then
      local dots = (type(k) == "string") and select(2, k:gsub("%.", "")) or 0
      if dots <= max_dots then
        calc_map[k] = fn
      end
    end
  end

  local targets = {}
  for key in pairs(calc_map) do
    targets[#targets + 1] = key
  end
  table.sort(targets)
  if #targets == 0 then
    log.error("No callable scorers in codex set_functions after filtering; aborting.")
    return {}
  end

  local items = find_available_equipment() or {}

  -- Map numeric slot -> candidates
  local slot_to_items = {}
  for _, rec in ipairs(items) do
    for slot_num, allowed in pairs(rec.slots or {}) do
      if allowed then
        local t = slot_to_items[slot_num]
        if not t then t = {}; slot_to_items[slot_num] = t end
        t[#t + 1] = rec
      end
    end
  end

  for _, pool in pairs(slot_to_items) do
    table.sort(pool, function(a, b)
      local na, nb = a.name or "", b.name or ""
      if na ~= nb then return na < nb end
      return (a.id or 0) < (b.id or 0)
    end)
  end

  local slot_num_to_key = {
    [4]  = "head",
    [5]  = "body",
    [6]  = "hands",
    [7]  = "legs",
    [8]  = "feet",
    [9]  = "neck",
    [10] = "waist",
    [15] = "back",
    [11] = "left_ear",
    [12] = "right_ear",
    [13] = "left_ring",
    [14] = "right_ring",
  }
  local ordered_slots = { 4, 5, 6, 7, 8, 9, 10, 15, 11, 12, 13, 14 }

  local function add_stats(dst, add)
    for k, v in pairs(add or {}) do
      if type(v) == "number" then dst[k] = (dst[k] or 0) + v end
    end
  end
  local function sub_stats(dst, sub)
    for k, v in pairs(sub or {}) do
      if type(v) == "number" then dst[k] = (dst[k] or 0) - v end
    end
  end
  local function eval_score(fn, totals)
    local ok, val = pcall(fn, totals)
    return (ok and (tonumber(val) or 0)) or 0
  end

  local results = {}

  for _, target_key in ipairs(targets) do
    local score_fn = calc_map[target_key]

    local _, dots = string.gsub(target_key, "%.", "")
    local set_threshold = thr * (dots + 1)

    -- Global “meaningful change” scale G = best single-piece score.
    local S1 = 0
    for _, rec in ipairs(items) do
      local s = eval_score(score_fn, rec.parsed_stats or {})
      if s > S1 then S1 = s end
    end
    local G = math.max(math.abs(S1), 1e-6)

    -- Beam state (start from empty)
    local beam = { {
      slots    = {},
      totals   = {},
      used_ids = {},
      score    = eval_score(score_fn, {}), -- baseline
    } }

    for _, slot_num in ipairs(ordered_slots) do
      local slot_key = slot_num_to_key[slot_num]
      if slot_key then
        local pool = slot_to_items[slot_num] or {}
        local next_beam = {}

        for _, state in ipairs(beam) do
          -- Option A: keep empty
          next_beam[#next_beam + 1] = state

          -- Option B: try each item
          for _, it in ipairs(pool) do
            if not state.used_ids[it.id] then
              local new_totals = {}
              for k, v in pairs(state.totals) do new_totals[k] = v end
              add_stats(new_totals, it.parsed_stats)

              local new_score = eval_score(score_fn, new_totals)
              local delta     = new_score - state.score

              -- Require absolute improvement versus global scale
              if delta >= (set_threshold * G) then
                local new_used = {}
                for k, v in pairs(state.used_ids) do new_used[k] = v end
                new_used[it.id] = true

                local new_slots = {}
                for k, v in pairs(state.slots) do new_slots[k] = v end
                new_slots[slot_key] = it

                next_beam[#next_beam + 1] = {
                  slots    = new_slots,
                  totals   = new_totals,
                  used_ids = new_used,
                  score    = new_score,
                }
              end
            end
          end
        end

        table.sort(next_beam, function(a, b) return a.score > b.score end)
        if #next_beam > beam_k then
          for i = beam_k + 1, #next_beam do next_beam[i] = nil end
        end
        beam = next_beam
      end
    end

    table.sort(beam, function(a, b) return a.score > b.score end)
    local best = beam[1] or { slots = {}, totals = {}, score = eval_score(score_fn, {}) }

    -- Final sparse-set prune: remove slots whose contribution < thr * max(|best.score|, G)
    do
      local target_floor = set_threshold * math.max(math.abs(best.score), G)
      local slot_order = { "head","body","hands","legs","feet","neck","waist","back","left_ear","right_ear","left_ring","right_ring" }
      for _, sk in ipairs(slot_order) do
        local it = best.slots[sk]
        if it then
          local totals_without = {}
          for k, v in pairs(best.totals) do totals_without[k] = v end
          sub_stats(totals_without, it.parsed_stats)

          local score_without = eval_score(score_fn, totals_without)
          local drop = best.score - score_without

          if drop < target_floor then
            best.slots[sk] = nil
            best.totals    = totals_without
            best.score     = score_without
            target_floor   = set_threshold * math.max(math.abs(best.score), G)
          end
        end
      end
    end

    local out_slots, out_ids = {}, {}
    for sk, it in pairs(best.slots) do
      out_slots[sk] = it.name
      out_ids[sk]   = it.id
    end

    results[target_key] = {
      slots  = out_slots,
      ids    = out_ids,
      totals = best.totals,
      score  = best.score,
    }
  end

  return results
end


local function write_auto_set(setkey, result)
  if not setkey or result == nil then
    log.error("write_auto_set: setkey and result are required")
    return false, "bad args"
  end

  -- sanitize name and resolve output path
  local key, err = utils.sanitize_set_name(setkey)
  if not key then
    log.error("write_auto_set: " .. tostring(err))
    return false, err
  end

  local dir_ok, dir_err = utils.ensure_dir(get_auto_path())
  if not dir_ok then
    log.error(("write_auto_set: ensure_dir failed for %s: %s"):format(get_auto_path(), tostring(dir_err)))
    return false, dir_err
  end

  local fname  = ("%s%s%s.lua"):format(
    get_exported_file_prefix(), -- e.g. "Seloan_"
    get_job_prefix(),           -- e.g. "rdm."
    key                         -- e.g. "enfeebling_core"
  )
  local path   = utils.join_paths(get_auto_path(), fname)

  -- tolerate both shapes (full result vs. plain slots)
  local slots  = (type(result) == "table" and (result.slots or result)) or {}
  local score  = (type(result) == "table" and tonumber(result.score)) or nil
  local totals = (type(result) == "table" and result.totals) or nil
  local ids    = (type(result) == "table" and result.ids) or nil

  local function esc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    return s
  end

  local order = {
    "head", "body", "hands", "legs", "feet",
    "neck", "waist", "back",
    "left_ear", "right_ear",
    "left_ring", "right_ring",
  }

  -- build file contents
  local buf = {}
  buf[#buf + 1] = "return {\n"
  for _, sk in ipairs(order) do
    local name = slots[sk]
    if type(name) == "string" and name ~= "" then
      buf[#buf + 1] = ('  %s = "%s",\n'):format(sk, esc(name))
    end
  end

  -- helpful metadata as comments
  if score then
    buf[#buf + 1] = ('  -- score = %.6f\n'):format(score)
  end
  if ids and type(ids) == "table" then
    buf[#buf + 1] = "  -- ids = {"
    local first = true
    for sk, id in pairs(ids) do
      if first then first = false else buf[#buf + 1] = ", " end
      buf[#buf + 1] = tostring(sk) .. "=" .. tostring(id)
    end
    buf[#buf + 1] = " }\n"
  end
  if totals and type(totals) == "table" then
    buf[#buf + 1] = "  -- totals = {"
    local first = true
    for k, v in pairs(totals) do
      if type(v) == "number" then
        if first then first = false else buf[#buf + 1] = ", " end
        buf[#buf + 1] = tostring(k) .. "=" .. tostring(v)
      end
    end
    buf[#buf + 1] = " }\n"
  end
  buf[#buf + 1] = "}\n"

  local ok, werr = utils.atomic_write(path, table.concat(buf))
  if not ok then
    log.error(("write_auto_set: failed to write %s: %s"):format(path, tostring(werr)))
    return false, werr
  end

  return true, path
end

function sets.generate_auto_sets(level, threshold, beam_k, spacing_s)
  -- Build the sets first (sync)
  local auto_sets = calculate_auto_sets(level, threshold, beam_k)
  if type(auto_sets) ~= "table" or next(auto_sets) == nil then
    log.error("generate_auto_sets: calculate_auto_sets returned no results.")
    return false, auto_sets
  end

  -- Stable order for deterministic writes/logs
  local keys = {}
  for k in pairs(auto_sets) do keys[#keys + 1] = k end
  table.sort(keys)

  local spacing = tonumber(spacing_s) or 0.5
  local thr = tonumber(threshold) or 0
  thr = (thr > 1) and thr or (thr * 100)

  -- Schedule each file write; do not wait for completion
  for i, key in ipairs(keys) do
    local delay = spacing * (i - 1)
    coroutine.schedule(function()
      local ok, err = write_auto_set(key, auto_sets[key])
      if not ok then
        log.error(("Writing (%s) failed: %s"):format(tostring(key), tostring(err)))
      end
    end, delay)
  end

  log.debug(("Scheduled %d writes (threshold=%.0f%%, beam_k=%d, spacing=%.2fs)."):
  format(#keys, thr, tonumber(beam_k) or 0, spacing))

  -- We don't wait on the scheduled writes; return the computed sets
  return true, auto_sets
end

sets.help_topic = {
  title    = "sets",
  desc     = "Show and manage equipment sets.",
  usage    = { "sets <action>" },
  params   = { "<action> ::= list | save | equip | load | delete" },
  examples = { "gs c a sets save idle" },
  dynamic  = function()
    return "'list' shows the currently saved sets."
        .. "'save' will record your current gear to the named set."
        .. "\n'equip' will apply the named set over your current gear, while 'load' clears your current gear first."
        .. "\n'delete' removes the named set."
  end,
}

function sets.handle_sets_command(cmd)
  cmd = tostring(cmd or "")
  local a1, tail = cmd:match("^(%S+)%s*(.*)$")
  a1 = (a1 or ""):lower()
  local a2 = (tail ~= "" and tail) or nil

  if a1 == "list" then
    log.info("Sets:")
    local list = sets.list()
    for _, v in pairs(list) do
      log.info(v)
    end
  elseif a1 == "save" then
    sets.save(a2)
  elseif a1 == "equip" then
    local set = sets.get(a2)
    if not set then
      log.error("Could not find set: " .. a2)
      return
    end
    equip(set)
    log.debug("Equipped set " .. a2 .. " over current equipment.")
  elseif a1 == "load" then
    local set = sets.get(a2)
    if not set then
      log.error("Could not find set: " .. a2)
      return
    end
    equip(sets.naked)
    equip(set)
    log.debug("Equipped set " .. a2)
  elseif a1 == "clear" then
    equip(sets.naked)
  elseif a1 == "delete" then
    local result, err = sets.delete(a2)
    if result then
      log.info("Deleted " .. a2)
    else
      log.error(err)
    end
  else
    utils.print_help_topic(sets.help_topic)
  end
end

return sets
