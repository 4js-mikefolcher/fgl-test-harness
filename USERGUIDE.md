# fgltest — User Guide

`fgltest` is a functional-test harness for Genero BDL applications. It drives a
real application over the front-end protocol (using the supported **GGC** engine),
inspects the live AUI tree, and reports results in CI-standard formats.

This guide walks through installing the package, writing tests in both authoring
modes, configuring the runner, and reading the results.

- Library package: **`com.fourjs.fgltest`**
- Everything — the library modules and both programs, `fgltest` (the CLI runner)
  and `fgltest_json` (the generic action-file runner) — is compiled into the
  package directory **`com/fourjs/fgltest/`**

---

## 1. Concepts

| Term | Meaning |
|------|---------|
| **Application under test** | Your real Genero program (e.g. `price`), launched by the harness. |
| **Suite** | A collection of tests against one application. Either a compiled `.4gl` program or a JSON action file. |
| **Test** | One named scenario: a sequence of interactions and assertions. |
| **Hook** | `beforeAll` / `beforeEach` / `afterEach` / `afterAll` — setup/teardown around tests. |
| **Driver** | The seam between the harness and the GGC engine. The default `ggcdriver` speaks to GGC; the `Driver` INTERFACE lets a different backend be substituted without touching tests. |
| **Scenario server** | The GGC "BDL scenario server" (`ggcadmin`), a background process the engine connects to. The CLI starts and stops it for you. |

By default the harness runs all of a suite's tests in **one engine session**; use
hooks to return the UI to a known state between tests. (§6.3 covers `isolate`,
which runs each test in its own process.)

---

## 2. Requirements

- Genero BDL **6.x** — `fglcomp`, `fglform`, `fglrun` on `PATH`.
- The **GGC toolkit** shipped with Genero (`$FGLDIR/testing_utilities/ggc`).
  Source its `envggc` so that `ggc.jar` is on `CLASSPATH`, `ggc.42m` is on
  `FGLLDPATH`, and `ggcadmin` is on `PATH`.
- A Java runtime for the GGC engine.
- GNU `make` to build.

Activate the environment before building or running:

```
# 1. your normal Genero environment (envgenero / envcomp), then:
source "$FGLDIR/testing_utilities/ggc/envggc"
# 2. put the package root (the directory that contains com/) on FGLLDPATH
#    so IMPORT FGL com.fourjs.fgltest.* resolves:
export FGLLDPATH="$(pwd):$FGLLDPATH"
```

---

## 3. Build

```
make          # builds com/fourjs/fgltest/*.42m (library + the fgltest and
              # fgltest_json programs) and the bundled example
make clean
```

Sources and their compiled `.42m` are co-located in `com/fourjs/fgltest/` — the
directory mirrors the package path (TOPDIR is the project root). The `Makefile`
puts the package root on `FGLLDPATH` during the build so each module resolves its
already-compiled dependencies. The layout is required: the
`PACKAGE com.fourjs.fgltest` declaration must match the `IMPORT FGL` path and the
directory tree, or the compiler rejects it (`-8444`). The two programs are MAIN
modules with no `PACKAGE` line, so the build uses `--output-dir` to place their
`.42m` in the package directory alongside the library.

Non-Unix shells can override the file operations:

```
make MKDIR="mkdir" RM="del /q"
```

---

## 4. Authoring mode A — compiled BDL suites

Use this mode for full control: loops, computed test data, database setup, custom
helpers. A suite is a normal compiled program.

```4gl
IMPORT FGL com.fourjs.fgltest.runner
IMPORT FGL com.fourjs.fgltest.flow
IMPORT FGL com.fourjs.fgltest.expect
IMPORT FGL com.fourjs.fgltest.inspect

MAIN
    CALL runner.setApplication("price")

    CALL runner.beforeEach(FUNCTION settle)   -- runs before every test
    CALL runner.afterAll(FUNCTION leave)      -- runs once at the end

    CALL runner.test("shows edit and cancel actions", FUNCTION t_actions)
    CALL runner.test("starts on the price form",       FUNCTION t_form)

    CALL runner.run()   -- parses the tcp/ua connection args, runs, reports, exits
END MAIN

FUNCTION settle()
    CALL flow.pause(100)
END FUNCTION

FUNCTION leave()
    CALL flow.action("cancel")
END FUNCTION

FUNCTION t_actions()
    CALL expect.all(inspect.activeActionNames()).toContain("edit")
    CALL expect.all(inspect.activeActionNames()).toContain("cancel")
END FUNCTION

FUNCTION t_form()
    CALL expect.that(inspect.formName()).toEqual("price")
END FUNCTION
```

