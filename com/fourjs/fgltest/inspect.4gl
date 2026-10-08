# fgltest.inspect — AUI-tree introspection (headline feature).
#
# Answers live-state questions straight from the AUI tree / driver: what actions
# exist and are active, what fields exist and are enabled/visible/editable.
# Fields and tables are read from the CURRENT window only: the AUI tree keeps
# every open window, so with a modal child window up, a whole-tree query would
# also report the parent's fields.
# Fields live under two AUI tags — TableColumn (list columns) and FormField
# (standalone) — so fields() unions both. Enable/visibility semantics:
#   active : absent or "1" = enabled, "0" = disabled
#   hidden : "1" = hidden
#   noEntry: "1" = read-only

PACKAGE com.fourjs.fgltest

IMPORT xml
IMPORT FGL com.fourjs.fgltest.driver
IMPORT FGL com.fourjs.fgltest.core

PUBLIC TYPE StringList DYNAMIC ARRAY OF STRING

PUBLIC TYPE FieldInfo RECORD
    name STRING,
    colName STRING,
    widget STRING,
    varType STRING,
    active BOOLEAN,
    hidden BOOLEAN,
    readOnly BOOLEAN
END RECORD
PUBLIC TYPE FieldList DYNAMIC ARRAY OF FieldInfo

# ---------------------------------------------------------------- actions ----

#+ All actions of the current dialog (name/active/text).
PUBLIC FUNCTION actions() RETURNS driver.ActionList
    DEFINE d driver.Driver
    LET d = core.getDriver()
    RETURN d.actions()
END FUNCTION

#+ Names of all actions.
PUBLIC FUNCTION actionNames() RETURNS StringList
    DEFINE a driver.ActionList
    DEFINE r StringList
    DEFINE i INTEGER
    LET a = actions()
    FOR i = 1 TO a.getLength()
        LET r[r.getLength() + 1] = a[i].name
    END FOR
    RETURN r
END FUNCTION

#+ Names of the currently-active actions only.
PUBLIC FUNCTION activeActionNames() RETURNS StringList
    DEFINE a driver.ActionList
    DEFINE r StringList
    DEFINE i INTEGER
    LET a = actions()
    FOR i = 1 TO a.getLength()
        IF a[i].active THEN
            LET r[r.getLength() + 1] = a[i].name
        END IF
    END FOR
    RETURN r
END FUNCTION

#+ Current form name.
PUBLIC FUNCTION formName() RETURNS STRING
    DEFINE d driver.Driver
    LET d = core.getDriver()
    RETURN d.formName()
END FUNCTION

#+ Current window name.
PUBLIC FUNCTION windowName() RETURNS STRING
    DEFINE d driver.Driver
    LET d = core.getDriver()
    RETURN d.windowName()
END FUNCTION

#+ TRUE if an action with the given name exists in the current dialog.
PUBLIC FUNCTION hasAction(name STRING) RETURNS BOOLEAN
    DEFINE a driver.ActionList
    DEFINE i INTEGER
    LET a = actions()
    FOR i = 1 TO a.getLength()
        IF a[i].name == name THEN
            RETURN TRUE
        END IF
    END FOR
    RETURN FALSE
END FUNCTION

# ----------------------------------------------------------------- fields ----

#+ All fields on the current window's form — union of FormField and
#+ TableColumn nodes.
PUBLIC FUNCTION fields() RETURNS FieldList
    DEFINE d driver.Driver
    DEFINE doc xml.DomDocument
    DEFINE nl xml.DomNodeList
    DEFINE nd, w xml.DomNode
    DEFINE r FieldList
    DEFINE fi FieldInfo
    DEFINE i, n INTEGER

    LET d = core.getDriver()
    LET doc = d.auiPart(driver.CURRENT_WINDOW)
    IF doc IS NULL THEN
        RETURN r
    END IF
    LET nl = doc.selectByXPath("//FormField | //TableColumn", NULL)
    FOR i = 1 TO nl.getCount()
        LET nd = nl.getItem(i)
        INITIALIZE fi TO NULL
        LET fi.name = nd.getAttribute("name")
        LET fi.colName = nd.getAttribute("colName")
        LET fi.varType = nd.getAttribute("varType")
        -- NB: BDL treats "" as NULL, so `attr != "0"` can evaluate to NULL.
        -- attrEquals() always returns a concrete TRUE/FALSE.
        LET fi.active = NOT attrEquals(nd, "active", "0")
        LET fi.hidden = attrEquals(nd, "hidden", "1")
        LET fi.readOnly = attrEquals(nd, "noEntry", "1")
        LET w = nd.getFirstChildElement()
        IF w IS NULL THEN
            LET fi.widget = nd.getLocalName()
        ELSE
            LET fi.widget = w.getLocalName()
        END IF
        LET n = r.getLength() + 1
        LET r[n].* = fi.*
    END FOR
    RETURN r
END FUNCTION

#+ Names of all fields.
PUBLIC FUNCTION fieldNames() RETURNS StringList
    DEFINE f FieldList
    DEFINE r StringList
    DEFINE i INTEGER
    LET f = fields()
    FOR i = 1 TO f.getLength()
        LET r[r.getLength() + 1] = f[i].name
    END FOR
    RETURN r
