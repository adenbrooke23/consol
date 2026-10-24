import CoreText
import Foundation

// Registers the bundled Fonts/ at launch via CoreText, so no UIAppFonts entry
// in Info.plist is required (keeps the generated-plist project clean). Called
// once from ConsoleApp.init. Safe to call more than once; already-registered
// errors are ignored.

enum FontRegistrar {
    static func register() {
        for ext in ["otf", "ttf"] {
            // Cover both a flattened bundle and a preserved Fonts/ subdirectory.
            let urls = (Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [])
                + (Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") ?? [])
            for url in Set(urls) {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}
