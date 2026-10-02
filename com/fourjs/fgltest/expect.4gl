# fgltest.expect — assertion matchers.
#
#   CALL expect.that(driverValue).toEqual("ACME")          -- strings
#   CALL expect.num(inspect.rowCount("prices")).toEqual(5)  -- numbers
#   CALL expect.bool(flag).toBeTrue()                       -- booleans
#   CALL expect.all(inspect.enabledFields()).toContain("formonly.price")
#
# `that()`/`all()` return an expectation object; the matcher methods are VOID so
# the whole thing is a valid statement under CALL (BDL cannot discard a returned
# value, so matchers do not chain to each other — one assertion per statement).
# Each matcher records a pass/fail into fgltest.core. String comparisons are
# empty-safe (BDL treats "" as NULL).

PACKAGE com.fourjs.fgltest

IMPORT FGL com.fourjs.fgltest.core
IMPORT FGL com.fourjs.fgltest.inspect

PUBLIC TYPE Expect RECORD
    actual STRING
END RECORD

PUBLIC TYPE ListExpect RECORD
    actual inspect.StringList
END RECORD

#+ Numeric expectation. DECIMAL is the widest numeric carrier, so INTEGER,
#+ SMALLINT, FLOAT and MONEY actuals all convert without loss of precision.
PUBLIC TYPE NumExpect RECORD
    actual DECIMAL
END RECORD

PUBLIC TYPE BoolExpect RECORD
    actual BOOLEAN
END RECORD

#+ Begin a scalar (string) expectation.
PUBLIC FUNCTION that(actual STRING) RETURNS Expect
    DEFINE e Expect
    LET e.actual = actual
    RETURN e
END FUNCTION

#+ Begin a collection expectation over a list of strings.
PUBLIC FUNCTION all(actual inspect.StringList) RETURNS ListExpect
    DEFINE e ListExpect
    LET e.actual = actual
    RETURN e
END FUNCTION

#+ Begin a numeric expectation. Compares numerically, so no stringifying of
#+ counts (and "5" vs "5.0" cannot cause a spurious failure).
PUBLIC FUNCTION num(actual DECIMAL) RETURNS NumExpect
    DEFINE e NumExpect
    LET e.actual = actual
    RETURN e
END FUNCTION

#+ Begin a boolean expectation.
PUBLIC FUNCTION bool(actual BOOLEAN) RETURNS BoolExpect
    DEFINE e BoolExpect
    LET e.actual = actual
    RETURN e
END FUNCTION

# Once a driver error is outstanding the session state is unknown, so every
# further matcher in the same test records nothing: a "failure" derived from a
# value we could not read is noise, and a "pass" would be a lie. The runner
# reports the test as errored instead.
PRIVATE FUNCTION dead() RETURNS BOOLEAN
    RETURN core.hasDriverError()
END FUNCTION

# ------------------------------------------------------- scalar matchers ----

FUNCTION (self Expect) toEqual(expected STRING)
    IF dead() THEN RETURN END IF
    IF strEq(self.actual, expected) THEN
        CALL core.recordPass(SFMT("value equals [%1]", expected))
    ELSE
        CALL core.recordFail("toEqual", SFMT("expected [%1] to equal [%2]", self.actual, expected))
    END IF
END FUNCTION

FUNCTION (self Expect) notToEqual(expected STRING)
    IF dead() THEN RETURN END IF
    IF NOT strEq(self.actual, expected) THEN
        CALL core.recordPass(SFMT("value differs from [%1]", expected))
    ELSE
        CALL core.recordFail("notToEqual", SFMT("expected [%1] to differ from [%2]", self.actual, expected))
    END IF
END FUNCTION

FUNCTION (self Expect) toBeEmpty()
    IF dead() THEN RETURN END IF
    IF LENGTH(self.actual) == 0 THEN
        CALL core.recordPass("value is empty")
    ELSE
        CALL core.recordFail("toBeEmpty", SFMT("expected [%1] to be empty", self.actual))
    END IF
END FUNCTION

FUNCTION (self Expect) notToBeEmpty()
    IF dead() THEN RETURN END IF
    IF LENGTH(self.actual) > 0 THEN
        CALL core.recordPass("value is not empty")
    ELSE
        CALL core.recordFail("notToBeEmpty", "expected a non-empty value")
    END IF
END FUNCTION

FUNCTION (self Expect) toContainText(sub STRING)
    IF dead() THEN RETURN END IF
    IF hasSub(self.actual, sub) THEN
        CALL core.recordPass(SFMT("value contains [%1]", sub))
    ELSE
        CALL core.recordFail("toContainText",
            SFMT("expected [%1] to contain [%2]", self.actual, sub))
    END IF
END FUNCTION

FUNCTION (self Expect) notToContainText(sub STRING)
    IF dead() THEN RETURN END IF
    IF NOT hasSub(self.actual, sub) THEN
        CALL core.recordPass(SFMT("value excludes [%1]", sub))
    ELSE
        CALL core.recordFail("notToContainText",
            SFMT("expected [%1] not to contain [%2]", self.actual, sub))
    END IF
END FUNCTION

