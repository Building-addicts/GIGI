// channel-interface.js
// Abstract interface that all channel adapters must implement.
// Used for type documentation — JS has no enforced interfaces.

/**
 * Channel adapter interface.
 *
 * Each adapter module must export an object with this shape:
 *
 * {
 *   name: string,
 *
 *   // Handle an inbound webhook payload (HTTP request already read)
 *   handleWebhook(req, res, deps): Promise<void>,
 *
 *   // Send a text reply to a user
 *   sendText(recipientId: string, text: string, deps): Promise<void>,
 *
 *   // Send a voice note reply to a user
 *   sendVoice(recipientId: string, audioBuffer: Buffer, mimeType: string, deps): Promise<void>,
 *
 *   // Resolve an external channel ID to a GIGI userId
 *   resolveUserId(externalId: string, deps): Promise<{ gigiUserId, deviceId }>,
 * }
 *
 * deps is injected by channel-router.js and includes:
 *   { cfg, readBody, sendJson, userMapper, gigiServer, stt, tts, log }
 */
