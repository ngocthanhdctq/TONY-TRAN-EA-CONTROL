# TONY TRAN EA CONTROL – Protocol v1

- Transport: HTTP on private LAN or inside Tailscale; do not expose publicly.
- Auth: `Authorization: Bearer <token>`; token minimum 32 characters.
- Bridge default: `127.0.0.1:8765` for local-only. For phone LAN/Tailscale access start with `--host 0.0.0.0` and restrict inbound TCP 8765 with Windows Firewall.
- `GET /api/status`: Bridge/EA heartbeat state.
- `POST /api/ea/heartbeat`: EA sends symbol, balance, equity, EA position count, account floating P/L.
- `POST /api/command`: queue BUY, SELL, CLOSE_ALL, MOVE_STOP, or PING.
- `GET /api/commands/next`: atomically marks one queued command DELIVERED and returns its flattened payload.
- `POST /api/commands/ack/{id}`: EA returns ACK/REJECT and message.
- `POST/GET /api/settings`: staged-only settings; not applied to EA in this build.

EA commands call the existing strategy functions: `OpenInitialPosition`, `CloseAllAndReset`, and `MoveOppositeStopOneStep`. MOVE_STOP is in actual pips and uses existing `PipSize()` conversion. The existing initial-stop unit convention is unchanged (100 units = 10 pips in the current XAUUSD convention).

The command queue is in memory. A process restart loses queued commands and ACK history. Delivery is at-most-once in this MVP: the bridge marks a command DELIVERED before returning it to EA. If network/ACK status is uncertain, inspect MT5 Experts and open positions before retrying.


### Runtime EA pause/resume
- `POST /api/command` with `{"type":"EA_DISABLE"}` pauses new market entries while position management and existing protective stops remain active.
- `POST /api/command` with `{"type":"EA_ENABLE"}` resumes new entries.
- EA heartbeat includes boolean `trading_enabled`; `/api/status` exposes the latest value. The Android UI must treat a queued request as pending until a later heartbeat confirms it.
