/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

@file:OptIn(ExperimentalCoroutinesApi::class)

package me.him188.ani.app.ios

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import me.him188.ani.app.data.repository.user.SettingsRepository
import me.him188.ani.app.domain.media.download.DownloadEpisodeOption
import me.him188.ani.app.domain.media.fetch.MediaSourceFetchState
import me.him188.ani.app.platform.IosContext
import me.him188.ani.app.platform.PermissionManager
import me.him188.ani.app.ui.download.components.DownloadItem
import me.him188.ani.app.ui.download.createDownloadManagementViewModel
import me.him188.ani.app.ui.download.subject.DownloadMediaPickerState
import me.him188.ani.app.ui.download.subject.SubjectDownloadListItem
import me.him188.ani.app.ui.download.subject.SubjectDownloadsPresenterFactory
import me.him188.ani.datasources.api.Media
import me.him188.ani.datasources.api.source.MediaSourceKind

enum class IosDownloadStatus { DOWNLOADING, PAUSED, FAILED, COMPLETED }

class IosDownloadRow internal constructor(
    val downloadId: String,
    val episodeId: Int,
    val title: String,
    val status: IosDownloadStatus,
    val progress: Double,
    val isBusy: Boolean,
    val canPlay: Boolean,
)

class IosDownloadGroup internal constructor(
    val subjectId: Int,
    val title: String,
    val downloads: List<IosDownloadRow>,
)

class IosDownloadsState internal constructor(
    val groups: List<IosDownloadGroup>,
    val isLoading: Boolean,
    val operationFailures: Int,
)

class IosNativeDownloads internal constructor() {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { createDownloadManagementViewModel() }

    private val state = combine(viewModel.uiState, viewModel.operationFailures) { downloads, failures ->
        IosDownloadsState(
            downloads.groups.map { group ->
                IosDownloadGroup(group.subjectId, group.subjectName, group.entries.map { it.toIosRow() })
            },
            downloads.isLoading,
            failures,
        )
    }

