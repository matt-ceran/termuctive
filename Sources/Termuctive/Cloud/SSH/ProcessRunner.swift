import Foundation

struct ProcessResult: Equatable, Sendable {
    let status: Int32
    let output: Data
    let error: Data
    let timedOut: Bool

    var outputText: String {
        String(decoding: output, as: UTF8.self)
    }

    var errorText: String {
        String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var succeeded: Bool {
        status == 0 && !timedOut
    }
}

/// Runs a helper program to completion without a terminal, collecting its output.
enum ProcessRunner {
    static func run(
        _ executable: String,
        _ arguments: [String],
        input: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60,
        collectsOutput: Bool = true
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runBlocking(
                        executable,
                        arguments,
                        input: input,
                        environment: environment,
                        timeout: timeout,
                        collectsOutput: collectsOutput
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(
        _ executable: String,
        _ arguments: [String],
        input: Data?,
        environment: [String: String]?,
        timeout: TimeInterval,
        collectsOutput: Bool
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        // Programs that leave a background child behind (such as an ssh control master)
        // keep their output pipes open, so their output must not be collected.
        let output: DataCollector?
        let error: DataCollector?
        if collectsOutput {
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            output = DataCollector(outputPipe.fileHandleForReading)
            error = DataCollector(errorPipe.fileHandleForReading)
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            output = nil
            error = nil
        }
        try process.run()

        if let input, let inputPipe {
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = inputPipe.fileHandleForWriting
                try? handle.write(contentsOf: input)
                try? handle.close()
            }
        }

        let timeoutState = TimeoutState()
        let timer = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else {
                return
            }
            timeoutState.markTimedOut()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        process.waitUntilExit()
        timer.cancel()

        return ProcessResult(
            status: process.terminationStatus,
            output: output?.finish() ?? Data(),
            error: error?.finish() ?? Data(),
            timedOut: timeoutState.timedOut
        )
    }
}

private final class DataCollector: @unchecked Sendable {
    private let group = DispatchGroup()
    private var data = Data()

    init(_ handle: FileHandle) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            data = handle.readDataToEndOfFile()
            group.leave()
        }
    }

    func finish() -> Data {
        group.wait()
        return data
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func markTimedOut() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
