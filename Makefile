.PHONY: all clean

all: ocr asr tts

ocr: ocr.swift
	swiftc -O -framework Cocoa -framework Vision ocr.swift -o ocr

asr: asr.swift
	swiftc -O -framework Speech -framework AVFoundation asr.swift -o asr

tts: tts.swift
	swiftc -O -framework AVFoundation -framework Cocoa -framework NaturalLanguage tts.swift -o tts

clean:
	rm -f ocr asr tts
