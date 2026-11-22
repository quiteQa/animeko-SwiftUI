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
import kotlinx.coroutines.withTimeoutOrNull
import me.him188.ani.app.navigation.CommentThreadTarget
import me.him188.ani.app.navigation.NavRoutes
import me.him188.ani.app.ui.comment.CommentReportReason
import me.him188.ani.app.ui.comment.UIComment
import me.him188.ani.app.ui.comment.UICommentSource
import me.him188.ani.app.ui.comment.UICommentVote
import me.him188.ani.app.ui.comment.thread.CommentThreadRootState
import me.him188.ani.app.ui.comment.thread.CommentThreadViewModel
import me.him188.ani.app.ui.comment.thread.commentOrNull
import me.him188.ani.app.ui.comment.toPlainText

enum class IosCommentHost {
    EPISODE, PERSON, CHARACTER;

    internal fun toRoute(firstId: Int, secondId: Int, commentId: String, replyId: String?) =
        NavRoutes.CommentThread(
            when (this) {
                EPISODE -> CommentThreadTarget.Episode(firstId, secondId)
                PERSON -> CommentThreadTarget.Person(firstId)
                CHARACTER -> CommentThreadTarget.Character(firstId)
            },
            commentId = commentId,
            focusReplyId = replyId,
        )
}

enum class IosCommentAction { IDLE, SENDING, SENT, SEND_FAILED, REPORTING, REPORTED, REPORT_FAILED, VOTE_FAILED }

class IosCommentRow internal constructor(
    val stableId: String,
    val author: String?,
    val body: String,
    val createdAtMillis: Long,
    val replyTo: String?,
    val parentDeleted: Boolean,
    val likes: Int,
    val liked: Boolean,
    val disliked: Boolean,
    val readOnly: Boolean,
    val replyCount: Int,
)

class IosCommentThreadState internal constructor(
    val root: IosCommentRow?,
    val replies: List<IosCommentRow>,
    val status: IosLoadStatus,
    val repliesStatus: IosLoadStatus,
    val canLoadMore: Boolean,
    val appendFailed: Boolean,
    val subtitle: String?,
    val action: IosCommentAction,
    val canReply: Boolean,
    val replyTargetId: String?,
    val replyTargetName: String?,
    val focusReplyId: String?,
)

