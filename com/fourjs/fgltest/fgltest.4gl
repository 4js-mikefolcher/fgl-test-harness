# fgltest — the test-runner CLI.
#
#   fglrun com/fourjs/fgltest/fgltest [config.json]   (default: fgltest.json)
#
# Reads a JSON config listing suites + their connection, owns the GGC scenario
# server lifecycle (start once / stop once, robust to suite crashes), runs each
# suite as a subprocess (passing FGLTEST_* env for reporters/output), reads each
# suite's JSON result to merge counts, writes an aggregate summary, and exits
# non-zero if any suite failed, errored or did not run to completion.
#
# Two optional features on top of explicit suites:
#   discover : auto-find suites in a directory (JSON action files + compiled
#              *_test modules) using a shared connection template.
#   isolate  : run each *test* in its own subprocess (full crash/hang isolation)
#              — enumerate the suite's tests, then run each with FGLTEST_ONLY.
#
# The config model and every decision that needs no process — defaults, path
# resolution, the suite command, result folding, the exit code — live in
# fgltest.cli, where fgltest's own tests reach them.

IMPORT util
IMPORT os
IMPORT FGL com.fourjs.fgltest.core
IMPORT FGL com.fourjs.fgltest.server
IMPORT FGL com.fourjs.fgltest.cli

# Extra seconds the watchdog waits beyond a suite's own budget, so the child's
# soft limit (which still writes reports) gets to win the race.
CONSTANT GRACE_SECS = 10

# Minimal shape to read just the test names out of a JSON action file.
TYPE ActionNames RECORD
    tests DYNAMIC ARRAY OF RECORD
        name STRING
    END RECORD
END RECORD

# TRUE if this run started the scenario server, and so may stop or restart it.
# A server that was already listening belongs to someone else — a developer,
# or another run on the same machine — and is left alone.
DEFINE m_ownServer BOOLEAN

MAIN
    DEFINE cfgPath, jsonText, isoNote, err STRING
    DEFINE cfg cli.Config
    DEFINE agg cli.Summary
    DEFINE i, ok, code INTEGER
    DEFINE up BOOLEAN

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

    # Defaults, plus every relative path resolved against the config's own
    # directory (before discovery, which builds on the resolved discover.dir).
    # Every mistake in the config at once, before a server or app starts:
    # normalize() reports its problems (a bad port, an unset variable) without
    # stopping, and checkConfig() lists them with its own.
    LET err = cli.normalize(cfg, cfgPath, base.Application.getProgramDir())
    LET err = cli.checkConfig(cfgPath, jsonText, cfg, err)
    IF err IS NOT NULL THEN
        DISPLAY SFMT("fgltest: %1", err)
        EXIT PROGRAM 2
    END IF
    CALL discoverSuites(cfg, cfgPath)   -- append any auto-discovered suites

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

    # Every suite's reports from the last run go first — whole-suite and
    # per-test ones alike, whichever mode ran last — so none can be read back,
    # or picked up by a CI glob, as this run's. One that cannot be removed
    # stops the run: it would be taken for a result.
    LET err = clearPreviousRun(cfg)
    IF err IS NOT NULL THEN
        DISPLAY SFMT("fgltest: %1 — it would be read back as this run's result", err)
        EXIT PROGRAM 2
    END IF

    CALL server.ensure(cfg.port, 300, 30) RETURNING up, m_ownServer
    IF NOT up THEN
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
    IF NOT core.isTrue(m_ownServer) THEN
        DISPLAY SFMT("fgltest: using the scenario server already running on port %1 (it will be left running)",
            cfg.port)
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

    IF core.isTrue(m_ownServer) THEN
        CALL server.stop(cfg.port)
    END IF

    DISPLAY SFMT("=== fgltest: %1 suites, %2 tests, %3 passed, %4 failed, %5 errors, %6 skipped ===",
        agg.suites, agg.tests, agg.passed, agg.failed, agg.errors, agg.skipped)
    IF agg.timedOut > 0 THEN
        DISPLAY SFMT("fgltest: %1 suite(s) hit the configured timeout", agg.timedOut)
    END IF
    IF agg.incomplete > 0 THEN
        DISPLAY SFMT("fgltest: %1 suite process(es) ended before completing — see the logs in %2",
            agg.incomplete, cfg.outdir)
    END IF
    CALL writeText(SFMT("%1/fgltest.summary.json", cfg.outdir), util.JSON.stringify(agg))

    LET code = cli.exitCode(agg)
    EXIT PROGRAM code
END MAIN

