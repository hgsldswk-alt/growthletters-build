import SwiftUI
import WidgetKit

struct LetterEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct LetterTimeline: TimelineProvider {
    func placeholder(in context: Context) -> LetterEntry { LetterEntry(date: .now, snapshot: WidgetSnapshot(count: 10)) }
    func getSnapshot(in context: Context, completion: @escaping (LetterEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : LetterEntry(date: .now, snapshot: WidgetSnapshot.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LetterEntry>) -> Void) {
        let entry = LetterEntry(date: .now, snapshot: WidgetSnapshot.read())
        completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(3600))))
    }
}

@main
struct GrowthLettersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.kind, provider: LetterTimeline()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "envelope")
                    .font(.title2).foregroundStyle(Color(red: 0.212, green: 0.271, blue: 0.561))
                    .accessibilityHidden(true)
                if let snapshot = entry.snapshot {
                    Text(L.f("letters.count", snapshot.count)).font(.headline).privacySensitive()
                    if let date = snapshot.opening {
                        Text(date, style: .date).font(.caption).privacySensitive()
                    }
                } else {
                    Text(L.t("widget.write")).font(.headline)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(Color(red: 0.984, green: 0.973, blue: 0.949), for: .widget)
            .foregroundStyle(Color(red: 0.149, green: 0.149, blue: 0.20))
            .widgetURL(URL(string: "growthletters://write"))
        }
        .configurationDisplayName(L.t("app.title"))
        .description(L.t("widget.description"))
        .supportedFamilies([.systemSmall])
    }
}
