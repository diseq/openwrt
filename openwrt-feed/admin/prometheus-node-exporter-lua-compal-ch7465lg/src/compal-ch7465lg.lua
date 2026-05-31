local scraper = require("ch7465lg_metrics")

local function scrape()
  local opts = scraper.default_options()
  if opts.password == nil or opts.password == "" then
    error("missing password: set /etc/config/compal-ch7465lg option password or MODEM_PASSWORD")
  end
  local metrics = scraper.collect(opts)
  out:write(metrics)
end

return { scrape = scrape }
