.PHONY: mac android install test test-unit test-protocol

mac:
	./scripts/build-mac.sh

android:
	./scripts/build-android.sh

install: android
	./scripts/install-tv.sh

# Fast checks: no device, no running app.
test-unit: mac
	python3 tools/chaos_pairing.py --check
	swiftc -O -o /tmp/chaos_audio tools/chaos_audio.swift \
		mac/Sources/AirScreen/AudioWire.swift mac/Sources/AirScreen/StreamSettings.swift
	/tmp/chaos_audio
	./scripts/test-android.sh

# Drives the real Mac app over real TLS; starts and stops it itself.
test-protocol: mac
	python3 tools/chaos_pairing_protocol.py

test: test-unit test-protocol
