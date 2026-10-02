# fgltest — the test-runner CLI.
#
#   fglrun com/fourjs/fgltest/fgltest [config.json]   (default: fgltest.json)
#
# Reads a JSON config listing suites + their connection, owns the GGC scenario
# server lifecycle (start once / stop once, robust to suite crashes), runs each
# suite as a subprocess (passing FGLTEST_* env for reporters/output), reads each
# suite's JSON result to merge counts, writes an aggregate summary, and exits
# non-zero if any suite failed or errored.
#
# Two optional features on top of explicit suites:
#   discover : auto-find suites in a directory (JSON action files + compiled
#              *_test modules) using a shared connection template.
#   isolate  : run each *test* in its own subprocess (full crash/hang isolation)
#              — enumerate the suite's tests, then run each with FGLTEST_ONLY.

IMPORT util
IMPORT os
IMPORT FGL com.fourjs.fgltest.core
IMPORT FGL com.fourjs.fgltest.server

# Extra seconds the watchdog waits beyond a suite's own budget, so the child's
# soft limit (which still writes reports) gets to win the race.
CONSTANT GRACE_SECS = 10

TYPE StrList DYNAMIC ARRAY OF STRING

TYPE SuiteCfg RECORD
    name STRING,          # report basename + label
    module STRING,        # compiled suite program to fglrun (path/module)
    actions STRING,       # OR a declarative JSON action file (run via jsonRunner)
    mode STRING,          # "tcp" | "ua"
    workdir STRING,       # tcp: application working directory
    commandLine STRING,   # tcp: application launch command
    url STRING,           # ua: GAS application URL
    isolate BOOLEAN,      # run each test in its own process (else inherit global)
    timeout INTEGER       # per-suite wall-clock limit in seconds (0 = inherit)
END RECORD

# Auto-discovery: scan `dir` for *.actions.json (JSON suites) and compiled
# modules ending with `modulePattern` (default "_test"), applying one shared
# connection template (mode/workdir/commandLine/url) to every suite found.
TYPE DiscoverCfg RECORD
    dir STRING,
    mode STRING,
    workdir STRING,
    commandLine STRING,
    url STRING,
    modulePattern STRING
END RECORD

TYPE Config RECORD
    port INTEGER,
    reporters STRING,     # csv: console,junit,tap,json
    outdir STRING,
    jsonRunner STRING,    # generic runner for "actions" suites (default com/fourjs/fgltest/fgltest_json)
    isolate BOOLEAN,      # run every suite's tests in isolated processes
    timeout INTEGER,      # default wall-clock limit per suite/test, seconds (0 = none)
    discover DiscoverCfg, # optional auto-discovery
    suites DYNAMIC ARRAY OF SuiteCfg
END RECORD

# Subset of a suite's JSON report (extra fields like "cases" are ignored).
TYPE SuiteResult RECORD
    suite STRING,
    tests INTEGER,
    passed INTEGER,
    failed INTEGER,
    errors INTEGER,
    skipped INTEGER
END RECORD

# Minimal shape to read just the test names out of a JSON action file.
TYPE ActionNames RECORD
    tests DYNAMIC ARRAY OF RECORD
        name STRING
    END RECORD
END RECORD

TYPE Summary RECORD
    suites INTEGER,
    tests INTEGER,
    passed INTEGER,
    failed INTEGER,
    errors INTEGER,
    skipped INTEGER,
    timedOut INTEGER
END RECORD

