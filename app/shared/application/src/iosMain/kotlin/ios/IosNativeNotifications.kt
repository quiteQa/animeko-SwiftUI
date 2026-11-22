/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.ios

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import me.him188.ani.app.data.models.notification.Announcement
import me.him188.ani.app.data.models.notification.AppNotification
import me.him188.ani.app.data.models.notification.AppNotificationContent
import me.him188.ani.app.data.models.notification.NotificationDestination
import me.him188.ani.app.data.models.notification.NotificationGroup
import me.him188.ani.app.data.models.notification.SystemNotificationEvent
import me.him188.ani.app.data.repository.user.SettingsRepository
import me.him188.ani.app.ui.notification.AnnouncementDetailViewModel
import me.him188.ani.app.ui.notification.AnnouncementsViewModel
import me.him188.ani.app.ui.notification.DetailLoadState
import me.him188.ani.app.ui.notification.NotificationAccess
import me.him188.ani.app.ui.notification.NotificationCenterViewModel
import me.him188.ani.app.ui.notification.NotificationDetailViewModel
import me.him188.ani.app.ui.notification.NotificationInlineAction
import me.him188.ani.app.ui.notification.NotificationListItemDefaults
import me.him188.ani.app.ui.notification.NotificationOpenTarget
import me.him188.ani.app.ui.notification.ReadOverlay
import me.him188.ani.app.ui.notification.ReportResultAction
import me.him188.ani.app.ui.notification.commentReplyDestination
import me.him188.ani.app.ui.notification.labelRes
import me.him188.ani.app.ui.notification.notificationInlineActions
import me.him188.ani.app.ui.notification.notificationOpenTarget
import me.him188.ani.app.ui.notification.notificationRowText
import me.him188.ani.app.ui.notification.reportResultAction
import me.him188.ani.app.ui.notification.reportResultFallbackDestination
import me.him188.ani.app.ui.notification.reportTargetText
import me.him188.ani.app.ui.notification.resolveString
import org.jetbrains.compose.resources.getString

data class IosNotificationBadge internal constructor(val hasUnread: Boolean)

enum class IosNoticeDestinationKind {
    DETAIL, ACCOUNT, SUBJECT, EPISODE, PERSON, CHARACTER, EPISODE_COMMENT, PERSON_COMMENT, CHARACTER_COMMENT, URL,
}

class IosNoticeDestination internal constructor(
    val kind: IosNoticeDestinationKind,
    val firstId: Int = 0,
    val secondId: Int = 0,
    val commentId: String? = null,
    val replyId: String? = null,
    val url: String? = null,
)

class IosNoticeRow internal constructor(
    val id: String,
    val title: String,
    val overline: String?,
    val supporting: String?,
    val imageUrl: String?,
    val symbol: String,
    val createdAtMillis: Long,
    val unread: Boolean,
    val needsUpdate: Boolean,
    val canReauthorize: Boolean,
    val destination: IosNoticeDestination,
)

class IosNoticePage internal constructor(
    val rows: List<IosNoticeRow>,
    val status: IosLoadStatus,
    val canLoadMore: Boolean,
    val appendFailed: Boolean,
    val unreadCount: Int,
    val canMarkAllRead: Boolean,
)

class IosNotificationCenterState internal constructor(
    val notices: IosNoticePage,
    val interactions: IosNoticePage,
    val authorized: Boolean,
    val accessLoading: Boolean,
    val latestAnnouncementTitle: String?,
    val hasUnreadAnnouncements: Boolean,
    val operationFailed: Boolean,
)

class IosNativeNotifications internal constructor(settings: SettingsRepository) {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { NotificationCenterViewModel() }
    private val feeds = viewModel.groups.associateWith { group ->
        IosPagedFeed(screen.coroutineScope, flowOf(viewModel.notificationsPager(group)))
    }
    private val operationFailed = MutableStateFlow(false)
    private val marking = mutableSetOf<NotificationGroup>()
    private val originalTitles = settings.uiSettings.flow.map { it.subjectAppearance.useOriginalTitle }.distinctUntilChanged()

    private data class ListContext(val authorized: Boolean, val loading: Boolean, val originalTitles: Boolean)

    private val listContext = combine(viewModel.access, originalTitles) { access, original ->
        ListContext(access == NotificationAccess.AUTHORIZED, access == NotificationAccess.LOADING, original)
    }

