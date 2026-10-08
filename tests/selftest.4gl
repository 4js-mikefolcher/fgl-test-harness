# selftest — fgltest's own test suite.
#
#   fglrun tests/selftest        (or: make check)
#
# Runs with NO GGC engine, NO scenario server and NO application: the fake
# driver stands in for the interaction layer, so every piece of fgltest's own
# logic — AUI parsing, matchers, reporters, the action-file interpreter, the
# CLI's config and result handling, the runner's crash accounting — is
# exercised anywhere a compiler is available. Exits non-zero on any failure.

IMPORT os
IMPORT util
IMPORT FGL com.fourjs.fgltest.core
IMPORT FGL com.fourjs.fgltest.driver
IMPORT FGL com.fourjs.fgltest.inspect
IMPORT FGL com.fourjs.fgltest.flow
IMPORT FGL com.fourjs.fgltest.expect
IMPORT FGL com.fourjs.fgltest.script
IMPORT FGL com.fourjs.fgltest.reporters
IMPORT FGL com.fourjs.fgltest.cli
IMPORT FGL com.fourjs.fgltest.ggcdriver
IMPORT FGL com.fourjs.fgltest.server
IMPORT FGL ggc
IMPORT FGL fakedriver

DEFINE m_pass, m_fail INTEGER
DEFINE m_group STRING

# The parts of a suite's JSON report the crash tests read back.
TYPE SuiteReport RECORD
    tests INTEGER,
    errors INTEGER,
    cases core.OutcomeList
END RECORD

# A representative AUI tree: two standalone FormFields (one disabled, one
# read-only, one hidden) plus a Table whose columns are TableColumn nodes —
# the exact shape inspect.fields() has to union.

MAIN
    CALL setup()

    CALL group("environment: a UTF-8 locale is active")
    CALL t_utf8_locale()

    CALL group("expect: scalar matchers")
    CALL t_expect_scalar()
    CALL group("expect: empty and NULL handling")
    CALL t_expect_empty()
    CALL group("expect: text matchers")
    CALL t_expect_text()
    CALL group("expect: numeric matchers")
    CALL t_expect_numeric()
    CALL group("expect: boolean matchers")
    CALL t_expect_boolean()
    CALL group("expect: collection matchers")
    CALL t_expect_list()
    CALL group("expect: short-circuit on driver error")
    CALL t_expect_shortcircuit()

    CALL group("inspect: AUI field parsing")
    CALL t_inspect_fields()
    CALL group("inspect: tables and cells")
    CALL t_inspect_tables()
    CALL group("inspect: actions")
    CALL t_inspect_actions()
    CALL group("inspect: fields and tables come from the current window")
    CALL t_inspect_window()
    CALL group("inspect: the runtime's error box is recognised")
    CALL t_inspect_apperror()

    CALL group("flow: verbs reach the driver")
    CALL t_flow()

    CALL group("script: action-file validation")
    CALL t_script_validation()
    CALL group("script: step dispatch")
    CALL t_script_exec()
    CALL group("script: values the parser converts cleanly are accepted")
    CALL t_script_lenient()
    CALL group("script: every declared command is dispatched")
    CALL t_script_coverage()
    CALL group("script: the JSON Schema says what the command table says")
    CALL t_schema_drift()

    CALL group("reporters: JUnit")
    CALL t_junit()
    CALL group("reporters: TAP")
    CALL t_tap()
    CALL group("reporters: JSON")
    CALL t_json()

    CALL group("cli: config defaults and path resolution")
    CALL t_cli_config()
    CALL group("cli: the suite command line")
    CALL t_cli_command()
    CALL group("cli: folding results into the exit code")
    CALL t_cli_fold()
    CALL group("cli: stale run files are cleared")
    CALL t_cli_cleanup()
    CALL group("cli: config mistakes are reported before anything runs")
    CALL t_cli_checkconfig()
    CALL group("cli: environment variables in config values")
    CALL t_cli_env()
    CALL group("cli: value types and report-name clashes")
    CALL t_cli_types_and_clashes()
    CALL group("cli: values the parser converts cleanly are accepted")
    CALL t_cli_lenient()
    CALL group("cli: every config problem is listed at once")
    CALL t_cli_all_problems()
    CALL group("cli: files fgltest did not write are left alone")
    CALL t_cli_ownership()
    CALL group("ggcdriver: which statuses end the session")
    CALL t_ggc_session()
    CALL group("cli: isolate mode enumerates each test name once")
    CALL t_cli_unique()
    CALL group("core: shell arguments are quoted for the platform")
    CALL t_core_quote()

    CALL group("runner: a process that dies still reports every test")
    CALL t_runner_uncaught()
    CALL group("runner: a trapped runtime error errors one test")
    CALL t_runner_caught()
    CALL group("runner: a failing beforeAll stops the tests, afterAll still runs")
    CALL t_runner_beforeall()
    CALL group("runner: a failing afterAll is reported")
    CALL t_runner_afterall()
    CALL group("runner: a crashed application is charged to its test")
    CALL t_runner_appcrash()
    CALL group("runner: a test name used twice is reported, not run")
    CALL t_runner_duplicates()

    CALL group("server: a server already running is not claimed")
    CALL t_server_ownership()

    CALL group("release: the version is the same everywhere")
    CALL t_version()

    CALL summary()
END MAIN

# A representative AUI tree: standalone FormFields (one disabled, one read-only,
# one hidden) plus a Table whose columns are TableColumn nodes — the exact shape
# inspect.fields() has to union.
FUNCTION aui() RETURNS STRING
    RETURN '<Form name="price">'
        || '<FormField name="formonly.name" colName="name" varType="STRING">'
        || '<Edit/></FormField>'
        || '<FormField name="formonly.price" colName="price" varType="DECIMAL" noEntry="1">'
        || '<Edit/></FormField>'
        || '<FormField name="formonly.secret" colName="secret" hidden="1"><Edit/></FormField>'
        || '<FormField name="formonly.off" colName="off" active="0"><Edit/></FormField>'
        || '<Table name="prices">'
        || '<TableColumn name="formonly.pname" colName="pname" varType="STRING"/>'
        || '<TableColumn name="formonly.pcost" colName="pcost" varType="DECIMAL" noEntry="1"/>'
        || '</Table>'
        || '</Form>'
END FUNCTION

# ------------------------------------------------------------ framework ----

FUNCTION setup()
    CALL fakedriver.reset()
    CALL core.setDriver(fakedriver.asDriver())
    CALL core.clearDriverError()
    CALL core.resetResults()
END FUNCTION

FUNCTION group(name STRING)
    LET m_group = name
    DISPLAY SFMT("# %1", name)
END FUNCTION

FUNCTION check(label STRING, cond BOOLEAN)
    IF cond THEN
        LET m_pass = m_pass + 1
        DISPLAY SFMT("ok %1 - %2", m_pass + m_fail, label)
    ELSE
        LET m_fail = m_fail + 1
        DISPLAY SFMT("not ok %1 - %2 [%3]", m_pass + m_fail, label, m_group)
    END IF
END FUNCTION

FUNCTION checkEq(label STRING, got STRING, want STRING)
    IF eq(got, want) THEN
        CALL check(label, TRUE)
    ELSE
        CALL check(SFMT("%1 (got [%2], want [%3])", label, got, want), FALSE)
    END IF
END FUNCTION

FUNCTION checkInt(label STRING, got INTEGER, want INTEGER)
    IF got == want THEN
        CALL check(label, TRUE)
    ELSE
        CALL check(SFMT("%1 (got %2, want %3)", label, got, want), FALSE)
    END IF
END FUNCTION

# "" compares as NULL in BDL, so equality needs an explicit empty-safe helper.
FUNCTION eq(a STRING, b STRING) RETURNS BOOLEAN
    IF LENGTH(a) == 0 AND LENGTH(b) == 0 THEN RETURN TRUE END IF
    IF a == b THEN RETURN TRUE END IF
    RETURN FALSE
END FUNCTION

FUNCTION contains(hay STRING, needle STRING) RETURNS BOOLEAN
    IF hay IS NULL THEN RETURN FALSE END IF
    IF hay.getIndexOf(needle, 1) > 0 THEN RETURN TRUE END IF
    RETURN FALSE
END FUNCTION

# Assertion outcomes are recorded into core; these read and reset that buffer so
# each expectation can be checked in isolation.
FUNCTION lastPassed() RETURNS BOOLEAN
    DEFINE r core.CheckResultList
    LET r = core.getResults()
    IF r.getLength() == 0 THEN RETURN FALSE END IF
    RETURN r[r.getLength()].passed
END FUNCTION

FUNCTION recorded() RETURNS INTEGER
    RETURN core.getResults().getLength()
END FUNCTION

FUNCTION clear()
    CALL core.resetResults()
END FUNCTION

FUNCTION summary()
    DISPLAY ""
    DISPLAY SFMT("1..%1", m_pass + m_fail)
    DISPLAY SFMT("selftest: %1 passed, %2 failed", m_pass, m_fail)
    IF m_fail > 0 THEN
        EXIT PROGRAM 1
    END IF
    EXIT PROGRAM 0
END FUNCTION

# ------------------------------------------------------------- expect ----

FUNCTION t_expect_scalar()
    CALL clear()
    CALL expect.that("ACME").toEqual("ACME")
    CALL check("toEqual passes on equal values", lastPassed())
    CALL clear()
    CALL expect.that("ACME").toEqual("OTHER")
    CALL check("toEqual fails on different values", NOT lastPassed())
    CALL clear()
    CALL expect.that("ACME").notToEqual("OTHER")
    CALL check("notToEqual passes on different values", lastPassed())
    CALL clear()
    CALL expect.that("ACME").notToEqual("ACME")
    CALL check("notToEqual fails on equal values", NOT lastPassed())
    CALL clear()
END FUNCTION

FUNCTION t_expect_empty()
    DEFINE nul STRING
    CALL clear()
    CALL expect.that("").toBeEmpty()
    CALL check("toBeEmpty passes on empty string", lastPassed())
    CALL clear()
    CALL expect.that(nul).toBeEmpty()
    CALL check("toBeEmpty passes on NULL", lastPassed())
    CALL clear()
    # The BDL "" == NULL trap: these must compare EQUAL, not raise or fail.
    CALL expect.that(nul).toEqual("")
    CALL check("NULL equals empty string", lastPassed())
    CALL clear()
    CALL expect.that("x").toBeEmpty()
    CALL check("toBeEmpty fails on non-empty", NOT lastPassed())
    CALL clear()
    CALL expect.that("x").notToBeEmpty()
    CALL check("notToBeEmpty passes on non-empty", lastPassed())
    CALL clear()
END FUNCTION