MAIN
    DEFINE cfgPath, jsonText, isoNote STRING
    DEFINE cfg Config
    DEFINE agg Summary
    DEFINE i, ok INTEGER

    LET cfgPath = arg_val(1)
    CASE cfgPath
        WHEN "-h"
            CALL usage() RETURN
        WHEN "--help"
            CALL usage() RETURN
        WHEN "-V"
            DISPLAY SFMT("fgltest %1", core.VERSION) RETURN
        WHEN "--version"
            DISPLAY SFMT("fgltest %1", core.VERSION) RETURN
    END CASE
    IF cfgPath IS NULL OR LENGTH(cfgPath) == 0 THEN
        LET cfgPath = "fgltest.json"
    END IF

    LET jsonText = readFile(cfgPath)
    IF jsonText IS NULL THEN
        DISPLAY SFMT("fgltest: cannot read config '%1'", cfgPath)
        EXIT PROGRAM 2
    END IF
    TRY
        CALL util.JSON.parse(jsonText, cfg)
    CATCH
        DISPLAY SFMT("fgltest: invalid config JSON in '%1'", cfgPath)
        EXIT PROGRAM 2
    END TRY

    IF cfg.port == 0 THEN
        LET cfg.port = server.DEFAULT_PORT
    END IF
    IF cfg.outdir IS NULL OR LENGTH(cfg.outdir) == 0 THEN
        LET cfg.outdir = "."
    END IF
    IF cfg.reporters IS NULL OR LENGTH(cfg.reporters) == 0 THEN
        LET cfg.reporters = "console,junit,json"
    END IF
    IF cfg.jsonRunner IS NULL OR LENGTH(cfg.jsonRunner) == 0 THEN
        LET cfg.jsonRunner = "com/fourjs/fgltest/fgltest_json"
    END IF

    CALL discoverSuites(cfg)   -- append any auto-discovered suites

    LET ok = os.Path.mkDir(cfg.outdir)   -- ignore result: may already exist
    CALL fgl_setenv("FGLTEST_OUTDIR", cfg.outdir)   -- so the server log lands here too

    LET isoNote = ""
    IF cfg.isolate THEN
        LET isoNote = "; isolate=on"
    END IF
    DISPLAY SFMT("fgltest: %1 suite(s); server port %2; outdir %3%4",
        cfg.suites.getLength(), cfg.port, cfg.outdir, isoNote)

    IF cfg.suites.getLength() == 0 THEN
        DISPLAY "fgltest: no suites to run"
        EXIT PROGRAM 2
    END IF

    IF NOT server.start(cfg.port, 300, 30) THEN
        DISPLAY SFMT("fgltest: could not start the GGC scenario server on port %1.",
            cfg.port)
        IF NOT server.haveGgcAdmin() THEN
            DISPLAY "fgltest: 'ggcadmin' is not on PATH — source the GGC environment first:"
            DISPLAY '           . "$FGLDIR/testing_utilities/ggc/envggc"'
        ELSE
            DISPLAY SFMT("fgltest: see %1/ggcserver.log for the server's own output;", cfg.outdir)
            DISPLAY SFMT("           another process may already be using port %1.", cfg.port)
        END IF
        EXIT PROGRAM 2
    END IF

    FOR i = 1 TO cfg.suites.getLength()
        DISPLAY SFMT("--- %1 ---", cfg.suites[i].name)
        IF cfg.isolate OR cfg.suites[i].isolate THEN
            CALL runIsolated(cfg, i, agg)
        ELSE
            CALL runWhole(cfg, i, agg)
        END IF
    END FOR
    LET agg.suites = cfg.suites.getLength()

    CALL server.stop(cfg.port)

    DISPLAY SFMT("=== fgltest: %1 suites, %2 tests, %3 passed, %4 failed, %5 errors, %6 skipped ===",
        agg.suites, agg.tests, agg.passed, agg.failed, agg.errors, agg.skipped)
    IF agg.timedOut > 0 THEN
        DISPLAY SFMT("fgltest: %1 suite(s) hit the configured timeout", agg.timedOut)
    END IF
    CALL writeText(SFMT("%1/fgltest.summary.json", cfg.outdir), util.JSON.stringify(agg))

    IF agg.failed > 0 OR agg.errors > 0 THEN
        EXIT PROGRAM 1
    END IF
    EXIT PROGRAM 0
END MAIN

