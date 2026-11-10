import Foundation
import Testing
@testable import Dusk

/// Debug test builds cannot hit the `-O` miscompile behind the
/// `completeFuture` -> `__cxa_pure_virtual` crash (see `Result.capturing`), so the
/// shape that triggers it is banned at the source level as well.
@Suite("Task group child shape", .timeLimit(.minutes(1)))
struct TaskGroupChildShapeTests {
    private struct Failure: Error, Equatable {}

    private struct ChildAnswer: Sendable {
        let key: String
        let outcome: Result<Int, any Error>
    }

    @Test("capturing reports the value")
    func capturingSuccess() async throws {
        let result = await Result.capturing { 42 }
        #expect(try result.get() == 42)
    }

    @Test("capturing reports the error")
    func capturingFailure() async {
        let result: Result<Int, any Error> = await Result.capturing { throw Failure() }
        #expect(throws: Failure.self) { try result.get() }
    }

    @Test("Every child answers once, with its own key, through capturing")
    func everyChildAnswers() async {
        let keys = (0..<32).map(String.init)
        let answers = await withTaskGroup(of: ChildAnswer.self) { group in
            for key in keys {
                group.addTask {
                    let outcome = await Result.capturing {
                        try await Task.sleep(for: .milliseconds(1))
                        guard key.hasSuffix("7") else { return key.count }
                        throw Failure()
                    }
                    return ChildAnswer(key: key, outcome: outcome)
                }
            }
            var answers: [ChildAnswer] = []
            for await answer in group {
                answers.append(answer)
            }
            return answers
        }

        #expect(answers.map(\.key).sorted() == keys.sorted())
        for answer in answers {
            if answer.key.hasSuffix("7") {
                #expect(throws: Failure.self) { try answer.outcome.get() }
            } else {
                #expect((try? answer.outcome.get()) == answer.key.count)
            }
        }
    }

    @Test("No task group child closure in the app contains a catch")
    func noCatchInTaskGroupChildren() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Dusk/Sources")
        // The sources are not there when the tests run away from this Mac.
        guard FileManager.default.fileExists(atPath: sources.path) else { return }

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var scannedChildren = 0
        var offenders: [String] = []
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for body in Self.childClosureBodies(in: text) {
                scannedChildren += 1
                if body.contains(/\bcatch\b/) {
                    offenders.append("\(file.lastPathComponent): \(body.prefix(120))")
                }
            }
        }

        #expect(scannedChildren > 10, "The scan stopped finding task group children")
        #expect(offenders.isEmpty, "Use Result.capturing: \(offenders)")
    }

    @Test("The scan sees a catch in a child and skips comments")
    func scanFindsChildBodies() {
        let source = """
        group.addTask {
            // catch
            do { return try await load() } catch { return nil }
        }
        """
        let bodies = Self.childClosureBodies(in: source)
        #expect(bodies.count == 1)
        #expect(bodies.first?.contains("do {") == true)
        #expect(bodies.first?.contains("// catch") == false)
    }

    @Test("The scan sees closures handed to the fan-out helpers")
    func scanFindsFanOutClosures() {
        let source = """
        streamAcrossServers { service, serverID in
            do { return .success(try await load()) } catch { return .failure(error) }
        }
        for await result in streamAcrossServers({ service, serverID in
            do { return .success(try await load()) } catch { return .failure(error) }
        }) {}
        let answers = await fanOutAcrossServers { _, _ in 1 }
        let named = service.streamAcrossServers(loadHomePayload)
        if ok { do { try run() } catch {} }
        """
        let bodies = Self.childClosureBodies(in: source)
        #expect(bodies.count == 3)
        #expect(bodies.filter { $0.contains(/\bcatch\b/) }.count == 2)
    }

    /// The brace-balanced closure of every `addTask`, and of every closure
    /// literal passed to `streamAcrossServers` / `fanOutAcrossServers` (which
    /// run it as a task group child), with line comments removed.
    private static func childClosureBodies(in text: String) -> [String] {
        let code = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line)
            }
            .joined(separator: "\n")

        var opens: [String.Index] = []
        var searchStart = code.startIndex
        while let call = code.range(of: "addTask", range: searchStart..<code.endIndex) {
            searchStart = call.upperBound
            guard let open = code[call.upperBound...].firstIndex(of: "{") else { break }
            opens.append(open)
        }
        // Only a closure literal right after the name (`f {` or `f({`); a
        // function passed by name is checked where it is defined, if at all.
        for match in code.matches(of: /\b(?:streamAcrossServers|fanOutAcrossServers)\s*(?:\(\s*)?\{/) {
            opens.append(code.index(before: match.range.upperBound))
        }

        var bodies: [String] = []
        for open in opens {
            var depth = 0
            var index = open
            while index < code.endIndex {
                if code[index] == "{" { depth += 1 }
                if code[index] == "}" { depth -= 1 }
                if depth == 0 {
                    bodies.append(String(code[open...index]))
                    break
                }
                index = code.index(after: index)
            }
        }
        return bodies
    }
}