> Import modules with their full package path (`IMPORT FGL com.fourjs.fgltest.runner`),
> but call them by the short module name (`runner.setApplication(...)`).

### 4.1 Registration API (`runner`)

| Function | Purpose |
|----------|---------|
| `setApplication(name)` | Name of the application under test. |
| `test(name, FUNCTION fn)` | Register a test backed by a BDL function `FUNCTION() RETURNS ()`. |
| `testSkip(name, fn)` | Register a test but report it as **skipped** instead of running it. |
| `testOnly(name, fn)` | Focus the run: if any test is registered `only`, all others are skipped. |
| `beforeAll(fn)` / `afterAll(fn)` | Run once, before/after all tests. |
| `beforeEach(fn)` / `afterEach(fn)` | Run around every test. |
| `run()` | Connect, run every registered test, report, set the exit code. |

Hooks are additive — register several and they run in order.

A skipped test is neither a pass nor a failure: it appears as `<skipped/>` in
JUnit, `# SKIP` in TAP, and never affects the exit code.

### 4.2 Interaction verbs (`flow`)

Each verb acts on the application through the active driver. They are **void**
statements (BDL cannot discard a return value, so there is no method chaining).

| Verb | Effect |
|------|--------|
| `flow.field(name)` | Focus a field by name. |
| `flow.enter(value)` | Type a value into the current field. |
| `flow.fill(name, value)` | Focus a field and set its value in one step. |
| `flow.clear()` | Clear the current field. |
| `flow.action(name)` | Trigger an action (button/menu) by name. |
| `flow.press(keyName)` | Send a key by name (e.g. `"F1"`, `"ACCEPT"`). |
| `flow.pause(ms)` | Wait the given milliseconds. |
| `flow.selectRow(table, row)` | Focus (and load) a table row, 1-based. |
| `flow.focusCell(table, column, row)` | Focus (and load) a specific table cell. |

### 4.3 Assertions (`expect`)

Four entry points begin an assertion — `expect.that(...)` for strings,
`expect.num(...)` for numbers, `expect.bool(...)` for booleans and
`expect.all(...)` for collections. The matcher methods are **void** (one
assertion per statement) and record a pass/fail into the run. String comparisons
are empty-safe (BDL treats `""` as NULL).

```4gl
CALL expect.that(inspect.formName()).toEqual("price")
CALL expect.num(inspect.rowCount("prices")).toEqual(5)
CALL expect.bool(inspect.hasAction("save")).toBeTrue()
CALL expect.all(inspect.enabledFields()).toContain("formonly.price")
```

**Strings — `expect.that(v)`**

| Matcher | Passes when |
|---------|-------------|
| `.toEqual(expected)` / `.notToEqual(expected)` | the value is (not) equal |
| `.toBeEmpty()` / `.notToBeEmpty()` | the value is (not) empty or NULL |
| `.toContainText(sub)` / `.notToContainText(sub)` | `sub` is (not) a substring |
| `.toStartWith(prefix)` | the value begins with `prefix` |
| `.toEndWith(suffix)` | the value ends with `suffix` |
| `.toMatch(re)` / `.notToMatch(re)` | the regex does (not) match |

**Numbers — `expect.num(v)`**

| Matcher | Passes when |
|---------|-------------|
| `.toEqual(n)` / `.notToEqual(n)` | numerically (not) equal |
| `.toBeGreaterThan(n)` / `.toBeLessThan(n)` | strictly greater / less |
| `.toBeAtLeast(n)` / `.toBeAtMost(n)` | inclusive bound |
| `.toBeBetween(lo, hi)` | within `[lo, hi]`, inclusive |

**Booleans — `expect.bool(v)`**: `.toBeTrue()`, `.toBeFalse()`.

**Collections — `expect.all(list)`**

| Matcher | Passes when |
|---------|-------------|
| `.toContain(item)` / `.notToContain(item)` | the item is (not) present |
| `.toContainMatch(re)` | some item matches the regex |
| `.toHaveSize(n)` | the length is exactly `n` |
| `.toBeEmpty()` / `.notToBeEmpty()` | the list is (not) empty |

