import SwiftUI

extension SensorRow {
    /// The icon of fans, here and on the sensors list's Fans row.
    static let fanSymbol = "fan.fill"
    static let fanTint = badgeColor(.cyan, darkenedBy: 0.1)

    /// What it is at a glance: there are a lot of them, and names like "CPU Performance Core 5" look alike. Cores share
    /// a color, and their symbol says which kind they are.
    var symbol: String {
        switch kind {
        case .fan:
            return Self.fanSymbol
        case .temperature(let sensor):
            switch sensor.group {
            case .cpu:
                switch sensor.core {
                case .superCore: return "star.fill"
                case .efficiency: return "leaf.fill"
                case .performance: return "bolt.fill"
                case nil: return "cpu.fill"
                }
            // SF Symbols has nothing for a GPU, and a display would say it's the screen's temperature. It draws in 3D.
            case .gpu: return "cube.fill"
            case .memory: return "memorychip.fill"
            case .storage: return "internaldrive.fill"
            case .battery: return "minus.plus.batteryblock.fill"
            case .wireless: return "wifi"
            case .airflow: return "wind"
            // The raised hand is the Permissions pane's icon, and reads as "stop".
            case .palmRest: return "hand.palm.facing.fill"
            }
        }
    }

    /// One color per group. They're for a white symbol to sit on, so the lightest are darkened. None is red: in a list of
    /// temperatures it would read as a warning, which is what the rows' bars are for.
    var tint: Color {
        switch kind {
        case .fan:
            return Self.fanTint
        case .temperature(let sensor):
            switch sensor.group {
            case .cpu: return .blue
            case .gpu: return .purple
            case .memory: return .brown
            case .storage: return Self.badgeColor(.gray, darkenedBy: 0.1)
            case .battery: return Self.badgeColor(.green, darkenedBy: 0.2)
            case .wireless: return .indigo
            case .airflow: return Self.badgeColor(.mint, darkenedBy: 0.25)
            case .palmRest: return Self.badgeColor(.orange, darkenedBy: 0.15)
            }
        }
    }

    private static func badgeColor(_ color: Color, darkenedBy amount: Double) -> Color {
        color.mix(with: .black, by: amount)
    }
}