# Run a whole suite in one process (the default), merging its result into agg.
FUNCTION runWhole(cfg Config, idx INTEGER, agg Summary INOUT)
    DEFINE s SuiteCfg
    DEFINE st SMALLINT
    DEFINE sr SuiteResult
    DEFINE timedOut BOOLEAN

    LET s = cfg.suites[idx]
    CALL runSuiteProc(cfg, s, "", s.name) RETURNING st, timedOut
    IF timedOut THEN
        LET agg.timedOut = agg.timedOut + 1
    END IF
    LET sr = readResult(cfg, s.name)
    IF sr.tests IS NULL THEN
        LET agg.errors = agg.errors + 1
        IF timedOut THEN
            DISPLAY SFMT("  ! timed out after %1s, no results produced",
                suiteTimeout(cfg, s))
        ELSE
            DISPLAY SFMT("  ! no results produced (exit %1) — see %2/%3.log",
                st / 256, cfg.outdir, s.name)
        END IF
    ELSE
        LET agg.tests = agg.tests + sr.tests
        LET agg.passed = agg.passed + sr.passed
        # A suite JSON counts an errored test in BOTH failed and errors; keep the
        # aggregate consistent by taking failures as the non-errored remainder.
        LET agg.failed = agg.failed + (sr.failed - sr.errors)
        LET agg.errors = agg.errors + sr.errors
        LET agg.skipped = agg.skipped + sr.skipped
        DISPLAY SFMT("  %1 tests, %2 passed, %3 failed, %4 errors, %5 skipped",
            sr.tests, sr.passed, sr.failed - sr.errors, sr.errors, sr.skipped)
        IF timedOut THEN
            DISPLAY SFMT("  ! timed out after %1s (partial results above)",
                suiteTimeout(cfg, s))
        END IF
    END IF
END FUNCTION

# Run each of a suite's tests in its own process (isolate mode): enumerate the
# test names, then run one subprocess per test (FGLTEST_ONLY). Each test writes
# its own report files (<suite>.<k>.*); counts are merged into agg.
FUNCTION runIsolated(cfg Config, idx INTEGER, agg Summary INOUT)
    DEFINE s SuiteCfg
    DEFINE names StrList
    DEFINE k INTEGER
    DEFINE rname STRING
    DEFINE sr SuiteResult
    DEFINE st SMALLINT
    DEFINE timedOut BOOLEAN
    DEFINE tt, tp, tf, terr, tsk, tto INTEGER

    LET s = cfg.suites[idx]
    LET names = listTests(cfg, s)
    IF names.getLength() == 0 THEN
        LET agg.errors = agg.errors + 1
        DISPLAY "  ! no tests discovered to isolate"
        RETURN
    END IF

    FOR k = 1 TO names.getLength()
        LET rname = SFMT("%1.%2", s.name, k)
        CALL runSuiteProc(cfg, s, names[k], rname) RETURNING st, timedOut
        IF timedOut THEN
            LET tto = tto + 1
        END IF
        LET sr = readResult(cfg, rname)
        IF sr.tests IS NULL THEN
            LET terr = terr + 1
        ELSE
            LET tt = tt + sr.tests
            LET tp = tp + sr.passed
            LET tf = tf + (sr.failed - sr.errors)
            LET terr = terr + sr.errors
            LET tsk = tsk + sr.skipped
        END IF
    END FOR

    LET agg.tests = agg.tests + tt
    LET agg.passed = agg.passed + tp
    LET agg.failed = agg.failed + tf
    LET agg.errors = agg.errors + terr
    LET agg.skipped = agg.skipped + tsk
    LET agg.timedOut = agg.timedOut + tto
    DISPLAY SFMT("  %1 tests, %2 passed, %3 failed, %4 errors, %5 skipped  (isolated across %6 processes)",
        tt, tp, tf, terr, tsk, names.getLength())
    IF tto > 0 THEN
        DISPLAY SFMT("  ! %1 isolated test(s) timed out", tto)
    END IF
