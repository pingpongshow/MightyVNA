import Foundation

public enum PlotKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case rectangular
    case smith
    case polar
    case timeDomain
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .rectangular: return "Rectangular"
        case .smith: return "Smith Chart"
        case .polar: return "Polar"
        case .timeDomain: return "Time Domain / TDR"
        }
    }
    public var systemImage: String {
        switch self {
        case .rectangular: return "chart.xyaxis.line"
        case .smith: return "circle.circle"
        case .polar: return "dot.circle.and.hand.point.up.left.fill"
        case .timeDomain: return "waveform.path"
        }
    }
}

public enum ChartLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    case single
    case twoRows
    case twoColumns
    case grid2x2
    case grid2x3
    public var id: String { rawValue }
    public var paneCount: Int {
        switch self {
        case .single: return 1
        case .twoRows, .twoColumns: return 2
        case .grid2x2: return 4
        case .grid2x3: return 6
        }
    }
    public var displayName: String {
        switch self {
        case .single: return "Single"
        case .twoRows: return "Two rows"
        case .twoColumns: return "Two columns"
        case .grid2x2: return "2 × 2"
        case .grid2x3: return "2 × 3"
        }
    }
    public var systemImage: String {
        switch self {
        case .single: return "rectangle"
        case .twoRows: return "rectangle.split.1x2"
        case .twoColumns: return "rectangle.split.2x1"
        case .grid2x2: return "square.grid.2x2"
        case .grid2x3: return "square.grid.3x2"
        }
    }
}

public struct PlotPane: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var kind: PlotKind = .rectangular
    public var traceIDs: [UUID] = []
    public var title: String = ""
    /// Show the trace values at each marker beneath the plot.
    public var showsMarkerReadout: Bool = true

    public init(kind: PlotKind = .rectangular, traceIDs: [UUID] = [], title: String = "") {
        self.kind = kind
        self.traceIDs = traceIDs
        self.title = title
    }
}

public enum FrequencyAxisScale: String, Codable, CaseIterable, Sendable, Identifiable {
    case linear, logarithmic
    public var id: String { rawValue }
    public var displayName: String { self == .linear ? "Linear" : "Logarithmic" }
}

/// Everything about how the data is displayed, independent of the data itself.
public struct Workspace: Codable, Sendable {
    public var traces: [Trace] = []
    public var markers: [Marker] = []
    public var panes: [PlotPane] = []
    public var layout: ChartLayout = .grid2x2
    public var sweep = SweepConfiguration()
    public var timeDomain = TimeDomainSettings()
    public var limits: [LimitSet] = []
    public var averagingMode: SweepAccumulator.Mode = .off
    public var averagingDepth: Int = 8
    public var groupDelayAperture: Int = 1
    public var frequencyAxisScale: FrequencyAxisScale = .linear
    public var showGrid: Bool = true
    public var showMinorGrid: Bool = true
    public var z0: Double = 50
    public var applyHostCalibration: Bool = true

    public init() {}

    /// The default four-pane layout most people want on launch.
    public static func makeDefault() -> Workspace {
        var w = Workspace()

        var logMag = Trace(channel: .s11, format: .logMag, colorIndex: 0)
        logMag.referenceValue = 0
        var swr = Trace(channel: .s11, format: .swr, colorIndex: 1)
        swr.referenceValue = 1
        let smith = Trace(channel: .s11, format: .smith, colorIndex: 2)
        var thru = Trace(channel: .s21, format: .logMag, colorIndex: 3)
        thru.referenceValue = 0
        thru.scalePerDivision = 10
        thru.referencePosition = 9

        w.traces = [logMag, swr, smith, thru]
        w.panes = [
            PlotPane(kind: .rectangular, traceIDs: [logMag.id], title: "Reflection"),
            PlotPane(kind: .rectangular, traceIDs: [swr.id], title: "SWR"),
            PlotPane(kind: .smith, traceIDs: [smith.id], title: "Smith"),
            PlotPane(kind: .rectangular, traceIDs: [thru.id], title: "Transmission")
        ]
        w.markers = [Marker(number: 1), Marker(number: 2), Marker(number: 3), Marker(number: 4)]
        w.sweep = SweepConfiguration(start: 1e6, stop: 900e6, points: 201)
        return w
    }

    public func trace(id: UUID) -> Trace? { traces.first { $0.id == id } }

    public mutating func ensurePaneCount() {
        while panes.count < layout.paneCount {
            panes.append(PlotPane(kind: .rectangular, traceIDs: [], title: "Plot \(panes.count + 1)"))
        }
    }
}

/// The on-disk `.mightyvna` document.
public struct SessionDocument: Codable, Sendable {
    public static let currentVersion = 1
    public var version: Int = SessionDocument.currentVersion
    public var created: Date = Date()
    public var appVersion: String = "1.0"
    public var workspace: Workspace = .makeDefault()
    public var calibration: Calibration?
    public var liveFrame: SweepFrame?
    public var memories: [SweepFrame] = []
    public var notes: String = ""
    public var deviceDescription: String = ""

    public init() {}

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SessionDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionDocument.self, from: data)
    }
}
