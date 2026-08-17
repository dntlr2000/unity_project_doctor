---
name: unity-baseline-verification
description: "Verify a Unity 6000.0.69f1 script-compilation baseline from one explicit $unity-baseline-verification invocation by running the bundled Doctor scanner, resolving an exact Unity.exe candidate, and delegating all trust, isolation, process-tree, log, and integrity decisions to the fail-closed low-level verifier. Use only when the user explicitly writes $unity-baseline-verification; never infer it from ordinary requests to compile, inspect, test, build, debug, or open a Unity project."
---

# Unity Baseline Verification v0.2.0

## Require explicit invocation

- Run this workflow only after the user writes `$unity-baseline-verification`.
- Do not infer invocation from an ordinary Unity, compile, test, build, review, or debugging request.
- Treat the exact current working directory as `ProjectRoot`; never search a parent, child, or sibling for another Unity project.

## Use the one-command entrypoint

Resolve `scripts/invoke-unity-baseline-verification.ps1` relative to this file and run it once:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <skill-root>\scripts\invoke-unity-baseline-verification.ps1 -ProjectRoot <absolute-current-working-directory> -Pretty
~~~

Do not ask the user to prepare a Doctor JSON file or Unity.exe path before this default attempt. Apply `ExecutionPolicy Bypass` only to the child process; never change user or machine policy.

The entrypoint must:

1. Run the sibling `unity-project-doctor/scripts/inspect-unity-project.ps1` directly as a bundled component. Do not invoke the separate `$unity-project-doctor` Skill.
2. Preserve the scanner's exact stdout as UTF-8 without BOM and its stderr separately, outside the project.
3. Read only the Doctor editor version needed for deterministic executable resolution.
4. Resolve only exact Unity `6000.0.69f1` candidates in this order: explicit `-UnityExecutable`, `UNITY_EDITOR_PATH`, `UNITY_HUB_EDITOR_ROOT\6000.0.69f1\Editor\Unity.exe`, `%ProgramFiles%`, then `%ProgramFiles(x86)%` Hub layout.
5. Invoke `scripts/verify-unity-baseline.ps1`, which remains the only component allowed to start Unity.
6. Return the verifier stdout unchanged as the sole JSON stdout document.

By default, keep the orchestration root at `%TEMP%\ubv`. Preserve Doctor evidence under `o-<guid>\d`, and pass the separate `<ArtifactsRoot>\b` parent to the low-level verifier. The Doctor GUID and the verifier's own session GUID must keep concurrent runs isolated without nesting both GUID paths.

Never launch Unity Hub, search a drive recursively, choose a nearby Unity version, install or update Unity, or treat executable discovery as trust approval. The low-level verifier must still validate exact version, filename, reparse safety, Authenticode status, Unity Technologies signer, and SHA-256.

If automatic discovery fails, report the verifier's blocker and show this optional retry only when the user supplies a known exact executable:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <skill-root>\scripts\invoke-unity-baseline-verification.ps1 -ProjectRoot <absolute-current-working-directory> -UnityExecutable <absolute-Unity.exe-path> -Pretty
~~~

Do not promote a failed scanner, empty or malformed Doctor stdout, missing executable, or verifier failure to a successful audit or baseline.

## Preserve the safety contract

- Never pass the original project to Unity. Run Unity only against the verifier's isolated external copy.
- Never create or modify a file under the original project, including `Assets`, `Packages`, `ProjectSettings`, `UserSettings`, or `.git`.
- Reject a reparse-point project root and an artifact root inside the project or behind a reparse point.
- Keep Doctor JSON, logs, streams, copied project, and Baseline result under an external session.
- Before creating the isolated project copy, require every full destination directory path to be shorter than 248 characters and every file path to be shorter than 260 characters. Report any boundary violation as a structured blocker; do not retry with another hidden path or infer that copying would succeed.
- Never execute a project-local script, executable, Git hook, test, scene, player, or build.
- Never pass `-runTests`, `-executeMethod`, build arguments, `-accept-apiupdate`, or `-ignorecompilererrors`.
- Never install packages, modules, SDKs, certificate bundles, or other dependencies.
- Never repair, migrate, update, clean, format, roll back, or refactor the project.
- Preserve unknown evidence as `NOT_VERIFIED`; never infer success from missing evidence.

Keep the fail-closed low-level verifier responsible for complete Doctor schema/fingerprint validation, source-editor preflight, local `file:` package safety, executable trust, Job Object process control, Editor.log classification, copy-set integrity, Git metadata integrity, and final status.

## Treat verifier JSON as authoritative

Accept only one valid JSON document from verifier stdout. Do not reserialize it, remove Doctor warnings, reinterpret evidence, or promote `finalStatus`.

- `BASELINE_VERIFIED`: all required compilation, trust, isolation, process-tree, and integrity evidence passed.
- `BASELINE_FAILED`: Unity produced concrete nonzero-exit, compiler, fatal, or equivalent failure evidence.
- `VERIFICATION_BLOCKED`: required evidence was unavailable, invalid, unsafe, mismatched, or inconclusive.
- `ORIGINAL_PROJECT_CHANGED`: source copy-set content changed or disallowed Git metadata changed.

Only `verification.scriptCompilation` may become `VERIFIED_SUCCESS` or `VERIFIED_FAILURE`. Keep `tests`, `playerBuild`, `playMode`, and `runtime` as `NOT_VERIFIED`.

If the result is `ORIGINAL_PROJECT_CHANGED`, report exact paths and stop. Do not modify or clean the original project.

## Retain direct reproduction mode

Use the bundled low-level entrypoint directly only when the user explicitly provides or requests a saved Doctor result and exact Unity path for reproduction:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <skill-root>\scripts\verify-unity-baseline.ps1 -ProjectRoot <absolute-project-root> -DoctorResultPath <absolute-doctor-json-path> -UnityExecutable <absolute-6000.0.69f1-Unity.exe-path> -Pretty
~~~

Require Doctor `schemaVersion: 1.1.0`, scanner `0.2.1`, exact project-root match, accepted static status, no blocked checks, `projectFingerprint.status: COMPUTED`, and all Doctor dynamic checks as `NOT_VERIFIED`. Legacy Doctor 1.0.0/0.2.0 evidence remains static-audit evidence only and must not permit Unity.

## Report

Return a concise report containing:

1. Final status and Doctor acceptance with preserved warning count.
2. Unity version, signer subject, certificate thumbprint, executable SHA-256, and isolated project path.
3. Exit code, timeout/termination, process-tree exit proof, and Editor.log classification.
4. Copy-set integrity and separate Git metadata integrity, including ambient checkpoint-only additions.
5. Tests, Player Build, PlayMode, and runtime as `NOT_VERIFIED`.
6. Doctor and Baseline artifact paths.

Do not claim gameplay, test, build, runtime, release readiness, or support for another Unity version.
