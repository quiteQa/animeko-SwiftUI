/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

@file:OptIn(ExperimentalCoroutinesApi::class)

package me.him188.ani.app.ios

import androidx.compose.runtime.snapshotFlow
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.paging.LoadState
import androidx.paging.PagingData
import androidx.paging.compose.LazyPagingItems
import androidx.paging.compose.launchAsLazyPagingItemsIn
import androidx.paging.flatMap
import androidx.paging.map
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.TimeZone
import kotlinx.datetime.atStartOfDayIn
import kotlinx.datetime.toInstant
import me.him188.ani.app.data.models.preference.DarkMode
import me.him188.ani.app.data.models.preference.NsfwMode
import me.him188.ani.app.data.models.subject.SubjectInfo
import me.him188.ani.app.data.models.subject.listCoverUrl
import me.him188.ani.app.data.models.subject.nameOrNameCn
import me.him188.ani.app.data.network.TrendsRepository
import me.him188.ani.app.data.repository.subject.CollectionsFilterQuery
import me.him188.ani.app.data.repository.subject.SubjectCollectionRepository
import me.him188.ani.app.data.repository.user.QrLoginRepository
import me.him188.ani.app.data.repository.user.SettingsRepository
import me.him188.ani.app.data.repository.user.UserRepository
import me.him188.ani.app.domain.notification.NotificationBadgeManager
import me.him188.ani.app.domain.search.SubjectSearchQuery
import me.him188.ani.app.domain.session.auth.OAuthPlatform
import me.him188.ani.app.domain.session.InvalidSessionReason
import me.him188.ani.app.domain.session.SessionState
import me.him188.ani.app.domain.session.SessionStateProvider
import me.him188.ani.app.ui.rating.RateRequest
import me.him188.ani.app.navigation.EpisodeNavigationGuardRegistry
import me.him188.ani.app.platform.IosContext
import me.him188.ani.app.ui.exploration.schedule.AiringScheduleColumnItem
import me.him188.ani.app.ui.exploration.schedule.ScheduleDay
import me.him188.ani.app.ui.exploration.schedule.ScheduleViewModel
import me.him188.ani.app.ui.exploration.search.SearchPageIntent
import me.him188.ani.app.ui.exploration.search.SubjectPreviewItemInfo
import me.him188.ani.app.ui.exploration.trends.TrendingRankingViewModel
import me.him188.ani.app.ui.main.SearchViewModel
import me.him188.ani.app.ui.notification.showsEntryDot
import me.him188.ani.app.ui.subject.details.SubjectDetailsLoadState
import me.him188.ani.app.ui.subject.details.SubjectDetailsViewModel
import me.him188.ani.datasources.api.topic.UnifiedCollectionType
import org.koin.mp.KoinPlatform

class IosObservation internal constructor(private val job: Job) {
    fun cancel() = job.cancel()
}

internal fun <T> CoroutineScope.observe(flow: Flow<T>, onValue: (T) -> Unit): IosObservation =
    IosObservation(launch { flow.collect { onValue(it) } })

internal class IosScreenScope {
    val coroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val viewModels = ViewModelStore()

    inline fun <reified T : ViewModel> viewModel(crossinline create: () -> T): T =
        ViewModelProvider.create(viewModels, viewModelFactory { initializer { create() } })[T::class]

    fun close() {
        coroutineScope.cancel()
        viewModels.clear()
    }
}

enum class IosLoadStatus { IDLE, LOADING, READY, FAILED }

class IosSubjectCard internal constructor(
    val subjectId: Int,
    val title: String,
    val coverUrl: String,
    val obscuresCover: Boolean = false,
    val rank: Int = 0,
)

class IosCatalogState internal constructor(
    val subjects: List<IosSubjectCard>,
    val status: IosLoadStatus,
    val canLoadMore: Boolean = false,
    val appendFailed: Boolean = false,
    val requiresSignIn: Boolean = false,
)

