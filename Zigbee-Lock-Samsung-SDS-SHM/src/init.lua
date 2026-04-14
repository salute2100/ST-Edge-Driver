-- Copyright 2022 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0


-- Zigbee Driver utilities
local defaults          = require "st.zigbee.defaults"
local device_management = require "st.zigbee.device_management"
local ZigbeeDriver      = require "st.zigbee"

-- Zigbee Spec Utils
local clusters                = require "st.zigbee.zcl.clusters"
local Alarm                   = clusters.Alarms
local LockCluster             = clusters.DoorLock
local PowerConfiguration      = clusters.PowerConfiguration

-- Capabilities
local capabilities              = require "st.capabilities"
local Battery                   = capabilities.battery
local SecuritySystem            = capabilities.securitySystem
local Lock                      = capabilities.lock
local LockCodes                 = capabilities.lockCodes

-- Enums
local UserStatusEnum            = LockCluster.types.DrlkUserStatus
local UserTypeEnum              = LockCluster.types.DrlkUserType
local ProgrammingEventCodeEnum  = LockCluster.types.ProgramEventCode

local socket = require "cosock.socket"
local lock_utils = require "lock_utils"
local SECURITY_MODE_FIELD = "securityMode"
local user_switch = require "user_switch"
local log = require "log"

local DELAY_LOCK_EVENT = "_delay_lock_event"
local MAX_DELAY = 10

-- 보안모드 상태 emit (securitySystem capability → Home Monitor 연동)
-- triggered_by: nil=자동해제, "user"=사용자 조작 (현재 도어록은 항상 자동해제)
local function emit_security_mode(device, mode, triggered_by)
  log.info("[SecurityMode] 상태 변경: " .. tostring(mode))

  -- 직방 스타일 descriptionText 생성 (set_field 이전에 이전 상태 읽기)
  local desc
  if mode == "armedAway" then
    desc = "외출방범모드가 설정되었습니다."
  elseif mode == "armedStay" then
    desc = "재택안심모드가 설정되었습니다."
  else
    -- 해제: 어떤 모드에서 해제됐는지 이전 상태로 표시
    local prev = device:get_field(SECURITY_MODE_FIELD)
    if prev == "armedAway" then
      desc = "외출방범모드가 해제되었습니다."
    elseif prev == "armedStay" then
      desc = "재택안심모드가 해제되었습니다."
    else
      desc = "보안모드가 해제되었습니다."
    end
  end

  device:set_field(SECURITY_MODE_FIELD, mode, { persist = true })

  -- securitySystem (홈 모니터링 연동)
  if mode == "armedAway" then
    device:emit_event(SecuritySystem.securitySystemStatus.armedAway({ descriptionText = desc }))
  elseif mode == "armedStay" then
    device:emit_event(SecuritySystem.securitySystemStatus.armedStay({ descriptionText = desc }))
  else
    device:emit_event(SecuritySystem.securitySystemStatus.disarmed({ descriptionText = desc }))
  end

end

-- securitySystem 커맨드 핸들러 (홈 모니터링 양방향 연동)
-- 도어록 본체를 Zigbee로 제어 불가하지만 상태 표시는 동기화
-- 홈 모니터링 자동화 활용 가능 (외출방범 설정 시 조명 끄기 등)
local function security_cmd_handler(driver, device, command)
  if command.command == "armAway" then
    emit_security_mode(device, "armedAway")
  elseif command.command == "armStay" then
    emit_security_mode(device, "armedStay")
  elseif command.command == "disarm" then
    emit_security_mode(device, "disarmed")
  end
end

local reload_all_codes = function(driver, device, command)
  -- 삼성 SDS는 PIN 코드 조회 미지원 → 아무것도 하지 않음
  -- (기본 동작 시 1~50 슬롯 전체 unset 이벤트 발생해 기록 오염)
  device:emit_event(LockCodes.scanCodes("Complete", { visibility = { displayed = false } }))
end

