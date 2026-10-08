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

# The shape of a config, object by object: each key and the JSON type its value
# must have (see core.checkShape). Any other key is reported — a typo'd key
# would otherwise be dropped silently by the JSON parser — and so is a value of
# the wrong type, which the parser would turn into NULL.
PRIVATE CONSTANT TOP_SPEC = "port:int,reporters:string,outdir:string,jsonRunner:string,isolate:boolean,timeout:int,discover:object,suites:array"
PRIVATE CONSTANT SUITE_SPEC = "name:string,module:string,actions:string,mode:string,workdir:string,commandLine:string,url:string,isolate:boolean,timeout:int"
PRIVATE CONSTANT DISCOVER_SPEC = "dir:string,mode:string,workdir:string,commandLine:string,url:string,modulePattern:string"
PRIVATE CONSTANT REPORTERS = "console,junit,tap,json"

# The files a suite writes into outdir, all named after it.
PRIVATE CONSTANT RUN_FILE_EXTS = ".json,.junit.xml,.tap,.done,.log,.tests,.list.log"

# The problems normalize() found, one "  - " line each (see expand()).
PRIVATE DEFINE m_problems base.StringBuffer

# The report types fgltest writes; any other file in outdir that is named
# after a suite (its log, its test list) is fgltest's own by convention.
PRIVATE CONSTANT REPORT_EXTS = ".json,.junit.xml,.tap,.done"

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

#+ Apply defaults, expand environment variables and resolve every relative
#+ path in a parsed config.
#+
#+ Relative paths resolve against the config file's own directory, not the
#+ current one, so a config means the same thing wherever the CLI is started
#+ from — `fglpkg bdl` starts it inside the installed package.
#+
#+ `$NAME` and `${NAME}` in a path, a command line or a URL are replaced by the
#+ environment variable's value (see expandEnv), the same way on every
#+ platform; the shell no longer sees them, since every value is passed on
#+ quoted literally (cmd.exe on Windows does still expand `%NAME%`, inside
#+ quotes or not). A variable that is not set is reported.
#+
#+ The FGLTEST_PORT environment variable, when set, overrides "port": concurrent
#+ runs on one machine (CI jobs on a shared runner) can then each use their own
#+ scenario server without editing the config.
#+
#+ @param cfg        the parsed config, updated in place
#+ @param cfgPath    path of the config file
#+ @param programDir directory of the fgltest program (holds the default jsonRunner)
#+ It carries on past a problem, so that checkConfig() can list it along with
#+ every other one: pass the result to checkConfig().
#+
#+ @return NULL, or the problems found, one "  - " line each
PUBLIC FUNCTION normalize(cfg Config INOUT, cfgPath STRING, programDir STRING)
    RETURNS STRING
    DEFINE dir, env, what STRING
    DEFINE i, p INTEGER

    LET m_problems = base.StringBuffer.create()
    LET env = fgl_getenv("FGLTEST_PORT")
    IF LENGTH(env) > 0 THEN
        LET p = env   -- a non-number converts to NULL
        IF p IS NULL OR p <= 0 OR p > server.MAX_PORT THEN
            CALL core.problem(m_problems, SFMT("FGLTEST_PORT must be a port number (1-%1), not '%2'",
                server.MAX_PORT, env))
        ELSE
            LET cfg.port = p
        END IF
    END IF
    # Only an absent "port" (which parses as NULL, not 0) takes the default:
    # a zero or negative one is a mistake to report, not to paper over.
    IF cfg.port IS NULL THEN
        LET cfg.port = server.DEFAULT_PORT
    END IF
    IF cfg.port <= 0 OR cfg.port > server.MAX_PORT THEN
        CALL core.problem(m_problems, SFMT("\"port\" must be a port number (1-%1), not %2",
            server.MAX_PORT, cfg.port))
    END IF
    IF LENGTH(cfg.reporters) == 0 THEN
        LET cfg.reporters = "console,junit,json"
    END IF
    LET cfg.reporters = noSpaces(cfg.reporters)   -- "console, junit" is fine

    LET cfg.outdir = expand(cfg.outdir, "\"outdir\"")
    LET cfg.jsonRunner = expand(cfg.jsonRunner, "\"jsonRunner\"")
    LET cfg.discover.dir = expand(cfg.discover.dir, "\"discover\".dir")
    LET cfg.discover.workdir = expand(cfg.discover.workdir, "\"discover\".workdir")
    LET cfg.discover.commandLine = expand(cfg.discover.commandLine, "\"discover\".commandLine")
    LET cfg.discover.url = expand(cfg.discover.url, "\"discover\".url")
    FOR i = 1 TO cfg.suites.getLength()
        LET what = SFMT("suite #%1", i)
        LET cfg.suites[i].module = expand(cfg.suites[i].module, what || " module")
        LET cfg.suites[i].actions = expand(cfg.suites[i].actions, what || " actions")
        LET cfg.suites[i].workdir = expand(cfg.suites[i].workdir, what || " workdir")
        LET cfg.suites[i].commandLine = expand(cfg.suites[i].commandLine, what || " commandLine")
        LET cfg.suites[i].url = expand(cfg.suites[i].url, what || " url")
    END FOR
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
    IF m_problems.getLength() == 0 THEN
        RETURN NULL
    END IF
    RETURN m_problems.toString()
