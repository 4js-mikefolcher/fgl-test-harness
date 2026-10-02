# fgltest.runner — test registration, lifecycle hooks, and the run orchestrator.
#
# A suite is a compiled program:
#     IMPORT FGL com.fourjs.fgltest.runner
#     IMPORT FGL com.fourjs.fgltest.flow
#     IMPORT FGL com.fourjs.fgltest.expect
#     IMPORT FGL com.fourjs.fgltest.inspect
#     MAIN
#         CALL runner.setApplication("price")
#         CALL runner.beforeEach(FUNCTION settle)
#         CALL runner.test("edits a price", FUNCTION t_edit)
#         CALL runner.run()
#     END MAIN
#
# run() sets the driver and registers ONE ggc scenario (testLoop) that runs every
# test in-session with before/after hooks, records per-test outcomes, reports,
# then forwards failures to GGC (last, so no interaction follows) so the process
# exit code reflects them.
#
# The GGC scenario server lifecycle is owned by the fgltest CLI (Phase 5), NOT by
# the suite: GGC's provider may EXIT PROGRAM inside play(), so in-suite cleanup
# after play() is unreliable. A suite therefore assumes the server is already up.

PACKAGE com.fourjs.fgltest

IMPORT FGL ggc
IMPORT FGL com.fourjs.fgltest.core
IMPORT FGL com.fourjs.fgltest.ggcdriver
IMPORT FGL com.fourjs.fgltest.reporters
IMPORT FGL com.fourjs.fgltest.script

PUBLIC TYPE TestFn FUNCTION() RETURNS ()

# A test is either a BDL function (kind 0) or a JSON step-list (kind 1).
PRIVATE CONSTANT KIND_FN = 0
PRIVATE CONSTANT KIND_STEPS = 1

# Selection mode. If ANY test is registered ONLY, every test not marked ONLY is
# skipped — the usual "focus on what I am debugging" behaviour.
PRIVATE CONSTANT MODE_NORMAL = 0
PRIVATE CONSTANT MODE_SKIP = 1
PRIVATE CONSTANT MODE_ONLY = 2

PRIVATE DEFINE g_appName STRING
PRIVATE DEFINE g_testNames DYNAMIC ARRAY OF STRING
PRIVATE DEFINE g_testFns DYNAMIC ARRAY OF TestFn
PRIVATE DEFINE g_testSteps DYNAMIC ARRAY OF script.StepList
PRIVATE DEFINE g_testKind DYNAMIC ARRAY OF SMALLINT
PRIVATE DEFINE g_testMode DYNAMIC ARRAY OF SMALLINT
PRIVATE DEFINE g_hasOnly BOOLEAN
PRIVATE DEFINE g_beforeEach DYNAMIC ARRAY OF TestFn
PRIVATE DEFINE g_afterEach DYNAMIC ARRAY OF TestFn
PRIVATE DEFINE g_beforeAll DYNAMIC ARRAY OF TestFn
PRIVATE DEFINE g_afterAll DYNAMIC ARRAY OF TestFn
# JSON-mode hook step-lists (empty for compiled suites; a suite uses one of the
# two authoring modes, and the unused set stays empty so exec() is a no-op).
PRIVATE DEFINE g_beforeEachSteps script.StepList
PRIVATE DEFINE g_afterEachSteps script.StepList
PRIVATE DEFINE g_beforeAllSteps script.StepList
PRIVATE DEFINE g_afterAllSteps script.StepList
PRIVATE DEFINE g_outcomes core.OutcomeList

# ---------------------------------------------------------- registration ----

#+ Name of the application under test (passed to ggc).
PUBLIC FUNCTION setApplication(name STRING)
    LET g_appName = name
END FUNCTION

#+ Register a test case backed by a BDL function.
PUBLIC FUNCTION test(name STRING, fn TestFn)
    CALL addFn(name, fn, MODE_NORMAL)
END FUNCTION

#+ Register a test that is reported as skipped instead of run.
PUBLIC FUNCTION testSkip(name STRING, fn TestFn)
    CALL addFn(name, fn, MODE_SKIP)
END FUNCTION