FUNCTION (self Expect) toStartWith(prefix STRING)
    IF dead() THEN RETURN END IF
    IF strEq(safeSub(self.actual, 1, LENGTH(prefix)), prefix) THEN
        CALL core.recordPass(SFMT("value starts with [%1]", prefix))
    ELSE
        CALL core.recordFail("toStartWith",
            SFMT("expected [%1] to start with [%2]", self.actual, prefix))
    END IF
END FUNCTION

FUNCTION (self Expect) toEndWith(suffix STRING)
    IF dead() THEN RETURN END IF
    IF strEq(safeSub(self.actual, LENGTH(self.actual) - LENGTH(suffix) + 1,
                     LENGTH(self.actual)), suffix) THEN
        CALL core.recordPass(SFMT("value ends with [%1]", suffix))
    ELSE
        CALL core.recordFail("toEndWith",
            SFMT("expected [%1] to end with [%2]", self.actual, suffix))
    END IF
END FUNCTION

#+ Match against a regular expression. NB: STRING.matches() is *unanchored* —
#+ "world" matches "hello world". Anchor with ^...$ for a whole-value match.
FUNCTION (self Expect) toMatch(pattern STRING)
    IF dead() THEN RETURN END IF
    IF matchesRe(self.actual, pattern) THEN
        CALL core.recordPass(SFMT("value matches /%1/", pattern))
    ELSE
        CALL core.recordFail("toMatch",
            SFMT("expected [%1] to match /%2/", self.actual, pattern))
    END IF
END FUNCTION

FUNCTION (self Expect) notToMatch(pattern STRING)
    IF dead() THEN RETURN END IF
    IF NOT matchesRe(self.actual, pattern) THEN
        CALL core.recordPass(SFMT("value does not match /%1/", pattern))
    ELSE
        CALL core.recordFail("notToMatch",
            SFMT("expected [%1] not to match /%2/", self.actual, pattern))
    END IF
END FUNCTION

# ------------------------------------------------------ numeric matchers ----

FUNCTION (self NumExpect) toEqual(expected DECIMAL)
    IF dead() THEN RETURN END IF
    IF self.actual == expected THEN
        CALL core.recordPass(SFMT("number equals %1", expected))
    ELSE
        CALL core.recordFail("toEqual",
            SFMT("expected %1 to equal %2", self.actual, expected))
    END IF
END FUNCTION

FUNCTION (self NumExpect) notToEqual(expected DECIMAL)
    IF dead() THEN RETURN END IF
    IF self.actual != expected THEN
        CALL core.recordPass(SFMT("number differs from %1", expected))
    ELSE
        CALL core.recordFail("notToEqual",
            SFMT("expected %1 to differ from %2", self.actual, expected))
    END IF
END FUNCTION

FUNCTION (self NumExpect) toBeGreaterThan(bound DECIMAL)
    IF dead() THEN RETURN END IF
    IF self.actual > bound THEN
        CALL core.recordPass(SFMT("number is greater than %1", bound))
    ELSE
        CALL core.recordFail("toBeGreaterThan",
            SFMT("expected %1 to be greater than %2", self.actual, bound))
    END IF
END FUNCTION

FUNCTION (self NumExpect) toBeLessThan(bound DECIMAL)
    IF dead() THEN RETURN END IF
    IF self.actual < bound THEN
        CALL core.recordPass(SFMT("number is less than %1", bound))
    ELSE
        CALL core.recordFail("toBeLessThan",
            SFMT("expected %1 to be less than %2", self.actual, bound))
    END IF
END FUNCTION

FUNCTION (self NumExpect) toBeAtLeast(bound DECIMAL)
    IF dead() THEN RETURN END IF
    IF self.actual >= bound THEN
        CALL core.recordPass(SFMT("number is at least %1", bound))
    ELSE
        CALL core.recordFail("toBeAtLeast",
            SFMT("expected %1 to be at least %2", self.actual, bound))
    END IF
END FUNCTION

FUNCTION (self NumExpect) toBeAtMost(bound DECIMAL)
    IF dead() THEN RETURN END IF
    IF self.actual <= bound THEN
        CALL core.recordPass(SFMT("number is at most %1", bound))
    ELSE
        CALL core.recordFail("toBeAtMost",
            SFMT("expected %1 to be at most %2", self.actual, bound))
    END IF
END FUNCTION

#+ Inclusive range check.
FUNCTION (self NumExpect) toBeBetween(lo DECIMAL, hi DECIMAL)
    IF dead() THEN RETURN END IF
    IF self.actual >= lo AND self.actual <= hi THEN
        CALL core.recordPass(SFMT("number is within [%1, %2]", lo, hi))
    ELSE
        CALL core.recordFail("toBeBetween",
            SFMT("expected %1 to be within [%2, %3]", self.actual, lo, hi))
    END IF
END FUNCTION

# ------------------------------------------------------ boolean matchers ----

FUNCTION (self BoolExpect) toBeTrue()
    IF dead() THEN RETURN END IF
    IF self.actual THEN
        CALL core.recordPass("value is true")
    ELSE
        CALL core.recordFail("toBeTrue", "expected true, got false")
    END IF
