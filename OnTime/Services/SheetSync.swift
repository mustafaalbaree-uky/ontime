import Foundation
import SwiftData

/// Sends finished work sessions to the Work Hours Google Sheet, which is the
/// record of hours worked. The phone's store is not: on 24 Oct 2026 it was
/// set aside on a launch that could not open it, and the Work tab went to
/// zeros with every session still on disk under another name.
///
/// The sheet's side is an Apps Script web app that keys rows on the session's
/// `uuid`. Every sync sends every finished session from the last
/// `windowDays`, so a sync that failed (no signal, the script down) is simply
/// covered by the next one, and there is no queue of unsent sessions to lose.
/// Rows already in the sheet are updated only if their times changed.
///
/// A session missing from a sync is never removed from the sheet. Only a
/// delete made here is sent as one, so a store that comes up empty again
/// cannot empty the sheet with it. Deletes wait in `UserDefaults` until a
/// sync carrying them succeeds.
///
/// The URL and key come from `SheetEndpoint.json`, written into the bundle at
/// build time by `tools/sheet-endpoint.sh` from `~/.ontime/` and never
/// committed. A build without it has no endpoint and never syncs.
@MainActor
enum SheetSync {
    struct Endpoint: Decodable {
        let url: URL
        let key: String
    }

    static let endpoint: Endpoint? = {
        guard let file = Bundle.main.url(forResource: "SheetEndpoint", withExtension: "json"),
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Endpoint.self, from: data)
    }()

    /// Long enough to cover any gap between syncs that matters, short
    /// enough that a sync stays a few dozen rows.
    static let windowDays = 60

    /// When the last sync succeeded, as seconds since 1970. Read by the week
    /// view through `@AppStorage`.
    static let lastSentKey = "SheetSync.lastSent"
    private static let pendingDeletesKey = "SheetSync.pendingDeletes"

    private static var inFlight = false
    /// A sync asked for while one was running. It runs once the first ends,
    /// so a Stop pressed mid sync is never left out.
    private static var wantsAnother = false

    /// The sheet's ID for a session: the uuid as lowercase hex with no
    /// dashes, the form the rows recovered from the phone were written in.
    static func sheetID(_ uuid: UUID) -> String {
        uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Records a deletion to send. Call before deleting the row, then sync.
    static func noteDeleted(_ session: WorkSession) {
        var pending = UserDefaults.standard.stringArray(forKey: pendingDeletesKey) ?? []
        pending.append(sheetID(session.uuid))
        UserDefaults.standard.set(pending, forKey: pendingDeletesKey)
    }

    static func sync(in context: ModelContext) {
        guard let endpoint else { return }
        if inFlight {
            wantsAnother = true
            return
        }

        let since = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<WorkSession>(
            predicate: #Predicate { $0.endedAt != nil && $0.startedAt >= since },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        let sessions = ((try? context.fetch(descriptor)) ?? []).compactMap { session -> Payload.Session? in
            guard let end = session.endedAt else { return nil }
            return Payload.Session(id: sheetID(session.uuid),
                                   start: iso.string(from: session.startedAt),
                                   end: iso.string(from: end))
        }
        let deleted = UserDefaults.standard.stringArray(forKey: pendingDeletesKey) ?? []
        guard let body = try? JSONEncoder().encode(Payload(key: endpoint.key, sessions: sessions, deleted: deleted)) else { return }

        var request = URLRequest(url: endpoint.url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        inFlight = true
        Task {
            // Apps Script answers a POST with a redirect to the result, which
            // URLSession follows as a GET. The script has already run by then.
            let ok: Bool
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let reply = try? JSONDecoder().decode(Reply.self, from: data)
                ok = status == 200 && reply?.ok == true
                if !ok { print("SheetSync: status \(status), \(String(decoding: data.prefix(300), as: UTF8.self))") }
            } catch {
                ok = false
                print("SheetSync failed: \(error)")
            }
            finish(ok: ok, sentDeletes: deleted, context: context)
        }
    }

    private static func finish(ok: Bool, sentDeletes: [String], context: ModelContext) {
        if ok {
            // Only the deletes this request carried: one recorded while it
            // was in flight still has to go.
            let pending = UserDefaults.standard.stringArray(forKey: pendingDeletesKey) ?? []
            UserDefaults.standard.set(pending.filter { !sentDeletes.contains($0) }, forKey: pendingDeletesKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSentKey)
        }
        inFlight = false
        if wantsAnother {
            wantsAnother = false
            sync(in: context)
        }
    }

    private struct Payload: Encodable {
        let key: String
        let sessions: [Session]
        let deleted: [String]

        struct Session: Encodable {
            let id: String
            let start: String
            let end: String
        }
    }

    private struct Reply: Decodable {
        let ok: Bool
    }

    /// With the offset, so the script can place the session on the right day
    /// in the sheet's own time zone.
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
