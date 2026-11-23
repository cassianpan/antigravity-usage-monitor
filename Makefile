.PHONY: test xctest build app dmg run clean

APP_BUNDLE := build/Antigravity Usage Monitor.app

test:
	swift run UsageCoreSelfTest

xctest:
	swift test

build:
	swift build

app:
	chmod +x Scripts/build-app.sh
	./Scripts/build-app.sh

dmg: app
	chmod +x Scripts/build-dmg.sh
	./Scripts/build-dmg.sh

run: app
	open "$(APP_BUNDLE)"

clean:
	rm -rf .build build dist