END FUNCTION

# expandEnv() for normalize(). A value naming an unset variable is reported
# and kept as written, so later messages show it as the user wrote it.
PRIVATE FUNCTION expand(v STRING, what STRING) RETURNS STRING
    DEFINE r, unset STRING
    CALL expandEnv(v) RETURNING r, unset
    IF unset IS NOT NULL THEN
        CALL core.problem(m_problems,
            SFMT("%1 uses the environment variable %2, which is not set", what, unset))
        RETURN v
    END IF
    RETURN r
END FUNCTION

#+ Expand environment variables in a config value: `$NAME` and `${NAME}` become
#+ the variable's value and `$$` a single `$`; a `$` not followed by a name
#+ (`$5`, a lone `$`) is kept as it is.
#+
#+ @return the expanded value, and the name of the first variable that is not
#+         set or is empty (NULL if none) — a path built from a missing
#+         variable is a mistake to report, not an empty string to use
PUBLIC FUNCTION expandEnv(s STRING) RETURNS (STRING, STRING)
    DEFINE r base.StringBuffer
    DEFINE start, d, e, j, len INTEGER
    DEFINE name, missing, v STRING

    IF s IS NULL THEN
        RETURN NULL, NULL
    END IF
    # Only "$", "{", "}" and name characters — all ASCII — are inspected, and
    # text is copied with subString(), so multibyte values pass through intact
    # under either FGL_LENGTH_SEMANTICS.
    LET r = base.StringBuffer.create()
    LET len = s.getLength()
    LET start = 1
    WHILE start <= len
        LET d = s.getIndexOf("$", start)
        IF d == 0 THEN
            EXIT WHILE
        END IF
        IF d > start THEN
            CALL r.append(s.subString(start, d - 1))
        END IF
        LET name = NULL
        LET start = d + 1
        IF d < len THEN
            CASE s.getCharAt(d + 1)
                WHEN "$"
                    CALL r.append("$")
                    LET start = d + 2
                    CONTINUE WHILE
                WHEN "{"
                    LET e = s.getIndexOf("}", d + 2)
                    IF e > d + 2 THEN
                        LET name = s.subString(d + 2, e - 1)
                        LET start = e + 1
                    END IF
                OTHERWISE
                    LET j = d + 1
                    WHILE j <= len
                        IF NOT isNameChar(s.getCharAt(j), j == d + 1) THEN
                            EXIT WHILE
                        END IF
                        LET j = j + 1
                    END WHILE
                    IF j > d + 1 THEN
                        LET name = s.subString(d + 1, j - 1)
                        LET start = j
                    END IF
            END CASE
        END IF
        IF name IS NULL THEN
            CALL r.append("$")   -- not a variable reference: keep it
            CONTINUE WHILE
        END IF
        LET v = fgl_getenv(name)
        IF LENGTH(v) == 0 THEN
            IF missing IS NULL THEN
                LET missing = name
            END IF
        ELSE
            CALL r.append(v)
        END IF
    END WHILE
    IF start <= len THEN
        CALL r.append(s.subString(start, len))
    END IF
    RETURN r.toString(), missing
