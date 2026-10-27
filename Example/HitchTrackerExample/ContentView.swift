import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List(0..<1000, id: \.self) { index in
                Row(index: index)
            }
            .navigationTitle("Hitchy List")
        }
    }
}

private struct Row: View {
    let index: Int

    private var blockDuration: TimeInterval? {
        guard index > 0 else { return nil }
        if index % 50 == 0 { return 1.5 }
        if index % 10 == 0 { return 0.3 }
        if index % 5 == 0 { return 0.1 }
        return nil
    }

    var body: some View {
        HStack {
            Text("Row \(index)")
            Spacer()
            if let blockDuration {
                Text("blocks \(Int(blockDuration * 1000)) ms")
                    .font(.caption)
                    .foregroundStyle(blockDuration > 0.6 ? .red : blockDuration > 0.2 ? .orange : .yellow)
            }
        }
        .onAppear {
            if let blockDuration {
                Thread.sleep(forTimeInterval: blockDuration)
            }
        }
    }
}

#Preview {
    ContentView()
}
