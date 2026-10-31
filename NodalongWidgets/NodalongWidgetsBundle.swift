import SwiftUI
import WidgetKit

@main
struct NodalongWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ListeningLiveActivity()
        SpotlightsWidget()
        NowPlayingWidget()
    }
}