END FUNCTION

# A character of a variable name: a letter or "_", or a digit after the first.
PRIVATE FUNCTION isNameChar(c STRING, first BOOLEAN) RETURNS BOOLEAN
    IF c IS NULL THEN
        RETURN FALSE
    END IF
    IF core.isTrue(first) THEN
        RETURN c.matches("^[A-Za-z_]$")
    END IF
    RETURN c.matches("^[A-Za-z0-9_]$")
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
#+ "comandLine" silently — keys match without regard to case, as the parser
#+ matches them), a value of the wrong type ("timeout": "30s" would become
#+ NULL), a suite without a name or reusing another's (suites write their
#+ reports under their name), a suite whose reports would overwrite the config
#+ or an action file, both or neither of module/actions, a module or action
#+ file that does not exist, an unknown mode or reporter, a ua suite without a
#+ url, a negative timeout. Call it after normalize(), which resolves the paths
#+ it checks.
#+
#+ @param cfgPath the config file (for the message)
#+ @param text    the config's JSON text (for the key and type checks)
#+ @param cfg     the parsed, normalized config
#+ @param prior   the problems normalize() found (NULL if none), listed first
#+ @return NULL when the config is valid, else a multi-line description
PUBLIC FUNCTION checkConfig(cfgPath STRING, text STRING, cfg Config, prior STRING)
    RETURNS STRING
    DEFINE b base.StringBuffer
    DEFINE obj, o util.JSONObject
    DEFINE arr util.JSONArray
    DEFINE tok base.StringTokenizer
    DEFINE names DICTIONARY OF INTEGER
    DEFINE i INTEGER
    DEFINE t, where, name, k, clash STRING

    LET b = base.StringBuffer.create()
    CALL b.append(prior)
    TRY
        LET obj = util.JSONObject.parse(text)
    CATCH
        RETURN SFMT("config '%1' must be a JSON object", cfgPath)
    END TRY
    CALL core.checkShape(b, obj, "the config", TOP_SPEC)
    # Check a type before reading through it: assigning an object to the wrong
    # class is a -1260 that TRY/CATCH does not catch.
    LET k = core.jsonKey(obj, "discover")
    IF k IS NOT NULL AND obj.getType(k) == "OBJECT" THEN
        LET o = obj.get(k)
        CALL core.checkShape(b, o, "\"discover\"", DISCOVER_SPEC)
    END IF
    LET k = core.jsonKey(obj, "suites")
    IF k IS NOT NULL AND obj.getType(k) == "ARRAY" THEN
        LET arr = obj.get(k)
        FOR i = 1 TO arr.getLength()
            IF arr.getType(i) == "OBJECT" THEN
                LET o = arr.get(i)
                CALL core.checkShape(b, o, SFMT("suite #%1", i), SUITE_SPEC)
            ELSE
                CALL core.problem(b, SFMT("suite #%1 must be an object", i))
            END IF
        END FOR
    END IF

    LET tok = base.StringTokenizer.create(cfg.reporters, ",")
    WHILE tok.hasMoreTokens()
        LET t = tok.nextToken()
        IF LENGTH(t) > 0 AND NOT inList(t, REPORTERS) THEN
            CALL core.problem(b, SFMT("\"reporters\": unknown reporter '%1' (use %2)", t, REPORTERS))
        END IF
    END WHILE
    IF cfg.timeout < 0 THEN
        CALL core.problem(b, "\"timeout\" cannot be negative")
    END IF

    IF LENGTH(cfg.discover.dir) > 0 THEN
        IF NOT hasDollar(cfg.discover.dir) AND NOT os.Path.isDirectory(cfg.discover.dir) THEN
            CALL core.problem(b, SFMT("\"discover\": directory '%1' not found", cfg.discover.dir))
        END IF
        CALL checkConnection(b, "\"discover\"", cfg.discover.mode, cfg.discover.url)
    END IF

    FOR i = 1 TO cfg.suites.getLength()
        LET name = cfg.suites[i].name
        LET where = SFMT("suite #%1", i)
        IF LENGTH(name) == 0 THEN
            CALL core.problem(b, SFMT("%1 has no \"name\"", where))
        ELSE
            LET where = SFMT("suite '%1'", name)
            IF names.contains(name) THEN
                CALL core.problem(b, SFMT("suite #%1 reuses the name '%2' of suite #%3 — suite names must be unique (they name the report files)",
                    i, name, names[name]))
            ELSE
                LET names[name] = i
            END IF
            LET clash = outputClash(cfg, cfgPath, name)
            IF clash IS NOT NULL THEN
                CALL core.problem(b, SFMT("%1: %2", where, clash))
            END IF
        END IF
        IF LENGTH(cfg.suites[i].module) > 0 AND isActionSuite(cfg.suites[i]) THEN
            CALL core.problem(b, SFMT("%1 names both a \"module\" and an \"actions\" file — use one", where))
        END IF
        IF LENGTH(cfg.suites[i].module) == 0 AND NOT isActionSuite(cfg.suites[i]) THEN
            CALL core.problem(b, SFMT("%1 needs a \"module\" or an \"actions\" file", where))
        END IF
        # A value still holding a "$" names an unset variable, already reported.
        IF LENGTH(cfg.suites[i].module) > 0 AND NOT hasDollar(cfg.suites[i].module) THEN
            IF NOT os.Path.exists(cfg.suites[i].module)
                AND NOT os.Path.exists(cfg.suites[i].module || ".42m") THEN
                CALL core.problem(b, SFMT("%1: module '%2' not found (is it compiled?)",
                    where, cfg.suites[i].module))
            END IF
        END IF
        IF isActionSuite(cfg.suites[i]) AND NOT hasDollar(cfg.suites[i].actions) THEN
            IF NOT os.Path.exists(cfg.suites[i].actions) THEN
                CALL core.problem(b, SFMT("%1: action file '%2' not found", where, cfg.suites[i].actions))
            END IF
        END IF
        CALL checkConnection(b, where, cfg.suites[i].mode, cfg.suites[i].url)
        IF cfg.suites[i].timeout < 0 THEN
            CALL core.problem(b, SFMT("%1: \"timeout\" cannot be negative", where))
        END IF
    END FOR

    IF b.getLength() == 0 THEN
        RETURN NULL
    END IF
    RETURN SFMT("config '%1' is not valid:%2%3", cfgPath, ASCII 10, b.toString())
