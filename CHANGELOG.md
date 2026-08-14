# Changelog

이 모노레포와 각 Unity Skill의 주요 변경 사항을 기록한다. Skill 버전은 각 Skill 디렉터리의 VERSION 및 script metadata로 확인한다.

## Unreleased

### Unity Baseline Verification 0.1.1 hardening

#### Added

- Full no-module JSON Schema validation with exact JSON-path errors for Doctor schema 1.0.0 and 1.1.0 contracts
- Doctor scanner 0.2.1 copy-set fingerprint evidence and the separate `unity-project-audit-1.1.0.schema.json` contract
- Source/current/isolated SHA-256 fingerprint binding with two-pass stability checks
- Strict relative-only `file:` package normalization across source and isolated roots
- Authenticode publisher evidence for Unity.exe: FileVersion, ProductVersion, CompanyName, signer subject, certificate thumbprint, and SHA-256
- suspended process creation before Windows Job Object assignment, process-tree timeout termination, and bounded zero-active-process evidence
- Exact source-project Unity Editor preflight and external, non-reparse artifact/path checks
- Separate real-Unity 0.1.1 acceptance procedure

#### Changed

- `unity-baseline-verification` component version is now 0.1.1 and its result schemaVersion is 1.1.0; final status names are unchanged
- `unity-project-doctor` component/scanner version is now 0.2.1 and emits schemaVersion 1.1.0
- Saved Doctor schema 1.0.0/scanner 0.2.0 JSON remains valid static-audit evidence but is rejected by Baseline because it has no project fingerprint
- Fake Unity is used only by internal process/log tests; the production entrypoint blocks the unsigned fake with no bypass option
- Windows CI verifies `git diff` and `git status` after each test suite

#### Security

- Absolute paths are rejected even when they point inside the project; UNC, device, URI-authority, encoded escape, excluded-tree, and reparse package references also block before Unity
- Timeout handling terminates the assigned Unity process tree and blocks when zero active processes cannot be proven
- Unity trust is based on a currently valid Unity Technologies Authenticode signer, without a permanent single-thumbprint pin
- No automatic repair, external installation, test, Player Build, PlayMode, runtime, Unity Hub, or original-project Unity launch was added

### Added

- 명시적 호출 전용 `unity-baseline-verification` v0.1.0 Skill metadata
- `unity-project-doctor` v0.2 JSON의 엄격한 preflight validation
- Unity 6000.0.69f1 executable, project 및 Editor.log 버전 검사
- reparse point와 외부 file package dependency를 거부하는 안전한 격리 프로젝트 복사
- test나 build 없이 수행하는 batchmode import 및 script-compilation 검증
- process exit code와 Editor.log evidence classification
- 원본 프로젝트의 실행 전후 전체 파일 목록과 SHA-256 integrity 비교
- idempotent 공용 Skill installer, fake-Unity regression tests 및 별도 Windows CI
- Doctor와 Baseline의 독립적인 Skill VERSION 파일

### Changed

- 저장소 이름과 로컬 기준 경로를 `unity_agent_pipeline`으로 정리
- 공용 installer가 모노레포의 모든 `skills/codex` 하위 Skill을 설치하도록 문서화
- Baseline 문서와 테스트를 component별 경로로 통합

## unity-project-doctor 0.2.0 - 2026-08-14

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

## unity-project-doctor 0.1.0 - 2026-08-13

### Added

- 명시적 호출 전용 Unity Project Doctor instruction-only Skill 기준선
- 읽기 전용 static audit 절차
- 네 종료 상태: STATIC_AUDIT_COMPLETE, STATIC_AUDIT_COMPLETE_WITH_WARNINGS, AUDIT_BLOCKED, NOT_A_UNITY_PROJECT
- compilation, tests, build 및 runtime에 대한 NOT_VERIFIED 계약
- 사용자 홈 .agents/skills에 원본 저장소를 연결하는 비파괴 symbolic-link 설치기
- allow_implicit_invocation=false 정책
