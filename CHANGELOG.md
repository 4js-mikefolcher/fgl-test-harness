# Changelog

All notable changes to **fgltest** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._ Planned work is tracked in the README "Roadmap" section
(e.g. a jar-backed `Driver`).

## [1.0.0] - 2026-09-10

First stable release. The public API is now covered by semantic versioning.

### Fixed

- **A bad target name no longer destroys the run.** GGC's internal
  `checkStatus()` answers *any* bad parameter — a mistyped field, table or action
  name — with `EXIT PROGRAM`, which no `TRY/CATCH` or `WHENEVER` can trap. One
  typo therefore abandoned the whole suite and wrote **no reports at all**, so CI
  saw only "no results produced". The harness now puts the engine into non-fatal
  mode (`ggc.throwExceptions(FALSE)`) and inspects `ggc.statusCode` after every
  interaction, so an unusable target is reported as an **errored test**, naming
  the operation and the offending identifier, and the run continues.
- **TAP diagnostics and the suite exit code no longer depend on an unset
  boolean.** `NOT NULL` evaluates to NULL in BDL, which reads as false, so a
  record field that was never assigned silently took the wrong branch.
  Outcome flags are now always assigned, and negated reads go through
  `core.isTrue()`.
- Report writes no longer take the run down: an unwritable output directory is
  reported and the console results still stand.

### Added

- **Errored as an outcome distinct from failed.** An assertion that does not hold
  is a *failure*; a test that could not run is an *error*. JUnit emits
  `<failure>` vs `<error>` (with matching `failures=` / `errors=` counts), TAP
  marks `# ERROR`, and the JSON report carries `errored` and an `errors` total.
  Once a test errors, its remaining verbs and matchers short-circuit, so you get
  the root cause instead of a cascade.
- **`skip` / `only`.** `runner.testSkip` / `runner.testOnly` and
  `runner.testStepsSkip` / `testStepsOnly`, plus `"skip"` / `"only"` on a JSON
  test. Reported as `<skipped/>` (JUnit) and `# SKIP` (TAP); skips never fail a
  build.
- **Timeouts.** `timeout` (global or per suite) gives the runner a wall-clock
  budget — past it, remaining tests are marked errored and full reports are still
  written — backed by a CLI watchdog that restarts the scenario server to release
  a wedged process.
- **Matchers.** Strings gain `toContainText`, `notToContainText`, `toStartWith`,
  `toEndWith`, `toMatch`, `notToMatch`; new `expect.num()` (`toEqual`,
  `notToEqual`, `toBeGreaterThan`, `toBeLessThan`, `toBeAtLeast`, `toBeAtMost`,
  `toBeBetween`) compares numerically so `5` and `5.0` cannot differ; new
  `expect.bool()` (`toBeTrue`, `toBeFalse`); collections gain `toContainMatch`
  and `notToBeEmpty`.
- **Action-file commands** for the above, plus `assertWindowTitle`,
  `assertFieldDisabled`, `assertFieldReadOnly`, `assertFieldMissing` and
  `assertTableExists` — 38 in all.
- **Action files are validated on load**, before any application starts: unknown
  commands and missing `target` / `value` are reported together, with the test
  and step number. A JSON Schema for editor completion and validation ships in
  `schema/action-file.schema.json`.
- **Timings.** Per-test durations, surfaced as JUnit `time=` plus a suite
  `timestamp=`, in the JSON report, and on the console.
- **Reports are written after every test**, so a run cut short by a closing or
  crashing application still leaves the results gathered so far on disk.
- **`fgltest --help` / `--version`**, and an actionable diagnostic when the
  scenario server cannot start (it checks whether `ggcadmin` is on `PATH`).
- **fgltest's own test suite** — 165 assertions over the AUI parsing, matchers,
  reporters and action-file interpreter, run against a fake `Driver` with no GGC
  engine, no scenario server and no application: `make check`. Plus `make test`,
  `make lint`, and a GitHub Actions workflow.

### Changed

- **BREAKING (direct API users):** `reporters.writeFile()` now returns a `STRING`
  (NULL on success, else a message) rather than being void, so a failed write can
  be reported instead of aborting. `CALL reporters.writeFile(...)` must become
  `LET err = reporters.writeFile(...)`.
- `core.TestOutcome` gained `errored`, `skipped` and `duration`; the JSON report
  gained `errors`, `skipped` and `duration`. Existing consumers that read
  `tests` / `passed` / `failed` are unaffected — note that `failed` still counts
  errored tests, with `errors` the subset that could not run.
