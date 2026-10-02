# fgltest.flow — the interaction API (void verbs; statement-friendly).
#
#   CALL flow.field("custname")
#   CALL flow.enter("ACME")
#   CALL flow.action("accept")
#
# Named `flow` (not `ui`) to avoid colliding with the built-in `ui` package.
# BDL's CALL cannot discard a return value, so these are void verbs rather than
# a returning/chained builder (mirrors how built-ins like base.StringBuffer work).
# Each verb delegates to the active driver.

PACKAGE com.fourjs.fgltest

IMPORT FGL com.fourjs.fgltest.driver
IMPORT FGL com.fourjs.fgltest.core

#+ Focus a field by name.
PUBLIC FUNCTION field(name STRING)
    DEFINE d driver.Driver
    LET d = core.getDriver()
    CALL d.focus(name)
END FUNCTION

#+ Type a value into the current field.
PUBLIC FUNCTION enter(value STRING)
    DEFINE d driver.Driver
    LET d = core.getDriver()
    CALL d.enter(value)
END FUNCTION

#+ Focus a field and set its value in one step.
PUBLIC FUNCTION fill(name STRING, value STRING)
    DEFINE d driver.Driver
    LET d = core.getDriver()
    CALL d.setField(name, value)
END FUNCTION

#+ Clear the current field.
PUBLIC FUNCTION clear()
    DEFINE d driver.Driver
    LET d = core.getDriver()
    CALL d.enter("")
END FUNCTION

#+ Trigger an action by name.
PUBLIC FUNCTION action(name STRING)
    DEFINE d driver.Driver
    LET d = core.getDriver()
    CALL d.action(name)
END FUNCTION

#+ Send a key by name.
PUBLIC FUNCTION press(keyName STRING)
    DEFINE d driver.Driver
    LET d = core.getDriver()
    CALL d.press(keyName)
END FUNCTION

#+ Wait the given number of milliseconds.
PUBLIC FUNCTION pause(ms INTEGER)
    DEFINE d driver.Driver
    LET d = core.getDriver()
    CALL d.pause(ms)
END FUNCTION

#+ Focus (and load) a table row by 1-based row number.
PUBLIC FUNCTION selectRow(tableName STRING, row INTEGER)
    DEFINE d driver.Driver
    LET d = core.getDriver()
    CALL d.selectRow(tableName, row)
END FUNCTION

#+ Focus (and load) a specific table cell by column name and 1-based row number.
PUBLIC FUNCTION focusCell(tableName STRING, columnName STRING, row INTEGER)
    DEFINE d driver.Driver
    LET d = core.getDriver()
    CALL d.focusCell(tableName, columnName, row)
END FUNCTION
