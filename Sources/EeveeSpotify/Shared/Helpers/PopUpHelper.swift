import UIKit
import Orion

struct PopUpHelper {
    private static var isPopUpShowing = false
    
    static let sharedPresenter = type(
        of: Dynamic.SPTEncorePopUpPresenter
        .alloc(interface: SPTEncorePopUpPresenter.self)
    )
    .shared()

    static func showPopUp(
        delayed: Bool = false,
        message: String,
        buttonText: String,
        secondButtonText: String? = nil,
        onPrimaryClick: (() -> Void)? = nil,
        onSecondaryClick: (() -> Void)? = nil,
        onPresented: (() -> Void)? = nil
    ) {
        DispatchQueue.main.asyncAfter(deadline: delayed ? .now() + 3.0 : .now()) {
            if isPopUpShowing {
                return
            }

            let model = Dynamic.SPTEncorePopUpDialogModel
                .alloc(interface: SPTEncorePopUpDialogModel.self)
                .initWithTitle(
                    "EeveeSpotify",
                    description: message,
                    image: nil,
                    primaryButtonTitle: buttonText,
                    secondaryButtonTitle: secondButtonText
                )

            let dialog = Dynamic.SPTEncorePopUpDialog
                .alloc(interface: SPTEncorePopUpDialog.self)
                .`init`()
            
            dialog.update(model)
            dialog.setEventHandler({ state in
                switch (state) {
                
                case .primary: onPrimaryClick?()
                case .secondary: onSecondaryClick?()

                }

                sharedPresenter.dismissPopupWithAnimate(true, clearQueue: false, completion: nil)
                isPopUpShowing.toggle()
            })

            isPopUpShowing.toggle()
            sharedPresenter.presentPopUp(dialog)
            // 只有真的交给了 presenter 才回调；上面 `isPopUpShowing` 那道 guard 提前
            // return 时不会走到这里（调用方据此决定"这次算不算提示过"）。
            onPresented?()
        }
    }
}
