import SwiftUI

enum AureliaHomeDesign {
  static let pagePadding: CGFloat = 32
  static let cardRadius: CGFloat = 18
  static let sectionSpacing: CGFloat = 24
  static let pageTitle = Font.system(size: 34, weight: .bold)
  static let sectionTitle = Font.system(size: 20, weight: .semibold)
}

struct AureliaHomeBackdrop: View {
  var body: some View {
    LinearGradient(
      colors: [
        Color(red: 0.075, green: 0.085, blue: 0.105),
        Color(red: 0.025, green: 0.029, blue: 0.038),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .ignoresSafeArea()
  }
}

struct AvailabilityBadge: View {
  let availability: MediaAvailability

  var body: some View {
    if availability == .missing {
      Label("Missing", systemImage: "exclamationmark.triangle.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(.orange)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.orange.opacity(0.12), in: Capsule())
    }
  }
}

struct ErrorBanner: View {
  let message: String
  var retry: (() -> Void)?

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let retry {
        Button("Try Again", action: retry)
      }
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .padding(.horizontal, AureliaHomeDesign.pagePadding)
    .padding(.bottom, 18)
  }
}
