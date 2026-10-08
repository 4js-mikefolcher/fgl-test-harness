# Changelog

All notable changes to **fgltest** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._

## [1.1.0] - 2026-10-08

Hardening for distribution. A run can no longer pass when a suite crashed, was
killed or never started; the installed package works out of the box; config
and action-file mistakes are reported before anything runs; and every report
format is consistent and parseable. A few behaviours change for existing
users — config paths are relative to the config file, the JSON report's
`failed` no longer includes errors, and fgltest expands `$NAME` in config
values itself — see **Changed**.

### Fixed

- **A suite that dies part-way no longer passes.** The CLI judged a suite by its
  JSON report alone. A runtime error in test code (or anything else that
  stopped the process) left a report holding only the tests that had finished,
  and the run went green. Now:
  - the runner puts every selected test on the reports **before anything
    runs** (as *not run*), marks the running test *did not complete* while it
    runs, and rewrites the reports around each test. Whatever stops the
    process, the reports name the test it died in and every test it never
    reached;
  - the CLI requires the runner's `<name>.done` completion marker from every
    suite process (it was only consulted with a `timeout`). A process that
    ends without it is counted as **incomplete** and fails the run, even if
    every test that finished had passed;
  - a watchdog **timeout** now fails the run too (it used to be reported but
    leave the exit code at 0 when the partial results passed).
- **Results from an earlier run can no longer stand in for this one.** Before
  anything runs, the CLI deletes every suite's previous `<name>.json` /
  `.junit.xml` / `.tap` / `.done` and every old per-test `<name>.<n>.*`,
  whichever mode ran last; a file it cannot delete stops the run (exit 2). A
  suite whose module was missing used to report the previous run's passes and
  exit 0.
- **JSON suites work from an installed package.** The default `jsonRunner` was
  `com/fourjs/fgltest/fgltest_json` relative to the current directory, and
  `fglrun` never looks a program path up on `FGLLDPATH`, so every `actions`
  suite failed unless the CLI was started from the repository root. The
  default is now the `fgltest_json` program beside the CLI itself.
- **The `port` setting reaches the suites.** The CLI started the scenario
  server on the configured port but never told the suites, which connected to
  6500 regardless. Each suite now gets `--port`. An omitted `port` (which
  parses as NULL, not 0) now also falls back to 6500.
- Program paths in suite commands are quoted, so a path containing spaces
  works.
- **The action-file JSON Schema ships with the package**
  (`schema/action-file.schema.json`); it was only in the source repository.
- `.fglpkgignore` is committed. It was listed in `.gitignore`, so a fresh
  clone packed without it.
- **An application crash is charged to the test that caused it.** A Genero
  program that stops on a runtime error shows it in a message box and waits,
  and GGC keeps answering from the last screen — so the test that crashed the
  application could *pass*, and the crash surfaced later as an unrelated
  assertion failure. After every test and `beforeAll` / `afterAll` phase the
  runner now looks for the runtime's error box (new
  `inspect.applicationError()`); when it finds one it errors that test with the
  runtime's own message (`Program stopped at 'x.4gl', line number N. …`) and
  reports the remaining tests as not run.
- **`beforeAll` / `afterAll` failures are reported.** Their checks and driver
  errors used to be discarded, so a broken setup let every test run against it
  and a failed teardown went unnoticed. A failing `beforeAll` now gets a
  `beforeAll hook` entry and the tests are reported `not run: the beforeAll
  hook failed`; `afterAll` still runs, and a failing one gets an `afterAll
  hook` entry. Runtime errors in these hooks are trapped like a test's. Once
  the application has ended, an `afterAll` hook's interactions with it are
  expected to fail and are not counted.
- **The CLI no longer stops a scenario server it did not start.** A server
  already listening on the port — a developer's own, or another run's — is
  reused and left running, and the timeout watchdog no longer restarts it.
- **Action files are checked for table, number and key mistakes.** A table
  command missing its `column` or `row`, a row below 1 or not a whole number
  (`"row": 1.5` was row 1), a count or delay that is not a whole number
  (`"value": "five"` silently became NULL), and an unknown key (`"skipp": true`
  ran the test) used to load cleanly. They are now reported at load with the
  other problems. Keys match without regard to case, as the JSON parser
  matches them, except `column` / `row` (exact, like the parser). The JSON
  Schema carries the same rules — test `steps` may not be empty, values may be
  strings or numbers, `$`/`_` keys are allowed — and a self-test keeps its
  per-command rules in step with the loader.
- **A test name used twice no longer runs twice.** Isolate mode selected tests
  by name, so two tests sharing one were each run (and counted) under both
  processes. An action file with a repeated name is now rejected at load; in a
  compiled suite the repeat is reported as an error and not run, and the CLI
  enumerates each name once.
- **The TAP diagnostic block is valid YAML.** It repeated a `message:` key per
  message and left values unquoted, so a message with a `:` or `#` broke
  strict consumers. It now has `severity`, `message` and a `messages` list, all
  quoted, with control characters (DEL included) dropped; a `#` in a test name
  is escaped so it is not read as a directive.
- **JUnit reports drop control characters XML forbids.** An ESC or form feed
  in an application's message made the whole report unparseable.
- **`fgltest.json` mistakes are reported instead of ignored.** A typo'd key was
  dropped silently by the JSON parser (`"comandLine"`: the suite then ran with
  no command line), and a wrongly typed value became NULL (`"timeout": "30s"`).
  The config is now checked before anything starts — unknown keys (matched
  without regard to case, as the parser does), wrongly typed values, suites
  without or reusing a name (their reports overwrote each other), a suite whose
  reports would overwrite the config or an action file (a suite named
  `fgltest` used to replace `fgltest.json`), reserved names, both or neither of
  `module` / `actions`, a missing module or action file, an unknown `mode` or
  reporter, `ua` without a `url`, a negative `timeout` — with every problem
  listed and exit code 2. A discovered suite whose name is taken, or whose
  reports would clash, is skipped with a note.