#+ Register a focused test. If any test in the suite is registered with
#+ testOnly/testStepsOnly, all others are skipped.
PUBLIC FUNCTION testOnly(name STRING, fn TestFn)
    CALL addFn(name, fn, MODE_ONLY)
END FUNCTION

#+ Register a test case backed by a JSON step-list (declarative action file).
PUBLIC FUNCTION testSteps(name STRING, steps script.StepList)
    CALL addSteps(name, steps, MODE_NORMAL)
END FUNCTION

#+ Step-list test reported as skipped instead of run.
PUBLIC FUNCTION testStepsSkip(name STRING, steps script.StepList)
    CALL addSteps(name, steps, MODE_SKIP)
END FUNCTION

#+ Focused step-list test (see testOnly).
PUBLIC FUNCTION testStepsOnly(name STRING, steps script.StepList)
    CALL addSteps(name, steps, MODE_ONLY)
END FUNCTION

PRIVATE FUNCTION addFn(name STRING, fn TestFn, mode SMALLINT)
    DEFINE n INTEGER
    LET n = g_testNames.getLength() + 1
    LET g_testNames[n] = name
    LET g_testFns[n] = fn
    LET g_testKind[n] = KIND_FN
    CALL noteMode(n, mode)
END FUNCTION

PRIVATE FUNCTION addSteps(name STRING, steps script.StepList, mode SMALLINT)
    DEFINE n INTEGER
    LET n = g_testNames.getLength() + 1
    LET g_testNames[n] = name
    LET g_testSteps[n] = steps
    LET g_testKind[n] = KIND_STEPS
    CALL noteMode(n, mode)
END FUNCTION

PRIVATE FUNCTION noteMode(n INTEGER, mode SMALLINT)
    LET g_testMode[n] = mode
    IF mode == MODE_ONLY THEN
        LET g_hasOnly = TRUE
    END IF
END FUNCTION

#+ Set the JSON-mode beforeAll/beforeEach/afterEach/afterAll hook step-lists.
PUBLIC FUNCTION beforeAllSteps(steps script.StepList)
    LET g_beforeAllSteps = steps
END FUNCTION

PUBLIC FUNCTION beforeEachSteps(steps script.StepList)
    LET g_beforeEachSteps = steps
END FUNCTION

PUBLIC FUNCTION afterEachSteps(steps script.StepList)
    LET g_afterEachSteps = steps
END FUNCTION

PUBLIC FUNCTION afterAllSteps(steps script.StepList)
    LET g_afterAllSteps = steps
END FUNCTION

PUBLIC FUNCTION beforeEach(fn TestFn)
    LET g_beforeEach[g_beforeEach.getLength() + 1] = fn
END FUNCTION

PUBLIC FUNCTION afterEach(fn TestFn)
    LET g_afterEach[g_afterEach.getLength() + 1] = fn
END FUNCTION

PUBLIC FUNCTION beforeAll(fn TestFn)
    LET g_beforeAll[g_beforeAll.getLength() + 1] = fn
END FUNCTION

PUBLIC FUNCTION afterAll(fn TestFn)
    LET g_afterAll[g_afterAll.getLength() + 1] = fn
END FUNCTION

# --------------------------------------------------------------- run ----

#+ Run all registered tests. Parses the tcp/ua connection args from the command
#+ line (via ggc). Assumes the GGC scenario server is already running.
#+
#+ Two env-var hooks support the CLI's --isolate mode (both no-ops otherwise):
#+   FGLTEST_LIST=<path>  write the registered test names to <path> and return
#+                        without connecting (lets the CLI enumerate tests).
#+   FGLTEST_ONLY=<name>  run only the test with that name (see testLoop).
PUBLIC FUNCTION run()
    DEFINE listPath STRING
    LET listPath = fgl_getenv("FGLTEST_LIST")
    IF listPath IS NOT NULL AND LENGTH(listPath) > 0 THEN
        CALL writeTestNames(listPath)
        RETURN
    END IF
    CALL core.setDriver(ggcdriver.asDriver())
    CALL ggc.setApplicationName(g_appName)
    CALL ggc.parseOptions()
    CALL ggc.registerScenario(FUNCTION testLoop)
    CALL ggc.play()
