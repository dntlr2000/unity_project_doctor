# Unity Baseline Verification 0.2.0

Unity Baseline Verification is an explicit-only Codex Skill that checks a Unity 6000.0.69f1 script-compilation baseline without opening the original project in Unity. Component 0.2.0 adds a one-command orchestration layer that creates fresh Doctor evidence and resolves the exact Unity executable before delegating to fail-closed low-level verifier 0.1.3.

Tests, Player Build, PlayMode, and runtime behavior are always `NOT_VERIFIED`.

## Invocation and scope

- The literal name `$unity-baseline-verification` is required.
- `policy.allow_implicit_invocation` is `false`.
- The Skill does not invoke `$unity-project-doctor` implicitly. Its orchestrator calls the bundled sibling scanner script directly as a pipeline component.
- It performs import and script-compilation evidence collection only.
- It never runs tests, a Player Build, PlayMode, scenes, players, or runtime behavior.

## One-command flow

From an exact Unity project root, explicitly invoke:

~~~text
$unity-baseline-verification으로 현재 프로젝트를 검증해.
~~~

The Skill runs this entrypoint without requiring a pre-created Doctor file or Unity.exe path:

~~~powershell
$entrypoint = "<skill-root>\scripts\invoke-unity-baseline-verification.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entrypoint `
  -ProjectRoot (Get-Location).Path `
  -Pretty
~~~

The orchestrator performs only this handoff:

~~~text
exact ProjectRoot
→ bundled Doctor scanner child process
→ raw external Doctor JSON and stderr log
→ exact-version Unity.exe resolution
→ bundled verify-unity-baseline.ps1 child process
→ unchanged verifier JSON stdout
~~~

It does not implement Doctor schema validation, fingerprints, executable trust, Unity process control, Editor.log classification, source integrity, or final status. Those remain exclusively in `verify-unity-baseline.ps1`.

## Unity.exe resolution

For Doctor editor version `6000.0.69f1`, candidates are evaluated deterministically:

1. Explicit `-UnityExecutable` override.
2. Exact executable in `UNITY_EDITOR_PATH`.
3. `UNITY_HUB_EDITOR_ROOT\6000.0.69f1\Editor\Unity.exe`.
4. `%ProgramFiles%\Unity\Hub\Editor\6000.0.69f1\Editor\Unity.exe`.
5. `%ProgramFiles(x86)%\Unity\Hub\Editor\6000.0.69f1\Editor\Unity.exe`.

An explicit override is authoritative; an invalid override is preserved for structured verifier evidence instead of silently falling back. Automatic candidates must exist and must not traverse a reparse point. Discovery never launches Unity Hub, reads a registry key, recursively searches a drive, installs Unity, or substitutes another version. The low-level verifier independently checks filename, file/product version, company evidence, Authenticode status, Unity Technologies signer, and SHA-256 before Unity can start.

If automatic discovery returns a missing-executable blocker, retry only with a user-confirmed exact path:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entrypoint `
  -ProjectRoot "E:\Unity\ExampleProject" `
  -UnityExecutable "C:\Program Files\Unity\Hub\Editor\6000.0.69f1\Editor\Unity.exe" `
  -Pretty
~~~

## Artifact layout

When `-ArtifactsRoot` is omitted, the orchestrator uses `%TEMP%\ubv`. An explicit safe root uses the same compact layout:

~~~text
<ArtifactsRoot>/
├─ o-<guid>/
│  └─ d/
│     ├─ unity-project-doctor.json
│     └─ doctor-stderr.log
└─ b/
   └─ unity-baseline-verification-<guid>/
      ├─ logs/
      ├─ results/
      └─ project/
~~~

The one-command GUID isolates Doctor artifacts. The low-level verifier receives `<ArtifactsRoot>\b`, not a directory below that orchestration GUID, and creates its own GUID session so concurrent invocations remain isolated while the project destination stays short. The Doctor stdout is stored as UTF-8 without BOM without JSON reserialization. Scanner nonzero exit, empty stdout, or malformed JSON makes the Doctor input unusable and prevents Unity. An artifact root inside the source project or behind a reparse point is never written through and produces a structured low-level blocker.

