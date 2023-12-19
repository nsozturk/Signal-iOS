//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

public class SentMessageTranscriptReceiverImpl: SentMessageTranscriptReceiver {

    private let attachmentDownloads: Shims.AttachmentDownloads
    private let attachmentStore: AttachmentStore
    private let disappearingMessagesJob: Shims.DisappearingMessagesJob
    private let earlyMessageManager: Shims.EarlyMessageManager
    private let groupManager: Shims.GroupManager
    private let interactionStore: InteractionStore
    private let paymentsHelper: Shims.PaymentsHelper
    private let signalProtocolStoreManager: SignalProtocolStoreManager
    private let tsAccountManager: TSAccountManager
    private let viewOnceMessages: Shims.ViewOnceMessages

    public init(
        attachmentDownloads: Shims.AttachmentDownloads,
        attachmentStore: AttachmentStore,
        disappearingMessagesJob: Shims.DisappearingMessagesJob,
        earlyMessageManager: Shims.EarlyMessageManager,
        groupManager: Shims.GroupManager,
        interactionStore: InteractionStore,
        paymentsHelper: Shims.PaymentsHelper,
        signalProtocolStoreManager: SignalProtocolStoreManager,
        tsAccountManager: TSAccountManager,
        viewOnceMessages: Shims.ViewOnceMessages
    ) {
        self.attachmentDownloads = attachmentDownloads
        self.attachmentStore = attachmentStore
        self.disappearingMessagesJob = disappearingMessagesJob
        self.earlyMessageManager = earlyMessageManager
        self.groupManager = groupManager
        self.interactionStore = interactionStore
        self.paymentsHelper = paymentsHelper
        self.signalProtocolStoreManager = signalProtocolStoreManager
        self.tsAccountManager = tsAccountManager
        self.viewOnceMessages = viewOnceMessages
    }

    public func process(
        _ transcript: SentMessageTranscript,
        localIdentifiers: LocalIdentifiers,
        tx: DBWriteTransaction
    ) {

        func validateTimestampInt64() -> Bool {
            guard SDS.fitsInInt64(transcript.timestamp) else {
                owsFailDebug("Invalid timestamp.")
                return false
            }
            return true
        }

        func validateTimestampValue() -> Bool {
            guard validateTimestampInt64() else {
                return false
            }
            guard transcript.timestamp >= 1 else {
                owsFailDebug("Transcript is missing timestamp.")
                // This transcript is invalid, discard it.
                return false
            }
            guard transcript.timestamp == transcript.dataMessageTimestamp else {
                Logger.verbose("Transcript timestamps do not match: \(transcript.timestamp) != \(transcript.dataMessageTimestamp)")
                owsFailDebug("Transcript timestamps do not match, discarding message.")
                // This transcript is invalid, discard it.
                return false
            }
            return true
        }

        switch transcript.type {
        case .recipientUpdate(let groupThread):
            // "Recipient updates" are processed completely separately in order
            // to avoid resurrecting threads or messages.
            // No timestamp validation
            self.processRecipientUpdate(transcript, groupThread: groupThread, tx: tx)
            return
        case .endSessionUpdate(let thread):
            guard validateTimestampInt64() else { return }
            Logger.info("EndSession was sent to recipient: \(thread.contactAddress)")
            self.archiveSessions(for: thread.contactAddress, tx: tx)

            let infoMessage = TSInfoMessage(thread: thread, messageType: .typeSessionDidEnd)
            interactionStore.insertInteraction(infoMessage, tx: tx)

            // Don't continue processing lest we print a bubble for the session reset.
            return
        case .paymentNotification(let target, let paymentNotification):
            Logger.info("Recording payment notification from sync transcript in thread: \(target.threadUniqueId) timestamp: \(transcript.timestamp)")
            guard validateTimestampValue() else { return }
            guard validateProtocolVersion(for: transcript, thread: target.thread, tx: tx) else { return }

            let messageTimestamp = transcript.serverTimestamp > 0 ? transcript.serverTimestamp : transcript.timestamp
            owsAssertDebug(messageTimestamp > 0)

            self.paymentsHelper.processReceivedTranscriptPaymentNotification(
                thread: target.thread,
                paymentNotification: paymentNotification,
                messageTimestamp: messageTimestamp,
                tx: tx
            )
            return

        case .expirationTimerUpdate(let target):
            Logger.info("Recording expiration timer update transcript in thread: \(target.threadUniqueId) timestamp: \(transcript.timestamp)")
            guard validateTimestampValue() else { return }
            guard validateProtocolVersion(for: transcript, thread: target.thread, tx: tx) else { return }

            updateDisappearingMessageTokenIfNecessary(target: target, localIdentifiers: localIdentifiers, tx: tx)
            return

        case .message(let messageParams):
            Logger.info("Recording transcript in thread: \(messageParams.target.threadUniqueId) timestamp: \(transcript.timestamp)")
            guard validateTimestampValue() else { return }
            self.process(
                messageParams: messageParams,
                transcript: transcript,
                localIdentifiers: localIdentifiers,
                tx: tx
            )
            return
        }
    }