internal data class IosPage<T : Any>(
    val items: List<T>,
    val status: IosLoadStatus,
    val canLoadMore: Boolean = false,
    val appendFailed: Boolean = false,
    val appendLoading: Boolean = false,
)

internal class IosPagedFeed<T : Any>(
    scope: CoroutineScope,
    pages: Flow<Flow<PagingData<T>>?>,
) {
    private val current = MutableStateFlow(IosPage<T>(emptyList(), IosLoadStatus.IDLE))
    val state: StateFlow<IosPage<T>> get() = current
    private var activeItems: LazyPagingItems<T>? = null

    init {
        scope.launch {
            pages.collectLatest { page ->
                if (page == null) {
                    current.value = IosPage(emptyList(), IosLoadStatus.IDLE)
                    return@collectLatest
                }
                current.value = IosPage(emptyList(), IosLoadStatus.LOADING)
                coroutineScope {
                    val items = page.launchAsLazyPagingItemsIn(this)
                    activeItems = items
                    try {
                        snapshotFlow {
                            val loadState = items.loadState
                            val status = when (loadState.refresh) {
                                is LoadState.Error -> IosLoadStatus.FAILED
                                is LoadState.Loading -> IosLoadStatus.LOADING
                                is LoadState.NotLoading -> IosLoadStatus.READY
                            }
                            IosPage(
                                items.itemSnapshotList.items,
                                status,
                                canLoadMore = items.itemCount > 0 &&
                                        loadState.append is LoadState.NotLoading &&
                                        !loadState.append.endOfPaginationReached,
                                appendFailed = loadState.append is LoadState.Error,
                                appendLoading = loadState.append is LoadState.Loading,
                            )
                        }.collect { current.value = it }
                    } finally {
                        activeItems = null
                    }
                }
            }
        }
    }

    fun loadMore() {
        val items = activeItems ?: return
        val snapshot = items.itemSnapshotList
        if (state.value.canLoadMore && snapshot.items.isNotEmpty()) {
            items[snapshot.placeholdersBefore + snapshot.items.lastIndex]
        }
    }

    fun refresh() = activeItems?.refresh()
    fun retry() = activeItems?.retry()
}

private class IosCatalogPaging<T : Any>(
    scope: CoroutineScope,
    pages: Flow<Flow<PagingData<T>>?>,
    toCard: (T) -> IosSubjectCard?,
) {
    private val feed = IosPagedFeed(scope, pages)
    val state = feed.state.map { page ->
        IosCatalogState(
            page.items.mapNotNull(toCard).distinctBy { it.subjectId },
            page.status,
            page.canLoadMore,
            page.appendFailed,
        )
    }

    fun loadMore() = feed.loadMore()
    fun refresh() = feed.refresh()
    fun retry() = feed.retry()
}

class IosNativeSearch internal constructor() {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { SearchViewModel(SubjectSearchQuery("")) }
    private val search = viewModel.searchPageState.value.searchState
    private var submittedKeywords = ""
    private val paging = IosCatalogPaging(screen.coroutineScope, search.pagerFlow) { it.toCard() }

    fun observe(onValue: (IosCatalogState) -> Unit): IosObservation = screen.coroutineScope.observe(paging.state, onValue)

    fun submit(keywords: String) {
        val normalized = keywords.trim()
        if (normalized == submittedKeywords) return
        submittedKeywords = normalized
        if (normalized.isEmpty()) {
            search.clear()
        } else {
            viewModel.onSearchPageIntent(SearchPageIntent.UpdateQuery(SubjectSearchQuery(normalized), submit = true))
        }
    }

    fun loadMore() = paging.loadMore()
    fun retry() { paging.retry() }
    fun close() = screen.close()
}