    private fun page(group: NotificationGroup) =
        combine(feeds.getValue(group).state, viewModel.readOverlays, viewModel.badgeState, listContext) { page, overlays, badge, ctx ->
            val overlay = overlays[group] ?: ReadOverlay.Empty
            val unread = badge.unreadCountOf(group)
            IosNoticePage(
                if (ctx.authorized) page.items.map { it.toRow(overlay, ctx.originalTitles) } else emptyList(),
                page.status,
                page.canLoadMore,
                page.appendFailed,
                unread,
                ctx.authorized && page.items.isNotEmpty() && (unread > 0 || page.items.any { !overlay.isRead(it) }),
            )
        }

    private val state = combine(
        page(NotificationGroup.NOTICE),
        page(NotificationGroup.INTERACTION),
        listContext,
        viewModel.badgeState,
        operationFailed,
    ) { notices, interactions, context, badges, failed ->
        IosNotificationCenterState(
            notices, interactions, context.authorized, context.loading,
            badges.latestAnnouncement?.title, badges.hasUnreadAnnouncements, failed,
        )
    }

    init {
        screen.coroutineScope.launch {
            var previous = viewModel.badgeState.value.unreadCounts
            viewModel.badgeState.map { it.unreadCounts }.distinctUntilChanged().drop(1).collect { counts ->
                if (viewModel.access.value == NotificationAccess.AUTHORIZED) {
                    for ((group, feed) in feeds) {
                        val unread = counts[group] ?: 0
                        val page = feed.state.value
                        val overlay = viewModel.readOverlays.value[group] ?: ReadOverlay.Empty
                        if (page.status == IosLoadStatus.READY &&
                            unread > (previous[group] ?: 0) && unread > page.items.count { !overlay.isRead(it) }
                        ) {
                            feed.refresh()
                        }
                    }
                }
                previous = counts
            }
        }
    }

    fun observe(onValue: (IosNotificationCenterState) -> Unit): IosObservation =
        screen.coroutineScope.observe(state, onValue)

    fun refresh(interactions: Boolean) {
        feed(interactions).refresh()
        viewModel.refreshBadge()
    }

    fun retry(interactions: Boolean) { feed(interactions).retry() }
    fun loadMore(interactions: Boolean) = feed(interactions).loadMore()

    fun markRead(id: String) {
        if (viewModel.access.value != NotificationAccess.AUTHORIZED) return
        feeds.values.firstNotNullOfOrNull { feed -> feed.state.value.items.firstOrNull { it.id == id } }
            ?.let(viewModel::markRead)
    }

    fun markAllRead(interactions: Boolean) {
        if (viewModel.access.value != NotificationAccess.AUTHORIZED) return
        val group = group(interactions)
        val feed = feeds.getValue(group)
        val newest = feed.state.value.items.maxOfOrNull { it.createdAtMillis } ?: return
        if (!marking.add(group)) return
        screen.coroutineScope.launch {
            try {
                viewModel.markAllRead(group, newest)
                feed.refresh()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                operationFailed.value = true
            } finally {
                marking.remove(group)
            }
        }
    }

    fun dismissFailure() { operationFailed.value = false }
    fun close() = screen.close()

    private fun group(interactions: Boolean) = if (interactions) NotificationGroup.INTERACTION else NotificationGroup.NOTICE
    private fun feed(interactions: Boolean) = feeds.getValue(group(interactions))
}

class IosAnnouncementRow internal constructor(
    val id: String,
    val title: String,
    val tag: String,
    val body: String,
    val url: String?,
    val publishedAtMillis: Long,
    val pinned: Boolean,
    val unread: Boolean,
)

class IosAnnouncementPage internal constructor(
    val rows: List<IosAnnouncementRow>,
    val status: IosLoadStatus,
    val canLoadMore: Boolean,
    val appendFailed: Boolean,
)

class IosNativeAnnouncements internal constructor() {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { AnnouncementsViewModel() }
    private val feed = IosPagedFeed(screen.coroutineScope, flowOf(viewModel.announcementsPager))
    private val state = combine(feed.state, viewModel.access, viewModel.readOverlay) { page, access, overlay ->
        IosAnnouncementPage(
            page.items.map { it.toRow(access == NotificationAccess.AUTHORIZED && overlay.isRead(it) == false) },
            if (access == NotificationAccess.LOADING) IosLoadStatus.LOADING else page.status,
            page.canLoadMore,
            page.appendFailed,
        )
    }

    init {
        screen.coroutineScope.launch {
            feed.state.collect { page ->
                if (page.status == IosLoadStatus.READY && page.items.isNotEmpty()) viewModel.markLoadedAnnouncementsRead()
            }
        }
    }

