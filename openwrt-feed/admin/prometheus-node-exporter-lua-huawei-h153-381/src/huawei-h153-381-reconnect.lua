#!/usr/bin/lua

local scraper = require("huawei_h153_381_metrics")
os.exit(scraper.reconnect_main(arg or {}))
