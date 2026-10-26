#if os(macOS)
@testable import ScanBridgeHost
import Testing

struct HostOptionsTests {
    @Test func defaults() throws {
        #expect(try HostOptions.parse([]) == HostOptions())
    }

    @Test func parsesAllOptions() throws {
        let options = try HostOptions.parse([
            "--port", "9000", "-c", "Logitech", "--fps", "30", "--quality", "0.8", "--no-mirror", "--lite",
        ])
        #expect(options.lite)
        #expect(options.port == 9000)
        #expect(options.cameraName == "Logitech")
        #expect(options.framesPerSecond == 30)
        #expect(options.jpegQuality == 0.8)
        #expect(!options.mirrorsPreview)
    }

    @Test(arguments: [
        ["--port"],
        ["--port", "0"],
        ["--port", "70000"],
        ["--fps", "0"],
        ["--quality", "2"],
        ["--camera", "--no-mirror"],
        ["--unknown"],
    ])
    func rejectsInvalidArguments(_ arguments: [String]) {
        #expect(throws: HostOptions.ParseError.self) {
            try HostOptions.parse(arguments)
        }
    }
}
#endif