- The bundled example's deliberately-failing demo test is now registered with
  `testSkip`, so `make test` is green on a correct setup; flip it back to `test`
  to see failure reporting.

## [0.3.0] - 2026-07-13

First public release.

### Added

- **Table / list cell access.** New interaction verbs `flow.selectRow` and
  `flow.focusCell`, and introspection `inspect.tables`, `inspect.rowCount`,
  `inspect.currentRow`, `inspect.cellValue`, and `inspect.currentCellValue`.
- **Table commands for JSON action files:** `selectRow`, `focusCell`,
  `assertCell` (current row), `assertCellAtRow` (navigates to the row first),
  `assertRowCount`, and `assertCurrentRow` — adding optional `column` and `row`
  fields to a step.
- **`isolate` mode** (top-level or per-suite): run each test in its own
  subprocess for full crash/hang isolation. The CLI enumerates a suite's tests
  and runs each with `FGLTEST_ONLY`; each isolated test writes its own report
  files (`<suite>.<n>.*`) and counts are merged into the summary.
- **Auto-discovery:** a `discover` config block scans a directory and appends a
  suite for each `*.actions.json` (JSON suite) and each compiled
  `*<modulePattern>.42m` module (default pattern `_test`), all sharing one
  connection template.

### Notes

- Cell reads see only a *loaded* row: `assertCell` / `currentCellValue` read the
  always-loaded current row, while `assertCellAtRow` / `flow.selectRow` navigate
  (and load) a non-visible row first.

## [0.2.0] - 2026-07-08

### Added

- **Declarative JSON action files** — a second authoring mode using the
  established keyword-driven `command` / `target` / `value` model (à la Selenium
  IDE), run by the shipped generic program `fgltest_json`. Interaction commands
  (`action`, `field`, `enter`, `fill`, `clear`, `key`, `pause`) and assertion
  commands (`assertField`, `assertCurrent`, `assertFormName`, `assertFormTitle`,
  `assertWindowName`, `assertActionActive` / `assertActionInactive` /
  `assertActionExists` / `assertActionMissing`, `assertFieldEnabled` /
  `assertFieldEditable` / `assertFieldExists`, `assertFieldCount`). An unknown
  command fails the test rather than passing silently.
- `script` module (action-file loader + command dispatcher) and step-based
  registration on `runner` (`testSteps`, `beforeAllSteps`, `beforeEachSteps`,
  `afterEachSteps`, `afterAllSteps`).
- CLI: a suite may declare a JSON `actions` file instead of a compiled `module`;
  optional top-level `jsonRunner` override.

### Changed

- **BREAKING:** the library package was renamed `fgltest` →
  **`com.fourjs.fgltest`**, and sources plus compiled `.42m` were consolidated
  into the package directory `com/fourjs/fgltest/` (the two programs `fgltest`
  and `fgltest_json` compile there too). Suites now import
  `IMPORT FGL com.fourjs.fgltest.<module>`; qualified calls are unchanged.

### Fixed

- The per-suite report basename now honors `FGLTEST_NAME` (the suite's config
  name), so the CLI's result merge is correct even when the config name differs
  from the application name.

## [0.1.0] - 2026-07-07

### Added

- Initial harness, delivered as an `fglpkg` package and built on the supported
  GGC engine.
- **CLI runner** (`fgltest`) driven by `fgltest.json`, owning the GGC scenario
  server lifecycle (start once / stop once, robust to suite crashes).
- **Fluent, typed compiled BDL API:** `flow` interaction verbs, `expect` scalar
  and collection matchers, and `inspect` AUI-tree introspection (list actions,
  active actions, fields, enabled/editable fields, form/window names).
- **Setup/teardown hooks:** `beforeAll`, `afterAll`, `beforeEach`, `afterEach`.
- **Industry-standard reports:** console, JUnit XML, TAP v13, and JSON, plus an
  aggregate `fgltest.summary.json`. The process exit code reflects failures.
- **`Driver` INTERFACE** seam over `IMPORT FGL ggc` (default `ggcdriver`), so an
  alternate backend can be substituted without touching suites.

[Unreleased]: https://github.com/4js-mikefolcher/fgl-test-harness/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/4js-mikefolcher/fgl-test-harness/compare/v0.3.0...v1.0.0
[0.3.0]: https://github.com/4js-mikefolcher/fgl-test-harness/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/4js-mikefolcher/fgl-test-harness/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/4js-mikefolcher/fgl-test-harness/releases/tag/v0.1.0
