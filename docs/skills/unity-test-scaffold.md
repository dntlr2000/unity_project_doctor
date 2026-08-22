# Unity Test Scaffold 0.1.0

`$unity-test-scaffold`는 Unity 프로젝트에 EditMode 테스트를 작성할 수 있는 최소 Assembly Definition 구조를 준비하는 명시적 호출 전용 Skill이다. Doctor, Baseline, EditMode Verification과 달리 승인된 APPLY는 프로젝트에 파일을 추가하므로 별도 Skill과 별도 확인 계약으로 분리한다.

## 해결하는 문제

Unity EditMode Verification은 Doctor가 직접 근거로 확정한 테스트 어셈블리만 실행한다. 테스트용 asmdef가 없으면 `NO_CONFIRMED_TEST_ASSEMBLY`가 정상 결과다. 이 Scaffold는 다음 구조를 결정론적으로 계획한다.

~~~text
Assets/.../Scripts/Runtime/
└── <Project>.Runtime.asmdef

Assets/.../Tests/EditMode/
└── <Project>.EditModeTests.asmdef
~~~

두 asmdef와 필요한 새 폴더에는 `.meta`도 함께 계획한다. 생성되는 `.meta`는 UTF-8 without BOM, LF-only, 정확히 하나의 terminal LF로 직렬화되며 PLAN hash가 그 exact byte content를 결속한다. 테스트 asmdef는 `Editor` 전용이며 Runtime assembly를 참조하고 `optionalUnityReferences: ["TestAssemblies"]`를 포함한다. 이 속성이 Doctor의 confirmed test assembly 직접 근거가 되지만, Unity가 실제 import하거나 DLL을 생성했다는 증거는 아니다.

Scaffold는 테스트 메서드를 만들지 않는다. 자동으로 통과하는 placeholder test는 실제 동작을 검증하지 않으므로 `EDITMODE_VERIFIED` 근거로 사용해서는 안 된다.

## 전제조건

- 정확한 `ProjectRoot`에 `Assets`, `Packages/manifest.json`, `ProjectSettings/ProjectVersion.txt`가 있어야 한다.
- `Packages/manifest.json`은 JSON으로 파싱 가능해야 한다.
- `com.unity.test-framework`가 direct dependency로 선언돼 있어야 한다. Scaffold는 manifest를 수정하거나 package를 설치하지 않는다.
- Runtime C# source root가 하나의 `Runtime` 디렉터리로 유일하게 추론되거나 `-RuntimeSourceRoot`로 명시돼야 한다.
- ProjectRoot와 읽기·쓰기 대상 경로에 reparse point, junction 또는 symbolic link가 없어야 한다.
- 계획 경로에 기존 파일이 있으면 덮어쓰지 않고 차단한다.

## 두 단계 실행 계약

### 1. 읽기 전용 PLAN

Skill 호출 예시:

~~~text
$unity-test-scaffold로 현재 프로젝트의 EditMode 테스트 초기 구성을 계획해.
~~~

직접 실행:

~~~powershell
$scaffold = "E:\Playground\Pipelines\unity_agent_pipeline\skills\codex\unity-test-scaffold\scripts\invoke-unity-test-scaffold.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scaffold `
  -ProjectRoot "E:\Unity\ExampleProject" `
  -Pretty
~~~

PLAN은 프로젝트에 파일을 만들지 않는다. 출력의 `plan.files`에는 각 경로, 종류, 전체 content와 content SHA-256이 있고, `plan.planSha256`은 다음 항목을 함께 결속한다.

- 정규화된 절대 ProjectRoot
- 적용 전 Unity copy-set fingerprint
- Runtime/Test root와 assembly name
- 생성할 모든 directory
- 생성할 모든 file path, kind, content SHA-256

Runtime 후보가 여러 개이면 자동 선택하지 않는다.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scaffold `
  -ProjectRoot "E:\Unity\ExampleProject" `
  -RuntimeSourceRoot "Assets\_Project\Scripts\Runtime" `
  -Pretty
~~~

필요한 경우 `-RuntimeAssemblyName`, `-TestRoot`, `-TestAssemblyName`도 PLAN에서 명시할 수 있다. APPLY에서는 같은 옵션을 그대로 사용해야 한다.

### 2. 명시적으로 확인된 APPLY

계획의 모든 경로와 content, 특히 `RUNTIME_ASSEMBLY_BOUNDARY_CHANGE` 경고를 검토한다. 그 뒤 정확한 현재 hash를 명시해 적용한다.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scaffold `
  -ProjectRoot "E:\Unity\ExampleProject" `
  -Apply `
  -ExpectedPlanSha256 "<reviewed-64-character-sha256>" `
  -Pretty
~~~

프로젝트 상태나 옵션이 바뀌면 현재 plan hash도 바뀌므로 이전 확인은 재사용할 수 없다. 누락되거나 다른 hash는 쓰기 전에 `SCAFFOLD_BLOCKED`로 끝난다.

## APPLY가 생성할 수 있는 항목

