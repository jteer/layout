-- layout/json.lua
-- Self contained JSON encoder and decoder. Rex ships rex.json, but keeping
-- Layout standalone means every module can be exercised with a plain Lua
-- interpreter and no server attached.

local util = require("layout.util")
local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })

local function quote(s)
  local out = { '"' }
  for i = 1, #s do
    local c = s:sub(i, i)
    local b = c:byte()
    if c == '"' then out[#out + 1] = '\\"'
    elseif c == "\\" then out[#out + 1] = "\\\\"
    elseif c == "\n" then out[#out + 1] = "\\n"
    elseif c == "\r" then out[#out + 1] = "\\r"
    elseif c == "\t" then out[#out + 1] = "\\t"
    elseif c == "\b" then out[#out + 1] = "\\b"
    elseif c == "\f" then out[#out + 1] = "\\f"
    elseif b < 32 then out[#out + 1] = string.format("\\u%04x", b)
    else out[#out + 1] = c end
  end
  out[#out + 1] = '"'
  return table.concat(out)
end

local function number(v)
  if v ~= v or v == math.huge or v == -math.huge then return "null" end
  return util.format_number(v)
end

local function encode(v, opts, depth)
  depth = depth or 0
  if v == nil or v == M.null then return "null" end
  local t = type(v)
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then return number(v) end
  if t == "string" then return quote(v) end
  if t ~= "table" then return "null" end
  local indent = opts and opts.indent
  local pad = indent and string.rep("  ", depth) or ""
  local pad2 = indent and string.rep("  ", depth + 1) or ""
  if util.is_array(v) then
    local parts = {}
    for i = 1, #v do parts[i] = encode(v[i], opts, depth + 1) end
    if #parts == 0 then return "[]" end
    if indent then
      return "[\n" .. pad2 .. table.concat(parts, ",\n" .. pad2) .. "\n" .. pad .. "]"
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = util.sorted_keys(v)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = quote(tostring(k)) .. ":" .. encode(v[k], opts, depth + 1)
  end
  if #parts == 0 then return "{}" end
  if indent then
    return "{\n" .. pad2 .. table.concat(parts, ",\n" .. pad2) .. "\n" .. pad .. "}"
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.encode(v, opts)
  return encode(v, opts, 0)
end

local function utf8(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64))
  end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 4096),
                       0x80 + (math.floor(cp / 64) % 64),
                       0x80 + (cp % 64))
  end
  return string.char(0xF0 + math.floor(cp / 262144),
                     0x80 + (math.floor(cp / 4096) % 64),
                     0x80 + (math.floor(cp / 64) % 64),
                     0x80 + (cp % 64))
end

function M.decode(text)
  if type(text) ~= "string" then return nil, "json: expected a string" end
  local pos = 1
  local n = #text

  local function fail(msg)
    error("layout.json: " .. msg .. " at byte " .. pos, 0)
  end
  local function ws()
    while pos <= n do
      local c = text:sub(pos, pos)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then pos = pos + 1
      else break end
    end
  end
  local function literal(word, value)
    if text:sub(pos, pos + #word - 1) == word then
      pos = pos + #word
      return value
    end
    fail("expected " .. word)
  end

  local parse_value

  local function parse_string()
    if text:sub(pos, pos) ~= '"' then fail("expected string") end
    pos = pos + 1
    local out = {}
    while pos <= n do
      local c = text:sub(pos, pos)
      if c == '"' then pos = pos + 1; return table.concat(out) end
      if c == "\\" then
        pos = pos + 1
        local e = text:sub(pos, pos)
        if e == "n" then out[#out + 1] = "\n"; pos = pos + 1
        elseif e == "r" then out[#out + 1] = "\r"; pos = pos + 1
        elseif e == "t" then out[#out + 1] = "\t"; pos = pos + 1
        elseif e == "b" then out[#out + 1] = "\b"; pos = pos + 1
        elseif e == "f" then out[#out + 1] = "\f"; pos = pos + 1
        elseif e == '"' then out[#out + 1] = '"'; pos = pos + 1
        elseif e == "\\" then out[#out + 1] = "\\"; pos = pos + 1
        elseif e == "/" then out[#out + 1] = "/"; pos = pos + 1
        elseif e == "u" then
          local hex = text:sub(pos + 1, pos + 4)
          if not hex:match("^%x%x%x%x$") then fail("bad unicode escape") end
          local cp = tonumber(hex, 16)
          pos = pos + 5
          if cp >= 0xD800 and cp <= 0xDBFF and text:sub(pos, pos + 1) == "\\u" then
            local hex2 = text:sub(pos + 2, pos + 5)
            if hex2:match("^%x%x%x%x$") then
              local low = tonumber(hex2, 16)
              if low >= 0xDC00 and low <= 0xDFFF then
                cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
                pos = pos + 6
              end
            end
          end
          out[#out + 1] = utf8(cp)
        else fail("bad escape") end
      elseif c:byte() < 32 then
        fail("control character in string")
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    fail("unterminated string")
  end

  local function parse_number()
    local rest = text:sub(pos)
    local s = rest:match("^%-?%d+%.?%d*[eE][%+%-]?%d+")
           or rest:match("^%-?%d+%.?%d*")
    if not s then fail("expected number") end
    local v = tonumber(s)
    if not v then fail("bad number") end
    pos = pos + #s
    return v
  end

  local function parse_array()
    pos = pos + 1
    local out = util.array({})
    ws()
    if text:sub(pos, pos) == "]" then pos = pos + 1; return out end
    while true do
      out[#out + 1] = parse_value()
      ws()
      local c = text:sub(pos, pos)
      if c == "]" then pos = pos + 1; return out end
      if c ~= "," then fail("expected , or ]") end
      pos = pos + 1
      ws()
    end
  end

  local function parse_object()
    pos = pos + 1
    local out = {}
    ws()
    if text:sub(pos, pos) == "}" then pos = pos + 1; return out end
    while true do
      ws()
      local k = parse_string()
      ws()
      if text:sub(pos, pos) ~= ":" then fail("expected :") end
      pos = pos + 1
      ws()
      out[k] = parse_value()
      ws()
      local c = text:sub(pos, pos)
      if c == "}" then pos = pos + 1; return out end
      if c ~= "," then fail("expected , or }") end
      pos = pos + 1
    end
  end

  parse_value = function()
    ws()
    local c = text:sub(pos, pos)
    if c == '"' then return parse_string() end
    if c == "[" then return parse_array() end
    if c == "{" then return parse_object() end
    if c == "t" then return literal("true", true) end
    if c == "f" then return literal("false", false) end
    if c == "n" then return literal("null", M.null) end
    if c == "-" or c:match("%d") then return parse_number() end
    fail("unexpected character " .. string.format("%q", c))
  end

  local v = parse_value()
  ws()
  if pos <= n then fail("trailing content") end
  return v
end

return M