FUNCTION t_expect_text()
    CALL clear()
    CALL expect.that("hello world").toContainText("lo wo")
    CALL check("toContainText finds a substring", lastPassed())
    CALL clear()
    CALL expect.that("hello world").toContainText("zzz")
    CALL check("toContainText fails when absent", NOT lastPassed())
    CALL clear()
    CALL expect.that("hello world").notToContainText("zzz")
    CALL check("notToContainText passes when absent", lastPassed())
    CALL clear()
    CALL expect.that("hello world").toStartWith("hello")
    CALL check("toStartWith matches a prefix", lastPassed())
    CALL clear()
    CALL expect.that("hello world").toStartWith("world")
    CALL check("toStartWith rejects a non-prefix", NOT lastPassed())
    CALL clear()
    CALL expect.that("hello world").toEndWith("world")
    CALL check("toEndWith matches a suffix", lastPassed())
    CALL clear()
    # A suffix longer than the value must fail, not raise on subString bounds.
    CALL expect.that("ab").toEndWith("longer than value")
    CALL check("toEndWith survives an oversized suffix", NOT lastPassed())
    CALL clear()
    CALL expect.that("12.50").toMatch("^[0-9]+\.[0-9]+$")
    CALL check("toMatch honours a regex", lastPassed())
    CALL clear()
    CALL expect.that("abc").toMatch("^[0-9]+$")
    CALL check("toMatch fails on a non-match", NOT lastPassed())
    CALL clear()
    CALL expect.that("abc").notToMatch("^[0-9]+$")
    CALL check("notToMatch passes on a non-match", lastPassed())
    CALL clear()
END FUNCTION

FUNCTION t_expect_numeric()
    CALL clear()
    CALL expect.num(5).toEqual(5)
    CALL check("num toEqual passes", lastPassed())
    CALL clear()
    # The reason numeric matchers exist: "5" vs "5.0" must not matter.
    CALL expect.num(5).toEqual(5.0)
    CALL check("num toEqual ignores decimal formatting", lastPassed())
    CALL clear()
    CALL expect.num(5).toEqual(6)
    CALL check("num toEqual fails on difference", NOT lastPassed())
    CALL clear()
    CALL expect.num(5).toBeGreaterThan(4)
    CALL check("toBeGreaterThan passes", lastPassed())
    CALL clear()
    CALL expect.num(5).toBeGreaterThan(5)
    CALL check("toBeGreaterThan is strict", NOT lastPassed())
    CALL clear()
    CALL expect.num(5).toBeAtLeast(5)
    CALL check("toBeAtLeast is inclusive", lastPassed())
    CALL clear()
    CALL expect.num(5).toBeLessThan(6)
    CALL check("toBeLessThan passes", lastPassed())
    CALL clear()
    CALL expect.num(5).toBeAtMost(5)
    CALL check("toBeAtMost is inclusive", lastPassed())
    CALL clear()
    CALL expect.num(5).toBeBetween(1, 10)
    CALL check("toBeBetween passes inside the range", lastPassed())
    CALL clear()
    CALL expect.num(5).toBeBetween(5, 5)
    CALL check("toBeBetween bounds are inclusive", lastPassed())
    CALL clear()
    CALL expect.num(11).toBeBetween(1, 10)
    CALL check("toBeBetween fails outside the range", NOT lastPassed())
    CALL clear()
END FUNCTION

FUNCTION t_expect_boolean()
    CALL clear()
    CALL expect.bool(TRUE).toBeTrue()
    CALL check("toBeTrue passes on TRUE", lastPassed())
    CALL clear()
    CALL expect.bool(FALSE).toBeTrue()
    CALL check("toBeTrue fails on FALSE", NOT lastPassed())
    CALL clear()
    CALL expect.bool(FALSE).toBeFalse()
    CALL check("toBeFalse passes on FALSE", lastPassed())
    CALL clear()
END FUNCTION

FUNCTION t_expect_list()
    DEFINE l inspect.StringList
    LET l[1] = "alpha"
    LET l[2] = "beta"
    CALL clear()
    CALL expect.all(l).toContain("beta")
    CALL check("toContain finds an item", lastPassed())
    CALL clear()
    CALL expect.all(l).toContain("gamma")
    CALL check("toContain fails when absent", NOT lastPassed())
    CALL clear()
    CALL expect.all(l).notToContain("gamma")
    CALL check("notToContain passes when absent", lastPassed())
    CALL clear()
    CALL expect.all(l).toHaveSize(2)
    CALL check("toHaveSize matches the length", lastPassed())
    CALL clear()
    CALL expect.all(l).toHaveSize(3)
    CALL check("toHaveSize fails on the wrong length", NOT lastPassed())
    CALL clear()
    CALL expect.all(l).notToBeEmpty()
    CALL check("notToBeEmpty passes on a filled list", lastPassed())
    CALL clear()
    CALL expect.all(l).toContainMatch("^bet")
    CALL check("toContainMatch matches by regex", lastPassed())
    CALL clear()
    CALL expect.all(l).toContainMatch("^zzz")
    CALL check("toContainMatch fails when nothing matches", NOT lastPassed())
    CALL clear()
END FUNCTION

FUNCTION t_expect_shortcircuit()
    # While a driver error stands, matchers must record NOTHING: a pass would be
    # a lie and a failure would be noise attributed to the wrong cause.
    CALL clear()
    CALL core.setDriverError("simulated driver failure")
    CALL expect.that("a").toEqual("b")
    CALL expect.that("a").toEqual("a")
    CALL expect.num(1).toEqual(2)
    CALL expect.bool(TRUE).toBeFalse()
    CALL checkInt("matchers record nothing while errored", recorded(), 0)
    CALL core.clearDriverError()
    CALL expect.that("a").toEqual("a")
    CALL checkInt("matchers resume once cleared", recorded(), 1)
    CALL clear()
END FUNCTION

# ------------------------------------------------------------ inspect ----

FUNCTION t_inspect_fields()
    DEFINE f inspect.FieldList
    DEFINE names inspect.StringList
    DEFINE i INTEGER
    DEFINE seenTableCol BOOLEAN

    CALL fakedriver.reset()
    CALL fakedriver.setAui(aui())

    LET f = inspect.fields()
    # 4 FormField + 2 TableColumn: the union is the whole point of fields().
    CALL checkInt("fields() unions FormField and TableColumn", f.getLength(), 6)
    FOR i = 1 TO f.getLength()
        IF f[i].name == "formonly.pcost" THEN
            LET seenTableCol = TRUE
            CALL check("TableColumn noEntry is read as read-only", f[i].readOnly)
        END IF
        IF f[i].name == "formonly.name" THEN
            CALL check("a plain field is active", f[i].active)
            CALL check("a plain field is not hidden", NOT f[i].hidden)
            CALL check("a plain field is not read-only", NOT f[i].readOnly)
            CALL checkEq("widget comes from the child element", f[i].widget, "Edit")
            CALL checkEq("colName is read", f[i].colName, "name")
            CALL checkEq("varType is read", f[i].varType, "STRING")
        END IF
        IF f[i].name == "formonly.off" THEN
            # active="0" means disabled; absence of the attribute means enabled.
            CALL check("active=0 is read as inactive", NOT f[i].active)
        END IF
        IF f[i].name == "formonly.secret" THEN
            CALL check("hidden=1 is read as hidden", f[i].hidden)
        END IF
    END FOR
    CALL check("TableColumn nodes are included", seenTableCol)

    LET names = inspect.fieldNames()
    CALL checkInt("fieldNames() matches fields()", names.getLength(), 6)

    # enabled = active AND NOT hidden -> excludes .off and .secret
    LET names = inspect.enabledFields()
    CALL checkInt("enabledFields() drops inactive and hidden", names.getLength(), 4)

    # editable = enabled AND NOT read-only -> also drops .price and .pcost
    LET names = inspect.editableFields()
    CALL checkInt("editableFields() also drops read-only", names.getLength(), 2)
END FUNCTION

FUNCTION t_inspect_tables()
    DEFINE t inspect.StringList
    CALL fakedriver.reset()
    CALL fakedriver.setAui(aui())
    CALL fakedriver.setTable(5, 2)
    CALL fakedriver.setCell("prices", "pname", 3, "Blue Scissors")

    LET t = inspect.tables()
    CALL checkInt("tables() finds the Table node", t.getLength(), 1)
    CALL checkEq("tables() reports the AUI name", t[1], "prices")
    CALL checkInt("rowCount() is the model size", inspect.rowCount("prices"), 5)
    CALL checkInt("currentRow() is the focused row", inspect.currentRow("prices"), 2)
    CALL checkEq("cellValue() reads an explicit row",
        inspect.cellValue("prices", "pname", 3), "Blue Scissors")

    # currentCellValue must read the CURRENT row, not a fixed one.
    CALL fakedriver.setCell("prices", "pname", 2, "Globe")
    CALL checkEq("currentCellValue() follows the current row",
        inspect.currentCellValue("prices", "pname"), "Globe")
END FUNCTION

FUNCTION t_inspect_actions()
    DEFINE names inspect.StringList
    CALL fakedriver.reset()
    CALL fakedriver.addAction("edit", TRUE)
    CALL fakedriver.addAction("cancel", TRUE)
    CALL fakedriver.addAction("save", FALSE)

    LET names = inspect.actionNames()
    CALL checkInt("actionNames() lists every action", names.getLength(), 3)
    LET names = inspect.activeActionNames()
    CALL checkInt("activeActionNames() lists only active ones", names.getLength(), 2)
    CALL check("hasAction() finds a known action", inspect.hasAction("save"))
    CALL check("hasAction() rejects an unknown action", NOT inspect.hasAction("nope"))
END FUNCTION

# --------------------------------------------------------------- flow ----

FUNCTION t_flow()
    CALL fakedriver.reset()
    CALL flow.field("custname")
    CALL flow.enter("ACME")
    CALL flow.fill("city", "Paris")
    CALL flow.action("accept")
    CALL flow.press("F5")
    CALL flow.selectRow("prices", 3)
    CALL flow.focusCell("prices", "pname", 2)
    CALL flow.clear()

    CALL checkInt("every verb reaches the driver", fakedriver.logCount(), 8)
    CALL checkEq("field() focuses", fakedriver.logAt(1), "focus(custname)")
    CALL checkEq("enter() types", fakedriver.logAt(2), "enter(ACME)")
    CALL checkEq("fill() sets by name", fakedriver.logAt(3), "setField(city,Paris)")
    CALL checkEq("action() triggers", fakedriver.logAt(4), "action(accept)")
    CALL checkEq("press() sends a key", fakedriver.logAt(5), "press(F5)")
    CALL checkEq("selectRow() navigates", fakedriver.logAt(6), "selectRow(prices,3)")
    CALL checkEq("focusCell() navigates", fakedriver.logAt(7), "focusCell(prices,pname,2)")
    CALL checkEq("clear() enters an empty value", fakedriver.logAt(8), "enter()")
END FUNCTION

# ------------------------------------------------------------- script ----

FUNCTION writeTmp(path STRING, content STRING)
    DEFINE ch base.Channel
    LET ch = base.Channel.create()
    CALL ch.openFile(path, "w")
    CALL ch.writeLine(content)
    CALL ch.close()
END FUNCTION