class IosNativeCommentThread internal constructor(
    route: NavRoutes.CommentThread,
    snapshot: UIComment? = null,
    private val refreshParent: () -> Unit = {},
) {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { CommentThreadViewModel(route, snapshot = snapshot) }
    private val thread = viewModel.thread
    private val feed = IosPagedFeed(screen.coroutineScope, flowOf(thread.commentState.list))
    private val action = MutableStateFlow(IosCommentAction.IDLE)
    private val focusedReply = MutableStateFlow<String?>(null)
    val originalUrl: String get() = viewModel.originalCommentsUrl

    private data class Snapshot(
        val root: CommentThreadRootState,
        val page: IosPage<UIComment>,
        val subtitle: String?,
        val action: IosCommentAction,
        val focusedReply: String?,
    )

    private val state = combine(thread.root, feed.state, viewModel.subtitle, action, focusedReply, ::Snapshot)
        .flatMapLatest { snapshot ->
            snapshotFlow {
                val root = snapshot.root.commentOrNull
                IosCommentThreadState(
                    root?.let { thread.commentState.withOverlay(it).toNativeRow() },
                    snapshot.page.items.map { thread.commentState.withOverlay(it).toNativeRow() }.distinctBy { it.stableId },
                    when (snapshot.root) {
                        is CommentThreadRootState.Loading -> IosLoadStatus.LOADING
                        is CommentThreadRootState.Loaded -> IosLoadStatus.READY
                        is CommentThreadRootState.Failed -> IosLoadStatus.FAILED
                        CommentThreadRootState.NotFound -> IosLoadStatus.IDLE
                    },
                    snapshot.page.status,
                    snapshot.page.canLoadMore,
                    snapshot.page.appendFailed,
                    snapshot.subtitle,
                    snapshot.action,
                    root?.let { it.source == UICommentSource.ANI && it.canReply } == true,
                    thread.replyTarget?.stableId,
                    thread.replyTarget?.author?.nickname,
                    snapshot.focusedReply,
                )
            }
        }

    init {
        route.focusReplyId?.let { id -> screen.coroutineScope.launch { focusReply(id) } }
        screen.coroutineScope.launch {
            thread.commentState.actionSubmitFailures.collect {
                if (action.value == IosCommentAction.IDLE) action.value = IosCommentAction.VOTE_FAILED
            }
        }
    }

    fun observe(onValue: (IosCommentThreadState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun refresh() = thread.refresh()
    fun retryReplies() { feed.retry() }
    fun loadMore() = feed.loadMore()
    fun selectReply(id: String?) {
        thread.selectReplyTarget(id?.let(::findComment)?.takeIf { it.source == UICommentSource.ANI })
    }

    fun vote(id: String, like: Boolean) {
        val comment = findComment(id)?.takeIf { it.source == UICommentSource.ANI } ?: return
        thread.commentState.toggleVote(comment, if (like) UICommentVote.LIKE else UICommentVote.DISLIKE)
    }

    fun reply(text: String) {
        val root = thread.root.value.commentOrNull?.takeIf { it.source == UICommentSource.ANI && it.canReply } ?: return
        if (text.isBlank() || busy()) return
        val target = thread.replyTarget ?: root
        saveAction(IosCommentAction.SENDING, IosCommentAction.SENT, IosCommentAction.SEND_FAILED) {
            viewModel.startReply(target)
            viewModel.editorState.textFieldState.edit { replace(0, length, text.trim()) }
            viewModel.editorState.send().also {
                if (it) {
                    thread.onReplySent()
                    refreshParent()
                }
            }
        }
    }

    fun report(id: String, reason: String, detail: String) {
        val comment = findComment(id)?.takeIf { it.source == UICommentSource.ANI } ?: return
        val selected = CommentReportReason.entries.firstOrNull { it.name == reason } ?: return
        if (busy()) return
        saveAction(IosCommentAction.REPORTING, IosCommentAction.REPORTED, IosCommentAction.REPORT_FAILED) {
            viewModel.reportState.submitAwait(comment, selected, detail.trim()).isSuccess
        }
    }

    fun dismissAction() {
        if (!busy()) action.value = IosCommentAction.IDLE
    }

    fun acknowledgeFocus() { focusedReply.value = null }
    fun close() = screen.close()

    private fun busy() = action.value == IosCommentAction.SENDING || action.value == IosCommentAction.REPORTING

    private fun findComment(id: String): UIComment? =
        thread.root.value.commentOrNull?.takeIf { it.stableId == id }
            ?: feed.state.value.items.firstOrNull { it.stableId == id }

    private fun saveAction(
        inProgress: IosCommentAction,
        success: IosCommentAction,
        failure: IosCommentAction,
        run: suspend () -> Boolean,
    ) {
        action.value = inProgress
        screen.coroutineScope.launch {
            action.value = try {
                if (run()) success else failure
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                failure
            }
        }
    }

    private suspend fun focusReply(id: String) {
        val initial = combine(thread.root, feed.state) { root, page -> root to page }.first { (root, page) ->
            root == CommentThreadRootState.NotFound ||
                    (root is CommentThreadRootState.Loaded && page.status == IosLoadStatus.READY)
        }
        if (initial.first == CommentThreadRootState.NotFound) return
        var page = initial.second
        repeat(11) { index ->
            if (page.items.any { it.stableId == id }) {
                focusedReply.value = id
                return
            }
            if (index == 10 || !page.canLoadMore) return
            val previous = page.items.size
            feed.loadMore()
            page = withTimeoutOrNull(5_000) {
                feed.state.first { !it.appendLoading && (it.items.size > previous || !it.canLoadMore) }
            } ?: return
        }
    }
}

internal fun UIComment.toNativeRow() = IosCommentRow(
    stableId, author?.nickname, content.toPlainText(), createdAt, replyTo?.nickname,
    parentStableId != null && replyTo == null, likeCount, selfVote == UICommentVote.LIKE,
    selfVote == UICommentVote.DISLIKE, source == UICommentSource.BANGUMI, replyCount,
)