local refresh = function(driver, device, cmd)
  device:refresh()
  device:send(LockCluster.attributes.LockState:read(device))
  device:send(Alarm.attributes.AlarmCount:read(device))
  -- we can't determine from fingerprints if devices support lock codes, so
  -- here in the driver we'll do a check once to see if the device responds here
  -- and if it does, we'll switch it to a profile with lock codes
  if not device:supports_capability_by_id(LockCodes.ID) and not device:get_field(lock_utils.CHECKED_CODE_SUPPORT) then
    device:send(LockCluster.attributes.NumberOfPINUsersSupported:read(device))
    -- we won't make this value persist because it's not that important
    device:set_field(lock_utils.CHECKED_CODE_SUPPORT, true)
  end
end

local do_configure = function(self, device)
  device:send(device_management.build_bind_request(device, PowerConfiguration.ID, self.environment_info.hub_zigbee_eui))
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:configure_reporting(device, 600, 21600, 1))

  device:send(device_management.build_bind_request(device, LockCluster.ID, self.environment_info.hub_zigbee_eui))
  device:send(LockCluster.attributes.LockState:configure_reporting(device, 0, 3600, 0))

  device:send(device_management.build_bind_request(device, Alarm.ID, self.environment_info.hub_zigbee_eui))
  device:send(Alarm.attributes.AlarmCount:configure_reporting(device, 0, 21600, 0))

  -- Don't send a reload all codes if this is a part of migration
  if device.data.lockCodes == nil or device:get_field(lock_utils.MIGRATION_RELOAD_SKIPPED) == true then
    device.thread:call_with_delay(2, function(d)
      self:inject_capability_command(device, {
        capability = capabilities.lockCodes.ID,
        command = capabilities.lockCodes.commands.reloadAllCodes.NAME,
        args = {}
      })
    end)
  else
    device:set_field(lock_utils.MIGRATION_RELOAD_SKIPPED, true, { persist = true })
  end
end

local alarm_handler = function(driver, device, zb_mess)
  local alarm_code = zb_mess.body.zcl_body.alarm_code.value
  log.warn(string.format("[SDS] Alarm 수신: alarm_code=0x%02X", alarm_code))

  -- alarm_code: 0x00, 0x01 → 잠금 실패 등 일반 알람
  -- alarm_code: 0x06 → 강제 개방 (Forced Entry)
  --   보안모드 해제 없이 즉시 lock.unlocked 발송
  --   → STHM이 armedStay/armedAway 상태에서 침입 경보 발동
  if alarm_code == 0x06 then
    log.warn("[SDS] 강제 개방 감지 (alarm_code=0x06) → lock.unlocked 즉시 발송")
    local event = Lock.lock.unlocked()
    event["data"] = { method = "manual", codeName = "강제 개방 감지" }
    device:emit_event(event)
    return
  end

  local ALARM_REPORT = {
    [0] = Lock.lock.unknown(),
    [1] = Lock.lock.unknown(),
    -- Events 16-19 are low battery events, but are presented as descriptionText only
  }
  if (ALARM_REPORT[alarm_code] ~= nil) then
    device:emit_event(ALARM_REPORT[alarm_code])
  end
end

local get_pin_response_handler = function(driver, device, zb_mess)
  local event = LockCodes.codeChanged("", { state_change = true })
  local code_slot = tostring(zb_mess.body.zcl_body.user_id.value)
  event.data = {codeName = lock_utils.get_code_name(device, code_slot)}
  if (zb_mess.body.zcl_body.user_status.value == UserStatusEnum.OCCUPIED_ENABLED) then
    -- Code slot is occupied
    event.value = code_slot .. lock_utils.get_change_type(device, code_slot)
    local lock_codes = lock_utils.get_lock_codes(device)
    lock_codes[code_slot] = event.data.codeName
    device:emit_event(event)
    lock_utils.lock_codes_event(device, lock_codes)
    lock_utils.reset_code_state(device, code_slot)
  else
    -- Code slot is unoccupied
    if (lock_utils.get_lock_codes(device)[code_slot] ~= nil) then
      -- Code has been deleted
      lock_utils.lock_codes_event(device, lock_utils.code_deleted(device, code_slot))
    else
      -- Code is unset
      event.value = code_slot .. " unset"
      device:emit_event(event)
    end
  end

  code_slot = tonumber(code_slot)
  if (code_slot == device:get_field(lock_utils.CHECKING_CODE)) then
    -- the code we're checking has arrived
    local last_slot = device:get_latest_state("main", capabilities.lockCodes.ID, capabilities.lockCodes.maxCodes.NAME) - 1
    if (code_slot >= last_slot) then
      device:emit_event(LockCodes.scanCodes("Complete", { visibility = { displayed = false } }))
      device:set_field(lock_utils.CHECKING_CODE, nil)
    else
      local checkingCode = device:get_field(lock_utils.CHECKING_CODE) + 1
      device:set_field(lock_utils.CHECKING_CODE, checkingCode)
      device:send(LockCluster.server.commands.GetPINCode(device, checkingCode))
    end
  end
