.PHONY: build app run clean

build:
	swift build

app:
	bash scripts/build-app.sh

run: app
	open build/LiveTrans.app

clean:
	rm -rf .build build
