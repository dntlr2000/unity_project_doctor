# Unity Agent Pipeline

[![Doctor static fixture tests](https://github.com/dntlr2000/unity_agent_pipeline/actions/workflows/static-tests.yml/badge.svg)](https://github.com/dntlr2000/unity_agent_pipeline/actions/workflows/static-tests.yml)
[![Baseline fake-Unity tests](https://github.com/dntlr2000/unity_agent_pipeline/actions/workflows/baseline-static-tests.yml/badge.svg)](https://github.com/dntlr2000/unity_agent_pipeline/actions/workflows/baseline-static-tests.yml)
[![EditMode fake-Unity tests](https://github.com/dntlr2000/unity_agent_pipeline/actions/workflows/editmode-static-tests.yml/badge.svg)](https://github.com/dntlr2000/unity_agent_pipeline/actions/workflows/editmode-static-tests.yml)
[![Test Scaffold static tests](https://github.com/dntlr2000/unity_agent_pipeline/actions/workflows/test-scaffold-static-tests.yml/badge.svg)](https://github.com/dntlr2000/unity_agent_pipeline/actions/workflows/test-scaffold-static-tests.yml)

Unity Agent Pipeline은 여러 Unity 프로젝트에서 재사용하는 명시적 호출 전용 Codex Skill 모음이다. Skill 원본, 공용 설치기, 계약, 테스트 및 CI는 이 모노레포에 유지한다.

| Skill | 버전 | 역할 |
| --- | --- | --- |
| `$unity-project-doctor` | 0.2.1 | Unity를 실행하지 않는 읽기 전용 정적 감사와 Baseline copy-set fingerprint 생성 |
| `$unity-baseline-verification` | 0.2.0 | bundled Doctor와 exact Unity.exe를 자동 준비한 뒤 승인된 저수준 verifier로 격리 컴파일 근거와 원본 무결성을 판정 |
| `$unity-editmode-verification` | 0.1.0 (Unreleased) | fresh Baseline 격리본과 confirmed test assembly만 사용해 EditMode NUnit 결과와 원본 무결성을 판정 |
| `$unity-test-scaffold` | 0.1.0 (Unreleased) | Runtime/EditMode asmdef 초기 구성을 먼저 PLAN하고 정확한 hash 확인 뒤에만 새 파일로 적용 |

네 Skill 모두 `allow_implicit_invocation=false`이며 이름을 명시하지 않은 요청에서는 실행되지 않는다. 동적 안전 계약은 [Baseline](docs/skills/unity-baseline-verification.md), [EditMode](docs/skills/unity-editmode-verification.md)에, 초기 구성의 mutation 계약은 [Test Scaffold](docs/skills/unity-test-scaffold.md)에 분리되어 있다.

## Baseline 0.2.0 one-command orchestration

- 사용자는 Unity 프로젝트 루트에서 `$unity-baseline-verification으로 현재 프로젝트를 검증해.`만 명시하면 된다.
- 새 orchestrator는 sibling Doctor scanner를 직접 실행하고 원문 JSON을 외부 artifact에 저장한다. 별도 `$unity-project-doctor` Skill을 암묵적으로 호출하지 않는다.
- Unity.exe는 명시적 override, `UNITY_EDITOR_PATH`, `UNITY_HUB_EDITOR_ROOT`, Program Files, Program Files (x86) 순으로 exact `6000.0.69f1`만 확인한다.
- Unity Hub 실행, registry/drive 검색, 다른 버전 대체, 설치 및 업데이트는 하지 않는다.
- 기존 `verify-unity-baseline.ps1` 0.1.3이 Unity를 시작할 수 있는 유일한 컴포넌트이며 결과 `schemaVersion: 1.1.0`과 네 final status를 그대로 유지한다.
- 실제 signed-Unity one-command 실행은 2026-08-17에 [APPROVED — SCRIPT COMPILATION ONLY](docs/validation/v0.2.0-baseline-orchestration-acceptance.md)로 승인됐다. Tests, Player Build, PlayMode 및 runtime은 승인 범위가 아니다.

## EditMode Verification 0.1.0 (Unreleased)

- 사용자는 Unity 프로젝트 루트에서 `$unity-editmode-verification으로 현재 프로젝트의 EditMode 테스트를 검증해.`라고 명시적으로 호출한다.
- production entrypoint는 sibling Baseline one-command를 매 실행마다 새로 호출하고, 좁은 handoff schema로 `BASELINE_VERIFIED`, Doctor 0.2.1/schema 1.1.0, 원본 project root 및 fingerprint를 다시 검증한다.
- Baseline이 승인한 같은 격리 프로젝트와 exact Unity executable만 재사용하며, Doctor의 `confirmedTestAssemblies`만 선택한다. Doctor confirmation은 asmdef 선언 증거이므로, 각 선택 assembly의 non-empty DLL이 Baseline `Library/ScriptAssemblies`에 실제 존재하는지 확인한 뒤에만 `-assemblyNames`에 전달한다. candidate-only evidence는 실행 대상이 아니다.
- 원본·Doctor·Baseline의 pre-Unity fingerprint는 exact match를 요구한다. Baseline Unity가 격리본 루트에 재생성한 `.sln`, `.csproj`, `.csproj.user`만 구조화된 delta로 허용하며, 그 밖의 파일·디렉터리 변화는 계속 차단한다.
- NUnit XML, Editor.log, child exit, signed Unity identity, Job Object process-tree 종료, 원본 copy-set 및 Git metadata를 함께 판정한다. 거부된 Baseline의 compiler/failure/process-cleanup 진단도 중첩 결과에 보존한다.
- 하나 이상의 passed test와 0 failed/error/inconclusive일 때만 `EDITMODE_VERIFIED`다. skipped test는 warning으로 보존한다. confirmed assembly가 없거나 선택 DLL이 생성되지 않았으면 Unity를 두 번째로 실행하지 않으며, 유효한 XML의 0 tests는 `NO_DISCOVERED_TEST_CASES`로 차단한다.
- commit `56001b16e67a8f9543d2bf8eca90706d1faa3511`은 네 Windows workflow 통과 후 실제 signed Unity `6000.0.69f1`에서 selected DLL과 의미 있는 EditMode 테스트 4개를 검증해 [APPROVED — SCRIPT COMPILATION + SELECTED EDITMODE TESTS ONLY](docs/validation/v0.1.0-editmode-real-unity-acceptance.md)로 기록됐다. PlayMode, Player Build 및 runtime은 항상 `NOT_VERIFIED`다.

## Test Scaffold 0.1.0 (Unreleased)

- 사용자는 `$unity-test-scaffold로 현재 프로젝트의 EditMode 테스트 초기 구성을 계획해.`라고 명시적으로 호출한다.
- 기본 실행은 읽기 전용 PLAN이며 Runtime/Test root, assembly name, 새 directory, 전체 file content와 SHA-256을 JSON으로 출력한다.
- 실제 APPLY는 사용자가 검토한 exact `planSha256`을 다시 제공해야만 가능하다. 상태나 옵션이 바뀌면 hash가 달라져 쓰기 전에 차단된다.
- 기존 file은 덮어쓰지 않고 Runtime asmdef, Editor-only test asmdef, 필요한 새 directory와 `.meta`만 create-new 방식으로 생성한다. `.meta` bytes는 UTF-8 without BOM, LF-only, 정확히 하나의 terminal LF로 고정한다.
- 자동으로 통과하는 test method는 만들지 않으며 Unity, compilation, Test Runner, PlayMode, Player Build 및 runtime도 실행하지 않는다.
- Runtime 코드의 package/assembly reference를 추측해 자동 추가하지 않는다. APPLY 뒤 Baseline이 누락 reference를 보고하면 프로젝트별 검토와 별도 승인이 필요하다.

## 저수준 verifier 0.1.3과 원본 무결성 판정

- Doctor scanner 0.2.1은 별도 계약 파일인 `schemaVersion: 1.1.0`을 출력하고, Baseline이 복사하는 파일 집합의 안정된 SHA-256 fingerprint를 포함한다.
- 기존 `schemas/unity-project-audit.schema.json`의 1.0.0 계약은 수정하지 않았다. 저장된 scanner 0.2.0 결과는 계속 유효한 정적 감사 자료지만 fingerprint가 없어 저수준 verifier 0.1.3에서는 Unity 실행 전에 차단된다.
- Baseline은 선택된 Doctor schema 전체를 외부 모듈 없이 검사하며 중첩 enum/type/required/additionalProperties 오류의 정확한 JSON path를 반환한다.
- `file:` package는 상대 경로만 허용되며 절대·UNC·device·authority·encoded escape·excluded tree·reparse 경로는 원본과 격리 양쪽 검증 전에 차단된다.
- Unity.exe는 ProductVersion뿐 아니라 유효한 Unity Technologies Authenticode signer가 필요하다. 결과에는 회사명, signer subject, certificate thumbprint와 executable SHA-256이 남는다.
- Unity 프로세스는 suspended 상태로 생성해 kill-on-close Windows Job Object에 먼저 연결한 뒤 재개하며, timeout에는 부모와 자식을 종료하고 active process가 0임을 제한 시간 안에 증명해야 한다.
- 원본 콘텐츠는 Doctor fingerprint와 동일한 Baseline copy set으로 판정하고, `.git`은 별도 해시 증거로 감시한다.
- `.git/refs/codex/turn-diffs/checkpoints/` 아래의 새 경로만 ambient metadata로 허용한다. HEAD, index, config, hook, 일반 ref, object 또는 기존 Git 파일 변경·삭제는 계속 `ORIGINAL_PROJECT_CHANGED`다.
- CI의 unsigned fake Unity는 production entrypoint에서 반드시 차단된다. fake 실행은 내부 process/log 회귀 테스트에만 사용된다.

Doctor migration 세부사항은 [Unity Project Doctor 0.2.1 문서](docs/skills/unity-project-doctor.md), one-command 흐름과 Baseline 안전 계약은 [Unity Baseline Verification 0.2.0 문서](docs/skills/unity-baseline-verification.md), 초기 구성은 [Unity Test Scaffold 0.1.0 문서](docs/skills/unity-test-scaffold.md)를 참고한다.

## Unity Project Doctor v0.2.1

Unity Project Doctor는 현재 작업 디렉터리를 반복 가능한 JSON으로 검사한다. Unity Editor, Unity Hub, batchmode, compiler, test runner, player build 또는 runtime을 실행하지 않는다.

## 주요 기능

- 정확한 현재 작업 디렉터리가 Unity 프로젝트 루트인지 확인
- ProjectSettings/ProjectVersion.txt에서 Unity Editor 버전 수집
- 안전하게 포함된 Git worktree의 branch, detached HEAD, dirty state 및 changed path 수집
- Packages/manifest.json과 Packages/packages-lock.json의 존재 및 JSON parse 상태 확인
- direct dependency와 resolved dependency 비교
- Assets와 project-local Packages의 asmdef inventory
- 직접 근거가 있는 test assembly와 이름 또는 경로만 test처럼 보이는 candidate 분리
- EditorBuildSettings.asset의 enabled, disabled 및 missing Scene 확인
- AGENTS.md와 표준 위치의 project-local Skill inventory
- Git에 추적된 Unity generated 또는 policy-sensitive folder 확인
- compilation, tests, build 및 runtime을 항상 NOT_VERIFIED로 명시
- 모든 관찰의 evidence, warning, blocked check 및 최종 상태를 구조화

## 요구 환경

- Windows PowerShell 5.1 이상
- Codex의 전역 Skill 검색 경로인 사용자 홈의 .agents/skills
- Git 검사 대상이면 PATH에서 실행 가능한 Git

Unity 설치와 외부 PowerShell module은 필요하지 않다. 이 저장소의 설치 또는 테스트를 위해 package manager를 실행하지 않는다.

## 저장소 구조

~~~text
unity_agent_pipeline/
├── .github/workflows/
│   ├── static-tests.yml
│   ├── baseline-static-tests.yml
│   ├── editmode-static-tests.yml
│   └── test-scaffold-static-tests.yml
├── CHANGELOG.md
├── README.md
├── VERSION
├── docs/
│   ├── skills/unity-baseline-verification.md
│   ├── skills/unity-editmode-verification.md
│   ├── skills/unity-project-doctor.md
│   ├── skills/unity-test-scaffold.md
│   ├── releases/v0.3.0.md
│   ├── releases/v0.4.0.md
│   ├── validation/v0.1.1-unity-baseline-real-unity-acceptance.md
│   ├── validation/v0.1.2-original-integrity-acceptance.md
│   ├── validation/v0.1.2-real-unity-acceptance-result.md
│   ├── validation/v0.2.0-baseline-orchestration-acceptance.md
│   └── validation/v0.2.0-real-project-acceptance.md
├── schemas/
│   ├── unity-project-audit.schema.json
│   ├── unity-project-audit-1.1.0.schema.json
│   ├── unity-baseline-editmode-handoff-1.0.0.schema.json
│   ├── unity-editmode-verification-result-1.0.0.schema.json
│   └── unity-test-scaffold-result-1.0.0.schema.json
├── scripts/
│   └── install-codex-skills.ps1
├── skills/codex/
│   ├── unity-project-doctor/
│   │   ├── VERSION
│   │   ├── SKILL.md
│   │   ├── agents/openai.yaml
│   │   └── scripts/inspect-unity-project.ps1
│   ├── unity-baseline-verification/
│   │   ├── VERSION
│   │   ├── SKILL.md
│   │   ├── agents/openai.yaml
│   │   └── scripts/
│   │       ├── invoke-unity-baseline-verification.ps1
│   │       ├── verify-unity-baseline.ps1
│   │       ├── lib/unity-baseline-orchestration.ps1
│   │       ├── lib/unity-isolation-path-budget.ps1
│   │       └── lib/git-metadata-integrity.ps1
│   ├── unity-editmode-verification/
│   │   ├── VERSION
│   │   ├── SKILL.md
│   │   ├── agents/openai.yaml
│   │   └── scripts/invoke-unity-editmode-verification.ps1
│   └── unity-test-scaffold/
│       ├── VERSION
│       ├── SKILL.md
│       ├── agents/openai.yaml
│       └── scripts/
│           ├── invoke-unity-test-scaffold.ps1
│           └── lib/unity-test-scaffold-core.ps1
└── tests/
    ├── fixtures/...
    ├── run-tests.ps1
    ├── unity-baseline-verification/run-tests.ps1
    ├── unity-baseline-verification/orchestration/run-tests.ps1
    ├── unity-editmode-verification/run-tests.ps1
    └── unity-test-scaffold/run-tests.ps1
~~~

Skill 원본은 이 Git 저장소에 남는다. 설치기는 `skills/codex` 아래의 모든 Skill을 사용자 홈 `.agents/skills`에 이름별 symbolic link로 연결한다.

루트 `VERSION`은 저장소 Release 버전을 선언한다. 게시된 봉인의 권위 있는 근거는 같은 버전을 가리키는 annotated Git tag와 GitHub Release이며, 각 Skill의 실제 component 버전은 해당 Skill 디렉터리의 `VERSION`을 사용한다.

## 안전 계약

scanner는 다음 계약을 지킨다.

- ProjectRoot를 절대 경로로 정규화하고 그 경로만 candidate root로 사용한다.
- 부모, 자식 또는 형제 폴더에서 다른 Unity 프로젝트를 검색하지 않는다.
- candidate root 안에 파일, 임시 파일, 로그, 보고서 또는 cache를 만들지 않는다.
- Assets, Packages, ProjectSettings, UserSettings 및 .git을 수정하지 않는다.
- reparse point, junction 또는 symbolic link를 따라가지 않는다.
- candidate root 밖을 가리키는 Git metadata를 읽지 않는다.
- project에서 발견한 script, executable 또는 hook을 실행하지 않는다.
- PATH가 project 내부 Git executable을 선택하면 실행을 거부한다.
- Git은 고정된 read-only operation만 사용하고 optional lock, fsmonitor, maintenance, submodule recursion 및 외부 config source를 비활성화한다.
- child Git process에서 inherited GIT environment override를 제거한다.
- JSON parse 실패를 process crash로 승격하지 않고 warning 또는 blockedChecks에 기록한다.
- 실행하지 않은 동적 검증을 PASS 또는 성공으로 표시하지 않는다.

보수적 경계 정책 때문에 linked worktree, 외부 common Git directory, object alternates, Git config include 또는 Git metadata 내부 reparse point가 있는 프로젝트에서는 Git 검사가 NOT_AVAILABLE 또는 warning으로 보고될 수 있다.

Test Scaffold만 별도의 명시적 mutation 계약을 가진다. 기본 PLAN은 읽기 전용이며, exact plan hash를 사용자가 확인한 APPLY에서만 계획에 선언된 새 asmdef, 새 directory 및 `.meta`를 create-new 방식으로 추가한다. 기존 파일은 덮어쓰지 않고 Unity나 동적 검증도 실행하지 않는다.

## 설치

PowerShell에서 저장소 루트로 이동한 뒤 먼저 설치 계획을 확인한다.

~~~powershell
cd E:\Playground\Pipelines\unity_agent_pipeline
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-codex-skills.ps1 -WhatIf
~~~

계획이 맞으면 설치한다.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-codex-skills.ps1
~~~

Windows에서 symbolic link 생성에는 개발자 모드 또는 관리자 권한이 필요할 수 있다. ExecutionPolicy Bypass는 위 child process에만 적용되며 사용자 또는 시스템 정책을 바꾸지 않는다.

설치 결과를 확인한다.

~~~powershell
$doctorLink = Get-Item "$HOME\.agents\skills\unity-project-doctor" -Force
$baselineLink = Get-Item "$HOME\.agents\skills\unity-baseline-verification" -Force
$editModeLink = Get-Item "$HOME\.agents\skills\unity-editmode-verification" -Force
$scaffoldLink = Get-Item "$HOME\.agents\skills\unity-test-scaffold" -Force
$doctorLink, $baselineLink, $editModeLink, $scaffoldLink | Select-Object FullName, LinkType, Target
Test-Path "$HOME\.agents\skills\unity-project-doctor\scripts\inspect-unity-project.ps1"
Test-Path "$HOME\.agents\skills\unity-baseline-verification\scripts\invoke-unity-baseline-verification.ps1"
Test-Path "$HOME\.agents\skills\unity-baseline-verification\scripts\verify-unity-baseline.ps1"
Test-Path "$HOME\.agents\skills\unity-editmode-verification\scripts\invoke-unity-editmode-verification.ps1"
Test-Path "$HOME\.agents\skills\unity-test-scaffold\scripts\invoke-unity-test-scaffold.ps1"
~~~

설치기는 기존 경로를 삭제하거나 덮어쓰지 않는다.

- 같은 원본을 가리키는 symbolic link는 unchanged로 유지한다.
- 실제 directory, file, 다른 link 또는 dangling link가 충돌하면 아무 새 link도 만들기 전에 종료한다.
- Skill 원본을 복사하지 않는다.

## 업데이트

원본 저장소를 정상적인 Git 절차로 업데이트한다.

~~~powershell
cd E:\Playground\Pipelines\unity_agent_pipeline
git pull --ff-only
~~~

기존 symbolic link가 같은 저장소 원본을 가리키므로 새 Skill 파일은 즉시 반영된다. 설치 상태도 다시 검사하려면 설치기를 재실행한다.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-codex-skills.ps1
~~~

정상적인 반복 실행은 기존 link를 변경하지 않고 unchanged로 보고한다.

## Codex에서 호출

Assets, Packages 및 ProjectSettings가 직접 들어 있는 Unity 프로젝트 루트를 Codex task의 현재 작업 디렉터리로 열고 Skill 이름을 명시한다.

~~~text
$unity-project-doctor 현재 작업 디렉터리의 Unity 프로젝트를 읽기 전용으로 점검해.
~~~

격리 script compilation 기준 검증은 별도 Skill 이름을 명시한다.

~~~text
$unity-baseline-verification으로 현재 프로젝트를 검증해.
~~~

fresh Baseline과 동일 격리본에서 확정된 EditMode 테스트만 검증하려면 별도 이름을 명시한다.

~~~text
$unity-editmode-verification으로 현재 프로젝트의 확정된 EditMode 테스트를 검증해.
~~~

EditMode 테스트 어셈블리 초기 구성이 없는 프로젝트에서는 별도 mutation Skill을 먼저 명시적으로 호출한다.

~~~text
$unity-test-scaffold로 현재 프로젝트의 EditMode 테스트 초기 구성을 계획해.
~~~

첫 호출은 PLAN만 반환한다. Codex는 전체 계획과 `planSha256`을 보여주고 기다리며, 사용자가 exact hash를 명시적으로 승인한 다음 호출에서만 APPLY한다. 이 Skill은 테스트 메서드를 만들거나 Unity를 실행하지 않는다.

Baseline 0.2.0은 Doctor JSON, scanner 경로, verifier 경로, artifact root 또는 일반적인 Hub 설치 위치의 Unity.exe 경로를 먼저 요구하지 않는다. bundled scanner의 원문 JSON을 프로젝트 밖에 저장하고 exact `6000.0.69f1` 후보를 자동으로 결정한 뒤 기존 verifier를 호출한다. 자동 탐색이 실패한 경우에만 blocker와 `-UnityExecutable` override 방법을 보고한다.

allow_implicit_invocation은 false다. Skill 이름이 없는 일반 Unity 질문이나 일반 코드 검토 요청으로 어떤 Skill도 자동 실행되어서는 안 된다.

`$unity-project-doctor`는 bundled scanner가 실행 가능하면 이를 우선한다. scanner JSON이 사실과 상태의 원본이며 Codex는 warning을 제거하거나 finalStatus를 승격하지 않는다. scanner가 실행 불가능한 경우에만 v0.1 읽기 전용 manual audit를 fallback으로 사용하며, 그 사실을 반드시 warning 또는 blocker로 보고한다. Baseline orchestrator에는 이 manual fallback을 적용하지 않는다.

## scanner 직접 실행

ProjectRoot 기본값은 현재 작업 디렉터리다.

~~~powershell
$scanner = "E:\Playground\Pipelines\unity_agent_pipeline\skills\codex\unity-project-doctor\scripts\inspect-unity-project.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scanner
~~~

다른 candidate root를 명시할 수 있다.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scanner -ProjectRoot "E:\Unity\ExampleProject"
~~~

들여쓴 JSON이 필요하면 Pretty를 사용한다.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scanner -ProjectRoot "E:\Unity\ExampleProject" -Pretty
~~~

정상 stdout에는 JSON document 하나만 출력된다. 사람이 읽는 진행 로그는 섞이지 않는다. 예기치 않은 scanner 진단은 stderr로 출력되며, 예상 가능한 개별 파일 문제는 JSON의 warnings 또는 blockedChecks에 들어간다.

출력을 프로젝트 안의 파일로 redirect하지 않는다. 메모리에서 확인하려면 다음처럼 사용한다.

~~~powershell
$json = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scanner -ProjectRoot "E:\Unity\ExampleProject"
$audit = $json | ConvertFrom-Json
$audit.finalStatus
~~~

## JSON schema 개요

schemaVersion 1.0.0의 동결 계약은 [unity-project-audit.schema.json](schemas/unity-project-audit.schema.json)에 그대로 보존되어 있다. Scanner 0.2.1의 현재 계약은 별도 [unity-project-audit-1.1.0.schema.json](schemas/unity-project-audit-1.1.0.schema.json)이며 `projectFingerprint`를 필수로 추가한다. 두 파일 모두 JSON Schema Draft 2020-12를 사용한다.

최상위 필드는 다음과 같다.

| 필드 | 내용 |
| --- | --- |
| schemaVersion | JSON contract 버전 |
| scannerVersion | scanner 구현 버전 |
| projectRoot | 정규화된 absolute candidate root |
| projectDetection | Unity root marker와 감지 결과 |
| unityEditorVersion | ProjectVersion.txt 출처, parse 상태 및 버전 |
| git | Git 사용 가능성, worktree, branch, detached HEAD, HEAD commit, dirty state, changed paths |
| packages | manifest와 lockfile 상태, direct/resolved dependency 및 lock 누락 |
| assemblies | asmdef parse 결과, confirmed 및 candidate-only test assembly evidence |
| buildSettings | enabled, disabled 및 missing Scene |
| agentsFiles | AGENTS.md path와 directory scope |
| projectSkills | project-local SKILL.md path, scope, name 및 parse 상태 |
| trackedGeneratedFolderPaths | Git이 추적하는 generated folder 경로 |
| projectFingerprint | Baseline copy-set의 canonical path/length/file SHA-256 결속 정보 |
| warnings | 정적 warning code, check, path 및 message |
| blockedChecks | 완료할 수 없었던 check와 구체적 이유 |
| dynamicVerification | compilation, tests, build 및 runtime의 NOT_VERIFIED 상태 |
| finalStatus | 네 종료 상태 중 하나 |
| evidence | 순서가 고정된 관찰 및 판단 근거 |

compact 출력은 동일한 입력 filesystem과 Git metadata에서 byte-for-byte 결정성을 목표로 한다. Pretty는 같은 의미를 유지하면서 whitespace만 바꾼다.

### 호환성 규칙

- `schemaVersion`은 consumer가 의존하는 JSON 형상과 상태 의미의 호환성 버전이다.
- 필수 필드의 제거·이름 변경·타입 변경, enum 값의 제거 또는 기존 상태 의미 변경은 `schemaVersion`을 올려야 한다.
- `scannerVersion`은 scanner 구현 버전이다. JSON 계약을 유지하는 버그 수정은 `scannerVersion`만 올릴 수 있다.
- v1 계약의 object는 Schema에 선언되지 않은 추가 필드를 허용하지 않는다. 새 필드가 필요하면 consumer 호환성을 검토하고 계약 버전을 결정한다.
- consumer는 알 수 없는 `schemaVersion`을 임의 해석하거나 `finalStatus`, warning, blocked check를 더 성공적인 상태로 승격해서는 안 된다.
- `compilation`, `tests`, `build`, `runtime`은 v1 계약에서 항상 `NOT_VERIFIED`다.

## 종료 상태

- STATIC_AUDIT_COMPLETE: 모든 필수 정적 check가 완료됐고 warning 또는 blocker가 없다.
- STATIC_AUDIT_COMPLETE_WITH_WARNINGS: 정적 audit는 완료됐지만 warning 또는 NOT_AVAILABLE check가 있다.
- AUDIT_BLOCKED: permission, I/O, unsafe path 또는 tool failure가 의미 있는 필수 check를 막았다.
- NOT_A_UNITY_PROJECT: 정확한 candidate root에 필수 Unity marker가 없다.

Compilation, tests, build 및 runtime의 의도된 NOT_VERIFIED는 그 자체로 warning을 만들지 않는다.

## 자동 테스트

Doctor fixture 및 계약 테스트:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
~~~

Baseline fake-Unity 및 격리 안전성 테스트:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\unity-baseline-verification\run-tests.ps1
~~~

EditMode의 순수 판정, unsigned fake process, NUnit/XML, source-editor, 설치기 회귀는 별도로 실행한다.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\unity-editmode-verification\run-tests.ps1
~~~

Test Scaffold PLAN/APPLY, exact delta 및 rollback 회귀도 별도로 실행한다.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\unity-test-scaffold\run-tests.ps1
~~~

네 정적 테스트 묶음 모두 외부 테스트 framework나 Unity 설치 없이 Windows PowerShell 기본 기능만 사용한다.

- NOT_A_UNITY_PROJECT
- ProjectRoot 생략 시 current working directory 기본값
- clean minimal Unity project
- warning project
- malformed manifest
- missing Build Settings Scene
- compact JSON determinism
- Unicode project path round-trip
- Draft 2020-12 Schema parse와 고정된 `schemaVersion`
- 모든 주요 scanner 결과의 필수 필드, 타입, enum, const, 배열 항목 및 추가 필드 금지 검증
- 모든 dynamic verification의 NOT_VERIFIED
- 실행 전후 fixture clone의 file list와 SHA-256 불변
- source fixture의 file list와 SHA-256 불변
- installer WhatIf
- 동일 symbolic link 반복 설치의 idempotency
- 기존 충돌 경로 보존
- inherited GIT_DIR 무력화
- junction 뒤의 외부 파일 미열람
- reparse-point project root의 AUDIT_BLOCKED
- project-local Git executable 실행 거부
- Baseline copy-set 콘텐츠와 `.git` metadata의 독립 snapshot
- Codex checkpoint-only 추가의 `AMBIENT_CODEX_CHECKPOINTS_ONLY` 판정
- HEAD, index, config, hook, 일반 ref, object, checkpoint 기존 파일 변경·삭제의 차단
- `.git` reparse point 미추적과 차단
- 저장소 콘텐츠 불변 및 ambient checkpoint 외 Git metadata 불변
- Baseline ProjectRoot 생략 시 exact current working directory
- one-command Doctor scanner 자동 탐색과 raw JSON/stderr 외부 보존
- Doctor warning의 저수준 결과 전달
- scanner nonzero/empty/malformed stdout의 Unity 실행 전 차단
- Unity override/environment/Hub root/Program Files resolver 우선순위
- exact `6000.0.69f1`만 선택하고 인접 버전, Hub 실행, registry 또는 recursive drive 검색을 사용하지 않음
- in-project/reparse artifact root의 구조화된 차단과 원본 무변경
- Orchestrator compact/Pretty stdout이 verifier JSON 하나만 포함
- production unsigned fake 차단과 trust bypass 부재
- Test Scaffold PLAN의 byte-for-byte 결정성과 fixture 무변경
- exact `planSha256` 없는 APPLY 및 stale/mismatched hash 차단
- create-new 적용, exact path/content delta 및 partial transaction rollback
- unique Runtime inference, ambiguous Runtime fail-closed, explicit root override 및 path escape 차단
- 생성된 test asmdef를 Doctor가 confirmed evidence로 분류하는지 확인

fixture는 system temporary directory에 복제되어 Git fixture로 초기화된다. 테스트 출력에 표시된 scratch artifact는 저장소 밖에 남으며 Unity project나 source fixture에는 영향을 주지 않는다.

모든 PowerShell script의 parse 상태도 확인할 수 있다.

~~~powershell
Get-ChildItem -Filter *.ps1 -File -Recurse | ForEach-Object {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $_.FullName,
        [ref]$null,
        [ref]$errors
    ) | Out-Null
    [pscustomobject]@{
        Path = $_.FullName
        ParseErrors = $errors.Count
    }
}
~~~

GitHub Actions의 `static-tests.yml`은 Doctor fixture/schema/fingerprint를, `baseline-static-tests.yml`은 production unsigned-fake 차단과 내부 Job Object/log 회귀를, `editmode-static-tests.yml`은 Baseline handoff·NUnit/XML·EditMode 인수·source-editor·process-tree 회귀를, `test-scaffold-static-tests.yml`은 PLAN/APPLY/hash/delta/rollback 회귀를 `windows-latest`에서 실행한다. 네 workflow 모두 Unity와 외부 package를 설치하지 않으며 테스트 뒤 `git diff`와 `git status`가 깨끗한지 확인한다.

## 수동 검증

실제 프로젝트 승인 결과는 [v0.2.0 실제 프로젝트 승인 기록](docs/validation/v0.2.0-real-project-acceptance.md)에 정리되어 있다.

Baseline 0.1.2의 checkpoint 오탐 회귀 조건과 실제 Unity 재승인 기준은 [v0.1.2 원본 무결성 승인 절차](docs/validation/v0.1.2-original-integrity-acceptance.md)에 정의되어 있다. 해당 절차는 명시적으로 호출된 signed-Unity 실행에서 `BASELINE_VERIFIED`로 승인되었으며, 공개 가능한 근거는 [v0.1.2 실제 Unity 승인 결과](docs/validation/v0.1.2-real-unity-acceptance-result.md)에 기록했다. 기존 [v0.1.1 절차](docs/validation/v0.1.1-unity-baseline-real-unity-acceptance.md)는 과거 기준선으로 보존한다.

### 비 Unity 폴더

1. 새 빈 폴더 또는 이 저장소처럼 Unity marker가 없는 폴더를 선택한다.
2. scanner를 해당 경로로 실행한다.
3. projectDetection.isUnityProject가 false인지 확인한다.
4. finalStatus가 NOT_A_UNITY_PROJECT인지 확인한다.
5. 실행 전후 파일 목록이 같은지 확인한다.

### 실제 Unity 프로젝트

1. Unity를 종료하고 프로젝트 루트에서 호출 전 Git 상태를 기록한다.
2. Skill을 명시적으로 호출하거나 scanner를 ProjectRoot와 함께 직접 실행한다.
3. stdout이 JSON 하나인지 확인한다.
4. projectRoot와 Unity marker가 기대한 경로인지 확인한다.
5. compilation, tests, build 및 runtime이 모두 NOT_VERIFIED인지 확인한다.
6. warning과 blocked check가 실제 evidence와 연결되는지 확인한다.
7. 실행 후 Git 상태가 호출 전과 같은지 비교한다.
8. Unity Editor, Unity Hub, test runner, build 또는 player process가 실행되지 않았는지 확인한다.

Git worktree가 없는 정상 Unity folder는 Git check가 NOT_AVAILABLE이므로 STATIC_AUDIT_COMPLETE_WITH_WARNINGS가 된다.

## v0.1에서 달라진 점

v0.1은 Codex가 SKILL.md 절차를 직접 해석하는 instruction-only audit였다. v0.2는 같은 안전 계약과 종료 상태를 유지하면서 정적 수집을 bundled PowerShell scanner로 고정했다.

- 반복 실행 가능한 단일 JSON contract
- 정렬된 inventory와 timestamp 없는 결정론적 출력
- parse 실패와 blocked check의 구조화
- root 경계와 reparse point 차단
- fixture regression test 및 Windows CI
- scanner가 불가능할 때만 남겨 둔 v0.1 manual fallback

## Doctor에서 의도적으로 미구현한 범위

- Unity Editor 또는 batchmode
- compilation
- EditMode 또는 PlayMode test 실행
- Player Build
- runtime 또는 gameplay 검증
- Unity 실행 기반 검증. Script compilation은 Baseline, EditMode 테스트는 EditMode Verification이 각각 담당함
- MCP
- UPM package
- 자동 수정 또는 cleanup
- debugging
- 구조 refactoring
- Python 또는 Node CLI
- 결과 database
- 프로젝트 내부 설정 설치

## Baseline과의 책임 경계

`$unity-baseline-verification`은 Doctor에 동적 기능을 추가하지 않는다. 별도 명시적 호출, 별도 Skill 정책 및 별도 종료 상태를 유지하며, component 0.2.0 orchestrator가 Doctor 0.2.1 `schemaVersion: 1.1.0` JSON을 새로 생성해 현재 project fingerprint와 함께 저수준 verifier에 전달한다. Legacy 1.0.0 JSON은 정적 감사 자료로만 인정하고 실행 근거로 승격하지 않는다.

- Doctor는 원본 Unity 프로젝트를 완전한 읽기 전용으로 정적 감사한다.
- Baseline orchestrator는 bundled scanner를 직접 재사용하며 `$unity-project-doctor` Skill을 암묵적으로 호출하지 않는다.
- 저수준 verifier는 Doctor와 동일한 copy set으로 원본 콘텐츠를 보호하고, `.git` metadata를 별도 분류하며, 외부 임시 위치에 만든 격리 복사본에만 검증된 Unity.exe를 실행한다.
- Baseline component 0.2.0과 저수준 verifier 0.1.3은 script compilation 근거만 다루며 tests, Player Build, PlayMode 및 runtime은 `NOT_VERIFIED`로 유지한다.

자세한 전제조건, 실행 명령, 결과 상태 및 안전 계약은 [Unity Baseline Verification 문서](docs/skills/unity-baseline-verification.md)를 따른다.

## Test Scaffold와 검증 Skill의 책임 경계

`$unity-test-scaffold`는 `NO_CONFIRMED_TEST_ASSEMBLY`를 성공으로 바꾸는 verifier가 아니다. 기본 PLAN과 hash-confirmed APPLY로 Runtime/EditMode asmdef 구조만 준비한다.

- APPLY만 원본 프로젝트에 계획된 새 파일을 추가하며 기존 파일은 수정하지 않는다.
- Runtime asmdef 추가는 assembly boundary를 바꿀 수 있으므로 다음 `$unity-baseline-verification`에서 실제 Script Compilation을 다시 확인해야 한다.
- 의미 있는 EditMode test method는 프로젝트 요구사항에 맞춰 별도로 작성해야 한다.
- `$unity-editmode-verification`은 그 뒤 Doctor가 confirmed evidence로 인정한 assembly만 격리 실행한다.

자세한 PLAN/APPLY 확인, rollback 및 결과 schema는 [Unity Test Scaffold 문서](docs/skills/unity-test-scaffold.md)를 따른다.

실제 서명된 Unity를 사용하는 검증은 자동 테스트 범위가 아니다. 기존 저수준 verifier 0.1.2의 승인 결과는 [실제 Unity 승인 결과](docs/validation/v0.1.2-real-unity-acceptance-result.md)와 [v0.3.0 Release 노트](docs/releases/v0.3.0.md)에 보존한다. Baseline 0.2.0 one-command 흐름은 2026-08-17에 별도로 실행됐고 [승인 기록](docs/validation/v0.2.0-baseline-orchestration-acceptance.md)에 `APPROVED — SCRIPT COMPILATION ONLY`로 봉인됐다. 이 승인은 tests, Player Build, PlayMode, gameplay, runtime 또는 release readiness를 증명하지 않는다.
