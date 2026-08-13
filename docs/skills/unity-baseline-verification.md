# Unity Baseline Verification

Unity Baseline Verification is an explicit-only Codex Skill in the Unity Agent Pipeline monorepo. Version 0.1.0 verifies a Unity 6000.0.69f1 script-compilation baseline without opening the original project in Unity. It consumes an existing unity-project-doctor v0.2 JSON document, makes a guarded temporary copy, runs only the supplied Unity.exe against that copy, analyzes the process and Editor.log, and proves the original tree is unchanged.

The Skill never runs tests, PlayMode, a Player Build, or runtime behavior.

## Safety contract

- Invocation requires the literal Skill name $unity-baseline-verification.
- unity-project-doctor v0.2 JSON schema 1.0.0 is required before Unity can start.
- Only Unity 6000.0.69f1 is accepted.
- Unity.exe receives the isolated project path; the original path is rejected from its argument list.
- Unity Hub is never launched by the verifier.
- Logs, captured streams, the copied project, and the JSON result are created under a unique external temporary session.
- The original directory list, file list, file lengths, and per-file SHA-256 hashes are captured before and after the isolated run.
- Reparse points and local file package dependencies that escape the project are rejected.
- Library, Temp, Obj, Logs, Build, Builds, UserSettings, version-control metadata, IDE state, and project-local agent metadata are not copied.
- No external PowerShell module, package, CLI, SDK, test framework, or other dependency is installed.
- No API update, automatic repair, migration, cleanup, build, test, PlayMode, or runtime command is requested.
- Missing positive evidence remains NOT_VERIFIED and can never be inferred as success.

The isolated project and evidence are intentionally retained outside the original project for inspection.

## Repository layout

~~~text
unity_agent_pipeline/
├── .github/workflows/baseline-static-tests.yml
├── docs/skills/unity-baseline-verification.md
├── scripts/install-codex-skills.ps1
├── skills/codex/unity-baseline-verification/
│   ├── VERSION
│   ├── SKILL.md
│   ├── agents/openai.yaml
│   └── scripts/verify-unity-baseline.ps1
└── tests/unity-baseline-verification/run-tests.ps1
~~~

## Prerequisites

- Windows PowerShell 5.1 or newer
- A Unity project whose ProjectSettings/ProjectVersion.txt identifies 6000.0.69f1
- The exact Unity 6000.0.69f1 Unity.exe
- An existing unity-project-doctor 0.2.0 JSON result for the same absolute project root

The verifier follows Unity 6 command-line behavior for -projectPath, -batchmode, -nographics, -quit, -logFile, and -upmLogFile:

https://docs.unity3d.com/6000.0/Documentation/Manual/EditorCommandLineArguments.html

## Doctor v0.2 compatibility

The consumer requires:

| Field | Required value |
| --- | --- |
| schemaVersion | 1.0.0 |
| scannerVersion | 0.2.0 |
| projectRoot | Exact normalized original project root |
| projectDetection.isUnityProject | true |
| projectDetection.rootStatus | UNITY_PROJECT |
| unityEditorVersion.parseStatus | PARSED |
| unityEditorVersion.editorVersion | 6000.0.69f1 |
| finalStatus | STATIC_AUDIT_COMPLETE or STATIC_AUDIT_COMPLETE_WITH_WARNINGS |
| blockedChecks | Empty |
| dynamicVerification.*.status | NOT_VERIFIED |
| evidence | Non-empty |

Doctor warnings are preserved in the baseline result and do not become success evidence. AUDIT_BLOCKED and NOT_A_UNITY_PROJECT stop before any Unity process.

The Doctor JSON SHA-256 is included in the output so the exact preflight document remains traceable.

## Install the global Skill

Preview the symbolic-link install:

~~~powershell
cd E:\Playground\Pipelines\unity_agent_pipeline
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-codex-skills.ps1 -WhatIf
~~~

Install into the default user-wide .agents/skills directory:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-codex-skills.ps1
~~~

The installer is conflict-safe and idempotent. It never replaces a directory, file, dangling link, or link to another source.

## Invoke from Codex

