import SwiftUI

/// Sets up waking the server through a FRITZ!Box, for an Apple TV that may not wake it itself.
struct TVRouterWakeView: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var host = TVRouterWake.defaultHost
  @State private var username = ""
  @State private var password = ""
  @State private var working = false
  @State private var message: String?
  @State private var loaded = false

  var body: some View {
    HStack(alignment: .top, spacing: 90) {
      VStack(spacing: 26) {
        Image(systemName: "power.circle.fill").font(.system(size: 150))
          .symbolRenderingMode(.hierarchical).foregroundStyle(.white.opacity(0.85))
        Text("Wake with FRITZ!Box").font(.system(size: 48, weight: .bold))
          .multilineTextAlignment(.center)
        Text(
          "Apple TV can’t wake a sleeping server by itself. If your router is a FRITZ!Box, Aurelia asks it to wake the server whenever the server is off."
        )
        .font(.system(size: 24)).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }.frame(width: 560).padding(.top, 100)
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if model.routerWake != nil {
            Label("Set up on this Apple TV", systemImage: "checkmark.circle.fill")
              .font(.title3).foregroundStyle(.green)
              .accessibilityIdentifier("router-wake-configured")
          }
          TextField("FRITZ!Box Address", text: $host)
            .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
            .autocorrectionDisabled().accessibilityIdentifier("router-wake-host")
          TextField("FRITZ!Box User Name", text: $username)
            .textContentType(.username).textInputAutocapitalization(.never)
            .autocorrectionDisabled().accessibilityIdentifier("router-wake-user")
          SecureField(
            model.routerWake == nil ? "FRITZ!Box Password" : "New Password (optional)",
            text: $password)
            .textContentType(.password).accessibilityIdentifier("router-wake-password")
          Text(
            "Use a FRITZ!Box user that may change FRITZ!Box settings, and keep “Allow access for applications” on in Home Network › Network › Network Settings. The sign-in stays in this Apple TV’s keychain."
          )
          .font(.system(size: 22)).foregroundStyle(.secondary)
          HStack(spacing: 30) {
            Button(model.routerWake == nil ? "Save and Test" : "Save Changes and Test") {
              working = true
              message = nil
              Task {
                // An empty password keeps the saved one, which is never shown again.
                message = await model.saveRouterWake(
                  host: host, username: username,
                  password: password.isEmpty ? model.routerWake?.password ?? "" : password)
                if model.routerWake != nil, message == nil {
                  message = "The FRITZ!Box accepted the sign-in."
                }
                working = false
              }
            }
            .buttonStyle(TVButtonStyle(kind: .primary))
            .disabled(working || (password.isEmpty && model.routerWake == nil))
            .accessibilityIdentifier("router-wake-save")
            if model.routerWake != nil {
              Button("Remove", role: .destructive) {
                model.removeRouterWake()
                password = ""
                message = nil
              }
              .disabled(working).accessibilityIdentifier("router-wake-remove")
            }
          }.padding(.top, 10)
          if working { ProgressView("Asking the FRITZ!Box…") }
          if let message {
            Text(message).font(.callout).foregroundStyle(.secondary)
              .accessibilityIdentifier("router-wake-message")
          }
        }.frame(maxWidth: 900, alignment: .leading).padding(.vertical, 40).padding(.horizontal, 20)
      }.frame(maxWidth: .infinity).focusSection()
    }.padding(.horizontal, TVDesign.pagePadding).padding(.top, 20)
      .background(TVDesign.canvas.ignoresSafeArea())
      .onAppear {
        guard !loaded else { return }
        loaded = true
        if let account = model.routerWake {
          host = account.host
          username = account.username
        }
      }
  }
}