END FUNCTION

# Write each registered test name (one per line) to <path>, for FGLTEST_LIST.
PRIVATE FUNCTION writeTestNames(path STRING)
    DEFINE ch base.Channel
    DEFINE i INTEGER
    LET ch = base.Channel.create()
    CALL ch.openFile(path, "w")
    FOR i = 1 TO g_testNames.getLength()
        CALL ch.writeLine(g_testNames[i])
    END FOR
    CALL ch.close()
END FUNCTION

# Runs in the child scenario process: executes every test with hooks, captures
# outcomes, reports, then forwards failures to GGC (last) so exit code reflects them.
PRIVATE FUNCTION testLoop()
    DEFINE i, j, k, n, oc INTEGER
    DEFINE res core.CheckResultList
    DEFINE only STRING
    DEFINE t0, runStart, budget FLOAT

    CALL g_outcomes.clear()
    LET only = fgl_getenv("FGLTEST_ONLY")   -- isolate mode: run just this test

    # Make ggc report errors instead of calling EXIT PROGRAM, so a mistyped
    # field/table/action name fails one test instead of killing the whole run
    # (and losing every report). Must be inside the scenario: the session is
    # connected here.
    CALL ggcdriver.beNonFatal()

    LET runStart = core.nowSeconds()
    LET budget = timeoutSeconds()   -- 0 = no budget

    FOR j = 1 TO g_beforeAll.getLength()
        CALL g_beforeAll[j]()
    END FOR
    CALL script.exec(g_beforeAllSteps)      -- no-op unless JSON-driven

    FOR i = 1 TO g_testNames.getLength()
        IF only IS NOT NULL AND LENGTH(only) > 0 AND g_testNames[i] != only THEN
            CONTINUE FOR
        END IF
        # The application under test is gone: no later test can run. Stop
        # scheduling and let the loop fall through to reporting, so the results
        # gathered so far are still written.
        IF core.isFatal() THEN
            CALL markNotRun(i, g_testNames.getLength(), only,
                "not run: the application under test ended")
            EXIT FOR
        END IF
        # Suite budget exhausted: record the remainder as errored rather than
        # silently dropping them, then report what we have.
        IF budget > 0 AND (core.nowSeconds() - runStart) > budget THEN
            CALL markNotRun(i, g_testNames.getLength(), only,
                SFMT("not run: suite exceeded FGLTEST_TIMEOUT of %1s", budget))
            EXIT FOR
        END IF
        IF g_testMode[i] == MODE_SKIP OR (g_hasOnly AND g_testMode[i] != MODE_ONLY) THEN
            LET oc = g_outcomes.getLength() + 1
            LET g_outcomes[oc].name = g_testNames[i]
            LET g_outcomes[oc].skipped = TRUE
            LET g_outcomes[oc].passed = FALSE
            LET g_outcomes[oc].errored = FALSE
            LET g_outcomes[oc].duration = 0
            CONTINUE FOR
        END IF
        CALL core.resetResults()
        CALL core.clearDriverError()
        LET t0 = core.nowSeconds()

        FOR j = 1 TO g_beforeEach.getLength()
            CALL g_beforeEach[j]()
        END FOR
        CALL script.exec(g_beforeEachSteps)

        IF g_testKind[i] == KIND_STEPS THEN
            CALL script.exec(g_testSteps[i])
        ELSE
            CALL g_testFns[i]()
        END IF

        # afterEach must still run even when the body errored, so per-test
        # cleanup happens; it short-circuits at the driver if the session is bad.
        FOR j = 1 TO g_afterEach.getLength()
            CALL g_afterEach[j]()
        END FOR
        CALL script.exec(g_afterEachSteps)

        # Append outcomes sequentially (not indexed by i) so FGLTEST_ONLY, which
        # skips tests, leaves no gaps — the report holds only the tests that ran.
        LET res = core.getResults()
        LET oc = g_outcomes.getLength() + 1
        LET g_outcomes[oc].name = g_testNames[i]
        LET g_outcomes[oc].checks = res.getLength()
        LET g_outcomes[oc].failed = core.failCount()
        LET g_outcomes[oc].duration = core.nowSeconds() - t0
        # Assign every boolean explicitly: an unset field is NULL, and NULL
        # negates to NULL, which silently reads as false downstream.
        LET g_outcomes[oc].skipped = FALSE
        LET g_outcomes[oc].errored = core.isTrue(core.hasDriverError())
        LET g_outcomes[oc].passed =
            (g_outcomes[oc].failed == 0 AND NOT g_outcomes[oc].errored)
        IF g_outcomes[oc].errored THEN
            LET g_outcomes[oc].messages[g_outcomes[oc].messages.getLength() + 1] =
                SFMT("driver error: %1", core.driverError())
        END IF
        FOR k = 1 TO res.getLength()
            IF NOT res[k].passed THEN
                LET n = g_outcomes[oc].messages.getLength() + 1
                LET g_outcomes[oc].messages[n] = SFMT("%1: %2", res[k].message, res[k].detail)
            END IF
        END FOR
        # Write the reports after every test, so a hard exit later (the app under
        # test dying, a ggc CLOSED) still leaves the results gathered so far.
        CALL emitReports()
    END FOR

    FOR j = 1 TO g_afterAll.getLength()
        CALL g_afterAll[j]()
    END FOR
    CALL script.exec(g_afterAllSteps)

    CALL reportConsole()
    CALL emitReports()
    # Signal completion BEFORE the closing ggc calls below. If the application
    # has already gone, notifyFailure/end hit ggc.CLOSED, which exits the process
    # from inside ggc — so a marker written after them would never appear, and
    # the CLI's watchdog would wait out the whole timeout on a healthy run.
    CALL writeDoneMarker()

    # Forward failures LAST (no ggc interaction may follow notifyFailure), then end.
    FOR i = 1 TO g_outcomes.getLength()
        IF NOT core.isTrue(g_outcomes[i].passed) AND NOT core.isTrue(g_outcomes[i].skipped) THEN
            CALL ggc.notifyFailure(SFMT("test '%1': %2/%3 checks failed",
                g_outcomes[i].name, g_outcomes[i].failed, g_outcomes[i].checks))
        END IF
    END FOR

    CALL ggc.end()
