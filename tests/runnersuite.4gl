# runnersuite — suites that go wrong in specific ways, for selftest.
#
#   fglrun tests/runnersuite <mode>
#
# Runs on the fake driver through runner.runWith(), so no GGC is needed.
# selftest sets FGLTEST_REPORTERS / FGLTEST_OUTDIR / FGLTEST_NAME, runs one
# mode as a subprocess, and reads the JSON report back. Modes:
#
#   uncaught        test 2 dereferences a NULL object (-8083) in a function
#                   ABOVE this module's WHENEVER directive, so BDL stops the
#                   program on the spot. The reports must still account for
#                   all three tests, and no completion marker may appear.
#   caught          the same error, raised in a function BELOW
#                   `WHENEVER ANY ERROR RAISE`: it propagates to the runner,
#                   which errors that one test and carries on.
#   beforeall-fails a beforeAll hook records a failed check: no test may run,
#                   and afterAll must still run (it leaves afterall.ran).
#   afterall-fails  an afterAll hook hits a driver error after passing tests.
#   duplicates      two tests share a name: the second must be reported, not
#                   run (and not run twice under FGLTEST_ONLY).
#   app-crash       test 2 "crashes the application": the fake AUI tree starts
#                   showing the runtime's error box while reads still succeed.
#                   An afterAll interaction then fails, as it would against a
#                   dead application, which must not be held against it.
#
# Like the fake driver, this lives outside the package root.

IMPORT FGL com.fourjs.fgltest.runner
IMPORT FGL com.fourjs.fgltest.expect
IMPORT FGL com.fourjs.fgltest.core
IMPORT FGL fakedriver

MAIN
    DEFINE mode STRING
    LET mode = arg_val(1)
    CALL runner.setApplication("runnersuite")
    CASE mode
        WHEN "caught"
            -- records one check per test, so the report shows afterEach ran
            CALL runner.afterEach(FUNCTION t_pass)
            CALL runner.test("passes before the error", FUNCTION t_pass)
            CALL runner.test("raises a runtime error", FUNCTION t_error_raised)
            CALL runner.test("runs after the error", FUNCTION t_pass)
        WHEN "beforeall-fails"
            CALL runner.beforeAll(FUNCTION h_failing_check)
            CALL runner.afterAll(FUNCTION h_note_afterall)
            CALL runner.test("first", FUNCTION t_pass)
            CALL runner.test("second", FUNCTION t_pass)
            CALL runner.testSkip("skipped", FUNCTION t_pass)
        WHEN "afterall-fails"
            CALL runner.afterAll(FUNCTION h_driver_error)
            CALL runner.test("first", FUNCTION t_pass)
            CALL runner.test("second", FUNCTION t_pass)
        WHEN "duplicates"
            CALL runner.test("same name", FUNCTION t_pass)
            CALL runner.test("same name", FUNCTION t_pass)
            CALL runner.test("another name", FUNCTION t_pass)
        WHEN "app-crash"
            CALL runner.afterAll(FUNCTION h_driver_error)
            CALL runner.test("passes before the crash", FUNCTION t_pass)
            CALL runner.test("crashes the application", FUNCTION t_crash_app)
            CALL runner.test("comes after the crash", FUNCTION t_pass)
        OTHERWISE   -- "uncaught"
            CALL runner.afterEach(FUNCTION t_pass)
            CALL runner.test("passes before the error", FUNCTION t_pass)
            CALL runner.test("raises a runtime error", FUNCTION t_error_fatal)
            CALL runner.test("runs after the error", FUNCTION t_pass)
    END CASE
    CALL runner.runWith(fakedriver.asDriver())
END MAIN

FUNCTION t_pass()
    CALL expect.bool(TRUE).toBeTrue()
END FUNCTION

# No WHENEVER directive above this line: a language error stops the program.
FUNCTION t_error_fatal()
    DEFINE sb base.StringBuffer
    CALL sb.append("x")   -- -8083: sb was never created
END FUNCTION

# A WHENEVER directive applies to every line after it in the module, whether
# or not this function ever runs. This is the opt-in a suite module uses to
# have the runner trap its runtime errors.
FUNCTION optInToRaise()
    WHENEVER ANY ERROR RAISE
END FUNCTION

FUNCTION t_error_raised()
    DEFINE sb base.StringBuffer
    CALL sb.append("x")   -- -8083, now raised to the runner's TRY
END FUNCTION

FUNCTION h_failing_check()
    CALL expect.bool(FALSE).toBeTrue()
END FUNCTION

FUNCTION h_driver_error()
    CALL core.setDriverError("simulated: the action could not be sent")
END FUNCTION

# Leave a file behind, so selftest can see that afterAll ran.
FUNCTION h_note_afterall()
    DEFINE ch base.Channel
    LET ch = base.Channel.create()
    CALL ch.openFile(fgl_getenv("FGLTEST_OUTDIR") || "/afterall.ran", "w")
    CALL ch.writeLine("ran")
    CALL ch.close()
END FUNCTION

# What GGC shows once the application under test has stopped on a runtime
# error: the runtime's message box, while the old window is still on screen.
FUNCTION t_crash_app()
    CALL fakedriver.setAui('<UserInterface><Window name="screen"><Form name="f"/>'
        || '<Menu style="winmsg" text="ERROR" comment="Program stopped at '
        || "'app.4gl'" || ', line number 12.&#10;FORMS statement error number -8083.&#10;'
        || 'Null pointer exception.&#10;"><MenuAction name="ok" active="1"/></Menu>'
        || '</Window></UserInterface>')
    -- a read against the stale screen still "passes"
    CALL expect.bool(TRUE).toBeTrue()
END FUNCTION
