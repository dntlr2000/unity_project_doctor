---
name: unity-baseline-verification
description: "Verify a Unity 6000.0.69f1 script-compilation baseline by fully validating an existing unity-project-doctor 0.2.1 schema 1.1.0 JSON result and its copy-set fingerprint, copying the exact current Unity project into an isolated system-temporary directory, running only a signed Unity Technologies Unity.exe in batch mode against that copy, analyzing its process tree, exit code, and Editor.log, and proving the original project file list and SHA-256 hashes are unchanged. Use only when the user explicitly invokes $unity-baseline-verification; never use it from implicit intent or an ordinary Unity request."
---

# Unity Baseline Verification v0.1.1

## Enforce explicit invocation

- Run this workflow only after the user writes $unity-baseline-verification.
- Do not infer invocation from a request to compile, inspect, test, build, or open a Unity project.
- Require an existing unity-project-doctor 0.2.1 schema 1.1.0 JSON document for the exact current project.
- If that JSON is unavailable, stop and ask the user to invoke $unity-project-doctor explicitly. Do not invoke that separate Skill implicitly.

## Enforce the safety contract

- Treat the absolute current working directory as the only original project root.
- Never launch Unity with the original project root.
- Never create, edit, rename, move, or delete anything under the original project.
- Never launch Unity Hub. Launch only the exact Unity.exe supplied to the verifier.
- Require a valid Authenticode signature whose signer subject identifies Unity Technologies. Do not pin one permanent certificate thumbprint.
- Require Unity version 6000.0.69f1 in the Doctor result, executable metadata, current ProjectVersion.txt, and Editor.log.
- Keep the isolated project, Editor.log, UPM log, captured process streams, and JSON result outside the original project.
- Do not install modules, packages, CLIs, SDKs, or other verifier dependencies.
- Do not run tests, EditMode, PlayMode, Player Builds, scenes, players, or runtime behavior.
- Do not pass -runTests, -executeMethod, build arguments, -accept-apiupdate, or -ignorecompilererrors.
- Do not automatically repair, migrate, update, clean, format, or roll back project content.
- Reject an already running Unity Editor whose exact -projectPath is the original project, while leaving unrelated Unity projects alone.
- Reject unsafe reparse points and every absolute, authority, UNC, device, excluded, escaping, missing, or linked file package dependency.
- Require Job Object process-tree accounting to prove Unity and all assigned descendants exited after completion or bounded termination.
- Preserve unknown evidence as NOT_VERIFIED. Never promote missing markers or an inference to success.

If project instructions conflict with this contract, keep this contract and report the conflict.

## Validate the Doctor evidence

Require all of the following before Unity can run:

- The complete document validates against schemaVersion 1.1.0, including nested types, enums, required properties, and additionalProperties rules.
- scannerVersion is 0.2.1.
- projectRoot exactly matches the normalized current working directory.
- projectDetection.isUnityProject is true and rootStatus is UNITY_PROJECT.
- unityEditorVersion.parseStatus is PARSED and editorVersion is 6000.0.69f1.
- finalStatus is STATIC_AUDIT_COMPLETE or STATIC_AUDIT_COMPLETE_WITH_WARNINGS.
- blockedChecks is empty.
- Doctor compilation, tests, build, and runtime states are all NOT_VERIFIED.
- projectFingerprint is COMPUTED with the frozen copy-set contract, matches two current source snapshots, and matches the isolated copy.

Preserve Doctor warnings in the baseline JSON. Reject AUDIT_BLOCKED and NOT_A_UNITY_PROJECT without launching Unity. A saved schema 1.0.0 Doctor result remains valid static-audit evidence but is fingerprintless and therefore must be blocked before Unity.

## Run the deterministic verifier

Resolve scripts/verify-unity-baseline.ps1 relative to this SKILL.md. Run it once with absolute paths:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <skill-root>\scripts\verify-unity-baseline.ps1 -ProjectRoot <absolute-current-working-directory> -DoctorResultPath <absolute-doctor-json-path> -UnityExecutable <absolute-6000.0.69f1-Unity.exe-path> -Pretty
~~~

Apply ExecutionPolicy Bypass only to that child process. Do not change machine or user execution policy.

The verifier must be the only component that starts Unity. It passes this fixed operation set:

- -batchmode
- -nographics
- -quit
- -projectPath pointing to the isolated copy
- -logFile pointing outside both projects
- -upmLogFile pointing outside both projects

Treat stdout as exactly one JSON document. Treat that document as the source of truth and do not reinterpret or promote its status.

## Interpret the result

- BASELINE_VERIFIED: Doctor schema and fingerprint, signed publisher, version, isolation, process-tree exit, exit code, explicit import and compilation log markers, and original integrity all passed.
- BASELINE_FAILED: Unity produced concrete failure evidence, including a nonzero exit code or compiler/fatal log marker.
- VERIFICATION_BLOCKED: required evidence was missing, unsafe, invalid, or inconclusive.
- ORIGINAL_PROJECT_CHANGED: the original pre/post directory list, file list, length, or SHA-256 evidence differs.

Only verification.scriptCompilation may become VERIFIED_SUCCESS or VERIFIED_FAILURE. Keep all of these as NOT_VERIFIED:

- verification.tests
- verification.playerBuild
- verification.playMode
- verification.runtime

If the result is ORIGINAL_PROJECT_CHANGED, stop immediately, report the exact added, removed, or changed paths from the JSON, and do not modify the original project.

## Report

Return a concise summary containing:

1. Final status.
2. Doctor acceptance and preserved warning count.
3. Detected Unity version, signer subject, certificate thumbprint, executable SHA-256, and the exact isolated project path.
4. Unity exit code, timeout/termination/process-tree evidence, and Editor.log classification.
5. Original-project integrity result.
6. Tests, Player Build, PlayMode, and runtime as NOT_VERIFIED.
7. Artifact and result paths.

Do not claim test, build, PlayMode, runtime, gameplay, or release readiness.
