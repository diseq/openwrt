local M = {}

local DEFAULT_TIMEOUT = 9
local DEFAULT_HOST = "192.168.0.1"

local FUN = {
  GLOBALSETTINGS = 1,
  MULTILANG = 3,
  CM_SYSTEM_INFO = 2,
  CM_OPERATIONAL_STATUS = 5,
  CM_FREQUENCY_PLAN = 6,
  DOWNSTREAM_TABLE = 10,
  UPSTREAM_TABLE = 11,
  SIGNAL_TABLE = 12,
  EVENTLOG_TABLE = 13,
  LOGIN = 15,
  LOGOUT = 16,
  LANUSERTABLE = 123,
  PORT_STATUS = 143,
  CMSTATE = 136,
  CMSTATUS = 144,
}

local EXTRACTORS = {
  "device_status",
  "downstream",
  "upstream",
  "lan_users",
  "operational_status",
  "frequency_plan",
  "temperature",
  "port_status",
  "service_status",
  "eventlog",
}

local PROVISIONING_STATUSES = {
  "Online",
  "Partial Service (US only)",
  "Partial Service (DS only)",
  "Partial Service (US+DS)",
  "Modem Mode",
  "DS scanning",
  "US scanning",
  "US ranging",
  "DS ranging",
  "Requesting CM IP address",
  "unknown",
}

M.FUN = FUN
M.PROVISIONING_STATUSES = PROVISIONING_STATUSES

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
  return (tag:gsub("([^%w_])", "%%%1"))
end

local function xml_text(xml, tag)
  if not xml then
    return nil
  end
  local p = tag_pat(tag)
  local v = xml:match("<%s*" .. p .. "%f[%s>/][^>]*>(.-)</%s*" .. p .. "%f[%s>/]%s*>")
  return xml_unescape(trim(v))
end

local function xml_blocks(xml, tag)
  local p = tag_pat(tag)
  local pattern = "<%s*" .. p .. "%f[%s>/][^>]*>(.-)</%s*" .. p .. "%f[%s>/]%s*>"
  return xml:gmatch(pattern)
end

local function as_number(s)
  if s == nil then
    return nil
  end
  return tonumber(s)
end

local function zfill2(s)
  s = tostring(s or "")
  if #s == 1 then
    return "0" .. s
  end
  return s
end

local function prometheus_escape_label(s)
  s = tostring(s or "")
  return s:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub('"', '\\"')
end

local function prometheus_escape_help(s)
  s = tostring(s or "")
  return s:gsub("\\", "\\\\"):gsub("\n", "\\n")
end

