# Prio build targets. Requires only the Xcode Command Line Tools.

SWIFT ?= swift
APP := build/Prio.app

# The Command Line Tools ship the Swift Testing macro plugin in a subfolder
# that SwiftPM does not search on its own. Add it only when it exists, so a
# full Xcode install keeps working unchanged.
TESTING_PLUGIN_DIR := $(shell d="$$(dirname "$$(xcrun --find swift 2>/dev/null || command -v swift)")/../lib/swift/host/plugins/testing"; [ -d "$$d" ] && cd "$$d" && pwd)
ifneq ($(TESTING_PLUGIN_DIR),)
TEST_FLAGS := -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGIN_DIR)
endif

.PHONY: all app test run clean

all: app

app:
	bash scripts/build-app.sh

test:
	$(SWIFT) test $(TEST_FLAGS)

run: app
	open "$(APP)"

clean:
	rm -rf .build build
