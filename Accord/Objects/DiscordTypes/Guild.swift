//
//  Guild.swift
//  Guild
//
//  Created by Evelyn on 2021-08-16.
//

import Foundation

struct Guild: Decodable, Equatable, Hashable, Identifiable {
    static func == (lhs: Guild, rhs: Guild) -> Bool {
        lhs.id == rhs.id && lhs.channels == rhs.channels
    }

    var newChannelID: String? {
        return UserDefaults.standard.object(forKey: "AccordChannelIn\(self.id)") as? String ??
        self.rules_channel_id ??
        self.channels.first(where: { $0.name?.contains("general") ?? false })?.id
    }
    
    let id: String
    let name: String?
    var icon: String?
    var icon_hash: String?
    // var splash: String?
    // var discovery_splash: String?
    var owner: Bool?
    var owner_id: String
    // var region: String?
    // var afk_channel_id: String?
    // var afk_timeout: Int
    // var widget_enabled: Bool?
    // var widget_channel_id: String?
    // var verification_level: Int
    // var default_message_notification: Int?
    // var explicit_content_filter: Int
    // TODO: Role object
    var roles: [Role]?
    var emojis: [DiscordEmote]
    // TODO: Guild features
    // var features:
    var mfa_level: Int
    // var application_id: String?
    // var system_channel_id: String?
    // var system_channel_flags: Int?
     var rules_channel_id: String?
    // TODO: ISO8061 timestamp
    // var joined_at: ISO8061
    var large: Bool?
    var unavailable: Bool?
    var member_count: Int?
    // TODO: Voice state object
    // var voice_states: [VoiceState]
    // var members: [GuildMember]?
    var channels: [Channel]
    // TODO: Thread object
    var threads: [Channel]?
    // TODO: PresenceUpdate object
    // var presences: [PresenceUpdate]?
    let max_presences: Int?
    let max_members: Int?
    var vanity_url_code: String?
    var description: String?
    var banner: String?
    var premium_tier: Int?
    var premium_subscription_count: Int?
    // var preferred_locale: String?
    // var public_updates_channel_id: String?
    // var max_video_channel_users: Int?
    var approximate_member_count: Int?
    var approximate_presence_count: Int?
    // TODO: Welcome Screen object
    // var welcome_screen: WelcomeScreen
    var nsfw_level: Int
    // TODO: StageInstance objects
    // var stage_instances: [StageInstances]
    var stickers: [Sticker]?

    var mergedMember: MergedMember?
    var guildPermissions: String?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(self.channels)
    }

    struct MergedMember: Decodable {
        var guild_id: String?
        var hoisted_role: String?
        var nick: String?
        var roles: [String]
        var cachedPermissions: Permissions?
    }
}

// MARK: - Tolerant decoding

/// Decodes each element on its own so one unexpected entry (a new channel type, a new sticker
/// format, ...) doesn't make the whole guild disappear from READY.
private struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
    }
}

extension Guild {
    private enum GuildKeys: String, CodingKey {
        case id, name, icon, icon_hash, owner, owner_id, roles, emojis, mfa_level, rules_channel_id,
             large, unavailable, member_count, channels, threads, max_presences, max_members,
             vanity_url_code, description, banner, premium_tier, premium_subscription_count,
             approximate_member_count, approximate_presence_count, nsfw_level, stickers,
             properties
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: GuildKeys.self)
        // Newer READY payloads nest the guild metadata in a `properties` object, while channels,
        // roles, emojis etc. stay at the top level. Support both layouts.
        let props = (try? root.nestedContainer(keyedBy: GuildKeys.self, forKey: .properties)) ?? root

        func value<T: Decodable>(_ key: GuildKeys) -> T? {
            if let v = try? props.decodeIfPresent(T.self, forKey: key) { return v }
            return try? root.decodeIfPresent(T.self, forKey: key)
        }
        func list<T: Decodable>(_ key: GuildKeys) -> [T]? {
            if let v = try? root.decodeIfPresent(LossyArray<T>.self, forKey: key) { return v.elements }
            return (try? props.decodeIfPresent(LossyArray<T>.self, forKey: key))?.elements
        }

        guard let id: String = value(.id) else {
            throw DecodingError.keyNotFound(GuildKeys.id, .init(codingPath: decoder.codingPath, debugDescription: "Guild without id"))
        }
        self.init(
            id: id,
            name: value(.name),
            icon: value(.icon),
            icon_hash: value(.icon_hash),
            owner: value(.owner),
            owner_id: value(.owner_id) ?? "",
            roles: list(.roles),
            emojis: list(.emojis) ?? [],
            mfa_level: value(.mfa_level) ?? 0,
            rules_channel_id: value(.rules_channel_id),
            large: value(.large),
            unavailable: value(.unavailable),
            member_count: value(.member_count),
            channels: list(.channels) ?? [],
            threads: list(.threads),
            max_presences: value(.max_presences),
            max_members: value(.max_members),
            vanity_url_code: value(.vanity_url_code),
            description: value(.description),
            banner: value(.banner),
            premium_tier: value(.premium_tier),
            premium_subscription_count: value(.premium_subscription_count),
            approximate_member_count: value(.approximate_member_count),
            approximate_presence_count: value(.approximate_presence_count),
            nsfw_level: value(.nsfw_level) ?? 0,
            stickers: list(.stickers),
            mergedMember: nil,
            guildPermissions: nil
        )
    }
}
