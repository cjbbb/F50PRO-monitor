import SwiftUI
import F50Core

struct F50PopoverView: View {
    @ObservedObject var fetcher: F50Fetcher
    @State private var isShowingSettings = false
    @State private var isShowingSMS = false

    var body: some View {
        Group {
            if isShowingSMS {
                SMSListView(fetcher: fetcher) {
                    isShowingSMS = false
                }
            } else if isShowingSettings {
                SettingsView(fetcher: fetcher) {
                    isShowingSettings = false
                }
            } else {
                F50PanelView(
                    fetcher: fetcher,
                    onOpenSettings: { isShowingSettings = true },
                    onOpenSMS: { isShowingSMS = true }
                )
            }
        }
        .frame(width: 376)
        .fixedSize(horizontal: false, vertical: true)
    }
}
