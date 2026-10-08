# fgltest.core — shared run state: the active Driver used by the fluent API,
# expectations and introspection, plus the per-test assertion results buffer.

PACKAGE com.fourjs.fgltest

IMPORT util
IMPORT os
IMPORT FGL com.fourjs.fgltest.driver

#+ Package version. Keep in step with fglpkg.json and CHANGELOG.md.
PUBLIC CONSTANT VERSION = "1.1.1"


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
#+ Windows, so the value arrives exactly as given — quotes, backslashes, `$`
#+ and backticks included. (fgltest expands `$NAME` in config values itself,
#+ before quoting; see cli.expandEnv.) One exception on Windows: cmd.exe
#+ expands `%NAME%` even inside double quotes, and has no reliable escape for
#+ it there, so a value holding `%NAME%` is expanded by the shell.
PUBLIC FUNCTION shellArg(s STRING) RETURNS STRING
    RETURN quoteArg(s, os.Path.separator() == "\\")
END FUNCTION

#+ shellArg() for a given platform (windows = TRUE for the Windows rules).
#+
#+ Built only from getIndexOf(), subString() and StringBuffer.replace(), which
#+ agree on positions under either FGL_LENGTH_SEMANTICS. Walking getCharAt() up
#+ to getLength() would split multibyte characters under BYTE semantics (the
#+ default), corrupting any non-ASCII path.
PUBLIC FUNCTION quoteArg(s STRING, windows BOOLEAN) RETURNS STRING
    DEFINE e, r base.StringBuffer

    LET e = base.StringBuffer.create()
    IF isTrue(windows) THEN
        CALL e.append(windowsEscape(s))
    ELSE
        # Inside double quotes sh gives \ " $ and ` meaning: escape them all.
        CALL e.append(s)
        CALL e.replace("\\", "\\\\", 0)
        CALL e.replace('"', '\\"', 0)
        CALL e.replace("$", "\\$", 0)
        CALL e.replace("`", "\\`", 0)
    END IF
    LET r = base.StringBuffer.create()
    CALL r.append('"')
    CALL r.append(e.toString())
    CALL r.append('"')
    RETURN r.toString()
END FUNCTION

# The C runtime's rule: backslashes are literal unless they precede a quote;
# then each is doubled and the quote escaped. Trailing backslashes are doubled
# too, so they cannot escape the closing quote. Only ASCII positions are
# inspected, so multibyte text is copied through untouched.
PRIVATE FUNCTION windowsEscape(s STRING) RETURNS STRING
    DEFINE r base.StringBuffer
    DEFINE start, q, n, k, len INTEGER

    LET r = base.StringBuffer.create()
    LET len = s.getLength()
    LET start = 1
    WHILE start <= len
        LET q = s.getIndexOf('"', start)
        IF q == 0 THEN
            EXIT WHILE
        END IF
        LET n = backslashesBefore(s, q, start)
        IF q > start THEN
            CALL r.append(s.subString(start, q - 1))   -- includes those n
        END IF
        FOR k = 1 TO n + 1
            CALL r.append("\\")
        END FOR
        CALL r.append('"')
        LET start = q + 1
    END WHILE
    IF start <= len THEN
        CALL r.append(s.subString(start, len))
        LET n = backslashesBefore(s, len + 1, start)
        FOR k = 1 TO n
            CALL r.append("\\")
        END FOR
    END IF
    RETURN r.toString()
END FUNCTION

# How many backslashes run up to (not including) position pos, from no
# earlier than position floor.
PRIVATE FUNCTION backslashesBefore(s STRING, pos INTEGER, floor INTEGER) RETURNS INTEGER
    DEFINE n, i INTEGER
    LET n = 0
    LET i = pos - 1
    WHILE i >= floor
        IF s.getCharAt(i) != "\\" THEN
            EXIT WHILE
        END IF
        LET n = n + 1
        LET i = i - 1
    END WHILE
    RETURN n