enum class IosCollectionFilter(internal val type: UnifiedCollectionType) {
    WATCHING(UnifiedCollectionType.DOING),
    WANTED(UnifiedCollectionType.WISH),
    COMPLETED(UnifiedCollectionType.DONE),
    ON_HOLD(UnifiedCollectionType.ON_HOLD),
    DROPPED(UnifiedCollectionType.DROPPED),
}

class IosSubjectCollectionState internal constructor(
    val status: IosCollectionFilter?,
    val signedIn: Boolean,
    val available: Boolean,
    val working: Boolean,
    val offerMarkAllWatched: Boolean,
    val failed: Boolean,
)

class IosNativeCollections internal constructor(
    repository: SubjectCollectionRepository,
    settings: SettingsRepository,
    session: SessionStateProvider,
) {
    private val screen = IosScreenScope()
    private val filter = MutableStateFlow(IosCollectionFilter.WATCHING)
    private val paging = IosCatalogPaging(
        screen.coroutineScope,
        filter.flatMapLatest { selected ->
            settings.uiSettings.flow.map { it.subjectAppearance.useOriginalTitle }.distinctUntilChanged()
                .map { useOriginalTitle ->
                    repository.subjectCollectionsPager(CollectionsFilterQuery(selected.type))
                        .map { data ->
                            data.map { item -> item.subjectInfo.toCard(useOriginalTitle, item.nsfwMode == NsfwMode.BLUR) }
                        }
                }
        },
    ) { item -> item }

    private val state = combine(paging.state, session.stateFlow) { page, account ->
        if (page.subjects.isEmpty() && account is SessionState.Invalid && account.reason == InvalidSessionReason.NO_TOKEN) {
            IosCatalogState(emptyList(), IosLoadStatus.IDLE, requiresSignIn = true)
        } else {
            page
        }
    }

    fun observe(onValue: (IosCatalogState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun select(filter: IosCollectionFilter) { this.filter.value = filter }
    fun loadMore() = paging.loadMore()
    fun retry() { paging.retry() }
    fun refresh() { paging.refresh() }
    fun close() = screen.close()
}

class IosNativeExplore internal constructor(repository: TrendsRepository) {
    private val screen = IosScreenScope()
    private val paging = IosCatalogPaging(
        screen.coroutineScope,
        flowOf(repository.trendsInfoPager().map { page -> page.flatMap { it.subjects.take(10) } }),
    ) { item -> IosSubjectCard(item.bangumiId, item.nameCn, item.imageLarge) }

    fun observe(onValue: (IosCatalogState) -> Unit): IosObservation = screen.coroutineScope.observe(paging.state, onValue)
    fun retry() { paging.retry() }
    fun refresh() { paging.refresh() }
    fun close() = screen.close()
}

class IosNativeRankings internal constructor() {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { TrendingRankingViewModel() }
    private val paging = IosCatalogPaging(screen.coroutineScope, flowOf(viewModel.items)) { item ->
        item.subject.toCard(rank = item.rank)
    }

    fun observe(onValue: (IosCatalogState) -> Unit): IosObservation = screen.coroutineScope.observe(paging.state, onValue)
    fun retry() { paging.retry() }
    fun refresh() { paging.refresh() }
    fun loadMore() = paging.loadMore()
    fun close() = screen.close()
}

class IosAiringEpisode internal constructor(
    val episodeId: Int,
    val subject: IosSubjectCard,
    val episodeNumber: String,
    val episodeTitle: String?,
    val airTimeMillis: Long?,
)

class IosAiringDay internal constructor(val dateMillis: Long, val isToday: Boolean, val episodes: List<IosAiringEpisode>)

class IosAiringSchedule internal constructor(val status: IosLoadStatus, val days: List<IosAiringDay>)

class IosNativeSchedule internal constructor(settings: SettingsRepository) {
    private val screen = IosScreenScope()
    private val timeZone = TimeZone.currentSystemDefault()
    private val viewModel = screen.viewModel { ScheduleViewModel(timeZone = timeZone) }
    private val state = combine(
        viewModel.presentationFlow,
        settings.uiSettings.flow.map { it.subjectAppearance.useOriginalTitle }.distinctUntilChanged(),
    ) { schedule, useOriginalTitle ->
        val status = when {
            schedule.error != null -> IosLoadStatus.FAILED
            schedule.isPlaceholder -> IosLoadStatus.LOADING
            else -> IosLoadStatus.READY
        }
        val episodesByDay = schedule.airingSchedules.associateBy { it.date }
        IosAiringSchedule(status, schedule.days.map { day ->
            val episodes = episodesByDay[day.date]?.episodes.orEmpty().mapNotNull { entry ->
                val item = (entry as? AiringScheduleColumnItem.Data)?.item ?: return@mapNotNull null
                IosAiringEpisode(
                    item.episodeId,
                    IosSubjectCard(
                        item.subjectId,
                        if (useOriginalTitle) item.subjectOriginalTitle else item.subjectTitle,
                        item.imageUrl,
                    ),
                    (item.episodeEp ?: item.episodeSort).toString(),
                    if (useOriginalTitle) item.episodeOriginalName else item.episodeName,
                    item.time?.let { LocalDateTime(day.date, it).toInstant(timeZone).toEpochMilliseconds() },
                )
            }
            IosAiringDay(day.date.atStartOfDayIn(timeZone).toEpochMilliseconds(), day.kind == ScheduleDay.Kind.TODAY, episodes)
        })
    }

    fun observe(onValue: (IosAiringSchedule) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun refresh() = viewModel.refresh()
    fun close() = screen.close()
}

class IosEpisodeRow internal constructor(
    val episodeId: Int,
    val number: String,
    val title: String,
    val canPlay: Boolean,
    val watched: Boolean,
    val imageUrl: String?,
    val progress: Double,
)

class IosSubjectRating internal constructor(
    val communityScore: Double,
    val score: Int,
    val comment: String,
    val isPrivate: Boolean,
    val canEdit: Boolean,
    val showEditor: Boolean,
    val saving: Boolean,
)

class IosSubjectState internal constructor(
    val subject: IosSubjectCard?,
    val summary: String,
    val episodes: List<IosEpisodeRow>,
    val status: IosLoadStatus,
    val episodesLoading: Boolean = false,
    val staff: List<IosPersonReference> = emptyList(),
    val characters: List<IosPersonReference> = emptyList(),
    val rating: IosSubjectRating? = null,
    val moreStaff: Boolean = false,
    val moreCharacters: Boolean = false,
    val staffAppendFailed: Boolean = false,
    val charactersAppendFailed: Boolean = false,
)

class IosNativeSubject internal constructor(
    subjectId: Int,
    settings: SettingsRepository,
    private val session: SessionStateProvider,
) {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { SubjectDetailsViewModel(subjectId) }
    private val collectionAction = MutableStateFlow(IosLoadStatus.IDLE)
    private val collectionState = combine(
        viewModel.state.flatMapLatest { load ->
            val details = (load as? SubjectDetailsLoadState.Ok)?.value
            details?.uiState?.map { it.collectionTypeEdit.takeUnless { edit -> edit.isPlaceholder } } ?: flowOf(null)
        },
        session.stateFlow,
        collectionAction,
    ) { edit, account, action ->
        IosSubjectCollectionState(
            IosCollectionFilter.entries.firstOrNull { it.type == edit?.selfCollectionType },
            signedIn = account is SessionState.Valid,
            available = edit != null,
            working = action == IosLoadStatus.LOADING,
            offerMarkAllWatched = edit?.showSetAllEpisodesDoneDialog == true,
            failed = action == IosLoadStatus.FAILED,
        )
    }
    private val appearance = settings.uiSettings.flow.map { it.subjectAppearance to it.episodeProgress }.distinctUntilChanged()
    private val staff = IosPagedFeed(
        screen.coroutineScope,
        viewModel.state.map { (it as? SubjectDetailsLoadState.Ok)?.value?.exposedStaffPager }.distinctUntilChanged(),
    )
    private val characters = IosPagedFeed(
        screen.coroutineScope,
        viewModel.state.map { (it as? SubjectDetailsLoadState.Ok)?.value?.exposedCharactersPager }.distinctUntilChanged(),
    )
    private val state = viewModel.state.flatMapLatest { load ->
        when (load) {
            is SubjectDetailsLoadState.Placeholder ->
                appearance.map { (titles, _) ->
                    IosSubjectState(load.subjectInfo?.toCard(titles.useOriginalTitle), "", emptyList(), IosLoadStatus.LOADING)
                }
            is SubjectDetailsLoadState.Err ->
                appearance.map { (titles, _) ->
                    IosSubjectState(load.placeholder?.toCard(titles.useOriginalTitle), "", emptyList(), IosLoadStatus.FAILED)
                }
            is SubjectDetailsLoadState.Ok -> combine(load.value.uiState, appearance, staff.state, characters.state) {
                detail, (titles, episodes), staffPage, characterPage ->
                val useOriginalTitle = titles.useOriginalTitle
                val info = load.value.info
                val episodeList = detail.episodeListUiState
                IosSubjectState(
                    info?.toCard(useOriginalTitle) ?: IosSubjectCard(subjectId, detail.displayName, ""),
                    info?.summary.orEmpty(),
                    (episodeList.mainEpisodes + episodeList.otherEpisodes).map { episode ->
                        IosEpisodeRow(
                            episode.episodeId,
                            (episode.ep ?: episode.sort).toString(),
                            episode.preferredDisplayName(useOriginalTitle),
                            episode.isBroadcast,
                            episode.collectionType == UnifiedCollectionType.DONE,
                            episode.imageMedium.takeIf { episodes.showEpisodeImages },
                            if (episode.isDoneOrDropped) 0.0 else episode.playProgress?.toDouble() ?: 0.0,
                        )
                    },
                    if (detail.isPlaceholder && info == null) IosLoadStatus.LOADING else IosLoadStatus.READY,
                    episodesLoading = episodeList.isPlaceholder,
                    staff = staffPage.items.map { item ->
                        val person = item.personInfo
                        IosPersonReference(person.id, person.displayName, person.imageMedium, false)
                    }.distinctBy { it.id },
                    characters = characterPage.items.map { item ->
                        val character = item.character
                        IosPersonReference(character.id, character.displayName, character.imageMedium, true)
                    }.distinctBy { it.id },
                    rating = detail.rating.let { rating ->
                        IosSubjectRating(
                            rating.ratingInfo.scoreFloat.toDouble(), rating.selfRatingInfo.score,
                            rating.selfRatingInfo.comment.orEmpty(), rating.selfRatingInfo.isPrivate,
                            rating.enableEdit, rating.showRatingDialog, rating.isUpdating,
                        )
                    },
                    moreStaff = staffPage.canLoadMore,
                    moreCharacters = characterPage.canLoadMore,
                    staffAppendFailed = staffPage.appendFailed,
                    charactersAppendFailed = characterPage.appendFailed,
                )
            }
        }
    }

    init {
        viewModel.load()
    }

    fun observe(onValue: (IosSubjectState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun observeCollection(onValue: (IosSubjectCollectionState) -> Unit): IosObservation =
        screen.coroutineScope.observe(collectionState, onValue)

    fun openRating() { (viewModel.state.value as? SubjectDetailsLoadState.Ok)?.value?.requestEditRating() }
    fun closeRating() { (viewModel.state.value as? SubjectDetailsLoadState.Ok)?.value?.cancelEditRating() }
    fun saveRating(score: Int, review: String, privateRating: Boolean) {
        val details = (viewModel.state.value as? SubjectDetailsLoadState.Ok)?.value ?: return
        if (score in 0..10 && details.uiState.value.rating.enableEdit && !details.uiState.value.rating.isUpdating) {
            details.submitRating(RateRequest(score, review.trim(), privateRating))
        }
    }

    fun loadMoreStaff() = staff.loadMore()
    fun retryStaff() = staff.retry()
    fun loadMoreCharacters() = characters.loadMore()
    fun retryCharacters() = characters.retry()

    fun setCollection(filter: IosCollectionFilter?) {
        val details = (viewModel.state.value as? SubjectDetailsLoadState.Ok)?.value ?: return
        changeCollection { details.setSelfCollectionType(filter?.type ?: UnifiedCollectionType.NOT_COLLECTED) == null }
    }

    fun markAllWatched() {
        val details = (viewModel.state.value as? SubjectDetailsLoadState.Ok)?.value ?: return
        details.dismissSetAllEpisodesDoneDialog()
        changeCollection { details.setAllEpisodesWatchedAwait() == null }
    }

    fun dismissMarkAllWatched() {
        (viewModel.state.value as? SubjectDetailsLoadState.Ok)?.value?.dismissSetAllEpisodesDoneDialog()
    }

    fun dismissCollectionFailure() { collectionAction.value = IosLoadStatus.IDLE }

    private fun changeCollection(change: suspend () -> Boolean) {
        if (collectionAction.value == IosLoadStatus.LOADING) return
        collectionAction.value = IosLoadStatus.LOADING
        screen.coroutineScope.launch {
            val signedIn = session.stateFlow.first() is SessionState.Valid
            collectionAction.value = if (signedIn && change()) IosLoadStatus.READY else IosLoadStatus.FAILED
        }
    }

    fun retry() = viewModel.reload()
    fun close() = screen.close()
}

private fun SubjectInfo.toCard(useOriginalTitle: Boolean, blurNsfw: Boolean = false) =
    IosSubjectCard(subjectId, if (useOriginalTitle) nameOrNameCn else displayName, listCoverUrl, nsfw && blurNsfw)

private fun SubjectPreviewItemInfo.toCard(rank: Int = 0): IosSubjectCard? {
    if (hide || (nsfw && nsfwMode == NsfwMode.HIDE)) return null
    return IosSubjectCard(subjectId, title, imageUrl, nsfw && nsfwMode == NsfwMode.BLUR, rank)
}

enum class IosAppearance { SYSTEM, LIGHT, DARK }
enum class IosInitialTab { EXPLORE, COLLECTION, DOWNLOADS }

@ConsistentCopyVisibility
data class IosNativePreferences internal constructor(
    val appearance: IosAppearance,
    val initialTab: IosInitialTab,
)

class IosNativeCatalog internal constructor(private val context: IosContext, private val appScope: CoroutineScope) {
    private val koin = KoinPlatform.getKoin()
    private val settings = koin.get<SettingsRepository>()
    private val mainScope = CoroutineScope(appScope.coroutineContext + Dispatchers.Main.immediate)
    private val notificationBadgeManager by lazy { koin.get<NotificationBadgeManager>() }
    private val nativeSettings by lazy { IosNativeSettings(settings, mainScope) }

    fun openExplore() = IosNativeExplore(koin.get())
    fun openRankings() = IosNativeRankings()
    fun openSchedule() = IosNativeSchedule(settings)
    fun openSearch() = IosNativeSearch()
    fun openCollections() = IosNativeCollections(koin.get(), settings, koin.get())
    fun openDownloads() = IosNativeDownloads()
    fun openSubjectDownloads(subjectId: Int) = IosNativeSubjectDownloads(subjectId, koin.get(), settings, koin.get(), context)
    fun openSettings() = nativeSettings
    fun openMediaSources() = IosNativeMediaSources(koin.get(), koin.get(), koin.get(), koin.get(), mainScope)
    fun openMediaSourceEditor(kind: IosMediaSourceKind, instanceId: String?) =
        IosNativeMediaSourceEditor(koin.get(), koin.get(), koin.get(), koin.get(), kind, instanceId, mainScope)
    fun openSubject(subjectId: Int) = IosNativeSubject(subjectId, settings, koin.get())
    fun openNotifications() = IosNativeNotifications(settings)
    fun openAnnouncements() = IosNativeAnnouncements()
    fun openNotification(id: String) = IosNativeNotificationDetail(id, settings)
    fun openAnnouncement(id: String) = IosNativeAnnouncementDetail(id)
    fun openNotificationSettings() = IosNativeNotificationSettings(settings, mainScope)
    fun openPlaybackHistory() = IosNativePlaybackHistory()
    fun openPerson(id: Int) = IosNativePeople(id, isCharacter = false)
    fun openCharacter(id: Int) = IosNativePeople(id, isCharacter = true)
    fun openPersonComments(id: Int, character: Boolean) = openPeopleComments(id, character, koin.get())
    fun openSeries(subjectId: Int) = IosNativeSeries(subjectId, settings)
    fun openCommentThread(host: IosCommentHost, firstId: Int, secondId: Int, commentId: String, replyId: String?) =
        IosNativeCommentThread(host.toRoute(firstId, secondId, commentId, replyId))
    fun openAccount() = IosNativeAccount()
    fun openBangumiMerge() = IosNativeBangumiMerge()
    fun openEmailSignIn() = IosNativeEmailSignIn()
    fun openOAuth(providerId: String): IosNativeOAuth? =
        OAuthPlatform.fromId(providerId)?.let { IosNativeOAuth(it, koin.get(), context) }
    fun openQrLogin(requestId: String) = IosNativeQrLogin(requestId)
    fun qrLoginRequestId(content: String): String? = QrLoginRepository.parseRequestId(content)

    fun setNotificationForeground(foreground: Boolean) = notificationBadgeManager.setAppForeground(foreground)

    fun observeNotificationBadge(onValue: (IosNotificationBadge) -> Unit): IosObservation =
        mainScope.observe(
            combine(
                notificationBadgeManager.state,
                settings.notificationSettings.flow,
                koin.get<SessionStateProvider>().stateFlow,
                koin.get<UserRepository>().selfInfoFlow,
            ) { badge, preferences, session, user ->
                IosNotificationBadge(session is SessionState.Valid && user != null && badge.showsEntryDot(preferences))
            }.distinctUntilChanged(),
            onValue,
        )

    fun openPlayback(subjectId: Int, episodeId: Int): IosNativePlayback? {
        if (!EpisodeNavigationGuardRegistry.checkOrNotifyDenied(subjectId, episodeId)) return null
        return IosNativePlayback(subjectId, episodeId, context, koin.get(), settings)
    }

    fun observePreferences(onValue: (IosNativePreferences) -> Unit): IosObservation =
        mainScope.observe(
            combine(settings.themeSettings.flow, settings.uiSettings.flow) { theme, ui ->
                IosNativePreferences(
                    when (theme.darkMode) {
                        DarkMode.AUTO -> IosAppearance.SYSTEM
                        DarkMode.LIGHT -> IosAppearance.LIGHT
                        DarkMode.DARK -> IosAppearance.DARK
                    },
                    ui.mainSceneInitialPage.toNativeInitialTab(),
                )
            }.distinctUntilChanged(),
            onValue,
        )

    fun setAppearance(appearance: IosAppearance) {
        mainScope.launch {
            settings.themeSettings.update {
                copy(darkMode = when (appearance) {
                    IosAppearance.SYSTEM -> DarkMode.AUTO
                    IosAppearance.LIGHT -> DarkMode.LIGHT
                    IosAppearance.DARK -> DarkMode.DARK
                })
            }
        }
    }
}
