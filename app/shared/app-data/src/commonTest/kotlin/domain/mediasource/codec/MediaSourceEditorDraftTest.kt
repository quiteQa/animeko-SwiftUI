/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.domain.mediasource.codec

import me.him188.ani.app.domain.mediasource.jsonapi.JsonApiHttpMethod
import me.him188.ani.app.domain.mediasource.jsonapi.JsonApiMediaSourceArguments
import me.him188.ani.app.domain.mediasource.rss.RssMediaSourceArguments
import me.him188.ani.app.domain.mediasource.web.SelectorMediaSourceArguments
import me.him188.ani.app.domain.mediasource.web.format.SelectorSubjectFormatA
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs

class MediaSourceEditorDraftTest {
    private val codecs = MediaSourceCodecManager()

    @Test
    fun `editing selector basics retains configured rules and matching preferences`() {
        val original = SelectorMediaSourceArguments.Default.let { source ->
            source.copy(searchConfig = source.searchConfig.copy(
                selectorSubjectFormatA = SelectorSubjectFormatA.Config("a.result"),
                autoMatch = source.searchConfig.autoMatch.copy(preferShorterName = false),
            ))
        }
        val draft = open(original, MediaSourceEditorKind.SELECTOR)
        val changed = draft.withFields(draft.fields.copy(name = " Example ", autoMatch = false))
        val reopened = MediaSourceEditorDraft.open(changed.kind, changed.configuration(), codecs)
        val source = assertIs<SelectorMediaSourceArguments>(reopened.arguments)
        assertEquals("Example", source.name)
        assertEquals("a.result", source.searchConfig.selectorSubjectFormatA.selectLists)
        assertFalse(source.searchConfig.autoMatch.enabled)
        assertFalse(source.searchConfig.autoMatch.preferShorterName)
    }

    @Test
    fun `editing an API endpoint retains method body and field paths`() {
        val original = JsonApiMediaSourceArguments.Default.let { source ->
            val search = source.searchConfig.search
            source.copy(searchConfig = source.searchConfig.copy(search = search.copy(
                request = search.request.copy(method = JsonApiHttpMethod.POST, body = """{"q":"{keyword}"}"""),
                selectItems = "$.payload",
            )))
        }
        val draft = open(original, MediaSourceEditorKind.JSON_API)
        val changed = draft.withFields(draft.fields.copy(
            baseUrl = "https://example.test", searchUrl = "/catalog", episodesUrl = "/episodes/{id}",
        ))
        val imported = MediaSourceEditorDraft.importSingle(changed.kind, changed.export(), codecs)
        val source = assertIs<JsonApiMediaSourceArguments>(imported.arguments)
        assertEquals("/catalog", source.searchConfig.search.request.url)
        assertEquals("/episodes/{id}", source.searchConfig.subject.request.url)
        assertEquals(JsonApiHttpMethod.POST, source.searchConfig.search.request.method)
        assertEquals("""{"q":"{keyword}"}""", source.searchConfig.search.request.body)
        assertEquals("$.payload", source.searchConfig.search.selectItems)
    }

    @Test
    fun `legacy RSS exports round trip through advanced JSON`() {
        val existing = open(RssMediaSourceArguments.Default, MediaSourceEditorKind.RSS)
        val changed = existing.withFields(existing.fields.copy(
            searchUrl = "https://example.test/rss?q={keyword}", filterByEpisode = false,
        ))
        val legacy = """{"exportedMediaSourceDataList":${changed.export()}}"""
        val imported = MediaSourceEditorDraft.importSingle(changed.kind, legacy, codecs)
        val json = imported.withAdvancedJson(imported.advancedJson())
        assertEquals(changed.fields, json.fields)
        assertFalse(assertIs<RssMediaSourceArguments>(json.arguments).searchConfig.filterByEpisodeSort)
    }

    @Test
    fun `import rejects empty malformed multiple and incompatible sources`() {
        val kind = MediaSourceEditorKind.SELECTOR
        val valid = open(SelectorMediaSourceArguments.Default, kind).export()
        val multiple = codecs.serializeToString(listOf(SelectorMediaSourceArguments.Default, SelectorMediaSourceArguments.Default))
        assertImportError(kind, "", MediaSourceImportError.EMPTY)
        assertImportError(kind, "not json", MediaSourceImportError.INVALID)
        assertImportError(kind, multiple, MediaSourceImportError.MULTIPLE)
        assertImportError(MediaSourceEditorKind.RSS, valid, MediaSourceImportError.WRONG_KIND)
        assertImportError(kind, valid.replace("\"version\":2", "\"version\":999"), MediaSourceImportError.UNSUPPORTED_VERSION)
        assertImportError(kind, valid.replace("\"schemaVersion\":2", "\"schemaVersion\":999"), MediaSourceImportError.UNSUPPORTED_VERSION)
    }

    @Test
    fun `invalid advanced JSON cannot replace the draft`() {
        val draft = open(SelectorMediaSourceArguments.Default, MediaSourceEditorKind.SELECTOR)
        assertFailsWith<InvalidMediaSourceContentException> { draft.withAdvancedJson("""{"name":false}""") }
        assertEquals("Selector", draft.fields.name)
    }

    private fun open(arguments: MediaSourceArguments, kind: MediaSourceEditorKind): MediaSourceEditorDraft =
        MediaSourceEditorDraft.open(kind, codecs.encode(arguments).arguments, codecs)

    private fun assertImportError(kind: MediaSourceEditorKind, text: String, error: MediaSourceImportError) {
        assertEquals(error, assertFailsWith<MediaSourceEditorImportException> {
            MediaSourceEditorDraft.importSingle(kind, text, codecs)
        }.error)
    }
}
