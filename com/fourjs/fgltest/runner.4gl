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
#
# Reports account for every test even when the process dies part-way: each
# selected test gets an outcome up front ("not run"), the running test is marked
# "did not complete" before it starts, and the reports are rewritten around each
# test. Whatever kills the process, the last reports on disk name the test it
# died in and every test it never reached.

PACKAGE com.fourjs.fgltest

IMPORT FGL ggc
IMPORT FGL com.fourjs.fgltest.driver
IMPORT FGL com.fourjs.fgltest.core
IMPORT FGL com.fourjs.fgltest.ggcdriver
IMPORT FGL com.fourjs.fgltest.inspect
IMPORT FGL com.fourjs.fgltest.reporters
IMPORT FGL com.fourjs.fgltest.script

PUBLIC TYPE TestFn FUNCTION() RETURNS ()

# Write-ahead outcome messages: what the reports say about a test if the
# process ends before the runner gets to record the real result.
PRIVATE CONSTANT NOT_STARTED = "not run: the suite process ended before this test started"
PRIVATE CONSTANT IN_FLIGHT = "did not complete: the suite process ended during this test — see the suite log for the error"
PRIVATE CONSTANT IN_FLIGHT_HOOK = "did not complete: the suite process ended during this hook — see the suite log for the error"

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
# Test names must be unique: a name identifies a test in the reports and
# selects it in isolate mode. Each name's first test, and for every test the
# index of the earlier test it shares its name with (0 = none).
PRIVATE DEFINE g_firstWithName DICTIONARY OF INTEGER
PRIVATE DEFINE g_dupOf DYNAMIC ARRAY OF INTEGER
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
# Test index -> its slot in g_outcomes (0 = not selected in this run).
PRIVATE DEFINE g_slot DYNAMIC ARRAY OF INTEGER

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
    LET g_dupOf[n] = 0
    IF LENGTH(g_testNames[n]) > 0 THEN
        IF g_firstWithName.contains(g_testNames[n]) THEN
            LET g_dupOf[n] = g_firstWithName[g_testNames[n]]
        ELSE
            LET g_firstWithName[g_testNames[n]] = n
        END IF
    END IF
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

#+ Run every registered test against `d`, with no GGC session.
#+
#+ run() is the normal entry point. runWith() leaves GGC out entirely — no
#+ connection, no scenario — and drives the given Driver directly, so an
#+ alternative Driver implementation (or fgltest's own tests, with an in-memory
#+ one) gets the whole runner: hooks, selection, the FGLTEST_* settings,
#+ reports and the completion marker. Afterwards getOutcomes() holds the results.
#+
#+ @param d the driver the tests interact through
PUBLIC FUNCTION runWith(d driver.Driver)
    CALL core.setDriver(d)
    CALL execute()
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
    DEFINE i INTEGER

    # Make ggc report errors instead of calling EXIT PROGRAM, so a mistyped
    # field/table/action name fails one test instead of killing the whole run
    # (and losing every report). Must be inside the scenario: the session is
    # connected here.
    CALL ggcdriver.beNonFatal()

    CALL execute()

    # Forward failures LAST (no ggc interaction may follow notifyFailure), then end.
    FOR i = 1 TO g_outcomes.getLength()
        IF NOT core.isTrue(g_outcomes[i].passed) AND NOT core.isTrue(g_outcomes[i].skipped) THEN
            CALL ggc.notifyFailure(failureNote(i))
        END IF
    END FOR

    CALL ggc.end()
END FUNCTION

# The one-line reason GGC records for a test that did not pass.
PRIVATE FUNCTION failureNote(oc INTEGER) RETURNS STRING
    IF core.isTrue(g_outcomes[oc].errored) AND g_outcomes[oc].messages.getLength() > 0 THEN
        RETURN SFMT("test '%1': %2", g_outcomes[oc].name, g_outcomes[oc].messages[1])
    END IF
    RETURN SFMT("test '%1': %2/%3 checks failed",
        g_outcomes[oc].name, g_outcomes[oc].failed, g_outcomes[oc].checks)
END FUNCTION