FUNCTION t_script_validation()
    DEFINE p, err STRING
    DEFINE ok INTEGER

    LET p = "selftest_actions.json"

    # A well-formed file loads cleanly.
    CALL writeTmp(p,
        '{"application":"app","tests":[{"name":"t","steps":['
        || '{"command":"action","target":"edit"}]}]}')
    LET err = script.load(p)
    CALL check("a valid action file loads", err IS NULL)
    CALL checkInt("testCount() sees the test", script.testCount(), 1)
    CALL checkEq("testName() reads the name", script.testName(1), "t")

    # An unknown command must be rejected up front, naming the command.
    CALL writeTmp(p,
        '{"application":"app","tests":[{"name":"t","steps":['
        || '{"command":"nosuchcommand","target":"x"}]}]}')
    LET err = script.load(p)
    CALL check("an unknown command is rejected", err IS NOT NULL)
    CALL check("the message names the bad command", contains(err, "nosuchcommand"))

    # A command missing its required target is a typo worth catching early.
    CALL writeTmp(p,
        '{"application":"app","tests":[{"name":"t","steps":['
        || '{"command":"action"}]}]}')
    LET err = script.load(p)
    CALL check("a missing target is rejected", err IS NOT NULL)
    CALL check("the message says target", contains(err, "target"))

    # ... and a missing value likewise.
    CALL writeTmp(p,
        '{"application":"app","tests":[{"name":"t","steps":['
        || '{"command":"assertFormName"}]}]}')
    LET err = script.load(p)
    CALL check("a missing value is rejected", err IS NOT NULL)
    CALL check("the message says value", contains(err, "value"))

    # Structural problems.
    CALL writeTmp(p, '{"application":"app","tests":[]}')
    LET err = script.load(p)
    CALL check("an empty test list is rejected", err IS NOT NULL)

    CALL writeTmp(p, '{"tests":[{"name":"t","steps":[{"command":"clear"}]}]}')
    LET err = script.load(p)
    CALL check("a missing application is rejected", err IS NOT NULL)

    CALL writeTmp(p, 'this is not json at all')
    LET err = script.load(p)
    CALL check("malformed JSON is rejected", err IS NOT NULL)

    LET err = script.load("no_such_file_at_all.json")
    CALL check("a missing file is rejected", err IS NOT NULL)

    # Table commands need their column and row; counts must be numbers.
    CALL writeTmp(p,
        '{"application":"app","tests":[{"name":"t","steps":['
        || '{"command":"assertCellAtRow","target":"prices","value":"x"},'
        || '{"command":"selectRow","target":"prices","row":0},'
        || '{"command":"assertRowCount","target":"prices","value":"five"},'
        || '{"command":"pause","value":"1.5"}]}]}')
    LET err = script.load(p)
    CALL check("a missing column is rejected", contains(err, 'step 1: command \'assertCellAtRow\' needs a "column"'))
    CALL check("a missing row is rejected", contains(err, 'step 1: command \'assertCellAtRow\' needs a "row"'))
    CALL check("a row below 1 is rejected", contains(err, 'step 2: command \'selectRow\' needs a "row"'))
    CALL check("a non-numeric count is rejected", contains(err, "not 'five'"))
    CALL check("a fractional delay is rejected", contains(err, "not '1.5'"))

    # Two tests may not share a name: reports and isolate mode tell them apart by it.
    CALL writeTmp(p,
        '{"application":"app","tests":['
        || '{"name":"same","steps":[{"command":"clear"}]},'
        || '{"name":"same","steps":[{"command":"clear"}]}]}')
    LET err = script.load(p)
    CALL check("a repeated test name is rejected", contains(err, "test #2 reuses the name 'same' of test #1"))

    # Keys the parser would drop, and values it would truncate or nullify.
    CALL writeTmp(p,
        '{"application":"app","$comment":"ok","_note":"ok","tests":[{"name":"t","skipp":true,"steps":['
        || '{"command":"selectRow","target":"t","row":1.5},'
        || '{"command":"selectRow","target":"t","row":"three"},'
        || '{"command":"selectRow","target":"t","Row":2},'
        || '{"command":"clear","row":0}]}]}')
    LET err = script.load(p)
    CALL check("an unknown test key is rejected", contains(err, "test 't': unknown key \"skipp\""))
    CALL check("a fractional row is rejected", contains(err, "test 't' step 1: \"row\" must be a whole number, not 1.5"))
    CALL check("a row that is not a number is rejected", contains(err, "step 2: \"row\" must be a whole number, not the string \"three\""))
    CALL check("a json_name key must be spelled exactly", contains(err, "step 3: unknown key \"Row\""))
    CALL check("a row below 1 is rejected on any command", contains(err, "step 4: \"row\" must be 1 or more"))
    CALL check("$ and _ keys are allowed", NOT contains(err, "comment") AND NOT contains(err, "_note"))

    # The parser matches plain member names without regard to case, so must the checks.
    CALL writeTmp(p,
        '{"Application":"app","Tests":[{"Name":"t","Steps":['
        || '{"Command":"assertRowCount","Target":"p","Value":5}]}]}')
    LET err = script.load(p)
    CALL check("keys in another case, and a numeric value, load", err IS NULL)
    IF err IS NOT NULL THEN
        DISPLAY "# ", err
    END IF

    CALL checkEq("requirements() describes a command", script.requirements("assertCellAtRow"), "tcrv")
    CALL checkEq("a command needing nothing says so", script.requirements("clear"), "-")
    CALL check("an unknown command has no requirements", script.requirements("nosuch") IS NULL)

    # skip / only flags survive the round trip.
    CALL writeTmp(p,
        '{"application":"app","tests":['
        || '{"name":"a","skip":true,"steps":[{"command":"clear"}]},'
        || '{"name":"b","only":true,"steps":[{"command":"clear"}]}]}')
    LET err = script.load(p)
    CALL check("skip/only file loads", err IS NULL)
    CALL check("skip is parsed", script.testIsSkipped(1))
    CALL check("only is parsed", script.testIsOnly(2))
    CALL check("unmarked tests are neither", NOT script.testIsSkipped(2))

    LET ok = os.Path.delete(p)
END FUNCTION

FUNCTION t_script_exec()
    DEFINE steps script.StepList
    DEFINE p, err STRING
    DEFINE ok INTEGER

    CALL fakedriver.reset()
    CALL core.clearDriverError()
    CALL clear()
    CALL fakedriver.setForm("price", "Prices")
    CALL fakedriver.setTable(5, 1)
    CALL fakedriver.setCell("prices", "pname", 1, "Globe")
    CALL fakedriver.setFieldValue("formonly.price", "9.99")

    LET p = "selftest_actions.json"
    # column/row use json_name mappings, so this also covers that binding.
    CALL writeTmp(p,
        '{"application":"price","tests":[{"name":"t","steps":['
        || '{"command":"fill","target":"formonly.price","value":"9.99"},'
        || '{"command":"assertField","target":"formonly.price","value":"9.99"},'
        || '{"command":"assertFormName","value":"price"},'
        || '{"command":"assertRowCount","target":"prices","value":"5"},'
        || '{"command":"assertRowCountAtLeast","target":"prices","value":"3"},'
        || '{"command":"assertCell","target":"prices","column":"pname","value":"Globe"},'
        || '{"command":"assertFieldContains","target":"formonly.price","value":"9."}'
        || ']}]}')
    LET err = script.load(p)
    CALL check("dispatch fixture loads", err IS NULL)

    LET steps = script.testStepsAt(1)
    CALL checkInt("all steps are parsed", steps.getLength(), 7)
    CALL script.exec(steps)
    CALL checkInt("every assertion is recorded", recorded(), 6)
    CALL checkInt("none of them failed", core.failCount(), 0)

    # A driver error must stop the remaining steps dead.
    CALL clear()
    CALL core.setDriverError("simulated")
    CALL script.exec(steps)
    CALL checkInt("exec stops at an outstanding driver error", recorded(), 0)
    CALL core.clearDriverError()
    CALL clear()

    LET ok = os.Path.delete(p)
END FUNCTION

# Every command the validator accepts must also be handled by exec(): the two
# lists live in different CASE blocks, and a command present in one but not the
# other would either be rejected wrongly or silently fail a user's test at
# runtime. Run each one through exec() and assert it is never "unknownCommand".
FUNCTION t_script_coverage()
    DEFINE cmds inspect.StringList
    DEFINE i INTEGER

    CALL fakedriver.reset()
    CALL fakedriver.setAui(aui())
    CALL core.clearDriverError()
    # Every command in the table, so a new one cannot be added without exec().
    LET cmds = script.commands()
    CALL checkInt("the command table lists 38 commands", cmds.getLength(), 38)
    FOR i = 1 TO cmds.getLength()
        CALL one(cmds[i])
    END FOR
END FUNCTION

FUNCTION one(cmd STRING)
    DEFINE steps script.StepList
    CALL clear()
    LET steps[1].command = cmd
    LET steps[1].target = "prices"
    LET steps[1].col = "pname"
    LET steps[1].rowNum = 1
    LET steps[1].value = "1"
    CALL script.exec(steps)
    CALL check(SFMT("exec() handles '%1'", cmd), NOT sawUnknown())
    CALL clear()
END FUNCTION

FUNCTION sawUnknown() RETURNS BOOLEAN
    DEFINE r core.CheckResultList
    DEFINE i INTEGER
    LET r = core.getResults()
    FOR i = 1 TO r.getLength()
        IF r[i].message == "unknownCommand" THEN
            RETURN TRUE
        END IF
    END FOR
    RETURN FALSE
END FUNCTION

# ---------------------------------------------------------- reporters ----

# Build a representative outcome list: one pass, one failure, one error, one skip.
FUNCTION sampleOutcomes() RETURNS core.OutcomeList
    DEFINE o core.OutcomeList
    LET o[1].name = "passing test"
    LET o[1].passed = TRUE
    LET o[1].checks = 2
    LET o[1].duration = 0.25

    LET o[2].name = "failing test"
    LET o[2].passed = FALSE
    LET o[2].checks = 1
    LET o[2].failed = 1
    LET o[2].duration = 0.5
    LET o[2].messages[1] = 'toEqual: expected <a> & "b"'

    LET o[3].name = "errored test"
    LET o[3].passed = FALSE
    LET o[3].errored = TRUE
    LET o[3].duration = 0.1
    LET o[3].messages[1] = "driver error: (GGC-7) not found"

    LET o[4].name = "skipped test"
    LET o[4].skipped = TRUE
    RETURN o
END FUNCTION

FUNCTION t_junit()
    DEFINE x STRING
    DEFINE o core.OutcomeList
    LET x = reporters.toJUnit(sampleOutcomes(), "suite<&>")

    CALL check("declares the XML prolog", contains(x, '<?xml version="1.0" encoding="UTF-8"?>'))
    CALL check("counts tests", contains(x, 'tests="4"'))
    # An assertion failure and a test that could not run are different things.
    CALL check("counts failures separately", contains(x, 'failures="1"'))
    CALL check("counts errors separately", contains(x, 'errors="1"'))
    CALL check("counts skips", contains(x, 'skipped="1"'))
    CALL check("emits <failure> for an assertion failure", contains(x, "<failure message="))
    CALL check("emits <error> for a test that could not run", contains(x, "<error message="))
    CALL check("emits <skipped/>", contains(x, "<skipped/>"))
    CALL check("carries per-test time", contains(x, 'time="0.250"'))
    # The skipped outcome deliberately has no duration set. In BDL x + NULL is
    # NULL, so an unguarded total would come out as 0.000 for the whole suite.
    CALL check("totals durations across outcomes, ignoring unset ones",
        contains(x, 'time="0.850"'))
    CALL check("an outcome with no duration renders as 0.000",
        contains(x, 'name="skipped test" classname="suite&lt;&amp;&gt;" time="0.000"'))
    CALL check("carries a timestamp", contains(x, "timestamp="))
    # Escaping matters: an unescaped & or < makes the report unparseable, which
    # in CI looks exactly like "the tests did not run".
    CALL check("escapes & in the suite name", contains(x, "suite&lt;&amp;&gt;"))
    CALL check("escapes < in a message", contains(x, "&lt;a&gt;"))
    CALL check("escapes quotes in a message", contains(x, "&quot;b&quot;"))
    CALL check("leaves no raw ampersand", NOT contains(x, "<&>"))
    LET o = sampleOutcomes()
    LET o[2].messages[1] = "esc" || (ASCII 27) || " ff" || (ASCII 12) || " café"
    LET x = reporters.toJUnit(o, "s")
    CALL check("JUnit drops control characters XML forbids", contains(x, "esc ff café"))