END FUNCTION

# ----------------------------------------------------------- JSON shape ----

#+ Check a parsed JSON object against a shape, appending a "  - " line to `b`
#+ for every problem: a key the shape does not list (a typo the JSON parser
#+ would otherwise drop silently), or a value util.JSON.parse cannot convert
#+ to the member's type without losing it — it would become NULL ("30s" for a
#+ number, "yes" for a boolean) or be truncated (6.5 for a whole number).
#+ What the parser does convert cleanly is accepted, as it always was: "60"
#+ for a whole number, 1 / 0 or "1" / "0" for a boolean, 5 for a string.
#+
#+ `spec` is a comma-separated list of key:type, type being string, number,
#+ int (a whole number), boolean, object, array or any. Keys match without
#+ regard to case, as util.JSON.parse matches them to record members; a key
#+ written "=key" must match exactly, for a member renamed with json_name,
#+ which the parser matches exactly. Keys starting with "$" or "_" (a
#+ "$schema", a "_comment") are always allowed; a JSON null is always accepted.
PUBLIC FUNCTION checkShape(b base.StringBuffer, o util.JSONObject, where STRING, spec STRING)
    DEFINE i INTEGER
    DEFINE k, expected, actual STRING

    FOR i = 1 TO o.getLength()
        LET k = o.name(i)
        IF k.getIndexOf("$", 1) == 1 OR k.getIndexOf("_", 1) == 1 THEN
            CONTINUE FOR
        END IF
        LET expected = specType(spec, k)
        IF expected IS NULL THEN
            CALL problem(b, SFMT('%1: unknown key "%2" (known keys: %3)', where, k, specKeys(spec)))
            CONTINUE FOR
        END IF
        LET actual = o.getType(k)
        IF actual == "NULL" OR expected == "any" THEN
            CONTINUE FOR
        END IF
        IF NOT typeFits(o, k, expected, actual) THEN
            CALL problem(b, SFMT('%1: "%2" must be %3, not %4', where, k,
                describeType(expected), describeValue(o, k, actual)))
        END IF
    END FOR
END FUNCTION

#+ The key of `o` that matches `name` without regard to case (NULL if none),
#+ for reading a member the way util.JSON.parse would.
PUBLIC FUNCTION jsonKey(o util.JSONObject, name STRING) RETURNS STRING
    DEFINE i INTEGER
    DEFINE k STRING
    FOR i = 1 TO o.getLength()
        LET k = o.name(i)
        IF k.toLowerCase() == name.toLowerCase() THEN
            RETURN k
        END IF
    END FOR
    RETURN NULL
END FUNCTION

#+ Append one "  - msg" problem line, the format every validator reports in.
PUBLIC FUNCTION problem(b base.StringBuffer, msg STRING)
    CALL b.append("  - ")
    CALL b.append(msg)
    CALL b.append(ASCII 10)
END FUNCTION

# The type `spec` gives key k (NULL if the key is not in it).
PRIVATE FUNCTION specType(spec STRING, k STRING) RETURNS STRING
    DEFINE tok base.StringTokenizer
    DEFINE entry, key STRING
    DEFINE colon INTEGER
    DEFINE exact BOOLEAN

    LET tok = base.StringTokenizer.create(spec, ",")
    WHILE tok.hasMoreTokens()
        LET entry = tok.nextToken()
        LET colon = entry.getIndexOf(":", 1)
        LET key = entry.subString(1, colon - 1)
        LET exact = (key.getIndexOf("=", 1) == 1)
        IF exact THEN
            LET key = key.subString(2, key.getLength())
            IF key == k THEN
                RETURN entry.subString(colon + 1, entry.getLength())
            END IF
        ELSE
            IF key.toLowerCase() == k.toLowerCase() THEN
                RETURN entry.subString(colon + 1, entry.getLength())
            END IF
        END IF
    END WHILE
    RETURN NULL
END FUNCTION

