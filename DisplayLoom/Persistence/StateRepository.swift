import Foundation
import os

protocol StatePersisting: AnyObject {
  func load() -> PersistedState
  func save(_ state: PersistedState)
}

final class StateRepository: StatePersisting {
  static let storageKey = "persistedState.v1"

  private let defaults: UserDefaults
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let logger = Logger(subsystem: "dev.narumi.DisplayLoom", category: "Persistence")

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    decoder = JSONDecoder()
  }

  func load() -> PersistedState {
    guard let data = defaults.data(forKey: Self.storageKey) else {
      return PersistedState()
    }

    do {
      let state = try decoder.decode(PersistedState.self, from: data)
      guard state.version == PersistedState.currentVersion else {
        logger.error("Unsupported persisted state version: \(state.version)")
        return PersistedState()
      }
      return state
    } catch {
      logger.error(
        "Could not decode persisted state: \(error.localizedDescription, privacy: .public)"
      )
      return PersistedState()
    }
  }

  func save(_ state: PersistedState) {
    do {
      defaults.set(try encoder.encode(state), forKey: Self.storageKey)
    } catch {
      logger.error(
        "Could not encode persisted state: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
