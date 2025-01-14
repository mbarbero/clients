import SafariServices
import os.log
import LocalAuthentication

let SFExtensionMessageKey = "message"
let ServiceName = "Bitwarden"
let ServiceNameBiometric = ServiceName + "_biometric"

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    override init() {
        super.init();
        NSApplication.shared.setActivationPolicy(.accessory)
    }

	func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems[0] as! NSExtensionItem
        let message = item.userInfo?[SFExtensionMessageKey] as AnyObject?
        os_log(.default, "Received message from browser.runtime.sendNativeMessage: %@", message as! CVarArg)

        let response = NSExtensionItem()

        guard let command = message?["command"] as? String else {
            return
        }

        switch (command) {
        case "readFromClipboard":
            handleReadFromClipboard(&response)
        case "copyToClipboard":
            handleCopyToClipboard(message)
        case "showPopover":
            handleShowPopover()
        case "downloadFile":
            handleDownloadFile(message)
        case "sleep":
            handleSleep(context, response)
            return
        case "biometricUnlock":
            handleBiometricUnlock(message, context, &response)
            return
        default:
            return
        }

        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

}

func handleReadFromClipboard(_ response: inout NSExtensionItem) {
    let pasteboard = NSPasteboard.general
    response.userInfo = [ SFExtensionMessageKey: pasteboard.pasteboardItems?.first?.string(forType: .string) as Any ]
}

func handleCopyToClipboard(_ message: [String: Any]?) {
    guard let msg = message?["data"] as? String else {
        return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(msg, forType: .string)
}

func handleShowPopover() {
    SFSafariApplication.getActiveWindow { win in
        win?.getToolbarItem(completionHandler: { item in
            item?.showPopover()
        })
    }
}

func createBlobData(from dlMsg: DownloadFileMessage) -> Data? {
    if dlMsg.blobOptions?.type == "text/plain" {
        return dlMsg.blobData?.data(using: .utf8)
    } else if let blob = dlMsg.blobData {
        return Data(base64Encoded: blob)
    }
    return nil
}

func writeFile(data: Data, to url: URL) {
    do {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.absoluteString) {
            fileManager.createFile(atPath: url.absoluteString, contents: Data(),
                                    attributes: nil)
        }
        try data.write(to: url)
    } catch {
        print(error)
        NSLog("ERROR in downloadFile, \(error)")
    }
}

func handleDownloadFile(_ message: [String: Any]?) {
    guard let jsonData = message?["data"] as? String,
          let dlMsg: DownloadFileMessage = jsonDeserialize(json: jsonData),
          let blobData = createBlobData(from: dlMsg) else {
        return
    }

    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = dlMsg.fileName
    let response = panel.runModal()

    if response == NSApplication.ModalResponse.OK, let url = panel.url {
        writeFile(data: blobData, to: url)
    }
}

func handleSleep(_ context: NSExtensionContext, _ response: NSExtensionItem) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}

let notSupportedResponse: [String: Any] = [
    SFExtensionMessageKey: [
        "message": [
            "command": "biometricUnlock",
            "response": "not supported",
            "timestamp": Int64(NSDate().timeIntervalSince1970 * 1000),
        ],
    ],
]

let notEnabledResponse: [String: Any] = [
    SFExtensionMessageKey: [
        "message": [
            "command": "biometricUnlock",
            "response": "not enabled",
            "timestamp": Int64(NSDate().timeIntervalSince1970 * 1000),
        ],
    ],
]

func createResponse(_ response: String, _ result: String? = nil) -> [String: Any] {
    var message: [String: Any] = [
        "command": "biometricUnlock",
        "response": response,
        "timestamp": Int64(NSDate().timeIntervalSince1970 * 1000),
    ]
    if let result = result {
        message["userKeyB64"] = result.replacingOccurrences(of: "\"", with: "")
    }
    return [SFExtensionMessageKey: ["message": message]]
}

func handleBiometricUnlock(_ message: [String: Any]?, _ context: NSExtensionContext, _ response: inout NSExtensionItem) {
    var error: NSError?
    let laContext = LAContext()

    if #available(macOSApplicationExtension 10.15, *) {
        laContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrWatch, error: &error)
    } else {
        laContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    if let e = error, e.code != kLAErrorBiometryLockout {
        response.userInfo = notSupportedResponse
        return
    }

    guard let accessControl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], nil) else {
        response.userInfo = notSupportedResponse
        return
    }

    laContext.evaluateAccessControl(accessControl, operation: .useKeySign, localizedReason: "Bitwarden Safari Extension") { (success, error) in
        if success {
            guard let userId = message?["userId"] as? String else {
                return
            }
            let passwordName = userId + "_user_biometric"
            var passwordLength: UInt32 = 0
            var passwordPtr: UnsafeMutableRawPointer? = nil

            var status = SecKeychainFindGenericPassword(nil, UInt32(ServiceNameBiometric.utf8.count), ServiceNameBiometric, UInt32(passwordName.utf8.count), passwordName, &passwordLength, &passwordPtr, nil)
            if status != errSecSuccess {
                let fallbackName = "key"
                status = SecKeychainFindGenericPassword(nil, UInt32(ServiceNameBiometric.utf8.count), ServiceNameBiometric, UInt32(fallbackName.utf8.count), fallbackName, &passwordLength, &passwordPtr, nil)
            }

            // TODO: Remove after 2023.10 release (https://bitwarden.atlassian.net/browse/PM-3473)
            if status != errSecSuccess {
                let secondaryFallbackName = "_masterkey_biometric"
                status = SecKeychainFindGenericPassword(nil, UInt32(ServiceNameBiometric.utf8.count), ServiceNameBiometric, UInt32(secondaryFallbackName.utf8.count), secondaryFallbackName, &passwordLength, &passwordPtr, nil)
            }

            if status == errSecSuccess {
                let result = NSString(bytes: passwordPtr!, length: Int(passwordLength), encoding: String.Encoding.utf8.rawValue) as String?
                SecKeychainItemFreeContent(nil, passwordPtr)

                response.userInfo = createResponse("unlocked", result)
            } else {
                response.userInfo = notEnabledResponse
            }
        }

        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    return
}

func jsonSerialize<T: Encodable>(obj: T?) -> String? {
    let encoder = JSONEncoder()
    do {
        let data = try encoder.encode(obj)
        return String(data: data, encoding: .utf8) ?? "null"
    } catch _ {
        return "null"
    }
}

func jsonDeserialize<T: Decodable>(json: String?) -> T? {
    if json == nil {
        return nil
    }
    let decoder = JSONDecoder()
    do {
        let obj = try decoder.decode(T.self, from: json!.data(using: .utf8)!)
        return obj
    } catch _ {
        return nil
    }
}

class DownloadFileMessage: Decodable, Encodable {
    var fileName: String
    var blobData: String?
    var blobOptions: DownloadFileMessageBlobOptions?
}

class DownloadFileMessageBlobOptions: Decodable, Encodable {
    var type: String?
}
