/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.ios

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import me.him188.ani.app.data.models.preference.BackgroundBehavior
import me.him188.ani.app.data.models.preference.NsfwMode
import me.him188.ani.app.data.repository.user.SettingsRepository
import me.him188.ani.app.navigation.MainScreenPage

enum class IosSensitiveContent { HIDE, BLUR, SHOW }

@ConsistentCopyVisibility
data class IosSettingsState internal constructor(
    val initialTab: IosInitialTab,
    val originalTitles: Boolean,
    val episodeImages: Boolean,
    val hideCompletedSearch: Boolean,
    val sensitiveContent: IosSensitiveContent,
    val autoPlayNext: Boolean,
    val autoMarkWatched: Boolean,
    val autoSkipOpeningAndEnding: Boolean,
    val autoPictureInPicture: Boolean,
    val fastSelectWeb: Boolean,
)

internal fun MainScreenPage.toNativeInitialTab(): IosInitialTab = when (this) {
    MainScreenPage.Exploration -> IosInitialTab.EXPLORE
    MainScreenPage.Collection -> IosInitialTab.COLLECTION
    MainScreenPage.CacheManagement -> IosInitialTab.DOWNLOADS
}

class IosNativeSettings internal constructor(
    private val repository: SettingsRepository,
    private val scope: CoroutineScope,
) {
    private val state = combine(
        repository.uiSettings.flow,
        repository.videoScaffoldConfig.flow,
        repository.mediaSelectorSettings.flow,
    ) { ui, player, selection ->
        IosSettingsState(
            initialTab = ui.mainSceneInitialPage.toNativeInitialTab(),
            originalTitles = ui.subjectAppearance.useOriginalTitle,
            episodeImages = ui.episodeProgress.showEpisodeImages,
            hideCompletedSearch = ui.searchSettings.ignoreDoneAndDroppedSubjects,
            sensitiveContent = when (ui.searchSettings.nsfwMode) {
                NsfwMode.HIDE -> IosSensitiveContent.HIDE
                NsfwMode.BLUR -> IosSensitiveContent.BLUR
                NsfwMode.DISPLAY -> IosSensitiveContent.SHOW
            },
            autoPlayNext = player.autoPlayNext,
            autoMarkWatched = player.autoMarkDone,
            autoSkipOpeningAndEnding = player.autoSkipOpEd,
            autoPictureInPicture = player.backgroundBehavior == BackgroundBehavior.AUTO_PICTURE_IN_PICTURE,
            fastSelectWeb = selection.fastSelectWebKind,
        )
    }.distinctUntilChanged()

    fun observe(onValue: (IosSettingsState) -> Unit): IosObservation = scope.observe(state, onValue)

    fun setInitialTab(value: IosInitialTab) {
        scope.launch {
            repository.uiSettings.update {
                copy(mainSceneInitialPage = when (value) {
                    IosInitialTab.EXPLORE -> MainScreenPage.Exploration
                    IosInitialTab.COLLECTION -> MainScreenPage.Collection
                    IosInitialTab.DOWNLOADS -> MainScreenPage.CacheManagement
                })
            }
        }
    }

    fun setOriginalTitles(enabled: Boolean) {
        scope.launch {
            repository.uiSettings.update { copy(subjectAppearance = subjectAppearance.copy(useOriginalTitle = enabled)) }
        }
    }

    fun setEpisodeImages(enabled: Boolean) {
        scope.launch {
            repository.uiSettings.update { copy(episodeProgress = episodeProgress.copy(showEpisodeImages = enabled)) }
        }
    }

    fun setHideCompletedSearch(enabled: Boolean) {
        scope.launch {
            repository.uiSettings.update {
                copy(searchSettings = searchSettings.copy(ignoreDoneAndDroppedSubjects = enabled))
            }
        }
    }

    fun setSensitiveContent(value: IosSensitiveContent) {
        scope.launch {
            repository.uiSettings.update {
                val mode = when (value) {
                    IosSensitiveContent.HIDE -> NsfwMode.HIDE
                    IosSensitiveContent.BLUR -> NsfwMode.BLUR
                    IosSensitiveContent.SHOW -> NsfwMode.DISPLAY
                }
                copy(searchSettings = searchSettings.copy(nsfwMode = mode))
            }
        }
    }

    fun setAutoPlayNext(enabled: Boolean) {
        scope.launch { repository.videoScaffoldConfig.update { copy(autoPlayNext = enabled) } }
    }

    fun setAutoMarkWatched(enabled: Boolean) {
        scope.launch { repository.videoScaffoldConfig.update { copy(autoMarkDone = enabled) } }
    }

    fun setAutoSkipOpeningAndEnding(enabled: Boolean) {
        scope.launch { repository.videoScaffoldConfig.update { copy(autoSkipOpEd = enabled) } }
    }

    fun setAutoPictureInPicture(enabled: Boolean) {
        scope.launch {
            repository.videoScaffoldConfig.update {
                copy(backgroundBehavior = if (enabled) BackgroundBehavior.AUTO_PICTURE_IN_PICTURE else BackgroundBehavior.PAUSE)
            }
        }
    }

    fun setFastSelectWeb(enabled: Boolean) {
        scope.launch { repository.mediaSelectorSettings.update { copy(fastSelectWebKind = enabled) } }
    }
}
