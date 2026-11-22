/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.domain.mediasource.codec

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import me.him188.ani.app.domain.mediasource.jsonapi.JsonApiMediaSource
import me.him188.ani.app.domain.mediasource.jsonapi.JsonApiMediaSourceArguments
import me.him188.ani.app.domain.mediasource.rss.RssMediaSource
import me.him188.ani.app.domain.mediasource.rss.RssMediaSourceArguments
import me.him188.ani.app.domain.mediasource.subscription.UnsupportedSubscriptionSchemaException
import me.him188.ani.app.domain.mediasource.web.SelectorMediaSource
import me.him188.ani.app.domain.mediasource.web.SelectorMediaSourceArguments
import me.him188.ani.datasources.api.source.FactoryId

enum class MediaSourceEditorKind(val factoryId: FactoryId) {
    SELECTOR(SelectorMediaSource.FactoryId),
    JSON_API(JsonApiMediaSource.FactoryId),
    RSS(RssMediaSource.FactoryId),
}

data class MediaSourceEditorFields(
    val name: String,
    val description: String,
    val iconUrl: String,
    val baseUrl: String = "",
    val searchUrl: String = "",
    val episodesUrl: String = "",
    val playUrl: String = "",
    val autoMatch: Boolean = true,
    val filterByEpisode: Boolean = true,
)

enum class MediaSourceImportError { EMPTY, MULTIPLE, WRONG_KIND, UNSUPPORTED_VERSION, INVALID }

class MediaSourceEditorImportException(val error: MediaSourceImportError) : Exception(error.name)

/**
 * A local configuration draft. Form edits update only the fields they expose; advanced edits and
 * import use the same versioned codecs as playback and subscriptions.
 */
class MediaSourceEditorDraft private constructor(
    val kind: MediaSourceEditorKind,
    val arguments: MediaSourceArguments,
    private val codecs: MediaSourceCodecManager,
) {
    val fields: MediaSourceEditorFields
        get() = when (val source = arguments) {
            is SelectorMediaSourceArguments -> MediaSourceEditorFields(
                source.name, source.description, source.iconUrl,
                baseUrl = source.searchConfig.rawBaseUrl,
                searchUrl = source.searchConfig.searchUrl,
                autoMatch = source.searchConfig.autoMatch.enabled,
            )
            is JsonApiMediaSourceArguments -> with(source.searchConfig) {
                MediaSourceEditorFields(
                    source.name, source.description, source.iconUrl,
                    baseUrl, search.request.url, subject.request.url, play.request.url, autoMatch.enabled,
                )
            }
            is RssMediaSourceArguments -> MediaSourceEditorFields(
                source.name, source.description, source.iconUrl,
                searchUrl = source.searchConfig.searchUrl,
                filterByEpisode = source.searchConfig.filterByEpisodeSort,
            )
            else -> error("Unsupported editor parameters")
        }

    fun withFields(fields: MediaSourceEditorFields): MediaSourceEditorDraft {
        val name = fields.name.trim()
        val description = fields.description.trim()
        val iconUrl = fields.iconUrl.trim()
        val edited = when (val source = arguments) {
            is SelectorMediaSourceArguments -> source.copy(
                name = name,
                description = description,
                iconUrl = iconUrl,
                searchConfig = source.searchConfig.copy(
                    rawBaseUrl = fields.baseUrl.trim(),
                    searchUrl = fields.searchUrl.trim(),
                    autoMatch = source.searchConfig.autoMatch.copy(enabled = fields.autoMatch),
                ),
            )
            is JsonApiMediaSourceArguments -> with(source.searchConfig) {
                source.copy(
                    name = name,
                    description = description,
                    iconUrl = iconUrl,
                    searchConfig = copy(
                        baseUrl = fields.baseUrl.trim(),
                        search = search.copy(request = search.request.copy(url = fields.searchUrl.trim())),
                        subject = subject.copy(request = subject.request.copy(url = fields.episodesUrl.trim())),
                        play = play.copy(request = play.request.copy(url = fields.playUrl.trim())),
                        autoMatch = autoMatch.copy(enabled = fields.autoMatch),
                    ),
                )
            }
            is RssMediaSourceArguments -> source.copy(
                name = name,
                description = description,
                iconUrl = iconUrl,
                searchConfig = source.searchConfig.copy(
                    searchUrl = fields.searchUrl.trim(),
                    filterByEpisodeSort = fields.filterByEpisode,
                ),
            )
            else -> error("Unsupported editor parameters")
        }
        return MediaSourceEditorDraft(kind, edited, codecs)
    }

    fun withAdvancedJson(text: String): MediaSourceEditorDraft =
        open(kind, PRETTY_JSON.parseToJsonElement(text), codecs)

    fun configuration(): JsonElement = codecs.encode(arguments).arguments

    fun advancedJson(): String = PRETTY_JSON.encodeToString(JsonElement.serializer(), configuration())

    fun export(): String = codecs.serializeToString(listOf(arguments))

    companion object {
        private val PRETTY_JSON = Json(MediaSourceCodecManager.json) { prettyPrint = true }

        fun open(kind: MediaSourceEditorKind, stored: JsonElement?, codecs: MediaSourceCodecManager): MediaSourceEditorDraft {
            val args = stored?.let { codecs.deserializeArgument(kind.factoryId, it) } ?: when (kind) {
                MediaSourceEditorKind.SELECTOR -> SelectorMediaSourceArguments.Default
                MediaSourceEditorKind.JSON_API -> JsonApiMediaSourceArguments.Default
                MediaSourceEditorKind.RSS -> RssMediaSourceArguments.Default
            }
            return MediaSourceEditorDraft(kind, args, codecs)
        }

        fun importSingle(
            kind: MediaSourceEditorKind,
            text: String,
            codecs: MediaSourceCodecManager,
        ): MediaSourceEditorDraft {
            if (text.isBlank()) throw MediaSourceEditorImportException(MediaSourceImportError.EMPTY)
            val data = try {
                codecs.decodeSubscriptionFromString(text).mediaSources
            } catch (_: UnsupportedSubscriptionSchemaException) {
                throw MediaSourceEditorImportException(MediaSourceImportError.UNSUPPORTED_VERSION)
            } catch (_: IllegalArgumentException) {
                throw MediaSourceEditorImportException(MediaSourceImportError.INVALID)
            }
            when {
                data.isEmpty() -> throw MediaSourceEditorImportException(MediaSourceImportError.EMPTY)
                data.size > 1 -> throw MediaSourceEditorImportException(MediaSourceImportError.MULTIPLE)
            }
            val source = data.single()
            if (source.factoryId != kind.factoryId) throw MediaSourceEditorImportException(MediaSourceImportError.WRONG_KIND)
            val decoded = try {
                codecs.decode(source)
            } catch (e: MediaSourceDecodeException) {
                val error = if (e is UnsupportedVersionException) {
                    MediaSourceImportError.UNSUPPORTED_VERSION
                } else {
                    MediaSourceImportError.INVALID
                }
                throw MediaSourceEditorImportException(error)
            }
            return MediaSourceEditorDraft(kind, decoded, codecs)
        }
    }
}
