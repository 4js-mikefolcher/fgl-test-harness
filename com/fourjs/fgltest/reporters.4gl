# fgltest.reporters — render test outcomes to industry-standard formats.
#
# Batch model: the runner captures every outcome, then asks for the formats it
# needs. Console lives in the runner; JUnit XML / TAP / JSON live here.
# XML fragments use single-quoted BDL literals so embedded double quotes need no
# escaping; newlines use ASCII 10 to avoid backslash-escape ambiguity.

PACKAGE com.fourjs.fgltest

IMPORT util
IMPORT FGL com.fourjs.fgltest.core

# --------------------------------------------------------------- JUnit ----

#+ JUnit XML (consumable by Jenkins/GitLab/GitHub Actions/etc.).
PUBLIC FUNCTION toJUnit(outcomes core.OutcomeList, suiteName STRING) RETURNS STRING
    DEFINE b base.StringBuffer
    DEFINE i, k, total, failed, errors, skipped INTEGER
    DEFINE elapsed FLOAT
    DEFINE nl, tag STRING

    LET nl = ASCII 10
    LET total = outcomes.getLength()
    # JUnit separates the two: <failure> is an assertion that did not hold,
    # <error> is a test that could not run. CI dashboards colour them apart.
    FOR i = 1 TO total
        LET elapsed = elapsed + secsOf(outcomes[i].duration)
        IF core.isTrue(outcomes[i].skipped) THEN
            LET skipped = skipped + 1
        ELSE
            IF core.isTrue(outcomes[i].errored) THEN
                LET errors = errors + 1
            ELSE
                IF NOT core.isTrue(outcomes[i].passed) THEN
                    LET failed = failed + 1
                END IF
            END IF
        END IF
    END FOR

    LET b = base.StringBuffer.create()
    CALL b.append('<?xml version="1.0" encoding="UTF-8"?>')
    CALL b.append(nl)
    CALL b.append(SFMT('<testsuites tests="%1" failures="%2" errors="%3" time="%4">',
        total, failed, errors, secs(elapsed)))
    CALL b.append(nl)
    CALL b.append('  <testsuite name="')
    CALL b.append(xmlEsc(suiteName))
    CALL b.append(SFMT('" tests="%1" failures="%2" errors="%3" skipped="%4" time="%5" timestamp="%6">',
        total, failed, errors, skipped, secs(elapsed), isoNow()))
    CALL b.append(nl)

    FOR i = 1 TO total
        CALL b.append('    <testcase name="')
        CALL b.append(xmlEsc(outcomes[i].name))
        CALL b.append('" classname="')
        CALL b.append(xmlEsc(suiteName))
        CALL b.append(SFMT('" time="%1', secs(secsOf(outcomes[i].duration))))
        IF core.isTrue(outcomes[i].skipped) THEN
            CALL b.append('">')
            CALL b.append(nl)
            CALL b.append('      <skipped/>')
            CALL b.append(nl)
            CALL b.append('    </testcase>')
            CALL b.append(nl)
        ELSE
        IF core.isTrue(outcomes[i].passed) THEN
            CALL b.append('"/>')
            CALL b.append(nl)
        ELSE
            IF core.isTrue(outcomes[i].errored) THEN
                LET tag = "error"
            ELSE
                LET tag = "failure"
            END IF
            CALL b.append('">')
            CALL b.append(nl)
            FOR k = 1 TO outcomes[i].messages.getLength()
                CALL b.append(SFMT('      <%1 message="', tag))
                CALL b.append(xmlEsc(outcomes[i].messages[k]))
                CALL b.append('">')
                CALL b.append(xmlEsc(outcomes[i].messages[k]))
                CALL b.append(SFMT('</%1>', tag))
                CALL b.append(nl)
            END FOR
            CALL b.append('    </testcase>')
            CALL b.append(nl)
        END IF
        END IF
    END FOR

    CALL b.append('  </testsuite>')
    CALL b.append(nl)
    CALL b.append('</testsuites>')
    CALL b.append(nl)
    RETURN b.toString()
END FUNCTION

# ----------------------------------------------------------------- TAP ----

