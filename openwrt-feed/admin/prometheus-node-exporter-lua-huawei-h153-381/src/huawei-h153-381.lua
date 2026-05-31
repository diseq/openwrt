local scraper = require("huawei_h153_381_metrics")

local function scrape()
  local metrics = scraper.collect(scraper.default_options())
  out:write(metrics)
end

return { scrape = scrape }
