# Example fgltest suite for the bundled `price` application.
#
# Build:  fglcomp -M price_test.4gl   (with the package root on FGLLDPATH)
# Run:    fglrun price_test tcp --working-directory . --command-line "fglrun price"
#         (or `make test`, which drives it through the fgltest CLI and owns the
#          GGC scenario server)

IMPORT FGL com.fourjs.fgltest.runner
IMPORT FGL com.fourjs.fgltest.flow
IMPORT FGL com.fourjs.fgltest.expect
IMPORT FGL com.fourjs.fgltest.inspect

MAIN
    CALL runner.setApplication("price")
    CALL runner.beforeEach(FUNCTION settle)     -- give the UI a moment before each test
    CALL runner.afterAll(FUNCTION leave)        -- exit the app cleanly at the end

    CALL runner.test("shows edit and cancel actions", FUNCTION t_actions)
    CALL runner.test("lists three fields incl. price", FUNCTION t_fields)
    CALL runner.test("starts on the price form", FUNCTION t_form)
    CALL runner.test("reads table cells (list)", FUNCTION t_table)
    -- Registered with testSkip so the example run is green. Change testSkip to
    -- test to see how a failing assertion is reported (console detail, JUnit
    -- <failure>, TAP diagnostics, and a non-zero exit code).
    CALL runner.testSkip("DEMO: deliberately failing test", FUNCTION t_fail)

    CALL runner.run()
END MAIN

FUNCTION settle()
    CALL flow.pause(100)
END FUNCTION

FUNCTION leave()
    CALL flow.action("cancel")
END FUNCTION

FUNCTION t_actions()
    CALL expect.all(inspect.activeActionNames()).toContain("edit")
    CALL expect.all(inspect.activeActionNames()).toContain("cancel")
END FUNCTION

FUNCTION t_fields()
    CALL expect.all(inspect.fieldNames()).toHaveSize(3)
    CALL expect.all(inspect.enabledFields()).toContain("formonly.price")
    CALL expect.all(inspect.fieldNames()).toContainMatch("^formonly[.]")
END FUNCTION

FUNCTION t_form()
    CALL expect.that(inspect.formName()).toEqual("price")
END FUNCTION

FUNCTION t_table()
    CALL expect.all(inspect.tables()).toContain("prices")
    -- expect.num compares numerically, so no stringifying of counts
    CALL expect.num(inspect.rowCount("prices")).toEqual(5)
    CALL expect.num(inspect.rowCount("prices")).toBeAtLeast(1)
    -- current row's cell (no navigation)
    CALL flow.selectRow("prices", 1)
    CALL expect.that(inspect.currentCellValue("prices", "name")).toEqual("Globe")
    -- a non-visible row: navigate first, then read
    CALL flow.selectRow("prices", 3)
    CALL expect.that(inspect.cellValue("prices", "name", 3)).toEqual("Blue Scissors")
    CALL expect.that(inspect.cellValue("prices", "name", 3)).toContainText("Scissors")
END FUNCTION

FUNCTION t_fail()
    CALL expect.all(inspect.actionNames()).toContain("save_nonexistent")
END FUNCTION
