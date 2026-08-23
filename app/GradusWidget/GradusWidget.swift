import GradusWidgetSupport
import SwiftUI
import WidgetKit

@main
struct GradusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GradusWidgetMetadata.kind, provider: WidgetTimelineProvider()) { entry in
            GradusSmallWidgetView(entry: entry)
        }
        .configurationDisplayName(GradusWidgetMetadata.displayName)
        .description(GradusWidgetMetadata.galleryDescription)
        .supportedFamilies(GradusWidgetMetadata.supportedFamilies)
    }
}