#+ Test Anything Protocol v13.
#+
#+ A test that did not pass carries a YAML diagnostic block: `severity` (fail or
#+ error), `message` (the first message, for consumers that read only that)
#+ and `messages` (all of them). Every value is a double-quoted YAML string, so
#+ a message holding `:`, `#` or quotes cannot break the block; a `#` or `\` in a
#+ test name is escaped, as TAP requires, so it is not read as a directive.
PUBLIC FUNCTION toTAP(outcomes core.OutcomeList) RETURNS STRING
    DEFINE b base.StringBuffer
    DEFINE i, k INTEGER
    DEFINE nl, name STRING

    LET nl = ASCII 10
    LET b = base.StringBuffer.create()
    CALL b.append("TAP version 13")
    CALL b.append(nl)
    CALL b.append(SFMT("1..%1", outcomes.getLength()))
    CALL b.append(nl)

    FOR i = 1 TO outcomes.getLength()
        LET name = tapDescription(outcomes[i].name)
        IF core.isTrue(outcomes[i].skipped) THEN
            CALL b.append(SFMT("ok %1 - %2 # SKIP", i, name))
        ELSE
            IF core.isTrue(outcomes[i].passed) THEN
                CALL b.append(SFMT("ok %1 - %2", i, name))
            ELSE
                IF core.isTrue(outcomes[i].errored) THEN
                    CALL b.append(SFMT("not ok %1 - %2 # ERROR", i, name))
                ELSE
                    CALL b.append(SFMT("not ok %1 - %2", i, name))
                END IF
            END IF
        END IF
        CALL b.append(nl)
        IF NOT core.isTrue(outcomes[i].passed) AND NOT core.isTrue(outcomes[i].skipped) THEN
            CALL b.append("  ---")
            CALL b.append(nl)
            IF core.isTrue(outcomes[i].errored) THEN
                CALL b.append("  severity: error")
            ELSE
                CALL b.append("  severity: fail")
            END IF
            CALL b.append(nl)
            IF outcomes[i].messages.getLength() > 0 THEN
                CALL b.append("  message: ")
                CALL b.append(yamlString(outcomes[i].messages[1]))
                CALL b.append(nl)
                CALL b.append("  messages:")
                CALL b.append(nl)
                FOR k = 1 TO outcomes[i].messages.getLength()
                    CALL b.append("    - ")
                    CALL b.append(yamlString(outcomes[i].messages[k]))
                    CALL b.append(nl)
                END FOR
            END IF
            CALL b.append("  ...")
            CALL b.append(nl)
        END IF
    END FOR
    RETURN b.toString()
END FUNCTION

# ---------------------------------------------------------------- JSON ----

PRIVATE TYPE JsonReport RECORD
    suite STRING,
    tests INTEGER,
    passed INTEGER,
    failed INTEGER,
    errors INTEGER,
    skipped INTEGER,
    duration FLOAT,
    cases core.OutcomeList
END RECORD

#+ Structured JSON report: the suite name, the counts — tests, passed, failed
#+ (a check did not hold), errors (could not run), skipped; disjoint, so they
#+ add up to tests — the total duration, and the per-test cases.
PUBLIC FUNCTION toJSON(outcomes core.OutcomeList, suiteName STRING) RETURNS STRING
    DEFINE rep JsonReport
    DEFINE i INTEGER

    LET rep.suite = suiteName
    LET rep.tests = outcomes.getLength()
    FOR i = 1 TO outcomes.getLength()
        LET rep.duration = rep.duration + secsOf(outcomes[i].duration)
        IF core.isTrue(outcomes[i].skipped) THEN
            LET rep.skipped = rep.skipped + 1
        ELSE
            # passed, failed and errors are disjoint, like JUnit's counts:
            # failed = a check did not hold, errors = could not run.
            IF core.isTrue(outcomes[i].passed) THEN
                LET rep.passed = rep.passed + 1
            ELSE
                IF core.isTrue(outcomes[i].errored) THEN
                    LET rep.errors = rep.errors + 1
                ELSE
                    LET rep.failed = rep.failed + 1
                END IF
            END IF
        END IF
    END FOR
    LET rep.cases = outcomes
    RETURN util.JSON.stringify(rep)
