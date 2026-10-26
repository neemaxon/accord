//
//  Gateway.swift
//  Accord
//
//  Created by evelyn on 2022-01-01.
//

import AppKit // Necessary for the locale & architecture
import Combine
import Foundation
import Network

var hasReset: Bool = false

// The second version of Accord's gateway.
// This uses Network.framework instead of URLSessionWebSocketTask
final class Gateway {
    private(set) var connection: NWConnection?
    private(set) var sessionID: String?

    internal var pendingHeartbeat: Bool = false
    internal var seq: Int = 0
    internal var bag = Set<AnyCancellable>()

    // To communicate with the view
    private(set) var messageSubject = PassthroughSubject<(Data, String, Bool), Never>()
    private(set) var editSubject = PassthroughSubject<(Data, String), Never>()
    private(set) var deleteSubject = PassthroughSubject<(Data, String), Never>()
    private(set) var typingSubject = PassthroughSubject<(Data, String), Never>()
    private(set) var memberChunkSubject = PassthroughSubject<Data, Never>()
    private(set) var memberListSubject = PassthroughSubject<MemberListUpdate, Never>()

    var presencePipeline = [String: PassthroughSubject<PresenceUpdate, Never>]()
            
    private(set) var stateUpdateHandler: (NWConnection.State) -> Void = { state in
        switch state {
        case .ready:
            print("Ready up")
        case .cancelled:
            print("Connection cancelled, what happened?")
            wss.hardReset()
        case let .failed(error):
            print("Connection failed \(error.debugDescription)")
        case .preparing:
            print("Preparing")
        case let .waiting(error):
            print("Spinning infinitely \(error.debugDescription)")
        case .setup:
            print("Setting up")
        @unknown default:
            fatalError()
        }
    }

    func closeMessageHandler(_ message: String?) {
        guard let message = message?.lowercased() else {
            return
        }

        if (message.contains("not authenticated") || message.contains("authentication failed")) && !hasReset {
            logOut()
        }
    }

    private let socketEndpoint: NWEndpoint
    internal let compress: Bool

    enum GatewayErrors: Error {
        case noStringData(String)
        case essentialEventFailed(String)
        case eventCorrupted
        case unknownEvent(String)
        case heartbeatMissed
        case noToken
        case closed(code: Int?, reason: String?)

        var localizedDescription: String {
            switch self {
            case .noToken:
                return "No valid token found. Please log in again."
            case let .closed(code, reason):
                let codeText = code.map { "\($0)" } ?? "unknown"
                return "Discord closed the connection (code \(codeText))" + (reason.map { ": \($0)" } ?? "")
            case let .essentialEventFailed(event):
                return "Essential Gateway Event failed: \(event)"
            case let .noStringData(string):
                return "Invalid data \(string)"
            case .eventCorrupted:
                return "Bad event sent"
            case let .unknownEvent(event):
                return "Unknown event: \(event)"
            case .heartbeatMissed:
                return "Heartbeat ACK missed"
            }
        }
    }

    private let additionalHeaders: [(String, String)] = [
        // Host is set by Network.framework itself; a second Host header (and the old
        // Accept-Encoding/Pragma) can make the edge drop the connection right after the upgrade.
        ("User-Agent", discordUserAgent),
        ("Origin", "https://discord.com"),
        ("Cache-Control", "no-cache"),
        ("Accept-Language", "en-US,en;q=0.9"),
    ]

    static var gatewayURL: URL = .init(string: "wss://gateway.discord.gg/?v=9&encoding=json")!

    internal var decompressor = ZStream()

    public var presences: [Activity] = []

    init(
        url: URL = Gateway.gatewayURL,
        session_id: String? = nil,
        seq: Int? = nil,
        compress: Bool = true,
        decompressor: ZStream? = nil
    ) throws {
        if let session_id, let seq {
            self.sessionID = session_id
            self.seq = seq
        }
        if let decompressor = decompressor {
            self.decompressor = decompressor
        }
        if compress {
            socketEndpoint = NWEndpoint.url(URL(string: "wss://gateway.discord.gg/?v=9&encoding=json&compress=zlib-stream")!)
            print("Connecting with stream compression enabled")
        } else {
            socketEndpoint = NWEndpoint.url(url)
        }
        let parameters: NWParameters = .tls
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 1_000_000_000
        wsOptions.setAdditionalHeaders(additionalHeaders)
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        connection = NWConnection(to: socketEndpoint, using: parameters)
        connection?.stateUpdateHandler = stateUpdateHandler
        self.compress = compress
        try connect(session_id, seq)
    }

    private func connect(_ session_id: String? = nil, _ seq: Int? = nil) throws {
        connection?.start(queue: concurrentQueue)
        hello(session_id, seq)
    }

