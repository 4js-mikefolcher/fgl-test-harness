# fgltest.server — manage the GGC "BDL scenario server" (ggcadmin) lifecycle.
#
# The ggc BDL API is a JSON client to a separate scenario server; ggc's setup()
# only *connects* to localhost:<port> — nothing starts the server automatically.
# The harness therefore starts/stops it around a test run. Requires `ggcadmin`
# on PATH and ggc.jar on CLASSPATH (both provided by sourcing envggc).

PACKAGE com.fourjs.fgltest

IMPORT os
IMPORT FGL com.fourjs.fgltest.core

PUBLIC CONSTANT DEFAULT_PORT = 6500
PUBLIC CONSTANT MAX_PORT = 65535

#+ TRUE if `ggcadmin` can be found on PATH. Used to turn "could not start the
#+ scenario server" into an actionable message: by far the most common cause is
#+ that the GGC environment was never sourced.
PUBLIC FUNCTION haveGgcAdmin() RETURNS BOOLEAN
    DEFINE st SMALLINT
    # `ggcadmin --version` is a cheap, side-effect-free probe. A shell that
    # cannot find the command exits non-zero, which is exactly the signal we
    # want, and output is discarded so the console stays clean.
    RUN "ggcadmin --version > \"" || nullDevice() || "\" 2>&1" RETURNING st
    RETURN (st == 0)
END FUNCTION

#+ The platform's discard device, so probe output is thrown away on both
#+ POSIX shells and Windows cmd.
PRIVATE FUNCTION nullDevice() RETURNS STRING
    IF os.Path.separator() == "\\" THEN
        RETURN "NUL"
    END IF
    RETURN "/dev/null"
END FUNCTION

#+ TRUE if a TCP server is accepting connections on localhost:<port>.
#+
#+ @param port the TCP port to probe
#+ @return TRUE if a connection can be opened
PUBLIC FUNCTION isUp(port INTEGER) RETURNS BOOLEAN
    DEFINE ch base.Channel
    LET ch = base.Channel.create()
    TRY
        CALL ch.openClientSocket("localhost", port, "u", 1)
        CALL ch.close()
        RETURN TRUE
    CATCH
        RETURN FALSE
    END TRY
END FUNCTION

#+ Start the ggcadmin BDL scenario server if not already up, and wait until it
#+ is listening.
#+
#+ @param port        listen port (e.g. 6500)
#+ @param idleSecs    idle seconds before the server auto-exits (-1 = never)
#+ @param timeoutSecs max seconds to wait for the port to open
#+ @return TRUE once the server is listening, FALSE on timeout
PUBLIC FUNCTION start(port INTEGER, idleSecs INTEGER, timeoutSecs INTEGER) RETURNS BOOLEAN
    DEFINE up, started BOOLEAN
    CALL ensure(port, idleSecs, timeoutSecs) RETURNING up, started
    RETURN up
END FUNCTION

#+ Make sure a scenario server is listening on <port>, starting one only if
#+ nothing is, and say whether this call started it.
#+
#+ Only a server you started is yours to stop: one that was already listening
#+ may be a developer's own, or serving another test run on the same machine,
#+ and stopping it would kill that run's sessions.
#+
#+ @param port        listen port (e.g. 6500)
#+ @param idleSecs    idle seconds before a started server auto-exits (-1 = never)
#+ @param timeoutSecs max seconds to wait for the port to open
#+ @return TRUE once a server is listening; TRUE if this call started it
PUBLIC FUNCTION ensure(port INTEGER, idleSecs INTEGER, timeoutSecs INTEGER)
    RETURNS (BOOLEAN, BOOLEAN)
    DEFINE i INTEGER
    IF isUp(port) THEN
        RETURN TRUE, FALSE
    END IF
    # Redirect the server process's stdout/stderr to a log so it does not clutter
    # the caller's console. Log dir from FGLTEST_OUTDIR (set by the CLI), else cwd.
    RUN SFMT("ggcadmin startbdlserver -p %1 -i %2 > %3 2>&1",
        port, idleSecs, core.shellArg(logDir() || "/ggcserver.log")) WITHOUT WAITING
    FOR i = 1 TO timeoutSecs
        IF isUp(port) THEN
            RETURN TRUE, TRUE
        END IF
        SLEEP 1
    END FOR
    IF isUp(port) THEN
        RETURN TRUE, TRUE
    END IF
    RETURN FALSE, FALSE
END FUNCTION

#+ Stop the ggcadmin BDL scenario server on <port> (no-op if not running).
#+ Call it only for a server you started (see ensure()).
#+
#+ @param port the server port to stop
PUBLIC FUNCTION stop(port INTEGER)
    IF isUp(port) THEN
        RUN SFMT("ggcadmin stopbdlserver -p %1 >> %2 2>&1", port,
            core.shellArg(logDir() || "/ggcserver.log"))
    END IF
END FUNCTION

# Log directory for the server process (FGLTEST_OUTDIR, else current directory).
PRIVATE FUNCTION logDir() RETURNS STRING
    DEFINE d STRING
    LET d = fgl_getenv("FGLTEST_OUTDIR")
    IF d IS NULL OR LENGTH(d) == 0 THEN
        RETURN "."
    END IF
    RETURN d
END FUNCTION
