import SwiftUI
import Foundation
import UserNotifications
import AppKit
import Network

// MARK: - Local Clash/Mihomo configuration

struct ControllerConfiguration: Sendable {
  var address: String
  var secret: String
  var groupName: String
  var unixSocket: String

  static func discover() -> ControllerConfiguration {
    let fallback = ControllerConfiguration(
      address: "http://127.0.0.1:9097",
      secret: "",
      groupName: "Proxies",
      unixSocket: "/tmp/verge/verge-mihomo.sock"
    )

    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first

    guard let configURL = appSupport?
      .appendingPathComponent("io.github.clash-verge-rev.clash-verge-rev")
      .appendingPathComponent("config.yaml"),
      let content = try? String(contentsOf: configURL, encoding: .utf8)
    else {
      return fallback
    }

    var controller = "127.0.0.1:9097"
    var secret = ""
    var unixSocket = "/tmp/verge/verge-mihomo.sock"

    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("external-controller:") {
        controller = yamlValue(from: line) ?? controller
      } else if line.hasPrefix("external-controller-unix:") {
        unixSocket = yamlValue(from: line) ?? unixSocket
      } else if line.hasPrefix("secret:") {
        secret = yamlValue(from: line) ?? ""
      }
    }

    if controller.isEmpty {
      controller = "127.0.0.1:9097"
    }
    if !controller.hasPrefix("http://") && !controller.hasPrefix("https://") {
      controller = "http://\(controller)"
    }

    return ControllerConfiguration(
      address: controller,
      secret: secret,
      groupName: UserDefaults.standard.string(forKey: "groupName") ?? "Proxies",
      unixSocket: FileManager.default.fileExists(atPath: "/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock") ? "/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock" : unixSocket
    )
  }

  private static func yamlValue(from line: String) -> String? {
    guard let separator = line.firstIndex(of: ":") else { return nil }
    var value = String(line[line.index(after: separator)...])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if value.count >= 2,
      (value.hasPrefix("\"") && value.hasSuffix("\""))
        || (value.hasPrefix("'") && value.hasSuffix("'"))
    {
      value.removeFirst()
      value.removeLast()
    }
    return value
  }
}

// MARK: - Mihomo controller API

private enum UnixHTTPClient {
  static func send(
    socketPath: String,
    requestPath: String,
    method: String,
    authorization: String?,
    body: Data?
  ) async throws -> (Data, Int) {
    try await withCheckedThrowingContinuation { continuation in
      let connection = NWConnection(
        to: .unix(path: socketPath),
        using: .tcp
      )
      let queue = DispatchQueue(label: "io.local.aiproxy.unix-http")
      var response = Data()
      var completed = false

      func finish(_ result: Result<(Data, Int), Error>) {
        guard !completed else { return }
        completed = true
        connection.cancel()
        continuation.resume(with: result)
      }

      func parseResponse() throws -> (Data, Int) {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = response.range(of: separator) else {
          throw ControllerError.unexpectedResponse
        }

        let headerData = response[..<headerRange.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else {
          throw ControllerError.unexpectedResponse
        }
        let firstLine = header.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
          throw ControllerError.unexpectedResponse
        }

        let bodyStart = headerRange.upperBound
        let rawBody = Data(response[bodyStart...])
        if header.lowercased().contains("transfer-encoding: chunked") {
          return (try decodeChunked(rawBody), status)
        }
        return (rawBody, status)
      }

      func receiveNext() {
        connection.receive(
          minimumIncompleteLength: 1,
          maximumLength: 1_048_576
        ) { data, _, isComplete, error in
          if let data {
            response.append(data)
          }
          if let error {
            finish(.failure(error))
          } else if isComplete {
            do {
              finish(.success(try parseResponse()))
            } catch {
              finish(.failure(error))
            }
          } else {
            receiveNext()
          }
        }
      }

      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          var headers = [
            "\(method) \(requestPath) HTTP/1.1",
            "Host: localhost",
            "Accept: application/json",
            "Connection: close",
          ]
          if let authorization, !authorization.isEmpty {
            headers.append("Authorization: \(authorization)")
          }
          if let body {
            headers.append("Content-Type: application/json")
            headers.append("Content-Length: \(body.count)")
          }

          var payload = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
          if let body {
            payload.append(body)
          }
          connection.send(
            content: payload,
            completion: .contentProcessed { error in
              if let error {
                finish(.failure(error))
              } else {
                receiveNext()
              }
            }
          )
        case let .failed(error):
          finish(.failure(error))
        case .cancelled:
          finish(.failure(ControllerError.unexpectedResponse))
        default:
          break
        }
      }
      connection.start(queue: queue)
    }
  }

  private static func decodeChunked(_ data: Data) throws -> Data {
    var cursor = data.startIndex
    var decoded = Data()
    let lineBreak = Data("\r\n".utf8)

    while cursor < data.endIndex {
      guard let lineRange = data[cursor...].range(of: lineBreak),
        let lengthLine = String(
          data: data[cursor..<lineRange.lowerBound],
          encoding: .utf8
        )
      else {
        throw ControllerError.unexpectedResponse
      }

      let lengthText = lengthLine.split(separator: ";", maxSplits: 1).first ?? ""
      guard let length = Int(lengthText.trimmingCharacters(in: .whitespaces), radix: 16) else {
        throw ControllerError.unexpectedResponse
      }
      cursor = lineRange.upperBound
      if length == 0 { return decoded }
      guard data.distance(from: cursor, to: data.endIndex) >= length + 2 else {
        throw ControllerError.unexpectedResponse
      }
      let end = data.index(cursor, offsetBy: length)
      decoded.append(data[cursor..<end])
      cursor = data.index(end, offsetBy: 2)
    }
    return decoded
  }
}

