import Foundation
import Security

/// Code-signing identity of the running app, and verification of a candidate
/// replacement bundle against it. Used by the in-app updater so that nothing
/// is installed unless it can be tied back to the same developer (or, for
/// ad-hoc local builds, at least proven intact and the same app).
enum CodeSignature {

    enum Identity: Equatable {
        /// Signed with an Apple-issued certificate; the string is the Team ID.
        case team(String)
        /// Ad-hoc signed (local builds) or signed without a Team ID: there is
        /// no identity to pin a replacement to.
        case adhoc
    }

    struct RunningApp {
        let bundleID: String
        let identity: Identity
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Bundle identifier and signing identity of the running process.
    static func runningApp() throws -> RunningApp {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw Failure(message: "Could not inspect this app's code signature.")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw Failure(message: "Could not inspect this app's code signature.")
        }
        let info = try signingInfo(staticCode)
        guard let bundleID = info[kSecCodeInfoIdentifier as String] as? String else {
            throw Failure(message: "This app is not code-signed, so updates cannot be verified.")
        }
        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return RunningApp(bundleID: bundleID, identity: .team(team))
        }
        return RunningApp(bundleID: bundleID, identity: .adhoc)
    }

    /// Verifies that `bundle` is a legitimate replacement for `running`: its
    /// signature must be intact (every file matches the seal), its bundle
    /// identifier must match, and — when the running app is signed with an
    /// Apple-issued certificate — it must be signed by the same Team ID under
    /// the Apple anchor. Throws with a user-facing message otherwise.
    static func verify(bundle: URL, replaces running: RunningApp) throws {
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &candidate) == errSecSuccess,
              let candidate else {
            throw Failure(message: "The downloaded app could not be read for signature verification.")
        }

        var requirement: SecRequirement?
        if case .team(let teamID) = running.identity {
            // Requirement language. Both values come from our own signing
            // information, not from the download.
            let text = "anchor apple generic and identifier \"\(running.bundleID)\" "
                + "and certificate leaf[subject.OU] = \"\(teamID)\""
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
                throw Failure(message: "Could not build the code-signing requirement.")
            }
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var cfError: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(candidate, flags, requirement, &cfError)
        guard status == errSecSuccess else {
            // SecCopyErrorMessageString names the reason ("code failed to satisfy
            // specified code requirement(s)", "invalid resource directory", …);
            // the CFError's own description is just a generic OSStatus line.
            _ = cfError?.takeRetainedValue()
            let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            let expectation: String
            switch running.identity {
            case .team(let teamID): expectation = "signed by Team ID \(teamID)"
            case .adhoc: expectation = "intact"
            }
            throw Failure(message: "The downloaded app's code signature is not \(expectation): \(detail). Nothing was installed.")
        }

        // The requirement above already pins the identifier for signed builds;
        // for ad-hoc builds check it here so an unrelated app cannot be
        // swapped in.
        let info = try signingInfo(candidate)
        guard info[kSecCodeInfoIdentifier as String] as? String == running.bundleID else {
            throw Failure(message: "The downloaded app has a different bundle identifier. Nothing was installed.")
        }
    }

    private static func signingInfo(_ code: SecStaticCode) throws -> [String: Any] {
        var cfInfo: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &cfInfo)
        guard status == errSecSuccess, let info = cfInfo as? [String: Any] else {
            throw Failure(message: "Could not read code-signing information.")
        }
        return info
    }
}