END FUNCTION

# Build and run one suite subprocess. `only` (FGLTEST_ONLY) restricts the run to
# a single test name ("" = whole suite); `rname` is the report basename.
# Child env is set in-process (RUN inherits it) — OS-agnostic, no shell VAR=val
# prefix. Args are double-quoted (valid in both sh and cmd). Suite stdout is
# redirected to a log so the CLI's console stays clean.
#
# Returns the child's termination status and whether the timeout fired.
FUNCTION runSuiteProc(cfg Config, s SuiteCfg, only STRING, rname STRING)
    RETURNS (SMALLINT, BOOLEAN)
    DEFINE cmd, logf, runModule, donef STRING
    DEFINE st SMALLINT
    DEFINE tmo, w INTEGER

    LET logf = SFMT("%1/%2.log", cfg.outdir, rname)
    LET donef = SFMT("%1/%2.done", cfg.outdir, rname)
    LET tmo = suiteTimeout(cfg, s)

    CALL fgl_setenv("FGLTEST_REPORTERS", SFMT("%1,json", cfg.reporters))
    CALL fgl_setenv("FGLTEST_OUTDIR", cfg.outdir)
    CALL fgl_setenv("FGLTEST_NAME", rname)
    CALL fgl_setenv("FGLTEST_ONLY", only)
    CALL fgl_setenv("FGLTEST_LIST", "")   -- ensure enumeration mode is off
    # The child gets the same budget as its own soft limit: it stops scheduling
    # tests once exceeded and still writes reports, which is a far better outcome
    # than the hard watchdog below. The watchdog only catches a wedged process.
    CALL fgl_setenv("FGLTEST_TIMEOUT", tmo)

    # A JSON action file runs via the generic runner (path from FGLTEST_ACTIONS);
    # a compiled suite runs its own module. Clear FGLTEST_ACTIONS otherwise so a
    # prior JSON suite does not leak into a following compiled one.
    IF s.actions IS NOT NULL AND LENGTH(s.actions) > 0 THEN
        LET runModule = cfg.jsonRunner
        CALL fgl_setenv("FGLTEST_ACTIONS", s.actions)
    ELSE
        LET runModule = s.module
        CALL fgl_setenv("FGLTEST_ACTIONS", "")
    END IF

    IF s.mode == "ua" THEN
        LET cmd = SFMT('fglrun %1 ua --url "%2" > "%3" 2>&1', runModule, s.url, logf)
    ELSE
        LET cmd = SFMT('fglrun %1 tcp --working-directory "%2" --command-line "%3" > "%4" 2>&1',
            runModule, s.workdir, s.commandLine, logf)
    END IF

    # No timeout configured: wait for the child directly. This is the accurate
    # path — RETURNING gives the real termination status.
    IF tmo <= 0 THEN
        RUN cmd RETURNING st
        RETURN st, FALSE
    END IF

    # Timeout configured: BDL's RUN offers no PID and no timed wait, so poll for
    # the marker the runner drops on completion. GRACE lets the child's own soft
    # budget finish and report first; the watchdog is the last resort.
    CALL deleteQuietly(donef)
    RUN cmd WITHOUT WAITING
    FOR w = 1 TO tmo + GRACE_SECS
        SLEEP 1
        IF os.Path.exists(donef) THEN
            RETURN 0, FALSE
        END IF
    END FOR

    # Wedged. The child is almost certainly blocked reading the scenario server
    # socket, so bouncing the server releases it (ggc exits on a closed channel)
    # and leaves a clean server for the suites that follow.
    DISPLAY SFMT("  ! no completion after %1s — restarting the scenario server",
        tmo + GRACE_SECS)
    CALL server.stop(cfg.port)
    IF NOT server.start(cfg.port, 300, 30) THEN
        DISPLAY "  ! could not restart the scenario server; later suites will fail"
    END IF
    RETURN -1, TRUE
END FUNCTION