end

local programming_event_handler = function(driver, device, zb_mess)
  local event = LockCodes.codeChanged("", { state_change = true })
  local code_slot = tostring(zb_mess.body.zcl_body.user_id.value)
  event.data = {}
  if (zb_mess.body.zcl_body.program_event_code.value == ProgrammingEventCodeEnum.MASTER_CODE_CHANGED) then
    -- Master code changed
    event.value = "0 set"
    event.data = {codeName = "Master Code"}
    device:emit_event(event)
  elseif (zb_mess.body.zcl_body.program_event_code.value == ProgrammingEventCodeEnum.PIN_CODE_DELETED) then
    if (zb_mess.body.zcl_body.user_id.value == 0xFF) then
      -- All codes deleted
      for cs, _ in pairs(lock_utils.get_lock_codes(device)) do
        lock_utils.code_deleted(device, cs)
      end
      lock_utils.lock_codes_event(device, {})
    else
      -- One code deleted
      if (lock_utils.get_lock_codes(device)[code_slot] ~= nil) then
        lock_utils.lock_codes_event(device, lock_utils.code_deleted(device, code_slot))
      end
    end
  elseif (zb_mess.body.zcl_body.program_event_code.value == ProgrammingEventCodeEnum.PIN_CODE_ADDED or
          zb_mess.body.zcl_body.program_event_code.value == ProgrammingEventCodeEnum.PIN_CODE_CHANGED) then
    -- Code added or changed
    local change_type = lock_utils.get_change_type(device, code_slot)
    local code_name = lock_utils.get_code_name(device, code_slot)
    event.value = code_slot .. change_type
    event.data = {codeName = code_name}
    device:emit_event(event)
    if (change_type == " set") then
      local lock_codes = lock_utils.get_lock_codes(device)
      lock_codes[code_slot] = code_name
      lock_utils.lock_codes_event(device, lock_codes)
    end
  end
end

local handle_max_codes = function(driver, device, value)
  if value.value ~= 0 then
    -- Here's where we'll end up if we queried a lock whose profile does not have lock codes,
    -- but it gave us a non-zero number of pin users, so we want to switch the profile
    if not device:supports_capability_by_id(LockCodes.ID) then
      device:try_update_metadata({profile = "base-lock"}) -- switch to a lock with codes
      lock_utils.populate_state_from_data(device) -- if this was a migrated device, try to migrate the lock codes
      if not device:get_field(lock_utils.MIGRATION_COMPLETE) then -- this means we didn't find any pre-migration lock codes
        -- so we'll load them manually
        driver:inject_capability_command(device, {
          capability = capabilities.lockCodes.ID,
          command = capabilities.lockCodes.commands.reloadAllCodes.NAME,
          args = {}
        })
      end
    end
    device:emit_event(LockCodes.maxCodes(value.value, { visibility = { displayed = false } }))
  end
end

local handle_max_code_length = function(driver, device, value)
  device:emit_event(LockCodes.maxCodeLength(value.value, { visibility = { displayed = false } }))
end

local handle_min_code_length = function(driver, device, value)
  device:emit_event(LockCodes.minCodeLength(value.value, { visibility = { displayed = false } }))
end