> **Compare numbers with `expect.num`.** `expect.that` stringifies, so `5` and
> `5.0` would not match. `expect.num` takes a `DECIMAL`, so `INTEGER`, `FLOAT`
> and `MONEY` values all convert without loss.

> **`toMatch` is unanchored.** `STRING.matches()` finds the pattern anywhere in
> the value, so `"world"` matches `"hello world"`. Anchor with `^...$` when you
> mean the whole value.

### 4.4 AUI-tree introspection (`inspect`)

Answers live-state questions straight from the running UI's AUI tree. This is the
harness's headline capability — you can enumerate what is on screen rather than
hard-coding it.

| Function | Returns |
|----------|---------|
| `inspect.actions()` | All dialog actions (`name` / `active` / `text`). |
| `inspect.actionNames()` | Names of all actions. |
| `inspect.activeActionNames()` | Names of currently-active actions only. |
| `inspect.hasAction(name)` | Whether an action exists. |
| `inspect.fields()` | All fields (union of form fields and table columns) with `active`/`hidden`/`readOnly`/`widget`/`varType`. |
| `inspect.fieldNames()` | Names of all fields. |
| `inspect.enabledFields()` | Names of enabled (active, not hidden) fields. |
| `inspect.editableFields()` | Names of editable (active, not hidden, not read-only) fields. |
| `inspect.formName()` / `inspect.windowName()` | Current form / window name. |
| `inspect.tables()` | Names of tables/matrices on the form (the identifier the table calls/verbs expect). |
| `inspect.rowCount(table)` | Total number of rows. |
| `inspect.currentRow(table)` | Current (focused) row, 1-based. |
| `inspect.cellValue(table, column, row)` | Value at an explicit row (must be loaded — navigate first). |
| `inspect.currentCellValue(table, column)` | Value of a column in the current row (always loaded). |

**Working with tables/lists.** The `table` argument is the name from
`inspect.tables()` (the AUI `Table` `name`; the screen-record name also works).
Columns are the plain column names (e.g. `name`, not `formonly.name`). A cell read
only sees a **loaded** row: the current row is always loaded, so
`currentCellValue` needs no navigation, but to read an arbitrary row you must
`flow.selectRow(table, n)` (or `flow.focusCell`) first — otherwise the read comes
back empty.

```4gl
CALL expect.that(inspect.currentCellValue("prices", "name")).toEqual("Globe")
CALL flow.selectRow("prices", 3)
CALL expect.that(inspect.cellValue("prices", "name", 3)).toEqual("Blue Scissors")
```

---

## 5. Authoring mode B — declarative JSON action files

For the common "drive + assert" test, skip BDL entirely: write a JSON **action
file** and let the shipped `fgltest_json` program run it. Nothing to compile.

The format follows the established keyword-driven model (Selenium IDE's
`command` / `target` / `value` triple). Each step is one command; the runner
dispatches it to the same `flow` / `expect` / `inspect` verbs.

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

Top-level keys: `application` (required), the optional hook step-lists
`beforeAll` / `beforeEach` / `afterEach` / `afterAll`, and `tests` (each with a
`name` and a `steps` list).

### 5.1 Command reference

**Interaction**

| `command` | Uses | Maps to |
|-----------|------|---------|
| `action` | `target` | `flow.action` |
| `field` | `target` | `flow.field` |
| `enter` | `value` | `flow.enter` |
| `fill` | `target`, `value` | `flow.fill` |
| `clear` | — | `flow.clear` |
| `key` | `target` | `flow.press` |
| `pause` | `value` (ms) | `flow.pause` |
| `selectRow` | `target` (table), `row` | `flow.selectRow` |
| `focusCell` | `target` (table), `column`, `row` | `flow.focusCell` |

**Assertions**

