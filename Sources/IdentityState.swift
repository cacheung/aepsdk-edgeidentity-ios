//
// Copyright 2021 Adobe. All rights reserved.
// This file is licensed to you under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License. You may obtain a copy
// of the License at http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software distributed under
// the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS
// OF ANY KIND, either express or implied. See the License for the specific language
// governing permissions and limitations under the License.
//

import AEPCore
import AEPServices
import Foundation

/// Manages the business logic of this Identity extension
class IdentityState {
    private(set) var hasBooted = false
    #if DEBUG
    var identityProperties: IdentityProperties
    #else
    private(set) var identityProperties: IdentityProperties
    #endif

    /// Creates a new `IdentityState` with the given Identity properties
    /// - Parameter identityProperties: Identity properties
    init(identityProperties: IdentityProperties) {
        self.identityProperties = identityProperties
    }

    /// Completes init for this Identity extension.
    /// Loads any persisted properties for this `IdentityState`.
    /// If an ECID is not loaded from persistence, attempts to migrate an existing ECID from the direct Identity extension, either from its persisted store or from its shared state if the
    /// direct Identity extension is registered. If no ECID is found for migration, then a new ECID is generated. Stores this `IdentityState` to persistence
    /// once an ECID is set.
    /// - Parameters:
    ///         - getSharedState: function to get a shared state from the EventHub
    ///         - createXDMSharedState: function to create a shared state on the EventHub
    /// - Returns: true if bootup completed, false if bootup is not complete
    func bootupIfReady(getSharedState: @escaping (_ name: String, _ event: Event?) -> SharedStateResult?,
                       createXDMSharedState: (_ data: [String: Any], _ event: Event?) -> Void) -> Bool {

        if hasBooted { return true }

        // load data from local storage
        identityProperties.loadFromPersistence()

        // Get new ECID on first launch
        if identityProperties.ecid == nil {
            let identityDirectSharedState = getIdentityDirectSharedState(getSharedState: getSharedState)

            // Attempt to get ECID from direct Identity persistence to migrate an existing ECID
            if let ecid = identityProperties.getEcidFromDirectIdentityPersistence() {
                identityProperties.ecid = ecid.ecidString // migrate ECID from direct Identity persisted store
                Log.debug(label: IdentityConstants.LOG_TAG, "IdentityState - Loading ECID from direct Identity extension on bootup '\(ecid)'")
            }
                // If direct Identity has no persisted ECID, check if direct Identity is registered with the SDK
            else if isIdentityDirectRegistered(getSharedState: getSharedState) {
                // If the direct Identity extension is registered, attempt to get its shared state
                if identityDirectSharedState.isSet {
                    // If the shared state is set, attempt to get the ECID
                    if let ecid = identityDirectSharedState.ecid {
                        identityProperties.ecid = ecid // migrate ECID from direct Identity shared state
                        Log.debug(label: IdentityConstants.LOG_TAG, "IdentityState - Bootup setting ECID from direct Identity " +
                            "extension shared state: '\(identityProperties.ecid?.description ?? "")'")
                    }
                        // If the shared state is set but does not contain an ECID, generate a new one
                    else {
                        identityProperties.ecid = ECID().ecidString
                        Log.debug(label: IdentityConstants.LOG_TAG, "IdentityState - Generating new ECID on bootup as direct Identity " +
                            "extension shared state contained none: '\(identityProperties.ecid?.description ?? "")'")
                    }
                }
                    // If there is no direct Identity shared state, abort boot-up and try again when direct Identity shares its state
                else {
                    Log.debug(label: IdentityConstants.LOG_TAG, "IdentityState - Bootup detected the direct Identity " +
                        "extension is registered, waiting for its state change.")
                    return false // If no ECID to migrate but Identity direct is registered, wait for Identity direct shared state
                }
            }
                // Generate a new ECID as the direct Identity extension is not registered with the SDK and there was no direct Identity persisted ECID
            else {
                identityProperties.ecid = ECID().ecidString // generate new ECID
                Log.debug(label: IdentityConstants.LOG_TAG, "IdentityState - Generating new ECID on bootup '\(identityProperties.ecid?.description ?? "")'")
            }

            // Whew! Save the new ECID
            identityProperties.saveToPersistence()
        }

        hasBooted = true
        Log.debug(label: IdentityConstants.LOG_TAG, "IdentityState - Edge Identity has successfully booted up")
        createXDMSharedState(identityProperties.toXdmData(), nil)
        return hasBooted
    }

    /// Update the customer identifiers by merging `updateIdentityMap` with the current identifiers. Any identifier in `updateIdentityMap` which
    /// has the same id in the same namespace will update the current identifier.
    /// Certain namespaces are not allowed to be modified and if exist in the given customer identifiers will be removed before the update operation is executed.
    /// The namespaces which cannot be modified through this function call include:
    /// - ECID
    /// - IDFA
    ///
    /// - Parameters
    ///   - event: event containing customer identifiers to add or update with the current customer identifiers
    ///   - createXDMSharedState: function which creates new XDM shared state
    func updateCustomerIdentifiers(event: Event, createXDMSharedState: ([String: Any], Event) -> Void) {
        guard let identifiersData = event.data else {
            Log.debug(label: IdentityConstants.FRIENDLY_NAME, "IdentityState - Failed to update identifiers as no identifiers were found in the event data.")
            return
        }

        guard let updateIdentityMap = IdentityMap.from(eventData: identifiersData) else {
            Log.debug(label: IdentityConstants.FRIENDLY_NAME, "IdentityState - Failed to update identifiers as the event data could not be encoded to an IdentityMap.")
            return
        }

        identityProperties.updateCustomerIdentifiers(updateIdentityMap)
        saveToPersistence(and: createXDMSharedState, using: event)
    }

