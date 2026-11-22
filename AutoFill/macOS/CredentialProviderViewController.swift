import AuthenticationServices
import AppKit
import SwiftUI

/// Vault's AutoFill extension on the Mac (Safari and apps). Same rules as iPhone: unlock with
/// Touch ID, show only logins for the exact site, hand back one login.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let model = AutoFillModel()

    override func loadView() {
        Fonts.register()
        model.cancel = { [weak self] in
            self?.extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
        }
        model.finish = { [weak self] item in
            if let p = self?.model.copyForConfirmBox {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p, forType: .string)
            } else if let t = TOTP(item.otp) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t.code(), forType: .string)
            }
            self?.extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: item.username, password: item.password))
        }
        model.finishAssertion = { [weak self] c in self?.extensionContext.completeAssertionRequest(using: c) }
        model.finishRegistration = { [weak self] c in self?.extensionContext.completeRegistrationRequest(using: c) }
        model.finishCode = { [weak self] code in
            if #available(macOS 15.0, *) { self?.extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code)) }
        }
        let host = NSHostingView(rootView: AutoFillView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        view = host
        preferredContentSize = NSSize(width: 420, height: 480)
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        model.setServices(serviceIdentifiers); model.mode = .password; model.start()
    }

    @available(macOS 15.0, *)
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        model.setServices(serviceIdentifiers); model.mode = .code; model.start()
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier], requestParameters: ASPasskeyCredentialRequestParameters) {
        model.setServices(serviceIdentifiers)
        model.mode = .password
        model.signIn = .init(rp: requestParameters.relyingPartyIdentifier, clientDataHash: requestParameters.clientDataHash,
                             allowed: requestParameters.allowedCredentials)
        model.start()
    }

    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        guard let r = registrationRequest as? ASPasskeyCredentialRequest, let id = r.credentialIdentity as? ASPasskeyCredentialIdentity,
              r.supportedAlgorithms.contains(where: { $0.rawValue == WebAuthn.es256 }) else {
            extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.failed.rawValue))
            return
        }
        model.create = .init(rp: id.relyingPartyIdentifier, userName: id.userName, userHandle: id.userHandle, clientDataHash: r.clientDataHash)
        model.start()
    }

    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        if credentialRequest.type == .passkeyAssertion, let r = credentialRequest as? ASPasskeyCredentialRequest,
           let id = r.credentialIdentity as? ASPasskeyCredentialIdentity {
            model.signIn = .init(rp: id.relyingPartyIdentifier, clientDataHash: r.clientDataHash, allowed: [])
            model.directCredentialID = id.credentialID
            model.start()
            return
        }
        model.directID = credentialRequest.credentialIdentity.recordIdentifier.flatMap(UUID.init(uuidString:))
        model.setServices([credentialRequest.credentialIdentity.serviceIdentifier])
        if #available(macOS 15.0, *), credentialRequest.type == .oneTimeCode { model.mode = .code } else { model.mode = .password }
        model.start()
    }

    override func prepareInterfaceForExtensionConfiguration() { extensionContext.completeExtensionConfigurationRequest() }
}

enum Fonts {
    static func register() {
        for name in ["IBMPlexSans", "IBMPlexMono-Regular", "IBMPlexMono-Medium"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }
}
