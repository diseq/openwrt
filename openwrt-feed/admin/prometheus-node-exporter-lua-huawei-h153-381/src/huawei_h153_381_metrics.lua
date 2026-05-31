local M = {}

local DEFAULT_HOST = "192.168.8.1"
local DEFAULT_USERNAME = "admin"
local DEFAULT_TIMEOUT = 9
local UCI_PACKAGE = "huawei-h153-381"

local ENDPOINTS = {
  { key = "device_signal", endpoint = "device/signal" },
  { key = "monitoring_status", endpoint = "monitoring/status" },
  { key = "traffic_statistics", endpoint = "monitoring/traffic-statistics" },
  { key = "device_information", endpoint = "device/information" },
  { key = "current_plmn", endpoint = "net/current-plmn" },
  { key = "wlan_hosts", endpoint = "wlan/host-list" },
  { key = "lan_hosts", endpoint = "lan/HostInfo" },
}

local NETWORK_TYPES = {
  ["0"] = "No Service",
  ["1"] = "GSM",
  ["2"] = "GPRS",
  ["3"] = "EDGE",
  ["4"] = "WCDMA",
  ["5"] = "HSDPA",
  ["6"] = "HSUPA",
  ["7"] = "HSPA",
  ["8"] = "TDSCDMA",
  ["9"] = "HSPA+",
  ["10"] = "EVDO Rev.0",
  ["11"] = "EVDO Rev.A",
  ["12"] = "EVDO Rev.B",
  ["13"] = "1xRTT",
  ["14"] = "UMB",
  ["15"] = "1xEVDV",
  ["16"] = "3xRTT",
  ["17"] = "HSPA+ 64QAM",
  ["18"] = "HSPA+ MIMO",
  ["19"] = "LTE",
  ["41"] = "LTE CA",
  ["101"] = "NR5G NSA",
  ["102"] = "NR5G SA",
}

M.ENDPOINTS = ENDPOINTS

local function now()
  local ok, socket = pcall(require, "socket")
  if ok and socket and socket.gettime then
    return socket.gettime()
  end
  return os.clock()
end

local function trim(s)
  if s == nil then
    return nil
  end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function xml_unescape(s)
  if s == nil then
    return nil
  end
  s = s:gsub("&lt;", "<")
       :gsub("&gt;", ">")
       :gsub("&quot;", '"')
       :gsub("&apos;", "'")
       :gsub("&amp;", "&")
  s = s:gsub("&#(%d+);", function(n)
    n = tonumber(n)
    if n and n >= 0 and n <= 255 then
      return string.char(n)
    end
    return ""
  end)
  return s
end

local function tag_pat(tag)
  return (tag:gsub("([^%w_%-])", "%%%1"))
end

local function xml_text(xml, tag)
  if not xml then
    return nil
  end
  local p = tag_pat(tag)
  return xml_unescape(trim(xml:match("<%s*" .. p .. "[^>]*>(.-)</%s*" .. p .. "%s*>")))
end

local function xml_blocks(xml, tag)
  local p = tag_pat(tag)
  return (xml or ""):gmatch("<%s*" .. p .. "[^>]*>(.-)</%s*" .. p .. "%s*>")
end

local function xml_map(xml)
  local out = {}
  for key, value in (xml or ""):gmatch("<([%w_%-]+)[^>/]*>([^<]*)</%1>") do
    out[key] = xml_unescape(trim(value)) or ""
  end
  return out
end

M.xml_text = xml_text
M.xml_map = xml_map

