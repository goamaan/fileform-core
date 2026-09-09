// SPDX-License-Identifier: Apache-2.0
import Foundation
import PDFKit
import CoreGraphics
import AppKit
// Adapt the labeled generated PDF to exercise nonzero crop origins and rotation.
guard CommandLine.arguments.count == 3,
      let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])), document.pageCount == 2 else { fatalError("Expected generated two-page PDF") }
for index in 0..<document.pageCount {
    let page = document.page(at: index)!
    let box = page.bounds(for: .mediaBox)
    page.setBounds(CGRect(x: box.minX + 20, y: box.minY + 30, width: box.width - 40, height: box.height - 60), for: .cropBox)
}
document.page(at: 1)!.rotation = 90
let first = document.page(at: 0)!
let crop = first.bounds(for: .cropBox)
let note = PDFAnnotation(bounds: CGRect(x: crop.minX + 24, y: crop.minY + 24, width: 200, height: 30), forType: .freeText, withProperties: nil)
note.contents = "Visible page annotation"
note.font = .systemFont(ofSize: 14)
note.fontColor = .systemRed
note.color = .clear
first.addAnnotation(note)
guard document.write(to: URL(fileURLWithPath: CommandLine.arguments[2])) else { fatalError("Could not write page fixture") }
