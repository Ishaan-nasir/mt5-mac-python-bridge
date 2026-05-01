"""
broker/fastapi_bridge.py — HTTP Bridge (Routes Only).

This file is now a thin HTTP dispatcher. All intelligence, execution,
and analysis logic has been extracted to dedicated packages:

  sniper/         — Execution loop (reads battle_plan.json, fires trades)
  math_specialist/ — SMC analysis + mplfinance vision chart
  commander/      — Local LLM brain (writes battle_plan.json)

Shared in-process memory (dicts):
  market_state  — populated by POST /tick
  trade_queue   — consumed by GET /command (MT5 EA polls this)
  trade_results — populated by POST /result
  candle_cache  — populated by POST /candles (last closed candle snapshot)
"""
import asyncio
import json
import os
import time

import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from typing import Optional

from sniper.executor import sniper_loop, inject_shared_memory
from sniper.state_machine import CandleSnapshot
from commander.battle_planner import generate_battle_plan, commander_scheduler
from commander.eod_scheduler import eod_scheduler
from database.trade_ledger import init_db
from config import COMMANDER_INTERVAL_SECONDS, OUTPUT_DIR, ACCOUNT_STATE_PATH, EOD_TRIGGER_HOUR_UTC, MOCK_EXECUTION
from utils.file_io import safe_write_json  # BUG-1 fix: atomic account_state writes

app = FastAPI(title="TIS MT5 HTTP Bridge")

# Serve only the output/ directory as /static — .env and source are never exposed
app.mount("/static", StaticFiles(directory=OUTPUT_DIR), name="static")

# ─────────────────────────────────────────────────────────────────────
# In-process shared memory — all agents read/write these dicts
# ─────────────────────────────────────────────────────────────────────
market_state:  dict = {}   # {symbol: {"bid": float, "ask": float}}
trade_queue:   list = []   # [{"action": ..., "symbol": ..., "lot_size": ..., "sl": ..., "tp": ...}]
trade_results: dict = {}   # {"last_result": {...}}
candle_cache:  dict = {}   # {symbol: CandleSnapshot}


# ─────────────────────────────────────────────────────────────────────
# Pydantic models
# ─────────────────────────────────────────────────────────────────────

class Tick(BaseModel):
    symbol: str
    bid: float
    ask: float

class TradeResult(BaseModel):
    status: str
    ticket: Optional[int] = None
    retcode: Optional[int] = None
    action: Optional[str] = None
    symbol: Optional[str] = None
    final_pnl: Optional[float] = None   # Pillar 3: realised P&L posted by MT5


class AccountState(BaseModel):
    """Live account snapshot posted by the MT5 EA every 1 second."""
    balance:         float
    equity:          float
    margin:          float
    floating_pnl:    float
    open_positions:  int   = 0
    timestamp:       Optional[int] = None


# ─────────────────────────────────────────────────────────────────────
# Routes
# ─────────────────────────────────────────────────────────────────────

@app.post("/tick")
async def receive_tick(tick: Tick):
    """Receive sub-millisecond ticks from MT5 EA. Written to shared market_state."""
    market_state[tick.symbol] = {"bid": tick.bid, "ask": tick.ask}
    return {"status": "OK"}


@app.post("/candles")
async def receive_candles(request: Request):
    """
    Receive historical M15 candle arrays from MT5 EA on each new bar close.

    Pipeline (non-blocking — all tasks run in background):
      1. Math Specialist: SMC analysis → intelligence_report.json + vision_feed.png
      2. Commander: LLM reasoning → battle_plan.json
    """
    try:
        # HIGH-7: Hard cap on incoming request body (500 KB)
        # Protects against OOM from malformed/corrupted MT5 reconnect buffers.
        content_length = request.headers.get("content-length")
        if content_length and int(content_length) > 500_000:
            print(f"[DATA ERROR] Request body too large: {content_length} bytes. Rejecting.")
            return {"status": "REQUEST_TOO_LARGE"}

        data = await request.json()
        candles = data.get("candles", [])
        symbol = data.get("symbol", "UNKNOWN")
        h4_candles = data.get("h4_candles", [])
        daily_candles = data.get("daily_candles", [])

        print(f"\n[DATA PIPELINE] 📦 {len(candles)} M15 candles received for {symbol}")

        if len(candles) < 10:
            return {"status": "TOO_FEW_CANDLES"}

        # ── Run Math Specialist synchronously (fast Pandas/NumPy ops) ──
        from math_specialist.structure_analyzer import generate_report
        from math_specialist.vision_generator import generate_vision_chart

        report, smc_df = generate_report(candles, symbol, h4_candles, daily_candles)

        # ── Cache the last closed candle for Sniper state machine ──────
        if not smc_df.empty:
            last = smc_df.iloc[-1]
            candle_cache[symbol] = CandleSnapshot(
                open=float(last["open"]),
                close=float(last["close"]),
                high=float(last["high"]),
                low=float(last["low"]),
            )

        # ── Generate vision chart (async to avoid blocking HTTP response)
        # ── DISABLED FOR GROQ MIGRATION (LATENCY OPTIMIZATION) ──
        # if not smc_df.empty:
        #     asyncio.create_task(
        #         asyncio.to_thread(generate_vision_chart, smc_df, symbol)
        #     )

        # ── Trigger Commander (fully async — does not block tick stream) ─
        asyncio.create_task(generate_battle_plan(symbol))

        return {"status": "OK"}

    except Exception as e:
        print(f"[DATA ERROR] Failed to process candles: {e}")
        return {"status": "ERROR", "detail": str(e)}


