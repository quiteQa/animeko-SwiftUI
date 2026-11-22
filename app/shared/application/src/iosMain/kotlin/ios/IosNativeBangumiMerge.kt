/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.ios

import kotlinx.coroutines.flow.map
import me.him188.ani.app.data.models.bangumi.BangumiConflictFieldType
import me.him188.ani.app.data.models.bangumi.BangumiMergeSide
import me.him188.ani.app.data.models.subject.SelfRatingInfo
import me.him188.ani.app.ui.bangumi.merge.BangumiMergeApplyOutcome
import me.him188.ani.app.ui.bangumi.merge.BangumiMergeConflict
import me.him188.ani.app.ui.bangumi.merge.BangumiMergeViewModel
import me.him188.ani.app.ui.bangumi.merge.MergeRatingValue
import me.him188.ani.app.ui.bangumi.merge.sideValue
import me.him188.ani.datasources.api.topic.UnifiedCollectionType

enum class IosMergeSide(internal val model: BangumiMergeSide) {
    ANIMEKO(BangumiMergeSide.ANIMEKO), BANGUMI(BangumiMergeSide.BANGUMI),
}

enum class IosMergeField { COLLECTION, RATING, COMMENT, EPISODE }
enum class IosMergeOutcome { NONE, APPLIED, REMAINING, SYNCING, FAILED }

class IosMergeValue internal constructor(
    val collection: String? = null,
    val score: Int = 0,
    val comment: String? = null,
    val tags: List<String> = emptyList(),
    val showsComment: Boolean = false,
    val showsTags: Boolean = false,
    val privacy: Boolean? = null,
    val modifiedAtMillis: Long = 0,
) {
    val removesCollection: Boolean get() = collection == UnifiedCollectionType.NOT_COLLECTED.name
}

class IosMergeConflict internal constructor(
    val id: String,
    val field: IosMergeField,
    val animeko: IosMergeValue,
    val bangumi: IosMergeValue,
    val newer: IosMergeSide?,
    val selected: IosMergeSide?,
)

class IosMergeGroup internal constructor(val id: Int, val title: String, val conflicts: List<IosMergeConflict>)

class IosMergeChange internal constructor(
    val key: String,
    val title: String,
    val field: IosMergeField,
    val side: IosMergeSide,
    val value: IosMergeValue?,
    val watched: List<String>,
    val unwatched: List<String>,
)

class IosBangumiMergeState internal constructor(
    val status: IosLoadStatus,
    val groups: List<IosMergeGroup>,
    val changes: List<IosMergeChange>,
    val changeCount: Int,
    val selectedCount: Int,
    val conflictCount: Int,
    val syncing: Boolean,
    val applying: Boolean,
    val canApply: Boolean,
    val outcome: IosMergeOutcome,
)

class IosNativeBangumiMerge internal constructor() {
    private val screen = IosScreenScope()
    private val viewModel = screen.viewModel { BangumiMergeViewModel() }
    private val state = viewModel.uiState.map { state ->
        IosBangumiMergeState(
            status = when {
                state.isLoading -> IosLoadStatus.LOADING
                state.loadError != null -> IosLoadStatus.FAILED
                else -> IosLoadStatus.READY
            },
            groups = state.groups.map { group ->
                IosMergeGroup(group.subjectId, group.title, group.conflicts.map { conflict ->
                    IosMergeConflict(
                        conflict.id,
                        when (conflict) {
                            is BangumiMergeConflict.Collection -> IosMergeField.COLLECTION
                            is BangumiMergeConflict.Rating -> IosMergeField.RATING
                            is BangumiMergeConflict.Comment -> IosMergeField.COMMENT
                        },
                        conflict.value(BangumiMergeSide.ANIMEKO),
                        conflict.value(BangumiMergeSide.BANGUMI),
                        conflict.newerSide?.native,
                        state.choices[conflict.key]?.native,
                    )
                })
            },
            changes = state.autoMerged.mapIndexed { index, change ->
                IosMergeChange(
                    "${change.subjectId}-${change.fieldType.name}-$index",
                    change.title,
                    when (change.fieldType) {
                        BangumiConflictFieldType.COLLECTION -> IosMergeField.COLLECTION
                        BangumiConflictFieldType.RATING -> IosMergeField.RATING
                        BangumiConflictFieldType.EPISODE -> IosMergeField.EPISODE
                    },
                    change.side.native,
                    change.rating?.toMergeValue() ?: change.collectionType?.let { IosMergeValue(collection = it.name) },
                    change.watchedEpisodeSorts,
                    change.unwatchedEpisodeSorts,
                )
            },
            changeCount = state.autoMergedTotal,
            selectedCount = state.confirmedCount,
            conflictCount = state.totalConflictCount,
            syncing = state.syncInProgress,
            applying = state.isApplying,
            canApply = state.canApply,
            outcome = when (val result = state.applyOutcome) {
                null -> IosMergeOutcome.NONE
                is BangumiMergeApplyOutcome.Applied ->
                    if (result.remainingCount == 0) IosMergeOutcome.APPLIED else IosMergeOutcome.REMAINING
                BangumiMergeApplyOutcome.SyncInProgress -> IosMergeOutcome.SYNCING
                is BangumiMergeApplyOutcome.Failed -> IosMergeOutcome.FAILED
            },
        )
    }

    fun observe(onValue: (IosBangumiMergeState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)

    fun select(id: String, side: IosMergeSide) {
        val conflict = viewModel.uiState.value.groups.firstNotNullOfOrNull { group ->
            group.conflicts.firstOrNull { it.id == id }
        } ?: return
        viewModel.select(conflict.key, side.model)
    }

    fun selectAll(side: IosMergeSide) = viewModel.selectAll(side.model)
    fun selectNewer() = viewModel.adoptNewer()
    fun applyChoices() = viewModel.startApply()
    fun dismissOutcome() = viewModel.clearApplyOutcome()
    fun retry() = viewModel.reload()
    fun close() = screen.close()
}

private val BangumiMergeSide.native get() = when (this) {
    BangumiMergeSide.ANIMEKO -> IosMergeSide.ANIMEKO
    BangumiMergeSide.BANGUMI -> IosMergeSide.BANGUMI
}

private val BangumiMergeConflict.id get() = "$subjectId-${fieldType.name}"

private fun BangumiMergeConflict.value(side: BangumiMergeSide): IosMergeValue {
    val time = sideModifiedAt(side)?.toEpochMilliseconds() ?: 0
    return when (this) {
        is BangumiMergeConflict.Collection -> IosMergeValue(collection = sideValue(side).value.name, modifiedAtMillis = time)
        is BangumiMergeConflict.Rating -> {
            val value = sideValue(side).value
            IosMergeValue(
                score = value.score,
                comment = value.comment.takeIf { includesComment },
                tags = value.tags.takeIf { includesTags }.orEmpty(),
                showsComment = includesComment,
                showsTags = includesTags,
                privacy = value.isPrivate.takeIf { includesPrivate },
                modifiedAtMillis = time,
            )
        }
        is BangumiMergeConflict.Comment -> IosMergeValue(
            comment = sideValue(side).value, showsComment = true, modifiedAtMillis = time,
        )
    }
}

private fun SelfRatingInfo.toMergeValue(): IosMergeValue =
    MergeRatingValue.from(this).let { IosMergeValue(score = it.score, comment = it.comment, tags = it.tags, privacy = it.isPrivate) }
