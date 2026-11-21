import AuthenticationServices
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Vault's AutoFill extension. It unlocks the vault with Face ID inside the extension,
/// shows only logins saved for the exact site being signed in to, and hands back one login.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let model = AutoFillModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.cancel = { [weak self] in
            self?.extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
        }
        model.finish = { [weak self] item in self?.complete(item) }
        model.finishAssertion = { [weak self] c in self?.extensionContext.completeAssertionRequest(using: c) }
        model.finishRegistration = { [weak self] c in self?.extensionContext.completeRegistrationRequest(using: c) }
        model.finishCode = { [weak self] code in
            guard let self else { return }
            if #available(iOS 18.0, *) {
                self.extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
            }
        }
        view.backgroundColor = UIColor(Ink.bg)
        let host = UIHostingController(rootView: AutoFillView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        model.sites = serviceIdentifiers.map(\.identifier)
        model.mode = .password
        model.start()
    }

    @available(iOS 18.0, *)
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        model.sites = serviceIdentifiers.map(\.identifier)
        model.mode = .code
        model.start()
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier], requestParameters: ASPasskeyCredentialRequestParameters) {
        model.sites = serviceIdentifiers.map(\.identifier)
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
        // The vault key needs Face ID, so every fill goes through the interface.
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
        model.sites = [credentialRequest.credentialIdentity.serviceIdentifier.identifier]
        if #available(iOS 18.0, *), credentialRequest.type == .oneTimeCode { model.mode = .code } else { model.mode = .password }
        model.start()
    }

    override func prepareInterfaceForExtensionConfiguration() {
        extensionContext.completeExtensionConfigurationRequest()
    }

    private func complete(_ item: VaultItem) {
        // Two-factor code goes on the clipboard for 60 seconds, ready to paste on the next screen.
        if let totp = TOTP(item.otp) {
            UIPasteboard.general.setItems([[UTType.plainText.identifier: totp.code()]],
                                          options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
        }
        extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: item.username, password: item.password))
    }
}

