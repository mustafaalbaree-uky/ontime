import SwiftUI
import WidgetKit

@main
struct OnTimeWidgetBundle: WidgetBundle {
    var body: some Widget {
        OnTimeLiveActivity()
        PlaceholderWidget()
    }
}

struct PlaceholderWidget: Widget {
    let kind: String = "OnTimePlaceholderWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlaceholderProvider()) { entry in
            Text("On Time")
        }
        .configurationDisplayName("On Time")
        .description("Countdown and deadline solver for departure steps.")
    }
}

struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry {
        PlaceholderEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: Date())], policy: .never))
    }
}