@app.get("/command")
async def get_command():
    """
    MT5 EA polls this endpoint every 500ms.
    Returns the next queued trade command, or {"action": "NONE"}.
    """
    if trade_queue:
        return trade_queue.pop(0)
    return {"action": "NONE"}


@app.post("/result")
async def receive_result(result: TradeResult):
    """
    Receive trade execution results posted back by MT5 EA.

    Pillar 3 — Reflection Engine:
    If the result signals a trade CLOSE (action=="CLOSE" or status contains
    'close'/'closed'), fires two background tasks:
      1. write_trade_journal() — structured Obsidian .md written to Journals/
      2. trigger_incremental_reindex() — Graph-RAG cache invalidated
    Response to the EA is always instant (non-blocking).
    """
    trade_results["last_result"] = result.model_dump()
    print(f"[BRIDGE RESULT] {result.model_dump()}")

    # ── Pillar 3: Reflection Engine trigger ────────────────────────
    is_close = (
        result.action == "CLOSE"
        or "close" in (result.status or "").lower()
        or "closed" in (result.status or "").lower()
    )

    if is_close and result.ticket:
        pnl    = result.final_pnl or 0.0
        sym    = result.symbol or "XAUUSD"
        ticket = result.ticket

        async def _run_reflection():
            try:
                from memory.journal_writer import write_trade_journal
                await asyncio.to_thread(write_trade_journal, ticket, pnl, sym)
            except Exception as e:
                print(f"[REFLECTION ❌] Journal write failed: {e}")

        asyncio.create_task(_run_reflection())
        print(
            f"[BRIDGE 📓] Reflection Engine triggered: "
            f"ticket={ticket} pnl={pnl:+.2f} sym={sym}"
        )

    return {"status": "ACK"}


@app.post("/state")
async def receive_state(state: AccountState):
    """
    Receive live account state from MT5 EA every 1 second.
    Writes instantly to output/account_state.json for UI consumption.
    """
    data = state.model_dump()
    if data.get("timestamp") is None:
        data["timestamp"] = int(time.time())

    try:
        safe_write_json(ACCOUNT_STATE_PATH, data)  # BUG-1 fix: atomic + locked
    except Exception as e:
        print(f"[BRIDGE ❌] Failed to write account_state.json: {e}")
        return {"status": "ERROR", "detail": str(e)}

    return {"status": "OK"}


@app.get("/")
async def serve_dashboard():
    """Serve the Command Center UI dashboard."""
    return FileResponse("ui/index.html", media_type="text/html")


# ─────────────────────────────────────────────────────────────────────
# Startup — wire shared memory and launch background tasks
# ─────────────────────────────────────────────────────────────────────

@app.on_event("startup")
async def startup_event():
    # Ensure output/ directory exists before mounting static files
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Initialize SQLite trade ledger (creates table if not exists)
    init_db()

    # Inject shared memory references into the Sniper
    inject_shared_memory(market_state, trade_queue, candle_cache)

    # Launch Sniper execution loop (200ms cadence)
    asyncio.create_task(sniper_loop())

    # Launch Commander 15-minute fallback scheduler
    asyncio.create_task(commander_scheduler("XAUUSD", COMMANDER_INTERVAL_SECONDS))

    # Launch EOD Reflection Agent scheduler (fires daily at 17:00 EST / 22:00 UTC)
    asyncio.create_task(eod_scheduler(trigger_hour_utc=EOD_TRIGGER_HOUR_UTC))

    print("\n" + "=" * 60)
    print("  ✅ TIS FastAPI Bridge fully operational")
    print("  📡 Listening on 0.0.0.0:8000")
    if MOCK_EXECUTION:
        print("  🟡 MOCK MODE — no real trades will fire")
    else:
        print("  🔴 LIVE EXECUTION MODE — trades will be sent to MT5 EA")
    print(f"  🎯 Sniper loop armed (200ms cadence)")
    print(f"  🧠 Commander scheduler active ({COMMANDER_INTERVAL_SECONDS // 60}m interval)")
    print(f"  📓 EOD Reflection scheduled at {EOD_TRIGGER_HOUR_UTC:02d}:00 UTC ({EOD_TRIGGER_HOUR_UTC - 5:02d}:00 EST)")
    print("=" * 60 + "\n")


# ─────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000, reload=False,log_level="warning")