Before the verifier creates the isolated `project` directory or copies a source file, it calculates every absolute destination path in the exact copy-set. Directory destinations must be shorter than 248 characters and file destinations shorter than 260 characters. A path at either boundary is blocked as `ISOLATION_DIRECTORY_PATH_BUDGET_EXCEEDED` or `ISOLATION_FILE_PATH_BUDGET_EXCEEDED`; a calculation failure is `ISOLATION_PATH_BUDGET_CHECK_FAILED`. Each blocker reports the exact destination path, relative source path, measured length, and boundary through the existing structured blocker/evidence shape. No long-path filesystem failure is treated as successful or inconclusive compilation evidence.

## Safety contract

- The original project is read-only and is never passed to Unity.
- Unity Hub is never started. The low-level verifier is the only component that starts the selected `Unity.exe`.
- Logs, captured streams, result JSON, the Job Object session, and the copied project stay outside the source project.
- The source root, Doctor JSON, Unity.exe, artifact root, and copy-included package paths must not traverse reparse points.
- The exact source project must not already be open through a running `Unity.exe -projectPath` argument. Unrelated Unity projects are not blocked.
- Source-editor preflight first enumerates processes with `Get-Process`. When that independent observation reports zero Unity processes, it records `PASSED` without calling CIM. When any Unity process exists, every still-running observed PID requires readable CIM CommandLine and one safely normalized `-projectPath`; unavailable or incomplete live-process evidence remains blocked.
- Two Doctor/Baseline copy-set snapshots must be identical before copying, and another must still match before Unity starts.
- The copy-set pre/post directory list, file list, file lengths, and per-file SHA-256 values must remain identical. Generated, tooling, agent, IDE, and version-control trees excluded from isolation are outside this content proof.
- The in-project `.git` entry is hashed separately. New paths strictly under `.git/refs/codex/turn-diffs/checkpoints/` are recorded as ambient metadata and do not invalidate unchanged project content.
- Existing Git metadata may never change or disappear. HEAD, index, config, hooks, ordinary refs, objects, and additions outside the checkpoint namespace remain blocking changes.
- No module, package, CLI, SDK, certificate bundle, or other dependency is installed.
- No automatic repair, migration, API update, cleanup, rollback, or success inference is allowed.

## Doctor schema and migration

The low-level verifier 0.1.3 recognizes two Doctor contracts:

| Doctor contract | Static-audit validity | Baseline eligibility |
| --- | --- | --- |
| schema 1.0.0 / scanner 0.2.0 | Still valid under `schemas/unity-project-audit.schema.json` | Blocked because it has no copy-set fingerprint |
| schema 1.1.0 / scanner 0.2.1 | Valid under `schemas/unity-project-audit-1.1.0.schema.json` | Eligible after semantic and fingerprint checks |

The frozen 1.0.0 schema was not edited or redefined. Schema 1.1.0 is a separate file and reuses the frozen definitions through local `$ref` resolution.

Before any Unity process can start, the production verifier checks the entire selected schema. Its no-module validator deterministically supports the keywords used by these contracts:

- `$ref`
- `type`
- `required`
- `const`
- `enum`
- `pattern`
- `minLength` and `maxLength`
- `minItems`
- `items`
- `additionalProperties`

Nested enum/type errors, missing nested fields, and extra properties produce structured errors with exact paths such as `$.git.metadataStatus`. Schema success evidence is emitted only after full validation.

Schema-valid Doctor 1.1.0 input must also satisfy:

- `projectRoot` exactly equals the normalized source root.
- The root is a Unity project and its parsed editor version is 6000.0.69f1.
- `finalStatus` is `STATIC_AUDIT_COMPLETE` or `STATIC_AUDIT_COMPLETE_WITH_WARNINGS`.
- `blockedChecks` is empty and static evidence is non-empty.
- Doctor compilation, tests, build, and runtime remain `NOT_VERIFIED`.
- `projectFingerprint.status` is `COMPUTED`, uses contract 1.0.0, and records two stable passes.
- The current copy-included source fingerprint exactly matches the Doctor fingerprint.

Warnings remain warnings and are preserved in the result.

## Fingerprint contract

