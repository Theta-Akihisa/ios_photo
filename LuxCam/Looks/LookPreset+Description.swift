//  LookPreset+Description.swift

import Foundation

extension LookPreset {
    /// Short Japanese description for the UI.
    var shortDescription: String {
        switch self {
        case .native: return "iOS標準：加工なしの自然な仕上がり"
        case .leicaClassic: return "ライカ・クラシック風：深いコントラストと温かい肌色"
        case .leicaContemporary: return "ライカ・コンテンポラリー風：鮮やかで切れのある描写"
        case .leicaMonochrome: return "ライカ・モノクローム風：締まった黒と高コントラスト"
        case .hasselbladNatural: return "ハッセルブラッド・ナチュラル風：忠実で滑らかな階調"
        case .hasselbladPortrait: return "ハッセルブラッド・ポートレート風：柔らかく心地よい肌色"
        case .sigmaTealOrange: return "シグマ・ティール&オレンジ風：肌はオレンジ、影と青はティール"
        case .sigmaWarmGold: return "シグマ・ウォームゴールド風：黄金色の温かみと褪せた黒"
        case .sigmaPowderBlue: return "シグマ・パウダーブルー風：淡く涼しいパステル調"
        case .sigmaMonochrome: return "シグマ・モノクローム風：やわらかく軽やかな白黒"
        }
    }
}
