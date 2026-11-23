import Foundation

/// Learns how you use Nebula, per type of file:
/// - formats you pick often slowly drift to the first slots (top, then clockwise),
///   one small step at a time so positions stay predictable for muscle memory;
/// - the most used format gets a small marker;
/// - the Mini toggle is remembered per type;
/// - the flick threshold adapts to how fast you normally move the pointer.
@MainActor
final class Habits {
    static let shared = Habits()

    private struct Store: Codable {
        var scores: [String: [String: Double]] = [:]
        var orders: [String: [String]] = [:]
        var mini: [String: Bool] = [:]
        var speeds: [Double] = []
    }

    private var store: Store

    var enabled: Bool { UserDefaults.standard.object(forKey: "adaptive") as? Bool ?? true }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "habits"),
           let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        } else {
            store = Store()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: "habits")
        }
    }

    static func key(for urls: [URL]) -> String {
        Set(urls.map { url -> String in
            let ext = url.pathExtension.lowercased()
            return ext.isEmpty ? FileInspector.kind(of: url).label : ext
        }).sorted().joined(separator: "+")
    }

    func arrange(_ ids: [String], key: String) -> [String] {
        guard enabled, let saved = store.orders[key] else { return ids }
        var order = saved.filter { ids.contains($0) }
        for id in ids where !order.contains(id) { order.append(id) }
        return order
    }

    func record(_ id: String, key: String, shown ids: [String]) {
        guard enabled else { return }
        var scores = store.scores[key] ?? [:]
        for k in scores.keys { scores[k] = (scores[k] ?? 0) * 0.97 }
        scores[id, default: 0] += 1
        store.scores[key] = scores

        // One gentle bubble pass: a format moves up one slot only when clearly more used.
        var order = arrange(ids, key: key)
        if order.count > 1 {
            for i in 1..<order.count {
                let above = scores[order[i - 1]] ?? 0
                let here = scores[order[i]] ?? 0
                if here > above * 1.5 + 0.5 { order.swapAt(i - 1, i) }
            }
        }
        store.orders[key] = order
        save()
    }

    func favorite(key: String) -> String? {
        guard enabled, let best = store.scores[key]?.max(by: { $0.value < $1.value }), best.value >= 3 else { return nil }
        return best.key
    }

    func mini(for key: String) -> Bool { store.mini[key] ?? false }

    func setMini(_ on: Bool, key: String) {
        store.mini[key] = on
        save()
    }

    /// Speed of ordinary pointer moves that reached the edge without being a flick.
    func recordSpeed(_ speed: Double) {
        guard enabled, speed.isFinite else { return }
        store.speeds.append(speed)
        if store.speeds.count > 120 { store.speeds.removeFirst(store.speeds.count - 120) }
        save()
    }

    /// Average speed (pt/s) a move from the center must exceed to count as a flick.
    var flickThreshold: CGFloat {
        let base: Double = 1100
        guard enabled, store.speeds.count >= 8 else { return CGFloat(base) }
        let sorted = store.speeds.sorted()
        let p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
        return CGFloat(max(base, p90 * 1.4))
    }

    func reset() {
        store = Store()
        save()
    }
}