# Effective wall-clock limit for a suite: its own, else the global, else none.
FUNCTION suiteTimeout(cfg Config, s SuiteCfg) RETURNS INTEGER
    IF s.timeout > 0 THEN
        RETURN s.timeout
    END IF
    IF cfg.timeout > 0 THEN
        RETURN cfg.timeout
    END IF
    RETURN 0
END FUNCTION

# Remove a file, ignoring "not there" and permission problems.
FUNCTION deleteQuietly(path STRING)
    DEFINE ok INTEGER
    IF os.Path.exists(path) THEN
        LET ok = os.Path.delete(path)
    END IF
END FUNCTION

FUNCTION usage()
    DISPLAY "fgltest — functional-test runner for Genero BDL applications"
    DISPLAY ""
    DISPLAY "Usage:"
    DISPLAY "  fglrun com/fourjs/fgltest/fgltest [config.json]"
    DISPLAY ""
    DISPLAY "Arguments:"
    DISPLAY "  config.json      test configuration (default: fgltest.json)"
    DISPLAY ""
    DISPLAY "Options:"
    DISPLAY "  -h, --help       show this help"
    DISPLAY "  -V, --version    show the fgltest version"
    DISPLAY ""
    DISPLAY "Requires the GGC environment on PATH:"
    DISPLAY '  . "$FGLDIR/testing_utilities/ggc/envggc"'
    DISPLAY ""
    DISPLAY "Exit codes: 0 all passed, 1 tests failed or errored, 2 setup problem."
    DISPLAY "Docs: README.md and USERGUIDE.md"
END FUNCTION

# Read a suite's JSON result (sr.tests IS NULL if missing/unparseable).
FUNCTION readResult(cfg Config, rname STRING) RETURNS SuiteResult
    DEFINE txt STRING
    DEFINE sr SuiteResult
    INITIALIZE sr TO NULL
    LET txt = readFile(SFMT("%1/%2.json", cfg.outdir, rname))
    IF txt IS NOT NULL THEN
        TRY
            CALL util.JSON.parse(txt, sr)
        CATCH
        END TRY
    END IF
    RETURN sr
END FUNCTION

# ---------------------------------------------------------- enumeration ----

# Test names of a suite: parsed from a JSON action file, or obtained by running a
# compiled module in FGLTEST_LIST mode (which writes names and exits, no app).
FUNCTION listTests(cfg Config, s SuiteCfg) RETURNS StrList
    IF s.actions IS NOT NULL AND LENGTH(s.actions) > 0 THEN
        RETURN listActionTests(s.actions)
    END IF
    RETURN listModuleTests(cfg, s)
END FUNCTION

FUNCTION listActionTests(path STRING) RETURNS StrList
    DEFINE txt STRING
    DEFINE an ActionNames
    DEFINE names StrList
    DEFINE i INTEGER
    LET txt = readFile(path)
    IF txt IS NULL THEN
        RETURN names
    END IF
    TRY
        CALL util.JSON.parse(txt, an)
    CATCH
        RETURN names
    END TRY
    FOR i = 1 TO an.tests.getLength()
        LET names[i] = an.tests[i].name
    END FOR
    RETURN names
END FUNCTION

FUNCTION listModuleTests(cfg Config, s SuiteCfg) RETURNS StrList
    DEFINE listFile, cmd, line STRING
    DEFINE st SMALLINT
    DEFINE names StrList
    DEFINE ch base.Channel

    LET listFile = SFMT("%1/%2.tests", cfg.outdir, s.name)
    CALL fgl_setenv("FGLTEST_ONLY", "")
    CALL fgl_setenv("FGLTEST_ACTIONS", "")
    CALL fgl_setenv("FGLTEST_TIMEOUT", "")
    CALL fgl_setenv("FGLTEST_LIST", listFile)
    LET cmd = SFMT('fglrun %1 > "%2/%3.list.log" 2>&1', s.module, cfg.outdir, s.name)
    RUN cmd RETURNING st
    CALL fgl_setenv("FGLTEST_LIST", "")

    LET ch = base.Channel.create()
    TRY
        CALL ch.openFile(listFile, "r")
    CATCH
        RETURN names
    END TRY
    WHILE (line := ch.readLine()) IS NOT NULL
        IF LENGTH(line) > 0 THEN
            LET names[names.getLength() + 1] = line
        END IF
    END WHILE
    CALL ch.close()
    RETURN names
