# fgltest.ggcdriver — the default Driver, delegating to IMPORT FGL ggc.
#
# GgcDriver is a stateless adapter: it holds no interaction state itself (the
# real session/current-field state lives in the ggc engine); it just forwards
# each Driver method to the corresponding ggc.* call.

PACKAGE com.fourjs.fgltest

IMPORT FGL ggc
IMPORT FGL com.fourjs.fgltest.driver
IMPORT FGL com.fourjs.fgltest.core
IMPORT xml

#+ Concrete GGC-backed driver.
PUBLIC TYPE GgcDriver RECORD
    ready BOOLEAN
END RECORD

# Module-static instance: an interface variable references a concrete variable,
# so that concrete must outlive the interface. A temporary (function return)
# would dangle (-8083 null pointer at first use), hence a stable module var.
PRIVATE DEFINE m_instance GgcDriver

#+ Return the shared GgcDriver as a Driver interface, backed by a stable
#+ module-static instance (safe to store in fgltest.core).
PUBLIC FUNCTION asDriver() RETURNS driver.Driver
    DEFINE d driver.Driver
    LET m_instance.ready = TRUE
    LET d = m_instance
    RETURN d
END FUNCTION

#+ Put the ggc library into non-fatal mode. MUST be called from inside the
#+ scenario (after the session is connected), because it also sends a request to
#+ the scenario server.
#+
#+ By default ggc's internal checkStatus() answers ANY error — a mistyped field,
#+ table or action name included — with `EXIT PROGRAM 1`. A process exit cannot
#+ be trapped by TRY/CATCH or WHENEVER, so one typo would kill the whole run and
#+ lose every result. With exceptions off, ggc records the failure in the public
#+ ggc.statusCode / ggc.statusMsg instead and returns; check() below turns that
#+ into a per-test driver error. (ggc.CLOSED still exits inside ggc: the
#+ application under test is gone and nothing further can be driven.)
PUBLIC FUNCTION beNonFatal()
    CALL ggc.throwExceptions(FALSE)
    LET ggc.statusCode = ggc.SUCCESS
END FUNCTION

# Inspect ggc's status after a call and convert a non-success into a driver
# error on the current test. Resets statusCode so the next call starts clean.
PRIVATE FUNCTION check(op STRING, target STRING)
    IF ggc.statusCode == ggc.SUCCESS THEN
        RETURN
    END IF
    CALL core.setDriverError(SFMT("(GGC-%1) %2 [%3 '%4']",
        ggc.statusCode, ggc.statusMsg, op, target))
    # The application can no longer be driven: no later test can run, so the
    # runner stops scheduling.
    IF sessionOver(ggc.statusCode, ggc.statusMsg) THEN
        CALL core.setFatal()
    END IF
    LET ggc.statusCode = ggc.SUCCESS
END FUNCTION

#+ TRUE if a GGC status means the application under test can no longer be
#+ driven: the session is gone (CLOSED, PREMATURE_SCENARIO_END), or the program
#+ has ended. GGC reports the latter as ILLEGAL_STATE, but uses that code for
#+ other states as well ("the DVM is not in interactive state but VM
#+ processing", "client already started"), so only its "already ended" message
#+ counts: a busy application must not end the whole run.
PUBLIC FUNCTION sessionOver(code INTEGER, msg STRING) RETURNS BOOLEAN
    IF code == ggc.CLOSED OR code == ggc.PREMATURE_SCENARIO_END THEN
        RETURN TRUE
    END IF
    IF code == ggc.ILLEGAL_STATE AND msg.toLowerCase().getIndexOf("already ended", 1) > 0 THEN
        RETURN TRUE
    END IF
    RETURN FALSE
END FUNCTION

# TRUE when the current test has already failed at the driver level, so this
# call must be skipped: the session is in an unknown state and running on would
# produce cascading, misleading results.
PRIVATE FUNCTION skip() RETURNS BOOLEAN
    RETURN core.hasDriverError()
END FUNCTION

FUNCTION (self GgcDriver) focus(fieldName STRING)
    IF skip() THEN RETURN END IF
    CALL ggc.setFocus(fieldName)
    CALL check("focus", fieldName)
END FUNCTION

FUNCTION (self GgcDriver) enter(value STRING)
    IF skip() THEN RETURN END IF
    CALL ggc.setValue(value)
    CALL check("enter", value)
END FUNCTION

FUNCTION (self GgcDriver) setField(fieldName STRING, value STRING)
    IF skip() THEN RETURN END IF
    CALL ggc.setFieldValue(fieldName, value)
    CALL check("fill", fieldName)
END FUNCTION

FUNCTION (self GgcDriver) action(name STRING)
    IF skip() THEN RETURN END IF
    CALL ggc.action(name)
    CALL check("action", name)
