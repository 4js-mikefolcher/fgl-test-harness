# fgltest.cli — the CLI's configuration model and the decisions it makes.
#
# Everything the fgltest program decides without touching a process lives here,
# so fgltest's own test suite can exercise it with no GGC: config defaults and
# path resolution, the command that runs a suite, which files a run leaves
# behind, and how each suite process folds into the aggregate and the exit
# code. The program itself (fgltest.4gl) keeps what needs the outside world —
# launching processes, polling, the scenario server.
#
# Not part of the suite-authoring API: suites never import it.

PACKAGE com.fourjs.fgltest

IMPORT os
IMPORT util
IMPORT FGL com.fourjs.fgltest.core
IMPORT FGL com.fourjs.fgltest.server

# The keys a config may use, by object. Any other key is reported: a typo'd
# key would otherwise be dropped silently by the JSON parser. Keys starting
# with "$" or "_" are left alone, for "$schema" and comment-style entries.
PRIVATE CONSTANT TOP_KEYS = "port,reporters,outdir,jsonRunner,isolate,timeout,discover,suites"
PRIVATE CONSTANT SUITE_KEYS = "name,module,actions,mode,workdir,commandLine,url,isolate,timeout"
PRIVATE CONSTANT DISCOVER_KEYS = "dir,mode,workdir,commandLine,url,modulePattern"
PRIVATE CONSTANT REPORTERS = "console,junit,tap,json"

PUBLIC TYPE NameList DYNAMIC ARRAY OF STRING

PUBLIC TYPE SuiteCfg RECORD
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
PUBLIC TYPE DiscoverCfg RECORD
    dir STRING,
    mode STRING,
    workdir STRING,
    commandLine STRING,
    url STRING,
    modulePattern STRING
END RECORD

PUBLIC TYPE Config RECORD
    port INTEGER,
    reporters STRING,     # csv: console,junit,tap,json
    outdir STRING,
    jsonRunner STRING,    # generic runner for "actions" suites (default: beside the CLI)
    isolate BOOLEAN,      # run every suite's tests in isolated processes
    timeout INTEGER,      # default wall-clock limit per suite/test, seconds (0 = none)
    discover DiscoverCfg, # optional auto-discovery
    suites DYNAMIC ARRAY OF SuiteCfg
END RECORD

# Subset of a suite's JSON report (extra fields like "cases" are ignored).
PUBLIC TYPE SuiteResult RECORD
    suite STRING,
    tests INTEGER,
    passed INTEGER,
    failed INTEGER,
    errors INTEGER,
    skipped INTEGER
END RECORD

#+ The CLI's aggregate, written as fgltest.summary.json.
PUBLIC TYPE Summary RECORD
    suites INTEGER,
    tests INTEGER,
    passed INTEGER,
    failed INTEGER,
    errors INTEGER,
    skipped INTEGER,
    timedOut INTEGER,     # processes the watchdog gave up on
    incomplete INTEGER    # processes that ended without the runner's completion marker
END RECORD

# ---------------------------------------------------------------- config ----

