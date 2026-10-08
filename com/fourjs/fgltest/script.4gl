# fgltest.script — declarative JSON "action file" support (data-driven tests).
#
# An action file lets you author functional tests as JSON instead of compiled
# BDL. The shape mirrors the established keyword-driven model (Selenium IDE's
# command/target/value triple): each test is a list of steps, and each step is
# one command dispatched to the same flow/expect/inspect verbs the compiled API
# uses. No new engine — this is a thin interpreter over the existing surface.
#
#   {
#     "application": "price",
#     "beforeEach": [ { "command": "pause", "value": "100" } ],
#     "tests": [
#       { "name": "edits a price", "steps": [
#           { "command": "action",      "target": "edit" },
#           { "command": "fill",        "target": "formonly.price", "value": "9.99" },
#           { "command": "assertField", "target": "formonly.price", "value": "9.99" }
#       ] }
#     ]
#   }
#
# load() parses a file into a module-static ActionFile; the runner drives the
# tests via testSteps()/*Steps() and calls exec() for each step list. Accessors
# expose the parsed model so a generic program can wire it into the runner
# without a runner<->script import cycle (this module never imports runner).

PACKAGE com.fourjs.fgltest

IMPORT util

IMPORT FGL com.fourjs.fgltest.driver
IMPORT FGL com.fourjs.fgltest.core
IMPORT FGL com.fourjs.fgltest.flow
IMPORT FGL com.fourjs.fgltest.expect
IMPORT FGL com.fourjs.fgltest.inspect

#+ One step: a command with an optional target (a field/action/key/table name)
#+ and value. Mirrors the command/target/value triple used by keyword-driven test
#+ tools; `column` and `row` extend it for table-cell commands (mapped via
#+ json_name so the BDL field identifiers stay reserved-word-safe).
PUBLIC TYPE Step RECORD
    command STRING,
    target STRING,
    col STRING ATTRIBUTES(json_name = "column"),
    rowNum INTEGER ATTRIBUTES(json_name = "row"),
    value STRING
END RECORD
PUBLIC TYPE StepList DYNAMIC ARRAY OF Step

#+ One named test: a list of steps. `skip` reports the test as skipped without
#+ running it; `only` focuses the run on the marked tests (see runner.testOnly).
PUBLIC TYPE TestSpec RECORD
    name STRING,
    skip BOOLEAN,
    only BOOLEAN,
    steps StepList
END RECORD

#+ A parsed action file: the application, optional hook step-lists, and tests.
PUBLIC TYPE ActionFile RECORD
    application STRING,
    beforeAll StepList,
    beforeEach StepList,
    afterEach StepList,
    afterAll StepList,
    tests DYNAMIC ARRAY OF TestSpec
END RECORD

PRIVATE DEFINE m_file ActionFile
# The command table: command -> requirement letters (see commandTable()).
PRIVATE DEFINE m_commands DICTIONARY OF STRING

# ------------------------------------------------------------------ load ----

#+ Read and parse an action file into the module-static model.
#+
#+ @param path the action-file path
#+ @return NULL on success, else a human-readable error message
PUBLIC FUNCTION load(path STRING) RETURNS STRING
    DEFINE txt STRING
    LET txt = readFile(path)
    IF txt IS NULL THEN
        RETURN SFMT("cannot read action file '%1'", path)
    END IF
    TRY
        CALL util.JSON.parse(txt, m_file)
    CATCH
        RETURN SFMT("invalid JSON in action file '%1'", path)
    END TRY
    IF m_file.application IS NULL OR LENGTH(m_file.application) == 0 THEN
        RETURN SFMT("action file '%1' has no \"application\"", path)
    END IF
    RETURN checkModel(path)
END FUNCTION

# ------------------------------------------------------------ validate ----