END FUNCTION

#+ Why suite `name` may not write its files into cfg.outdir, or NULL if it may.
#+
#+ A suite's reports and log are named after it, and the CLI deletes stale
#+ copies before every run; a name that turns one of them into the config file,
#+ an action file, the summary or the scenario-server log would destroy that
#+ file before the suite even starts. Nor may a report name an existing file
#+ that is not an fgltest report — an `orders.tap` of the user's beside a suite
#+ called "orders", or the project's `fglpkg.json` beside one called "fglpkg"
#+ (see isOwnReport). Logs and test lists named after a suite are fgltest's.
PUBLIC FUNCTION outputClash(cfg Config, cfgPath STRING, name STRING) RETURNS STRING
    DEFINE tok base.StringTokenizer
    DEFINE f STRING
    DEFINE j INTEGER

    IF LENGTH(name) == 0 THEN
        RETURN NULL
    END IF
    IF name.getIndexOf("/", 1) > 0 OR name.getIndexOf("\\", 1) > 0 THEN
        RETURN "a suite name cannot contain a path separator: it names the report files"
    END IF
    IF name == "fgltest.summary" THEN
        RETURN "the name 'fgltest.summary' is reserved: its report would replace fgltest.summary.json"
    END IF
    IF name == "ggcserver" THEN
        RETURN "the name 'ggcserver' is reserved: its log would replace the scenario server's ggcserver.log"
    END IF
    LET tok = base.StringTokenizer.create(RUN_FILE_EXTS, ",")
    WHILE tok.hasMoreTokens()
        LET f = os.Path.join(cfg.outdir, name || tok.nextToken())
        IF NOT os.Path.exists(f) THEN
            CONTINUE WHILE
        END IF
        IF sameFile(f, cfgPath) THEN
            RETURN SFMT("its report '%1' would replace the config file — rename the suite or set \"outdir\"", f)
        END IF
        FOR j = 1 TO cfg.suites.getLength()
            IF isActionSuite(cfg.suites[j]) THEN
                IF sameFile(f, cfg.suites[j].actions) THEN
                    RETURN SFMT("its report '%1' would replace the action file of suite '%2' — rename the suite or set \"outdir\"",
                        f, cfg.suites[j].name)
                END IF
            END IF
        END FOR
        IF NOT isOwnReport(f) THEN
            RETURN SFMT("'%1' exists and is not an fgltest report — it would be deleted or overwritten; rename the suite or set \"outdir\"", f)
        END IF
    END WHILE
    RETURN NULL