    fun observe(onValue: (IosDownloadsState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)

    fun pause(downloadId: String) {
        findDownload(downloadId)?.let { viewModel.pauseDownload(it) }
    }

    fun resume(downloadId: String) {
        findDownload(downloadId)?.let { viewModel.resumeDownload(it) }
    }

    fun delete(downloadId: String) {
        findDownload(downloadId)?.let { viewModel.deleteDownload(it) }
    }

    fun dismissFailures() = viewModel.dismissOperationFailures()
    fun close() = screen.close()

    private fun findDownload(id: String): DownloadItem? =
        viewModel.uiState.value.groups.firstNotNullOfOrNull { group -> group.entries.firstOrNull { it.id == id } }
}

private fun DownloadItem.toIosRow() = IosDownloadRow(
    id,
    episodeId,
    displayName,
    when {
        isFinished -> IosDownloadStatus.COMPLETED
        isPaused -> IosDownloadStatus.PAUSED
        isFailed -> IosDownloadStatus.FAILED
        else -> IosDownloadStatus.DOWNLOADING
    },
    progress.getOrNull()?.toDouble() ?: 0.0,
    isBusy,
    playability == DownloadItem.Playability.PLAYABLE,
)

class IosDownloadEpisode internal constructor(
    val episodeId: Int,
    val number: String,
    val title: String,
    val published: Boolean,
)

class IosSubjectDownloadsState internal constructor(
    val title: String?,
    val episodes: List<IosDownloadEpisode>,
    val downloads: List<IosDownloadRow>,
    val status: IosLoadStatus,
    val working: Boolean,
    val operationFailures: Int,
)

enum class IosDownloadStep { NONE, SOURCES, EPISODES, FAILED }
enum class IosEpisodeDownloadAvailability { AVAILABLE, DOWNLOADED, UNMATCHED }

class IosDownloadCandidate internal constructor(
    internal val picker: DownloadMediaPickerState,
    internal val media: Media,
    val sourceName: String,
) {
    val id: String get() = media.mediaId
    val title: String get() = media.originalTitle
    val line: String get() = media.properties.alliance
}

class IosDownloadEpisodeOption internal constructor(
    val episodeId: Int,
    val number: String,
    val title: String,
    val resource: String?,
    val current: Boolean,
    val availability: IosEpisodeDownloadAvailability,
)

class IosDownloadRequestState internal constructor(
    val step: IosDownloadStep,
    val candidates: List<IosDownloadCandidate> = emptyList(),
    val loading: Boolean = false,
    val canBrowse: Boolean = false,
    val options: List<IosDownloadEpisodeOption> = emptyList(),
)

class IosNativeSubjectDownloads internal constructor(
    subjectId: Int,
    factory: SubjectDownloadsPresenterFactory,
    settings: SettingsRepository,
    private val permission: PermissionManager,
    private val context: IosContext,
) {
    private val screen = IosScreenScope()
    private val presenter = factory.create(subjectId, screen.coroutineScope)
    private val state = combine(presenter.uiState, presenter.operationFailures, settings.uiSettings.flow) { page, failures, settings ->
        IosSubjectDownloadsState(
            page.title,
            page.items.filterIsInstance<SubjectDownloadListItem.Episode>().map { (episode) ->
                val title = if (settings.subjectAppearance.useOriginalTitle) episode.originalTitle else episode.title
                IosDownloadEpisode(episode.episodeId, episode.sort.toString(), title, episode.hasPublished)
            },
            page.downloads.map { it.toIosRow() },
            when {
                page.episodesFailed || page.downloadsFailed -> IosLoadStatus.FAILED
                page.episodesLoading || page.downloadsLoading -> IosLoadStatus.LOADING
                else -> IosLoadStatus.READY
            },
            page.request.busy,
            failures,
        )
    }
    private val request = presenter.requestDialogs.flatMapLatest { request ->
        val picker = request?.selection
        val episodes = request?.episodePicker
        when {
            request?.failed == true -> flowOf(IosDownloadRequestState(IosDownloadStep.FAILED))
            episodes != null -> flowOf(IosDownloadRequestState(
                IosDownloadStep.EPISODES,
                options = episodes.options.map {
                    IosDownloadEpisodeOption(
                        it.episodeId, it.sort.toString(), it.name, it.resourceTitle, it.isCurrent,
                        when (it.availability) {
                            DownloadEpisodeOption.Availability.AVAILABLE -> IosEpisodeDownloadAvailability.AVAILABLE
                            DownloadEpisodeOption.Availability.ALREADY_DOWNLOADED -> IosEpisodeDownloadAvailability.DOWNLOADED
                            DownloadEpisodeOption.Availability.UNMATCHED -> IosEpisodeDownloadAvailability.UNMATCHED
                        },
                    )
                },
            ))
            picker != null -> {
                val names = picker.fetchSession.mediaSourceResults.associate { it.mediaSourceId to it.sourceInfo.displayName }
                combine(picker.selector.filteredCandidatesMedia, picker.fetchSession.hasCompleted) { candidates, completed ->
                    IosDownloadRequestState(
                        IosDownloadStep.SOURCES,
                        candidates = candidates.filter { it.kind == MediaSourceKind.WEB }.distinctBy { it.mediaId }.map {
                            IosDownloadCandidate(picker, it, names[it.mediaSourceId] ?: it.mediaSourceId)
                        },
                        loading = completed[MediaSourceKind.WEB] == false,
                        canBrowse = picker.manualBrowse != null,
                    )
                }
            }
            else -> flowOf(IosDownloadRequestState(IosDownloadStep.NONE))
        }
    }

    fun observe(onValue: (IosSubjectDownloadsState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun observeRequest(onValue: (IosDownloadRequestState) -> Unit): IosObservation =
        screen.coroutineScope.observe(request, onValue)

    fun requestDownload(episodeId: Int) {
        if (presenter.requestDownload(episodeId)) {
            screen.coroutineScope.launch { permission.requestNotificationPermission(context) }
        }
    }

    fun select(candidate: IosDownloadCandidate) {
        val dialog = presenter.requestDialogs.value ?: return
        if (dialog.selection !== candidate.picker || dialog.episodePicker != null) return
        presenter.selectMedia(candidate.picker.episodeId, candidate.media)
    }

    fun openManualBrowse(): IosNativeManualBrowse? =
        presenter.requestDialogs.value?.selection?.manualBrowse?.let { IosNativeManualBrowse(it, screen.coroutineScope) }

    fun confirmEpisodes(ids: List<Int>) = presenter.confirmEpisodes(ids.toSet())
    fun chooseSourceAgain() = presenter.backToMediaSelection()
    fun cancelRequest() = presenter.cancelRequest()
    fun refreshSources() {
        presenter.requestDialogs.value?.selection?.fetchSession?.mediaSourceResults?.forEach { source ->
            if (source.state.value != MediaSourceFetchState.Disabled) source.restart()
        }
    }
    fun reload() = presenter.reload()
    fun pause(downloadId: String) = presenter.pauseDownloads(setOf(downloadId))
    fun resume(downloadId: String) = presenter.resumeDownloads(setOf(downloadId))
    fun delete(downloadId: String) = presenter.deleteDownloads(setOf(downloadId))
    fun dismissFailures() = presenter.dismissOperationFailures()
    fun close() {
        presenter.close()
        screen.close()
    }
}
