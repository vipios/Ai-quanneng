//
//  RelayProxy.swift
//  RelayDylib — 本地 HTTP 反向代理：让聊天请求随线路自动换地址
//
//  ============================================================
//  这是「无感自动换线」的核心
//
//  为什么需要它：
//    App 发聊天请求时，地址写死在服务商配置里（customBaseURL）。
//    fork 版原本在 App 源码的 ProviderInstance.resolvedBaseURL 里按线路换地址，
//    但那是 fork 的 App 才有的代码 —— 官方 App 没有这个 hook，dylib 也改不了
//    正在发出的请求。所以唯一能让官方 App「无感换线」的办法：
//
//      App 服务商地址固定填 http://127.0.0.1:18923  ← 只配一次，之后永不变
//                    │
//                    ▼
//      本代理在该端口监听，收到请求后按 RelayStore 的实时判定，
//      把请求转发到当前线路的目标：
//        在家 → http://192.168.x.x:8080/v1/...
//        在外 → https://域名/v1/...
//                    │
//                    ▼
//      响应（含 SSE 流式）原样回给 App
//
//    App 从头到尾只认那一个本地地址，WiFi 切蜂窝、在家出门，它毫无感知，
//    全是代理内部换目标。这就是「无感」。
//
//  ============================================================
//  三个技术要点
//
//  1. HTTP 服务器用 Network.framework 的 NWListener，只绑 127.0.0.1（回环），
//     不对局域网暴露。系统框架，不需要额外依赖。
//
//  2. 转发用 URLSession.bytes(for:)（iOS 15+）逐块读，读到就立刻用 chunked
//     写回本地连接 —— SSE 的字是一个一个蹦的，绝不能攒完再发（那样会卡）。
//
//  3. 目标地址由 RelayStore 判定后推过来（setTarget），代理不直接读 SwiftUI
//     的 @Published 状态，避免跨线程的时序问题。
//  ============================================================

import Foundation
import Network

// MARK: - 配置

enum RelayProxyConfig {
    /// 本地监听端口。18923 不与其他常见服务冲突。
    static let port: UInt16 = 18923

    /// 填进 App 服务商「地址」栏的值 —— 用户只需配这一次。
    static let localBaseURL = "http://127.0.0.1:18923"
}

// MARK: - 代理

final class RelayProxy {

    static let shared = RelayProxy()

    // MARK: 线程安全状态

    private let lock = NSLock()
    /// 当前线路的目标 base（带协议，不含路径）。由 RelayStore 判定后推送。
    private var _targetBase = ""
    private var _listener: NWListener?
    private var _running = false
    private var _lastError = ""
    private var _requestCount = 0