# Run the hooks and the selected tests against the active driver, recording an
# outcome per test, then report and drop the completion marker. Shared by run()
# (inside the GGC scenario) and runWith().
PRIVATE FUNCTION execute()
    DEFINE i, oc INTEGER
    DEFINE only STRING
    DEFINE runStart, budget FLOAT
    DEFINE ok BOOLEAN

    LET only = fgl_getenv("FGLTEST_ONLY")   -- isolate mode: run just this test
    LET runStart = core.nowSeconds()
    LET budget = timeoutSeconds()   -- 0 = no budget
    CALL core.clearFatal()

    # Write-ahead: every selected test is on the reports before anything runs.
    # If the process then dies — an uncaught runtime error, the application
    # taking the session down, a kill — the reports still list every test
    # instead of quietly holding only the ones that finished.
    CALL planOutcomes(only)
    CALL emitReports()

    # A failed beforeAll means the suite's setup did not happen: running the
    # tests anyway would only bury the root cause under consequences. Each test
    # is reported not run, and the hook's own entry says why.
    LET ok = runSuiteHooks("beforeAll", g_beforeAll, g_beforeAllSteps)
    IF NOT ok THEN
        CALL markNotRun(1, "not run: the beforeAll hook failed")
    END IF

    FOR i = 1 TO g_testNames.getLength()
        IF NOT ok THEN
            EXIT FOR
        END IF
        LET oc = g_slot[i]
        IF oc == 0 THEN
            CONTINUE FOR   -- not selected (FGLTEST_ONLY)
        END IF
        IF core.isTrue(g_outcomes[oc].skipped) OR g_dupOf[i] > 0 THEN
            CONTINUE FOR   -- recorded as skipped / duplicate by planOutcomes()
        END IF
        # The application under test is gone: no later test can run. Stop
        # scheduling and let the loop fall through to reporting, so the results
        # gathered so far are still written.
        IF core.isFatal() THEN
            CALL markNotRun(i, "not run: the application under test ended")
            EXIT FOR
        END IF
        # Suite budget exhausted: record the remainder as errored rather than
        # silently dropping them, then report what we have.
        IF budget > 0 AND (core.nowSeconds() - runStart) > budget THEN
            CALL markNotRun(i,
                SFMT("not run: suite exceeded FGLTEST_TIMEOUT of %1s", budget))
            EXIT FOR
        END IF
        # On disk as "did not complete" while it runs, so a process that dies in
        # this test leaves reports naming it.
        CALL setNotRun(oc, IN_FLIGHT)
        CALL emitReports()
        CALL runOne(i, oc)
        CALL emitReports()
        IF probeApplication(oc) THEN
            CALL emitReports()
        END IF
    END FOR

    # afterAll runs even after a failure, so cleanup still happens.
    LET ok = runSuiteHooks("afterAll", g_afterAll, g_afterAllSteps)

    CALL reportConsole()
    CALL emitReports()
    # Signal completion last of all here, and before any closing ggc call. If the
    # application has already gone, notifyFailure/end hit ggc.CLOSED, which exits
    # the process from inside ggc — so a marker written after them would never
    # appear, and the CLI would take a finished suite for one that died.
    CALL writeDoneMarker()
END FUNCTION

# Run the beforeAll or afterAll hooks as a phase of their own. While they run
# they are on the reports as "<label> hook: did not complete"; if they pass,
# that entry is removed, otherwise it stays, errored, with what went wrong — a
# failed check, a driver error or a trapped runtime error. Returns TRUE if the
# hooks passed (or there were none).
#
# Once the application under test is gone, an afterAll hook can still do its
# non-UI cleanup, but its interactions are bound to fail. Those driver errors
# are consequences, not news, so they are not held against the hook.
PRIVATE FUNCTION runSuiteHooks(label STRING, fns DYNAMIC ARRAY OF TestFn,
    steps script.StepList) RETURNS BOOLEAN
    DEFINE j, oc INTEGER
    DEFINE t0 FLOAT
    DEFINE crash STRING
    DEFINE appGone, crashed BOOLEAN

    IF fns.getLength() == 0 AND steps.getLength() == 0 THEN
        RETURN TRUE
    END IF
    LET appGone = core.isTrue(core.isFatal())
    LET oc = g_outcomes.getLength() + 1
    LET g_outcomes[oc].name = SFMT("%1 hook", label)
    CALL setNotRun(oc, IN_FLIGHT_HOOK)
    CALL emitReports()

    CALL core.resetResults()
    CALL core.clearDriverError()
    LET t0 = core.nowSeconds()
    TRY
        FOR j = 1 TO fns.getLength()
            CALL fns[j]()
        END FOR
        CALL script.exec(steps)
    CATCH
        LET crash = runtimeError(status)
    END TRY
    IF appGone THEN
        CALL core.clearDriverError()
    END IF
    CALL recordOutcome(oc, crash, t0)
    IF NOT appGone THEN
        LET crashed = probeApplication(oc)   -- errors the entry if so
    END IF

    IF core.isTrue(g_outcomes[oc].passed) THEN
        CALL g_outcomes.deleteElement(oc)   -- the last entry: no test slot moves
        CALL emitReports()
        RETURN TRUE
    END IF
    CALL emitReports()
    RETURN FALSE
