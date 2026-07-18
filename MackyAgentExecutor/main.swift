import Foundation

private final class AgentJavaScriptExecutorServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let exportedService = AgentJavaScriptExecutorService()
        newConnection.exportedInterface = NSXPCInterface(
            with: (any MackyAgentExecutorXPCProtocol).self
        )
        newConnection.exportedObject = exportedService
        newConnection.invalidationHandler = {
            exportedService.cancelActiveExecution()
        }
        newConnection.interruptionHandler = {
            exportedService.cancelActiveExecution()
        }
        newConnection.resume()
        return true
    }
}

private let serviceDelegate = AgentJavaScriptExecutorServiceDelegate()
private let serviceListener = NSXPCListener.service()
serviceListener.delegate = serviceDelegate
serviceListener.resume()