# Run a whole suite in one process (the default), merging its result into agg.
FUNCTION runWhole(cfg cli.Config, idx INTEGER, agg cli.Summary INOUT)
    DEFINE s cli.SuiteCfg
    DEFINE st INTEGER
    DEFINE sr cli.SuiteResult
    DEFINE timedOut, completed BOOLEAN
    DEFINE part cli.Summary

    LET s = cfg.suites[idx]
    CALL runSuiteProc(cfg, s, "", s.name) RETURNING st, timedOut, completed
    LET sr = readResult(cfg, s.name)
    CALL cli.fold(part, sr, completed, timedOut)
    IF sr.tests IS NOT NULL THEN
        DISPLAY SFMT("  %1 tests, %2 passed, %3 failed, %4 errors, %5 skipped",
            part.tests, part.passed, part.failed, part.errors, part.skipped)
    END IF
    CALL explainProblem(cfg, s, s.name, st, sr, completed, timedOut)
    CALL cli.add(agg, part)
END FUNCTION

# Run each of a suite's tests in its own process (isolate mode): enumerate the
# test names, then run one subprocess per test (FGLTEST_ONLY). Each test writes
# its own report files (<suite>.<k>.*); counts are merged into agg.
FUNCTION runIsolated(cfg cli.Config, idx INTEGER, agg cli.Summary INOUT)
    DEFINE s cli.SuiteCfg
    DEFINE names cli.NameList
    DEFINE k INTEGER
    DEFINE rname STRING
    DEFINE sr cli.SuiteResult
    DEFINE st INTEGER
    DEFINE timedOut, completed BOOLEAN
    DEFINE part cli.Summary

    LET s = cfg.suites[idx]
    LET names = listTests(cfg, s)
    IF names.getLength() == 0 THEN
        LET agg.errors = agg.errors + 1
        DISPLAY "  ! no tests discovered to isolate"
        RETURN
    END IF

    FOR k = 1 TO names.getLength()
        LET rname = SFMT("%1.%2", s.name, k)
        CALL runSuiteProc(cfg, s, names[k], rname) RETURNING st, timedOut, completed
        LET sr = readResult(cfg, rname)
        CALL cli.fold(part, sr, completed, timedOut)
        IF NOT core.isTrue(completed) THEN
            DISPLAY SFMT("  ! test '%1':", names[k])
        END IF
        CALL explainProblem(cfg, s, rname, st, sr, completed, timedOut)
    END FOR

    DISPLAY SFMT("  %1 tests, %2 passed, %3 failed, %4 errors, %5 skipped  (isolated across %6 processes)",
        part.tests, part.passed, part.failed, part.errors, part.skipped, names.getLength())
    IF part.timedOut > 0 THEN
        DISPLAY SFMT("  ! %1 isolated test(s) timed out", part.timedOut)
    END IF
    CALL cli.add(agg, part)
END FUNCTION

# Say why a suite process needs attention, if it does: it timed out, it ended
# without completing (a runtime error, a crash, a kill), or it left no results.
FUNCTION explainProblem(cfg cli.Config, s cli.SuiteCfg, rname STRING, st INTEGER,
    sr cli.SuiteResult, completed BOOLEAN, timedOut BOOLEAN)
    IF core.isTrue(timedOut) THEN
        IF sr.tests IS NULL THEN
            DISPLAY SFMT("  ! timed out after %1s, no results produced",
                suiteTimeout(cfg, s))
        ELSE
            DISPLAY SFMT("  ! timed out after %1s (partial results above)",
                suiteTimeout(cfg, s))
        END IF
        RETURN
    END IF
    IF core.isTrue(completed) AND sr.tests IS NOT NULL THEN
        RETURN
    END IF
    IF sr.tests IS NULL THEN
        DISPLAY SFMT("  ! no results produced (exit %1) — see %2/%3.log",
            exitOf(st), cfg.outdir, rname)
    ELSE
        DISPLAY SFMT("  ! the suite process ended before completing (exit %1); the results above are partial — see %2/%3.log",
            exitOf(st), cfg.outdir, rname)
    END IF
END FUNCTION

# A RUN status as the exit code to show (RUN reports the wait status).
FUNCTION exitOf(st INTEGER) RETURNS STRING
    IF st IS NULL OR st < 0 THEN
        RETURN "unknown"
    END IF
    RETURN st / 256 USING "<<<<&"
END FUNCTION

