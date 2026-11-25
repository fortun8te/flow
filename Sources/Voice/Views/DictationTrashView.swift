import SwiftUI

struct DictationTrashView: View {
    var onRestore: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items = RecentDictations.trash()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Recently deleted").font(.title2); Spacer(); Button("Done") { dismiss() } }
            Text("Deleted dictations stay here for seven days.").foregroundStyle(.secondary)
            if items.isEmpty { Text("No deleted dictations.").foregroundStyle(.secondary) }
            List(items) { item in
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text(item.text).textSelection(.enabled)
                        if let date = item.deletedAt { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Restore") {
                        RecentDictations.restore(id: item.id)
                        items = RecentDictations.trash()
                        onRestore()
                    }
                }.padding(.vertical, 6)
            }
        }.padding(24).frame(width: 600, height: 420)
    }
}
