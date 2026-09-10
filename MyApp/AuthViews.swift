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
    @State private var signInTask: Task<Void, Never>?

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

                    // 로그인 화면에는 비밀번호 선검증을 적용하지 않는다 — 기존 계정의 비밀번호가
                    // 현재 규칙보다 약할 수 있고, 실패는 항상 INVALID_CREDENTIALS로 구분 없이 처리한다(ADR-0004).
                    AuthField(icon: "lock", placeholder: "비밀번호", text: $password, isSecure: true)
                        .textContentType(.password)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .accessibilityLabel("로그인 오류: \(errorMessage)")
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
        .onDisappear {
            // 화면을 떠나면 진행 중인 로그인 요청은 취소한다 (PRD E13).
            signInTask?.cancel()
        }
    }

    private func signIn() {
        errorMessage = nil
        isLoading = true
        signInTask = Task {
            // C2: 정리는 `defer`로 — 취소를 포함한 **모든** 경로에서 실행된다.
            // `catch is CancellationError { return }`은 정리 코드를 건너뛰어 화면을 떠났다가
            // 돌아오면(예: "회원가입" NavigationLink) `isLoading == true`가 영구히 남아
            // submit 버튼이 비활성인 채로 고착된다(LL-001).
            defer { isLoading = false }
            do {
                try await appState.authStore.signIn(email: email, password: password)
                appState.phase = .main
            } catch {
                // 취소는 던져진 오류 타입이 아니라 `Task.isCancelled`로 판정한다 — 실서버 경로에서
                // 취소는 `CancellationError`가 아니라 `URLError(.cancelled)`로 오기 때문에
                // 오류 타입만으로 취소를 가리는 분기는 목에서만 통하는 죽은 코드가 된다(LL-001).
                guard !Task.isCancelled else { return }
                errorMessage = (error as? AuthError)?.localizedDescription
                    ?? "일시적인 오류가 발생했습니다. 잠시 후 다시 시도해 주세요."
            }
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
    @State private var nickname = ""
    @State private var isLoading = false
    @State private var fieldErrors: [String: String] = [:]
    @State private var globalErrorMessage: String?
    @State private var showSuccess = false
    @State private var signUpTask: Task<Void, Never>?

    /// 이 화면이 필드별로 매핑하는 필드명 — 그 외 `violations[].field`는 전역 오류로 합쳐 표시한다(E3).
    private static let mappedFields: Set<String> = ["email", "password", "nickname"]

    private var confirmMismatchMessage: String? {
        guard !password.isEmpty, !confirmPassword.isEmpty else { return nil }
        return password == confirmPassword ? nil : "비밀번호가 일치하지 않습니다."
    }

    private var passwordHint: String? {
        // 서버 violations가 있으면 항상 서버 문구 우선(ADR-0004).
        if let serverMessage = fieldErrors["password"] { return serverMessage }
        guard !password.isEmpty else { return nil }
        return PasswordRule.submitBlockingHint(for: password)
    }

    private var emailFieldError: String? { fieldErrors["email"] }
    private var nicknameFieldError: String? { fieldErrors["nickname"] }

    private var canSubmit: Bool {
        !email.isEmpty
            && PasswordRule.isValidForSubmit(password)
            && password == confirmPassword
            && !nickname.isEmpty
            && !isLoading
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 12) {
                        AuthFieldRow(fieldName: "이메일", errorText: emailFieldError) {
                            AuthField(icon: "envelope", placeholder: "이메일", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                        }

                        AuthFieldRow(fieldName: "비밀번호", errorText: passwordHint) {
                            AuthField(
                                icon: "lock",
                                placeholder: "비밀번호 (8~20자, 영문+숫자)",
                                text: $password,
                                isSecure: true
                            )
                            .textContentType(.newPassword)
                        }

                        AuthFieldRow(fieldName: "비밀번호 확인", errorText: confirmMismatchMessage) {
                            AuthField(icon: "lock.rotation", placeholder: "비밀번호 확인", text: $confirmPassword, isSecure: true)
                                .textContentType(.newPassword)
                        }

                        // PRD SC2: textContentType(.nickname)/textInputAutocapitalization(.never)를
                        // 이 호출부에서 추가로 적용하지 않는다 — 한글 닉네임 입력을 방해하지 않기 위함.
                        AuthFieldRow(fieldName: "닉네임", errorText: nicknameFieldError) {
                            AuthField(icon: "person", placeholder: "닉네임", text: $nickname)
                        }

                        if let globalErrorMessage {
                            Text(globalErrorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .accessibilityLabel("가입 오류: \(globalErrorMessage)")
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
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
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
        .onDisappear {
            signUpTask?.cancel()
        }
        // Minor 4: 서버 필드 오류는 사용자가 해당 필드를 다시 편집하기 시작하면 지운다 —
        // 그러지 않으면 수정 후에도 오래된 서버 오류 캡션이 남아 있는다.
        .onChange(of: email) { _, _ in fieldErrors["email"] = nil }
        .onChange(of: password) { _, _ in fieldErrors["password"] = nil }
        .onChange(of: nickname) { _, _ in fieldErrors["nickname"] = nil }
    }

    private func signUp() {
        fieldErrors = [:]
        globalErrorMessage = nil
        isLoading = true
        signUpTask = Task {
            // C2: LoginView.signIn()과 동일한 이유로 `defer` + `Task.isCancelled` 패턴을 쓴다(LL-001).
            defer { isLoading = false }
            do {
                _ = try await appState.authStore.signUp(email: email, password: password, nickname: nickname)
                showSuccess = true
            } catch {
                guard !Task.isCancelled else { return }
                if let authError = error as? AuthError {
                    apply(authError)
                } else {
                    globalErrorMessage = "일시적인 오류가 발생했습니다. 잠시 후 다시 시도해 주세요."
                }
            }
        }
    }

    private func apply(_ error: AuthError) {
        switch error {
        case .validationFailed(let violations, let detail):
            var mapped: [String: String] = [:]
            var unmapped: [String] = []
            for violation in violations {
                if Self.mappedFields.contains(violation.field) {
                    // 같은 필드에 서버가 메시지를 두 번 이상 실으면 마지막 값이 남는다 — 명세에 없는 케이스.
                    mapped[violation.field] = violation.message
                } else {
                    unmapped.append(violation.message)
                }
            }
            fieldErrors = mapped
            if !unmapped.isEmpty {
                globalErrorMessage = unmapped.joined(separator: "\n")
            } else if mapped.isEmpty {
                // M3: violations가 비어 있거나 아예 없는 400 VALIDATION_FAILED — 필드/전역 어디에도
                // 아무것도 안 뜨면 완전 무음 실패가 된다. 서버 `detail` 우선, 없으면 일반 문구.
                globalErrorMessage = detail ?? error.localizedDescription
            } else {
                globalErrorMessage = nil
            }
        case .emailAlreadyExists:
            fieldErrors = ["email": error.localizedDescription]
        default:
            globalErrorMessage = error.localizedDescription
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

/// `AuthField` 아래 필드별 오류 캡션 슬롯. `AuthField` 자체는 건드리지 않는다 —
/// 로그인 화면과 공유되는 타입이라 시그니처 변경의 파급을 피한다(PRD SC2 구현 제안).
struct AuthFieldRow<Content: View>: View {
    var fieldName: String
    var errorText: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
                // 필드에 포커스했을 때 그 필드의 오류를 함께 듣게 한다(원래 목표).
                // 주의: 여기서 `.accessibilityElement(children: .combine)`를 쓰면 안 된다 —
                // 자식들을 하나의 엘리먼트로 합쳐 버려서 안에 있는 TextField/SecureField가
                // 개별 컨트롤로서 사라지고 **입력이 불가능해진다.** 실제로 그 버그가 났었다.
                // 컨테이너를 건드리지 않고 필드 자신에게 힌트만 붙이는 방식으로 목표를 달성한다.
                .accessibilityHint(errorText.map { "\(fieldName) 오류: \($0)" } ?? "")
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
    }
}

#if DEBUG
// M8: `#if DEBUG`로 감싸는 이유 — `#Preview` 본문은 Release 빌드에서도 타입체크되는데
// `MockAuthAPI`/`InMemoryTokenStore`는 의도적으로 DEBUG 전용이다(실측: 없이 했다가
// Release 빌드가 "cannot find 'MockAuthAPI' in scope"로 실패했다).
#Preview {
    LoginFlowView()
        .environment(AppState(authStore: AuthStore(api: MockAuthAPI(), tokenStore: InMemoryTokenStore()), analysisAPI: MockAnalysisAPI()))
}
#endif
