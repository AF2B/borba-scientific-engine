// Each literal below is the value of the constant named by its case, so a separate name would only repeat it.
// swiftlint:disable no_magic_numbers

/// A physical constant with its unit and measurement uncertainty.
struct ConstantDefinition: Sendable, Equatable {
    /// The value in SI units.
    let value: Double

    /// The SI unit the value is expressed in.
    let unit: String

    /// The standard uncertainty in the same unit; zero for exact values.
    let uncertainty: Double

    /// Where the value comes from.
    let source: String
}

/// Fundamental physical constants, as recommended by CODATA 2022 (the values defining the SI are exact).
enum PhysicalConstant: String, CaseIterable, Sendable {
    case speedOfLight = "speed_of_light"
    case planckConstant = "planck_constant"
    case reducedPlanckConstant = "reduced_planck_constant"
    case elementaryCharge = "elementary_charge"
    case boltzmannConstant = "boltzmann_constant"
    case avogadroConstant = "avogadro_constant"
    case molarGasConstant = "molar_gas_constant"
    case gravitationalConstant = "gravitational_constant"
    case standardGravity = "standard_gravity"
    case electronMass = "electron_mass"
    case protonMass = "proton_mass"
    case vacuumPermittivity = "vacuum_permittivity"
    case stefanBoltzmannConstant = "stefan_boltzmann_constant"

    private static let exactSource = "SI definition (exact)"
    private static let derivedSource = "Derived from SI defining constants (exact)"
    private static let measuredSource = "CODATA 2022"

    /// The value, unit and uncertainty of the constant.
    var definition: ConstantDefinition {
        switch self {
        case .speedOfLight:
            Self.exact(299_792_458, unit: "m/s")
        case .planckConstant:
            Self.exact(6.626_070_15e-34, unit: "J s")
        case .reducedPlanckConstant:
            Self.derived(1.054_571_817_646_156e-34, unit: "J s")
        case .elementaryCharge:
            Self.exact(1.602_176_634e-19, unit: "C")
        case .boltzmannConstant:
            Self.exact(1.380_649e-23, unit: "J/K")
        case .avogadroConstant:
            Self.exact(6.022_140_76e23, unit: "1/mol")
        case .molarGasConstant:
            Self.derived(8.314_462_618_153_24, unit: "J/(mol K)")
        case .gravitationalConstant:
            Self.measured(6.674_30e-11, uncertainty: 1.5e-15, unit: "m^3/(kg s^2)")
        case .standardGravity:
            Self.exact(9.806_65, unit: "m/s^2")
        case .electronMass:
            Self.measured(9.109_383_713_9e-31, uncertainty: 2.8e-40, unit: "kg")
        case .protonMass:
            Self.measured(1.672_621_925_95e-27, uncertainty: 5.2e-37, unit: "kg")
        case .vacuumPermittivity:
            Self.measured(8.854_187_818_8e-12, uncertainty: 1.4e-21, unit: "F/m")
        case .stefanBoltzmannConstant:
            Self.derived(5.670_374_419_184_43e-8, unit: "W/(m^2 K^4)")
        }
    }

    private static func exact(
        _ value: Double,
        unit: String
    ) -> ConstantDefinition {
        ConstantDefinition(value: value, unit: unit, uncertainty: 0, source: exactSource)
    }

    private static func derived(
        _ value: Double,
        unit: String
    ) -> ConstantDefinition {
        ConstantDefinition(value: value, unit: unit, uncertainty: 0, source: derivedSource)
    }

    private static func measured(
        _ value: Double,
        uncertainty: Double,
        unit: String
    ) -> ConstantDefinition {
        ConstantDefinition(value: value, unit: unit, uncertainty: uncertainty, source: measuredSource)
    }
}

// swiftlint:enable no_magic_numbers