#+ Apply defaults and resolve every relative path in a parsed config.
#+
#+ Relative paths resolve against the config file's own directory, not the
#+ current one, so a config means the same thing wherever the CLI is started
#+ from — `fglpkg bdl` starts it inside the installed package.
#+
#+ The FGLTEST_PORT environment variable, when set, overrides "port": concurrent
#+ runs on one machine (CI jobs on a shared runner) can then each use their own
#+ scenario server without editing the config.
#+
#+ @param cfg        the parsed config, updated in place
#+ @param cfgPath    path of the config file
#+ @param programDir directory of the fgltest program (holds the default jsonRunner)
#+ @return NULL when the config is usable, else what is wrong with it
PUBLIC FUNCTION normalize(cfg Config INOUT, cfgPath STRING, programDir STRING)
    RETURNS STRING
    DEFINE dir, env STRING
    DEFINE i, p INTEGER

    LET env = fgl_getenv("FGLTEST_PORT")
    IF LENGTH(env) > 0 THEN
        LET p = env   -- a non-number converts to NULL
        IF p IS NULL OR p <= 0 OR p > server.MAX_PORT THEN
            RETURN SFMT("FGLTEST_PORT must be a port number (1-%1), not '%2'",
                server.MAX_PORT, env)
        END IF
        LET cfg.port = p
    END IF
    # An absent "port" parses as NULL, not 0, so a bare `== 0` misses it.
    IF cfg.port IS NULL OR cfg.port <= 0 THEN
        LET cfg.port = server.DEFAULT_PORT
    END IF
    IF cfg.port > server.MAX_PORT THEN
        RETURN SFMT("\"port\" must be a port number (1-%1), not %2",
            server.MAX_PORT, cfg.port)
    END IF
    IF LENGTH(cfg.reporters) == 0 THEN
        LET cfg.reporters = "console,junit,json"
    END IF
    LET cfg.reporters = noSpaces(cfg.reporters)   -- "console, junit" is fine

    LET dir = os.Path.dirName(cfgPath)
    IF LENGTH(cfg.outdir) == 0 THEN
        LET cfg.outdir = "."
    END IF
    LET cfg.outdir = resolvePath(dir, cfg.outdir)
    # A relative program path is only resolved against the current directory by
    # fglrun (never via FGLLDPATH), so the default runner is located from the
    # CLI's own position: the two programs ship side by side.
    IF LENGTH(cfg.jsonRunner) == 0 THEN
        LET cfg.jsonRunner = os.Path.join(programDir, "fgltest_json")
    ELSE
        LET cfg.jsonRunner = resolvePath(dir, cfg.jsonRunner)
    END IF
    # A tcp application without a "workdir" runs in the config's directory,
    # like the rest of the config's paths (not wherever the CLI was started).
    LET cfg.discover.dir = resolvePath(dir, cfg.discover.dir)
    LET cfg.discover.workdir = resolvePath(dir, defaultWorkdir(cfg.discover.mode, cfg.discover.workdir))
    FOR i = 1 TO cfg.suites.getLength()
        LET cfg.suites[i].module = resolvePath(dir, cfg.suites[i].module)
        LET cfg.suites[i].actions = resolvePath(dir, cfg.suites[i].actions)
        LET cfg.suites[i].workdir = resolvePath(dir,
            defaultWorkdir(cfg.suites[i].mode, cfg.suites[i].workdir))
    END FOR
    RETURN NULL
END FUNCTION

# "." for a tcp suite with no workdir (resolved to the config's directory).
PRIVATE FUNCTION defaultWorkdir(mode STRING, workdir STRING) RETURNS STRING
    IF LENGTH(workdir) == 0 AND NOT isUa(mode) THEN
        RETURN "."
    END IF
    RETURN workdir
END FUNCTION

PRIVATE FUNCTION isUa(mode STRING) RETURNS BOOLEAN
    IF mode == "ua" THEN
        RETURN TRUE
    END IF
    RETURN FALSE
END FUNCTION

PRIVATE FUNCTION noSpaces(s STRING) RETURNS STRING
    DEFINE b base.StringBuffer
    LET b = base.StringBuffer.create()
    CALL b.append(s)
    CALL b.replace(" ", "", 0)
    RETURN b.toString()
END FUNCTION

#+ Resolve `p` against directory `dir`. Absolute and empty paths are returned
#+ unchanged, and so is everything when `dir` is the current directory — the
#+ paths then read exactly as the config wrote them.
PUBLIC FUNCTION resolvePath(dir STRING, p STRING) RETURNS STRING
    IF LENGTH(p) == 0 THEN
        RETURN p
    END IF
    IF LENGTH(dir) == 0 OR dir == "." THEN
        RETURN p
    END IF
    IF p == "." THEN
        RETURN dir
    END IF
    RETURN os.Path.join(dir, p)   -- returns p itself when p is absolute
