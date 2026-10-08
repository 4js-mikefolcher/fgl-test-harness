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

## 3. Install or build

### 3.1 Install with fglpkg

Add the package to your project as a dev dependency, then activate it alongside
the GGC environment:

```
fglpkg install --save-dev 4js-fgltest
eval "$(fglpkg env)"                         # the package root goes on FGLLDPATH
source "$FGLDIR/testing_utilities/ggc/envggc"
```

Your suites now compile with a plain `fglcomp -M`, and the two programs are in
`.fglpkg/packages/4js-fgltest/com/fourjs/fgltest/`. §6.2 shows how to run the
CLI.

### 3.2 Build from source

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
| `runWith(driver)` | Run every registered test against the given `Driver`, with no GGC session (for an alternative driver, or testing with an in-memory one). Results via `getOutcomes()`. |

Hooks are additive — register several and they run in order.

**Test names must be unique.** A name identifies the test in the reports and
selects it in isolate mode, so a name registered twice is reported as an error
(`not run: test #1 already has this name …`) and only its first test runs.

**When a hook fails.** `beforeEach` / `afterEach` belong to their test: a
failure in one fails or errors that test. `beforeAll` / `afterAll` are phases of
their own. A `beforeAll` that fails (a check that does not hold, a driver error,
a trapped runtime error) is reported as a `beforeAll hook` entry, and every test
is reported `not run: the beforeAll hook failed` instead of running on a broken
setup. `afterAll` always runs, so cleanup happens; if it fails it is reported as
an `afterAll hook` entry. These entries appear only when a hook fails. Once the
application under test has ended, an `afterAll` hook's interactions with it are
bound to fail and are not counted against it — so a last test that closes the
application, followed by an `afterAll` that would have closed it, still passes.

A skipped test is neither a pass nor a failure: it appears as `<skipped/>` in
JUnit, `# SKIP` in TAP, and never affects the exit code.

**Runtime errors in tests.** A BDL runtime error inside a test or hook (a NULL
object, a file that will not open, …) normally stops the program. To have the
runner trap it instead — error that one test, still run its `afterEach`, and
carry on — opt the suite module in. `WHENEVER` applies to every line after it
in the same module and never crosses module boundaries, so place it in a
function **above** your tests (the function never needs to be called):

```4gl
FUNCTION optInToRaise()
    WHENEVER ANY ERROR RAISE
END FUNCTION
```

The test then reports `runtime error -8083: Null pointer exception.`.
Conversion errors in those functions are raised too, instead of silently
producing NULL. Without the opt-in the suite process stops, and the reports
(§7) mark that test "did not complete" and the remaining ones "not run".

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
| `inspect.fields()` | All fields of the current window (union of form fields and table columns) with `active`/`hidden`/`readOnly`/`widget`/`varType`. |
| `inspect.fieldNames()` | Names of all fields. |
| `inspect.enabledFields()` | Names of enabled (active, not hidden) fields. |
| `inspect.editableFields()` | Names of editable (active, not hidden, not read-only) fields. |
| `inspect.formName()` / `inspect.windowName()` | Current form / window name. |
| `inspect.tables()` | Names of tables/matrices on the current window's form (the identifier the table calls/verbs expect). |
| `inspect.rowCount(table)` | Total number of rows. |
| `inspect.currentRow(table)` | Current (focused) row, 1-based. |
| `inspect.cellValue(table, column, row)` | Value at an explicit row (must be loaded — navigate first). |
| `inspect.currentCellValue(table, column)` | Value of a column in the current row (always loaded). |
| `inspect.applicationError()` | The runtime error the application under test stopped with (`Program stopped at …`), or NULL. The runner checks this after every test for you. |

**Current window only.** The AUI tree keeps every open window, so with a modal
child window up it also holds the parent's fields. The field and table queries
read only the **current** window — the one the active dialog runs in — so
`fieldNames()` inside a child window lists the child's fields, not the
parent's as well.

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
is started, and every problem in the file is reported at once: an unknown
command; a missing `target`, `value`, `column` or `row` (rows start at 1); a
count or delay (`pause`, `assertFieldCount`, `assertRowCount*`,
`assertCurrentRow`) that is not a whole number; and two tests with the same
name.