#+ Check the loaded model before anything is launched: an unknown command, a
#+ missing target/value/column/row, a count that is not a number or a test name
#+ used twice is a mistake in the action file, and catching it here reports
#+ every problem at once instead of failing one test deep into a run that has
#+ already started an application.
#+
#+ @param path the action-file path (for the message)
#+ @return NULL when valid, else a multi-line description of every problem
PRIVATE FUNCTION checkModel(path STRING) RETURNS STRING
    DEFINE b base.StringBuffer
    DEFINE i, n INTEGER
    DEFINE seen DICTIONARY OF INTEGER
    DEFINE name STRING

    LET b = base.StringBuffer.create()
    CALL checkSteps(b, "beforeAll", m_file.beforeAll)
    CALL checkSteps(b, "beforeEach", m_file.beforeEach)
    CALL checkSteps(b, "afterEach", m_file.afterEach)
    CALL checkSteps(b, "afterAll", m_file.afterAll)

    LET n = m_file.tests.getLength()
    IF n == 0 THEN
        CALL addProblem(b, "no \"tests\" declared")
    END IF
    FOR i = 1 TO n
        LET name = m_file.tests[i].name
        IF name IS NULL OR LENGTH(name) == 0 THEN
            CALL addProblem(b, SFMT("test #%1 has no \"name\"", i))
        ELSE
            # A name identifies a test in the reports and selects it in
            # isolate mode, so two tests may not share one.
            IF seen.contains(name) THEN
                CALL addProblem(b, SFMT("test #%1 reuses the name '%2' of test #%3 — test names must be unique",
                    i, name, seen[name]))
            ELSE
                LET seen[name] = i
            END IF
        END IF
        IF m_file.tests[i].steps.getLength() == 0 THEN
            CALL addProblem(b,
                SFMT("test '%1' has no \"steps\"", name))
        END IF
        CALL checkSteps(b, SFMT("test '%1'", name), m_file.tests[i].steps)
    END FOR

    IF b.getLength() == 0 THEN
        RETURN NULL
    END IF
    RETURN SFMT("action file '%1' is not valid:%2%3", path, ASCII 10, b.toString())
END FUNCTION

PRIVATE FUNCTION checkSteps(b base.StringBuffer, where STRING, steps StepList)
    DEFINE i INTEGER
    DEFINE req, at STRING
    FOR i = 1 TO steps.getLength()
        LET at = SFMT("%1 step %2", where, i)
        LET req = requirements(steps[i].command)
        IF req IS NULL THEN
            CALL addProblem(b, SFMT("%1: unknown command '%2'", at, steps[i].command))
            CONTINUE FOR
        END IF
        IF needs(req, "t") AND LENGTH(steps[i].target) == 0 THEN
            CALL addProblem(b, SFMT("%1: command '%2' needs a \"target\"", at, steps[i].command))
        END IF
        IF needs(req, "c") AND LENGTH(steps[i].col) == 0 THEN
            CALL addProblem(b, SFMT("%1: command '%2' needs a \"column\"", at, steps[i].command))
        END IF
        IF needs(req, "r") AND (steps[i].rowNum IS NULL OR steps[i].rowNum < 1) THEN
            CALL addProblem(b, SFMT("%1: command '%2' needs a \"row\" (1 or more)", at, steps[i].command))
        END IF
        IF needs(req, "v") AND steps[i].value IS NULL THEN
            CALL addProblem(b, SFMT("%1: command '%2' needs a \"value\"", at, steps[i].command))
        ELSE
            # A count or a delay that is not a number would quietly become
            # NULL at run time and fail with a confusing message.
            IF needs(req, "n") AND NOT isCount(steps[i].value) THEN
                CALL addProblem(b, SFMT("%1: command '%2' needs a whole-number \"value\", not '%3'",
                    at, steps[i].command, steps[i].value))
            END IF
        END IF
    END FOR
END FUNCTION

PRIVATE FUNCTION addProblem(b base.StringBuffer, msg STRING)
    CALL b.append("  - ")
    CALL b.append(msg)
    CALL b.append(ASCII 10)
END FUNCTION

