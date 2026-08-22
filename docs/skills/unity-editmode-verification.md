# Unity EditMode Verification 0.1.0

Unity EditMode Verification is an explicit-only pipeline component for selected Unity Test Framework EditMode assemblies. It first requires a fresh successful Baseline run, then reuses the same external isolation copy. It never opens the original Unity project in Unity.

## Current approval state

The component remains `Unreleased`. A 2026-08-22 precursor run on signed Unity `6000.0.69f1` executed four meaningful tests and recorded 4 passed, 0 failed, and unchanged original/Git state. Production hardening was added afterward, so that run is historical evidence only and is not final acceptance for the current revision. The exact post-hardening implementation still requires a new acceptance run after its implementation commit and Windows CI pass.

## One-command flow

~~~text
exact source root
→ bundled Baseline one-command run
→ Baseline schema 1.1.0 / verifier 0.1.3 handoff validation
→ referenced Doctor 1.1.0 / scanner 0.2.1 validation
→ Doctor-confirmed test assembly selection
→ exact source/receipt fingerprint and reusable isolation source-projection recheck
→ selected assembly DLL proof in Baseline Library/ScriptAssemblies
→ Unity.exe version, SHA-256 and Authenticode recheck
→ source-editor fail-closed preflight
→ same Baseline isolation copy + Unity Test Framework EditMode
→ NUnit XML + Editor.log + Job Object evidence
→ source and Git metadata post-check
~~~

The Baseline receipt is preserved byte-for-byte under the EditMode artifact session and hashed before interpretation. Its concrete compiler errors, failure markers, blockers, failures, and process-cleanup state are also summarized under `baseline.diagnostics` before narrow handoff validation, so a rejected Baseline does not collapse into a generic error. Candidate-only asmdef records are reported but never passed to Unity.

Baseline Unity may regenerate project-root solution metadata after the pre-Unity isolation fingerprint was captured. EditMode therefore preserves both raw hashes and accepts a post-Unity isolation mismatch only when the complete delta consists of root `*.sln`, `*.csproj`, or `*.csproj.user` files. It records added, removed, and changed paths with hashes under `isolation.fingerprintDelta`. Any directory delta, nested IDE-like path, `Assets`, `Packages`, `ProjectSettings`, or other file delta remains `FINGERPRINT_BINDING_FAILED`.

## Invocation

From an exact Unity project root, explicitly request:

~~~text
$unity-editmode-verification으로 현재 프로젝트의 확정된 EditMode 테스트를 검증해.
~~~

The Skill runs:

~~~powershell
$entrypoint = "<skill-root>\scripts\invoke-unity-editmode-verification.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entrypoint `
  -ProjectRoot (Get-Location).Path `
  -Pretty
~~~

The default artifact root is `%TEMP%\uev`. A GUID session keeps concurrent invocations separate. The Baseline component retains its own `%TEMP%\ubv` isolation and the EditMode component points Unity at the existing accepted `projectCopyPath`.

## Test selection

Only `assemblies.confirmedTestAssemblies` from the exact Doctor artifact referenced by Baseline are eligible. Doctor confirmation proves a direct test-asmdef declaration such as `optionalUnityReferences: ["TestAssemblies"]`; it does not prove that Unity imported or compiled the assembly. Each name must be unique and match the closed assembly-name grammar before all names are sorted and joined as one semicolon-delimited `-assemblyNames` value.

`candidateOnlyTestAssemblies` are not executable evidence. When the confirmed set is empty, the workflow stops without a second Unity process and returns `NO_CONFIRMED_TEST_ASSEMBLY`.

After Baseline and fingerprint acceptance, the preflight requires a non-empty `Library/ScriptAssemblies/<assembly-name>.dll` for every selected name. It records the absolute DLL path, byte length, and SHA-256. A missing DLL returns blocker `TEST_ASSEMBLY_NOT_BUILT` without starting a second Unity process; likely causes include asmdef or `.meta` import failure, platform/define constraints, or compilation failure.

## Fixed Unity arguments

The EditMode process receives only the fixed test-runner contract:

~~~text
-batchmode
-nographics
-runTests
-projectPath <accepted Baseline isolation>
-testPlatform EditMode
-assemblyNames <Doctor-confirmed names>
-testResults <external XML>
-logFile <external Editor.log>
-upmLogFile <external UPM log>
~~~

`-runSynchronously`, `-quit`, `-executeMethod`, `-accept-apiupdate`, and `-ignorecompilererrors` are forbidden. No Player Build or PlayMode argument is accepted.

## Evidence rules

NUnit XML is the direct test evidence. Editor.log, exact exit code, and Job Object accounting are mandatory supporting evidence. Exit code 0 alone is never success.

`EDITMODE_VERIFIED` requires:

- accepted fresh Baseline and Doctor receipts;
- exact Unity `6000.0.69f1` bytes and signer unchanged since Baseline;
- current source, Doctor, and Baseline pre-Unity fingerprints matching exactly;
- reusable isolation classified as `EXACT_MATCH` or `ROOT_IDE_GENERATED_FILES_ONLY`, with raw equality reported separately and every allowed delta recorded;
- every selected assembly represented by a non-empty DLL in the accepted Baseline isolation, with path, byte length, and SHA-256 preserved;
- at least one passed test;
- zero failed, error, and inconclusive tests;
- optional skipped tests recorded as warnings;
- exit code 0 and safe Editor.log markers;
- zero active processes after bounded Job Object wait;
- unchanged original copy-set and accepted Git metadata state.

Failure details are sorted and capped at 100 records with a truncation flag. Missing, malformed, or inconsistent XML remains `NUNIT_EVIDENCE_INCONCLUSIVE`. A valid NUnit document with zero discovered tests is distinguished as `NO_DISCOVERED_TEST_CASES`; neither result is successful.

Editor.log classification includes precise markers for malformed `.meta` YAML, invalid `.meta` GUIDs, and failed asmdef import. Unrelated licensing text is not treated as those failures. These diagnostics supplement, but never replace, the selected DLL and NUnit evidence gates.

## Deliberately unverified scope

- PlayMode tests
- Player Build
- player or scene runtime
- gameplay correctness
- performance, device input, visuals, and release readiness
- Unity versions other than exact `6000.0.69f1`

No automatic test generation, repair, package installation, source modification, cleanup, or rollback is implemented.
