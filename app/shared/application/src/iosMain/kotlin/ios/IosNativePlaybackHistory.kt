/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.ios

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import me.him188.ani.app.data.repository.player.PlaybackHistoryPendingOp
import me.him188.ani.app.ui.playback.PendingSyncEpisode
import me.him188.ani.app.ui.playback.PlaybackHistorySyncStatusUiItem
import me.him188.ani.app.ui.playback.PlaybackHistoryViewModel
import me.him188.ani.datasources.api.topic.UnifiedCollectionType
import kotlin.math.floor

class IosHistoryEntry internal constructor(
    val episodeId: Int,
    val subjectId: Int,
    val name: String?,
    val episode: String?,
    val episodeNumber: String?,
    val artwork: String?,
    val positionMillis: Long,
    val durationMillis: Long,
    val updatedAtMillis: Long,
)

enum class IosPendingHistoryAction { SAVE_PROGRESS, DELETE_PROGRESS, MARK_WATCHED, UNMARK_WATCHED }

class IosHistoryPendingEntry internal constructor(
    val key: String,
    val episodeId: Int,
    val name: String?,
    val episode: String?,
    val actions: List<IosPendingHistoryAction>,
    val updatedAtMillis: Long,
)

enum class IosHistorySyncStatus { IDLE, SYNCING, FINISHED, FAILED }

class IosHistoryState internal constructor(
    val entries: List<IosHistoryEntry>,
    val pending: List<IosHistoryPendingEntry>,
    val syncStatus: IosHistorySyncStatus,
)

class IosNativePlaybackHistory internal constructor() {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { PlaybackHistoryViewModel() }
    private val syncStatus = MutableStateFlow(IosHistorySyncStatus.IDLE)
    private val entries = viewModel.stateFlow.map { records ->
        records.map { record ->
            IosHistoryEntry(
                record.episodeId, record.subjectId ?: 0, record.subjectName, record.episodeName,
                record.episodeSort?.let { if (it == floor(it)) it.toInt().toString() else it.toString() },
                record.subjectImageUrl, record.positionMillis, record.durationMillis ?: 0L, record.updatedAtMillis,
            )
        }
    }
    private val pending = viewModel.pendingSyncEpisodesFlow.map { records -> records.map { it.toEntry() } }
    private val state = combine(entries, pending, syncStatus, ::IosHistoryState)

    fun observe(onValue: (IosHistoryState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun delete(episodeId: Int) = viewModel.delete(listOf(episodeId))

    fun discardPending(key: String) {
        val item = viewModel.pendingSyncEpisodesFlow.value.firstOrNull { it.key == key } ?: return
        viewModel.deletePendingItems(
            listOf(
                PlaybackHistorySyncStatusUiItem(
                    item.episodeId, emptyList(), item.subjectName, item.episodeName, item.versionMillis,
                    item.playbackOp?.id, item.collectionOp?.id,
                ),
            ),
        )
    }

    fun sync() {
        if (syncStatus.value == IosHistorySyncStatus.SYNCING) return
        syncStatus.value = IosHistorySyncStatus.SYNCING
        screen.coroutineScope.launch {
            syncStatus.value = try {
                viewModel.syncOnce()
                IosHistorySyncStatus.FINISHED
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                IosHistorySyncStatus.FAILED
            }
        }
    }

    fun dismissSyncStatus() {
        if (syncStatus.value != IosHistorySyncStatus.SYNCING) syncStatus.value = IosHistorySyncStatus.IDLE
    }
    fun close() = screen.close()
}

private val PendingSyncEpisode.key get() = "$episodeId:${playbackOp?.id}:${collectionOp?.id}"

private fun PendingSyncEpisode.toEntry() = IosHistoryPendingEntry(
    key, episodeId, subjectName, episodeName,
    buildList {
        when (playbackOp) {
            is PlaybackHistoryPendingOp.Upsert -> add(IosPendingHistoryAction.SAVE_PROGRESS)
            is PlaybackHistoryPendingOp.Delete -> add(IosPendingHistoryAction.DELETE_PROGRESS)
            null -> Unit
        }
        collectionOp?.let {
            add(if (it.collectionType == UnifiedCollectionType.DONE) IosPendingHistoryAction.MARK_WATCHED else IosPendingHistoryAction.UNMARK_WATCHED)
        }
    },
    versionMillis,
)
