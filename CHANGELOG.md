# Changelog

이 프로젝트의 주요 변경 사항을 기록한다. 버전은 Semantic Versioning 형식으로 관리한다.

## 0.2.0 - 2026-08-14

### Added

- PowerShell 5.1 호환 결정론적 정적 스캐너
- 단일 JSON 출력과 선택적 Pretty 출력
- Unity 루트, 버전, Git, 패키지, asmdef, 테스트 어셈블리 근거, Build Settings Scene, AGENTS.md, 프로젝트 Skill, 추적된 생성 폴더 검사
- 경로 정규화, 프로젝트 루트 경계 검사, reparse point 미추적
- fixture 5종과 외부 프레임워크 없는 PowerShell 테스트 실행기
- Windows GitHub Actions 정적 테스트
- VERSION 파일과 확장된 사용 문서
- JSON Schema Draft 2020-12 기반 `schemaVersion: 1.0.0` 기계 판독 계약
- Schema의 필수 필드, 타입, enum, const 및 추가 필드 금지를 검사하는 외부 모듈 없는 회귀 테스트
- 서로 다른 실제 Unity 프로젝트 세 개의 읽기 전용 승인 기록

### Changed

- Skill이 사용 가능할 때 bundled scanner를 우선 실행하도록 변경
- scanner JSON을 감사 사실과 종료 상태의 원본으로 사용
- 결정론적 scanner가 실행 불가능할 때만 v0.1 수동 감사를 fallback으로 유지

### Security

- Unity 프로젝트 안에 파일, 로그, 보고서 또는 캐시를 생성하지 않음
- Unity Editor, Unity Hub, batchmode, 테스트, 빌드 및 플레이어를 실행하지 않음
- 프로젝트 내부의 script, executable 또는 Git hook을 실행하지 않음
- 외부 Git config include, object alternates, common directory 및 reparse point가 있는 Git metadata에서 Git 명령 실행을 거부
- worktree junction 또는 symbolic link를 발견하면 Git status를 실행하지 않음
- inherited GIT environment override와 project-local Git executable을 거부

## 0.1.0 - 2026-08-13

### Added

- 명시적 호출 전용 Unity Project Doctor instruction-only Skill 기준선
- 읽기 전용 static audit 절차
- 네 종료 상태: STATIC_AUDIT_COMPLETE, STATIC_AUDIT_COMPLETE_WITH_WARNINGS, AUDIT_BLOCKED, NOT_A_UNITY_PROJECT
- compilation, tests, build 및 runtime에 대한 NOT_VERIFIED 계약
- 사용자 홈 .agents/skills에 원본 저장소를 연결하는 비파괴 symbolic-link 설치기
- allow_implicit_invocation=false 정책
