/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.ios

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import me.him188.ani.app.ui.mediaselect.manual.ManualBrowseState
import me.him188.ani.app.ui.mediaselect.manual.ManualLoadState

class IosManualSource internal constructor(val id: String, val name: String)
class IosManualResult internal constructor(val url: String, val name: String)
class IosManualEntry internal constructor(val index: Int, val name: String?)

class IosManualBrowseState internal constructor(
    val sources: List<IosManualSource>,
    val selectedSourceId: String?,
    val keyword: String,
    val results: List<IosManualResult>,
    val searchStatus: IosLoadStatus,
    val searchBlockedByCaptcha: Boolean,
    val title: String?,
    val channels: List<IosManualEntry>,
    val selectedChannelIndex: Int,
    val episodes: List<IosManualEntry>,
    val selectedEpisodeIndex: Int,
    val episodeStatus: IosLoadStatus,
    val episodeBlockedByCaptcha: Boolean,
    val targetEpisodeNumber: String?,
    val rememberSelection: Boolean,
    val isPlaying: Boolean,
)

class IosNativeManualBrowse internal constructor(
    private val browse: ManualBrowseState,
    private val scope: CoroutineScope,
) {
    private val state = browse.presentationFlow.map { presentation ->
        val results = presentation.results
        val channels = presentation.channels
        IosManualBrowseState(
            presentation.sources.map { IosManualSource(it.instanceId, it.info.displayName) },
            presentation.selectedSourceId,
            presentation.keyword,
            results.items().map { IosManualResult(it.url, it.name) }.distinctBy { it.url },
            if (presentation.isPlaceholder) IosLoadStatus.LOADING else results.status,
            results is ManualLoadState.Failed && results.captchaUnsupported,
            presentation.openedSubject?.name,
            channels.items().mapIndexed { index, item -> IosManualEntry(index, item.label) },
            presentation.selectedChannelIndex,
            presentation.selectedChannel?.episodes.orEmpty().mapIndexed { index, item -> IosManualEntry(index, item.name) },
            presentation.selectedEpisodeIndex ?: -1,
            channels.status,
            channels is ManualLoadState.Failed && channels.captchaUnsupported,
            presentation.target?.episodeSortText,
            presentation.rememberSelection,
            presentation.isPlaying,
        )
    }

    fun observe(onValue: (IosManualBrowseState) -> Unit): IosObservation = scope.observe(state, onValue)
    fun selectSource(id: String) = browse.selectSource(id)
    fun searchIfNeeded() = browse.searchIfNeeded()
    fun search(keyword: String) {
        browse.setKeyword(keyword.trim())
        browse.search()
    }

    fun openSubject(url: String, sourceId: String): Boolean {
        val current = browse.presentationFlow.value
        if (current.selectedSourceId != sourceId) return false
        val subject = current.results.items().find { it.url == url } ?: return false
        browse.openSubject(subject)
        return true
    }

    fun closeSubject() = browse.closeSubject()
    fun retry() = browse.retry()
    fun selectChannel(index: Int) = browse.selectChannel(index)
    fun setRememberSelection(enabled: Boolean) = browse.setRememberSelection(enabled)

    fun play(index: Int, onResult: (IosLoadStatus) -> Unit) {
        scope.launch {
            browse.play(index)?.let { onResult(if (it) IosLoadStatus.READY else IosLoadStatus.FAILED) }
        }
    }
}

private val ManualLoadState<*>.status: IosLoadStatus
    get() = when (this) {
        ManualLoadState.Idle -> IosLoadStatus.IDLE
        ManualLoadState.Loading -> IosLoadStatus.LOADING
        is ManualLoadState.Success -> IosLoadStatus.READY
        is ManualLoadState.Failed -> IosLoadStatus.FAILED
    }

private fun <T> ManualLoadState<List<T>>.items(): List<T> =
    (this as? ManualLoadState.Success)?.value.orEmpty()