```
fgltest_json: action file 'tests/price.actions.json' is not valid:
  - test 'edits a price' step 2: unknown command 'assertFeild'
  - test 'edits a price' step 4: command 'action' needs a "target"
  - test 'reads a cell' step 1: command 'assertCellAtRow' needs a "column"
  - test 'counts rows' step 1: command 'assertRowCount' needs a whole-number "value", not 'five'
  - test #4 reuses the name 'edits a price' of test #1 — test names must be unique
```

A JSON Schema for action files, encoding the same rules, ships with the
package: `schema/action-file.schema.json` (in a project install,
`.fglpkg/packages/4js-fgltest/schema/action-file.schema.json`). Point an
action file's `"$schema"` key at it, or map `*.actions.json` to it in your
editor, for validation and completion as you type.

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
| `port` | Scenario-server port (default `6500`). The CLI starts the server on it and passes it to every suite. The `FGLTEST_PORT` environment variable overrides it (see §8). |
| `reporters` | CSV of `console`, `junit`, `tap`, `json`. |
| `outdir` | Directory for report files and logs (default: the config file's directory). |
| `jsonRunner` | Program used to run `actions` suites (default: the `fgltest_json` beside the CLI). |
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
| `workdir`, `commandLine` | For `tcp`: the app's working directory (default: the config's directory) and launch command (default: GGC's `fglrun <application>`). The command line reaches GGC as written — on POSIX the shell still expands `$VAR` — and GGC splits it at spaces without honouring quotes, so an argument cannot contain a space. |
| `url` | For `ua`: the GAS application URL. |
| `isolate` | Run this suite's tests in isolated processes (in addition to the global `isolate`). |
| `timeout` | Wall-clock limit for this suite, in seconds; overrides the global `timeout`. |

**Validation.** The config is checked before the scenario server or any
application starts, and every problem is listed (exit code 2): an unknown key
— a typo such as `comandLine` would otherwise be silently ignored — a suite
without a name or reusing another's (suites write reports under their name),
a suite with both or neither of `module` / `actions`, a `module` (or `.42m`)
or action file that does not exist, an unknown `mode` or reporter, a `ua`
suite without a `url`, and a negative `timeout`. Keys starting with `$` or `_`
are allowed, for `$schema` or comment entries. A discovered suite whose name
is already taken is skipped with a note.

**Paths.** Every relative path in the config — `outdir`, `jsonRunner`, a suite's
`module` / `actions` / `workdir`, and `discover.dir` / `discover.workdir` — is
resolved against the **directory of the config file**, not the current
directory. A config therefore means the same thing wherever the CLI is started
from. Absolute paths are used as written.

### 6.2 Run

With the package installed (§3.1), from your project root:

```
fglpkg bdl 4js-fgltest fgltest "$PWD/fgltest.json"
# or, equivalently:
fglrun .fglpkg/packages/4js-fgltest/com/fourjs/fgltest/fgltest fgltest.json
```

`fglpkg bdl` starts programs inside the installed package's directory, so pass
it the config as an **absolute** path; the paths inside the config are resolved
against the config file either way.

From a source checkout, run from the package root with that directory on
`FGLLDPATH` (`export FGLLDPATH="$(pwd):$FGLLDPATH"`):

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
| `<name>.tap` | Test Anything Protocol v13. A test that did not pass carries a YAML block — `severity` (`fail` / `error`), `message` (the first) and `messages` (all) — with quoted values; `#` in a test name is escaped. |
| `<name>.json` | Structured results (below). |
| `fgltest.summary.json` | The CLI's merged aggregate across all suites. |

Every format distinguishes three outcomes, because they mean different things to
whoever reads the dashboard:

| Outcome | Meaning | JUnit | TAP |
|---------|---------|-------|-----|
| **failure** | an assertion did not hold — the app behaved differently than expected | `<failure>` | `not ok` |
| **error** | the test could not run — a bad field/table/action name, a runtime error, a crashed or lost application | `<error>` | `not ok … # ERROR` |
| **skipped** | deliberately not run (`testSkip` / `"skip"` / not the focused `only`) | `<skipped/>` | `ok … # SKIP` |

JUnit reports carry a per-test `time` and a suite `timestamp`, so CI shows
durations and trends.

**The JSON report** (`<name>.json`):

| Field | Meaning |
|-------|---------|
| `suite` | The suite name. |
| `tests` | Number of entries in `cases` (tests, plus a `beforeAll hook` / `afterAll hook` entry when one failed). |
| `passed` / `failed` / `errors` / `skipped` | Disjoint counts that add up to `tests`: `failed` — a check did not hold; `errors` — the test could not run. |
| `duration` | Total seconds. |
| `cases[]` | Per entry: `name`, `passed`, `errored`, `skipped`, `checks`, `failed` (failed checks), `duration`, `messages[]`. |

Reports account for **every test, even when the suite process dies part-way.**
Before anything runs, each test is on the reports as *not run*; the test in
progress is marked *did not complete* while it runs; and the reports are
rewritten around each test. So whatever cuts a run short — an uncaught runtime
error, the application taking the session down, a kill — the last reports on
disk hold the results gathered so far, an errored entry naming the test the
process died in (`did not complete: …`), and an errored entry for each test it
never reached (`not run: …`).

The CLI also checks that each suite process reached the end: the runner drops a
`<name>.done` marker when it finishes, and a process that exits without one is
counted as **incomplete**, even if every test that finished had passed. Before
each run the CLI deletes that suite's previous reports and marker, so results
left by an earlier run can never stand in for this one.

The process exit code is non-zero if any test failed or errored, or any suite
process was incomplete (crashed, killed, or stopped by the watchdog) — wire it
straight into CI. Skipped tests never fail a build. `fgltest.summary.json`
carries the counts behind that decision: `tests`, `passed`, `failed`, `errors`,
`skipped`, `timedOut` and `incomplete`.

---

## 8. The scenario server

The GGC BDL API is a client to a separate **scenario server**. The `fgltest` CLI
owns its lifecycle: it starts `ggcadmin startbdlserver` before the run and stops
it after, even if a suite crashes.

If a server is **already** listening on the port, the CLI uses it, says so, and
leaves it running: it only stops (or, for a wedged suite, restarts) a server it
started itself. That keeps it from killing a server you started by hand, but it
cannot make two runs share one server safely — whichever started it stops it
when it finishes, cutting off the other. Give **concurrent runs on one machine**
(CI jobs on a shared runner, say) a port each with `FGLTEST_PORT`, which
overrides the config's `port`:

```
FGLTEST_PORT=$((6500 + RUNNER_SLOT)) fglrun …/fgltest fgltest.json
```

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
| Suite reports "no results produced" | The suite process exited before writing its JSON — the module was not found, the app could not start, or the scenario server was unreachable. Inspect `outdir/<name>.log`. |
| "the suite process ended before completing" | The suite died part-way. Its reports name the test it died in (`did not complete`) and the tests it never reached (`not run`); the log shows the error. A runtime error in your test code can be trapped per test instead — see §4.1. |
| A test reports `driver error: (GGC-7) … not found` | A field name doesn't exist on the current form. Use `inspect.fieldNames()` to list what is actually there. Only that test errors; the run continues. |
| A test reports `driver error: (GGC-11) No scrollable widget …` | A table name is wrong. It must be the AUI `<Table name>` (or the screen-record name) — **not** the `.per` `TABLE` widget tag. `inspect.tables()` lists the valid names. |
| A test reports `driver error: (GGC-9) The action … does not belong` | An action name doesn't exist in the active dialog. `inspect.actionNames()` lists them. |
| A test errors with `GGC-12 The scenario has already ended`, the rest are "not run: the application under test ended" | The app exited mid-run (often an `afterEach` that closes it, or a test that ends the program before a later test expects it). Reports still contain everything up to that point. |
| A test errors with "the application under test stopped with a runtime error: Program stopped at …" | The application crashed during that test; the message is the runtime's own, with file and line. The remaining tests are not run. |
| A test passes, then the next ones fail with nothing obviously wrong | The application may have crashed with `gui.programStoppedMessage` set in its FGLPROFILE, which hides the error text the runner looks for. In `tcp` mode the suite log captures the application's own error output. |
| Every test is "not run: the beforeAll hook failed" | See the `beforeAll hook` entry in the same report for what went wrong. |
| "using the scenario server already running on port …" | Something was already listening on the port — your own server, or another run. It is reused and left running. For concurrent runs, set `FGLTEST_PORT` per run (§8). |
| `fglpkg bdl … fgltest fgltest.json` says `cannot read config` | `fglpkg bdl` runs programs inside the installed package; pass the config as an absolute path (`"$PWD/fgltest.json"`). |
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
lifecycle), `cli` (the CLI's config model and result handling — used by the
`fgltest` program, not by suites).