| `command` | Uses | Checks |
|-----------|------|--------|
| `assertField` | `target`, `value` | field value equals |
| `assertFieldNot` | `target`, `value` | field value differs |
| `assertFieldContains` | `target`, `value` | field value contains the substring |
| `assertFieldMatches` | `target`, `value` (regex) | field value matches |
| `assertCurrent` | `value` | current field value equals |
| `assertFormName` | `value` | current form name |
| `assertFormTitle` | `value` | current form title |
| `assertWindowName` | `value` | current window name |
| `assertWindowTitle` | `value` | current window title |
| `assertActionActive` | `target` | action is active |
| `assertActionInactive` | `target` | action is not active |
| `assertActionExists` | `target` | action exists |
| `assertActionMissing` | `target` | action does not exist |
| `assertFieldEnabled` | `target` | field is enabled |
| `assertFieldDisabled` | `target` | field is not enabled |
| `assertFieldEditable` | `target` | field is editable |
| `assertFieldReadOnly` | `target` | field is not editable |
| `assertFieldExists` | `target` | field exists |
| `assertFieldMissing` | `target` | field does not exist |
| `assertFieldCount` | `value` (n) | number of fields |
| `assertTableExists` | `target` | a table/matrix with that name exists |
| `assertCell` | `target` (table), `column`, `value` | current row's cell value equals |
| `assertCellContains` | `target` (table), `column`, `value` | current row's cell contains |
| `assertCellMatches` | `target` (table), `column`, `value` (regex) | current row's cell matches |
| `assertCellAtRow` | `target` (table), `column`, `row`, `value` | navigates to `row`, then cell value equals |
| `assertRowCount` | `target` (table), `value` (n) | number of rows equals |
| `assertRowCountAtLeast` | `target` (table), `value` (n) | at least n rows |
| `assertRowCountAtMost` | `target` (table), `value` (n) | at most n rows |
| `assertCurrentRow` | `target` (table), `value` (n) | current row index |

**Validation.** An action file is checked when it loads, before any application
is started: an unknown command, or one missing its required `target` / `value`,
is reported with every other problem in the file at once.

```
fgltest_json: action file 'tests/price.actions.json' is not valid:
  - test 'edits a price' step 2: unknown command 'assertFeild'
  - test 'edits a price' step 4: command 'action' needs a "target"
```

**Skipping and focusing.** A test object may carry `"skip": true` (reported as
skipped, never run) or `"only": true` (if any test is `only`, all others are
skipped):

```json
{ "name": "work in progress", "skip": true, "steps": [] }
```

Rows are 1-based. `assertCell` reads the **current** row (always loaded);
`assertCellAtRow` navigates to `row` first, so use it (or a `selectRow` step) for
any non-visible row.

### 5.2 Running an action file directly

The path is passed via the `FGLTEST_ACTIONS` environment variable (not a command
argument, because the GGC engine parses the `tcp` / `ua` arguments itself):

```
FGLTEST_ACTIONS=examples/price/price.actions.json \
  fglrun com/fourjs/fgltest/fgltest_json tcp \
    --working-directory examples/price \
    --command-line "fglrun price"
```

(The scenario server must already be running — see §7 — or use the CLI in §6,
which manages it for you.)

---

## 6. Configure and run with the CLI

`fgltest.json` describes the suites and how to reach each application. The CLI
(`com/fourjs/fgltest/fgltest`) reads it, starts the scenario server, runs each
suite as a subprocess, merges the results, and exits non-zero if anything failed.

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

### 6.1 Configuration reference

| Key | Meaning |
|-----|---------|
| `port` | Scenario-server port (default `6500`). |
| `reporters` | CSV of `console`, `junit`, `tap`, `json`. |
| `outdir` | Directory for report files and logs (default `.`). |
| `jsonRunner` | Program used to run `actions` suites (default `com/fourjs/fgltest/fgltest_json`). |
| `isolate` | Run every suite's tests in isolated processes (see §6.3). Default `false`. |
| `timeout` | Wall-clock limit per suite, in seconds (see §6.5). Default `0` — no limit. |
| `discover` | Auto-discovery block (see §6.4). |
| `suites[]` | The suites to run (below). |

Each suite:

| Key | Meaning |
|-----|---------|
| `name` | Label and report basename. |
| `module` | Compiled suite program to run **— or —** |
| `actions` | Path to a JSON action file (run via `jsonRunner`). Use one of `module`/`actions`. |
| `mode` | `tcp` (launch the app locally) or `ua` (drive a GAS-deployed app). |
| `workdir`, `commandLine` | For `tcp`: the app's working directory and launch command. |
| `url` | For `ua`: the GAS application URL. |
| `isolate` | Run this suite's tests in isolated processes (in addition to the global `isolate`). |
| `timeout` | Wall-clock limit for this suite, in seconds; overrides the global `timeout`. |

### 6.2 Run

Run from the package root with that directory on `FGLLDPATH`
(`export FGLLDPATH="$(pwd):$FGLLDPATH"`):

```
fglrun com/fourjs/fgltest/fgltest.42m            # uses ./fgltest.json
fglrun com/fourjs/fgltest/fgltest.42m my.json    # explicit config
```

