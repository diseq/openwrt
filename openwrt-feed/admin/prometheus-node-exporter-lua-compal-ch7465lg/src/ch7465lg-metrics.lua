#!/usr/bin/lua

local scraper = require("ch7465lg_metrics")
os.exit(scraper.main(arg or {}))
