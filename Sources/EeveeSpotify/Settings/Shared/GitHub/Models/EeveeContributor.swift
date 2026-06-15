struct EeveeContributorRole: Decodable, Equatable {
    var name: String
    var coUsernames: [String]?
    var coDisplayNames: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case coUsernames
        case coDisplayNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        coUsernames = try container.decodeIfPresent([String].self, forKey: .coUsernames)
        coDisplayNames = try container.decodeIfPresent([String].self, forKey: .coDisplayNames)
    }
}

struct EeveeContributor: Decodable, Equatable {
    var usernames: [String]
    var displayName: String?
    var roles: [String]
    var richRoles: [EeveeContributorRole]?

    enum CodingKeys: String, CodingKey {
        case usernames
        case displayName
        case roles
        case richRoles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usernames = try container.decode([String].self, forKey: .usernames)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        roles = try container.decode([String].self, forKey: .roles)
        richRoles = try container.decodeIfPresent([EeveeContributorRole].self, forKey: .richRoles)
    }
}