The CLI prints a per-suite line and an aggregate summary; full per-suite console
output and raw engine logs go to `outdir/<name>.log`.

```
fgltest: 2 suite(s); server port 6500; outdir results
--- price ---
  4 tests, 3 passed, 1 failed
--- price-json ---
  3 tests, 3 passed, 0 failed
=== fgltest: 2 suites, 7 tests, 6 passed, 1 failed, 0 errors ===
```

### 6.3 Isolation (a process per test)

By default all of a suite's tests run in **one** engine session — fast, and the
common case. If a test can crash or hang the application (and take the rest of
the suite down with it), set `isolate`:

```json
{ "isolate": true, "suites": [ /* ... */ ] }        // globally
{ "suites": [ { "name": "flaky", "isolate": true, /* ... */ } ] }   // per suite
```

In isolate mode the CLI enumerates the suite's tests (it parses a JSON action
file directly, or runs a compiled suite once in list-only mode), then runs **each
test in its own subprocess** — a fresh application session per test. Counts are
merged into the summary exactly as before, so the totals are unchanged; only the
process boundary differs.

Each isolated test writes its own report files, named `<suite>.<n>.*` (e.g.
`price.4.junit.xml`). CI systems aggregate them with a glob such as
`results/*.junit.xml`. Isolation trades speed (one app launch per test) for
robustness, so reach for it only where a shared session is a real risk.

### 6.4 Auto-discovery

Rather than listing every suite, point a `discover` block at a directory:

```json
{
  "discover": {
    "dir": "tests",
    "mode": "tcp", "workdir": ".", "commandLine": "fglrun myapp",
    "modulePattern": "_test"
  }
}
```

The CLI scans `dir` and appends a suite for each match:

- every `*.actions.json` → a JSON suite (name = the file stem);
- every compiled module ending in `modulePattern` + `.42m` (default `_test`, so
  `foo_test.42m`) → a compiled suite.

| Key | Meaning |
|-----|---------|
| `dir` | Directory to scan (required; discovery is off if omitted). |
| `mode` / `workdir` / `commandLine` / `url` | Connection template applied to **every** discovered suite. |
| `modulePattern` | Basename suffix that marks a compiled suite (default `_test`). |

All discovered suites share the one connection template, so discovery fits a
directory of tests that drive the **same** application. Discovered suites are
appended to any explicit `suites[]`, and honour the global `isolate` flag.

---

### 6.5 Timeouts

`timeout` (global, or per suite) bounds how long a suite may take:

```json
{
  "timeout": 120,
  "suites": [
    { "name": "slow-reports", "timeout": 600, "module": "tests/reports_test" }
  ]
}
```

Two mechanisms cooperate, because BDL's `RUN` gives no PID and no timed wait:

1. **The suite's own budget.** Before each test the runner checks elapsed time;
   past the budget it stops scheduling, marks the remaining tests as errored, and
   writes complete reports. This is the good path, and it covers a slow or
   looping suite.
2. **The CLI watchdog.** For a genuinely wedged process, the CLI polls for the
   completion marker the runner writes and, on expiry, restarts the scenario
   server — which releases a child blocked reading its socket — then moves on to
   the next suite.

> With no `timeout` set (the default) the CLI waits for each suite directly, so a
> crash is noticed immediately. With `timeout` set, a suite that dies *without*
> completing costs the full timeout before the watchdog concludes. Set it high
> enough to be an emergency brake, not a normal bound.

---

## 7. Reports

Written to `outdir/`, selected by the `reporters` config (or the
`FGLTEST_REPORTERS` env var for a direct run):

| File | Format |
|------|--------|
| console | Readable pass/fail with failure detail (always on for direct runs). |
| `<name>.junit.xml` | JUnit XML — consumable by Jenkins, GitLab, GitHub Actions, … |
| `<name>.tap` | Test Anything Protocol v13. |
| `<name>.json` | Structured results (per-test cases and messages). |
| `fgltest.summary.json` | The CLI's merged aggregate across all suites. |

Every format distinguishes three outcomes, because they mean different things to
whoever reads the dashboard:

| Outcome | Meaning | JUnit | TAP |
|---------|---------|-------|-----|
| **failure** | an assertion did not hold — the app behaved differently than expected | `<failure>` | `not ok` |
| **error** | the test could not run — a bad field/table/action name, or a lost session | `<error>` | `not ok … # ERROR` |
| **skipped** | deliberately not run (`testSkip` / `"skip"` / not the focused `only`) | `<skipped/>` | `ok … # SKIP` |