local function format_labels(order, labels)
  if not order or #order == 0 then
    return ""
  end
  local out = {}
  for i = 1, #order do
    local name = order[i]
    out[#out + 1] = name .. '="' .. prometheus_escape_label(labels[name]) .. '"'
  end
  return "{" .. table.concat(out, ",") .. "}"
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

local function form_escape(s)
  s = tostring(s or "")
  s = s:gsub("\n", "\r\n")
  s = s:gsub("([^%w%-_%.~ ])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return (s:gsub(" ", "+"))
end

local function encode_form(items)
  local parts = {}
  for i = 1, #items do
    parts[#parts + 1] = form_escape(items[i][1]) .. "=" .. form_escape(items[i][2])
  end
  return table.concat(parts, "&")
end

M.encode_form = encode_form
M.xml_text = xml_text

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

local function normalize_base_url(host)
  host = tostring(host or DEFAULT_HOST)
  if host:match("^https?://") then
    return host:gsub("/+$", "")
  end
  return "http://" .. host:gsub("/+$", "")
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'"
end

local function option_enabled(value, default)
  if value == nil or value == "" then
    return default and true or false
  end
  value = tostring(value):lower()
  return not (value == "0" or value == "false" or value == "no" or value == "off")
end

local function non_empty(value)
  if value == nil or value == "" then
    return nil
  end
  return value
end

local function cache_escape(value)
  return (tostring(value or ""):gsub("([^A-Za-z0-9_.~-])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function cache_unescape(value)
  return (tostring(value or ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16) or 0)
  end))
end

local function cache_component(value)
  return (tostring(value or ""):gsub("[^A-Za-z0-9_.-]", "_"))
end

local function default_session_cache_path(host)
  return "/tmp/compal-ch7465lg-session-" .. cache_component(host)
end

local function command_loose_output(command)
  local f = io.popen(command)
  if not f then
    return nil
  end
  local output = f:read("*a") or ""
  f:close()
  if output == "" then
    return nil
  end
  return output
end
local function command_output(command)
  local f = io.popen(command)
  if not f then
    error("failed to run command: " .. command)
  end
  local output = f:read("*a") or ""
  local ok, _, code = f:close()
  if ok == nil or ok == false then
    error("command failed" .. (code and (" with exit " .. tostring(code)) or "") .. ": " .. command)
  end
  return output
end

local function write_temp_file(content)
  local path = os.tmpname()
  local f, err = io.open(path, "wb")
  if not f then
    error("failed to create temporary file: " .. tostring(err))
  end
  f:write(content or "")
  f:close()
  os.execute("chmod 0600 " .. shell_quote(path))
  return path
end

local function remove_file(path)
  if path then
    os.remove(path)
  end
end

local function read_file(path)
  local f, err = io.open(path, "rb")
  if not f then
    error("failed to read temporary file: " .. tostring(err))
  end
  local content = f:read("*a") or ""
  f:close()
  return content
end

local function digest_hex(algorithm, content)
  local path = write_temp_file(content)
  local ok, output = pcall(command_output, "openssl dgst -" .. algorithm .. " -r " .. shell_quote(path))
  remove_file(path)
  if not ok then
    error(output)
  end
  local hex = output:match("^([0-9a-fA-F]+)")
  if not hex then
    error("failed to parse openssl " .. algorithm .. " digest")
  end
  return hex:lower()
end

local function bytes_to_hex(s)
  local out = {}
  for i = 1, #s do
    out[i] = string.format("%02x", string.byte(s, i))
  end
  return table.concat(out)
end

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(s)
  local out = {}
  local n = #s
  local i = 1
  while i <= n do
    local a = string.byte(s, i) or 0
    local b = string.byte(s, i + 1) or 0
    local c = string.byte(s, i + 2) or 0
    local triple = a * 65536 + b * 256 + c
    out[#out + 1] = BASE64_ALPHABET:sub(math.floor(triple / 262144) % 64 + 1, math.floor(triple / 262144) % 64 + 1)
    out[#out + 1] = BASE64_ALPHABET:sub(math.floor(triple / 4096) % 64 + 1, math.floor(triple / 4096) % 64 + 1)
    if i + 1 <= n then
      out[#out + 1] = BASE64_ALPHABET:sub(math.floor(triple / 64) % 64 + 1, math.floor(triple / 64) % 64 + 1)
    else
      out[#out + 1] = "="
    end
    if i + 2 <= n then
      out[#out + 1] = BASE64_ALPHABET:sub(triple % 64 + 1, triple % 64 + 1)
    else
      out[#out + 1] = "="
    end
    i = i + 3
  end
  return table.concat(out)
end

local function run_ok(command)
  local ok, _, code = os.execute(command)
  if ok == true or ok == 0 then
    return true
  end
  error("command failed" .. (code and (" with exit " .. tostring(code)) or "") .. ": " .. command)
end

local function cbn_encrypt_password(password, token)
  token = tostring(token or "")
  local key = digest_hex("sha256", token)
  local iv = digest_hex("md5", token)
  local in_path = write_temp_file(password or "")
  local out_path = os.tmpname()
  local ok, err = pcall(run_ok, "openssl enc -aes-256-cbc -K " .. key .. " -iv " .. iv .. " -nosalt -in " .. shell_quote(in_path) .. " -out " .. shell_quote(out_path))
  remove_file(in_path)
  if not ok then
    remove_file(out_path)
    error(err)
  end
  local ciphertext = read_file(out_path)
  remove_file(out_path)
  return base64_encode(":" .. bytes_to_hex(ciphertext))
end

M.cbn_encrypt_password = cbn_encrypt_password

local function base_host(host)
  host = normalize_base_url(host)
  local hostport = host:match("^https?://([^/]+)") or host
  hostport = hostport:match("^([^@]+)@(.+)$") or hostport
  local parsed = hostport:match("^%[([^%]]+)%]")
  if parsed then
    return parsed
  end
  return hostport:match("^([^:]+)") or hostport
end

local function ipv4_to_int(address)
  local a, b, c, d = tostring(address or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if not a or not b or not c or not d or a > 255 or b > 255 or c > 255 or d > 255 then
    return nil
  end
  return (((a * 256) + b) * 256 + c) * 256 + d
end

local function same_ipv4_prefix(a, b, prefix)
  a, b, prefix = ipv4_to_int(a), ipv4_to_int(b), tonumber(prefix)
  if not a or not b or not prefix or prefix < 0 or prefix > 32 then
    return false
  end
  if prefix == 0 then
    return true
  end
  local divisor = 2 ^ (32 - prefix)
  return math.floor(a / divisor) == math.floor(b / divisor)
end

local function is_private_ipv4(address)
  local a, b = tostring(address or ""):match("^(%d+)%.(%d+)")
  a, b = tonumber(a), tonumber(b)
  return a == 10 or (a == 172 and b and b >= 16 and b <= 31) or (a == 192 and b == 168)
end

local function add_ipv4_candidate(candidates, seen, address, prefix)
  if address and address:match("^%d+%.%d+%.%d+%.%d+$") and not seen[address] then
    seen[address] = true
    candidates[#candidates + 1] = { address = address, prefix = tonumber(prefix) }
  end
end

local function collect_ipv4_candidates(output, candidates, seen)
  if not output then
    return
  end
  for address, prefix in output:gmatch("inet%s+(%d+%.%d+%.%d+%.%d+)/(%d+)") do
    add_ipv4_candidate(candidates, seen, address, prefix)
  end
  for address, prefix in output:gmatch('"address"%s*:%s*"(%d+%.%d+%.%d+%.%d+)".-"mask"%s*:%s*(%d+)') do
    add_ipv4_candidate(candidates, seen, address, prefix)
  end
  for address in output:gmatch("(%d+%.%d+%.%d+%.%d+)") do
    add_ipv4_candidate(candidates, seen, address, nil)
  end
end

local function choose_bind_address(candidates, target_host)
  local best, best_prefix = nil, -1
  if target_host and target_host:match("^%d+%.%d+%.%d+%.%d+$") then
    for i = 1, #candidates do
      local candidate = candidates[i]
      local prefix = candidate.prefix or 32
      if same_ipv4_prefix(candidate.address, target_host, prefix) and prefix > best_prefix then
        best, best_prefix = candidate.address, prefix
      end
    end
    if best then
      return best
    end
  end
  for i = 1, #candidates do
    if is_private_ipv4(candidates[i].address) then
      return candidates[i].address
    end
  end
  return candidates[1] and candidates[1].address or nil
end



local function resolve_bind_address(interface, target_host)
  if interface == nil or interface == "" then
    return nil
  end
  interface = tostring(interface)
  if interface:match("^%d+%.%d+%.%d+%.%d+$") or interface:find(":", 1, true) then
    return interface
  end

  local quoted = shell_quote(interface)
  local candidates, seen = {}, {}
  collect_ipv4_candidates(command_loose_output("ifstatus " .. quoted .. " 2>/dev/null"), candidates, seen)
  collect_ipv4_candidates(command_loose_output("ip -o -f inet addr show dev " .. quoted .. " 2>/dev/null"), candidates, seen)
  collect_ipv4_candidates(command_loose_output("ip -o addr show dev " .. quoted .. " 2>/dev/null"), candidates, seen)
  collect_ipv4_candidates(command_loose_output("ip addr show dev " .. quoted .. " 2>/dev/null"), candidates, seen)
  local address = choose_bind_address(candidates, target_host)
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
  local base_url = normalize_base_url(opts.host)
  local host = base_host(base_url)
  local bind_address = opts.bind_address or resolve_bind_address(opts.interface, host)
  local session_cache = option_enabled(opts.session_cache, true)
  local session_cache_path = non_empty(opts.session_cache_path) or default_session_cache_path(host)
  return setmetatable({
    base_url = base_url,
    password = opts.password,
    http = http,
    ltn12 = ltn12,
    bind_address = bind_address,
    password_encryption = opts.password_encryption or "cbn",
    session_cache = session_cache,
    session_cache_path = session_cache_path,
    cookies = {},
  }, Client)

end
function Client:update_cookies(headers)
  if not headers then
    return
  end
  local set_cookie = headers["set-cookie"] or headers["Set-Cookie"]
  if not set_cookie then
    return
  end
  local values = type(set_cookie) == "table" and set_cookie or { set_cookie }
  for i = 1, #values do
    local raw = tostring(values[i])
    for k, v in raw:gmatch("([%w_%-]+)=([^;,%s]*)") do
      local lower = k:lower()
      if not COOKIE_ATTRS[lower] then
        self.cookies[k] = v
      end
    end
  end
end

function Client:cookie_header()
  local parts = {}
  for k, v in pairs(self.cookies) do
    parts[#parts + 1] = k .. "=" .. v
  end
  return table.concat(parts, "; ")
end

function Client:clear_session()
  self.cookies = {}
end

function Client:load_session_cache()
  if not self.session_cache or not self.session_cache_path then
    return false
  end
  local f = io.open(self.session_cache_path, "r")
  if not f then
    return false
  end
  local cookies = {}
  local has_sid = false
  local has_token = false
  for line in f:lines() do
    local kind, a, b = line:match("^([^\t]+)\t([^\t]*)\t?(.*)$")
    if kind == "base_url" and cache_unescape(a) ~= self.base_url then
      f:close()
      return false
    elseif kind == "cookie" and a ~= "" then
      local name = cache_unescape(a)
      local value = cache_unescape(b)
      cookies[name] = value
      has_sid = has_sid or name == "SID"
      has_token = has_token or name == "sessionToken" or name == "SessionToken"
    end
  end
  f:close()
  if not (has_sid and has_token) then
    return false
  end
  self.cookies = cookies
  return true
end

function Client:save_session_cache()
  if not self.session_cache or not self.session_cache_path or self.password == nil or self.password == "" then
    return false
  end
  if not (self.cookies.SID and (self.cookies.sessionToken or self.cookies.SessionToken)) then
    return false
  end
  local tmp = self.session_cache_path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return false
  end
  f:write("version\t1\n")
  f:write("base_url\t", cache_escape(self.base_url), "\n")
  f:write("created\t", tostring(os.time()), "\n")
  for k, v in pairs(self.cookies) do
    f:write("cookie\t", cache_escape(k), "\t", cache_escape(v), "\n")
  end
  f:close()
  os.execute("chmod 0600 " .. shell_quote(tmp) .. " 2>/dev/null")
  local ok = os.rename(tmp, self.session_cache_path)
  return ok and true or false
end

function Client:remove_session_cache()
  if self.session_cache_path then
    os.remove(self.session_cache_path)
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
function Client:request(method, path, body)
  local response = {}
  local headers = {
    ["Accept"] = "application/xml, text/xml, */*; q=0.01",
    ["X-Requested-With"] = "XMLHttpRequest",
  }
  local cookie = self:cookie_header()
  if cookie ~= "" then
    headers["Cookie"] = cookie
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
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    headers["Content-Length"] = tostring(#body)
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
  return table.concat(response)
end

function Client:get_session_token()
  local token = self.cookies.sessionToken or self.cookies.SessionToken
  if token == nil or token == "" then
    error("sessionToken cookie not found")
  end
  return token
end

function Client:prime_session()
  local paths = { "/", "/index.html", "/common_page/login.html" }
  for i = 1, #paths do
    pcall(function()
      self:request("GET", paths[i])
    end)
    if self.cookies.sessionToken or self.cookies.SessionToken then
      break
    end
  end
  if self.cookies.sessionToken or self.cookies.SessionToken then
    pcall(function()
      self:get(FUN.GLOBALSETTINGS)
    end)
    pcall(function()
      self:get(FUN.MULTILANG)
    end)
  end
end

function Client:login()
  if self.password == nil or self.password == "" then
    error("password is required")
  end

  self:prime_session()
  local token = self:get_session_token()
  local password = self.password
  if self.password_encryption ~= "plain" then
    password = cbn_encrypt_password(password, token)
  end
  local body = encode_form({
    { "token", token },
    { "fun", FUN.LOGIN },
    { "Username", "NULL" },
    { "Password", password },
  })
  local response = self:request("POST", "/xml/setter.xml", body)
  local sid = response:match("^%s*successful;SID=(%d+)")
  if not sid then
    error("login failed: " .. response:gsub("%s+", " "):sub(1, 160))
  end
  self.cookies.SID = sid
end

function Client:logout()
  local body = encode_form({
    { "token", self:get_session_token() },
    { "fun", FUN.LOGOUT },
  })
  self:request("POST", "/xml/setter.xml", body)
  self.cookies.SID = nil
end

function Client:get(fun)
  local body = encode_form({
    { "token", self:get_session_token() },
    { "fun", fun },
  })
  return self:request("POST", "/xml/getter.xml", body)
end

local function emit_downstream(ctx, downstream_xml, signal_xml)
  local channel_label = { "channel_id" }
  for block in xml_blocks(downstream_xml, "downstream") do
    local channel_id = zfill2(xml_text(block, "chid"))
    local labels = { channel_id = channel_id }
    ctx:metric("connectbox_downstream_frequency_hz", "gauge", "Downstream channel frequency", channel_label, labels, as_number(xml_text(block, "freq")))
    ctx:metric("connectbox_downstream_power_level_dbmv", "gauge", "Downstream channel power level", channel_label, labels, as_number(xml_text(block, "pow")))
    ctx:metric("connectbox_downstream_snr_db", "gauge", "Downstream channel signal-to-noise ratio (SNR)", channel_label, labels, as_number(xml_text(block, "snr")))
    ctx:metric("connectbox_downstream_rxmer_db", "gauge", "Downstream channel receive modulation error ratio (RxMER)", channel_label, labels, as_number(xml_text(block, "RxMER")))
    ctx:metric("connectbox_downstream_pre_rs_errors_total", "counter", "Downstream pre-RS errors", channel_label, labels, as_number(xml_text(block, "PreRs")))
    ctx:metric("connectbox_downstream_post_rs_errors_total", "counter", "Downstream post-RS errors", channel_label, labels, as_number(xml_text(block, "PostRs")))
    ctx:metric("connectbox_downstream_modulation_info", "gauge", "Downstream channel modulation", { "channel_id", "modulation" }, { channel_id = channel_id, modulation = xml_text(block, "mod") or "" }, 1)
    ctx:metric("connectbox_downstream_lock_status", "gauge", "Downstream channel lock status", { "channel_id", "lock" }, { channel_id = channel_id, lock = "qam" }, as_number(xml_text(block, "IsQamLocked")))
    ctx:metric("connectbox_downstream_lock_status", "gauge", "Downstream channel lock status", { "channel_id", "lock" }, { channel_id = channel_id, lock = "fec" }, as_number(xml_text(block, "IsFECLocked")))
    ctx:metric("connectbox_downstream_lock_status", "gauge", "Downstream channel lock status", { "channel_id", "lock" }, { channel_id = channel_id, lock = "mpeg" }, as_number(xml_text(block, "IsMpegLocked")))
  end
  if signal_xml then
    for block in xml_blocks(signal_xml, "signal") do
      local channel_id = zfill2(xml_text(block, "dsid"))
      local labels = { channel_id = channel_id }
      ctx:metric("connectbox_downstream_codewords_unerrored_total", "counter", "Unerrored downstream codewords", channel_label, labels, as_number(xml_text(block, "unerrored")))
      ctx:metric("connectbox_downstream_codewords_corrected_total", "counter", "Corrected downstream codewords", channel_label, labels, as_number(xml_text(block, "correctable")))
      ctx:metric("connectbox_downstream_codewords_uncorrectable_total", "counter", "Uncorrectable downstream codewords", channel_label, labels, as_number(xml_text(block, "uncorrectable")))
    end
  end
end

local function emit_upstream(ctx, upstream_xml)
  local channel_label = { "channel_id" }
  local timeout_label = { "channel_id", "timeout_type" }
  for block in xml_blocks(upstream_xml, "upstream") do
    local channel_id = zfill2(xml_text(block, "usid"))
    local labels = { channel_id = channel_id }
    ctx:metric("connectbox_upstream_frequency_hz", "gauge", "Upstream channel frequency", channel_label, labels, as_number(xml_text(block, "freq")))
    ctx:metric("connectbox_upstream_power_level_dbmv", "gauge", "Upstream channel power level", channel_label, labels, as_number(xml_text(block, "power")))
    ctx:metric("connectbox_upstream_symbol_rate_ksps", "gauge", "Upstream channel symbol rate", channel_label, labels, as_number(xml_text(block, "srate")))
    ctx:metric("connectbox_upstream_modulation_info", "gauge", "Upstream channel modulation and type", { "channel_id", "modulation", "channel_type", "upstream_type", "message_type" }, {
      channel_id = channel_id,
      modulation = xml_text(block, "mod") or "",
      channel_type = xml_text(block, "channeltype") or "",
      upstream_type = xml_text(block, "ustype") or "",
      message_type = xml_text(block, "messageType") or "",
    }, 1)
    ctx:metric("connectbox_upstream_timeouts_total", "counter", "Upstream channel timeout occurrences", timeout_label, { channel_id = channel_id, timeout_type = "T1" }, as_number(xml_text(block, "t1Timeouts")))
    ctx:metric("connectbox_upstream_timeouts_total", "counter", "Upstream channel timeout occurrences", timeout_label, { channel_id = channel_id, timeout_type = "T2" }, as_number(xml_text(block, "t2Timeouts")))
    ctx:metric("connectbox_upstream_timeouts_total", "counter", "Upstream channel timeout occurrences", timeout_label, { channel_id = channel_id, timeout_type = "T3" }, as_number(xml_text(block, "t3Timeouts")))
    ctx:metric("connectbox_upstream_timeouts_total", "counter", "Upstream channel timeout occurrences", timeout_label, { channel_id = channel_id, timeout_type = "T4" }, as_number(xml_text(block, "t4Timeouts")))
  end
end

local function emit_lan_users(ctx, lan_xml)
  local label_order = { "mac_address", "ipv4_address", "ipv6_address", "hostname" }
  local function emit_clients(parent_tag, metric_name, help)
    local parent = lan_xml:match("<%s*" .. parent_tag .. "[^>]*>(.-)</%s*" .. parent_tag .. "%s*>") or ""
    for block in xml_blocks(parent, "clientinfo") do
      local labels = {
        mac_address = xml_text(block, "MACAddr") or "",
        ipv4_address = xml_text(block, "IPv4Addr") or "",
        ipv6_address = xml_text(block, "IPv6Addr") or "",
        hostname = xml_text(block, "hostname") or "",
      }
      ctx:metric(metric_name, "gauge", help, label_order, labels, as_number(xml_text(block, "speed")))
    end
  end
  emit_clients("Ethernet", "connectbox_ethernet_client_speed_mbit", "Ethernet client network speed")
  emit_clients("WIFI", "connectbox_wifi_client_speed_mbit", "Wi-Fi client network speed")
  ctx:metric("connectbox_lan_client_count", "gauge", "Connected LAN client count", nil, nil, as_number(xml_text(lan_xml, "totalClient")))

end

local function fahrenheit_to_celsius(f)
  if f == nil then
    return nil
  end
  return (f - 32) * 5 / 9
end

local function emit_temperature(ctx, cmstate_xml)
  ctx:metric("connectbox_tuner_temperature_celsius", "gauge", "Tuner temperature", nil, nil, fahrenheit_to_celsius(as_number(xml_text(cmstate_xml, "TunnerTemperature"))))
  ctx:metric("connectbox_temperature_celsius", "gauge", "Temperature", nil, nil, fahrenheit_to_celsius(as_number(xml_text(cmstate_xml, "Temperature"))))
end

local function emit_operational_status(ctx, status_xml)
  local label_order = { "cm_status", "bandmode" }
  ctx:metric("connectbox_operational_status_info", "gauge", "Operational status information", label_order, {
    cm_status = xml_text(status_xml, "cm_status") or "",
    bandmode = xml_text(status_xml, "Bandmode") or "",
  }, 1)
  ctx:metric("connectbox_wifi_bss_enabled", "gauge", "Wi-Fi BSS enabled state", { "band" }, { band = "2g" }, as_number(xml_text(status_xml, "BssEnable2g")))
  ctx:metric("connectbox_wifi_bss_enabled", "gauge", "Wi-Fi BSS enabled state", { "band" }, { band = "5g" }, as_number(xml_text(status_xml, "BssEnable5g")))
  ctx:metric("connectbox_lan_user_count", "gauge", "LAN user count reported by modem status", nil, nil, as_number(xml_text(status_xml, "LanUserCount")))
end

local function emit_frequency_plan(ctx, config_xml)
  ctx:metric("connectbox_frequency_plan_info", "gauge", "Cable modem frequency plan", { "frequency_plan" }, { frequency_plan = xml_text(config_xml, "FrequencyPlan") or "" }, 1)
  ctx:metric("connectbox_locked_frequency_hz", "gauge", "Locked channel frequency", nil, nil, as_number(xml_text(config_xml, "Frequency")))
end

local function emit_port_status(ctx, ports_xml)
  local seen = {}
  local label_order = { "port_id" }
  for block in xml_blocks(ports_xml, "port") do
    local port_id = xml_text(block, "Eth")
    if port_id and port_id ~= "" then
      seen[port_id] = true
      local labels = { port_id = port_id }
      ctx:metric("connectbox_ethernet_port_connected", "gauge", "Ethernet port link state", label_order, labels, 1)
      ctx:metric("connectbox_ethernet_port_speed_mbit", "gauge", "Ethernet port link speed", label_order, labels, as_number(xml_text(block, "Speed")))
    end
  end
  for port_id = 0, 3 do
    local key = tostring(port_id)
    if not seen[key] then
      ctx:metric("connectbox_ethernet_port_connected", "gauge", "Ethernet port link state", label_order, { port_id = key }, 0)
    end
  end
  ctx:metric("connectbox_ethernet_connected_device_count", "gauge", "Connected Ethernet device count", nil, nil, as_number(xml_text(ports_xml, "Device")))
end

local function emit_service_status(ctx, status_xml)
  ctx:metric("connectbox_max_cpes", "gauge", "Maximum allowed customer premises equipment", nil, nil, as_number(xml_text(status_xml, "dMaxCpes")))
  ctx:metric("connectbox_number_of_cpes", "gauge", "Number of customer premises equipment", nil, nil, as_number(xml_text(status_xml, "NumberOfCpes")))
  ctx:metric("connectbox_bpi_enabled", "gauge", "Baseline Privacy Interface enabled state", nil, nil, as_number(xml_text(status_xml, "bpiEnable")))

  local ds_labels = { "slot", "channel_id", "frequency_hz", "modulation", "primary" }
  local slot = 0
  for block in xml_blocks(status_xml, "downstream") do
    slot = slot + 1
    local labels = {
      slot = tostring(slot),
      channel_id = zfill2(xml_text(block, "chid")),
      frequency_hz = xml_text(block, "freq") or "",
      modulation = xml_text(block, "mod") or "",
      primary = xml_text(block, "primarySettings") or "",
    }
    ctx:metric("connectbox_docsis_downstream_channel_state", "gauge", "DOCSIS downstream channel state", ds_labels, labels, as_number(xml_text(block, "state")))
    ctx:metric("connectbox_docsis_downstream_channel_status", "gauge", "DOCSIS downstream channel status", ds_labels, labels, as_number(xml_text(block, "status")))
  end

  local us_labels = { "slot", "channel_id", "frequency_hz" }
  slot = 0
  for block in xml_blocks(status_xml, "upstream") do
    slot = slot + 1
    local labels = {
      slot = tostring(slot),
      channel_id = zfill2(xml_text(block, "usid")),
      frequency_hz = xml_text(block, "freq") or "",
    }
    ctx:metric("connectbox_docsis_upstream_channel_state", "gauge", "DOCSIS upstream channel state", us_labels, labels, as_number(xml_text(block, "state")))
    ctx:metric("connectbox_docsis_upstream_channel_power_raw", "gauge", "DOCSIS upstream channel raw power value from status", us_labels, labels, as_number(xml_text(block, "power")))
  end

  local flow_labels = { "service_flow_id", "direction", "scheduling_type" }
  for block in xml_blocks(status_xml, "serviceflow") do
    local labels = {
      service_flow_id = xml_text(block, "Sfid") or "",
      direction = xml_text(block, "direction") or "",
      scheduling_type = xml_text(block, "pSchedulingType") or "",
    }
    ctx:metric("connectbox_service_flow_max_traffic_rate_bps", "gauge", "DOCSIS service flow maximum traffic rate", flow_labels, labels, as_number(xml_text(block, "pMaxTrafficRate")))
    ctx:metric("connectbox_service_flow_min_reserved_rate_bps", "gauge", "DOCSIS service flow minimum reserved rate", flow_labels, labels, as_number(xml_text(block, "pMinReservedRate")))
    ctx:metric("connectbox_service_flow_max_traffic_burst_bytes", "gauge", "DOCSIS service flow maximum traffic burst", flow_labels, labels, as_number(xml_text(block, "pMaxTrafficBurst")))
    ctx:metric("connectbox_service_flow_max_concat_burst_bytes", "gauge", "DOCSIS service flow maximum concat burst", flow_labels, labels, as_number(xml_text(block, "pMaxConcatBurst")))
  end
end

local function emit_eventlog(ctx, eventlog_xml)
  local counts = {}
  local total = 0
  for block in xml_blocks(eventlog_xml, "eventlog") do
    local priority = xml_text(block, "prior") or "unknown"
    counts[priority] = (counts[priority] or 0) + 1
    total = total + 1
  end
  ctx:metric("connectbox_eventlog_entries", "gauge", "Event log entries returned by priority", { "priority" }, { priority = "all" }, total)
  for priority, count in pairs(counts) do
    ctx:metric("connectbox_eventlog_entries", "gauge", "Event log entries returned by priority", { "priority" }, { priority = priority }, count)
  end
end

local function parse_uptime_seconds(s)
  if not s then
    return -1
  end
  local days, hours, minutes, seconds = s:match("^(%d+)day%(s%)(%d+)h:(%d+)m:(%d+)s$")
  if not days then
    return -1
  end
  return tonumber(days) * 86400 + tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(seconds)
end

M.parse_uptime_seconds = parse_uptime_seconds

local function emit_device(ctx, global_xml, system_xml, status_xml)
  local provisioning_status = xml_text(status_xml, "provisioning_st") or "unknown"
  local known = false
  for i = 1, #PROVISIONING_STATUSES do
    if provisioning_status == PROVISIONING_STATUSES[i] then
      known = true
      break
    end
  end
  if not known then
    provisioning_status = "unknown"
  end

  local info_labels = {
    "hardware_version",
    "firmware_version",
    "docsis_mode",
    "cm_provision_mode",
    "gw_provision_mode",
    "cable_modem_status",
    "operator_id",
  }
  ctx:metric("connectbox_device_info", "gauge", "Assorted device information", info_labels, {
    hardware_version = xml_text(system_xml, "cm_hardware_version") or "",
    firmware_version = xml_text(global_xml, "SwVersion") or "",
    docsis_mode = xml_text(system_xml, "cm_docsis_mode") or "",
    cm_provision_mode = xml_text(global_xml, "CmProvisionMode") or "Unknown",
    gw_provision_mode = xml_text(global_xml, "GwProvisionMode") or "",
    cable_modem_status = xml_text(status_xml, "cm_comment") or "",
    operator_id = xml_text(global_xml, "OperatorId") or "",
  }, 1)

  local status_label = { "status" }
  for i = 1, #PROVISIONING_STATUSES do
    local status = PROVISIONING_STATUSES[i]
    ctx:metric("connectbox_provisioning_status", "gauge", "Provisioning status description", status_label, { status = status }, status == provisioning_status and 1 or 0)
  end

  ctx:metric("connectbox_uptime_seconds", "gauge", "Device uptime in seconds", nil, nil, parse_uptime_seconds(xml_text(system_xml, "cm_system_uptime")))
end

function M.emit_from_xmls(xmls)
  local ctx = Context.new()
  if xmls[FUN.GLOBALSETTINGS] and xmls[FUN.CMSTATUS] then
    emit_device(ctx, xmls[FUN.GLOBALSETTINGS], xmls[FUN.CM_SYSTEM_INFO], xmls[FUN.CMSTATUS])
  end
  if xmls[FUN.DOWNSTREAM_TABLE] then
    emit_downstream(ctx, xmls[FUN.DOWNSTREAM_TABLE], xmls[FUN.SIGNAL_TABLE])
  end
  if xmls[FUN.UPSTREAM_TABLE] then
    emit_upstream(ctx, xmls[FUN.UPSTREAM_TABLE])
  end
  if xmls[FUN.CM_OPERATIONAL_STATUS] then
    emit_operational_status(ctx, xmls[FUN.CM_OPERATIONAL_STATUS])
  end
  if xmls[FUN.CM_FREQUENCY_PLAN] then
    emit_frequency_plan(ctx, xmls[FUN.CM_FREQUENCY_PLAN])
  end
  if xmls[FUN.LANUSERTABLE] then
    emit_lan_users(ctx, xmls[FUN.LANUSERTABLE])
  end
  if xmls[FUN.CMSTATE] then
    emit_temperature(ctx, xmls[FUN.CMSTATE])
  end
  if xmls[FUN.PORT_STATUS] then
    emit_port_status(ctx, xmls[FUN.PORT_STATUS])
  end
  if xmls[FUN.CMSTATUS] then
    emit_service_status(ctx, xmls[FUN.CMSTATUS])
  end
  if xmls[FUN.EVENTLOG_TABLE] then
    emit_eventlog(ctx, xmls[FUN.EVENTLOG_TABLE])
  end
  return table.concat(ctx.lines, "\n") .. "\n"
end

local SCRAPERS = {
  device_status = function(ctx, client)
    local ok_system, system_xml = pcall(function()
      return client:get(FUN.CM_SYSTEM_INFO)
    end)
    if not ok_system then
      system_xml = nil
    end
    emit_device(ctx, client:get(FUN.GLOBALSETTINGS), system_xml, client:get(FUN.CMSTATUS))
  end,
  downstream = function(ctx, client)
    local ok_signal, signal_xml = pcall(function()
      return client:get(FUN.SIGNAL_TABLE)
    end)
    if not ok_signal then
      signal_xml = nil
    end
    emit_downstream(ctx, client:get(FUN.DOWNSTREAM_TABLE), signal_xml)
  end,
  upstream = function(ctx, client)
    emit_upstream(ctx, client:get(FUN.UPSTREAM_TABLE))
  end,
  lan_users = function(ctx, client)
    emit_lan_users(ctx, client:get(FUN.LANUSERTABLE))
  end,
  operational_status = function(ctx, client)
    emit_operational_status(ctx, client:get(FUN.CM_OPERATIONAL_STATUS))
  end,
  frequency_plan = function(ctx, client)
    emit_frequency_plan(ctx, client:get(FUN.CM_FREQUENCY_PLAN))
  end,
  temperature = function(ctx, client)
    emit_temperature(ctx, client:get(FUN.CMSTATE))
  end,
  port_status = function(ctx, client)
    emit_port_status(ctx, client:get(FUN.PORT_STATUS))
  end,
  service_status = function(ctx, client)
    emit_service_status(ctx, client:get(FUN.CMSTATUS))
  end,
  eventlog = function(ctx, client)
    emit_eventlog(ctx, client:get(FUN.EVENTLOG_TABLE))
  end,
}

local function debug_log(opts, message)
  if opts and opts.debug then
    io.stderr:write("ch7465lg-metrics: ", tostring(message), "\n")
  end
end

function M.collect(opts)
  opts = opts or {}
  local ctx = Context.new()
  local scrape_duration = {}
  local scrape_success = {}
  for i = 1, #EXTRACTORS do
    scrape_success[EXTRACTORS[i]] = 0
  end

  local login_logout_success = 0
  local ok_client, client = pcall(M.new_client, opts)
  if ok_client then
    local authenticated = false
    if client:load_session_cache() then
      local ok_cached = pcall(function()
        return client:get(FUN.CMSTATUS)
      end)
      if ok_cached then
        authenticated = true
        login_logout_success = 1
        debug_log(opts, "using cached Connect Box session")
      else
        client:clear_session()
        client:remove_session_cache()
        debug_log(opts, "cached Connect Box session expired")
      end
    end
    if not authenticated then
      local ok_login, login_err = pcall(function()
        client:login()
      end)
      if ok_login then
        authenticated = true
        login_logout_success = 1
        client:save_session_cache()
      else
        client:remove_session_cache()
        debug_log(opts, "login failed: " .. tostring(login_err))
      end
    end
    if authenticated then
      for i = 1, #EXTRACTORS do
        local name = EXTRACTORS[i]
        local started = now()
        local ok, scrape_err = pcall(SCRAPERS[name], ctx, client)
        if ok then
          scrape_success[name] = 1
          scrape_duration[name] = now() - started
        else
          debug_log(opts, name .. " scrape failed: " .. tostring(scrape_err))
        end
      end
      if client.session_cache then
        client:save_session_cache()
      else
        local ok_logout, logout_err = pcall(function()
          client:logout()
        end)
        if not ok_logout then
          login_logout_success = 0
          debug_log(opts, "logout failed: " .. tostring(logout_err))
        end
      end
    end
  else
    debug_log(opts, "client setup failed: " .. tostring(client))
  end
  scrape_success.login_logout = login_logout_success

  local extractor_label = { "extractor" }
  for i = 1, #EXTRACTORS do
    local name = EXTRACTORS[i]
    if scrape_duration[name] ~= nil then
      ctx:metric("connectbox_scrape_duration_seconds", "gauge", "Scrape duration by extractor", extractor_label, { extractor = name }, scrape_duration[name])
    end
  end
  for i = 1, #EXTRACTORS do
    local name = EXTRACTORS[i]
    ctx:metric("connectbox_up", "gauge", "Connect Box exporter scrape success by extractor", extractor_label, { extractor = name }, scrape_success[name])
  end
  ctx:metric("connectbox_up", "gauge", "Connect Box exporter scrape success by extractor", extractor_label, { extractor = "login_logout" }, scrape_success.login_logout)

  return table.concat(ctx.lines, "\n") .. "\n", login_logout_success == 1
end

local function load_uci_config(package_name)
  local ok, uci = pcall(require, "uci")
  if not ok then
    return {}
  end
  local cursor = uci.cursor()
  local section = "main"
  local cfg = {}
  cfg.host = cursor:get(package_name, section, "host")
  cfg.password = cursor:get(package_name, section, "password")
  cfg.timeout = cursor:get(package_name, section, "timeout")
  cfg.interface = cursor:get(package_name, section, "interface")
  cfg.password_encryption = cursor:get(package_name, section, "password_encryption")
  cfg.session_cache = cursor:get(package_name, section, "session_cache")
  return cfg
end

local function usage(stream)
  stream:write("Usage: ch7465lg-metrics [--host HOST] [--interface IFACE_OR_SOURCE_IP] [--password PASSWORD] [--password-encryption cbn|plain] [--timeout SECONDS] [--no-session-cache] [--debug] [--no-config]\n")
  stream:write("Scrapes a Compal CH7465LG / ConnectBox and writes Prometheus metrics to stdout.\n")
end

function M.default_options(overrides)
  local opts = { uci_package = "compal-ch7465lg", use_config = true }
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
  opts.password = opts.password or config.password or os.getenv("MODEM_PASSWORD") or os.getenv("CONNECTBOX_PASSWORD")
  opts.timeout = opts.timeout or config.timeout or DEFAULT_TIMEOUT
  opts.interface = opts.interface or config.interface or os.getenv("CONNECTBOX_INTERFACE") or os.getenv("MODEM_INTERFACE")
  opts.password_encryption = opts.password_encryption or config.password_encryption or os.getenv("CONNECTBOX_PASSWORD_ENCRYPTION") or os.getenv("MODEM_PASSWORD_ENCRYPTION") or "cbn"
  opts.session_cache = non_empty(opts.session_cache) or non_empty(config.session_cache) or os.getenv("CONNECTBOX_SESSION_CACHE") or os.getenv("MODEM_SESSION_CACHE") or "1"
  if opts.password_encryption ~= "cbn" and opts.password_encryption ~= "plain" then
    error("password_encryption must be 'cbn' or 'plain'")
  end
  opts.debug = opts.debug or os.getenv("CONNECTBOX_DEBUG") == "1" or os.getenv("MODEM_DEBUG") == "1"
  return opts
end

local function require_arg_value(argv, index, name)
  local value = argv[index]
  if value == nil or value:match("^%-%-") then
    error(name .. " requires a value")
  end
  return value
end

function M.parse_args(argv)
  local opts = { uci_package = "compal-ch7465lg", use_config = true }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--no-config" then
      opts.use_config = false
    elseif a == "--debug" then
      opts.debug = true
    elseif a == "--no-session-cache" then
      opts.session_cache = "0"
    elseif a == "--host" then
      i = i + 1
      opts.host = require_arg_value(argv, i, a)
    elseif a:match("^%-%-host=") then
      opts.host = a:match("^%-%-host=(.*)$")
    elseif a == "--password" then
      i = i + 1
      opts.password = require_arg_value(argv, i, a)
    elseif a == "--interface" then
      i = i + 1
      opts.interface = require_arg_value(argv, i, a)
    elseif a:match("^%-%-interface=") then
      opts.interface = a:match("^%-%-interface=(.*)$")
    elseif a:match("^%-%-password=") then
      opts.password = a:match("^%-%-password=(.*)$")
    elseif a == "--password-encryption" then
      i = i + 1
      opts.password_encryption = require_arg_value(argv, i, a)
    elseif a:match("^%-%-password%-encryption=") then
      opts.password_encryption = a:match("^%-%-password%-encryption=(.*)$")
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

  if opts.password == nil or opts.password == "" then
    io.stderr:write("missing password: set /etc/config/compal-ch7465lg option password or MODEM_PASSWORD\n")
    return 2
  end

  local metrics = M.collect(opts)
  io.write(metrics)
  return 0
end

return M