# The command table: every command an action file may use, and what it
# requires, one letter per requirement —
#   t  a "target"              c  a "column"
#   v  a "value"               r  a "row" (1-based)
#   n  a whole-number "value"  -  nothing
# It is the single list of commands: validation reads it, a self-test runs each
# command through exec()'s CASE, and another checks that
# schema/action-file.schema.json says the same. A new command goes here and in
# exec(), and the schema is updated to match. (Filled on first use.)
PRIVATE FUNCTION commandTable()
    IF m_commands.getLength() > 0 THEN
        RETURN
    END IF
    # interaction
    LET m_commands["action"] = "t"
    LET m_commands["field"] = "t"
    LET m_commands["enter"] = "v"
    LET m_commands["fill"] = "tv"
    LET m_commands["clear"] = "-"
    LET m_commands["key"] = "t"
    LET m_commands["pause"] = "vn"
    LET m_commands["selectRow"] = "tr"
    LET m_commands["focusCell"] = "tcr"
    # scalar assertions
    LET m_commands["assertField"] = "tv"
    LET m_commands["assertFieldNot"] = "tv"
    LET m_commands["assertFieldContains"] = "tv"
    LET m_commands["assertFieldMatches"] = "tv"
    LET m_commands["assertCurrent"] = "v"
    LET m_commands["assertFormName"] = "v"
    LET m_commands["assertFormTitle"] = "v"
    LET m_commands["assertWindowName"] = "v"
    LET m_commands["assertWindowTitle"] = "v"
    # action / field state
    LET m_commands["assertActionActive"] = "t"
    LET m_commands["assertActionInactive"] = "t"
    LET m_commands["assertActionExists"] = "t"
    LET m_commands["assertActionMissing"] = "t"
    LET m_commands["assertFieldEnabled"] = "t"
    LET m_commands["assertFieldDisabled"] = "t"
    LET m_commands["assertFieldEditable"] = "t"
    LET m_commands["assertFieldReadOnly"] = "t"
    LET m_commands["assertFieldExists"] = "t"
    LET m_commands["assertFieldMissing"] = "t"
    LET m_commands["assertFieldCount"] = "vn"
    # tables
    LET m_commands["assertTableExists"] = "t"
    LET m_commands["assertCell"] = "tcv"
    LET m_commands["assertCellContains"] = "tcv"
    LET m_commands["assertCellMatches"] = "tcv"
    LET m_commands["assertCellAtRow"] = "tcrv"
    LET m_commands["assertRowCount"] = "tvn"
    LET m_commands["assertRowCountAtLeast"] = "tvn"
    LET m_commands["assertRowCountAtMost"] = "tvn"
    LET m_commands["assertCurrentRow"] = "tvn"
END FUNCTION

#+ What an action-file command requires: letters from the command table
#+ (t target, v value, n whole-number value, c column, r row), "-" when it needs
#+ nothing, or NULL if there is no such command.
PUBLIC FUNCTION requirements(command STRING) RETURNS STRING
    CALL commandTable()
    IF command IS NULL OR NOT m_commands.contains(command) THEN
        RETURN NULL
    END IF
    RETURN m_commands[command]
END FUNCTION

#+ Every command an action file may use, in alphabetical order.
PUBLIC FUNCTION commands() RETURNS inspect.StringList
    DEFINE r inspect.StringList
    CALL commandTable()
    LET r = m_commands.getKeys()
    CALL r.sort(NULL, FALSE)
    RETURN r
END FUNCTION

# TRUE if requirement letter `what` is in `req`.
PRIVATE FUNCTION needs(req STRING, what STRING) RETURNS BOOLEAN
    IF req.getIndexOf(what, 1) > 0 THEN
        RETURN TRUE
    END IF
    RETURN FALSE
END FUNCTION

# TRUE if v is a whole number that fits an INTEGER count or delay.
PRIVATE FUNCTION isCount(v STRING) RETURNS BOOLEAN
    IF v IS NULL OR LENGTH(v) == 0 OR LENGTH(v) > 9 THEN
        RETURN FALSE
    END IF
    IF v.matches("^[0-9]+$") THEN
        RETURN TRUE
    END IF
    RETURN FALSE