enum ControllerError: LocalizedError {
  case invalidAddress
  case unexpectedResponse
  case http(Int, String)
  case missingGroup(String)
  case noHealthyNode

  var errorDescription: String? {
    switch self {
    case .invalidAddress:
      return "控制地址无效"
    case .unexpectedResponse:
      return "控制接口返回了无法识别的内容"
    case let .http(code, message):
      return code == 401 ? "控制密钥不正确" : "控制接口错误 \(code)：\(message)"
    case let .missingGroup(name):
      return "找不到代理组 \(name)"
    case .noHealthyNode:
      return "所有候选节点均不可用"
    }
  }
}

struct ProxyGroupResponse: Decodable, Sendable {
  let all: [String]?
  let now: String?
  let type: String?
}

struct ProxyMapResponse: Decodable, Sendable {
  let proxies: [String: ProxyGroupResponse]
}

struct DelayResponse: Decodable, Sendable {
  let delay: Int
}

struct ProviderEnvelope: Decodable, Sendable {
  let providers: [String: ProviderInfo]
}

struct ProviderInfo: Decodable, Sendable {
  let name: String?
  let type: String?
}

struct MihomoClient: Sendable {
  let configuration: ControllerConfiguration

  private var baseURL: URL {
    get throws {
      guard let url = URL(string: configuration.address) else {
        throw ControllerError.invalidAddress
      }
      return url
    }
  }