local function load_bit()
  local ok, bit = pcall(require, "bit")
  if ok then
    return bit
  end
  ok, bit = pcall(require, "bit32")
  if ok then
    return bit
  end

  local function norm(x)
    x = tonumber(x) or 0
    x = x % 4294967296
    if x < 0 then
      x = x + 4294967296
    end
    return x
  end

  local function bit_reduce(args, reducer)
    local result = norm(args[1])
    for i = 2, #args do
      local a = result
      local b = norm(args[i])
      local out = 0
      local p = 1
      for _ = 1, 32 do
        local abit = a % 2
        local bbit = b % 2
        if reducer(abit, bbit) then
          out = out + p
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        p = p * 2
      end
      result = out
    end
    return result
  end

  local pure = {}
  function pure.band(...)
    return bit_reduce({ ... }, function(a, b) return a == 1 and b == 1 end)
  end
  function pure.bor(...)
    return bit_reduce({ ... }, function(a, b) return a == 1 or b == 1 end)
  end
  function pure.bxor(...)
    return bit_reduce({ ... }, function(a, b) return a ~= b end)
  end
  function pure.bnot(x)
    return 4294967295 - norm(x)
  end
  function pure.rshift(x, n)
    return math.floor(norm(x) / (2 ^ n))
  end
  function pure.lshift(x, n)
    return norm(norm(x) * (2 ^ n))
  end
  function pure.tobit(x)
    x = norm(x)
    if x >= 2147483648 then
      return x - 4294967296
    end
    return x
  end
  return pure
end

local bit = load_bit()
local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local bnot = bit.bnot
local rshift = bit.rshift
local lshift = bit.lshift
local tobit = bit.tobit or function(x) return band(x, 0xffffffff) end
local TWO32 = 4294967296

local function unsigned(x)
  x = tonumber(x) or 0
  if x < 0 then
    return x + TWO32
  end
  return x
end

local function add32(...)
  local sum = 0
  for i = 1, select("#", ...) do
    sum = (sum + unsigned(select(i, ...))) % TWO32
  end
  return tobit(sum)
end

local function ror(x, n)
  if bit.ror then
    return bit.ror(x, n)
  end
  return bor(rshift(x, n), lshift(x, 32 - n))
end

local SHA256_K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function hex32(x)
  return string.format("%08x", unsigned(x))
end