END FUNCTION

# ------------------------------------------------------------------ exec ----

#+ Execute a list of steps against the active driver, recording assertion
#+ outcomes into fgltest.core. Unknown commands record a failure (never silent).
PUBLIC FUNCTION exec(steps StepList)
    DEFINE i INTEGER
    DEFINE s Step
    DEFINE d driver.Driver

    LET d = core.getDriver()
    FOR i = 1 TO steps.getLength()
        # Once the driver has errored the session state is unknown; the rest of
        # this step list would only produce noise. The runner reports the test.
        IF core.hasDriverError() THEN
            EXIT FOR
        END IF
        LET s = steps[i]
        CASE s.command
            # ------------------------------------------ interaction verbs ----
            WHEN "action"
                CALL flow.action(s.target)
            WHEN "field"
                CALL flow.field(s.target)
            WHEN "enter"
                CALL flow.enter(s.value)
            WHEN "fill"
                CALL flow.fill(s.target, s.value)
            WHEN "clear"
                CALL flow.clear()
            WHEN "key"
                CALL flow.press(s.target)
            WHEN "pause"
                CALL flow.pause(toInt(s.value))
            # ---------------------------------------- table interaction ----
            WHEN "selectRow"
                CALL flow.selectRow(s.target, s.rowNum)
            WHEN "focusCell"
                CALL flow.focusCell(s.target, s.col, s.rowNum)
            # ---------------------------------------------- assertions ----
            WHEN "assertField"
                CALL expect.that(d.fieldValue(s.target)).toEqual(s.value)
            WHEN "assertFieldNot"
                CALL expect.that(d.fieldValue(s.target)).notToEqual(s.value)
            WHEN "assertFieldContains"
                CALL expect.that(d.fieldValue(s.target)).toContainText(s.value)
            WHEN "assertFieldMatches"
                CALL expect.that(d.fieldValue(s.target)).toMatch(s.value)
            WHEN "assertCurrent"
                CALL expect.that(d.currentValue()).toEqual(s.value)
            WHEN "assertFormName"
                CALL expect.that(inspect.formName()).toEqual(s.value)
            WHEN "assertFormTitle"
                CALL expect.that(d.formTitle()).toEqual(s.value)
            WHEN "assertWindowName"
                CALL expect.that(inspect.windowName()).toEqual(s.value)
            WHEN "assertWindowTitle"
                CALL expect.that(d.windowTitle()).toEqual(s.value)
            WHEN "assertActionActive"
                CALL expect.all(inspect.activeActionNames()).toContain(s.target)
            WHEN "assertActionInactive"
                CALL expect.all(inspect.activeActionNames()).notToContain(s.target)
            WHEN "assertActionExists"
                CALL expect.all(inspect.actionNames()).toContain(s.target)
            WHEN "assertActionMissing"
                CALL expect.all(inspect.actionNames()).notToContain(s.target)
            WHEN "assertFieldEnabled"
                CALL expect.all(inspect.enabledFields()).toContain(s.target)
            WHEN "assertFieldDisabled"
                CALL expect.all(inspect.enabledFields()).notToContain(s.target)
            WHEN "assertFieldEditable"
                CALL expect.all(inspect.editableFields()).toContain(s.target)
            WHEN "assertFieldReadOnly"
                CALL expect.all(inspect.editableFields()).notToContain(s.target)
            WHEN "assertFieldExists"
                CALL expect.all(inspect.fieldNames()).toContain(s.target)
            WHEN "assertFieldMissing"
                CALL expect.all(inspect.fieldNames()).notToContain(s.target)
            WHEN "assertFieldCount"
                CALL expect.all(inspect.fieldNames()).toHaveSize(toInt(s.value))
            # ------------------------------------------ table assertions ----
            WHEN "assertTableExists"
                CALL expect.all(inspect.tables()).toContain(s.target)
            WHEN "assertCell"
                CALL expect.that(inspect.currentCellValue(s.target, s.col)).toEqual(s.value)
            WHEN "assertCellContains"
                CALL expect.that(inspect.currentCellValue(s.target, s.col)).toContainText(s.value)
            WHEN "assertCellMatches"
                CALL expect.that(inspect.currentCellValue(s.target, s.col)).toMatch(s.value)
            WHEN "assertCellAtRow"
                CALL flow.selectRow(s.target, s.rowNum)
                CALL expect.that(inspect.cellValue(s.target, s.col, s.rowNum)).toEqual(s.value)
            WHEN "assertRowCount"
                CALL expect.num(inspect.rowCount(s.target)).toEqual(toInt(s.value))
            WHEN "assertRowCountAtLeast"
                CALL expect.num(inspect.rowCount(s.target)).toBeAtLeast(toInt(s.value))
            WHEN "assertRowCountAtMost"
                CALL expect.num(inspect.rowCount(s.target)).toBeAtMost(toInt(s.value))
            WHEN "assertCurrentRow"
                CALL expect.num(inspect.currentRow(s.target)).toEqual(toInt(s.value))
            OTHERWISE
                CALL core.recordFail("unknownCommand",
                    SFMT("unknown command '%1' at step %2", s.command, i))
        END CASE
    END FOR