END FUNCTION

#+ Check a config for mistakes before anything runs, and describe them all at
#+ once: an unknown key (the JSON parser would otherwise drop a typo like
#+ "comandLine" silently), a suite without a name or reusing another's (suites
#+ write their reports under their name), a suite naming both or neither of
#+ module/actions, a module or action file that does not exist, an unknown mode
#+ or reporter, a ua suite without a url, a negative timeout. Call it after
#+ normalize(), which resolves the paths it checks.
#+
#+ @param cfgPath the config file (for the message)
#+ @param text    the config's JSON text (for the key check)
#+ @param cfg     the parsed, normalized config
#+ @return NULL when the config is valid, else a multi-line description
PUBLIC FUNCTION checkConfig(cfgPath STRING, text STRING, cfg Config) RETURNS STRING
    DEFINE b base.StringBuffer
    DEFINE obj, o util.JSONObject
    DEFINE arr util.JSONArray
    DEFINE tok base.StringTokenizer
    DEFINE names DICTIONARY OF INTEGER
    DEFINE i INTEGER
    DEFINE t, where, name STRING

    LET b = base.StringBuffer.create()
    TRY
        LET obj = util.JSONObject.parse(text)
    CATCH
        RETURN SFMT("config '%1' must be a JSON object", cfgPath)
    END TRY
    CALL checkKeys(b, obj, "the config", TOP_KEYS)
    # Check a type before reading through it: assigning an object to the wrong
    # class is a -1260 that TRY/CATCH does not catch.
    IF obj.getType("discover") == "OBJECT" THEN
        LET o = obj.get("discover")
        CALL checkKeys(b, o, "\"discover\"", DISCOVER_KEYS)
    END IF
    IF obj.getType("suites") == "ARRAY" THEN
        LET arr = obj.get("suites")
        FOR i = 1 TO arr.getLength()
            IF arr.getType(i) == "OBJECT" THEN
                LET o = arr.get(i)
                CALL checkKeys(b, o, SFMT("suite #%1", i), SUITE_KEYS)
            END IF
        END FOR
    END IF

    LET tok = base.StringTokenizer.create(cfg.reporters, ",")
    WHILE tok.hasMoreTokens()
        LET t = tok.nextToken()
        IF LENGTH(t) > 0 AND NOT inList(t, REPORTERS) THEN
            CALL addProblem(b, SFMT("\"reporters\": unknown reporter '%1' (use %2)", t, REPORTERS))
        END IF
    END WHILE
    IF cfg.timeout < 0 THEN
        CALL addProblem(b, "\"timeout\" cannot be negative")
    END IF

    IF LENGTH(cfg.discover.dir) > 0 THEN
        IF NOT os.Path.isDirectory(cfg.discover.dir) THEN
            CALL addProblem(b, SFMT("\"discover\": directory '%1' not found", cfg.discover.dir))
        END IF
        CALL checkConnection(b, "\"discover\"", cfg.discover.mode, cfg.discover.url)
    END IF

    FOR i = 1 TO cfg.suites.getLength()
        LET name = cfg.suites[i].name
        LET where = SFMT("suite #%1", i)
        IF LENGTH(name) == 0 THEN
            CALL addProblem(b, SFMT("%1 has no \"name\"", where))
        ELSE
            LET where = SFMT("suite '%1'", name)
            IF names.contains(name) THEN
                CALL addProblem(b, SFMT("suite #%1 reuses the name '%2' of suite #%3 — suite names must be unique (they name the report files)",
                    i, name, names[name]))
            ELSE
                LET names[name] = i
            END IF
        END IF
        IF LENGTH(cfg.suites[i].module) > 0 AND isActionSuite(cfg.suites[i]) THEN
            CALL addProblem(b, SFMT("%1 names both a \"module\" and an \"actions\" file — use one", where))
        END IF
        IF LENGTH(cfg.suites[i].module) == 0 AND NOT isActionSuite(cfg.suites[i]) THEN
            CALL addProblem(b, SFMT("%1 needs a \"module\" or an \"actions\" file", where))
        END IF
        IF LENGTH(cfg.suites[i].module) > 0 THEN
            IF NOT os.Path.exists(cfg.suites[i].module)
                AND NOT os.Path.exists(cfg.suites[i].module || ".42m") THEN
                CALL addProblem(b, SFMT("%1: module '%2' not found (is it compiled?)",
                    where, cfg.suites[i].module))
            END IF
        END IF
        IF isActionSuite(cfg.suites[i]) THEN
            IF NOT os.Path.exists(cfg.suites[i].actions) THEN
                CALL addProblem(b, SFMT("%1: action file '%2' not found", where, cfg.suites[i].actions))
            END IF
        END IF
        CALL checkConnection(b, where, cfg.suites[i].mode, cfg.suites[i].url)
        IF cfg.suites[i].timeout < 0 THEN
            CALL addProblem(b, SFMT("%1: \"timeout\" cannot be negative", where))
        END IF
    END FOR

    IF b.getLength() == 0 THEN
        RETURN NULL
    END IF
    RETURN SFMT("config '%1' is not valid:%2%3", cfgPath, ASCII 10, b.toString())