END FUNCTION

# Record tests from index `from` onwards as errored-without-running, so a
# truncated run still accounts for every registered test.
PRIVATE FUNCTION markNotRun(from INTEGER, to INTEGER, only STRING, why STRING)
    DEFINE i, oc INTEGER
    FOR i = from TO to
        IF only IS NOT NULL AND LENGTH(only) > 0 AND g_testNames[i] != only THEN
            CONTINUE FOR
        END IF
        LET oc = g_outcomes.getLength() + 1
        LET g_outcomes[oc].name = g_testNames[i]
        LET g_outcomes[oc].errored = TRUE
        LET g_outcomes[oc].passed = FALSE
        LET g_outcomes[oc].skipped = FALSE
        LET g_outcomes[oc].duration = 0
        LET g_outcomes[oc].messages[1] = why
    END FOR
END FUNCTION

# Drop a marker file telling the CLI this suite ran to completion. Used only by
# the CLI's opt-in timeout watchdog, which cannot otherwise tell a finished
# subprocess from a wedged one (BDL's RUN gives no PID to poll).
PRIVATE FUNCTION writeDoneMarker()
    DEFINE outdir, name, err STRING
    LET outdir = fgl_getenv("FGLTEST_OUTDIR")
    LET name = fgl_getenv("FGLTEST_NAME")
    IF LENGTH(outdir) == 0 OR LENGTH(name) == 0 THEN
        RETURN
    END IF
    LET err = reporters.writeFile(SFMT("%1/%2.done", outdir, name), "done")
    IF err IS NOT NULL THEN
        DISPLAY SFMT("fgltest: %1", err)
    END IF
END FUNCTION

#+ Whole-suite wall-clock budget in seconds from FGLTEST_TIMEOUT (0 = none).
PRIVATE FUNCTION timeoutSeconds() RETURNS FLOAT
    DEFINE v STRING
    DEFINE n FLOAT
    LET v = fgl_getenv("FGLTEST_TIMEOUT")
    IF v IS NULL OR LENGTH(v) == 0 THEN
        RETURN 0
    END IF
    LET n = v
    IF n IS NULL OR n < 0 THEN
        RETURN 0
    END IF
    RETURN n