END FUNCTION

# ------------------------------------------------------------- accessors ----

#+ The application name declared by the loaded action file.
PUBLIC FUNCTION appName() RETURNS STRING
    RETURN m_file.application
END FUNCTION

PUBLIC FUNCTION beforeAllSteps() RETURNS StepList
    RETURN m_file.beforeAll
END FUNCTION

PUBLIC FUNCTION beforeEachSteps() RETURNS StepList
    RETURN m_file.beforeEach
END FUNCTION

PUBLIC FUNCTION afterEachSteps() RETURNS StepList
    RETURN m_file.afterEach
END FUNCTION

PUBLIC FUNCTION afterAllSteps() RETURNS StepList
    RETURN m_file.afterAll
END FUNCTION

#+ Number of tests in the loaded action file.
PUBLIC FUNCTION testCount() RETURNS INTEGER
    RETURN m_file.tests.getLength()
END FUNCTION

#+ Name of test #i (1-based).
PUBLIC FUNCTION testName(i INTEGER) RETURNS STRING
    RETURN m_file.tests[i].name
END FUNCTION

#+ Steps of test #i (1-based).
PUBLIC FUNCTION testStepsAt(i INTEGER) RETURNS StepList
    RETURN m_file.tests[i].steps
END FUNCTION

#+ TRUE if test #i is marked "skip". Concrete boolean: a flag absent from the
#+ JSON parses as NULL, and callers legitimately write `IF NOT ...`.
PUBLIC FUNCTION testIsSkipped(i INTEGER) RETURNS BOOLEAN
    RETURN core.isTrue(m_file.tests[i].skip)
END FUNCTION

#+ TRUE if test #i is marked "only" (see testIsSkipped on the concrete boolean).
PUBLIC FUNCTION testIsOnly(i INTEGER) RETURNS BOOLEAN
    RETURN core.isTrue(m_file.tests[i].only)
END FUNCTION

# --------------------------------------------------------------- helpers ----

#+ Parse an integer from a step value (NULL/blank -> 0).
PRIVATE FUNCTION toInt(v STRING) RETURNS INTEGER
    DEFINE n INTEGER
    IF v IS NULL OR LENGTH(v) == 0 THEN
        RETURN 0
    END IF
    LET n = v
    RETURN n
END FUNCTION

#+ Read a whole file into a string (NULL if it cannot be opened).
PRIVATE FUNCTION readFile(path STRING) RETURNS STRING
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
        CALL b.append(ASCII 10)
    END WHILE
    CALL ch.close()
    RETURN b.toString()
END FUNCTION
