# fgltest

A modern functional-test harness for Genero BDL applications, built on the
supported **GGC** (Genero Ghost Client) engine. It keeps GGC's protocol engine —
it drives a real application over the front-end protocol and inspects the AUI
tree — and replaces GGC's thin ergonomics with:

- a **CLI runner** (`fgltest`) with a JSON config, automatic GGC scenario-server management, optional process-per-test isolation, and suite auto-discovery;
- **two authoring modes** — a fluent, typed BDL API *and* declarative JSON action files (no compile step);
- **industry-standard reports** — JUnit XML (with timings, and `<error>` distinct from `<failure>`), TAP, and JSON (plus a readable console);
- **setup/teardown hooks** — `beforeAll` / `afterAll` / `beforeEach` / `afterEach`;
- a **discoverable, typed API** — interaction verbs, string/numeric/regex/collection matchers, and table/list cell access;
- **`skip` / `only`** focus controls and per-suite **timeouts**;
- **fault isolation** — a mistyped field, table or action name fails *that test* and the run continues, instead of taking the whole suite down (see [Fault isolation](#fault-isolation)); and
- first-class **AUI-tree introspection** — list every available action, list enabled/visible/editable fields, straight from the running UI.

Delivered as an `fglpkg` package (see `fglpkg.json`); library modules live in
the package **`com.fourjs.fgltest`**. For a step-by-step walkthrough see
[USERGUIDE.md](USERGUIDE.md); for release history see [CHANGELOG.md](CHANGELOG.md).

## Requirements

- Genero BDL **6.x** (`fglcomp`, `fglform`, `fglrun` on `PATH`).
- The **GGC toolkit** shipped with the Genero installation
  (`$FGLDIR/testing_utilities/ggc`): source its `envggc` so `ggc.jar` is on
  `CLASSPATH`, `ggc.42m` is on `FGLLDPATH`, and `ggcadmin` is on `PATH`.
- A Java runtime for the GGC engine.
- GNU `make`.

## Build

```
make          # builds com/fourjs/fgltest/*.42m (library + the fgltest and
              # fgltest_json programs), the bundled example, and the self-tests
make check    # runs fgltest's own test suite (no GGC engine needed)
make test     # runs the bundled example suites end to end (needs GGC)
make lint     # validates fglpkg.json exactly as pack/publish would
make clean
```

Everything compiles into `com/fourjs/fgltest/` (the package directory). The build
needs the package root — the directory that contains `com/` — on `FGLLDPATH`; the
`Makefile` sets that automatically. Ensure the Genero + GGC environment is active
first.

## Write a suite

A suite is a normal `.4gl` program. Import the modules from the
`com.fourjs.fgltest` package (calls use the short module name — `runner`, `flow`,
…), register tests and hooks, then call `runner.run()`:

```4gl
IMPORT FGL com.fourjs.fgltest.runner
IMPORT FGL com.fourjs.fgltest.flow
IMPORT FGL com.fourjs.fgltest.expect
IMPORT FGL com.fourjs.fgltest.inspect

MAIN
    CALL runner.setApplication("price")
    CALL runner.beforeEach(FUNCTION settle)
    CALL runner.test("shows edit and cancel actions", FUNCTION t_actions)
    CALL runner.run()
END MAIN

FUNCTION settle()
    CALL flow.pause(100)
END FUNCTION

FUNCTION t_actions()
    CALL expect.all(inspect.activeActionNames()).toContain("edit")
    CALL expect.all(inspect.enabledFields()).toContain("formonly.price")
END FUNCTION
```

## Write a suite (declarative JSON — no compile)

For the common "drive + assert" tests you can skip BDL entirely and author an
**action file**: a JSON list of steps, each a `command` with an optional `target`
(a field/action/key name) and `value`. This is the established keyword-driven
model (Selenium IDE's `command`/`target`/`value`); a shipped generic runner
(`com/fourjs/fgltest/fgltest_json`) interprets any action file by dispatching each command to
the same `flow`/`expect`/`inspect` verbs — so there is nothing new to learn and
nothing to compile.

```json
{
  "application": "price",
  "beforeEach": [ { "command": "pause", "value": "100" } ],
  "afterAll":   [ { "command": "action", "target": "cancel" } ],
  "tests": [
    {
      "name": "edits a price",
      "steps": [
        { "command": "action",      "target": "edit" },
        { "command": "fill",        "target": "formonly.price", "value": "9.99" },
        { "command": "action",      "target": "accept" },
        { "command": "assertField", "target": "formonly.price", "value": "9.99" }
      ]
    },
    {
      "name": "shows edit and cancel actions",
      "steps": [
        { "command": "assertActionActive", "target": "edit" },
        { "command": "assertActionActive", "target": "cancel" }
      ]
    }
  ]
}
```

`beforeAll` / `beforeEach` / `afterEach` / `afterAll` are optional step-lists.
Command vocabulary (each maps 1:1 to an existing verb):

| Interaction | Args | Assertion | Args |
|-------------|------|-----------|------|
| `action` | `target` | `assertField` / `assertFieldNot` | `target`, `value` |
| `field` | `target` | `assertCurrent` | `value` |
| `enter` | `value` | `assertFormName` / `assertFormTitle` | `value` |
| `fill` | `target`, `value` | `assertWindowName` | `value` |
| `clear` | — | `assertActionActive` / `assertActionInactive` | `target` |
| `key` | `target` | `assertActionExists` / `assertActionMissing` | `target` |
| `pause` | `value` (ms) | `assertFieldEnabled` / `assertFieldEditable` / `assertFieldExists` | `target` |
| | | `assertFieldCount` | `value` (n) |

Tables/lists (the `target` is the table name from `inspect.tables()`):

| Interaction | Args | Assertion | Args |
|-------------|------|-----------|------|
| `selectRow` | `target`, `row` | `assertCell` (current row) | `target`, `column`, `value` |
| `focusCell` | `target`, `column`, `row` | `assertCellAtRow` (navigates) | `target`, `column`, `row`, `value` |
| | | `assertRowCount` / `assertCurrentRow` | `target`, `value` |

Rows are 1-based. A cell read only sees a **loaded** row, so `assertCell` targets
the **current** row (always loaded) while `assertCellAtRow` navigates to `row`
first — use it, or a `selectRow` step, to reach a non-visible row.

An unknown command fails the test (never silently passes). Complex tests
(loops, computed data, DB setup) still use the compiled BDL API above — both
modes share the same engine, hooks, reporters, and CI exit code.

## Configure and run

`fgltest.json` lists the suites and how to reach each application. A suite names
either a compiled `module` **or** a JSON `actions` file:

```json
{
  "port": 6500,
  "reporters": "console,junit,tap,json",
  "outdir": "results",
  "suites": [
    {
      "name": "price",
      "module": "examples/price/price_test",
      "mode": "tcp",
      "workdir": "examples/price",
      "commandLine": "fglrun price"
    },
    {
      "name": "price-json",
      "actions": "examples/price/price.actions.json",
      "mode": "tcp",
      "workdir": "examples/price",
      "commandLine": "fglrun price"
    }
  ]
}
```

- `mode` — `tcp` launches the app via `commandLine` in `workdir`; `ua` drives a
  GAS-deployed app via `url`.
- `module` vs `actions` — a suite uses one: `module` runs a compiled suite;
  `actions` runs a JSON action file via the generic runner (overridable with the
  top-level `jsonRunner`, default `com/fourjs/fgltest/fgltest_json`).

**Isolate — a process per test.** By default a suite's tests share one engine
session (fast). Set `"isolate": true` (top-level, or per-suite) to run each test
in its own subprocess, so a test that crashes or hangs the app can't affect the
others. Each isolated test writes its own report files (`<suite>.<n>.junit.xml`,
…) — CI aggregates them with a glob like `results/*.junit.xml`.

**Auto-discovery.** Instead of listing suites, point a top-level `discover` block
at a directory and the CLI finds them — `*.actions.json` become JSON suites, and
compiled modules ending in `modulePattern` (default `_test`) become compiled
suites, all sharing one connection template:

```json
{
  "outdir": "results",
  "isolate": true,
  "discover": {
    "dir": "examples/price",
    "mode": "tcp", "workdir": "examples/price", "commandLine": "fglrun price",
    "modulePattern": "_test"
  }
}
```

Discovered suites are appended to any explicit `suites[]`. (All discovered suites
share the one template, so use it for a directory of tests against the same app.)

Run all suites (from the package root, with that directory on `FGLLDPATH`):

```
export FGLLDPATH="$(pwd):$FGLLDPATH"
fglrun com/fourjs/fgltest/fgltest.42m            # uses ./fgltest.json
fglrun com/fourjs/fgltest/fgltest.42m my.json    # explicit config
```

The CLI starts the GGC scenario server, runs each suite, merges results, writes
reports to `outdir/`, prints an aggregate summary, and exits non-zero if any test
failed. Per-suite console output (and raw engine logs) go to `outdir/<name>.log`.

Run a single suite directly (server must already be running via
`ggcadmin startbdlserver -p 6500`):

```
fglrun examples/price/price_test tcp --working-directory examples/price --command-line "fglrun price"
```

Run a JSON action file directly (its path comes via `FGLTEST_ACTIONS`, since
`ggc` parses the `tcp`/`ua` argv itself):

```
FGLTEST_ACTIONS=examples/price/price.actions.json \
  fglrun com/fourjs/fgltest/fgltest_json tcp --working-directory examples/price --command-line "fglrun price"
```

## Reports

Selected via the config `reporters` list (or the `FGLTEST_REPORTERS` env var for a
direct run), written to `outdir/`:

- `console` — readable pass/fail with failure detail (always on for direct runs).
- `<name>.junit.xml` — JUnit XML for CI (Jenkins, GitLab, GitHub Actions, …), with
  per-test `time`, a suite `timestamp`, `<skipped/>`, and `<error>` (a test that
  could not run) reported separately from `<failure>` (an assertion that did not hold).
- `<name>.tap` — Test Anything Protocol v13, with `# SKIP` / `# ERROR` directives.
- `<name>.json` — structured results, including `errors`, `skipped` and durations.
- `fgltest.summary.json` — the CLI's merged aggregate.

Reports are written **after every test**, so a run cut short by a crashing or
closing application still leaves the results gathered so far on disk.

## API

All library modules are in the package `com.fourjs.fgltest`
(`IMPORT FGL com.fourjs.fgltest.<module>`); qualified calls use the short module
name shown below.

| Module | Purpose | Highlights |
|--------|---------|-----------|
| `runner` | test model + orchestration | `setApplication`, `test`, `testSkip`, `testOnly`, `beforeAll/afterAll/beforeEach/afterEach`, `run` |
| `flow` | interaction verbs | `field`, `enter`, `fill`, `clear`, `action`, `press`, `pause`, `selectRow`, `focusCell` |
| `expect` | assertions | **strings** `expect.that(v).toEqual/notToEqual/toBeEmpty/notToBeEmpty/toContainText/notToContainText/toStartWith/toEndWith/toMatch/notToMatch`<br>**numbers** `expect.num(n).toEqual/notToEqual/toBeGreaterThan/toBeLessThan/toBeAtLeast/toBeAtMost/toBeBetween`<br>**booleans** `expect.bool(b).toBeTrue/toBeFalse`<br>**collections** `expect.all(list).toContain/notToContain/toContainMatch/toHaveSize/toBeEmpty/notToBeEmpty` |
| `inspect` | AUI introspection | `actions`, `activeActionNames`, `actionNames`, `hasAction`, `fields`, `fieldNames`, `enabledFields`, `editableFields`, `formName`, `windowName`, `tables`, `rowCount`, `currentRow`, `cellValue`, `currentCellValue` |
| `script` | declarative JSON tests | `load` (parses **and validates**), `exec` (command dispatcher over `flow`/`expect`/`inspect`); backs the `fgltest_json` runner |
| `driver` | interaction seam | `Driver` INTERFACE (default impl `ggcdriver`); a jar-backed driver can be added without touching suites |

## How it works

```
suite.4gl ── IMPORT FGL com.fourjs.fgltest.* ──► runner.run()
                                        │ registers one GGC scenario
        fgltest CLI ── ggcadmin server ─┤ (owns start/stop)
                                        ▼
                     GGC engine ── front-end protocol ──► application under test
```

Interaction and introspection go through the `Driver` seam to the GGC engine.
Assertions record outcomes; the runner reports them and forwards failures so the
process exit code is CI-correct.

## Fault isolation

GGC's own error handling ends the process on *any* bad parameter: internally it
answers a mistyped field, table or action name with `EXIT PROGRAM`, which no
`TRY/CATCH` or `WHENEVER` can trap. A single typo would therefore abandon the
whole run and write no reports at all.

fgltest puts the engine into non-fatal mode and inspects the status after every
interaction, so an unusable target is reported as an **errored test** and the run
carries on:

```
  ok    1 - shows edit and cancel actions (2 checks, 0.11s)
  ERROR 2 - edits a price (could not run to completion)
         - driver error: (GGC-7) FormField or Table named 'formonly.pirce' not found. [focus 'formonly.pirce']
  ok    3 - lists three fields incl. price (2 checks, 0.31s)
```

Once a test has errored, the rest of *that* test is skipped: its remaining verbs
and matchers short-circuit, so you get the one root cause rather than a cascade
of consequences. State is reset for the next test.

The one unrecoverable case is the application under test going away
(`GGC-17 CLOSED`). The runner then stops scheduling, marks the remaining tests
as not-run, and still writes the reports.

## Timeouts

Set `timeout` (seconds) globally or per suite to bound a run:

```json
{ "timeout": 120, "suites": [ { "name": "slow", "timeout": 600, "...": "" } ] }
```

Two mechanisms cooperate:

- The **suite's own budget** — before each test the runner checks the elapsed
  time and, once past the budget, stops scheduling, marks the remainder errored
  and writes full reports. This is the good outcome and handles a slow or looping
  suite.
- The **CLI watchdog** — a last resort for a genuinely wedged process. BDL's
  `RUN` exposes no PID and no timed wait, so the CLI polls for the completion
  marker the runner drops, and on expiry restarts the scenario server, which
  releases a child blocked on its socket.

Leave `timeout` unset (the default) and the CLI waits for each suite directly,
which reports a crash immediately; with it set, a suite that dies without
completing costs the full timeout before the watchdog concludes.

## Contributing

fgltest has its own test suite:

```
make check
```

It runs against a **fake driver** — the `Driver` INTERFACE seam means the AUI
parsing, matchers, reporters and action-file interpreter are all exercised with
no GGC engine, no scenario server and no application under test, so it runs
anywhere the compiler does. `.github/workflows/ci.yml` gates on it.

Add a test alongside any change; `tests/selftest.4gl` is a plain program with a
small assertion helper at the top.

## Notes

- Field/action names in `inspect` come from the AUI `name` attribute
  (e.g. `formonly.price`). Table **columns** are addressed by their plain
  `colName` (e.g. `price`); read cell values with `inspect.cellValue` /
  `currentCellValue` (or the `assertCell` / `assertCellAtRow` steps), navigating
  to a non-visible row first with `flow.selectRow`.
- The harness runs a suite's tests in one engine session (unless `isolate` is
  set); use `afterEach` to reset UI/data state between tests when a test navigates.
- `runner.testSkip` / `runner.testOnly` (and `"skip"` / `"only"` on a JSON test)
  control which tests run. If any test is marked `only`, every other test is
  skipped — handy while debugging one failure.
- `expect.that()` compares strings, where BDL treats `""` and NULL as equal. Use
  `expect.num()` for counts and amounts so `5` and `5.0` cannot differ, and
  `toMatch` for regular expressions (unanchored — use `^...$` for a whole-value
  match).
- Action files are validated when they load: an unknown command or a missing
  `target`/`value` is reported before any application is started, listing every
  problem at once.

## Roadmap

- **Jar-backed `Driver`** — an alternate `Driver` implementation that talks to
  `ggc.jar` in-process (no separate scenario server) via Java interop. The
  `Driver` INTERFACE already supports swapping the backend without touching
  suites; this is deferred as it duplicates the existing engine path for no new
  capability.