    private func process(
        messageParams: SentMessageTranscriptType.Message,
        transcript: SentMessageTranscript,
        localIdentifiers: LocalIdentifiers,
        tx: DBWriteTransaction
    ) {
        guard validateProtocolVersion(for: transcript, thread: messageParams.target.thread, tx: tx) else { return }

        updateDisappearingMessageTokenIfNecessary(target: messageParams.target, localIdentifiers: localIdentifiers, tx: tx)

        // The builder() factory method requires us to specify every
        // property so that this will break if we add any new properties.
        let outgoingMessageBuilder = TSOutgoingMessageBuilder.builder(
            thread: messageParams.target.thread,
            timestamp: transcript.timestamp,
            messageBody: messageParams.body,
            bodyRanges: messageParams.bodyRanges,
            attachmentIds: [],
            expiresInSeconds: messageParams.expirationDuration,
            expireStartedAt: messageParams.expirationStartedAt,
            isVoiceMessage: false,
            groupMetaMessage: .unspecified,
            quotedMessage: messageParams.quotedMessage,
            contactShare: messageParams.contact,
            linkPreview: messageParams.linkPreview,
            messageSticker: messageParams.messageSticker,
            isViewOnceMessage: messageParams.isViewOnceMessage,
            changeActionsProtoData: nil,
            additionalRecipients: nil,
            skippedRecipients: nil,
            storyAuthorAci: messageParams.storyAuthorAci.map(AciObjC.init),
            storyTimestamp: messageParams.storyTimestamp.map { NSNumber(value: $0) },
            storyReactionEmoji: nil,
            giftBadge: messageParams.giftBadge
        )
        var outgoingMessage = interactionStore.buildOutgoingMessage(builder: outgoingMessageBuilder, tx: tx)

        // Typically `hasRenderableContent` will depend on whether or not the message has any attachmentIds
        // But since outgoingMessage is partially built and doesn't have the attachments yet, we check
        // for attachments explicitly.
        let outgoingMessageHasContent = outgoingMessage.hasRenderableContent()
            || messageParams.attachmentPointerProtos.isEmpty.negated
        if !outgoingMessageHasContent && !outgoingMessage.isViewOnceMessage {
            switch messageParams.target {
            case .group(let thread):
                if thread.isGroupV2Thread {
                    // This is probably a v2 group update.
                    Logger.warn("Ignoring message transcript for empty v2 group message.")
                } else {
                    fallthrough
                }
            case .contact:
                Logger.warn("Ignoring message transcript for empty message.")
            }
            return
        }

        let existingFailedMessage = interactionStore.findMessage(
            withTimestamp: outgoingMessage.timestamp,
            threadId: outgoingMessage.uniqueThreadId,
            author: localIdentifiers.aciAddress,
            tx: tx
        )
        if let existingFailedMessage = existingFailedMessage as? TSOutgoingMessage {
            // Update the reference to the outgoing message so that we apply all updates to the
            // existing copy, and just throw away the new copy before we insert it.
            outgoingMessage = existingFailedMessage
        } else {
            // Check for any placeholders inserted because of a previously undecryptable message
            // The sender may have resent the message. If so, we should swap it in place of the placeholder
            interactionStore.insertOrReplacePlaceholder(for: outgoingMessage, from: localIdentifiers.aciAddress, tx: tx)

            let attachmentPointers = TSAttachmentPointer.attachmentPointers(
                fromProtos: messageParams.attachmentPointerProtos,
                albumMessage: outgoingMessage
            )
            var attachmentIds = outgoingMessage.attachmentIds
            for pointer in attachmentPointers {
                attachmentStore.anyInsert(pointer, tx: tx)
                attachmentIds.append(pointer.uniqueId)
            }
            if outgoingMessage.attachmentIds.count != attachmentIds.count {
                interactionStore.updateAttachmentIds(attachmentIds, for: outgoingMessage, tx: tx)
            }
        }
        owsAssertDebug(outgoingMessage.hasRenderableContent())

        interactionStore.updateWithWasSentFromLinkedDevice(
            outgoingMessage,
            udRecipients: transcript.udRecipients,
            nonUdRecipients: transcript.nonUdRecipients,
            isSentUpdate: false,
            tx: tx
        )

        // The insert and update methods above may start expiration for this message, but
        // transcript.expirationStartedAt may be earlier, so we need to pass that to
        // the OWSDisappearingMessagesJob in case it needs to back-date the expiration.
        disappearingMessagesJob.startExpiration(
            for: outgoingMessage,
            expirationStartedAt: messageParams.expirationStartedAt,
            tx: tx
        )

        self.earlyMessageManager.applyPendingMessages(for: outgoingMessage, tx: tx)

        if (outgoingMessage.isViewOnceMessage) {
            // Don't download attachments for "view-once" messages from linked devices.
            // To be extra-conservative, always mark as complete immediately.
            viewOnceMessages.markAsComplete(message: outgoingMessage, sendSyncMessages: false, tx: tx)
        } else {
            attachmentDownloads.enqueueDownloadOfAttachmentsForNewMessage(outgoingMessage, tx: tx)
        }
    }