The Doctor and Baseline use the same implementation. It fingerprints exactly the paths Baseline copies, excluding generated, tooling, version-control, IDE, and agent trees.

Entries are ordered with ordinal relative-path ordering. Canonical records contain:

- directory relative path and its UTF-8 byte length;
- file relative path and its UTF-8 byte length;
- file length;
- lowercase file SHA-256;
- LF record separators.

The contract identifier is `unity-copy-set-relative-path-length-sha256-lf-v1`. No fingerprint file or cache is written in the source project. Baseline recomputes the fingerprint from the source and the isolated copy; any mismatch blocks before Unity.

## Local `file:` package isolation

Every `Packages/manifest.json` dependency beginning with `file:` must be a relative reference that resolves to a copy-included path under the project root.

The verifier blocks:

- absolute references, including absolute paths still inside the project;
- UNC, URI authority, drive, and Windows device syntax;
- single- or multi-percent-encoded escape paths;
- relative paths that escape the project;
- generated or otherwise excluded top-level trees;
- missing targets;
- junctions, symlinks, or other reparse traversal.

Safe references are normalized at the source and isolated manifests. The normalized relative path must be identical, the isolated target must exist with the same filesystem type, and the source and isolated absolute paths must differ.

## Unity.exe trust

The production low-level entrypoint requires all of the following:

- filename `Unity.exe` outside the source project;
- no reparse traversal;
- ProductVersion identifying exactly 6000.0.69f1;
- `Get-AuthenticodeSignature` status `Valid`;
- a signer subject identifying Unity Technologies.

The result records FileVersion, ProductVersion, CompanyName, signer subject, certificate thumbprint, and executable SHA-256. Thumbprints are evidence for the inspected binary, not a permanent single-certificate pin. There is no `SkipSignatureCheck`, `TestMode`, or equivalent production bypass.

## Process-tree control and log evidence

Unity is created with `CREATE_SUSPENDED`, assigned to a Windows Job Object configured with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, and resumed only after assignment succeeds. This closes the start-to-assignment window in which an early child could otherwise escape process-tree control. After normal root-process exit, Job Object accounting must report zero active processes. On timeout or lingering descendants, the verifier terminates the Job Object and waits a bounded interval for zero active processes. Failure to prove tree exit blocks verification.

The result includes:

- Job Object creation/configuration/assignment;
- root process ID and exit state;
- timeout and termination reason;
- termination API result;
- final active-process count;
- bounded wait duration and tree-exit proof.

`BASELINE_VERIFIED` additionally requires process exit code 0 and explicit Editor.log evidence for the exact Unity version, batch mode, isolated project path, initial AssetDatabase refresh, `CompileScripts`, domain reload, successful batch-mode shutdown, and logged return code 0. Missing markers are inconclusive, never inferred success.

## Advanced direct reproduction

The manual handoff remains supported for exact reproduction with a saved Doctor result. Generate Doctor JSON outside the project first, then run:

~~~powershell
$verifier = "<skill-root>\scripts\verify-unity-baseline.ps1"
$unity = "C:\Program Files\Unity\Hub\Editor\6000.0.69f1\Editor\Unity.exe"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifier `
  -ProjectRoot "E:\Unity\ExampleProject" `
  -DoctorResultPath "C:\Temp\doctor-1.1.0.json" `
  -UnityExecutable $unity `
  -Pretty
~~~

`ExecutionPolicy Bypass` applies only to that child PowerShell process. The verifier prints exactly one JSON document to stdout; diagnostics use stderr. The same JSON is saved to `artifacts.resultPath`.

The one-command orchestrator does not replace or weaken this mode; it prepares the same inputs automatically.

## Original integrity model

The original-integrity split introduced by low-level verifier 0.1.2 is retained unchanged by verifier 0.1.3:

| Result object | Scope | Accepted states |
| --- | --- | --- |
| `originalProjectIntegrity` | Exact Doctor/Baseline copy set | `UNCHANGED` |
| `gitMetadataIntegrity` | In-project `.git` entry and descendants | `NOT_PRESENT`, `UNCHANGED`, `AMBIENT_CODEX_CHECKPOINTS_ONLY` |

