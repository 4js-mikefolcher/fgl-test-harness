# fgltest.driver — the driver seam.
#
# `Driver` is a BDL INTERFACE describing every low-level interaction the harness
# needs against an application under test. `GgcDriver` (fgltest.ggcdriver)
# implements it by delegating to `IMPORT FGL ggc`; a future jar-backed driver can
# implement the same interface without touching the fluent API, runner, or tests.

PACKAGE com.fourjs.fgltest

IMPORT FGL ggc
IMPORT xml

#+ Named list type (method return values cannot be anonymous types).
PUBLIC TYPE ActionList DYNAMIC ARRAY OF ggc.Action

#+ auiPart() selector for the current window: the Window node the active dialog
#+ runs in, with its form and dialog. Equal to
#+ ggc.WindowSelector(ggc.AUI_CURRENT_SELECTOR); a Driver must accept it.
PUBLIC CONSTANT CURRENT_WINDOW = "$Window:!current!$"

#+ Low-level interaction seam implemented by concrete drivers.
PUBLIC TYPE Driver INTERFACE
    -- interaction
    focus(fieldName STRING),
    enter(value STRING),
    setField(fieldName STRING, value STRING),
    action(name STRING),
    press(keyName STRING),
    pause(ms INTEGER),
    -- table interaction (navigation also loads the target row)
    selectRow(tableName STRING, row INTEGER),
    focusCell(tableName STRING, columnName STRING, row INTEGER),
    -- scalar queries
    fieldValue(fieldName STRING) RETURNS STRING,
    currentValue() RETURNS STRING,
    formName() RETURNS STRING,
    formTitle() RETURNS STRING,
    windowName() RETURNS STRING,
    windowTitle() RETURNS STRING,
    isActionActive(name STRING) RETURNS BOOLEAN,
    -- table queries (cellValue reads a *loaded* row — navigate to it first)
    cellValue(tableName STRING, columnName STRING, row INTEGER) RETURNS STRING,
    rowCount(tableName STRING) RETURNS INTEGER,
    currentRow(tableName STRING) RETURNS INTEGER,
    -- introspection
    actions() RETURNS ActionList,
    auiTree() RETURNS xml.DomDocument,
    auiPart(selector STRING) RETURNS xml.DomDocument
END INTERFACE