END FUNCTION

FUNCTION t_tap()
    DEFINE x STRING
    DEFINE o core.OutcomeList
    LET x = reporters.toTAP(sampleOutcomes())
    CALL check("declares the TAP version", contains(x, "TAP version 13"))
    CALL check("declares the plan", contains(x, "1..4"))
    CALL check("reports a pass", contains(x, "ok 1 - passing test"))
    CALL check("reports a failure", contains(x, "not ok 2 - failing test"))
    CALL check("marks an errored test", contains(x, "not ok 3 - errored test # ERROR"))
    # TAP has no "skip" result: a skip is an ok with a SKIP directive.
    CALL check("marks a skip with the SKIP directive", contains(x, "ok 4 - skipped test # SKIP"))
    CALL check("emits a YAML diagnostic block", contains(x, "  ---"))
    CALL check("gives a failure's severity", contains(x, "  severity: fail"))
    CALL check("gives an error's severity", contains(x, "  severity: error"))
    CALL check("quotes the message as a YAML string",
        contains(x, '  message: "toEqual: expected <a> & \\"b\\""'))
    CALL check("lists every message", contains(x, '  messages:' || (ASCII 10) || '    - "'))
    CALL check("never repeats a key", NOT contains(x, '  message: "driver error: (GGC-7) not found"' || (ASCII 10) || '  message:'))
    LET o = sampleOutcomes()
    LET o[1].name = "pays #1 invoice"
    LET x = reporters.toTAP(o)
    CALL check("escapes # in a test name so it is not a directive", contains(x, "ok 1 - pays \\#1 invoice"))
    LET o[2].messages[1] = "café — naïve ü 日本"
    LET o[2].messages[2] = "bell" || (ASCII 7) || " del" || (ASCII 127) || " end"
    LET x = reporters.toTAP(o)
    CALL check("non-ASCII text in a message is kept intact", contains(x, '"café — naïve ü 日本"'))
    CALL check("control characters and DEL are dropped", contains(x, '"bell del end"'))
    LET o[2].messages[2] = "c1" || util.Strings.urlDecode("%C2%90") || " nel"
        || util.Strings.urlDecode("%C2%85") || " end"
    LET x = reporters.toTAP(o)
    CALL check("C1 control characters are dropped, NEL kept",
        contains(x, '"c1 nel' || util.Strings.urlDecode("%C2%85") || ' end"'))
END FUNCTION

FUNCTION t_json()
    DEFINE x STRING
    LET x = reporters.toJSON(sampleOutcomes(), "mysuite")
    CALL check("names the suite", contains(x, '"suite":"mysuite"'))
    CALL check("counts tests", contains(x, '"tests":4'))
    CALL check("counts passes", contains(x, '"passed":1'))
    CALL check("counts errors", contains(x, '"errors":1'))
    # failed and errors are disjoint, as in JUnit: the errored test is not a failure too.
    CALL check("counts only real failures as failed", contains(x, '"failed":1'))
    CALL check("counts skips", contains(x, '"skipped":1'))
    CALL check("totals durations", contains(x, '"duration":0.85'))
    CALL check("includes the cases array", contains(x, '"cases":['))
    CALL check("carries the errored flag", contains(x, '"errored":true'))
    CALL check("carries the skipped flag", contains(x, '"skipped":true'))
END FUNCTION

# ---------------------------------------------------------------- cli ----

FUNCTION t_cli_config()
    DEFINE c1, c2, c3, c4, c5, c6, c7 cli.Config
    DEFINE err STRING

    # An absent "port" parses as NULL, not 0: the default must still apply.
    CALL util.JSON.parse('{"suites":[]}', c1)
    CALL check("an absent port parses as NULL (the trap being guarded)", c1.port IS NULL)
    LET err = cli.normalize(c1, "fgltest.json", "/opt/pkg/com/fourjs/fgltest/")
    CALL checkInt("an absent port defaults to 6500", c1.port, 6500)
    CALL checkEq("reporters default", c1.reporters, "console,junit,json")
    CALL checkEq("outdir defaults to the config's directory", c1.outdir, ".")
    # fglrun resolves a program path against the current directory only, never
    # FGLLDPATH, so the default runner must come from the CLI's own location.
    CALL checkEq("jsonRunner defaults to the program beside the CLI",
        c1.jsonRunner, os.Path.join("/opt/pkg/com/fourjs/fgltest/", "fgltest_json"))

    CALL util.JSON.parse('{"port":0,"suites":[]}', c2)
    LET err = cli.normalize(c2, "fgltest.json", "/opt/pkg/")
    CALL check("port 0 is rejected, not silently replaced", contains(err, '"port" must be a port number'))

    CALL util.JSON.parse('{"port":7000,"suites":[]}', c3)
    LET err = cli.normalize(c3, "fgltest.json", "/opt/pkg/")
    CALL checkInt("an explicit port is kept", c3.port, 7000)

    # Relative paths resolve against the config file's directory, so the config
    # means the same thing whatever the current directory (fglpkg bdl runs the
    # CLI inside the installed package). Absolute paths are left alone.
    CALL util.JSON.parse('{"outdir":"results","jsonRunner":"bin/runner",'
        || '"discover":{"dir":"t","workdir":"app"},"suites":['
        || '{"name":"a","module":"tests/a_test","workdir":"app"},'
        || '{"name":"b","actions":"/abs/b.actions.json","workdir":"/abs/app"}]}', c4)
    LET err = cli.normalize(c4, os.Path.join("conf", "fgltest.json"), "/opt/pkg/")
    CALL checkEq("outdir resolves against the config dir", c4.outdir, os.Path.join("conf", "results"))
    CALL checkEq("an explicit jsonRunner resolves against the config dir",
        c4.jsonRunner, os.Path.join("conf", "bin/runner"))
    CALL checkEq("discover.dir resolves", c4.discover.dir, os.Path.join("conf", "t"))
    CALL checkEq("discover.workdir resolves", c4.discover.workdir, os.Path.join("conf", "app"))
    CALL checkEq("a suite module resolves", c4.suites[1].module, os.Path.join("conf", "tests/a_test"))
    CALL checkEq("a suite workdir resolves", c4.suites[1].workdir, os.Path.join("conf", "app"))
    CALL checkEq("an absolute actions path is kept", c4.suites[2].actions, "/abs/b.actions.json")
    CALL checkEq("an absolute workdir is kept", c4.suites[2].workdir, "/abs/app")
    CALL checkEq("the default outdir is the config dir",
        cli.resolvePath("conf", "."), "conf")

    # A config in the current directory leaves every path exactly as written.
    CALL util.JSON.parse('{"suites":[{"name":"a","module":"tests/a_test","workdir":"app"}]}', c5)
    LET err = cli.normalize(c5, "fgltest.json", "/opt/pkg/")
    CALL checkEq("a config in the current dir keeps paths as written",
        c5.suites[1].module, "tests/a_test")
    CALL check("an unset path stays unset", LENGTH(c5.suites[1].actions) == 0)
    CALL check("a valid config normalizes without error", err IS NULL)

    # FGLTEST_PORT lets concurrent runs on one machine each take a server.
    CALL fgl_setenv("FGLTEST_PORT", "7123")
    CALL util.JSON.parse('{"port":7000,"suites":[]}', c6)
    LET err = cli.normalize(c6, "fgltest.json", "/opt/pkg/")
    CALL checkInt("FGLTEST_PORT overrides the config's port", c6.port, 7123)
    CALL fgl_setenv("FGLTEST_PORT", "not-a-port")
    LET err = cli.normalize(c6, "fgltest.json", "/opt/pkg/")
    CALL check("a non-numeric FGLTEST_PORT is rejected", contains(err, "FGLTEST_PORT"))
    CALL fgl_setenv("FGLTEST_PORT", "")
    CALL util.JSON.parse('{"port":70000,"suites":[]}', c7)
    LET err = cli.normalize(c7, "fgltest.json", "/opt/pkg/")
    CALL check("an out-of-range port is rejected", contains(err, "port"))
END FUNCTION

FUNCTION t_cli_command()
    DEFINE cfg cli.Config
    DEFINE s cli.SuiteCfg
    DEFINE cmd STRING

    LET cfg.port = 7001
    LET cfg.jsonRunner = "/opt/pkg/fgltest_json"
    LET s.module = "tests/a_test"
    LET s.mode = "tcp"
    LET s.workdir = "app"
    LET s.commandLine = "fglrun app"
    LET cmd = cli.suiteCommand(cfg, s, "out/a.log")
    # ggc connects to 6500 unless told otherwise: the configured port must be
    # passed to every suite, not just used to start the server.
    CALL check("tcp: the suite is told the server port", contains(cmd, " tcp --port 7001 "))
    CALL check("tcp: the program path is quoted", contains(cmd, 'fglrun "tests/a_test" tcp'))
    CALL check("tcp: passes the working directory", contains(cmd, '--working-directory "app"'))
    CALL check("tcp: passes the command line", contains(cmd, '--command-line "fglrun app"'))
    CALL check("output goes to the log", contains(cmd, '> "out/a.log" 2>&1'))

    # Quotes inside the command line must survive the shell.
    LET s.commandLine = 'fglrun app --title "Big Co"'
    LET cmd = cli.suiteCommand(cfg, s, "out/a.log")
    CALL check("quotes in the command line are escaped",
        contains(cmd, '--command-line "fglrun app --title \\"Big Co\\""'))
    LET s.commandLine = NULL
    LET cmd = cli.suiteCommand(cfg, s, "out/a.log")
    CALL check("an empty command line is left to ggc's default", NOT contains(cmd, "--command-line"))

    LET s.mode = "ua"
    LET s.url = "http://host/ua/r/app"
    LET cmd = cli.suiteCommand(cfg, s, "out/a.log")
    CALL check("ua: the suite is told the server port", contains(cmd, " ua --port 7001 "))
    CALL check("ua: passes the url", contains(cmd, '--url "http://host/ua/r/app"'))

    LET s.mode = "tcp"
    LET s.actions = "a.actions.json"
    LET cmd = cli.suiteCommand(cfg, s, "out/a.log")
    CALL check("an action suite runs via jsonRunner",
        contains(cmd, 'fglrun "/opt/pkg/fgltest_json" tcp'))
END FUNCTION

# One suite result folded into a fresh aggregate.
FUNCTION folded(sr cli.SuiteResult, completed BOOLEAN, timedOut BOOLEAN) RETURNS cli.Summary
    DEFINE agg cli.Summary
    CALL cli.fold(agg, sr, completed, timedOut)
    RETURN agg
