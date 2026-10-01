import Foundation

extension UserDefaults {
    @UserDefault(
        key: "experimentsOptions",
        defaultValue: ExperimentsOptions(
            liveContainerSharing: true
        )
    )
    static var experimentsOptions
}
