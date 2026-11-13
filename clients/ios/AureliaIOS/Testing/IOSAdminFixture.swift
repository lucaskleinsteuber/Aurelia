#if DEBUG
  import Foundation

  /// Invented answers for server administration in the "admin" UI scenario, so the Settings
  /// screens can be looked at and photographed in the simulator. There is no server, media or
  /// personal data: names, folders and addresses are made up (addresses from 192.0.2.0/24).
  enum IOSAdminFixture {
    static let movies = "00000000-0000-4000-8000-0000000000a1"
    static let shows = "00000000-0000-4000-8000-0000000000a2"
    static let archive = "00000000-0000-4000-8000-0000000000a3"
    static let stamp = "2026-11-13T18:00:00Z"
    static let earlier = "2026-11-12T20:15:00Z"

    static func answer(path: String, method: String, query: [String: String]) -> Any? {
      switch (method, path) {
      case ("GET", "/api/v1/libraries"): return libraries
      case ("GET", "/api/v1/libraries/scans"): return [scan(library: shows, active: true)]
      case ("GET", "/api/v1/libraries/folders"): return folders(query["path"])
      case ("GET", "/api/v1/server/settings"): return settings
      case ("GET", "/api/v1/server/status"): return status
      case ("GET", "/api/v1/server/health"): return health
      case ("GET", "/api/v1/server/capabilities"):
        return ["nativeHostOperations": false, "encryptedBackups": true, "transcoding": true,
                "platform": "linux", "linuxPackage": true]
      case ("GET", "/api/v1/server/power"):
        return ["available": true, "mode": "shutdown", "idleMinutes": 15, "wakeOnAccess": false,
                "wakeSupport": "supported", "hosting": "linuxServer", "network": "wired",
                "wakeOn": "g", "sleepKind": "deep"]
      case ("GET", "/api/v1/server/updates"):
        return ["available": true, "installed": "2.15.0", "newest": "2.15.0", "updateAvailable": false,
                "state": "idle", "checkedAt": stamp]
      case ("GET", "/api/v1/server/users"): return users
      case ("GET", "/api/v1/auth/sessions"): return ownDevices
      case ("GET", "/api/v1/server/security/devices"): return securityDevices
      case ("GET", "/api/v1/server/security/blocked"):
        return [["id": "00000000-0000-4000-8000-0000000000e1", "deviceName": "Unknown Tablet",
                 "platform": "Browser · Chrome on Android", "ipAddress": "192.0.2.77", "blockedAt": earlier]]
      case ("GET", "/api/v1/server/security/settings"):
        return ["securityLogDays": 90, "requirePasskeysForAdministrators": false, "passkeyCount": 1]
      case ("GET", "/api/v1/server/security/alerts"):
        return ["version": 1, "newDevices": [], "unlockRequests": []]
      case ("GET", "/api/v1/management/passkeys"):
        return [["id": "00000000-0000-4000-8000-0000000000f1", "userId": IOSUITestFixtures.profileID.uuidString,
                 "userName": "Alex", "name": "Alex’s Mac", "createdAt": earlier, "lastUsedAt": stamp,
                 "isThisDevice": false]]
      case ("GET", "/api/v1/metadata/provider"):
        return ["enabled": true, "hasToken": true, "language": "en-US", "artworkBytes": 412_000_000,
                "artworkLimitBytes": 2_000_000_000, "provider": "TMDB",
                "attribution": "This product uses the TMDB API but is not endorsed or certified by TMDB."]
      case ("GET", "/api/v1/metadata/jobs"): return [metadataJob]
      case ("GET", "/api/v1/metadata/reviews"): return []
      case ("GET", "/api/v1/metadata/subtitles"):
        return ["enabled": true, "hasApiKey": true, "hasAccount": false, "languages": ["en", "de"],
                "automatic": true, "provider": "OpenSubtitles", "attribution": "Subtitles from OpenSubtitles.com",
                "downloadedCount": 14]
      case ("GET", "/api/v1/library/health/duplicates"):
        return [["key": "dup-1", "title": "The Lighthouse Keeper", "kind": "movie", "year": 2019,
                 "items": [
                   ["id": "00000000-0000-4000-8000-0000000000b1", "title": "The Lighthouse Keeper",
                    "kind": "movie", "year": 2019, "fileName": "The Lighthouse Keeper (2019).mkv",
                    "fileSize": 8_400_000_000, "availability": "available"],
                   ["id": "00000000-0000-4000-8000-0000000000b2", "title": "The Lighthouse Keeper",
                    "kind": "movie", "year": 2019, "fileName": "The Lighthouse Keeper 720p.mp4",
                    "fileSize": 2_100_000_000, "availability": "available"],
                 ]]]
      case ("GET", "/api/v1/library/health/offline"):
        return [["id": "00000000-0000-4000-8000-0000000000c1", "title": "Northern Lights", "kind": "movie",
                 "year": 2021, "libraryName": "Archive", "fileName": "Northern Lights.mkv",
                 "lastSeenAt": "2026-09-30T10:00:00Z", "daysOffline": 44]]
      case ("GET", "/api/v1/library/health/unmatched"):
        return [["id": "00000000-0000-4000-8000-0000000000d1", "title": "Holiday 2024", "kind": "movie",
                 "year": NSNull(), "fileName": "Holiday 2024 final cut.mp4", "issueReason": "noMatch"]]
      default:
        break
      }
      if method == "GET", path.hasPrefix("/api/v1/libraries/") {
        let parts = path.split(separator: "/")
        guard parts.count == 5 else { return nil }
        let library = String(parts[3])
        switch parts[4] {
        case "scans": return [scan(library: library, active: library == shows), scan(library: library, active: false)]
        case "exclusions":
          return library == movies
            ? [["id": "00000000-0000-4000-8000-0000000000e2", "libraryId": library,
                "relativePath": "Samples", "isDirectory": true]] : []
        case "discoveries":
          return library == movies
            ? [["id": "00000000-0000-4000-8000-0000000000e3", "libraryId": library,
                "relativePath": "Concerts/Live at the Harbor", "detectedTitle": "Live at the Harbor",
                "suggestedKind": NSNull(), "reason": "mixed", "decision": NSNull()]] : []
        case "import-reviews":
          return library == movies
            ? [["id": "00000000-0000-4000-8000-0000000000e4", "libraryId": library,
                "relativePath": "The Lighthouse Keeper/Behind the Scenes.mkv",
                "detectedTitle": "Behind the Scenes", "reason": "An extra without a movie it clearly belongs to.",
                "state": "pending"]] : []
        default: return nil
        }
      }
      if method != "GET" { return [:] }
      return nil
    }

    static func library(_ id: String, _ name: String, _ path: String, kind: String, available: Bool = true,
                        watching: Bool = true, review: Bool = false) -> [String: Any] {
      ["id": id, "name": name, "path": path, "kind": kind, "availability": available ? "available" : "unavailable",
       "createdAt": "2026-10-22T12:00:00Z", "lastScanStartedAt": earlier, "lastScanCompletedAt": earlier,
       "lastError": NSNull(), "monitoringEnabled": watching, "importPreviewRequired": review,
       "health": available ? "healthy" : "waitingForStorage"]
    }

    static var libraries: [[String: Any]] {
      [library(movies, "Movies", "/mnt/media/Movies", kind: "movies"),
       library(shows, "TV Shows", "/mnt/media/TV Shows", kind: "tvShows"),
       library(archive, "Archive", "/mnt/archive", kind: "automatic", available: false, watching: false,
               review: true)]
    }

    static func scan(library: String, active: Bool) -> [String: Any] {
      ["id": active ? "00000000-0000-4000-8000-000000000101" : "00000000-0000-4000-8000-000000000102",
       "libraryId": library, "state": active ? "running" : "completed", "createdAt": active ? stamp : earlier,
       "startedAt": active ? stamp : earlier, "completedAt": active ? NSNull() : earlier,
       "filesDiscovered": 1_240, "filesProcessed": active ? 530 : 1_240, "addedFiles": active ? 12 : 3,
       "updatedFiles": active ? 2 : 0, "missingFiles": 0, "skippedFiles": active ? 0 : 1, "error": NSNull(),
       "issues": active ? [] : [["code": "unreadable", "message": "One file couldn’t be read.",
                                  "path": "Season 2/Episode 07.mkv"]],
       "trigger": active ? "manual" : "fileChange", "phase": active ? "reading" : NSNull()]
    }

    static func folders(_ path: String?) -> [String: Any] {
      guard let path, !path.isEmpty else {
        return ["path": NSNull(), "parent": NSNull(), "folders": [
          ["name": "Media Drive", "path": "/mnt/media"], ["name": "Archive Drive", "path": "/mnt/archive"],
          ["name": "Home", "path": "/home/server"]]]
      }
      return ["path": path, "parent": (path as NSString).deletingLastPathComponent, "folders": [
        ["name": "Movies", "path": path + "/Movies"], ["name": "TV Shows", "path": path + "/TV Shows"],
        ["name": "Concerts", "path": path + "/Concerts"]]]
    }

    static var settings: [String: Any] {
      ["stored": ["pairingEnabled": true, "automaticBackupsEnabled": true, "monitoringEnabled": true,
                  "bonjourEnabled": true, "serverName": "Living Room Server"],
       "active": ["serverName": "Living Room Server", "lanAccessEnabled": true, "lanHttpsPort": 43111],
       "restartRequired": false]
    }

    static var status: [String: Any] {
      ["state": "ready", "version": "2.15.0", "uptimeSeconds": 273_600, "activeStreams": 1,
       "databaseBytes": 48_000_000, "users": 3, "libraries": 3, "freeDiskBytes": 1_200_000_000_000,
       "certificateExpiresAt": "2028-10-22T12:00:00Z", "networkAddresses": ["192.0.2.10"],
       "readiness": ["state": "degraded", "checkedAt": stamp, "components": [
         ["id": "database", "state": "ready", "reason": NSNull()],
         ["id": "media", "state": "degraded", "reason": "One storage location is not connected."]]]]
    }

    static var health: [String: Any] {
      ["uptimeSeconds": 273_600, "freeDiskBytes": 1_200_000_000_000, "databaseBytes": 48_000_000,
       "scrubPreviewTitleCount": 120, "scrubPreviewBytes": 640_000_000, "scrubPreviewPendingCount": 4,
       "activeLiveConversions": 0, "activeStreams": 1, "offlineMediaCount": 1,
       "lastScan": ["scanId": "00000000-0000-4000-8000-000000000102", "state": "completed", "startedAt": earlier,
                    "completedAt": earlier, "durationSeconds": 42, "addedFiles": 3, "updatedFiles": 0,
                    "missingFiles": 0, "failedFiles": 1],
       "backgroundJobs": ["activeScans": 1, "activeMetadataJobs": 0, "activeScrubPreviewJobs": 1],
       "recentIssues": [],
       "backup": ["enabled": true, "lastAttemptFailed": false, "lastSucceededAt": earlier, "totalBackups": 7,
                  "totalBackupBytes": 330_000_000]]
    }

    static func user(_ id: String, _ name: String, role: String, age: Int? = nil, pin: Bool = true,
                     access: String = "entireLibrary") -> [String: Any] {
      ["user": ["id": id, "username": name, "role": role, "pinProtectionEnabled": pin, "accessMode": access,
                "ageLimit": age.map { $0 as Any } ?? NSNull()],
       "isEnabled": true, "libraryIds": []]
    }

    static var users: [[String: Any]] {
      [user(IOSUITestFixtures.profileID.uuidString, "Alex", role: "owner"),
       user("00000000-0000-4000-8000-000000000201", "Sam", role: "admin"),
       user("00000000-0000-4000-8000-000000000202", "Mia", role: "user", age: 12, access: "selectedTitles")]
    }

    static var ownDevices: [[String: Any]] {
      [["id": IOSUITestFixtures.serverID.uuidString, "userId": IOSUITestFixtures.profileID.uuidString,
        "deviceName": "Alex’s iPhone", "createdAt": earlier, "lastSeenAt": stamp,
        "expiresAt": "2099-01-01T00:00:00Z", "revokedAt": NSNull(), "isCurrent": true]]
    }

    static func device(_ id: String, _ name: String, _ user: String, platform: String, ip: String,
                       new: Bool = false, current: Bool = false) -> [String: Any] {
      ["id": id, "userId": IOSUITestFixtures.profileID.uuidString, "userName": user, "deviceName": name,
       "platform": platform, "clientVersion": "2.15.0", "ipAddress": ip, "createdAt": earlier,
       "lastSeenAt": stamp, "isNew": new, "canBlock": !current, "isCurrent": current]
    }

    static var securityDevices: [[String: Any]] {
      [device(IOSUITestFixtures.serverID.uuidString, "Alex’s iPhone", "Alex", platform: "iPhone or iPad",
              ip: "192.0.2.21", current: true),
       device("00000000-0000-4000-8000-000000000301", "Living Room", "Alex", platform: "Apple TV", ip: "192.0.2.30"),
       device("00000000-0000-4000-8000-000000000302", "Kitchen Laptop", "Sam", platform: "Browser · Firefox on Linux",
              ip: "192.0.2.44", new: true)]
    }

    static var metadataJob: [String: Any] {
      ["id": "00000000-0000-4000-8000-000000000401", "libraryId": NSNull(), "mediaId": NSNull(),
       "state": "completed", "itemsTotal": 15, "itemsProcessed": 15, "itemsMatched": 14,
       "itemsNeedingReview": 0, "itemsFailed": 1, "error": NSNull(), "createdAt": earlier,
       "startedAt": earlier, "completedAt": earlier]
    }
  }
#endif
