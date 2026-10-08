# fakedriver — an in-memory Driver used by the harness's own test suite.
#
# This is what the `Driver` INTERFACE seam is for: fgltest's logic (AUI parsing,
# matchers, reporters, the action-file interpreter) can be exercised with no GGC
# engine, no scenario server and no application under test — so `make check`
# runs anywhere a compiler does.
#
# It is a test double, not part of the shipped package: it lives outside
# com/fourjs/fgltest/ so `fglpkg pack` never picks it up.

IMPORT xml
IMPORT FGL com.fourjs.fgltest.driver

PUBLIC TYPE FakeDriver RECORD
    ready BOOLEAN
END RECORD

# Interface variables reference a concrete variable that must outlive them, so
# the instance is module-static (a function-local would dangle -> -8083).
PRIVATE DEFINE m_instance FakeDriver

# --- scripted state -------------------------------------------------------
PRIVATE DEFINE m_aui STRING
# The current-window tree auiPart() returns (NULL = the whole tree), and the
# selector it was last asked for.
PRIVATE DEFINE m_auiPart, m_lastSelector STRING
PRIVATE DEFINE m_formName, m_formTitle, m_windowName, m_windowTitle STRING
PRIVATE DEFINE m_fieldValues DICTIONARY OF STRING
PRIVATE DEFINE m_current STRING
PRIVATE DEFINE m_actions driver.ActionList
PRIVATE DEFINE m_rowCount, m_currentRow INTEGER
PRIVATE DEFINE m_cells DICTIONARY OF STRING
# Interaction log, so tests can assert what the verbs actually did.
PRIVATE DEFINE m_log DYNAMIC ARRAY OF STRING

#+ Reset every scripted value and the interaction log.
PUBLIC FUNCTION reset()
    LET m_aui = NULL
    LET m_auiPart = NULL
    LET m_lastSelector = NULL
    LET m_formName = NULL
    LET m_formTitle = NULL
    LET m_windowName = NULL
    LET m_windowTitle = NULL
    LET m_current = NULL
    LET m_rowCount = 0
    LET m_currentRow = 0
    CALL m_fieldValues.clear()
    CALL m_cells.clear()
    CALL m_actions.clear()
    CALL m_log.clear()
END FUNCTION

#+ The shared FakeDriver as a Driver interface (safe to pass to core.setDriver).
PUBLIC FUNCTION asDriver() RETURNS driver.Driver
    DEFINE d driver.Driver
    LET m_instance.ready = TRUE
    LET d = m_instance
    RETURN d
END FUNCTION

# --- scripting API --------------------------------------------------------

PUBLIC FUNCTION setAui(xmlText STRING)
    LET m_aui = xmlText
END FUNCTION

#+ Script what auiPart() returns (the current window), separately from the
#+ whole tree. Unset, auiPart() returns the whole tree.
PUBLIC FUNCTION setAuiPart(xmlText STRING)
    LET m_auiPart = xmlText
END FUNCTION

#+ The selector auiPart() was last called with.
PUBLIC FUNCTION lastSelector() RETURNS STRING
    RETURN m_lastSelector
END FUNCTION

PUBLIC FUNCTION setForm(name STRING, title STRING)
    LET m_formName = name
    LET m_formTitle = title
END FUNCTION

PUBLIC FUNCTION setWindow(name STRING, title STRING)
    LET m_windowName = name
    LET m_windowTitle = title
END FUNCTION

PUBLIC FUNCTION setFieldValue(name STRING, value STRING)
    LET m_fieldValues[name] = value
END FUNCTION

PUBLIC FUNCTION setCurrentValue(value STRING)
    LET m_current = value
END FUNCTION

PUBLIC FUNCTION addAction(name STRING, active BOOLEAN)
    DEFINE n INTEGER
    LET n = m_actions.getLength() + 1
    LET m_actions[n].name = name
    LET m_actions[n].active = active
END FUNCTION

PUBLIC FUNCTION setTable(rows INTEGER, curRow INTEGER)
    LET m_rowCount = rows
    LET m_currentRow = curRow
END FUNCTION

PUBLIC FUNCTION setCell(table STRING, col STRING, row INTEGER, value STRING)
    LET m_cells[cellKey(table, col, row)] = value
END FUNCTION

#+ Number of interactions recorded since reset().
PUBLIC FUNCTION logCount() RETURNS INTEGER
    RETURN m_log.getLength()
END FUNCTION