  private func encodedURL(segments: [String], query: [URLQueryItem] = []) throws -> URL {
    var url = try baseURL
    for segment in segments {
      url.appendPathComponent(segment)
    }
    guard !query.isEmpty else { return url }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw ControllerError.invalidAddress
    }
    components.queryItems = query
    guard let result = components.url else {
      throw ControllerError.invalidAddress
    }
    return result
  }

  private func request(
    _ url: URL,
    method: String = "GET",
    jsonBody: [String: String]? = nil
  ) async throws -> Data {
    let bodyData = try jsonBody.map {
      try JSONSerialization.data(withJSONObject: $0)
    }

    if !configuration.unixSocket.isEmpty,
      FileManager.default.fileExists(atPath: configuration.unixSocket)
    {
      guard let components = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
      ) else {
        throw ControllerError.invalidAddress
      }
      let path = components.percentEncodedPath
        + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
      let (data, status) = try await UnixHTTPClient.send(
        socketPath: configuration.unixSocket,
        requestPath: path,
        method: method,
        authorization: configuration.secret.isEmpty
          ? nil
          : "Bearer \(configuration.secret)",
        body: bodyData
      )
      guard (200...299).contains(status) else {
        let message = String(data: data, encoding: .utf8) ?? ""
        throw ControllerError.http(status, message)
      }
      return data
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 8
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if !configuration.secret.isEmpty {
      request.setValue(
        "Bearer \(configuration.secret)",
        forHTTPHeaderField: "Authorization"
      )
    }
    if let bodyData {
      request.httpBody = bodyData
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    // The user's system proxy is often the same Mihomo instance. A controller
    // request must never be routed back through that proxy or it can loop/fail.
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.connectionProxyDictionary = [:]
    sessionConfiguration.waitsForConnectivity = false
    let session = URLSession(configuration: sessionConfiguration)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ControllerError.unexpectedResponse
    }
    guard (200...299).contains(http.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? ""
      throw ControllerError.http(http.statusCode, message)
    }
    return data
  }

  func nodeNames() async throws -> [String] {
    let data = try await request(try encodedURL(segments: ["proxies"]))
    let map = try JSONDecoder().decode(ProxyMapResponse.self, from: data).proxies
    return map.filter { $0.value.all == nil && !["Direct", "Reject", "RejectDrop", "Pass", "Compatible", "Dns"].contains($0.value.type ?? "") }.keys.sorted()
  }

  func group() async throws -> (name: String, value: ProxyGroupResponse) {
    let url = try encodedURL(segments: ["proxies"])
    let data = try await request(url)
    let map = try JSONDecoder().decode(ProxyMapResponse.self, from: data).proxies

    let preferredNames = [
      configuration.groupName,
      "节点选择",
      "Proxies",
      "Proxy",
      "代理",
      "自动选择",
      "GLOBAL",
    ]

    for name in preferredNames {
      if let value = map[name], value.all != nil {
        return (name, value)
      }
    }

    if let match = map.first(where: { _, value in
      value.all != nil && ["Selector", "Fallback", "URLTest"].contains(value.type ?? "")
    }) {
      return (match.key, match.value)
    }
    throw ControllerError.missingGroup(configuration.groupName)
  }

  // These unauthenticated probes verify service reachability, not an authenticated chat.
  func delay(for proxy: String) async throws -> Int {
    async let api = probe(proxy, url: "https://chatgpt.com/backend-api/models", expected: "401")
    async let socket = probe(proxy, url: "https://ws.chatgpt.com/", expected: "404")
    return try await max(api, socket)
  }

  private func probe(_ proxy: String, url target: String, expected: String) async throws -> Int {
    let url = try encodedURL(segments: ["proxies", proxy, "delay"], query: [
      URLQueryItem(name: "timeout", value: "2800"),
      URLQueryItem(name: "url", value: target),
      // Installed cores may ignore expected; verify the active route separately.
    ])
    let data = try await request(url)
    let result = try JSONDecoder().decode(DelayResponse.self, from: data)
    guard result.delay > 0, result.delay <= 2800 else { throw ControllerError.noHealthyNode }
    return result.delay
  }

  func verifyActiveRoute() async throws {
    let configPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("io.github.clash-verge-rev.clash-verge-rev/config.yaml")
    let config = try String(contentsOf: configPath, encoding: .utf8)
    let line = config.components(separatedBy: .newlines).first { $0.hasPrefix("mixed-port:") }
    guard let port = line.flatMap({ Int($0.dropFirst("mixed-port:".count).trimmingCharacters(in: .whitespaces)) }) else { throw ControllerError.invalidAddress }
    let settings = URLSessionConfiguration.ephemeral
    settings.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port, "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port]
    let session = URLSession(configuration: settings)
    defer { session.invalidateAndCancel() }
    for (target, expected) in [("https://chatgpt.com/backend-api/models", 401), ("https://ws.chatgpt.com/", 404)] {
      var req = URLRequest(url: URL(string: target)!)
      req.timeoutInterval = 2.8
      req.cachePolicy = .reloadIgnoringLocalCacheData
      let (_, response) = try await session.data(for: req)
      guard (response as? HTTPURLResponse)?.statusCode == expected else { throw ControllerError.noHealthyNode }
    }
  }

  private struct Connections: Decodable {
    struct Entry: Decodable {
      struct Metadata: Decodable { let host: String? }
      let id: String
      let metadata: Metadata
      let chains: [String]
    }
    let connections: [Entry]
  }

  func switchTo(_ proxy: String, in groupName: String) async throws {
    let url = try encodedURL(segments: ["proxies", groupName])
    _ = try await request(url, method: "PUT", jsonBody: ["name": proxy])
    // Existing streams keep their old route. Close only related stale streams.
    let data = try await request(try encodedURL(segments: ["connections"]))
    let entries = try JSONDecoder().decode(Connections.self, from: data).connections
    for entry in entries {
      let host = (entry.metadata.host ?? "").lowercased()
      let related = ["chatgpt.com", "openai.com"].contains { host == $0 || host.hasSuffix("." + $0) }
      if related && entry.chains.contains(groupName) && !entry.chains.contains(proxy) {
        _ = try await request(try encodedURL(segments: ["connections", entry.id]), method: "DELETE")
      }
    }

  }

  func refreshProviders() async throws -> Int {
    let listURL = try encodedURL(segments: ["providers", "proxies"])
    let data = try await request(listURL)
    let envelope = try JSONDecoder().decode(ProviderEnvelope.self, from: data)
    let names = envelope.providers.keys.filter { $0 != "default" }

    var refreshed = 0
    for name in names {
      let url = try encodedURL(segments: ["providers", "proxies", name])
      do {
        _ = try await request(url, method: "PUT")
        refreshed += 1
      } catch {
        continue
      }
    }
    return refreshed
  }
}