END FUNCTION

FUNCTION result(tests INTEGER, passed INTEGER, failed INTEGER, errors INTEGER) RETURNS cli.SuiteResult
    DEFINE sr cli.SuiteResult
    INITIALIZE sr TO NULL
    LET sr.tests = tests
    LET sr.passed = passed
    LET sr.failed = failed
    LET sr.errors = errors
    LET sr.skipped = 0
    RETURN sr
END FUNCTION

FUNCTION t_cli_fold()
    DEFINE agg, total cli.Summary
    DEFINE none cli.SuiteResult

    LET agg = folded(result(3, 3, 0, 0), TRUE, FALSE)
    CALL checkInt("a completed run counts its tests", agg.tests, 3)
    CALL checkInt("a clean completed run exits 0", cli.exitCode(agg), 0)

    # A suite report's counts are disjoint: failed (checks that did not hold)
    # and errors (could not run) are added as they are.
    LET agg = folded(result(3, 1, 1, 1), TRUE, FALSE)
    CALL checkInt("failures are counted as reported", agg.failed, 1)
    CALL checkInt("errors are counted", agg.errors, 1)
    CALL checkInt("failures and errors exit 1", cli.exitCode(agg), 1)

    # The false green: a process that died after writing passing results.
    LET agg = folded(result(1, 1, 0, 0), FALSE, FALSE)
    CALL checkInt("passing partial results without the marker are incomplete", agg.incomplete, 1)
    CALL checkInt("an incomplete suite exits 1, whatever its results say", cli.exitCode(agg), 1)

    INITIALIZE none TO NULL
    LET agg = folded(none, FALSE, FALSE)
    CALL checkInt("no report at all is an error", agg.errors, 1)
    CALL checkInt("no report at all exits 1", cli.exitCode(agg), 1)

    LET agg = folded(result(2, 2, 0, 0), FALSE, TRUE)
    CALL checkInt("a watchdog timeout is counted", agg.timedOut, 1)
    CALL checkInt("a timed-out suite exits 1 even with passing results", cli.exitCode(agg), 1)

    # A report missing some counts must not blank the aggregate (x + NULL is NULL).
    INITIALIZE none TO NULL
    LET none.tests = 2
    LET none.passed = 2
    LET agg = folded(none, TRUE, FALSE)
    CALL checkInt("absent counts read as 0 (failed)", agg.failed, 0)
    CALL checkInt("absent counts read as 0 (skipped)", agg.skipped, 0)
    CALL checkInt("a report with absent counts still exits 0", cli.exitCode(agg), 0)

    CALL cli.add(total, folded(result(2, 2, 0, 0), TRUE, FALSE))
    CALL cli.add(total, folded(result(1, 1, 0, 0), FALSE, FALSE))
    CALL checkInt("add() totals tests", total.tests, 3)
    CALL checkInt("add() totals incomplete processes", total.incomplete, 1)
    CALL checkInt("one incomplete suite fails the whole run", cli.exitCode(total), 1)
END FUNCTION

FUNCTION t_cli_cleanup()
    DEFINE dir STRING
    DEFINE ok INTEGER

    LET dir = os.Path.makeTempName()
    LET ok = os.Path.mkDir(dir)
    CALL report(dir, "s.json")
    CALL report(dir, "s.junit.xml")
    CALL report(dir, "s.tap")
    CALL report(dir, "s.done")
    CALL touch(dir, "s.log")
    CALL touch(dir, "s.tests")
    CALL report(dir, "s.1.json")
    CALL report(dir, "s.12.junit.xml")
    CALL report(dir, "s.3.done")
    CALL touch(dir, "s.2.log")
    CALL touch(dir, "s.x.json")
    CALL touch(dir, "s-json.1.json")
    CALL touch(dir, "fgltest.json")

    CALL check("clearing stale reports succeeds", cli.clearRunFiles(dir, "s") IS NULL)
    CALL check("a stale report is removed before a run", NOT there(dir, "s.json"))
    CALL check("a stale JUnit report is removed", NOT there(dir, "s.junit.xml"))
    CALL check("a stale TAP report is removed", NOT there(dir, "s.tap"))
    CALL check("a stale completion marker is removed", NOT there(dir, "s.done"))
    CALL check("the suite's old log is removed", NOT there(dir, "s.log"))
    CALL check("an old test list from isolate mode is removed", NOT there(dir, "s.tests"))
    CALL check("other suites' files are left alone", there(dir, "s-json.1.json"))
    CALL check("the config is left alone", there(dir, "fgltest.json"))

    CALL check("clearing old per-test reports succeeds", cli.clearIsolatedFiles(dir, "s") IS NULL)
    CALL check("old per-test reports are removed", NOT there(dir, "s.1.json"))
    CALL check("old per-test reports of any number are removed", NOT there(dir, "s.12.junit.xml"))
    CALL check("old per-test markers are removed", NOT there(dir, "s.3.done"))
    CALL check("old per-test logs are removed", NOT there(dir, "s.2.log"))
    CALL check("a non-numbered name is not mistaken for one", there(dir, "s.x.json"))
    CALL check("a suite sharing a prefix is left alone", there(dir, "s-json.1.json"))
    CALL check("cleanup never touches the config", there(dir, "fgltest.json"))
    CALL check("isIsolatedFile rejects the suite's own report", NOT cli.isIsolatedFile("s.json", "s"))

    # A stale report that cannot be removed would be read back as new results.
    LET ok = os.Path.mkDir(os.Path.join(dir, "stuck.json"))
    CALL touch(dir, "stuck.json/keep")
    CALL check("a report that cannot be removed is reported",
        contains(cli.clearRunFiles(dir, "stuck"), "stuck.json"))
    LET ok = os.Path.delete(os.Path.join(dir, "stuck.json/keep"))

    CALL removeDir(dir)
END FUNCTION

# A file with the content fgltest writes for a report of that type.
FUNCTION report(dir STRING, name STRING)
    DEFINE c STRING
    CASE
        WHEN name MATCHES "*.junit.xml" LET c = '<?xml version="1.0"?><testsuites tests="0"></testsuites>'
        WHEN name MATCHES "*.json" LET c = '{"suite":"s","tests":0,"cases":[]}'
        WHEN name MATCHES "*.tap" LET c = "TAP version 13"
        WHEN name MATCHES "*.done" LET c = "done"
    END CASE
    CALL writeTmp(os.Path.join(dir, name), c)
END FUNCTION

FUNCTION touch(dir STRING, name STRING)
    CALL writeTmp(os.Path.join(dir, name), "x")
END FUNCTION

FUNCTION there(dir STRING, name STRING) RETURNS BOOLEAN
    IF os.Path.exists(os.Path.join(dir, name)) THEN
        RETURN TRUE
    END IF
    RETURN FALSE
END FUNCTION

# Delete a scratch directory and the files in it.
FUNCTION removeDir(dir STRING)
    DEFINE h, ok INTEGER
    DEFINE entry STRING
    LET h = os.Path.dirOpen(dir)
    IF h > 0 THEN
        WHILE TRUE
            LET entry = os.Path.dirNext(h)
            IF entry IS NULL THEN
                EXIT WHILE
            END IF
            IF entry != "." AND entry != ".." THEN
                LET ok = os.Path.delete(os.Path.join(dir, entry))
            END IF
        END WHILE
        CALL os.Path.dirClose(h)
    END IF
    LET ok = os.Path.delete(dir)
END FUNCTION

# -------------------------------------------------------------- runner ----

# Run tests/runnersuite in `mode` with its reports in `dir`; return the RUN
# status and the parsed JSON report (rep.tests NULL if none was written).
FUNCTION runSuite(mode STRING, dir STRING) RETURNS (INTEGER, SuiteReport)
    DEFINE prog, txt, err STRING
    DEFINE st INTEGER
    DEFINE rep SuiteReport

    LET prog = os.Path.join(base.Application.getProgramDir(), "runnersuite")
    CALL fgl_setenv("FGLTEST_REPORTERS", "json")
    CALL fgl_setenv("FGLTEST_OUTDIR", dir)
    CALL fgl_setenv("FGLTEST_NAME", "crash")
    CALL fgl_setenv("FGLTEST_ONLY", fgl_getenv("SELFTEST_ONLY"))
    CALL fgl_setenv("FGLTEST_TIMEOUT", "")
    LET err = cli.clearRunFiles(dir, "crash")
    RUN SFMT('fglrun "%1" %2 > "%3" 2>&1', prog, mode,
        os.Path.join(dir, mode || ".log")) RETURNING st
    CALL fgl_setenv("FGLTEST_REPORTERS", "")
    CALL fgl_setenv("FGLTEST_OUTDIR", "")
    CALL fgl_setenv("FGLTEST_NAME", "")
    CALL fgl_setenv("FGLTEST_ONLY", "")

    INITIALIZE rep.tests TO NULL
    LET txt = readTmp(os.Path.join(dir, "crash.json"))
    IF txt IS NOT NULL THEN
        TRY
            CALL util.JSON.parse(txt, rep)
        CATCH
            INITIALIZE rep.tests TO NULL
        END TRY
    END IF
    RETURN st, rep
END FUNCTION

FUNCTION readTmp(path STRING) RETURNS STRING
    DEFINE ch base.Channel
    DEFINE b base.StringBuffer
    DEFINE line STRING
    LET ch = base.Channel.create()
    TRY
        CALL ch.openFile(path, "r")
    CATCH
        RETURN NULL
    END TRY
    LET b = base.StringBuffer.create()
    WHILE (line := ch.readLine()) IS NOT NULL
        CALL b.append(line)
    END WHILE
    CALL ch.close()
    RETURN b.toString()
END FUNCTION

# The message list of outcome `i` as one string, for substring checks.
FUNCTION caseText(rep SuiteReport, i INTEGER) RETURNS STRING
    DEFINE b base.StringBuffer
    DEFINE k INTEGER
    LET b = base.StringBuffer.create()
    IF i > rep.cases.getLength() THEN
        RETURN NULL
    END IF
    FOR k = 1 TO rep.cases[i].messages.getLength()
        CALL b.append(rep.cases[i].messages[k])
        CALL b.append(" | ")
    END FOR
    RETURN b.toString()
END FUNCTION

FUNCTION t_runner_uncaught()
    DEFINE dir STRING
    DEFINE st, ok INTEGER
    DEFINE rep SuiteReport

    LET dir = os.Path.makeTempName()
    LET ok = os.Path.mkDir(dir)
    CALL runSuite("uncaught", dir) RETURNING st, rep

    CALL check("an uncaught runtime error stops the suite process", st != 0)
    CALL check("a report is still on disk", rep.tests IS NOT NULL)
    CALL checkInt("the report accounts for every registered test", rep.tests, 3)
    IF rep.cases.getLength() == 3 THEN
        CALL check("the test before the error keeps its pass", core.isTrue(rep.cases[1].passed))
        CALL check("the test in progress is reported as errored", core.isTrue(rep.cases[2].errored))
        CALL check("... as one that did not complete", contains(caseText(rep, 2), "did not complete"))
        CALL check("the test never reached is reported as errored", core.isTrue(rep.cases[3].errored))
        CALL check("... as one that was not run", contains(caseText(rep, 3), "not run"))
    ELSE
        CALL check("the report lists three cases", FALSE)
    END IF
    CALL check("no completion marker is written", NOT there(dir, "crash.done"))

    CALL removeDir(dir)
