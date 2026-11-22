/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

@file:OptIn(ExperimentalCoroutinesApi::class)

package me.him188.ani.app.ios

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.window.ComposeUIViewController
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.launch
import me.him188.ani.app.domain.comment.CommentContext
import me.him188.ani.app.domain.episode.UnsafeEpisodeSessionApi
import me.him188.ani.app.domain.media.selector.SelectTrigger
import me.him188.ani.app.domain.player.VideoLoadingState
import me.him188.ani.app.domain.session.SessionStateProvider
import me.him188.ani.app.pip.NoOpPictureInPictureController
import me.him188.ani.app.pip.PictureInPictureController
import me.him188.ani.app.pip.rememberPictureInPictureController
import me.him188.ani.app.pip.shouldAutoEnterPictureInPicture
import me.him188.ani.app.platform.IosContext
import me.him188.ani.app.ui.danmaku.PlayerDanmakuHost
import me.him188.ani.app.ui.mediaselect.summary.MediaSelectorSummary
import me.him188.ani.app.ui.subject.episode.EpisodeViewModel
import me.him188.ani.app.ui.subject.episode.MediampAudioLevelController
import me.him188.ani.app.videoplayer.ui.VideoPlayer
import me.him188.ani.app.videoplayer.videoenhancement.VideoEnhancementMode
import me.him188.ani.datasources.api.topic.UnifiedCollectionType
import org.openani.mediamp.features.AspectRatioMode
import org.openani.mediamp.features.AudioLevelController
import org.openani.mediamp.features.PlaybackSpeed
import org.openani.mediamp.features.VideoAspectRatio
import platform.UIKit.UIViewController
import kotlin.math.roundToInt

class IosPlaybackState internal constructor(
    val episodeId: Int,
    val subjectTitle: String,
    val episodeTitle: String,
    val episodeNumber: String,
    val isPlaying: Boolean,
    val status: IosLoadStatus,
    val danmakuEnabled: Boolean,
    val canEnterPictureInPicture: Boolean,
    val hasNextEpisode: Boolean,
)

class IosPlaybackProgress internal constructor(val positionMillis: Long, val durationMillis: Long)

class IosPlaybackSpeed internal constructor(val current: Float, val options: List<Float>)

enum class IosPlaybackAspect(internal val mode: AspectRatioMode) {
    FIT(AspectRatioMode.FIT), CROP(AspectRatioMode.CROP), STRETCH(AspectRatioMode.STRETCH),
}

enum class IosPlaybackEnhancement(internal val mode: VideoEnhancementMode) {
    OFF(VideoEnhancementMode.OFF), PERFORMANCE(VideoEnhancementMode.PERFORMANCE), QUALITY(VideoEnhancementMode.QUALITY),
}

class IosPlaybackAudio internal constructor(val level: Float, val maximum: Float, val muted: Boolean)

class IosPlaybackOptions internal constructor(
    val audio: IosPlaybackAudio?,
    val aspect: IosPlaybackAspect?,
    val enhancement: IosPlaybackEnhancement?,
    val showAutoSkip: Boolean,
)

class IosPlaybackEpisode internal constructor(
    val id: Int,
    val number: String,
    val title: String,
    val published: Boolean,
    val watched: Boolean,
    val selected: Boolean,
)

class IosPlaybackLine internal constructor(
    val mediaId: String,
    val title: String,
    val sourceName: String,
    val selected: Boolean,
)

