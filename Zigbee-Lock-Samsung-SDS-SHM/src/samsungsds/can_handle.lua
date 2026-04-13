-- Copyright 2025 SmartThings, Inc. / Custom Enhancement
-- Licensed under the Apache License, Version 2.0

local function samsungsds_can_handle(opts, driver, device, ...)
  local mfr = device:get_manufacturer()
  if mfr == "SAMSUNG SDS" or mfr == "Zigbang" then
    return true, require("samsungsds")
  end
  return false
end

return samsungsds_can_handle
