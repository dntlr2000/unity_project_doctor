# Unity EditMode Verification 0.1.0

Unity EditMode Verification is an explicit-only pipeline component for selected Unity Test Framework EditMode assemblies. It first requires a fresh successful Baseline run, then reuses the same external isolation copy. It never opens the original Unity project in Unity.

## Current approval state

The component and deterministic fake/process/XML regressions are implemented under `Unreleased`. A signed Unity `6000.0.69f1` acceptance run has not been performed for this component, so this document does not claim real-Unity EditMode approval.

## One-command flow

~~~text
exact source root
→ bundled Baseline one-command run
→ Baseline schema 1.1.0 / verifier 0.1.3 handoff validation
→ referenced Doctor 1.1.0 / scanner 0.2.1 validation
→ Doctor-confirmed test assembly selection
→ source and reusable isolation fingerprint recheck
→ Unity.exe version, SHA-256 and Authenticode recheck
→ source-editor fail-closed preflight
→ same Baseline isolation copy + Unity Test Framework EditMode
→ NUnit XML + Editor.log + Job Object evidence
→ source and Git metadata post-check
~~~

The Baseline receipt is preserved byte-for-byte under the EditMode artifact session and hashed before interpretation. Candidate-only asmdef records are reported but never passed to Unity.

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

Only `assemblies.confirmedTestAssemblies` from the exact Doctor artifact referenced by Baseline are eligible. Each name must be unique and match the closed assembly-name grammar before all names are sorted and joined as one semicolon-delimited `-assemblyNames` value.

`candidateOnlyTestAssemblies` are not executable evidence. When the confirmed set is empty, the workflow stops without a second Unity process and returns `NO_CONFIRMED_TEST_ASSEMBLY`.

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
- current source and isolation copy-set fingerprints matching Doctor;
- at least one passed test;
- zero failed, error, and inconclusive tests;
- optional skipped tests recorded as warnings;
- exit code 0 and safe Editor.log markers;
- zero active processes after bounded Job Object wait;
- unchanged original copy-set and accepted Git metadata state.

Failure details are sorted and capped at 100 records with a truncation flag. Missing, malformed, inconsistent, or zero-test XML is blocking rather than successful.

## Deliberately unverified scope

- PlayMode tests
- Player Build
- player or scene runtime
- gameplay correctness
- performance, device input, visuals, and release readiness
- Unity versions other than exact `6000.0.69f1`

No automatic test generation, repair, package installation, source modification, cleanup, or rollback is implemented.