- Runtime source owner가 없을 때 Runtime asmdef 1개와 그 `.meta`
- compatible test asmdef가 없을 때 Editor-only EditMode test asmdef 1개와 그 `.meta`
- 위 파일의 parent로 꼭 필요한 새 directory와 각 folder `.meta`

기존 owning Runtime asmdef 또는 compatible test asmdef가 있으면 재사용한다. 둘 다 이미 있으면 `SCAFFOLD_ALREADY_CONFIGURED`이며 아무것도 쓰지 않는다.

## 안전성과 롤백

- 파일은 create-new mode로만 쓴다. 기존 file, directory 또는 collision path를 덮어쓰지 않는다.
- 적용 직전에 copy-set fingerprint를 다시 계산한다.
- 적용 후 실제 added directory/file과 각 file SHA-256이 계획과 정확히 같은지 검사한다.
- 쓰기 실패나 예상 밖 delta가 있으면 현재 transaction이 새로 만든 정확한 파일과 빈 directory만 제거한다.
- 다른 프로세스가 만든 파일, 기존 파일, 기존 directory, Git metadata에는 손대지 않는다.
- 복원이 증명되지 않으면 `PROJECT_CHANGED_DURING_APPLY`를 유지하고 성공으로 승격하지 않는다.

Scaffold는 Unity, Unity Hub, compiler, Test Runner, Player Build, PlayMode 또는 player를 실행하지 않는다. project script, executable, Git hook도 실행하지 않는다. 모든 동적 검증 필드는 항상 `NOT_VERIFIED`다.

## Runtime asmdef의 영향

기존 Runtime source가 predefined `Assembly-CSharp`에 속해 있었다면 새 asmdef는 해당 source를 별도 assembly로 이동시킨다. 이 변화는 올바른 테스트 참조를 위해 필요할 수 있지만 다음 문제를 드러낼 수 있다.

- Runtime 코드가 다른 asmdef assembly를 참조하지만 새 Runtime asmdef에 reference가 없음
- 다른 asmdef assembly가 새 Runtime assembly를 참조해야 함
- Editor/Runtime source 배치가 기존 implicit compile order에 의존함
- internal type 접근을 위한 명시적 설계가 필요함

Scaffold는 이런 의존성을 추측해 자동 추가하지 않는다. APPLY 후에는 `$unity-project-doctor`, `$unity-baseline-verification`을 각각 명시적으로 호출해 정적 구조와 Script Compilation을 다시 검증한다. 그 다음 의미 있는 EditMode test code를 작성하고 `$unity-editmode-verification`을 명시적으로 호출한다.

Baseline이 `Unity.InputSystem` 같은 누락 reference를 보고하더라도 Scaffold가 이를 자동 수정하지 않는다. 필요한 package/assembly reference는 프로젝트의 실제 Runtime 코드와 의존 관계를 검토한 뒤 사용자가 승인한 별도 소스 변경으로 추가해야 한다.

## 결과 계약

결과 schema는 [unity-test-scaffold-result-1.0.0.schema.json](../../schemas/unity-test-scaffold-result-1.0.0.schema.json)이다.

주요 필드:

| 필드 | 의미 |
| --- | --- |
| `projectDetection` | 정확한 root의 Unity marker |
| `testFramework` | manifest parse와 direct Test Framework dependency |
| `runtime` | 후보, 선택 root, assembly name, existing/planned asmdef |
| `tests` | Test root, assembly name, existing/planned asmdef, test file 미생성 증거 |
| `preconditionFingerprint` | PLAN이 결속한 copy-set SHA-256 |
| `plan` | 전체 directory/file/content와 confirmation hash |
| `apply` | hash 일치, 시도, 생성 항목, postcondition, delta 및 rollback |
| `verification` | compilation/tests/build/runtime의 `NOT_VERIFIED` |
| `warnings`, `blockers`, `evidence` | 승격 없이 보존할 구조화된 판단 근거 |
| `finalStatus` | 아래 다섯 종료 상태 중 하나 |

종료 상태:

- `SCAFFOLD_PLAN_READY`: 검토 가능한 결정론적 PLAN이 준비됨
- `SCAFFOLD_APPLIED`: 확인된 추가 항목과 content만 생성되고 postcondition이 일치함
- `SCAFFOLD_ALREADY_CONFIGURED`: compatible 구조가 이미 있어 write가 없음
- `SCAFFOLD_BLOCKED`: 전제조건, 경로, 충돌, ambiguity, 확인 또는 transaction이 차단됨
- `PROJECT_CHANGED_DURING_APPLY`: delta나 rollback으로 계획 외 무변경을 증명할 수 없음

`SCAFFOLD_APPLIED`는 Script Compilation이나 test success가 아니다.

## 회귀 테스트

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\unity-test-scaffold\run-tests.ps1
~~~

테스트는 `TEMP`/`TMP`가 가리키는 외부 temporary directory의 fixture copy만 변경하며 실제 Unity를 실행하지 않는다. PLAN 결정성, exact `.meta` bytes와 terminal LF, hash 확인, exact delta, rollback, Doctor confirmed evidence, ambiguity, path escape, collision, installer 및 PowerShell parse를 검증한다.
