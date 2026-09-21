.PHONY: build package install run dmg

build:
	swift build

package:
	scripts/package-app.sh --no-install

install:
	scripts/package-app.sh

run: install
	open ~/Applications/GlowTop.app

dmg:
	scripts/make-dmg.sh
