import XCTest
@testable import NXCore

final class SpanishLocalizationTests: XCTestCase {
    func testSpanishCatalogIsComplete() throws {
        let spanish = try XCTUnwrap(L10n.catalogs["es"])
        XCTAssertEqual(Set(spanish.keys), Set(L10n.table.keys), "Spanish must not silently fall back to English")
    }

    func testSpanishLocalesAndVisibleTexts() {
        let languages = LocalizationFiles.languages()
        for locale in ["es", "es-CL", "es-ES", "es-MX", "es-419", "ES-cl", "spanish_chile"] {
            XCTAssertEqual(Lang.detect(preferred: [locale], among: languages), Lang("es"), locale)
        }
        XCTAssertEqual(Lang("es").name, "Español")
        XCTAssertEqual(L10n.string("build.heading", Lang("es")), "Compilar juego")
        XCTAssertEqual(L10n.string("settings.language", Lang("es")), "Idioma")
        XCTAssertEqual(String(format: L10n.string("onboarding.stepCount", Lang("es")), 2, 6), "Paso 2 de 6")
    }
}
