.PHONY: all clean

all: ocr asr tts cv

ocr: ocr.swift
	swiftc -O -framework Cocoa -framework Vision ocr.swift -o ocr

asr: asr.swift
	swiftc -O -framework Speech -framework AVFoundation asr.swift -o asr

tts: tts.swift
	swiftc -O -framework AVFoundation -framework Cocoa -framework NaturalLanguage tts.swift -o tts

cv: cv.swift
	swiftc -O -framework Vision -framework CoreImage -framework ImageIO -framework AppKit -framework Cocoa cv.swift -o cv

clean:
	rm -f ocr asr tts cv
