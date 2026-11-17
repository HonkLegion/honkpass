// Measures pictures and compares a PassVault screenshot with its reference picture.
// Build and run through `make compare`, or: swiftc -O scripts/image-tool.swift -o .build/image-tool
//
//   image-tool size <png>
//   image-tool color <png> <x> <y>
//   image-tool runs <png> row|column <index> [from] [to]     colour runs along one line of pixels
//   image-tool bbox <png> <x0> <y0> <x1> <y1>                 the box around what stands out from the ground
//   image-tool compare <reference> <candidate> <out.png> [skipTop]
//
// All coordinates are pixels of the picture. Reference pictures have two pixels to a point.
import AppKit

struct Bitmap {
    let width: Int
    let height: Int
    var data: [UInt8]

    init?(path: String) {
        guard let image = NSImage(contentsOfFile: path),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        width = cg.width
        height = cg.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        data = [UInt8](repeating: 255, count: width * height * 4)
    }

    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let offset = (y * width + x) * 4
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }

    mutating func set(_ x: Int, _ y: Int, _ r: Int, _ g: Int, _ b: Int) {
        let offset = (y * width + x) * 4
        data[offset] = UInt8(clamping: r)
        data[offset + 1] = UInt8(clamping: g)
        data[offset + 2] = UInt8(clamping: b)
        data[offset + 3] = 255
    }

    func write(to path: String) -> Bool {
        var copy = data
        guard let context = CGContext(data: &copy, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return false }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}

func hex(_ p: (r: Int, g: Int, b: Int)) -> String {
    String(format: "#%02X%02X%02X", p.r, p.g, p.b)
}

func distance(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Int {
    max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("Usage: image-tool size|color|runs|compare ...") }

switch command {
case "size":
    guard arguments.count == 2, let bitmap = Bitmap(path: arguments[1]) else { fail("Usage: image-tool size <png>") }
    print("\(bitmap.width) x \(bitmap.height) pixels")

case "color":
    guard arguments.count == 4, let bitmap = Bitmap(path: arguments[1]), let x = Int(arguments[2]), let y = Int(arguments[3]),
          x >= 0, y >= 0, x < bitmap.width, y < bitmap.height else { fail("Usage: image-tool color <png> <x> <y>") }
    print(hex(bitmap.pixel(x, y)))

case "runs":
    // Runs of one colour along a row or a column. Runs shorter than three pixels are joined as "…".
    guard arguments.count >= 4, let bitmap = Bitmap(path: arguments[1]), let index = Int(arguments[3]),
          arguments[2] == "row" || arguments[2] == "column" else {
        fail("Usage: image-tool runs <png> row|column <index> [from] [to]")
    }
    let isRow = arguments[2] == "row"
    let length = isRow ? bitmap.width : bitmap.height
    let from = arguments.count > 4 ? Int(arguments[4]) ?? 0 : 0
    let to = min(arguments.count > 5 ? Int(arguments[5]) ?? length : length, length)
    guard index >= 0, index < (isRow ? bitmap.height : bitmap.width), from >= 0, from < to else { fail("The line is outside the picture.") }
    func at(_ i: Int) -> (r: Int, g: Int, b: Int) { isRow ? bitmap.pixel(i, index) : bitmap.pixel(index, i) }
    var start = from
    var noiseStart: Int?
    var output: [String] = []
    func flushNoise(until end: Int) {
        if let begin = noiseStart {
            output.append("\(begin)-\(end - 1) …")
            noiseStart = nil
        }
    }
    var i = from
    while i < to {
        var end = i + 1
        while end < to, distance(at(end), at(i)) <= 3 { end += 1 }
        if end - i >= 3 {
            flushNoise(until: i)
            output.append("\(i)-\(end - 1) \(hex(at(i)))")
        } else if noiseStart == nil {
            noiseStart = i
        }
        start = end
        i = end
    }
    flushNoise(until: start)
    print(output.joined(separator: "\n"))

case "bbox":
    // The box around everything that differs from the colour of the region's first pixel.
    guard arguments.count == 6, let bitmap = Bitmap(path: arguments[1]),
          let x0 = Int(arguments[2]), let y0 = Int(arguments[3]), let x1 = Int(arguments[4]), let y1 = Int(arguments[5]),
          x0 >= 0, y0 >= 0, x1 <= bitmap.width, y1 <= bitmap.height, x0 < x1, y0 < y1 else {
        fail("Usage: image-tool bbox <png> <x0> <y0> <x1> <y1>")
    }
    let ground = bitmap.pixel(x0, y0)
    var left = Int.max, top = Int.max, right = -1, bottom = -1
    for y in y0..<y1 {
        for x in x0..<x1 where distance(bitmap.pixel(x, y), ground) > 40 {
            left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
        }
    }
    print(right < 0 ? "nothing differs from \(hex(ground))" : "x \(left)-\(right)  y \(top)-\(bottom)  (ground \(hex(ground)))")

case "compare":
    guard arguments.count >= 4, let reference = Bitmap(path: arguments[1]), let candidate = Bitmap(path: arguments[2]) else {
        fail("Usage: image-tool compare <reference> <candidate> <out.png> [skipTop]")
    }
    let skipTop = arguments.count > 4 ? Int(arguments[4]) ?? 0 : 0
    guard reference.width == candidate.width, reference.height == candidate.height else {
        print("SIZE DIFFERS: reference \(reference.width)x\(reference.height), candidate \(candidate.width)x\(candidate.height)")
        exit(1)
    }
    // Three panels at half size, side by side: reference, candidate, difference.
    let w = reference.width / 2, h = reference.height / 2
    var sheet = Bitmap(width: w * 3 + 16, height: h)
    var differing = 0, total = 0, sum = 0
    for y in 0..<h {
        for x in 0..<w {
            let a = reference.pixel(x * 2, y * 2), b = candidate.pixel(x * 2, y * 2)
            sheet.set(x, y, a.r, a.g, a.b)
            sheet.set(w + 8 + x, y, b.r, b.g, b.b)
            let d = distance(a, b)
            let counted = y * 2 >= skipTop
            if counted {
                total += 1
                sum += d
                if d > 24 { differing += 1 }
            }
            // Equal pixels are grey; differences go from yellow to red.
            if !counted { sheet.set(2 * (w + 8) + x, y, 40, 40, 40) }
            else if d <= 24 { sheet.set(2 * (w + 8) + x, y, 235, 235, 235) }
            else { sheet.set(2 * (w + 8) + x, y, 255, max(0, 220 - d * 2), 0) }
        }
    }
    guard sheet.write(to: arguments[3]) else { fail("The comparison picture could not be written.") }
    let percent = Double(differing) * 100 / Double(max(total, 1))
    print(String(format: "different pixels: %.2f %%   mean difference: %.2f of 255   (top %d pixel rows ignored)",
                 percent, Double(sum) / Double(max(total, 1)), skipTop))

default:
    fail("Unknown command \(command).")
}
