-- Copyright 2022 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

local log = require "log"
local device_management = require "st.zigbee.device_management"
local clusters = require "st.zigbee.zcl.clusters"
local battery_defaults = require "st.zigbee.defaults.battery_defaults"
local capabilities = require "st.capabilities"
local cluster_base = require "st.zigbee.cluster_base"
local PowerConfiguration = clusters.PowerConfiguration
local DoorLock = clusters.DoorLock
local Lock = capabilities.lock
local lock_utils = require "lock_utils"
local user_switch = require "user_switch"

local SAMSUNG_SDS_MFR_SPECIFIC_UNLOCK_COMMAND = 0x1F
local SAMSUNG_SDS_MFR_CODE = 0x0003


local function handle_lock_state(driver, device, value, zb_rx)
  if value.value == DoorLock.attributes.LockState.LOCKED then
    device:emit_event(Lock.lock.locked())
  elseif value.value == DoorLock.attributes.LockState.UNLOCKED then
    device:emit_event(Lock.lock.unlocked())
  end
end

local function mfg_lock_door_handler(driver, device, zb_rx)
  -- 0x1F 응답 처리
  -- 00 = 성공 → RF code=16 OperatingEvent에서 처리하므로 여기서는 emit 안 함
  -- 01 = 실패 → 재택안심 모드 등으로 도어록이 열기 거부한 경우
  local body = zb_rx.body.zcl_body.body_bytes
  if body and body:byte(1) == 0x01 then
    log.warn("[SDS] 앱 열기 실패: 도어록이 거부함 (재택안심 모드 등)")
    device:emit_event(Lock.lock.locked({
      descriptionText = "도어록 버튼으로 해제 후 열어주세요."
    }))
  end
end

local function unlock_cmd_handler(driver, device, command)
  -- 재택안심(armedStay) 상태에서도 Zigbee 커맨드를 보냄
  -- → 도어록 본체가 거부하면서 "재택안심모드가 설정되었습니다" 음성 안내 출력
  -- → 앱은 타임아웃 후 "네트워크 또는 서버에 오류" 표시 (SmartThings 앱 레벨 한계)
  device:send(cluster_base.build_manufacturer_specific_command(
          device,
          DoorLock.ID,
          SAMSUNG_SDS_MFR_SPECIFIC_UNLOCK_COMMAND,
          SAMSUNG_SDS_MFR_CODE,
          "\x10\x04\x31\x32\x33\x35"))
end

local function lock_cmd_handler(driver, device, command)
  -- do nothing in lock command handler
end

local refresh = function(driver, device, cmd)
  device:send(DoorLock.attributes.LockState:read(device))
  -- lockCodes 탭 활성화: NumberOfPINUsersSupported 쿼리
  -- 응답이 오면 베이스 드라이버가 base-lock 프로파일로 전환하여 lockCodes 탭 표시
  device:send(DoorLock.attributes.NumberOfPINUsersSupported:read(device))
end

local function emit_event_if_latest_state_missing(device, component, capability, attribute_name, value)
  if device:get_latest_state(component, capability.ID, attribute_name) == nil then
    device:emit_event(value)
  end
end

local device_added = function(self, device)
  lock_utils.populate_state_from_data(device)
  emit_event_if_latest_state_missing(device, "main", capabilities.lock, capabilities.lock.lock.NAME, capabilities.lock.lock.unlocked())
  device:emit_event(capabilities.battery.battery(100))
  -- lockCodes 탭 활성화: maxCodes 설정
  device:emit_event(capabilities.lockCodes.maxCodes(50, { visibility = { displayed = false } }))
  -- 빈 lock_codes로 초기화 (오염 방지)
  lock_utils.lock_codes_event(device, {})
end

local do_configure = function(self, device)
  device:send(device_management.build_bind_request(device, DoorLock.ID, self.environment_info.hub_zigbee_eui))
  device:send(device_management.build_bind_request(device, PowerConfiguration.ID, self.environment_info.hub_zigbee_eui))
  device:send(DoorLock.attributes.LockState:configure_reporting(device, 0, 3600, 0))
end

local battery_init = battery_defaults.build_linear_voltage_init(4.0, 6.0)

local device_init = function(driver, device, event)
  battery_init(driver, device, event)
  device:remove_monitored_attribute(clusters.PowerConfiguration.ID, clusters.PowerConfiguration.attributes.BatteryVoltage.ID)
  device:remove_configured_attribute(clusters.PowerConfiguration.ID, clusters.PowerConfiguration.attributes.BatteryVoltage.ID)
  lock_utils.populate_state_from_data(device)
  -- lockCodes 탭 활성화: maxCodes 강제 설정
  device:emit_event(capabilities.lockCodes.maxCodes(50, { visibility = { displayed = false } }))
  -- Child Switch 동기화 (5초 딜레이 - 드라이버 완전 로드 후 실행)
  log.info("[UserSwitch] device_init: sync_children 예약")
  device.thread:call_with_delay(5, function()
    log.info("[UserSwitch] sync_children 실행 시작")
    user_switch.sync_children(driver, device)
    log.info("[UserSwitch] sync_children 실행 완료")
  end)
  -- 기존 lock_codes 정리 후 재발송 (reloadAllCodes로 인한 unset 오염 제거)
  local lc = lock_utils.get_lock_codes(device)
  local clean_lc = {}
  for k, v in pairs(lc) do
    if v ~= nil and v ~= "" then
      clean_lc[k] = v
    end
  end
  lock_utils.lock_codes_event(device, clean_lc)
end

-- Preferences 변경 감지 → Child Switch 동기화
local info_changed = function(driver, device, event, args)
  if args and args.old_st_store and args.old_st_store.preferences then
    -- Preferences가 변경됐으면 Child Switch 동기화
    user_switch.sync_children(driver, device)
  end
end

local samsung_sds_driver = {
  NAME = "SAMSUNG SDS Lock Driver",
  zigbee_handlers = {
    cluster = {
      [DoorLock.ID] = {
        [SAMSUNG_SDS_MFR_SPECIFIC_UNLOCK_COMMAND] = mfg_lock_door_handler
      }
    },
    attr = {
      [DoorLock.ID] = {
        [DoorLock.attributes.LockState.ID] = handle_lock_state
      }
    }
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh
    },
    [capabilities.lock.ID] = {
      [capabilities.lock.commands.unlock.NAME] = unlock_cmd_handler,
      [capabilities.lock.commands.lock.NAME] = lock_cmd_handler
    }
  },
  lifecycle_handlers = {
    doConfigure = do_configure,
    added = device_added,
    init = device_init
  },
  can_handle = require("samsungsds.can_handle"),
}

return samsung_sds_driver