local function sha256_hex(msg)
  local bytes = { string.byte(msg, 1, #msg) }
  local bit_len = #bytes * 8
  bytes[#bytes + 1] = 0x80
  while (#bytes % 64) ~= 56 do
    bytes[#bytes + 1] = 0
  end
  for _ = 1, 4 do
    bytes[#bytes + 1] = 0
  end
  bytes[#bytes + 1] = band(rshift(bit_len, 24), 0xff)
  bytes[#bytes + 1] = band(rshift(bit_len, 16), 0xff)
  bytes[#bytes + 1] = band(rshift(bit_len, 8), 0xff)
  bytes[#bytes + 1] = band(bit_len, 0xff)

  local h0, h1, h2, h3 = tobit(0x6a09e667), tobit(0xbb67ae85), tobit(0x3c6ef372), tobit(0xa54ff53a)
  local h4, h5, h6, h7 = tobit(0x510e527f), tobit(0x9b05688c), tobit(0x1f83d9ab), tobit(0x5be0cd19)

  for chunk = 1, #bytes, 64 do
    local w = {}
    for i = 0, 15 do
      local j = chunk + i * 4
      w[i + 1] = tobit(bor(lshift(bytes[j], 24), lshift(bytes[j + 1], 16), lshift(bytes[j + 2], 8), bytes[j + 3]))
    end
    for i = 17, 64 do
      local s0 = bxor(ror(w[i - 15], 7), ror(w[i - 15], 18), rshift(w[i - 15], 3))
      local s1 = bxor(ror(w[i - 2], 17), ror(w[i - 2], 19), rshift(w[i - 2], 10))
      w[i] = add32(w[i - 16], s0, w[i - 7], s1)
    end

    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 1, 64 do
      local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local temp1 = add32(h, S1, ch, SHA256_K[i], w[i])
      local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local temp2 = add32(S0, maj)
      h = g
      g = f
      f = e
      e = add32(d, temp1)
      d = c
      c = b
      b = a
      a = add32(temp1, temp2)
    end

    h0 = add32(h0, a)
    h1 = add32(h1, b)
    h2 = add32(h2, c)
    h3 = add32(h3, d)
    h4 = add32(h4, e)
    h5 = add32(h5, f)
    h6 = add32(h6, g)
    h7 = add32(h7, h)
  end

  return table.concat({ hex32(h0), hex32(h1), hex32(h2), hex32(h3), hex32(h4), hex32(h5), hex32(h6), hex32(h7) })
end

M.sha256_hex = sha256_hex

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64_encode(data)
  local out = {}
  local len = #data
  local i = 1
  while i <= len do
    local a = data:byte(i) or 0
    local b = data:byte(i + 1) or 0
    local c = data:byte(i + 2) or 0
    local n = a * 65536 + b * 256 + c
    out[#out + 1] = BASE64_ALPHABET:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
    out[#out + 1] = BASE64_ALPHABET:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
    if i + 1 <= len then
      out[#out + 1] = BASE64_ALPHABET:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
    else
      out[#out + 1] = "="
    end
    if i + 2 <= len then
      out[#out + 1] = BASE64_ALPHABET:sub(n % 64 + 1, n % 64 + 1)
    else
      out[#out + 1] = "="
    end
    i = i + 3
  end
  return table.concat(out)
end

M.base64_encode = base64_encode

local function encode_password(username, password, password_type, token)
  if password == nil or password == "" then
    return ""
  end
  password_type = tonumber(password_type) or 0
  if password_type == 4 then
    local inner = base64_encode(sha256_hex(password))
    return base64_encode(sha256_hex(username .. inner .. (token or "")))
  end
  return base64_encode(password)
end

M.encode_password = encode_password

local function prometheus_escape_label(s)
  s = tostring(s or "")
  return s:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub('"', '\\"')
end

local function prometheus_escape_help(s)
  s = tostring(s or "")
  return s:gsub("\\", "\\\\"):gsub("\n", "\\n")
end

local function format_value(v)
  if type(v) == "number" then
    if v ~= v then
      return "NaN"
    end
    return string.format("%.17g", v)
  end
  return tostring(v)
end

local function format_labels(order, labels)
  if not order or #order == 0 then
    return ""
  end
  local out = {}
  for i = 1, #order do
    local key = order[i]
    out[#out + 1] = key .. '="' .. prometheus_escape_label(labels[key]) .. '"'
  end
  return "{" .. table.concat(out, ",") .. "}"
end

local Context = {}
Context.__index = Context

function Context.new()
  return setmetatable({ lines = {}, declared = {} }, Context)
end

function Context:declare(name, typ, help)
  if self.declared[name] then
    return
  end
  self.declared[name] = true
  self.lines[#self.lines + 1] = "# HELP " .. name .. " " .. prometheus_escape_help(help)
  self.lines[#self.lines + 1] = "# TYPE " .. name .. " " .. typ
end

function Context:metric(name, typ, help, label_order, labels, value)
  if value == nil then
    return
  end
  self:declare(name, typ, help)
  self.lines[#self.lines + 1] = name .. format_labels(label_order, labels or {}) .. " " .. format_value(value)
end

local COOKIE_ATTRS = {
  path = true,
  domain = true,
  expires = true,
  maxage = true,
  ["max-age"] = true,
  httponly = true,
  secure = true,
  samesite = true,
}

local Client = {}
Client.__index = Client

local function normalize_url(host)
  host = tostring(host or DEFAULT_HOST):gsub("/+$", "")
  if host:match("^https?://") then
    return host
  end
  return "http://" .. host
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'"
end

local function command_first_ipv4(command)
  local f = io.popen(command)
  if not f then
    return nil
  end
  local output = f:read("*a") or ""
  f:close()
  return output:match("(%d+%.%d+%.%d+%.%d+)")
end

local function resolve_bind_address(interface)
  if interface == nil or interface == "" then
    return nil
  end
  interface = tostring(interface)
  if interface:match("^%d+%.%d+%.%d+%.%d+$") or interface:find(":", 1, true) then
    return interface
  end

  local quoted = shell_quote(interface)
  local address = command_first_ipv4("ifstatus " .. quoted .. " 2>/dev/null") or command_first_ipv4("ip -o -4 addr show dev " .. quoted .. " 2>/dev/null")
  if not address then
    error("failed to resolve interface to source IPv4 address: " .. interface)
  end
  return address
end

function M.new_client(opts)
  opts = opts or {}
  local ok_http, http = pcall(require, "socket.http")
  if not ok_http then
    error("missing LuaSocket HTTP module: " .. tostring(http))
  end
  local ok_ltn12, ltn12 = pcall(require, "ltn12")
  if not ok_ltn12 then
    error("missing ltn12 module: " .. tostring(ltn12))
  end
  local timeout = tonumber(opts.timeout) or DEFAULT_TIMEOUT
  if timeout <= 0 then
    error("timeout must be positive")
  end
  http.TIMEOUT = timeout
  local bind_address = opts.bind_address or resolve_bind_address(opts.interface)
  return setmetatable({
    base_url = normalize_url(opts.host),
    username = opts.username or DEFAULT_USERNAME,
    password = opts.password,
    http = http,
    ltn12 = ltn12,
    bind_address = bind_address,
    cookies = {},
    tokens = {},
  }, Client)
end

local function header_value(headers, name)
  if not headers then
    return nil
  end
  local wanted = name:lower()
  for k, v in pairs(headers) do
    if tostring(k):lower() == wanted then
      return v
    end
  end
  return nil
end

function Client:update_cookies(headers)
  local set_cookie = header_value(headers, "set-cookie")
  if not set_cookie then
    return
  end
  local values = type(set_cookie) == "table" and set_cookie or { set_cookie }
  for i = 1, #values do
    for k, v in tostring(values[i]):gmatch("([%w_%-]+)=([^;,%s]*)") do
      if not COOKIE_ATTRS[k:lower()] then
        self.cookies[k] = v
      end
    end
  end
end

function Client:update_tokens(headers, refresh)
  if refresh then
    self.tokens = {}
  end
  local one = header_value(headers, "__RequestVerificationTokenone")
  local two = header_value(headers, "__RequestVerificationTokentwo")
  local single = header_value(headers, "__RequestVerificationToken")
  if one then
    self.tokens[#self.tokens + 1] = one
    if two then
      self.tokens[#self.tokens + 1] = two
    end
  elseif single then
    self.tokens[#self.tokens + 1] = single
  end
end

function Client:cookie_header()
  local parts = {}
  for k, v in pairs(self.cookies) do
    parts[#parts + 1] = k .. "=" .. v
  end
  return table.concat(parts, "; ")
end

function Client:token_header(headers)
  if #self.tokens == 1 then
    headers["__RequestVerificationToken"] = self.tokens[1]
  elseif #self.tokens > 1 then
    headers["__RequestVerificationToken"] = table.remove(self.tokens, 1)
  end
end

function Client:create_tcp()
  local ok_socket, socket = pcall(require, "socket")
  if not ok_socket then
    error("missing LuaSocket core module: " .. tostring(socket))
  end
  local tcp = socket.tcp()
  if self.bind_address then
    local ok, err = tcp:bind(self.bind_address, 0)
    if not ok then
      error("failed to bind outbound socket to " .. tostring(self.bind_address) .. ": " .. tostring(err))
    end
  end
  return tcp
end

function Client:request(method, path, body, refresh_csrf)
  local response = {}
  local headers = {}
  local cookie = self:cookie_header()
  if cookie ~= "" then
    headers.Cookie = cookie
  end
  if body then
    headers["Content-Type"] = "application/xml"
    headers["Content-Length"] = tostring(#body)
    self:token_header(headers)
  elseif method == "GET" then
    self:token_header(headers)
  end
  local req = {
    url = self.base_url .. path,
    method = method,
    headers = headers,
    sink = self.ltn12.sink.table(response),
  }
  if self.bind_address then
    req.create = function()
      return self:create_tcp()
    end
  end
  if body then
    req.source = self.ltn12.source.string(body)
  end
  local ok, code, resp_headers, status = self.http.request(req)
  if not ok then
    error(tostring(code or status or "HTTP request failed"))
  end
  code = tonumber(code)
  if not code or code < 200 or code >= 400 then
    error(tostring(status or ("HTTP status " .. tostring(code))))
  end
  self:update_cookies(resp_headers)
  self:update_tokens(resp_headers, refresh_csrf)
  local text = table.concat(response)
  local error_code = xml_text(text, "code")
  if text:find("<%s*error[%s>]", 1) and error_code then
    error("Huawei API error " .. error_code .. ": " .. tostring(xml_text(text, "message") or ""))
  end
  return text
end

function Client:initialize()
  local html = self:request("GET", "/", nil, false)
  for token in html:gmatch('name="csrf_token"%s+content="([^"]+)"') do
    self.tokens[#self.tokens + 1] = token
  end
  if #self.tokens == 0 then
    local ok, body = pcall(function()
      return self:get("webserver/token")
    end)
    local token = ok and xml_text(body, "token") or nil
    if not token then
      ok, body = pcall(function()
        return self:get("webserver/SesTokInfo")
      end)
      token = ok and xml_text(body, "TokInfo") or nil
    end
    if token then
      self.tokens[#self.tokens + 1] = token
    end
  end
end

function Client:get(endpoint)
  return self:request("GET", "/api/" .. endpoint, nil, false)
end

local function request_xml(fields)
  local out = { "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request>" }
  for i = 1, #fields do
    local key, value = fields[i][1], tostring(fields[i][2] or "")
    out[#out + 1] = "<" .. key .. ">" .. value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;") .. "</" .. key .. ">"
  end
  out[#out + 1] = "</request>"
  return table.concat(out)
end

function Client:post(endpoint, fields, refresh_csrf)
  return self:request("POST", "/api/" .. endpoint, request_xml(fields), refresh_csrf)
end

function Client:login()
  if self.password == nil or self.password == "" then
    return true
  end
  local state = self:get("user/state-login")
  local state_map = xml_map(state)
  if tonumber(state_map.State) == 0 then
    return true
  end
  local password_type = tonumber(state_map.password_type) or 0
  local password = encode_password(self.username, self.password, password_type, self.tokens[1])
  local response = self:post("user/login", {
    { "Username", self.username },
    { "Password", password },
    { "password_type", password_type },
  }, true)
  return xml_text(response, "response") == "OK"
end

function Client:logout()
  if self.password == nil or self.password == "" then
    return true
  end
  self:post("user/logout", { { "Logout", 1 } }, false)
  return true
end

local function as_number(value)
  if value == nil then
    return nil
  end
  local n = tostring(value):match("%-?%d+%.?%d*")
  return n and tonumber(n) or nil
end

local function metric_suffix_unit(unit)
  unit = tostring(unit or ""):lower()
  if unit == "dbm" then return "dbm" end
  if unit == "db" then return "db" end
  if unit == "mhz" then return "mhz" end
  if unit == "mbps" then return "mbps" end
  if unit == "kbps" then return "mbps" end
  if unit == "bps" then return "bps" end
  if unit == "ms" then return "milliseconds" end
  if unit == "gb" then return "gb" end
  if unit == "mb" then return "mb" end
  if unit == "kb" then return "kb" end
  if unit == "b" then return "bytes" end
  return unit:gsub("[^a-z0-9]", "_")
end

local function sanitize_metric_part(s)
  s = tostring(s or ""):lower():gsub("[^a-z0-9_]", "_"):gsub("_+", "_")
  return (s:gsub("^_+", ""):gsub("_+$", ""))
end

local function emit_unit_metric(ctx, key, raw, help)
  if raw == nil or raw == "" then
    return
  end
  local value, unit = tostring(raw):match("^%s*(%-?%d+%.?%d*)%s*([%a/]+)%s*$")
  if not value then
    return
  end
  value = tonumber(value)
  if unit == "Kbps" then
    value = value / 1024
  end
  local suffix = metric_suffix_unit(unit)
  if suffix == "" then
    return
  end
  local typ = ({ gb = "counter", mb = "counter", kb = "counter", bytes = "counter" })[suffix] or "gauge"
  ctx:metric("huawei_metrics_" .. sanitize_metric_part(key) .. "_" .. suffix, typ, help or key, nil, nil, value)
end

local function emit_numeric(ctx, name, typ, help, value)
  local n = as_number(value)
  if n ~= nil then
    ctx:metric(name, typ, help, nil, nil, n)
  end
end

local SIGNAL_FIELDS = {
  rsrp = { "huawei_metrics_rsrp_dbm", "RSRP" },
  rsrq = { "huawei_metrics_rsrq_db", "RSRQ" },
  rssi = { "huawei_metrics_rssi_dbm", "RSSI" },
  sinr = { "huawei_metrics_sinr_db", "SINR" },
  nrrsrp = { "huawei_metrics_nrrsrp_dbm", "5G NR RSRP" },
  nrrsrq = { "huawei_metrics_nrrsrq_db", "5G NR RSRQ" },
  nrsinr = { "huawei_metrics_nrsinr_db", "5G NR SINR" },
  nr_rsrp = { "huawei_metrics_nr_rsrp_dbm", "5G NR RSRP" },
  nr_rsrq = { "huawei_metrics_nr_rsrq_db", "5G NR RSRQ" },
  nr_sinr = { "huawei_metrics_nr_sinr_db", "5G NR SINR" },
}

local function emit_signal(ctx, data)
  for key, spec in pairs(SIGNAL_FIELDS) do
    emit_numeric(ctx, spec[1], "gauge", spec[2], data[key])
  end
  for key, value in pairs(data) do
    emit_unit_metric(ctx, key, value, key)
  end
  emit_numeric(ctx, "huawei_metrics_pci", "gauge", "Physical cell ID", data.pci or data.PCI)
  emit_numeric(ctx, "huawei_metrics_nr_pci", "gauge", "5G NR physical cell ID", data.nrpci or data.nr_pci)
  emit_numeric(ctx, "huawei_metrics_cell_id", "gauge", "Cell ID", data.cell_id or data.cellid)
  if data.band or data.mode or data.earfcn or data.dlbandwidth or data.ulbandwidth then
    ctx:metric("huawei_metrics_radio_info", "gauge", "Radio connection labels", { "band", "mode", "earfcn", "dlbandwidth", "ulbandwidth" }, {
      band = data.band or "",
      mode = data.mode or "",
      earfcn = data.earfcn or "",
      dlbandwidth = data.dlbandwidth or "",
      ulbandwidth = data.ulbandwidth or "",
    }, 1)
  end
end

local function emit_status(ctx, data)
  local network_type = tostring(data.CurrentNetworkType or "")
  emit_numeric(ctx, "huawei_metrics_current_network_type", "gauge", "Current network type code", network_type)
  emit_numeric(ctx, "huawei_metrics_signal_icon", "gauge", "Router signal icon level", data.SignalIcon)
  emit_numeric(ctx, "huawei_metrics_connection_status", "gauge", "Connection status code", data.ConnectionStatus)
  emit_numeric(ctx, "huawei_metrics_roaming_status", "gauge", "Roaming status code", data.RoamingStatus)
  if network_type ~= "" or data.CurrentServiceDomain or data.WanIPAddress then
    ctx:metric("huawei_metrics_status_info", "gauge", "Connection status labels", { "network_type", "network_name", "service_domain", "wan_ip" }, {
      network_type = network_type,
      network_name = NETWORK_TYPES[network_type] or "",
      service_domain = data.CurrentServiceDomain or "",
      wan_ip = data.WanIPAddress or "",
    }, 1)
  end
end

local function emit_traffic(ctx, data)
  emit_numeric(ctx, "huawei_metrics_current_upload_bytes", "gauge", "Current session uploaded bytes", data.CurrentUpload)
  emit_numeric(ctx, "huawei_metrics_current_download_bytes", "gauge", "Current session downloaded bytes", data.CurrentDownload)
  emit_numeric(ctx, "huawei_metrics_current_upload_rate_bytes_per_second", "gauge", "Current upload rate", data.CurrentUploadRate)
  emit_numeric(ctx, "huawei_metrics_current_download_rate_bytes_per_second", "gauge", "Current download rate", data.CurrentDownloadRate)
  emit_numeric(ctx, "huawei_metrics_total_upload_bytes", "counter", "Total uploaded bytes", data.TotalUpload)
  emit_numeric(ctx, "huawei_metrics_total_download_bytes", "counter", "Total downloaded bytes", data.TotalDownload)
  emit_numeric(ctx, "huawei_metrics_current_connect_time_seconds", "gauge", "Current connection time", data.CurrentConnectTime)
  emit_numeric(ctx, "huawei_metrics_total_connect_time_seconds", "counter", "Total connection time", data.TotalConnectTime)
end

local function emit_device_info(ctx, data)
  local labels = {
    device_name = data.DeviceName or data.devicename or "",
    serial_number = data.SerialNumber or data.serialnumber or "",
    imei = data.Imei or data.imei or "",
    imsi = data.Imsi or data.imsi or "",
    hardware_version = data.HardwareVersion or data.hardwareversion or "",
    software_version = data.SoftwareVersion or data.softwareversion or "",
    webui_version = data.WebUIVersion or data.WebUIVersion1 or data.webuiversion or "",
    mac_address = data.MacAddress1 or data.MacAddress2 or data.macaddress1 or "",
  }
  ctx:metric("huawei_metrics_device_info", "gauge", "Huawei router device information", {
    "device_name", "serial_number", "imei", "imsi", "hardware_version", "software_version", "webui_version", "mac_address",
  }, labels, 1)
end

local function emit_plmn(ctx, data)
  if data.FullName or data.ShortName or data.Numeric or data.State then
    ctx:metric("huawei_metrics_plmn_info", "gauge", "Current public land mobile network", { "full_name", "short_name", "numeric", "state", "rat" }, {
      full_name = data.FullName or "",
      short_name = data.ShortName or "",
      numeric = data.Numeric or "",
      state = data.State or "",
      rat = data.Rat or "",
    }, 1)
  end
end

local function host_value(block, names)
  for i = 1, #names do
    local v = xml_text(block, names[i])
    if v and v ~= "" then
      return v
    end
  end
  return ""
end

local function emit_hosts(ctx, prefix, xml)
  local count = 0
  local info_name = "huawei_metrics_" .. prefix .. "_host_info"
  for block in xml_blocks(xml, "Host") do
    count = count + 1
    ctx:metric(info_name, "gauge", prefix .. " host labels", { "mac", "hostname", "ip" }, {
      mac = host_value(block, { "MacAddress", "MACAddress", "mac", "Mac" }),
      hostname = host_value(block, { "HostName", "hostname", "Name" }),
      ip = host_value(block, { "IpAddress", "IPAddress", "ip", "IP" }),
    }, 1)
  end
  ctx:metric("huawei_metrics_" .. prefix .. "_devices", "gauge", "Number of " .. prefix .. " devices", nil, nil, count)
  return count
end

function M.emit_from_xmls(xmls)
  local ctx = Context.new()
  local total_hosts = 0
  if xmls.device_signal then
    emit_signal(ctx, xml_map(xmls.device_signal))
  end
  if xmls.monitoring_status then
    emit_status(ctx, xml_map(xmls.monitoring_status))
  end
  if xmls.traffic_statistics then
    emit_traffic(ctx, xml_map(xmls.traffic_statistics))
  end
  if xmls.device_information then
    emit_device_info(ctx, xml_map(xmls.device_information))
  end
  if xmls.current_plmn then
    emit_plmn(ctx, xml_map(xmls.current_plmn))
  end
  if xmls.wlan_hosts then
    total_hosts = total_hosts + emit_hosts(ctx, "wifi", xmls.wlan_hosts)
  end
  if xmls.lan_hosts then
    total_hosts = total_hosts + emit_hosts(ctx, "lan", xmls.lan_hosts)
  end
  if xmls.wlan_hosts or xmls.lan_hosts then
    ctx:metric("huawei_metrics_total_devices", "gauge", "Number of total devices", nil, nil, total_hosts)
  end
  return table.concat(ctx.lines, "\n") .. "\n"
end

function M.collect(opts)
  opts = opts or {}
  local ctx = Context.new()
  local scrape_success = {}
  local scrape_duration = {}
  for i = 1, #ENDPOINTS do
    scrape_success[ENDPOINTS[i].key] = 0
  end
  local login_success = 0
  local xmls = {}

  local ok_client, client = pcall(M.new_client, opts)
  if ok_client then
    local ok_init = pcall(function() client:initialize() end)
    local ok_login = ok_init and pcall(function() return client:login() end)
    if ok_login then
      login_success = 1
      for i = 1, #ENDPOINTS do
        local item = ENDPOINTS[i]
        local started = now()
        local ok, body = pcall(function()
          return client:get(item.endpoint)
        end)
        if ok then
          xmls[item.key] = body
          scrape_success[item.key] = 1
          scrape_duration[item.key] = now() - started
        end
      end
      pcall(function() client:logout() end)
    end
  end

  local metrics = M.emit_from_xmls(xmls)
  if metrics ~= "\n" then
    ctx.lines[#ctx.lines + 1] = metrics:gsub("\n$", "")
  end
  local label = { "collector" }
  for i = 1, #ENDPOINTS do
    local key = ENDPOINTS[i].key
    if scrape_duration[key] then
      ctx:metric("huawei_metrics_scrape_duration_seconds", "gauge", "Scrape duration by collector", label, { collector = key }, scrape_duration[key])
    end
  end
  for i = 1, #ENDPOINTS do
    local key = ENDPOINTS[i].key
    ctx:metric("huawei_metrics_up", "gauge", "Huawei metrics scrape success by collector", label, { collector = key }, scrape_success[key])
  end
  ctx:metric("huawei_metrics_up", "gauge", "Huawei metrics scrape success by collector", label, { collector = "login" }, login_success)
  return table.concat(ctx.lines, "\n") .. "\n", login_success == 1
end

local function load_uci_config(package_name)
  local ok, uci = pcall(require, "uci")
  if not ok then
    return {}
  end
  local cursor = uci.cursor()
  local section = "main"
  return {
    host = cursor:get(package_name, section, "host"),
    username = cursor:get(package_name, section, "username"),
    password = cursor:get(package_name, section, "password"),
    timeout = cursor:get(package_name, section, "timeout"),
    interface = cursor:get(package_name, section, "interface"),
  }
end

function M.default_options(overrides)
  local opts = { uci_package = UCI_PACKAGE, use_config = true }
  if overrides then
    for k, v in pairs(overrides) do
      opts[k] = v
    end
  end
  local config = {}
  if opts.use_config then
    config = load_uci_config(opts.uci_package)
  end
  opts.host = opts.host or config.host or DEFAULT_HOST
  opts.username = opts.username or config.username or DEFAULT_USERNAME
  opts.password = opts.password or config.password or os.getenv("HUAWEI_ROUTER_PASS") or os.getenv("HUAWEI_PASSWORD")
  opts.timeout = opts.timeout or config.timeout or DEFAULT_TIMEOUT
  opts.interface = opts.interface or config.interface or os.getenv("HUAWEI_ROUTER_INTERFACE") or os.getenv("HUAWEI_INTERFACE")
  return opts
end

local function usage(stream)
  stream:write("Usage: huawei-h153-381-metrics [--host HOST] [--interface IFACE_OR_SOURCE_IP] [--username USER] [--password PASSWORD] [--timeout SECONDS] [--no-config]\n")
  stream:write("Scrapes Huawei H153-381 router API and writes Prometheus metrics to stdout.\n")
end

local function require_arg_value(argv, index, name)
  local value = argv[index]
  if value == nil or value:match("^%-%-") then
    error(name .. " requires a value")
  end
  return value
end

function M.parse_args(argv)
  local opts = { uci_package = UCI_PACKAGE, use_config = true }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--no-config" then
      opts.use_config = false
    elseif a == "--host" then
      i = i + 1
      opts.host = require_arg_value(argv, i, a)
    elseif a:match("^%-%-host=") then
      opts.host = a:match("^%-%-host=(.*)$")
    elseif a == "--username" then
      i = i + 1
      opts.username = require_arg_value(argv, i, a)
    elseif a:match("^%-%-username=") then
      opts.username = a:match("^%-%-username=(.*)$")
    elseif a == "--interface" then
      i = i + 1
      opts.interface = require_arg_value(argv, i, a)
    elseif a:match("^%-%-interface=") then
      opts.interface = a:match("^%-%-interface=(.*)$")
    elseif a == "--password" then
      i = i + 1
      opts.password = require_arg_value(argv, i, a)
    elseif a:match("^%-%-password=") then
      opts.password = a:match("^%-%-password=(.*)$")
    elseif a == "--timeout" then
      i = i + 1
      opts.timeout = require_arg_value(argv, i, a)
    elseif a:match("^%-%-timeout=") then
      opts.timeout = a:match("^%-%-timeout=(.*)$")
    else
      error("unknown argument: " .. tostring(a))
    end
    i = i + 1
  end
  return opts
end

function M.main(argv)
  local ok_args, opts = pcall(M.parse_args, argv or {})
  if not ok_args then
    io.stderr:write(tostring(opts) .. "\n")
    usage(io.stderr)
    return 2
  end
  if opts.help then
    usage(io.stdout)
    return 0
  end
  opts = M.default_options(opts)
  local metrics = M.collect(opts)
  io.write(metrics)
  return 0
end

return M