END FUNCTION

FUNCTION t_runner_caught()
    DEFINE dir STRING
    DEFINE st, ok INTEGER
    DEFINE rep SuiteReport

    LET dir = os.Path.makeTempName()
    LET ok = os.Path.mkDir(dir)
    CALL runSuite("caught", dir) RETURNING st, rep

    CALL checkInt("the suite process runs to the end", st, 0)
    CALL checkInt("every test is reported", rep.tests, 3)
    CALL checkInt("exactly one test errored", rep.errors, 1)
    IF rep.cases.getLength() == 3 THEN
        CALL check("the trapped error errors its test", core.isTrue(rep.cases[2].errored))
        CALL check("... naming the runtime error", contains(caseText(rep, 2), "runtime error -8083"))
        CALL checkInt("afterEach still runs after a trapped error", rep.cases[2].checks, 1)
        CALL check("the next test runs and passes", core.isTrue(rep.cases[3].passed))
    ELSE
        CALL check("the report lists three cases", FALSE)
    END IF
    CALL check("the completion marker is written", there(dir, "crash.done"))

    CALL removeDir(dir)
END FUNCTION

# ------------------------------------------------- inspect: window scope ----

FUNCTION t_inspect_window()
    DEFINE names inspect.StringList

    CALL fakedriver.reset()
    CALL core.clearDriverError()
    # The whole tree holds every open window: the main one AND the modal child.
    CALL fakedriver.setAui('<UserInterface>'
        || '<Window name="screen"><Form name="main">'
        || '<FormField name="formonly.a1" colName="a1"><Edit/></FormField>'
        || '<FormField name="formonly.a2" colName="a2"><Edit/></FormField>'
        || '<Table name="orders"><TableColumn name="formonly.o1" colName="o1"/></Table>'
        || '</Form></Window>'
        || '<Window name="w2"><Form name="child">'
        || '<FormField name="formonly.b1" colName="b1"><Edit/></FormField>'
        || '</Form></Window></UserInterface>')
    # ... while the current-window part holds just the child.
    CALL fakedriver.setAuiPart('<Window name="w2"><Form name="child">'
        || '<FormField name="formonly.b1" colName="b1"><Edit/></FormField>'
        || '</Form></Window>')

    LET names = inspect.fieldNames()
    CALL checkInt("only the current window's fields are listed", names.getLength(), 1)
    IF names.getLength() > 0 THEN
        CALL checkEq("... which is the child's field", names[1], "formonly.b1")
    END IF
    CALL checkEq("fields() asks for the current window", fakedriver.lastSelector(),
        driver.CURRENT_WINDOW)
    LET names = inspect.tables()
    CALL checkInt("a parent window's table is not listed", names.getLength(), 0)
    CALL checkEq("CURRENT_WINDOW is GGC's current-window selector", driver.CURRENT_WINDOW,
        ggc.WindowSelector(ggc.AUI_CURRENT_SELECTOR))
    CALL fakedriver.reset()
END FUNCTION

FUNCTION t_inspect_apperror()
    DEFINE msg STRING

    CALL fakedriver.reset()
    CALL core.clearDriverError()
    CALL check("no AUI tree: no application error", inspect.applicationError() IS NULL)

    CALL fakedriver.setAui('<UserInterface><Window name="w"><Form name="f"/>'
        || '<Menu style="winmsg" text="ERROR" comment="Program stopped at '
        || "'app.4gl'" || ', line number 12.&#10;FORMS statement error number -8083.&#10;'
        || 'Null pointer exception.&#10;"/></Window></UserInterface>')
    LET msg = inspect.applicationError()
    CALL check("the runtime's error box is found", msg IS NOT NULL)
    CALL check("... with where the program stopped", contains(msg, "Program stopped at 'app.4gl', line number 12."))
    CALL check("... and the error number", contains(msg, "-8083"))
    CALL check("... on one line", NOT contains(msg, ASCII 10))

    # The application's own message box is not a crash.
    CALL fakedriver.setAui('<UserInterface><Window name="w">'
        || '<Menu style="winmsg" text="Info" comment="Record saved."/></Window></UserInterface>')
    CALL check("an application message box is not an error", inspect.applicationError() IS NULL)
    CALL fakedriver.reset()
END FUNCTION

# --------------------------------------------------------- runner: hooks ----

FUNCTION t_runner_beforeall()
    DEFINE dir STRING
    DEFINE st, ok INTEGER
    DEFINE rep SuiteReport

    LET dir = os.Path.makeTempName()
    LET ok = os.Path.mkDir(dir)
    CALL runSuite("beforeall-fails", dir) RETURNING st, rep

    CALL checkInt("the suite runs to the end", st, 0)
    CALL checkInt("the report holds the tests and the hook", rep.tests, 4)
    IF rep.cases.getLength() == 4 THEN
        CALL check("a test is not run after a failed beforeAll", core.isTrue(rep.cases[1].errored))
        CALL check("... and says why", contains(caseText(rep, 1), "beforeAll hook failed"))
        CALL checkInt("... nor are its checks recorded", rep.cases[1].checks, 0)
        CALL check("a skipped test stays skipped", core.isTrue(rep.cases[3].skipped))
        CALL checkEq("the hook has its own entry", rep.cases[4].name, "beforeAll hook")
        # A check that did not hold is a failure, in a hook as in a test.
        CALL check("... reported as not passed", NOT core.isTrue(rep.cases[4].passed))
        CALL checkInt("... with its failed check counted", rep.cases[4].failed, 1)
        CALL check("... and described", contains(caseText(rep, 4), "toBeTrue"))
    ELSE
        CALL check("the report lists four cases", FALSE)
    END IF
    CALL check("afterAll still runs after a failed beforeAll", there(dir, "afterall.ran"))
    CALL check("the completion marker is written", there(dir, "crash.done"))
    CALL removeDir(dir)
END FUNCTION

FUNCTION t_runner_afterall()
    DEFINE dir STRING
    DEFINE st, ok INTEGER
    DEFINE rep SuiteReport

    LET dir = os.Path.makeTempName()
    LET ok = os.Path.mkDir(dir)
    CALL runSuite("afterall-fails", dir) RETURNING st, rep

    CALL checkInt("the report holds the tests and the hook", rep.tests, 3)
    CALL checkInt("only the hook errored", rep.errors, 1)
    IF rep.cases.getLength() == 3 THEN
        CALL check("the tests keep their passes", core.isTrue(rep.cases[2].passed))
        CALL checkEq("the afterAll hook has its own entry", rep.cases[3].name, "afterAll hook")
        CALL check("... with the driver error", contains(caseText(rep, 3), "driver error: simulated"))
    ELSE
        CALL check("the report lists three cases", FALSE)
    END IF
    CALL removeDir(dir)
END FUNCTION

FUNCTION t_runner_appcrash()
    DEFINE dir STRING
    DEFINE st, ok INTEGER
    DEFINE rep SuiteReport

    LET dir = os.Path.makeTempName()
    LET ok = os.Path.mkDir(dir)
    CALL runSuite("app-crash", dir) RETURNING st, rep

    CALL checkInt("every test is reported", rep.tests, 3)
    IF rep.cases.getLength() == 3 THEN
        CALL check("the test before the crash passes", core.isTrue(rep.cases[1].passed))
        # Its own checks passed against the stale screen; the crash must win.
        CALL check("the test that crashed the application errors", core.isTrue(rep.cases[2].errored))
        CALL check("... naming the runtime error",
            contains(caseText(rep, 2), "stopped with a runtime error: Program stopped at 'app.4gl'"))
        CALL check("the next test is not run", contains(caseText(rep, 3), "not run: the application under test ended"))
    ELSE
        CALL check("the report lists three cases", FALSE)
    END IF
    CALL check("afterAll's failed interaction with a dead app is not reported",
        rep.cases.getLength() == 3)
    CALL removeDir(dir)
END FUNCTION

# ---------------------------------------------------------------- server ----

FUNCTION t_server_ownership()
    DEFINE ch base.Channel
    DEFINE up, started, listening BOOLEAN
    DEFINE port INTEGER

    # Listen on a free port in a quiet range (a busy CI host may hold one).
    LET ch = base.Channel.create()
    LET listening = FALSE
    FOR port = 47613 TO 47632
        TRY
            CALL ch.openServerSocket("127.0.0.1", port, "u")
            LET listening = TRUE
        CATCH
            CONTINUE FOR
        END TRY
        EXIT FOR
    END FOR
    IF NOT listening THEN
        CALL check("a free port can be opened for the test", FALSE)
        RETURN
    END IF
    CALL check("a listening port is seen as up", server.isUp(port))
    # Something already listens, so nothing is started — and the CLI, told it
    # did not start it, leaves it running at the end.
    CALL server.ensure(port, 1, 1) RETURNING up, started
    CALL check("ensure() finds the running server", up)
    CALL check("ensure() does not claim a server it did not start", NOT started)
    CALL ch.close()
END FUNCTION

# ------------------------------------------------- script: schema drift ----

# The command table (script.requirements) and schema/action-file.schema.json
# must agree command by command, or editors would accept files the loader
# rejects (or the reverse).
FUNCTION t_schema_drift()
    DEFINE text, cmd, field, letters STRING
    DEFINE root, defs, step, props, cmdProp, rule, ifo, ifProps, c, thenO, vp util.JSONObject
    DEFINE names, allOf, e, req util.JSONArray
    DEFINE fromSchema DICTIONARY OF STRING
    DEFINE cmds inspect.StringList
    DEFINE i, j INTEGER

    LET text = readTmp(os.Path.join(base.Application.getProgramDir(),
        "../schema/action-file.schema.json"))
    IF text IS NULL THEN
        CALL check("the schema file can be read", FALSE)
        RETURN
    END IF
    LET root = util.JSONObject.parse(text)
    IF root.getType("$defs") != "OBJECT" THEN
        CALL check("the schema has $defs", FALSE)
        RETURN
    END IF
    LET defs = root.get("$defs")
    LET step = defs.get("step")
    LET props = step.get("properties")
    LET cmdProp = props.get("command")
    LET names = cmdProp.get("enum")
    FOR i = 1 TO names.getLength()
        LET cmd = names.get(i)
        LET fromSchema[cmd] = ""
    END FOR
    LET allOf = step.get("allOf")
    FOR i = 1 TO allOf.getLength()
        LET rule = allOf.get(i)
        LET ifo = rule.get("if")
        LET ifProps = ifo.get("properties")
        LET c = ifProps.get("command")
        LET e = c.get("enum")
        LET thenO = rule.get("then")
        LET letters = NULL
        IF thenO.getType("required") == "ARRAY" THEN
            LET req = thenO.get("required")
            LET field = req.get(1)
            CASE field
                WHEN "target" LET letters = "t"
                WHEN "value" LET letters = "v"
                WHEN "column" LET letters = "c"
                WHEN "row" LET letters = "r"
            END CASE
        ELSE
            LET vp = thenO.get("properties")
            IF vp.getType("value") == "OBJECT" THEN
                LET letters = "n"   -- a pattern on value: a whole number
            END IF
        END IF
        FOR j = 1 TO e.getLength()
            LET cmd = e.get(j)
            LET fromSchema[cmd] = fromSchema[cmd].append(letters)
        END FOR
    END FOR

    LET cmds = script.commands()
    CALL checkInt("the schema lists every command", fromSchema.getLength(), cmds.getLength())
    FOR i = 1 TO cmds.getLength()
        CALL checkEq(SFMT("schema and table agree on '%1'", cmds[i]),
            canonical(fromSchema[cmds[i]]), canonical(script.requirements(cmds[i])))
    END FOR