END FUNCTION

# Give every test selected for this run its outcome slot, in registration
# order: skipped tests are final at once, the rest start as not run.
PRIVATE FUNCTION planOutcomes(only STRING)
    DEFINE i, oc INTEGER

    CALL g_outcomes.clear()
    CALL g_slot.clear()
    FOR i = 1 TO g_testNames.getLength()
        LET g_slot[i] = 0
        IF only IS NOT NULL AND LENGTH(only) > 0 AND g_testNames[i] != only THEN
            CONTINUE FOR
        END IF
        LET oc = g_outcomes.getLength() + 1
        LET g_slot[i] = oc
        LET g_outcomes[oc].name = g_testNames[i]
        IF g_dupOf[i] > 0 THEN
            # Reported, not run: two tests with one name cannot be told apart
            # in the reports, and isolate mode would run both under either.
            CALL setNotRun(oc, SFMT("not run: test #%1 already has this name — test names must be unique",
                g_dupOf[i]))
            CONTINUE FOR
        END IF
        IF g_testMode[i] == MODE_SKIP OR (g_hasOnly AND g_testMode[i] != MODE_ONLY) THEN
            # Assign every boolean explicitly: an unset field is NULL, and NULL
            # negates to NULL, which silently reads as false downstream.
            LET g_outcomes[oc].skipped = TRUE
            LET g_outcomes[oc].passed = FALSE
            LET g_outcomes[oc].errored = FALSE
            LET g_outcomes[oc].checks = 0
            LET g_outcomes[oc].failed = 0
            LET g_outcomes[oc].duration = 0
        ELSE
            CALL setNotRun(oc, NOT_STARTED)
        END IF
    END FOR
END FUNCTION

# Record outcome `oc` as errored without a result, for the reason `why`.
PRIVATE FUNCTION setNotRun(oc INTEGER, why STRING)
    LET g_outcomes[oc].passed = FALSE
    LET g_outcomes[oc].errored = TRUE
    LET g_outcomes[oc].skipped = FALSE
    LET g_outcomes[oc].checks = 0
    LET g_outcomes[oc].failed = 0
    LET g_outcomes[oc].duration = 0
    CALL g_outcomes[oc].messages.clear()
    LET g_outcomes[oc].messages[1] = why
END FUNCTION

# Record the selected, non-skipped tests from index `from` onwards as not run,
# so a truncated run says why every remaining test has no result.
PRIVATE FUNCTION markNotRun(from INTEGER, why STRING)
    DEFINE i, oc INTEGER
    FOR i = from TO g_testNames.getLength()
        LET oc = g_slot[i]
        IF oc == 0 THEN
            CONTINUE FOR
        END IF
        IF core.isTrue(g_outcomes[oc].skipped) OR g_dupOf[i] > 0 THEN
            CONTINUE FOR
        END IF
        CALL setNotRun(oc, why)
    END FOR
END FUNCTION

# Run test i — its beforeEach hooks, body and afterEach hooks — and record the
# result in outcome slot oc.
PRIVATE FUNCTION runOne(i INTEGER, oc INTEGER)
    DEFINE j INTEGER
    DEFINE t0 FLOAT
    DEFINE crash STRING

    CALL core.resetResults()
    CALL core.clearDriverError()
    LET t0 = core.nowSeconds()

    # A runtime error in a test or hook reaches this TRY only if the module that
    # raised it declares WHENEVER ANY ERROR RAISE; otherwise BDL stops the
    # program where it happened, and the write-ahead outcome above reports it.
    # Trapped, it errors just this test: the rest of the body is abandoned and
    # afterEach still runs.
    TRY
        FOR j = 1 TO g_beforeEach.getLength()
            CALL g_beforeEach[j]()
        END FOR
        CALL script.exec(g_beforeEachSteps)

        IF g_testKind[i] == KIND_STEPS THEN
            CALL script.exec(g_testSteps[i])
        ELSE
            CALL g_testFns[i]()
        END IF
    CATCH
        LET crash = runtimeError(status)
    END TRY

    # afterEach must still run even when the body errored, so per-test
    # cleanup happens; it short-circuits at the driver if the session is bad.
    TRY
        FOR j = 1 TO g_afterEach.getLength()
            CALL g_afterEach[j]()
        END FOR
        CALL script.exec(g_afterEachSteps)
    CATCH
        IF crash IS NULL THEN
            LET crash = runtimeError(status)
        END IF
    END TRY

    CALL recordOutcome(oc, crash, t0)
