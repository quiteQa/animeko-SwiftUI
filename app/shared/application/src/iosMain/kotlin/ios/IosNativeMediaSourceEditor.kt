/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.ios

import io.ktor.http.Url
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonElement
import me.him188.ani.app.data.repository.media.MediaSourceInstanceRepository
import me.him188.ani.app.domain.foundation.HttpClientProvider
import me.him188.ani.app.domain.foundation.ScopedHttpClientUserAgent
import me.him188.ani.app.domain.foundation.get
import me.him188.ani.app.domain.media.fetch.MediaSourceManager
import me.him188.ani.app.domain.mediasource.codec.MediaSourceCodecManager
import me.him188.ani.app.domain.mediasource.codec.MediaSourceEditorDraft
import me.him188.ani.app.domain.mediasource.codec.MediaSourceEditorFields
import me.him188.ani.app.domain.mediasource.codec.MediaSourceEditorImportException
import me.him188.ani.app.domain.mediasource.codec.MediaSourceEditorKind
import me.him188.ani.app.domain.mediasource.codec.MediaSourceImportError
import me.him188.ani.app.domain.mediasource.rss.DefaultRssMediaSourceEngine
import me.him188.ani.app.domain.mediasource.rss.RssMediaSourceArguments
import me.him188.ani.app.domain.mediasource.rss.RssSearchQuery
import me.him188.ani.app.domain.mediasource.web.SelectorSearchConfig
import me.him188.ani.datasources.api.EpisodeSort
import me.him188.ani.datasources.api.source.BrowseSubject
import me.him188.ani.datasources.api.source.ConnectionStatus
import me.him188.ani.datasources.api.source.MediaSource
import me.him188.ani.datasources.api.source.MediaSourceConfig
import me.him188.ani.utils.platform.Uuid

enum class IosMediaSourceKind(internal val model: MediaSourceEditorKind) {
    SELECTOR(MediaSourceEditorKind.SELECTOR),
    JSON_API(MediaSourceEditorKind.JSON_API),
    RSS(MediaSourceEditorKind.RSS),
}

data class IosMediaSourceFields(
    val name: String,
    val summary: String,
    val iconUrl: String,
    val baseUrl: String,
    val searchUrl: String,
    val episodesUrl: String,
    val playUrl: String,
    val autoMatch: Boolean,
    val filterByEpisode: Boolean,
) {
    internal constructor(fields: MediaSourceEditorFields) : this(
        fields.name, fields.description, fields.iconUrl, fields.baseUrl, fields.searchUrl, fields.episodesUrl,
        fields.playUrl, fields.autoMatch, fields.filterByEpisode,
    )

    internal fun toShared() =
        MediaSourceEditorFields(name, summary, iconUrl, baseUrl, searchUrl, episodesUrl, playUrl, autoMatch, filterByEpisode)
}

enum class IosSourceEditorError {
    MISSING, INVALID, EMPTY_IMPORT, MULTIPLE_IMPORT, WRONG_KIND, UNSUPPORTED_VERSION, CHANGED, SAVE_FAILED
}

class IosSourcePreviewRow internal constructor(val id: Int, val title: String)
class IosSourcePreviewLine internal constructor(val index: Int, val title: String?, val episodes: List<String>)

@ConsistentCopyVisibility
data class IosSourceEditorState internal constructor(
    val status: IosLoadStatus = IosLoadStatus.LOADING,
    val fields: IosMediaSourceFields? = null,
    val readOnly: Boolean = false,
    val saving: Boolean = false,
    val saved: Boolean = false,
    val draftVersion: Int = 0,
    val error: IosSourceEditorError? = null,
    val connection: IosLoadStatus = IosLoadStatus.IDLE,
    val search: IosLoadStatus = IosLoadStatus.IDLE,
    val results: List<IosSourcePreviewRow> = emptyList(),
    val canOpenResults: Boolean = false,
    val browse: IosLoadStatus = IosLoadStatus.IDLE,
    val browsedTitle: String? = null,
    val lines: List<IosSourcePreviewLine> = emptyList(),
)

