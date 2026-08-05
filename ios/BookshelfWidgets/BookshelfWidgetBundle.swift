import SwiftUI
import WidgetKit

/// Everything the extension publishes: three Home/Lock Screen widgets and the
/// reading-session Live Activity.
@main
struct BookshelfWidgetBundle: WidgetBundle {
    var body: some Widget {
        CurrentlyReadingWidget()
        StreakWidget()
        GoalWidget()
        ReadingSessionLiveActivity()
    }
}
