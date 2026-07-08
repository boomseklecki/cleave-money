import SwiftUI
import PhotosUI
import UIKit

/// The receipt-scan entry flow as a reusable modifier: a `DocumentScannerView` sheet + a `PhotosPicker`
/// `onChange` (both run `ReceiptScanModel.process`) + the prefilled-editor sheet. The two menu affordances
/// (Scan / Receipt from Photo) stay inline in each host's menu (placement varies) and drive `showingScanner` /
/// `photo`; this owns the bulky sheets/handlers. `editor` builds the host's own prefilled editor
/// (ManualTransactionView vs ExpenseEditView) so one flow serves both targets.
struct ReceiptScanEntry<Editor: View>: ViewModifier {
    let scan: ReceiptScanModel
    let categories: [String]
    @Binding var showingScanner: Bool
    @Binding var photo: PhotosPickerItem?
    @ViewBuilder let editor: (ExpensePrefill, Data?) -> Editor

    private var presentEditor: Binding<Bool> {
        Binding(get: { scan.presentEditor }, set: { scan.presentEditor = $0 })
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingScanner) {
                DocumentScannerView(
                    onComplete: { images in
                        showingScanner = false
                        if let first = images.first {
                            Task { await scan.process(image: first, categories: categories) }
                        }
                    },
                    onCancel: { showingScanner = false }
                )
                .ignoresSafeArea()
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    defer { photo = nil }
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    await scan.process(image: image, categories: categories)
                }
            }
            .sheet(isPresented: presentEditor) {
                if let prefill = scan.prefill { editor(prefill, scan.imageData) }
            }
    }
}

extension View {
    /// Attach the receipt-scan flow. The host declares `scan`/`showingScanner`/`photo` and the two menu buttons;
    /// `editor` opens its own prefilled editor from the extracted `(ExpensePrefill, Data?)`.
    func receiptScanEntry<Editor: View>(
        scan: ReceiptScanModel, categories: [String],
        showingScanner: Binding<Bool>, photo: Binding<PhotosPickerItem?>,
        @ViewBuilder editor: @escaping (ExpensePrefill, Data?) -> Editor
    ) -> some View {
        modifier(ReceiptScanEntry(scan: scan, categories: categories,
                                  showingScanner: showingScanner, photo: photo, editor: editor))
    }
}