    private func hello(_ session_id: String? = nil, _ seq: Int? = nil) {
        guard connection?.state != .cancelled else { return } // Don't listen for hello if there is no connection
        connection?.receiveMessage { [weak self] data, context, _, error in
            guard let self = self else { return }

            print("Got HELLO")

            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata

            if let metadata, metadata.opcode == .close {
                let reason = data.flatMap { String(data: $0, encoding: .utf8) }
                let code = Gateway.closeCodeValue(metadata.closeCode)
                print("[Gateway] Closed instead of HELLO, code \(code): \(reason ?? "<no reason>")")
                self.readyFailure = GatewayErrors.closed(code: code, reason: reason)
                return
            }

            if let error = error {
                print("[Gateway] HELLO receive error:", error)
                self.readyFailure = error
                return
            }

            guard let data, !data.isEmpty else {
                print("[Gateway] HELLO: empty message, opcode \(String(describing: metadata?.opcode))")
                self.readyFailure = GatewayErrors.essentialEventFailed("HELLO (empty message)")
                return self.close(.protocolCode(.protocolError))
            }

            // Text frames are plain JSON even when compression was requested;
            // binary frames are zlib-stream compressed.
            var payload = data
            if metadata?.opcode == .binary || (self.compress && data.first != UInt8(ascii: "{")) {
                if let decompressed = try? self.decompressor.decompress(data: data), !decompressed.isEmpty {
                    payload = decompressed
                } else {
                    print("[Gateway] HELLO: failed to decompress \(data.count) bytes, first bytes: \(data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))")
                }
            }

            guard let hello = try? JSONSerialization.jsonObject(with: payload, options: []) as? [String: Any],
                  let helloD = hello["d"] as? [String: Any],
                  let interval = (helloD["heartbeat_interval"] as? NSNumber)?.intValue
            else {
                let preview = String(data: payload.prefix(300), encoding: .utf8) ?? "<\(payload.count) bytes binary: \(payload.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))>"
                print("Failed to get a heartbeat interval. opcode: \(String(describing: metadata?.opcode)), payload: \(preview)")
                self.readyFailure = GatewayErrors.essentialEventFailed("HELLO: " + String(preview.prefix(120)))
                return self.close(.protocolCode(.protocolError))
            }
            DispatchQueue.main.async {
                Timer.publish(
                    every: Double(interval / 1000),
                    tolerance: nil,
                    on: .main,
                    in: .default
                )
                .autoconnect()
                .sink { [weak self] _ in
                    wssThread.async {
                        do {
                            print("Heartbeating")
                            try self?.heartbeat()
                        } catch {
                            print("Error sending heartbeat", error)
                        }
                    }
                }
                .store(in: &self.bag)
            }
            do {
                if let session_id = session_id, let seq = seq {
                    print("resuming")
                    try self.reconnect(session_id: session_id, seq: seq)
                } else {
                    try self.identify()
                }
            } catch {
                print(error)
            }
        }
    }

    private func listen() {
        guard connection?.state != .cancelled else { print("wtf"); return }
        connection?.receiveMessage { [weak self] data, context, _, error in
            guard let self = self else { return }
            if let error = error {
                print(error)
            } else {
                self.listen()
            }
            guard let data = data else {
                return print(context as Any, data as Any)
            }
            if let info = context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata {
                if info.opcode == .close {
                    if let closeMessage = String(data: data, encoding: .utf8) {
                        print("Closed with \(closeMessage)")
                        self.closeMessageHandler(closeMessage)
                    } else {
                        print("Closed with unknown close code")
                    }
                    wss.reset()
                    return
                }
            }
            if self.compress {
                self.decompressor.decompressionQueue.sync {
                    guard let data = try? self.decompressor.decompress(data: data) else { return }
                    wssThread.async {
                        do {
                            let event = try GatewayEvent(data: data)
                            try self.handleMessage(event: event)
                        } catch {
                            // A single event Accord can't parse (new event types, changed payloads)
                            // must not tear down the whole connection.
                            print("[Gateway] failed to handle event:", error)
                        }
                    }
                }
            } else {
                wssThread.async {
                    do {
                        let event = try GatewayEvent(data: data)
                        try self.handleMessage(event: event)
                    } catch {
                        print(error)
                    }
                }
            }
        }
    }

