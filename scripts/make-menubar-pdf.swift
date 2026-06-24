#!/usr/bin/env swift
// Regenerate the menu-bar icon (Sources/Skelf/Resources/skelf-menubar.pdf) from skelf.svg.
//
// Why a PDF: the status item loads this as a TEMPLATE image. A vector PDF goes through AppKit's
// own template-rendering path (the same one asset-catalog template images use) and draws reliably
// in the live menu bar. Rasterizing the SVG into a hand-built NSBitmapImageRep at runtime — what
// older builds did — renders BLANK in the status bar when the app is compiled against the macOS 26
// SDK, which is how the icon went missing in a shipped release.
//
// Usage:  swift scripts/make-menubar-pdf.swift
// Run from the repo root. Re-run whenever skelf.svg changes, then commit the regenerated PDF.

import AppKit

let root = FileManager.default.currentDirectoryPath
let svgPath = "\(root)/Sources/Skelf/Resources/skelf.svg"
let outPath = "\(root)/Sources/Skelf/Resources/skelf-menubar.pdf"

guard let svg = NSImage(contentsOfFile: svgPath) else {
    FileHandle.standardError.write(Data("error: cannot load \(svgPath)\n".utf8)); exit(1)
}

// Vector media box at the mark's aspect (~1.38:1). Size is cosmetic — the PDF is vector and the
// app scales it to the bar. The mark keeps its own colour; the template tint uses alpha coverage.
let w: CGFloat = 220, h: CGFloat = 160
var mediaBox = CGRect(x: 0, y: 0, width: w, height: h)
let data = NSMutableData()
guard let consumer = CGDataConsumer(data: data as CFMutableData),
      let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    FileHandle.standardError.write(Data("error: cannot open PDF context\n".utf8)); exit(1)
}
ctx.beginPDFPage(nil)
let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gc
svg.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
ctx.endPDFPage()
ctx.closePDF()

do {
    try (data as Data).write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath) (\(data.length) bytes)")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
}