class IosNativeMediaSourceEditor internal constructor(
    private val manager: MediaSourceManager,
    private val instances: MediaSourceInstanceRepository,
    private val http: HttpClientProvider,
    private val codecs: MediaSourceCodecManager,
    private val kind: IosMediaSourceKind,
    private val instanceId: String?,
    private val writes: CoroutineScope,
) {
    private val screen = IosScreenScope()
    private val state = MutableStateFlow(IosSourceEditorState())
    private val newId = if (instanceId == null) Uuid.randomString() else instanceId
    private var draft: MediaSourceEditorDraft? = null
    private var stored: JsonElement? = null
    private var previewDraft: MediaSourceEditorDraft? = null
    private var previewSubjects = emptyList<BrowseSubject>()

    init { reload() }

    fun observe(onValue: (IosSourceEditorState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)

    fun reload() {
        if (state.value.saving || testing()) return
        state.update { it.copy(status = IosLoadStatus.LOADING, error = null) }
        screen.coroutineScope.launch {
            try {
                val existing = instanceId?.let { id -> instances.flow.first().find { it.instanceId == id } }
                if (instanceId != null && existing?.factoryId != kind.model.factoryId) {
                    state.update { it.copy(status = IosLoadStatus.FAILED, error = IosSourceEditorError.MISSING) }
                    return@launch
                }
                val config = existing?.config
                stored = config?.serializedArguments
                state.update { it.copy(readOnly = config?.subscriptionId != null) }
                setDraft(MediaSourceEditorDraft.open(kind.model, stored, codecs))
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                state.update { it.copy(status = IosLoadStatus.FAILED, error = IosSourceEditorError.INVALID) }
            }
        }
    }

    fun advancedJson(fields: IosMediaSourceFields): String? = edited(fields)?.advancedJson()
    fun export(fields: IosMediaSourceFields): String? = edited(fields)?.export()

    fun applyAdvancedJson(text: String): Boolean {
        if (!canEdit()) return false
        val current = draft ?: return false
        return try {
            setDraft(current.withAdvancedJson(text))
            true
        } catch (_: Exception) {
            state.update { it.copy(error = IosSourceEditorError.INVALID) }
            false
        }
    }

    fun importConfiguration(text: String): Boolean {
        if (!canEdit()) return false
        return try {
            setDraft(MediaSourceEditorDraft.importSingle(kind.model, text, codecs))
            true
        } catch (e: MediaSourceEditorImportException) {
            val error = when (e.error) {
                MediaSourceImportError.EMPTY -> IosSourceEditorError.EMPTY_IMPORT
                MediaSourceImportError.MULTIPLE -> IosSourceEditorError.MULTIPLE_IMPORT
                MediaSourceImportError.WRONG_KIND -> IosSourceEditorError.WRONG_KIND
                MediaSourceImportError.UNSUPPORTED_VERSION -> IosSourceEditorError.UNSUPPORTED_VERSION
                MediaSourceImportError.INVALID -> IosSourceEditorError.INVALID
            }
            state.update { it.copy(error = error) }
            false
        }
    }

    fun dismissError() { state.update { it.copy(error = null) } }

    fun save(fields: IosMediaSourceFields) {
        if (!canEdit() || fields.name.isBlank() || fields.searchUrl.isBlank()) return
        val next = edited(fields) ?: return
        state.update { it.copy(saving = true, error = null) }
        writes.launch {
            try {
                val arguments = next.configuration()
                if (instanceId == null) {
                    manager.addInstance(newId, newId, kind.model.factoryId, MediaSourceConfig(serializedArguments = arguments))
                    state.update { it.copy(saved = true) }
                } else {
                    var applied = false
                    val found = instances.updateSave(instanceId) {
                        applied = factoryId == kind.model.factoryId && config.subscriptionId == null &&
                                config.serializedArguments == stored
                        if (applied) copy(config = config.copy(serializedArguments = arguments)) else this
                    }
                    state.update {
                        when {
                            !found -> it.copy(error = IosSourceEditorError.MISSING)
                            !applied -> it.copy(error = IosSourceEditorError.CHANGED)
                            else -> it.copy(saved = true)
                        }
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                state.update { it.copy(error = IosSourceEditorError.SAVE_FAILED) }
            } finally {
                state.update { it.copy(saving = false) }
            }
        }
    }

    fun testConnection(fields: IosMediaSourceFields) {
        if (state.value.saving || testing()) return
        val candidate = edited(fields) ?: return
        val config = candidate.fields
        val address = if (kind == IosMediaSourceKind.JSON_API) {
            config.baseUrl.ifBlank { SelectorSearchConfig.guessBaseUrl(config.searchUrl) }
        } else {
            config.searchUrl
        }
        val httpAddress = address.startsWith("https://", ignoreCase = true) || address.startsWith("http://", ignoreCase = true)
        if (!httpAddress || runCatching { Url(address).host.isBlank() }.getOrDefault(true)) {
            state.update { it.copy(connection = IosLoadStatus.FAILED) }
            return
        }
        val connectionDraft = if (kind == IosMediaSourceKind.JSON_API && config.baseUrl.isBlank()) {
            candidate.withFields(config.copy(baseUrl = address))
        } else {
            candidate
        }
        state.update { it.copy(connection = IosLoadStatus.LOADING) }
        screen.coroutineScope.launch {
            val connected = testSafely {
                withSource(connectionDraft) { it.checkConnection() } == ConnectionStatus.SUCCESS
            } == true
            state.update { it.copy(connection = if (connected) IosLoadStatus.READY else IosLoadStatus.FAILED) }
        }
    }

    fun testSearch(fields: IosMediaSourceFields, keyword: String) {
        if (state.value.saving || testing() || keyword.isBlank()) return
        val candidate = edited(fields) ?: return
        val query = keyword.trim()
        previewDraft = null
        previewSubjects = emptyList()
        state.update {
            it.copy(
                search = IosLoadStatus.LOADING, results = emptyList(), canOpenResults = false,
                browse = IosLoadStatus.IDLE, browsedTitle = null, lines = emptyList(),
            )
        }
        screen.coroutineScope.launch {
            val results = testSafely {
                val rss = candidate.arguments as? RssMediaSourceArguments
                if (rss != null) {
                    val client = http.get(ScopedHttpClientUserAgent.BROWSER)
                    val result = DefaultRssMediaSourceEngine(flowOf(client)).search(
                        rss.searchConfig, RssSearchQuery(query, listOf(query), EpisodeSort(1), null, null), 1, "preview:$newId",
                    )
                    result.error?.let { throw it }
                    result.allMediaList.orEmpty().take(50).map { it.originalTitle }
                } else {
                    previewSubjects = withSource(candidate) { it.searchSubjects(query).take(50) }
                    previewDraft = candidate
                    previewSubjects.map { it.name }
                }
            }
            state.update {
                it.copy(
                    search = if (results == null) IosLoadStatus.FAILED else IosLoadStatus.READY,
                    results = results.orEmpty().mapIndexed { index, title -> IosSourcePreviewRow(index, title) },
                    canOpenResults = previewDraft != null,
                )
            }
        }
    }

    fun openPreview(index: Int) {
        if (state.value.saving || testing()) return
        val candidate = previewDraft ?: return
        val subject = previewSubjects.getOrNull(index) ?: return
        state.update { it.copy(browse = IosLoadStatus.LOADING, browsedTitle = subject.name, lines = emptyList()) }
        screen.coroutineScope.launch {
            val lines = testSafely {
                withSource(candidate) { source ->
                    source.browseSubject(subject).take(50).mapIndexed { index, channel ->
                        IosSourcePreviewLine(index, channel.label, channel.episodes.take(100).map { it.name })
                    }
                }
            }
            state.update {
                it.copy(browse = if (lines == null) IosLoadStatus.FAILED else IosLoadStatus.READY, lines = lines.orEmpty())
            }
        }
    }

    fun close() = screen.close()

    private fun setDraft(value: MediaSourceEditorDraft) {
        draft = value
        previewDraft = null
        previewSubjects = emptyList()
        state.update {
            IosSourceEditorState(
                status = IosLoadStatus.READY, fields = IosMediaSourceFields(value.fields),
                readOnly = it.readOnly, draftVersion = it.draftVersion + 1,
            )
        }
    }

    private fun canEdit(): Boolean = state.value.let {
        it.status == IosLoadStatus.READY && !it.readOnly && !it.saving && !it.saved && !testing()
    }

    private fun testing(): Boolean = state.value.let {
        it.connection == IosLoadStatus.LOADING || it.search == IosLoadStatus.LOADING || it.browse == IosLoadStatus.LOADING
    }

    private fun edited(fields: IosMediaSourceFields): MediaSourceEditorDraft? =
        draft?.let { if (state.value.readOnly) it else it.withFields(fields.toShared()) }

    private suspend fun <T> withSource(candidate: MediaSourceEditorDraft, action: suspend (MediaSource) -> T): T {
        val factory = manager.allFactories.first { it.factoryId == candidate.kind.factoryId }
        val source = factory.create(
            "preview:$newId",
            MediaSourceConfig(serializedArguments = candidate.configuration()),
            http.get(ScopedHttpClientUserAgent.BROWSER),
        )
        return try {
            action(source)
        } finally {
            source.close()
        }
    }

    private suspend fun <T> testSafely(operation: suspend () -> T): T? {
        return try {
            withTimeoutOrNull(20_000) { operation() }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }
    }
}
