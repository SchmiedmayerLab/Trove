//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import _AuthenticationServices_SwiftUI
import AuthenticationServices
import SwiftUI
import TroveAPIClient


struct ProviderConnectionsSection: View {
    private enum Action: Hashable { case connect(String), disconnect(String), refresh }
    private struct Selection: Hashable {
        let session: KeycloakSessionSnapshot
        let action: Action
    }

    @Environment(ProviderConnectionsModel.self) private var model
    @Environment(\.webAuthenticationSession) private var authentication
    @Environment(\.locale) private var locale
    @State private var selection: Selection?
    @State private var disconnecting: Components.Schemas.ProviderConnection?

    var body: some View {
        if model.offersWearableServices {
            section
        }
    }

    private var section: some View {
        Section {
            if model.isBusy { ProgressView("Updating wearable connections…") }
            ForEach(model.connections, id: \.id) { connection in
                connectionRow(connection)
            }
            ForEach(model.registrations, id: \.id) { registration in
                if !model.connections.contains(where: { $0.registrationId == registration.id && $0.state == .active }) {
                    VStack(alignment: .leading) {
                        Button {
                            select(.connect(registration.id))
                        } label: {
                            Text("Connect \(registration.displayName)")
                        }
                        .disabled(redirect(for: registration) == nil)
                        Text("\(registration.controller) · \(registration.region)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.registrations.isEmpty, !model.registrations.contains(where: { redirect(for: $0) != nil }) {
                Text("Connecting a wearable service is not configured in this installation. Contact your study team.")
                    .foregroundStyle(.secondary)
            }
            if model.hasFailed {
                Text("Wearable connections could not be updated. Refresh to check their current status.")
                    .foregroundStyle(.secondary)
            }
            Button("Refresh Connections") { select(.refresh) }
        } header: {
            Text("Wearable Services")
        } footer: {
            Text("Connecting a service does not enroll you in a study. Only data covered by your accepted study settings is collected.")
        }
        .disabled(model.isBusy || model.sessionSnapshot == nil)
        .task(id: model.sessionSnapshot) {
            selection = nil
            disconnecting = nil
        }
        .task(id: selection) {
            guard let selection, selection.session == model.sessionSnapshot else {
                return
            }
            switch selection.action {
            case .refresh: await model.refresh()
            case .disconnect(let id):
                if let connection = model.connections.first(where: { $0.id == id }) { await model.disconnect(connection) }
            case .connect(let id):
                if let registration = model.registrations.first(where: { $0.id == id }), let redirect = redirect(for: registration) {
                    await model.connect(registration: registration, redirect: redirect) { authorization, callback in
                        let components = try ProviderAuthorizationCallback.redirectComponents(callback)
                        guard let host = components.host else { throw ProviderAuthorizationCallback.Failure.invalidRedirect }
                        do {
                            return try await authentication.authenticate(
                                using: authorization, callback: .https(host: host, path: components.path), additionalHeaderFields: [:]
                            )
                        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                            throw CancellationError()
                        }
                    }
                }
            }
            if self.selection == selection { self.selection = nil }
        }
        .confirmationDialog(
            "Disconnect this wearable service?",
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                if let connection = disconnecting { select(.disconnect(connection.id)) }
                disconnecting = nil
            }
            Button("Cancel", role: .cancel) { disconnecting = nil }
        } message: {
            Text("New data collection from this connection will stop. Previously accepted study data follows the study retention settings.")
        }
    }

    private func connectionRow(_ connection: Components.Schemas.ProviderConnection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.registrations.first { $0.id == connection.registrationId }?.displayName ?? String(localized: "Previously Connected Service"))
                .font(.headline)
            switch connection.state {
            case .active: Text("Connected")
            case .disconnected: Text("Disconnected")
            case .reauthorizationRequired: Text("Authorization needs to be renewed.")
            }
            if let successful = connection.lastSuccessfulFetch { LabeledContent("Last successful check", value: successful, format: .dateTime) }
            if let accepted = connection.acceptedThrough { LabeledContent("Data accepted through", value: accepted, format: .dateTime) }
            if connection.state == .active, let attempt = connection.collectionAttempt {
                collectionAttempt(attempt, registrationID: connection.registrationId)
            }
            if connection.state != .disconnected {
                Button("Disconnect", role: .destructive) { disconnecting = connection }
            }
        }
    }

    private func collectionAttempt(_ attempt: Components.Schemas.ProviderCollectionAttempt, registrationID: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Latest collection attempt").font(.subheadline)
            LabeledContent("Data source", value: sourceTitle(attempt.sourceTypeIdentifier, registrationID: registrationID))
            switch attempt.outcome {
            case .scheduled: Text("Collection is scheduled.")
            case .deferred: Text("Collection is waiting for its next opportunity.")
            case .accepted: Text("Data from this attempt was accepted.")
            case .noCurrentDemand: Text("No current study collection is requested for this source.")
            case .transientFailure: Text("The service could not be reached. Collection will retry.")
            case .capacityBlocked: Text("Collection is paused because a capacity limit was reached. Contact the study team.")
            case .sourceBlocked: Text("This source could not be collected. Contact the study team.")
            case .authorizationChanged: Text("Collection permissions changed. Refresh to review the connection.")
            }
            LabeledContent("Next check", value: attempt.nextAttempt, format: .dateTime)
            Text("This status applies to the named source, not every source on your account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceTitle(_ token: String, registrationID: String) -> String {
        let capability = model.registrations.first { $0.id == registrationID }?.capabilities.first { $0.sourceTypeIdentifier == token }
        guard let measurements = capability?.measurements, !measurements.isEmpty else {
            return String(localized: "Previously selected data")
        }
        return measurements.map { locale.language.languageCode?.identifier == "de" ? $0.displayNameGerman : $0.displayNameEnglish }
            .joined(separator: ", ")
    }

    private func redirect(for registration: Components.Schemas.ProviderRegistration) -> Components.Schemas.ProviderRedirect? {
        guard let configured = Config.providerRedirectURI else {
            return nil
        }
        return registration.redirects.first { URL(string: $0.uri) == configured }
    }

    private func select(_ action: Action) {
        guard let session = model.sessionSnapshot else {
            return
        }
        selection = .init(session: session, action: action)
    }
}
