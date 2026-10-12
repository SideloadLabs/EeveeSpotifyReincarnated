import Foundation

// spoti.pw (its dylib is spotifyglass) hooks the same lyrics page and lyrics card as Eevee's glass
// lyrics. When both are injected, Eevee leaves those hooks off so spoti.pw's page is the only one
// that paints the page.
let eeveeSpotiPwInjected: Bool = {
    for index in 0..<_dyld_image_count() {
        guard let path = _dyld_get_image_name(index) else { continue }
        if String(cString: path).lowercased().contains("spotifyglass") { return true }
    }
    return false
}()
