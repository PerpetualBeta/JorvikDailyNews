import Foundation

// The whole executable: stand up the listener and wait. Everything else lives
// in PDFRenderService.swift so it can be exercised by a harness without a
// second `main` symbol in the link.
let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
