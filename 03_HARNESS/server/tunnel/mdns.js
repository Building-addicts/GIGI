// Advertise the GIGI harness on the local network via mDNS/Bonjour under
// the service type `_gigi._tcp.local`. The iOS app uses `NWBrowser` to
// discover the service when the user picks LAN-only mode.
//
// We intentionally keep this opt-in (driven by `tunnel.mode === "lan"` in
// config.json) — it should not advertise by default because that would
// expose the harness to every device on the Wi-Fi.
import { Bonjour } from 'bonjour-service';

let bonjourInstance = null;
let currentService  = null;

/**
 * Start advertising the harness. Idempotent — calling twice just updates
 * the TXT record without throwing.
 *
 * @param {{ port:number, deviceName?:string, version?:string, bearer?:string }} opts
 * @returns {{ stop: () => void }}
 */
export function startAdvertise(opts) {
  const port = opts.port;
  if (!port) throw new Error('mdns.startAdvertise: port required');

  const txt = {
    device:  opts.deviceName || process.env.COMPUTERNAME || 'gigi-harness',
    version: opts.version    || '1.0',
    // NOTE: we do NOT put the bearer in the TXT record. The pair QR is
    // the only place the bearer leaves localhost. LAN discovery returns
    // only the device name + URL; the client scans the QR to get the bearer.
  };

  if (bonjourInstance) {
    try { currentService?.stop(); } catch {}
  } else {
    bonjourInstance = new Bonjour();
  }

  currentService = bonjourInstance.publish({
    name: txt.device,
    type: 'gigi',
    protocol: 'tcp',
    port,
    txt
  });

  return {
    stop: () => {
      try { currentService?.stop(); } catch {}
      currentService = null;
    }
  };
}

export function stopAdvertise() {
  try { currentService?.stop(); } catch {}
  currentService = null;
  try { bonjourInstance?.destroy(); } catch {}
  bonjourInstance = null;
}
