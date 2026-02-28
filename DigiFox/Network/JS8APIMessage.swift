import Foundation

struct JS8APIMessage: Codable, Identifiable {
    let id: UUID
    var type: String
    var value: String
    var params: [String: String]?

    init(type: String, value: String, params: [String: String]? = nil) {
        self.id = UUID(); self.type = type; self.value = value; self.params = params
    }

    enum CodingKeys: String, CodingKey { case type, value, params }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.type = try c.decode(String.self, forKey: .type)
        self.value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        self.params = try c.decodeIfPresent([String: String].self, forKey: .params)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(value, forKey: .value)
        try c.encodeIfPresent(params, forKey: .params)
    }
}
