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
- GNU `make` (only to build from source).

## Install

Add fgltest to your project with the Genero package manager — as a dev
dependency, since only your tests use it:

```
fglpkg install --save-dev 4js-fgltest
eval "$(fglpkg env)"                         # puts the package on FGLLDPATH
. "$FGLDIR/testing_utilities/ggc/envggc"     # the GGC engine, ggcadmin, ggc.42m
```

`IMPORT FGL com.fourjs.fgltest.*` then resolves, so your suites compile with a
plain `fglcomp -M`. Run the CLI either through fglpkg or directly from your
project root:

```
fglpkg bdl 4js-fgltest fgltest "$PWD/fgltest.json"
fglrun .fglpkg/packages/4js-fgltest/com/fourjs/fgltest/fgltest fgltest.json
```

Give `fglpkg bdl` an **absolute** config path: it starts programs inside the
installed package's directory, so a bare `fgltest.json` would be looked for
there. The paths *inside* the config are resolved against the config file's
own directory, so the config works the same either way.

## Build from source

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

An action file is validated when it loads, before any application starts,
and every problem is reported at once: an unknown command, a missing
`target` / `value` / `column` / `row`, a count or delay that is not a whole
number, or two tests with the same name (names identify tests in the reports).
The package ships a JSON Schema with the same rules,
`schema/action-file.schema.json`, for editor validation and completion.

Complex tests (loops, computed data, DB setup) still use the compiled BDL API
above — both modes share the same engine, hooks, reporters, and CI exit code.

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
  top-level `jsonRunner`; by default the `fgltest_json` program that sits beside
  the CLI).
- Relative paths (`outdir`, `module`, `actions`, `workdir`, `jsonRunner`,
  `discover.dir`, `discover.workdir`) resolve against the **config file's
  directory**, not the current one. `outdir` defaults to that directory.
- The config is **validated before anything runs**: an unknown key (a typo like
  `comandLine` would otherwise be ignored; keys match without regard to case,
  as the JSON parser matches them), a value of the wrong type (`"timeout":
  "30s"` would otherwise become NULL), a suite without a name or reusing
  another's, a suite whose reports would overwrite the config or an action
  file, a missing `module` / `actions` file, an unknown `mode` or reporter, a
  `ua` suite without a `url`. Every problem is listed, and the CLI exits 2.
  Keys starting with `$` or `_` are allowed, for `$schema` or comments.
- **Environment variables**: `$NAME` and `${NAME}` in a path, command line or
  URL are expanded by fgltest itself, the same way on every platform (`$$` is a
  literal `$`); a variable that is not set is a config error. Values are then
  passed to the suite exactly as they are.
- `workdir` defaults to the config's directory; `commandLine` defaults to
  GGC's `fglrun <application>`. **GGC splits the command line at spaces without
  honouring quotes**, so an application argument cannot contain a space.
- `port` (default `6500`) is the scenario-server port; the CLI starts the server
  on it and passes it to every suite. The `FGLTEST_PORT` environment variable
  overrides it. If a server is already listening on the port, the CLI uses it
  and leaves it running; it only stops a server it started itself. **Concurrent
  runs on one machine** (CI jobs on a shared runner) should each use their own
  port, e.g. `FGLTEST_PORT=$((6500 + N))`: one run stopping its server would
  otherwise cut off the other's sessions.

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

