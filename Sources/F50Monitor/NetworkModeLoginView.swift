import SwiftUI
import F50Core

struct NetworkModeLoginView: View {
    @ObservedObject var fetcher: F50Fetcher
    let mode: F50NetworkMode
    var onClose: () -> Void

    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("切换为\(mode.title)")
                .font(.system(size: 17, weight: .semibold))

            SecureField("路由器管理密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($isPasswordFocused)
                .disabled(isSubmitting)
                .onSubmit { submit() }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(F50Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("取消", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button("登录并切换", action: submit)
                    .buttonStyle(.borderedProminent)
                    .tint(F50Theme.blue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 320)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            fetcher.loadSavedPasswordIfNeeded()
            password = fetcher.password
            isPasswordFocused = true
        }
    }

    private func submit() {
        guard !password.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await fetcher.authenticateForNetworkMode(password: password)
                try await fetcher.setNetworkMode(mode)
                onClose()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
