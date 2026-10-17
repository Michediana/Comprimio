//
//  BackgroundRun.swift
//  Comprimio iOS
//
//  Tiene in vita un batch quando l'utente lascia l'app. Su iOS 26 il batch
//  diventa un `BGContinuedProcessingTask`: il sistema lo mostra con il suo
//  avanzamento (nell'isola dinamica, nella schermata bloccata) e lo lascia
//  finire, a meno che l'utente non lo fermi da lì. Prima di iOS 26, e se il
//  sistema non lo accetta, resta `beginBackgroundTask`: una trentina di
//  secondi, poi l'app viene sospesa e il batch riprende quando si torna.
//

import BackgroundTasks
import UIKit

@MainActor
final class BackgroundRun {

    /// Prefisso degli identificatori, dichiarato con il carattere jolly in
    /// `BGTaskSchedulerPermittedIdentifiers` (Info.plist). Ogni batch ha il
    /// suo: un identificatore si può registrare una volta sola.
    private static let prefix = (Bundle.main.bundleIdentifier ?? "com.michediana.Comprimio") + ".convert."

    /// Unità di avanzamento per file: abbastanza fini da far vedere al
    /// sistema che il batch procede anche dentro una conversione lunga.
    static let unitsPerFile: Int64 = 100

    private let totalFiles: Int
    private var legacyTask: UIBackgroundTaskIdentifier = .invalid
    /// Il `BGContinuedProcessingTask` del batch, quando il sistema l'ha
    /// avviato. `AnyObject` perché il tipo esiste solo da iOS 26.
    private var continuedTask: AnyObject?
    private var completedUnits: Int64 = 0
    private var completedFiles = 0
    /// Il batch è finito prima che il sistema avviasse il task.
    private var finished = false
    private var ended = false

    /// Avvia la protezione per un batch di `totalFiles` file. `onStop` è
    /// chiamato quando l'utente ferma il batch dall'interfaccia del sistema,
    /// o quando il sistema non può più lasciarlo continuare.
    init(totalFiles: Int, onStop: @escaping @MainActor () -> Void) {
        self.totalFiles = totalFiles
        if #available(iOS 26.0, *), submitContinuedTask(onStop: onStop) { return }
        beginLegacyTask()
    }

    /// File conclusi e frazione dei file in corso, in unità (`unitsPerFile`
    /// per file). L'avanzamento non torna mai indietro.
    func update(completedFiles: Int, units: Int64) {
        self.completedFiles = completedFiles
        completedUnits = max(completedUnits, units)
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            report(to: task)
        }
    }

    /// Fine del batch, completato, annullato o fermato.
    func end(success: Bool) {
        guard !ended else { return }
        ended = true
        finished = true
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            report(to: task)
            task.setTaskCompleted(success: success)
            continuedTask = nil
        }
        endLegacyTask()
    }

    // MARK: - iOS 26

    @available(iOS 26.0, *)
    private func submitContinuedTask(onStop: @escaping @MainActor () -> Void) -> Bool {
        let identifier = Self.prefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { return }
                guard let self, !self.finished else {
                    // Il batch è finito (o non c'è più) prima dell'avvio.
                    task.setTaskCompleted(success: true)
                    return
                }
                self.continuedTask = task
                task.expirationHandler = { [weak self] in
                    // Chiamato fuori dal main thread: l'utente ha toccato
                    // Interrompi, o il sistema ha bisogno delle risorse.
                    Task { @MainActor in
                        guard let self, !self.ended else { return }
                        onStop()
                        self.end(success: false)
                    }
                }
                self.report(to: task)
            }
        }
        guard registered else { return false }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: String(localized: "Converting images"),
            subtitle: subtitle
        )
        // Se il sistema non può avviarlo subito, meglio il ripiego che un
        // batch messo in coda per dopo: l'utente l'ha chiesto adesso.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    @available(iOS 26.0, *)
    private func report(to task: BGContinuedProcessingTask) {
        task.progress.totalUnitCount = Int64(totalFiles) * Self.unitsPerFile
        task.progress.completedUnitCount = completedUnits
        task.updateTitle(String(localized: "Converting images"), subtitle: subtitle)
    }

    private var subtitle: String {
        String(localized: "\(completedFiles) of \(totalFiles)")
    }

    // MARK: - Prima di iOS 26

    private func beginLegacyTask() {
        legacyTask = UIApplication.shared.beginBackgroundTask(withName: "Comprimio batch") { [weak self] in
            // Tempo scaduto: il batch non si annulla. L'app viene sospesa a
            // metà conversione e riprende quando l'utente torna.
            MainActor.assumeIsolated { self?.endLegacyTask() }
        }
    }

    private func endLegacyTask() {
        guard legacyTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(legacyTask)
        legacyTask = .invalid
    }
}