// MARK: - Monitoring state machine

struct ReconnectRecord: Identifiable, Codable {
  let id: UUID
  let occurredAt: Date
  let fromNode: String
  let toNode: String?
  let delay: Int?
  let succeeded: Bool
  let modeName: String?

  init(
    id: UUID = UUID(),
    occurredAt: Date,
    fromNode: String,
    toNode: String?,
    delay: Int?,
    succeeded: Bool,
    modeName: String? = nil
  ) {
    self.id = id
    self.occurredAt = occurredAt
    self.fromNode = fromNode
    self.toNode = toNode
    self.delay = delay
    self.succeeded = succeeded
    self.modeName = modeName
  }

  var timeText: String {
    occurredAt.formatted(date: .omitted, time: .standard)
  }
}

@MainActor
final class ProxyMonitor: ObservableObject {
  enum Health {
    case connecting
    case healthy
    case warning
    case failed

    var color: Color {
      switch self {
      case .connecting: return .secondary
      case .healthy: return Color(red: 0.20, green: 0.82, blue: 0.48)
      case .warning: return .orange
      case .failed: return .red
      }
    }

    var label: String {
      switch self {
      case .connecting: return "正在连接"
      case .healthy: return "保护中"
      case .warning: return "正在恢复"
      case .failed: return "连接异常"
      }
    }
  }

  @Published var currentNode = "正在读取…"
  @Published var latency: Int?
  @Published var totalChecks = 0
  @Published var successfulChecks = 0
  @Published var consecutiveFailures = 0
  @Published var health: Health = .connecting
  @Published var statusMessage = "正在连接 Clash Verge"
  @Published var autoProtection = true
  @Published var isChecking = false
  @Published var lastCheckedAt: Date?
  @Published var lastHeartbeatSucceeded: Bool?
  @Published var reconnectRecords: [ReconnectRecord] = []

  let failureThreshold = 2
  let checkIntervalSeconds = 3
  struct Sample: Codable { let name: String; let date: Date; let delay: Int? }
  struct PoolNode: Identifiable {
    var id: String { name }
    let name: String; let successes: Int; let total: Int; let delay: Int?
    var rate: Double { Double(successes) / Double(total) }
  }
  @Published var pool: [PoolNode] = []
  @Published var scanStatus = "等待全量测试"
  @Published var isScanning = false
  private var samples: [Sample] = []
  private var availableNames: Set<String> = []
  private var scanTask: Task<Void, Never>?
  private let historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("vpn_autochange/service-tests-v2.jsonl")
  var allPoolNodeNames: Set<String> { Set(pool.map(\.name)) }

  private func rebuildPool() {
    pool = Dictionary(grouping: samples, by: \.name).compactMap { name, rows in
      guard availableNames.contains(name) else { return nil }
      let good = rows.compactMap(\.delay)
      guard !good.isEmpty else { return nil }
      return PoolNode(name: name, successes: good.count, total: rows.count, delay: rows.last?.delay)
    }.sorted {
      if $0.rate != $1.rate { return $0.rate > $1.rate }
      if $0.total != $1.total { return $0.total > $1.total }
      return ($0.delay ?? Int.max, $0.name) < ($1.delay ?? Int.max, $1.name)
    }.prefix(10).map { $0 }
  }