END FUNCTION

# Requirement letters in a fixed order, "-" (nothing) as empty.
FUNCTION canonical(letters STRING) RETURNS STRING
    DEFINE r STRING
    DEFINE k INTEGER
    DEFINE order, l STRING
    LET order = "tcrvn"
    LET r = ""
    FOR k = 1 TO order.getLength()
        LET l = order.getCharAt(k)
        IF letters.getIndexOf(l, 1) > 0 THEN
            LET r = r.append(l)
        END IF
    END FOR
    RETURN r
END FUNCTION

# ------------------------------------------------------ cli: config check ----

FUNCTION t_cli_checkconfig()
    DEFINE dir, cfgPath, text, err STRING
    DEFINE cfg, bad cli.Config

    LET dir = os.Path.makeTempName()
    IF NOT os.Path.mkDir(dir) THEN
        CALL check("a scratch directory can be made", FALSE)
        RETURN
    END IF
    CALL touch(dir, "a_test.42m")
    CALL touch(dir, "b.actions.json")
    LET cfgPath = os.Path.join(dir, "fgltest.json")

    LET text = '{"$schema":"x","_comment":"ok","reporters":"console, junit","suites":['
        || '{"name":"a","module":"a_test"},'
        || '{"name":"b","actions":"b.actions.json","mode":"ua","url":"http://h/ua/r/b"}]}'
    CALL util.JSON.parse(text, cfg)
    LET err = cli.normalize(cfg, cfgPath, "/opt/pkg/")
    LET err = cli.checkConfig(cfgPath, text, cfg, err)
    CALL check("a valid config passes", err IS NULL)
    IF err IS NOT NULL THEN
        DISPLAY "# ", err
    END IF
    CALL checkEq("spaces in reporters are tolerated", cfg.reporters, "console,junit")
    CALL checkEq("a tcp suite with no workdir runs in the config's directory",
        cfg.suites[1].workdir, dir)

    LET text = '{"reporter":"junit","reporters":"junit,xml","suites":['
        || '{"name":"a","module":"a_test","comandLine":"fglrun a"},'
        || '{"name":"a","actions":"b.actions.json"},'
        || '{"module":"missing_test"},'
        || '{"name":"c","module":"a_test","actions":"b.actions.json"},'
        || '{"name":"d"},'
        || '{"name":"e","actions":"b.actions.json","mode":"ua"},'
        || '{"name":"f","actions":"b.actions.json","mode":"telnet","timeout":-1}]}'
    CALL util.JSON.parse(text, bad)
    LET err = cli.normalize(bad, cfgPath, "/opt/pkg/")
    LET err = cli.checkConfig(cfgPath, text, bad, err)
    CALL check("an unknown top-level key is reported", contains(err, 'the config: unknown key "reporter"'))
    CALL check("an unknown suite key is reported", contains(err, 'suite #1: unknown key "comandLine"'))
    CALL check("a reused suite name is reported", contains(err, "suite #2 reuses the name 'a' of suite #1"))
    CALL check("a suite without a name is reported", contains(err, 'suite #3 has no "name"'))
    CALL check("a missing module is reported", contains(err, "missing_test' not found"))
    CALL check("module and actions together are reported", contains(err, "suite 'c' names both"))
    CALL check("neither module nor actions is reported", contains(err, "suite 'd' needs a \"module\" or an \"actions\" file"))
    CALL check("ua without a url is reported", contains(err, "suite 'e': mode ua needs a \"url\""))
    CALL check("an unknown mode is reported", contains(err, "unknown \"mode\" 'telnet'"))
    CALL check("a negative timeout is reported", contains(err, "suite 'f': \"timeout\" cannot be negative"))
    CALL check("an unknown reporter is reported", contains(err, "unknown reporter 'xml'"))
    CALL check("every problem is listed at once", contains(err, "is not valid:"))

    CALL removeDir(dir)
END FUNCTION

FUNCTION t_cli_unique()
    DEFINE names, u cli.NameList
    LET names[1] = "a"
    LET names[2] = "b"
    LET names[3] = "a"
    LET names[4] = "c"
    LET u = cli.uniqueNames(names)
    CALL checkInt("a repeated name is listed once", u.getLength(), 3)
    CALL checkEq("first occurrences keep their order", u[3], "c")
END FUNCTION

# ------------------------------------------------------------ core: quoting ----

FUNCTION t_core_quote()
    -- POSIX sh: backslash and quote escaped, the rest literal.
    CALL checkEq("a plain value is double-quoted", core.quoteArg("app dir", FALSE), '"app dir"')
    CALL checkEq("sh: a quote is escaped", core.quoteArg('say "hi"', FALSE), '"say \\"hi\\""')
    CALL checkEq("sh: a backslash is escaped", core.quoteArg('a\\b', FALSE), '"a\\\\b"')
    -- Windows: backslashes stay single unless they precede a quote or the end.
    CALL checkEq("windows: a path keeps its backslashes", core.quoteArg('C:\\app\\x', TRUE), '"C:\\app\\x"')
    CALL checkEq("windows: a quote is escaped", core.quoteArg('say "hi"', TRUE), '"say \\"hi\\""')
    CALL checkEq("windows: a trailing backslash cannot escape the closing quote",
        core.quoteArg('C:\\app\\', TRUE), '"C:\\app\\\\"')
    CALL checkEq("windows: backslashes before a quote are doubled",
        core.quoteArg('a\\"b', TRUE), '"a\\\\\\"b"')
    CALL checkEq("an empty value is an empty argument", core.quoteArg(NULL, FALSE), '""')
    -- Non-ASCII text must pass through whole under BYTE semantics too.
    CALL checkEq("sh: a non-ASCII path is kept intact",
        core.quoteArg("/Users/josé/données", FALSE), '"/Users/josé/données"')
    CALL checkEq("windows: a non-ASCII path is kept intact",
        core.quoteArg('C:\\josé\\données\\', TRUE), '"C:\\josé\\données\\\\"')
    CALL checkEq("windows: a quote at the end is escaped", core.quoteArg('a"', TRUE), '"a\\""')
    -- $NAME is expanded by fgltest itself, so the shell must see it literally.
    CALL checkEq("sh: $ and backticks are literal", core.quoteArg("$HOME/`x`", FALSE), '"\\$HOME/\\`x\\`"')
END FUNCTION

# ------------------------------------------------- runner: duplicates ----

FUNCTION t_runner_duplicates()
    DEFINE dir STRING
    DEFINE st, ok INTEGER
    DEFINE rep SuiteReport

    LET dir = os.Path.makeTempName()
    LET ok = os.Path.mkDir(dir)
    CALL runSuite("duplicates", dir) RETURNING st, rep
    CALL checkInt("every registration is reported", rep.tests, 3)
    IF rep.cases.getLength() == 3 THEN
        CALL check("the first test with the name runs", core.isTrue(rep.cases[1].passed))
        CALL check("the repeat is errored", core.isTrue(rep.cases[2].errored))
        CALL check("... and says why", contains(caseText(rep, 2), "test #1 already has this name"))
        CALL check("the repeat is not run", rep.cases[2].checks == 0)
    ELSE
        CALL check("the report lists three cases", FALSE)
    END IF

    # Isolate mode selects by name: the name must not run twice.
    CALL fgl_setenv("SELFTEST_ONLY", "same name")
    CALL runSuite("duplicates", dir) RETURNING st, rep
    CALL fgl_setenv("SELFTEST_ONLY", "")
    CALL checkInt("selecting the name reports the test and its repeat", rep.tests, 2)
    CALL checkInt("... running it once", rep.errors, 1)
    CALL removeDir(dir)
END FUNCTION

# --------------------------------------------------------------- release ----

# core.VERSION (what `fgltest --version` prints), fglpkg.json (what is
# published) and CHANGELOG.md (what is documented) must name the same release.
FUNCTION t_version()
    DEFINE root, manifest, changelog STRING
    DEFINE m util.JSONObject
    DEFINE v STRING

    LET root = os.Path.join(base.Application.getProgramDir(), "..")
    LET manifest = readTmp(os.Path.join(root, "fglpkg.json"))
    LET changelog = readTmp(os.Path.join(root, "CHANGELOG.md"))
    IF manifest IS NULL OR changelog IS NULL THEN
        CALL check("fglpkg.json and CHANGELOG.md can be read", FALSE)
        RETURN
    END IF
    LET m = util.JSONObject.parse(manifest)
    LET v = m.get("version")
    CALL checkEq("core.VERSION matches fglpkg.json", core.VERSION, v)
    CALL check("CHANGELOG.md has a section for this version",
        contains(changelog, SFMT("## [%1] - ", core.VERSION)))
END FUNCTION

# --------------------------------------------------- cli: env and config ----

FUNCTION t_cli_env()
    DEFINE v, unset, err STRING
    DEFINE c cli.Config

    CALL fgl_setenv("SELFTEST_DIR", "/opt/app")
    CALL fgl_setenv("SELFTEST_EMPTY", "")
    CALL cli.expandEnv("$SELFTEST_DIR/x") RETURNING v, unset
    CALL checkEq("$NAME is expanded", v, "/opt/app/x")
    CALL cli.expandEnv("${SELFTEST_DIR}y") RETURNING v, unset
    CALL checkEq("${NAME} is expanded", v, "/opt/appy")
    CALL cli.expandEnv("costs $$5, or $5 — a$") RETURNING v, unset
    CALL checkEq("$$ is a $, and a $ before no name is kept", v, "costs $5, or $5 — a$")
    CALL cli.expandEnv("données/$SELFTEST_DIR") RETURNING v, unset
    CALL checkEq("non-ASCII text around a variable is kept", v, "données//opt/app")
    CALL cli.expandEnv("$SELFTEST_NOPE/x") RETURNING v, unset
    CALL checkEq("an unset variable is named", unset, "SELFTEST_NOPE")
    CALL cli.expandEnv("$SELFTEST_EMPTY/x") RETURNING v, unset
    CALL checkEq("an empty variable counts as unset", unset, "SELFTEST_EMPTY")

    CALL util.JSON.parse('{"suites":[{"name":"a","module":"$SELFTEST_DIR/a_test",'
        || '"commandLine":"fglrun $SELFTEST_DIR/app"}]}', c)
    LET err = cli.normalize(c, os.Path.join("conf", "fgltest.json"), "/opt/pkg/")
    CALL checkEq("a variable in a module path is expanded before resolving",
        c.suites[1].module, "/opt/app/a_test")
    CALL checkEq("a variable in the command line is expanded",
        c.suites[1].commandLine, "fglrun /opt/app/app")
    CALL util.JSON.parse('{"suites":[{"name":"a","module":"$SELFTEST_NOPE/a_test"}]}', c)
    LET err = cli.normalize(c, "fgltest.json", "/opt/pkg/")
    CALL check("an unset variable in the config is reported",
        contains(err, "suite #1 module uses the environment variable SELFTEST_NOPE, which is not set"))
    CALL fgl_setenv("SELFTEST_DIR", "")
