import Foundation
import CarPlay

// =============================================================================
// ShelfHead • CarPlay scene lifecycle
// =============================================================================
//
// The CarPlay layer is split across four files in this folder:
//   • CarPlaySceneDelegate.swift  – scene connect/disconnect (this file)
//   • CarPlayCoordinator.swift    – template graph, playback, live sync
//   • CarPlayTemplates.swift      – Setup screen builder (a CPListTemplate; a
//                                    CPInformationTemplate can't be used inside a tab bar)
//   • CarPlayImageLoader.swift    – async cover art for CPListItem
//
// The `@objc` class name must stay in sync with `UISceneDelegateClassName` in
// Info.plist (`CarPlaySceneDelegate`, no module prefix).
// =============================================================================

@objc(CarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let coordinator = CarPlayCoordinator(interfaceController: interfaceController)
        self.coordinator = coordinator
        coordinator.start()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        coordinator?.stop()
        coordinator = nil
    }
}
