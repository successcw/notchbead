APP_NAME   = NotchBead
BUNDLE_DIR = $(APP_NAME).app
ARCHS      = --arch arm64 --arch x86_64

.PHONY: build test bundle run icon sound clean install

build:
	swift build -c release $(ARCHS)

test:
	swift test

bundle: build
	@rm -rf $(BUNDLE_DIR)
	@mkdir -p $(BUNDLE_DIR)/Contents/MacOS $(BUNDLE_DIR)/Contents/Resources
	cp "$$(swift build -c release $(ARCHS) --show-bin-path)/$(APP_NAME)" $(BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)
	cp SupportFiles/Info.plist $(BUNDLE_DIR)/Contents/
	cp SupportFiles/AppIcon.icns $(BUNDLE_DIR)/Contents/Resources/AppIcon.icns
	cp SupportFiles/Arrival.wav $(BUNDLE_DIR)/Contents/Resources/Arrival.wav
	codesign --force --sign - $(BUNDLE_DIR)
	@echo "Bundled: $(BUNDLE_DIR)"

run: bundle
	open $(BUNDLE_DIR)

# Copies the app to /Applications, so Open at Login points at a stable place.
install: bundle
	rm -rf /Applications/$(BUNDLE_DIR)
	cp -R $(BUNDLE_DIR) /Applications/
	open /Applications/$(BUNDLE_DIR)

icon:
	swift SupportFiles/generate-icon.swift

sound:
	python3 SupportFiles/generate-sound.py SupportFiles/Arrival.wav

clean:
	rm -rf .build $(BUNDLE_DIR)
