import Intents

class IntentHandler: INExtension {

    override func handler(for intent: INIntent) -> Any {
        switch intent {
        case is INStartCallIntent:
            return CallIntentHandler()
        case is INSendMessageIntent:
            return MessageIntentHandler()
        case is INAddTasksIntent:
            return TaskIntentHandler()
        default:
            return self
        }
    }
}

class CallIntentHandler: NSObject, INStartCallIntentHandling {
    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        let response = INStartCallIntentResponse(code: .continueInApp, userActivity: nil)
        completion(response)
    }
}

class MessageIntentHandler: NSObject, INSendMessageIntentHandling {
    func handle(intent: INSendMessageIntent, completion: @escaping (INSendMessageIntentResponse) -> Void) {
        let response = INSendMessageIntentResponse(code: .success, userActivity: nil)
        completion(response)
    }
}

class TaskIntentHandler: NSObject, INAddTasksIntentHandling {
    func handle(intent: INAddTasksIntent, completion: @escaping (INAddTasksIntentResponse) -> Void) {
        let response = INAddTasksIntentResponse(code: .success, userActivity: nil)
        completion(response)
    }
}