JUnit reports carry a per-test `time` and a suite `timestamp`, so CI shows
durations and trends.

Reports are rewritten **after every test**, so if a run is cut short — the
application closes, a suite is killed — the results gathered up to that point are
still on disk.

The process exit code is non-zero if any test failed or errored, or a suite
produced no results — wire it straight into CI. Skipped tests never fail a build.

---

## 8. The scenario server

The GGC BDL API is a client to a separate **scenario server**. The `fgltest` CLI
owns its lifecycle: it starts `ggcadmin startbdlserver` before the run and stops
it after, even if a suite crashes.

When running a suite or an action file **directly** (not via the CLI), start the
server yourself first:

```
ggcadmin startbdlserver -p 6500 -i 300     # -i = idle seconds before auto-exit
# ... run your suite / action file ...
ggcadmin stopbdlserver -p 6500
```

---

## 9. Choosing a mode

| Prefer… | When |
|---------|------|
| **JSON action file** | Straight-line "drive + assert" flows; non-programmers authoring tests; no compile step wanted. |
| **Compiled BDL suite** | Loops or data-driven repetition, computed values, database/fixture setup, reusable helper functions, custom assertions. |

Both share the same engine, hooks, reporters, and CI exit code, and can live
side-by-side in the same `fgltest.json`.

---

## 10. Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `-8444 … must contain this package declaration` | An `IMPORT FGL com.fourjs.fgltest.X` path doesn't match the module's `PACKAGE` line or its directory. Keep path, `PACKAGE`, and directory identical (case included). |
| `IMPORT FGL` cannot find a module | The package root (the directory containing `com/`) is not on `FGLLDPATH`, or the package wasn't built. Run `make` and `export FGLLDPATH="$(pwd):$FGLLDPATH"`. |
| Cannot connect / suite hangs at start | The scenario server isn't running. Use the CLI (it manages the server) or start `ggcadmin startbdlserver` yourself. |
| `ggcadmin` / `ggc.jar` not found | `envggc` wasn't sourced. |
| Action file: `unknown command '…'` at load | A `command` value isn't in the reference table (§5.1). The file is rejected before the app starts; every problem is listed at once. |
| Suite reports "no results produced" | The suite process exited before writing its JSON — inspect `outdir/<name>.log`. |
| A test reports `driver error: (GGC-7) … not found` | A field name doesn't exist on the current form. Use `inspect.fieldNames()` to list what is actually there. Only that test errors; the run continues. |
| A test reports `driver error: (GGC-11) No scrollable widget …` | A table name is wrong. It must be the AUI `<Table name>` (or the screen-record name) — **not** the `.per` `TABLE` widget tag. `inspect.tables()` lists the valid names. |
| A test reports `driver error: (GGC-9) The action … does not belong` | An action name doesn't exist in the active dialog. `inspect.actionNames()` lists them. |
| Every test after some point is "not run: the application under test ended" | The app exited mid-run (often an `afterEach`/`afterAll` that closes it, or a crash). Reports still contain everything up to that point. |
| Run never finishes | A wedged application. Set `timeout` (§6.5); the CLI's own CI job timeout remains the ultimate backstop. |

---

## 11. Package layout

```
com/fourjs/fgltest/            PACKAGE com.fourjs.fgltest — sources and .42m together
  <module>.4gl / .42m            library modules (PACKAGE com.fourjs.fgltest)
  fgltest.4gl / .42m             the CLI program (MAIN, no PACKAGE)
  fgltest_json.4gl / .42m        generic action runner (MAIN, no PACKAGE)
tests/                          fgltest's own test suite (fake driver, no GGC) — `make check`
examples/price/                 a worked example app + BDL suite + action file
README.md / USERGUIDE.md        docs (at the project root, next to fglpkg.json)
fglpkg.json                     package manifest (root = com/fourjs/fgltest)
fgltest.json                    suite/run configuration
```

Library modules: `driver` / `ggcdriver` (the GGC seam), `core` (shared state and
results), `inspect` (AUI introspection), `flow` (interaction verbs), `expect`
(matchers), `script` (JSON action-file loader + dispatcher), `runner`
(orchestration), `reporters` (JUnit/TAP/JSON), `server` (scenario-server
lifecycle).
