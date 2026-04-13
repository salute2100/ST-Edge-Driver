-- user_switch.lua
-- 사용자별 Child Switch 관리
-- 지문으로 열릴 때 해당 사용자 Switch ON → 5초 후 OFF
-- 잠길 때 마지막 사용자 Switch OFF

local capabilities = require "st.capabilities"
local presenceSensor = capabilities.presenceSensor
local log = require "log"

local user_switch = {}

local LAST_USER_KEY = "last_user_slot"

-- Preferences에서 슬롯→이름 매핑 테이블 빌드
-- child_key는 이름 기준 → 같은 이름(같은 사람)은 하나의 Child Switch 공유
function user_switch.get_user_map(device)
  local map = {}  -- { [slot_number] = { name=..., key=... } }
  if not device.preferences then return map end
  for i = 1, 8 do
    local slot = device.preferences["fp" .. i .. "Slot"]
    local name = device.preferences["fp" .. i .. "Name"]
    if slot ~= nil and slot ~= 0 and name ~= nil and name ~= "" then
      -- key는 슬롯 기준으로 고정 (이름이 같아도 슬롯별로 관리)
      -- 단, 같은 이름이면 find_child에서 이름으로 찾아서 공유
      local safe_name = name:gsub("[%s%p]", "_")
      map[slot] = { name = name, key = "uslot_" .. tostring(slot), safe_name = safe_name }
    end
  end
  return map
end

-- Child Device 찾기 (label 또는 child_key로)
function user_switch.find_child(driver, parent, child_key, label)
  for _, device in ipairs(driver:get_devices()) do
    if device.parent_device_id == parent.id then
      if device.parent_assigned_child_key == child_key then
        return device
      end
      -- 이름이 같은 Child Switch 찾기 (key가 달라도)
      if label and device.label == label then
        return device
      end
    end
  end
  return nil
end

-- Child Switch 생성
function user_switch.create_child(driver, parent, slot, name, child_key)
  -- key 또는 label로 이미 존재하는지 확인
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

-- Child Switch 삭제
function user_switch.delete_child(driver, parent, slot)
  local child_key = "user_slot_" .. slot
  local child = user_switch.find_child(driver, parent, child_key)
  if child then
    log.info("[UserSwitch] Child Switch 삭제: 슬롯 " .. slot)
    driver:try_delete_device(child.id)
  end
end

-- Preferences 변경 시 Child Switch 동기화
function user_switch.sync_children(driver, device)
  local map = user_switch.get_user_map(device)
  log.info("[UserSwitch] sync_children: 사용자 수 = " .. tostring(#map))

  -- 활성 key 목록 (이름 기준, 중복 제거)
  local active_keys = {}
  local created = {}  -- 이미 생성한 key 추적
  local count = 0
  for slot, info in pairs(map) do
    count = count + 1
    log.info("[UserSwitch] 슬롯 " .. slot .. " → " .. info.name .. " (" .. info.key .. ")")
    -- 이름 기준으로 중복 방지
    if not created[info.name] then
      active_keys[info.key] = true
      active_keys[info.name] = true  -- 이름도 active로 표시
      user_switch.create_child(driver, device, slot, info.name, info.key)
      created[info.name] = true
    end
  end
  log.info("[UserSwitch] 처리된 슬롯 수: " .. count)

  -- 더 이상 없는 Child Switch 삭제 (이름 기준)
  for _, child in ipairs(driver:get_devices()) do
    if child.parent_device_id == device.id then
      if not active_keys[child.label] then
        log.info("[UserSwitch] 미사용 Child Switch 삭제: " .. child.label)
        driver:try_delete_device(child.id)
      end
    end
  end
end

-- 지문 열림 → 해당 사용자 Switch ON → 5초 후 OFF
function user_switch.on_unlock(driver, device, slot)
  local map = user_switch.get_user_map(device)
  local info = map[slot]
  if not info then return end

  local child = user_switch.find_child(driver, device, info.key, info.name)
  if not child then
    log.warn("[UserSwitch] Child 없음: " .. info.name .. " (key=" .. info.key .. ")")
    return
  end

  log.info("[UserSwitch] 감지: " .. info.name)
  child:emit_event(presenceSensor.presence("present"))
  device:set_field(LAST_USER_KEY, slot, { persist = false })

  -- 5초 후 not present
  device.thread:call_with_delay(5, function()
    child:emit_event(presenceSensor.presence("not present"))
    log.info("[UserSwitch] 감지 종료: " .. info.name)
  end)
end

-- 잠김 → 마지막 사용자 Switch OFF
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
