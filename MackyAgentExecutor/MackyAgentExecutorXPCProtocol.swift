import Foundation

/// Only Foundation data crosses the process boundary. The app and service decode
/// their own private wire models instead of sharing runtime model classes.
@objc protocol MackyAgentExecutorXPCProtocol {
    func executeRequest(_ requestData: NSData, withReply reply: @escaping (NSData) -> Void)
    func cancelRequest(_ requestIdentifier: NSString)
}
