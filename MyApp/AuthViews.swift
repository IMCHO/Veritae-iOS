import SwiftUI

// MARK: - SC1 · 로그인

struct LoginFlowView: View {
    var body: some View {
        NavigationStack {
            LoginView()
        }
    }
}

struct LoginView: View {
    @Environment(AppState.self) private var appState

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && !isLoading
    }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    LogoMark(size: 76)

                    Text("Veritae")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                }

                VStack(spacing: 12) {
                    AuthField(icon: "envelope", placeholder: "이메일", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)

                    AuthField(icon: "lock", placeholder: "비밀번호", text: $password, isSecure: true)
                        .textContentType(.password)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.top, 48)

                Button {
                    signIn()
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("로그인")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                }
                .buttonStyle(.glassProminent)
                .disabled(!canSubmit)
                .padding(.top, 24)

                Spacer()

                NavigationLink("회원가입") {
                    SignUpView(prefilledEmail: $email)
                }
                .font(.subheadline)
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 28)
        }
    }

    private func signIn() {
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await appState.signIn(email: email, password: password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - 회원가입

struct SignUpView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @Binding var prefilledEmail: String

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSuccess = false

    private var localValidationMessage: String? {
        if password.isEmpty || confirmPassword.isEmpty { return nil }
        if password.count < 8 { return "비밀번호는 8자 이상이어야 합니다." }
        if password != confirmPassword { return "비밀번호가 일치하지 않습니다." }
        return nil
    }

    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && password == confirmPassword
            && password.count >= 8 && !isLoading
    }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    AuthField(icon: "envelope", placeholder: "이메일", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)

                    AuthField(icon: "lock", placeholder: "비밀번호 (8자 이상)", text: $password, isSecure: true)
                        .textContentType(.newPassword)

                    AuthField(icon: "lock.rotation", placeholder: "비밀번호 확인", text: $confirmPassword, isSecure: true)
                        .textContentType(.newPassword)

                    if let message = localValidationMessage ?? errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.top, 24)

                Button {
                    signUp()
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("가입하기")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                }
                .buttonStyle(.glassProminent)
                .disabled(!canSubmit)
                .padding(.top, 24)

                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .navigationTitle("회원가입")
        .navigationBarTitleDisplayMode(.large)
        .alert("가입 완료", isPresented: $showSuccess) {
            Button("확인") {
                prefilledEmail = email
                dismiss()
            }
        } message: {
            Text("계정이 생성되었습니다. 로그인해 주세요.")
        }
    }

    private func signUp() {
        errorMessage = nil
        isLoading = true
        Task {
            do {
                // 서버에서 이메일 유일성과 비밀번호 안전성을 확인한다 (Mock)
                try await appState.signUp(email: email, password: password)
                showSuccess = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - 공용 입력 필드

struct AuthField: View {
    var icon: String
    var placeholder: String
    @Binding var text: String
    var isSecure = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }
}

#Preview {
    LoginFlowView()
        .environment(AppState())
}
