/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.ios

import androidx.paging.map
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import me.him188.ani.app.data.models.person.InfoboxRowInfo
import me.him188.ani.app.data.models.person.PersonSubjectSummary
import me.him188.ani.app.data.models.subject.SubjectRelationGraphSubject
import me.him188.ani.app.data.repository.person.PersonDetailsRepository
import me.him188.ani.app.data.repository.user.SettingsRepository
import me.him188.ani.app.ui.subject.relations.SubjectRelationGraphViewModel
import me.him188.ani.utils.coroutines.flows.FlowRestarter
import me.him188.ani.utils.coroutines.flows.catching
import me.him188.ani.utils.coroutines.flows.restartable
import org.koin.mp.KoinPlatform

class IosPeopleInfo internal constructor(val label: String, val value: String)

class IosPersonReference internal constructor(val id: Int, val name: String, val artwork: String, val character: Boolean)

class IosPeopleWork internal constructor(
    val key: String,
    val subjectId: Int,
    val title: String,
    val artwork: String,
    val role: String,
)

class IosPeopleState internal constructor(
    val status: IosLoadStatus,
    val title: String = "",
    val artwork: String = "",
    val summary: String = "",
    val info: List<IosPeopleInfo> = emptyList(),
    val actors: List<IosPersonReference> = emptyList(),
    val works: List<IosPeopleWork> = emptyList(),
    val worksStatus: IosLoadStatus = IosLoadStatus.IDLE,
    val canLoadMore: Boolean = false,
    val appendFailed: Boolean = false,
)

class IosNativePeople internal constructor(id: Int, isCharacter: Boolean) {
    private val screen = IosScreenScope()
    private val repository = KoinPlatform.getKoin().get<PersonDetailsRepository>()
    private val restarter = FlowRestarter()
    private val credits: IosPagedFeed<IosPeopleWork>
    private val details: Flow<Result<IosPeopleState>>
    private val state: Flow<IosPeopleState>

    init {
        if (isCharacter) {
            credits = IosPagedFeed(screen.coroutineScope, flowOf(repository.characterSubjectsPager(id).map { page ->
                page.map { item -> item.subject.toWork(item.actors.joinToString(" / ") { it.displayName }) }
            }))
            details = repository.characterDetailsFlow(id).map { detail ->
                IosPeopleState(
                    IosLoadStatus.READY, detail.character.displayName, detail.character.imageLarge, detail.summary,
                    detail.infobox.toRows(),
                    detail.character.actors.map { IosPersonReference(it.id, it.displayName, it.imageMedium, false) },
                )
            }.catching().restartable(restarter)
        } else {
            credits = IosPagedFeed(screen.coroutineScope, flowOf(repository.personWorksPager(id).map { page ->
                page.map { item -> item.subject.toWork(item.roleNames.joinToString(" / ")) }
            }))
            details = repository.personDetailsFlow(id).map { detail ->
                IosPeopleState(
                    IosLoadStatus.READY, detail.person.displayName, detail.person.imageLarge, detail.person.summary,
                    detail.infobox.toRows(),
                )
            }.catching().restartable(restarter)
        }
        state = combine(details, credits.state) { result, page ->
            val detail = result.getOrNull() ?: return@combine IosPeopleState(IosLoadStatus.FAILED)
            IosPeopleState(
                detail.status, detail.title, detail.artwork, detail.summary,
                detail.info, detail.actors, page.items.distinctBy { it.key }, page.status, page.canLoadMore, page.appendFailed,
            )
        }
    }

    fun observe(onValue: (IosPeopleState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun retry() = restarter.restart()
    fun loadMore() = credits.loadMore()
    fun retryWorks() { credits.retry() }
    fun close() = screen.close()
}

private fun List<InfoboxRowInfo>.toRows() = map { IosPeopleInfo(it.key, it.value) }

private fun PersonSubjectSummary.toWork(role: String) =
    IosPeopleWork(subjectId.toString(), subjectId, displayName, imageLarge, role)

class IosSeriesEntry internal constructor(
    val subject: IosSubjectCard,
    val platform: String?,
    val relationship: String?,
    val selected: Boolean,
)

class IosSeriesNode internal constructor(val main: IosSeriesEntry, val number: Int, val branches: List<IosSeriesEntry>)

class IosSeriesState internal constructor(
    val status: IosLoadStatus,
    val nodes: List<IosSeriesNode> = emptyList(),
    val truncated: Boolean = false,
)

class IosNativeSeries internal constructor(subjectId: Int, settings: SettingsRepository) {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { SubjectRelationGraphViewModel(subjectId) }
    private val state = combine(viewModel.state, settings.uiSettings.flow) { state, settings ->
        val graph = state.graph ?: return@combine IosSeriesState(
            if (state.error != null) IosLoadStatus.FAILED else IosLoadStatus.LOADING,
        )
        val originalTitles = settings.subjectAppearance.useOriginalTitle
        var ordinal = 0
        IosSeriesState(
            IosLoadStatus.READY,
            graph.mainline.map { node ->
                IosSeriesNode(
                    node.subject.toEntry(subjectId, originalTitles),
                    if (node.isMinor) 0 else ++ordinal,
                    node.branches.map { it.subject.toEntry(subjectId, originalTitles, it.relation?.name ?: "OTHER") },
                )
            },
            graph.truncated,
        )
    }

    fun observe(onValue: (IosSeriesState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)
    fun retry() = viewModel.retry()
    fun close() = screen.close()
}

private fun SubjectRelationGraphSubject.toEntry(subjectId: Int, originalTitles: Boolean, relationship: String? = null) =
    IosSeriesEntry(
        IosSubjectCard(this.subjectId, if (originalTitles) name.ifBlank { displayName } else displayName, image),
        platform?.name,
        relationship,
        this.subjectId == subjectId,
    )