END FUNCTION

FUNCTION t_cli_types_and_clashes()
    DEFINE dir, cfgPath, text, err STRING
    DEFINE ok INTEGER
    DEFINE c1, c2, c3, c4 cli.Config

    LET dir = os.Path.makeTempName()
    LET ok = os.Path.mkDir(dir)
    CALL touch(dir, "a_test.42m")
    LET cfgPath = os.Path.join(dir, "fgltest.json")

    # Keys in another case reach the record (the parser ignores case), so they
    # must not be called unknown.
    LET text = '{"suites":[{"Name":"a","module":"a_test","workDir":".","commandline":"fglrun a"}]}'
    CALL writeTmp(cfgPath, text)
    CALL util.JSON.parse(text, c1)
    LET err = cli.normalize(c1, cfgPath, "/opt/pkg/")
    LET err = cli.checkConfig(cfgPath, text, c1, err)
    CALL check("keys in another case are accepted", err IS NULL)
    IF err IS NOT NULL THEN
        DISPLAY "# ", err
    END IF

    # Values of the wrong type would parse to NULL (or be truncated) silently.
    LET text = '{"timeout":"30s","isolate":"yes","suites":[{"name":"a","module":"a_test","timeout":1.5}]}'
    CALL writeTmp(cfgPath, text)
    CALL util.JSON.parse(text, c2)
    LET err = cli.normalize(c2, cfgPath, "/opt/pkg/")
    LET err = cli.checkConfig(cfgPath, text, c2, err)
    CALL check("a string timeout is rejected", contains(err, 'the config: "timeout" must be a whole number, not the string "30s"'))
    CALL check("a non-boolean isolate is rejected", contains(err, '"isolate" must be true or false'))
    CALL check("a fractional suite timeout is rejected", contains(err, 'suite #1: "timeout" must be a whole number, not 1.5'))

    # A suite whose report would be the config file must not run: the CLI
    # deletes stale reports first, so the config would be gone.
    LET text = '{"suites":[{"name":"fgltest","module":"a_test"},{"name":"ggcserver","module":"a_test"}]}'
    CALL writeTmp(cfgPath, text)
    CALL util.JSON.parse(text, c3)
    LET err = cli.normalize(c3, cfgPath, "/opt/pkg/")
    LET err = cli.checkConfig(cfgPath, text, c3, err)
    CALL check("a suite whose report would replace the config is rejected",
        contains(err, "suite 'fgltest': its report") AND contains(err, "would replace the config file"))
    CALL check("a reserved suite name is rejected", contains(err, "the name 'ggcserver' is reserved"))

    LET text = '{"port":-1,"suites":[{"name":"a","module":"a_test"}]}'
    CALL util.JSON.parse(text, c4)
    LET err = cli.normalize(c4, cfgPath, "/opt/pkg/")
    CALL check("a negative port is rejected", contains(err, '"port" must be a port number'))

    CALL removeDir(dir)
END FUNCTION

FUNCTION t_ggc_session()
    CALL check("CLOSED ends the session", ggcdriver.sessionOver(17, ""))
    CALL check("an ended scenario ends the session",
        ggcdriver.sessionOver(12, "The scenario has already ended."))
    CALL check("a busy DVM does not end the session",
        NOT ggcdriver.sessionOver(12, "The DVM is not in interactive state but VM processing"))
    CALL check("a bad field name does not end the session",
        NOT ggcdriver.sessionOver(7, "FormField not found"))
END FUNCTION

# ---------------------------------------------------------- environment ----

# The multibyte cases below only catch a string bug when the locale is UTF-8:
# under a single-byte one, getCharAt() returns whole bytes and a broken
# per-character loop leaves the text intact, so the cases would pass
# vacuously. Fail instead, naming the fix.
FUNCTION t_utf8_locale()
    DEFINE e STRING
    LET e = "é"
    CALL check(SFMT("a UTF-8 locale is active (LANG=%1); set LANG to one, e.g. C.UTF-8",
        fgl_getenv("LANG")), e.getCharAt(1) == e)
END FUNCTION

# -------------------------------------------------- lenient conversions ----

# util.JSON.parse converts "60" to a whole number and 1 to TRUE, so configs
# relying on that kept working on main and must keep working; only values it
# cannot convert, or would truncate, are mistakes.
FUNCTION t_cli_lenient()
    DEFINE dir, cfgPath, text, err STRING
    DEFINE ok INTEGER
    DEFINE c1, c2 cli.Config

    LET dir = os.Path.makeTempName()
    LET ok = os.Path.mkDir(dir)
    CALL touch(dir, "a_test.42m")
    LET cfgPath = os.Path.join(dir, "fgltest.json")

    LET text = '{"port":"6752","timeout":"60","isolate":1,"suites":['
        || '{"name":"a","module":"a_test","isolate":"1","timeout":" 30"}]}'
    CALL writeTmp(cfgPath, text)
    CALL util.JSON.parse(text, c1)
    LET err = cli.normalize(c1, cfgPath, "/opt/pkg/")
    LET err = cli.checkConfig(cfgPath, text, c1, err)
    CALL check("numeric strings and 0/1 booleans are accepted", err IS NULL)
    IF err IS NOT NULL THEN
        DISPLAY "# ", err
    END IF
    CALL checkInt("... and applied (port)", c1.port, 6752)
    CALL checkInt("... and applied (timeout)", c1.timeout, 60)
    CALL check("... and applied (isolate)", core.isTrue(c1.isolate))
    CALL check("... and applied (a suite's isolate)", core.isTrue(c1.suites[1].isolate))

    LET text = '{"timeout":"6.5","isolate":2,"suites":[{"name":"a","module":"a_test"}]}'
    CALL writeTmp(cfgPath, text)
    CALL util.JSON.parse(text, c2)
    LET err = cli.normalize(c2, cfgPath, "/opt/pkg/")
    LET err = cli.checkConfig(cfgPath, text, c2, err)
    CALL check("a fractional string the parser would cut is rejected",
        contains(err, '"timeout" must be a whole number, not the string "6.5"'))
    CALL check("a number other than 0 / 1 is not a boolean", contains(err, '"isolate" must be true or false'))
    CALL removeDir(dir)
END FUNCTION

FUNCTION t_script_lenient()
    DEFINE p, err STRING
    DEFINE steps script.StepList
    DEFINE ok INTEGER

    LET p = "selftest_lenient.json"
    CALL writeTmp(p,
        '{"application":"app","tests":[{"name":5,"steps":['
        || '{"command":"selectRow","target":"t","row":"3"},'
        || '{"command":"assertCell","target":"t","column":5,"value":"x"},'
        || '{"command":"pause","value":5.0},'
        || '{"command":"pause","value":1e3},'
        || '{"command":"assertField","target":"f","value":5.0}]}]}')
    LET err = script.load(p)
    CALL check("numbers and numeric strings the parser converts load", err IS NULL)
    IF err IS NOT NULL THEN
        DISPLAY "# ", err
    END IF
    LET steps = script.testStepsAt(1)
    CALL checkEq("a numeric name is a name", script.testName(1), "5")
    CALL checkInt('"row": "3" is row 3', steps[1].rowNum, 3)
    CALL checkEq('"column": 5 is column "5"', steps[2].col, "5")
    -- the schema calls 5.0 and 1e3 whole numbers, so the loader must too
    CALL checkEq("a whole-number count written 5.0 is 5", steps[3].value, "5")
    CALL checkEq("a whole-number count written 1e3 is 1000", steps[4].value, "1000")
    CALL checkEq("a value that is not a count is kept as written", steps[5].value, "5.0")

    CALL writeTmp(p,
        '{"application":"app","description":"x","tests":[{"name":"t","steps":['
        || '{"command":"pause","value":5.5}]}]}')
    LET err = script.load(p)
    CALL check("a fractional count is rejected", contains(err, "needs a whole-number \"value\", not '5.5'"))
    CALL check("a description key is unknown (use _description)", contains(err, 'unknown key "description"'))
    LET ok = os.Path.delete(p)
END FUNCTION

FUNCTION t_cli_all_problems()
    DEFINE text, err STRING
    DEFINE c cli.Config

    -- an unset variable used to hide every other problem
    LET text = '{"colour":"red","suites":[{"name":"a","module":"$SELFTEST_NOPE/a_test"},'
        || '{"name":"a","module":"missing_test","mode":"telnet"}]}'
    CALL util.JSON.parse(text, c)
    LET err = cli.normalize(c, "fgltest.json", "/opt/pkg/")
    LET err = cli.checkConfig("fgltest.json", text, c, err)
    CALL check("the unset variable is listed", contains(err, "environment variable SELFTEST_NOPE"))
    CALL check("... and the unknown key", contains(err, 'unknown key "colour"'))
    CALL check("... and the reused name", contains(err, "reuses the name 'a'"))
    CALL check("... and the missing module", contains(err, "module 'missing_test' not found"))
    CALL check("... and the bad mode", contains(err, "unknown \"mode\" 'telnet'"))
    CALL check("a path naming the unset variable is not also called missing",
        NOT contains(err, "SELFTEST_NOPE/a_test' not found"))
END FUNCTION

FUNCTION t_cli_ownership()
    DEFINE dir, cfgPath, text, err STRING
    DEFINE ok INTEGER
    DEFINE c cli.Config

    LET dir = os.Path.makeTempName()
    LET ok = os.Path.mkDir(dir)
    CALL writeTmp(os.Path.join(dir, "orders.tap"), "precious data")
    CALL writeTmp(os.Path.join(dir, "fglpkg.json"), '{"name":"app","version":"1.0.0"}')
    CALL report(dir, "mine.tap")
    CALL touch(dir, "a_test.42m")
    LET cfgPath = os.Path.join(dir, "fgltest.json")
    LET text = '{"reporters":"console","suites":[{"name":"orders","module":"a_test"},'
        || '{"name":"fglpkg","module":"a_test"},{"name":"mine","module":"a_test"}]}'
    CALL writeTmp(cfgPath, text)
    CALL util.JSON.parse(text, c)
    LET err = cli.normalize(c, cfgPath, "/opt/pkg/")
    LET err = cli.checkConfig(cfgPath, text, c, err)
    CALL check("a user's file named like a report is protected",
        contains(err, "suite 'orders'") AND contains(err, "orders.tap' exists and is not an fgltest report"))
    CALL check("the project's fglpkg.json is protected", contains(err, "fglpkg.json' exists and is not an fgltest report"))
    CALL check("an earlier fgltest report is not a clash", NOT contains(err, "suite 'mine'"))
    CALL check("clearRunFiles refuses a file fgltest did not write",
        contains(cli.clearRunFiles(dir, "orders"), "refusing to remove"))
    CALL check("... and leaves it in place", there(dir, "orders.tap"))
    CALL check("clearRunFiles removes fgltest's own report", cli.clearRunFiles(dir, "mine") IS NULL)
    CALL check("... which is gone", NOT there(dir, "mine.tap"))
    CALL removeDir(dir)
END FUNCTION