END FUNCTION

PRIVATE FUNCTION reportConsole()
    DEFINE i, k, passed, failed, skipped INTEGER
    DISPLAY ""
    DISPLAY "=== fgltest ==="
    FOR i = 1 TO g_outcomes.getLength()
        IF core.isTrue(g_outcomes[i].skipped) THEN
            LET skipped = skipped + 1
            DISPLAY SFMT("  skip %1 - %2", i, g_outcomes[i].name)
        ELSE
        IF core.isTrue(g_outcomes[i].passed) THEN
            LET passed = passed + 1
            DISPLAY SFMT("  ok   %1 - %2 (%3 checks, %4s)",
                i, g_outcomes[i].name, g_outcomes[i].checks,
                g_outcomes[i].duration USING "&.##")
        ELSE
            LET failed = failed + 1
            IF core.isTrue(g_outcomes[i].errored) THEN
                DISPLAY SFMT("  ERROR %1 - %2 (could not run to completion)",
                    i, g_outcomes[i].name)
            ELSE
                DISPLAY SFMT("  FAIL %1 - %2 (%3/%4 checks failed)",
                    i, g_outcomes[i].name, g_outcomes[i].failed, g_outcomes[i].checks)
            END IF
            FOR k = 1 TO g_outcomes[i].messages.getLength()
                DISPLAY SFMT("         - %1", g_outcomes[i].messages[k])
            END FOR
        END IF
        END IF
    END FOR
    DISPLAY SFMT("%1 tests: %2 passed, %3 failed, %4 skipped",
        g_outcomes.getLength(), passed, failed, skipped)
END FUNCTION

#+ The per-test outcomes from the last run.
PUBLIC FUNCTION getOutcomes() RETURNS core.OutcomeList
    RETURN g_outcomes
END FUNCTION

# Emit file reporters selected via env: FGLTEST_REPORTERS (csv of
# console,junit,tap,json) and FGLTEST_OUTDIR (default "."). Console is always
# printed by reportConsole(); this writes the file formats.
PRIVATE FUNCTION emitReports()
    DEFINE spec, outdir, suite, tk, err STRING
    DEFINE tok base.StringTokenizer

    LET spec = fgl_getenv("FGLTEST_REPORTERS")
    IF LENGTH(spec) == 0 THEN
        RETURN
    END IF
    LET outdir = fgl_getenv("FGLTEST_OUTDIR")
    IF LENGTH(outdir) == 0 THEN
        LET outdir = "."
    END IF
    # Report basename: FGLTEST_NAME (set by the CLI to the suite's config name)
    # wins so aggregated results match the config; else the application name.
    LET suite = fgl_getenv("FGLTEST_NAME")
    IF LENGTH(suite) == 0 THEN
        LET suite = g_appName
    END IF
    IF LENGTH(suite) == 0 THEN
        LET suite = "fgltest"
    END IF

    LET tok = base.StringTokenizer.create(spec, ",")
    WHILE tok.hasMoreTokens()
        LET tk = tok.nextToken()
        CASE tk
            WHEN "junit"
                LET err = reporters.writeFile(SFMT("%1/%2.junit.xml", outdir, suite),
                    reporters.toJUnit(g_outcomes, suite))
            WHEN "tap"
                LET err = reporters.writeFile(SFMT("%1/%2.tap", outdir, suite),
                    reporters.toTAP(g_outcomes))
            WHEN "json"
                LET err = reporters.writeFile(SFMT("%1/%2.json", outdir, suite),
                    reporters.toJSON(g_outcomes, suite))
            OTHERWISE
                -- console (already printed) or unknown: ignore
        END CASE
        # A report we could not write is worth saying out loud, but it must not
        # take the run down: the console results above are still valid.
        IF err IS NOT NULL THEN
            DISPLAY SFMT("fgltest: %1", err)
            LET err = NULL
        END IF
    END WHILE
END FUNCTION
