import SwiftUI

public struct IOSRootView: View {
  @ObservedObject var model: IOSAppModel
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var selectedSection: IOSNavigationSection = .home

  public init(model: IOSAppModel) {
    self.model = model
  }

  public var body: some View {
    Group {
      if horizontalSizeClass == .regular {
        // iPad Sidebar Layout
        NavigationSplitView {
          List {
            ForEach(IOSNavigationSection.allCases) { section in
              Button(action: { selectedSection = section }) {
                HStack {
                  Label(section.rawValue, systemImage: section.systemImage)
                  Spacer()
                  if selectedSection == section {
                    Image(systemName: "checkmark")
                      .font(.caption.bold())
                  }
                }
              }
              .foregroundStyle(selectedSection == section ? .white : .primary)
            }
          }
          .navigationTitle("Aurelia")
          .listStyle(.sidebar)
        } detail: {
          sectionContent(selectedSection)
        }
      } else {
        // iPhone Tab Bar Layout
        TabView(selection: $selectedSection) {
          IOSHomeView(model: model)
            .tabItem {
              Label(
                IOSNavigationSection.home.rawValue,
                systemImage: IOSNavigationSection.home.systemImage)
            }
            .tag(IOSNavigationSection.home)

          IOSLibraryView(model: model)
            .tabItem {
              Label(
                IOSNavigationSection.library.rawValue,
                systemImage: IOSNavigationSection.library.systemImage)
            }
            .tag(IOSNavigationSection.library)

          IOSSearchView(model: model)
            .tabItem {
              Label(
                IOSNavigationSection.search.rawValue,
                systemImage: IOSNavigationSection.search.systemImage)
            }
            .tag(IOSNavigationSection.search)

          IOSSettingsView(model: model)
            .tabItem {
              Label(
                IOSNavigationSection.settings.rawValue,
                systemImage: IOSNavigationSection.settings.systemImage)
            }
            .tag(IOSNavigationSection.settings)
        }
        .tint(.white)
      }
    }
    .fullScreenCover(isPresented: $model.isPlayingMedia) {
      IOSPlayerView(controller: model.playbackController) {
        model.isPlayingMedia = false
      }
    }
    .sheet(item: $model.pinPromptProfile) { profile in
      IOSPinPromptSheet(profile: profile) { pin in
        Task {
          _ = try? await model.switchProfile(profile, pin: pin)
        }
      }
    }
    .task {
      await model.bootstrap()
    }
  }

  @ViewBuilder
  private func sectionContent(_ section: IOSNavigationSection) -> some View {
    switch section {
    case .home:
      IOSHomeView(model: model)
    case .library:
      IOSLibraryView(model: model)
    case .search:
      IOSSearchView(model: model)
    case .settings:
      IOSSettingsView(model: model)
    }
  }
}