END FUNCTION

# -------------------------------------------------------------- helpers ----

#+ Write a string to a file (overwrites). Returns NULL on success, else a
#+ message. An unwritable output directory must not take the run down with it —
#+ the results are still on stdout, so report the problem and carry on.
PUBLIC FUNCTION writeFile(path STRING, content STRING) RETURNS STRING
    DEFINE ch base.Channel
    LET ch = base.Channel.create()
    TRY
        CALL ch.openFile(path, "w")
    CATCH
        RETURN SFMT("cannot write report '%1'", path)
    END TRY
    TRY
        CALL ch.writeLine(content)
        CALL ch.close()
    CATCH
        RETURN SFMT("failed writing report '%1'", path)
    END TRY
    RETURN NULL
END FUNCTION

#+ A duration as a concrete number. An outcome that never ran (skipped, or cut
#+ short by a timeout) has no duration, and in BDL `x + NULL` is NULL — one such
#+ value would otherwise zero the whole suite total.
PRIVATE FUNCTION secsOf(v FLOAT) RETURNS FLOAT
    IF v IS NULL OR v < 0 THEN
        RETURN 0
    END IF
    RETURN v
END FUNCTION

#+ Format seconds for a JUnit time= attribute (3 decimals, always a plain
#+ number — USING would pad, and a leading space breaks some XML parsers).
PRIVATE FUNCTION secs(v FLOAT) RETURNS STRING
    DEFINE s STRING
    IF v IS NULL OR v < 0 THEN
        RETURN "0.000"
    END IF
    LET s = v USING "&.###"
    RETURN s.trim()
END FUNCTION

#+ Current local time as an ISO-8601 timestamp for the JUnit timestamp=
#+ attribute (the format CI servers expect: no timezone suffix).
PRIVATE FUNCTION isoNow() RETURNS STRING
    DEFINE dt DATETIME YEAR TO SECOND
    DEFINE s STRING
    LET dt = CURRENT YEAR TO SECOND
    LET s = dt
    RETURN SFMT("%1T%2", s.subString(1, 10), s.subString(12, 19))
END FUNCTION

# A TAP test description: on one line, with "\" and "#" escaped so the name
# cannot be read as a directive.
PRIVATE FUNCTION tapDescription(s STRING) RETURNS STRING
    DEFINE b base.StringBuffer
    LET b = base.StringBuffer.create()
    CALL b.append(s)
    CALL b.replace("\\", "\\\\", 0)
    CALL b.replace("#", "\\#", 0)
    CALL b.replace(ASCII 13, " ", 0)
    CALL b.replace(ASCII 10, " ", 0)
    RETURN b.toString()
END FUNCTION

# A double-quoted YAML scalar: backslash, quote and line breaks escaped, other
# control characters dropped.
PRIVATE FUNCTION yamlString(s STRING) RETURNS STRING
    DEFINE b base.StringBuffer
    DEFINE i INTEGER
    DEFINE c STRING
    LET b = base.StringBuffer.create()
    CALL b.append('"')
    FOR i = 1 TO s.getLength()
        LET c = s.getCharAt(i)
        CASE
            WHEN c == "\\"
                CALL b.append("\\\\")
            WHEN c == '"'
                CALL b.append('\\"')
            WHEN c == ASCII 10
                CALL b.append("\\n")
            WHEN c == ASCII 9
                CALL b.append("\\t")
            WHEN c == ASCII 13
                CALL b.append("\\r")
            WHEN ORD(c) < 32
                -- other control characters have no place in a message
            OTHERWISE
                CALL b.append(c)
        END CASE
    END FOR
    CALL b.append('"')
    RETURN b.toString()
END FUNCTION

#+ Escape a string for XML text/attribute content.
PRIVATE FUNCTION xmlEsc(s STRING) RETURNS STRING
    DEFINE b base.StringBuffer
    LET b = base.StringBuffer.create()
    CALL b.append(s)
    CALL b.replace("&", "&amp;", 0)
    CALL b.replace("<", "&lt;", 0)
    CALL b.replace(">", "&gt;", 0)
    CALL b.replace('"', "&quot;", 0)
    RETURN b.toString()
END FUNCTION
