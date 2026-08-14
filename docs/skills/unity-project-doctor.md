# Unity Project Doctor 0.2.1

Unity Project Doctor is an explicit-only, read-only static audit. It never starts Unity, Unity Hub, tests, builds, players, or project-discovered executables. Its stdout is exactly one JSON document, and all dynamic scopes remain `NOT_VERIFIED`.

## Contract versions

| Scanner | schemaVersion | Schema file | Meaning |
| --- | --- | --- | --- |
| 0.2.0 | 1.0.0 | `schemas/unity-project-audit.schema.json` | Frozen original static-audit contract |
| 0.2.1 | 1.1.0 | `schemas/unity-project-audit-1.1.0.schema.json` | Static audit plus Baseline copy-set fingerprint |

The 1.0.0 schema file remains unchanged. Saved 1.0.0 results remain valid when interpreted with that frozen file, but they have no content fingerprint and cannot authorize Unity Baseline Verification 0.1.1.

Scanner 0.2.1 emits schema 1.1.0. The new schema is a separate Draft 2020-12 document. It references the frozen definitions locally and adds the required `projectFingerprint` object.

## Project fingerprint

For a detected Unity project, the scanner computes two consecutive read-only snapshots over exactly the file set copied by Baseline. Generated, version-control, IDE, agent, cache, log, build-output, and user-settings top-level trees are excluded.

The canonical digest uses ordinal relative-path ordering and SHA-256 over directory records and file path/length/hash records. The result records:

- `contractVersion`;
- `status`;
- `algorithm`;
- `canonicalization`;
- `excludedTopLevelPaths`;
- directory and file counts;
- `treeSha256`;
- `stabilityPasses`;
- an error only when computation is blocked.

No fingerprint file, cache, or temporary output is written under the project. Reparse points in the copy-included set or changing content block fingerprint computation and therefore produce `AUDIT_BLOCKED`.

## Migration for consumers

- Select the schema by the exact `schemaVersion`; never guess.
- Validate the complete document before interpreting nested fields.
- Continue to accept saved schema 1.0.0 only as legacy static-audit evidence.
- Require schema 1.1.0/scanner 0.2.1 and a `COMPUTED` fingerprint for Baseline 0.1.1.
- Never promote warnings, blocked checks, missing fields, or unknown versions to success.
- Keep compilation, tests, build, and runtime `NOT_VERIFIED`.

## Run

~~~powershell
$scanner = "E:\Playground\Pipelines\unity_agent_pipeline\skills\codex\unity-project-doctor\scripts\inspect-unity-project.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scanner -ProjectRoot "E:\Unity\ExampleProject" -Pretty
~~~

Store any captured JSON outside the Unity project. The scanner itself creates no output file.
