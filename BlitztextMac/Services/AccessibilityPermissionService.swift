import AppKit
import ApplicationServices

@MainActor
enum AccessibilityPermissionService {
    private static var hasPromptedThisSession = false

    static func currentStatus() -> Bool {
        AXIsProcessTrusted()
    }

    static func isTrusted(promptIfNeeded: Bool) -> Bool {
        let shouldPrompt = promptIfNeeded && !hasPromptedThisSession
        if shouldPrompt {
            hasPromptedThisSession = true
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: shouldPrompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestPermissionPrompt() -> Bool {
        hasPromptedThisSession = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func openAutomationSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
