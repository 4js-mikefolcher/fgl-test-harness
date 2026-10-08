# fgltest.core — shared run state: the active Driver used by the fluent API,
# expectations and introspection, plus the per-test assertion results buffer.

PACKAGE com.fourjs.fgltest

IMPORT util
IMPORT os
IMPORT FGL com.fourjs.fgltest.driver

#+ Package version. Keep in step with fglpkg.json and CHANGELOG.md.
PUBLIC CONSTANT VERSION = "1.0.0"


#+ One recorded assertion outcome.
PUBLIC TYPE CheckResult RECORD
    passed BOOLEAN,
    message STRING,
    detail STRING
END RECORD
PUBLIC TYPE CheckResultList DYNAMIC ARRAY OF CheckResult

#+ One test's outcome (produced by the runner, consumed by reporters).
PUBLIC TYPE TestOutcome RECORD
    name STRING,
    passed BOOLEAN,
    errored BOOLEAN,   # the test could not run to completion (driver error)
    skipped BOOLEAN,   # registered but deliberately not run
    checks INTEGER,
    failed INTEGER,
    duration FLOAT,    # wall-clock seconds
    messages DYNAMIC ARRAY OF STRING
END RECORD
PUBLIC TYPE OutcomeList DYNAMIC ARRAY OF TestOutcome

PRIVATE DEFINE g_driver driver.Driver
PRIVATE DEFINE g_hasDriver BOOLEAN
PRIVATE DEFINE g_results CheckResultList

# Driver-error state. A driver error (a bad field/table/action name, a lost
# session) is NOT an assertion failure: it means the interaction itself could not
# be performed, so everything after it in the same test is meaningless. The flag
# is sticky for the rest of the current test — verbs and matchers short-circuit
# while it is set — and the runner clears it between tests. `fatal` marks the
# unrecoverable case (the application under test is gone), which ends the run.
PRIVATE DEFINE g_errMsg STRING
PRIVATE DEFINE g_hasErr BOOLEAN
PRIVATE DEFINE g_fatal BOOLEAN

# ------------------------------------------------------------- driver ----

#+ Set the active driver for the current run (any Driver implementation).
PUBLIC FUNCTION setDriver(d driver.Driver)
    LET g_driver = d
    LET g_hasDriver = TRUE
END FUNCTION

#+ The active driver. Assign to a local Driver variable before calling methods.
PUBLIC FUNCTION getDriver() RETURNS driver.Driver
    RETURN g_driver
END FUNCTION

#+ TRUE once a driver has been set.
PUBLIC FUNCTION hasDriver() RETURNS BOOLEAN
    RETURN g_hasDriver
END FUNCTION

# ------------------------------------------------------------- booleans ----

#+ Force a possibly-NULL BOOLEAN to a concrete TRUE/FALSE.
#+
#+ BDL evaluates `NOT NULL` to NULL, and `TRUE AND NULL` to NULL — both of which
#+ read as false in an IF. So negating a BOOLEAN that was never assigned (a
#+ record field straight out of a DYNAMIC ARRAY, or one absent from parsed JSON)
#+ silently takes the wrong branch. Wrap such reads in isTrue().
PUBLIC FUNCTION isTrue(v BOOLEAN) RETURNS BOOLEAN
    IF v THEN
        RETURN TRUE
    END IF
    RETURN FALSE
END FUNCTION

# --------------------------------------------------------------- clock ----

#+ Wall-clock seconds since the epoch, with sub-millisecond resolution.
#+ Used for test durations and run deadlines. getCurrentAsUTC() reads the clock
#+ directly (no timezone round trip), so it is safe across DST boundaries.
PUBLIC FUNCTION nowSeconds() RETURNS FLOAT
    RETURN util.Datetime.toSecondsSinceEpoch(util.Datetime.getCurrentAsUTC())
END FUNCTION

# --------------------------------------------------------------- shell ----

#+ `s` as one double-quoted argument for a command run with RUN, quoted by the
#+ rules of sh on POSIX systems and of the C runtime's argument parser on
#+ Windows, so a value holding quotes, backslashes or spaces arrives intact. On
#+ POSIX, `$VAR` still expands, as in any double-quoted shell argument.
PUBLIC FUNCTION shellArg(s STRING) RETURNS STRING
    RETURN quoteArg(s, os.Path.separator() == "\\")
END FUNCTION

