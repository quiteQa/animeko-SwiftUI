/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

@file:OptIn(ExperimentalCoroutinesApi::class)

package me.him188.ani.app.ios

import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import me.him188.ani.app.domain.session.SessionState
import me.him188.ani.app.domain.session.SessionStateProvider
import me.him188.ani.app.navigation.NavRoutes
import me.him188.ani.app.ui.comment.CommentEditorState
import me.him188.ani.app.ui.comment.CommentState
import me.him188.ani.app.ui.comment.UIComment
import me.him188.ani.app.ui.subject.person.CharacterDetailsViewModel
import me.him188.ani.app.ui.subject.person.PeopleDetailsViewModel
import me.him188.ani.app.ui.subject.person.PersonDetailsViewModel

class IosCommentListState internal constructor(
    val comments: List<IosCommentRow>,
    val status: IosLoadStatus,
    val canLoadMore: Boolean,
    val appendFailed: Boolean,
    val signedIn: Boolean,
    val originalCommentsUnavailable: Boolean,
    val action: IosCommentAction,
)

class IosNativeComments internal constructor(
    private val screen: IosScreenScope,
    private val comments: CommentState,
    private val editor: CommentEditorState,
    private val startNewComment: () -> Boolean,
    private val refreshComments: () -> Unit,
    private val threadRoute: (UIComment) -> NavRoutes.CommentThread,
    private val session: SessionStateProvider,
    val originalUrl: String,
) {
    private val feed = IosPagedFeed(screen.coroutineScope, flowOf(comments.list))
    private val action = MutableStateFlow(IosCommentAction.IDLE)
    private val originalUnavailable = MutableStateFlow(false)

    private val state = combine(feed.state, session.stateFlow, originalUnavailable, action) { page, account, unavailable, action ->
        snapshotFlow {
            IosCommentListState(
                page.items.map { comments.withOverlay(it).toNativeRow() }.distinctBy { it.stableId },
                page.status,
                page.canLoadMore,
                page.appendFailed,
                account is SessionState.Valid,
                unavailable,
                action,
            )
        }
    }.flatMapLatest { it }

    init {
        screen.coroutineScope.launch { comments.commentLoadFailures.collect { originalUnavailable.value = true } }
    }

    fun observe(onValue: (IosCommentListState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun loadMore() = feed.loadMore()
    fun retry() { feed.retry() }
    fun refresh() {
        originalUnavailable.value = false
        refreshComments()
    }

    fun openThread(id: String): IosNativeCommentThread? {
        val comment = feed.state.value.items.find { it.stableId == id } ?: return null
        return IosNativeCommentThread(threadRoute(comment), comments.withOverlay(comment), ::refresh)
    }

    fun send(text: String) {
        if (action.value == IosCommentAction.SENDING || text.isBlank()) return
        action.value = IosCommentAction.SENDING
        screen.coroutineScope.launch {
            action.value = try {
                if (session.stateFlow.first() is SessionState.Valid && startNewComment()) {
                    editor.textFieldState.edit { replace(0, length, text.trim()) }
                    if (editor.send()) {
                        refresh()
                        IosCommentAction.SENT
                    } else {
                        IosCommentAction.SEND_FAILED
                    }
                } else {
                    IosCommentAction.SEND_FAILED
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                IosCommentAction.SEND_FAILED
            }
        }
    }

    fun dismissAction() {
        if (action.value != IosCommentAction.SENDING) action.value = IosCommentAction.IDLE
    }

    fun close() = screen.close()
}

internal fun openPeopleComments(id: Int, isCharacter: Boolean, session: SessionStateProvider): IosNativeComments {
    val screen = IosScreenScope()
    val viewModel: PeopleDetailsViewModel = if (isCharacter) {
        screen.viewModel { CharacterDetailsViewModel(id) }
    } else {
        screen.viewModel { PersonDetailsViewModel(id) }
    }
    val state = viewModel.comments
    val host = if (isCharacter) IosCommentHost.CHARACTER else IosCommentHost.PERSON
    return IosNativeComments(
        screen,
        state.commentState,
        state.editorState,
        {
            state.startNewComment()
            true
        },
        state::refresh,
        { comment -> host.toRoute(id, 0, comment.stableId, null) },
        session,
        state.originalCommentsUrl,
    )
}