END FUNCTION

# Report every key of `o` that is not in the comma-separated `known` list.
PRIVATE FUNCTION checkKeys(b base.StringBuffer, o util.JSONObject, where STRING, known STRING)
    DEFINE i INTEGER
    DEFINE k STRING
    FOR i = 1 TO o.getLength()
        LET k = o.name(i)
        IF k.getIndexOf("$", 1) == 1 OR k.getIndexOf("_", 1) == 1 THEN
            CONTINUE FOR
        END IF
        IF NOT inList(k, known) THEN
            CALL addProblem(b, SFMT("%1: unknown key \"%2\" (known keys: %3)", where, k, known))
        END IF
    END FOR
END FUNCTION

# A suite's (or the discovery template's) connection settings.
PRIVATE FUNCTION checkConnection(b base.StringBuffer, where STRING, mode STRING, url STRING)
    IF LENGTH(mode) > 0 AND mode != "tcp" AND mode != "ua" THEN
        CALL addProblem(b, SFMT("%1: unknown \"mode\" '%2' (use tcp or ua)", where, mode))
    END IF
    IF isUa(mode) AND LENGTH(url) == 0 THEN
        CALL addProblem(b, SFMT("%1: mode ua needs a \"url\"", where))
    END IF
END FUNCTION

# TRUE if `item` is one of the comma-separated `list`.
PRIVATE FUNCTION inList(item STRING, list STRING) RETURNS BOOLEAN
    DEFINE padded STRING
    LET padded = "," || list || ","
    IF padded.getIndexOf("," || item || ",", 1) > 0 THEN
        RETURN TRUE
    END IF
    RETURN FALSE
END FUNCTION

PRIVATE FUNCTION addProblem(b base.StringBuffer, msg STRING)
    CALL b.append("  - ")
    CALL b.append(msg)
    CALL b.append(ASCII 10)
END FUNCTION

# ------------------------------------------------------------- commands ----

#+ TRUE if the suite is a JSON action file (run via jsonRunner).
PUBLIC FUNCTION isActionSuite(s SuiteCfg) RETURNS BOOLEAN
    IF LENGTH(s.actions) > 0 THEN
        RETURN TRUE
    END IF
    RETURN FALSE
END FUNCTION

