import SwiftUI

struct DraftMessagePreviewSheet: View {
    let contact: String
    let messageBody: String
    let platform: String
    let onResult: (PermissionConfirmationResult) -> Void

    var body: some View {
        PermissionConfirmationSheet(
            payload: PermissionPayload.make(
                toolName: platform == "whatsapp" ? "web_whatsapp" : "send_message",
                args: [
                    "contact": contact,
                    "body": messageBody,
                    "platform": platform
                ]
            ),
            onResult: onResult
        )
    }
}