#+ shellArg() for a given platform (windows = TRUE for the Windows rules).
PUBLIC FUNCTION quoteArg(s STRING, windows BOOLEAN) RETURNS STRING
    DEFINE b base.StringBuffer
    DEFINE i, k, slashes INTEGER
    DEFINE c STRING

    LET b = base.StringBuffer.create()
    CALL b.append('"')
    IF isTrue(windows) THEN
        # Backslashes are literal unless they precede a quote: then each one
        # is doubled and the quote escaped. Trailing ones are doubled so they
        # cannot escape the closing quote.
        LET slashes = 0
        FOR i = 1 TO s.getLength()
            LET c = s.getCharAt(i)
            IF c == "\\" THEN
                LET slashes = slashes + 1
                CONTINUE FOR
            END IF
            IF c == '"' THEN
                FOR k = 1 TO slashes * 2 + 1
                    CALL b.append("\\")
                END FOR
            ELSE
                FOR k = 1 TO slashes
                    CALL b.append("\\")
                END FOR
            END IF
            LET slashes = 0
            CALL b.append(c)
        END FOR
        FOR k = 1 TO slashes * 2
            CALL b.append("\\")
        END FOR
    ELSE
        # Inside double quotes sh gives \ and " meaning: escape both.
        FOR i = 1 TO s.getLength()
            LET c = s.getCharAt(i)
            IF c == "\\" OR c == '"' THEN
                CALL b.append("\\")
            END IF
            CALL b.append(c)
        END FOR
    END IF
    CALL b.append('"')
    RETURN b.toString()
END FUNCTION

# ------------------------------------------------------- driver errors ----

#+ Record a driver error for the current test. The FIRST error is kept (it is
#+ the root cause; later ones are consequences), and the test is abandoned.
PUBLIC FUNCTION setDriverError(msg STRING)
    IF NOT g_hasErr THEN
        LET g_hasErr = TRUE
        LET g_errMsg = msg
    END IF
END FUNCTION

#+ TRUE while the current test has an outstanding driver error.
PUBLIC FUNCTION hasDriverError() RETURNS BOOLEAN
    RETURN g_hasErr
END FUNCTION

#+ The message of the current test's driver error (NULL if none).
PUBLIC FUNCTION driverError() RETURNS STRING
    RETURN g_errMsg
END FUNCTION

#+ Clear the driver-error flag (the runner calls this between tests).
PUBLIC FUNCTION clearDriverError()
    LET g_hasErr = FALSE
    LET g_errMsg = NULL
END FUNCTION

#+ Mark the run unrecoverable (the application under test is gone).
PUBLIC FUNCTION setFatal()
    LET g_fatal = TRUE
END FUNCTION

#+ TRUE once the session is unrecoverable; the runner stops scheduling tests.
PUBLIC FUNCTION isFatal() RETURNS BOOLEAN
    RETURN g_fatal
END FUNCTION

#+ Forget an unrecoverable session (a fresh run starts with a live one).
PUBLIC FUNCTION clearFatal()
    LET g_fatal = FALSE
END FUNCTION

# ------------------------------------------------------ assertion results ----

#+ Record a passing assertion.
PUBLIC FUNCTION recordPass(message STRING)
    DEFINE n INTEGER
    LET n = g_results.getLength() + 1
    LET g_results[n].passed = TRUE
    LET g_results[n].message = message
END FUNCTION

#+ Record a failing assertion (message = what, detail = expected vs actual).
PUBLIC FUNCTION recordFail(message STRING, detail STRING)
    DEFINE n INTEGER
    LET n = g_results.getLength() + 1
    LET g_results[n].passed = FALSE
    LET g_results[n].message = message
    LET g_results[n].detail = detail
END FUNCTION

#+ All assertion results recorded since the last reset.
PUBLIC FUNCTION getResults() RETURNS CheckResultList
    RETURN g_results
END FUNCTION

#+ Clear the results buffer (call before each test).
PUBLIC FUNCTION resetResults()
    CALL g_results.clear()
END FUNCTION

#+ Number of failed assertions recorded.
PUBLIC FUNCTION failCount() RETURNS INTEGER
    DEFINE i, c INTEGER
    FOR i = 1 TO g_results.getLength()
        IF NOT g_results[i].passed THEN
            LET c = c + 1
        END IF
    END FOR
    RETURN c
END FUNCTION
