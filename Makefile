# Strata — developer entry points. End users run install.sh instead.
DEVELOPER_DIR ?= $(shell [ -d /Applications/Xcode.app ] && echo /Applications/Xcode.app/Contents/Developer || xcode-select -p)
export DEVELOPER_DIR

.PHONY: build test app dev release install uninstall clean lint

build:            ## debug build of the strata executable
	swift build --product strata

test:             ## run unit tests (needs Xcode's XCTest; DEVELOPER_DIR is set automatically if Xcode exists)
	swift test

app:              ## build + sign dist/Strata.app and dist/Strata-<version>.zip
	scripts/build-app.sh

dev: app          ## build, install to /Applications, (re)start daemon + GUI (asks for sudo)
	./install.sh --app dist/Strata.app --replace-kmonad

release: test app ## build release artefacts (then: gh release create vX.Y.Z dist/Strata-X.Y.Z.zip)
	@echo "artefacts in dist/"

install:          ## run the installer from this checkout
	./install.sh --from-source

uninstall:
	./uninstall.sh

clean:
	rm -rf .build dist

lint:
	bash -n install.sh uninstall.sh scripts/*.sh
	plutil -lint packaging/*.plist

help:
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/ —/'
