import Foundation

/// Frequency ranges offered as one-click sweep presets.
struct BandPreset: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var start: Double
    var stop: Double
    var group: String
    /// A little margin either side so the whole band is visible.
    var padded: (Double, Double) {
        let margin = (stop - start) * 0.1
        return (max(1000, start - margin), stop + margin)
    }
}

enum BandPresets {
    static let amateur: [BandPreset] = [
        BandPreset(name: "630 m", start: 472e3, stop: 479e3, group: "Amateur"),
        BandPreset(name: "160 m", start: 1.8e6, stop: 2.0e6, group: "Amateur"),
        BandPreset(name: "80 m", start: 3.5e6, stop: 4.0e6, group: "Amateur"),
        BandPreset(name: "60 m", start: 5.25e6, stop: 5.45e6, group: "Amateur"),
        BandPreset(name: "40 m", start: 7.0e6, stop: 7.3e6, group: "Amateur"),
        BandPreset(name: "30 m", start: 10.1e6, stop: 10.15e6, group: "Amateur"),
        BandPreset(name: "20 m", start: 14.0e6, stop: 14.35e6, group: "Amateur"),
        BandPreset(name: "17 m", start: 18.068e6, stop: 18.168e6, group: "Amateur"),
        BandPreset(name: "15 m", start: 21.0e6, stop: 21.45e6, group: "Amateur"),
        BandPreset(name: "12 m", start: 24.89e6, stop: 24.99e6, group: "Amateur"),
        BandPreset(name: "10 m", start: 28.0e6, stop: 29.7e6, group: "Amateur"),
        BandPreset(name: "6 m", start: 50e6, stop: 54e6, group: "Amateur"),
        BandPreset(name: "4 m", start: 70e6, stop: 70.5e6, group: "Amateur"),
        BandPreset(name: "2 m", start: 144e6, stop: 148e6, group: "Amateur"),
        BandPreset(name: "1.25 m", start: 222e6, stop: 225e6, group: "Amateur"),
        BandPreset(name: "70 cm", start: 420e6, stop: 450e6, group: "Amateur"),
        BandPreset(name: "33 cm", start: 902e6, stop: 928e6, group: "Amateur"),
        BandPreset(name: "23 cm", start: 1240e6, stop: 1300e6, group: "Amateur"),
        BandPreset(name: "13 cm", start: 2300e6, stop: 2450e6, group: "Amateur")
    ]

    static let general: [BandPreset] = [
        BandPreset(name: "AM broadcast", start: 530e3, stop: 1710e3, group: "Broadcast & service"),
        BandPreset(name: "HF 1–30 MHz", start: 1e6, stop: 30e6, group: "Broadcast & service"),
        BandPreset(name: "FM broadcast", start: 88e6, stop: 108e6, group: "Broadcast & service"),
        BandPreset(name: "Airband", start: 108e6, stop: 137e6, group: "Broadcast & service"),
        BandPreset(name: "Marine VHF", start: 156e6, stop: 163e6, group: "Broadcast & service"),
        BandPreset(name: "DAB / TV III", start: 174e6, stop: 240e6, group: "Broadcast & service"),
        BandPreset(name: "UHF TV", start: 470e6, stop: 790e6, group: "Broadcast & service")
    ]

    static let ism: [BandPreset] = [
        BandPreset(name: "ISM 433 MHz", start: 433.05e6, stop: 434.79e6, group: "ISM & wireless"),
        BandPreset(name: "LoRa 868 MHz", start: 863e6, stop: 870e6, group: "ISM & wireless"),
        BandPreset(name: "LoRa 915 MHz", start: 902e6, stop: 928e6, group: "ISM & wireless"),
        BandPreset(name: "GSM 900", start: 880e6, stop: 960e6, group: "ISM & wireless"),
        BandPreset(name: "GPS L1", start: 1565e6, stop: 1586e6, group: "ISM & wireless"),
        BandPreset(name: "GSM 1800", start: 1710e6, stop: 1880e6, group: "ISM & wireless"),
        BandPreset(name: "Wi-Fi 2.4 GHz", start: 2400e6, stop: 2500e6, group: "ISM & wireless"),
        BandPreset(name: "Wi-Fi 5 GHz", start: 5150e6, stop: 5900e6, group: "ISM & wireless")
    ]

    static let allGroups: [(String, [BandPreset])] = [
        ("Amateur", amateur),
        ("Broadcast & service", general),
        ("ISM & wireless", ism)
    ]
}