- **Values in suite commands are quoted properly.** The command line, working
  directory, URL and paths were wrapped in `"…"` unescaped: a `commandLine`
  with quotes of its own broke the suite command, and on Windows a `workdir`
  ending in `\` swallowed the closing quote. They are now quoted for the
  platform's shell (`core.shellArg`) and arrive exactly as written — quotes,
  backslashes, `$`, backticks and non-ASCII text alike. Note that GGC itself
  splits the command line at spaces without honouring quotes, so an
  application argument still cannot contain a space.
- **`inspect.fields()` and `inspect.tables()` read the current window only.**
  They searched the whole AUI tree, which keeps every open window, so inside a
  modal child window they also returned the parent's fields and tables
  (`assertFieldCount`, `assertFieldMissing`, `assertFieldExists`, …, were
  affected the same way).

### Changed

- **Relative paths in `fgltest.json` resolve against the config file's
  directory**, not the current one: `outdir`, `jsonRunner`, each suite's
  `module` / `actions` / `workdir`, and `discover.dir` / `discover.workdir`.
  `outdir` defaults to the config's directory. A config at the project root
  run from the project root behaves exactly as before; this is what lets
  `fglpkg bdl 4js-fgltest fgltest "$PWD/fgltest.json"` work, since fglpkg
  starts programs inside the installed package.
- **Runtime errors in tests can be trapped per test.** A test or
  `beforeEach`/`afterEach` hook whose module declares `WHENEVER ANY ERROR RAISE`
  now errors just that test (`runtime error -8083: …`), still runs its
  `afterEach`, and lets the suite carry on. Without the opt-in BDL stops the
  program, which the write-ahead reports above account for.
- A skipped test stays *skipped* when a run is cut short (it used to be
  re-reported as errored-not-run).
- **The JSON report's `failed` no longer includes errored tests.** `passed`,
  `failed`, `errors` and `skipped` are now disjoint and add up to `tests`, as in
  JUnit and in `fgltest.summary.json` (which already counted this way). Anyone
  reading `<name>.json` and subtracting `errors` from `failed` should stop.
- A `tcp` suite without a `workdir` runs its application in the config's
  directory, and an empty `commandLine` is left out so GGC applies its default
  (`fglrun <application>`).
- `"reporters"` tolerates spaces (`"console, junit"`).
- The manifest's Genero range is `^6.0.0` (was `>=6.0.0`): the shipped `.42m`
  files are built for Genero 6, so a future 7.x is not claimed.
- **The application ending stops the run at once.** GGC's
  `GGC-12 The scenario has already ended` is now treated like a closed
  session: the test that hit it errors and the remaining tests are reported
  `not run: the application under test ended`, instead of each one erroring on
  its first interaction. (Other `ILLEGAL_STATE` reports, such as a DVM still
  processing, only error the test that hit them.)
- **`$NAME` and `${NAME}` in config values are expanded by fgltest**, in paths,
  command lines and URLs, the same way on every platform (`$$` for a literal
  `$`), and an unset variable is a config error. Before, the POSIX shell
  expanded `$VAR` in a `commandLine` (an unset one became empty), not at all on
  Windows, and not in a `module` or `workdir` once they were quoted.
- A `port` of 0 or below is an error; only an absent `port` defaults to 6500.
- The failure note forwarded to GGC for an errored test gives its cause
  instead of `0/0 checks failed`.

### Added

- `runner.runWith(driver)` — run the registered tests against any `Driver`
  with no GGC session.
- `inspect.applicationError()` — the runtime error the application under test
  stopped with, or NULL.
- `FGLTEST_PORT` — overrides the config's `port`, so concurrent runs on one
  machine can each use their own scenario server; an invalid value (or an
  out-of-range `port`) is a setup error (exit 2).
- `script.requirements(command)` / `script.commands()` — the action-file
  command table, for tooling. `core.shellArg(s)` / `core.quoteArg(s, windows)`
  — quote one argument for a command run with `RUN`.
- `cli.expandEnv(s)`; `core.checkShape(b, o, where, spec)` / `core.jsonKey()` /
  `core.problem()` — the JSON shape checks both validators use;
  `ggcdriver.sessionOver(code, msg)` — which GGC statuses end the session.
- `make check` runs the self-tests under both `FGL_LENGTH_SEMANTICS=BYTE` (the
  default) and `CHAR`.
- `server.ensure(port, idle, timeout)` — starts a scenario server only if none
  is listening, and says whether it did. `driver.CURRENT_WINDOW` — the
  `auiPart()` selector for the current window.
- `incomplete` in `fgltest.summary.json`: suite processes that ended without
  completing.
- Install and run instructions for the fglpkg package (README "Install",
  USERGUIDE §3.1 and §6.2).
- Self-tests for the CLI's config handling, suite command, result folding and
  stale-file cleanup (a new `cli` module holds that logic); for window-scoped
  introspection, crash detection and server ownership; and, through
  `tests/runnersuite.4gl` run as a subprocess, for a suite process that dies
  part-way, trapped runtime errors, failing hooks and a crashed application.

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

[Unreleased]: https://github.com/4js-mikefolcher/fgl-test-harness/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/4js-mikefolcher/fgl-test-harness/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/4js-mikefolcher/fgl-test-harness/compare/v0.3.0...v1.0.0
[0.3.0]: https://github.com/4js-mikefolcher/fgl-test-harness/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/4js-mikefolcher/fgl-test-harness/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/4js-mikefolcher/fgl-test-harness/releases/tag/v0.1.0