The content snapshot uses the same exclusion list and canonical file set as Doctor `projectFingerprint`. This prevents Unity-generated or app-owned metadata outside the isolated copy from being misreported as a source-content mutation.

`AMBIENT_CODEX_CHECKPOINTS_ONLY` requires all of the following:

- every file addition is strictly below `.git/refs/codex/turn-diffs/checkpoints/`;
- added directories are only that namespace, its required parent directories, or descendants;
- no directory or file was removed;
- no existing file changed by path, length, or SHA-256;
- the `.git` root did not appear, disappear, or change filesystem type.

The path classification identifies a reserved namespace; it does not claim which process wrote the entries. Any other Git delta produces `CHANGED` and final status `ORIGINAL_PROJECT_CHANGED`. No cleanup or rollback is attempted.

## Result contract compatibility

Baseline component 0.2.0 forwards the verifier result without reserialization. Result `schemaVersion` remains 1.1.0 and `verifierVersion` is 0.1.3 for the Windows source-editor preflight compatibility fix. The four final status names are unchanged:

| finalStatus | Meaning |
| --- | --- |
| `BASELINE_VERIFIED` | All required positive compilation, trust, isolation, process-tree, and integrity evidence passed |
| `BASELINE_FAILED` | Concrete nonzero exit or compiler/fatal log evidence exists |
| `VERIFICATION_BLOCKED` | Required evidence is invalid, unavailable, unsafe, mismatched, or inconclusive |
| `ORIGINAL_PROJECT_CHANGED` | Copy-set content changed, or Git metadata changed outside the checkpoint-only allowance |

New or expanded evidence is under:

- `doctor.schemaPath`, `schemaValidated`, `validationErrors`, `projectFingerprint`, `currentProjectFingerprint`, and `fingerprintMatched`;
- `unity.companyName`, `signatureStatus`, `signerSubject`, `certificateThumbprint`, and executable SHA-256;
- `preflight`;
- `processControl`;
- `isolation.localPackageReferences` and `isolation.copyFingerprint`;
- `originalProjectIntegrity.scope` and `excludedTopLevelPaths`;
- separate `gitMetadataIntegrity` snapshots, deltas, allowed prefix, and classification.

Only `verification.scriptCompilation` can become verified. `verification.tests`, `playerBuild`, `playMode`, and `runtime` remain `NOT_VERIFIED`.

## Static and fake tests

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\unity-baseline-verification\run-tests.ps1
~~~

CI uses plain Windows PowerShell and installs neither Unity nor external packages. The Baseline suite includes resolver and orchestration tests for exact CWD, raw Doctor handoff, warning preservation, resolver precedence, unsafe artifacts, malformed/nonzero scanners, JSON-only stdout, Pretty formatting, the compact `%TEMP%\ubv` layout, and separate GUID isolation. It also models the observed 125-character ColorGateRush relative file path and proves the conservative Windows boundaries: 247-character directories and 259-character files are accepted, while 248-character directories and 260-character files are blocked before copying. The unsigned fake executable is blocked by both the one-command production path and the direct low-level entrypoint. It is invoked only through the existing internal process-control and shared log-analysis seam to verify arguments, exit codes, log classification, parent/child timeout termination, and delayed-sentinel suppression.

Regression tests also prove that checkpoint-only additions are accepted while HEAD, index, config, hook, and ordinary-ref changes remain blocking. The historical low-level gate passed on 2026-08-15; its anonymized evidence is recorded in the [0.1.2 real-Unity acceptance result](../validation/v0.1.2-real-unity-acceptance-result.md). That historical result does not approve verifier 0.1.3 or the new orchestration path. A separate explicit signed-Unity one-command run passed on 2026-08-17 and is sealed as [APPROVED — SCRIPT COMPILATION ONLY](../validation/v0.2.0-baseline-orchestration-acceptance.md). It does not verify tests, Player Build, PlayMode, gameplay, runtime, release readiness, or any Unity version other than 6000.0.69f1. The prior [0.1.2 procedure](../validation/v0.1.2-original-integrity-acceptance.md) and [0.1.1 procedure](../validation/v0.1.1-unity-baseline-real-unity-acceptance.md) remain historical evidence.
