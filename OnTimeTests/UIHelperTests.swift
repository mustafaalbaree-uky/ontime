import Foundation
import Testing
@testable import OnTime

/// The pure helpers that used to be private view code with zero coverage:
/// the typed time parser guarding the only keyboard entry path for times,
/// and the settings store's load behavior.
struct ParseTimeTests {
    private func components(_ text: String) -> (hour: Int, minute: Int)? {
        guard let date = FullScreenTimePicker.parseTime(text) else { return nil }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? -1, comps.minute ?? -1)
    }

    @Test func acceptsTheDocumentedLooseFormats() throws {
        #expect(try #require(components("2:47 PM")) == (14, 47))
        #expect(try #require(components("2:47pm")) == (14, 47))
        #expect(try #require(components("14:47")) == (14, 47))
        #expect(try #require(components("2 pm")) == (14, 0))
        #expect(try #require(components("2pm")) == (14, 0))
        #expect(try #require(components("  7:05 am  ")) == (7, 5))
    }

    @Test func rejectsGarbage() {
        #expect(FullScreenTimePicker.parseTime("") == nil)
        #expect(FullScreenTimePicker.parseTime("soon") == nil)
        #expect(FullScreenTimePicker.parseTime("25:99") == nil)
    }
}

struct AppSettingsTests {
    private func freshDefaults() -> UserDefaults {
        let name = "AppSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func firstLaunchUsesDeclaredDefaults() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.walkSafetyPercent == 15)
        #expect(settings.walkHeadsUpMinutes == 10)
        #expect(settings.quickDeadlineHour == 9)
        #expect(settings.confidenceIsSafe)
        #expect(settings.autoAdvanceEnabled)
    }

    @Test func writesRoundTripThroughTheSuite() {
        let d = freshDefaults()
        let settings = AppSettings(defaults: d)
        settings.walkSafetyPercent = 25
        settings.quickDeadlineHour = 19
        settings.confidenceIsSafe = false

        let reloaded = AppSettings(defaults: d)
        #expect(reloaded.walkSafetyPercent == 25)
        #expect(reloaded.quickDeadlineHour == 19)
        #expect(reloaded.confidenceIsSafe == false)
    }

    /// An out-of-range persisted value must not leak in from disk: a
    /// negative safety percent would *shrink* walk return estimates, quiet
    /// and wrong in the dangerous direction.
    @Test func integerLoadsAreClampedToTheUIRanges() {
        let d = freshDefaults()
        d.set(-40, forKey: "walkSafetyPercent")
        d.set(999, forKey: "walkHeadsUpMinutes")
        d.set(30, forKey: "quickDeadlineHour")

        let settings = AppSettings(defaults: d)
        #expect(settings.walkSafetyPercent == 0)
        #expect(settings.walkHeadsUpMinutes == 30)
        #expect(settings.quickDeadlineHour == 23)
    }
}