# The keys of `spec`, for a message.
PRIVATE FUNCTION specKeys(spec STRING) RETURNS STRING
    DEFINE tok base.StringTokenizer
    DEFINE entry, key STRING
    DEFINE r base.StringBuffer

    LET r = base.StringBuffer.create()
    LET tok = base.StringTokenizer.create(spec, ",")
    WHILE tok.hasMoreTokens()
        LET entry = tok.nextToken()
        LET key = entry.subString(1, entry.getIndexOf(":", 1) - 1)
        IF key.getIndexOf("=", 1) == 1 THEN
            LET key = key.subString(2, key.getLength())
        END IF
        IF r.getLength() > 0 THEN
            CALL r.append(", ")
        END IF
        CALL r.append(key)
    END WHILE
    RETURN r.toString()
END FUNCTION

PRIVATE FUNCTION typeFits(o util.JSONObject, k STRING, expected STRING, actual STRING) RETURNS BOOLEAN
    DEFINE f FLOAT
    DEFINE v STRING
    CASE expected
        WHEN "string"
            -- a number's JSON text becomes the string, as the parser does
            RETURN (actual == "STRING" OR actual == "NUMBER")
        WHEN "number"
            IF actual == "NUMBER" THEN
                RETURN TRUE
            END IF
            IF actual == "STRING" THEN
                LET v = o.get(k)
                RETURN v.matches("^ *[-+]?[0-9]+([.][0-9]+)? *$")
            END IF
            RETURN FALSE
        WHEN "int"
            IF actual == "NUMBER" THEN
                LET f = o.get(k)
                RETURN isWhole(f)   -- 5.0 and 1e3 are whole; 6.5 would be cut
            END IF
            IF actual == "STRING" THEN
                LET v = o.get(k)
                RETURN v.matches("^ *[-+]?[0-9]+ *$")
            END IF
            RETURN FALSE
        WHEN "boolean"
            IF actual == "BOOLEAN" THEN
                RETURN TRUE
            END IF
            IF actual == "NUMBER" THEN
                LET f = o.get(k)
                RETURN (f == 0 OR f == 1)
            END IF
            IF actual == "STRING" THEN
                LET v = o.get(k)
                RETURN v.matches("^ *[01] *$")
            END IF
            RETURN FALSE
        WHEN "object" RETURN (actual == "OBJECT")
        WHEN "array" RETURN (actual == "ARRAY")
    END CASE
    RETURN FALSE
END FUNCTION

#+ TRUE if f is a whole number that fits a BIGINT.
PUBLIC FUNCTION isWhole(f FLOAT) RETURNS BOOLEAN
    DEFINE n BIGINT
    IF f IS NULL THEN
        RETURN FALSE
    END IF
    LET n = f
    IF n IS NULL OR n != f THEN
        RETURN FALSE
    END IF
    RETURN TRUE
END FUNCTION

PRIVATE FUNCTION describeType(t STRING) RETURNS STRING
    CASE t
        WHEN "string" RETURN "a string"
        WHEN "number" RETURN "a number"
        WHEN "int" RETURN "a whole number"
        WHEN "boolean" RETURN "true or false (or 1 / 0)"
        WHEN "object" RETURN "an object"
        WHEN "array" RETURN "a list"
    END CASE
    RETURN t
END FUNCTION

# A value as a message shows it: a scalar with its text, a container by kind.
PRIVATE FUNCTION describeValue(o util.JSONObject, k STRING, actual STRING) RETURNS STRING
    DEFINE v STRING
    DEFINE f FLOAT
    CASE actual
        WHEN "STRING"
            LET v = o.get(k)
            RETURN SFMT('the string "%1"', v)
        WHEN "NUMBER"
            LET f = o.get(k)
            RETURN SFMT("%1", f)
        WHEN "BOOLEAN" RETURN "a boolean"
        WHEN "OBJECT" RETURN "an object"
        WHEN "ARRAY" RETURN "a list"
    END CASE
    RETURN actual
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
