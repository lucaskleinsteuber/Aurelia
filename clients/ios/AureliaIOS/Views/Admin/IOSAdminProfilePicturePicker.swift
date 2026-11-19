import SwiftUI

/// The actual identity being edited, separate from the controls that choose a picture.
struct IOSAdminProfileIdentity: View {
  let name: String
  let role: String
  let picture: String?
  var id: UUID?
  var pictureRevision: Int64 = 0

  private var shownName: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "New Profile" : trimmed
  }

  var body: some View {
    HStack(spacing: 16) {
      IOSProfilePicture(
        id: id, name: shownName, size: 72, pictureKey: picture,
        pictureRevision: pictureRevision)
      VStack(alignment: .leading, spacing: 4) {
        Text(shownName).font(.headline)
        Text(IOSAdminText.role(role)).font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
  }
}

/// Keep the name label visible after the field has a value.
struct IOSAdminProfileNameField: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Binding var name: String

  var body: some View {
    LabeledContent("Name") {
      TextField("Name", text: $name, prompt: Text("Required"))
        .textContentType(.name)
        .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
    }
  }
}

/// Built-in picture controls: colors show colors, symbols show symbols. The profile above
/// previews the result, so this grid does not repeat a whole decorated avatar in every cell.
struct IOSAdminPicturePicker: View {
  @Binding var selection: String?
  let name: String
  @State private var palette = IOSProfilePictures.palettes[0]

  private var parsed: (symbol: String, palette: String)? { IOSProfilePictures.parse(selection) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Color").font(.caption).foregroundStyle(.secondary)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 4) {
            ForEach(IOSProfilePictures.palettes, id: \.self) { color in
              colorButton(color)
            }
          }
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Symbol").font(.caption).foregroundStyle(.secondary)
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 8)],
          alignment: .leading, spacing: 8
        ) {
          symbolButton(nil)
          ForEach(IOSProfilePictures.symbols, id: \.self) { symbol in symbolButton(symbol) }
        }
      }
    }
    .padding(.vertical, 6)
    .onAppear { if let parsed { palette = parsed.palette } }
    .onChange(of: selection) { _, _ in if let parsed { palette = parsed.palette } }
  }

  private func colorButton(_ color: String) -> some View {
    let colors = IOSProfilePicture.namedPalette(color)
    let selected = parsed?.palette == color
    return Button {
      palette = color
      selection = IOSProfilePictures.builtin(symbol: parsed?.symbol ?? "star", palette: color)
    } label: {
      Circle()
        .fill(LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom))
        .overlay {
          if selected {
            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
              .foregroundStyle(.white)
          }
        }
        .frame(width: 30, height: 30)
        .padding(3)
        .overlay {
          if selected {
            Circle().strokeBorder(Color.white, lineWidth: 2)
          }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(color.capitalized) color")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func symbolButton(_ symbol: String?) -> some View {
    let selected = symbol.map { parsed?.symbol == $0 } ?? (selection == nil)
    let color: Color = selected ? .blue : .primary
    return Button {
      selection = symbol.map { IOSProfilePictures.builtin(symbol: $0, palette: palette) }
    } label: {
      Group {
        if let symbol {
          if symbol == "rocket" {
            IOSRocketShape().fill(color, style: FillStyle(eoFill: true))
              .frame(width: 24, height: 24)
          } else {
            Image(systemName: IOSProfilePictures.systemImage(for: symbol))
              .font(.system(size: 22, weight: .medium))
          }
        } else {
          Text(IOSProfileColor.initial(of: name.isEmpty ? "A" : name))
            .font(.system(size: 22, weight: .medium, design: .rounded))
        }
      }
      .foregroundStyle(color)
      .frame(maxWidth: .infinity, minHeight: 44)
      .background(
        selected ? Color.blue.opacity(0.14) : Color.primary.opacity(0.04),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(selected ? Color.blue : .clear, lineWidth: 1.5)
      }
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Self.symbolLabel(symbol))
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private static func symbolLabel(_ symbol: String?) -> String {
    guard let symbol else { return "Use Initial" }
    switch symbol {
    case "gamecontroller": return "Game Controller"
    default: return symbol.capitalized
    }
  }
}