END FUNCTION

#+ Names of enabled (active and not hidden) fields.
PUBLIC FUNCTION enabledFields() RETURNS StringList
    DEFINE f FieldList
    DEFINE r StringList
    DEFINE i INTEGER
    LET f = fields()
    FOR i = 1 TO f.getLength()
        IF f[i].active AND NOT f[i].hidden THEN
            LET r[r.getLength() + 1] = f[i].name
        END IF
    END FOR
    RETURN r
END FUNCTION

#+ Names of editable fields (active, not hidden, not read-only).
PUBLIC FUNCTION editableFields() RETURNS StringList
    DEFINE f FieldList
    DEFINE r StringList
    DEFINE i INTEGER
    LET f = fields()
    FOR i = 1 TO f.getLength()
        IF f[i].active AND NOT f[i].hidden AND NOT f[i].readOnly THEN
            LET r[r.getLength() + 1] = f[i].name
        END IF
    END FOR
    RETURN r
END FUNCTION

# ----------------------------------------------------------------- tables ----

#+ Names of all tables/matrices on the current window's form (the AUI Table
#+ `name` attribute — this is the identifier the table queries/verbs expect).
PUBLIC FUNCTION tables() RETURNS StringList
    DEFINE d driver.Driver
    DEFINE doc xml.DomDocument
    DEFINE nl xml.DomNodeList
    DEFINE r StringList
    DEFINE i INTEGER

    LET d = core.getDriver()
    LET doc = d.auiPart(driver.CURRENT_WINDOW)
    IF doc IS NULL THEN
        RETURN r
    END IF
    LET nl = doc.selectByXPath("//Table | //Matrix", NULL)
    FOR i = 1 TO nl.getCount()
        LET r[r.getLength() + 1] = nl.getItem(i).getAttribute("name")
    END FOR
    RETURN r
END FUNCTION

#+ Number of rows in a table (total model size).
PUBLIC FUNCTION rowCount(tableName STRING) RETURNS INTEGER
    DEFINE d driver.Driver
    LET d = core.getDriver()
    RETURN d.rowCount(tableName)
END FUNCTION

#+ Current (focused) row of a table, 1-based.
PUBLIC FUNCTION currentRow(tableName STRING) RETURNS INTEGER
    DEFINE d driver.Driver
    LET d = core.getDriver()
    RETURN d.currentRow(tableName)
END FUNCTION

#+ Value of a cell at an explicit 1-based row. The row must be loaded (visible or
#+ previously navigated to via flow.selectRow); a non-loaded row reads as empty.
PUBLIC FUNCTION cellValue(tableName STRING, columnName STRING, row INTEGER) RETURNS STRING
    DEFINE d driver.Driver
    LET d = core.getDriver()
    RETURN d.cellValue(tableName, columnName, row)
END FUNCTION

#+ Value of a column in the current (focused) row — always loaded, no navigation.
PUBLIC FUNCTION currentCellValue(tableName STRING, columnName STRING) RETURNS STRING
    DEFINE d driver.Driver
    LET d = core.getDriver()
    RETURN d.cellValue(tableName, columnName, d.currentRow(tableName))
END FUNCTION

# ------------------------------------------------------------ application ----

#+ The runtime error the application under test stopped with, or NULL.
#+
#+ When a Genero program stops on a runtime error in GUI mode, the runtime
#+ shows the message in a "winmsg" message box and waits for it to be
#+ acknowledged. Meanwhile GGC keeps answering from the screen it last saw, so
#+ the application looks alive — reads still succeed and assertions may pass.
#+ This finds that box by its text ("Program stopped at ..."). A program that
#+ sets gui.programStoppedMessage in FGLPROFILE replaces that text, and then
#+ the box cannot be told apart from the application's own message boxes.
PUBLIC FUNCTION applicationError() RETURNS STRING
    DEFINE d driver.Driver
    DEFINE doc xml.DomDocument
    DEFINE nl xml.DomNodeList
    DEFINE msg STRING
    DEFINE b base.StringBuffer
    DEFINE i INTEGER

    LET d = core.getDriver()
    LET doc = d.auiTree()
    IF doc IS NULL THEN
        RETURN NULL
    END IF
    LET nl = doc.selectByXPath("//Menu[@style='winmsg']", NULL)
    FOR i = 1 TO nl.getCount()
        LET msg = nl.getItem(i).getAttribute("comment")
        IF msg.getIndexOf("Program stopped at", 1) > 0 THEN
            # One line: the message spans several, ending with a newline.
            LET b = base.StringBuffer.create()
            CALL b.append(msg)
            CALL b.replace(ASCII 13, "", 0)
            CALL b.replace(ASCII 10, " ", 0)
            LET msg = b.toString()
            RETURN msg.trim()
        END IF
    END FOR
    RETURN NULL
END FUNCTION

# ---------------------------------------------------------------- helpers ----

#+ TRUE iff node's <name> attribute equals <val> (never NULL, unlike a bare ==).
PRIVATE FUNCTION attrEquals(nd xml.DomNode, name STRING, val STRING) RETURNS BOOLEAN
    IF nd.getAttribute(name) == val THEN
        RETURN TRUE
    END IF
    RETURN FALSE
END FUNCTION
