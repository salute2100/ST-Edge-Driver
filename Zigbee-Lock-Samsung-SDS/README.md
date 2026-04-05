# Zigbee Lock Samsung SDS

삼성 SDS / 직방 Zigbee 도어록용 SmartThings Edge 드라이버입니다.

## 지원 기기

- 삼성 SDS SHP-DP950 (DADT302 Zigbee 모듈)
- 직방 Zigbee 도어록 (동일 모듈 사용 제품)

## 주요 기능

- 지문 / 비밀번호 / 앱 원격 / 내부에서 열림 구분 기록
- 사용자별 재실 센서 자동 생성 (지문 슬롯 번호 + 이름 등록)
- 자동잠금 감지
- 외출방범 / 재택안심 모드 로그 기록

## 설치 방법

1. [채널 등록](https://bestow-regional.api.smartthings.com/invite/r3MyN87OZJ2p) 후 허브에 Enroll
2. SmartThings 앱 → 기기 → 도어록 → 드라이버 선택 → `Zigbee Lock Samsung SDS` 설치

## 사용자 재실 센서 설정

설치 후 기기 설정(Preferences)에서 슬롯 번호와 이름을 입력하면 사용자별 재실 센서가 자동 생성됩니다.

슬롯 번호 확인 방법: 드라이버 설치 후 지문으로 열면 앱 기록에 `잠금 해제됨, 슬롯 N, 지문` 으로 표시됩니다.

## 한계

- NFC: 직방 클라우드 인증 필요, 미등록 키 불가
- 비밀번호 사용자 구분 불가 (user_id=0 고정)
- 외출방범 / 재택안심 모드 원격 해제 불가
