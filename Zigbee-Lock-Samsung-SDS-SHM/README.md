# Zigbee Lock Samsung SDS (SHM)

SmartThings Edge Driver for Samsung SDS Zigbee Door Locks with Smart Home Monitor (SHM) integration.

## 지원 기기

- Samsung SDS SHP-DP950 (DADT302 Zigbee 모듈 장착)
- 기타 Samsung SDS Zigbee 도어록

## 주요 기능

### 기본 잠금/해제
- 지문, 비밀번호, 앱(원격), 내부 버튼 등 모든 열림 수단 지원
- 잠금/해제 이벤트 기록 (수단 및 사용자 이름 포함)
- 자동잠금 지원

### 사용자별 재실감지 (Child Device)
- 슬롯별 가족 구성원을 Preferences에 등록하면 차일드 기기(presenceSensor) 자동 생성
- 지문/비번으로 열릴 때 해당 사용자 `present` → 잠길 때 `not present`
- SmartThings 자동화 루틴에서 재실 조건으로 활용 가능

### 홈 모니터링(SHM) 연동 - 직방 방식
드라이버가 열림 수단을 판단하여 SHM 보안 모드를 제어합니다.

| 보안 모드 | 열림 수단 | 결과 |
|---------|----------|------|
| 안심(외출) | 지문 / 비번 / 앱 | 보안 모드 해제 (경보 없음) |
| 안심(외출) | 내부 버튼 | 경보 유지 (침입 감지) |
| 안심(실내) | 모든 수단 | 보안 모드 해제 (경보 없음) |

도어록 본체의 외출방범/재택안심 버튼으로 SHM 모드가 자동 설정됩니다.

## 설치 방법

1. [ST-Edge-Driver 채널](https://bestow-regional.api.smartthings.com/invite/Q1jP7BqnNNyk) 구독
2. SmartThings 앱 → 허브 → 드라이버 → 드라이버 추가
3. `Zigbee Lock Samsung SDS (SHM)` 선택 후 설치
4. 도어록을 SmartThings에 추가 (Zigbee 페어링)

## Preferences 설정

도어록 기기 설정 → 슬롯 등록으로 가족 구성원을 등록합니다.

| 설정 항목 | 설명 |
|---------|------|
| 사용자 1~8 슬롯 번호 | 앱 기록에서 확인한 슬롯 번호 (예: `31 unlocked` → `31` 입력) |
| 사용자 1~8 이름 | 차일드 기기에 표시될 이름 (예: `홍길동`) |

슬롯 번호 확인 방법: SmartThings 앱 → 도어록 → 기록 탭 → `31 unlocked` 형식으로 표시됨

## 홈 모니터링 설정 (중요)

SHM 연동이 올바르게 동작하려면 아래 설정이 필요합니다.

### ✅ 올바른 설정
- **보안 모드 연동 기기**: Samsung Door Lock 추가
- **안심(외출) → 잠금 선택**: Samsung Door Lock 추가
- **안심(실내) → 잠금 선택**: Samsung Door Lock 추가

### ⚠️ 반드시 선택 안 함
- **재실 감지 센서**: 차일드 기기(홍길동, 김철수 등) 선택하면 오경보 발생
- **동작/접촉/소리 센서**: 도어록 관련 센서 선택 금지

> **이유**: 차일드 presenceSensor는 귀가 감지 목적으로 지문 열림 시 `present`가 됩니다.
> 이를 재실 감지에 등록하면 귀가할 때마다 경보가 발생합니다.

## 알려진 한계

- **NFC**: Zigbee 프로토콜로 NFC 이벤트를 수신할 수 없어 지원 불가
- **비번 사용자 구분**: 비밀번호 열림은 슬롯 정보가 없어 사용자 구분 불가
- **보안 모드 원격 설정**: Zigbee로 도어록 본체의 보안 모드를 원격 변경 불가 (읽기만 가능)

## 변경 이력

### v3 (2026-04-13)
- SHM(홈 모니터링) 연동 추가 (직방 방식)
  - 안심(외출) + 지문/앱 귀가 → 경보 없음
  - 안심(외출) + 내부 버튼 → 경보 유지
  - 안심(실내) + 모든 수단 → 경보 없음
- 재실감지 차일드 동작 변경: 5초 타이머 → 잠길 때 `not present`

### v2
- 사용자별 재실감지 차일드 기기 추가
- 지문 슬롯 → 이름 매핑 (Preferences)
- 잠금 기록 한글화

## 라이선스

Apache License 2.0