    var targetBase: String { lock.lock(); defer { lock.unlock() }; return _targetBase }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _running }
    var lastError: String { lock.lock(); defer { lock.unlock() }; return _lastError }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requestCount }

    /// RelayStore.refresh() 判定完成后调用，把最新线路推给代理。
    func setTarget(_ base: String) {
        lock.lock(); _targetBase = base; lock.unlock()
    }

    private func setRunning(_ running: Bool, error: String) {
        lock.lock()
        _running = running
        _lastError = error
        lock.unlock()
    }

    private static let queue = DispatchQueue(
        label: "minis.relay.proxy",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {}

    // MARK: - 启动

    func start() {
        lock.lock()
        let alreadyRunning = _running
        lock.unlock()
        guard !alreadyRunning else { return }

        // 判定完成前（约 1 秒）先给个兜底目标。选外网域名而不是内网：
        // 判定未完成时用户多半不在家，域名一定能通，只是慢一点；
        // 用内网 IP 当兜底则出门时必然失败。
        if targetBase.isEmpty {
            setTarget("https://\(RelayVault.shared.awayHost)")
        }

        let params = NWParameters.tcp
        // 只绑回环：127.0.0.1，局域网里别的设备连不上这个端口。
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: RelayProxyConfig.port)!
        )

        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.setRunning(true, error: "")
                    relayLog("本地代理已启动 127.0.0.1:\(RelayProxyConfig.port)")
                case .failed(let err):
                    self?.setRunning(false, error: err.localizedDescription)
                    relayLog("本地代理启动失败: \(err)")
                default:
                    break
                }
            }
            lock.lock(); _listener = listener; lock.unlock()
            listener.start(queue: Self.queue)
            relayLog("本地代理正在启动…")
        } catch {
            setRunning(false, error: error.localizedDescription)
            relayLog("本地代理创建失败: \(error)")
        }
    }

    // MARK: - 读请求

    private func handle(_ conn: NWConnection) {
        conn.start(queue: Self.queue)
        readRequest(conn, accumulated: Data())
    }

    /// 循环收数据，直到能解析出一个完整的 HTTP 请求（header + body 都到齐）。
    private func readRequest(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }

            var buf = accumulated
            if let chunk = data, !chunk.isEmpty { buf.append(chunk) }

            if error != nil {
                conn.cancel()
                return
            }

            if let request = HTTPRequest.parse(buf) {
                self.forward(request, on: conn)
                return
            }

            if isComplete {
                conn.cancel()
                return
            }

            // 防呆：请求涨到 4MB 还没解析出完整请求，直接放弃，别无限攒内存。
            if buf.count > 4 * 1024 * 1024 {
                relayLog("代理：请求超过 4MB 仍未完整，放弃")
                conn.cancel()
                return
            }

            self.readRequest(conn, accumulated: buf)
        }
    }

    // MARK: - 转发

    private func forward(_ req: HTTPRequest, on conn: NWConnection) {
        let base = targetBase
        guard !base.isEmpty, let url = URL(string: base + req.target) else {
            relayLog("代理：没有可用目标地址（判定未完成？）")
            sendSimple(conn, status: 503, text: "relay route not ready")
            return
        }

        lock.lock(); _requestCount += 1; lock.unlock()
        relayLog("代理转发 \(req.method) \(req.target) → \(base)")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = req.method
        urlRequest.httpBody = req.body.isEmpty ? nil : req.body

        // 透传 App 的请求头。Authorization 在里面 —— 那是中转站的 Key，
        // 必须原样带过去，否则中转站会拒。
        // 去掉的是 hop-by-hop 和该由 URLSession 自己管的（Host/长度/压缩）。
        let skip: Set<String> = [
            "host", "content-length", "connection", "transfer-encoding",
            "proxy-connection", "keep-alive", "upgrade", "accept-encoding"
        ]
        for (key, value) in req.headers where !skip.contains(key) {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let session = URLSession(configuration: .ephemeral)
        Task {
            do {
                let (bytes, response) = try await session.bytes(for: urlRequest)
                self.writeResponse(conn, response: response, bytes: bytes, session: session)
            } catch {
                relayLog("代理转发失败 \(req.target): \(error.localizedDescription)")
                self.sendSimple(conn, status: 502, text: "upstream error: \(error.localizedDescription)")
                session.invalidateAndCancel()
            }
        }
    }

    // MARK: - 回写响应（chunked，支持 SSE 流式）

    private func writeResponse(conn: NWConnection,
                               response: URLResponse,
                               bytes: URLSession.AsyncBytes,
                               session: URLSession) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200

        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        // 只透传对客户端有意义的头。Content-Length 绝不能透传 —— 我们改用
        // chunked，字节数对不上会让 App 的 URLSession 提前判定流结束。
        let passHeaders: Set<String> = [
            "content-type", "cache-control", "access-control-allow-origin", "x-accel-buffering"
        ]
        let responseHeaders: [AnyHashable: Any] = http?.allHeaderFields ?? [:]
        for (rawKey, rawValue) in responseHeaders {
            guard let key = rawKey as? String, let value = rawValue as? String else { continue }
            if passHeaders.contains(key.lowercased()) {
                head += "\(key): \(value)\r\n"
            }
        }
        head += "Transfer-Encoding: chunked\r\n"
        head += "Connection: close\r\n\r\n"

        conn.send(Data(head.utf8)) { _ in }

        // 用逐字节迭代（AsyncBytes 唯一确定可用的读法，项目里也大量用过）。
        // 实时性策略：**遇到换行就 flush**。SSE 每个 data: 事件都以 \n 结尾，
        // 所以一行一发 = 一个 token 一到就吐给 App，不卡；同时不会像逐字节
        // send 那样产生海量小包。普通 JSON 响应没有换行，靠 8KB 阈值兜底。
        Task {
            do {
                var buffer = Data()
                buffer.reserveCapacity(8 * 1024)
                for try await byte in bytes {
                    buffer.append(byte)
                    if byte == 0x0A || buffer.count >= 8 * 1024 {  // \n 或攒够 8KB
                        conn.send(Self.chunked(buffer)) { _ in }
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                if !buffer.isEmpty {
                    conn.send(Self.chunked(buffer)) { _ in }
                }
                conn.send(Data("0\r\n\r\n".utf8)) { _ in
                    conn.cancel()
                    session.invalidateAndCancel()
                }
            } catch {
                relayLog("代理读响应流出错: \(error.localizedDescription)")
                conn.send(Data("0\r\n\r\n".utf8)) { _ in conn.cancel() }
                session.invalidateAndCancel()
            }
        }
    }

    /// HTTP chunked 编码：一行十六进制长度 + 数据 + CRLF。
    private static func chunked(_ data: Data) -> Data {
        var out = Data()
        out.append(contentsOf: "\(String(data.count, radix: 16))\r\n".utf8)
        out.append(data)
        out.append(contentsOf: "\r\n".utf8)
        return out
    }

    /// 简单错误响应（判定未就绪 / 上游失败时）。
    private func sendSimple(_ conn: NWConnection, status: Int, text: String) {
        let body = Data(text.utf8)
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        conn.send(Data(head.utf8)) { _ in }
        conn.send(body) { _ in conn.cancel() }
    }
}

// MARK: - 极简 HTTP 请求解析

private struct HTTPRequest {
    let method: String
    /// 原始请求目标，形如 /v1/chat/completions?x=1
    let target: String
    let headers: [String: String]
    let body: Data

    /// 从已收到的字节里解析一个完整请求；header 或 body 没到齐就返回 nil。
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headData = data[data.startIndex..<separator.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else { return nil }

        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        let bodyEnd = bodyStart.advanced(by: contentLength)
        guard bodyEnd <= data.endIndex else { return nil }  // body 还没收全

        return HTTPRequest(
            method: method,
            target: target,
            headers: headers,
            body: Data(data[bodyStart..<bodyEnd])
        )
    }
}