    private func validateProtocolVersion(
        for transcript: SentMessageTranscript,
        thread: TSThread,
        tx: DBWriteTransaction
    ) -> Bool {
        if
            let requiredProtocolVersion = transcript.requiredProtocolVersion,
            requiredProtocolVersion > SSKProtos.currentProtocolVersion
        {
            owsFailDebug("Unknown protocol version: \(requiredProtocolVersion)")

            let message = OWSUnknownProtocolVersionMessage.init(
                thread: thread,
                sender: nil,
                protocolVersion: UInt(requiredProtocolVersion)
            )
            interactionStore.insertInteraction(message, tx: tx)
            return false
        }
        return true
    }

    private func updateDisappearingMessageTokenIfNecessary(
        target: SentMessageTranscriptTarget,
        localIdentifiers: LocalIdentifiers,
        tx: DBWriteTransaction
    ) {
        switch target {
        case .group:
            return
        case .contact(let thread, let disappearingMessageToken):
            groupManager.remoteUpdateDisappearingMessages(
                withContactThread: thread,
                disappearingMessageToken: disappearingMessageToken,
                changeAuthor: localIdentifiers.aci,
                localIdentifiers: localIdentifiers,
                tx: tx
            )
        }
    }

    // MARK: -

    private func processRecipientUpdate(
        _ transcript: SentMessageTranscript,
        groupThread: TSGroupThread,
        tx: DBWriteTransaction
    ) {

        if
            transcript.udRecipients.isEmpty,
            transcript.nonUdRecipients.isEmpty
        {
            owsFailDebug("Ignoring empty 'recipient update' transcript.")
            return
        }

        let timestamp = transcript.timestamp
        if timestamp < 1 {
            owsFailDebug("'recipient update' transcript has invalid timestamp.")
            return
        }
        if !SDS.fitsInInt64(timestamp) {
            owsFailDebug("Invalid timestamp.")
            return
        }

        let groupId = groupThread.groupId
        if groupId.isEmpty {
            owsFailDebug("'recipient update' transcript has invalid groupId.")
            return
        }

        let messages: [TSOutgoingMessage]
        do {
            messages = try interactionStore
                .interactions(withTimestamp: timestamp, tx: tx)
                .compactMap { $0 as? TSOutgoingMessage }
        } catch {
            owsFailDebug("Error loading interactions: \(error)")
            return
        }

        if messages.isEmpty {
            // This message may have disappeared.
            Logger.error("No matching message with timestamp: \(timestamp)")
            return
        }

        var messageFound = false
        for message in messages {
            guard message.wasNotCreatedLocally else {
                // wasNotCreatedLocally isn't always set for very old linked messages, but:
                //
                // a) We should never receive a "sent update" for a very old message.
                // b) It's safe to discard suspicious "sent updates."
                continue
            }
            guard message.uniqueThreadId == groupThread.uniqueId else {
                continue
            }

            Logger.info("Processing 'recipient update' transcript in thread: \(groupThread.uniqueId), timestamp: \(timestamp), nonUdRecipientIds: \(transcript.nonUdRecipients), udRecipientIds: \(transcript.udRecipients)")

            interactionStore.updateWithWasSentFromLinkedDevice(
                message,
                udRecipients: transcript.udRecipients,
                nonUdRecipients: transcript.nonUdRecipients,
                isSentUpdate: true,
                tx: tx
            )

            messageFound = true
        }

        if (!messageFound) {
            // This message may have disappeared.
            Logger.error("No matching message with timestamp: \(timestamp)")
        }
    }

    private func archiveSessions(for address: SignalServiceAddress, tx: DBWriteTransaction) {
        let sessionStore = signalProtocolStoreManager.signalProtocolStore(for: .aci).sessionStore
        sessionStore.archiveAllSessions(for: address, tx: tx)
    }
}