    private func identify() throws {
        let token: String? = {
            let candidates: [String?] = [
                KeychainManager.load(key: keychainItemName).flatMap { String(data: $0, encoding: .utf8) },
                Globals.token,
            ]
            return candidates
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty && AppGlobals.validateToken($0) })
        }()
        guard let token else {
            print("[Gateway] No valid token available, cannot IDENTIFY")
            readyFailure = GatewayErrors.noToken
            close(.protocolCode(.normalClosure))
            return
        }
        let packet: [String: Any] = [
            "op": 2,
            "d": [
                "token": token,
                // Same capability set as the classic READY layout Accord's models understand:
                // LAZY_USER_NOTES | VERSIONED_READ_STATES | VERSIONED_USER_GUILD_SETTINGS |
                // DEDUPE_USER_OBJECTS | PRIORITIZED_READY_PAYLOAD | MULTIPLE_GUILD_EXPERIMENT_POPULATIONS |
                // NON_CHANNEL_READ_STATES
                "capabilities": 253,
                "compress": false,
                "client_state": [
                    "guild_versions": [String: Any](),
                ] as [String : Any],
                "presence": [
                    "activities": [Any](),
                    "afk": false,
                    "since": 0,
                    "status": "online",
                ] as [String : Any],
                "properties": discordClientProperties(gateway: true),
            ] as [String : Any],
        ]
        try send(json: packet)
    }

    private func heartbeat() throws {
        let packet: [String: Any] = [
            "op": 1,
            "d": seq,
        ]
        try send(json: packet)
        pendingHeartbeat = true
    }

    /// Set when something goes wrong before READY so the UI can show a meaningful error
    internal var readyFailure: Error?

    func ready() -> Future<GatewayD, Error> {
        Future { [weak self] promise in
            guard let self else { return }
            self.receiveReady(promise: promise)
        }
    }

    static func closeCodeValue(_ code: NWProtocolWebSocket.CloseCode) -> Int {
        switch code {
        case let .protocolCode(defined): return Int(defined.rawValue)
        case let .applicationCode(value): return Int(value)
        case let .privateCode(value): return Int(value)
        @unknown default: return -1
        }
    }

    private func failReady(_ promise: @escaping (Result<GatewayD, Error>) -> Void, _ error: Error) {
        print("[Gateway] READY failed:", error)
        promise(.failure(error))
    }

    /// Waits for the READY dispatch. Any other packet received before it (heartbeat ACKs,
    /// new event types, etc.) is skipped instead of being treated as a failed READY.
    private func receiveReady(promise: @escaping (Result<GatewayD, Error>) -> Void) {
        guard connection?.state != .cancelled else {
            return failReady(promise, readyFailure ?? GatewayErrors.essentialEventFailed("READY"))
        }
        connection?.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata

            if let metadata, metadata.opcode == .close {
                let reason = data.flatMap { String(data: $0, encoding: .utf8) }
                let code = Gateway.closeCodeValue(metadata.closeCode)
                print("[Gateway] Closed before READY with code \(code): \(reason ?? "<no reason>")")
                self.closeMessageHandler(reason)
                return self.failReady(promise, self.readyFailure ?? GatewayErrors.closed(code: code, reason: reason))
            }
            if let error {
                print("[Gateway] receive error before READY:", error)
                return self.failReady(promise, self.readyFailure ?? error)
            }
            guard let metadata, let data, !data.isEmpty else {
                return self.failReady(promise, self.readyFailure ?? GatewayErrors.essentialEventFailed("READY"))
            }
            switch metadata.opcode {
            case .text:
                self.handleReadyPayload(data, promise: promise)
            case .binary:
                self.decompressor.decompressionQueue.async {
                    do {
                        let decompressed = try self.decompressor.decompress(data: data, large: true)
                        self.handleReadyPayload(decompressed, promise: promise)
                    } catch {
                        self.failReady(promise, error)
                    }
                }
            default:
                self.receiveReady(promise: promise)
            }
        }
    }

    private func handleReadyPayload(_ data: Data, promise: @escaping (Result<GatewayD, Error>) -> Void) {
        guard let packet = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            print("[Gateway] Undecodable packet before READY, skipping")
            return receiveReady(promise: promise)
        }
        let t = packet["t"] as? String
        let op = packet["op"] as? Int
        if let s = packet["s"] as? Int {
            seq = s
        }
        if op == 9 { // INVALID_SESSION
            return failReady(promise, GatewayErrors.closed(code: nil, reason: "Invalid session"))
        }
        guard t == "READY" else {
            print("[Gateway] Skipping \(t ?? "op \(op ?? -1)") while waiting for READY")
            return receiveReady(promise: promise)
        }
        wssThread.async { [weak self] in
            guard let self else { return }
            let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("socketOut.json")
            try? data.write(to: path)
            do {
                let structure = try JSONDecoder().decode(GatewayStructure.self, from: data)
                try? self.updateVoiceState(guildID: nil, channelID: nil)
                wssThread.async {
                    self.listen()
                }
                print("Hello, \(structure.d.user.username) !!")
                self.sessionID = structure.d.session_id
                print("Connected with session ID", structure.d.session_id)
                promise(.success(structure.d))
            } catch {
                print("[Gateway] Failed to decode READY (raw payload saved to \(path.path)):", error)
                promise(.failure(error))
            }
        }
    }

    func updatePresence(status: String, since: Int, @ActivityBuilder _ activities: () -> [Activity]) throws {
        try updatePresence(status: status, since: since, activities: activities())
    }

    func updatePresence(status: String, since: Int, activities: [Activity]) throws {
        presences = activities
        let packet: [String: Any] = [
            "op": 3,
            "d": [
                "status": status,
                "since": since,
                "activities": activities.map(\.dictValue),
                "afk": false,
            ] as [String : Any],
        ]
        try send(json: packet)
    }

    func reconnect(session_id: String? = nil, seq: Int? = nil) throws {
        guard let token = Globals.token else { throw "No token" }
        let packet: [String: Any] = [
            "op": 6,
            "d": [
                "seq": seq ?? self.seq,
                "session_id": session_id ?? sessionID ?? "",
                "token": token,
            ] as [String : Any],
        ]
        try send(json: packet)
        wssThread.async {
            self.listen()
        }
    }

    func subscribe(to guild: String) throws {
        guard guild != "@me" else { return }
        let packet: [String: Any] = [
            "op": 14,
            "d": [
                "guild_id": guild,
                "typing": true,
                "activities": true,
                "threads": true,
            ] as [String : Any],
        ]
        try send(json: packet)
    }

    var requestedMemberListsForGuilds: Set<String> = .init()
    
    func subscribeWithList(for guild: String, in channel: String, channels: [[Int]] = [[0, 99]]) throws {
        guard !requestedMemberListsForGuilds.contains(guild) else { return }
        self.requestedMemberListsForGuilds.insert(guild)
        print("requesting subscribing list")
        let packet: [String: Any] = [
            "op": 14,
            "d": [
                "typing": true,
                "activities": true,
                "threads": true,
                "guild_id": guild,
                "members":[],
                "thread_member_lists":[],
                "channels": [
                    channel: channels,
                ],
            ],
        ]
        try send(json: packet)
    }
    
    func memberList(for guild: String, in channel: String? = nil, thread: String? = nil, channels: [[Int]] = [[0, 99]]) throws {
        guard guild != "@me" else { return }
        var d: [String : Any] = [
            "guild_id": guild,
        ]
        
        if let thread {
            d["thread_member_lists"] = [thread]
        } else if let channel {
            d["channels"] = [
                channel: channels,
            ]
        }
        
        let packet: [String: Any] = [
            "op": 14,
            "d": d
        ]
        
        try send(json: packet)
    }

    func subscribeToDM(_ channel: String) throws {
        let packet: [String: Any] = [
            "op": 13,
            "d": [
                "channel_id": channel,
            ],
        ]
        try send(json: packet)
    }

    func getMembers(ids: [String], guild: String) throws {
        let packet: [String: Any] = [
            "op": 8,
            "d": [
                "limit": 0,
                "user_ids": ids,
                "guild_id": guild,
            ] as [String : Any],
        ]
        try send(json: packet)
    }

    func getCommands(guildID: String, commandIDs: [String] = [], limit: Int = 10) throws {
        let packet: [String: Any] = [
            "op": 24,
            "d": [
                "applications": true,
                "command_ids": commandIDs,
                "guild_id": guildID,
                "limit": limit,
                "locale": NSNull(),
                "nonce": generateFakeNonce(),
                "offset": 0,
                "type": 1,
            ] as [String : Any],
        ]
        try send(json: packet)
    }

    func getCommands(guildID: String, query: String, limit: Int = 10) throws {
        let packet: [String: Any] = [
            "op": 24,
            "d": [
                "locale": NSNull(),
                "query": query,
                "guild_id": guildID,
                "limit": limit,
                "nonce": generateFakeNonce(),
                "type": 1,
            ] as [String : Any],
        ]
        try send(json: packet)
    }

    func listenForPresence(userID: String, action: @escaping ((PresenceUpdate) -> Void)) {
        presencePipeline[userID] = .init()
        presencePipeline[userID]?.sink(receiveValue: action).store(in: &bag)
    }

    func unregisterPresence(userID: String) {
        presencePipeline.removeValue(forKey: userID)
    }

    // cleanup
    deinit {
        self.bag.invalidateAll()
    }
}

@resultBuilder
enum ActivityBuilder {
    static func buildBlock() -> [Activity] { [] }
}

extension ActivityBuilder {
    static func buildBlock(_ activities: Activity...) -> [Activity] {
        activities
    }
}
