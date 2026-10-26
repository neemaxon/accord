//
//  Settings.swift
//  Settings
//
//  Created by evelyn on 2021-08-27.
//

import Foundation

class DiscordSettings: ObservableObject, Decodable {
    internal init() {
        self.theme = .dark
        self.status = ""
        self.render_reactions = nil
        self.render_embeds = nil
        self.message_display_compact = nil
        self.inline_embed_media = nil
        self.inline_attachment_media = nil
        self.gif_auto_play = nil
        self.guild_positions = []
        self.custom_status = nil
        self.animate_stickers = nil
        self.animate_emoji = nil
        self.afk_timeout = nil
        self.guild_folders = []
    }
    
    var theme: SyncedTheme
    var status: String
    var render_reactions: Bool?
    var render_embeds: Bool?
    var message_display_compact: Bool?
    var inline_embed_media: Bool?
    var inline_attachment_media: Bool?
    @DefaultEmptyArray
    var guild_positions: [String]
    var guild_folders: [GuildFolder]
    var gif_auto_play: Bool?
    var custom_status: Status?
    // var convert_emoticons: Bool?
    // var contact_sync_enabled: Bool?
    var animate_stickers: Int?
    var animate_emoji: Bool?
    // var allow_accessibility_detection: Bool?
    var afk_timeout: Int?

    private enum CodingKeys: String, CodingKey {
        case theme, status, render_reactions, render_embeds, message_display_compact,
             inline_embed_media, inline_attachment_media, guild_positions, guild_folders,
             gif_auto_play, custom_status, animate_stickers, animate_emoji, afk_timeout
    }

    // Lenient decoding: one changed/unknown field (e.g. theme "darker"/"midnight") must not
    // make the whole READY payload fail.
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? c.decodeIfPresent(SyncedTheme.self, forKey: .theme)) ?? .dark
        status = ((try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil) ?? "online"
        render_reactions = (try? c.decodeIfPresent(Bool.self, forKey: .render_reactions)) ?? nil
        render_embeds = (try? c.decodeIfPresent(Bool.self, forKey: .render_embeds)) ?? nil
        message_display_compact = (try? c.decodeIfPresent(Bool.self, forKey: .message_display_compact)) ?? nil
        inline_embed_media = (try? c.decodeIfPresent(Bool.self, forKey: .inline_embed_media)) ?? nil
        inline_attachment_media = (try? c.decodeIfPresent(Bool.self, forKey: .inline_attachment_media)) ?? nil
        guild_positions = ((try? c.decodeIfPresent([String].self, forKey: .guild_positions)) ?? nil) ?? []
        guild_folders = ((try? c.decodeIfPresent([GuildFolder].self, forKey: .guild_folders)) ?? nil) ?? []
        gif_auto_play = (try? c.decodeIfPresent(Bool.self, forKey: .gif_auto_play)) ?? nil
        custom_status = (try? c.decodeIfPresent(Status.self, forKey: .custom_status)) ?? nil
        animate_stickers = (try? c.decodeIfPresent(Int.self, forKey: .animate_stickers)) ?? nil
        animate_emoji = (try? c.decodeIfPresent(Bool.self, forKey: .animate_emoji)) ?? nil
        afk_timeout = (try? c.decodeIfPresent(Int.self, forKey: .afk_timeout)) ?? nil
    }
}

final class GuildFolder: Decodable, Hashable {
    internal init(name: String? = nil, color: Int? = nil, guild_ids: [String]) {
        self.name = name
        self.color = color
        self.guild_ids = guild_ids
    }

    static func == (lhs: GuildFolder, rhs: GuildFolder) -> Bool {
        lhs.guild_ids == rhs.guild_ids && lhs.guilds == rhs.guilds
    }

    var id: String { UUID().uuidString }
    var name: String?
    var color: Int?
    var guild_ids: [String]
    @DefaultEmptyArray
    var guilds: Array<Guild>

    var unreadMessages: Bool {
        guilds
            .map { Accord.unreadMessages(guild: $0) }
            .contains(true)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(guilds)
    }
}

enum SyncedTheme: String, Codable {
    case dark
    case light

    // Discord now also has "darker", "midnight", etc. — treat anything that isn't light as dark
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "light" ? .light : .dark
    }
}

// MARK: - Protobuf settings (user_settings_proto)
//  Discord no longer sends the JSON user_settings object in READY; settings come as a base64
//  PreloadedUserSettings protobuf. Minimal dependency-free reader for the fields Accord uses
//  (field numbers from DiscordKit's generated protos).

struct ProtoReader {
    enum WireValue {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    private let data: [UInt8]
    private var index = 0

    init(_ data: Data) {
        self.data = [UInt8](data)
    }

    var isAtEnd: Bool { index >= data.count }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.count, shift < 64 {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func readFixed64() -> UInt64? {
        guard index + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(data[index + i]) << (8 * UInt64(i)) }
        index += 8
        return value
    }

    mutating func readFixed32() -> UInt32? {
        guard index + 4 <= data.count else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(data[index + i]) << (8 * UInt32(i)) }
        index += 4
        return value
    }