local update_codes = function(driver, device, command)
  local delay = 0
  -- args.codes is json
  for name, code in pairs(command.args.codes) do
    -- these seem to come in the format "code[slot#]: code"
    local code_slot = tonumber(string.gsub(name, "code", ""), 10)
    if (code_slot ~= nil) then
      if (code ~= nil and (code ~= "0" and code ~= "")) then
        device.thread:call_with_delay(delay, function ()
          device:send(LockCluster.server.commands.SetPINCode(device,
                code_slot,
                UserStatusEnum.OCCUPIED_ENABLED,
                UserTypeEnum.UNRESTRICTED,
                code))
        end)
        delay = delay + 2
      else
        device.thread:call_with_delay(delay, function ()
          device:send(LockCluster.server.commands.ClearPINCode(device, code_slot))
        end)
        delay = delay + 2
      end
      device.thread:call_with_delay(delay, function(d)
        device:send(LockCluster.server.commands.GetPINCode(device, code_slot))
      end)
      delay = delay + 2
    end
  end
end

local delete_code = function(driver, device, command)
  device:send(LockCluster.attributes.SendPINOverTheAir:write(device, true))
  device:send(LockCluster.server.commands.ClearPINCode(device, command.args.codeSlot))
  device.thread:call_with_delay(2, function(d)
    device:send(LockCluster.server.commands.GetPINCode(device, command.args.codeSlot))
  end)
end

local request_code = function(driver, device, command)
  device:send(LockCluster.server.commands.GetPINCode(device, command.args.codeSlot))
end

local set_code = function(driver, device, command)
  if (command.args.codePIN == "") then
    driver:inject_capability_command(device, {
      capability = capabilities.lockCodes.ID,
      command = capabilities.lockCodes.commands.nameSlot.NAME,
      args = {command.args.codeSlot, command.args.codeName}
    })
  else
    device:send(LockCluster.server.commands.SetPINCode(device,
            command.args.codeSlot,
            UserStatusEnum.OCCUPIED_ENABLED,
            UserTypeEnum.UNRESTRICTED,
            command.args.codePIN)
    )
    if (command.args.codeName ~= nil) then
      -- wait for confirmation from the lock to commit this to memory
      -- Groovy driver has a lot more info passed here as a description string, may need to be investigated
      local codeState = device:get_field(lock_utils.CODE_STATE) or {}
      codeState["setName"..command.args.codeSlot] = command.args.codeName
      device:set_field(lock_utils.CODE_STATE, codeState, { persist = true })
    end

    device.thread:call_with_delay(4, function(d)
      device:send(LockCluster.server.commands.GetPINCode(device, command.args.codeSlot))
    end)
  end
end

local name_slot = function(driver, device, command)
  local code_slot = tostring(command.args.codeSlot)
  local lock_codes = lock_utils.get_lock_codes(device)
  -- 삼성 SDS: PIN 등록 불가이므로 슬롯이 없어도 이름 등록 허용
  -- 지문 슬롯 번호와 사용자 이름을 매핑하는 용도로 사용
  local is_new = (lock_codes[code_slot] == nil)
  lock_codes[code_slot] = command.args.codeName
  if is_new then
    device:emit_event(LockCodes.codeChanged(code_slot .. " set", { state_change = true }))
  else
    device:emit_event(LockCodes.codeChanged(code_slot .. " renamed", { state_change = true }))
  end
  lock_utils.lock_codes_event(device, lock_codes)
end

local function device_added(driver, device)
  lock_utils.populate_state_from_data(device)

  driver:inject_capability_command(device, {
    capability = capabilities.refresh.ID,
    command = capabilities.refresh.commands.refresh.NAME,
    args = {}
  })
end

local function init(driver, device)
  lock_utils.populate_state_from_data(device)
  device:set_field(lock_utils.CODE_STATE, nil, { persist = true })
  -- 보안모드 상태 복원
  local saved = device:get_field(SECURITY_MODE_FIELD) or "disarmed"
  emit_security_mode(device, saved)
end

