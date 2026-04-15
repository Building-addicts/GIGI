import Foundation
import AVFoundation
 
class GigiAudioSequestrator: NSObject {
    static let shared = GigiAudioSequestrator()
    
    private let audioSession = AVAudioSession.sharedInstance()
    
    func seizeControl() {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            print("GIGI: Microfono sequestrato. Ducking attivo.")
        } catch {
            print("GIGI: Errore nel dirottamento audio: \(error.localizedDescription)")
        }
    }
    
    func releaseControl() {
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            print("GIGI: Controllo audio rilasciato.")
        } catch {
            print("GIGI: Impossibile rilasciare la sessione: \(error.localizedDescription)")
        }
    }
}
