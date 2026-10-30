import SwiftUI

public struct IOSProfilePickerView: View {
  @ObservedObject var model: IOSAppModel
  @Environment(\.dismiss) private var dismiss

  public init(model: IOSAppModel) {
    self.model = model
  }

  public var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 20)], spacing: 24
        ) {
          ForEach(model.profiles) { profile in
            Button(action: {
              Task {
                do {
                  if try await model.switchProfile(profile) {
                    dismiss()
                  }
                } catch {
                  // Handled by model
                }
              }
            }) {
              VStack(spacing: 10) {
                ZStack {
                  Circle()
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .frame(width: 90, height: 90)

                  Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.85))

                  if profile.hasPin {
                    Image(systemName: "lock.fill")
                      .font(.caption)
                      .padding(6)
                      .background(.black.opacity(0.7))
                      .clipShape(Circle())
                      .offset(x: 30, y: 30)
                  }
                }

                Text(profile.name)
                  .font(.headline)
                  .foregroundStyle(.primary)

                if model.currentProfile?.id == profile.id {
                  Text("Active")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.white)
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
                }
              }
            }
            .buttonStyle(.plain)
          }
        }
        .padding(24)
      }
      .navigationTitle("Switch Profile")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }
}

public struct IOSPinPromptSheet: View {
  let profile: IOSUserProfile
  let onSubmit: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var pin: String = ""

  public init(profile: IOSUserProfile, onSubmit: @escaping (String) -> Void) {
    self.profile = profile
    self.onSubmit = onSubmit
  }

  public var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Image(systemName: "lock.shield.fill")
          .font(.system(size: 60))
          .foregroundStyle(.white)

        Text("Enter PIN for \(profile.name)")
          .font(.title3.bold())

        SecureField("4-digit PIN", text: $pin)
          .keyboardType(.numberPad)
          .multilineTextAlignment(.center)
          .font(.title.monospaced())
          .frame(width: 160)
          .padding()
          .background(Color(uiColor: .secondarySystemBackground))
          .clipShape(RoundedRectangle(cornerRadius: 12))

        Button("Unlock") {
          onSubmit(pin)
          dismiss()
        }
        .disabled(pin.count < 4)
        .buttonStyle(.borderedProminent)
        .tint(.white)
        .foregroundStyle(.black)

        Spacer()
      }
      .padding(.top, 40)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium])
  }
}
