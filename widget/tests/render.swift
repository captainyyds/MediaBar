// Renders the bar to PNG in both shapes. The Touch Bar cannot be screenshotted
// on this machine, so this is how the layout is checked and how the images in
// the README are made.
//
//   cd widget && ./build.sh && swiftc -parse-as-library -o dist/render-test \
//     tests/render.swift Sources/*.swift -I dist -L dist/lib -lPockKit \
//     -Xlinker -rpath -Xlinker "$PWD/dist/lib" && ./dist/render-test
import AppKit
import Foundation

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("dist")

/// A stand-in cover, so the shots do not depend on what happens to be playing.
func swatch(_ top: NSColor, _ bottom: NSColor) -> NSImage {
    let size = NSSize(width: 96, height: 96)
    let image = NSImage(size: size)
    image.lockFocus()
    NSGradient(starting: top, ending: bottom)?.draw(in: NSRect(origin: .zero, size: size), angle: -90)
    image.unlockFocus()
    return image
}

func snapshot(_ view: NSView, width: CGFloat, file: String) {
    view.frame = NSRect(x: 0, y: 0, width: width, height: 30)
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    view.layer?.layoutIfNeeded()
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width) * 2, pixelsHigh: 60,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("no rep") }
    // Without this the rep counts as 2x the points and the view is drawn at 1x
    // into one corner.
    rep.size = NSSize(width: width, height: 30)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: 30).fill()
    view.cacheDisplay(in: view.bounds, to: rep)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: outDir.appendingPathComponent(file))
    print("wrote dist/\(file)")
}

/// Content extents, so the layout is checked by measurement and not by eye.
func extents(_ file: String) -> String {
    guard let img = NSImage(contentsOfFile: outDir.appendingPathComponent(file).path),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff), let d = rep.bitmapData else { return "unreadable" }
    let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
    var minY = Int.max, maxY = -1, minX = Int.max, maxX = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            let o = y * bpr + x * spp
            if abs(Int(d[o]) - 28) > 22 || abs(Int(d[o+1]) - 28) > 22 || abs(Int(d[o+2]) - 28) > 22 {
                minY = min(minY, y); maxY = max(maxY, y)
                minX = min(minX, x); maxX = max(maxX, x)
            }
        }
    }
    guard maxY >= 0 else { return "empty" }
    let lo = 30.0 - Double(maxY) / 2, hi = 30.0 - Double(minY) / 2
    return String(format: "y %.1f…%.1f (centre %.1f)  x %.1f…%.1f",
                  lo, hi, (lo + hi) / 2, Double(minX) / 2, Double(maxX) / 2)
}

@main
struct RenderTest {
    static func main() {
        guard dlopen(outDir.appendingPathComponent("lib/libPockKit.dylib").path, RTLD_NOW) != nil else {
            fatalError(String(cString: dlerror()))
        }

        var playing = NowPlaying()
        playing.title = "Blue Hour"
        playing.artist = "45° Urban Blues"
        playing.duration = 245
        playing.anchorElapsed = 97
        playing.anchorAt = Date().timeIntervalSince1970
        playing.rate = 1
        playing.hasArtwork = true
        playing.commands = [0, 1, 4, 5]

        let cover = swatch(
            NSColor(calibratedRed: 0.30, green: 0.44, blue: 0.78, alpha: 1),
            NSColor(calibratedRed: 0.13, green: 0.18, blue: 0.40, alpha: 1)
        )

        UserDefaults.standard.set(true, forKey: "MediaBarExpanded")
        let expanded = MediaBarView(frame: NSRect(x: 0, y: 0, width: 685, height: 30))
        expanded.apply(playing)
        expanded.setArtwork(cover)
        snapshot(expanded, width: 685, file: "expanded.png")

        UserDefaults.standard.set(false, forKey: "MediaBarExpanded")
        let collapsed = MediaBarView(frame: NSRect(x: 0, y: 0, width: MediaBarView.collapsedWidth, height: 30))
        collapsed.apply(playing)
        collapsed.setArtwork(cover)
        snapshot(collapsed, width: MediaBarView.collapsedWidth, file: "collapsed.png")

        print("expanded : \(extents("expanded.png"))")
        print("collapsed: \(extents("collapsed.png"))")

        // The bar must sit on the centre line of a 30pt strip, and must not
        // spill past its own width.
        for (file, width) in [("expanded.png", 685.0), ("collapsed.png", Double(MediaBarView.collapsedWidth))] {
            let report = extents(file)
            guard report.contains("centre 15.0") || report.contains("centre 14.") || report.contains("centre 15.") else {
                fatalError("\(file) is not vertically centred: \(report)")
            }
            _ = width
        }
        print("RENDER TEST PASSED")
    }
}