#+ Interaction #i, formatted "verb(args)".
PUBLIC FUNCTION logAt(i INTEGER) RETURNS STRING
    IF i < 1 OR i > m_log.getLength() THEN
        RETURN NULL
    END IF
    RETURN m_log[i]
END FUNCTION

PRIVATE FUNCTION note(entry STRING)
    LET m_log[m_log.getLength() + 1] = entry
END FUNCTION

PRIVATE FUNCTION cellKey(table STRING, col STRING, row INTEGER) RETURNS STRING
    RETURN SFMT("%1/%2/%3", table, col, row)
END FUNCTION

# --- Driver implementation -----------------------------------------------

FUNCTION (self FakeDriver) focus(fieldName STRING)
    CALL note(SFMT("focus(%1)", fieldName))
END FUNCTION

FUNCTION (self FakeDriver) enter(value STRING)
    CALL note(SFMT("enter(%1)", value))
    LET m_current = value
END FUNCTION

FUNCTION (self FakeDriver) setField(fieldName STRING, value STRING)
    CALL note(SFMT("setField(%1,%2)", fieldName, value))
    LET m_fieldValues[fieldName] = value
END FUNCTION

FUNCTION (self FakeDriver) action(name STRING)
    CALL note(SFMT("action(%1)", name))
END FUNCTION

FUNCTION (self FakeDriver) press(keyName STRING)
    CALL note(SFMT("press(%1)", keyName))
END FUNCTION

FUNCTION (self FakeDriver) pause(ms INTEGER)
    CALL note(SFMT("pause(%1)", ms))
END FUNCTION

FUNCTION (self FakeDriver) selectRow(tableName STRING, row INTEGER)
    CALL note(SFMT("selectRow(%1,%2)", tableName, row))
    LET m_currentRow = row
END FUNCTION

FUNCTION (self FakeDriver) focusCell(tableName STRING, columnName STRING, row INTEGER)
    CALL note(SFMT("focusCell(%1,%2,%3)", tableName, columnName, row))
    LET m_currentRow = row
END FUNCTION

FUNCTION (self FakeDriver) fieldValue(fieldName STRING) RETURNS STRING
    RETURN m_fieldValues[fieldName]
END FUNCTION

FUNCTION (self FakeDriver) currentValue() RETURNS STRING
    RETURN m_current
END FUNCTION

FUNCTION (self FakeDriver) formName() RETURNS STRING
    RETURN m_formName
END FUNCTION

FUNCTION (self FakeDriver) formTitle() RETURNS STRING
    RETURN m_formTitle
END FUNCTION

FUNCTION (self FakeDriver) windowName() RETURNS STRING
    RETURN m_windowName
END FUNCTION

FUNCTION (self FakeDriver) windowTitle() RETURNS STRING
    RETURN m_windowTitle
END FUNCTION

FUNCTION (self FakeDriver) isActionActive(name STRING) RETURNS BOOLEAN
    DEFINE i INTEGER
    FOR i = 1 TO m_actions.getLength()
        IF m_actions[i].name == name THEN
            RETURN m_actions[i].active
        END IF
    END FOR
    RETURN FALSE
END FUNCTION

FUNCTION (self FakeDriver) cellValue(tableName STRING, columnName STRING, row INTEGER) RETURNS STRING
    RETURN m_cells[cellKey(tableName, columnName, row)]
END FUNCTION

FUNCTION (self FakeDriver) rowCount(tableName STRING) RETURNS INTEGER
    RETURN m_rowCount
END FUNCTION

FUNCTION (self FakeDriver) currentRow(tableName STRING) RETURNS INTEGER
    RETURN m_currentRow
END FUNCTION

FUNCTION (self FakeDriver) actions() RETURNS driver.ActionList
    RETURN m_actions
END FUNCTION

FUNCTION (self FakeDriver) auiTree() RETURNS xml.DomDocument
    DEFINE doc xml.DomDocument
    IF m_aui IS NULL THEN
        RETURN doc
    END IF
    LET doc = xml.DomDocument.Create()
    CALL doc.loadFromString(m_aui)
    RETURN doc
END FUNCTION

FUNCTION (self FakeDriver) auiPart(selector STRING) RETURNS xml.DomDocument
    DEFINE doc xml.DomDocument
    LET m_lastSelector = selector
    IF m_auiPart IS NULL THEN
        RETURN self.auiTree()
    END IF
    LET doc = xml.DomDocument.Create()
    CALL doc.loadFromString(m_auiPart)
    RETURN doc
END FUNCTION