#+ The shell command that runs one suite process, its output sent to logFile.
#+ The suite is told the scenario-server port: ggc connects to 6500 unless told
#+ otherwise. Every value is quoted with core.shellArg(), so a commandLine that
#+ holds quotes of its own reaches ggc intact. An empty commandLine is left out:
#+ ggc then runs `fglrun <application>`.
PUBLIC FUNCTION suiteCommand(cfg Config, s SuiteCfg, logFile STRING) RETURNS STRING
    DEFINE prog, cmd STRING
    IF isActionSuite(s) THEN
        LET prog = cfg.jsonRunner
    ELSE
        LET prog = s.module
    END IF
    IF isUa(s.mode) THEN
        LET cmd = SFMT("fglrun %1 ua --port %2 --url %3",
            core.shellArg(prog), cfg.port, core.shellArg(s.url))
    ELSE
        LET cmd = SFMT("fglrun %1 tcp --port %2", core.shellArg(prog), cfg.port)
        IF LENGTH(s.workdir) > 0 THEN
            LET cmd = cmd || " --working-directory " || core.shellArg(s.workdir)
        END IF
        IF LENGTH(s.commandLine) > 0 THEN
            LET cmd = cmd || " --command-line " || core.shellArg(s.commandLine)
        END IF
    END IF
    RETURN SFMT("%1 > %2 2>&1", cmd, core.shellArg(logFile))
END FUNCTION

#+ `names` without repeats, the first of each kept, in order. Isolate mode runs
#+ one process per name; a name listed twice would run (and count) twice.
PUBLIC FUNCTION uniqueNames(names NameList) RETURNS NameList
    DEFINE r NameList
    DEFINE seen DICTIONARY OF BOOLEAN
    DEFINE i INTEGER
    FOR i = 1 TO names.getLength()
        IF LENGTH(names[i]) == 0 THEN
            CONTINUE FOR
        END IF
        IF NOT seen.contains(names[i]) THEN
            LET seen[names[i]] = TRUE
            LET r[r.getLength() + 1] = names[i]
        END IF
    END FOR
    RETURN r
END FUNCTION

# ------------------------------------------------------------ run files ----

#+ Delete the files a previous run of `rname` left in outdir. The CLI reads
#+ `<rname>.json` and `<rname>.done` back after a suite exits, so a copy left
#+ from an earlier run would be taken for this run's results — a suite that
#+ never started would report the old run's passes.
PUBLIC FUNCTION clearRunFiles(outdir STRING, rname STRING)
    CALL deleteQuietly(SFMT("%1/%2.json", outdir, rname))
    CALL deleteQuietly(SFMT("%1/%2.junit.xml", outdir, rname))
    CALL deleteQuietly(SFMT("%1/%2.tap", outdir, rname))
    CALL deleteQuietly(SFMT("%1/%2.done", outdir, rname))
END FUNCTION

#+ Delete every per-test file an earlier isolated run of suite `name` left in
#+ outdir (`<name>.<n>.*` for any n). Without this, a suite that now has fewer
#+ tests keeps the old higher-numbered reports, and CI globs pick them up.
PUBLIC FUNCTION clearIsolatedFiles(outdir STRING, name STRING)
    DEFINE h INTEGER
    DEFINE entry STRING
    LET h = os.Path.dirOpen(outdir)
    IF h <= 0 THEN
        RETURN
    END IF
    WHILE TRUE
        LET entry = os.Path.dirNext(h)
        IF entry IS NULL THEN
            EXIT WHILE
        END IF
        IF isIsolatedFile(entry, name) THEN
            CALL deleteQuietly(os.Path.join(outdir, entry))
        END IF
    END WHILE
    CALL os.Path.dirClose(h)
END FUNCTION