END FUNCTION

# Fill outcome slot oc from what the phase that started at t0 recorded: its
# checks, its driver error, and `crash` (a trapped runtime error, or NULL).
PRIVATE FUNCTION recordOutcome(oc INTEGER, crash STRING, t0 FLOAT)
    DEFINE k, n INTEGER
    DEFINE res core.CheckResultList

    LET res = core.getResults()
    CALL g_outcomes[oc].messages.clear()
    LET g_outcomes[oc].checks = res.getLength()
    LET g_outcomes[oc].failed = core.failCount()
    LET g_outcomes[oc].duration = core.nowSeconds() - t0
    # Assign every boolean explicitly: an unset field is NULL, and NULL
    # negates to NULL, which silently reads as false downstream.
    LET g_outcomes[oc].skipped = FALSE
    LET g_outcomes[oc].errored = FALSE
    IF crash IS NOT NULL OR core.isTrue(core.hasDriverError()) THEN
        LET g_outcomes[oc].errored = TRUE
    END IF
    LET g_outcomes[oc].passed =
        (g_outcomes[oc].failed == 0 AND NOT g_outcomes[oc].errored)
    IF crash IS NOT NULL THEN
        LET g_outcomes[oc].messages[g_outcomes[oc].messages.getLength() + 1] = crash
    END IF
    IF core.isTrue(core.hasDriverError()) THEN
        LET g_outcomes[oc].messages[g_outcomes[oc].messages.getLength() + 1] =
            SFMT("driver error: %1", core.driverError())
    END IF
    FOR k = 1 TO res.getLength()
        IF NOT res[k].passed THEN
            LET n = g_outcomes[oc].messages.getLength() + 1
            LET g_outcomes[oc].messages[n] = SFMT("%1: %2", res[k].message, res[k].detail)
        END IF
    END FOR
END FUNCTION

# After a test or hook phase recorded in slot oc: if the application under test
# stopped on a runtime error meanwhile, charge that phase with it and end the
# run. GGC keeps answering from the screen it last saw, so without this check
# the phase could pass and the crash would surface later, as some unrelated
# assertion failure. Returns TRUE if it changed the outcome.
PRIVATE FUNCTION probeApplication(oc INTEGER) RETURNS BOOLEAN
    DEFINE msg STRING
    IF core.isFatal() THEN
        RETURN FALSE   -- already known to be gone
    END IF
    # The phase's own driver error is recorded already; the probe must run
    # regardless, and its own failure is not the phase's.
    CALL core.clearDriverError()
    LET msg = inspect.applicationError()
    CALL core.clearDriverError()
    IF msg IS NULL THEN
        RETURN FALSE
    END IF
    CALL core.setFatal()
    LET g_outcomes[oc].passed = FALSE
    LET g_outcomes[oc].errored = TRUE
    CALL g_outcomes[oc].messages.insertElement(1)
    LET g_outcomes[oc].messages[1] =
        SFMT("the application under test stopped with a runtime error: %1", msg)
    RETURN TRUE
END FUNCTION

# Describe a trapped runtime error on one line (err_get() text ends in a
# newline, which trim() does not remove).
PRIVATE FUNCTION runtimeError(code INTEGER) RETURNS STRING
    DEFINE b base.StringBuffer
    DEFINE msg STRING
    LET b = base.StringBuffer.create()
    CALL b.append(err_get(code))
    CALL b.replace(ASCII 13, " ", 0)
    CALL b.replace(ASCII 10, " ", 0)
    LET msg = b.toString()
    RETURN SFMT("runtime error %1: %2", code, msg.trim())
END FUNCTION

# Drop a marker file telling the CLI this suite ran to completion. A process
# exit status cannot tell "tests failed" from "the process died part-way", and
# BDL's RUN gives the timeout watchdog no PID to poll, so the CLI judges every
# suite process by this marker: no marker, and the run did not finish.
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
