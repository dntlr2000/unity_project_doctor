---
name: unity-test-scaffold
description: "Plan and, only after hash-bound user confirmation, create the minimal Unity Runtime and EditMode test asmdef scaffold without overwriting project files. Use only when the user explicitly invokes $unity-test-scaffold; never infer permission to modify a Unity project from an ordinary testing request."
---

# Unity Test Scaffold 0.1.0

Use the bundled deterministic PowerShell entrypoint to prepare the assembly-definition structure required for meaningful EditMode tests. This Skill is intentionally separate from the read-only Doctor and verification Skills because an approved APPLY changes the Unity project.

## Require explicit invocation

- Require the literal name `$unity-test-scaffold` in the user's request.
- Never run from implicit intent, `NO_CONFIRMED_TEST_ASSEMBLY`, a Doctor warning, or an ordinary request to test Unity code.
- Never treat a request to inspect, verify, explain, or diagnose as permission to create project files.
- Do not invoke Doctor, Baseline, or EditMode Skills automatically after applying the scaffold. Recommend their explicit calls as separate follow-up gates.

## Always produce a plan first

From the exact Unity project root, resolve the script relative to this `SKILL.md` and run without `-Apply`:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <skill-root>\scripts\invoke-unity-test-scaffold.ps1 `
  -ProjectRoot <absolute-current-working-directory> `
  -Pretty
~~~

The default invocation is read-only. It may infer a Runtime source root only when exactly one included directory segment named `Runtime` contains C# source. Otherwise rerun the plan with a user-reviewed in-project path:

~~~powershell
-RuntimeSourceRoot <Assets-relative-or-absolute-path>
~~~

Optional assembly and test-root overrides are `-RuntimeAssemblyName`, `-TestRoot`, and `-TestAssemblyName`. Preserve the same overrides between PLAN and APPLY.

## Require hash-bound confirmation before applying

- Treat the plan JSON as the source of truth. Show the user every planned directory, file path, file content, warning, and `planSha256`.
- Explain that a new runtime asmdef changes Unity assembly boundaries and may reveal missing references during the next compilation.
- Do not apply in the same turn that first reveals a new plan unless the user had already supplied the exact current `planSha256` and explicitly requested APPLY.
- After the user explicitly confirms the exact hash, rerun with the same root and overrides:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <skill-root>\scripts\invoke-unity-test-scaffold.ps1 `
  -ProjectRoot <absolute-current-working-directory> `
  -Apply `
  -ExpectedPlanSha256 <reviewed-plan-sha256> `
  -Pretty
~~~

- Never invent, truncate, normalize, or substitute the confirmation hash. A changed project or changed option must produce a new plan for review.

## Preserve the mutation boundary

- The entrypoint may create only the plan-declared Runtime asmdef, Editor-only EditMode test asmdef, required new directories, and their Unity `.meta` files.
- Serialize generated `.meta` files as UTF-8 without BOM, LF-only, with exactly one terminal LF. The planned content and hash must bind those exact bytes.
- Never overwrite, edit, rename, or delete an existing project file. A collision is a blocker.
- Never create a passing placeholder test. The user must add meaningful test code after the assembly structure exists.
- Never modify `Packages/manifest.json`; when `com.unity.test-framework` is not directly declared, block and report that package setup remains manual.
- Do not infer or add Runtime asmdef package/assembly references. Missing references exposed by the next Baseline run require a project-specific, user-reviewed source change.
- Never run Unity, Unity Hub, compilation, tests, PlayMode, Player Build, a player, project scripts, hooks, or executables.
- Never install Unity, a package, a PowerShell module, or an external test framework.
- Never follow a reparse point, junction, or symbolic link, and never write outside the exact project root.
- On a partial write failure, remove only exact entries created by that transaction. Do not delete pre-existing paths or attempt a broad rollback.

## Treat JSON as the source of truth

- Require exactly one JSON document on stdout; diagnostics belong to stderr.
- Require `schemaVersion: 1.0.0` and `scaffoldVersion: 0.1.0` before interpreting fields.
- Preserve plan contents, warnings, blockers, fingerprints, delta, rollback evidence, and `finalStatus` without promotion or deletion.
- Never claim compilation or EditMode success. All dynamic verification fields remain `NOT_VERIFIED`.
- `SCAFFOLD_APPLIED` means only that the exact reviewed additions were created and the postcondition delta matched; it does not mean Unity accepted or compiled them.

## Report the result narrowly

For PLAN, report the inferred or explicit roots, assembly names, every planned path, content-changing warning, and exact confirmation hash. For APPLY, report exact created entries, postcondition evidence, and any rollback result.

End with exactly:

~~~text
FINAL_STATUS: <scaffold finalStatus>
~~~

Allowed statuses and meanings:

| finalStatus | Meaning |
| --- | --- |
| `SCAFFOLD_PLAN_READY` | A deterministic read-only plan is ready for explicit hash-bound review |
| `SCAFFOLD_APPLIED` | Only the confirmed planned additions and exact contents were created |
| `SCAFFOLD_ALREADY_CONFIGURED` | Compatible Runtime and EditMode test asmdefs already exist; nothing was written |
| `SCAFFOLD_BLOCKED` | Project detection, package, path, ambiguity, collision, plan confirmation, or transaction safety failed |
| `PROJECT_CHANGED_DURING_APPLY` | The postcondition was not exactly the planned delta or rollback could not prove restoration |