#+ TRUE if `entry` is `<name>.<digits>.<ext>` for a file an isolated run writes.
PUBLIC FUNCTION isIsolatedFile(entry STRING, name STRING) RETURNS BOOLEAN
    DEFINE prefix, rest, num, ext STRING
    DEFINE dot INTEGER

    LET prefix = name || "."
    IF entry.getIndexOf(prefix, 1) != 1 THEN
        RETURN FALSE
    END IF
    LET rest = entry.subString(prefix.getLength() + 1, entry.getLength())
    LET dot = rest.getIndexOf(".", 1)
    IF dot <= 1 THEN
        RETURN FALSE
    END IF
    LET num = rest.subString(1, dot - 1)
    IF NOT num.matches("^[0-9]+$") THEN
        RETURN FALSE
    END IF
    LET ext = rest.subString(dot + 1, rest.getLength())
    CASE ext
        WHEN "json" RETURN TRUE
        WHEN "junit.xml" RETURN TRUE
        WHEN "tap" RETURN TRUE
        WHEN "done" RETURN TRUE
        WHEN "log" RETURN TRUE
    END CASE
    RETURN FALSE
END FUNCTION

#+ Remove a file, ignoring "not there" and permission problems.
PUBLIC FUNCTION deleteQuietly(path STRING)
    DEFINE ok INTEGER
    IF os.Path.exists(path) THEN
        LET ok = os.Path.delete(path)
    END IF
END FUNCTION

# -------------------------------------------------------------- results ----

#+ Fold one suite process into `agg`.
#+
#+ A process that ended without the runner's completion marker is counted as
#+ incomplete even when it left results: a crash after the last report write
#+ (in an afterAll hook, say) or a runtime error that stopped the program would
#+ otherwise pass on the strength of the tests that happened to finish first.
#+
#+ @param sr        the process's JSON report (sr.tests NULL when none was read)
#+ @param completed TRUE if the runner wrote its completion marker
#+ @param timedOut  TRUE if the CLI watchdog gave up on the process
PUBLIC FUNCTION fold(agg Summary INOUT, sr SuiteResult, completed BOOLEAN, timedOut BOOLEAN)
    IF core.isTrue(timedOut) THEN
        LET agg.timedOut = agg.timedOut + 1
    END IF
    IF NOT core.isTrue(completed) THEN
        LET agg.incomplete = agg.incomplete + 1
    END IF
    IF sr.tests IS NULL THEN
        LET agg.errors = agg.errors + 1
        RETURN
    END IF
    LET agg.tests = agg.tests + nz(sr.tests)
    LET agg.passed = agg.passed + nz(sr.passed)
    # Disjoint counts: failed = checks that did not hold, errors = could not run.
    LET agg.failed = agg.failed + nz(sr.failed)
    LET agg.errors = agg.errors + nz(sr.errors)
    LET agg.skipped = agg.skipped + nz(sr.skipped)
END FUNCTION

#+ Add the counts of `part` into `total` (the suite count is not summed).
PUBLIC FUNCTION add(total Summary INOUT, part Summary)
    LET total.tests = total.tests + part.tests
    LET total.passed = total.passed + part.passed
    LET total.failed = total.failed + part.failed
    LET total.errors = total.errors + part.errors
    LET total.skipped = total.skipped + part.skipped
    LET total.timedOut = total.timedOut + part.timedOut
    LET total.incomplete = total.incomplete + part.incomplete
END FUNCTION

#+ The CLI's exit code: 1 if any test failed or errored, or any suite process
#+ did not run to completion; 0 otherwise. (2, a setup problem, is decided
#+ before any suite runs.)
PUBLIC FUNCTION exitCode(agg Summary) RETURNS INTEGER
    IF agg.failed > 0 OR agg.errors > 0 OR agg.incomplete > 0 OR agg.timedOut > 0 THEN
        RETURN 1
    END IF
    RETURN 0
END FUNCTION

# A count read from a report, with a missing value taken as 0: in BDL x + NULL
# is NULL, and one absent field would otherwise blank the whole aggregate.
PRIVATE FUNCTION nz(v INTEGER) RETURNS INTEGER
    IF v IS NULL THEN
        RETURN 0
    END IF
    RETURN v
END FUNCTION