The Skill has policy.allow_implicit_invocation set to false. Invoke it by name and provide an existing Doctor JSON path:

~~~text
$unity-baseline-verification Verify the current Unity project with Doctor JSON C:\Temp\doctor.json and Unity.exe C:\Program Files\Unity\Hub\Editor\6000.0.69f1\Editor\Unity.exe.
~~~

If Doctor JSON does not exist, explicitly invoke $unity-project-doctor first. Unity Baseline Verification does not implicitly invoke that separate Skill.

## Run the verifier directly

~~~powershell
$verifier = "E:\Playground\Pipelines\unity_agent_pipeline\skills\codex\unity-baseline-verification\scripts\verify-unity-baseline.ps1"
$unity = "C:\Program Files\Unity\Hub\Editor\6000.0.69f1\Editor\Unity.exe"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifier -ProjectRoot "E:\Unity\ExampleProject" -DoctorResultPath "C:\Temp\doctor.json" -UnityExecutable $unity -Pretty
~~~

Parameters:

| Parameter | Meaning |
| --- | --- |
| ProjectRoot | Exact original Unity project; defaults to the current directory |
| DoctorResultPath | Existing Doctor 0.2.0 JSON file outside the project |
| UnityExecutable | Exact Unity 6000.0.69f1 Unity.exe |
| ArtifactsRoot | External parent for a unique session; defaults to the system temporary directory |
| TimeoutSeconds | Unity process timeout; defaults to 1800 |
| Pretty | Pretty-print the one JSON stdout document |

Normal stdout is exactly one JSON document. The same JSON is written to artifacts.resultPath. Unity stdout, stderr, Editor.log, and UPM output remain under the external session.

## Unity evidence rules

BASELINE_VERIFIED requires all of these concrete facts:

- Unity.exe ProductVersion identifies 6000.0.69f1.
- Current ProjectVersion.txt identifies 6000.0.69f1.
- Editor.log identifies 6000.0.69f1.
- Editor.log records BatchMode: 1.
- Editor.log records the exact isolated project path.
- Editor.log records Application.AssetDatabase Initial Refresh End.
- Editor.log records the CompileScripts phase and a completed domain reload.
- Editor.log records successful batch-mode shutdown and return code 0.
- The actual process exit code is 0.
- No compiler, fatal, crash, package-resolution, or nonzero-return marker is present.
- The original pre/post tree evidence is identical.

If any positive marker is missing, the result is not promoted to success. Compiler errors and other concrete failures produce BASELINE_FAILED. Unsafe or inconclusive evidence produces VERIFICATION_BLOCKED.

## Result statuses

| finalStatus | Meaning |
| --- | --- |
| BASELINE_VERIFIED | Compilation evidence and original integrity both passed |
| BASELINE_FAILED | Concrete Unity exit or log failure evidence exists |
| VERIFICATION_BLOCKED | Required evidence is invalid, unsafe, unavailable, or inconclusive |
| ORIGINAL_PROJECT_CHANGED | Original directory or file hash evidence differs |

Only verification.scriptCompilation can be verified. These always remain NOT_VERIFIED in v0.1:

- verification.tests
- verification.playerBuild
- verification.playMode
- verification.runtime

## Tests

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\unity-baseline-verification\run-tests.ps1
~~~

Tests compile a small fake Unity.exe with the Windows PowerShell built-in C# compiler. No Unity installation or external module is used. The fake executable validates argument forwarding and produces controlled Editor.log and exit-code cases.

Coverage includes:

- accepted and rejected Doctor v0.2 contracts
- exact Unity executable version checks
- success, compiler failure, nonzero exit, missing log, and inconclusive log classification
- isolated -projectPath and external log arguments
- absence of tests, builds, PlayMode, runtime, API updates, and compiler-error bypass arguments
- source-copy exclusions
- original-project unchanged evidence
- deliberate original mutation detection
- stdout-only JSON behavior
- installer WhatIf, idempotency, and conflict preservation
- PowerShell parsing and Skill metadata policy

GitHub Actions runs only these fake-Unity and static tests on windows-latest. It does not install or run Unity.