END FUNCTION

FUNCTION (self GgcDriver) press(keyName STRING)
    IF skip() THEN RETURN END IF
    CALL ggc.key(keyName)
    CALL check("key", keyName)
END FUNCTION

FUNCTION (self GgcDriver) pause(ms INTEGER)
    IF skip() THEN RETURN END IF
    CALL ggc.wait(ms)
    CALL check("pause", ms)
END FUNCTION

FUNCTION (self GgcDriver) selectRow(tableName STRING, row INTEGER)
    IF skip() THEN RETURN END IF
    CALL ggc.setRowFocus(tableName, row)
    CALL check("selectRow", tableName)
END FUNCTION

FUNCTION (self GgcDriver) focusCell(tableName STRING, columnName STRING, row INTEGER)
    IF skip() THEN RETURN END IF
    CALL ggc.setCellFocus(tableName, columnName, row)
    CALL check("focusCell", tableName)
END FUNCTION

FUNCTION (self GgcDriver) fieldValue(fieldName STRING) RETURNS STRING
    DEFINE v STRING
    IF skip() THEN RETURN NULL END IF
    LET v = ggc.getFieldValue(fieldName)
    CALL check("fieldValue", fieldName)
    RETURN v
END FUNCTION

FUNCTION (self GgcDriver) currentValue() RETURNS STRING
    DEFINE v STRING
    IF skip() THEN RETURN NULL END IF
    LET v = ggc.getValue()
    CALL check("currentValue", "")
    RETURN v
END FUNCTION

FUNCTION (self GgcDriver) formName() RETURNS STRING
    DEFINE v STRING
    IF skip() THEN RETURN NULL END IF
    LET v = ggc.getFormName()
    CALL check("formName", "")
    RETURN v
END FUNCTION

FUNCTION (self GgcDriver) formTitle() RETURNS STRING
    DEFINE v STRING
    IF skip() THEN RETURN NULL END IF
    LET v = ggc.getFormTitle()
    CALL check("formTitle", "")
    RETURN v
END FUNCTION

FUNCTION (self GgcDriver) windowName() RETURNS STRING
    DEFINE v STRING
    IF skip() THEN RETURN NULL END IF
    LET v = ggc.getWindowName()
    CALL check("windowName", "")
    RETURN v
END FUNCTION

FUNCTION (self GgcDriver) windowTitle() RETURNS STRING
    DEFINE v STRING
    IF skip() THEN RETURN NULL END IF
    LET v = ggc.getWindowTitle()
    CALL check("windowTitle", "")
    RETURN v
END FUNCTION

FUNCTION (self GgcDriver) isActionActive(name STRING) RETURNS BOOLEAN
    DEFINE v BOOLEAN
    IF skip() THEN RETURN FALSE END IF
    LET v = ggc.isActionActive(name)
    CALL check("isActionActive", name)
    RETURN v
END FUNCTION

FUNCTION (self GgcDriver) cellValue(tableName STRING, columnName STRING, row INTEGER) RETURNS STRING
    DEFINE v STRING
    IF skip() THEN RETURN NULL END IF
    LET v = ggc.getColumnValue(tableName, columnName, row)
    CALL check("cellValue", tableName)
    RETURN v
END FUNCTION

FUNCTION (self GgcDriver) rowCount(tableName STRING) RETURNS INTEGER
    DEFINE v INTEGER
    IF skip() THEN RETURN 0 END IF
    LET v = ggc.getTableSize(tableName)
    CALL check("rowCount", tableName)
    RETURN v
END FUNCTION

FUNCTION (self GgcDriver) currentRow(tableName STRING) RETURNS INTEGER
    DEFINE v INTEGER
    IF skip() THEN RETURN 0 END IF
    LET v = ggc.getCurrentRow(tableName)
    CALL check("currentRow", tableName)
    RETURN v
END FUNCTION

FUNCTION (self GgcDriver) actions() RETURNS driver.ActionList
    DEFINE a driver.ActionList
    IF skip() THEN RETURN a END IF
    LET a = ggc.getActions()
    CALL check("actions", "")
    RETURN a
END FUNCTION

FUNCTION (self GgcDriver) auiTree() RETURNS xml.DomDocument
    DEFINE doc xml.DomDocument
    IF skip() THEN RETURN doc END IF
    LET doc = ggc.getAuiTree()
    CALL check("auiTree", "")
    RETURN doc
END FUNCTION

FUNCTION (self GgcDriver) auiPart(selector STRING) RETURNS xml.DomDocument
    DEFINE doc xml.DomDocument
    IF skip() THEN RETURN doc END IF
    LET doc = ggc.getAuiTreePart(selector)
    CALL check("auiPart", selector)
    RETURN doc
END FUNCTION
