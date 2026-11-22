/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.ios

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import me.him188.ani.app.domain.session.auth.OAuthPlatform
import me.him188.ani.app.navigation.BrowserNavigator
import me.him188.ani.app.platform.IosContext
import me.him188.ani.app.ui.login.EmailLoginUiState
import me.him188.ani.app.ui.login.EmailLoginViewModel
import me.him188.ani.app.ui.oauth.AuthState
import me.him188.ani.app.ui.oauth.OAuthAuthorizeViewModel
import me.him188.ani.app.ui.qrlogin.QrLoginConfirmUiState
import me.him188.ani.app.ui.qrlogin.QrLoginConfirmViewModel
import me.him188.ani.app.ui.settings.account.ProfileViewModel

enum class IosEmailStage { ADDRESS, CODE, COMPLETE }

class IosOAuthProvider internal constructor(val id: String, val name: String)

class IosEmailSignInState internal constructor(
    val stage: IosEmailStage,
    val email: String,
    val isBusy: Boolean,
    val failed: Boolean,
    val canBindEmail: Boolean,
    val providers: List<IosOAuthProvider>,
    val resendAtMillis: Long,
)

class IosNativeEmailSignIn internal constructor() {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { EmailLoginViewModel() }
    private val stage = MutableStateFlow(IosEmailStage.ADDRESS)
    private val busy = MutableStateFlow(false)
    private val failed = MutableStateFlow(false)
    private var verificationMode = EmailLoginUiState.Mode.LOGIN

    private val state = combine(viewModel.state, stage, busy, failed) { emailState, step, working, error ->
        IosEmailSignInState(
            step,
            emailState.email,
            working,
            error,
            emailState.mode != EmailLoginUiState.Mode.LOGIN,
            emailState.thirdPartyPlatforms.map { IosOAuthProvider(it.id, it.displayName) },
            emailState.nextResendTime.toEpochMilliseconds(),
        )
    }

    fun observe(onValue: (IosEmailSignInState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)

    fun sendCode(email: String) {
        val address = email.trim()
        if (address.isEmpty() || !address.contains('@') || !address.contains('.')) return
        runAction {
            if (stage.value == IosEmailStage.ADDRESS) verificationMode = viewModel.state.value.mode
            viewModel.setEmail(address)
            viewModel.sendEmailOtp()
            stage.value = IosEmailStage.CODE
        }
    }

    fun submitCode(code: String) {
        if (stage.value != IosEmailStage.CODE || code.length != 6 || !code.all { it in '0'..'9' }) return
        runAction {
            when (verificationMode) {
                EmailLoginUiState.Mode.LOGIN -> viewModel.submitEmailOtp(code)
                EmailLoginUiState.Mode.BIND, EmailLoginUiState.Mode.REBIND -> viewModel.bindOrRebind(code)
            }
            stage.value = IosEmailStage.COMPLETE
        }
    }

    fun editEmail() {
        if (!busy.value) {
            failed.value = false
            stage.value = IosEmailStage.ADDRESS
        }
    }

    private fun runAction(block: suspend () -> Unit) {
        if (busy.value) return
        busy.value = true
        failed.value = false
        screen.coroutineScope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                failed.value = true
            } finally {
                busy.value = false
            }
        }
    }

    fun close() = screen.close()
}

class IosNativeOAuth internal constructor(
    provider: OAuthPlatform,
    private val browser: BrowserNavigator,
    private val context: IosContext,
) {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { OAuthAuthorizeViewModel(provider) }
    private var attempt: Job? = null

    private val state = viewModel.state.map { auth ->
        when (auth) {
            AuthState.AwaitingResult -> IosLoadStatus.LOADING
            AuthState.Success -> IosLoadStatus.READY
            is AuthState.Failed -> IosLoadStatus.FAILED
            is AuthState.LoggedInAni, AuthState.NoAniAccount -> IosLoadStatus.IDLE
        }
    }

    fun observe(onValue: (IosLoadStatus) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)

    fun authorize() {
        if (attempt?.isActive == true) return
        attempt = screen.coroutineScope.launch {
            val current = viewModel.state.first()
            val register = current is AuthState.NoAniAccount || (current is AuthState.Failed && !current.loggedIn)
            viewModel.doOAuth(register) { url -> browser.openBrowser(context, url) }
        }
    }

    fun cancel() {
        viewModel.cancelCurrentOAuth()
        attempt?.cancel()
    }

    fun close() {
        cancel()
        screen.close()
    }
}

class IosAccountState internal constructor(
    val isSignedIn: Boolean,
    val nickname: String?,
    val email: String?,
    val bangumiUsername: String?,
)

class IosNativeAccount internal constructor() {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { ProfileViewModel() }
    private val state = viewModel.stateFlow.map { value ->
        IosAccountState(
            value.selfInfo.isSessionValid == true,
            value.selfInfo.selfInfo?.nickname,
            value.selfInfo.selfInfo?.email,
            value.selfInfo.selfInfo?.bangumiUsername,
        )
    }

    fun observe(onValue: (IosAccountState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun signOut() {
        screen.coroutineScope.launch { viewModel.logout() }
    }
    fun close() = screen.close()
}

enum class IosQrLoginStage { LOADING, REQUIRES_LOGIN, CONFIRM, APPROVED, REJECTED, EXPIRED, HANDLED, FAILED }

class IosQrLoginState internal constructor(
    val stage: IosQrLoginStage,
    val deviceName: String? = null,
    val busy: Boolean = false,
    val failed: Boolean = false,
)

class IosNativeQrLogin internal constructor(requestId: String) {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { QrLoginConfirmViewModel.create(requestId) }

    private val state = viewModel.state.map { value ->
        when (value) {
            QrLoginConfirmUiState.Loading -> IosQrLoginState(IosQrLoginStage.LOADING)
            QrLoginConfirmUiState.RequiresLogin -> IosQrLoginState(IosQrLoginStage.REQUIRES_LOGIN)
            is QrLoginConfirmUiState.Confirming ->
                IosQrLoginState(IosQrLoginStage.CONFIRM, value.deviceName, value.submitting, value.error != null)
            is QrLoginConfirmUiState.Approved -> IosQrLoginState(IosQrLoginStage.APPROVED, value.deviceName)
            QrLoginConfirmUiState.Rejected -> IosQrLoginState(IosQrLoginStage.REJECTED)
            QrLoginConfirmUiState.Expired -> IosQrLoginState(IosQrLoginStage.EXPIRED)
            QrLoginConfirmUiState.AlreadyHandled -> IosQrLoginState(IosQrLoginStage.HANDLED)
            is QrLoginConfirmUiState.Failed -> IosQrLoginState(IosQrLoginStage.FAILED)
        }
    }

    fun observe(onValue: (IosQrLoginState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun retry() = viewModel.load()
    fun confirm(approved: Boolean) = viewModel.confirm(approved)
    fun close() = screen.close()
}
