# fgltest — build
#
# Compiles the library modules AND the two runner programs into the package
# directory com/fourjs/fgltest/*.42m (fglcomp -M writes each .42m beside its
# source), then the bundled example (app + suite).
#
# Requires GNU make and a configured Genero environment (fglcomp/fglform on PATH,
# and the GGC toolkit reachable — see README/USERGUIDE). No shell scripts are used.
# Non-Unix shells can override the file ops, e.g.:
#   make RM="del /q"

FGLCOMP ?= fglcomp
FGLFORM ?= fglform
FGLRUN  ?= fglrun
# NB: GNU make predefines RM = rm -f, so use = (not ?=) to override it here;
# a command-line `make RM=...` still wins (command-line beats makefile).
RM       = rm -rf

PKGDIR  := com/fourjs/fgltest

# The package root (the directory holding com/) must be on FGLLDPATH so
# IMPORT FGL com.fourjs.fgltest.* resolves already-built deps during the build,
# regardless of the recipe's working directory. tests/ is on the path too, so the
# self-test can import its fake driver.
export FGLLDPATH := $(CURDIR):$(CURDIR)/tests$(if $(FGLLDPATH),:$(FGLLDPATH))

# Library modules in dependency order (IMPORT FGL needs deps compiled first).
# script imports flow/expect/inspect; cli imports server; runner imports script.
LIBMODS := driver core ggcdriver inspect flow expect script reporters server cli runner
# MAIN programs (compiled after the library they import).
PROGS   := fgltest fgltest_json

TESTDIR := tests

.PHONY: all lib programs example tests check check-byte check-char test lint clean

all: lib programs example tests

# Compile each package module in order into com/fourjs/fgltest/.
lib:
	$(foreach m,$(LIBMODS),$(FGLCOMP) -M $(PKGDIR)/$(m).4gl &&) true

# Compile the CLI and generic JSON-runner programs into the package dir.
# These are MAIN modules with no PACKAGE line, so (unlike package modules) -M
# writes their .42m to the CWD, not beside the source — force the location with
# --output-dir so they land in com/fourjs/fgltest/ alongside the library.
programs: lib
	$(foreach p,$(PROGS),$(FGLCOMP) -M --output-dir $(PKGDIR) $(PKGDIR)/$(p).4gl &&) true

# Compile the bundled example application and its test suite.
example: lib
	cd examples/price && $(FGLFORM) -M price.per \
	  && $(FGLFORM) -M edit_price.per \
	  && $(FGLCOMP) -M price.4gl \
	  && $(FGLCOMP) -M price_test.4gl

# Build fgltest's own test suite. These are modules without a PACKAGE line, and
# for those `fglcomp -M` writes the .42m to the CWD rather than beside the
# source — so each needs --output-dir to land in tests/ (same reason the two
# runner programs use it). runnersuite is a helper program selftest runs as a
# subprocess.
tests: lib
	$(FGLCOMP) -M --output-dir $(TESTDIR) $(TESTDIR)/fakedriver.4gl
	$(FGLCOMP) -M --output-dir $(TESTDIR) $(TESTDIR)/runnersuite.4gl
	$(FGLCOMP) -M --output-dir $(TESTDIR) $(TESTDIR)/selftest.4gl

# Run fgltest's own tests. Needs NO GGC engine, NO scenario server and NO
# application, so it runs anywhere the compiler does — this is the target CI
# should gate on. They run twice, under each FGL_LENGTH_SEMANTICS: BYTE is
# Genero's default and CHAR a common setting, and string code that is right
# under one can split multibyte text under the other. They need a UTF-8 locale
# (as Genero does): without one the multibyte cases would pass vacuously, so
# selftest's first check fails instead.
check: check-byte check-char

check-byte: export FGL_LENGTH_SEMANTICS = BYTE
check-byte: tests
	$(FGLRUN) $(TESTDIR)/selftest

check-char: export FGL_LENGTH_SEMANTICS = CHAR
check-char: tests
	$(FGLRUN) $(TESTDIR)/selftest

# Run the bundled example suites end to end. Unlike `check`, this needs the GGC
# toolkit on PATH (source $$FGLDIR/testing_utilities/ggc/envggc first); the CLI
# starts and stops the scenario server itself.
test: all
	$(FGLRUN) $(PKGDIR)/fgltest fgltest.json

# Validate the package manifest exactly as `fglpkg pack`/`publish` would.
lint:
	fglpkg lint

clean:
	$(RM) $(PKGDIR)/*.42m \
	  $(TESTDIR)/*.42m \
	  results \
	  examples/price/price.42m examples/price/price_test.42m \
	  examples/price/price.42f examples/price/edit_price.42f
