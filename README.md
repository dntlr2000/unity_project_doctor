# Unity Project Doctor

Unity Project Doctor는 Codex에서 명시적으로 호출하는 Unity 프로젝트 읽기 전용 정적 감사 Skill이다. 현재 버전은 0.2.0이며, bundled PowerShell scanner가 현재 작업 디렉터리를 반복 가능한 JSON으로 검사한다.

이 도구는 Unity 프로젝트의 정적 상태만 관찰한다. Unity Editor, Unity Hub, batchmode, compiler, test runner, player build 또는 runtime을 실행하지 않는다.

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
unity_project_doctor/
├── .github/workflows/static-tests.yml
├── CHANGELOG.md
├── README.md
├── VERSION
├── scripts/
│   └── install-codex-skills.ps1
├── skills/codex/unity-project-doctor/
│   ├── SKILL.md
│   ├── agents/openai.yaml
│   └── scripts/inspect-unity-project.ps1
└── tests/
    ├── fixtures/
    │   ├── not-unity/
    │   ├── unity-minimal-clean/
    │   ├── unity-with-warnings/
    │   ├── malformed-manifest/
    │   └── missing-build-scene/
    └── run-tests.ps1
~~~

Skill 원본은 이 Git 저장소에 남는다. 설치기는 원본 디렉터리를 사용자 홈의 .agents/skills/unity-project-doctor에 symbolic link로 연결한다.

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

## 설치

PowerShell에서 저장소 루트로 이동한 뒤 먼저 설치 계획을 확인한다.

~~~powershell
cd E:\Playground\Pipelines\unity_project_doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-codex-skills.ps1 -WhatIf
~~~

계획이 맞으면 설치한다.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-codex-skills.ps1
~~~

Windows에서 symbolic link 생성에는 개발자 모드 또는 관리자 권한이 필요할 수 있다. ExecutionPolicy Bypass는 위 child process에만 적용되며 사용자 또는 시스템 정책을 바꾸지 않는다.

설치 결과를 확인한다.

~~~powershell
$link = Get-Item "$HOME\.agents\skills\unity-project-doctor" -Force
$link | Select-Object FullName, LinkType, Target
Test-Path "$HOME\.agents\skills\unity-project-doctor\SKILL.md"
Test-Path "$HOME\.agents\skills\unity-project-doctor\scripts\inspect-unity-project.ps1"
~~~

설치기는 기존 경로를 삭제하거나 덮어쓰지 않는다.

- 같은 원본을 가리키는 symbolic link는 unchanged로 유지한다.
- 실제 directory, file, 다른 link 또는 dangling link가 충돌하면 아무 새 link도 만들기 전에 종료한다.
- Skill 원본을 복사하지 않는다.

## 업데이트

원본 저장소를 정상적인 Git 절차로 업데이트한다.

~~~powershell
cd E:\Playground\Pipelines\unity_project_doctor
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

allow_implicit_invocation은 false다. Skill 이름이 없는 일반 Unity 질문이나 일반 코드 검토 요청으로 이 audit가 자동 실행되어서는 안 된다.

Skill은 bundled scanner가 실행 가능하면 이를 우선한다. scanner JSON이 사실과 상태의 원본이며 Codex는 warning을 제거하거나 finalStatus를 승격하지 않는다. scanner가 실행 불가능한 경우에만 v0.1 읽기 전용 manual audit를 fallback으로 사용하며, 그 사실을 반드시 warning 또는 blocker로 보고한다.

## scanner 직접 실행

ProjectRoot 기본값은 현재 작업 디렉터리다.

~~~powershell
$scanner = "E:\Playground\Pipelines\unity_project_doctor\skills\codex\unity-project-doctor\scripts\inspect-unity-project.ps1"
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

schemaVersion 1.0.0의 최상위 필드는 다음과 같다.

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
| warnings | 정적 warning code, check, path 및 message |
| blockedChecks | 완료할 수 없었던 check와 구체적 이유 |
| dynamicVerification | compilation, tests, build 및 runtime의 NOT_VERIFIED 상태 |
| finalStatus | 네 종료 상태 중 하나 |
| evidence | 순서가 고정된 관찰 및 판단 근거 |

compact 출력은 동일한 입력 filesystem과 Git metadata에서 byte-for-byte 결정성을 목표로 한다. Pretty는 같은 의미를 유지하면서 whitespace만 바꾼다.

## 종료 상태

- STATIC_AUDIT_COMPLETE: 모든 필수 정적 check가 완료됐고 warning 또는 blocker가 없다.
- STATIC_AUDIT_COMPLETE_WITH_WARNINGS: 정적 audit는 완료됐지만 warning 또는 NOT_AVAILABLE check가 있다.
- AUDIT_BLOCKED: permission, I/O, unsafe path 또는 tool failure가 의미 있는 필수 check를 막았다.
- NOT_A_UNITY_PROJECT: 정확한 candidate root에 필수 Unity marker가 없다.

Compilation, tests, build 및 runtime의 의도된 NOT_VERIFIED는 그 자체로 warning을 만들지 않는다.

## 자동 테스트

저장소 루트에서 다음 명령을 실행한다.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
~~~

테스트는 외부 framework 없이 기본 PowerShell 기능만 사용한다.

- NOT_A_UNITY_PROJECT
- ProjectRoot 생략 시 current working directory 기본값
- clean minimal Unity project
- warning project
- malformed manifest
- missing Build Settings Scene
- compact JSON determinism
- Unicode project path round-trip
- 필수 schema field
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

GitHub Actions의 static-tests workflow는 windows-latest에서 같은 fixture test만 실행한다. Unity와 외부 package를 설치하지 않는다.

## 수동 검증

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

## 의도적으로 미구현한 범위

- Unity Editor 또는 batchmode
- compilation
- EditMode 또는 PlayMode test 실행
- Player Build
- runtime 또는 gameplay 검증
- unity-baseline-verification
- MCP
- UPM package
- 자동 수정 또는 cleanup
- debugging
- 구조 refactoring
- Python 또는 Node CLI
- 결과 database
- 프로젝트 내부 설정 설치

## unity-baseline-verification 진입 조건

다음 단계는 v0.2 scanner JSON schema와 안전 계약이 실제 여러 Unity 프로젝트에서 안정화된 뒤 시작한다.

- fixture CI가 지속적으로 통과
- 서로 다른 Unity version과 package 구성을 가진 실제 프로젝트에서 수동 read-only 검증 완료
- warning code와 blocked check 의미가 충분히 안정화
- schemaVersion 1.0.0 consumer contract 합의
- compile, test, build를 실행할 별도 명시적 권한과 격리된 output 위치 설계
- static audit와 dynamic baseline verification의 종료 상태 및 책임 경계 정의

이 조건을 만족하기 전에는 unity-baseline-verification 기능을 이 Skill에 추가하지 않는다.