    /// Returns the next (field number, value) pair, or nil when done / malformed.
    mutating func next() -> (Int, WireValue)? {
        guard !isAtEnd, let key = readVarint() else { return nil }
        let field = Int(key >> 3)
        switch key & 0x7 {
        case 0:
            guard let v = readVarint() else { return nil }
            return (field, .varint(v))
        case 1:
            guard let v = readFixed64() else { return nil }
            return (field, .fixed64(v))
        case 2:
            guard let length = readVarint(), index + Int(length) <= data.count else { return nil }
            let bytes = Data(data[index..<(index + Int(length))])
            index += Int(length)
            return (field, .bytes(bytes))
        case 5:
            guard let v = readFixed32() else { return nil }
            return (field, .fixed32(v))
        default:
            return nil // groups / unknown wire types are not used by Discord's settings
        }
    }

    /// Iterates all top-level fields of a message
    static func fields(_ data: Data) -> [(Int, WireValue)] {
        var reader = ProtoReader(data)
        var result = [(Int, WireValue)]()
        while let field = reader.next() { result.append(field) }
        return result
    }

    /// Decodes a packed or unpacked repeated fixed64 field
    static func fixed64s(_ value: WireValue) -> [UInt64] {
        switch value {
        case let .fixed64(v): return [v]
        case let .bytes(packed):
            var reader = ProtoReader(packed)
            var out = [UInt64]()
            while !reader.isAtEnd, let v = reader.readFixed64() { out.append(v) }
            return out
        default: return []
        }
    }

    static func string(_ value: WireValue) -> String? {
        if case let .bytes(d) = value { return String(data: d, encoding: .utf8) }
        return nil
    }

    static func message(_ value: WireValue) -> Data? {
        if case let .bytes(d) = value { return d }
        return nil
    }

    static func uint(_ value: WireValue) -> UInt64? {
        switch value {
        case let .varint(v), let .fixed64(v): return v
        case let .fixed32(v): return UInt64(v)
        default: return nil
        }
    }

    /// google.protobuf.*Value wrappers store their value in field 1
    static func wrapped(_ value: WireValue) -> WireValue? {
        guard let msg = message(value) else { return nil }
        return fields(msg).first(where: { $0.0 == 1 })?.1
    }
}

extension DiscordSettings {
    /// Builds settings from the base64 `PreloadedUserSettings` protobuf
    convenience init?(protoBase64: String) {
        var base64 = protoBase64
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        self.init()

        for (field, value) in ProtoReader.fields(data) {
            switch field {
            case 11: // StatusSettings
                guard let msg = ProtoReader.message(value) else { continue }
                for (statusField, statusValue) in ProtoReader.fields(msg) {
                    switch statusField {
                    case 1: // StringValue status
                        if let wrapped = ProtoReader.wrapped(statusValue), let status = ProtoReader.string(wrapped) {
                            self.status = status
                        }
                    case 2: // CustomStatus
                        guard let custom = ProtoReader.message(statusValue) else { continue }
                        var dict = [String: Any]()
                        for (customField, customValue) in ProtoReader.fields(custom) {
                            switch customField {
                            case 1: dict["text"] = ProtoReader.string(customValue)
                            case 2:
                                if let id = ProtoReader.uint(customValue), id != 0 { dict["emoji_id"] = String(id) }
                            case 3: dict["emoji_name"] = ProtoReader.string(customValue)
                            default: break
                            }
                        }
                        if let json = try? JSONSerialization.data(withJSONObject: dict, options: []) {
                            self.custom_status = try? JSONDecoder().decode(Status.self, from: json)
                        }
                    default: break
                    }
                }
            case 13: // AppearanceSettings
                guard let msg = ProtoReader.message(value) else { continue }
                if let theme = ProtoReader.fields(msg).first(where: { $0.0 == 1 }).flatMap({ ProtoReader.uint($0.1) }) {
                    self.theme = theme == 2 ? .light : .dark
                }
            case 14: // GuildFolders
                guard let msg = ProtoReader.message(value) else { continue }
                var folders = [GuildFolder]()
                var positions = [String]()
                for (folderField, folderValue) in ProtoReader.fields(msg) {
                    switch folderField {
                    case 1: // GuildFolder
                        guard let folderMsg = ProtoReader.message(folderValue) else { continue }
                        var ids = [String]()
                        var name: String?
                        var color: Int?
                        for (f, v) in ProtoReader.fields(folderMsg) {
                            switch f {
                            case 1: ids += ProtoReader.fixed64s(v).map { String($0) }
                            case 3: name = ProtoReader.wrapped(v).flatMap(ProtoReader.string)
                            case 4: color = ProtoReader.wrapped(v).flatMap(ProtoReader.uint).map { Int(truncatingIfNeeded: $0) }
                            default: break
                            }
                        }
                        if !ids.isEmpty {
                            folders.append(GuildFolder(name: name, color: color, guild_ids: ids))
                        }
                    case 2:
                        positions += ProtoReader.fixed64s(folderValue).map { String($0) }
                    default: break
                    }
                }
                self.guild_folders = folders
                self.guild_positions = positions.isEmpty ? folders.flatMap(\.guild_ids) : positions
            default:
                break
            }
        }
    }
}