END FUNCTION

#+ TRUE unless `path` is a report-type file (.json, .junit.xml, .tap, .done)
#+ that fgltest did not write: a JSON report has "suite" and "cases", JUnit
#+ has <testsuites>, TAP starts "TAP version", a marker reads "done". Other
#+ files are not judged (TRUE).
PUBLIC FUNCTION isOwnReport(path STRING) RETURNS BOOLEAN
    DEFINE txt, first STRING
    DEFINE o util.JSONObject

    IF NOT isReportFile(path) OR NOT os.Path.exists(path) THEN
        RETURN TRUE
    END IF
    LET txt = readText(path)
    IF txt IS NULL THEN
        RETURN FALSE
    END IF
    LET first = txt
    IF txt.getIndexOf(ASCII 10, 1) > 0 THEN
        LET first = txt.subString(1, txt.getIndexOf(ASCII 10, 1) - 1)
    END IF
    CASE
        WHEN endsWithText(path, ".done")
            RETURN (first == "done")
        WHEN endsWithText(path, ".tap")
            RETURN (first.getIndexOf("TAP version", 1) == 1)
        WHEN endsWithText(path, ".junit.xml")
            RETURN (txt.getIndexOf("<testsuites", 1) > 0)
        WHEN endsWithText(path, ".json")
            TRY
                LET o = util.JSONObject.parse(txt)
            CATCH
                RETURN FALSE
            END TRY
            RETURN (o.has("suite") AND o.has("cases"))
    END CASE
    RETURN TRUE
END FUNCTION

PRIVATE FUNCTION isReportFile(path STRING) RETURNS BOOLEAN
    DEFINE tok base.StringTokenizer
    LET tok = base.StringTokenizer.create(REPORT_EXTS, ",")
    WHILE tok.hasMoreTokens()
        IF endsWithText(path, tok.nextToken()) THEN
            RETURN TRUE
        END IF
    END WHILE
    RETURN FALSE
END FUNCTION

PRIVATE FUNCTION endsWithText(s STRING, suffix STRING) RETURNS BOOLEAN
    IF suffix.getLength() > s.getLength() THEN
        RETURN FALSE
    END IF
    RETURN (s.subString(s.getLength() - suffix.getLength() + 1, s.getLength()) == suffix)
END FUNCTION

# A file's whole text (NULL if it cannot be read).
PRIVATE FUNCTION readText(path STRING) RETURNS STRING
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

