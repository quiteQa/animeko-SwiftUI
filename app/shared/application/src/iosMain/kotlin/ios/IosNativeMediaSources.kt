/*
 * Copyright (C) 2026 OpenAni and contributors.
 *
 * Use of this source code is governed by the GNU AGPLv3 license.
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.ios

import io.ktor.http.URLProtocol
import io.ktor.http.Url
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import me.him188.ani.app.data.repository.media.MediaSourceSubscriptionRepository
import me.him188.ani.app.domain.media.fetch.MediaSourceManager
import me.him188.ani.app.domain.mediasource.codec.MediaSourceCodecManager
import me.him188.ani.app.domain.mediasource.codec.serializeSubscriptionToString
import me.him188.ani.app.domain.mediasource.instance.MediaSourceInstance
import me.him188.ani.app.domain.mediasource.subscription.MediaSourceSubscription
import me.him188.ani.app.domain.mediasource.subscription.MediaSourceSubscriptionUpdater
import me.him188.ani.app.domain.mediasource.subscription.displayName
import me.him188.ani.datasources.api.source.ConnectionStatus
import me.him188.ani.utils.platform.Uuid

class IosMediaSource internal constructor(
    val id: String,
    val name: String,
    val enabled: Boolean,
    val connection: IosLoadStatus,
    val editorKind: IosMediaSourceKind?,
    val managedBySubscription: Boolean,
)

class IosMediaSourceSubscription internal constructor(
    val id: String,
    val title: String,
    val url: String,
    val description: String?,
    val enabled: Boolean,
    val updatedAtMillis: Long,
    val refreshFailed: Boolean,
    val requiresNewerApp: Boolean,
    val sources: List<IosMediaSource>,
)

class IosMediaSourceState internal constructor(
    val subscriptions: List<IosMediaSourceSubscription>,
    val localSources: List<IosMediaSource>,
    val working: Boolean,
    val failed: Boolean,
    val exportText: String?,
)

class IosNativeMediaSources internal constructor(
    private val manager: MediaSourceManager,
    private val subscriptions: MediaSourceSubscriptionRepository,
    private val updater: MediaSourceSubscriptionUpdater,
    private val codec: MediaSourceCodecManager,
    private val writes: CoroutineScope,
) {
    private val screen = IosScreenScope()
    private val working = MutableStateFlow(false)
    private val failed = MutableStateFlow(false)
    private val connections = MutableStateFlow<Map<String, IosLoadStatus>>(emptyMap())
    private val exported = MutableStateFlow<String?>(null)

    private val state = combine(
        subscriptions.flow, manager.allInstances, working, failed, combine(connections, exported, ::Pair),
    ) { subscriptions, instances, busy, failure, (tested, exportText) ->
        val available = instances.filterNot { manager.isLocal(it.factoryId) }
        val bySubscription = available.groupBy { it.config.subscriptionId }
        val activeSubscriptionIds = subscriptions.mapTo(mutableSetOf()) { it.subscriptionId }
        fun MediaSourceInstance.row() = IosMediaSource(
            instanceId,
            source.info.displayName,
            isEnabled,
            tested[instanceId] ?: IosLoadStatus.IDLE,
            IosMediaSourceKind.entries.firstOrNull { it.model.factoryId == factoryId },
            config.subscriptionId != null,
        )

        IosMediaSourceState(
            subscriptions.map { sub ->
                IosMediaSourceSubscription(
                    sub.subscriptionId,
                    sub.displayName,
                    sub.url,
                    sub.metadata?.description,
                    sub.enabled,
                    sub.lastUpdated?.timeMillis ?: 0,
                    sub.lastUpdated?.error != null,
                    sub.lastUpdated?.error?.requiresNewerApp == true,
                    bySubscription[sub.subscriptionId].orEmpty().map { it.row() },
                )
            },
            available.filter { it.config.subscriptionId !in activeSubscriptionIds }.map { it.row() },
            busy,
            failure,
            exportText,
        )
    }

    fun observe(onValue: (IosMediaSourceState) -> Unit): IosObservation = screen.coroutineScope.observe(state, onValue)

    fun addSubscription(url: String) = runAction {
        val address = url.trim()
        require(address.startsWith("https://", ignoreCase = true) || address.startsWith("http://", ignoreCase = true))
        val parsed = Url(address)
        require(parsed.host.isNotBlank() && parsed.protocol in setOf(URLProtocol.HTTP, URLProtocol.HTTPS))
        require(subscriptions.flow.first().none { it.url == address })
        val subscription = MediaSourceSubscription(Uuid.randomString(), address)
        subscriptions.add(subscription)
        updater.update(subscription.subscriptionId)
    }

    fun refreshAll() = runAction { updater.updateAllOutdated(force = true) }
    fun refresh(id: String) = runAction { updater.update(id) }

    fun setSubscriptionEnabled(id: String, enabled: Boolean) = runAction {
        subscriptions.update(id) { current ->
            manager.setEnabled(manager.getListBySubscriptionId(id).map { it.instanceId }, enabled)
            current.copy(enabled = enabled)
        }
    }

    fun deleteSubscription(id: String) = runAction {
        val subscription = subscriptions.flow.first().find { it.subscriptionId == id } ?: return@runAction
        subscriptions.remove(subscription)
        manager.removeInstances(manager.getListBySubscriptionId(id).map { it.instanceId })
    }

    fun exportSubscription(id: String) = runAction {
        val subscription = subscriptions.flow.first().find { it.subscriptionId == id } ?: return@runAction
        exported.value = codec.serializeSubscriptionToString(
            manager.getListBySubscriptionId(id),
            subscription.metadata,
        )
    }

    fun clearExport() { exported.value = null }

    fun setSourceEnabled(id: String, enabled: Boolean) = runAction { manager.setEnabled(id, enabled) }
    fun deleteLocalSource(id: String) = runAction {
        val instance = manager.allInstances.first().find { it.instanceId == id } ?: return@runAction
        if (manager.isLocal(instance.factoryId)) return@runAction
        val owner = instance.config.subscriptionId
        if (owner == null || subscriptions.flow.first().none { it.subscriptionId == owner }) {
            manager.removeInstance(id)
        }
    }

    fun reorderLocalSources(ids: List<String>) = runAction {
        val subscriptionIds = subscriptions.flow.first().mapTo(mutableSetOf()) { it.subscriptionId }
        val currentIds = manager.allInstances.first().filter {
            !manager.isLocal(it.factoryId) && it.config.subscriptionId !in subscriptionIds
        }.mapTo(mutableSetOf()) { it.instanceId }
        manager.partiallyReorderInstances(ids.filter { it in currentIds }.distinct())
    }

    fun testSource(id: String) = runAction {
        val source = manager.allInstances.first().find { it.instanceId == id }?.source ?: return@runAction
        connections.value = connections.value + (id to IosLoadStatus.LOADING)
        try {
            val result = source.checkConnection()
            connections.value = connections.value + (id to if (result == ConnectionStatus.SUCCESS) {
                IosLoadStatus.READY
            } else {
                IosLoadStatus.FAILED
            })
        } catch (e: Exception) {
            connections.value = connections.value + (id to IosLoadStatus.FAILED)
            throw e
        }
    }

    private fun runAction(block: suspend () -> Unit) {
        if (working.value) return
        working.value = true
        failed.value = false
        writes.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                failed.value = true
            } finally {
                working.value = false
            }
        }
    }

    fun close() = screen.close()
}