END FUNCTION

# ----------------------------------------------------------- discovery ----

# Scan cfg.discover.dir and append discovered suites to cfg.suites.
FUNCTION discoverSuites(cfg Config INOUT)
    DEFINE d DiscoverCfg
    DEFINE h, n INTEGER
    DEFINE entry, modFull STRING
    DEFINE s SuiteCfg

    LET d = cfg.discover
    IF d.dir IS NULL OR LENGTH(d.dir) == 0 THEN
        RETURN
    END IF
    IF d.modulePattern IS NULL OR LENGTH(d.modulePattern) == 0 THEN
        LET d.modulePattern = "_test"
    END IF
    LET modFull = SFMT("%1.42m", d.modulePattern)

    CALL os.Path.dirSort("name", 1)
    LET h = os.Path.dirOpen(d.dir)
    IF h <= 0 THEN
        DISPLAY SFMT("fgltest: discover: cannot open directory '%1'", d.dir)
        RETURN
    END IF
    WHILE TRUE
        LET entry = os.Path.dirNext(h)
        IF entry IS NULL THEN
            EXIT WHILE
        END IF
        IF entry == "." OR entry == ".." THEN
            CONTINUE WHILE
        END IF
        INITIALIZE s TO NULL
        IF endsWith(entry, ".actions.json") THEN
            LET s.name = entry.subString(1, entry.getLength() - 13)
            LET s.actions = os.Path.join(d.dir, entry)
            CALL applyTemplate(s, d)
            LET n = cfg.suites.getLength() + 1
            LET cfg.suites[n].* = s.*
            CONTINUE WHILE
        END IF
        IF endsWith(entry, modFull) THEN
            LET s.name = entry.subString(1, entry.getLength() - 4)   -- strip ".42m"
            LET s.module = os.Path.join(d.dir, s.name)
            CALL applyTemplate(s, d)
            LET n = cfg.suites.getLength() + 1
            LET cfg.suites[n].* = s.*
            CONTINUE WHILE
        END IF
    END WHILE
    CALL os.Path.dirClose(h)
END FUNCTION

# Apply the discovery connection template to a discovered suite.
FUNCTION applyTemplate(s SuiteCfg INOUT, d DiscoverCfg)
    IF d.mode IS NOT NULL AND LENGTH(d.mode) > 0 THEN
        LET s.mode = d.mode
    ELSE
        LET s.mode = "tcp"
    END IF
    LET s.workdir = d.workdir
    LET s.commandLine = d.commandLine
    LET s.url = d.url
END FUNCTION

# TRUE if s ends with suffix (empty-safe, concrete boolean).
FUNCTION endsWith(s STRING, suffix STRING) RETURNS BOOLEAN
    DEFINE sl, xl INTEGER
    LET sl = s.getLength()
    LET xl = suffix.getLength()
    IF xl == 0 THEN
        RETURN TRUE
    END IF
    IF xl > sl THEN
        RETURN FALSE
    END IF
    IF s.subString(sl - xl + 1, sl) == suffix THEN
        RETURN TRUE
    END IF
    RETURN FALSE
END FUNCTION

# ------------------------------------------------------------- file I/O ----

FUNCTION readFile(path STRING) RETURNS STRING
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

FUNCTION writeText(path STRING, content STRING)
    DEFINE ch base.Channel
    LET ch = base.Channel.create()
    CALL ch.openFile(path, "w")
    CALL ch.writeLine(content)
    CALL ch.close()
END FUNCTION
