import Foundation

public enum BaseDestinationCatalog {
    public static let home = "home"
    public static let settings = "settings"
    public static let modules = "modules"

    public static let all: [String] = [home, settings, modules]
}

public enum SlotCatalog {
    public static let homeBanner = "home.banner"
    public static let dashboardPrimary = "dashboard.primary"
    public static let overlayMain = "overlay.main"
    public static let moduleWorkspace = "module.workspace"

    public static let all: [String] = [homeBanner, dashboardPrimary, overlayMain, moduleWorkspace]
}
