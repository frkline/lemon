import Foundation

@Observable
@MainActor
final class AppNavigation {
    var selectedSession: Session?
    var showingSettings = false

    func showDetail(_ session: Session) { selectedSession = session; showingSettings = false }
    func showSettings()                 { showingSettings = true;    selectedSession = nil  }
    func showList()                     { selectedSession = nil;     showingSettings = false }
}
