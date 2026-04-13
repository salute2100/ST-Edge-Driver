-- user_switch.lua
-- 사용자별 Child presenceSensor 관리
-- 지문/비번으로 열릴 때 해당 사용자 present → 잠길 때 not present

local capabilities = require "st.capabilities"
local presenceSensor = capabilities.presenceSensor
local log = require "log"

local user_switch = {}

local LAST_USER_KEY = "last_user_slot"

function user_switch.get_user_map(device)
  local map = {}
  if not device.preferences then return map end
  for i = 1, 8 do
    local slot = device.preferences["fp" .. i .. "Slot"]
    local name = device.preferences["fp" .. i .. "Name"]
    if slot ~= nil and slot ~= 0 and name ~= nil and name ~= "" then
      local safe_name = name:gsub("[%s%p]", "_")
      map[slot] = { name = name, key = "uslot_" .. tostring(slot), safe_name = safe_name }
    end
  end
  return map
end

function user_switch.find_child(driver, parent, child_key, label)
  for _, device in ipairs(driver:get_devices()) do
    if device.parent_device_id == parent.id then
      if device.parent_assigned_child_key == child_key then
        return device
      end
      if label and device.label == label then
        return device
      end
    end
  end
  return nil
end

function user_switch.create_child(driver, parent, slot, name, child_key)
  if user_switch.find_child(driver, parent, child_key, name) then
    log.info("[UserSwitch] 이미 존재: " .. name)
    return
  end
  log.info("[UserSwitch] Child Switch 생성: " .. name)
  local metadata = {
    type = "EDGE_CHILD",
    parent_device_id = parent.id,
    parent_assigned_child_key = child_key,
    label = name,
    profile = "door-user-switch",
    manufacturer = "SamsungSDS",
    model = "DoorLockUser"
  }
  local ok, err = driver:try_create_device(metadata)
  if ok then
    log.info("[UserSwitch] 생성 요청 성공: " .. name)
  else
    log.error("[UserSwitch] 생성 실패: " .. name .. " / err=" .. tostring(err))
  end
end

function user_switch.delete_child(driver, parent, slot)
  local child_key = "user_slot_" .. slot
  local child = user_switch.find_child(driver, parent, child_key)
  if child then
    log.info("[UserSwitch] Child Switch 삭제: 슬롯 " .. slot)
    driver:try_delete_device(child.id)
  end
end

function user_switch.sync_children(driver, device)
  local map = user_switch.get_user_map(device)
  log.info("[UserSwitch] sync_children: 사용자 수 = " .. tostring(#map))

  local active_keys = {}
  local created = {}
  local count = 0
  for slot, info in pairs(map) do
    count = count + 1
    log.info("[UserSwitch] 슬롯 " .. slot .. " → " .. info.name .. " (" .. info.key .. ")")
    if not created[info.name] then
      active_keys[info.key] = true
      active_keys[info.name] = true
      user_switch.create_child(driver, device, slot, info.name, info.key)
      created[info.name] = true
    end
  end
  log.info("[UserSwitch] 처리된 슬롯 수: " .. count)

  for _, child in ipairs(driver:get_devices()) do
    if child.parent_device_id == device.id then
      if not active_keys[child.label] then
        log.info("[UserSwitch] 미사용 Child Switch 삭제: " .. child.label)
        driver:try_delete_device(child.id)
      end
    end
  end
end

-- 인증 열림 → present (잠길 때까지 유지)
function user_switch.on_unlock(driver, device, slot)
  local map = user_switch.get_user_map(device)
  local info = map[slot]
  if not info then return end

  local child = user_switch.find_child(driver, device, info.key, info.name)
  if not child then
    log.warn("[UserSwitch] Child 없음: " .. info.name .. " (key=" .. info.key .. ")")
    return
  end

  log.info("[UserSwitch] present: " .. info.name)
  child:emit_event(presenceSensor.presence("present"))
  device:set_field(LAST_USER_KEY, slot, { persist = false })
end

-- 잠김 → 마지막 인증 사용자 not present
function user_switch.on_lock(driver, device)
  local last_slot = device:get_field(LAST_USER_KEY)
  if not last_slot then return end

  local map = user_switch.get_user_map(device)
  local info = map[last_slot]
  if not info then return end

  local child = user_switch.find_child(driver, device, info.key, info.name)
  if child then
    log.info("[UserSwitch] 잠김 → not present: " .. info.name)
    child:emit_event(presenceSensor.presence("not present"))
  end
  device:set_field(LAST_USER_KEY, nil)
end

return user_switch