-- The following two functions are from the lock defaults. They are in the base driver temporarily
-- until the fix is widely released in the lua libs
local lock_state_handler = function(driver, device, value, zb_rx)
  local attr = capabilities.lock.lock
  local LOCK_STATE = {
    [value.NOT_FULLY_LOCKED]     = attr.unknown(),
    [value.LOCKED]               = attr.locked(),
    [value.UNLOCKED]             = attr.unlocked(),
    [value.UNDEFINED]            = attr.unknown(),
  }

  -- this is where we decide whether or not we need to delay our lock event because we've
  -- observed it coming before the event (or we're starting to compute the timer)
  local delay = device:get_field(DELAY_LOCK_EVENT) or 100
  if (delay < MAX_DELAY) then
    device.thread:call_with_delay(delay+.5, function ()
      device:emit_event_for_endpoint(zb_rx.address_header.src_endpoint.value, LOCK_STATE[value.value] or attr.unknown())
    end)
  else
    device:set_field(DELAY_LOCK_EVENT, socket.gettime())
    device:emit_event_for_endpoint(zb_rx.address_header.src_endpoint.value, LOCK_STATE[value.value] or attr.unknown())
  end
end

local lock_operation_event_handler = function(driver, device, zb_rx)
  local OperationEventCode = require "st.zigbee.generated.zcl_clusters.DoorLock.types.OperationEventCode"

  -- source → lock data.method 문자열
  local METHOD = {
    [0] = "keypad",
    [1] = "command",   -- 앱/RF 원격
    [2] = "manual",    -- 내부/외부 손잡이
    [3] = "rfid",
    [4] = "fingerprint",
    [5] = "bluetooth"
  }

  -- OperatingEventNotification 파싱
  -- st.zigbee 라이브러리 파싱 실패 시 raw bytes fallback
  local event_code, source, user_id
  if zb_rx.body.zcl_body.operation_event_code ~= nil then
    event_code = zb_rx.body.zcl_body.operation_event_code.value
    source     = zb_rx.body.zcl_body.operation_event_source.value
    user_id    = zb_rx.body.zcl_body.user_id.value
  else
    local raw = zb_rx.body.zcl_body.body_bytes or ""
    if #raw < 4 then return end
    source     = raw:byte(1)
    event_code = raw:byte(2)
    user_id    = raw:byte(3) + (raw:byte(4) * 256)
  end

  -- Samsung SDS 실측 코드값
  -- LOCK:   1=Lock, 5=KeyLock, 6=KeyLock2, 9=ManualLock, 10=AutoLock(삼성실측), 12=ScheduleLock
  -- UNLOCK: 2=Unlock, 7=KeyUnlock, 11=ScheduleUnlock, 13=ManualUnlock(ZCL), 14=ManualUnlock(삼성실측), 16=RFUnlock(삼성확장)
  local LOCK_CODES   = { 1, 5, 6, 9, 10, 12 }
  local UNLOCK_CODES = { 2, 7, 11, 13, 14, 16 }

  local is_locked = false
  local is_unlocked = false
  for _, c in ipairs(LOCK_CODES)   do if event_code == c then is_locked   = true end end
  for _, c in ipairs(UNLOCK_CODES) do if event_code == c then is_unlocked = true end end

  if not (is_locked or is_unlocked) then return end

  -- method 결정
  local is_auto = (event_code == OperationEventCode.AUTO_LOCK or event_code == 10 or
                   event_code == OperationEventCode.SCHEDULE_LOCK or
                   event_code == OperationEventCode.SCHEDULE_UNLOCK)

  -- source=1(RF/앱), code=16: 앱 원격 해제
  local is_rf_unlock = (source == 1 and event_code == 16)
  -- source=2(MANUAL), code=14: 내부 버튼/손잡이 해제
  local is_manual_unlock = (source == 2 and (event_code == 13 or event_code == 14))
  -- 내부에서 열림 처리 (MANUAL_UNLOCK, user_id=0xFFFF)
  -- source=2(MANUAL), code=10: 자동잠금
  -- source=4(지문), code=2: 지문 해제
  -- source=0(키패드), code=2: 비번 해제

  local method
  if is_auto then
    method = "auto"
  elseif is_rf_unlock then
    method = "command"   -- 앱 원격
  else
    method = METHOD[source] or "manual"
  end

  -- 잠금 이벤트 생성
  local event
  if is_locked then
    event = capabilities.lock.lock.locked()
    event["data"] = { method = method }
  else
    event = capabilities.lock.lock.unlocked()
    -- 기본 data 설정
    if is_manual_unlock then
      -- 내부에서 열림
      event["data"] = { method = method, codeName = "내부에서 열림" }
    elseif is_rf_unlock then
      -- 앱/원격으로 열림
      event["data"] = { method = method, codeName = "앱으로 열림" }
    elseif source == 0 then
      -- 비밀번호로 열림 (KEYPAD, user_id=0)
      event["data"] = { method = method, codeName = "키패드" }
    else
      event["data"] = { method = method }
    end
  end

  -- 사용자 특정 가능한 경우 (user_id 유효, 0xFFFF 아님, 0 아님)
  local has_valid_user = is_unlocked
    and user_id ~= nil
    and user_id ~= 0xFFFF
    and user_id ~= 0
    and device:supports_capability_by_id(capabilities.lockCodes.ID)

  if has_valid_user then
    local code_id   = tostring(user_id)
    local lc        = lock_utils.get_lock_codes(device)
    -- Preferences에서 슬롯→이름 매핑 조회
    local user_map = user_switch.get_user_map(device)
    local user_info = user_map[user_id]
    local code_name = (user_info and user_info.name) or
                      lc[user_id] or lc[code_id] or ("슬롯 " .. user_id)
    local code_id_str = code_id
    -- Child Switch ON
    user_switch.on_unlock(driver, device, user_id)

    event.data = { method = method, codeId = code_id_str, codeName = code_name }

    -- codeChanged: 기록에 안 보이게 숨김 처리
    local ce = LockCodes.codeChanged(code_id .. " unlocked", { state_change = true, visibility = { displayed = false } })
    ce.data  = { codeName = code_name }
    device:emit_event(ce)
  end

  -- unlock 시 보안모드 조건부 해제 (직방 방식)
  -- armedAway + 지문/비번/앱 → disarmed (정상 귀가, 경보 없음)
  -- armedAway + 내부 버튼   → armedAway 유지 (경보 지속)
  -- armedStay + 모든 수단   → disarmed
  -- ★ Race Condition 방지:
  --   emit_security_mode 호출 전에 현재 보안모드를 먼저 읽어야 함.
  --   (호출 후에는 set_field로 이미 "disarmed"로 바뀌어 조건 판별 불가)
  local current_mode_before = device:get_field(SECURITY_MODE_FIELD)
  local race_condition_possible = is_unlocked
    and (current_mode_before == "armedStay" or current_mode_before == "armedAway")

  if is_unlocked then
    local current = device:get_field(SECURITY_MODE_FIELD)
    if current ~= nil and current ~= "disarmed" then
      local should_disarm = false

      if has_valid_user then
        should_disarm = true
        log.info("[SecurityMode] 인증 열림(슬롯=" .. tostring(user_id) .. ") → disarmed")
      elseif is_rf_unlock then
        should_disarm = true
        log.info("[SecurityMode] 앱 원격 열림 → disarmed")
      elseif is_manual_unlock then
        if current == "armedStay" then
          should_disarm = true
          log.info("[SecurityMode] 재택안심 + 내부 열림 → disarmed")
        else
          log.warn("[SecurityMode] 외출방범 + 내부 열림 → 경보 유지!")
        end
      else
        should_disarm = true
        log.info("[SecurityMode] 분류 불가 열림 → disarmed (안전 처리)")
      end

      if should_disarm then
        emit_security_mode(device, "disarmed")
      end
    end
  end

  -- 잠길 때 마지막 사용자 Switch OFF
  if is_locked then
    user_switch.on_lock(driver, device)
  end

  -- 지연 타이머 처리 (공식 드라이버 로직 유지)
  if device:get_latest_state(
      device:get_component_id_for_endpoint(zb_rx.address_header.src_endpoint.value),
      capabilities.lock.ID,
      capabilities.lock.lock.ID) == event.value.value then
    local preceding_event_time = device:get_field(DELAY_LOCK_EVENT) or 0
    local time_diff = socket.gettime() - preceding_event_time
    if time_diff < MAX_DELAY then
      device:set_field(DELAY_LOCK_EVENT, time_diff)
    end
  end

  if race_condition_possible then
    log.info("[SecurityMode] 내부 수동 열림 + 보안모드 활성 → lock.unlocked 1초 지연 발송 (Race Condition 방지)")
    local ep = zb_rx.address_header.src_endpoint.value
    device.thread:call_with_delay(1, function()
      log.info("[SecurityMode] lock.unlocked 지연 발송")
      device:emit_event_for_endpoint(ep, event)
    end)
  else
    device:emit_event_for_endpoint(zb_rx.address_header.src_endpoint.value, event)
  end
end

local function lock(driver, device, command)
  device:send_to_component(command.component, LockCluster.server.commands.LockDoor(device))
end

local function unlock(driver, device, command)
  device:send_to_component(command.component, LockCluster.server.commands.UnlockDoor(device))
end

-- ProgrammingEventNotification 핸들러 (외출방범/재택안심 → securitySystem emit)
local programming_event_handler_sds = function(driver, device, zb_rx)
  local body = zb_rx.body.zcl_body
  if not body then return end

  local event_code = body.program_event_code and body.program_event_code.value
  if event_code == nil then
    local bytes = zb_rx.body_bytes
    if bytes and #bytes >= 2 then event_code = bytes:byte(2) end
  end

  log.info("[SecurityMode] ProgramEventCode: " .. tostring(event_code))

  if event_code == 10 then
    emit_security_mode(device, "armedAway")   -- 외출방범
  elseif event_code == 11 then
    emit_security_mode(device, "armedStay")   -- 재택안심
  elseif event_code == 12 then
    emit_security_mode(device, "disarmed")    -- 해제
  end
end

local zigbee_lock_driver = {
  supported_capabilities = {
    Lock,
    LockCodes,
    Battery,
  },
  zigbee_handlers = {
    cluster = {
      [Alarm.ID] = {
        [Alarm.client.commands.Alarm.ID] = alarm_handler
      },
      [LockCluster.ID] = {
        [LockCluster.client.commands.GetPINCodeResponse.ID] = get_pin_response_handler,
        [LockCluster.client.commands.ProgrammingEventNotification.ID] = programming_event_handler_sds,
        [LockCluster.client.commands.OperatingEventNotification.ID] = lock_operation_event_handler
      }
    },
    attr = {
      [LockCluster.ID] = {
        [LockCluster.attributes.LockState.ID] = lock_state_handler,
        [LockCluster.attributes.MaxPINCodeLength.ID] = handle_max_code_length,
        [LockCluster.attributes.MinPINCodeLength.ID] = handle_min_code_length,
        [LockCluster.attributes.NumberOfPINUsersSupported.ID] = handle_max_codes
      }
    }
  },
  capability_handlers = {
    [LockCodes.ID] = {
      [LockCodes.commands.updateCodes.NAME] = update_codes,
      [LockCodes.commands.deleteCode.NAME] = delete_code,
      [LockCodes.commands.reloadAllCodes.NAME] = reload_all_codes,
      [LockCodes.commands.requestCode.NAME] = request_code,
      [LockCodes.commands.setCode.NAME] = set_code,
      [LockCodes.commands.nameSlot.NAME] = name_slot,
    },
    [Lock.ID] = {
      [Lock.commands.lock.NAME] = lock,
      [Lock.commands.unlock.NAME] = unlock,
    },
    [SecuritySystem.ID] = {
      [SecuritySystem.commands.armAway.NAME]  = security_cmd_handler,
      [SecuritySystem.commands.armStay.NAME]  = security_cmd_handler,
      [SecuritySystem.commands.disarm.NAME]   = security_cmd_handler,
    },

    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh
    },
  },
  sub_drivers = require("sub_drivers"),
  lifecycle_handlers = {
    doConfigure = do_configure,
    added = device_added,
    init = init,
    infoChanged = function(driver, device, event, args)
      log.info("[UserSwitch] infoChanged 수신: " .. tostring(device.label))
      user_switch.sync_children(driver, device)
    end,
  },
  health_check = false,
}

defaults.register_for_default_handlers(zigbee_lock_driver, zigbee_lock_driver.supported_capabilities)
local lock = ZigbeeDriver("zigbee-lock", zigbee_lock_driver)
lock:run()
