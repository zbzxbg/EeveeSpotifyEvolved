import SwiftUI
import UIKit

struct EeveeExperimentsSettingsView: View {
    @State var experimentsOptions = UserDefaults.experimentsOptions

    var body: some View {
        List {
            Section(footer: Text("livecontainer_sharing_description".localized)) {
                Toggle(
                    "livecontainer_sharing".localized,
                    isOn: $experimentsOptions.liveContainerSharing
                )
            }
            
            // （"显示 Instagram 分享位"那个实验已于 2026-10-02 删除：
            //   目标类 `SPTSharingSDK` / `SPTShare_FoundationImplProperties` 只在 Spotify 9.1.0 上存在，
            //   在 9.1.86 上这个开关永远不会有效果。）

        }
        .onChange(of: experimentsOptions) { options in
            UserDefaults.experimentsOptions = options
        }
        
        .listStyle(GroupedListStyle())
        .animation(.default, value: experimentsOptions)
    }
}
