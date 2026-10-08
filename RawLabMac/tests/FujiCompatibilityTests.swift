import AppKit
import Foundation

@main
struct FujiCompatibilityTests {
    static func main() throws {
        guard CommandLine.arguments.count > 2 else {
            throw RenderError.failed("Pass a RAW and one or more external CUBE fixtures")
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("rawlab-fuji-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: directory) }
        let library = try LookLibrary(directory: directory)
        let raw = URL(fileURLWithPath: CommandLine.arguments[1])
        let cpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        let automatic = try RenderEngine()
        let forced = try RenderEngine(gpuMode: SONY2FUJI_GPU_FORCE)
        for path in CommandLine.arguments.dropFirst(2) {
            let source = URL(fileURLWithPath: path)
            let before = try Data(contentsOf: source)
            let imported = try library.importLook(from: source)
            let restored = try LookLibrary(directory: directory)
            guard restored.looks.contains(where: { $0.id == imported.id }),
                  try Data(contentsOf: restored.url(for: imported)) == before,
                  try Data(contentsOf: source) == before else {
                throw RenderError.failed("Import/readback changed bytes or lost the registry entry")
            }
            let lut = restored.url(for: imported)
            guard let reference = try cpu.render(raw, settings: Adjustments(), lut: lut, edge: 400),
                  let actual = try automatic.render(raw, settings: Adjustments(), lut: lut, edge: 400),
                  let gpu = try forced.render(raw, settings: Adjustments(), lut: lut, edge: 400),
                  let referenceData = reference.image.dataProvider?.data,
                  let actualData = actual.image.dataProvider?.data,
                  let forcedData = gpu.image.dataProvider?.data else {
                throw RenderError.failed("Missing preview")
            }
            let a = referenceData as Data, b = actualData as Data
            let maximum = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 999
            let c = forcedData as Data
            let forcedMaximum = zip(a, c).map { abs(Int($0) - Int($1)) }.max() ?? 999
            guard a.count == b.count, a.count == c.count, !a.isEmpty, maximum <= 2, forcedMaximum <= 2 else {
                throw RenderError.failed("CPU/Auto mismatch for \(source.lastPathComponent): \(maximum)")
            }
            print("PASS \(raw.lastPathComponent) / \(source.lastPathComponent): import, managed readback, source unchanged, preview CPU/Auto max DN=\(maximum), CPU/Force Metal max DN=\(forcedMaximum)")
        }
        print("PASS \(CommandLine.arguments.count - 2) external CUBEs")
    }
}
