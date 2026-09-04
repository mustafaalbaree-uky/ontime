import SwiftUI
import WidgetKit

@main
struct OnTimeWidgetBundle: WidgetBundle {
    var body: some Widget {
        OnTimeLiveActivity()
        UpNextWidget()
    }
}