# Build and run one suite subprocess. `only` (FGLTEST_ONLY) restricts the run to
# a single test name ("" = whole suite); `rname` is the report basename.
# Child env is set in-process (RUN inherits it) — OS-agnostic, no shell VAR=val
# prefix. Suite stdout is redirected to a log so the CLI's console stays clean.
#
# Returns the child's termination status, whether the timeout fired, and
# whether the runner reached the end of the suite (its completion marker).
FUNCTION runSuiteProc(cfg cli.Config, s cli.SuiteCfg, only STRING, rname STRING)
    RETURNS (INTEGER, BOOLEAN, BOOLEAN)
    DEFINE cmd, logf, donef, err STRING
    DEFINE st INTEGER
    DEFINE tmo, w INTEGER

    LET logf = SFMT("%1/%2.log", cfg.outdir, rname)
    LET donef = SFMT("%1/%2.done", cfg.outdir, rname)
    LET tmo = suiteTimeout(cfg, s)
    # The reports and marker are read back after the child exits: remove any
    # left by an earlier run first, or a suite that never started would be
    # credited with that run's results. (clearPreviousRun() did this already;
    # this covers a file that appeared since.) If one survives, the suite is
    # not run, and counts as incomplete.
    LET err = cli.clearRunFiles(cfg.outdir, rname)
    IF err IS NOT NULL THEN
        DISPLAY SFMT("  ! %1 — not run, as it would be read back as this run's result", err)
        RETURN -1, FALSE, FALSE
    END IF

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
    IF cli.isActionSuite(s) THEN
        CALL fgl_setenv("FGLTEST_ACTIONS", s.actions)
    ELSE
        CALL fgl_setenv("FGLTEST_ACTIONS", "")
    END IF
    LET cmd = cli.suiteCommand(cfg, s, logf)

    # No timeout configured: wait for the child directly. This is the accurate
    # path — RETURNING gives the real termination status. The completion marker
    # still decides whether the suite ran to the end: an exit status cannot tell
    # "tests failed" from "the process died".
    IF tmo <= 0 THEN
        RUN cmd RETURNING st
        RETURN st, FALSE, os.Path.exists(donef)
    END IF

    # Timeout configured: BDL's RUN offers no PID and no timed wait, so poll for
    # the marker the runner drops on completion. GRACE lets the child's own soft
    # budget finish and report first; the watchdog is the last resort.
    RUN cmd WITHOUT WAITING
    FOR w = 1 TO tmo + GRACE_SECS
        SLEEP 1
        IF os.Path.exists(donef) THEN
            RETURN 0, FALSE, TRUE
        END IF
    END FOR

    # Wedged. The child is almost certainly blocked reading the scenario server
    # socket, so bouncing the server releases it (ggc exits on a closed channel)
    # and leaves a clean server for the suites that follow. A server this run
    # did not start is not ours to bounce: it may be serving someone else.
    IF NOT core.isTrue(m_ownServer) THEN
        DISPLAY SFMT("  ! no completion after %1s — the scenario server on port %2 was not started by this run, so it is not restarted; the stuck suite process is left behind",
            tmo + GRACE_SECS, cfg.port)
        RETURN -1, TRUE, FALSE
    END IF
    DISPLAY SFMT("  ! no completion after %1s — restarting the scenario server",
        tmo + GRACE_SECS)
    CALL server.stop(cfg.port)
    IF NOT server.start(cfg.port, 300, 30) THEN
        DISPLAY "  ! could not restart the scenario server; later suites will fail"
    END IF
    RETURN -1, TRUE, FALSE
END FUNCTION

# Remove what the last run left for every suite: its whole-suite reports and
# marker, and its per-test (isolated) ones. Returns the first file that could
# not be removed, or NULL.
FUNCTION clearPreviousRun(cfg cli.Config) RETURNS STRING
    DEFINE i INTEGER
    DEFINE err STRING
    FOR i = 1 TO cfg.suites.getLength()
        LET err = cli.clearRunFiles(cfg.outdir, cfg.suites[i].name)
        IF err IS NULL THEN
            LET err = cli.clearIsolatedFiles(cfg.outdir, cfg.suites[i].name)
        END IF
        IF err IS NOT NULL THEN
            RETURN err
        END IF
    END FOR
    RETURN NULL
END FUNCTION

# Effective wall-clock limit for a suite: its own, else the global, else none.
FUNCTION suiteTimeout(cfg cli.Config, s cli.SuiteCfg) RETURNS INTEGER
    IF s.timeout > 0 THEN
        RETURN s.timeout
    END IF
    IF cfg.timeout > 0 THEN
        RETURN cfg.timeout
    END IF
    RETURN 0
END FUNCTION