  func scanAll() async {
    guard !isScanning else { return }
    isScanning = true
    defer { isScanning = false }
    let client = MihomoClient(configuration: ControllerConfiguration.discover())
    do {
      let names = try await client.nodeNames()
      availableNames = Set(names)
      for start in stride(from: 0, to: names.count, by: 45) {
        let batch = Array(names[start..<min(start + 45, names.count)])
        let results = await withTaskGroup(of: Sample.self, returning: [Sample].self) { group in
          for name in batch { group.addTask { Sample(name: name, date: Date(), delay: try? await client.delay(for: name)) } }
          var rows: [Sample] = []
          for await row in group { rows.append(row) }
          return rows
        }
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: historyURL.path) { FileManager.default.createFile(atPath: historyURL.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: historyURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for row in results {
          var data = try JSONEncoder().encode(row); data.append(10)
          try handle.write(contentsOf: data)
          samples.append(row)
        }
        rebuildPool()
        scanStatus = "全量测试 \(min(start + 45, names.count))/\(names.count) · 累计 \(samples.count) 条"
      }
    } catch { scanStatus = "全量测试失败：\(error.localizedDescription)" }
  }

  func selectNode(_ name: String) async {
    guard !isChecking else { return }
    isChecking = true
    defer { isChecking = false }
    do {
      let client = MihomoClient(configuration: ControllerConfiguration.discover())
      let group = try await client.group()
      try await client.switchTo(name, in: group.name)
      currentNode = name
      try await client.verifyActiveRoute()
      statusMessage = "已手动切换到 \(name)"
    } catch { statusMessage = error.localizedDescription }
  }

  private var configuration = ControllerConfiguration.discover()
  private var monitorTask: Task<Void, Never>?
  private var hadFailure = false
  private let reconnectRecordsKey = "aiProxyReconnectRecords"

  init() {
    if let data = try? Data(contentsOf: historyURL) { samples = data.split(separator: 10).compactMap { try? JSONDecoder().decode(Sample.self, from: Data($0)) } }
    if
      let data = UserDefaults.standard.data(forKey: reconnectRecordsKey),
      let records = try? JSONDecoder().decode([ReconnectRecord].self, from: data)
    {
      reconnectRecords = Array(records.prefix(20))
    }
  }

  var successRate: Double {
    guard totalChecks > 0 else { return 0 }
    return Double(successfulChecks) / Double(totalChecks) * 100
  }

  var successRateText: String {
    totalChecks == 0 ? "—" : String(format: "%.1f%%", successRate)
  }

  var latencyText: String {
    latency.map { "\($0) ms" } ?? "—"
  }

  var lastCheckedText: String {
    guard let lastCheckedAt else { return "尚未检测" }
    return lastCheckedAt.formatted(date: .omitted, time: .standard)
  }

  var heartbeatLabel: String {
    switch lastHeartbeatSucceeded {
    case .some(true): return "心跳正常"
    case .some(false): return "心跳失败"
    case .none: return "等待心跳"
    }
  }

  var heartbeatColor: Color {
    switch lastHeartbeatSucceeded {
    case .some(true): return Color(red: 0.20, green: 0.82, blue: 0.48)
    case .some(false): return .red
    case .none: return .secondary
    }
  }

  func start() {
    guard monitorTask == nil else { return }
    requestNotificationPermission()
    scanTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.scanAll()
        try? await Task.sleep(for: .seconds(5))
      }
    }
    monitorTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        let began = Date()
        await self.checkNow()
        let remaining = max(0.05, Double(self.checkIntervalSeconds) - Date().timeIntervalSince(began))
        try? await Task.sleep(for: .seconds(remaining))
      }
    }
  }

  func stop() {
    monitorTask?.cancel()
    monitorTask = nil
  }

  func switchToFastestNode() async {
    guard !isChecking else { return }
    isChecking = true
    defer {
      isChecking = false
      lastCheckedAt = Date()
    }

    configuration = ControllerConfiguration.discover()
    let client = MihomoClient(configuration: configuration)
    do {
      let resolvedGroup = try await client.group()
      let oldNode = resolvedGroup.value.now ?? currentNode
      statusMessage = "正在测试 Codex 稳定节点池"
      let candidate = try await bestCandidateWithBackup(
        from: resolvedGroup.value.all ?? [],
        excluding: nil,
        client: client
      )

      if candidate.name != oldNode {
        try await client.switchTo(candidate.name, in: resolvedGroup.name)
        addReconnectRecord(
          from: oldNode,
          to: candidate.name,
          delay: candidate.delay,
          succeeded: true
        )
      }

      currentNode = candidate.name
      try await client.verifyActiveRoute()
      latency = candidate.delay
      consecutiveFailures = 0
      health = .healthy
      statusMessage = candidate.name == oldNode
        ? "当前已是最快的\(candidate.isBackup ? "备选" : "主池")节点"
        : "已切换到最快的\(candidate.isBackup ? "备选" : "主池")节点：\(candidate.name)"
    } catch {
      latency = nil
      health = .failed
      statusMessage = "当前订阅没有可用的稳定节点：\(error.localizedDescription)"
    }
  }

  func checkNow() async {
    guard !isChecking else { return }
    isChecking = true
    defer {
      isChecking = false
      lastCheckedAt = Date()
    }

    configuration = ControllerConfiguration.discover()
    let client = MihomoClient(configuration: configuration)

    do {
      let resolvedGroup = try await client.group()
      let group = resolvedGroup.value
      guard let node = group.now, !node.isEmpty else {
        throw ControllerError.missingGroup(resolvedGroup.name)
      }
      currentNode = node

      do {
        let measuredDelay = try await client.delay(for: node)
        try await client.verifyActiveRoute()
        recordSuccess(delay: measuredDelay)
        if hadFailure {
          hadFailure = false
          statusMessage = "连接已恢复，当前节点稳定"
          sendNotification(
            title: "节点切换已恢复",
            body: "\(node) · \(measuredDelay) ms"
          )
        } else {
          statusMessage = "心跳正常，每 \(checkIntervalSeconds) 秒自动检测"
        }
      } catch {
        await recordFailureAndRecover(
          client: client,
          group: group,
          groupName: resolvedGroup.name
        )
      }
    } catch {
      latency = nil
      lastHeartbeatSucceeded = false
      health = .failed
      statusMessage = error.localizedDescription
    }
  }

  private func recordSuccess(delay: Int) {
    totalChecks += 1
    successfulChecks += 1
    consecutiveFailures = 0
    latency = delay
    lastHeartbeatSucceeded = true
    health = .healthy
  }

  private func recordFailureAndRecover(
    client: MihomoClient,
    group: ProxyGroupResponse,
    groupName: String
  ) async {
    let failedNode = currentNode
    totalChecks += 1
    consecutiveFailures += 1
    latency = nil
    lastHeartbeatSucceeded = false
    hadFailure = true
    health = consecutiveFailures >= failureThreshold ? .warning : .failed

    guard autoProtection else {
      statusMessage = "检测失败；自动保护已暂停"
      return
    }

    guard consecutiveFailures >= failureThreshold else {
      statusMessage = "节点检测失败 \(consecutiveFailures)/\(failureThreshold)"
      return
    }

    statusMessage = "连续失败 \(failureThreshold) 次，正在寻找其他稳定节点"

    do {
      let candidate = try await bestCandidateWithBackup(
        from: group.all ?? [],
        excluding: currentNode,
        client: client
      )
      try await client.switchTo(candidate.name, in: groupName)
      currentNode = candidate.name
      try await client.verifyActiveRoute()
      latency = candidate.delay
      consecutiveFailures = 0
      successfulChecks += 1
      health = .healthy
      statusMessage = candidate.isBackup
        ? "主池不可用，已切换到备选节点 \(candidate.name)"
        : "已自动切换到 \(candidate.name)"
      hadFailure = false
      addReconnectRecord(
        from: failedNode,
        to: candidate.name,
        delay: candidate.delay,
        succeeded: true
      )
      sendNotification(
        title: "节点切换已自动切换",
        body: "\(candidate.name) · \(candidate.delay) ms"
      )
    } catch {
      addReconnectRecord(
        from: failedNode,
        to: nil,
        delay: nil,
        succeeded: false
      )
      health = .warning
      statusMessage = "前十节点暂不可用，等待全量检测更新"

    }
  }

  private func addReconnectRecord(
    from: String,
    to: String?,
    delay: Int?,
    succeeded: Bool
  ) {
    reconnectRecords.insert(
      ReconnectRecord(
        occurredAt: Date(),
        fromNode: from,
        toNode: to,
        delay: delay,
        succeeded: succeeded,
        modeName: "Codex 稳定节点池"
      ),
      at: 0
    )
    if reconnectRecords.count > 20 {
      reconnectRecords.removeLast(reconnectRecords.count - 20)
    }
    if let data = try? JSONEncoder().encode(reconnectRecords) {
      UserDefaults.standard.set(data, forKey: reconnectRecordsKey)
    }
  }

  private func bestCandidate(
    from all: [String],
    excluding current: String?,
    client: MihomoClient,
    allowedNodeNames: Set<String>
  ) async throws -> (name: String, delay: Int) {
    let ignored = Set(["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"])
    let candidates = Array(Set(all
      .filter { name in
        (current == nil || name != current)
          && allowedNodeNames.contains(name)
          && !ignored.contains(name.uppercased())
      }))

    // Avoid flooding Mihomo's delay endpoint. Large simultaneous batches can
    // make otherwise fast nodes time out and distort the winner.
    var results: [(String, Int)] = []
    let batchSize = 8
    for start in stride(from: 0, to: candidates.count, by: batchSize) {
      let end = min(start + batchSize, candidates.count)
      let batch = Array(candidates[start..<end])
      let batchResults = await withTaskGroup(
        of: (String, Int)?.self,
        returning: [(String, Int)].self
      ) { group in
        for name in batch {
          group.addTask {
            guard let delay = try? await client.delay(for: name) else { return nil }
            return (name, delay)
          }
        }

        var healthy: [(String, Int)] = []
        for await result in group {
          if let result {
            healthy.append(result)
          }
        }
        return healthy
      }
      results.append(contentsOf: batchResults)
    }

    guard let best = results.min(by: { $0.1 < $1.1 }) else { throw ControllerError.noHealthyNode }
    return (best.0, best.1)
  }

  private func bestCandidateWithBackup(
    from all: [String],
    excluding current: String?,
    client: MihomoClient
  ) async throws -> (name: String, delay: Int, isBackup: Bool) {
    let best = try await bestCandidate(from: all, excluding: current, client: client, allowedNodeNames: allPoolNodeNames)
    return (best.name, best.delay, false)
  }

  private func requestNotificationPermission() {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound]
    ) { _, _ in }
  }

  private func sendNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
  }
}