class IosNativePlayback internal constructor(
    private val subjectId: Int,
    episodeId: Int,
    context: IosContext,
    private val session: SessionStateProvider,
) {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { EpisodeViewModel(subjectId, episodeId, context = context) }
    private val player = viewModel.player
    private val speed = player.features[PlaybackSpeed]
    private val audio = player.features[AudioLevelController]?.let { MediampAudioLevelController(it, viewModel::savePlayerVolume) }
    private val aspect = player.features[VideoAspectRatio.Key]
    private val manualBrowse by lazy { IosNativeManualBrowse(viewModel.manualBrowseState, screen.coroutineScope) }
    private val pip = MutableStateFlow<PictureInPictureController>(NoOpPictureInPictureController)
    private var resumeOnActivation = false

    private val state = combine(
        viewModel.pageState,
        player.state.map { it.playWhenReady }.distinctUntilChanged(),
        viewModel.videoStatisticsFlow.map { it.videoLoadingState }.distinctUntilChanged(),
        pip.flatMapLatest { it.isPictureInPicturePossible },
        snapshotFlow { viewModel.episodeSelectorState.hasNextEpisode },
    ) { page, playWhenReady, videoLoading, canEnterPiP, hasNext ->
        val status = when {
            page?.loadError != null || videoLoading is VideoLoadingState.Failed -> IosLoadStatus.FAILED
            page == null || page.isLoading || page.mediaSelectorSummary is MediaSelectorSummary.AutoSelecting ||
                    videoLoading is VideoLoadingState.ResolvingSource ||
                    videoLoading is VideoLoadingState.DecodingData -> IosLoadStatus.LOADING
            videoLoading == VideoLoadingState.Initial -> IosLoadStatus.IDLE
            else -> IosLoadStatus.READY
        }
        IosPlaybackState(
            page?.episodePresentation?.takeUnless { it.isPlaceholder }?.episodeId ?: episodeId,
            page?.subjectPresentation?.takeUnless { it.isPlaceholder }?.title.orEmpty(),
            page?.episodePresentation?.takeUnless { it.isPlaceholder }?.title.orEmpty(),
            page?.episodePresentation?.takeUnless { it.isPlaceholder }?.ep.orEmpty(),
            playWhenReady,
            status,
            page?.danmakuEnabled ?: false,
            canEnterPiP,
            hasNext,
        )
    }

    private val progress = combine(player.currentPositionMillis, player.mediaProperties) { position, media ->
        IosPlaybackProgress(position, media?.durationMillis ?: 0L)
    }

    private val audioState = audio?.let { controller ->
        combine(controller.levelFlow, controller.muteFlow) { level, muted ->
            IosPlaybackAudio(level, controller.range.endInclusive, muted)
        }
    } ?: flowOf(null)

    private val options = combine(
        audioState,
        aspect?.mode ?: flowOf(null),
        viewModel.videoEnhancement?.mode ?: flowOf(null),
        snapshotFlow { viewModel.playerSkipOpEdState.showSkipTips },
    ) { audio, aspect, enhancement, skip ->
        IosPlaybackOptions(
            audio,
            IosPlaybackAspect.entries.firstOrNull { it.mode == aspect },
            IosPlaybackEnhancement.entries.firstOrNull { it.mode == enhancement },
            skip,
        )
    }

    private val episodes = snapshotFlow {
        val selector = viewModel.episodeSelectorState
        val current = selector.current?.episodeId
        selector.items.map { item ->
            IosPlaybackEpisode(
                item.episodeId, item.ep, item.title, item.isKnownBroadcast,
                item.collectionType == UnifiedCollectionType.DONE, item.episodeId == current,
            )
        }
    }

    private val selector = viewModel.pageState.map { it?.mediaSelectorState }.distinctUntilChanged()
    private val lines = selector.flatMapLatest { state ->
        state?.presentationFlow?.map { presentation ->
            presentation.webSources.flatMap { source ->
                source.channels.mapNotNull { line ->
                    line.original?.let { media ->
                        IosPlaybackLine(media.mediaId, line.name, source.name, media == presentation.selected)
                    }
                }
            }.distinctBy { it.mediaId }
        } ?: flowOf(emptyList())
    }

    fun observe(onValue: (IosPlaybackState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun observeProgress(onValue: (IosPlaybackProgress) -> Unit): IosObservation =
        screen.coroutineScope.observe(progress, onValue)
    fun observeLines(onValue: (List<IosPlaybackLine>) -> Unit): IosObservation =
        screen.coroutineScope.observe(lines, onValue)
    fun observeOptions(onValue: (IosPlaybackOptions) -> Unit): IosObservation =
        screen.coroutineScope.observe(options, onValue)
    fun observeEpisodes(onValue: (List<IosPlaybackEpisode>) -> Unit): IosObservation =
        screen.coroutineScope.observe(episodes, onValue)

    fun setVolume(value: Float) {
        if (value.isFinite()) audio?.setLevel(value)
    }

    fun toggleMute() { audio?.toggleMute() }
    fun setAspect(value: IosPlaybackAspect) { aspect?.setMode(value.mode) }
    fun setEnhancement(value: IosPlaybackEnhancement) { viewModel.videoEnhancement?.setMode(value.mode) }
    fun continueOpeningOrEnding() = viewModel.playerSkipOpEdState.cancelSkipOpEd()

    fun skipOpeningOrEnding() {
        if (player.mediaProperties.value != null) {
            viewModel.onClickSkipOpEd(player.currentPositionMillis.value)
        }
    }

    fun selectEpisode(id: Int) {
        val selector = viewModel.episodeSelectorState
        val item = selector.items.firstOrNull { it.episodeId == id && it.isKnownBroadcast } ?: return
        if (selector.current?.episodeId != id) selector.select(item)
    }

    fun observeSpeed(onValue: (IosPlaybackSpeed) -> Unit): IosObservation =
        screen.coroutineScope.observe(
            combine(
                speed?.let { it.valueFlow.onStart { emit(it.value) } } ?: flowOf(1f),
                snapshotFlow { viewModel.playbackSpeedRange },
            ) { current, range ->
                val steps = ((range.endInclusive - range.start) * 4).roundToInt().coerceIn(1, 20)
                val options = (0 until steps).map { index ->
                    range.start + (range.endInclusive - range.start) * index / steps
                } + range.endInclusive
                IosPlaybackSpeed(current, if (speed == null) emptyList() else (options + current).distinct().sorted())
            },
            onValue,
        )

    fun setPlaybackSpeed(value: Float) {
        if (speed != null && value.isFinite() && value in viewModel.playbackSpeedRange) {
            viewModel.setPlaybackSpeed(value)
        }
    }

    fun openManualBrowse() = manualBrowse

    @OptIn(UnsafeEpisodeSessionApi::class)
    fun openComments(episodeId: Int): IosNativeComments =
        IosNativeComments(
            screen = IosScreenScope(),
            comments = viewModel.episodeCommentState,
            editor = viewModel.commentEditorState,
            startNewComment = {
                val current = viewModel.pageState.value?.episodePresentation
                if (current == null || current.episodeId != episodeId || current.isPlaceholder) {
                    false
                } else {
                    viewModel.commentEditorState.startEdit(CommentContext.Episode(subjectId, episodeId.toLong()))
                    true
                }
            },
            refreshComments = viewModel::refreshComments,
            threadRoute = { comment ->
                IosCommentHost.EPISODE.toRoute(subjectId, comment.episodeId?.toInt() ?: episodeId, comment.stableId, null)
            },
            session = session,
            originalUrl = "https://bgm.tv/ep/$episodeId",
        )

    fun togglePlayback() {
        if (player.state.value.playWhenReady) player.pause() else player.play()
    }

    fun seekTo(positionMillis: Long) {
        val duration = player.mediaProperties.value?.durationMillis ?: return
        if (duration > 0) player.seekTo(positionMillis.coerceIn(0, duration))
    }

    fun seekBy(offsetMillis: Long) = seekTo(player.currentPositionMillis.value + offsetMillis)
    fun setDanmakuEnabled(enabled: Boolean) = viewModel.setDanmakuEnabled(enabled)
    fun setFullscreen(fullscreen: Boolean) { viewModel.isFullscreen = fullscreen }
    fun selectNextEpisode() = viewModel.episodeSelectorState.selectNext()
    fun enterPictureInPicture() = pip.value.enterPictureInPicture()

    fun selectLine(mediaId: String) {
        val current = viewModel.pageState.value?.mediaSelectorState ?: return
        val media = current.presentationFlow.value.webSources.firstNotNullOfOrNull { source ->
            source.channels.firstNotNullOfOrNull { channel -> channel.original?.takeIf { it.mediaId == mediaId } }
        } ?: return
        current.select(media, SelectTrigger.MANUAL_AUTO_PAGE)
    }

    fun retry() {
        val loadError = viewModel.pageState.value?.loadError
        if (loadError != null) viewModel.retryLoad(loadError) else viewModel.refreshFetch()
    }

    fun didEnterBackground() {
        val playing = player.state.value.playWhenReady
        if (viewModel.playbackAutomationSuppressed.value || pip.value.isInPictureInPicture.value ||
            shouldAutoEnterPictureInPicture(viewModel.videoScaffoldConfig.backgroundBehavior, playing)
        ) {
            resumeOnActivation = false
            return
        }
        resumeOnActivation = playing
        if (playing) player.pause()
    }

    fun didBecomeActive() {
        if (resumeOnActivation && !viewModel.playbackAutomationSuppressed.value) player.play()
        resumeOnActivation = false
    }

    fun makeVideoController(): UIViewController = ComposeUIViewController {
        val controller = rememberPictureInPictureController(player)
        val isInPiP by controller.isInPictureInPicture.collectAsState()
        val page by viewModel.pageState.collectAsState()
        val playerState by player.state.collectAsState()
        val media by player.mediaProperties.collectAsState()
        DisposableEffect(controller) {
            pip.value = controller
            onDispose {
                if (pip.value === controller) pip.value = NoOpPictureInPictureController
            }
        }
        SideEffect {
            viewModel.onUIReady()
            controller.updatePolicy(
                shouldAutoEnterPictureInPicture(viewModel.videoScaffoldConfig.backgroundBehavior, playerState.playWhenReady),
                aspectWidth = media?.videoWidth,
                aspectHeight = media?.videoHeight,
            )
        }
        LaunchedEffect(viewModel) { viewModel.collectDanmakuConfig() }
        LaunchedEffect(player) {
            val audio = player.features[AudioLevelController] ?: return@LaunchedEffect
            val volume = viewModel.playerVolumeFlow.first()
            audio.setVolume(volume.level)
            audio.setMute(volume.mute)
        }
        Box(Modifier.fillMaxSize().onSizeChanged { viewModel.videoEnhancement?.setViewportSize(it.width, it.height) }) {
            VideoPlayer(player, Modifier.fillMaxSize())
            if (page?.danmakuEnabled == true && !isInPiP) {
                PlayerDanmakuHost(player, viewModel.danmakuHostState, viewModel.uiDanmakuEventFlow, Modifier.fillMaxSize())
            }
        }
    }

    fun close() {
        pip.value.updatePolicy(false, null, null)
        pip.value.exitPictureInPicture()
        screen.close()
    }
}