Run all suites. With the package installed, see [Install](#install); from a
source checkout, from the package root with that directory on `FGLLDPATH`:

```
export FGLLDPATH="$(pwd):$FGLLDPATH"
fglrun com/fourjs/fgltest/fgltest.42m            # uses ./fgltest.json
fglrun com/fourjs/fgltest/fgltest.42m my.json    # explicit config
```

The CLI starts the GGC scenario server, runs each suite, merges results, writes
reports to `outdir/`, prints an aggregate summary, and exits non-zero if any test
failed or errored, or any suite process ended before completing. Per-suite
console output (and raw engine logs) go to `outdir/<name>.log`.

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
- `<name>.tap` — Test Anything Protocol v13, with `# SKIP` / `# ERROR` directives
  and, for a test that did not pass, a YAML block (`severity`, `message`,
  `messages`) whose values are quoted, so any message parses.
- `<name>.json` — structured results: `tests`, `passed`, `failed`, `errors`,
  `skipped` (disjoint counts, as in JUnit: `failed` is a check that did not
  hold, `errors` a test that could not run), durations and the per-test cases.
- `fgltest.summary.json` — the CLI's merged aggregate.

Reports account for **every test, even when the suite process dies part-way**.
Each test is on the reports before anything runs (as not run), the test in
progress is marked "did not complete" while it runs, and the reports are
rewritten around each test. If the process is cut short, the last reports on
disk show the results gathered so far, name the test it died in, and list every
test it never reached. The CLI separately checks that each suite process reached
the end (the runner's `<name>.done` marker), so a crash fails the run even if
every test that finished had passed.

## API

All library modules are in the package `com.fourjs.fgltest`
(`IMPORT FGL com.fourjs.fgltest.<module>`); qualified calls use the short module
name shown below.

| Module | Purpose | Highlights |
|--------|---------|-----------|
| `runner` | test model + orchestration | `setApplication`, `test`, `testSkip`, `testOnly`, `beforeAll/afterAll/beforeEach/afterEach`, `run`, `runWith` (any `Driver`, no GGC) |
| `flow` | interaction verbs | `field`, `enter`, `fill`, `clear`, `action`, `press`, `pause`, `selectRow`, `focusCell` |
| `expect` | assertions | **strings** `expect.that(v).toEqual/notToEqual/toBeEmpty/notToBeEmpty/toContainText/notToContainText/toStartWith/toEndWith/toMatch/notToMatch`<br>**numbers** `expect.num(n).toEqual/notToEqual/toBeGreaterThan/toBeLessThan/toBeAtLeast/toBeAtMost/toBeBetween`<br>**booleans** `expect.bool(b).toBeTrue/toBeFalse`<br>**collections** `expect.all(list).toContain/notToContain/toContainMatch/toHaveSize/toBeEmpty/notToBeEmpty` |
| `inspect` | AUI introspection (fields and tables of the current window) | `actions`, `activeActionNames`, `actionNames`, `hasAction`, `fields`, `fieldNames`, `enabledFields`, `editableFields`, `formName`, `windowName`, `tables`, `rowCount`, `currentRow`, `cellValue`, `currentCellValue`, `applicationError` |
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

**Runtime errors in a test.** If a compiled suite's test or hook hits a BDL
runtime error (a NULL object, a file that will not open, …), the runner can trap
it and error just that test — but only if the module the error comes from opts
in, because a `WHENEVER` directive never crosses module boundaries. Put this in
each suite module, in a function placed **above** your test functions:

```4gl
FUNCTION optInToRaise()      -- never needs to be called: WHENEVER is
    WHENEVER ANY ERROR RAISE -- a compile-time directive for the lines below
END FUNCTION
```

The test is then reported as `runtime error -8083: Null pointer exception.`, its
`afterEach` hooks still run, and the suite carries on. (Conversion errors in
those functions are raised too, rather than silently yielding NULL.) Without the
opt-in, BDL stops the program on the spot; the reports then mark that test as
"did not complete" and the rest as "not run", and the CLI fails the run.

Some errors can **never** be trapped, opt-in or not: BDL's non-trappable errors
— `-1326` (array index out of bounds) among them — stop the program wherever
they occur. They end the suite the same way: that test "did not complete", the
rest "not run", and the run fails.

**The application going away.** When the application under test ends
mid-run, the test that hits it errors (`GGC-12 The scenario has already ended`)
and the remaining tests are reported as `not run: the application under test
ended` rather than each failing in turn. A loss that ends the suite process
from inside GGC itself (a closed connection) is accounted for by the reports
and the CLI's completion check, as described in [Reports](#reports).

**The application crashing.** A Genero program that stops on a runtime error
shows the error in a message box and waits — and meanwhile GGC keeps answering
from the screen it last saw, so reads still succeed and assertions can still
pass. After every test (and every `beforeAll` / `afterAll` phase) the runner
therefore looks for the runtime's error box, and when it finds one it errors
that test with the application's own message, then stops the run:

```
  ERROR 2 - saves the order (could not run to completion)
         - the application under test stopped with a runtime error: Program stopped at 'orders.4gl', line number 212. FORMS statement error number -8083. Null pointer exception.
```

The box is recognised by its standard text (`Program stopped at …`). If the
application sets `gui.programStoppedMessage` in FGLPROFILE, that text is
replaced and the crash cannot be told from an ordinary message box; it then
surfaces as a failure in a later test, and the suite log (`outdir/<name>.log`)
holds the application's own error output in `tcp` mode.

**Hooks.** A `beforeAll` hook that fails (a check that does not hold, a driver
error, a trapped runtime error) gets its own `beforeAll hook` entry in the
reports, and the tests are reported `not run: the beforeAll hook failed`
instead of running on a broken setup. `afterAll` still runs, and an `afterAll`
that fails gets an `afterAll hook` entry. Hook entries appear only when a hook
fails. Once the application has ended, an `afterAll` hook's interactions with
it are expected to fail and are not held against it, so a last test that
closes the application is fine.

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