// MARK: - Interface

struct MetricCard: View {
  let title: String
  let value: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 20, weight: .semibold, design: .rounded))
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.primary.opacity(0.055))
    )
  }
}

struct FlowStep: View {
  let label: String
  let detail: String
  let accent: Color

  var body: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(accent.opacity(0.18))
        .frame(width: 30, height: 30)
        .overlay(
          Circle()
            .fill(accent)
            .frame(width: 8, height: 8)
        )

      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.system(size: 13, weight: .semibold))
        Text(detail)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .fill(Color.primary.opacity(0.045))
    )
  }
}

struct ContentView: View {
  @ObservedObject var monitor: ProxyMonitor

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.055, green: 0.070, blue: 0.10),
          Color(red: 0.08, green: 0.095, blue: 0.14),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      Circle()
        .fill(Color.blue.opacity(0.12))
        .frame(width: 330, height: 330)
        .blur(radius: 90)
        .offset(x: 170, y: -250)

      ScrollView {
        VStack(spacing: 18) {
          header
          stablePoolSummary
          nodeCard
          metrics
          protectionFlow
          footer
          reconnectHistory
        }
        .padding(24)
      }
    }
    .frame(minWidth: 430, idealWidth: 460, minHeight: 670, idealHeight: 720)
    .preferredColorScheme(.dark)
    .task {
      monitor.start()
    }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("节点切换")
          .font(.system(size: 28, weight: .bold, design: .rounded))
        Text("心跳检测 · 故障转移 · 恢复通知")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
      }

      Spacer()

      Toggle("", isOn: $monitor.autoProtection)
        .toggleStyle(.switch)
        .labelsHidden()
        .help("自动保护")
    }
  }

  private var nodeCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        HStack(spacing: 8) {
          Circle()
            .fill(monitor.health.color)
            .frame(width: 10, height: 10)
            .shadow(color: monitor.health.color.opacity(0.7), radius: 6)
          Text(monitor.health.label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(monitor.health.color)
        }
        Spacer()
        HStack(spacing: 5) {
          Image(systemName: "heart.fill")
            .foregroundStyle(monitor.heartbeatColor)
          Text("\(monitor.heartbeatLabel) · \(monitor.checkIntervalSeconds) 秒")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 5) {
        Text("当前节点")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
        Text(monitor.currentNode)
          .font(.system(size: 24, weight: .bold, design: .rounded))
          .lineLimit(1)
          .minimumScaleFactor(0.65)
      }
    }
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(monitor.health.color.opacity(0.22), lineWidth: 1)
        )
    )
  }

  private var stablePoolSummary: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("双目标网络探测前十 · 双击切换").font(.headline)
        Spacer()
        Button("全量测试") { Task { await monitor.scanAll() } }.disabled(monitor.isScanning)
      }
      Text("历史探测率不代表对话成功率；当前路径另做 HTTP 校验").font(.caption).foregroundStyle(.secondary)
      Text(monitor.scanStatus).font(.caption).foregroundStyle(.secondary)
      ForEach(monitor.pool) { node in
        HStack {
          Text(node.name).lineLimit(1)
          Spacer()
          Text(String(format: "%.1f%%", node.rate * 100))
          Text("\(node.successes)/\(node.total)").foregroundStyle(.secondary)
          Text(node.delay.map { "\($0) ms" } ?? "失败")
        }
        .font(.system(size: 11)).padding(5)
        .background(node.name == monitor.currentNode ? Color.blue.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await monitor.selectNode(node.name) } }
      }
    }.padding(15)
  }

  private var metrics: some View {
    LazyVGrid(
      columns: [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
      ],
      spacing: 10
    ) {
      MetricCard(
        title: "延迟",
        value: monitor.latencyText,
        tint: monitor.health.color
      )
      MetricCard(
        title: "成功率",
        value: monitor.successRateText,
        tint: Color(red: 0.38, green: 0.70, blue: 1)
      )
      MetricCard(
        title: "连续失败",
        value: "\(monitor.consecutiveFailures)",
        tint: monitor.consecutiveFailures == 0 ? .white : .orange
      )
    }
  }

  private var protectionFlow: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("自动保护流程")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 2)

      FlowStep(
        label: "连续失败 \(monitor.failureThreshold) 次",
        detail: "只检测当前订阅中的 Codex 稳定节点",
        accent: .orange
      )

      Image(systemName: "arrow.down")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)

      FlowStep(
        label: "自动切节点",
        detail: "优先切换到延迟最低的主池节点",
        accent: .blue
      )

      Image(systemName: "arrow.down")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)

      FlowStep(
        label: "主池全部失败",
        detail: "启用二级备选池并选择最快可用节点",
        accent: .purple
      )

      Image(systemName: "arrow.down")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)

      FlowStep(
        label: "两级节点池全部失败",
        detail: "重新拉取订阅；恢复后发送系统通知",
        accent: Color(red: 0.20, green: 0.82, blue: 0.48)
      )
    }
  }

  private var footer: some View {
    VStack(spacing: 12) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "info.circle")
          .foregroundStyle(.secondary)
        Text(monitor.statusMessage)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Text("上次心跳：\(monitor.lastCheckedText)")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)

        Spacer()

        Button {
          Task { await monitor.checkNow() }
        } label: {
          HStack(spacing: 6) {
            if monitor.isChecking {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "arrow.clockwise")
            }
            Text("立即检测")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(monitor.isChecking)
      }
    }
  }

  private var reconnectHistory: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack {
        Text("重连记录")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Text("最近 \(monitor.reconnectRecords.count) 条")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
      }

      if monitor.reconnectRecords.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "clock.arrow.circlepath")
          Text("暂无重连记录")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
      } else {
        ForEach(monitor.reconnectRecords.prefix(10)) { record in
          HStack(spacing: 10) {
            Circle()
              .fill(record.succeeded ? Color.green : Color.red)
              .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 3) {
              if let toNode = record.toNode {
                Text("\(record.fromNode) → \(toNode)")
                  .lineLimit(1)
                  .minimumScaleFactor(0.72)
              } else {
                Text(
                  "\(record.fromNode) → 未找到可用\(record.modeName ?? "稳定节点")"
                )
                  .lineLimit(1)
                  .minimumScaleFactor(0.72)
              }

              Text(record.timeText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .medium))

            Spacer(minLength: 8)

            Text(
              record.succeeded
                ? record.delay.map { "\($0) ms" } ?? "成功"
                : "失败"
            )
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(record.succeeded ? Color.green : Color.red)
          }

          if record.id != monitor.reconnectRecords.prefix(10).last?.id {
            Divider().opacity(0.45)
          }
        }
      }
    }
    .padding(15)
    .background(
      RoundedRectangle(cornerRadius: 15, style: .continuous)
        .fill(Color.primary.opacity(0.045))
    )
  }
}

struct MenuBarContent: View {
  @ObservedObject var monitor: ProxyMonitor
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(monitor.currentNode)
        .font(.headline)
      Text("\(monitor.latencyText) · \(monitor.health.label)")
        .foregroundStyle(.secondary)
      Divider()
      Button("切换到最快稳定节点") {
        Task { await monitor.switchToFastestNode() }
      }
      Divider()
      Button("立即检测") {
        Task { await monitor.checkNow() }
      }
      Button("打开节点切换") {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
      }
      Divider()
      Button("退出") {
        NSApp.terminate(nil)
      }
    }
    .padding(8)
    .frame(width: 220)
  }
}

@main
struct AIProxyApp: App {
  @StateObject private var monitor = ProxyMonitor()

  var body: some Scene {
    Window("节点切换", id: "main") {
      ContentView(monitor: monitor)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)

    MenuBarExtra("节点切换", systemImage: "network") {
      MenuBarContent(monitor: monitor)
    }
  }
}
