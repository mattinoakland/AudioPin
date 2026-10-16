APP = build/AudioPin.app
INSTALL_DIR = /Applications

.PHONY: build run install uninstall stop clean logs dist

build:
	./build.sh release

run: build stop
	open $(APP)

# Login items work best from /Applications; install puts it there and launches it.
install: build stop
	rm -rf $(INSTALL_DIR)/AudioPin.app
	ditto $(APP) $(INSTALL_DIR)/AudioPin.app
	open $(INSTALL_DIR)/AudioPin.app

uninstall: stop
	rm -rf $(INSTALL_DIR)/AudioPin.app

stop:
	-pkill -x AudioPin 2>/dev/null || true

clean:
	rm -rf .build build

# Zip the app for sending to someone else (see README, "Sharing it").
dist: build
	mkdir -p dist
	rm -f dist/AudioPin.zip
	ditto -c -k --keepParent $(APP) dist/AudioPin.zip
	@echo "Wrote dist/AudioPin.zip"

# Live log stream from the app (what Console.app would show).
logs:
	/usr/bin/log stream --level info --style compact --predicate 'subsystem == "com.mattmoglia.AudioPin"'
