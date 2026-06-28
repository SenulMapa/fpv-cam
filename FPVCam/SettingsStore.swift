import Observation

/// Thin umbrella that groups the three settings sub-stores so they can be passed around together.
/// Observation of individual properties works because each sub-store is itself `@Observable`.
@Observable
final class SettingsStore {
    let video    = VideoSettings()
    let lens     = LensSettings()
    let exposure = ExposureSettings()
}