    /// Remove customer identifiers specified in `event` from the current `IdentityMap`.
    /// - Parameters:
    ///   - event: event containing customer identifiers to remove from the current customer identities
    ///   - createXDMSharedState: function which creates new XDM shared states
    func removeCustomerIdentifiers(event: Event, createXDMSharedState: ([String: Any], Event) -> Void) {
        guard let identifiersData = event.data else {
            Log.debug(label: IdentityConstants.LOG_TAG, "IdentityState - Failed to remove identifier as no identifiers were found in the event data.")
            return
        }

        guard let removeIdentityMap = IdentityMap.from(eventData: identifiersData) else {
            Log.debug(label: IdentityConstants.LOG_TAG, "IdentityState - Failed to remove identifier as the event data could not be encoded to an IdentityMap.")
            return
        }

        identityProperties.removeCustomerIdentifiers(removeIdentityMap)
        saveToPersistence(and: createXDMSharedState, using: event)
    }

    /// Clears all identities and regenerates a new ECID value.
    /// Saves identities to persistence and creates a new XDM shared state and dispatches a new` resetComplete` event after operation completes.
    /// - Parameters:
    ///   - event: event which triggered the reset call
    ///   - createXDMSharedState: function which creates new XDM shared states
    ///   - eventDispatcher: function which dispatches a new `Event`
    func resetIdentifiers(event: Event,
                          createXDMSharedState: ([String: Any], Event) -> Void,
                          eventDispatcher: (Event) -> Void) {

        identityProperties.clear()
        identityProperties.ecid = ECID().ecidString

        saveToPersistence(and: createXDMSharedState, using: event)

        let event = Event(name: IdentityConstants.EventNames.RESET_IDENTITIES_COMPLETE,
                          type: EventType.edgeIdentity,
                          source: EventSource.resetComplete,
                          data: nil)
        eventDispatcher(event)
    }

    /// Update the legacy ECID property with `legacyEcid` provided it does not equal the current ECID or legacy ECID.
    /// - Parameter legacyEcid: the current ECID for the Identity Direct extension
    /// - Returns: true if the legacy ECID was updated, or false if the legacy ECID did not change
    func updateLegacyExperienceCloudId(_ legacyEcid: String) -> Bool {
        if legacyEcid == identityProperties.ecid || legacyEcid == identityProperties.ecidSecondary {
            return false
        }

        identityProperties.ecidSecondary = legacyEcid
        identityProperties.saveToPersistence()
        Log.debug(label: IdentityConstants.LOG_TAG, "IdentityState - Identity direct ECID updated to '\(legacyEcid)', updating the IdentityMap")
        return true
    }

    /// Save `identityProperties` to persistence and create an XDM shared state.
    /// - Parameters:
    ///   - createXDMSharedState: function which creates an XDM shared state
    ///   - event: the event used to share the XDM state
    private func saveToPersistence(and createXDMSharedState: ([String: Any], Event) -> Void, using event: Event) {
        identityProperties.saveToPersistence()
        createXDMSharedState(identityProperties.toXdmData(), event)
    }

    /// Check if the Identity direct extension is registered by checking the EventHub's shared state list of registered extensions.
    /// - Parameter: getSharedState: function to get shared states from the EventHub
    /// - Returns: true if the Identity direct extension is registered with the EventHub
    private func isIdentityDirectRegistered(getSharedState: (_ name: String, _ event: Event?) -> SharedStateResult?) -> Bool {
        if let registeredExtensionsWithHub = getSharedState(IdentityConstants.SharedState.Hub.SHARED_OWNER_NAME, nil)?.value,
            let extensions = registeredExtensionsWithHub[IdentityConstants.SharedState.Hub.EXTENSIONS] as? [String: Any],
            extensions[IdentityConstants.SharedState.IdentityDirect.SHARED_OWNER_NAME] as? [String: Any] != nil {
            return true
        }

        return false
    }

    /// Get the latest direct Identity shared state.
    /// - Parameter getSharedState: function to get shared states from the EventHub
    /// - Returns: `isSet` true if a shared state is set for the direct Identity extension
    ///            `ecid` string value of the shared direct Identity ECID, or nil if no ECID was found in the shared state
    private func getIdentityDirectSharedState(getSharedState: (_ name: String, _ event: Event?) -> SharedStateResult?) -> (isSet: Bool, ecid: String?) {
        guard let sharedStateResult = getSharedState(IdentityConstants.SharedState.IdentityDirect.SHARED_OWNER_NAME, nil) else {
            return (false, nil)
        }

        return (sharedStateResult.status == .set, sharedStateResult.value?[IdentityConstants.SharedState.IdentityDirect.VISITOR_ID_ECID] as? String)
    }

}
