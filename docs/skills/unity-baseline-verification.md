# Unity Baseline Verification 0.1.1

Unity Baseline Verification is an explicit-only Codex Skill that checks a Unity 6000.0.69f1 script-compilation baseline without opening the original project in Unity. It fully validates Doctor evidence, binds that evidence to current content, copies only the approved file set to an external temporary session, and runs only a trusted Unity.exe against that copy.

Tests, Player Build, PlayMode, and runtime behavior are always `NOT_VERIFIED`.

## Invocation and scope

- The literal name `$unity-baseline-verification` is required.
- `policy.allow_implicit_invocation` is `false`.
- The Skill does not invoke `$unity-project-doctor` implicitly.
- It performs import and script-compilation evidence collection only.
- It never runs tests, a Player Build, PlayMode, scenes, players, or runtime behavior.

## Safety contract

- The original project is read-only and is never passed to Unity.
- Unity Hub is never started. The verifier starts only the supplied `Unity.exe`.
- Logs, captured streams, result JSON, the Job Object session, and the copied project stay outside the source project.
- The source root, Doctor JSON, Unity.exe, artifact root, and copy-included package paths must not traverse reparse points.
- The exact source project must not already be open through a running `Unity.exe -projectPath` argument. Unrelated Unity projects are not blocked.
- Two complete source snapshots must be identical before copying, and another must still match before Unity starts.
- The complete pre/post source directory list, file list, file lengths, and per-file SHA-256 values must remain identical.
- No module, package, CLI, SDK, certificate bundle, or other dependency is installed.
- No automatic repair, migration, API update, cleanup, rollback, or success inference is allowed.

## Doctor schema and migration

Baseline 0.1.1 recognizes two Doctor contracts:

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

The production entrypoint requires all of the following:

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

## Direct invocation

Generate Doctor JSON outside the project first, then run:

~~~powershell
$verifier = "E:\Playground\Pipelines\unity_agent_pipeline\skills\codex\unity-baseline-verification\scripts\verify-unity-baseline.ps1"
$unity = "C:\Program Files\Unity\Hub\Editor\6000.0.69f1\Editor\Unity.exe"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifier `
  -ProjectRoot "E:\Unity\ExampleProject" `
  -DoctorResultPath "C:\Temp\doctor-1.1.0.json" `
  -UnityExecutable $unity `
  -Pretty
~~~

`ExecutionPolicy Bypass` applies only to that child PowerShell process. The verifier prints exactly one JSON document to stdout; diagnostics use stderr. The same JSON is saved to `artifacts.resultPath`.

## Result contract changes

Baseline result `schemaVersion` is 1.1.0 and `verifierVersion` is 0.1.1. The four final status names are unchanged:

| finalStatus | Meaning |
| --- | --- |
| `BASELINE_VERIFIED` | All required positive compilation, trust, isolation, process-tree, and integrity evidence passed |
| `BASELINE_FAILED` | Concrete nonzero exit or compiler/fatal log evidence exists |
| `VERIFICATION_BLOCKED` | Required evidence is invalid, unavailable, unsafe, mismatched, or inconclusive |
| `ORIGINAL_PROJECT_CHANGED` | The source pre/post directory or file/hash evidence differs |

New or expanded evidence is under:

- `doctor.schemaPath`, `schemaValidated`, `validationErrors`, `projectFingerprint`, `currentProjectFingerprint`, and `fingerprintMatched`;
- `unity.companyName`, `signatureStatus`, `signerSubject`, `certificateThumbprint`, and executable SHA-256;
- `preflight`;
- `processControl`;
- `isolation.localPackageReferences` and `isolation.copyFingerprint`.

Only `verification.scriptCompilation` can become verified. `verification.tests`, `playerBuild`, `playMode`, and `runtime` remain `NOT_VERIFIED`.

## Static and fake tests

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\unity-baseline-verification\run-tests.ps1
~~~

CI uses plain Windows PowerShell and installs neither Unity nor external packages. The unsigned fake executable is blocked by the production entrypoint. It is invoked only through internal process-control and shared log-analysis functions to verify arguments, exit codes, log classification, parent/child timeout termination, and delayed-sentinel suppression.

For the separate signed-editor acceptance procedure, see [Unity Baseline Verification 0.1.1 real-Unity acceptance](../validation/v0.1.1-unity-baseline-real-unity-acceptance.md).