END FUNCTION

FUNCTION (self BoolExpect) toBeFalse()
    IF dead() THEN RETURN END IF
    IF NOT self.actual THEN
        CALL core.recordPass("value is false")
    ELSE
        CALL core.recordFail("toBeFalse", "expected false, got true")
    END IF
END FUNCTION

# --------------------------------------------------- collection matchers ----

FUNCTION (self ListExpect) toContain(item STRING)
    IF dead() THEN RETURN END IF
    IF listHas(self.actual, item) THEN
        CALL core.recordPass(SFMT("list contains [%1]", item))
    ELSE
        CALL core.recordFail("toContain", SFMT("expected list (%1 items) to contain [%2]", self.actual.getLength(), item))
    END IF
END FUNCTION

FUNCTION (self ListExpect) notToContain(item STRING)
    IF dead() THEN RETURN END IF
    IF NOT listHas(self.actual, item) THEN
        CALL core.recordPass(SFMT("list excludes [%1]", item))
    ELSE
        CALL core.recordFail("notToContain", SFMT("expected list not to contain [%1]", item))
    END IF
END FUNCTION

FUNCTION (self ListExpect) toHaveSize(n INTEGER)
    IF dead() THEN RETURN END IF
    IF self.actual.getLength() == n THEN
        CALL core.recordPass(SFMT("list has %1 items", n))
    ELSE
        CALL core.recordFail("toHaveSize", SFMT("expected %1 items, got %2", n, self.actual.getLength()))
    END IF
END FUNCTION

FUNCTION (self ListExpect) toBeEmpty()
    IF dead() THEN RETURN END IF
    IF self.actual.getLength() == 0 THEN
        CALL core.recordPass("list is empty")
    ELSE
        CALL core.recordFail("toBeEmpty", SFMT("expected empty list, got %1 items", self.actual.getLength()))
    END IF
END FUNCTION

FUNCTION (self ListExpect) toContainMatch(pattern STRING)
    IF dead() THEN RETURN END IF
    IF listHasMatch(self.actual, pattern) THEN
        CALL core.recordPass(SFMT("list has an item matching /%1/", pattern))
    ELSE
        CALL core.recordFail("toContainMatch",
            SFMT("expected list (%1 items) to have an item matching /%2/",
                self.actual.getLength(), pattern))
    END IF
END FUNCTION

FUNCTION (self ListExpect) notToBeEmpty()
    IF dead() THEN RETURN END IF
    IF self.actual.getLength() > 0 THEN
        CALL core.recordPass("list is not empty")
    ELSE
        CALL core.recordFail("notToBeEmpty", "expected a non-empty list")
    END IF
END FUNCTION

# ------------------------------------------------------------- helpers ----

#+ Empty-safe string equality (treats NULL and "" as equal).
PRIVATE FUNCTION strEq(a STRING, b STRING) RETURNS BOOLEAN
    DEFINE ea, eb BOOLEAN
    LET ea = (LENGTH(a) == 0)
    LET eb = (LENGTH(b) == 0)
    IF ea AND eb THEN RETURN TRUE END IF
    IF ea OR eb THEN RETURN FALSE END IF
    IF a == b THEN RETURN TRUE END IF
    RETURN FALSE
END FUNCTION

#+ Empty-safe substring test.
PRIVATE FUNCTION hasSub(hay STRING, needle STRING) RETURNS BOOLEAN
    IF LENGTH(needle) == 0 THEN
        RETURN TRUE
    END IF
    IF LENGTH(hay) == 0 THEN
        RETURN FALSE
    END IF
    IF hay.getIndexOf(needle, 1) > 0 THEN
        RETURN TRUE
    END IF
    RETURN FALSE
END FUNCTION

#+ subString() with out-of-range bounds clamped to "" instead of raising.
PRIVATE FUNCTION safeSub(s STRING, a INTEGER, b INTEGER) RETURNS STRING
    IF s IS NULL OR a < 1 OR b > LENGTH(s) OR b < a THEN
        RETURN ""
    END IF
    RETURN s.subString(a, b)
END FUNCTION

#+ Empty-safe regex test (a NULL actual never matches).
PRIVATE FUNCTION matchesRe(s STRING, pattern STRING) RETURNS BOOLEAN
    IF s IS NULL THEN
        RETURN FALSE
    END IF
    IF s.matches(pattern) THEN
        RETURN TRUE
    END IF
    RETURN FALSE
END FUNCTION

PRIVATE FUNCTION listHasMatch(list inspect.StringList, pattern STRING) RETURNS BOOLEAN
    DEFINE i INTEGER
    FOR i = 1 TO list.getLength()
        IF matchesRe(list[i], pattern) THEN
            RETURN TRUE
        END IF
    END FOR
    RETURN FALSE
END FUNCTION

PRIVATE FUNCTION listHas(list inspect.StringList, item STRING) RETURNS BOOLEAN
    DEFINE i INTEGER
    FOR i = 1 TO list.getLength()
        IF strEq(list[i], item) THEN
            RETURN TRUE
        END IF
    END FOR
    RETURN FALSE
END FUNCTION