    fun observe(onValue: (IosAnnouncementPage) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun markRead(id: String) {
        feed.state.value.items.firstOrNull { it.id == id }?.let(viewModel::markRead)
    }
    fun refresh() {
        feed.refresh()
        viewModel.refreshBadge()
    }
    fun retry() { feed.retry() }
    fun loadMore() = feed.loadMore()
    fun close() = screen.close()
}

class IosNoticeDetailState internal constructor(
    val status: IosLoadStatus,
    val row: IosNoticeRow? = null,
    val body: String? = null,
    val destination: IosNoticeDestination? = null,
    val actionTitle: String? = null,
    val report: IosNoticeReport? = null,
)

class IosNoticeReport internal constructor(
    val target: String,
    val reason: String,
    val removed: Boolean,
    val reportedAtMillis: Long,
    val handledAtMillis: Long,
    val snapshot: String?,
)

class IosNativeNotificationDetail internal constructor(id: String, settings: SettingsRepository) {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { NotificationDetailViewModel(id) }
    private val state = combine(viewModel.state, settings.uiSettings.flow) { load, settings ->
        when (load) {
            DetailLoadState.Loading -> IosNoticeDetailState(IosLoadStatus.LOADING)
            DetailLoadState.NotFound -> IosNoticeDetailState(IosLoadStatus.IDLE)
            is DetailLoadState.Failed -> IosNoticeDetailState(IosLoadStatus.FAILED)
            is DetailLoadState.Loaded -> load.value.toDetail(settings.subjectAppearance.useOriginalTitle)
        }
    }

