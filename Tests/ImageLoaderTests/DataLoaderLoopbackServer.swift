import Foundation
import Network

@testable import ImageLoader

final class DataLoaderLoopbackServer: Sendable {
    struct Response: Sendable {
        var statusCode: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    struct ReceivedRequest: Sendable {
        var path: String
        var headers: [String: String]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ImageLoaderTests.DataLoaderLoopbackServer")
    private let routes = LockIsolated<[String: Response]>([:])
    private let received = LockIsolated<[ReceivedRequest]>([])
    private let readyPort = LockIsolated<UInt16?>(nil)
    private let hasFailed = LockIsolated(false)

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
    }

    deinit {
        listener.cancel()
    }

    func start() async -> UInt16? {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            switch state {
            case .ready:
                let port = self.listener.port?.rawValue
                self.readyPort.withLock { $0 = port }
            case .failed, .cancelled:
                self.hasFailed.withLock { $0 = true }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        await waitUntil(timeout: 10) { self.readyPort.value != nil || self.hasFailed.value }
        return readyPort.value
    }

    func route(_ path: String, _ response: Response) {
        routes.withLock { $0[path] = response }
    }

    func requests(path: String) -> [ReceivedRequest] {
        received.withLock { $0.filter { $0.path == path } }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let content {
                buffer.append(content)
            }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: buffer.subdata(in: 0..<end.lowerBound), on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: Data, on connection: NWConnection) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let path = requestLine.count > 1 ? String(requestLine[1]) : "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        received.withLock { $0.append(ReceivedRequest(path: path, headers: headers)) }
        let response = routes.withLock { $0[path] } ?? Response(statusCode: 404)
        var fields = response.headers
        fields["Content-Length"] = "\(response.body.count)"
        fields["Connection"] = "close"
        if fields["Cache-Control"] == nil {
            fields["Cache-Control"] = "no-store"
        }
        var text = "HTTP/1.1 \(response.statusCode) \(Self.reasonPhrase(for: response.statusCode))\r\n"
        for (name, value) in fields {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var payload = Data(text.utf8)
        payload.append(response.body)
        connection.send(
            content: payload,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 404: "Not Found"
        default: "Status"
        }
    }
}