# TRUE if a config value still holds a "$" (an unset variable left as written).
PRIVATE FUNCTION hasDollar(v STRING) RETURNS BOOLEAN
    IF v.getIndexOf("$", 1) > 0 THEN
        RETURN TRUE
    END IF
    RETURN FALSE
END FUNCTION

PRIVATE FUNCTION sameFile(a STRING, b STRING) RETURNS BOOLEAN
    IF NOT os.Path.exists(a) OR NOT os.Path.exists(b) THEN
        RETURN FALSE
    END IF
    RETURN core.isTrue(os.Path.isSameFile(a, b))
END FUNCTION

# A suite's (or the discovery template's) connection settings.
PRIVATE FUNCTION checkConnection(b base.StringBuffer, where STRING, mode STRING, url STRING)
    IF LENGTH(mode) > 0 AND mode != "tcp" AND mode != "ua" THEN
        CALL core.problem(b, SFMT("%1: unknown \"mode\" '%2' (use tcp or ua)", where, mode))
    END IF
    IF isUa(mode) AND LENGTH(url) == 0 THEN
        CALL core.problem(b, SFMT("%1: mode ua needs a \"url\"", where))
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

#+ Delete every file a previous run of `rname` left in outdir: its reports,
#+ completion marker, log and test list. The CLI reads `<rname>.json` and
#+ `<rname>.done` back after a suite exits, so a copy left from an earlier run
#+ would be taken for this run's results — a suite that never started would
#+ report the old run's passes. A report-type file fgltest did not write is
#+ left alone and reported (see isOwnReport).
#+
#+ @return NULL, or which file could not (or may not) be removed
PUBLIC FUNCTION clearRunFiles(outdir STRING, rname STRING) RETURNS STRING
    DEFINE tok base.StringTokenizer
    DEFINE err STRING
    LET tok = base.StringTokenizer.create(RUN_FILE_EXTS, ",")
    WHILE tok.hasMoreTokens() AND err IS NULL
        LET err = removeRunFile(SFMT("%1/%2%3", outdir, rname, tok.nextToken()))
    END WHILE
    RETURN err
END FUNCTION

# removeFile(), but only for a file fgltest wrote.
PRIVATE FUNCTION removeRunFile(path STRING) RETURNS STRING
    IF NOT isOwnReport(path) THEN
        RETURN SFMT("refusing to remove '%1': it is not an fgltest report", path)
    END IF
    RETURN removeFile(path)
END FUNCTION

#+ Delete every per-test file an earlier isolated run of suite `name` left in
#+ outdir (`<name>.<n>.*` for any n). Without this, a suite that now has fewer
#+ tests, or now runs whole, keeps old per-test reports a CI glob picks up.
#+
#+ @return NULL, or which file could not be removed
PUBLIC FUNCTION clearIsolatedFiles(outdir STRING, name STRING) RETURNS STRING
    DEFINE h INTEGER
    DEFINE entry, err STRING
    LET h = os.Path.dirOpen(outdir)
    IF h <= 0 THEN
        RETURN NULL
    END IF
    WHILE TRUE
        LET entry = os.Path.dirNext(h)
        IF entry IS NULL THEN
            EXIT WHILE
        END IF
        IF isIsolatedFile(entry, name) THEN
            LET err = removeRunFile(os.Path.join(outdir, entry))
            IF err IS NOT NULL THEN
                EXIT WHILE
            END IF
        END IF
    END WHILE
    CALL os.Path.dirClose(h)
    RETURN err
END FUNCTION

#+ Remove a file. NULL if it is gone afterwards (or was never there), else a
#+ message: a stale report that survives would be read back as new results.
PUBLIC FUNCTION removeFile(path STRING) RETURNS STRING
    DEFINE ok INTEGER
    IF NOT os.Path.exists(path) THEN
        RETURN NULL
    END IF
    LET ok = os.Path.delete(path)
    IF os.Path.exists(path) THEN
        RETURN SFMT("cannot remove '%1'", path)
    END IF
    RETURN NULL
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
