# fgltest_json — the generic runner for a declarative JSON action file.
#
# It is the JSON-mode twin of a compiled suite: it connects to an application
# (tcp/ua, via ggc) and runs tests — but the tests come from an action file
# instead of compiled BDL. One shipped program runs any action file, so authors
# write JSON and never compile.
#
#   FGLTEST_ACTIONS=tests/price.actions.json \
#     fglrun fgltest_json tcp --working-directory <dir> --command-line "fglrun price"
#
# The action-file path arrives via the FGLTEST_ACTIONS env var, NOT argv, because
# ggc.parseOptions() (inside runner.run()) consumes argv and rejects unknown
# flags. The fgltest CLI sets this automatically for suites that declare
# "actions". Reporting, hooks, and the CI exit code are the runner's, shared with
# compiled suites.

IMPORT FGL com.fourjs.fgltest.runner
IMPORT FGL com.fourjs.fgltest.script

MAIN
    DEFINE path, err STRING
    DEFINE i INTEGER

    LET path = fgl_getenv("FGLTEST_ACTIONS")
    IF path IS NULL OR LENGTH(path) == 0 THEN
        DISPLAY "fgltest_json: set FGLTEST_ACTIONS to the action-file path"
        EXIT PROGRAM 2
    END IF

    LET err = script.load(path)
    IF err IS NOT NULL THEN
        DISPLAY SFMT("fgltest_json: %1", err)
        EXIT PROGRAM 2
    END IF

    CALL runner.setApplication(script.appName())
    CALL runner.beforeAllSteps(script.beforeAllSteps())
    CALL runner.beforeEachSteps(script.beforeEachSteps())
    CALL runner.afterEachSteps(script.afterEachSteps())
    CALL runner.afterAllSteps(script.afterAllSteps())
    FOR i = 1 TO script.testCount()
        # "skip"/"only" in the action file map onto the same registration modes
        # a compiled suite uses, so both authoring modes behave identically.
        IF script.testIsSkipped(i) THEN
            CALL runner.testStepsSkip(script.testName(i), script.testStepsAt(i))
        ELSE
            IF script.testIsOnly(i) THEN
                CALL runner.testStepsOnly(script.testName(i), script.testStepsAt(i))
            ELSE
                CALL runner.testSteps(script.testName(i), script.testStepsAt(i))
            END IF
        END IF
    END FOR

    CALL runner.run()
END MAIN
