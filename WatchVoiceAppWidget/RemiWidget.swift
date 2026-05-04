import WidgetKit
import SwiftUI

struct RemiEntry: TimelineEntry {
    let date: Date
}

struct RemiProvider: TimelineProvider {
    func placeholder(in context: Context) -> RemiEntry { RemiEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (RemiEntry) -> Void) {
        completion(RemiEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RemiEntry>) -> Void) {
        completion(Timeline(entries: [RemiEntry(date: .now)], policy: .never))
    }
}

struct RemiWidgetView: View {
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            if family == .accessoryInline {
                Image(systemName: "mic.fill")
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(URL(string: "watchvoiceapp://speak")!)
    }
}

struct RemiWidget: Widget {
    let kind = "RemiWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RemiProvider()) { _ in
            RemiWidgetView()
        }
        .configurationDisplayName("レミ")
        .description("タップで話す")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct RemiWidgetBundle: WidgetBundle {
    var body: some Widget {
        RemiWidget()
    }
}