FUNCTION usage()
    DISPLAY "fgltest — functional-test runner for Genero BDL applications"
    DISPLAY ""
    DISPLAY "Usage:"
    DISPLAY "  fglrun com/fourjs/fgltest/fgltest [config.json]"
    DISPLAY ""
    DISPLAY "Arguments:"
    DISPLAY "  config.json      test configuration (default: fgltest.json); relative"
    DISPLAY "                   paths inside it resolve against its own directory"
    DISPLAY ""
    DISPLAY "Options:"
    DISPLAY "  -h, --help       show this help"
    DISPLAY "  -V, --version    show the fgltest version"
    DISPLAY ""
    DISPLAY "Requires the GGC environment on PATH:"
    DISPLAY '  . "$FGLDIR/testing_utilities/ggc/envggc"'
    DISPLAY ""
    DISPLAY "Exit codes: 0 all passed, 1 tests failed or errored (or a suite did not"
    DISPLAY "            run to completion), 2 setup problem."
    DISPLAY "Docs: README.md and USERGUIDE.md"
END FUNCTION

# Read a suite's JSON result (sr.tests IS NULL if missing/unparseable).
FUNCTION readResult(cfg cli.Config, rname STRING) RETURNS cli.SuiteResult
    DEFINE txt STRING
    DEFINE sr cli.SuiteResult
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
# Each name once: isolate mode runs a process per name, and a repeated name
# would run, and count, twice (the runner reports the repeat as an error).
FUNCTION listTests(cfg cli.Config, s cli.SuiteCfg) RETURNS cli.NameList
    IF cli.isActionSuite(s) THEN
        RETURN cli.uniqueNames(listActionTests(s.actions))
    END IF
    RETURN cli.uniqueNames(listModuleTests(cfg, s))
END FUNCTION

FUNCTION listActionTests(path STRING) RETURNS cli.NameList
    DEFINE txt STRING
    DEFINE an ActionNames
    DEFINE names cli.NameList
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

FUNCTION listModuleTests(cfg cli.Config, s cli.SuiteCfg) RETURNS cli.NameList
    DEFINE listFile, cmd, line STRING
    DEFINE st INTEGER
    DEFINE names cli.NameList
    DEFINE ch base.Channel

    LET listFile = SFMT("%1/%2.tests", cfg.outdir, s.name)
    # A list left by an earlier run would be read as this module's tests if the
    # module now fails to start.
    IF cli.removeFile(listFile) IS NOT NULL THEN
        DISPLAY SFMT("  ! cannot remove the stale test list '%1'", listFile)
        RETURN names
    END IF
    CALL fgl_setenv("FGLTEST_ONLY", "")
    CALL fgl_setenv("FGLTEST_ACTIONS", "")
    CALL fgl_setenv("FGLTEST_TIMEOUT", "")
    CALL fgl_setenv("FGLTEST_LIST", listFile)
    LET cmd = SFMT("fglrun %1 > %2 2>&1", core.shellArg(s.module),
        core.shellArg(SFMT("%1/%2.list.log", cfg.outdir, s.name)))
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

# Scan cfg.discover.dir and append discovered suites to cfg.suites. Runs after
# cli.normalize(), so dir and workdir are already resolved and the paths built
# here need no further resolution.
FUNCTION discoverSuites(cfg cli.Config INOUT, cfgPath STRING)
    DEFINE d cli.DiscoverCfg
    DEFINE h, n INTEGER
    DEFINE entry, modFull, clash STRING
    DEFINE s cli.SuiteCfg

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
        ELSE
            IF endsWith(entry, modFull) THEN
                LET s.name = entry.subString(1, entry.getLength() - 4)   -- strip ".42m"
                LET s.module = os.Path.join(d.dir, s.name)
            ELSE
                CONTINUE WHILE
            END IF
        END IF
        # Suites write their reports under their name: a discovered suite may
        # not take a name an explicit (or earlier discovered) one already has.
        IF hasSuite(cfg, s.name) THEN
            DISPLAY SFMT("fgltest: discover: skipped '%1' — a suite with that name is already configured",
                entry)
            CONTINUE WHILE
        END IF
        LET clash = cli.outputClash(cfg, cfgPath, s.name)
        IF clash IS NOT NULL THEN
            DISPLAY SFMT("fgltest: discover: skipped '%1' — %2", entry, clash)
            CONTINUE WHILE
        END IF
        CALL applyTemplate(s, d)
        LET n = cfg.suites.getLength() + 1
        LET cfg.suites[n].* = s.*
    END WHILE
    CALL os.Path.dirClose(h)
END FUNCTION

# TRUE if cfg already has a suite called `name`.
FUNCTION hasSuite(cfg cli.Config, name STRING) RETURNS BOOLEAN
    DEFINE i INTEGER
    FOR i = 1 TO cfg.suites.getLength()
        IF cfg.suites[i].name == name THEN
            RETURN TRUE
        END IF
    END FOR
    RETURN FALSE
END FUNCTION

# Apply the discovery connection template to a discovered suite.
FUNCTION applyTemplate(s cli.SuiteCfg INOUT, d cli.DiscoverCfg)
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
