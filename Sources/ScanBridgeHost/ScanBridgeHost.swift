import Foundation

@main
enum ScanBridgeHost {
    static func main() async {
        let options: HostOptions
        do {
            options = try HostOptions.parse(CommandLine.arguments.dropFirst())
        } catch {
            Console.error(error.description)
            print("\n" + HostOptions.usage)
            exit(EX_USAGE)
        }

        if options.showHelp {
            print(HostOptions.usage)
            return
        }

        if options.listCameras {
            let devices = CameraCapture.availableDevices()
            if devices.isEmpty {
                print("No camera found.")
            }
            for device in devices {
                print("• \(device.localizedName)")
            }
            return
        }

        guard await CameraCapture.requestAccess() else {
            Console.error(
                "Camera access denied. Allow your terminal (or Xcode) in System Settings › Privacy & Security › Camera, then run again."
            )
            exit(EXIT_FAILURE)
        }

        guard let device = CameraCapture.device(matching: options.cameraName) else {
            Console.error(
                options.cameraName.map { "No camera matching '\($0)'. Use --list-cameras." } ?? "No camera found."
            )
            exit(EXIT_FAILURE)
        }

        let host: BridgeHost
        do {
            host = BridgeHost(capture: try CameraCapture(device: device), options: options)
            try host.start { error in
                Console.error("Server failed: \(error.localizedDescription). Is another scanbridge-host already running on port \(options.port)?")
                exit(EXIT_FAILURE)
            }
        } catch {
            Console.error("\(error)")
            exit(EXIT_FAILURE)
        }

        Console.info("Camera: \(device.localizedName)" + (options.lite ? " (lite: stream only)" : "") + ". Press Ctrl-C to quit.")
        await waitForTerminationSignal()
        host.stop()
        Console.info("Bye.")
    }

    private static func waitForTerminationSignal() async {
        let queue = DispatchQueue(label: "ScanBridgeHost.signals")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var sources: [DispatchSourceSignal] = []
            var resumed = false
            for signalNumber in [SIGINT, SIGTERM] {
                signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
                source.setEventHandler {
                    // Runs on the serial `queue`, so `resumed` needs no further synchronisation.
                    guard !resumed else { return }
                    resumed = true
                    sources.forEach { $0.cancel() }
                    continuation.resume()
                }
                sources.append(source)
            }
            queue.sync {
                sources.forEach { $0.resume() }
            }
        }
    }
}
