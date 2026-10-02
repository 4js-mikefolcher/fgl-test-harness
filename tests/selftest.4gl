# selftest — fgltest's own test suite.
#
#   fglrun tests/selftest        (or: make check)
#
# Runs with NO GGC engine, NO scenario server and NO application: the fake
# driver stands in for the interaction layer, so every piece of fgltest's own
# logic — AUI parsing, matchers, reporters, the action-file interpreter — is
# exercised anywhere a compiler is available. Exits non-zero on any failure.

IMPORT os
IMPORT FGL com.fourjs.fgltest.core
IMPORT FGL com.fourjs.fgltest.driver
IMPORT FGL com.fourjs.fgltest.inspect
IMPORT FGL com.fourjs.fgltest.flow
IMPORT FGL com.fourjs.fgltest.expect
IMPORT FGL com.fourjs.fgltest.script
IMPORT FGL com.fourjs.fgltest.reporters
IMPORT FGL fakedriver

DEFINE m_pass, m_fail INTEGER
DEFINE m_group STRING

# A representative AUI tree: two standalone FormFields (one disabled, one
# read-only, one hidden) plus a Table whose columns are TableColumn nodes —
# the exact shape inspect.fields() has to union.

MAIN
    CALL setup()

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

    CALL group("flow: verbs reach the driver")
    CALL t_flow()

    CALL group("script: action-file validation")
    CALL t_script_validation()
    CALL group("script: step dispatch")
    CALL t_script_exec()
    CALL group("script: every declared command is dispatched")
    CALL t_script_coverage()

    CALL group("reporters: JUnit")
    CALL t_junit()
    CALL group("reporters: TAP")
    CALL t_tap()
    CALL group("reporters: JSON")
    CALL t_json()

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
    CALL fakedriver.reset()
    CALL fakedriver.setAui(aui())
    CALL core.clearDriverError()
    CALL one("action")
    CALL one("field")
    CALL one("enter")
    CALL one("fill")
    CALL one("clear")
    CALL one("key")
    CALL one("pause")
    CALL one("selectRow")
    CALL one("focusCell")
    CALL one("assertField")
    CALL one("assertFieldNot")
    CALL one("assertFieldContains")
    CALL one("assertFieldMatches")
    CALL one("assertCurrent")
    CALL one("assertFormName")
    CALL one("assertFormTitle")
    CALL one("assertWindowName")
    CALL one("assertWindowTitle")
    CALL one("assertActionActive")
    CALL one("assertActionInactive")
    CALL one("assertActionExists")
    CALL one("assertActionMissing")
    CALL one("assertFieldEnabled")
    CALL one("assertFieldDisabled")
    CALL one("assertFieldEditable")
    CALL one("assertFieldReadOnly")
    CALL one("assertFieldExists")
    CALL one("assertFieldMissing")
    CALL one("assertFieldCount")
    CALL one("assertTableExists")
    CALL one("assertCell")
    CALL one("assertCellContains")
    CALL one("assertCellMatches")
    CALL one("assertCellAtRow")
    CALL one("assertRowCount")
    CALL one("assertRowCountAtLeast")
    CALL one("assertRowCountAtMost")
    CALL one("assertCurrentRow")
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
END FUNCTION

FUNCTION t_tap()
    DEFINE x STRING
    LET x = reporters.toTAP(sampleOutcomes())
    CALL check("declares the TAP version", contains(x, "TAP version 13"))
    CALL check("declares the plan", contains(x, "1..4"))
    CALL check("reports a pass", contains(x, "ok 1 - passing test"))
    CALL check("reports a failure", contains(x, "not ok 2 - failing test"))
    CALL check("marks an errored test", contains(x, "not ok 3 - errored test # ERROR"))
    # TAP has no "skip" result: a skip is an ok with a SKIP directive.
    CALL check("marks a skip with the SKIP directive", contains(x, "ok 4 - skipped test # SKIP"))
    CALL check("emits a YAML diagnostic block", contains(x, "  ---"))
END FUNCTION

FUNCTION t_json()
    DEFINE x STRING
    LET x = reporters.toJSON(sampleOutcomes(), "mysuite")
    CALL check("names the suite", contains(x, '"suite":"mysuite"'))
    CALL check("counts tests", contains(x, '"tests":4'))
    CALL check("counts passes", contains(x, '"passed":1'))
    CALL check("counts errors", contains(x, '"errors":1'))
    CALL check("counts skips", contains(x, '"skipped":1'))
    CALL check("totals durations", contains(x, '"duration":0.85'))
    CALL check("includes the cases array", contains(x, '"cases":['))
    CALL check("carries the errored flag", contains(x, '"errored":true'))
    CALL check("carries the skipped flag", contains(x, '"skipped":true'))
END FUNCTION
