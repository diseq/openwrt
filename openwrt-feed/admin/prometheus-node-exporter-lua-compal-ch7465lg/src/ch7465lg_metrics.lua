local M = {}

local DEFAULT_TIMEOUT = 9
local DEFAULT_HOST = "192.168.0.1"

local FUN = {
  GLOBALSETTINGS = 1,
  CM_SYSTEM_INFO = 2,
  DOWNSTREAM_TABLE = 10,
  UPSTREAM_TABLE = 11,
  SIGNAL_TABLE = 12,
  LOGIN = 15,
  LOGOUT = 16,
  LANUSERTABLE = 123,
  CMSTATE = 136,
  CMSTATUS = 144,
}

local EXTRACTORS = {
  "device_status",
  "downstream",
  "upstream",
  "lan_users",
  "temperature",
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
  local v = xml:match("<%s*" .. p .. "[^>]*>(.-)</%s*" .. p .. "%s*>")
  return xml_unescape(trim(v))
end

local function xml_blocks(xml, tag)
  local p = tag_pat(tag)
  local pattern = "<%s*" .. p .. "[^>]*>(.-)</%s*" .. p .. "%s*>"
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
    base_url = normalize_base_url(opts.host),
    password = opts.password,
    http = http,
    ltn12 = ltn12,
    bind_address = bind_address,
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
  local headers = {}
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

function Client:login()
  if self.password == nil or self.password == "" then
    error("password is required")
  end

  pcall(function()
    self:request("GET", "/common_page/login.html")
  end)
  if not (self.cookies.sessionToken or self.cookies.SessionToken) then
    self:request("GET", "/")
  end

  local body = encode_form({
    { "token", self:get_session_token() },
    { "fun", FUN.LOGIN },
    { "Username", "NULL" },
    { "Password", self.password },
  })
  local response = self:request("POST", "/xml/setter.xml", body)
  local sid = response:match("^%s*successful;SID=(%d+)")
  if not sid then
    error("login failed")
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
  end
  for block in xml_blocks(signal_xml, "signal") do
    local channel_id = zfill2(xml_text(block, "dsid"))
    local labels = { channel_id = channel_id }
    ctx:metric("connectbox_downstream_codewords_unerrored_total", "counter", "Unerrored downstream codewords", channel_label, labels, as_number(xml_text(block, "unerrored")))
    ctx:metric("connectbox_downstream_codewords_corrected_total", "counter", "Corrected downstream codewords", channel_label, labels, as_number(xml_text(block, "correctable")))
    ctx:metric("connectbox_downstream_codewords_uncorrectable_total", "counter", "Uncorrectable downstream codewords", channel_label, labels, as_number(xml_text(block, "uncorrectable")))
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
  if xmls[FUN.GLOBALSETTINGS] and xmls[FUN.CM_SYSTEM_INFO] and xmls[FUN.CMSTATUS] then
    emit_device(ctx, xmls[FUN.GLOBALSETTINGS], xmls[FUN.CM_SYSTEM_INFO], xmls[FUN.CMSTATUS])
  end
  if xmls[FUN.DOWNSTREAM_TABLE] and xmls[FUN.SIGNAL_TABLE] then
    emit_downstream(ctx, xmls[FUN.DOWNSTREAM_TABLE], xmls[FUN.SIGNAL_TABLE])
  end
  if xmls[FUN.UPSTREAM_TABLE] then
    emit_upstream(ctx, xmls[FUN.UPSTREAM_TABLE])
  end
  if xmls[FUN.LANUSERTABLE] then
    emit_lan_users(ctx, xmls[FUN.LANUSERTABLE])
  end
  if xmls[FUN.CMSTATE] then
    emit_temperature(ctx, xmls[FUN.CMSTATE])
  end
  return table.concat(ctx.lines, "\n") .. "\n"
end

local SCRAPERS = {
  device_status = function(ctx, client)
    emit_device(ctx, client:get(FUN.GLOBALSETTINGS), client:get(FUN.CM_SYSTEM_INFO), client:get(FUN.CMSTATUS))
  end,
  downstream = function(ctx, client)
    emit_downstream(ctx, client:get(FUN.DOWNSTREAM_TABLE), client:get(FUN.SIGNAL_TABLE))
  end,
  upstream = function(ctx, client)
    emit_upstream(ctx, client:get(FUN.UPSTREAM_TABLE))
  end,
  lan_users = function(ctx, client)
    emit_lan_users(ctx, client:get(FUN.LANUSERTABLE))
  end,
  temperature = function(ctx, client)
    emit_temperature(ctx, client:get(FUN.CMSTATE))
  end,
}

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
    local ok_login = pcall(function()
      client:login()
    end)
    if ok_login then
      login_logout_success = 1
      for i = 1, #EXTRACTORS do
        local name = EXTRACTORS[i]
        local started = now()
        local ok = pcall(SCRAPERS[name], ctx, client)
        if ok then
          scrape_success[name] = 1
          scrape_duration[name] = now() - started
        end
      end
      local ok_logout = pcall(function()
        client:logout()
      end)
      if not ok_logout then
        login_logout_success = 0
      end
    end
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
  return cfg
end

local function usage(stream)
  stream:write("Usage: ch7465lg-metrics [--host HOST] [--interface IFACE_OR_SOURCE_IP] [--password PASSWORD] [--timeout SECONDS] [--no-config]\n")
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
