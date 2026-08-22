---
name: unity-editmode-verification
description: "Run only Unity Project Doctor-confirmed EditMode test assemblies against the same isolated project copy produced by a fresh successful Unity Baseline Verification. Use only when the user explicitly invokes $unity-editmode-verification; never infer it from an ordinary Unity testing request."
---

# Unity EditMode Verification 0.1.0

Use the bundled PowerShell entrypoint as the sole source of EditMode verification truth. It creates fresh Doctor and Script Compilation evidence through the sibling Baseline component, reuses that accepted external isolation copy, and starts the exact signed Unity editor only for confirmed EditMode test assemblies.

## Require explicit invocation

- Require the literal name `$unity-editmode-verification` in the user's request.
- Never run from implicit intent or as an automatic continuation of Doctor, Baseline, code review, or an ordinary Unity question.
- Do not reinterpret an earlier chat report or saved Baseline artifact as a new run. The entrypoint creates a fresh Baseline receipt for the exact current source state.
- Do not invoke the `$unity-project-doctor` or `$unity-baseline-verification` Skills. The trusted entrypoint calls the bundled sibling Baseline script directly as a pipeline component.

## Run the deterministic entrypoint

From the exact Unity project root, resolve the script relative to this `SKILL.md` and run:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <skill-root>\scripts\invoke-unity-editmode-verification.ps1 `
  -ProjectRoot <absolute-current-working-directory> `
  -Pretty
~~~

Apply `ExecutionPolicy Bypass` only to this child process. Do not change user or machine policy. An explicit user-confirmed exact `Unity.exe` path may be supplied with `-UnityExecutable` when normal Baseline discovery cannot find Unity `6000.0.69f1`.

## Preserve the safety contract

- Treat the original project as fully read-only. Never pass it to Unity or create a file, log, cache, report, package, test, or setting in it.
- Do not start Unity Hub, install or update Unity, install a package or module, run a Player Build, enter PlayMode, start a player, or perform runtime automation.
- Do not add, generate, repair, migrate, or modify tests. Run only assembly names backed by Doctor `confirmedTestAssemblies` evidence.
- Treat Doctor confirmation only as direct asmdef declaration evidence. It does not prove that Unity imported the asmdef or built its DLL.
- Never run candidate-only test assemblies. A test-like path or name is not direct test evidence.
- Reuse the exact Baseline isolation copy. Do not copy the project again or mutate the original to prepare tests.
- Require the current source, Doctor receipt, and Baseline pre-Unity copy fingerprint to remain exact. In the reusable post-Unity isolation, accept only a structured delta limited to project-root `*.sln`, `*.csproj`, and `*.csproj.user` IDE files; any directory, nested IDE-like file, or other file delta remains blocking.
- Before the EditMode Unity process starts, require a non-empty `Library/ScriptAssemblies/<assembly-name>.dll` for every selected assembly in the accepted Baseline isolation. Missing or unreadable DLL evidence is blocking, not an empty test run.
- Keep all EditMode XML, logs, streams, and JSON under the external artifact session reported by the script.
- Never add a signature bypass, test mode, safety-disable environment variable, or alternate executable launcher.
- Preserve `playMode`, `playerBuild`, and `runtime` as `NOT_VERIFIED`.

## Treat JSON as the source of truth

- Require exactly one JSON document on stdout. Diagnostics belong to stderr.
- Require result `schemaVersion: 1.0.0` and `verifierVersion: 0.1.0` before interpreting fields.
- Preserve Baseline and Doctor warnings, Baseline failure/process-cleanup diagnostics, selected assembly declaration and DLL evidence, NUnit counts, logs, blockers, failures, integrity evidence, and `finalStatus` without promotion or deletion.
- Do not infer success from exit code alone. `EDITMODE_VERIFIED` requires valid NUnit XML with at least one passed test, zero failed/error/inconclusive tests, a safe Editor.log, exit code 0, proven process-tree exit, and unchanged original content and Git metadata.
- Skipped tests remain visible warnings. They do not become failures when at least one test passed and no failed/error/inconclusive test exists.
- If the scanner finds no confirmed test assembly, preserve `NO_CONFIRMED_TEST_ASSEMBLY`; do not run candidate assemblies or report a pass.
- If a selected DLL was not built, preserve `TEST_ASSEMBLY_NOT_BUILT` under `EDITMODE_BLOCKED` and do not start the EditMode Unity process.
- If NUnit reports zero discovered tests after the selected DLL was proven, preserve `NO_DISCOVERED_TEST_CASES` under `EDITMODE_BLOCKED`; do not describe it as a test pass.
- Preserve raw source and isolation SHA-256 values, `fingerprintBindingClassification`, and the complete structured `fingerprintDelta`. Do not report raw fingerprint equality when only the narrow root-IDE projection matched.
- If Baseline, Doctor, executable trust, source-editor association, fingerprint binding, process control, XML, log, or integrity evidence is unavailable or contradictory, preserve the blocking status.

## Report the result narrowly

Summarize the exact Unity version, Baseline and Doctor contracts, selected confirmed assemblies, NUnit counts, process-tree evidence, original integrity, warnings, and artifact paths. State that Script Compilation and selected EditMode tests are the only potentially verified scopes.

End with exactly:

~~~text
FINAL_STATUS: <scanner finalStatus>
~~~

Allowed statuses and meanings:

| finalStatus | Meaning |
| --- | --- |
| `EDITMODE_VERIFIED` | The selected confirmed EditMode tests have complete positive evidence |
| `EDITMODE_FAILED` | Complete evidence contains a concrete test, compiler, package, crash, or fatal failure |
| `NO_CONFIRMED_TEST_ASSEMBLY` | Doctor supplied no directly confirmed test assembly, so no EditMode test process was started |
| `EDITMODE_BLOCKED` | A safety, trust, completeness, timeout, or evidence prerequisite was not met |
| `ORIGINAL_PROJECT_CHANGED` | Original source content or disallowed Git metadata changed during the workflow |
