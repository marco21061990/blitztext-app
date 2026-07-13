import ApplicationServices
import AppKit
import os

@MainActor
enum AutoPasteService {
    enum PasteMethod: String {
        case systemEvents = "system_events"
        case commandV = "command_v"
        case pasteMenu = "paste_menu"
    }

    enum PasteOutcome {
        case pasteCommandDispatched(PasteMethod)
        case copiedOnly
        case failedToCopy
    }

    private static let logger = Logger(subsystem: "app.blitztext.mac", category: "AutoPaste")
    private static let maxMenuSearchDepth = 6
    private static let pasteboardRestoreDelay: TimeInterval = 1.0
    private static let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func pasteWithTemporaryClipboard(_ text: String, targetProcessIdentifier: pid_t) -> PasteOutcome {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        guard writeTemporaryText(text, to: pasteboard) else {
            logger.error("Temporary clipboard write failed.")
            return .failedToCopy
        }

        let temporaryChangeCount = pasteboard.changeCount

        if performSystemEventsPaste() {
            schedulePasteboardRestore(
                snapshot: snapshot,
                insertedText: text,
                expectedChangeCount: temporaryChangeCount
            )
            logger.info("System Events Cmd+V dispatched.")
            return .pasteCommandDispatched(.systemEvents)
        }

        if postCommandV() {
            schedulePasteboardRestore(
                snapshot: snapshot,
                insertedText: text,
                expectedChangeCount: temporaryChangeCount
            )
            logger.info("CGEvent Cmd+V dispatched.")
            return .pasteCommandDispatched(.commandV)
        }

        if performPasteMenuCommand(for: targetProcessIdentifier) {
            schedulePasteboardRestore(
                snapshot: snapshot,
                insertedText: text,
                expectedChangeCount: temporaryChangeCount
            )
            logger.info("AX paste menu dispatched.")
            return .pasteCommandDispatched(.pasteMenu)
        }

        logger.error("No paste command could be dispatched; leaving text on clipboard.")
        return .copiedOnly
    }

    static func insertTextWithAccessibility(_ text: String) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )

        guard copyResult == .success,
              let focusedElement = focusedObject as! AXUIElement? else {
            logger.error("AX focused element unavailable. result=\(copyResult.rawValue)")
            return false
        }

        guard AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success else {
            var roleObject: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(
                focusedElement,
                kAXRoleAttribute as CFString,
                &roleObject
            )
            let role = (roleObject as? String) ?? "unknown"
            logger.error("AX selected-text insert failed. focusedRole=\(role, privacy: .public)")
            return false
        }

        logger.info("AX selected-text insert succeeded.")
        return true
    }

    static func performPasteMenuCommand(for processIdentifier: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        guard let menuBar = copyElementAttribute(kAXMenuBarAttribute, from: appElement) else {
            logger.error("AX menu bar unavailable for target pid=\(processIdentifier)")
            return false
        }

        guard let pasteItem = findPasteMenuItem(in: menuBar, depth: 0) else {
            logger.error("AX paste menu item unavailable for target pid=\(processIdentifier)")
            return false
        }

        let result = AXUIElementPerformAction(pasteItem, kAXPressAction as CFString)
        guard result == .success else {
            logger.error("AX paste menu press failed. result=\(result.rawValue)")
            return false
        }

        logger.info("AX paste menu press succeeded.")
        return true
    }

    static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            logger.error("Failed to create Cmd+V CGEvents.")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        logger.info("Posted Cmd+V fallback.")
        return true
    }

    private static func performSystemEventsPaste() -> Bool {
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else {
            logger.error("Failed to create System Events paste script.")
            return false
        }

        var errorInfo: NSDictionary?
        _ = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            logger.error("System Events paste failed: \(String(describing: errorInfo), privacy: .public)")
            return false
        }

        return true
    }

    private static func writeTemporaryText(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealedPasteboardType], owner: nil)
        let didSetString = pasteboard.setString(text, forType: .string)
        let didSetConcealedType = pasteboard.setString("", forType: concealedPasteboardType)
        return didSetString && didSetConcealedType && pasteboard.string(forType: .string) == text
    }

    private static func schedulePasteboardRestore(
        snapshot: PasteboardSnapshot,
        insertedText: String,
        expectedChangeCount: Int
    ) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(pasteboardRestoreDelay))
            let pasteboard = NSPasteboard.general

            guard pasteboard.changeCount == expectedChangeCount ||
                    pasteboard.string(forType: .string) == insertedText else {
                logger.info("Skipped clipboard restore because clipboard changed externally.")
                return
            }

            snapshot.restore(to: pasteboard)
            logger.info("Restored previous clipboard contents after paste dispatch.")
        }
    }

    private static func findPasteMenuItem(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= maxMenuSearchDepth else { return nil }

        if isPasteMenuItem(element) {
            return element
        }

        guard let children = copyElementArrayAttribute(kAXChildrenAttribute, from: element) else {
            return nil
        }

        for child in children {
            if let match = findPasteMenuItem(in: child, depth: depth + 1) {
                return match
            }
        }

        return nil
    }

    private static func isPasteMenuItem(_ element: AXUIElement) -> Bool {
        let role = copyStringAttribute(kAXRoleAttribute, from: element)
        guard role == kAXMenuItemRole else { return false }

        if let enabled = copyBoolAttribute(kAXEnabledAttribute, from: element), !enabled {
            return false
        }

        if let commandChar = copyStringAttribute(kAXMenuItemCmdCharAttribute, from: element),
           commandChar.caseInsensitiveCompare("v") == .orderedSame {
            return true
        }

        guard let title = copyStringAttribute(kAXTitleAttribute, from: element)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return false
        }

        return title == "paste" || title == "einsetzen" || title == "einfügen"
    }

    private static func copyElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var object: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &object)
        guard result == .success else { return nil }
        return object as! AXUIElement?
    }

    private static func copyElementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement]? {
        var object: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &object)
        guard result == .success else { return nil }
        return object as? [AXUIElement]
    }

    private static func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var object: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &object)
        guard result == .success else { return nil }
        return object as? String
    }

    private static func copyBoolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var object: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &object)
        guard result == .success else { return nil }
        return object as? Bool
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let capturedItems = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { values, type in
                values[type] = item.data(forType: type)
            }
        } ?? []

        return PasteboardSnapshot(items: capturedItems)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard !items.isEmpty else {
            return
        }

        let restoredItems = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }

        pasteboard.writeObjects(restoredItems)
    }
}