    fun observe(onValue: (IosNoticeDetailState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun retry() = viewModel.reload()
    fun close() = screen.close()
}

class IosAnnouncementDetailState internal constructor(val status: IosLoadStatus, val row: IosAnnouncementRow? = null)

class IosNativeAnnouncementDetail internal constructor(id: String) {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { AnnouncementDetailViewModel(id) }
    private val state = viewModel.state.map { load ->
        when (load) {
            DetailLoadState.Loading -> IosAnnouncementDetailState(IosLoadStatus.LOADING)
            DetailLoadState.NotFound -> IosAnnouncementDetailState(IosLoadStatus.IDLE)
            is DetailLoadState.Failed -> IosAnnouncementDetailState(IosLoadStatus.FAILED)
            is DetailLoadState.Loaded -> IosAnnouncementDetailState(IosLoadStatus.READY, load.value.toRow(false))
        }
    }

    fun observe(onValue: (IosAnnouncementDetailState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun retry() = viewModel.reload()
    fun close() = screen.close()
}

private suspend fun AppNotification.toRow(overlay: ReadOverlay, originalTitles: Boolean): IosNoticeRow {
    val text = notificationRowText(this, originalTitles)
    val destination = when (val target = notificationOpenTarget(this)) {
        NotificationOpenTarget.AccountSettings -> IosNoticeDestination(IosNoticeDestinationKind.ACCOUNT)
        is NotificationOpenTarget.Destination -> target.destination.toIos()
        NotificationOpenTarget.Detail -> null
    } ?: IosNoticeDestination(IosNoticeDestinationKind.DETAIL)
    return IosNoticeRow(
        id, text.headline.resolveString(), text.overline?.resolveString(), text.supporting?.resolveString(),
        NotificationListItemDefaults.imageUrlFor(this),
        when (display.icon?.wireValue) {
            "report" -> "exclamationmark.shield"
            "security" -> "lock.shield"
            "reply" -> "arrowshape.turn.up.left"
            "mention" -> "at"
            "reaction" -> "heart"
            "follow" -> "person.badge.plus"
            else -> "bell"
        },
        createdAtMillis,
        !overlay.isRead(this),
        type == null,
        NotificationInlineAction.REAUTHORIZE_BANGUMI in notificationInlineActions(content),
        destination,
    )
}

private suspend fun AppNotification.toDetail(originalTitles: Boolean): IosNoticeDetailState {
    val row = toRow(ReadOverlay.Empty, originalTitles)
    val reportContent = content as? AppNotificationContent.ReportResult
    val reportAction = reportContent?.let(::reportResultAction)
    val destination = when (val content = content) {
        is AppNotificationContent.ReportResult ->
            reportAction?.toDestination() ?: reportResultFallbackDestination(content, display)
        is AppNotificationContent.CommentReply -> commentReplyDestination(content, display)
        is AppNotificationContent.System ->
            if (content.event == SystemNotificationEvent.BANGUMI_AUTHORIZATION_EXPIRED) null else display.target?.destination
        is AppNotificationContent.AccountSecurity, AppNotificationContent.Unknown -> display.target?.destination
    }
    return IosNoticeDetailState(
        IosLoadStatus.READY,
        row,
        if (row.canReauthorize) row.supporting else display.body,
        destination?.toIos(),
        destination?.let { getString(it.labelRes) },
        reportContent?.let {
            IosNoticeReport(
                reportTargetText(it, display, originalTitles).resolveString(),
                it.reason.name, it.contentRemoved, it.reportedAtMillis, it.handledAtMillis, it.contentSnapshot,
            )
        },
    )
}

private fun ReportResultAction.toDestination(): NotificationDestination = when (this) {
    is ReportResultAction.OpenEpisode -> NotificationDestination.Episode(subjectId.toLong(), episodeId.toLong())
    is ReportResultAction.OpenSubject -> NotificationDestination.Subject(subjectId.toLong())
    is ReportResultAction.OpenPerson -> NotificationDestination.Person(personId.toLong())
    is ReportResultAction.OpenCharacter -> NotificationDestination.Character(characterId.toLong())
}

private fun Long.positiveIntId() = takeIf { it in 1L..Int.MAX_VALUE.toLong() }?.toInt()

private fun NotificationDestination.toIos(): IosNoticeDestination? = when (this) {
    is NotificationDestination.Subject -> subjectId.positiveIntId()?.let { IosNoticeDestination(IosNoticeDestinationKind.SUBJECT, it) }
    is NotificationDestination.Episode -> {
        val subject = subjectId.positiveIntId()
        val episode = episodeId.positiveIntId()
        if (subject != null && episode != null) IosNoticeDestination(IosNoticeDestinationKind.EPISODE, subject, episode) else null
    }
    is NotificationDestination.Person -> personId.positiveIntId()?.let { IosNoticeDestination(IosNoticeDestinationKind.PERSON, it) }
    is NotificationDestination.Character -> characterId.positiveIntId()?.let { IosNoticeDestination(IosNoticeDestinationKind.CHARACTER, it) }
    is NotificationDestination.Url -> IosNoticeDestination(IosNoticeDestinationKind.URL, url = url)
    is NotificationDestination.CommentThread -> host.toIos()?.let { target ->
        val kind = when (host) {
            is NotificationDestination.Episode -> IosNoticeDestinationKind.EPISODE_COMMENT
            is NotificationDestination.Person -> IosNoticeDestinationKind.PERSON_COMMENT
            is NotificationDestination.Character -> IosNoticeDestinationKind.CHARACTER_COMMENT
        }
        IosNoticeDestination(kind, target.firstId, target.secondId, commentId, replyId)
    }
}

private fun Announcement.toRow(unread: Boolean) =
    IosAnnouncementRow(id, title, rawTag, body, linkUrl, publishedAtMillis, pinned, unread)

enum class IosNotificationPreference { ANNOUNCEMENT_BADGE, COMMENT_REPLIES, REPORT_RESULTS, ACCOUNT_SECURITY }

data class IosNotificationPreferences internal constructor(
    val announcementBadge: Boolean,
    val commentReplies: Boolean,
    val reportResults: Boolean,
    val accountSecurity: Boolean,
)

class IosNativeNotificationSettings internal constructor(
    private val settings: SettingsRepository,
    private val writes: CoroutineScope,
) {
    private val screen = IosScreenScope()
    private val state = settings.notificationSettings.flow.map {
        IosNotificationPreferences(it.showAnnouncementDot, it.showCommentReplies, it.showReportResults, it.showAccountSecurity)
    }

    fun observe(onValue: (IosNotificationPreferences) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)

    fun update(preference: IosNotificationPreference, enabled: Boolean) {
        writes.launch {
            settings.notificationSettings.update {
                when (preference) {
                    IosNotificationPreference.ANNOUNCEMENT_BADGE -> copy(showAnnouncementDot = enabled)
                    IosNotificationPreference.COMMENT_REPLIES -> copy(showCommentReplies = enabled)
                    IosNotificationPreference.REPORT_RESULTS -> copy(showReportResults = enabled)
                    IosNotificationPreference.ACCOUNT_SECURITY -> copy(showAccountSecurity = enabled)
                }
            }
        }
    }

    fun close() = screen.close()
}
